-- The dogfood dashboard: cartograph on cartograph. Unit-level, we just confirm
-- the report wires census + serving + lint over a store without crashing and
-- returns the three sections + a seam count (the real self-run is
-- tools/dogfood.lua, which extracts our own tree from disk).

local store = require 'cartograph.store'
local dogfood = require 'cartograph.dogfood'

local R = { start = { line = 0, char = 0 }, ['end'] = { line = 0, char = 0 } }
local DATA = {
    root = '/x',
    nodes = {
        { id = 'm.lua', name = 'm.lua', kind = 'module', file = 'm.lua', range = R, order = 0 },
        { id = 'm.lua::a', name = 'a', kind = 'function', file = 'm.lua', range = R, order = 0 },
        { id = 'm.lua::b', name = 'b', kind = 'function', file = 'm.lua', range = R, order = 1 },
    },
    edges = { { from = 'm.lua::a', to = 'm.lua::b', kind = 'ref', at = { R } } },
    calls = { { fn = 'm.lua::a', callee = 'b', file = 'm.lua', line = 0, to = 'm.lua::b', at = R } },
}

test('dogfood: run() reports the three sections + a seam count, non-destructively', function ()
    store.ingest(DATA)
    require('cartograph.config').seams = nil -- a clean user config
    local lines, counts = dogfood.run(store)
    local text = table.concat(lines, '\n')
    ok(text:find('RESOLUTION'), 'has the resolution section')
    ok(text:find('SERVING'), 'has the serving section')
    ok(text:find('seam%-guard %(Band%)'), 'has the seam-guard line')
    eq(0, counts.seam, 'no seam breach on an in-memory graph (no files on disk)')
    eq(nil, require('cartograph.config').seams, 'config.seams restored (non-destructive)')
end)

test('dogfood: metrics() is the numeric record (the ratchet\'s fuel)', function ()
    store.ingest(DATA)
    require('cartograph.config').seams = nil
    local m = dogfood.metrics(store)
    eq(3, m.nodes); eq(1, m.calls)
    eq(100, m.resolved_pct) -- the one call resolves
    eq(0, m.seam)
    ok(type(m.serving_pct) == 'number', 'serving is a number')
    ok(m.by_prov ~= nil and m.lint ~= nil, 'by_prov + lint breakdown present')
end)

test('dogfood: the BAND_SEAM guards the wide index tables, not the whole-map form', function ()
    local pats = {}
    for _, p in ipairs(dogfood.BAND_SEAM.patterns) do pats[p] = true end
    ok(pats['store%.uses%['], 'per-node uses[ is guarded')
    ok(pats['store%.edge_tier%['], 'the new edge_tier index is guarded')
    ok(not pats['store%.uses'], 'the bare whole-map form is NOT guarded (scc/cone pass it)')
    ok(not pats['store%.edge_inferred%['], 'edge_inferred excluded (a deferred reader owns it)')
end)
