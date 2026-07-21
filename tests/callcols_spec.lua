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

test('callcols: row() proxy reads columns + residual, transparently', function ()
    -- a residual field (argv detail) rides a per-row table, not a column
    local rec = { file = 'a.lua', callee = 'f', line = 10, method = true,
        to = 'a.lua::f@9', argv = { { k = 'lit', v = 'x' } } }
    local cc = callcols.build({ rec })
    local c = callcols.row(cc, 1, { argv = rec.argv })
    eq('a.lua', c.file)                    -- covered → column
    eq('f', c.callee); eq(10, c.line); eq(true, c.method)
    eq('a.lua::f@9', c.to)                 -- resolution overlay
    eq(rec.argv, c.argv)                   -- residual → same table reference
    eq(nil, c.nonesuch)                    -- absent → nil
end)

test('callcols: row() proxy routes writes (overlay vs residual vs immutable)', function ()
    local cc = callcols.build({ { file = 'a.lua', callee = 'f', line = 1 } })
    local resid = {}
    local c = callcols.row(cc, 1, resid)
    c.to = 'a.lua::f@9'                    -- resolution field → overlay
    eq('a.lua::f@9', callcols.get(cc, 'to', 1))
    c.strarg = { ty = 'sql' }              -- non-covered field → residual
    eq('sql', resid.strarg.ty)
    local ok = pcall(function () c.file = 'x.lua' end)  -- immutable syntactic → refused
    eq(false, ok)
    eq('a.lua', c.file)
end)

test('callcols: view() is a faithful drop-in for the record list', function ()
    local R2 = { start = { line = 2, char = 0 }, ['end'] = { line = 2, char = 4 } }
    local calls = {
        { file = 'a.lua', callee = 'f', fn = 'a.lua::g@1', line = 3, method = false,
            at = R2, to = 'a.lua::f@9', inferred = true, argv = { 1, 2 }, hedge = true },
        { file = 'b.lua', callee = 'h', line = 7, refused = { 'x' } },
    }
    local v = callcols.view(calls)
    for i, rec in ipairs(calls) do
        for k, val in pairs(rec) do
            -- flags compare by truthiness (false ≡ nil); else by value/reference
            if k == 'method' or k == 'inferred' then
                eq(not not val, not not v.rows[i][k])
            else
                eq(val, v.rows[i][k])
            end
        end
    end
    -- residual holds the non-columnar fields; columns hold the rest
    eq(true, v.residual[1].argv ~= nil and v.residual[1].hedge ~= nil)
    eq(nil, v.residual[1].file)            -- file is columnar, not residual
end)
