-- The schema validator: the closed schema as an executable registry.
local validate = require 'cartograph.validate'

local R = { start = { line = 0, char = 0 }, ['end'] = { line = 0, char = 0 } }
local function node(id, kind, extra)
    local n = { id = id, name = id, kind = kind or 'function',
        file = 'm.lua', range = R, order = 0 }
    for k, v in pairs(extra or {}) do n[k] = v end
    return n
end

test('validate: a clean graph is OK', function ()
    local r = validate.check({ nodes = { node('m.lua', 'module'), node('a') },
        edges = { { from = 'm.lua', to = 'a', kind = 'reg', at = { R } } },
        calls = { { callee = 'x', file = 'm.lua', line = 3 } } })
    ok(r.ok, 'clean')
    eq(2, r.checked.nodes)
end)

test('validate: each violation class is caught', function ()
    local r = validate.check({
        nodes = { node('a'), node('a'),                  -- dup id
            node('b', 'gadget'),                          -- unknown kind
            node('c', 'var', { mystery = 1 }),            -- unknown field
            { id = 'd', name = 'd', kind = 'var', file = 'm.lua',
                order = 0, range = { start = { line = 5, char = 0 },
                    ['end'] = { line = 2, char = 0 } } } }, -- inverted range
        edges = { { from = 'a', to = 'ghost', kind = 'ref' },      -- dangling
            { from = 'a', to = 'c', kind = 'wormhole' },           -- unknown kind
            { from = 'a', to = 'c', kind = 'ref',
                at = { R, R, R }, atn = 2 } },                     -- atn < #at
        calls = { { callee = 'x', file = 'm.lua', line = 1,
            refused = {} },                                        -- rule-less refusal
            { callee = 'y', file = 'm.lua', line = 2, to = 'ghost' } }, -- dangling to
    })
    ok(not r.ok)
    for _, rule in ipairs({ 'node-dup-id', 'node-kind', 'node-field',
        'node-range', 'edge-dangling-to', 'edge-kind', 'edge-atn',
        'call-refusal-rule', 'call-dangling-to' }) do
        ok(r.violations[rule], rule .. ' caught')
    end
end)
