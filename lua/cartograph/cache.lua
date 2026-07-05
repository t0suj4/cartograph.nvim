-- The incremental cache: extraction is a pure function of file contents,
-- and node ids are deterministic (file::name@line) — so an unchanged
-- file's entire contribution to the graph, INCLUDING edges between two
-- unchanged files, is still valid. The cache is that contribution,
-- SHARDED PER FILE: a shard holds everything a file originates (its
-- nodes, its calls, the edges leaving its nodes, its stamp, its mention
-- index), so a save touches only the shards a change actually dirtied —
-- O(diff), not O(corpus). The MANIFEST (stamps + unparsed roster) is the
-- sidecar and the commit point: the warm/cold decision reads a few KB,
-- never a blob it might discard. Load is a deterministic concat of
-- shards — the state was globally consistent when saved, so no relink.
--
-- Only RAW graphs are cached (before xlang/sql/toc/clangd post-passes —
-- init re-runs those on every open; oracle verdicts are session-live by
-- design). Slice opens (opts.subdirs) bypass the cache entirely.
-- setup{ cache = false } opts out.

local M = {}

-- bump when the extractor's OUTPUT shape changes (new node fields,
-- resolution semantics) — a stale-format cache must miss, not mislead
M.VERSION = 9 -- v9: lua module nodes carry load-time effects;
              -- v8: import edges carry their local binding (bind);
              -- v7: php oo/loaders/torn defs (receiver-aware calls,
              -- PSR-4 suffixes, error-gated indexing);
              -- v6: containers (vue/svelte) + js/ts one resolution family;
              -- v5: any stamped source (manifest carries provider);
              -- v4: per-file shards; v3: binary codec; v2: data.names

-- The codec is the cache's speed floor. string.buffer (LuaJIT) is
-- near-memcpy; vim.mpack is the fallback. Either way binary-safe (the
-- \31-packed name index rides untouched) and faithful to Lua tables —
-- no vim.NIL artifacts. A file written by one codec and read by a
-- build with the other simply misses (decode fails -> cold extract).
local has_sb, sb = pcall(require, 'string.buffer')

function M.encode(t)
    return has_sb and sb.encode(t) or vim.mpack.encode(t)
end

function M.decode(s)
    if has_sb then
        local ok, v = pcall(sb.decode, s)
        if ok then return v end
    end
    local ok, v = pcall(vim.mpack.decode, s)
    if ok then return v end
    return nil
end

--- Cache directory for a project root (root normalized like extract
--- does). Layout: <dir>/manifest.bin + <dir>/<file-key>.bin shards.
function M.path(root)
    local base = vim.fn.stdpath('cache') .. '/cartograph'
    vim.fn.mkdir(base, 'p')
    if root:match('^%w+://') then
        -- URI roots (mcp://pg) are stable identities, not paths
        root = root:gsub('/+$', '')
    else
        root = vim.fn.fnamemodify(vim.fn.expand(root), ':p'):gsub('/+$', '')
    end
    return base .. '/' .. root:gsub('[/\\:]', '%%') .. '.d', root
end

--- Remove a root's cache entirely (shards, manifest, legacy flat files).
function M.wipe(root)
    local dir = M.path(root)
    vim.fn.delete(dir, 'rf')
    for _, ext in ipairs({ '.bin', '.meta', '.json' }) do
        vim.fn.delete((dir:gsub('%.d$', ext)))
    end
end

local function fkey(rel)
    return rel:gsub('[/\\:]', '%%') .. '.bin'
end

local function file_of(id)
    return id:match('^(.-)::') or id
end

local function read_decoded(file)
    local fd = io.open(file, 'rb')
    if not fd then return nil end
    local txt = fd:read('a')
    fd:close()
    return M.decode(txt)
end

local function write_encoded(file, t)
    local fd = io.open(file, 'wb')
    if not fd then return false end
    local bytes = M.encode(t)
    fd:write(bytes)
    fd:close()
    return #bytes
end

-- the manifest is the COMMIT POINT: written to a temp file and renamed
-- into place, so a crash mid-write can only ever leave the old one
local function write_manifest(dir, m)
    local tmp = dir .. '/manifest.tmp'
    if not write_encoded(tmp, m) then return false end
    return pcall(vim.uv.fs_rename, tmp, dir .. '/manifest.bin')
end

local function read_manifest(root)
    local dir, nroot = M.path(root)
    local m = read_decoded(dir .. '/manifest.bin')
    if type(m) == 'table' and m.version == M.VERSION and m.root == nroot
        and type(m.stamps) == 'table' then
        return m, dir
    end
    return nil, dir
end

-- bucket a graph into per-file shard tables (nil want = all files)
local function build_shards(data, want)
    -- synthetic ids: never persisted (their edges either) — sql entities
    -- and db-linked tables re-derive as post-passes, landings re-search
    local synth = {}
    for _, n in ipairs(data.nodes) do
        if n.id:sub(1, 5) == 'sql::' or n.unparsed or n.db or n.dj then
            synth[n.id] = true
        end
    end
    local shards = {}
    for f in pairs(want) do
        shards[f] = { nodes = {}, edges = {}, calls = {},
            stamp = data.stamps[f],
            names = data.names and data.names[f] or nil }
    end
    for _, n in ipairs(data.nodes) do
        local s = not synth[n.id] and shards[n.file]
        if s then s.nodes[#s.nodes + 1] = n end
    end
    for _, e in ipairs(data.edges) do
        if not (synth[e.from] or synth[e.to]) then
            local s = shards[file_of(e.from)]
            if s then s.edges[#s.edges + 1] = e end
        end
    end
    for _, c in ipairs(data.calls or {}) do
        local s = shards[c.file]
        if s then s.calls[#s.calls + 1] = c end
    end
    return shards
end

local function manifest_of(data, sizes)
    return { version = M.VERSION, root = data.root, schema = data.schema,
        provider = data.provider, -- which source: dispatch key for diff/refresh
        stamps = data.stamps, unparsed = data.unparsed,
        capabilities = data.capabilities, no_parser = data.no_parser,
        sizes = sizes } -- per-shard byte lengths: truncation detector
end

--- Sweep shard files the manifest no longer references. Deletion is a
--- TOMBSTONE BY OMISSION: load() reads only manifest-referenced shards,
--- so garbage is inert — reclaiming it is never on the hot path.
--- Deferred by default; { sync = true } runs now and returns the count.
M._gc_pending = {}
function M.gc(root, opts)
    local function sweep()
        M._gc_pending[root] = nil
        local m, dir = read_manifest(root)
        if not m then return 0 end
        local keep = { ['manifest.bin'] = true, ['manifest.tmp'] = true }
        for f in pairs(m.stamps) do keep[fkey(f)] = true end
        local removed = 0
        local it = vim.uv.fs_scandir(dir)
        while it do
            local name = vim.uv.fs_scandir_next(it)
            if not name then break end
            if not keep[name] then
                vim.fn.delete(dir .. '/' .. name)
                removed = removed + 1
            end
        end
        return removed
    end
    if opts and opts.sync then return sweep() end
    if M._gc_pending[root] then return end
    M._gc_pending[root] = true
    vim.defer_fn(sweep, 2000)
end

--- Persist a raw graph, synchronously. `dirty` (list of rels) limits the
--- write to those files' shards — the caller owes an HONEST account of
--- every file whose contribution changed (splice reports one); nil
--- writes everything. Deletions need no unlink: the manifest omits them
--- (tombstone), gc reclaims the files later. Post-pass artifacts (sql::
--- entities, frontier landings) are stripped — they re-derive; unparsed
--- bundle modules live in the manifest and are synthesized at load.
function M.save(data, dirty)
    if require('cartograph.config').cache == false then return end
    -- persistable <=> stamps: the source supplied wire-free validity
    -- keys, whatever it is. Samples (no stamps) never persist.
    if not (data and data.provider and data.stamps) then return end
    local dir = M.path(data.root)
    vim.fn.mkdir(dir, 'p')
    M._bg_cancel(data.root) -- a sync save supersedes an in-flight one

    local want = {}
    if dirty then
        for _, f in ipairs(dirty) do
            if data.stamps[f] then want[f] = true end
        end
    else
        for f in pairs(data.stamps) do want[f] = true end
    end
    -- sizes for untouched shards carry over from the previous manifest
    local old = dirty and read_manifest(data.root) or nil
    local sizes = {}
    for f in pairs(data.stamps) do
        sizes[f] = old and old.sizes and old.sizes[f] or nil
    end
    for f, s in pairs(build_shards(data, want)) do
        local n = write_encoded(dir .. '/' .. fkey(f), s)
        if not n then
            return vim.notify('cartograph: cannot write cache shard for ' .. f,
                vim.log.levels.WARN)
        end
        sizes[f] = n
    end
    -- manifest LAST: the commit point (any skew re-splices at next diff)
    write_manifest(dir, manifest_of(data, sizes))
    M.gc(data.root)
end

-- Background full save: ENCODE NOW (immutable strings — post-passes may
-- mutate the live graph the moment we return, encoded bytes can't lie),
-- write on a timer, manifest last. Cancelling (a newer save for the same
-- root) simply never writes the manifest: the old one stands, and any
-- shard file already overwritten re-splices at the next diff — the
-- commit-point discipline makes partial background work harmless.
M._bg = {}
function M._bg_cancel(root)
    local t = M._bg[root]
    if t then
        M._bg[root] = nil
        pcall(function () t:stop(); t:close() end)
    end
end

function M.saving(root)
    local _, nroot = M.path(root)
    return M._bg[nroot] ~= nil
end

function M.save_bg(data)
    if require('cartograph.config').cache == false then return end
    if not (data and data.provider and data.stamps) then return end
    local dir = M.path(data.root)
    vim.fn.mkdir(dir, 'p')
    M._bg_cancel(data.root)

    local want = {}
    for f in pairs(data.stamps) do want[f] = true end
    local jobs, sizes = {}, {}
    for f, s in pairs(build_shards(data, want)) do
        local bytes = M.encode(s)
        jobs[#jobs + 1] = { file = dir .. '/' .. fkey(f), bytes = bytes }
        sizes[f] = #bytes
    end
    local manifest = manifest_of(data, sizes)

    local i, root = 1, data.root
    local timer = vim.uv.new_timer()
    M._bg[root] = timer
    timer:start(0, 15, vim.schedule_wrap(function ()
        if M._bg[root] ~= timer then return end -- superseded
        local stop = math.min(i + 255, #jobs)
        while i <= stop do
            local fd = io.open(jobs[i].file, 'wb')
            if fd then
                fd:write(jobs[i].bytes)
                fd:close()
            end
            i = i + 1
        end
        if i > #jobs then
            write_manifest(dir, manifest)
            M._bg_cancel(root)
            M.gc(root)
        end
    end))
end

--- Load a cached graph for `root`: manifest + every shard, concatenated
--- in sorted order (deterministic). A CORRUPTED SHARD (truncated —
--- caught by the manifest's byte length — undecodable, or misshapen)
--- costs exactly that file: it is skipped and reported in the `bad`
--- list, and the caller re-extracts it like any changed file.
--- Extraction is a pure function of file content, so the repair is
--- exact. Only a bad MANIFEST misses the whole cache.
--- Returns (data, bad) or nil.
function M.load(root)
    if require('cartograph.config').cache == false then return nil end
    local m, dir = read_manifest(root)
    if not m then return nil end
    local data = { schema = m.schema or 1, root = m.root,
        provider = m.provider or 'treesitter', capabilities = m.capabilities,
        no_parser = m.no_parser, stamps = m.stamps,
        nodes = {}, edges = {}, calls = {}, names = {} }
    local files, bad = {}, {}
    for f in pairs(m.stamps) do files[#files + 1] = f end
    table.sort(files)
    for _, f in ipairs(files) do
        local path = dir .. '/' .. fkey(f)
        local want = m.sizes and m.sizes[f]
        local st = vim.uv.fs_stat(path)
        local s = (st and (not want or st.size == want))
            and read_decoded(path) or nil
        if type(s) == 'table' and type(s.nodes) == 'table' then
            for _, n in ipairs(s.nodes) do data.nodes[#data.nodes + 1] = n end
            for _, e in ipairs(s.edges or {}) do
                data.edges[#data.edges + 1] = e
            end
            for _, c in ipairs(s.calls or {}) do
                data.calls[#data.calls + 1] = c
            end
            if s.names then data.names[f] = s.names end
        else
            bad[#bad + 1] = f
            data.stamps[f] = nil -- its content is NOT represented
            data.names[f] = nil
        end
    end
    -- frontier bundles: modules synthesized from the manifest roster
    if m.unparsed and #m.unparsed > 0 then
        data.unparsed = m.unparsed
        for _, f in ipairs(m.unparsed) do
            data.nodes[#data.nodes + 1] = { id = f, name = f, kind = 'module',
                file = f, unparsed = true, order = -1,
                range = { start = { line = 0, char = 0 },
                    ['end'] = { line = 0, char = 0 } } }
        end
    end
    return data, bad
end

--- The incremental open: cached graph brought up to date, or nil (cold).
--- Returns (data, note) — note says what happened, honestly.
function M.open(root)
    if require('cartograph.config').cache == false then return nil end
    -- diff from the MANIFEST: the warm/cold decision costs a few KB (or
    -- one cheap stamps round-trip), not a shard sweep it might discard
    local m = read_manifest(root)
    if not m then return nil end
    local src = require 'cartograph.source'
    local p = src.provider(m)
    -- warm-openable <=> the source can diff and re-extract slices
    if not (p and p.diff and p.refresh_slice) then return nil end
    local changed, deleted = p.diff(m)
    if not changed then
        return nil, 'diff unavailable (' .. tostring(deleted) .. ') — cold'
    end

    -- a warm open must never lose to a cold one: the splice re-extracts
    -- changed files SEQUENTIALLY and blocks the UI, while the cold path
    -- is parallel and streams. Past the break-even (≈ total/workers,
    -- since cold divides the whole tree by the worker count), step aside
    -- WITHOUT reading a single shard. Only where cold IS parallel — the
    -- filesystem source above the threshold; other sources have no
    -- parallel path, so warm always wins for them.
    local cfg = require 'cartograph.config'
    local total = vim.tbl_count(m.stamps)
    if m.provider == 'treesitter' or not m.provider then
        local would_parallel = cfg.parallel ~= false
            and total >= (cfg.parallel_threshold or 300)
        local limit = cfg.cache_max_diff or math.max(32,
            math.floor(total
                / require('cartograph.parallel').default_workers()))
        if (would_parallel or cfg.cache_max_diff) and #changed > limit then
            return nil, ('%d files changed (warm limit %d) — cold extract'
                .. ' is faster, going parallel'):format(#changed, limit)
        end
    end

    -- committed to warm: NOW read the shards. Corrupted ones cost
    -- exactly their own file — they join the changed set and re-extract
    local data, bad = M.load(root)
    if not data then return nil end
    if bad and #bad > 0 then
        local seen = {}
        for _, f in ipairs(changed) do seen[f] = true end
        for _, f in ipairs(bad) do
            if not seen[f] then changed[#changed + 1] = f end
        end
        table.sort(changed)
    end
    if #changed == 0 and #deleted == 0 then
        return data, ('warm open — %d files unchanged'):format(total)
    end
    local stats = require('cartograph.refresh').splice(data, changed, deleted)
    -- O(diff) persist: exactly the shards the splice reports dirty
    -- (deleted files are tombstoned by manifest omission; gc reclaims)
    M.save(data, stats.dirty)
    return data, ('warm open — %d re-extracted, %d deleted, %d shards'
        .. ' rewritten, rest untouched%s')
        :format(#changed, #deleted, #(stats.dirty or {}),
            (bad and #bad > 0)
                and ('; %d corrupted shard(s) repaired'):format(#bad) or '')
end

return M
