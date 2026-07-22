-- rescolgate — the RESOLUTION-ON-COLUMNS parity gate (record-fold arc, the
-- gitlab-peak lever). rescols.lua is the in-resolution columnar call store; this
-- proves it is a behaviour-faithful drop-in for raw call records THROUGH the
-- resolution pipeline (M.audit + M.relink + all resolve passes). It is the
-- resolution-phase analog of callgate/callcolslive: extract a corpus twice, run
-- the SAME pipeline once over raw records and once over the columnar proxy, and
-- assert the resolution PRODUCTS (per-call to/inferred/full/prov/refused/… + the
-- argv upgrades + the ref/reg edges) are identical. The immutable-column assert
-- inside rescols is the loud mid-run net: a mis-partitioned field (a resolution
-- write the schema calls immutable) crashes here, not silently.
--
--   nvim --headless -u NONE -l tools/rescolgate.lua <corpus>
-- Exit 1 on any divergence, 2 if not applicable.

local here = debug.getinfo(1, 'S').source:sub(2):match('^(.*)/rescolgate%.lua$')
local bench = dofile(here .. '/bench.lua')
bench.bootstrap()
local rescols = require 'cartograph.rescols'
local parallel = require 'cartograph.parallel'
local ts = require 'cartograph.providers.treesitter'

local name = arg and arg[1]
if not name then print('usage: rescolgate <corpus>'); os.exit(2) end
local ok = pcall(bench.corpus, name)
if not ok then print('unknown corpus: ' .. name); os.exit(2) end

-- one call's resolution product as a canonical tuple: the fields resolution
-- reads/writes, plus the argv upgrade (k/name/v/to/up per element). c is a plain
-- materialized record on both sides, so reads are identical by construction.
local function call_tuple(c)
    local av = {}
    for _, a in ipairs(c.argv or {}) do
        av[#av + 1] = table.concat({ tostring(a.k), tostring(a.name), tostring(a.v),
            tostring(a.to), a.up and 'u' or '-' }, ':')
    end
    return table.concat({
        tostring(c.fn), tostring(c.callee), tostring(c.to), c.inferred and 'i' or '-',
        tostring(c.full), tostring(c.prov), tostring(c.stdpath),
        c.tinf and 't' or '-', c.rtfull and 'r' or '-', c.dynamic and 'd' or '-',
        c.refused and tostring(c.refused.rule) or '-', tostring(c.ext),
        tostring(c.registry), '[' .. table.concat(av, ',') .. ']',
    }, '|')
end

local function edge_tuple(e)
    local ats = {}
    for _, a in ipairs(e.at or {}) do
        ats[#ats + 1] = (a.start and a.start.line or 0) .. '.' .. (a.start and a.start.char or 0)
            .. '-' .. (a['end'] and a['end'].line or 0) .. '.' .. (a['end'] and a['end'].char or 0)
    end
    table.sort(ats)
    return table.concat({ tostring(e.from), tostring(e.to), tostring(e.kind),
        e.inferred and 'i' or '-', e.tinf and 't' or '-', e.self and 's' or '-',
        table.concat(ats, ';') }, '|')
end

-- run the parent's resolution tail (audit -> relink) over a fresh extract, in
-- one of three representations, and return the sorted product multisets:
--   'rec'    raw records (the default path)
--   'proxy'  audit + relink over rescols proxy rows (the compat shim)
--   'index'  audit INDEX-FORM over the columnar store (data._callstore, no
--            proxies — the peak path), then materialize + relink as usual
--   'relink' audit AND relink (base loop + the 13 resolve passes + mint) all
--            INDEX-FORM — the store stays set through the WHOLE resolution tail,
--            no records materialized until the final read (the full peak path)
local function run(mode)
    local data = bench.extract(name) -- fresh, deterministic; inline-resolved
    local view
    if mode == 'proxy' then
        view = rescols.view(data.calls)
        data.calls = view.rows
        parallel.audit(data)
    elseif mode == 'index' then
        view = rescols.view(data.calls)
        data._callstore = view -- audit reads/writes the columns index-form
        parallel.audit(data)
        local recs = {} -- materialize back for the (records) relink
        for i = 1, #view.rows do recs[i] = rescols.record(view, i) end
        data.calls, data._callstore = recs, nil
        view = nil
    elseif mode == 'relink' then
        view = rescols.view(data.calls)
        data._callstore = view -- STAYS set through relink → fully index-form
        data.calls = view.rows -- safety net for any not-yet-converted record reader
        parallel.audit(data)
    else
        parallel.audit(data)
    end
    ts.relink(data)
    local calls = data.calls
    if view then -- proxy mode: materialize the columnar calls for a like-for-like read
        local recs = {}
        for i = 1, #view.rows do recs[i] = rescols.record(view, i) end
        calls = recs
    end
    local ct, et = {}, {}
    for i = 1, #calls do ct[i] = call_tuple(calls[i]) end
    for _, e in ipairs(data.edges or {}) do et[#et + 1] = edge_tuple(e) end
    table.sort(ct); table.sort(et)
    return { calls = ct, edges = et }
end

local rec = run('rec')
local col = run('proxy')
local idx = run('index')
local rlk = run('relink')

print(('rescolgate %s — records %d calls / %d edges · proxy %d/%d · index-audit %d/%d · index-relink %d/%d')
    :format(name, #rec.calls, #rec.edges, #col.calls, #col.edges,
        #idx.calls, #idx.edges, #rlk.calls, #rlk.edges))

local fails = {}
local function cmp(a, b, what)
    if #a ~= #b then
        fails[#fails + 1] = ('%s count moved %d -> %d'):format(what, #a, #b)
        return
    end
    for i = 1, #a do
        if a[i] ~= b[i] then
            fails[#fails + 1] = ('%s diverged at #%d:\n      records: %s\n      columns: %s')
                :format(what, i, a[i], b[i])
            return
        end
    end
end
cmp(rec.calls, col.calls, 'proxy call product')
cmp(rec.edges, col.edges, 'proxy ref/reg edge')
cmp(rec.calls, idx.calls, 'index-audit call product')
cmp(rec.edges, idx.edges, 'index-audit ref/reg edge')
cmp(rec.calls, rlk.calls, 'index-relink call product')
cmp(rec.edges, rlk.edges, 'index-relink ref/reg edge')

if #fails > 0 then
    print('FAIL:')
    for _, f in ipairs(fails) do print('  - ' .. f) end
    vim.cmd('cquit 1')
else
    print('OK — resolution (audit + relink) is behaviour-identical on records vs the columnar store')
    vim.cmd('qall!')
end
