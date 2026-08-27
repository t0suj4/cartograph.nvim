-- SHAPE MATCHING against the profile's declared class table (CART-0590).
-- The premise: the members OBSERVED on an unresolved base are its shape, and a
-- class that declares every one of them is a candidate — a subset lookup, not
-- receiver typing. These specs fence the four things that make the answer honest
-- rather than merely present:
--   1. PARENT CLOSURE. `insert` is not on LuaPlayer, it is on LuaControl. Without
--      the transitive closure the most observed receiver in the corpus FALSE-ZEROES
--      — a premise that dies for the wrong reason looks exactly like one that dies.
--   2. THE FREE ANSWER KEY. global2class declares 9 (base -> class) pairs, so the
--      matcher is scored against ground truth: 9/9 must CONTAIN the declared class
--      (soundness) and 8/9 resolve UNIQUELY (precision — `rcon` is genuinely
--      ambiguous, its two members are shared by 5 classes).
--   3. THREE OUTCOMES THAT RENDER DIFFERENTLY. determined / ambiguous / no-class
--      are different facts; a reader who cannot tell them apart is being told a
--      candidate list is an answer. Plus the n=0 case, where the empty shape is a
--      subset of EVERY class and must not read as a 148-way match.
--   4. THE TWO KNOWN WRONGS. `name.find` -> LuaEquipmentGrid (it is string.find)
--      and `Zone.get_surface` -> LuaGameScript are both n=1, both real answers the
--      matcher gives. They must stay VISIBLE as single-member hypotheses — n is in
--      the evidence and in the rendering — rather than be excluded by a threshold
--      that would also drop the 27-of-29 high-call n=1 answers that are right.

local cm = require 'cartograph.classmatch'
local tier = require 'cartograph.tier'

local function ct()
    local t, why = cm.table(nil)
    if not t then skip('no class table: ' .. tostring(why)) end
    return t
end

test('classmatch: the class table closes over `parent` (player.insert lives on LuaControl)', function ()
    local t = ct()
    ok(t.n >= 100, ('the full class table is distilled, not the 9-global set (%d classes)'):format(t.n))
    ok(t.n_parent > 0, ('`parent` is emitted (%d classes carry one)'):format(t.n_parent))
    local pl = t.classes.LuaPlayer
    ok(pl ~= nil, 'LuaPlayer is in the table (it was one of the 139 discarded classes)')
    eq('LuaControl', pl.parent, 'LuaPlayer inherits LuaControl')
    ok(pl.own.insert == nil, 'and `insert` is NOT one of its OWN members — this is the trap')
    ok(pl.all.insert == true, 'the closure supplies it; without this `player` false-zeroes')

    -- the shape a real mod uses on `player`, from the corpus that motivated this
    local ev = cm.match({ insert = 3, print = 2, character = 1, index = 1 }, t)
    eq('determined', ev.outcome, 'the observed shape determines a single class')
    eq('LuaPlayer', ev.class, 'and it is LuaPlayer')
    eq(4, ev.n, 'the discriminating quantity `n` rides in the evidence')

    -- THE NEGATIVE CONTROL: the same query with closure removed must fail, so this
    -- spec cannot pass for a reason other than the closure working.
    local flat = { n = t.n, order = t.order, classes = {} }
    for name, c in pairs(t.classes) do flat.classes[name] = { own = c.own, all = c.own } end
    local ev2 = cm.match({ insert = 3, print = 2, character = 1, index = 1 }, flat)
    eq('zero', ev2.outcome, 'own-members-only really does zero out `player` (the fence is live)')
end)

test('classmatch: the free answer key — 9/9 contain the declared class, 8/9 unique', function ()
    local t = ct()
    local rows, sum = cm.answer_key(t)
    ok(rows ~= nil, 'the answer key runs: ' .. tostring(sum))
    eq(9, sum.n, 'global2class declares 9 (base -> class) pairs')
    eq(sum.n, sum.contains, 'SOUNDNESS: every declared class survives its own shape')
    eq(8, sum.unique, 'PRECISION: 8 of 9 resolve uniquely')
    local by = {}
    for _, r in ipairs(rows) do by[r.base] = r end
    eq('LuaGameScript', by.game.ev.class, 'game determines LuaGameScript')
    eq('ambiguous', by.rcon.ev.outcome, 'rcon is the one that does NOT — and it says so')
    ok(by.rcon.ev.ncand > 1, ('rcon is shared by %d classes'):format(by.rcon.ev.ncand))
    ok(by.rcon.contains, 'and the true class is still IN the candidate set (never dropped)')
end)

test('classmatch: determined / ambiguous / no-class / no-shape render differently', function ()
    local t = ct()
    local det = cm.match({ get_surface = 1 }, t)             -- 1 class declares it
    local amb = cm.match({ print = 1 }, t)                   -- 5 do
    local zero = cm.match({ definitely_not_an_api_name = 1, nor_this_one = 1 }, t)
    local none = cm.match({}, t)                             -- bare calls only

    eq('determined', det.outcome, 'a unique match is determined')
    eq('ambiguous', amb.outcome, 'a shared shape is ambiguous')
    ok(amb.ncand > 1, 'ambiguous carries its candidate LIST')
    eq('zero', zero.outcome, 'an unmatchable shape is its own answer, not a failure')
    eq('no-shape', none.outcome,
        'an EMPTY shape must not match all 148 classes by vacuous subset')
    eq(0, none.ncand, 'and it claims no candidates at all')

    local ld, la, lz, ln = cm.line(det), cm.line(amb), cm.line(zero), cm.line(none)
    ok(ld:find('LuaGameScript', 1, true), 'determined names the class: ' .. ld)
    ok(la:find('AMBIGUOUS', 1, true) and la:find('LuaRCON', 1, true),
        'ambiguous shows the candidates: ' .. la)
    ok(lz:find('NO CLASS declares this shape', 1, true),
        'no-class says exactly that: ' .. lz)
    ok(not lz:find('AMBIGUOUS', 1, true) and ld ~= la and la ~= lz and lz ~= ln,
        'the four outcomes are four different renderings')

    -- the DISTANCE is what makes zero-match useful: 66 of 74 zero-match bases in
    -- the corpus are UNRELATED to every class, i.e. mod-local tables, and the tail
    -- depends on telling those from a near miss
    eq(false, zero.overlap, 'nothing in the API shares even one of those names')
    eq(nil, zero.distance, 'so there is no meaningful distance to report')
    ok(cm.unrelated(zero), 'and the base is judged UNRELATED — not an API object')
    local near = cm.match({ insert = 1, definitely_not_an_api_name = 1 }, t)
    eq('zero', near.outcome, 'one bogus member is enough to zero a real shape')
    eq(true, near.overlap, 'but classes DO share `insert`')
    eq(1, near.distance, 'so it is ONE member away — a near miss, not a stranger')
    eq(false, cm.unrelated(near), 'and it is NOT written off as a non-API object')
    ok((near.nearest[1] or {}).shared == 1, 'the nearest class states what it shares')
end)

test('classmatch: "unrelated" is measured among OVERLAPPING classes only', function ()
    local t = ct()
    -- ★ THE NAIVE METRIC IS WRONG AND SILENTLY SO. Minimum-miss over ALL 148
    -- classes calls EVERY single-member zero-match base "one member away", because
    -- a class that shares nothing with the shape still misses only that one name.
    -- Measured on ~/work/factorio-mods: the naive definition put 38 of 74
    -- zero-match bases in the "not an API object" bucket where the recorded premise
    -- run had 66; restricting the distance to classes that share at least one
    -- member reproduces 66 exactly. Same data, same matcher, a metric that quietly
    -- meant something else — so the definition is fenced here.
    local lone = cm.match({ some_name_no_class_declares = 1 }, t)
    eq('zero', lone.outcome, 'a single unknown member matches no class')
    eq(false, lone.overlap, 'and no class shares it')
    ok(cm.unrelated(lone), 'so it is UNRELATED — the naive min-miss would have called'
        .. ' it "1 member away" from some arbitrary class')
    -- THE CORPUS CASE, kept verbatim because it is what exposed the bug: `Log`
    -- (127 calls, a mod-local logger, shape {debug}). Under the naive metric it
    -- printed "nearest LuaAISettings is 1 member away (debug)" — LuaAISettings
    -- shares NOTHING with it; it was merely the alphabetically first of 148
    -- classes all equally 1 miss away. The report read as a near miss of a real
    -- API class. It is a stranger, and now says so.
    local log = cm.match({ debug = 1 }, t)
    eq('zero', log.outcome, 'the mod-local logger matches no class')
    eq(false, log.overlap, 'because no class declares `debug` at all')
    ok(cm.unrelated(log), 'so it is UNRELATED, not "one member from LuaAISettings"')
    ok(cm.line(log):find('NO class shares even one member', 1, true),
        'and the rendering says so instead of naming an unrelated class: ' .. cm.line(log))
end)

test('classmatch: the two known wrong answers stay visible as n=1 hypotheses', function ()
    local t = ct()
    -- `name.find` — `name` is a string, so this is string.find; the class table
    -- knows nothing about Lua strings and answers LuaEquipmentGrid. 1 call in the
    -- corpus. It is a WRONG answer the matcher is expected to give.
    local find = cm.match({ find = 1 }, t)
    eq('determined', find.outcome, 'the matcher does answer (it is not excluded)')
    eq('LuaEquipmentGrid', find.class, 'and the answer is the known-wrong one')
    eq(1, find.n, 'with n=1 in the evidence, which is the reason to distrust it')
    -- `Zone.get_surface` — a mod-local table with an API-looking verb
    local zone = cm.match({ get_surface = 1 }, t)
    eq('LuaGameScript', zone.class, 'the second known wrong')
    eq(1, zone.n, 'also n=1')

    ok(cm.line(find):find('single%-member hypothesis'),
        'the rendering marks a one-member answer as weak: ' .. cm.line(find))
    ok(not cm.line(cm.match({ insert = 1, character = 1, print = 1 }, t))
        :find('single%-member hypothesis'), 'and a multi-member one is not marked')

    -- ★ NO THRESHOLD IN THE QUERY. n and the candidate list are the evidence; the
    -- consumer decides. 47 bases resolve on one member and 27 of the 29 highest-call
    -- ones are RIGHT, so a matcher that dropped n=1 would lose more than it saved.
    eq('inferred', find.tier, 'a determined match rides the `inferred` rung, not `stdlib`')
    ok(tier.RANK[find.tier], 'and that rung exists on the canonical ladder')
    ok(tier.RANK['stdlib'] < tier.RANK[find.tier],
        'which is strictly WEAKER than stdlib — a profile NAMING a symbol is authoritative,'
        .. ' a shape match is a hypothesis')
    ok(find.hedge and find.hedge:find('hypothesis', 1, true),
        'and it carries a stated hedge: ' .. tostring(find.hedge))
end)

test('classmatch: a deep chain matches on its FIRST segment (player.character.insert)', function ()
    local t = ct()
    -- externals hands back the whole remainder of a call chain as the "member", so
    -- `player.character.insert` arrives as `character.insert`. What LuaPlayer
    -- declares is the ATTRIBUTE `character` — matching the raw chain would miss
    -- every deep call, and a methods-only class table would too.
    ok(t.classes.LuaPlayer.all.character, 'attributes are in the class table, not only methods')
    local ev = cm.match({ ['character.insert'] = 1, ['print'] = 1, index = 1 }, t)
    eq('LuaPlayer', ev.class, 'the chain head is what gets matched')
    eq(3, ev.n, 'and the shape counts three distinct members')
end)

test('classmatch: surface-wide query reports outcomes, discrimination and provenance', function ()
    local t = ct()
    -- a synthetic external surface in externals.surface's own shape, so this needs
    -- no corpus: two API receivers, one mod-local table, one bare-only base
    local surf = { bases = {
        player  = { calls = 23, bare = 0, files = { ['a.lua'] = true },
                    members = { insert = 3, print = 2, character = 1, index = 1 } },
        surface = { calls = 18, bare = 0, files = {},
                    members = { find_entities_filtered = 9, create_entity = 4, name = 1 } },
        util    = { calls = 529, bare = 0, files = {},
                    members = { by_pixel = 1, moveposition = 1, formattime = 1 } },
        cb      = { calls = 4, bare = 4, files = {}, members = {} },
    } }
    local rows, sum = cm.of_surface(surf, t)
    ok(rows ~= nil, 'the surface query runs: ' .. tostring(sum))
    eq(4, sum.bases, 'every base is judged')
    local by = {}
    for _, r in ipairs(rows) do by[r.base] = r end
    eq('LuaPlayer', by.player.ev.class, 'player determines LuaPlayer')
    eq('LuaSurface', by.surface.ev.class, 'surface determines LuaSurface')
    eq('zero', by.util.ev.outcome, 'a mod-local table matches NO class — the cheap discriminator')
    eq('no-shape', by.cb.ev.outcome, 'a bare-only base has no shape to match')
    eq(529, sum.calls.zero, 'the census is call-weighted too (zero-match is the biggest pile)')
    ok(rows[1].base == 'util', 'rows are ranked by call volume, the order a reader triages in')

    -- the discrimination table is RECOMPUTED, never quoted: a divergence from the
    -- recorded measurement has to be visible as a finding
    local b3
    for _, b in ipairs(sum.buckets) do if b.n == 3 then b3 = b end end
    ok(b3 ~= nil, 'the n>=3 bucket is reported')
    eq(2, b3.matched, 'two of these bases match at least one class at n>=3')
    eq(2, b3.unique, 'and both are unique')
    ok((sum.meta or {}).artifact and sum.meta.version,
        'the report states WHICH artifact and API version answered')
end)

test('classmatch: an artifact with no class table REFUSES with a reason', function ()
    -- honesty about the input, not a silent empty answer: the 1.1 artifact predates
    -- the class table, and asking it must say so rather than return zero matches
    local t, why = cm.table('lua-factorio-api-11')
    if t then
        ok(t.n > 0, 'the 1.1 artifact has since been re-distilled with a class table')
    else
        ok(why and why:find('class table', 1, true),
            'a classless artifact refuses with a reason naming what is missing: ' .. tostring(why))
    end
    local t2, why2 = cm.table('no-such-runtime-at-all')
    eq(nil, t2, 'an unknown artifact yields no table')
    ok(why2 and why2:find('no-such-runtime-at-all', 1, true),
        'and names what it tried: ' .. tostring(why2))
end)
