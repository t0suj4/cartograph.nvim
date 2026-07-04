-- Parallel extraction: N worker processes parse file slices while the
-- editor stays responsive and the browser fills in as chunks arrive.
-- Semantics are IDENTICAL to sequential extraction, by construction:
--
--   phase 1 (parallel) — workers parse slices with the id pass skipped;
--   audit (parent)     — every cross-file HYPOTHESIS a worker made
--                        (name-matched, indirect-literal, traced) is
--                        nulled: unique-in-slice is not unique-globally;
--   relink (parent)    — the global resolver re-derives those links
--                        against the full node set, full-fidelity ranges;
--   phase 2 (parallel) — workers run the id pass (use edges, dispatch
--                        refs, cbarg marks) against PARENT-built global
--                        indexes.
--
-- Same-file resolutions are never touched — a file lives in exactly one
-- slice, so file-scope decisions are already global truth.

local M = {}

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

-- greedy size balance: biggest file to the lightest bucket
local function slice(root, files, n)
    local sized = {}
    for _, f in ipairs(files) do
        local st = vim.uv.fs_stat(root .. '/' .. f)
        sized[#sized + 1] = { f = f, s = st and st.size or 0 }
    end
    table.sort(sized, function (a, b)
        if a.s ~= b.s then return a.s > b.s end
        return a.f < b.f
    end)
    local buckets, weights = {}, {}
    for i = 1, n do buckets[i], weights[i] = {}, 0 end
    for _, e in ipairs(sized) do
        local best = 1
        for i = 2, n do if weights[i] < weights[best] then best = i end end
        table.insert(buckets[best], e.f)
        weights[best] = weights[best] + e.s
    end
    return buckets
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
                local cfd = io.open(job.out, 'r')
                if cfd then
                    local ok, d = pcall(vim.json.decode, cfd:read('a'))
                    cfd:close()
                    if ok then chunk = d end
                end
            end
            vim.fn.delete(jf)
            vim.fn.delete(job.out)
            cb(chunk, res)
        end)
    end)
end

-- fold a phase-1 chunk into the accumulator (disjoint by construction:
-- one file lives in exactly one slice)
local function merge(acc, chunk)
    for _, n in ipairs(chunk.nodes or {}) do acc.nodes[#acc.nodes + 1] = n end
    for _, e in ipairs(chunk.edges or {}) do acc.edges[#acc.edges + 1] = e end
    for _, c in ipairs(chunk.calls or {}) do acc.calls[#acc.calls + 1] = c end
    for f, s in pairs(chunk.stamps or {}) do acc.stamps[f] = s end
    for f, r in pairs(chunk.fn_ranges or {}) do acc.fn_ranges[f] = r end
    for _, l in ipairs(chunk.no_parser or {}) do acc._no_parser[l] = true end
end

--- Null every cross-file hypothesis a slice made: the resolution that
--- justified it saw only the slice's names. Same-file links stay; relink
--- re-derives the rest against the global node set. Pure; exposed for
--- the equivalence test.
function M.audit(data)
    local byid = {}
    for _, n in ipairs(data.nodes) do byid[n.id] = n end
    local kill, dropped = {}, 0
    for _, c in ipairs(data.calls or {}) do
        if c.to then
            local t = byid[c.to]
            if t and t.file ~= c.file
                and (c.inferred or c.indirect or c.traced) then
                if c.fn then kill[c.fn .. '\31' .. c.to] = true end
                c.to = nil
                c.inferred = nil
                dropped = dropped + 1
            end
        end
        for _, a in ipairs(c.argv or {}) do
            if a.k == 'func' and a.to then
                local t = byid[a.to]
                if t and t.file ~= c.file then
                    a.k, a.to = 'local', nil -- relink re-upgrades globally
                end
            end
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

--- Parallel extract. o = { workers?, on_chunk(done, total, acc)?,
--- on_note(msg)?, on_done(data) }. Asynchronous: returns immediately,
--- on_done fires on the main loop with the finished graph.
function M.extract(root, o)
    root = vim.fn.fnamemodify(vim.fn.expand(root), ':p'):gsub('/+$', '')
    local ts = require 'cartograph.providers.treesitter'
    local files, minified = ts.list_files(root)
    local nw = math.min(o.workers or M.default_workers(),
        math.max(1, math.floor(#files / 25)))
    if nw < 2 then
        o.on_done(ts.extract(root))
        return
    end
    local rtp = worker_rtp()
    local buckets = slice(root, files, nw)
    local acc = { schema = 1, root = root, provider = 'treesitter',
        capabilities = { calls = true, litdata = true, df = 'lite' },
        nodes = {}, edges = {}, calls = {}, stamps = {}, fn_ranges = {},
        _no_parser = {} }

    local function finalize()
        -- minified bundles: workers never see them (they are not in any
        -- slice) — the parent owns the frontier modules
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
        o.on_done(acc)
    end

    local function phase2()
        local count = {}
        for _, n in ipairs(acc.nodes) do
            if n.kind == 'function' or n.kind == 'method' then
                count[n.name] = (count[n.name] or 0) + 1
            end
        end
        local fn_unique, var_named = {}, {}
        for _, n in ipairs(acc.nodes) do
            if (n.kind == 'function' or n.kind == 'method')
                and count[n.name] == 1 then
                fn_unique[n.name] = { id = n.id, file = n.file,
                    line = n.range.start.line }
            elseif n.kind == 'var' then
                var_named[n.name] = var_named[n.name] or {}
                table.insert(var_named[n.name],
                    { id = n.id, file = n.file, line = n.range.start.line })
            end
        end
        local idxf = vim.fn.tempname() .. '.index.json'
        local fd = assert(io.open(idxf, 'w'))
        fd:write(vim.json.encode({ fn_unique = fn_unique, var_named = var_named }))
        fd:close()

        local byid = {}
        for _, n in ipairs(acc.nodes) do byid[n.id] = n end
        local refEdge = {}
        for _, e in ipairs(acc.edges) do
            if e.kind == 'ref' then refEdge[e.from .. '\31' .. e.to] = e end
        end
        local done = 0
        for _, b in ipairs(buckets) do
            local fr = {}
            for _, f in ipairs(b) do fr[f] = acc.fn_ranges[f] end
            spawn({ phase = 'ids', root = root, files = b, rtp = rtp,
                index_file = idxf, fn_ranges = fr }, function (chunk, res)
                done = done + 1
                if chunk then
                    for _, e in ipairs(chunk.edges or {}) do
                        local k = e.kind == 'ref' and (e.from .. '\31' .. e.to)
                        local ex = k and refEdge[k]
                        if ex then -- fold into the existing pair, like addref
                            for _, at in ipairs(e.at or {}) do
                                ex.at[#ex.at + 1] = at
                            end
                            if not e.inferred then ex.inferred = nil end
                        else
                            if k then refEdge[k] = e end
                            acc.edges[#acc.edges + 1] = e
                        end
                    end
                    for _, id in ipairs(chunk.cbarg or {}) do
                        if byid[id] then byid[id].cbarg = true end
                    end
                elseif o.on_note then
                    o.on_note(('id-pass slice failed (%d) — use edges for '
                        .. '%d files missing; :CartographRefresh! rebuilds')
                        :format(res.code, #b))
                end
                if done == #buckets then
                    vim.fn.delete(idxf)
                    finalize()
                end
            end)
        end
    end

    local done, failed = 0, {}
    for _, b in ipairs(buckets) do
        spawn({ phase = 'parse', root = root, files = b, fileset = files,
            rtp = rtp }, function (chunk, res)
            done = done + 1
            if chunk then
                merge(acc, chunk)
            else
                failed[#failed + 1] = b
                if o.on_note then
                    o.on_note(('slice failed (exit %d) — re-extracting %d '
                        .. 'files in-process'):format(res.code, #b))
                end
            end
            if o.on_chunk then o.on_chunk(done, #buckets, acc) end
            if done == #buckets then
                for _, fb in ipairs(failed) do -- sequential fallback, honest
                    merge(acc, ts.extract(root, { subdirs = fb,
                        fileset = files, skip_idpass = true }))
                end
                M.audit(acc)
                ts.relink(acc)
                phase2()
            end
        end)
    end
end

return M
