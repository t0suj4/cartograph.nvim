-- callcols: the resident columnar call-store (packed/ffi u32 columns + pool).
-- The gate is READ-PARITY — every accessor returns exactly what a record read
-- would (absent str → nil, absent int → 0, flag false → nil, absent range → nil).

local callcols = require 'cartograph.callcols'

local R = { start = { line = 5, char = 2 }, ['end'] = { line = 5, char = 9 } }
local CALLS = {
    { file = 'a.lua', callee = 'f', fn = 'a.lua::g@1', full = 'M.f', to = 'a.lua::f@9',
        line = 10, method = true, inferred = false, at = R },
    { file = 'a.lua', callee = 'h', fn = 'a.lua::g@1', line = 22 },        -- sparse
    { file = 'b.lua', callee = 'f', line = 0, inferred = true },            -- shared f / a.lua
}

test('callcols: accessors read exactly what the records held', function ()
    local cc = callcols.build(CALLS)
    eq(3, cc.n)
    eq('a.lua', callcols.str(cc, 'file', 1)); eq('f', callcols.str(cc, 'callee', 1))
    eq('M.f', callcols.str(cc, 'full', 1)); eq('a.lua::f@9', callcols.str(cc, 'to', 1))
    eq(nil, callcols.str(cc, 'full', 2))                       -- absent str → nil
    eq('b.lua', callcols.str(cc, 'file', 3))
    eq('f', callcols.str(cc, 'callee', 3))                     -- pooled once, resolves in both
    eq(10, callcols.int(cc, 'line', 1)); eq(22, callcols.int(cc, 'line', 2)); eq(0, callcols.int(cc, 'line', 3))
    eq(true, callcols.flag(cc, 'method', 1)); eq(nil, callcols.flag(cc, 'inferred', 1))
    eq(true, callcols.flag(cc, 'inferred', 3))
    eq(5, callcols.range(cc, 'at', 1).start.line); eq(9, callcols.range(cc, 'at', 1)['end'].char)
    eq(nil, callcols.range(cc, 'at', 2), 'absent range → nil')
end)

test('callcols: record() reconstructs the schema-field record', function ()
    local cc = callcols.build(CALLS)
    eq({ file = 'a.lua', callee = 'f', fn = 'a.lua::g@1', full = 'M.f', to = 'a.lua::f@9',
        line = 10, method = true, at = R }, callcols.record(cc, 1))
    eq({ file = 'a.lua', callee = 'h', fn = 'a.lua::g@1', line = 22 }, callcols.record(cc, 2))
    eq({ file = 'b.lua', callee = 'f', line = 0, inferred = true }, callcols.record(cc, 3))
end)

test('callcols: empty list builds a valid empty store', function ()
    local cc = callcols.build({})
    eq(0, cc.n)
    eq(nil, callcols.str(cc, 'file', 1) ~= nil and 'x' or nil)
end)
