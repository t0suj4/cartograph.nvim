-- The seam onto the proven template algebra (cartograph.algebra, CART-0888).
--
-- These tests do NOT re-test the algebra -- it carries 243 of its own. They
-- guard the three claims the SEAM makes, each of which is a claim about
-- SOMEONE ELSE'S SOURCE and so can rot without anything here changing:
--
--   1. spans ride through `rebuild` and are ignored by `eq`
--   2. the adapter puts discriminants in the KIND, where `eq` looks
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

test('algebra seam: a DIFFERING OPERATOR is not equal (kind, not field)', function ()
    local A = need()
    local plus = A.node(alg.kind_of({ k = 'bin', op = '+' }))
    local minus = A.node(alg.kind_of({ k = 'bin', op = '-' }))
    eq('bin:+', plus.k)
    ok(not A.eq(plus, minus), 'bin:+ and bin:- are distinct to eq')
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
