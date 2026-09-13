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

-- CART-0887. The charter demands "a reified fact must say how it came to be"; until
-- now the schema could not carry it, and the manual said of accessor reads that they
-- are "shown, never minted as edges — the graph has nowhere to record where an edge
-- came from yet, and an edge that cannot say would launder one kind of claim as the
-- other". `origin` is the strength, `via` the channel — two fields because
-- characterize.lua learned from a shipped bug that "THE CHANNEL RECORDS HOW, THE TIER
-- RECORDS HOW STRONG".
test('validate: a derived fact with no `via` is the laundering the field exists to stop', function ()
    local base = { id = 'a.lua::f@1', name = 'f', kind = 'function',
        file = 'a.lua', range = { start = { line = 0, char = 0 }, ['end'] = { line = 0, char = 1 } } }
    local function check(extra)
        local n = vim.tbl_extend('force', {}, base, extra or {})
        return validate.check({ nodes = { n }, edges = {}, calls = {}, root = '/x' })
    end
    -- ⚠ `check` returns { checked, ok, violations } and the rules live under
    -- `violations`, keyed by rule name. Two wrong guesses before reading it: a list
    -- of flags, then a top-level map. Both read as "the validation never fires" when
    -- it was firing correctly one level down — an accessor error, not a code one.
    local function flagged(res, tag)
        for rule in pairs((res or {}).violations or {}) do
            if tostring(rule):find(tag, 1, true) then return true end
        end
        return false
    end
    -- observed needs no via: the parse said so and the file is the witness
    ok(not flagged(check { origin = 'observed' }, 'origin'), 'observed alone is fine')
    -- derived without via is the laundering
    ok(flagged(check { origin = 'derived' }, 'origin-via'),
        'derived with no via is flagged')
    ok(not flagged(check { origin = 'derived', via = 'symfony' }, 'origin'),
        'derived WITH via is fine')
    -- and a value outside the three reads as "some other kind of fact" to consumers
    ok(flagged(check { origin = 'guessed', via = 'x' }, 'origin'),
        'an origin outside the three is flagged')
end)
