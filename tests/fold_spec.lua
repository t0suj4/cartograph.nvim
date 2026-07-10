-- The fold: wide data -> one typed-edge triple table + by-subject/by-object
-- indexes. Pure over the neutral schema (no parser), so it always runs.
-- Parity is checked against the store's own forward/backward indexes on the
-- same data — the fold must be indistinguishable from the wide topology.

local fold = require 'cartograph.fold'
local store = require 'cartograph.store'

local R = { start = { line = 0, char = 0 }, ['end'] = { line = 0, char = 0 } }
local function node(id, kind)
    return { id = id, name = id, kind = kind or 'function',
        file = 'm.lua', range = R, order = 0 }
end

-- a graph exercising all four edge kinds + a refused frontier + a self-ref
local DATA = {
    nodes = {
        node('m.lua', 'module'), node('a'), node('b'), node('c'),
        node('v', 'var'), node('iso'),
    },
    edges = {
        { from = 'a', to = 'b', kind = 'ref', at = { R } },
        { from = 'a', to = 'c', kind = 'ref', at = { R } },
        { from = 'b', to = 'c', kind = 'ref', at = { R } },
        { from = 'c', to = 'c', kind = 'ref', at = { R } },   -- self (recursion)
        { from = 'a', to = 'v', kind = 'use', at = { R } },
        { from = 'm.lua', to = 'b', kind = 'reg', at = { R } },
        { from = 'm.lua', to = 'other.lua', kind = 'import' },
    },
    calls = {
        { callee = 'b', fn = 'a', to = 'b', file = 'm.lua', line = 1 },
        { callee = 'mystery', fn = 'a', file = 'm.lua', line = 2,
            refused = { rule = 'ambiguous' } },
        { callee = 'toplevel_mystery', file = 'm.lua', line = 3,
            refused = { rule = 'blocked' } }, -- no fn: counted, not folded
    },
}

test('fold: forward and backward parity with the store, all predicates', function ()
    store.ingest({ nodes = DATA.nodes, edges = DATA.edges, calls = DATA.calls,
        root = '/x' })
    local f = fold.build(DATA)
    local function names(ids)
        local t = {}
        for _, i in ipairs(ids) do t[#t + 1] = f.names[i + 1] end
        table.sort(t)
        return t
    end
    -- graph VIEW: no_self, matching the store's uses/usedby policy
    local function fwd(id, pred)
        return names(f:out(f.it.get(id), fold.PRED[pred], true))
    end
    local function bwd(id, pred)
        return names(f:incoming(f.it.get(id), fold.PRED[pred], true))
    end
    -- the self-loop IS a stored fact (raw slice keeps it)...
    eq({ 'a', 'b', 'c' }, names(f:incoming(f.it.get('c'), fold.PRED.ref)))
    -- ...but the graph view excludes it, as the store does
    eq({ 'b', 'c' }, fwd('a', 'ref'))
    eq({ 'a', 'b' }, bwd('c', 'ref'))         -- callers of c (self excluded)
    eq({ 'v' }, fwd('a', 'use'))
    eq({ 'a' }, bwd('v', 'use'))              -- used-by, free reverse
    eq({ 'b' }, fwd('m.lua', 'reg'))
    eq({ 'm.lua' }, bwd('b', 'reg'))
    eq({ 'other.lua' }, fwd('m.lua', 'import'))
    -- and it agrees with the store, computed independently
    local function storelist(t, key)
        local out = {}
        for _, x in ipairs(t or {}) do
            out[#out + 1] = type(x) == 'table' and (x.to or x.from) or x
        end
        table.sort(out)
        return out
    end
    eq(storelist(store.uses['a']), fwd('a', 'ref'))
    eq(storelist(store.usedby['c']), bwd('c', 'ref'))
    eq(storelist(store.var_usedby['v'], 'from'), bwd('v', 'use'))
    eq(storelist(store.registers['m.lua']), fwd('m.lua', 'reg'))
    eq(storelist(store.imports_out['m.lua']), fwd('m.lua', 'import'))
end)

test('fold: refused calls fold as frontier facts; top-level ones counted', function ()
    local f = fold.build(DATA)
    -- a's frontier: one refused call (mystery); points at the sentinel
    local fr = f:out(f.it.get('a'), fold.PRED.refused)
    eq(1, #fr)
    eq(f.sentinel, fr[1])
    eq(1, f.skipped_refused, 'the fn-less top-level refusal is counted, not folded')
    -- every fact is edges (7) + folded refused (1) = 8
    eq(8, f.m)
end)

test('fold: isolated nodes interned; size is columnar-small', function ()
    local f = fold.build(DATA)
    ok(f.it.get('iso'), 'isolated node exists in the id space')
    eq(0, #f:out(f.it.get('iso')), 'and has no facts')
    -- core = 3 columns + 2 offset arrays + 1 permutation, all u32
    eq(f.m * 4 * 3 + (f.n + 1) * 4 * 2 + f.m * 4, f:bytes())
end)
