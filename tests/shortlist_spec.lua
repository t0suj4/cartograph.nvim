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

-- ★★ COMPOSITION: run a tool over another tool's rows, and the COMPLETENESS
-- COMPOSES DOWNWARD. This is where the contract earns its keep a second time —
-- an exhaustive check over the top 15 of a ranked-open list has examined every
-- member OF THE FIFTEEN and says nothing about the rest, so reporting it as
-- exhaustive is a false claim about the ORIGINAL population.
test('shortlist: ranked-open is ABSORBING under derive', function ()
    local open = sl.new{ subject = 'top signatures', scope = '1274 signatures',
        complete = sl.RANKED_OPEN, rows = { { name = 'a' }, { name = 'b' } } }
    local d = open:derive{ subject = 'of those, the ones with a fix',
        complete = sl.EXHAUSTIVE, rows = { { name = 'a' } } }
    ok(d, 'it composes')
    eq(sl.RANKED_OPEN, d.complete,
        'an exhaustive step over a truncated population is NOT exhaustive')
    ok(d:lost_at(), 'and the loss is recorded, not silent')
    ok(table.concat(d:render(), '\n'):find('coverage lost'),
        '...and surfaces in the render, naming the step that spent it')
end)

-- ★★ THE LEDGER NAMES THE STEP THAT ACTUALLY TRUNCATED, NOT THE LAST ONE TO RUN.
-- The first version of this recorded only the immediate parent, and MEASURED on
-- a four-step chain that was wrong in both directions: the step that truncated
-- (B) came back blameless, and the accusation landed on C — a step that examined
-- every member and spent nothing.
test('shortlist: the absorbing event is attributed to its ORIGIN across a chain', function ()
    local a = sl.new{ subject = 'A all', scope = 'all', complete = sl.EXHAUSTIVE, rows = { {} } }
    local b = a:derive{ subject = 'B top 15', complete = sl.RANKED_OPEN, rows = { {} } }
    local c = b:derive{ subject = 'C checked each', complete = sl.EXHAUSTIVE, rows = { {} } }
    local d = c:derive{ subject = 'D checked again', complete = sl.EXHAUSTIVE, rows = { {} } }
    eq(nil, a:lost_at(), 'an exhaustive root has spent nothing')
    eq('B top 15', b:lost_at().subject, 'the truncating step records the event ON ITSELF')
    eq('B top 15', c:lost_at().subject, 'a later exhaustive step does not take the blame')
    eq('B top 15', d:lost_at().subject, '...however far downstream it is')
    eq(1, #d:weakenings(), "and one cut is counted once, not once per step")
    eq(4, #d.derivation, "...while EVERY step is on the chain, lossy or not")
end)

-- ★ HOW MANY TIMES matters as much as where: one truncation of 1274 is a
-- different object from three stacked ones, and a reader deciding whether a
-- small surviving set is worth acting on needs the count.
test('shortlist: stacked truncations each get an entry', function ()
    local a = sl.new{ subject = 'A all', scope = 'all', complete = sl.EXHAUSTIVE, rows = { {} } }
    local b = a:derive{ subject = 'B top 15', complete = sl.RANKED_OPEN, rows = { {} } }
    local c = b:derive{ subject = 'C top 3', complete = sl.RANKED_OPEN, rows = { {} } }
    eq(2, #c:weakenings(), "two independent cuts, two weakenings")
    eq('B top 15', c:lost_at().subject, 'the FIRST is still where it was lost')
    local text = table.concat(c:render(), '\n')
    ok(text:find('narrowed 2 time'), 'the count is rendered')
    ok(text:find('and again at "C top 3"', 1, true), 'and the later cut is named too')
end)

test('shortlist: exhaustive composes with exhaustive, and only then', function ()
    local ex = sl.new{ subject = 'declared entries', scope = 'the 3 entries',
        complete = sl.EXHAUSTIVE, rows = { { name = 'a' }, { name = 'b' } } }
    local d = ex:derive{ subject = 'of those, unguarded',
        complete = sl.EXHAUSTIVE, rows = { { name = 'a' } } }
    eq(sl.EXHAUSTIVE, d.complete, 'both steps examined everything')
    eq(nil, d.demoted_by, 'nothing was spent')
    -- and a ranked step over an exhaustive parent still demotes
    local d2 = ex:derive{ subject = 'the best of those', complete = sl.RANKED_OPEN,
        rows = { { name = 'a' } } }
    eq(sl.RANKED_OPEN, d2.complete, 'a derived list may be MORE restricted, never less')
end)

test('shortlist: a derived list must state its own completeness too', function ()
    local ex = sl.new{ subject = 'x', scope = 'y', complete = sl.EXHAUSTIVE, rows = {} }
    local d, why = ex:derive{ subject = 'z', rows = {} }
    eq(nil, d, 'inheriting silently is refused')
    ok(why and why:find('exhaustive'), 'and the refusal says why: ' .. tostring(why))
end)

-- ★ ADDRESSABILITY IS WHAT MAKES THE NEXT TOOL POSSIBLE. A row may carry a
-- durable `ref` (store.ref_of's contract — what pins, plans and journals hold
-- instead of a session-lived id), so a downstream tool can resolve it against a
-- re-extracted graph without this module knowing about node ids at all.
test('shortlist: rows carrying a durable ref are collectable for the next tool', function ()
    local s = sl.new{ subject = 'candidates', scope = 'all', complete = sl.EXHAUSTIVE,
        rows = { { name = 'a', ref = { file = 'x.lua', kind = 'function', name = 'f' } },
                 { name = 'b' } } }
    eq(1, #s:refs(), 'only the rows that carry one')
    eq('x.lua', s:refs()[1].file)
end)

-- ★★ THE LADDER IS THE CONVERGENCE (user: "it is a provenance tracking").
-- `complete` is a two-rung TIER, the meet is `max(rank)`, and the absorbing
-- element FALLS OUT of the ladder instead of being special-cased — so a third
-- rung inserts as ONE ROW, which is the lesson tier.lua's header records after
-- its if-chain was hand-copied into four places and drifted.
test('shortlist: completeness is a ranked ladder, and the meet is the weaker rung', function ()
    eq(1, sl.rank(sl.EXHAUSTIVE), 'lower rank is more complete')
    eq(2, sl.rank(sl.RANKED_OPEN))
    eq(sl.EXHAUSTIVE, sl.meet(sl.EXHAUSTIVE, sl.EXHAUSTIVE))
    eq(sl.RANKED_OPEN, sl.meet(sl.EXHAUSTIVE, sl.RANKED_OPEN), 'the weaker wins')
    eq(sl.RANKED_OPEN, sl.meet(sl.RANKED_OPEN, sl.EXHAUSTIVE), '...in either order')
    eq(nil, sl.meet('made-up', sl.EXHAUSTIVE), 'an unknown rung has no rank and no meet')
    -- the ladder is data, so a reader can enumerate the rungs and their meaning
    eq(2, #sl.LADDER)
    ok(sl.LADDER[1].why:find('every member'), 'each rung says what it claims')
end)

-- ★ EVERY STEP IS ON THE CHAIN, LOSSY OR NOT — that is what makes it PROVENANCE
-- rather than an incident log. A lossy-events-only ledger left an all-exhaustive
-- derivation with NO record of how it was built.
test('shortlist: an all-exhaustive chain still records its provenance', function ()
    local a = sl.new{ subject = 'A', scope = 'all', complete = sl.EXHAUSTIVE, rows = { {} } }
    local b = a:derive{ subject = 'B', complete = sl.EXHAUSTIVE, rows = { {} } }
    local c = b:derive{ subject = 'C', complete = sl.EXHAUSTIVE, rows = { {} } }
    eq(3, #c.derivation, 'three steps, three entries')
    eq(0, #c:weakenings(), 'none of them weakened anything')
    eq(nil, c:lost_at(), 'so nothing was lost')
    eq('A', c.derivation[1].subject, 'and the chain reads oldest-first')
end)

-- ★ A STEP RECORDS THE CLAIM IT MADE, NOT THE MEET IT LANDED IN. A step that
-- examined everything it was given says `exhaustive` forever; the meet lives on
-- the LIST. Conflating them would blame an honest step for an upstream cut,
-- which is exactly the attribution bug this replaced.
test('shortlist: a chain step keeps its OWN claim, not the composed one', function ()
    local a = sl.new{ subject = 'A', scope = 'all', complete = sl.RANKED_OPEN, rows = { {} } }
    local b = a:derive{ subject = 'B examined all 15', complete = sl.EXHAUSTIVE, rows = { {} } }
    eq(sl.RANKED_OPEN, b.complete, 'the LIST is ranked-open, by the meet')
    eq(sl.EXHAUSTIVE, b.derivation[2].complete, '...while the STEP kept its honest claim')
    eq('A', b:lost_at().subject, 'so the loss is attributed upstream, where it happened')
end)
