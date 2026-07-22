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
-- one of the two representations, and return the sorted product multisets.
local function run(use_cols)
    local data = bench.extract(name) -- fresh, deterministic; inline-resolved
    local view
    if use_cols then
        view = rescols.view(data.calls)
        data.calls = view.rows
    end
    parallel.audit(data)
    ts.relink(data)
    -- materialize the columnar calls back to plain records for a like-for-like read
    local calls = data.calls
    if use_cols then
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

local rec = run(false)
local col = run(true)

print(('rescolgate %s — records %d calls / %d edges · columns %d calls / %d edges')
    :format(name, #rec.calls, #rec.edges, #col.calls, #col.edges))

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
cmp(rec.calls, col.calls, 'call product')
cmp(rec.edges, col.edges, 'ref/reg edge')

if #fails > 0 then
    print('FAIL:')
    for _, f in ipairs(fails) do print('  - ' .. f) end
    vim.cmd('cquit 1')
else
    print('OK — resolution (audit + relink) is behaviour-identical on records vs the columnar store')
    vim.cmd('qall!')
end
