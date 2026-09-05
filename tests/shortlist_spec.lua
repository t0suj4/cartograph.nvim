-- CART-0755. A SHORTLIST IS THE THIRD OUTPUT KIND: not an action ("do this"),
-- not a premise ("true if X"), but "the answer is in here, ranked". It asserts
-- nothing about correctness, which is exactly why it generalises where a derived
-- action does not — a wrong shortlist costs TIME, not truth.
--
-- ★★ THE ONE RULE THESE TESTS EXIST FOR: `complete` is MANDATORY. A narrowing
-- presented as complete becomes a CLAIM, and it fails in the dangerous direction
-- — "the answer is one of these five" makes a reader STOP LOOKING.

local sl = require 'cartograph.shortlist'

test('shortlist: a list that does not state its completeness is REFUSED', function ()
    local s, why = sl.new{ subject = 'unguarded entries', scope = 'SOLE_WRAP', rows = {} }
    eq(nil, s, 'no shortlist is built')
    ok(why and why:find('complete'), 'and the refusal names the missing field: ' .. tostring(why))
    -- ...and a WRONG value is refused too, not silently coerced
    local s2 = sl.new{ subject = 'x', scope = 'y', complete = 'probably', rows = {} }
    eq(nil, s2, 'an unrecognised completeness is not accepted')
end)

test('shortlist: subject and scope are required — a set with no population is not a narrowing', function ()
    eq(nil, sl.new{ scope = 'y', complete = sl.EXHAUSTIVE, rows = {} })
    eq(nil, sl.new{ subject = 'x', complete = sl.EXHAUSTIVE, rows = {} })
    ok(sl.new{ subject = 'x', scope = 'y', complete = sl.EXHAUSTIVE, rows = {} },
        'with both, it builds')
end)

-- ★★ THE ASYMMETRY IS THE POINT. Two empty lists, two different meanings, and
-- conflating them is how a measured zero turns into "nothing to see".
test('shortlist: an EMPTY list means different things under the two completenesses', function ()
    local ex = sl.new{ subject = 'unguarded entries', scope = 'the 3 declared entries',
        complete = sl.EXHAUSTIVE, rows = {} }
    local op = sl.new{ subject = 'recurring signatures', scope = '1028 signatures',
        complete = sl.RANKED_OPEN, rows = {} }
    ok(ex:empty_reason():find('every member was examined'),
        'exhaustive-and-empty is a FINDING')
    ok(op:empty_reason():find('NOT a statement'),
        'ranked-open-and-empty is the ABSENCE of a finding, and says so')
    ok(ex:empty_reason() ~= op:empty_reason(), 'and the two never read alike')
end)

test('shortlist: render carries the completeness in the header, unskippably', function ()
    local s = sl.new{ subject = 'unguarded entries', scope = 'SOLE_WRAP',
        complete = sl.RANKED_OPEN, columns = { 'name' },
        rows = { { name = 'a' }, { name = 'b' } } }
    local lines = s:render()
    ok(lines[1]:find(sl.RANKED_OPEN, 1, true),
        'the first line states what the list does and does not mean')
    eq(3, #lines, 'header + one line per row')
    -- a caller may format rows, and STILL cannot drop the header
    local custom = s:render(function (r, i) return i .. ':' .. r.name end)
    ok(custom[1]:find(sl.RANKED_OPEN, 1, true), 'a custom formatter does not remove it')
    eq('  1:a', custom[2])
end)

-- ★ SKIPPED MEMBERS ARE PART OF THE COMPLETENESS CLAIM. An "exhaustive" list
-- that quietly skipped members is not exhaustive; naming them is what keeps the
-- header true rather than aspirational.
test('shortlist: an exhaustive list names what it did not examine', function ()
    local s = sl.new{ subject = 'unguarded entries', scope = 'the 5 declared entries',
        complete = sl.EXHAUSTIVE, columns = { 'name' },
        rows = { { name = 'a' } }, skipped = { 'd', 'e' } }
    local text = table.concat(s:render(), '\n')
    ok(text:find('not examined'), 'the skipped members are stated')
    ok(text:find('d, e', 1, true), '...by name, so the claim can be checked')
end)
