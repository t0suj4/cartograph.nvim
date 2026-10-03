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
-- ── RUNG 1 (CART-1399): the relations, their hashes and orders, and the LAWS between them ───────────────────────────
local R = require 'cartograph.algebraread'
local AC = { plus = { A = true, C = true } }
local function population()
    local pop = {}
    local function add(t) pop[#pop + 1] = t end
    if pcall(vim.treesitter.get_string_parser, '', 'lua') then
        local t = assert(R.read('local a = f(x, 1) + f(x, 1)\nreturn { a, "1", 1 }\n', 'lua'))
        local function collect(u) add(u); for _, c in ipairs(u.kids or {}) do collect(c) end end
        collect(t)
    end
    -- keyed permutations (term, not ordered)
    add(A.kv_term({ o = { a = '1', b = '2' }, keys = { 'a', 'b' } })); add(A.kv_term({ o = { a = '1', b = '2' }, keys = { 'b', 'a' } }))
    -- renamed holes and renamed presence marks (variant, not term)
    add(A.node('f', A.hole('x'), A.hole('y'), A.hole('x'))); add(A.node('f', A.hole('p'), A.hole('q'), A.hole('p')))
    add(A.node('f', A.hole('x'), A.hole('x'), A.hole('y')))
    local function marked(h) local p = A.node('pair', A.lit('k'), A.lit(1)); p.opt = h; return A.keyed('obj', { p }) end
    add(marked('h1')); add(marked('h9'))
    -- an AC reordering (theory, not term)
    add(A.node('plus', A.lit(1), A.lit(2))); add(A.node('plus', A.lit(2), A.lit(1)))
    -- what the corpus lacked: floats, -0, marks on literals, grammars
    add(A.lit(0.1 + 0.2)); add(A.lit(0.3)); add(A.lit(-0)); add(A.lit(0)); add(A.lit('1')); add(A.lit(1))
    add({ k = 'lit', v = 'b', opt = 'h1' }); add({ k = 'lit', v = 'b', opt = 'h2' }); add(A.lit('b'))
    add({ k = 'embed', g = 'sql', kids = { A.lit('x') } }); add({ k = 'embed', g = 'lua', kids = { A.lit('x') } })
    return pop
end

test('law: each relation holds IFF its hashes agree — every pair of a mixed population, both directions', function ()
    local pop = population()
    local checked = 0
    for _, name in ipairs({ 'ordered', 'term', 'variant', 'theory' }) do
        local r = A.equality(name)
        local param = name == 'theory' and AC or nil
        local h = {}
        for i, t in ipairs(pop) do h[i] = r.hash(t, param) end
        for i = 1, #pop do for j = 1, #pop do
            eq(r.eq(pop[i], pop[j], param), h[i] == h[j], ('%s: %s / %s'):format(name, A.show(pop[i]), A.show(pop[j])))
            checked = checked + 1
        end end
    end
    ok(checked > 2000, checked .. ' pairs')
end)

test('law: ordered => term => variant => equivalent, term => theory — and every implication is STRICT (a witness each way)', function ()
    local pop = population()
    local O, T, V, Th = A.equality('ordered'), A.equality('term'), A.equality('variant'), A.equality('theory')
    local strict = { term_not_ordered = 0, variant_not_term = 0, theory_not_term = 0, variant_pairs = 0 }
    for i = 1, #pop do for j = 1, #pop do
        local a, b = pop[i], pop[j]
        local o, t, v, th = O.eq(a, b), T.eq(a, b), V.eq(a, b), Th.eq(a, b, AC)
        if o then ok(t, 'ordered => term: ' .. A.show(a)) end
        if t then ok(v, 'term => variant: ' .. A.show(a)); ok(th, 'term => theory: ' .. A.show(a)) end
        -- (equivalent's domain: bodies without an embed — instance_of is not reflexive on one, CART-1409)
        local function has_embed(u) if u.k == 'embed' then return true end; for _, c in ipairs(u.kids or {}) do if has_embed(c) then return true end end; return false end
        if v and not has_embed(a) and not has_embed(b) then
            strict.variant_pairs = strict.variant_pairs + 1
            ok(A.equality('equivalent').eq(A.template(a), A.template(b)), 'variant => equivalent: ' .. A.show(a) .. ' / ' .. A.show(b))
        end
        if t and not o then strict.term_not_ordered = strict.term_not_ordered + 1 end
        if v and not t then strict.variant_not_term = strict.variant_not_term + 1 end
        if th and not t then strict.theory_not_term = strict.theory_not_term + 1 end
    end end
    ok(strict.term_not_ordered > 0 and strict.variant_not_term > 0 and strict.theory_not_term > 0, vim.inspect(strict))
    ok(strict.variant_pairs > #pop, 'variant => equivalent was checked on more than the diagonal: ' .. strict.variant_pairs)
    -- the presence mark is renamed WITH the holes: two marks by different names are one variant, and not one term
    local function marked(h) local p = A.node('pair', A.lit('k'), A.lit(1)); p.opt = h; return A.keyed('obj', { p }) end
    ok(V.eq(marked('h1'), marked('h9')) and not T.eq(marked('h1'), marked('h9')), 'a renamed presence mark')
end)

test('law: each ORDER is consistent with its relation (equal => neither sorts first) and total on what it orders', function ()
    local pop = population()
    for _, name in ipairs({ 'ordered', 'term', 'variant' }) do
        local r = A.equality(name)
        for i = 1, #pop do for j = 1, #pop do
            local a, b = pop[i], pop[j]
            if r.eq(a, b) then ok(not r.less(a, b) and not r.less(b, a), name .. ': equal yet ordered')
            else ok(r.less(a, b) ~= r.less(b, a), name .. ': unequal yet unordered') end
        end end
    end
    -- identity orders by type first ("1" and 1 are two objects and two places); nil has one fixed term id
    local I = A.equality('identity')
    ok(I.less('1', 1) ~= I.less(1, '1'), 'a string and a number are ordered')
    eq('nil', A.content_id(nil))
    -- literals: by type, then the canonical text
    local L = A.equality('literal')
    ok(L.eq(A.lit(-0), A.lit(0)) and not L.eq(A.lit(0.1 + 0.2), A.lit(0.3)) and not L.eq(A.lit('1'), A.lit(1)))
end)

test('the TABLE: a memo DECLARES its relation (Lisp :test) — a keyed permutation is one key under term, two under ordered', function ()
    local p = A.kv_term({ o = { a = '1', b = '2' }, keys = { 'a', 'b' } })
    local q = A.kv_term({ o = { a = '1', b = '2' }, keys = { 'b', 'a' } })
    local term, ord = A.table_by('term'), A.table_by('ordered')
    term.put(p, 'x'); ord.put(p, 'x')
    eq('x', term.get(q)); eq(nil, ord.get(q)); eq(1, term.size())
    local v = A.table_by('variant'); v.put(A.node('f', A.hole('a')), 1); eq(1, v.get(A.node('f', A.hole('z'))))
    local id = A.table_by('identity'); id.put(p, 1); eq(nil, id.get(A.copy(p))); eq(1, id.get(p))
    ok(not pcall(A.table_by, 'bisimilar'), 'a relation with no hash cannot key a memo')
    local okn, why = pcall(A.equality, 'nope'); ok(not okn and tostring(why):find('no equality', 1, true), tostring(why))
end)
-- ── RUNG 3 (CART-1401): the stores and memos that keyed on show() — a THIRD equality — key on the relation they mean
test('a store keyed by the TERM relation: values eq tells apart are never one hole (show printed 0.1 + 0.2 as 0.3)', function ()
    local I1, I2 = A.node('f', A.lit(0.1 + 0.2), A.lit(0.3)), A.node('f', A.lit(1), A.lit(1))
    for _, which in ipairs({ 'generalize', 'join' }) do
        local T, V1
        if which == 'generalize' then
            local g = A.generalize({ I1, I2 }); T, V1 = g.template, g.values[1]
        else
            local j = A.join(A.template(I1), I2); T, V1 = j.template, j.left({})
        end
        eq(2, vim.tbl_count(T.holes), which .. ': two pairs, two holes')
        ok(A.eq(A.instantiate(T, V1).term, I1), which .. ': member 1 comes back as itself')
    end
    -- term graphs share by the same relation: two literals by one value and different marks are two nodes
    local G = A.tg_of_term(A.node('f', { k = 'lit', v = 'b', opt = 'h1' }, A.lit('b'), A.lit('b')), { share = true })
    eq(3, vim.tbl_count(G.eqs), 'f, "b"?h1, "b" — the unmarked twins shared, the marked one apart')
end)
-- ── RUNG 4 (CART-1402): the audit's switches — a hand-rolled relation replaced by the family's
test('a PARTIAL variant: rename the holes a caller does not keep (xmpppeer\'s replies: parameters keep their names, the rest o1, o2, …)', function ()
    local t = A.node('f', A.hole('a'), A.hole('P'), A.hole('a'), A.hole('@id'))
    local r = A.rename_holes(t, { keep = function (h) return h == 'P' or h:sub(1, 1) == '@' end, prefix = 'o' })
    eq('(f ?o1 ?P ?o1 ?@id)', A.show(r))
    eq('(f ?v1 ?v2 ?v1 ?v3)', A.show(A.rename_holes(t)), 'with no keep, every name')
end)
-- ── RUNG 5 (CART-1403): TERMS ARE VALUES (EGAL) — measured 2026-10-03: the whole suite under CARTOGRAPH_FREEZE=1 is
-- green (3,926 passed): no operation edits a term in place after its content id was taken
test('terms are values: under the freeze an in-place edit of an OBSERVED term refuses by name; a fresh copy is the caller\'s to edit', function ()
    local was = A.FREEZE
    A.FREEZE = true
    local t = A.node('f', A.lit(1), A.node('g', A.lit(2)))
    A.content_id(t)
    local ok1, why = pcall(A.assert_mutable, t.kids[2], 'test')
    ok(not ok1 and tostring(why):find('terms are values', 1, true), tostring(why))
    ok(pcall(A.assert_mutable, A.copy(t).kids[2], 'test'), 'a copy is owned')
    -- the operations that edit in place do so on their OWN copies: run them over hashed (observed) inputs
    local I1, I2 = A.node('f', A.lit(1), A.node('g', A.lit(2))), A.node('f', A.lit(3), A.node('g', A.lit(2)))
    A.content_id(I1); A.content_id(I2)
    local okr, err = pcall(function ()
        local g = A.generalize({ I1, I2 })
        A.join(A.template(I1), I2)
        A.dig(A.template(I1), { 2 }, 'z')
        A.fill(g.template, next(g.template.holes), A.template(A.lit(9)))
        A.abstract(I1, A.sites(g.template))
        A.kv_generalize({ { o = { a = '1' }, keys = { 'a' } }, { o = { a = '2' }, keys = { 'a' } } }, {})
    end)
    A.FREEZE = was
    ok(okr, tostring(err))
end)
-- ── RUNG 7 (CART-1405): DISTANCES AGREE WITH RELATIONS — tree edit distance matches exact LABELS (node_sym) in order,
-- so a FULL match (the common subforest is both trees whole) is the ORDERED relation, nothing looser or stricter
test('law: tree edit distance 0 <=> ORDERED — Zhang and Tai/JWZ, every pair of the mixed population', function ()
    local pop = population()
    local O = A.equality('ordered')
    local full = { zhang = 0, jwz = 0 }
    for i = 1, #pop do for j = 1, #pop do
        local a, b = pop[i], pop[j]
        local sa, sb = A.size(a), A.size(b)
        local o = O.eq(a, b)
        local z = A.zhang({ a }, { b }).size
        eq(o, z == sa and z == sb, ('zhang: %s / %s'):format(A.show(a), A.show(b)))
        local w = A.jwz({ a }, { b })
        local ws = w.size or (w.alignment and #w.alignment) or 0
        eq(o, ws == sa and ws == sb, ('jwz: %s / %s'):format(A.show(a), A.show(b)))
        if o then full.zhang = full.zhang + 1 end
    end end
    ok(full.zhang > #pop, 'off-diagonal full matches exist: ' .. full.zhang)
end)
-- ── RUNG 6 (CART-1404): MODULO TRIVIA — the code adapter declares its trivia (the parser's extras + whitespace gaps)
test('modulo trivia: two Lua texts that differ only in whitespace and comments are one; a changed token — or whitespace INSIDE a string — is not', function ()
    if not pcall(vim.treesitter.get_string_parser, '', 'lua') then skip 'no lua parser' end
    local Rd = require 'cartograph.algebraread'
    local a = assert(Rd.read('local x = f(1, 2) -- the sum\nreturn x\n', 'lua'))
    local b = assert(Rd.read('local x=f(1,2)\n\n--[[ block ]]\nreturn   x', 'lua'))
    local c = assert(Rd.read('local x = f(1, 3)\nreturn x\n', 'lua'))
    local Tv = A.equality('trivia')
    ok(not A.eq(a, b), 'the premise: as terms they differ')
    ok(Tv.eq(a, b), 'modulo trivia they are one')
    eq(Tv.hash(a), Tv.hash(b), 'and so are their hashes')
    ok(not Tv.eq(a, c) and Tv.hash(a) ~= Tv.hash(c), 'a changed token is not trivia')
    -- ★ whitespace inside a token is CONTENT: the reader marks only its gaps and the parser's extras
    local s1, s2 = assert(Rd.read('x = " "\n', 'lua')), assert(Rd.read('x = "  "\n', 'lua'))
    ok(not Tv.eq(s1, s2), '" " and "  " are two strings')
    ok(Tv.eq(A.copy(a), a), 'term => trivia')
end)
