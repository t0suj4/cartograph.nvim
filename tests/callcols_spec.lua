-- callcols: the resident columnar call-store. Two-phase — SYNTACTIC fields are
-- immutable u32 columns, RESOLUTION fields a mutable overlay. Gates: read-parity
-- (get returns what a record read would), and the overlay is writable while the
-- columns are not.

local callcols = require 'cartograph.callcols'

local R = { start = { line = 5, char = 2 }, ['end'] = { line = 5, char = 9 } }
local CALLS = {
    { file = 'a.lua', callee = 'f', fn = 'a.lua::g@1', full = 'M.f', to = 'a.lua::f@9',
        line = 10, method = true, inferred = false, at = R },
    { file = 'a.lua', callee = 'h', fn = 'a.lua::g@1', line = 22 },        -- sparse
    { file = 'b.lua', callee = 'f', line = 0, inferred = true },            -- shared f / a.lua
}

test('callcols: get() reads syntactic columns + resolution overlay alike', function ()
    local cc = callcols.build(CALLS)
    eq(3, cc.n)
    -- syntactic (immutable columns)
    eq('a.lua', callcols.get(cc, 'file', 1)); eq('f', callcols.get(cc, 'callee', 1))
    eq('M.f', callcols.get(cc, 'full', 1)); eq(10, callcols.get(cc, 'line', 1))
    eq(true, callcols.get(cc, 'method', 1))
    eq(5, callcols.get(cc, 'at', 1).start.line); eq(9, callcols.get(cc, 'at', 1)['end'].char)
    eq(nil, callcols.get(cc, 'at', 2))                        -- absent range → nil
    eq('b.lua', callcols.get(cc, 'file', 3)); eq('f', callcols.get(cc, 'callee', 3)) -- pooled once
    -- resolution (mutable overlay)
    eq('a.lua::f@9', callcols.get(cc, 'to', 1))
    eq(nil, callcols.get(cc, 'to', 2))                        -- absent → nil
    eq(nil, callcols.get(cc, 'inferred', 1))                  -- false → nil
    eq(true, callcols.get(cc, 'inferred', 3))
end)

test('callcols: record() reconstructs the full record (columns + overlay)', function ()
    local cc = callcols.build(CALLS)
    eq({ file = 'a.lua', callee = 'f', fn = 'a.lua::g@1', full = 'M.f', to = 'a.lua::f@9',
        line = 10, method = true, at = R }, callcols.record(cc, 1))
    eq({ file = 'b.lua', callee = 'f', line = 0, inferred = true }, callcols.record(cc, 3))
end)

test('callcols: resolution overlay is writable; syntactic columns are not', function ()
    local cc = callcols.build(CALLS)
    -- resolution writes what resolution does: fill `to`, flip `inferred`
    callcols.set(cc, 'to', 2, 'a.lua::h@5')
    callcols.set(cc, 'inferred', 2, true)
    eq('a.lua::h@5', callcols.get(cc, 'to', 2))
    eq(true, callcols.get(cc, 'inferred', 2))
    callcols.set(cc, 'to', 1, nil)                            -- a refuted resolution clears it
    eq(nil, callcols.get(cc, 'to', 1))
    -- an immutable syntactic field errors (catches a resolution-writes-parse bug)
    local ok = pcall(callcols.set, cc, 'file', 1, 'x.lua')
    eq(false, ok, 'setting a syntactic column is refused')
    eq('a.lua', callcols.get(cc, 'file', 1))                  -- unchanged
end)
