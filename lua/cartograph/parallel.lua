-- Parallel extraction: worker processes parse file batches pulled from a
-- PRIORITY queue while the editor stays responsive and the browser fills
-- in as chunks arrive. The queue serves the user's attention, not the
-- filesystem's order: open buffers first (current buffer at the head),
-- then most-recently-modified, then the rest — and descending into a
-- file still in the queue extracts it in-process RIGHT NOW (demand),
-- with arrival-dedup so its queued copy is skipped.
--
-- Semantics are IDENTICAL to sequential extraction, by construction:
--
--   phase 1 (parallel) — workers parse batches with the id pass skipped;
--   audit (parent)     — every cross-file HYPOTHESIS a worker made
--                        (name-matched, indirect-literal, traced) is
--                        nulled: unique-in-batch is not unique-globally;
--   relink (parent)    — the global resolver re-derives those links
--                        against the full node set, full-fidelity ranges;
--   phase 2 (parallel) — workers run the id pass (use edges, dispatch
--                        refs, cbarg marks) against PARENT-built global
--                        indexes.
--
-- Same-file resolutions are never touched — a file lives in exactly one
-- batch, so file-scope decisions are already global truth.

local M = {}

M.BATCH = 48 -- files per worker batch: small enough to reorder, big
             -- enough to amortize process startup

local function plugin_root()
    local src = debug.getinfo(1, 'S').source:sub(2)
    return vim.fn.fnamemodify(src, ':h:h:h')
end

local function worker_rtp()
    local out = { plugin_root() }
    for _, p in ipairs(vim.api.nvim_list_runtime_paths()) do
        if p:find('nvim%-treesitter') then out[#out + 1] = p end
    end
    return out
end

function M.default_workers()
    local n = (vim.uv.available_parallelism and vim.uv.available_parallelism()) or 4
    return math.max(2, math.min(8, n - 1))
end

--- Pure priority order: current buffer first, then other open buffers
--- (in ctx order), then by modification time, newest first. ctx =
--- { current?, bufs = {rel,...}, mtime = fn(rel) -> secs }.
function M.order(files, ctx)
    local bufpos = {}
    for i, b in ipairs(ctx.bufs or {}) do
        if not bufpos[b] then bufpos[b] = i end
    end
    local mt = {}
    for _, f in ipairs(files) do
        mt[f] = ctx.mtime and ctx.mtime(f) or 0
    end
    local sorted = {}
    for _, f in ipairs(files) do sorted[#sorted + 1] = f end
    table.sort(sorted, function (a, b)
        local ca, cb = a == ctx.current, b == ctx.current
        if ca ~= cb then return ca end
        local ba, bb = bufpos[a], bufpos[b]
        if (ba ~= nil) ~= (bb ~= nil) then return ba ~= nil end
        if ba and bb and ba ~= bb then return ba < bb end
        if mt[a] ~= mt[b] then return mt[a] > mt[b] end
        return a < b
    end)
    return sorted
end

-- the editor's actual attention, for M.order: current buffer, then the
-- persisted WORKING SET (declared intent outranks incidentally-open
-- buffers), then other loaded buffers
local function attention(root)
    local ctx = { bufs = {} }
    local function rel(buf)
        local name = vim.api.nvim_buf_get_name(buf)
        if name ~= '' and name:sub(1, #root + 1) == root .. '/' then
            return name:sub(#root + 2)
        end
    end
    ctx.current = rel(vim.api.nvim_get_current_buf())
    for _, f in ipairs(require('cartograph.store').ws_peek(root)) do
        ctx.bufs[#ctx.bufs + 1] = f
    end
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(b) then
            local r = rel(b)
            if r then ctx.bufs[#ctx.bufs + 1] = r end
        end
    end
    ctx.mtime = function (f)
        local st = vim.uv.fs_stat(root .. '/' .. f)
        return st and st.mtime.sec or 0
    end
    return ctx
end

local function spawn(job, cb)
    local jf = vim.fn.tempname() .. '.job.json'
    job.out = vim.fn.tempname() .. '.chunk.json'
    local fd = assert(io.open(jf, 'w'))
    fd:write(vim.json.encode(job))
    fd:close()
    local worker = plugin_root() .. '/lua/cartograph/worker.lua'
    vim.system({ vim.v.progpath, '-u', 'NONE', '-i', 'NONE', '--headless',
        '-l', worker, jf }, {}, function (res)
        vim.schedule(function ()
            local chunk
            if res.code == 0 then
                local cfd = io.open(job.out, 'rb')
                if cfd then
                    chunk = require('cartograph.cache').decode(cfd:read('a'))
                    cfd:close()
                end
            end
            vim.fn.delete(jf)
            vim.fn.delete(job.out)
            cb(chunk, res)
        end)
    end)
end

-- id of an edge endpoint -> its file (ids embed the file as the prefix)
local function file_of(id)
    return id:match('^(.-)::') or id
end

-- fold a phase-1 chunk into the session, skipping files that already
-- arrived (a demanded file's queued copy lands later and must not
-- duplicate); marks the chunk's files as arrived
local function merge_chunk(s, chunk)
    local acc, seen = s.acc, s.arrived
    for _, n in ipairs(chunk.nodes or {}) do
        if not seen[n.file] then acc.nodes[#acc.nodes + 1] = n end
    end
    for _, e in ipairs(chunk.edges or {}) do
        if not seen[file_of(e.from)] then acc.edges[#acc.edges + 1] = e end
    end
    for _, c in ipairs(chunk.calls or {}) do
        if not seen[c.file] then acc.calls[#acc.calls + 1] = c end
    end
    local new = {}
    for f, v in pairs(chunk.stamps or {}) do
        if not seen[f] then acc.stamps[f] = v end
        new[f] = true
    end
    for f, r in pairs(chunk.fn_ranges or {}) do
        if not seen[f] then acc.fn_ranges[f] = r end
        new[f] = true
    end
    for _, l in ipairs(chunk.no_parser or {}) do acc._no_parser[l] = true end
    for f in pairs(new) do seen[f] = true end
end

--- Null every cross-file hypothesis a batch made: the resolution that
--- justified it saw only the batch's names. Same-file links stay; relink
--- re-derives the rest against the global node set. Pure; exposed for
--- the equivalence test.
function M.audit(data)
    local kill, dropped = {}, 0
    for _, c in ipairs(data.calls or {}) do
        -- ANY resolution that leaned on uniqueness (name-match inferred,
        -- indirect literal, traced literal) is a batch-scoped hypothesis —
        -- even a SAME-FILE one, because the tail fallback and the
        -- unique-candidate branch count candidates globally. Null them
        -- all; relink re-derives with global indexes. The only survivors
        -- are same-file PRIORITY hits (plain calls, inferred=false):
        -- those decisions never looked past their own file.
        if c.to and (c.inferred or c.indirect or type(c.traced) == 'string') then
            if c.fn then kill[c.fn .. '\31' .. c.to] = true end
            c.to = nil
            c.inferred = nil
            dropped = dropped + 1
        end
        for _, a in ipairs(c.argv or {}) do
            if a.up then -- a resolution-pass upgrade: relink re-derives it,
                -- and the edge the upgrade added dies with it
                if c.fn and a.to then kill[c.fn .. '\31' .. a.to] = true end
                a.k, a.to, a.up = 'local', nil, nil
            end
        end
    end
    -- a killed (from, to) pair may also carry occurrences of NON-audited
    -- calls (a plain call to the same target): reopen those too, so
    -- relink rebuilds the pair's edge with every occurrence
    for _, c in ipairs(data.calls or {}) do
        if c.to and c.fn and kill[c.fn .. '\31' .. c.to] then
            c.to = nil
        end
    end
    local edges = {}
    for _, e in ipairs(data.edges) do
        if not (e.kind == 'ref' and kill[e.from .. '\31' .. e.to]) then
            edges[#edges + 1] = e
        end
    end
    data.edges = edges
    return dropped
end

--- The user descended into a file still in the queue: extract it NOW,
--- in-process, and merge. Its queued copy dedups on arrival. Returns
--- true if this call did the work.
function M.demand(file)
    local s = M._session
    if not (s and s.phase == 1) or s.arrived[file] then return false end
    local ts = require 'cartograph.providers.treesitter'
    local chunk = ts.extract(s.root,
        { files = { file }, fileset = s.fileset, skip_idpass = true })
    merge_chunk(s, chunk)
    s.arrived[file] = true -- even if unreadable: don't retry per descend
    if s.on_chunk then s.on_chunk(s.done, s.total, s.acc) end
    return true
end

--- Parallel extract. o = { workers?, on_chunk(done, total, acc)?,
--- on_note(msg)?, on_done(data) }. Asynchronous: returns immediately,
--- on_done fires on the main loop with the finished graph.
function M.extract(root, o)
    root = vim.fn.fnamemodify(vim.fn.expand(root), ':p'):gsub('/+$', '')
    local ts = require 'cartograph.providers.treesitter'
    local files, minified = ts.list_files(root)
    local nw = math.min(o.workers or M.default_workers(),
        math.max(1, math.ceil(#files / M.BATCH)))
    if nw < 2 then
        o.on_done(ts.extract(root))
        return
    end
    local rtp = worker_rtp()

    -- the queue: priority-ordered files in small batches
    local ordered = M.order(files, attention(root))
    local batches = {}
    for i = 1, #ordered, M.BATCH do
        local b = {}
        for j = i, math.min(i + M.BATCH - 1, #ordered) do
            b[#b + 1] = ordered[j]
        end
        batches[#batches + 1] = b
    end

    local acc = { schema = 1, root = root, provider = 'treesitter',
        capabilities = { calls = true, litdata = true, df = 'lite' },
        nodes = {}, edges = {}, calls = {}, stamps = {}, fn_ranges = {},
        _no_parser = {} }
    local s = { root = root, fileset = files, acc = acc, arrived = {},
        on_chunk = o.on_chunk, done = 0, total = #batches, phase = 1,
        next = 1 }
    M._session = s

    local function finalize()
        local okc, cfg = pcall(require, 'cartograph.config')
        if #minified > 0 and not (okc and cfg.unparsed == false) then
            acc.unparsed = minified
            for _, f in ipairs(minified) do
                acc.nodes[#acc.nodes + 1] = { id = f, name = f, kind = 'module',
                    file = f, unparsed = true, order = -1,
                    range = { start = { line = 0, char = 0 },
                        ['end'] = { line = 0, char = 0 } } }
            end
        end
        acc.no_parser = next(acc._no_parser) and vim.tbl_keys(acc._no_parser) or nil
        acc._no_parser = nil
        acc.fn_ranges = nil
        M._session = nil
        o.on_done(acc)
    end

    local function phase2()
        s.phase = 2
        local L = ts.lookups(acc.nodes, root)
        local idxf = vim.fn.tempname() .. '.index.bin'
        local fd = assert(io.open(idxf, 'wb'))
        fd:write(require('cartograph.cache').encode(L))
        fd:close()

        -- fn_ranges are consumed here, split evenly across the id-pass
        -- workers (batching no longer matters: all decisions are global)
        local groups = {}
        for i = 1, nw do groups[i] = {} end
        for i, f in ipairs(files) do
            table.insert(groups[(i % nw) + 1], f)
        end
        local done = 0
        for _, g in ipairs(groups) do
            local fr = {}
            for _, f in ipairs(g) do fr[f] = acc.fn_ranges[f] end
            spawn({ phase = 'ids', root = root, files = g, rtp = rtp,
                index_file = idxf, fn_ranges = fr }, function (chunk, res)
                done = done + 1
                if chunk then
                    ts.merge_idpass(acc, chunk)
                elseif o.on_note then
                    o.on_note(('id-pass group failed (%d) — use edges for '
                        .. '%d files missing; :CartographRefresh! rebuilds')
                        :format(res.code, #g))
                end
                if done == #groups then
                    vim.fn.delete(idxf)
                    finalize()
                end
            end)
        end
    end

    local failed = {}
    local function finish_phase1()
        for _, fb in ipairs(failed) do -- sequential fallback, honest
            merge_chunk(s, ts.extract(root, { files = fb,
                fileset = files, skip_idpass = true }))
        end
        M.audit(acc)
        ts.relink(acc)
        phase2()
    end
    -- work-pulling: each worker takes the next batch off the queue when
    -- it finishes (priority order preserved; demand dedups on arrival)
    local function pull()
        local i = s.next
        if i > #batches then return false end
        s.next = i + 1
        spawn({ phase = 'parse', root = root, files = batches[i],
            fileset = files, rtp = rtp }, function (chunk, res)
            if chunk then
                merge_chunk(s, chunk)
            else
                failed[#failed + 1] = batches[i]
                if o.on_note then
                    o.on_note(('batch failed (exit %d) — re-extracting %d '
                        .. 'files in-process'):format(res.code, #batches[i]))
                end
            end
            s.done = s.done + 1
            if o.on_chunk then o.on_chunk(s.done, s.total, acc) end
            if not pull() and s.done == s.total then
                finish_phase1()
            end
        end)
        return true
    end
    for _ = 1, math.min(nw, #batches) do pull() end
end

return M
