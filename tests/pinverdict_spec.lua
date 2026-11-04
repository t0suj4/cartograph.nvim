-- A pin's movement as a VERDICT (CART-0446) — tools/pinverdict.lua. Each case is one the ticket recorded being argued
-- in prose because the count could not say which way it went.
local pv = dofile('tools/pinverdict.lua')

test('verdict: v8 — missing:declaration +156 while both:declaration -156 is LATERAL, not worse (RED IF WEAKENED)', function ()
    local r = pv.classify({ total = 1000, ['missing:declaration'] = 356, ['both:declaration'] = 0 },
        { total = 1000, ['missing:declaration'] = 200, ['both:declaration'] = 156 }, true)
    eq('LATERAL', r.verdict, vim.inspect(r))
    eq({ { 'both:declaration', 'missing:declaration', 156 } }, r.lateral)
    ok(pv.line(r):find('no regression', 1, true))
end)

test('verdict: any class that ROSE beyond a lateral pairing is WEAKENED — a regression', function ()
    local r = pv.classify({ ['binder:if_statement'] = 1044, ['binder:declaration'] = 257 },
        { ['binder:if_statement'] = 1043, ['binder:declaration'] = 472 }, true)
    eq('WEAKENED', r.verdict)
    eq({ { 'binder:if_statement', 1043, 1044 } }, r.weakened)
    eq({ { 'binder:declaration', 472, 257 } }, r.strengthened)
    ok(pv.line(r):find('REGRESSION', 1, true), pv.line(r))
end)

test('verdict: only falls is STRENGTHENED; GONE and new classes count by direction; total is ignored', function ()
    local r = pv.classify({ total = 1, ['binder:for_statement'] = 1 },
        { total = 17, ['binder:expression_statement'] = 13, ['binder:for_statement'] = 2 }, true)
    eq('STRENGTHENED', r.verdict)
    eq(2, #r.strengthened)
    local n = pv.classify({ ['extra:select_statement'] = 5 }, {}, true)
    eq('WEAKENED', n.verdict, 'a NEW class is a rise from 0')
end)

test('verdict: a rise larger than its both-fall is lateral up to the fall, weakened beyond it', function ()
    local r = pv.classify({ ['both:x'] = 0, ['missing:x'] = 10 }, { ['both:x'] = 3, ['missing:x'] = 5 }, true)
    eq('WEAKENED', r.verdict)
    eq({ { 'both:x', 'missing:x', 3 } }, r.lateral)
    eq({ { 'missing:x', 5, 10 } }, r.weakened)
end)

test('verdict: without pairing (dfparity keys) a rise is weakened, and an unchanged pin is SAME', function ()
    eq('WEAKENED', pv.classify({ ['flow-over-collects'] = 52 }, { ['flow-over-collects'] = 48 }).verdict)
    eq('SAME', pv.classify({ a = 1, total = 1 }, { a = 1, total = 9 }).verdict)
end)
