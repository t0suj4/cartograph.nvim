-- Unit tests for temporal-coupling attribution and co-occurrence.

local coupling = require 'cartograph.coupling'

local R = function (s, e) return { start = { line = s, char = 0 }, ['end'] = { line = e, char = 0 } } end
local function fn(file, name, s, e) return { file = file, name = name, kind = 'function', range = R(s, e) } end

test('coupling: changed lines are attributed to the functions containing them', function ()
    -- A spans lines 1..6 (0-based 0..5), B spans 10..16 (0-based 9..15)
    local nodes = { fn('m.lua', 'A', 0, 5), fn('m.lua', 'B', 9, 15) }
    local touched = coupling.attribute(nodes, { ['m.lua'] = { [3] = true, [12] = true } })
    ok(touched['m.lua::A/function'], 'A touched (line 3)')
    ok(touched['m.lua::B/function'], 'B touched (line 12)')
end)

test('coupling: a change outside any function touches nothing', function ()
    local nodes = { fn('m.lua', 'A', 0, 5) }
    local touched = coupling.attribute(nodes, { ['m.lua'] = { [99] = true } })
    eq(nil, touched['m.lua::A/function'])
end)

test('coupling: co-occurrence counts pairs and solo support', function ()
    local sets = {
        { ['A'] = true, ['B'] = true },
        { ['A'] = true, ['C'] = true },
        { ['A'] = true, ['B'] = true },
    }
    local c = coupling.accumulate(sets)
    eq(3, c.solo['A'])
    eq(2, c.solo['B'])
    eq(2, c.pair['A\31B'])
    eq(1, c.pair['A\31C'])
    eq(nil, c.pair['B\31C'])
end)

test('coupling: partners are ranked with confidence = count/support', function ()
    local c = coupling.accumulate({
        { ['A'] = true, ['B'] = true },
        { ['A'] = true, ['C'] = true },
        { ['A'] = true, ['B'] = true },
    })
    local p = coupling.partners(c, 'A')
    eq('B', p[1].key)
    eq(2, p[1].count)
    eq(2 / 3, p[1].confidence)   -- A changed 3×, with B 2×
    eq('C', p[2].key)
end)
