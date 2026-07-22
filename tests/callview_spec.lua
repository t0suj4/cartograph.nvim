-- callview: the representation-neutral call accessor for resolution. Same reads/
-- writes over raw records (default) and the columnar store (data._callstore) — the
-- substrate audit/relink/the resolve passes share so they run index-form on the
-- peak path. Gate: both backends behave identically for get/set + argv.

local callview = require 'cartograph.callview'
local rescols = require 'cartograph.rescols'

local function calls()
    return {
        { file = 'a.lua', callee = 'f', fn = 'a.lua::g@1', line = 10,
            argv = { { k = 'local', name = 'cb' } } },
        { file = 'a.lua', callee = 'h', fn = 'a.lua::g@1', line = 22, to = 'a.lua::h@3' },
    }
end

local function check(label, cv)
    test('callview: ' .. label .. ' reads + writes', function ()
        eq(2, cv.n)
        eq('a.lua', cv.get(1, 'file')); eq('f', cv.get(1, 'callee'))
        eq('a.lua::g@1', cv.get(1, 'fn')); eq(10, cv.get(1, 'line'))
        eq(nil, cv.get(1, 'to')); eq('a.lua::h@3', cv.get(2, 'to'))
        -- argv
        eq(1, cv.argn(1)); eq(0, cv.argn(2))
        eq('local', cv.aget(1, 1, 'k')); eq('cb', cv.aget(1, 1, 'name'))
        -- resolution writes (overlay on the store, direct on records)
        cv.set(1, 'to', 'a.lua::f@9'); eq('a.lua::f@9', cv.get(1, 'to'))
        cv.set(2, 'to', nil); eq(nil, cv.get(2, 'to'))
        -- the argv upgrade shape (a.k/a.to/a.up)
        cv.aset(1, 1, 'k', 'func'); cv.aset(1, 1, 'to', 'a.lua::cb@3'); cv.aset(1, 1, 'up', true)
        eq('func', cv.aget(1, 1, 'k')); eq('a.lua::cb@3', cv.aget(1, 1, 'to'))
        eq(true, cv.aget(1, 1, 'up'))
    end)
end

check('records backend', callview.of({ calls = calls() }))
-- store backend: a rescols view attached as data._callstore (the peak path)
do
    local data = { calls = calls() }
    data._callstore = rescols.view(data.calls)
    check('columnar-store backend', callview.of(data))
end
