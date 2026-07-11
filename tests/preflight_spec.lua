-- Preflight's pure core: changed lines -> containing fns -> reverse cone
-- -> spec selection via require-cones (import-cone honesty: a spec that
-- reaches a touched file by fixture, not require, is NOT selected — the
-- full suite guards the push).

local preflight = require 'cartograph.preflight'
local store = require 'cartograph.store'

local function node(id, kind, file, sl, el)
    return { id = id, name = id, kind = kind, file = file, order = 0,
        range = { start = { line = sl, char = 0 },
            ['end'] = { line = el, char = 0 } } }
end

test('preflight: containment, cone, spec selection', function ()
    store.ingest({
        root = '/x',
        nodes = {
            node('lua/a.lua', 'module', 'lua/a.lua', 0, 30),
            node('lua/a.lua::hit', 'function', 'lua/a.lua', 4, 9),
            node('lua/a.lua::miss', 'function', 'lua/a.lua', 12, 20),
            node('lua/b.lua', 'module', 'lua/b.lua', 0, 10),
            node('lua/b.lua::caller', 'function', 'lua/b.lua', 1, 5),
            node('tests/a_spec.lua', 'module', 'tests/a_spec.lua', 0, 5),
            node('tests/other_spec.lua', 'module', 'tests/other_spec.lua', 0, 5),
        },
        edges = {
            { from = 'lua/b.lua::caller', to = 'lua/a.lua::hit', kind = 'ref',
                at = { { start = { line = 2, char = 0 },
                    ['end'] = { line = 2, char = 3 } } } },
            { from = 'tests/a_spec.lua', to = 'lua/a.lua', kind = 'import' },
            { from = 'tests/other_spec.lua', to = 'lua/b.lua', kind = 'import' },
        },
        calls = {},
    })
    local a = preflight.affected(store, { ['lua/a.lua'] = { 6 } })
    eq({ 'lua/a.lua::hit' }, a.fns, 'line 6 lands in hit, not miss')
    eq({ 'lua/b.lua::caller' }, a.cone, 'the caller is in the reverse cone')
    ok(a.files['lua/b.lua'], "the cone fn's home file is touched")
    eq({ 'tests/a_spec.lua', 'tests/other_spec.lua' }, a.specs,
        'a_spec requires the changed file; other_spec requires the CONE file')
    local b = preflight.affected(store, { ['lua/a.lua'] = { 15 } })
    eq({ 'lua/a.lua::miss' }, b.fns)
    eq({}, b.cone, 'nothing calls miss')
    eq({ 'tests/a_spec.lua' }, b.specs, 'only the direct-require spec')
end)
