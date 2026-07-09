-- tools/snapshot: the faithfulness invariant — a slim snapshot must be
-- indistinguishable FROM THE INSTRUMENTS' POINT OF VIEW: graphdiff of the
-- original vs a save/load round-trip is empty, and the census matches.
-- (tools/ is dev tooling outside the plugin runtime; loaded via dofile.)

local snapshot = dofile('tools/snapshot.lua')
local gd = require 'cartograph.graphdiff'
local census = require 'cartograph.census'

local function fat_data()
    return {
        schema = 1, root = '/x', provider = 'treesitter',
        nodes = {
            { id = 'f', name = 'f', kind = 'function', file = 'm.lua',
                range = { start = { line = 3, char = 0 } }, df = { defs = {} } },
            { id = 'x.js::lost@3', name = 'lost', kind = 'function',
                file = 'x.js', unparsed = true },
        },
        edges = {
            { from = 'f', to = 'g', kind = 'ref', inferred = true,
                at = { start = { line = 4, char = 2 } } }, -- fat: at dropped
            { from = 'f', to = 'g', kind = 'ref', proven = true },
        },
        calls = {
            { fn = 'f', callee = 'g', to = 'g', file = 'm.lua', line = 4,
                args = { 'a' }, argv = { { k = 'lit' } } }, -- fat: args/argv dropped
            { fn = 'f', callee = 'h', file = 'm.lua', line = 5,
                refused = { rule = 'ambiguous', cands = { 'h1', 'h2' }, n = 2 } },
            { fn = 'f', callee = 'k', to = 'k', file = 'm.lua', line = 6,
                hedge = { rule = 'shadow-walkout', row = 2 } }, -- row is fat
        },
    }
end

test('snapshot: slim round-trip is instrument-faithful', function ()
    local data = fat_data()
    snapshot.dir = vim.fn.tempname()
    snapshot.save('spec', data)
    local back, meta = snapshot.load('spec')
    ok(back, 'loads')
    ok(meta and meta.when, 'stamped')
    ok(gd.empty(gd.diff(data, back)), 'graphdiff sees no difference')
    local ca, cb = census.take(data), census.take(back)
    eq(ca.edges.ref.inferred, cb.edges.ref.inferred)
    eq(ca.calls.refused, cb.calls.refused)
    eq(ca.calls.hedged, cb.calls.hedged)
    eq(1, cb.calls.hedged)
    eq(ca.calls.rules['ambiguous'].n, cb.calls.rules['ambiguous'].n)
    eq(ca.nodes.unparsed, cb.nodes.unparsed)
end)

test('snapshot: a missing or corrupt file is a clean miss', function ()
    snapshot.dir = vim.fn.tempname()
    local d, why = snapshot.load('nope')
    eq(nil, d)
    ok(why:find('no snapshot'), why)
    vim.fn.mkdir(snapshot.dir, 'p')
    local fd = assert(io.open(snapshot.dir .. '/bad.snapshot.mpack', 'wb'))
    fd:write('garbage') fd:close()
    local d2, why2 = snapshot.load('bad')
    eq(nil, d2)
    ok(why2:find('corrupt'), why2)
end)
