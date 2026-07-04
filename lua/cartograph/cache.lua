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
M.VERSION = 4 -- v4: per-file shards; v3: binary codec; v2: data.names

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
    root = vim.fn.fnamemodify(vim.fn.expand(root), ':p'):gsub('/+$', '')
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
    fd:write(M.encode(t))
    fd:close()
    return true
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

--- Persist a raw graph. `dirty` (list of rels) limits the write to those
--- files' shards — the caller owes an HONEST account of every file whose
--- contribution changed (splice reports one); nil writes everything.
--- `deleted` removes shards. Post-pass artifacts (sql:: entities,
--- frontier landings) are stripped — they re-derive; unparsed bundle
--- modules live in the manifest and are synthesized at load.
function M.save(data, dirty, deleted)
    if require('cartograph.config').cache == false then return end
    if not (data and data.provider == 'treesitter' and data.stamps) then
        return
    end
    local dir = M.path(data.root)
    vim.fn.mkdir(dir, 'p')

    local want = {}
    if dirty then
        for _, f in ipairs(dirty) do
            if data.stamps[f] then want[f] = true end
        end
    else
        for f in pairs(data.stamps) do want[f] = true end
    end

    -- synthetic ids: never persisted (their edges either)
    local synth = {}
    for _, n in ipairs(data.nodes) do
        if n.id:sub(1, 5) == 'sql::' or n.unparsed then synth[n.id] = true end
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
    for f, s in pairs(shards) do
        if not write_encoded(dir .. '/' .. fkey(f), s) then
            return vim.notify('cartograph: cannot write cache shard for ' .. f,
                vim.log.levels.WARN)
        end
    end
    for _, f in ipairs(deleted or {}) do
        vim.fn.delete(dir .. '/' .. fkey(f))
    end
    if not dirty then
        -- full save: sweep shards of files no longer in the graph
        local keep = { ['manifest.bin'] = true }
        for f in pairs(data.stamps) do keep[fkey(f)] = true end
        local it = vim.uv.fs_scandir(dir)
        while it do
            local name = vim.uv.fs_scandir_next(it)
            if not name then break end
            if not keep[name] then vim.fn.delete(dir .. '/' .. name) end
        end
    end
    -- manifest LAST: the commit point (a crash above leaves the old
    -- manifest pointing at old-or-new shards, both decodable; version
    -- and per-open validation turn any real skew into a cold miss)
    write_encoded(dir .. '/manifest.bin', {
        version = M.VERSION, root = data.root, schema = data.schema,
        stamps = data.stamps, unparsed = data.unparsed,
        capabilities = data.capabilities, no_parser = data.no_parser,
    })
end

--- Load a cached graph for `root`: manifest + every shard, concatenated
--- in sorted order (deterministic). nil on any miss, skew or doubt —
--- a miss just means a cold extract, never a wrong graph.
function M.load(root)
    if require('cartograph.config').cache == false then return nil end
    local m, dir = read_manifest(root)
    if not m then return nil end
    local data = { schema = m.schema or 1, root = m.root,
        provider = 'treesitter', capabilities = m.capabilities,
        no_parser = m.no_parser, stamps = m.stamps,
        nodes = {}, edges = {}, calls = {}, names = {} }
    local files = {}
    for f in pairs(m.stamps) do files[#files + 1] = f end
    table.sort(files)
    for _, f in ipairs(files) do
        local s = read_decoded(dir .. '/' .. fkey(f))
        if not (type(s) == 'table' and s.nodes) then return nil end
        for _, n in ipairs(s.nodes) do data.nodes[#data.nodes + 1] = n end
        for _, e in ipairs(s.edges or {}) do data.edges[#data.edges + 1] = e end
        for _, c in ipairs(s.calls or {}) do data.calls[#data.calls + 1] = c end
        if s.names then data.names[f] = s.names end
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
    return data
end

--- Diff a cached graph against the tree as it is NOW. Returns
--- (changed, deleted): changed covers edits AND new files (no stamp);
--- an unparsed bundle counts only when it appears or vanishes — content
--- churn inside it is the frontier machinery's job.
function M.diff(data)
    local ts = require 'cartograph.providers.treesitter'
    local files, minified = ts.list_files(data.root)
    local changed, deleted, on_disk = {}, {}, {}
    for _, f in ipairs(files) do
        on_disk[f] = true
        local st = vim.uv.fs_stat(data.root .. '/' .. f)
        local now = st
            and ('%d:%d:%d'):format(st.mtime.sec, st.mtime.nsec, st.size)
        if data.stamps[f] ~= now then changed[#changed + 1] = f end
    end
    local un = {}
    for _, f in ipairs(data.unparsed or {}) do un[f] = true end
    for _, f in ipairs(minified) do
        on_disk[f] = true
        if not un[f] then changed[#changed + 1] = f end
    end
    for f in pairs(data.stamps) do
        if not on_disk[f] then deleted[#deleted + 1] = f end
    end
    for f in pairs(un) do
        if not on_disk[f] then deleted[#deleted + 1] = f end
    end
    table.sort(changed)
    table.sort(deleted)
    return changed, deleted
end

--- The incremental open: cached graph brought up to date, or nil (cold).
--- Returns (data, note) — note says what happened, honestly.
function M.open(root)
    if require('cartograph.config').cache == false then return nil end
    -- diff from the MANIFEST: the warm/cold decision costs a few KB,
    -- not a shard sweep it might immediately discard
    local m = read_manifest(root)
    if not m then return nil end
    local changed, deleted = M.diff(m)

    -- a warm open must never lose to a cold one: the splice re-extracts
    -- changed files SEQUENTIALLY and blocks the UI, while the cold path
    -- is parallel and streams. Past the break-even (≈ total/workers,
    -- since cold divides the whole tree by the worker count), step aside
    -- WITHOUT reading a single shard. Only when cold would actually BE
    -- parallel: on a small or parallel-disabled project, cold is
    -- sequential over the whole tree and the warm splice always wins.
    local cfg = require 'cartograph.config'
    local total = vim.tbl_count(m.stamps)
    local would_parallel = cfg.parallel ~= false
        and total >= (cfg.parallel_threshold or 300)
    local limit = cfg.cache_max_diff or math.max(32,
        math.floor(total
            / require('cartograph.parallel').default_workers()))
    if (would_parallel or cfg.cache_max_diff) and #changed > limit then
        return nil, ('%d files changed (warm limit %d) — cold extract'
            .. ' is faster, going parallel'):format(#changed, limit)
    end

    -- committed to warm: NOW read the shards
    local data = M.load(root)
    if not data then return nil end
    if #changed == 0 and #deleted == 0 then
        return data, ('warm open — %d files unchanged'):format(total)
    end
    local stats = require('cartograph.refresh').splice(data, changed, deleted)
    -- O(diff) persist: exactly the shards the splice reports dirty
    M.save(data, stats.dirty, deleted)
    return data, ('warm open — %d re-extracted, %d deleted, %d shards'
        .. ' rewritten, rest untouched')
        :format(#changed, #deleted, #(stats.dirty or {}))
end

return M
