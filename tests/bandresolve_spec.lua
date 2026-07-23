-- bandresolve: the IN-BAND fit (federation F2). Mirrors relink's resolve core —
-- EXACT key wins if uniquely lang-fitting; exact-present-but-non-unique REFUSES (no
-- tail fallback); tail (last segment) only when the exact key is ABSENT; never crosses
-- languages. The federated resolver's in-band half (bandlink is the cross-band half).

local bandresolve = require 'cartograph.bandresolve'
local LUA = function () return 'lua' end

local function index(exact, tail)
    return { exact = exact or {}, tail = tail or {} }
end

test('bandresolve: a unique exact key resolves in-band', function ()
    local ix = index({ ['A.f'] = { { id = 'a', file = 'x.lua' } } })
    local fit, why = bandresolve.in_band_fit('A.f', ix, 'lua', LUA)
    eq('a', fit.id); eq('exact', why)
end)

test('bandresolve: exact present but NON-unique refuses (no tail fallback)', function ()
    local ix = index(
        { ['A.f'] = { { id = 'a', file = 'x.lua' }, { id = 'b', file = 'y.lua' } } },
        { f = { { id = 'c', file = 'z.lua' } } })
    local fit, why = bandresolve.in_band_fit('A.f', ix, 'lua', LUA)
    eq(nil, fit); eq('ambiguous', why) -- did NOT fall through to the unique tail 'c'
end)

test('bandresolve: tail fires only when the exact key is ABSENT', function ()
    local ix = index({}, { f = { { id = 'c', file = 'z.lua' } } })
    local fit, why = bandresolve.in_band_fit('A.f', ix, 'lua', LUA)
    eq('c', fit.id); eq('tail', why)
end)

test('bandresolve: an ambiguous tail refuses', function ()
    local ix = index({}, { f = { { id = 'c', file = 'z.lua' }, { id = 'd', file = 'w.lua' } } })
    local fit, why = bandresolve.in_band_fit('A.f', ix, 'lua', LUA)
    eq(nil, fit); eq('ambiguous', why)
end)

test('bandresolve: a name never crosses languages (exact filtered → absent)', function ()
    local ix = index({ ['A.f'] = { { id = 'a', file = 'x.rb' } } })
    local fit, why = bandresolve.in_band_fit('A.f', ix, 'lua', function () return 'ruby' end)
    eq(nil, fit); eq('absent', why)
end)

test('bandresolve: a missing band is no-band, not a crash', function ()
    local fit, why = bandresolve.in_band_fit('A.f', nil, 'lua', LUA)
    eq(nil, fit); eq('no-band', why)
end)
