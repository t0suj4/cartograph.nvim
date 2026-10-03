-- The seam onto the proven template algebra (cartograph.algebra, CART-0888).
--
-- These tests do NOT re-test the algebra -- it carries 243 of its own. They
-- guard the three claims the SEAM makes, each of which is a claim about
-- SOMEONE ELSE'S SOURCE and so can rot without anything here changing:
--
--   1. spans ride through `rebuild` and are ignored by `eq`
--   2. the adapter puts discriminants in the KID LIST, where `eq` also looks
--      (they were in the KIND until CART-0934; a kind can never be a hole)
--   3. an absent algebra is a NAMED answer, never a silent fallback
--
-- (1) is the one that matters most: the header licences carrying source ranges
-- through a model with no notion of text. The day something teaches `eq` a
-- fourth field, that licence is void and every span-carrying result goes quietly
-- wrong -- so it is checked against the LOADED module, not asserted in prose.

local alg = require 'cartograph.algebra'

local function need()
    local ok, why = alg.available()
    if not ok then skip('algebra unavailable: ' .. tostring(why)) end
    return alg.load()
end

test('algebra seam: loads the real module, and says where from', function ()
    local A = need()
    ok(A.generalize ~= nil, 'generalize present')
    ok(A.vertical ~= nil, 'vertical present')
    ok(A.join ~= nil, 'join present')
    ok(A.unify ~= nil, 'unify present')
    local _, why = alg.available()
    ok(why:find('from '), 'reports its declared source: ' .. tostring(why))
end)

--- ★★★ THE SPAN LICENCE. Not "the docs say rebuild carries extra fields" --
--- this runs it.
test('algebra seam: a span survives rebuild and disturbs no comparison', function ()
    local A = need()
    local t = A.node('bin:+', A.name('x'), A.lit('number:1'))
    t.at = { 1, 2, 3, 4 }
    local r = A.rebuild(t, { A.name('y'), A.lit('number:1') })
    ok(r.at ~= nil, 'rebuild carried the span')
    eq(t.at, r.at)

    local u = A.node('bin:+', A.name('x'), A.lit('number:1'))
    u.at = { 9, 9, 9, 9 }
    ok(A.eq(t, u), 'eq ignores the span entirely')
end)

--- ★★★ THE CLAIM, NOT THE ENCODING (CART-0934). This used to assert `plus.k ==
--- 'bin:+'` — the discriminant welded into the kind. It now rides as the first KID,
--- and the claim that MATTERS is unchanged and asserted directly: `eq` compares the
--- kid list, so differing operators stay distinct. ⚠ A field would NOT work: `eq`
--- reads `k`, `v`, `n` and kids only, so an operator in a plain field would make
--- `a + b` and `a - b` compare EQUAL. Both halves are pinned below.
test('algebra seam: a DIFFERING OPERATOR is not equal, and CAN be abstracted',
    function ()
        local A = need()
        local plus = alg.term({ k = 'bin', op = '+',
            l = { k = 'name', n = 'a' }, r = { k = 'name', n = 'b' } })
        local minus = alg.term({ k = 'bin', op = '-',
            l = { k = 'name', n = 'a' }, r = { k = 'name', n = 'b' } })
        ok(not A.eq(plus, minus), 'a differing operator is still distinct to eq')
        eq('bin', plus.k, 'the kind is the bare node kind')
        eq('+', plus.kids[1].n, 'and the operator leads the kid list')
        -- ⚠ THE HALF THE OLD SHAPE COULD NOT DO: they now share a family instead of
        -- collapsing to a bare hole. This is the entire point of the change.
        local p = A.partition({ plus, minus }, { min_fixed = 1 })
        eq(1, #p.families, 'differing operators anti-unify to ONE family')
        ok(p.one_family_admissible, 'and it is admissible on its fixed structure')
        ok(alg.fixed_nodes(p.families[1].template.body) >= 2,
            'the operands survive as fixed structure, not just the hole')
    end)

--- a literal's TYPE is part of its identity, as it is in `expr.key`
test('algebra seam: number 1 and string "1" are distinct literals', function ()
    local A = need()
    local n = alg.term({ k = 'lit', ty = 'number', v = 1 })
    local s = alg.term({ k = 'lit', ty = 'string', v = '1' })
    ok(not A.eq(n, s), 'the literal type rides into the term')
end)

--- mirrors `clones.anti_unify`'s alpha rule: both locals ⇒ no hole
test('algebra seam: locals collapse to one symbol, globals do not', function ()
    local A = need()
    local locals = { a = true, b = true }
    local ta = alg.term({ k = 'name', n = 'a' }, locals)
    local tb = alg.term({ k = 'name', n = 'b' }, locals)
    ok(A.eq(ta, tb), 'two locals are alpha-equivalent')
    local ga = alg.term({ k = 'name', n = 'a' }, {})
    local gb = alg.term({ k = 'name', n = 'b' }, {})
    ok(not A.eq(ga, gb), 'two globals stay distinct')
end)

--- ★★ ABSENCE IS A NAMED ANSWER. A seam that quietly returned a worse answer
--- when its oracle is missing is the exact shape of every
--- guarantee-outside-the-code failure on record. This is exercised IN A PROCESS
--- THAT HAS ALREADY LOADED THE ALGEBRA, which is the only reason it is not
--- vacuous: the disable check deliberately sits in front of the memo.
test('algebra seam: disabled reports a reason and mints nothing', function ()
    need()
    local cfg = require 'cartograph.config'
    local saved = cfg.algebra
    cfg.algebra = false
    local okd, why = alg.available()
    local term = alg.term({ k = 'name', n = 'x' })
    local row = alg.row_term({ lhs = {}, rhs = {} })
    cfg.algebra = saved

    ok(not okd, 'disabled algebra is unavailable')
    ok(tostring(why):find('disabled'), 'and says why: ' .. tostring(why))
    eq(nil, term)
    eq(nil, row)
    ok(alg.available(), 're-enabling restores it without a reload')
end)

--- ★★★ THE ACCESSOR THAT WENT DEAD, PINNED FROM BOTH SIDES.
--- A TEMPLATE is a record `{ body, holes, edits }`; the TERM is `template.body`.
--- A guard written as `template.k == 'hole'` reads nil for EVERY template and so
--- never fires -- which is exactly what happened in tools/familydiff.lua and let
--- a bare-hole "family" be counted as a success (CART-0888).
---
--- ⚠ ASSERTING ONLY THE FALSE SIDE IS HOW THE BUG SURVIVES. A predicate that can
--- never return true passes every "is not collapsed" assertion in the suite, so
--- the TRUE case is the one that has to be pinned.
test('algebra seam: is_collapsed fires on a bare hole, and .k on the template does not', function ()
    local A = need()
    local g = A.generalize({ A.node('alpha', A.name('p')), A.node('beta', A.lit('number:7')) })
    eq(nil, g.template.k)                      -- the trap: nil, silently
    eq('hole', g.template.body.k)              -- the term really is a bare hole
    ok(alg.is_collapsed(g.template), 'is_collapsed sees it')
    eq(0, alg.fixed_nodes(g.template.body))    -- and it shares no fixed structure

    -- the negative side, so the predicate is not simply always true
    local h = A.generalize({ A.node('f', A.name('x')), A.node('f', A.name('y')) })
    ok(not alg.is_collapsed(h.template), 'a shared root is not collapsed')
    ok(alg.fixed_nodes(h.template.body) > 0, 'and it shares fixed structure')
end)

--- ★★ A BARE-HOLE TEMPLATE RETRACTS TO EVERY INSTANCE TRIVIALLY, which is why
--- "the lgg retracts" is NOT evidence that the members are one family. This is
--- the law that made the dead guard's damage invisible.
test('algebra seam: retraction alone does not witness a family', function ()
    local A = need()
    local xs = { A.node('alpha', A.name('p')), A.node('beta', A.lit('number:7')) }
    local g = A.generalize(xs)
    for i = 1, #xs do
        local r = A.instantiate(g.template, g.values[i])
        ok(r and A.eq(r.term, xs[i]), 'a COLLAPSED template still retracts to instance ' .. i)
    end
    ok(alg.is_collapsed(g.template),
        'so retraction and collapse are true at once — only fixed_nodes separates them')
end)

--- ★★★ `preserved_nodes` EXISTS BECAUSE `fixed_nodes` IS NOT AN ADMISSIBILITY TEST
--- FOR A CONTEXT-VARIABLE TEMPLATE (CART-0934). `A.vertical` returns a hole that
--- CARRIES the arguments both sides shared; `fixed_nodes` returns 0 at a hole
--- without descending, so it scores a real generalization and a vacuous one alike.
---
--- ⚠ THE NEGATIVE HALF IS THE POINT. Three positives alone looked like a clean win
--- and were not: the measure that "worked" on them admitted every unrelated pair
--- too. Both directions are pinned below, and the third test pins the FAILURE of
--- the old measure — if `fixed_nodes` ever starts separating these, this measure
--- is redundant and should be deleted rather than kept out of habit.
local function vert_body(a, b)
    local A = need()
    local r = A.vertical(A.seq({ a }), A.seq({ b }), {})
    local T = r.templates and r.templates[1]
    return T and (T.body or T)
end

test('algebra seam: preserved_nodes counts what a context hole carries', function ()
    local A = need()
    -- the measured shape: {k='hole', ctx=true, kids={{k='name', n='a'}}}
    local body = vert_body(A.node('field.foo', A.name('a')),
                           A.node('field.bar', A.name('a')))
    ok(body, 'vertical produced a template')
    eq(1, alg.fixed_nodes(body), 'fixed_nodes sees only the seq wrapper')
    eq(2, alg.preserved_nodes(body), 'preserved_nodes also sees the carried argument')
end)

test('algebra seam: preserved_nodes separates real families from vacuous ones',
    function ()
        local A = need()
        local N, L, D = A.name, A.lit, A.node
        -- POSITIVE: shares structure the lgg cannot express (kind-welded discriminants)
        local pos = {
            { 'field selector', D('field.foo', N 'a'), D('field.bar', N 'a') },
            { 'operator', D('bin:+', N 'a', N 'b'), D('bin:-', N 'a', N 'b') },
            { 'operator, big arms', D('bin:+', D('call', N 'f', N 'x'), N 'b'),
                D('bin:-', D('call', N 'f', N 'x'), N 'b') },
        }
        -- NEGATIVE: shares NOTHING. Each must land on the wrapper alone.
        local neg = {
            { 'unrelated', D('call', N 'FOO'), D('bin:*', N 'zzz', L 'num:9') },
            { 'bare names', N 'alpha', N 'omega' },
            { 'deep unrelated', D('while', D('cmp:<', N 'i', N 'n'), N 'body'),
                D('return', D('call', N 'QQQ', L 'str:x')) },
        }
        for _, c in ipairs(pos) do
            local p = alg.preserved_nodes(vert_body(c[2], c[3]))
            ok(p >= 2, ('%s must be admissible, preserved=%d'):format(c[1], p))
        end
        for _, c in ipairs(neg) do
            local p = alg.preserved_nodes(vert_body(c[2], c[3]))
            eq(1, p, ('%s must score the wrapper ALONE'):format(c[1]))
        end
    end)

--- ★ AND THE MEASURE IS MONOTONE IN SHARED MATERIAL, so it ranks as well as admits.
--- A threshold-only measure would pass the two tests above and still be useless for
--- choosing BETWEEN candidate families, which is what donor enumeration needs.
test('algebra seam: preserved_nodes rises with the material actually shared',
    function ()
        local A = need()
        local N, D = A.name, A.node
        local small = alg.preserved_nodes(vert_body(
            D('bin:+', N 'a', N 'b'), D('bin:-', N 'a', N 'b')))
        local big = alg.preserved_nodes(vert_body(
            D('bin:+', D('call', N 'f', N 'x'), N 'b'),
            D('bin:-', D('call', N 'f', N 'x'), N 'b')))
        ok(big > small,
            ('bigger shared arms must score higher: %d vs %d'):format(big, small))
        -- ⚠ AND fixed_nodes MUST STILL BE FLAT ACROSS THEM — the reason this exists.
        eq(alg.fixed_nodes(vert_body(D('bin:+', N 'a', N 'b'), D('bin:-', N 'a', N 'b'))),
            alg.fixed_nodes(vert_body(D('bin:+', D('call', N 'f', N 'x'), N 'b'),
                D('bin:-', D('call', N 'f', N 'x'), N 'b'))),
            'fixed_nodes cannot tell them apart, which is why preserved_nodes exists')
    end)

--- ★★★ `pair_family` IS THE PAIRWISE FAMILY SELECTOR (CART-0934) — `A.vertical` for
--- the generalizer, `preserved_nodes` for admissibility. It exists because
--- `mdl.family_of` hard-codes BOTH the first-order lgg and `fixed_nodes`, and neither
--- can be swapped. ⚠ It is a SECOND selector beside `partition` and must not outlive
--- that; the exit condition is written beside the function.
local function fld(sel, base) return { k = 'field', n = sel, b = { k = 'name', n = base } } end
local function bin(op, l, r)
    return { k = 'bin', op = op, l = { k = 'name', n = l }, r = { k = 'name', n = r } }
end

test('algebra seam: pair_family admits shared structure and refuses the wrapper',
    function ()
        need()
        -- POSITIVE: exactly the shapes the welded kind could not abstract at all
        local ok1, i1 = alg.pair_family(alg.term(fld('foo', 'a')), alg.term(fld('bar', 'a')))
        ok(ok1, 'a differing selector over a shared base is a family')
        ok(i1.preserved >= 3, 'the field kind AND the base survive: ' .. i1.preserved)
        local ok2, i2 = alg.pair_family(alg.term(bin('+', 'a', 'b')),
            alg.term(bin('-', 'a', 'b')))
        ok(ok2, 'a differing operator over shared arms is a family')
        ok(i2.preserved >= 4, 'the bin kind AND both arms survive: ' .. i2.preserved)

        -- NEGATIVE: nothing shared. Each must land on the wrapper ALONE and REFUSE.
        local ok3, i3 = alg.pair_family(
            alg.term({ k = 'call', f = { k = 'name', n = 'FOO' }, a = {} }),
            alg.term(bin('*', 'zzz', 'q')))
        ok(not ok3, 'unrelated terms are refused')
        eq(1, i3.preserved, 'and score the wrapper alone')
        ok(i3.why and i3.why:find('wrapper'), 'the refusal says why: ' .. tostring(i3.why))
        local ok4 = alg.pair_family(alg.term({ k = 'name', n = 'alpha' }),
            alg.term({ k = 'name', n = 'omega' }))
        ok(not ok4, 'two bare names are refused')
    end)

--- ★★ THE MIXED PAIR IS THE CALIBRATION, and it is why the floor is a PARAMETER.
--- `a.foo` vs `b.bar` shares only the node KIND — both are field accesses, nothing
--- else survives. At the default floor of 2 that is ADMITTED, which is the weakest
--- admission the measure can make. A caller who wants a shared OPERAND too must say
--- so; the default is not a judgement that kind-alone is enough for every use.
test('algebra seam: pair_family floor decides the weakest admission', function ()
    need()
    local a, b = alg.term(fld('foo', 'a')), alg.term(fld('bar', 'b'))
    local ok2, i2 = alg.pair_family(a, b)                 -- default floor = 2
    ok(ok2, 'kind-alone is admitted at the default floor')
    eq(2, i2.preserved, 'and it preserves exactly the wrapper + the kind')
    local ok3 = alg.pair_family(a, b, { floor = 3 })      -- demand an operand too
    ok(not ok3, 'a caller demanding more than the kind can refuse it')
    -- ⚠ AND THE FLOOR MUST NEVER BE 1: that is the wrapper, so it admits everything.
    local okall = alg.pair_family(alg.term({ k = 'name', n = 'alpha' }),
        alg.term({ k = 'name', n = 'omega' }), { floor = 1 })
    ok(okall, 'floor 1 admits even two bare names — the trap, pinned so it stays visible')
end)

--- ★★★ THE CASE THAT DISTINGUISHES THE TWO MEASURES, and the reason `pair_family`
--- uses `preserved_nodes` rather than `fixed_nodes`. ⚠ WITHOUT THIS TEST THE CHOICE
--- IS UNGUARDED: swapping in `fixed_nodes` passed every other test in this file,
--- because reification made most templates align STRUCTURALLY — the shared material
--- becomes genuinely fixed and the two measures agree. They part company only where
--- `vertical` still emits a CONTEXT hole, i.e. where one side nests what the other
--- leaves bare.
test('algebra seam: a context hole is where the two measures part', function ()
    local A = need()
    local nm = function (n) return { k = 'name', n = n } end
    -- `f(x) + b` vs `x + b` — same operator, same second operand, first operand
    -- WRAPPED. vertical keeps the bin and `b`, and holes the wrapper as a context
    -- variable APPLIED TO `x`: (seq (bin + ?X1(x) b)).
    local wrapped = alg.term({ k = 'bin', op = '+',
        l = { k = 'call', f = nm 'f', a = { nm 'x' } }, r = nm 'b' })
    local bare = alg.term({ k = 'bin', op = '+', l = nm 'x', r = nm 'b' })
    local r = A.vertical(A.seq({ wrapped }), A.seq({ bare }), {})
    local body = r.templates[1].body
    ok(alg.preserved_nodes(body) > alg.fixed_nodes(body),
        ('the carried argument is invisible to fixed_nodes: %d vs %d')
            :format(alg.preserved_nodes(body), alg.fixed_nodes(body)))

    -- ★ AND HERE THE MEASURE CHANGES THE VERDICT, not just the score. `f(a)` and
    -- `a.foo` share only `a`; vertical says "some unary context applied to a", which
    -- is exactly what a helper taking `a` would be. fixed_nodes scores 1 — the
    -- wrapper — and would REFUSE it; preserved_nodes scores 2 and admits.
    local okp, info = alg.pair_family(
        alg.term({ k = 'call', f = nm 'f', a = { nm 'a' } }),
        alg.term({ k = 'field', n = 'foo', b = nm 'a' }))
    ok(okp, 'a shared operand under differing contexts is a family')
    eq(2, info.preserved, 'preserved counts the carried argument')
    eq(1, alg.fixed_nodes(info.template),
        'fixed_nodes sees only the wrapper — swapping it in would refuse this pair')
end)

--- ★★★ THE REGRESSION THIS FILE COULD NOT HAVE CAUGHT (CART-0937). Every other
--- `pair_family` test above builds SMALL hand-made terms, and `vertical`'s DEFAULT
--- alignment handles those fine — so the suite was green while the function refused
--- essentially every real function body.
---
--- The terms below are the REAL dataflow terms of `ts.flow_stop` (13 rows) and
--- `expr.lua`'s `LOCALDECL_OF.__index` (10 rows), frozen as literals so the test
--- does not depend on the tree's current content. ⚠ SIZE ALONE DOES NOT REPRODUCE
--- IT: a synthetic 11-row pair differing by one clean insertion is handled by the
--- default, because LCS still finds an ADMISSIBLE alignment. It takes real scattered
--- divergence, which is why the fixture is measured rather than invented.
local function dfrow(A, dc, ...) return A.node('row', A.name(dc), A.seq({ ... })) end

test('algebra seam: pair_family handles REAL-SIZED terms, which the default cannot',
    function ()
        local A = need()
        local F, I = A.name 'free', A.name 'inner'
        local R = function (dc, ...) return dfrow(A, dc, ...) end
        local q = A.seq({
            R('fresh', F, F, F), R('fresh', I, F), R('fresh'),
            R('none', F, F, F), R('none', F, F, F), R('none', I, F),
            R('none', F, F, F, F, F), R('none', F, F, F, F, F), R('none', I, F),
            R('none', F, F, I), R('none', F, F, I), R('none', I, F), R('none', I) })
        local t = A.seq({
            R('fresh', F, F, F), R('fresh'),
            R('none', F, F, F), R('none', F, F, F), R('none', I, F),
            R('none', F, F, I, F), R('none', F, F, I, F), R('none', I, F),
            R('none', F, F, F, I), R('none', I) })

        -- ⚠ THE DEFAULT STRATEGY RETURNS A SILENT EMPTY HERE: candidates = 0 with
        -- truncated = false and budget_refusals = 0. Pinned so that the reason
        -- `skeleton = 'zhang'` is passed cannot be quietly removed as redundant.
        -- ★ If this half ever FAILS, the vendored default improved — check before
        -- deleting anything; that is good news, not a broken test.
        local d = A.vertical(A.seq({ q }), A.seq({ t }), {})
        eq(0, d.candidates or 0,
            'the DEFAULT alignment still finds no admissible alignment at this size')

        -- ⚠ NOT `local ok` — that shadows the `ok` assertion in this harness.
        local admitted, info = alg.pair_family(q, t, { floor = 2 })
        ok(admitted, 'pair_family admits the pair: ' .. tostring(info.why))
        ok(info.preserved >= 40,
            'and preserves most of it (measured 55 of 57): ' .. tostring(info.preserved))
    end)

--- ── the classifier that reads the lgg's holes back (CART-0939) ──────────────
---
--- ★★★ THESE GUARD A MIGRATION, NOT A FEATURE. `M.hole_kind` and `M.hole_sites`
--- exist so `clones.anti_unify` can be replaced by `A.generalize` without its three
--- callers noticing; they are the half that turns uniform holes back into
--- cartograph's vocabulary. Each test below is a case the first cut got WRONG on
--- real code, so none of them is a restatement of the implementation.

test('algebra seam: a discriminant hole is told from an ordinary child BY POSITION',
    function ()
        local A = need()
        -- ⚠ THE CASE THAT BROKE THE FIRST CUT, from `slice / slice` in our own tree:
        -- `at.sl(a)` against `atr.sl(a)`. A field term is `field(name:selector, base)`
        -- and BOTH children are names, so keying on the parent kind alone called the
        -- differing BASE a `field` hole. It is a `name` hole; only kid 1 is the
        -- selector.
        eq('field', alg.hole_kind(A.name 'sl', A.name 'sc', 'field', 1),
            'kid 1 under a field IS the selector')
        eq('name', alg.hole_kind(A.name 'at', A.name 'atr', 'field', 2),
            'kid 2 under a field is the BASE, an ordinary name')
        eq('operator', alg.hole_kind(A.name '+', A.name '-', 'bin', 1),
            'kid 1 under a bin is the reified operator')
        eq('name', alg.hole_kind(A.name 'x', A.name 'y', 'bin', 2),
            'kid 2 under a bin is an operand')
    end)

test('algebra seam: a local facing a global is a REFUSAL, not a name hole', function ()
    local A = need()
    -- `M.term` collapses every local to one sentinel, so two locals are equal and
    -- never reach the classifier at all; one local against one global is the
    -- `localglobal` struct hole that makes `anti_unify` return false.
    eq('struct', alg.hole_kind(A.name '\1local', A.name 'GLOBAL', nil, 2))
    eq('struct', alg.hole_kind(A.name 'GLOBAL', A.name '\1local', nil, 2))
    eq('name', alg.hole_kind(A.name 'A', A.name 'B', nil, 2),
        'two globals are a plain name hole')
    eq('literal', alg.hole_kind(A.lit 'str:a', A.lit 'str:b', nil, 2))
    eq('struct', alg.hole_kind(A.lit 'str:a', A.name 'b', nil, 2),
        'differing kinds are structural')
    eq('struct', alg.hole_kind(A.node('call', A.name 'f'), A.node('call', A.name 'g'), nil, 2),
        'two differing subtrees are structural, not a value')
end)

test('algebra seam: a hole SITE takes its span from the instance, not the value map',
    function ()
        local A = need()
        -- ⚠ THE LGG IS NON-LINEAR: one hole name stands at every position whose value
        -- tuple is equal. Reading `values[1][h].at` therefore gives every site of
        -- that hole THE SAME span -- measured as `field@2267:27-2267:29 x4`, one span
        -- with a multiplicity. Zipping against the instance gives each site the span
        -- of the subterm actually standing there.
        local function at(l) return { start = { line = l, char = 0 },
            ['end'] = { line = l, char = 3 } } end
        local a1, a2 = A.name 'x', A.name 'y'
        a1.at, a2.at = at(1), at(2)
        local b1, b2 = A.name 'p', A.name 'q'
        b1.at, b2.at = at(11), at(12)
        local body = A.node('seq', A.hole 'h1', A.hole 'h1')
        local sites = alg.hole_sites(body, A.node('seq', a1, a2), A.node('seq', b1, b2))
        eq(2, #sites, 'ONE hole name, TWO sites')
        eq('h1', sites[1].h); eq('h1', sites[2].h)
        eq(1, sites[1].at.start.line, 'site 1 takes instance A position 1')
        eq(2, sites[2].at.start.line, 'site 2 takes instance A position 2 — NOT the same span')
    end)

test('algebra seam: a site with no value of its own falls back to the enclosing span',
    function ()
        local A = need()
        -- ★ A REIFIED DISCRIMINANT HAS NO NODE, so it has no span -- which is the same
        -- fact our side records as `at_encloses`. It must not come back nil, or an
        -- operator hole would be unkeyable.
        -- ⇒ AND THIS IS WHY THE MIGRATION RECOVERS A SPAN THE WALKER LOSES: a
        -- method-call `field` node is built without one (CART-0940), so `anti_unify`
        -- emits `at_a = nil` where this returns the enclosing call's range.
        local sel = A.name 'foo'                     -- no `.at`, like `M.term` builds
        local outer = A.node('field', sel, A.name 'base')
        outer.at = { start = { line = 7, char = 0 }, ['end'] = { line = 7, char = 9 } }
        local body = A.node('field', A.hole 'h1', A.name 'base')
        local sites = alg.hole_sites(body, outer, outer)
        eq(1, #sites)
        ok(sites[1].at ~= nil, 'the site is keyable')
        eq(7, sites[1].at.start.line, 'and it takes the ENCLOSING field span')
        eq('field', sites[1].pk); eq(1, sites[1].idx)
    end)

-- ★ THE RECURSION PASS EXITS EARLY when no value shares the body's root kind (a
-- match refuses a root kind mismatch) — EXCEPT under an EMBED body, which binds a
-- string by parsing it. That exception is the exit's soundness condition and
-- `generalize` never builds an embed root, so it is pinned here directly.
test('algebra seam: the recursion pass still measures depth under an EMBED body', function ()
    local A = need()
    local T = A.template({ k = 'embed', g = 'sh', kids = { A.hole('h1') } }, { h1 = { domain = A.open() } })
    local S = A.summarize_recursion(T, 'h1', { A.lit('run fast'), A.node('x') })
    eq(2, S.note.distinct_depths, 'the string parses into the body (depth 1), the node does not (0)')
end)

-- ★ A TYPE'S NAME IS A NAME (CART-1412): `new Foo()` against `new Bar()` was NO divergence at all to clones' walker
-- and to this adapter (a bare `type` has no kids); the name now rides as the node's discriminant kid, so it is a
-- `name` hole located at the type node — 379 of 523 foreign pairs on elasticsearch's `common` gained one.
test('algebra seam: two different TYPE names are a name hole at the type node', function ()
    need()
    local at1 = { start = { line = 3, char = 4 }, ['end'] = { line = 3, char = 7 } }
    local at2 = { start = { line = 9, char = 4 }, ['end'] = { line = 9, char = 7 } }
    local okv, hs = alg.anti_unify({ k = 'type', n = 'Foo', at = at1 }, { k = 'type', n = 'Bar', at = at2 })
    eq(true, okv, 'a value divergence, not a shape one')
    eq(1, #hs)
    eq('name', hs[1].kind); eq('Foo', hs[1].a); eq('Bar', hs[1].b)
    eq(3, hs[1].at_a.start.line, 'located at the type node that carries the name')
    local same = select(2, alg.anti_unify({ k = 'type', n = 'Foo' }, { k = 'type', n = 'Foo' }))
    eq(0, #same, 'one type is no divergence')
end)

-- ★ A PRESENCE MARK AT THE ROOT MEANS NOTHING (CART-1413): no node holds the root, so nothing can be absent from it.
-- Written against whichever `match` is installed — the hand-written one here, the DERIVED one under DERIVE=match,
-- which crashed on the template's own body and refused a plain `b` as 'literal "b" vs "b"'.
test('algebra seam: a presence mark on the template ROOT is ignored, by match and instance_of alike', function ()
    local A = need()
    local T = A.template({ k = 'lit', v = 'b', opt = 'h1' })
    local own = A.match(T, T.body)
    eq(true, own.ok, 'the template matches its own body, mark and all')
    eq(true, A.match(T, A.lit('b')).ok, 'and a plain `b`')
    eq(nil, next(A.match(T, A.lit('b')).values or {}), 'binding nothing for the mark')
    eq(false, A.match(T, A.lit('c')).ok, 'a different literal still refuses')
    eq(true, A.instance_of(T, T), 'instance_of is reflexive on it')
end)

-- ★ A MEMBER THAT LACKS AN OPTIONAL PAIR OWES NO VALUE UNDER IT (CART-1395). The VALUE VECTOR is asserted, because
-- no spec read one and DERIVE=generalize stayed green while the derived fold gave {a=1} the neighbour's "x". Written
-- against whichever generalize is installed: the hand-written one here, the fold of join under DERIVE=generalize.
test('algebra seam: generalize owes a member that LACKS an optional pair no value under it', function ()
    local A = need()
    local function O(ps) local o, keys = {}, {}; for _, p in ipairs(ps) do o[p[1]] = p[2]; keys[#keys + 1] = p[1] end; return { o = o, keys = keys } end
    local inst = A.kv_terms({ O{ { 'a', 1 } }, O{ { 'a', 1 }, { 'b', 'x' } }, O{ { 'a', 1 }, { 'b', 'y' } } })
    local g = A.generalize(inst)
    local col
    for h, e in pairs(g.template.holes) do
        if not e.presence then
            col = {}
            for i = 1, 3 do local v = g.values[i][h]; col[i] = v == nil and '⊥' or A.show(v) end
        end
    end
    ok(col, 'there is a value hole under b')
    eq('⊥;"x";"y"', table.concat(col, ';'), 'the member without b owes no value there')
end)

-- ★ A HOLE IS ITS COLUMN (CART-1423): a mark under an optional parent (⊥ where the parent is absent) is not the same
-- hole as a top-level mark that is merely absent there, though the two agree on every other member. The derived fold
-- merged them mid-fold (and gave the top-level one the nested column); against whichever generalize is installed, they
-- stay two. The fixture is the SMALLEST disagreement a random search over 3-member families found.
test('algebra seam: generalize keeps a nested optional mark apart from a top-level one with another column', function ()
    local A = need()
    local function O(ps) local o, keys = {}, {}; for _, p in ipairs(ps) do o[p[1]] = p[2]; keys[#keys + 1] = p[1] end; return { o = o, keys = keys } end
    local inst = A.kv_terms({ O{ { 'a', O{ { 'c', O{} } } } }, O{}, O{ { 'a', O{ { 'a', 1 }, { 'b', 1 } } }, { 'c', 1 } } },
        { keyfield = 'name' })
    local g = A.generalize(inst, { align = 'none' })
    local by_path = {}
    for h, e in pairs(A.sites(g.template)) do
        for _, s in ipairs(e.sites) do
            local c = {}
            for i = 1, 3 do local v = g.values[i][h]; c[i] = v == nil and '⊥' or A.show(v) end
            by_path[table.concat(vim.tbl_map(tostring, s.path), '/')] = { h = h, col = table.concat(c, ';') }
        end
    end
    ok(by_path['c'] and by_path['a/2/a'], 'both marks are holes')
    ok(by_path['c'].h ~= by_path['a/2/a'].h, 'and NOT the same hole')
    eq('(absent);(absent);(present)', by_path['c'].col, 'the top-level mark is ABSENT in the empty member')
    eq('(absent);⊥;(present)', by_path['a/2/a'].col, 'the nested one is ⊥ there: its parent is gone')
end)

-- ★ WHAT GENERALIZE SAYS ABOUT ITS HOLES, NOT ONLY WHERE THEY ARE (CART-1360's drift): a hole's `why`, a keyed node's
-- `order` note and `under_optional` on a column with a gap. The derived fold recorded none of them; the donor suite
-- asserts them, but its baseline under DERIVE=generalize carries two unrelated hedge failures, so a mutation check
-- cannot run there — these assert the same three, against whichever generalize is installed.
test('algebra seam: generalize notes why each hole is one, the keyed order, and a column with a gap', function ()
    local A = need()
    local function P(k, v) return A.node('pair', A.lit(k), v) end
    local function obj(...) local n = A.node('obj', ...); n.align = 'keyed'; return n end
    -- a keyed list whose elements under one key diverge in kind: the whole list is the hole, and it says why
    local function list(...) local n = A.node('list', ...); n.align = 'keyed'; n.key = 'name'; return n end
    local a = list(A.node('c', P('name', A.lit('x'))), A.node('c', P('name', A.lit('y'))))
    local b = list(A.node('c', P('name', A.lit('x'))), A.node('s', P('name', A.lit('y'))))
    local g = A.generalize({ a, b }, {})
    ok(A.is_hole(g.template.body), 'the whole list is the hole')
    eq('alignment', g.notes[g.template.body.h].why)
    -- three members writing their keys in one order: stable, claimed; a permuted one is not stable
    local o = function (x, y) return obj(P('a', A.lit(x)), P('b', A.lit(y))) end
    local g3 = A.generalize({ o(1, 2), o(3, 4), o(5, 6) }, {})
    ok(g3.template.body.order and g3.template.body.order.stable and g3.template.body.order.claimed, 'stable and claimed')
    eq(3, g3.template.body.order.support)
    local g3p = A.generalize({ o(1, 2), o(3, 4), obj(P('b', A.lit(6)), P('a', A.lit(5))) }, {})
    eq(false, g3p.template.body.order.stable, 'a permuted member breaks it')
    -- a value hole under an optional pair: its column has a gap
    local gn = A.generalize({ obj(P('a', A.lit(1))), obj(P('a', A.lit(1)), P('m', A.lit(1))), obj(P('a', A.lit(1)), P('m', A.lit(2))) }, {})
    local valueh
    for h, e in pairs(gn.template.holes) do if not e.presence then valueh = h end end
    ok(valueh and gn.notes[valueh].under_optional, 'the value under the optional pair is marked under_optional')
end)

-- ★ HOLES ARE NAMED AS GENERALIZE MINTS THEM (CART-1360's drift): post-order over the template — a hole leaf when
-- reached, a presence mark after its own subtree. The derived fold numbered by join call (?h3 for a hedge the third
-- member's join minted); against whichever generalize is installed, the names are the canonical ones.
test('algebra seam: generalize names holes in mint order — a hedge ?h1, a mark after the value it guards', function ()
    local A = need()
    local function w(s) local ks = {}; for x in s:gmatch('%S+') do ks[#ks + 1] = A.lit(x) end; return A.node('w', unpack(ks)) end
    local g = A.generalize({ w 'x a b y', w 'x c b d y', w 'x e y' }, { need = 100 })
    eq('(w "x" ?h1... "y")', A.show(g.template.body), 'one hedge, the first hole minted')
    local function O(ps) local o, keys = {}, {}; for _, p in ipairs(ps) do o[p[1]] = p[2]; keys[#keys + 1] = p[1] end; return { o = o, keys = keys } end
    local kv = A.generalize(A.kv_terms({ O{ { 'a', 1 } }, O{ { 'a', 1 }, { 'b', 'x' } }, O{ { 'a', 1 }, { 'b', 'y' } } }))
    eq('(obj[keyed] (pair "a" 1) (?h2:pair "b" ?h1))', A.show(kv.template.body), 'the value under b is h1, its mark h2')
end)

-- ⚠ AN ENVIRONMENT FAULT IS NOT AN ANSWER: a refusal from `anti_unify` would reach
-- `element_template` as `alignable = false`, the same verdict ~70% of real
-- containers earn honestly — so a missing algebra RAISES (CART-0939).
test('algebra seam: anti_unify RAISES when the algebra is unavailable', function ()
    need()
    local load = alg.load
    alg.load = function () return nil end
    local fine, err = pcall(alg.anti_unify, { k = 'lit', v = 1, ty = 'num' }, { k = 'lit', v = 2, ty = 'num' })
    alg.load = load
    eq(false, fine, 'it raises')
    ok(tostring(err):find('not available', 1, true), 'and says why: ' .. tostring(err))
end)
