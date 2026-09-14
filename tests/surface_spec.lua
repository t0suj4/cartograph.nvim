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
