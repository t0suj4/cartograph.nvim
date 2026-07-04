-- The incremental cache: extraction is a pure function of file contents,
-- and node ids are deterministic (file::name@line) — so an unchanged
-- file's entire contribution to the graph, INCLUDING edges between two
-- unchanged files, is still valid. The cache is simply the raw extracted
-- graph saved per project root; an incremental open loads it, stats every
-- stamp, re-extracts only the diff through refresh.splice, and relinks.
-- A warm open of an untouched tree is one JSON decode.
--
-- Only RAW graphs are cached (before xlang/sql/toc/clangd post-passes —
-- init re-runs those on every open; oracle verdicts are session-live by
-- design). Slice opens (opts.subdirs) bypass the cache entirely: a slice
-- would poison the full-tree entry. setup{ cache = false } opts out.

local M = {}

-- bump when the extractor's OUTPUT shape changes (new node fields,
-- resolution semantics) — a stale-format cache must miss, not mislead
M.VERSION = 2 -- v2: data.names (per-file identifier mention index)

--- Cache file for a project root (root normalized like extract does).
function M.path(root)
    local dir = vim.fn.stdpath('cache') .. '/cartograph'
    vim.fn.mkdir(dir, 'p')
    root = vim.fn.fnamemodify(vim.fn.expand(root), ':p'):gsub('/+$', '')
    return dir .. '/' .. root:gsub('[/\\:]', '%%') .. '.json', root
end

--- Load a cached graph for `root`. nil on miss, version skew, or shape
--- doubt — a miss just means a cold extract, never a wrong graph.
function M.load(root)
    if require('cartograph.config').cache == false then return nil end
    local file, nroot = M.path(root)
    local fd = io.open(file, 'r')
    if not fd then return nil end
    local txt = fd:read('a')
    fd:close()
    local ok, wrap = pcall(vim.json.decode, txt)
    if not ok or type(wrap) ~= 'table' or wrap.version ~= M.VERSION then
        return nil
    end
    local data = wrap.data
    if not (type(data) == 'table' and data.root == nroot
        and data.provider == 'treesitter' and data.stamps
        and type(data.nodes) == 'table') then
        return nil
    end
    return data
end

--- Persist a raw graph. Post-pass artifacts (sql:: entities, frontier
--- landings) are stripped — they re-derive; caching them would duplicate
--- on the next attach.
function M.save(data)
    if require('cartograph.config').cache == false then return end
    if not (data and data.provider == 'treesitter' and data.stamps) then
        return
    end
    local synth = {}
    local nodes = {}
    for _, n in ipairs(data.nodes) do
        if n.id:sub(1, 5) == 'sql::' or (n.unparsed and n.kind ~= 'module') then
            synth[n.id] = true
        else
            nodes[#nodes + 1] = n
        end
    end
    local edges = {}
    for _, e in ipairs(data.edges) do
        if not (synth[e.from] or synth[e.to]) then edges[#edges + 1] = e end
    end
    local out = {}
    for k, v in pairs(data) do out[k] = v end
    out.nodes, out.edges = nodes, edges
    local file = M.path(data.root)
    local fd = io.open(file, 'w')
    if not fd then
        return vim.notify('cartograph: cannot write cache ' .. file,
            vim.log.levels.WARN)
    end
    fd:write(vim.json.encode({ version = M.VERSION, data = out }))
    fd:close()
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
    local data = M.load(root)
    if not data then return nil end
    local changed, deleted = M.diff(data)
    if #changed == 0 and #deleted == 0 then
        return data, ('warm open — %d files unchanged'):format(
            vim.tbl_count(data.stamps))
    end
    -- a warm open must never lose to a cold one: the splice re-extracts
    -- changed files SEQUENTIALLY and blocks the UI, while the cold path
    -- is parallel and streams. Past the break-even (≈ total/workers,
    -- since cold divides the whole tree by the worker count), step
    -- aside — the caller's cold path is strictly better UX.
    local cfg = require 'cartograph.config'
    local total = vim.tbl_count(data.stamps)
    -- ...but only when cold would actually BE parallel: on a small or
    -- parallel-disabled project, cold is sequential over the whole tree
    -- and the warm splice always wins
    local would_parallel = cfg.parallel ~= false
        and total >= (cfg.parallel_threshold or 300)
    local limit = cfg.cache_max_diff or math.max(32,
        math.floor(total
            / require('cartograph.parallel').default_workers()))
    if (would_parallel or cfg.cache_max_diff) and #changed > limit then
        return nil, ('%d files changed (warm limit %d) — cold extract'
            .. ' is faster, going parallel'):format(#changed, limit)
    end
    require('cartograph.refresh').splice(data, changed, deleted)
    M.save(data)
    return data, ('warm open — %d re-extracted, %d deleted, rest cached')
        :format(#changed, #deleted)
end

return M
