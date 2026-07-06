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

M.BATCH = 48 -- nominal batch size — still the heuristic for how many workers
             -- to spawn; the actual per-slice size is adaptive (MIN..MAX,
             -- ramped from MIN for fast first paint — see M.extract)
M.MIN_BATCH, M.MAX_BATCH = 8, 96

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
-- buffers), then other loaded buffers. A multi-root corpus (self://,
-- abs given) has no single root to match buffers against, so ordering
-- falls to mtime + name; `abs` resolves the labelled keys for mtime.
local function attention(root, abs)
    local ctx = { bufs = {} }
    local function rel(buf)
        local name = vim.api.nvim_buf_get_name(buf)
        if name ~= '' and name:sub(1, #root + 1) == root .. '/' then
            return name:sub(#root + 2)
        end
    end
    if not abs then
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
    end
    ctx.mtime = function (f)
        local st = vim.uv.fs_stat(abs and abs(f) or (root .. '/' .. f))
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
    -- OO extends pairs (for transitive parent::m resolution in relink):
    -- deduped by defining file, same as the rest of the slice's data
    acc.extends = acc.extends or {}
    for _, x in ipairs(chunk.extends or {}) do
        if not seen[x.file] then acc.extends[#acc.extends + 1] = x end
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
        -- 'reg' edges present at audit are phase-1 argv-upgrade
        -- hypotheses (load-time callback passed as data): slice-local,
        -- so drop them — relink re-derives against the global set, and
        -- the id-pass (phase 2) mints the data-reference registrations
        if e.kind == 'reg' then
            -- dropped
        elseif not (e.kind == 'ref' and kill[e.from .. '\31' .. e.to]) then
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
        { files = { file }, fileset = s.fileset, skip_idpass = true, abs = s.abs })
    merge_chunk(s, chunk)
    s.arrived[file] = true -- even if unreadable: don't retry per descend
    if s.on_chunk then s.on_chunk(s.done, s.total, s.acc) end
    return true
end

--- Parallel extract. o = { workers?, on_chunk(done, total, acc)?,
--- on_note(msg)?, on_done(data) }. Asynchronous: returns immediately,
--- on_done fires on the main loop with the finished graph.
function M.extract(root, o)
    local ts = require 'cartograph.providers.treesitter'
    -- a multi-root corpus (self://loaded) supplies its OWN roster + a
    -- label→dir map; `abs` resolves the labelled keys. A plain directory
    -- root walks itself as before.
    local files, minified, abs
    if o.roots then
        files, minified = o.files, {}
        local roots = o.roots
        abs = function (file)
            local label, rest = file:match('^([^/]+)/(.*)$')
            return (roots[label] or '') .. '/' .. (rest or file)
        end
    else
        root = vim.fn.fnamemodify(vim.fn.expand(root), ':p'):gsub('/+$', '')
        files, minified = ts.list_files(root)
    end
    local nw = math.min(o.workers or M.default_workers(),
        math.max(1, math.ceil(#files / M.BATCH)))
    if nw < 2 then
        o.on_done(ts.extract(root, { files = files, abs = abs }))
        return
    end
    local rtp = worker_rtp()

    -- the queue: priority-ordered files, handed out in ADAPTIVELY-sized slices
    -- (see next_slice/adapt below) — no pre-slicing, so the size can react to
    -- measured worker turnaround.
    local ordered = M.order(files, attention(root, abs))

    local acc = { schema = 1, root = root, provider = o.provider or 'treesitter',
        roots = o.roots,
        capabilities = { calls = true, litdata = true, df = 'lite' },
        nodes = {}, edges = {}, calls = {}, stamps = {}, fn_ranges = {},
        _no_parser = {} }
    local s = { root = root, fileset = files, acc = acc, arrived = {}, abs = abs,
        on_chunk = o.on_chunk, done = 0, total = #ordered, phase = 1 }
    M._session = s

    -- Adaptive coalescing of the streaming re-ingest. Worker chunks merge
    -- cheaply as they arrive (an append); the PROGRESSIVE re-ingest is the
    -- main-loop cost — O(nodes), 100ms+ on a big graph — so instead of running
    -- it on every batch it fires on a timer whose interval tracks its OWN last
    -- measured duration: re-ingest is held to ~a quarter of wall-clock, so the
    -- editor stays responsive. Early (few nodes, cheap) → frequent, smooth
    -- streaming; late (many nodes, dear) → the interval auto-widens. A demand
    -- extract (user descended a queued file) still refreshes immediately.
    local COAL_MIN, COAL_MAX, COAL_FRAC = 40, 500, 0.25
    local ingest_ms, pending, dirty = 0, false, false
    local schedule_progressive
    local function run_progressive()
        if s.phase ~= 1 or not dirty or not o.on_chunk then return end
        dirty = false
        local t0 = vim.uv.hrtime()
        o.on_chunk(s.done, s.total, acc)
        ingest_ms = (vim.uv.hrtime() - t0) / 1e6
    end
    function schedule_progressive()
        if pending or not o.on_chunk then return end
        pending = true
        local interval = math.max(COAL_MIN,
            math.min(COAL_MAX, ingest_ms / COAL_FRAC))
        vim.defer_fn(function ()
            pending = false
            run_progressive()
            if dirty then schedule_progressive() end -- more arrived; keep cadence
        end, math.floor(interval))
    end
    s.schedule = schedule_progressive

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
                roots = o.roots, index_file = idxf, fn_ranges = fr },
                function (chunk, res)
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
                fileset = files, skip_idpass = true, abs = abs }))
        end
        M.audit(acc)
        ts.relink(acc)
        phase2()
    end
    -- Adaptive batch size: start SMALL so the first worker returns quickly
    -- (fast first paint), then grow toward a turnaround sweet spot to amortize
    -- the ~150ms per-process startup, and cap each slice at an even share of
    -- what's left so no lane idles while another chews a big tail batch.
    local cursor, inflight, cur = 1, 0, M.MIN_BATCH
    local function next_slice()
        if cursor > #ordered then return nil end
        local remaining = #ordered - cursor + 1
        local cap = math.max(1, math.ceil(remaining / nw)) -- keep every lane fed
        local n = math.min(cur, cap, remaining)
        local b = {}
        for j = cursor, cursor + n - 1 do b[#b + 1] = ordered[j] end
        cursor = cursor + n
        return b
    end
    local function adapt(dt_ms)
        -- keep worker turnaround in a responsive throughput window: too fast =>
        -- startup dominated the slice, grow; too slow => coarse, shrink
        if dt_ms < 250 then cur = math.min(M.MAX_BATCH, cur * 2)
        elseif dt_ms > 600 then cur = math.max(M.MIN_BATCH, math.floor(cur / 2)) end
    end
    -- work-pulling: each lane takes the next adaptive slice when it finishes
    -- (priority order preserved; demand dedups on arrival)
    local function pull()
        local b = next_slice()
        if not b then return false end
        inflight = inflight + 1
        local t0 = vim.uv.hrtime()
        spawn({ phase = 'parse', root = root, files = b,
            fileset = files, rtp = rtp, roots = o.roots }, function (chunk, res)
            inflight = inflight - 1
            if chunk then
                merge_chunk(s, chunk)
            else
                failed[#failed + 1] = b
                if o.on_note then
                    o.on_note(('batch failed (exit %d) — re-extracting %d '
                        .. 'files in-process'):format(res.code, #b))
                end
            end
            s.done = s.done + #b
            adapt((vim.uv.hrtime() - t0) / 1e6)
            dirty = true
            schedule_progressive() -- coalesced; not a re-ingest per batch
            -- keep this lane busy; phase 1 ends when the queue is drained
            -- and nothing is still in flight
            if not pull() and cursor > #ordered and inflight == 0 then
                finish_phase1()
            end
        end)
        return true
    end
    for _ = 1, nw do if not pull() then break end end
end

return M
