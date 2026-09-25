-- surface: what a vendored artifact reaches for, and whether anything supplies it.
--
-- ★★★ THIS TOOL EXISTS BECAUSE I HAND-ROLLED THE SAME CHECK TWICE IN ONE DAY —
-- the PARTS protocol and the donor harness shim are both `reads ⊆ supplied`, one
-- interface apart. ⚠ AND ON EXTRACTION ITS OWN TWO GUARDS WERE UNPINNED: both
-- mutations passed the suite, because the two callers exercise the HAPPY PATH
-- and nothing exercised the tool. A promoted helper inherits its callers' tests
-- and not its own.

local surface = dofile(vim.fn.getcwd() .. '/tools/surface.lua')

test('surface: a dotted member is ONE name, not two', function ()
    -- `assert.are_not.equal` is a single busted assertion; splitting it at the
    -- first dot would report `assert.are_not` as the missing name and send a
    -- reader looking for the wrong thing
    local u = surface.uses('assert.are_not.equal(a, b)\nassert.same(c, d)\n',
        { receivers = { 'assert' } })
    eq(true, u['assert.are_not.equal'])
    eq(true, u['assert.same'])
    eq(nil, u['assert.are_not'])
end)

--- ★★★ THE RECEIVER FRONTIER. Without it a receiver matches inside a LONGER
--- name: the parts fence reported `termgraph reads S.eqs` — that part's own
--- term-graph store — back when the parameter was called `S`, and the fix was to
--- rename the convention AND anchor the match.
test('surface: a receiver matches on a word boundary, not a substring', function ()
    local src = 'local x = MYSHARED.nope\nlocal y = SHARED.yes\nlocal z = SHAREDX.no\n'
    local u = surface.uses(src, { receivers = { 'SHARED' } })
    eq(true, u['SHARED.yes'])
    eq(nil, u['SHARED.nope'], 'MYSHARED.nope is a different receiver')
    -- ⚠ `SHAREDX.no` has no frontier after the receiver, so the pattern must not
    -- treat `SHAREDX` as `SHARED` followed by a member
    eq(nil, u['SHARED.no'])
end)

test('surface: a bare name counts only where it is CALLED', function ()
    local u = surface.uses('describe("x", function () end)\n-- it is mentioned here\n',
        { bares = { 'describe', 'it' } })
    eq(true, u['describe'])
    eq(nil, u['it'], 'prose naming `it` is not a use')
end)

--- ★★★ THE FLOOR IS PART OF THE ANSWER. A scan whose pattern matches nothing
--- reports ZERO MISSING — indistinguishable from a shim that supplies
--- everything. Both hand-rolled versions carried this assertion separately and
--- both would have been wrong without it.
test('surface: an empty scan REFUSES rather than reporting a total surface', function ()
    local missing, why = surface.gap({}, { 'a', 'b' })
    eq(nil, missing)
    ok(tostring(why):find('NO uses at all', 1, true), tostring(why))
    -- a caller that legitimately expects nothing says so
    local m2 = surface.gap({}, { 'a' }, { allow_empty = true })
    eq(0, #m2)
end)

test('surface: supplied may be a list or a set, and the gap is sorted', function ()
    local used = { ['assert.same'] = true, ['assert.zzz'] = true, ['assert.aaa'] = true }
    local as_list = surface.gap(used, { 'assert.same' })
    local as_set = surface.gap(used, { ['assert.same'] = true })
    eq(as_list, as_set)
    eq({ 'assert.aaa', 'assert.zzz' }, as_list, 'sorted, so the message is stable')
    ok(surface.report(as_list, 'shim'):find('2 unsupplied', 1, true))
    eq('shim: total', surface.report({}, 'shim'))
end)

-- ── the free names of a SET, which is what a capture is ────────────────────

local expr = require 'cartograph.expr'
local ts2 = require 'cartograph.providers.treesitter'
local store2 = require 'cartograph.store'

local function ready2()
    return pcall(vim.treesitter.language.add, 'lua')
end

--- ★★★ THE SUBTRACTION IS THE WHOLE POINT. `expr.free` subtracts ONE function's
--- own bindings, which is right for one function and wrong for a SET: a nested
--- closure reads its parent's locals, and those are free for the child and BOUND
--- in the set.
test('expr.free_set: the set\'s own bindings are subtracted', function ()
    if not ready2() then skip('no lua parser') end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/m.lua', 'w'))
    fd:write(table.concat({
        'local M = {}',
        'local OUTSIDE = 1',
        'function M.a(x)',
        '    local mine = x',
        '    local function inner(y) return mine + y + OUTSIDE end',
        '    return inner(x)',
        'end',
        'return M',
    }, '\n')); fd:close()
    store2.ingest(ts2.extract(root))
    local ids = {}
    for _, n in ipairs(store2.data.nodes) do
        if n.file == 'm.lua' and (n.kind == 'function' or n.kind == 'method') then
            ids[#ids + 1] = n.id
        end
    end
    ok(#ids >= 2, 'the fixture has a parent and a child: ' .. #ids)

    local free, partial = expr.free_set(store2, ids)
    eq(false, partial)
    eq(true, free['OUTSIDE'], 'a name from outside the set is free')
    eq(nil, free['mine'], 'a name the SET binds is not free, though the child reads it')
    eq(nil, free['x'], 'nor is a parameter')
    eq(nil, free['y'], 'nor a nested parameter')
end)

--- ⚠ A PARTIAL ANSWER IS A LOWER BOUND, and a caller deciding on it must not
--- read an absence as evidence — which is why the flag exists rather than a
--- silently short set.
test('expr.free_set: an unanswerable node makes the result PARTIAL', function ()
    if not ready2() then skip('no lua parser') end
    local free, partial = expr.free_set(store2, { 'no-such-node-id' })
    eq(true, partial)
    eq(0, (function () local c = 0; for _ in pairs(free) do c = c + 1 end; return c end)())
end)
