-- BREAK UP EQUALITY (CART-1398): the algebra's equalities as a named family, each with its hash and its order, and the
-- laws between them. Rung 2 (CART-1400) first: eq's own inconsistencies, PINNED — measured 2026-10-03, the suite let
-- both old behaviours survive a perturbation (P3: a mark on a literal ignored; P4: an embed's grammar ignored).
local A = require('cartograph.algebra').load()
local function lit(v, opt) return { k = 'lit', v = v, opt = opt } end

test('eq: a PRESENCE MARK is identity on every kind — on a literal and a name too (CART-1397)', function ()
    ok(not A.eq(lit('b', 'h1'), lit('b')), 'a marked literal is not its unmarked twin')
    ok(not A.eq(lit('b', 'h1'), lit('b', 'h2')), 'nor one marked by another hole')
    ok(A.eq(lit('b', 'h1'), lit('b', 'h1')))
    ok(not A.eq({ k = 'name', n = 'x', opt = 'h1' }, { k = 'name', n = 'x' }))
    ok(A.content_id(lit('b', 'h1')) ~= A.content_id(lit('b')), 'and the content id follows')
end)

test('eq: an EMBED\'s grammar is identity — one tree parsed as SQL is not the same tree parsed as Lua', function ()
    local inner = A.node('select', A.lit('x'))
    local s, l = { k = 'embed', g = 'sql', kids = { inner } }, { k = 'embed', g = 'lua', kids = { A.copy(inner) } }
    ok(not A.eq(s, l))
    ok(A.eq(s, { k = 'embed', g = 'sql', kids = { A.copy(inner) } }))
    ok(A.content_id(s) ~= A.content_id(l))
end)

test('term graphs carry the same identity (CART-1396): a string is not the number it prints as, a keyed node not a positional one', function ()
    local function bisim(a, b) return (A.tg_bisimilar(A.tg_of_term(a), A.tg_of_term(b))) end
    ok(not bisim(A.node('f', A.lit('1')), A.node('f', A.lit(1))), 'f("1") / f(1)')
    ok(bisim(A.node('f', A.lit(1)), A.node('f', A.lit(1))), 'the known-true half')
    local kv = A.kv_term({ o = { a = '1' }, keys = { 'a' } })
    local pos = A.copy(kv); pos.align = nil
    ok(not bisim(kv, pos), 'alignment is identity')
    eq('f', A.node_sym(A.node('f')), 'a plain node prints as its kind')
    eq('lit:"1"', A.node_sym(A.lit('1'))); eq('lit:1', A.node_sym(A.lit(1)))
end)

test('law: the readable symbol and the hash label agree — one symbol iff one label, over every pair of a mixed population', function ()
    local pop = { A.lit('1'), A.lit(1), A.lit(1.0), A.lit(0.1 + 0.2), A.lit(0.3), A.lit(-0), A.lit(0), A.lit(true), lit('1', 'h1'),
        A.name('x'), { k = 'name', n = 'x', opt = 'h1' }, A.hole('x'), A.hole('x', true), A.node('f'), A.node('g'),
        { k = 'embed', g = 'sql', kids = {} }, { k = 'embed', g = 'lua', kids = {} },
        A.kv_term({ o = { a = '1' }, keys = { 'a' } }), A.keyed('obj', { A.node('pair', A.lit('a'), A.lit(1)) }, { ordered = true }) }
    local pairs_ = 0
    for i = 1, #pop do for j = 1, #pop do
        if pop[i].k then
            eq(A.node_sym(pop[i]) == A.node_sym(pop[j]), A.node_label(pop[i]) == A.node_label(pop[j]), ('%s / %s'):format(A.node_sym(pop[i]), A.node_sym(pop[j])))
            pairs_ = pairs_ + 1
        end
    end end
    ok(pairs_ > 300)
end)
