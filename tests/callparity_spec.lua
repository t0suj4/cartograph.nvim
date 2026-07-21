-- callparity: the resident-store faithfulness gate. callcols.view must be a
-- behaviour-faithful drop-in for data.calls — columns read back == records, the
-- proxy round-trips every field, and a FLAG stored as explicit `false` is parity
-- with the column's `nil` (both falsy). The gate is #mismatches == 0; the
-- residual set is the honest coverage disclosure.

local cp = dofile('tools/callparity.lua')

local R = { start = { line = 5, char = 2 }, ['end'] = { line = 5, char = 9 } }

test('callparity: a faithful store reports zero mismatches', function ()
    local data = { calls = {
        { file = 'a.lua', callee = 'f', fn = 'a.lua::g@1', full = 'M.f', line = 10,
            method = true, at = R, to = 'a.lua::f@9', inferred = false },
        { file = 'a.lua', callee = 'h', line = 22, method = false },   -- explicit false flag
        { file = 'b.lua', callee = 'f', line = 0, inferred = true,
            argv = { { k = 'lit', v = 'x' } } },                       -- residual field
    } }
    local r = cp.check(data)
    eq(3, r.n)
    eq(0, #r.mismatches)          -- method=false ≡ nil (flag truthiness), no false positive
    eq(1, r.residual.argv)        -- argv rides the residual (not yet columnar)
    eq(3, r.covered.file)         -- file is columnar on all three
end)

test('callparity: empty graph is trivially green', function ()
    local r = cp.check({ calls = {} })
    eq(0, r.n); eq(0, #r.mismatches)
end)
