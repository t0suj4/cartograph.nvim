-- The laws of the (template, holes, values) triplet — held, and deliberately attacked.
-- Run: busted  (from ~/tools/templates)
package.path = './?.lua;' .. package.path
local unpack = unpack or table.unpack
local A = require 'algebra'
local lit, name, node, hole, seq = A.lit, A.name, A.node, A.hole, A.seq

local function is_hole_term(t) return type(t) == "table" and t.k == "hole" end
local function call(f, ...) return node('call', name(f), ...) end
local function show_ok(m) return m.ok or (m.refusal.at .. ': ' .. m.refusal.why) end

-- a poisoned leg: any read raises
local function poisoned(label)
    return setmetatable({}, { __index = function(_, k) error(label .. ' was consulted (.' .. tostring(k) .. ')') end })
end

describe('the triplet and its arrows', function()
    -- T = (call register ?key ?fn)   the registry idiom, one hole per argument
    local T = A.template(call('register', hole 'key', hole 'fn'))
    local V = { key = lit 'on_tick', fn = name 'tick' }
    local I = call('register', lit 'on_tick', name 'tick')

    it('instantiate then match returns the same values', function()
        local i = A.instantiate(T, V)
        assert.is_true(i.ok)
        assert.is_true(A.eq(i.term, I))
        local m = A.match(T, i.term)
        assert.is_true(m.ok)
        assert.is_true(A.values_eq(m.values, V))
    end)

    it('match then instantiate returns the same instance', function()
        local m = A.match(T, I)
        assert.is_true(m.ok)
        assert.is_true(A.eq(A.instantiate(T, m.values).term, I))
    end)

    it('abstract at the holes recovers the template, values_at recovers the values', function()
        local H = A.sites(T)
        local T2 = A.abstract(I, H)
        assert.is_true(A.eq(T2.body, T.body))
        local V2 = A.values_at(I, H)
        assert.is_true(A.values_eq(V2, V))
    end)

    it('an unfilled hole must fail, and says which', function()
        local i = A.instantiate(T, { key = lit 'x' })
        assert.is_false(i.ok)
        assert.are.same({ 'fn' }, i.unfilled)
    end)

    it('a partial substitution leaves a template, and composes', function()
        local T1 = A.apply(T, { key = lit 'k' })
        assert.are.same({ 'fn' }, A.hole_names(T1))
        local both = A.apply(T1, { fn = name 'f' })
        local once = A.apply(T, { key = lit 'k', fn = name 'f' })
        assert.is_true(A.eq(both.body, once.body))
        assert.is_true(A.ground(both.body))
    end)

    it('filling a hole with a template is the same substitution one level up', function()
        local T2 = A.template(node('fn', hole 'body')) -- an anonymous function with a body hole
        local nested = A.fill(T, 'fn', T2)
        assert.are.same({ 'body', 'key' }, A.hole_names(nested))
        local direct = A.instantiate(T, { key = lit 'k', fn = A.instantiate(T2, { body = lit(1) }).term }).term
        local viaFill = A.instantiate(nested, { key = lit 'k', body = lit(1) }).term
        assert.is_true(A.eq(direct, viaFill))
    end)
end)

describe('ATTACK 1: the holes leg is positional, not by value', function()
    -- (add ?a ?b) with a = b = 1: identity by site survives; identity by value cannot
    local T = A.template(node('add', hole 'a', hole 'b'))
    local V = { a = lit(1), b = lit(1) }
    local I = A.instantiate(T, V).term

    it('match still tells the two holes apart because holes are sites', function()
        local m = A.match(T, I)
        assert.is_true(m.ok)
        assert.is_true(A.values_eq(m.values, V))
    end)

    it('but sites are NOT derivable from (instance, values): locate is ambiguous', function()
        local cands, ambiguous = A.locate(I, V)
        assert.is_true(ambiguous)
        assert.are.same({ '1', '2' }, cands.a)
        assert.are.same({ '1', '2' }, cands.b)
    end)

    it('so abstract needs H (sites), and with H it is exact', function()
        local H = { a = { sites = { { path = { 1 } } }, domain = A.open() },
            b = { sites = { { path = { 2 } } }, domain = A.open() } }
        assert.is_true(A.eq(A.abstract(I, H).body, T.body))
    end)

    it('a non-linear template (same hole twice) checks equality across its sites', function()
        local Tn = A.template(node('eq', hole 'x', hole 'x'))
        assert.is_true(A.match(Tn, node('eq', lit(1), lit(1))).ok)
        local m = A.match(Tn, node('eq', lit(1), lit(2)))
        assert.is_false(m.ok)
        assert.matches('already bound', m.refusal.why)
    end)
end)

describe('generalize: the lgg over a pair, and the pair shape', function()
    local Ia = call('register', lit 'on_tick', name 'tick')
    local Ib = call('register', lit 'on_load', name 'load')

    it('anti-unification yields a template both are instances of', function()
        local g = A.generalize { Ia, Ib }
        assert.equals('(call register ?h1 ?h2)', A.show(g.template.body))
        assert.is_true(A.match(g.template, Ia).ok)
        assert.is_true(A.match(g.template, Ib).ok)
    end)

    it('THE DONOR IS instantiate(T, V_a): the pair shape lacks nothing but the body', function()
        local g = A.generalize { Ia, Ib }
        -- both "donors" are derived, not chosen
        assert.is_true(A.eq(A.instantiate(g.template, g.values[1]).term, Ia))
        assert.is_true(A.eq(A.instantiate(g.template, g.values[2]).term, Ib))
        -- and the body itself is recoverable from (H, I_a) alone: the pair shape (holes with
        -- sites, a-values, b-values) plus either instance IS a matchable template
        local H = A.sites(g.template)
        assert.is_true(A.eq(A.abstract(Ia, H).body, g.template.body))
    end)

    it('equal divergent tuples share a hole (this is where non-linear templates come from)', function()
        local g1 = A.generalize { node('f', lit(1), lit(1)), node('f', lit(2), lit(2)) }
        assert.equals('(f ?h1 ?h1)', A.show(g1.template.body))
        local g2 = A.generalize { node('f', lit(1), lit(2)), node('f', lit(2), lit(1)) }
        assert.equals('(f ?h1 ?h2)', A.show(g2.template.body))
    end)

    it('is the JOIN: least among the templates both instances fit', function()
        local g = A.generalize { Ia, Ib }
        -- the lgg of two literals is "a literal": the hole carries its kind
        assert.equals('{lit}', A.show_domain(g.template.holes.h1.domain))
        assert.equals('{name}', A.show_domain(g.template.holes.h2.domain))
        local same = A.template(call('register', hole 'k', hole 'f'), { k = A.kinds { 'lit' }, f = A.kinds { 'name' } })
        local wider = A.template(call('register', hole 'k', hole 'f')) -- open holes
        local widest = A.template(node('call', hole 'callee', hole 'k', hole 'f'))
        assert.is_true(A.instance_of(g.template, same) and A.instance_of(same, g.template))
        assert.is_true(A.instance_of(g.template, wider))
        assert.is_false(A.instance_of(wider, g.template))
        assert.is_true(A.instance_of(g.template, widest))
        assert.is_false(A.instance_of(widest, g.template))
    end)
end)

describe('the generality order', function()
    local ground = A.template(node('wrap', lit 'x'))
    local open = A.template(node('wrap', hole 'h'))
    local top = A.template(hole 'any')
    local env = { defs = { base = A.template(lit 'x') } }
    local rec = A.template(node('wrap', hole 'h'), { h = A.alt(A.ref 'base', A.ref 'self') })

    it('ground <= recursive <= open <= top, each strictly', function()
        assert.is_true(A.instance_of(ground, rec, env))
        assert.is_false(A.instance_of(rec, ground, env))
        assert.is_true(A.instance_of(rec, open, env))
        assert.is_false(A.instance_of(open, rec, env))
        assert.is_true(A.instance_of(open, top, env))
        assert.is_false(A.instance_of(top, open, env))
    end)

    it('a recursive hole has UNBOUNDED coverage with the claim intact', function()
        local deep = node('wrap', node('wrap', node('wrap', node('wrap', lit 'x'))))
        assert.is_true(A.match(rec, deep, env).ok)
        local m = A.match(rec, node('wrap', node('wrap', lit 'y')), env)
        assert.is_false(m.ok) -- the base is wrong, however deep
        assert.is_true(A.match(open, node('wrap', node('wrap', lit 'y')), env).ok) -- open asserts nothing
    end)

    it('a non-linear template sits below its linear relaxation', function()
        local lin = A.template(node('f', hole 'a', hole 'b'))
        local non = A.template(node('f', hole 'x', hole 'x'))
        assert.is_true(A.instance_of(non, lin))
        assert.is_false(A.instance_of(lin, non))
    end)
end)

describe('ATTACK 2: arity 2 cannot evidence repetition or recursion (CART-0730 in miniature)', function()
    -- (call f <n distinct literals>), the literals differing per instance so that no
    -- column is identical across instances (an identical column is a FIXED part, and the
    -- least general template rightly keeps it fixed)
    local counter = 0
    local function list(n)
        local xs = { name 'f' }
        for _ = 1, n do counter = counter + 1; xs[#xs + 1] = lit(counter) end
        return node('call', unpack(xs))
    end

    it('two lengths (3,4) yield an under-determined struct hole with the rep hypothesis recorded', function()
        local g = A.generalize { list(3), list(4) }
        local h = g.notes.h1
        assert.equals('arity', h.why)
        assert.equals('open', h.claimed)
        assert.is_true(h.under_determined)
        assert.equals(2, h.distinct)
        assert.is_not_nil(h.hypothesis.rep_of) -- recorded, not claimed
    end)

    it('three lengths (3,4,5) yield a repetition hole whose element template is named', function()
        local i3, i4, i5 = list(3), list(4), list(5)
        local g = A.generalize { i3, i4, i5 }
        assert.equals('(call f ?h1...)', A.show(g.template.body))
        assert.equals('rep', g.notes.h1.claimed)
        assert.equals('@h1.elem{0,}', A.show_domain(g.template.holes.h1.domain))
        -- unbounded coverage, claim intact
        assert.is_true(A.match(g.template, list(9), g.env).ok)
        local m = A.match(g.template, node('call', name 'f', lit(1), name 'oops'), g.env)
        assert.is_false(m.ok)
        assert.matches('element 2', m.refusal.why)
        -- and the values are sequences, round-tripping through instantiate
        assert.is_true(A.eq(A.instantiate(g.template, g.values[2], g.env).term, i4))
    end)

    it('a heterogeneous varying middle is never claimed as repetition, at any arity', function()
        local g = A.generalize { node('t', lit(1)), node('t', lit(1), name 'a'), node('t', lit(1), name 'a', node('q')) }
        assert.equals('open', g.notes.h1.claimed)
        assert.is_false(g.notes.h1.homogeneous)
    end)

    local function wrap(n)
        local t = lit 'x'
        for _ = 1, n do t = node('wrap', t) end
        return t
    end

    it('two depths (1,2) say a wrap happened once: under-determined', function()
        local g = A.generalize { wrap(1), wrap(2) }
        assert.equals('(wrap ?h1)', A.show(g.template.body))
        assert.equals('open', g.notes.h1.claimed)
        assert.are.same({ 0, 1 }, g.notes.h1.depths)
        assert.is_true(g.notes.h1.under_determined)
    end)

    it('three depths (1,2,3) yield a recursive hole: base | self', function()
        local g = A.generalize { wrap(1), wrap(2), wrap(3) }
        assert.equals('rec', g.notes.h1.claimed)
        assert.equals('(@h1.base | @self)', A.show_domain(g.template.holes.h1.domain))
        assert.is_true(A.match(g.template, wrap(7), g.env).ok)
        assert.is_false(A.match(g.template, node('wrap', lit 'y'), g.env).ok)
    end)
end)

describe('hole domains: composition, and a grammar as a domain', function()
    it('meet intersects kind sets and is absorbed by open', function()
        local a, b = A.kinds { 'lit', 'name', 'call' }, A.kinds { 'name', 'call', 'bin' }
        assert.equals('{call|name}', A.show_domain(A.meet(a, b)))
        assert.equals('{call|name}', A.show_domain(A.meet(A.open(), A.meet(a, b))))
        assert.is_true(A.entails(A.meet(a, b), a))
        assert.is_false(A.entails(a, b))
    end)

    it('the VOCABULARY rung: a domain bounded to the grammar\'s node kinds', function()
        local go_kinds = A.kinds { 'lit', 'name', 'call', 'bin' } -- stand-in for inspect('go').symbols
        local T = A.template(node('ret', hole 'e'), { e = go_kinds })
        assert.is_true(A.match(T, node('ret', name 'err')).ok)
        local m = A.match(T, node('ret', node('block')))
        assert.is_false(m.ok)
        assert.matches('not in {bin|call|lit|name}', m.refusal.why)
    end)

    it('the STRUCTURE rung: a grammar rule is a recursive domain', function()
        -- expr := lit | name | (bin expr expr)      the shape node-types.json would declare
        local defs = {}
        defs.expr = A.template(hole 'e', { e = A.alt(A.kinds { 'lit', 'name' }, A.ref 'bin') })
        defs.bin = A.template(node('bin', hole 'l', hole 'r'), { l = A.ref 'expr', r = A.ref 'expr' })
        local env = { defs = defs }
        local T = A.template(node('ret', hole 'e'), { e = A.ref 'expr' })
        local deep = node('ret', node('bin', node('bin', lit(1), name 'a'), node('bin', name 'b', lit(2))))
        assert.is_true(A.match(T, deep, env).ok)
        local m = A.match(T, node('ret', node('bin', lit(1), node('call', name 'f'))), env)
        assert.is_false(m.ok)
        assert.matches('call', m.refusal.why)
    end)

    it('composition = intersection: grammar & protocol & profile', function()
        local grammar = A.kinds { 'lit', 'name', 'call' }
        local protocol = A.kinds { 'lit' } -- "a string field"
        local T = A.template(node('set', hole 'v'), { v = A.meet(grammar, protocol) })
        assert.is_true(A.match(T, node('set', lit 'a')).ok)
        assert.is_false(A.match(T, node('set', name 'a')).ok)
    end)
end)

describe('edits as moves in the order', function()
    local T = A.template(call('register', hole 'key', hole 'fn'))
    local I = call('register', lit 'on_tick', name 'tick')

    it('pin narrows: a differing payload now mismatches; open restores', function()
        local P = A.pin(T, 'key', lit 'on_tick')
        assert.is_true(A.match(P, I).ok)
        local m = A.match(P, call('register', lit 'on_load', name 'load'))
        assert.is_false(m.ok)
        assert.matches('pinned', m.refusal.why)
        assert.is_true(A.instance_of(P, T))
        assert.is_false(A.instance_of(T, P))
        local O = A.open_hole(P, 'key')
        assert.is_true(A.instance_of(T, O))
        assert.is_true(A.instance_of(O, T))
        assert.equals('open', O.edits[#O.edits].op)
    end)

    it('open is bounded to previously pinned holes', function()
        local ok, why = A.open_hole(T, 'fn')
        assert.is_nil(ok)
        assert.matches('never pinned', why)
    end)

    it('dig makes a hole where there was none, and needs a SITE to do it', function()
        local D = A.dig(T, { 1 }, 'callee')
        assert.equals('(call ?callee ?key ?fn)', A.show(D.body))
        assert.is_true(A.instance_of(T, D))
        assert.is_false(A.instance_of(D, T))
    end)

    it('merge makes the template non-linear (down); split undoes it (up)', function()
        local Tm = A.merge(A.template(node('f', hole 'a', hole 'b')), 'a', 'b')
        assert.equals('(f ?a ?a)', A.show(Tm.body))
        assert.is_false(A.match(Tm, node('f', lit(1), lit(2))).ok)
        local Ts = A.split(Tm, 'a', 2, 'b')
        assert.equals('(f ?a ?b)', A.show(Ts.body))
        assert.is_true(A.match(Ts, node('f', lit(1), lit(2))).ok)
        assert.are.same({ 'merge', 'split' }, { Ts.edits[1].op, Ts.edits[2].op })
    end)

    it('merge intersects the domains', function()
        local Td = A.template(node('f', hole 'a', hole 'b'),
            { a = A.kinds { 'lit', 'name' }, b = A.kinds { 'name', 'call' } })
        local Tm = A.merge(Td, 'a', 'b')
        assert.equals('{name}', A.show_domain(Tm.holes.a.domain))
    end)
end)

describe('the leave-one-out gate', function()
    local T = A.template(call('register', hole 'key', hole 'fn'))
    local V = { key = lit 'on_tick', fn = name 'tick' }
    local I = call('register', lit 'on_tick', name 'tick')

    it('a coherent triple is unrefuted on all three legs', function()
        local r = A.gate(T, V, I)
        assert.equals('unrefuted', r.verdict)
        assert.are.same({}, r.failed)
    end)

    it('a tampered value leg is refuted, and the failing legs are named', function()
        local r = A.gate(T, { key = lit 'on_load', fn = name 'tick' }, I)
        assert.equals('refuted', r.verdict)
        assert.are.same({ 'instance', 'values' }, r.failed) -- the template leg (H, I) still agrees
    end)

    it('a template with a hole too few: the value with no site is what refutes it', function()
        local T2 = A.template(call('register', hole 'key', name 'tick'))
        local r = A.gate(T2, V, I)
        assert.equals('refuted', r.verdict)
        -- the template leg AGREES: outside its holes T2 says what I says, and H is T2's own
        -- projection, so abstract(I, H) reproduces T2 — that leg tests the FIXED part only
        assert.are.same({ 'instance', 'values' }, r.failed)
        assert.matches('extra: fn', r.instance.why) -- V carries a hole T2 does not have
    end)

    it('a template wrong in its fixed part is caught by the template leg', function()
        local T2 = A.template(call('register', hole 'key', name 'tock'))
        local r = A.gate(T2, { key = lit 'on_tick' }, I)
        assert.are.same({ 'instance', 'values', 'template' }, r.failed)
    end)

    it('VACUITY GUARD: each derivation is blind to the leg it reconstructs', function()
        local H = A.sites(T)
        -- the guarantee is the SIGNATURE: each derivation takes only the two legs it may
        -- read. The excluded leg is passed poisoned in the position it would occupy if the
        -- signature ever grew, so a future read of it raises here.
        local t2 = A.derive.template(H, I, poisoned('T'))
        assert.is_true(A.eq(t2.body, T.body))
        local m = A.derive.values(T, I, nil, poisoned('V'))
        assert.is_true(m.ok)
        local i = A.derive.instance(T, V, nil, poisoned('I'))
        assert.is_true(i.ok)
        -- and the three re-derived legs agree with the originals
        assert.is_true(A.eq(i.term, I) and A.values_eq(m.values, V))
    end)

    it('with a repetition hole the holes leg is INSTANCE-relative: use the sites match reports', function()
        local g = A.generalize { call('f', lit(1), lit(2), lit(3)), call('f', lit(4), lit(5)), call('f', lit(6)) }
        local I3 = call('f', lit(1), lit(2), lit(3))
        local m = A.match(g.template, I3, g.env)
        assert.is_true(m.ok)
        assert.equals(3, m.sites.h1.sites[1].n)
        local r = A.gate(g.template, m.values, I3, g.env, m.sites)
        assert.equals('unrefuted', r.verdict)
        -- T's own sites carry no count, so abstract from them is wrong for this instance
        local r2 = A.gate(g.template, m.values, I3, g.env)
        assert.are.same({ 'template' }, r2.failed)
    end)
end)

-- ── from the survey: Cerna & Kutsia, "Anti-unification and Generalization: A Survey" ──
describe('survey §2: the framework, consistency, and variants', function()
    local I = call('register', lit 'on_tick', name 'tick')
    local Ts = {
        A.template(call('register', hole 'k', hole 'f'), { k = A.kinds { 'lit' }, f = A.kinds { 'name' } }),
        A.template(call('register', hole 'k', hole 'f')),
        A.template(node('call', hole 'c', hole 'k', hole 'f')),
        A.template(hole 'any'),
        A.template(call('register', lit 'on_tick', hole 'f')),
        A.template(call('register', hole 'k', hole 'k')),
    }
    local Os = { I, call('register', lit 'x', name 'y'), call('register', name 'x', name 'x'), node('other') }

    it('Definition 2, consistency: a generalization of O stays one under the preference order', function()
        local checked = 0
        for _, G1 in ipairs(Ts) do
            for _, G2 in ipairs(Ts) do
                for _, O in ipairs(Os) do
                    if A.match(G1, O).ok and A.instance_of(G1, G2) then
                        checked = checked + 1
                        assert.is_true(A.match(G2, O).ok, A.show(G1.body) .. ' <= ' .. A.show(G2.body) .. ' on ' .. A.show(O))
                    end
                end
            end
        end
        assert.is_true(checked > 20)
    end)

    it('the linear variant: no hole twice — element_template vs analyze_pair in one flag', function()
        local pair = { node('f', lit(1), lit(1)), node('f', lit(2), lit(2)) }
        assert.equals('(f ?h1 ?h1)', A.show(A.generalize(pair).template.body))
        assert.equals('(f ?h1 ?h2)', A.show(A.generalize(pair, { linear = true }).template.body))
        -- and the non-linear one is strictly more specific (the preferred one)
        assert.is_true(A.instance_of(A.generalize(pair).template, A.generalize(pair, { linear = true }).template))
        assert.is_false(A.instance_of(A.generalize(pair, { linear = true }).template, A.generalize(pair).template))
    end)
end)

describe('survey §3.4: unranked generalization with an LCS rigidity function', function()
    local function f(...) return node('f', ...) end
    local function g(...) return node('g', ...) end
    local a, b, c = name 'a', name 'b', name 'c'

    it('Example 5: the rigid variant keeps one lgg where the unrestricted problem has three', function()
        local r = A.rigid(g(f(a), f(a)), g(f(a), f()))
        assert.equals(1, #r.templates)
        assert.equals('(g (f a) (f ?X1...))', A.show(r.templates[1].body))
        assert.is_true(A.match(r.templates[1], g(f(a), f(a))).ok)
        assert.is_true(A.match(r.templates[1], g(f(a), f())).ok)
    end)

    it('Example 6: two longest common subsequences, two incomparable lggs — FINITARY', function()
        local H1 = seq { f(a, a), b, f(c), g(f(a), f(a)) }
        local H2 = seq { f(b, b), g(f(a), f()) }
        local r = A.rigid(H1, H2)
        assert.equals(2, #r.templates)
        assert.equals('(seq (f ?x1 ?x1) ?X2... (g (f a) (f ?X3...)))', A.show(r.templates[1].body))
        assert.equals('(seq ?X4... (f ?X5...) (g (f a) (f ?X3...)))', A.show(r.templates[2].body))
        assert.is_false(A.instance_of(r.templates[1], r.templates[2]))
        assert.is_false(A.instance_of(r.templates[2], r.templates[1]))
        for _, T in ipairs(r.templates) do
            assert.is_true(A.match(T, H1).ok and A.match(T, H2).ok, A.show(T.body))
        end
    end)

    it('a differing row inside a body is a hedge hole, not a disqualification', function()
        local body1 = seq { call('open', name 'p'), call('log', lit 'x'), call('close', name 'p') }
        local body2 = seq { call('open', name 'q'), call('close', name 'q') }
        local r = A.rigid(body1, body2)
        assert.equals(1, #r.templates)
        assert.equals('(seq (call open ?x1) ?X2... (call close ?x1))', A.show(r.templates[1].body))
    end)
end)

describe('survey §3.2: the keyed-table fragment of commutative generalization', function()
    local function tb(...) return node('table', ...) end
    local function pr(k, v) return node('pair', lit(k), v) end
    local t1 = tb(pr('a', lit(1)), pr('b', lit(2)), pr('c', lit(3)))
    local t2 = tb(pr('c', lit(3)), pr('a', lit(9)))

    it('positional generalization keeps only the field common to both, as an anchor; key alignment keeps the shared ones by key', function()
        -- ~~'(table ?h1...)'~~ since LCSJOIN.md the shared pair anchors the positional alignment; the pairs around it are two hedges
        assert.equals('(table ?h1... (pair "c" 3) ?h2...)', A.show(A.generalize({ t1, t2 }, { positional = true }).template.body))
        local g = A.generalize { t1, t2 }
        assert.equals('(table (pair "a" ?h1) (pair "c" 3) ?h2...)', A.show(g.template.body))
        assert.equals('{lit}', A.show_domain(g.template.holes.h1.domain))
    end)

    it('the fragment refuses when a key repeats or is not a literal (then it is positional)', function()
        local t3 = tb(pr('a', lit(1)), pr('a', lit(2)))
        assert.is_nil(A.keyed_fields { t3 })
        assert.is_nil(A.keyed_fields { tb(node('pair', name 'k', lit(1))) })
    end)
end)

-- ── Kutsia, Levy, Villaret, "Anti-unification for unranked terms and hedges" (RTA 2011) ──
describe('KLV §4: rigidity functions and the examples', function()
    local function f(...) return node('f', ...) end
    local function g(...) return node('g', ...) end
    local function h(...) return node('h', ...) end
    local a, b, c = name 'a', name 'b', name 'c'
    local X, Y = hole('X', true), hole('Y', true) -- hedge variables IN the inputs

    it('Example 4.4: f(g(a,X),a,X,b) vs f(g(b),b) has one LCS-rigid lgg f(g(Y),Z,b)', function()
        local r = A.rigid(f(g(a, X), a, X, b), f(g(b), b))
        assert.equals(1, #r.templates)
        assert.equals('(f (g ?X1...) ?X2... b)', A.show(r.templates[1].body))
    end)

    it('Example 4.4: the hedges a,b and b,c generalize to X,b,Y', function()
        local r = A.rigid(seq { a, b }, seq { b, c })
        assert.equals('(seq ?X1... b ?X2...)', A.show(r.templates[1].body))
    end)

    it('Example 4.12: two R-generalizations, minimization keeps one, and the store is the diff', function()
        local s1, s2 = f(g(a, a), a, X, b), f(g(b, b), g(Y), b)
        local r = A.rigid(s1, s2)
        assert.equals(2, r.candidates)
        assert.equals(1, #r.templates)
        -- the paper's f(g(U),Z,b), with the term-variable refinement giving g(x,x) for (a,a)/(b,b)
        local T = r.templates[1]
        assert.equals('(f (g ?x1 ?x1) ?X2... b)', A.show(T.body))
        -- the substitutions read off the store reproduce BOTH inputs: donor by law, hedges included
        assert.is_true(A.eq(A.instantiate(T, T.values[1]).term, s1))
        assert.is_true(A.eq(A.instantiate(T, T.values[2]).term, s2))
        -- and the dropped candidate f(V,g(U),Z,b) really is more general (two hedge holes in one list)
        local dropped = A.template(f(hole('V', true), g(hole('U', true)), hole('Z', true), b))
        assert.is_true(A.instance_of(T, dropped))
        assert.is_false(A.instance_of(dropped, T))
    end)

    it('Example 4.5: longest common SUBSTRING rigidity, pure Definition 4.3 vs the refinement', function()
        local s1 = seq { a, a, b, name 'f', name 'f', f(a, a, b) }
        local s2 = seq { a, a, c, name 'f', name 'f', f(a, a, c) }
        local pure = A.rigid(s1, s2, { rigidity = 'substring', refine = false })
        assert.equals('(seq ?X1... f f (f a a ?X2...))', A.show(pure.templates[1].body)) -- the paper's X,f,f,f(a,a,Y)
        local refined = A.rigid(s1, s2, { rigidity = 'substring' })
        assert.equals('(seq ?x1 ?x1 ?x2 f f (f a a ?x2))', A.show(refined.templates[1].body))
        assert.is_true(A.instance_of(refined.templates[1], pure.templates[1]))
    end)

    it('Quiz 2: a strict rigidity function loses structure even on IDENTICAL inputs', function()
        local id1 = seq { f(a, b, c), g(a), h(a) }
        local id2 = seq { f(a, b, c), g(a), h(a) }
        local strict = A.rigid(id1, id2, { rigidity = A.rigidity.lcs_min(3), refine = false })
        assert.equals('(seq (f a b c) (g ?X1...) (h ?X1...))', A.show(strict.templates[1].body)) -- not itself
        local lcs = A.rigid(id1, id2)
        assert.equals('(seq (f a b c) (g a) (h a))', A.show(lcs.templates[1].body))
    end)

    it('the same-position rigidity function reproduces ranked (Plotkin) anti-unification', function()
        local s1, s2 = f(g(a, b), h(a), lit(1)), f(g(c, b), h(c), lit(2))
        local rp = A.rigid(s1, s2, { rigidity = 'positional' })
        -- the paper's remark is about UNSORTED terms; generalize adds kind domains (the
        -- sorted setting the paper lists as future work), so compare with domains erased
        local plotkin = A.template(A.generalize({ s1, s2 }).template.body)
        assert.equals(1, #rp.templates)
        assert.is_true(A.instance_of(rp.templates[1], plotkin) and A.instance_of(plotkin, rp.templates[1]))
    end)

    it('minimization direction: x <= X holds, X <= x and X,X <= X,a fail', function()
        local Tx, TX = A.template(seq { hole 'x' }), A.template(seq { hole('X', true) })
        assert.is_true(A.instance_of(Tx, TX))
        assert.is_false(A.instance_of(TX, Tx))
        local TXX = A.template(seq { hole('X', true), hole('X', true) })
        local TXa = A.template(seq { hole('X', true), a })
        assert.is_false(A.instance_of(TXX, TXa))
    end)

    it('the matcher backtracks over several hedge holes in one list, with a budget', function()
        local T = A.template(seq { hole('X', true), b, hole('Y', true), b, hole('Z', true) })
        local m = A.match(T, seq { a, b, b, c, b, a })
        assert.is_true(m.ok)
        assert.equals(1, m.sites.X.sites[1].n)   -- X = (a)
        assert.equals(0, m.sites.Y.sites[1].n)   -- Y = ()
        assert.equals(3, m.sites.Z.sites[1].n)   -- Z = (c b a)
        local tiny = A.match(T, seq { a, b, b, c, b, a }, { cap = 3 })
        assert.is_false(tiny.ok)
        assert.matches('budget', tiny.refusal.why)
    end)
end)

describe('KLV §5: the Type III clone (Example 5.2)', function()
    local function asg(l, r) return node('=', l, r) end
    local function plus(l, r) return node('+', l, r) end
    local function minus(l, r) return node('-', l, r) end
    local function ge(l, r) return node('>=', l, r) end
    local a, b, d, x = name 'a', name 'b', name 'd', name 'x'
    local c1 = node('if', ge(a, b),
        node('then', asg(name 'c', plus(d, b)), asg(d, plus(d, lit(1)))),
        node('else', asg(name 'c', minus(d, a))))
    local c2 = node('if', ge(name 'm', name 'n'),
        node('then', asg(name 'y', plus(x, name 'n')), asg(name 'z', lit(1)), asg(x, plus(x, lit(5)))),
        node('else', asg(name 'y', minus(x, name 'm'))))

    it('three R-generalizations describe the three ways the added statement can sit', function()
        local r = A.rigid(c1, c2)
        assert.equals(3, #r.templates)
        local shown = {}
        for i, T in ipairs(r.templates) do shown[i] = A.show(T.body) end
        assert.equals('(if (>= ?x1 ?x2) (then (= ?x3 (+ ?x4 ?x2)) (= ?x5 ?x6) ?X7...) (else (= ?x3 (- ?x4 ?x1))))', shown[1])
        assert.equals('(if (>= ?x1 ?x2) (then (= ?x3 (+ ?x4 ?x2)) ?X8... (= ?x4 (+ ?x4 ?x9))) (else (= ?x3 (- ?x4 ?x1))))', shown[2])
        assert.equals('(if (>= ?x1 ?x2) (then ?X10... (= ?x11 ?x12) (= ?x4 (+ ?x4 ?x9))) (else (= ?x3 (- ?x4 ?x1))))', shown[3])
    end)

    it('the paper picks the second by size, and it is the one where the insertion sits between kept rows', function()
        local r = A.rigid(c1, c2)
        local best, bi = -1, nil
        for i, T in ipairs(r.templates) do
            local sz = A.size(T.body)
            if sz > best then best, bi = sz, i end
        end
        assert.equals(2, bi)
        -- every candidate is a genuine generalization of both clones
        for _, T in ipairs(r.templates) do
            assert.is_true(A.match(T, c1).ok and A.match(T, c2).ok)
        end
    end)
end)

-- ── Baumgartner & Kutsia, "Unranked Second-Order Anti-Unification" (WoLLIC 2014) ──
-- Paper notation in comments; zero-arity symbols a, b, c, d are encoded as nodes with
-- no children so that `a` and `a(b,b)` carry the same symbol, as in the paper.
describe('BK §3: admissible alignments', function()
    local function al(...)
        local out = {}
        for _, e in ipairs { ... } do out[#out + 1] = { sym = e[1], I = e[2], J = e[3] } end
        return out
    end

    it('the two witnesses on (a, f(b,c)) vs (f(a,b), c): a two-element and a three-element collision', function()
        -- f<2,1> b<2.1,1.2> c<2.2,2>: f is above c on the left, not on the right
        local ok, why = A.admissible(al({ 'f', { 2 }, { 1 } }, { 'b', { 2, 1 }, { 1, 2 } }, { 'c', { 2, 2 }, { 2 } }))
        assert.is_false(ok); assert.equals('two', why.kind)
        -- a<1,1.1> b<2.1,1.2> c<2.2,2>: b,c are sisters under 2 (uncle a) on the left; a,b under 1 (uncle c) on the right
        ok, why = A.admissible(al({ 'a', { 1 }, { 1, 1 } }, { 'b', { 2, 1 }, { 1, 2 } }, { 'c', { 2, 2 }, { 2 } }))
        assert.is_false(ok); assert.equals('three', why.kind)
    end)

    it('Example 2: the second bullet is not admissible, the third and fourth are', function()
        -- s = (a, a(b,b))   q = (a(a(b(b))), b, b)
        assert.is_false(A.admissible(al({ 'a', { 1 }, { 1 } }, { 'a', { 2 }, { 1, 1 } }, { 'b', { 2, 1 }, { 1, 1, 1 } }, { 'b', { 2, 2 }, { 3 } })))
        assert.is_true(A.admissible(al({ 'a', { 1 }, { 1, 1 } }, { 'b', { 2, 1 }, { 2 } }, { 'b', { 2, 2 }, { 3 } })))
        assert.is_true(A.admissible(al({ 'a', { 2 }, { 1 } }, { 'b', { 2, 2 }, { 1, 1, 1, 1 } })))
    end)
end)

describe('BK §4: the rigid lgg for an admissible alignment, and Theorem 3', function()
    local function f(...) return node('f', ...) end
    local function g(...) return node('g', ...) end
    local function h(...) return node('h', ...) end
    local a, b, c, d = node 'a', node 'b', node 'c', node 'd'
    local function al(...)
        local out = {}
        for _, e in ipairs { ... } do out[#out + 1] = { sym = e[1], I = e[2], J = e[3] } end
        return out
    end
    -- Theorem 3: the store rebuilds both inputs
    local function rebuilds(T, s, q)
        local L, R = A.instantiate(T, T.values[1]), A.instantiate(T, T.values[2])
        return L.ok and R.ok and A.eq(L.term, s) and A.eq(R.term, q)
    end

    it('Example 3 (appendix derivation): f(a,f(b,b)) vs (b, f(a,b), b) -> (z, f(a, Y(b)), z)', function()
        local s, q = seq { f(a, f(b, b)) }, seq { b, f(a, b), b }
        local r = A.vertical(s, q, { alignment = al({ 'f', { 1 }, { 2 } }, { 'a', { 1, 1 }, { 2, 1 } }, { 'b', { 1, 2, 1 }, { 2, 2 } }) })
        local T = r.templates[1]
        assert.equals('(seq ?x1... (f (a) ?X1((b))) ?x1...)', A.show(T.body))
        -- z is ONE variable for the two ε ≜ b pairs (Mer-S); Y absorbs f(◦,b), sibling included
        assert.equals('(seq)', A.show(T.values[1].x1)); assert.equals('(seq (b))', A.show(T.values[2].x1))
        assert.equals('(seq (f ◦ (b)))', A.show(T.values[1].X1)); assert.equals('(seq ◦)', A.show(T.values[2].X1))
        assert.is_true(rebuilds(T, s, q))
    end)

    it('Example 1: (h(a), f(h(g(a,b,b),c),b,b)) vs (a, f(g(a,d),c,d)) -> (X(a), f(X(g(a,x),c),x))', function()
        local s = seq { h(a), f(h(g(a, b, b), c), b, b) }
        local q = seq { a, f(g(a, d), c, d) }
        local r = A.vertical(s, q, { alignment = al({ 'a', { 1, 1 }, { 1 } }, { 'f', { 2 }, { 2 } }, { 'g', { 2, 1, 1 }, { 2, 1 } },
            { 'a', { 2, 1, 1, 1 }, { 2, 1, 1 } }, { 'c', { 2, 1, 2 }, { 2, 2 } }) })
        local T = r.templates[1]
        assert.equals('(seq ?X1((a)) (f ?X1((g (a) ?x1...) (c)) ?x1...))', A.show(T.body))
        assert.equals('(seq (h ◦))', A.show(T.values[1].X1)); assert.equals('(seq ◦)', A.show(T.values[2].X1))
        assert.equals('(seq (b) (b))', A.show(T.values[1].x1)); assert.equals('(seq (d))', A.show(T.values[2].x1))
        assert.is_true(rebuilds(T, s, q))
        -- the word-LCS filter finds exactly this skeleton here
        local sk = A.skeletons(s.kids, q.kids)
        assert.equals(1, sk.candidates); assert.equals(1, #sk.admissible)
    end)

    it('Example 2: two admissible alignments of one pair give two different rigid lggs', function()
        local s, q = seq { a, node('a', b, b) }, seq { node('a', node('a', node('b', b))), b, b }
        local r3 = A.vertical(s, q, { alignment = al({ 'a', { 1 }, { 1, 1 } }, { 'b', { 2, 1 }, { 2 } }, { 'b', { 2, 2 }, { 3 } }) })
        assert.equals('(seq ?X1((a ?x1...)) ?X2((b) (b)))', A.show(r3.templates[1].body)) -- (X(a(x)), Y(b,b))
        assert.is_true(rebuilds(r3.templates[1], s, q))
        local r4 = A.vertical(s, q, { alignment = al({ 'a', { 2 }, { 1 } }, { 'b', { 2, 2 }, { 1, 1, 1, 1 } }) })
        assert.equals('(seq ?x2... (a ?x1... ?X1((b))) ?x3...)', A.show(r4.templates[1].body)) -- (x, a(y, Y(b)), z)
        assert.is_true(rebuilds(r4.templates[1], s, q))
        -- ⚠ the word-LCS filter is NOT the paper's skeleton: every longest word alignment collides
        local sk = A.skeletons(s.kids, q.kids)
        assert.equals(6, sk.candidates); assert.equals(0, #sk.admissible)
    end)

    it('the §4 opener: (a,b,a) vs (b,c) under b<2,1> has two supporting lggs but one rigid one, (x,b,y)', function()
        local s, q = seq { a, b, a }, seq { b, c }
        local r = A.vertical(s, q, { alignment = al({ 'b', { 2 }, { 1 } }) })
        assert.equals('(seq ?x1... (b) ?x2...)', A.show(r.templates[1].body))
        assert.is_true(rebuilds(r.templates[1], s, q))
    end)

    it('the introduction pair f(a,b) vs g(h(a,b)) -> X(a,b), and wrap-in-if -> X(x = 1)', function()
        local s, q = node('f', name 'a', name 'b'), node('g', node('h', name 'a', name 'b'))
        local r = A.vertical(s, q)
        assert.equals(1, #r.templates)
        assert.equals('(seq ?X1(a b))', A.show(r.templates[1].body))
        assert.is_true(rebuilds(r.templates[1], seq { s }, seq { q }))
        local x1 = node('=', name 'x', lit(1))
        local wrapped = node('if', name 'c', node('then', x1))
        local rw = A.vertical(x1, wrapped)
        assert.equals('(seq ?X1((= x 1)))', A.show(rw.templates[1].body))
        assert.equals('(seq (if c (then ◦)))', A.show(rw.templates[1].values[2].X1))
        assert.is_true(rebuilds(rw.templates[1], seq { x1 }, seq { wrapped }))
    end)

    it('a context hole is matched (CTXMATCH.md; it used to be refused by name); a context value must hold exactly one cursor', function()
        local m = A.match(A.template(seq { A.ctx('X', { name 'a' }) }), seq { node('h', name 'a') })
        assert.is_true(m.ok); assert.equals('(seq (h ◦))', A.show(m.values.X))
        local T = A.template(seq { A.ctx('X', { name 'a' }) })
        assert.is_false(A.instantiate(T, { X = seq { A.cursor(), A.cursor() } }).ok)
        assert.is_true(A.instantiate(T, { X = seq { node('h', A.cursor()) } }).ok)
    end)
end)

-- ── Zhang 1995, constrained edit distance — AS PRESENTED IN Bille 2005 §3.4 ──────────
-- The primary was not read (paywalled). The predicate is Bille's statement of Zhang's
-- constraint; the DP is re-derived from it and checked here against brute force.
describe('Zhang (via Bille §3.4): Tai ⊋ admissible ⊋ constrained', function()
    local a, b, c = node 'a', node 'b', node 'c'
    local function f(...) return node('f', ...) end
    local function g(...) return node('g', ...) end
    local function al(...)
        local out = {}
        for _, e in ipairs { ... } do out[#out + 1] = { sym = e[1], I = e[2], J = e[3] } end
        return out
    end
    -- a small deterministic RNG so both runtimes see the same trees
    local function lcg(seed)
        local s = seed
        return function(n) s = (s * 1103515245 + 12345) % 2147483648; return (s % n) + 1 end
    end
    local function rand_tree(rnd, budget) -- one tree of at most `budget` nodes
        local labels = { 'a', 'b', 'c' }
        local t = node(labels[rnd(3)])
        budget = budget - 1
        while budget > 0 and rnd(2) == 1 do
            local kid = rand_tree(rnd, rnd(budget))
            t.kids[#t.kids + 1] = kid
            budget = budget - A.size(kid)
        end
        return t
    end
    -- brute force: the largest label-equal pair set satisfying `pred`
    local function best_mapping(S, Q, pred)
        local wS, wQ = A.word(S), A.word(Q)
        local P = {}
        for _, x in ipairs(wS) do for _, y in ipairs(wQ) do if x.sym == y.sym then P[#P + 1] = { sym = x.sym, I = x.pos, J = y.pos } end end end
        if #P > 12 then return nil end
        local best = 0
        for mask = 0, 2 ^ #P - 1 do
            local sub, bits = {}, mask
            for i = 1, #P do if bits % 2 == 1 then sub[#sub + 1] = P[i] end; bits = math.floor(bits / 2) end
            if #sub > best and pred(sub) then best = #sub end
        end
        return best
    end

    it('witness 1 (BK): (a, f(b,c)) vs (f(a,b), c) under a b c is a Tai mapping that no template supports', function()
        local w = al({ 'a', { 1 }, { 1, 1 } }, { 'b', { 2, 1 }, { 1, 2 } }, { 'c', { 2, 2 }, { 2 } })
        assert.is_true(A.tai_ok(w))
        assert.is_false(A.admissible(w))
        assert.is_false(A.constrained_ok(w))
    end)

    it('witness 2: f(a,b,c) vs f(g(a,b),c) with all four is admissible — f(X(a,b),c) — but NOT constrained', function()
        local w = al({ 'f', { 1 }, { 1 } }, { 'a', { 1, 1 }, { 1, 1, 1 } }, { 'b', { 1, 2 }, { 1, 1, 2 } }, { 'c', { 1, 3 }, { 1, 2 } })
        assert.is_true(A.admissible(w))
        local ok, why = A.constrained_ok(w)
        assert.is_false(ok); assert.equals('nca', why)
        local s, q = f(a, b, c), f(g(a, b), c)
        local v = A.vertical(s, q, { alignment = w })
        assert.equals('(seq (f ?X1((a) (b)) (c)))', A.show(v.templates[1].body))
        local T = v.templates[1]
        assert.is_true(A.eq(A.instantiate(T, T.values[1]).term, seq { s }))
        assert.is_true(A.eq(A.instantiate(T, T.values[2]).term, seq { q }))
        -- the constrained maximum is smaller than the admissible maximum
        assert.equals(3, A.zhang({ s }, { q }).size)
        assert.equals(4, best_mapping({ s }, { q }, A.admissible))
        assert.equals(4, best_mapping({ s }, { q }, A.tai_ok))
    end)

    it('the chain holds on random trees: constrained ⇒ admissible ⇒ Tai (strictness is the two witnesses above)', function()
        local rnd = lcg(7)
        local n_constr, n_adm, n_tai, adm_not_constr, tai_not_adm = 0, 0, 0, 0, 0
        for _ = 1, 60 do
            local S, Q = { rand_tree(rnd, 6) }, { rand_tree(rnd, 6) }
            local wS, wQ = A.word(S), A.word(Q)
            local P = {}
            for _, x in ipairs(wS) do for _, y in ipairs(wQ) do if x.sym == y.sym then P[#P + 1] = { sym = x.sym, I = x.pos, J = y.pos } end end end
            if #P <= 10 then
                for mask = 0, 2 ^ #P - 1 do
                    local sub, bits = {}, mask
                    for i = 1, #P do if bits % 2 == 1 then sub[#sub + 1] = P[i] end; bits = math.floor(bits / 2) end
                    local t, ad, co = A.tai_ok(sub), A.admissible(sub), A.constrained_ok(sub)
                    if co then assert.is_true(ad, 'constrained but not admissible'); n_constr = n_constr + 1 end
                    if ad then assert.is_true(t, 'admissible but not Tai'); n_adm = n_adm + 1 end
                    if t then n_tai = n_tai + 1 end
                    if ad and not co then adm_not_constr = adm_not_constr + 1 end
                    if t and not ad then tai_not_adm = tai_not_adm + 1 end
                end
            end
        end
        -- small random trees rarely populate the gaps; the implications are the claim here
        assert.is_true(n_constr > 100, ('constr=%d adm=%d tai=%d (adm¬constr=%d, tai¬adm=%d)')
            :format(n_constr, n_adm, n_tai, adm_not_constr, tai_not_adm))
    end)

    it('the DP equals the brute-force constrained maximum, and its output is always constrained', function()
        local rnd = lcg(11)
        local checked = 0
        for _ = 1, 40 do
            local S, Q = { rand_tree(rnd, 5) }, { rand_tree(rnd, 5) }
            local oracle = best_mapping(S, Q, A.constrained_ok)
            if oracle then
                local z = A.zhang(S, Q)
                assert.equals(oracle, z.size, A.show(S[1]) .. ' vs ' .. A.show(Q[1]))
                assert.equals(z.size, #z.alignment)
                assert.is_true(A.constrained_ok(z.alignment))
                assert.is_true(A.admissible(z.alignment))
                checked = checked + 1
            end
        end
        assert.is_true(checked > 20)
    end)

    it('the "whole forest under one child" term is needed: f(a,b) vs f(g(a,b)) scores 3, not 2', function()
        assert.equals(3, A.zhang({ f(a, b) }, { f(g(a, b)) }).size)
    end)

    it('BK Example 2: the constrained skeleton has size 2; the paper\'s size-3 admissible one is not constrained', function()
        local S, Q = seq { a, node('a', b, b) }, seq { node('a', node('a', node('b', b))), b, b }
        local paper3 = al({ 'a', { 1 }, { 1, 1 } }, { 'b', { 2, 1 }, { 2 } }, { 'b', { 2, 2 }, { 3 } })
        assert.is_true(A.admissible(paper3))
        assert.is_false(A.constrained_ok(paper3))
        local v = A.vertical(S, Q, { skeleton = 'zhang' })
        assert.equals(2, v.skeletons.size)
        local T = v.templates[1]
        assert.is_true(A.eq(A.instantiate(T, T.values[1]).term, S))
        assert.is_true(A.eq(A.instantiate(T, T.values[2]).term, Q))
    end)
end)

describe('LST01 via Kuboyama 2007: the published definition collapses, the revised one is admissibility', function()
    local a, b, c, d = node 'a', node 'b', node 'c', node 'd'
    local function f(...) return node('f', ...) end
    local function g(...) return node('g', ...) end
    local function e(...) return node('e', ...) end
    local function al(...)
        local out = {}
        for _, x in ipairs { ... } do out[#out + 1] = { sym = x[1], I = x[2], J = x[3] } end
        return out
    end
    local function lcg(seed)
        local s = seed
        return function(n) s = (s * 1103515245 + 12345) % 2147483648; return (s % n) + 1 end
    end
    local function rand_tree(rnd, budget)
        local labels = { 'a', 'b', 'c' }
        local t = node(labels[rnd(3)])
        budget = budget - 1
        while budget > 0 and rnd(2) == 1 do
            local kid = rand_tree(rnd, rnd(budget))
            t.kids[#t.kids + 1] = kid
            budget = budget - A.size(kid)
        end
        return t
    end
    -- every label-equal subset of pairs of two random trees, fed to `visit`
    local function subsets(rnd, rounds, budget, visit)
        for _ = 1, rounds do
            local S, Q = { rand_tree(rnd, budget) }, { rand_tree(rnd, budget) }
            local wS, wQ = A.word(S), A.word(Q)
            local P = {}
            for _, x in ipairs(wS) do for _, y in ipairs(wQ) do if x.sym == y.sym then P[#P + 1] = { sym = x.sym, I = x.pos, J = y.pos } end end end
            if #P <= 10 then
                for mask = 0, 2 ^ #P - 1 do
                    local sub, bits = {}, mask
                    for i = 1, #P do if bits % 2 == 1 then sub[#sub + 1] = P[i] end; bits = math.floor(bits / 2) end
                    visit(sub, S, Q)
                end
            end
        end
    end
    local function best_mapping(S, Q, pred)
        local wS, wQ = A.word(S), A.word(Q)
        local P = {}
        for _, x in ipairs(wS) do for _, y in ipairs(wQ) do if x.sym == y.sym then P[#P + 1] = { sym = x.sym, I = x.pos, J = y.pos } end end end
        if #P > 12 then return nil end
        local best = 0
        for mask = 0, 2 ^ #P - 1 do
            local sub, bits = {}, mask
            for i = 1, #P do if bits % 2 == 1 then sub[#sub + 1] = P[i] end; bits = math.floor(bits / 2) end
            if #sub > best and pred(sub) then best = #sub end
        end
        return best
    end
    local w2 = al({ 'f', { 1 }, { 1 } }, { 'a', { 1, 1 }, { 1, 1, 1 } }, { 'b', { 1, 2 }, { 1, 1, 2 } }, { 'c', { 1, 3 }, { 1, 2 } })
    local fig4b = al({ 'r', { 1 }, { 1 } }, { 'a', { 1, 1, 1 }, { 1, 1 } }, { 'b', { 1, 1, 2 }, { 1, 2 } }, { 'c', { 1, 2 }, { 1, 3 } })

    it('Prop 4.7: the published less-constrained definition (Def 2.70) is the constrained condition, on every random subset', function()
        local rnd, n, n_true = lcg(3), 0, 0
        subsets(rnd, 60, 6, function(sub)
            assert.equals(A.constrained_ok(sub), A.lst_original_ok(sub))
            n = n + 1; if A.constrained_ok(sub) then n_true = n_true + 1 end
        end)
        assert.is_true(n_true > 100 and n > n_true)
    end)

    it('so Bille\'s Figure 4(b) mapping r(p(a,b),c) vs r(a,b,c) is rejected by the definition it illustrates, and by Zhang', function()
        assert.is_false(A.lst_original_ok(fig4b))
        assert.is_false(A.constrained_ok(fig4b))
        assert.is_true(A.less_constrained_ok(fig4b))
        assert.is_true(A.admissible(fig4b))
        -- witness 2 from the Zhang pass behaves the same way
        assert.is_false(A.lst_original_ok(w2))
        assert.is_true(A.less_constrained_ok(w2))
    end)

    it('Def 4.8 (revised less-constrained) coincides with BK admissibility on every random subset; by Thm 4.19 admissible = alignable', function()
        local rnd, n, n_true, n_tai_only = lcg(5), 0, 0, 0
        subsets(rnd, 60, 6, function(sub)
            local lc, ad = A.less_constrained_ok(sub), A.admissible(sub)
            assert.equals(ad, lc, 'disagree on ' .. #sub .. ' pairs')
            n = n + 1
            if lc then n_true = n_true + 1 end
            if A.tai_ok(sub) and not lc then n_tai_only = n_tai_only + 1 end
        end)
        -- small random trees almost never contain the three-element flip; the Tai-only
        -- witnesses are BK's (a,f(b,c)) vs (f(a,b),c) and the composite in the last test
        assert.is_true(n_true > 100, ('n=%d true=%d tai-only=%d'):format(n, n_true, n_tai_only))
    end)

    it('the hierarchy on random subsets: accordant ⇒ constrained ⇒ less-constrained ⇒ Tai; a(b(c,d)) vs a(c,d) is constrained, not accordant', function()
        local rnd = lcg(9)
        subsets(rnd, 40, 6, function(sub)
            local ac, co, lc, t = A.accordant_ok(sub), A.constrained_ok(sub), A.less_constrained_ok(sub), A.tai_ok(sub)
            if ac then assert.is_true(co) end
            if co then assert.is_true(lc) end
            if lc then assert.is_true(t) end
        end)
        local acw = al({ 'a', { 1 }, { 1 } }, { 'c', { 1, 1, 1 }, { 1, 1 } }, { 'd', { 1, 1, 2 }, { 1, 2 } })
        assert.is_true(A.constrained_ok(acw))
        assert.is_false(A.accordant_ok(acw))
    end)

    it('Prop 4.22: a mapping is alignable iff its leaves are', function()
        local rnd, n_diff = lcg(13), 0
        subsets(rnd, 40, 6, function(sub)
            local leaves = A.mapping_leaves(sub)
            if #leaves < #sub then n_diff = n_diff + 1 end
            if A.tai_ok(sub) then assert.equals(A.less_constrained_ok(sub), A.less_constrained_ok(leaves)) end
        end)
        assert.is_true(n_diff > 50)
    end)

    it('JWZ alignment DP: f(a,b,c) vs f(g(a,b),c) scores 4 and vertical rebuilds both through f(X(a,b),c)', function()
        local s, q = f(a, b, c), f(g(a, b), c)
        local j = A.jwz({ s }, { q })
        assert.equals(4, j.size)
        assert.is_true(A.admissible(j.alignment))
        assert.is_false(A.constrained_ok(j.alignment))
        assert.equals(3, A.zhang({ s }, { q }).size)
        local v = A.vertical(s, q, { skeleton = 'jwz' })
        local T = v.templates[1]
        assert.equals('(seq (f ?X1((a) (b)) (c)))', A.show(T.body))
        assert.is_true(A.eq(A.instantiate(T, T.values[1]).term, seq { s }))
        assert.is_true(A.eq(A.instantiate(T, T.values[2]).term, seq { q }))
    end)

    it('BK Example 2: the JWZ skeleton reaches the brute-force admissible maximum where Zhang stopped at 2', function()
        local S, Q = seq { a, node('a', b, b) }, seq { node('a', node('a', node('b', b))), b, b }
        local oracle = best_mapping(S.kids, Q.kids, A.admissible)
        local j = A.jwz(S.kids, Q.kids)
        assert.equals(oracle, j.size)
        assert.equals(3, oracle)
        local v = A.vertical(S, Q, { skeleton = 'jwz' })
        local T = v.templates[1]
        assert.is_true(A.eq(A.instantiate(T, T.values[1]).term, S))
        assert.is_true(A.eq(A.instantiate(T, T.values[2]).term, Q))
    end)

    it('the DP equals the brute-force admissible maximum on random trees and its output is always admissible', function()
        local rnd, checked, beats_zhang = lcg(17), 0, 0
        for _ = 1, 40 do
            local S, Q = { rand_tree(rnd, 5) }, { rand_tree(rnd, 5) }
            local oracle = best_mapping(S, Q, A.admissible)
            if oracle then
                local j = A.jwz(S, Q)
                assert.equals(oracle, j.size, A.show(S[1]) .. ' vs ' .. A.show(Q[1]))
                assert.equals(j.size, #j.alignment)
                assert.is_true(A.admissible(j.alignment))
                assert.is_true(A.less_constrained_ok(j.alignment))
                if j.size > A.zhang(S, Q).size then beats_zhang = beats_zhang + 1 end
                local v = A.vertical(seq(S), seq(Q), { skeleton = 'jwz' })
                local T = v.templates[1]
                assert.is_true(A.eq(A.instantiate(T, T.values[1]).term, seq(S)))
                assert.is_true(A.eq(A.instantiate(T, T.values[2]).term, seq(Q)))
                checked = checked + 1
            end
        end
        assert.is_true(checked > 20)
    end)

    it('Prop 2.58: alignable mappings do not compose — e(a,b,c) shares a size-4 template with each of e(f(a,b),c) and e(a,g(b,c)), which share none', function()
        local S, R, T = e(a, b, c), e(f(a, b), c), e(a, g(b, c))
        assert.equals(4, A.jwz({ S }, { R }).size)
        assert.equals(4, A.jwz({ S }, { T }).size)
        assert.equals(3, A.jwz({ R }, { T }).size)
        local composite = al({ 'e', { 1 }, { 1 } }, { 'a', { 1, 1, 1 }, { 1, 1 } }, { 'b', { 1, 1, 2 }, { 1, 2, 1 } }, { 'c', { 1, 2 }, { 1, 2, 2 } })
        assert.is_true(A.tai_ok(composite))
        assert.is_false(A.less_constrained_ok(composite))
        assert.is_false(A.admissible(composite))
    end)
end)

describe('LST01 via Kuboyama: exhaustive check on the discriminating universe (all Tai 3-mappings, trees ≤ 5 nodes)', function()
    -- all four conditions quantify over triples, so size-3 Tai mappings decide them.
    local shapes = {}
    local function gen(n) -- all ordered tree shapes with exactly n nodes, single label
        if n == 1 then return { node 'a' } end
        local out = {}
        -- root + forest of total n-1 nodes: compositions
        local function forests(m)
            if m == 0 then return { {} } end
            local fs = {}
            for first = 1, m do
                for _, t in ipairs(gen(first)) do
                    for _, rest in ipairs(forests(m - first)) do
                        local f = { t }
                        for _, r in ipairs(rest) do f[#f + 1] = r end
                        fs[#fs + 1] = f
                    end
                end
            end
            return fs
        end
        for _, f in ipairs(forests(n - 1)) do out[#out + 1] = node('a', unpack(f)) end
        return out
    end
    for n = 1, 5 do for _, t in ipairs(gen(n)) do shapes[#shapes + 1] = t end end
    local perms = { { 1, 2, 3 }, { 1, 3, 2 }, { 2, 1, 3 }, { 2, 3, 1 }, { 3, 1, 2 }, { 3, 2, 1 } }

    it('23 shapes; on every Tai 3-mapping, admissible ≡ less-constrained and lst_original ≡ constrained, both rejecting some; chain holds', function()
        assert.equals(23, #shapes)
        local tai, rej_ad, rej_lc, rej_co, rej_lst, chain_bad, mism = 0, 0, 0, 0, 0, 0, 0
        for _, S in ipairs(shapes) do
            local wS = A.word { S }
            if #wS >= 3 then
                for _, Q in ipairs(shapes) do
                    local wQ = A.word { Q }
                    if #wQ >= 3 then
                        for i1 = 1, #wS do for i2 = i1 + 1, #wS do for i3 = i2 + 1, #wS do
                            for j1 = 1, #wQ do for j2 = j1 + 1, #wQ do for j3 = j2 + 1, #wQ do
                                local I, J = { wS[i1].pos, wS[i2].pos, wS[i3].pos }, { wQ[j1].pos, wQ[j2].pos, wQ[j3].pos }
                                for _, p in ipairs(perms) do
                                    local m = {}
                                    for k = 1, 3 do m[k] = { sym = 'a', I = I[k], J = J[p[k]] } end
                                    if A.tai_ok(m) then
                                        tai = tai + 1
                                        local ad, lc, co, lst = A.admissible(m), A.less_constrained_ok(m), A.constrained_ok(m), A.lst_original_ok(m)
                                        if ad ~= lc or co ~= lst then mism = mism + 1 end
                                        if not ad then rej_ad = rej_ad + 1 end
                                        if not lc then rej_lc = rej_lc + 1 end
                                        if not co then rej_co = rej_co + 1 end
                                        if not lst then rej_lst = rej_lst + 1 end
                                        if not lc and co then chain_bad = chain_bad + 1 end
                                    end
                                end
                            end end end
                        end end end
                    end
                end
            end
        end
        local msg = ('tai=%d rejected: admissible=%d less-constrained=%d constrained=%d lst-original=%d mismatches=%d chain-violations=%d')
            :format(tai, rej_ad, rej_lc, rej_co, rej_lst, mism, chain_bad)
        assert.equals(0, mism, msg)
        assert.equals(0, chain_bad, msg)
        assert.is_true(rej_ad > 0 and rej_ad == rej_lc and rej_co == rej_lst and rej_co > rej_ad, msg)
    end)
end)

describe('Term-graph anti-unification (Baumgartner, Kutsia, Levy, Villaret, FSCD 2018)', function()
    local tg = A.tg
    local function cyc(stem, per) -- a stem of `stem` f-nodes into a cycle of `per` f-nodes
        local e, n = {}, stem + per
        for i = 0, n - 1 do e['x' .. i] = { 'f', 'x' .. ((i + 1 < n) and (i + 1) or stem) } end
        return tg('x0', e)
    end
    local function rebuilds(r, G1, G2)
        return A.tg_bisimilar(A.tg_instantiate(r.G, r.sigmaL, { G1 }), G1)
            and A.tg_bisimilar(A.tg_instantiate(r.G, r.sigmaR, { G2 }), G2)
    end
    local function lcg(seed)
        local s = seed
        return function(n) s = (s * 1103515245 + 12345) % 2147483648; return (s % n) + 1 end
    end
    local function rand_tree(rnd, budget)
        local labels = { 'a', 'b', 'c' }
        local t = node(labels[rnd(3)])
        budget = budget - 1
        while budget > 0 and rnd(2) == 1 do
            local kid = rand_tree(rnd, rnd(budget))
            t.kids[#t.kids + 1] = kid
            budget = budget - A.size(kid)
        end
        return t
    end

    it('Example 8: a graph, its partial unwinding and its full collapse are bisimilar; a relabelled one is not', function()
        local G = tg('x', { x = { 'f', 'y', 'z' }, y = { 'a' }, z = { 'f', 'y', 'x' } })
        local collapsed = tg('x', { x = { 'f', 'y', 'x' }, y = { 'a' } })
        assert.is_true(A.tg_bisimilar(G, collapsed))
        -- every graph of unary f-nodes unwinds to the one infinite term f(f(f(...))), so
        -- stems and periods are invisible to bisimilarity (which is why Ex. 24 is a join)
        assert.is_true(A.tg_bisimilar(cyc(3, 3), cyc(0, 6)))
        assert.is_true(A.tg_bisimilar(cyc(0, 3), cyc(0, 6)))
        assert.is_false(A.tg_bisimilar(G, tg('x', { x = { 'f', 'y', 'x' }, y = { 'b' } })))
        -- show is canonical: renaming bound variables does not change it
        assert.equals(A.tg_show(collapsed), A.tg_show(tg('p', { p = { 'f', 'q', 'p' }, q = { 'a' } })))
    end)

    it('Example 9: substitution application unions the sources and splices hedges, keeping their cycles', function()
        local G = tg('x0', { x0 = { 'f', 'x0', 'X1', 'x1', 'X1', 'x2' }, X1 = { hvar = 'X' }, x1 = { 'g', 'X2', 'x2', 'X2' }, X2 = { hvar = 'Y' }, x2 = { var = 'x' } })
        local G1, G2 = tg('y', { y = { 'f', 'y' } }), tg('z', { z = { 'a' } })
        local I = A.tg_instantiate(G, { x = { 'y' }, X = { 'z', 'X' }, Y = {} }, { G1, G2 })
        local paper = tg('x0', { x0 = { 'f', 'x0', 'z', 'Z', 'x1', 'z', 'Z', 'y' }, z = { 'a' }, Z = { hvar = 'X' }, x1 = { 'g', 'y' }, y = { 'f', 'y' } })
        assert.is_true(A.tg_bisimilar(I, paper))
        assert.equals('z0=f(z0,z1,Z1,z2,z1,Z1,z3) z1=a Z1=U1 z2=g(z3) z3=f(z3)', A.tg_show(I))
    end)

    it('Example 14: the R-generalization, with Merge joining the two ε ≜ (y0) gaps, and the store rebuilds both inputs', function()
        local G1 = tg('x0', { x0 = { 'f', 'x1', 'x2' }, x1 = { 'g', 'x2', 'x2' }, x2 = { 'a' } })
        local G2 = tg('y0', { y0 = { 'f', 'y1', 'y0', 'y2', 'y0' }, y1 = { 'g' }, y2 = { 'a' } })
        local r = A.tg_generalize(G1, G2)
        local paper = tg('z0', { z0 = { 'f', 'z1', 'Z1', 'z2', 'Z1' }, z1 = { 'g', 'Z2' }, z2 = { 'a' }, Z1 = { hvar = 'U' }, Z2 = { hvar = 'V' } })
        assert.equals(A.tg_show(paper), A.tg_show(r.G))
        assert.is_true(A.tg_bisimilar(r.G, paper, { rename = true }))
        assert.is_true(rebuilds(r, G1, G2))
        -- the two rejected candidates of the example are not what Gen(R) produces
        assert.is_not.equals(A.tg_show(tg('z0', { z0 = { 'f', 'z1', 'Z1', 'z2', 'Z1' }, z1 = { 'g', 'Z2', 'Z2' }, z2 = { 'a' }, Z1 = { hvar = 'U' }, Z2 = { hvar = 'V' } })), A.tg_show(r.G))
    end)

    it('Example 15: the paper\'s G is produced, with a cycle through z0 and a self-loop at z1; LCS admits a second, incomparable one', function()
        local G1 = tg('x0', { x0 = { 'f', 'x1', 'x2', 'x3', 'x0', 'x3', 'x2', 'x3' }, x1 = { 'g', 'x1', 'x2' }, x2 = { 'b' }, x3 = { 'a' } })
        local G2 = tg('y0', { y0 = { 'f', 'y1', 'y0', 'y3' }, y1 = { 'g', 'y1', 'y2' }, y2 = { 'b' }, y3 = { 'a' } })
        local all = A.tg_generalize_all(G1, G2)
        local paper = tg('z0', { z0 = { 'f', 'z1', 'Z1', 'z0', 'z3', 'Z1' }, z1 = { 'g', 'z1', 'z2' }, Z1 = { hvar = 'U' }, z3 = { 'a' }, z2 = { 'b' } })
        local shows = {}
        for _, r in ipairs(all) do
            shows[#shows + 1] = A.tg_show(r.G)
            assert.is_true(rebuilds(r, G1, G2))
        end
        assert.equals(2, #all)
        assert.equals(A.tg_show(paper), shows[1])
        assert.equals('z0=f(z1,Z1,z0,Z2,z3) z1=g(z1,z2) z2=b Z1=U1 Z2=U2 z3=a', shows[2])
        -- the paper: to obtain G1 apply {U1 ↦ (x2, x3)}; the result is bisimilar, not equal
        local I = A.tg_instantiate(all[1].G, all[1].sigmaL, { G1 })
        assert.is_true(A.tg_bisimilar(I, G1))
        assert.is_true(A.tg_nodes(I) > A.tg_nodes(G1))
    end)

    it('Example 16: heads g and h differ under the cycle, so the cycle leaves the generalization and lives in the store', function()
        local G1 = tg('x0', { x0 = { 'f', 'x1', 'x2' }, x1 = { 'g', 'x0', 'x3' }, x2 = { 'a' }, x3 = { 'b' } })
        local G2 = tg('y0', { y0 = { 'f', 'y1', 'y2' }, y1 = { 'h', 'y0', 'y3' }, y2 = { 'a' }, y3 = { 'b' } })
        local r = A.tg_generalize(G1, G2)
        assert.equals('z0=f(z1,z2) z1=u1 z2=a', A.tg_show(r.G))
        assert.same({ 'x1' }, r.store.u1.A)
        assert.same({ 'y1' }, r.store.u1.B)
        assert.is_true(rebuilds(r, G1, G2))
        -- the printed rules alone give a hedge variable for that gap; the tree algorithm and
        -- the paper's own example give a term variable, which is the default here
        assert.equals('z0=f(Z1,z1) Z1=U1 z1=a', A.tg_show(A.tg_generalize(G1, G2, { literal = true }).G))
        assert.equals('(f ?x1 (b))', A.show(A.rigid(node('f', node('g', node('a')), node('b')), node('f', node('h', node('a')), node('b'))).templates[1].body))
    end)

    it('Example 24 and Theorem 23: bisimilar cycles generalize to their join; periods combine as a least common multiple', function()
        local r = A.tg_generalize(cyc(3, 3), cyc(2, 6))
        assert.equals(A.tg_show(cyc(3, 6)), A.tg_show(r.G))
        assert.is_nil(next(r.store))
        assert.is_true(A.tg_bisimilar(r.G, cyc(3, 3)) and A.tg_bisimilar(r.G, cyc(2, 6)))
        assert.equals(A.tg_show(cyc(0, 6)), A.tg_show(A.tg_generalize(cyc(0, 2), cyc(0, 3)).G))
        assert.equals(A.tg_show(cyc(0, 12)), A.tg_show(A.tg_generalize(cyc(0, 4), cyc(0, 6)).G))
        assert.equals(1, #A.tg_generalize_all(cyc(3, 3), cyc(2, 6)))
        -- cycles in the output come only from cycles in the input: finite trees give finite graphs
        local t = node('f', node('f', node('f', node('a'))))
        local rt = A.tg_generalize(A.tg_of_term(t), A.tg_of_term(node('f', node('f', node('a')))))
        assert.equals('z0=f(z1) z1=f(z2) z2=u1', A.tg_show(rt.G))
    end)

    it('the trail is the memo: sharing in the input is answered by Share, and Theorem 23 holds for a tree against its collapse', function()
        local rnd, checked = lcg(21), 0
        for _ = 1, 30 do
            local t = rand_tree(rnd, 9)
            local plain, shared = A.tg_of_term(t), A.tg_of_term(t, { share = true })
            assert.is_true(A.tg_bisimilar(plain, shared))
            local r = A.tg_generalize(plain, shared)
            assert.is_nil(next(r.store))
            assert.is_true(A.tg_bisimilar(r.G, plain))
            assert.equals(1, #A.tg_generalize_all(plain, shared))
            if A.tg_nodes(shared) < A.tg_nodes(plain) then checked = checked + 1 end
        end
        assert.is_true(checked > 5)
    end)

    it('on trees the graph algorithm agrees with the tree rigid lgg ONLY on collapsed inputs: Merge is by node identity, Mer-S by content', function()
        local rnd = lcg(23)
        local agree_shared, disagree_plain, pairs_n = 0, 0, 0
        local function to_graph(T) -- a template body as a graph, holes as free variables
            return A.tg_of_term(T.body, { share = true })
        end
        for _ = 1, 40 do
            local s, q = rand_tree(rnd, 7), rand_tree(rnd, 7)
            local tree = A.rigid(s, q, { rigidity = 'lcs' })
            local shared = A.tg_generalize_all(A.tg_of_term(s, { share = true }), A.tg_of_term(q, { share = true }))
            local plain = A.tg_generalize_all(A.tg_of_term(s), A.tg_of_term(q))
            pairs_n = pairs_n + 1
            local function covered(results)
                for _, T in ipairs(tree.templates) do
                    local found = false
                    for _, r in ipairs(results) do
                        if A.tg_bisimilar(to_graph(T), r.G, { rename = true }) then found = true; break end
                    end
                    if not found then return false end
                end
                return true
            end
            assert.is_true(covered(shared), A.show(s) .. ' vs ' .. A.show(q))
            agree_shared = agree_shared + 1
            if not covered(plain) then disagree_plain = disagree_plain + 1 end
            for _, r in ipairs(shared) do assert.is_true(rebuilds(r, A.tg_of_term(s, { share = true }), A.tg_of_term(q, { share = true }))) end
        end
        assert.equals(pairs_n, agree_shared)
        assert.is_true(disagree_plain > 0, 'plain encodings never disagreed')
    end)
end)

describe('Higher-order pattern anti-unification (Baumgartner, Kutsia, Levy, Villaret, JAR 2017)', function()
    local lam, app, bv, fv, lams = A.lam, A.app, A.bv, A.fv, A.lams
    local function rebuilds(r) -- Theorem 2(a) and 2(b): the result is a pattern and the store rebuilds both inputs
        assert.is_true(A.ho_is_pattern(r.result), 'not a pattern: ' .. A.ho_show(r.result))
        return A.alpha_eq(A.ho_apply(r.result, r.sigmaL), r.left) and A.alpha_eq(A.ho_apply(r.result, r.sigmaR), r.right)
    end
    local function ho_size(t)
        if t.k == 'lam' then return 1 + ho_size(t.body) end
        local n = 1
        for _, a in ipairs(t.args) do n = n + ho_size(a) end
        return n
    end
    -- Example 1 (a), (b), (c) and the Section 2 pair
    local ex1a = { lams({ 'x', 'y' }, app('f', fv('U', app('g', bv 'x'), bv 'y'), fv('U', app('g', bv 'y'), bv 'x'))),
        lams({ 'x', 'y' }, app('f', app('h', bv 'y', app('g', bv 'x')), app('h', bv 'x', app('g', bv 'y')))) }
    local ex1b = { lams({ 'x', 'y', 'z' }, app('g', app('f', bv 'x', bv 'z'), app('f', bv 'y', bv 'z'), app('f', bv 'y', bv 'x'))),
        lams({ 'x', 'y', 'z' }, app('g', app('h', bv 'y', bv 'x'), app('h', bv 'x', bv 'y'), app('h', bv 'z', bv 'y'))) }
    local ex1c = { lams({ 'x', 'y' }, app('f', lam('z', fv('U', bv 'z', bv 'y', bv 'x')), fv('U', bv 'x', bv 'y', bv 'x'))),
        lams({ 'x', 'y' }, app('f', lam('z', app('h', bv 'y', bv 'z', bv 'x')), app('h', bv 'y', bv 'x', bv 'x'))) }
    local sec2 = { lams({ 'x', 'y' }, app('f', app('h', bv 'x', bv 'x', bv 'y'), app('h', bv 'x', bv 'y', bv 'y'))),
        lams({ 'x', 'y' }, app('f', app('g', bv 'x', bv 'x', bv 'y'), app('g', bv 'x', bv 'y', bv 'y'))) }
    local function lcg(seed)
        local s = seed
        return function(n) s = (s * 1103515245 + 12345) % 2147483648; return (s % n) + 1 end
    end
    local function rand_tree(rnd, budget)
        local labels = { 'a', 'b', 'c' }
        local t = node(labels[rnd(3)])
        budget = budget - 1
        while budget > 0 and rnd(2) == 1 do
            local kid = rand_tree(rnd, rnd(budget))
            t.kids[#t.kids + 1] = kid
            budget = budget - A.size(kid)
        end
        return t
    end
    local function to_ho(t) -- a first-order tree (or template body with holes) as a λ-free term
        if t.k == 'hole' then return fv(t.h) end
        local args = {}
        for i, c in ipairs(t.kids or {}) do args[i] = to_ho(c) end
        return { k = 'app', h = t.k, args = args }
    end

    it('Example 1(a): the two disagreements are one variable applied to (x,y) and (y,x); the store rebuilds both', function()
        local r = A.hoau(ex1a[1], ex1a[2])
        -- paper: λx,y. f(Y1(x,y), Y1(y,x)); the queue order reproduces it exactly, the stack
        -- order keeps the other representative, and Theorem 4 says the two are equivalent
        assert.equals('λ.λ.f(Y1(#1,#0),Y1(#0,#1))', A.ho_show(A.hoau(ex1a[1], ex1a[2], { queue = true }).result))
        assert.equals('λ.λ.f(Y1(#0,#1),Y1(#1,#0))', A.ho_canon(r.result))
        assert.equals(1, #r.store)
        assert.is_true(rebuilds(r))
        -- the substitutions the paper reads from the store (queue order keeps the paper's representative)
        local q = A.hoau(ex1a[1], ex1a[2], { queue = true })
        assert.equals(A.ho_show(lams({ 'x', 'y' }, fv('U', app('g', bv 'x'), bv 'y'))), A.ho_show(lams(q.store[1].ys, q.store[1].t)))
        assert.equals(A.ho_show(lams({ 'x', 'y' }, app('h', bv 'y', app('g', bv 'x')))), A.ho_show(lams(q.store[1].ys, q.store[1].s)))
    end)

    it('Example 1(b): a three-cycle permutation, which fixes the direction of the matcher', function()
        local r = A.hoau(ex1b[1], ex1b[2], { queue = true })
        -- the paper prints the outer head as f; both inputs have g there, an erratum
        assert.equals('λ.λ.λ.g(Y1(#2,#1,#0),Y1(#1,#2,#0),Y1(#1,#0,#2))', A.ho_show(r.result))
        assert.equals(1, #r.store)
        assert.is_true(rebuilds(r))
        assert.equals(A.ho_canon(r.result), A.ho_canon(A.hoau(ex1b[1], ex1b[2]).result))
    end)

    it('Example 1(c): no merge, the two entries have three and two arguments', function()
        local r = A.hoau(ex1c[1], ex1c[2], { queue = true })
        assert.equals('λ.λ.f(λ.Y1(#2,#1,#0),Y2(#1,#0))', A.ho_show(r.result))
        assert.equals(2, #r.store)
        assert.is_true(rebuilds(r))
    end)

    it('Section 2: the pattern lgg f(Y1(x,y), Y2(x,y)); Mer cannot fire because no bijection sends h(x,x,y) to h(x,y,y)', function()
        local r = A.hoau(sec2[1], sec2[2], { queue = true })
        assert.equals('λ.λ.f(Y1(#1,#0),Y2(#1,#0))', A.ho_show(r.result))
        assert.equals(2, #r.store)
        assert.is_true(rebuilds(r))
    end)

    it('Sol on a shared FREE head, narrowing to the variables used, and the untyped extension (arity mismatch, lazy η)', function()
        local fh = A.hoau(lam('x', fv('U', bv 'x', app 'a')), lam('x', fv('U', bv 'x', app 'b')))
        assert.equals('λ.Y1(#0)', A.ho_show(fh.result))
        assert.is_true(A.ho_is_pattern(fh.result))
        assert.is_false(A.ho_is_pattern(fh.left)) -- the INPUT is not a pattern: U is applied to a constant
        local t, s = lams({ 'x', 'y' }, app('f', bv 'x', app('g', bv 'y'))), lams({ 'x', 'y' }, app('f', bv 'x', app('h', bv 'y')))
        assert.equals('λ.λ.f(#1,Y1(#0))', A.ho_show(A.hoau(t, s).result))
        assert.equals('λ.λ.f(#1,Y1(#1,#0))', A.ho_show(A.hoau(t, s, { no_narrow = true }).result))
        -- f(a,x) against f(b,x,y): same head, different arity, Sol (conclusion of the paper)
        local r = A.hoau(lams({ 'x', 'y' }, app('f', app 'a', bv 'x')), lams({ 'x', 'y' }, app('f', app 'b', bv 'x', bv 'y')))
        assert.equals('λ.λ.Y1(#1,#0)', A.ho_show(r.result))
        assert.is_true(rebuilds(r))
        -- a λ against a non-λ is η-expanded lazily; the rebuild is modulo η, so compare with the expanded input
        local e = A.hoau(lam('x', app('f', lam('y', app('g', bv 'y', bv 'x')))), lam('x', app('f', app('g', bv 'x'))))
        assert.equals('λ.f(λ.g(Y1(#0,#1),Y1(#1,#0)))', A.ho_canon(e.result))
        assert.is_true(A.alpha_eq(A.ho_apply(e.result, e.sigmaR), lam('x', app('f', lam('z', app('g', bv 'x', bv 'z'))))))
    end)

    it('Theorem 4 (uniqueness modulo ≃) and Theorem 1 (steps within the measure) over selection and merge orders', function()
        local rnd = lcg(29)
        local cases = { ex1a, ex1b, ex1c, sec2 }
        for _ = 1, 20 do
            local base = rand_tree(rnd, 8)
            cases[#cases + 1] = { lams({ 'x', 'y' }, to_ho(base)), lams({ 'x', 'y' }, to_ho(rand_tree(rnd, 8))) }
        end
        for _, c in ipairs(cases) do
            local shows = {}
            for _, o in ipairs { {}, { queue = true }, { reverse_merge = true }, { queue = true, reverse_merge = true } } do
                local r = A.hoau(c[1], c[2], o)
                shows[#shows + 1] = A.ho_canon(r.result)
                assert.is_true(r.steps <= 2 * (ho_size(c[1]) + ho_size(c[2])))
                assert.is_true(rebuilds(r))
            end
            for i = 2, #shows do assert.equals(shows[1], shows[i]) end
        end
    end)

    it('binder-free RANKED terms: the pattern lgg is Plotkin\'s non-linear lgg, i.e. the prototype\'s positional generalize', function()
        -- ranked, because the calculus is simply typed: equal types force equal arities, and
        -- an arity mismatch is where the untyped extension answers with a variable instead
        local function ranked(rnd2, depth)
            local arity = { f = 2, g = 1, a = 0, b = 0 }
            local names = depth > 3 and { 'a', 'b' } or { 'f', 'g', 'a', 'b' }
            local k = names[rnd2(#names)]
            local t = node(k)
            for i = 1, arity[k] do t.kids[i] = ranked(rnd2, depth + 1) end
            return t
        end
        local rnd, n = lcg(31), 0
        for _ = 1, 40 do
            local s, q = ranked(rnd, 1), ranked(rnd, 1)
            local g = A.generalize({ s, q })
            local r = A.hoau(to_ho(s), to_ho(q))
            assert.is_true(rebuilds(r))
            assert.equals(A.ho_canon(to_ho(g.template.body)), A.ho_canon(r.result), A.show(s) .. ' vs ' .. A.show(q))
            n = n + 1
        end
        assert.equals(40, n)
    end)

    it('α is the bisimilarity of this pass: a term against its renaming has no holes; a consistent binder swap gives holes over (x,y) and (y,x) with one store entry', function()
        local rnd, swapped_cases = lcg(37), 0
        local function with_vars(t, rnd2) -- replace some leaves by bound variables x, y
            if #(t.kids or {}) == 0 and rnd2(2) == 1 then return bv(rnd2(2) == 1 and 'x' or 'y') end
            local args = {}
            for i, c in ipairs(t.kids or {}) do args[i] = with_vars(c, rnd2) end
            return { k = 'app', h = t.k, args = args }
        end
        local function swap(t)
            if t.bv then return bv(t.bv == 'x' and 'y' or 'x') end
            local args = {}
            for i, a in ipairs(t.args) do args[i] = swap(a) end
            return { k = 'app', h = t.h, args = args }
        end
        for _ = 1, 30 do
            local body = with_vars(rand_tree(rnd, 9), rnd)
            local t = lams({ 'x', 'y' }, body)
            local function rn(u)
                if u.bv then return bv(u.bv == 'x' and 'p' or 'q') end
                local args = {}
                for i, a in ipairs(u.args) do args[i] = rn(a) end
                return { k = 'app', h = u.h, args = args }
            end
            local renamed = lams({ 'p', 'q' }, rn(body))
            local r = A.hoau(t, renamed)
            assert.is_true(rebuilds(r))
            assert.is_true(A.alpha_eq(r.result, t))
            assert.equals(0, #r.store)
            local sw = A.hoau(t, lams({ 'x', 'y' }, swap(body)))
            assert.is_true(rebuilds(sw))
            local cs = A.ho_canon(sw.result)
            if cs:find('Y') then
                swapped_cases = swapped_cases + 1
                assert.equals(1, #sw.store)
                for args in cs:gmatch('Y1%(([^)]*)%)') do assert.is_true(args == '#0,#1' or args == '#1,#0', cs) end
                assert.is_nil(cs:find('Y2'))
            end
        end
        assert.is_true(swapped_cases > 10)
    end)
end)

describe('keyed n-ary generalization of JSON-like documents (objects by key, arrays by merge key)', function()
    local function O(t, keys) -- object from a Lua table with an explicit key order
        local o = {}
        for _, k in ipairs(keys) do o[k] = t[k] end
        return { o = o, keys = keys }
    end
    local function Arr(...) return { a = { ... } } end
    local function holes_by_kind(r)
        local c = {}
        for _, h in ipairs(r.holes) do c[h.kind] = (c[h.kind] or 0) + 1 end
        return c
    end
    local function rebuilds(r, docs)
        for i, d in ipairs(docs) do if not A.kv_eq_keyed(r.instantiate(i), d) then return false, i end end
        return true
    end

    it('a value used at several paths is ONE hole: the non-linear store across the document', function()
        local d1 = O({ name = 'email', labels = O({ app = 'email' }, { 'app' }), port = 8080, replicas = 1 }, { 'name', 'labels', 'port', 'replicas' })
        local d2 = O({ name = 'cart', labels = O({ app = 'cart' }, { 'app' }), port = 7070, replicas = 1 }, { 'name', 'labels', 'port', 'replicas' })
        local r = A.kv_generalize({ d1, d2 })
        assert.equals(2, #r.holes)
        assert.same({ '$.name', '$.labels.app' }, r.holes[1].sites)
        assert.same({ 'email', 'cart' }, r.holes[1].values)
        assert.same({ '$.port' }, r.holes[2].sites)
        assert.equals(1, r.template.o.replicas)
        assert.is_true(rebuilds(r, { d1, d2 }))
    end)

    it('objects align by key whatever the order; a key present in some instances is a presence hole over the rest', function()
        local d1 = O({ a = 1, b = 2 }, { 'a', 'b' })
        local d2 = O({ b = 2, a = 1 }, { 'b', 'a' })
        local d3 = O({ a = 1, b = 2, c = O({ x = 1 }, { 'x' }) }, { 'a', 'b', 'c' })
        local r = A.kv_generalize({ d1, d2, d3 })
        assert.same({ presence = 1 }, holes_by_kind(r))
        assert.same({ false, false, true }, r.holes[1].values)
        assert.equals(1, r.template.o.c.body.o.x)
        assert.is_true(rebuilds(r, { d1, d2, d3 }))
    end)

    it('arrays of objects with a merge key align by that key, not by position; other arrays positionally or as one hole', function()
        local env1 = Arr(O({ name = 'PORT', value = '8080' }, { 'name', 'value' }), O({ name = 'X', value = '1' }, { 'name', 'value' }))
        local env2 = Arr(O({ name = 'X', value = '2' }, { 'name', 'value' }), O({ name = 'PORT', value = '8080' }, { 'name', 'value' }))
        local r = A.kv_generalize({ O({ env = env1 }, { 'env' }), O({ env = env2 }, { 'env' }) })
        assert.equals(1, #r.holes)
        assert.same({ '$.env[name].X.value' }, r.holes[1].sites)
        assert.equals('8080', r.template.o.env.ka.o.PORT.o.value)
        assert.is_true(rebuilds(r, { O({ env = env1 }, { 'env' }), O({ env = env2 }, { 'env' }) }))
        -- positional when lengths agree, one hole when they do not
        local p = A.kv_generalize({ O({ l = Arr(1, 2) }, { 'l' }), O({ l = Arr(1, 3) }, { 'l' }) })
        assert.same({ '$.l[2]' }, p.holes[1].sites)
        local q = A.kv_generalize({ O({ l = Arr(1, 2) }, { 'l' }), O({ l = Arr(1, 2, 3) }, { 'l' }) })
        assert.equals('array', q.holes[1].kind)
        -- a type change is a hole of its own kind
        local m = A.kv_generalize({ O({ v = 1 }, { 'v' }), O({ v = O({}, {}) }, { 'v' }) })
        assert.equals('mixed', m.holes[1].kind)
    end)

    it('n-ary: three instances, a hole carries a vector of three, and equal vectors merge even across kinds of path', function()
        local mk = function(name, cpu) return O({ meta = O({ name = name }, { 'name' }), img = name, cpu = cpu }, { 'meta', 'img', 'cpu' }) end
        local docs = { mk('a', '100m'), mk('b', '100m'), mk('c', '200m') }
        local r = A.kv_generalize(docs)
        assert.equals(2, #r.holes)
        assert.same({ 'a', 'b', 'c' }, r.holes[1].values)
        assert.equals(2, #r.holes[1].sites)
        assert.same({ '100m', '100m', '200m' }, r.holes[2].values)
        assert.is_true(rebuilds(r, docs))
    end)
end)

describe('value migration: the family follows an edit (reads T and V, never I)', function()
    local T0 = A.template(call('register', hole 'key', hole 'fn'))
    local Is = {
        call('register', lit 'on_tick', name 'tick'),
        call('register', lit 'on_draw', name 'draw'),
        call('register', lit 'on_tick', name 'tick2'),
    }
    local Vs = {}
    for i, I in ipairs(Is) do Vs[i] = A.match(T0, I).values end

    -- the law, one edit at a time: kept ⇒ instantiate(T', V') == I and match(T', I) ok;
    -- dropped ⇒ match(T', I) refuses. `Is` is consulted only here, never by migrate.
    local function law(T, T2, Vs_, Is_)
        local r = assert(A.migrate(T, T2, Vs_))
        local alive = {}
        for _, i in ipairs(r.kept) do
            alive[i] = true
            local inst = A.instantiate(T2, r.values[i])
            assert.is_true(inst.ok, 'kept ' .. i .. ' must instantiate')
            assert.is_true(A.eq(inst.term, Is_[i]), 'kept ' .. i .. ' must rebuild its instance')
            assert.is_true(A.match(T2, Is_[i]).ok, 'kept ' .. i .. ' must still match')
        end
        for _, d in ipairs(r.dropped) do
            assert.is_false(A.match(T2, Is_[d.i]).ok, 'dropped ' .. d.i .. ' must be refused')
        end
        return r
    end

    it('pin keeps the members whose value equals the pin and names the rest', function()
        local T1 = A.pin(T0, 'key', lit 'on_tick')
        local r = law(T0, T1, Vs, Is)
        assert.same({ 1, 3 }, r.kept)
        assert.equals(1, #r.dropped)
        assert.equals(2, r.dropped[1].i)
        assert.equals('pin key: value differs', r.dropped[1].why)
        assert.is_true(A.values_eq(r.values[1], Vs[1]))
    end)

    it('open brings nobody back: a member dropped by pin is re-ADMITTED, not re-migrated', function()
        local P = A.pin(T0, 'key', lit 'on_tick')
        local O = A.open_hole(P, 'key')
        local r = assert(A.migrate(T0, O, Vs))
        assert.same({ 1, 3 }, r.kept)
        assert.equals(1, r.dropped[1].edit) -- dropped at the pin, edit 1 of 2
        assert.is_true(A.match(O, Is[2]).ok)  -- yet it fits again: adoption is a match
    end)

    it('dig gives every member the dug subtree as its value; the instances are unchanged', function()
        local D = A.dig(T0, { 1 }, 'callee')
        local r = law(T0, D, Vs, Is)
        assert.same({ 1, 2, 3 }, r.kept)
        for i = 1, 3 do assert.is_true(A.eq(r.values[i].callee, name 'register')) end
    end)

    it('dig at the root swallows every hole: each member\'s value is its own instance (abstract, inverted)', function()
        local D = A.dig(T0, {}, 'all')
        assert.is_nil(D.holes.key); assert.is_nil(D.holes.fn)
        local r = law(T0, D, Vs, Is)
        for i = 1, 3 do
            assert.is_true(A.eq(r.values[i].all, Is[i]))
            assert.is_nil(r.values[i].key); assert.is_nil(r.values[i].fn)
        end
    end)

    it('a dig whose domain refuses drops the whole family with the domain\'s reason', function()
        local D = A.dig(T0, { 1 }, 'callee', A.closed(name 'other'))
        local r = law(T0, D, Vs, Is)
        assert.same({}, r.kept)
        assert.equals(3, #r.dropped)
        assert.truthy(r.dropped[1].why:find('domain refuses'))
    end)

    it('merge keeps the members whose two values agree and forgets the second hole', function()
        local F = A.template(node('f', hole 'a', hole 'b'))
        local Js = { node('f', lit(1), lit(1)), node('f', lit(1), lit(2)), node('f', lit(3), lit(3)) }
        local Ws = {}
        for i, J in ipairs(Js) do Ws[i] = A.match(F, J).values end
        local Fm = A.merge(F, 'a', 'b')
        local r = law(F, Fm, Ws, Js)
        assert.same({ 1, 3 }, r.kept)
        assert.equals('merge a/b: values differ', r.dropped[1].why)
        assert.is_nil(r.values[1].b)
        assert.is_true(A.eq(r.values[3].a, lit(3)))
    end)

    it('split duplicates the value into the new hole; an outsider now fits but is not adopted', function()
        local Fm = A.template(node('f', hole 'a', hole 'a'))
        local Js = { node('f', lit(1), lit(1)), node('f', lit(3), lit(3)) }
        local Ws = {}
        for i, J in ipairs(Js) do Ws[i] = A.match(Fm, J).values end
        local Fs = A.split(Fm, 'a', 2, 'b')
        local r = law(Fm, Fs, Ws, Js)
        assert.same({ 1, 2 }, r.kept)
        assert.is_true(A.eq(r.values[2].b, lit(3)))
        assert.is_true(A.match(Fs, node('f', lit(1), lit(2))).ok)   -- fits Fs
        assert.equals(2, #r.kept)                                   -- family unchanged
    end)

    it('repetition holes: pin binds a sequence, dig across a repetition renders it', function()
        local R = A.template(node('f', hole('xs', true), lit 'end'))
        local Js = { node('f', lit(1), lit(2), lit 'end'), node('f', lit(1), lit 'end'), node('f', lit(1), lit(2), lit 'end') }
        local Ws = {}
        for i, J in ipairs(Js) do Ws[i] = A.match(R, J).values end
        local P = A.pin(R, 'xs', seq { lit(1), lit(2) })
        local r = law(R, P, Ws, Js)
        assert.same({ 1, 3 }, r.kept)
        local D = A.dig(R, {}, 'all')
        local r2 = law(R, D, Ws, Js)
        assert.same({ 1, 2, 3 }, r2.kept)
        assert.is_nil(r2.values[2].xs)
        assert.is_true(A.eq(r2.values[2].all, Js[2]))
    end)

    it('a migration replays the recorded edits and refuses a T1 that is not T0 plus edits', function()
        local other = A.template(call('other', hole 'key', hole 'fn'))
        local P = A.pin(other, 'key', lit 'on_tick')
        local r, why = A.migrate(T0, P, Vs)
        assert.is_nil(r)
        assert.equals('T1 is not T0 plus its recorded edits', why)
    end)

    it('LAW over random families and random edit sequences (both runtimes, fixed seeds)', function()
        local function lcg(seed)
            local s = seed
            return function(n) s = (s * 1103515245 + 12345) % 2147483648; return (s % n) + 1 end
        end
        local function rand_tree(rnd, budget)
            local labels = { 'a', 'b', 'c' }
            local t = node(labels[rnd(3)])
            budget = budget - 1
            while budget > 0 and rnd(2) == 1 do
                local kid = rand_tree(rnd, rnd(budget))
                t.kids[#t.kids + 1] = kid
                budget = budget - A.size(kid)
            end
            return t
        end
        local function paths_of(t, pred) -- paths of nodes satisfying pred, root first
            local out = {}
            local function walk(x, path)
                if A.is_hole(x) then return end
                if pred(x) then out[#out + 1] = path end
                for i, c in ipairs(x.kids or {}) do
                    local p = {}
                    for j = 1, #path do p[j] = path[j] end
                    p[#p + 1] = i
                    walk(c, p)
                end
            end
            walk(t, {})
            return out
        end
        local function set_at(t, path, v, i)
            i = i or 1
            if i > #path then return A.copy(v) end
            local c = A.copy(t)
            c.kids[path[i]] = set_at(t.kids[path[i]], path, v, i + 1)
            return c
        end
        -- a family: one skeleton, 1..3 leaf positions varied over a small shared pool, so
        -- members agree at a position sometimes (pinnable) and at two positions sometimes
        -- (non-linear holes: mergeable, splittable)
        local pool = { lit(1), lit(2), node('a', lit(1)) }
        local function family(rnd)
            local skel = rand_tree(rnd, 9)
            local leaves = paths_of(skel, function(x) return #(x.kids or {}) == 0 end)
            local k = math.min(#leaves, rnd(3))
            local Js = {}
            for i = 1, 3 do
                local J = skel
                for j = 1, k do J = set_at(J, leaves[j], pool[rnd(3)]) end
                Js[i] = J
            end
            return Js
        end
        local function applicable(rnd, T, cur, alive) -- every edit that applies right now
            local names, H, out = A.hole_names(T), A.sites(T), {}
            for _, h in ipairs(names) do
                local donors = {}
                for i, V in pairs(cur) do if alive[i] then donors[#donors + 1] = V[h] end end
                if #donors > 0 then out[#out + 1] = function() return A.pin(T, h, donors[rnd(#donors)]) end end
                if T.holes[h].was then out[#out + 1] = function() return A.open_hole(T, h) end end
                if #H[h].sites > 1 then out[#out + 1] = function() return A.split(T, h, 2, h .. '_s' .. #T.edits) end end
                for _, g in ipairs(names) do
                    if g ~= h then out[#out + 1] = function() return A.merge(T, h, g) end end
                end
            end
            local ps = paths_of(T.body, function() return true end)
            if #ps > 0 then out[#out + 1] = function() return A.dig(T, ps[rnd(#ps)], 'd' .. #T.edits) end end
            return out
        end
        local kept_n, dropped_n, per = 0, 0, {}
        for seed = 1, 200 do
            local rnd = lcg(seed)
            local Js = family(rnd)
            local g = A.generalize(Js, { need = 100 })
            local T, cur = g.template, g.values
            local alive = { true, true, true }
            for _ = 1, 5 do
                local cands = applicable(rnd, T, cur, alive)
                if #cands == 0 then break end
                local T2 = cands[rnd(#cands)]()
                local op = T2.edits[#T2.edits]
                per[op.op] = (per[op.op] or 0) + 1
                for i = 1, 3 do
                    if alive[i] then
                        local W = A.migrate_one(T, T2, op, cur[i])
                        if W then
                            kept_n = kept_n + 1
                            local inst = A.instantiate(T2, W)
                            assert.is_true(inst.ok and A.eq(inst.term, Js[i]),
                                'seed ' .. seed .. ': kept member ' .. i .. ' must rebuild ' .. A.show(Js[i]))
                            assert.is_true(A.match(T2, Js[i]).ok, 'seed ' .. seed .. ': kept must match')
                            cur[i] = W
                        else
                            dropped_n = dropped_n + 1
                            alive[i] = false
                            assert.is_false(A.match(T2, Js[i]).ok,
                                'seed ' .. seed .. ': dropped member ' .. i .. ' must be refused by ' .. A.show(T2.body))
                        end
                    end
                end
                T = T2
            end
        end
        -- vacuity guard: every edit kind fired, and both outcomes occurred
        for _, op in ipairs { 'pin', 'open', 'dig', 'merge', 'split' } do
            assert.is_true((per[op] or 0) >= 10, op .. ' fired only ' .. tostring(per[op]) .. ' times')
        end
        assert.is_true(kept_n > 200 and dropped_n > 50, 'kept ' .. kept_n .. ' dropped ' .. dropped_n)
    end)
end)

describe('instantiate by editing, propagate by commitment (classify / propagate)', function()
    local T = A.template(call('register', hole 'key', hole 'fn'))
    local Is = {
        call('register', lit 'on_tick', name 'tick'),
        call('register', lit 'on_draw', name 'draw'),
        call('register', lit 'on_tick', name 'tick2'),
    }
    local Vs = {}
    for i, I in ipairs(Is) do Vs[i] = A.match(T, I).values end

    -- every non-straddle classification rebuilds the edited instance from (T', V')
    local function rebuilds(C, I2)
        local r = A.instantiate(C.template, C.values)
        return r.ok and A.eq(r.term, I2)
    end

    it('an unchanged instance classifies as none', function()
        assert.equals('none', A.classify(T, Vs[1], Is[1]).kind)
    end)

    it('a change inside a hole is a VALUE edit; the value class and the others are the clusters', function()
        local I2 = call('register', lit 'on_frame', name 'tick')
        local C = A.classify(T, Vs[1], I2)
        assert.equals('value', C.kind)
        assert.equals(1, #C.changed)
        assert.equals('key', C.changed[1].h)
        assert.is_true(A.eq(C.changed[1].to, lit 'on_frame'))
        assert.is_true(rebuilds(C, I2))
        local P = A.propagate(T, C, Vs, 1)
        local hc = P.values.holes[1]
        assert.same({ 1, 3 }, hc.class)                  -- members whose key is on_tick
        assert.equals(1, #hc.others)
        assert.same({ 2 }, hc.others[1].members)         -- on_draw
        -- preview for a class member: only the key moves
        assert.is_true(A.eq(hc.preview(3), call('register', lit 'on_frame', name 'tick2')))
        -- commit per scope: the template never changes, values do
        local byclass = P.values.commit('class')
        assert.is_true(A.eq(byclass[3].key, lit 'on_frame'))
        assert.is_true(A.eq(byclass[2].key, lit 'on_draw'))
        local bymember = P.values.commit('member')
        assert.is_true(A.eq(bymember[3].key, lit 'on_tick'))
        local all = P.values.commit('all')
        assert.is_true(A.eq(all[2].key, lit 'on_frame'))
        assert.is_nil(P.template)
    end)

    it('a change in the fixed part is a TEMPLATE edit recorded as a rewrite; previews for everyone', function()
        local I2 = call('subscribe', lit 'on_draw', name 'draw')
        local C = A.classify(T, Vs[2], I2)
        assert.equals('template', C.kind)
        assert.equals(0, #C.changed)
        assert.same({ { 1 } }, C.regions)
        assert.equals('rewrite', C.template.edits[#C.template.edits].op)
        assert.is_true(rebuilds(C, I2))
        local P = A.propagate(T, C, Vs, 2, nil, { instances = Is })
        assert.same({ 1, 2, 3 }, P.template.clean)
        assert.same({}, P.template.refused)
        assert.same({}, P.template.drifted)
        assert.is_true(A.eq(P.template.preview(1), call('subscribe', lit 'on_tick', name 'tick')))
        local R = P.template.commit({ 1, 2 })
        assert.is_true(A.eq(R.families[1].template.body, C.template.body))
        assert.is_true(A.eq(A.instantiate(R.families[1].template, R.families[1].values[1]).term, call('subscribe', lit 'on_tick', name 'tick')))
        assert.is_nil(R.families[1].values[3])
        assert.is_true(A.eq(A.instantiate(R.families[2].template, R.families[2].values[3]).term, Is[3]))
        -- the link remembers they were one family: the callee is the only difference
        assert.equals('(call ?j1 ?key ?fn)', A.show(R.link.body))
        assert.equals('{name}', A.show_domain(R.link.holes.j1.domain)) -- DOMAINS.md: the one summary policy is kinds
    end)

    it('a wrapper RELOCATES the holes: still a template edit, values untouched', function()
        local I2 = node('if', name 'enabled', Is[1])
        local C = A.classify(T, Vs[1], I2)
        assert.equals('template', C.kind)
        assert.equals(2, #C.relocated)
        assert.equals('(if enabled (call register ?key ?fn))', A.show(C.template.body))
        assert.is_true(A.values_eq(C.values, Vs[1]))
        assert.is_true(rebuilds(C, I2))
        local P = A.propagate(T, C, Vs, 1)
        assert.same({ 1, 2, 3 }, P.template.clean)
        assert.is_true(A.eq(P.template.preview(2), node('if', name 'enabled', Is[2])))
    end)

    it('fixed part and a value together is MIXED: the template part propagates, the value stays local', function()
        local I2 = call('subscribe', lit 'on_frame', name 'tick')
        local C = A.classify(T, Vs[1], I2)
        assert.equals('mixed', C.kind)
        assert.equals(1, #C.changed); assert.equals(1, #C.regions)
        assert.is_true(rebuilds(C, I2))
        local P = A.propagate(T, C, Vs, 1)
        assert.same({ 1, 3 }, P.values.holes[1].class)
        assert.same({ 1, 2, 3 }, P.template.clean)
        local R = P.template.commit({ 1, 2, 3 })
        -- the witness keeps its own new value; the others only get the template change
        assert.is_true(A.eq(A.instantiate(R.families[1].template, R.families[1].values[1]).term, I2))
        assert.is_true(A.eq(A.instantiate(R.families[1].template, R.families[1].values[3]).term, call('subscribe', lit 'on_tick', name 'tick2')))
    end)

    it('one site of a non-linear hole changed is a STRADDLE proposing a split; after the split it is a value edit', function()
        local F = A.template(node('f', hole 'a', hole 'a'))
        local Js = { node('f', lit(1), lit(1)), node('f', lit(3), lit(3)) }
        local Ws = {}
        for i, J in ipairs(Js) do Ws[i] = A.match(F, J).values end
        local J2 = node('f', lit(1), lit(2))
        local C = A.classify(F, Ws[1], J2)
        assert.equals('straddle', C.kind)
        assert.equals('split', C.proposal.op)
        assert.same({ 2 }, C.proposal.sites)
        assert.is_nil(A.propagate(F, C, Ws, 1).values)
        -- the abstraction moves first, values follow (migrate), then the edit classifies
        local F2 = A.split(F, 'a', 2, 'b')
        local mig = A.migrate(F, F2, Ws)
        local C2 = A.classify(F2, mig.values[1], J2)
        assert.equals('value', C2.kind)
        assert.equals('b', C2.changed[1].h)
        -- and both sites changed together is a plain value edit of the shared hole
        local C3 = A.classify(F, Ws[1], node('f', lit(7), lit(7)))
        assert.equals('value', C3.kind)
    end)

    it('a shared hole changed at one site and wrapped at the other is a STRADDLE (store law), proposing a split', function()
        local F = A.template(node('f', hole 'a', node('g', hole 'a')))
        local W = { a = lit(1) }
        local J2 = node('f', lit(2), node('w', node('g', lit(1))))
        local C = A.classify(F, W, J2)
        assert.equals('straddle', C.kind)
        assert.equals('split', C.proposal.op)
        assert.same({ 1 }, C.proposal.sites)
        assert.truthy(C.why:find('store law'))
    end)

    it('a value that vanished from a rewritten region, or occurs twice in it, is a STRADDLE', function()
        local gone = A.classify(T, Vs[1], call('register', name 'tick'))
        assert.equals('straddle', gone.kind)
        assert.equals('key', gone.hole); assert.equals(0, gone.occurrences)
        assert.is_nil(gone.proposal); assert.truthy(gone.hint:find('hole removed'))
        local G = A.template(node('g', hole 'x'))
        local W = { x = lit 'c' }
        local twice = A.classify(G, W, node('h', lit 'c', lit 'c'))
        assert.equals('straddle', twice.kind)
        assert.equals(2, twice.occurrences)
        assert.is_nil(twice.proposal); assert.truthy(twice.hint:find('ambiguous'))
    end)

    it('a new value a SUPPLIED domain refuses is a STRADDLE; a DERIVED domain widens and says so (DOMAINS.md)', function()
        local K = A.template(call('register', hole 'key', hole 'fn'), { key = A.kinds { 'lit' } }) -- a bare domain is a premise
        assert.equals('supplied', K.holes.key.origin)
        local C = A.classify(K, Vs[1], call('register', name 'dyn', name 'tick'))
        assert.equals('straddle', C.kind)
        assert.truthy(C.why:find('domain refuses'))
        assert.is_nil(C.proposal); assert.truthy(C.hint:find('supplied domain refuses'))
        -- the same family with a derived summary: the observation widens the domain
        local g = A.generalize(Is, { need = 100 })
        assert.equals('derived', g.template.holes.h1.origin)
        assert.equals('{lit}', A.show_domain(g.template.holes.h1.domain))
        local C2 = A.classify(g.template, g.values[1], call('register', name 'dyn', name 'tick'))
        assert.equals('value', C2.kind)
        assert.same({ { h = 'h1', from = '{lit}', to = '{lit|name}' } }, C2.widened)
        assert.equals('{lit|name}', A.show_domain(C2.template.holes.h1.domain))
        assert.equals('{lit}', A.show_domain(g.template.holes.h1.domain)) -- the caller's template is untouched
        -- propagate previews and commits against the widened template, which the family adopts
        local P = A.propagate(g.template, C2, g.values, 1)
        assert.is_true(A.eq(P.values.holes[1].preview(2), call('register', name 'dyn', name 'draw')))
        assert.same(C2.widened, P.values.widened)
        local new = P.values.commit('all')
        for j = 1, 3 do assert.is_true(A.instantiate(P.values.template, new[j]).ok) end
    end)

    it('an appended argument relocates the holes by value occurrence (the old region is not intact)', function()
        local I2 = call('register', lit 'on_tick', name 'tick', lit 'extra')
        local C = A.classify(T, Vs[1], I2)
        assert.equals('template', C.kind)
        assert.equals(2, #C.relocated)
        assert.equals('(call register ?key ?fn "extra")', A.show(C.template.body))
        assert.is_true(rebuilds(C, I2))
        local P = A.propagate(T, C, Vs, 1)
        assert.same({ 1, 2, 3 }, P.template.clean)
        assert.is_true(A.eq(P.template.preview(2), call('register', lit 'on_draw', name 'draw', lit 'extra')))
    end)

    it('a rewrite may relocate or duplicate a hole but never discard one; filling is pin', function()
        local F, why = A.rewrite(T, { 2 }, lit 'on_tick')
        assert.is_nil(F)
        assert.truthy(why:find('discard hole key'))
        -- duplicating: a guard that mentions the value makes the template non-linear
        local G = A.rewrite(T, {}, node('if', hole 'key', call('register', hole 'key', hole 'fn')))
        assert.equals(2, #A.sites(G).key.sites)
        local r = A.migrate(T, G, Vs)
        assert.same({ 1, 2, 3 }, r.kept)
        assert.is_true(A.eq(A.instantiate(G, r.values[2]).term, node('if', lit 'on_draw', Is[2])))
    end)

    it('LAW over random families: synthetic edits classify as intended and rebuild; propagation keeps everyone', function()
        local function lcg(seed)
            local s = seed
            return function(n) s = (s * 1103515245 + 12345) % 2147483648; return (s % n) + 1 end
        end
        local function rand_tree(rnd, budget)
            local labels = { 'a', 'b', 'c' }
            local t = node(labels[rnd(3)])
            budget = budget - 1
            while budget > 0 and rnd(2) == 1 do
                local kid = rand_tree(rnd, rnd(budget))
                t.kids[#t.kids + 1] = kid
                budget = budget - A.size(kid)
            end
            return t
        end
        local function paths_of(t, pred, into_holes)
            local out = {}
            local function walk(x, path)
                if A.is_hole(x) and not into_holes then return end
                if pred(x, path) then out[#out + 1] = path end
                for i, c in ipairs(x.kids or {}) do
                    local p = {}
                    for j = 1, #path do p[j] = path[j] end
                    p[#p + 1] = i
                    walk(c, p)
                end
            end
            walk(t, {})
            return out
        end
        local function set_at(t, path, v, i)
            i = i or 1
            if i > #path then return A.copy(v) end
            local c = A.copy(t)
            c.kids[path[i]] = set_at(t.kids[path[i]], path, v, i + 1)
            return c
        end
        local function has_hole(t)
            if A.is_hole(t) then return true end
            for _, c in ipairs(t.kids or {}) do if has_hole(c) then return true end end
            return false
        end
        local pool = { lit(1), lit(2), node('a', lit(1)) }
        local counts = { value = 0, template = 0, wrap = 0, straddle = 0 }
        for seed = 1, 150 do
            local rnd = lcg(seed)
            local skel = rand_tree(rnd, 9)
            local leaves = paths_of(skel, function(x) return #(x.kids or {}) == 0 end)
            local k = math.min(#leaves, rnd(3))
            local Js = {}
            for i = 1, 3 do
                local J = skel
                for j = 1, k do J = set_at(J, leaves[j], pool[rnd(3)]) end
                Js[i] = J
            end
            local g = A.generalize(Js, { need = 100 })
            local T0, Vs0 = g.template, g.values
            local names = A.hole_names(T0)
            local H = A.sites(T0)
            local i = rnd(3)
            local which = rnd(3)
            local I2, expect
            if which == 1 and #names > 0 then
                -- a value edit: the same fresh value at EVERY site of one hole
                local h = names[rnd(#names)]
                I2 = Js[i]
                for _, s in ipairs(H[h].sites) do I2 = set_at(I2, s.path, lit(99)) end
                expect = 'value'
            elseif which == 2 then
                -- a fixed-part edit: a hole-free fixed subtree becomes a fresh literal
                local ps = paths_of(T0.body, function(x) return not has_hole(x) end)
                if #ps == 0 then I2 = nil else
                    local p = ps[rnd(#ps)]
                    I2 = set_at(Js[i], p, lit(77))
                    expect = 'template'
                end
            else
                I2 = node('w', lit(0), Js[i])
                expect = 'wrap'
            end
            if I2 then
                local C = A.classify(T0, Vs0[i], I2)
                local want = expect == 'wrap' and 'template' or expect
                assert.equals(want, C.kind, 'seed ' .. seed .. ' ' .. expect .. ': ' .. tostring(C.why))
                counts[expect] = counts[expect] + 1
                local r = A.instantiate(C.template, C.values)
                assert.is_true(r.ok and A.eq(r.term, I2), 'seed ' .. seed .. ': must rebuild')
                if expect == 'wrap' then
                    local nsites = 0
                    for _, h in ipairs(names) do nsites = nsites + #H[h].sites end
                    assert.equals(nsites, #C.relocated) -- one relocation per SITE
                end
                local P = A.propagate(T0, C, Vs0, i)
                if P.template then
                    assert.equals(3, #P.template.clean, 'seed ' .. seed .. ': a fixed-part change keeps everyone')
                    for j = 1, 3 do
                        -- every preview is the old instance with the same change applied
                        local prev = P.template.preview(j)
                        assert.is_true(A.match(C.template, prev).ok)
                        if expect == 'wrap' then assert.is_true(A.eq(prev, node('w', lit(0), Js[j]))) end
                    end
                end
                if P.values then
                    local hc = P.values.holes[1]
                    local new = P.values.commit('class')
                    for _, j in ipairs(hc.class) do assert.is_true(A.eq(new[j][hc.h], lit(99))) end
                end
            end
        end
        assert.is_true(counts.value >= 30 and counts.template >= 30 and counts.wrap >= 30,
            'value ' .. counts.value .. ' template ' .. counts.template .. ' wrap ' .. counts.wrap)
    end)
end)

describe('incremental join: a stored template moves up by exactly what a newcomer needs', function()
    local T = A.template(call('register', hole 'key', hole 'fn'))
    local Is = {
        call('register', lit 'on_tick', name 'tick'),
        call('register', lit 'on_draw', name 'draw'),
        call('register', lit 'on_tick', name 'tick2'),
    }
    local Vs = {}
    for i, I in ipairs(Is) do Vs[i] = A.match(T, I).values end
    local function all_rebuild(J, values, instances)
        for j, I in ipairs(instances) do
            local r = A.instantiate(J, values[j])
            if not (r.ok and A.eq(r.term, I)) then return false, j end
        end
        return true
    end

    it('a newcomer that already fits is ADOPTED: template unchanged, values read off', function()
        local I = call('register', lit 'on_key', name 'key')
        local r = A.adjoin(T, Vs, I)
        assert.is_true(A.iso(r.template, T)) -- the body is unchanged
        assert.same({}, r.join.new); assert.same({}, r.join.split); assert.same({}, r.join.widened)
        -- derived domains are summaries of the column, refreshed on adoption (T's were open: no evidence yet)
        assert.equals('{lit}', A.show_domain(r.template.holes.key.domain))
        assert.equals('{name}', A.show_domain(r.template.holes.fn.domain))
        assert.is_true(A.eq(r.values[4].key, lit 'on_key'))
        assert.is_true(all_rebuild(r.template, r.values, { Is[1], Is[2], Is[3], I }))
    end)

    it('a fixed position that differs becomes a NEW hole; old members get the old fixed text as its value', function()
        local I = call('subscribe', lit 'on_tick', name 'tick')
        local r = A.adjoin(T, Vs, I)
        assert.equals('(call ?j1 ?key ?fn)', A.show(r.template.body))
        assert.same({ 'j1' }, r.join.new)
        assert.same({ 'fn', 'key' }, (function() local k = r.join.kept; table.sort(k); return k end)())
        assert.is_true(A.eq(r.values[2].j1, name 'register'))
        assert.is_true(A.eq(r.values[4].j1, name 'subscribe'))
        assert.is_true(all_rebuild(r.template, r.values, { Is[1], Is[2], Is[3], I }))
        -- the new hole's domain is exact: the two callees, as alternatives
        assert.equals('{name}', A.show_domain(r.template.holes.j1.domain)) -- DOMAINS.md: kinds, not an enumeration
    end)

    it('a hole facing different partners at its sites SPLITS; hole names are kept for the store', function()
        local F = A.template(node('f', hole 'a', hole 'a'))
        local Js = { node('f', lit(1), lit(1)), node('f', lit(3), lit(3)) }
        local Ws = {}
        for i, J in ipairs(Js) do Ws[i] = A.match(F, J).values end
        local I = node('f', lit(1), lit(2))
        local r = A.adjoin(F, Ws, I)
        assert.equals('(f ?a ?a_2)', A.show(r.template.body))
        assert.same({ { from = 'a', to = 'a_2' } }, r.join.split)
        assert.is_true(A.eq(r.values[1].a, lit(1)) and A.eq(r.values[1].a_2, lit(1)))
        assert.is_true(A.eq(r.values[3].a, lit(1)) and A.eq(r.values[3].a_2, lit(2)))
        assert.is_true(all_rebuild(r.template, r.values, { Js[1], Js[2], I }))
        -- and it agrees with batch generalization
        assert.is_true(A.iso(r.template, A.generalize({ Js[1], Js[2], I }, { need = 100 }).template))
    end)

    it('a SUPPLIED domain is kept; a newcomer that would widen it is refused unless forced, and join records the override (DOMAINS.md)', function()
        local K = A.template(call('register', hole 'key', hole 'fn'), { key = A.kinds { 'lit' } })
        local same = A.adjoin(K, Vs, call('register', lit 'on_key', name 'k'))
        assert.equals('{lit}', A.show_domain(same.template.holes.key.domain))
        assert.equals('supplied', same.template.holes.key.origin)
        assert.same({}, same.join.widened)
        local wider, why, j = A.adjoin(K, Vs, call('register', name 'dyn', name 'k'))
        assert.is_nil(wider); assert.truthy(why:find('supplied domain of hole key'))
        -- join itself stayed total: it is above both inputs, and says which premise it overrode
        assert.same({ { h = 'key', from = '{lit}', to = '{lit|name}' } }, j.overrode)
        assert.is_true(A.match(j.template, call('register', name 'dyn', name 'k')).ok)
        local forced = A.adjoin(K, Vs, call('register', name 'dyn', name 'k'), { force = true })
        assert.equals('{lit|name}', A.show_domain(forced.template.holes.key.domain))
        assert.same({ { h = 'key', from = '{lit}', to = '{lit|name}' } }, forced.join.widened)
        -- a pinned hole facing its own value stays pinned; facing another value the newcomer is refused
        local P = A.pin(T, 'key', lit 'on_tick')
        local Pm = A.migrate(T, P, Vs)
        local r1 = A.adjoin(P, Pm.values, call('register', lit 'on_tick', name 'z'))
        assert.equals('="on_tick"', A.show_domain(r1.template.holes.key.domain))
        local r2, why2 = A.adjoin(P, Pm.values, call('register', lit 'on_draw', name 'z'))
        assert.is_nil(r2); assert.truthy(why2:find('open the pin'))
    end)

    it('join_domain: under the default (kinds) two literals summarise as {lit}; under the enumerate knob, alternatives up to the cap; open absorbs; ref collapses to open', function()
        assert.equals('{lit}', A.show_domain(A.join_domain(A.closed(lit 'a'), A.closed(lit 'b'))))
        local E = { summary = 'enumerate' }
        local d = A.join_domain(A.closed(lit 'a'), A.closed(lit 'b'), E)
        assert.equals('(="a" | ="b")', A.show_domain(d))
        d = A.join_domain(d, A.closed(lit 'c'), E)
        assert.equals('(="a" | ="b" | ="c")', A.show_domain(d))
        d = A.join_domain(d, A.closed(lit 'd'), E)
        assert.equals('{lit}', A.show_domain(d))
        assert.equals('{lit|name}', A.show_domain(A.join_domain(A.kinds { 'lit' }, A.closed(name 'x'))))
        assert.equals('*', A.show_domain(A.join_domain(A.kinds { 'lit' }, A.open())))
        assert.equals('*', A.show_domain(A.join_domain(A.ref 'expr', A.closed(lit(1)))))
    end)

    it('an operator\'s dig survives a join the newcomer agrees with; batch generalize would not have it', function()
        local D = A.dig(T, { 1 }, 'callee')
        local Dm = A.migrate(T, D, Vs)
        local I = call('register', lit 'on_key', name 'k')
        local r = A.adjoin(D, Dm.values, I)
        assert.is_true(A.iso(r.template, D))
        assert.is_true(A.eq(r.values[4].callee, name 'register'))
        local batch = A.generalize({ Is[1], Is[2], Is[3], I }, { need = 100 }).template
        assert.is_false(A.iso(batch, r.template))
        assert.is_true(A.instance_of(batch, r.template)) -- the joined template sits above the batch lgg
    end)

    it('a newcomer with a different root swallows the whole template: each old member\'s instance is its value', function()
        local I = node('other')
        local r = A.adjoin(T, Vs, I)
        assert.equals('?j1', A.show(r.template.body))
        assert.is_true(A.eq(r.values[1].j1, Is[1]))
        assert.is_nil(r.values[1].key)
        assert.is_true(A.eq(r.values[4].j1, I))
    end)

    it('joining two TEMPLATES merges two families; a hole facing a hole keeps the left name and joins domains', function()
        local T2 = A.template(call('subscribe', hole 'key', hole 'fn'), { key = A.kinds { 'lit' } })
        local r = A.join(T, T2)
        assert.equals('(call ?j1 ?key ?fn)', A.show(r.template.body))
        assert.equals('*', A.show_domain(r.template.holes.key.domain)) -- open ⊔ {lit}
        local W = r.right({ key = lit 'x', fn = name 'y' })
        assert.is_true(A.eq(W.j1, name 'subscribe'))
        assert.is_true(A.eq(A.instantiate(r.template, W).term, call('subscribe', lit 'x', name 'y')))
    end)

    it('join is the seventh recorded edit: pins stay undoable and migrate replays across it', function()
        local P = A.pin(T, 'key', lit 'on_tick')
        local Pm = A.migrate(T, P, Vs)
        local r = A.adjoin(P, Pm.values, call('register', lit 'on_tick', name 'z'))
        assert.equals('join', r.template.edits[#r.template.edits].op)
        assert.equals(#P.edits + 1, #r.template.edits)
        local O = A.open_hole(r.template, 'key') -- would fail with "never pinned" on a fresh template
        assert.truthy(O)
        assert.equals('*', A.show_domain(O.holes.key.domain))
        -- the family's values across the join by replay equal adjoin's
        local I = call('subscribe', lit 'on_tick', name 'tick')
        local r2 = A.adjoin(T, Vs, I)
        local mig = A.migrate(T, r2.template, Vs)
        assert.same({ 1, 2, 3 }, mig.kept)
        for j = 1, 3 do assert.is_true(A.values_eq(mig.values[j], r2.values[j])) end
    end)

    it('LAW: join(generalize(J1..Jn), I) ≅ generalize(J1..Jn, I), and folding join from one instance is batch generalize', function()
        -- high bits of the LCG: its low bits cycle with period 4, which made rnd(4) constant
        local function lcg(seed)
            local s = seed
            return function(n) s = (s * 1103515245 + 12345) % 2147483648; return (math.floor(s / 65536) % n) + 1 end
        end
        local function rand_tree(rnd, budget)
            local labels = { 'a', 'b', 'c' }
            local t = node(labels[rnd(3)])
            budget = budget - 1
            while budget > 0 and rnd(2) == 1 do
                local kid = rand_tree(rnd, rnd(budget))
                t.kids[#t.kids + 1] = kid
                budget = budget - A.size(kid)
            end
            return t
        end
        local function leaves_of(t)
            local out = {}
            local function walk(x, path)
                if #(x.kids or {}) == 0 then out[#out + 1] = path end
                for i, c in ipairs(x.kids or {}) do
                    local p = {}
                    for j = 1, #path do p[j] = path[j] end
                    p[#p + 1] = i
                    walk(c, p)
                end
            end
            walk(t, {})
            return out
        end
        local function set_at(t, path, v, i)
            i = i or 1
            if i > #path then return A.copy(v) end
            local c = A.copy(t)
            c.kids[path[i]] = set_at(t.kids[path[i]], path, v, i + 1)
            return c
        end
        local pool = { lit(1), lit(2), node('a', lit(1)), node('b', lit(2), lit(2)) }
        local splits, news, kepts = 0, 0, 0
        for seed = 1, 300 do
            local rnd = lcg(seed)
            local skel = rand_tree(rnd, 9)
            local leaves = leaves_of(skel)
            local k = math.min(#leaves, rnd(4))
            -- the family of three draws from two values so it agrees often (fixed positions,
            -- non-linear holes); the newcomer draws from four so it disagrees often
            local Js = {}
            for i = 1, 4 do
                local J = skel
                for j = 1, k do J = set_at(J, leaves[j], pool[i < 4 and rnd(2) or rnd(4)]) end
                Js[i] = J
            end
            -- one step: family of three, then the fourth joins
            local g = A.generalize({ Js[1], Js[2], Js[3] }, { need = 100 })
            local r = assert(A.adjoin(g.template, g.values, Js[4]))
            local batch = A.generalize(Js, { need = 100 })
            assert.is_true(A.iso(r.template, batch.template), 'seed ' .. seed .. ': ' .. A.show(r.template.body) .. ' vs ' .. A.show(batch.template.body))
            assert.is_true(all_rebuild(r.template, r.values, Js), 'seed ' .. seed .. ': rebuild')
            splits, news, kepts = splits + #r.join.split, news + #r.join.new, kepts + #r.join.kept
            -- fold: start from the first instance alone, join the rest one at a time
            local F, Fv = A.template(Js[1]), { {} }
            for i = 2, 4 do
                local s = assert(A.adjoin(F, Fv, Js[i]))
                F, Fv = s.template, s.values
            end
            assert.is_true(A.iso(F, batch.template), 'seed ' .. seed .. ': fold')
            assert.is_true(all_rebuild(F, Fv, Js), 'seed ' .. seed .. ': fold rebuild')
        end
        assert.is_true(splits >= 10 and news >= 30 and kepts >= 50, 'split ' .. splits .. ' new ' .. news .. ' kept ' .. kepts)
    end)
end)

describe('correspondences: attributed instantiation and its composition through a pipeline', function()
    -- values.yaml → a Deployment-like term (the name is used twice) → two namespaces → text
    local values = { name = lit 'frontend', replicas = lit(3) }
    local Dep = A.template(node('Deployment',
        node('metadata', node('Name', hole 'name')),
        node('spec', node('replicas', hole 'replicas'), node('labels', node('app', hole 'name')))))
    local Envs = A.template(node('envs',
        node('ns', lit 'staging', hole 'd'),
        node('ns', lit 'prod', hole 'd')))
    local stages = { { template = Dep, values = values }, { template = Envs, taken = { d = {} } } }

    local function sound(T, V, tr)
        for pk, o in pairs(tr.origins) do
            local p = {}
            if pk ~= 'root' then for x in pk:gmatch('[^/]+') do p[#p + 1] = tonumber(x) end end
            local here = A.at(tr.term, p)
            if o.src == 'hole' then
                if not A.eq(here, A.at(V[o.hole], o.at)) then return false, pk .. ' hole' end
            else
                local there = A.at(T.body, o.at)
                if there.k ~= here.k then return false, pk .. ' fixed kind' end
                if not there.kids and not A.eq(there, here) then return false, pk .. ' fixed leaf' end
            end
        end
        return true
    end

    it('trace agrees with instantiate and every attribution is sound (point and repetition holes)', function()
        local tr = A.trace(Dep, values)
        assert.is_true(tr.ok)
        assert.is_true(A.eq(tr.term, A.instantiate(Dep, values).term))
        assert.is_true(sound(Dep, values, tr))
        assert.equals('hole', tr.origins['1/1/1'].src); assert.equals('name', tr.origins['1/1/1'].hole)
        assert.equals('fixed', tr.origins['1/1'].src); assert.equals('1/1', A.key(tr.origins['1/1'].at))
        -- a repetition hole: the sequence splices and every element is attributed by its index
        local R = A.template(node('f', hole('xs', true), lit 'end'))
        local Vr = { xs = seq { lit(1), node('g', lit(2)) } }
        local tr2 = A.trace(R, Vr)
        assert.is_true(A.eq(tr2.term, node('f', lit(1), node('g', lit(2)), lit 'end')))
        assert.is_true(sound(R, Vr, tr2))
        assert.equals('2/1', A.key(tr2.origins['2/1'].at)) -- the 2 inside g is element 2, kid 1
        assert.equals('fixed', tr2.origins['3'].src)
    end)

    it('the inverse: every site match reports is attributed to that hole at its root (GetPut)', function()
        local tr = A.trace(Dep, values)
        local m = A.match(Dep, tr.term)
        for h, e in pairs(m.sites) do
            for _, s in ipairs(e.sites) do
                local o = tr.origins[A.key(s.path)]
                assert.equals(h, o.hole); assert.equals('root', A.key(o.at))
            end
        end
        assert.equals(2, #m.sites.name.sites) -- the non-linear hole: one value, two sites
    end)

    it('a pipeline composes: a final position traces back through the taken hole to values.yaml', function()
        local P = A.pipeline(stages)
        assert.is_true(P.ok)
        -- envs / ns prod / Deployment / metadata / name
        local o = P.origin { 2, 2, 1, 1, 1 }
        assert.equals('hole', o.src); assert.equals(1, o.stage); assert.equals('name', o.hole)
        assert.same({ { stage = 2, at = { 1, 1, 1 } } }, o.via) -- the position it had in the chart output
        -- the namespace literal is fixed by stage 2; the Deployment kind is fixed by stage 1
        assert.same({ src = 'fixed', stage = 2, at = { 2, 1 } }, P.origin { 2, 1 })
        local k = P.origin { 1, 2 }
        assert.equals('fixed', k.src); assert.equals(1, k.stage); assert.equals('root', A.key(k.at))
    end)

    it('impact / uses: the forward image of one values key is every final site, four here', function()
        local P = A.pipeline(stages)
        assert.same({ '1/2/1/1/1', '1/2/2/2/1/1', '2/2/1/1/1', '2/2/2/2/1/1' }, P.uses(1, 'name'))
        assert.same({ '1/2/2/1/1', '2/2/2/1/1' }, P.uses(1, 'replicas'))
        -- through an intermediate position: the chart output's metadata.name lands twice
        assert.same({ '1/2/1/1/1', '2/2/1/1/1' }, P.impact(1, { 1, 1, 1 }))
        assert.same({}, P.uses(2, 'd')) -- taken holes are not external inputs
    end)

    it('the text stage: an offset maps to a path and from there to values.yaml', function()
        local P = A.pipeline(stages)
        local R = A.render(P.term)
        local off = R.text:find('"frontend"', 1, true) - 1
        local p = A.at_offset(R, off)
        assert.equals('1/2/1/1/1', A.key(p))
        assert.equals('name', P.origin(p).hole)
        -- the innermost span wins: an offset on "(Name" is the Name node, not the Deployment
        local off2 = R.text:find('(Name', 1, true) - 1
        assert.equals('1/2/1/1', A.key(A.at_offset(R, off2)))
        -- every occurrence of the value in the text is one of the four uses
        local n = 0
        for s in R.text:gmatch('()"frontend"') do
            n = n + 1
            local used = false
            for _, u in ipairs(P.uses(1, 'name')) do if u == A.key(A.at_offset(R, s - 1)) then used = true end end
            assert.is_true(used)
        end
        assert.equals(4, n)
    end)

    it('repetition holes: match records one site with a count, trace attributes each spliced element; a chain crosses a splice', function()
        local R = A.template(node('f', hole('xs', true), lit 'end'))
        local Vr = { xs = seq { node('g', lit(1)), node('g', lit(2)) } }
        local tr = A.trace(R, Vr)
        local s = A.match(R, tr.term).sites.xs.sites[1]
        assert.equals(2, s.n)
        local parent, idx = { unpack(s.path, 1, #s.path - 1) }, s.path[#s.path]
        for j = 1, s.n do
            local p = { unpack(parent) }
            p[#p + 1] = idx + j - 1
            local o = tr.origins[A.key(p)]
            assert.equals('xs', o.hole); assert.same({ j }, o.at)
        end
        -- stage 2 takes the literal inside the second spliced element
        local P = A.pipeline { { template = R, values = Vr }, { template = A.template(node('h', hole 't', lit 'k')), taken = { t = { 2, 1 } } } }
        assert.is_true(P.ok, P.why)
        local o = P.origin { 1 }
        assert.equals('xs', o.hole); assert.same({ 2, 1 }, o.at); assert.same({ { stage = 2, at = { 2, 1 } } }, o.via)
        assert.same({ '1' }, P.impact(1, { 2, 1 }))
        assert.same({ '1' }, P.impact(2, { 1 })) -- the final stage: a position is its own image
    end)

    it('composition is associative and sound over three stages, including a repetition splice', function()
        local Wrap = A.template(node('list', hole('items', true), node('tail', hole 'x')))
        -- stage 3 takes the prod Deployment's name into x and splices its own items
        local three = {
            { template = Dep, values = values },
            { template = Envs, taken = { d = {} } },
            { template = Wrap, taken = { x = { 2, 2, 1, 1, 1 } }, values = { items = seq { lit 'a', lit 'b' } } },
        }
        local P = A.pipeline(three)
        assert.is_true(P.ok, P.why)
        -- (c3 ∘ c2) ∘ c1 == c3 ∘ (c2 ∘ c1), origin by origin
        local c1, c2, c3 = P.corrs[1], P.corrs[2], P.corrs[3]
        local left = A.corr_compose(A.corr_compose(c3, c2, three[3].taken), c1, three[2].taken)
        local right = A.corr_compose(c3, A.corr_compose(c2, c1, three[2].taken), three[3].taken)
        for k, o in pairs(left) do assert.same(o, right[k], k) end
        for k in pairs(right) do assert.truthy(left[k]) end
        -- soundness through the chain: the final leaf equals the source leaf at every hop
        for pk, o in pairs(P.origins) do
            local p = {}
            if pk ~= 'root' then for x in pk:gmatch('[^/]+') do p[#p + 1] = tonumber(x) end end
            local here = A.at(P.term, p)
            for _, v in ipairs(o.via or {}) do
                assert.is_true(A.eq(here, A.at(P.outputs[v.stage - 1], v.at)), pk .. ' via stage ' .. v.stage)
            end
            if o.src == 'hole' then
                local src = three[o.stage].values[o.hole]
                assert.is_true(A.eq(here, A.at(src, o.at)), pk .. ' source')
            end
        end
        -- the tail's x came from values.name through two taken holes
        local o = P.origin { 3, 1 }
        assert.equals('name', o.hole); assert.equals(1, o.stage); assert.equals(2, #o.via)
        -- the spliced items are stage-3 external input
        assert.equals('items', P.origin({ 1 }).hole); assert.equals(3, P.origin({ 1 }).stage)
    end)

    it('LAW over random templates: trace is sound and agrees with instantiate; composition is sound', function()
        local function lcg(seed)
            local s = seed
            return function(n) s = (s * 1103515245 + 12345) % 2147483648; return (math.floor(s / 65536) % n) + 1 end
        end
        local function rand_tree(rnd, budget)
            local labels = { 'a', 'b', 'c' }
            local t = node(labels[rnd(3)])
            budget = budget - 1
            while budget > 0 and rnd(2) == 1 do
                local kid = rand_tree(rnd, rnd(budget))
                t.kids[#t.kids + 1] = kid
                budget = budget - A.size(kid)
            end
            return t
        end
        local function leaves_of(t)
            local out = {}
            local function walk(x, path)
                if #(x.kids or {}) == 0 then out[#out + 1] = path end
                for i, c in ipairs(x.kids or {}) do
                    local p = {}
                    for j = 1, #path do p[j] = path[j] end
                    p[#p + 1] = i
                    walk(c, p)
                end
            end
            walk(t, {})
            return out
        end
        local function set_at(t, path, v, i)
            i = i or 1
            if i > #path then return A.copy(v) end
            local c = A.copy(t)
            c.kids[path[i]] = set_at(t.kids[path[i]], path, v, i + 1)
            return c
        end
        local function all_positions(t)
            local out = {}
            local function walk(x, path)
                out[#out + 1] = path
                for i, c in ipairs(x.kids or {}) do
                    local p = {}
                    for j = 1, #path do p[j] = path[j] end
                    p[#p + 1] = i
                    walk(c, p)
                end
            end
            walk(t, {})
            return out
        end
        local pool = { lit(1), lit(2), node('a', lit(1)), node('b', lit(2), lit(2)) }
        local chains, holes_n = 0, 0
        for seed = 1, 200 do
            local rnd = lcg(seed)
            local skel = rand_tree(rnd, 8)
            local leaves = leaves_of(skel)
            local k = math.min(#leaves, rnd(3))
            local Js = {}
            for i = 1, 3 do
                local J = skel
                for j = 1, k do J = set_at(J, leaves[j], pool[rnd(4)]) end
                Js[i] = J
            end
            local g = A.generalize(Js, { need = 100 })
            local T1, V1 = g.template, g.values[1]
            local tr = A.trace(T1, V1)
            assert.is_true(A.eq(tr.term, Js[1]), 'seed ' .. seed .. ' trace = instantiate')
            assert.is_true(sound(T1, V1, tr), 'seed ' .. seed .. ' sound')
            holes_n = holes_n + #A.hole_names(T1)
            -- stage 2: a random template over a fresh skeleton takes a random position of stage 1's output
            local skel2 = rand_tree(rnd, 6)
            local l2 = leaves_of(skel2)
            local T2 = A.template(set_at(skel2, l2[rnd(#l2)], hole 't'))
            local pos1 = all_positions(Js[1])
            local q = pos1[rnd(#pos1)]
            local P = A.pipeline { { template = T1, values = V1 }, { template = T2, taken = { t = q } } }
            assert.is_true(P.ok, 'seed ' .. seed .. ' pipeline')
            for pk, o in pairs(P.origins) do
                local p = {}
                if pk ~= 'root' then for x in pk:gmatch('[^/]+') do p[#p + 1] = tonumber(x) end end
                local here = A.at(P.term, p)
                for _, v in ipairs(o.via or {}) do
                    chains = chains + 1
                    assert.is_true(A.eq(here, A.at(P.outputs[v.stage - 1], v.at)), 'seed ' .. seed .. ' via')
                end
                if o.src == 'hole' and o.stage == 1 then
                    assert.is_true(A.eq(here, A.at(V1[o.hole], o.at)), 'seed ' .. seed .. ' source')
                end
            end
            -- every final position has an origin; stage-2 fixed ones have no chain
            for _, p in ipairs(all_positions(P.term)) do
                local o = P.origins[A.key(p)]
                assert.truthy(o, 'seed ' .. seed .. ' unattributed ' .. A.key(p))
                if o.src == 'fixed' and o.stage == 2 then assert.is_nil(o.via) end
            end
        end
        assert.is_true(chains > 300 and holes_n > 100, 'chains ' .. chains .. ' holes ' .. holes_n)
    end)
end)

describe('cross-grammar nesting: a hole whose value is text under another grammar', function()
    local sh, kv = A.grammars.sh, A.grammars.kv
    local function doc(image, command) return node('doc', node('image', lit(image)), node('command', lit(command))) end

    it('the toy grammars round-trip and refuse non-canonical text', function()
        for _, s in ipairs { 'run fast', 'run --env A=1,B=2 | tee log', 'ls' } do
            assert.equals(s, (sh.print(sh.parse(s))))
        end
        assert.is_true(A.eq(sh.parse((sh.print(node('cmd', name 'run', lit 'x')))), node('cmd', name 'run', lit 'x')))
        assert.is_nil(sh.parse('run  fast')); assert.is_nil(sh.parse('')); assert.is_nil(sh.parse('a |'))
        for _, s in ipairs { 'A=1', 'A=1,B=two' } do assert.equals(s, (kv.print(kv.parse(s)))) end
        assert.is_nil(kv.parse('A')); assert.is_nil(kv.parse('A=1,,B=2'))
        local _, spans = sh.print(node('cmd', name 'run', lit 'fast'))
        assert.equals(3, #spans) -- run, fast, cmd
    end)

    it('instantiate prints through the boundary and match parses back (PutGet / GetPut), two levels deep', function()
        local T0 = A.template(node('doc', node('image', hole 'img'), node('command', hole 'cmd')))
        local Tsh = A.template(node('cmd', name 'run', lit '--env', hole 'env'))
        local Tkv = A.template(node('kv', node('pair', name 'A', hole 'a'), node('pair', name 'B', hole 'b')))
        local T = A.fill(A.fill(T0, 'cmd', A.embed('sh', Tsh)), 'env', A.embed('kv', Tkv))
        assert.same({ 'a', 'b', 'img' }, (function() local n = A.hole_names(T); table.sort(n); return n end)())
        local V = { img = lit 'x:1', a = lit '1', b = lit '2' }
        local I = A.instantiate(T, V)
        assert.is_true(I.ok)
        assert.is_true(A.eq(I.term, doc('x:1', 'run --env A=1,B=2')))
        local m = A.match(T, I.term)
        assert.is_true(m.ok, m.refusal and m.refusal.why)
        assert.is_true(A.values_eq(m.values, V))
        -- a string that does not parse is refused by name
        local bad = A.match(T, doc('x:1', 'run  --env A=1,B=2'))
        assert.is_false(bad.ok); assert.truthy(bad.refusal.why:find('does not parse'))
        -- the stored data is the inner values, never the string
        assert.is_nil(m.values.cmd); assert.is_nil(m.values.env)
    end)

    it('generalize crosses the boundary when the profile names the grammar, else the string is opaque', function()
        local docs = { doc('x:1', 'run fast'), doc('x:2', 'run slow'), doc('x:3', 'run fast') }
        local opaque = A.generalize(docs, { need = 100 })
        assert.equals('(doc (image ?h1) (command ?h2))', A.show(opaque.template.body))
        local g = A.generalize(docs, { need = 100, grammars = { command = 'sh' } })
        assert.equals('embed', g.template.body.kids[2].kids[1].k)
        assert.equals('(cmd run ?h2.1)', A.show(g.template.body.kids[2].kids[1].kids[1]))
        assert.is_true(A.eq(g.values[2]['h2.1'], lit 'slow'))
        assert.equals('{lit}', A.show_domain(g.template.holes['h2.1'].domain))
        for i, d in ipairs(docs) do assert.is_true(A.eq(A.instantiate(g.template, g.values[i]).term, d)) end
        -- two levels, automatically: the kv inside the shell argument
        local docs2 = { doc('x:1', 'run --env A=1,B=2'), doc('x:2', 'run --env A=1,B=3') }
        local g2 = A.generalize(docs2, { need = 100, grammars = { command = 'sh', cmd = 'kv' } })
        local names = A.hole_names(g2.template); table.sort(names)
        assert.same({ 'h1', 'h2.1.1' }, names) -- image, and B's value two boundaries down
        assert.is_true(A.eq(g2.values[2]['h2.1.1'], lit '3'))
        for i, d in ipairs(docs2) do assert.is_true(A.eq(A.instantiate(g2.template, g2.values[i]).term, d)) end
        -- a boundary inside a repetition element: the arity path passes the profile through
        local docs3 = { doc('x', 'run a'), doc('x', 'run a | tee b'), doc('x', 'run a | tee c') }
        local g3 = A.generalize(docs3, { need = 100, grammars = { command = 'sh' } })
        for i, d in ipairs(docs3) do assert.is_true(A.eq(A.instantiate(g3.template, g3.values[i]).term, d)) end
    end)

    it('fallback: when one instance does not parse, the position stays an opaque string hole', function()
        local docs = { doc('x:1', 'run fast'), doc('x:2', 'run  slow') } -- double space: not canonical
        local g = A.generalize(docs, { need = 100, grammars = { command = 'sh' } })
        assert.equals('(doc (image ?h1) (command ?h2))', A.show(g.template.body))
        assert.is_true(A.eq(g.values[2].h2, lit 'run  slow'))
    end)

    it('trace keeps the inside of the string: an offset resolves to an inner hole, through two boundaries', function()
        local T0 = A.template(node('doc', node('image', hole 'img'), node('command', hole 'cmd')))
        local Tsh = A.template(node('cmd', name 'run', lit '--env', hole 'env'))
        local Tkv = A.template(node('kv', node('pair', name 'A', hole 'a'), node('pair', name 'B', hole 'b')))
        local T = A.fill(A.fill(T0, 'cmd', A.embed('sh', Tsh)), 'env', A.embed('kv', Tkv))
        local V = { img = lit 'x:1', a = lit '1', b = lit '22' }
        local tr = A.trace(T, V)
        assert.is_true(A.eq(tr.term, A.instantiate(T, V).term))
        local o = tr.origins['2/1']
        assert.equals('embed', o.src); assert.equals('sh', o.g); assert.equals('run --env A=1,B=22', o.text)
        local s = 'run --env A=1,B=22'
        assert.equals('fixed', A.origin_in(tr.origins, { 2, 1 }, 0).src)                 -- 'run' is fixed inside sh
        assert.equals('fixed', A.origin_in(tr.origins, { 2, 1 }, s:find('A=', 1, true) - 1).src) -- the key A is fixed text of the kv template
        local ob = A.origin_in(tr.origins, { 2, 1 }, s:find('22', 1, true) - 1)
        assert.equals('hole', ob.src); assert.equals('b', ob.hole)
        local oa = A.origin_in(tr.origins, { 2, 1 }, s:find('1,', 1, true) - 1)
        assert.equals('a', oa.hole)
        local okey = A.origin_in(tr.origins, { 2, 1 }, s:find('B=', 1, true) - 1)
        assert.equals('fixed', okey.src) -- the key B is fixed text of the kv template
        assert.equals('img', tr.origins['1/1'].hole)
    end)

    it('an edit inside the string classifies and propagates like any other: value, template, and straddle', function()
        local docs = { doc('x:1', 'run fast'), doc('x:2', 'run slow'), doc('x:3', 'run fast') }
        local g = A.generalize(docs, { need = 100, grammars = { command = 'sh' } })
        local T, Vs = g.template, g.values
        -- value edit: fast → quick in member 1; the class is members 1 and 3
        local C = A.classify(T, Vs[1], doc('x:1', 'run quick'))
        assert.equals('value', C.kind); assert.equals('h2.1', C.changed[1].h)
        local P = A.propagate(T, C, Vs, 1)
        assert.same({ 1, 3 }, P.values.holes[1].class)
        assert.is_true(A.eq(P.values.holes[1].preview(3), doc('x:3', 'run quick')))
        -- template edit: run → exec in member 2; previews for everyone render the new string
        local C2 = A.classify(T, Vs[2], doc('x:2', 'exec slow'))
        assert.equals('template', C2.kind)
        assert.is_true(A.eq(A.instantiate(C2.template, C2.values).term, doc('x:2', 'exec slow')))
        local P2 = A.propagate(T, C2, Vs, 2)
        assert.same({ 1, 2, 3 }, P2.template.clean)
        assert.is_true(A.eq(P2.template.preview(1), doc('x:1', 'exec fast')))
        assert.is_true(A.eq(P2.template.preview(3), doc('x:3', 'exec fast')))
        -- the family link joins two embeds of the same grammar INSIDE the boundary
        local R = P2.template.commit({ 1, 2 })
        assert.equals('(doc (image ?h1) (command (embed (cmd ?j1 ?h2.1))))', A.show(R.link.body))
        assert.equals('{name}', A.show_domain(R.link.holes.j1.domain)) -- DOMAINS.md: kinds
        -- an edit that leaves the grammar is a straddle with a hint
        local C3 = A.classify(T, Vs[1], doc('x:1', 'run  fast'))
        assert.equals('straddle', C3.kind); assert.truthy(C3.why:find('does not parse'))
        -- a hole shared across the boundary (the tag in the image field and in the command)
        -- (fill would rename the inner t to avoid the clash; build the shared hole directly)
        local Tx = A.template(node('doc', node('image', hole 't'),
            node('command', A.embed('sh', A.template(node('cmd', name 'run', lit '--tag', hole 't'))).body)))
        local Vx = { t = lit 'v1' }
        local I = A.instantiate(Tx, Vx).term
        assert.is_true(A.eq(I, doc('v1', 'run --tag v1')))
        local both = A.classify(Tx, Vx, doc('v2', 'run --tag v2'))
        assert.equals('value', both.kind); assert.is_true(A.eq(both.values.t, lit 'v2'))
        local one = A.classify(Tx, Vx, doc('v1', 'run --tag v2'))
        assert.equals('straddle', one.kind) -- the store law crosses the boundary too
        assert.equals('split', one.proposal.op) -- by the store-law check, not the rebuild guard
        assert.same({ 2 }, one.proposal.sites)
    end)

    it('migrate and join work through the boundary because the boundary is a node', function()
        local docs = { doc('x:1', 'run fast'), doc('x:2', 'run slow'), doc('x:3', 'run fast') }
        local g = A.generalize(docs, { need = 100, grammars = { command = 'sh' } })
        local P = A.pin(g.template, 'h2.1', lit 'fast')
        local r = A.migrate(g.template, P, g.values)
        assert.same({ 1, 3 }, r.kept)
        local j = A.adjoin(g.template, g.values, doc('x:4', 'run fast'))
        assert.same({}, j.join.new); assert.same({}, j.join.split)
        assert.is_true(A.eq(j.values[4]['h2.1'], lit 'fast'))
        -- a newcomer whose command differs in shape: join parses it and generalizes inside the
        -- boundary; the new hole ranges over commands, the members' values render to their strings
        local j2 = A.adjoin(g.template, g.values, doc('x:5', 'ls'))
        -- joined INSIDE the boundary; since HEDGEJOIN.md the unequal arity is a hedge hole, not a node hole
        -- (a bare hole never anchors, LCSJOIN.md, so the word hole is absorbed as before)
        assert.equals('(doc (image ?h1) (command (embed (cmd ?j1...))))', A.show(j2.template.body))
        assert.is_true(A.eq(A.instantiate(j2.template, j2.values[4]).term, doc('x:5', 'ls')))
        assert.is_true(A.eq(A.instantiate(j2.template, j2.values[1]).term, docs[1]))
    end)

    it('the third leg crosses the boundary too: values_at, abstract and the gate (H carries the boundaries)', function()
        local T0 = A.template(node('doc', node('image', hole 'img'), node('command', hole 'cmd')))
        local Tsh = A.template(node('cmd', name 'run', lit '--env', hole 'env'))
        local Tkv = A.template(node('kv', node('pair', name 'A', hole 'a'), node('pair', name 'B', hole 'b')))
        local T = A.fill(A.fill(T0, 'cmd', A.embed('sh', Tsh)), 'env', A.embed('kv', Tkv))
        local V = { img = lit 'x:1', a = lit '1', b = lit '2' }
        local I = A.instantiate(T, V).term
        local H = A.sites(T)
        assert.equals(2, #H.a.sites[1].through); assert.equals('kv', H.a.sites[1].through[2].g)
        local W, conflicts = A.values_at(I, H)
        assert.same({}, conflicts)
        assert.is_true(A.values_eq(W, V))
        assert.is_true(A.eq(A.abstract(I, H).body, T.body))
        local g = A.gate(T, V, I)
        assert.equals('unrefuted', g.verdict)
        -- a poisoned template leg: abstract must rebuild the boundary from H and I alone
        local g2 = A.gate(T, V, I, nil, H)
        assert.equals('unrefuted', g2.verdict)
    end)

    it('Plotkin\'s rule crosses the boundary: one value tuple outside and inside the string is ONE hole', function()
        local docs = { doc('v1', 'run --tag v1'), doc('v2', 'run --tag v2'), doc('v3', 'run --tag v3') }
        local g = A.generalize(docs, { need = 100, grammars = { command = 'sh' } })
        assert.same({ 'h1' }, A.hole_names(g.template))
        assert.equals('(doc (image ?h1) (command (embed (cmd run "--tag" ?h1))))', A.show(g.template.body))
        assert.equals('{lit}', A.show_domain(g.template.holes.h1.domain)) -- the outer domain is kept
        for i, d in ipairs(docs) do assert.is_true(A.eq(A.instantiate(g.template, g.values[i]).term, d)) end
        -- and the shared hole is held to the store law on an edit of one side only
        local one = A.classify(g.template, g.values[1], doc('v1', 'run --tag v9'))
        assert.equals('straddle', one.kind); assert.equals('split', one.proposal.op)
    end)

    it('a wrapper around a node that contains a boundary relocates the whole template fragment', function()
        local g = A.generalize({ doc('x:1', 'run fast'), doc('x:2', 'run slow') }, { need = 100, grammars = { command = 'sh' } })
        local I2 = node('doc', node('image', lit 'x:1'), node('when', lit 'x', node('command', lit 'run fast')))
        local C = A.classify(g.template, g.values[1], I2)
        assert.equals('template', C.kind)
        assert.equals('(doc (image ?h1) (when "x" (command (embed (cmd run ?h2.1)))))', A.show(C.template.body))
        assert.is_true(A.eq(A.instantiate(C.template, C.values).term, I2))
        local P = A.propagate(g.template, C, g.values, 1)
        assert.is_true(A.eq(P.template.preview(2), node('doc', node('image', lit 'x:2'), node('when', lit 'x', node('command', lit 'run slow')))))
        -- wrapping the root is the same move
        local C3 = A.classify(g.template, g.values[1], node('when', lit 'x', doc('x:1', 'run fast')))
        assert.equals('template', C3.kind)
        -- a kid appended beside the boundary is a template edit that leaves the string whole
        -- (~~a straddle~~ under the positional diff, which took the whole command node as the region; CLASSIFY.md)
        local C4 = A.classify(g.template, g.values[1], node('doc', node('image', lit 'x:1'), node('command', lit 'run fast', lit 'extra')))
        assert.equals('template', C4.kind)
        assert.equals('(doc (image ?h1) (command (embed (cmd run ?h2.1)) "extra"))', A.show(C4.template.body))
        -- but a rewritten region that breaks the old region apart cannot thread a hole through a string
        local C5 = A.classify(g.template, g.values[1], node('doc', node('image', lit 'x:1'), node('command', lit 'run', lit 'fast')))
        assert.equals('straddle', C5.kind); assert.truthy(C5.why:find('behind a grammar boundary'))
    end)

    it('LAW over random shell strings: generalize across the boundary rebuilds, match inverts, adjoin and classify hold', function()
        local function lcg(seed)
            local s = seed
            return function(n) s = (s * 1103515245 + 12345) % 2147483648; return (math.floor(s / 65536) % n) + 1 end
        end
        local heads, words = { 'run', 'exec' }, { 'a', 'b', 'c', 'A=1,B=2', 'A=1,B=3' }
        local function rand_cmd(rnd, k) -- a command of k words; the family shares k so shapes agree
            local ws = { heads[rnd(2)] }
            for _ = 1, k do ws[#ws + 1] = words[rnd(5)] end
            return table.concat(ws, ' ')
        end
        local across, opaque, edits = 0, 0, 0
        for seed = 1, 120 do
            local rnd = lcg(seed)
            local k = rnd(3)
            local docs = {}
            for i = 1, 3 do docs[i] = doc('img:' .. rnd(2), rand_cmd(rnd, k)) end
            local g = A.generalize(docs, { need = 100, grammars = { command = 'sh', cmd = 'kv' } })
            local has_embed = A.show(g.template.body):find('embed', 1, true) ~= nil
            if has_embed then across = across + 1 else opaque = opaque + 1 end
            for i, d in ipairs(docs) do
                assert.is_true(A.eq(A.instantiate(g.template, g.values[i]).term, d), 'seed ' .. seed .. ' rebuild ' .. i)
                local m = A.match(g.template, d)
                assert.is_true(m.ok, 'seed ' .. seed .. ' match ' .. i)
                assert.is_true(A.values_eq(m.values, g.values[i]), 'seed ' .. seed .. ' GetPut ' .. i)
            end
            -- a fourth doc of the same word count joins; everyone still rebuilds
            local newcomer = doc('img:' .. rnd(2), rand_cmd(rnd, k))
            local j = assert(A.adjoin(g.template, g.values, newcomer))
            for i, d in ipairs(docs) do assert.is_true(A.eq(A.instantiate(j.template, j.values[i]).term, d), 'seed ' .. seed .. ' adjoin ' .. i) end
            assert.is_true(A.eq(A.instantiate(j.template, j.values[4]).term, newcomer), 'seed ' .. seed .. ' adjoin newcomer')
            -- an edit inside the string that changes one inner hole's value at all its sites classifies as value
            local names = {}
            for _, h in ipairs(A.hole_names(g.template)) do if h:find('%.') then names[#names + 1] = h end end
            table.sort(names)
            if #names > 0 then
                local h = names[rnd(#names)]
                local W = {}
                for x, v in pairs(g.values[1]) do W[x] = v end
                local nv = g.values[1][h].k == 'name' and name 'zz' or lit 'zz' -- keep the hole's kind
                W[h] = nv
                local inst = A.instantiate(g.template, W)
                assert.is_true(inst.ok, 'seed ' .. seed .. ' edit instantiates')
                local C = A.classify(g.template, g.values[1], inst.term)
                assert.equals('value', C.kind, 'seed ' .. seed .. ' ' .. h .. ': ' .. tostring(C.why))
                assert.is_true(A.eq(C.values[h], nv))
                edits = edits + 1
            end
        end
        assert.is_true(across >= 60 and edits >= 40, 'across ' .. across .. ' opaque ' .. opaque .. ' edits ' .. edits)
    end)
end)

describe('rebuild: a node field that is not the child list survives every arrow that rebuilds nodes', function()
    -- an arbitrary field stands in for the grammar of a boundary or anything a field adds later
    local function tagged(k, ...) local n = node(k, ...); n.meta = 'kept'; return n end
    local function metas(t, out)
        out = out or {}
        if t.meta then out[#out + 1] = t.k end
        for _, c in ipairs(t.kids or {}) do metas(c, out) end
        return out
    end

    it('instantiate, fill, generalize, join, trace and vertical keep it', function()
        local T = A.template(tagged('call', name 'f', hole 'x'))
        assert.same({ 'call' }, metas(A.instantiate(T, { x = lit(1) }).term))
        local F = A.fill(T, 'x', A.template(tagged('pair', hole 'a', hole 'b')))
        assert.same({ 'call', 'pair' }, metas(F.body))
        local g = A.generalize({ tagged('call', name 'f', lit(1)), tagged('call', name 'f', lit(2)) }, { need = 100 })
        assert.same({ 'call' }, metas(g.template.body))
        local j = A.join(T, tagged('call', name 'g', lit(3)))
        assert.same({ 'call' }, metas(j.template.body))
        assert.same({ 'call' }, metas(A.trace(T, { x = lit(1) }).term))
        local v = A.vertical(tagged('a', tagged('b', lit(1))), tagged('a', tagged('c', tagged('b', lit(1)))))
        assert.truthy(v.templates[1])
        assert.same({ 'a', 'b' }, metas(v.templates[1].body))
        -- the boundary case that started it: the grammar survives a fill and a wrapper classify
        local E = A.fill(T, 'x', A.embed('sh', A.template(node('cmd', name 'run', hole 'arg'))))
        assert.equals('sh', E.body.kids[2].g)
        local I = A.instantiate(E, { arg = lit 'fast' }).term
        local C = A.classify(E, { arg = lit 'fast' }, node('when', lit 'x', I))
        assert.equals('template', C.kind)
        assert.equals('sh', C.template.body.kids[2].kids[2].g)
    end)
end)

describe('MDL partitioning: which instances are one template', function()
    local calls = { call('register', lit 'on_tick', name 'tick'), call('register', lit 'on_draw', name 'draw'), call('register', lit 'on_key', name 'key') }
    local ifs = { node('if', name 'a', node('ret', lit(1))), node('if', name 'b', node('ret', lit(2))), node('if', name 'c', node('ret', lit(3))) }
    local G = { generalize = { need = 100 } }

    it('the cost model: one shared skeleton is paid once; unrelated instances are not cheaper together', function()
        local one = A.partition(calls, G)
        assert.equals(1, #one.families)
        assert.equals(3, #one.families[1].members)
        -- template 4 nodes + family 1 + values 3 members × 2 leaves = 11, against singletons 3 × (4 + 1) = 15
        assert.equals(11, one.dl); assert.equals(15, one.singletons_dl)
        -- a call and an if together collapse to a root hole: 1 + 1 + 4 + 4 = 10, a tie with 5 + 5,
        -- and a bare hole shares nothing, so it is not an admissible family anyway
        local two = A.partition({ calls[1], ifs[1] }, G)
        assert.equals(2, #two.families)
        assert.equals(10, two.dl); assert.equals(10, two.one_family_dl); assert.is_false(two.one_family_admissible)
        -- six one-node instances: without admissibility a bare hole "family" costs 8 against 12
        -- for singletons, and even against 6 for the three identical pairs it is refused
        -- a TIE is not a merge: f(1,2) and f(3,4) as one family cost 3 + 1 + 2 + 2 = 8, singletons 4 + 4 = 8
        local tie = A.partition({ node('f', lit(1), lit(2)), node('f', lit(3), lit(4)) }, G)
        assert.equals(2, #tie.families); assert.equals(8, tie.dl); assert.equals(8, tie.one_family_dl)
        assert.is_true(tie.one_family_admissible)
        -- a third member breaks the tie: 3 + 1 + 6 = 10 against 12
        assert.equals(1, #A.partition({ node('f', lit(1), lit(2)), node('f', lit(3), lit(4)), node('f', lit(5), lit(6)) }, G).families)
        -- (identical instances ARE a family: a template with no holes, paid once)
        local tiny = { lit(1), lit(2), lit(3), lit(1), lit(2), lit(3) }
        local r = A.partition(tiny, G)
        assert.equals(3, #r.families); assert.equals(6, r.dl); assert.equals(8, r.one_family_dl) -- ?h1: 1 + 1 + 6
        assert.is_false(r.one_family_admissible)
        assert.same({ 1, 4 }, r.families[1].members)
    end)

    it('two shapes mixed come apart into two families, each the lgg of its group', function()
        local mixed = { calls[1], ifs[1], calls[2], ifs[2], calls[3], ifs[3] }
        local r = A.partition(mixed, G)
        assert.equals(2, #r.families)
        assert.same({ 1, 3, 5 }, r.families[1].members)
        assert.same({ 2, 4, 6 }, r.families[2].members)
        assert.equals('(call register ?h1 ?h2)', A.show(r.families[1].template.body))
        assert.equals('(if ?h1 (ret ?h2))', A.show(r.families[2].template.body))
        assert.is_true(r.dl < r.one_family_dl and r.dl < r.singletons_dl)
        -- the greedy result is the optimum here
        assert.equals(A.partition_all(mixed, G).dl, r.dl)
        -- every member rebuilds from its family
        for _, f in ipairs(r.families) do
            for _, i in ipairs(f.members) do assert.is_true(A.eq(A.instantiate(f.template, f.values[i]).term, mixed[i])) end
        end
    end)

    it('a non-linear hole is priced once per member, so a shared value keeps a family together', function()
        local shared = { node('f', lit(1), lit(1)), node('f', lit(2), lit(2)), node('f', lit(3), lit(3)) }
        local r = A.partition(shared, G)
        assert.equals(1, #r.families)
        assert.equals(2, #A.sites(r.families[1].template).h1.sites)
        -- template 3 (f and two SITES of one hole) + family 1 + values 3 × 1 (one value per member,
        -- not per site) = 7; singletons 3 × (3 + 1) = 12
        assert.equals(7, r.dl); assert.equals(12, r.singletons_dl)
    end)

    it('an outlier stays a singleton rather than dissolving the family into a root hole', function()
        local r = A.partition({ calls[1], calls[2], calls[3], node('weird') }, G)
        assert.equals(2, #r.families)
        assert.same({ 4 }, r.families[2].members)
        assert.is_true(r.dl < r.one_family_dl)
    end)

    it('pricing an operator split: propagate.commit against one family', function()
        local T = A.template(call('register', hole 'key', hole 'fn'))
        local Vs = {}
        for i, I in ipairs(calls) do Vs[i] = A.match(T, I).values end
        local C = A.classify(T, Vs[1], call('subscribe', lit 'on_tick', name 'tick'))
        local d = A.dl_delta(T, Vs, C.template, { 1 })
        -- one family: 4 + 1 + 6 = 11; two: (4 + 1 + 2) + (4 + 1 + 4) = 16
        assert.equals(11, d.one); assert.equals(16, d.two); assert.equals(5, d.delta)
        local all = A.dl_delta(T, Vs, C.template, { 1, 2, 3 })
        assert.equals(0, all.delta) -- everyone moves: same cost, the callee just changed
    end)

    it('LAW: greedy never exceeds singletons or one family, and hits the brute-force optimum on most small mixes', function()
        local function lcg(seed)
            local s = seed
            return function(n) s = (s * 1103515245 + 12345) % 2147483648; return (math.floor(s / 65536) % n) + 1 end
        end
        local function rand_tree(rnd, budget)
            local labels = { 'a', 'b', 'c' }
            local t = node(labels[rnd(3)])
            budget = budget - 1
            while budget > 0 and rnd(2) == 1 do
                local kid = rand_tree(rnd, rnd(budget))
                t.kids[#t.kids + 1] = kid
                budget = budget - A.size(kid)
            end
            return t
        end
        local function leaves_of(t)
            local out = {}
            local function walk(x, path)
                if #(x.kids or {}) == 0 then out[#out + 1] = path end
                for i, c in ipairs(x.kids or {}) do
                    local p = {}
                    for j = 1, #path do p[j] = path[j] end
                    p[#p + 1] = i
                    walk(c, p)
                end
            end
            walk(t, {})
            return out
        end
        local function set_at(t, path, v, i)
            i = i or 1
            if i > #path then return A.copy(v) end
            local c = A.copy(t)
            c.kids[path[i]] = set_at(t.kids[path[i]], path, v, i + 1)
            return c
        end
        local pool = { lit(1), lit(2), lit(3) }
        local optimal, total, recovered = 0, 0, 0
        for seed = 1, 60 do
            local rnd = lcg(seed)
            -- two skeleton families of three members each, shuffled by construction (interleaved)
            local Is, truth = {}, {}
            for fam = 1, 2 do
                local skel = rand_tree(rnd, 7)
                local leaves = leaves_of(skel)
                local k = math.min(#leaves, rnd(2))
                for m = 1, 3 do
                    local J = skel
                    for j = 1, k do J = set_at(J, leaves[j], pool[rnd(3)]) end
                    Is[#Is + 1] = J
                    truth[#Is] = fam
                end
            end
            local r = A.partition(Is, G)
            assert.is_true(r.dl <= r.singletons_dl, 'seed ' .. seed .. ' worse than singletons')
            if r.one_family_admissible then assert.is_true(r.dl <= r.one_family_dl, 'seed ' .. seed .. ' worse than one family') end
            for _, f in ipairs(r.families) do assert.is_true(f.admissible) end
            local best = A.partition_all(Is, G)
            assert.equals(203, best.partitions) -- Bell(6)
            assert.is_true(best.dl <= r.dl, 'seed ' .. seed .. ' brute force must not lose to greedy')
            total = total + 1
            if best.dl == r.dl then optimal = optimal + 1 end
            -- did the cut recover the two skeletons? (only meaningful when they differ in shape)
            if #r.families == 2 then
                local ok = true
                for _, f in ipairs(r.families) do
                    for _, i in ipairs(f.members) do if truth[i] ~= truth[f.members[1]] then ok = false end end
                end
                if ok then recovered = recovered + 1 end
            end
        end
        assert.is_true(optimal >= total * 0.8, 'greedy optimal on ' .. optimal .. ' of ' .. total)
        -- `recovered` measures the GENERATOR's cut, not the objective: two skeletons that share
        -- structure are often cheaper as one family, or as three cut by leaf values. Measured
        -- once (MDL.md): greedy 6/60, brute-force optimum 11/60, greedy optimal 60/60.
        assert.is_true(recovered >= 0)
    end)
end)

describe('equational anti-unification modulo A, C, AC (Alpuente, Escobar, Meseguer, Ojeda 2008; Espert 2014; Sapiña 2021)', function()
    local function bodies(r) local out = {}; for i, g in ipairs(r.set) do out[i] = g.template.body end; return out end
    local function has(r, body, theory)
        for _, g in ipairs(r.set) do if A.leq_mod(g.template.body, body, theory) and A.leq_mod(body, g.template.body, theory) then return true end end
        return false
    end
    local function sound(r, t, s, theory)
        for _, g in ipairs(r.set) do
            local i1, i2 = A.instantiate(g.template, g.values[1]), A.instantiate(g.template, g.values[2])
            if not (i1.ok and i2.ok) then return false, 'refused' end
            if not (A.eq_mod(i1.term, t, theory) and A.eq_mod(i2.term, s, theory)) then return false, A.show(g.template.body) end
        end
        return true
    end
    local function minimal(r, theory)
        for i, g in ipairs(r.set) do
            for j, h in ipairs(r.set) do
                if i ~= j and A.leq_mod(g.template.body, h.template.body, theory) then return false end
            end
        end
        return true
    end

    it('LOPSTR Example 1 (syntactic): Recover makes the generalizer non-linear', function()
        local t = node('f', node('g', lit 'a'), node('g', name 'y'), lit 'a')
        local s = node('f', node('g', lit 'b'), node('g', name 'y'), lit 'b')
        local r = A.eau(t, s, {})
        assert.equals(1, #r.set)
        assert.is_true(has(r, node('f', node('g', hole 'x'), node('g', name 'y'), hole 'x'), {}))
        assert.equals(2, #A.sites(r.set[1].template).e6.sites)
        assert.is_true(sound(r, t, s, {}))
        -- the empty theory is Plotkin's lgg: the same template `generalize` computes
        assert.is_true(A.iso(r.set[1].template, A.generalize({ t, s }, { need = 100 }).template))
        -- an input VARIABLE (a hole in the inputs) is a constant of the problem and survives as itself
        local tv = node('f', node('g', lit 'a'), node('g', hole 'y'), lit 'a')
        local sv = node('f', node('g', lit 'b'), node('g', hole 'y'), lit 'b')
        local rv = A.eau(tv, sv, {})
        assert.equals(1, #rv.set)
        assert.is_true(sound(rv, tv, sv, {}))
        assert.is_true(A.eq(rv.set[1].values[1].y, hole 'y'))
    end)

    it('the introduction: sibling(sam, john) and sibling(tom, sam) with sibling commutative is sibling(x, sam)', function()
        local C = { sibling = { C = true } }
        local t, s = node('sibling', name 'sam', name 'john'), node('sibling', name 'tom', name 'sam')
        local r = A.eau(t, s, C)
        assert.equals(1, #r.set)
        assert.is_true(has(r, node('sibling', hole 'x', name 'sam'), C))
        assert.is_true(sound(r, t, s, C))
        -- without the declaration both arguments are holes
        assert.is_true(has(A.eau(t, s, {}), node('sibling', hole 'x', hole 'y'), {}))
    end)

    it('LOPSTR Example 3 and the cartograph case: f(a,b) vs f(b,a), and x == nil vs nil == x, are ground modulo C', function()
        local C = { f = { C = true }, ['=='] = { C = true } }
        local r = A.eau(node('f', lit 'a', lit 'b'), node('f', lit 'b', lit 'a'), C)
        assert.equals(1, #r.set); assert.equals(0, #A.hole_names(r.set[1].template))
        assert.is_true(A.eq_mod(r.set[1].template.body, node('f', lit 'a', lit 'b'), C))
        local e1, e2 = node('==', name 'x', lit 'nil'), node('==', lit 'nil', name 'x')
        local r2 = A.eau(e1, e2, C)
        assert.equals(0, #A.hole_names(r2.set[1].template))
        assert.equals(2, #A.hole_names(A.eau(e1, e2, {}).set[1].template)) -- syntactically two holes
    end)

    it('LOPSTR Example 4 (A): f(f(a,c),b) vs f(c,b) is f(x, b); the flatter branch is filtered out', function()
        local Th = { f = { A = true } }
        local t, s = node('f', node('f', lit 'a', lit 'c'), lit 'b'), node('f', lit 'c', lit 'b')
        local r = A.eau(t, s, Th)
        assert.equals(1, #r.set)
        assert.is_true(has(r, node('f', hole 'x', lit 'b'), Th))
        assert.is_true(r.complete > 1) -- f(x1, x2) was generated and dropped
        assert.is_true(sound(r, t, s, Th))
        -- lists that share both ends: two incomparable generalizers
        local r2 = A.eau(node('f', lit 'a', node('f', lit 'b', lit 'c')), node('f', lit 'a', lit 'c'), Th)
        assert.equals(2, #r2.set)
        assert.is_true(has(r2, node('f', lit 'a', hole 'x'), Th)); assert.is_true(has(r2, node('f', hole 'x', lit 'c'), Th))
        assert.is_true(minimal(r2, Th))
    end)

    it('LOPSTR Example 5 / survey Example 2 (AC): two incomparable lggs f(x,x,y) and f(x,a,b)', function()
        local AC = { f = { A = true, C = true } }
        local t, s = node('f', lit 'a', node('f', lit 'a', lit 'b')), node('f', node('f', lit 'b', lit 'b'), lit 'a')
        local r = A.eau(t, s, AC)
        assert.equals(2, #r.set)
        assert.is_true(has(r, node('f', hole 'x', hole 'x', hole 'y'), AC))
        assert.is_true(has(r, node('f', hole 'x', lit 'a', lit 'b'), AC))
        assert.is_true(sound(r, t, s, AC)); assert.is_true(minimal(r, AC))
        -- Definition 2 by brute force agrees (144 pairs of class representatives)
        local n = A.eau_naive(t, s, AC)
        assert.equals(144, n.pairs)
        assert.is_true(A.same_set_mod(bodies(r), n.set, AC))
        -- and a + b + c against c + a + b is ground
        local sum = { ['+'] = { A = true, C = true } }
        local r3 = A.eau(node('+', node('+', name 'a', name 'b'), name 'c'), node('+', name 'c', node('+', name 'a', name 'b')), sum)
        assert.equals(1, #r3.set); assert.equals(0, #A.hole_names(r3.set[1].template))
    end)

    it('the theory is a declaration: an or-chain of == comparisons with operands swapped', function()
        local l = node('or', node('==', name 'pt', lit 'a'), node('==', name 'pt', lit 'b'))
        local rr = node('or', node('==', lit 'b', name 'pt'), node('==', lit 'a', name 'pt'))
        local none = A.eau(l, rr, {})
        assert.equals(4, #A.hole_names(none.set[1].template))            -- every operand differs
        local ceq = A.eau(l, rr, { ['=='] = { C = true } })
        assert.equals(2, #A.hole_names(ceq.set[1].template))             -- == commutes: the literals still differ
        local both = A.eau(l, rr, { ['=='] = { C = true }, ['or'] = { A = true, C = true } })
        assert.equals(0, #A.hole_names(both.set[1].template))            -- or is AC too: the same term
        -- modulo A alone an or-chain against a single comparison has different roots: a hole
        local one = A.eau(l, node('==', name 'pt', lit 'a'), { ['or'] = { A = true } })
        assert.is_true(A.is_hole(one.set[1].template.body))
    end)

    it('unranked terms: the same free root with different arity is Solved, not stuck', function()
        local r = A.eau(node('f', lit 'a'), node('f', lit 'a', lit 'b'), {})
        assert.equals(1, #r.set); assert.is_true(A.is_hole(r.set[1].template.body))
    end)

    it('match_mod and canon: instances modulo B are recognised, non-instances refused', function()
        local AC = { f = { A = true, C = true }, g = { C = true } }
        assert.truthy(A.match_mod(node('f', hole 'x', lit 'a'), node('f', lit 'a', node('f', lit 'b', lit 'c')), AC))
        assert.is_nil(A.match_mod(node('f', hole 'x', lit 'd'), node('f', lit 'a', node('f', lit 'b', lit 'c')), AC))
        assert.truthy(A.match_mod(node('g', hole 'x', lit 'a'), node('g', lit 'a', lit 'b'), AC))
        assert.is_nil(A.match_mod(node('g', hole 'x', lit 'a'), node('g', lit 'c', lit 'b'), AC))
        assert.truthy(A.match_mod(node('f', hole 'x', hole 'x'), node('f', node('f', lit 'a', lit 'b'), node('f', lit 'b', lit 'a')), AC))
        -- associative only: a hole takes a consecutive GROUP, a non-hole child exactly one
        local Aonly = { f = { A = true } }
        local V = A.match_mod(node('f', hole 'x', lit 'c'), node('f', lit 'a', node('f', lit 'b', lit 'c')), Aonly)
        assert.truthy(V); assert.is_true(A.eq(V.x, node('f', lit 'a', lit 'b')))
        assert.is_nil(A.match_mod(node('f', lit 'a', lit 'c'), node('f', lit 'a', node('f', lit 'b', lit 'c')), Aonly))
        assert.is_nil(A.match_mod(node('f', hole 'x', lit 'a'), node('f', lit 'a', node('f', lit 'b', lit 'c')), Aonly)) -- order matters without C
        assert.is_true(A.eq_mod(node('f', lit 'a', node('f', lit 'b', lit 'c')), node('f', node('f', lit 'c', lit 'a'), lit 'b'), AC))
        assert.is_false(A.eq_mod(node('f', lit 'a', lit 'b'), node('f', lit 'a', lit 'c'), AC))
    end)

    it('LAW over random terms: eau equals Definition 2 by brute force, is sound modulo B and minimal; empty theory equals generalize', function()
        local function lcg(seed)
            local s = seed
            return function(n) s = (s * 1103515245 + 12345) % 2147483648; return (math.floor(s / 65536) % n) + 1 end
        end
        local Th = { f = { A = true, C = true }, g = { C = true } }
        local consts = { lit 'a', lit 'b', lit 'c' }
        local function rand_term(rnd, depth)
            local r = rnd(6)
            if depth == 0 or r <= 2 then return consts[rnd(3)] end
            if r == 3 then return node('h', rand_term(rnd, depth - 1)) end
            if r == 4 then return node('g', rand_term(rnd, depth - 1), rand_term(rnd, depth - 1)) end
            local kids = {}
            for _ = 1, rnd(2) + 1 do kids[#kids + 1] = rand_term(rnd, depth - 1) end
            return node('f', unpack(kids))
        end
        local agree, multi, total = 0, 0, 0
        for seed = 1, 120 do
            local rnd = lcg(seed)
            local t, s = rand_term(rnd, 2), rand_term(rnd, 2)
            -- keep the AC children count small so the class enumeration stays tractable
            local ft, fs = A.flatten(t, Th), A.flatten(s, Th)
            local function width(x) local w = #(x.kids or {}); for _, c in ipairs(x.kids or {}) do w = math.max(w, width(c)) end; return w end
            if width(ft) <= 3 and width(fs) <= 3 then
                local r = assert(A.eau(t, s, Th))
                assert.is_true(sound(r, t, s, Th), 'seed ' .. seed .. ' sound')
                assert.is_true(minimal(r, Th), 'seed ' .. seed .. ' minimal')
                local n = A.eau_naive(t, s, Th)
                assert.is_true(A.same_set_mod(bodies(r), n.set, Th), 'seed ' .. seed .. ': eau ' .. #r.set .. ' vs naive ' .. #n.set)
                agree = agree + 1
                if #r.set > 1 then multi = multi + 1 end
                total = total + 1
            end
        end
        -- AC-shaped pairs like the survey's: three children over two constants, one side permuted
        -- and one child changed, where several incomparable lggs are common
        for seed = 1, 90 do
            local rnd = lcg(seed)
            local pool = { lit 'a', lit 'b' }
            local k1, k2 = {}, {}
            for i = 1, 3 do k1[i] = pool[rnd(2)] end
            local order = { { 1, 2, 3 }, { 2, 3, 1 }, { 3, 1, 2 }, { 1, 3, 2 } }
            local o = order[rnd(4)]
            for i = 1, 3 do k2[i] = k1[o[i]] end
            k2[rnd(3)] = consts[rnd(3)]
            local t, s = node('f', unpack(k1)), node('f', unpack(k2))
            local r = assert(A.eau(t, s, Th))
            assert.is_true(sound(r, t, s, Th), 'ac seed ' .. seed .. ' sound')
            assert.is_true(minimal(r, Th), 'ac seed ' .. seed .. ' minimal')
            local n = A.eau_naive(t, s, Th)
            assert.is_true(A.same_set_mod(bodies(r), n.set, Th), 'ac seed ' .. seed .. ': eau ' .. #r.set .. ' vs naive ' .. #n.set)
            agree = agree + 1; total = total + 1
            if #r.set > 1 then multi = multi + 1 end
        end
        assert.is_true(total >= 100 and multi >= 10, 'total ' .. total .. ' multi ' .. multi)
        -- empty theory on ranked pairs: the single lgg is generalize's template
        for seed = 1, 40 do
            local rnd = lcg(seed)
            local t = rand_term(rnd, 2)
            local s = A.copy(t)
            -- perturb one leaf so the pair is ranked (same shape)
            local function perturb(x) if not x.kids then return consts[rnd(3)] end; local i = rnd(#x.kids); x.kids[i] = perturb(x.kids[i]); return x end
            s = perturb(s)
            local r = A.eau(t, s, {})
            assert.equals(1, #r.set)
            assert.is_true(A.iso(r.set[1].template, A.generalize({ t, s }, { need = 100 }).template), 'seed ' .. seed .. ' plotkin')
        end
    end)
end)

describe('the tensions: materialization onto the closed schema, provenance, absence, validity (CHARTER.md)', function()
    local function mod(...) return node('mod', ...) end
    local function def(n, ...) return node('def', type(n) == 'string' and name(n) or n, ...) end
    local function call(n) return node('call', type(n) == 'string' and name(n) or n) end
    local function use(n) return node('use', type(n) == 'string' and name(n) or n) end
    local function loc(n, v) return node('local', type(n) == 'string' and name(n) or n, v or lit(1)) end
    local function block(...) return node('block', ...) end
    local function edge(G, kind, from, to)
        for _, e in ipairs(G.edges) do if e.kind == kind and e.from == from and e.to == to then return e end end
    end
    local function absences_at(G, at) local out = {}; for _, a in ipairs(G.absences) do if a.at == at then out[#out + 1] = a end end; return out end

    it('a ground program lands on the six node kinds and four edge kinds, by name', function()
        local P = mod(def('f', call 'g', use 'x'), def('g'), loc('x'))
        local G = A.materialize(P)
        assert.is_true(A.on_schema(G))
        assert.equals('module', G.nodes.root.kind)
        assert.equals('function', G.nodes['1'].kind); assert.equals('f', G.nodes['1'].name)
        assert.equals('var', G.nodes['3'].kind)
        assert.truthy(edge(G, 'ref', '1', '2')); assert.equals('linked', edge(G, 'ref', '1', '2').tier)
        assert.truthy(edge(G, 'use', '1', '3'))
        assert.equals(0, #G.absences)
        -- the absence set is a table: an undeclared name is unrepresentable (CART-0831)
        assert.is_false(A.is_absence('banana'))
    end)

    it('ambiguity is `refused` with candidates, a missing definition is `frontier`', function()
        local G = A.materialize(mod(def('f', call 'g', call 'k'), def('g'), def('g')))
        local amb = absences_at(G, '1/2')[1]
        assert.equals('refused', amb.absence); assert.same({ '2', '3' }, amb.cands); assert.equals('nothing', amb.licenses)
        local none = absences_at(G, '1/3')[1]
        assert.equals('frontier', none.absence)
    end)

    it('a template with a family: agreement is STATED as derived, disagreement is `refused` with the members\' answers, no family is `unavailable`', function()
        local T = A.template(mod(def('f', call(hole 'p')), def('g'), def('h')), { p = A.kinds { 'name' } })
        local agree = A.materialize(T, { family = { { p = name 'g' }, { p = name 'g' } } })
        local e = edge(agree, 'ref', '1', '2')
        assert.truthy(e); assert.equals('derived', e.prov); assert.equals('family', e.via); assert.equals('linked', e.tier)
        assert.is_true(A.on_schema(agree))
        -- the stated tier is the WEAKEST member tier; the toy emits `linked` alone, so the
        -- helper is tested directly, in ladder.lua's display order (disputed, CART-0545)
        assert.equals('linked', A.worst_tier { 'proven', 'linked', 'confirmed' })
        assert.equals('inferred', A.worst_tier { 'linked', 'inferred', 'linked' })
        assert.equals('frontier', A.worst_tier { 'linked', 'banana' })
        -- over-hedging is the stated price: with a hole anywhere and no family, even a fully
        -- fixed edge reads `unavailable`; a bare term with holes is a template with open domains
        local fixed = A.materialize(mod(def('f', call 'g'), def('g'), hole 's'))
        assert.is_nil(edge(fixed, 'ref', '1', '2'))
        assert.equals('unavailable', absences_at(fixed, '1/2')[1].absence)
        local split = A.materialize(T, { family = { { p = name 'g' }, { p = name 'h' } } })
        assert.is_nil(edge(split, 'ref', '1', '2'))
        local a = absences_at(split, '1/2')[1]
        assert.equals('refused', a.absence); assert.same({ '2', '3' }, a.cands)
        local none = A.materialize(T)
        assert.equals('unavailable', absences_at(none, '1/2')[1].absence)
    end)

    it('a hole at a node position is still a place (a region with a hole field); its inside is stated only when every member agrees', function()
        local T = A.template(mod(def('f', hole 's'), def('g'), def('h')))
        local G0 = A.materialize(T)
        assert.equals('region', G0.nodes['1/2'].kind); assert.equals('s', G0.nodes['1/2'].hole)
        assert.equals('unavailable', absences_at(G0, '1/2')[1].absence)
        local same = A.materialize(T, { family = { { s = call 'g' }, { s = call 'g' } } })
        assert.truthy(edge(same, 'ref', '1', '2')); assert.equals('derived', edge(same, 'ref', '1', '2').prov)
        local diff = A.materialize(T, { family = { { s = call 'g' }, { s = call 'h' } } })
        assert.is_nil(edge(diff, 'ref', '1', '2')); assert.is_nil(edge(diff, 'ref', '1', '3'))
        local a = absences_at(diff, '1/2')[1]
        assert.equals('refused', a.absence); assert.equals(2, #a.cands)
        -- a def whose NAME is a hole: a fixed call to it depends on the hole's value
        local T2 = A.template(mod(def('f', call 'g'), def(hole 'p')), { p = A.kinds { 'name' } })
        local ok = A.materialize(T2, { family = { { p = name 'g' }, { p = name 'g' } } })
        assert.truthy(edge(ok, 'ref', '1', '2'))
        local half = A.materialize(T2, { family = { { p = name 'g' }, { p = name 'h' } } })
        local b = absences_at(half, '1/2')[1]
        assert.equals('refused', b.absence); assert.same({ '2' }, b.cands); assert.equals(1, b.missing_in)
        -- a target that lives INSIDE a hole whose contents differ: the members agree on the
        -- target id, but the node is not stated, so the edge is refused rather than dangling
        local T3 = A.template(mod(def('f', use 'x'), hole 's'))
        local G3 = A.materialize(T3, { family = { { s = block(loc 'x', call 'f') }, { s = block(loc 'x', call 'g') } } })
        assert.is_true(A.on_schema(G3))
        assert.is_nil(edge(G3, 'use', '1', '2/1'))
        local c = absences_at(G3, '1/2')[1]
        assert.equals('refused', c.absence); assert.same({ '2/1' }, c.cands)
    end)

    -- random toy families for the laws
    local function toy(seed)
        local s = seed * 7919 + 17
        local function rnd(n) s = (s * 1103515245 + 12345) % 2147483648; return math.floor(s / 65536) % n + 1 end
        local fns, vars = { 'f', 'g', 'h' }, { 'x', 'y' }
        local function nm(pool, h) return rnd(3) == 1 and hole(h) or name(pool[rnd(#pool)]) end
        local function stmt()
            local r = rnd(5)
            if r == 1 then return call(nm(fns, 'r')) elseif r == 2 then return use(nm(vars, 'u'))
            elseif r == 3 then return hole 's' elseif r == 4 then return loc(name(vars[rnd(2)]))
            else return block(call(nm(fns, 'r'))) end
        end
        local function body() local out = {}; for i = 1, rnd(3) do out[i] = stmt() end; return unpack(out) end
        local T = A.template(mod(def(nm(fns, 'p'), body()), def(nm(fns, 'q'), body()), loc(name(vars[rnd(2)]))),
            { p = A.kinds { 'name' }, q = A.kinds { 'name' }, r = A.kinds { 'name' }, u = A.kinds { 'name' } })
        local fam, present = {}, {}
        for _, h in ipairs(A.hole_names(T)) do present[h] = true end
        for i = 1, 1 + rnd(3) do
            local sv = ({ call(name(fns[rnd(3)])), use(name(vars[rnd(2)])), loc(name(vars[rnd(2)]), lit(2)), block(call(name(fns[rnd(3)]))) })[rnd(4)]
            local all = { p = name(fns[rnd(3)]), q = name(fns[rnd(3)]), r = name(fns[rnd(3)]), u = name(vars[rnd(2)]), s = sv }
            fam[i] = {}
            for h, v in pairs(all) do if present[h] then fam[i][h] = v end end
        end
        return T, fam
    end
    local function ekey(e) return e.from .. '>' .. e.to .. ':' .. e.kind .. '@' .. e.at end
    local function is_prefix(p, q) if #p > #q then return false end; for i = 1, #p do if p[i] ~= q[i] then return false end end; return true end

    it('LAW over random families: nodes commute with instantiation, stated facts hold in every member, nothing common is silently dropped, and every hedge is a declared absence', function()
        local stated, hedged, seeds = 0, 0, 0
        for seed = 1, 150 do
            local T, fam = toy(seed)
            local G = A.materialize(T, { family = fam })
            assert.is_true(A.on_schema(G), 'seed ' .. seed .. ' schema')
            local Ms = {}
            for i, V in ipairs(fam) do
                local r = A.instantiate(T, V)
                assert.is_true(r.ok, 'seed ' .. seed .. ' member ' .. i)
                Ms[i] = A.materialize(r.term)
            end
            seeds = seeds + 1
            -- (1) fixed nodes: same id and kind in every member
            for id, n in pairs(G.nodes) do
                if not n.prov and not n.hole then
                    for i, Mi in ipairs(Ms) do
                        assert.truthy(Mi.nodes[id], 'seed ' .. seed .. ' node ' .. id .. ' missing in member ' .. i)
                        assert.equals(n.kind, Mi.nodes[id].kind, 'seed ' .. seed .. ' node ' .. id)
                    end
                end
            end
            -- (2) soundness: every stated edge holds in every member
            for _, e in ipairs(G.edges) do
                for i, Mi in ipairs(Ms) do
                    local found
                    for _, f in ipairs(Mi.edges) do if ekey(f) == ekey(e) then found = f end end
                    assert.truthy(found, 'seed ' .. seed .. ' edge ' .. ekey(e) .. ' not in member ' .. i)
                end
                stated = stated + 1
            end
            -- (3) no silent drop: an edge every member has is stated or covered by an absence
            local common = {}
            for _, f in ipairs(Ms[1].edges) do
                local all = true
                for i = 2, #Ms do
                    local hit = false
                    for _, g in ipairs(Ms[i].edges) do if ekey(g) == ekey(f) then hit = true end end
                    if not hit then all = false end
                end
                if all then common[#common + 1] = f end
            end
            for _, f in ipairs(common) do
                local ok = false
                for _, e in ipairs(G.edges) do if ekey(e) == ekey(f) then ok = true end end
                if not ok then
                    for _, a in ipairs(G.absences) do if is_prefix(a.atp, f.atp) then ok = true end end
                end
                assert.is_true(ok, 'seed ' .. seed .. ' common edge ' .. ekey(f) .. ' silently dropped')
            end
            -- (4) the hedges: refused carries candidates; unavailable never appears with a family
            for _, a in ipairs(G.absences) do
                assert.is_true(A.is_absence(a.absence))
                assert.is_not.equals('unavailable', a.absence, 'seed ' .. seed)
                if a.absence == 'refused' then assert.is_true(#a.cands >= 1, 'seed ' .. seed .. ' refused without candidates') end
                hedged = hedged + 1
            end
        end
        assert.is_true(stated > 50 and hedged > 100, ('stated %d hedged %d'):format(stated, hedged))
    end)

    it('provenance: match observes, migrate and join carry, and a supplied value is never laundered into observed', function()
        local T = A.template(node('f', hole 'x', hole 'y'))
        local m = A.match(T, node('f', lit 'a', lit 'b'))
        assert.equals('observed', m.provenance.x.src)
        -- a supplied value (an operator premise, journaled)
        local P = { x = m.provenance.x, y = { src = 'supplied', via = { 'operator' }, journal = { op = 'pin', h = 'y' } } }
        local V = { x = lit 'a', y = lit 'b' }
        -- through split (copies) and dig (computes) and rewrite (carries)
        local T1 = A.split(A.template(node('f', hole 'x', hole 'x')), 'x', 2, 'x2')
        local r = A.migrate(A.template(node('f', hole 'x', hole 'x')), T1, { { x = lit 'a' } }, nil, { { x = P.y } })
        assert.equals('supplied', r.provenance[1].x.src)
        assert.equals('supplied', r.provenance[1].x2.src) -- the copy inherits the premise
        assert.truthy(r.provenance[1].x2.journal)
        local T2 = A.rewrite(T, { 1 }, node('g', hole 'x'))
        local r2 = A.migrate(T, T2, { V }, nil, { P })
        assert.equals('supplied', r2.provenance[1].y.src); assert.equals('observed', r2.provenance[1].x.src)
        assert.equals('migrate:rewrite', r2.provenance[1].y.via[#r2.provenance[1].y.via])
        -- through a join: a bare kept hole carries, a rendered fragment is derived
        local j = A.join(T, node('f', lit 'c', node('h', lit 'd')))
        local W, Q = j.left(V, P)
        assert.equals('supplied', Q.y.src); assert.equals('observed', Q.x.src)
        for _, n in ipairs(j.new) do assert.equals('derived', Q[n].src) end
        -- a dig computes: derived, not observed
        local T3 = A.template(node('f', node('g', lit 'k'), hole 'x'))
        local T4 = A.dig(T3, { 1 }, 'z')
        local r4 = A.migrate(T3, T4, { { x = lit 'a' } }, nil, { { x = P.x } })
        assert.equals('derived', r4.provenance[1].z.src)
    end)

    it('emission is the line: no provenance is authoring, a supplied value needs its journal, and the reader verifies the writer', function()
        local T = A.template(node('f', hole 'x', hole 'y'))
        local V = { x = lit 'a', y = lit 'b' }
        local none = A.emit(T, V, {})
        assert.is_false(none.ok); assert.equals('refused', none.absence); assert.truthy(none.why:find('authoring'))
        local unj = A.emit(T, V, { x = { src = 'observed', via = {} }, y = { src = 'supplied', via = {} } })
        assert.is_false(unj.ok); assert.truthy(unj.why:find('journal'))
        local ok = A.emit(T, V, { x = { src = 'observed', via = {} }, y = { src = 'supplied', via = {}, journal = { op = 'propagate' } } })
        assert.is_true(ok.ok); assert.is_true(ok.verified)
        -- propagate's value commit stamps observed on the source member and supplied+journal elsewhere
        local Vs = { { x = lit 'a', y = lit 'b' }, { x = lit 'a', y = lit 'c' }, { x = lit 'q', y = lit 'd' } }
        local C = A.classify(T, Vs[1], node('f', lit 'z', lit 'b'))
        assert.equals('value', C.kind)
        local out = A.propagate(T, C, Vs, 1, nil, { provenance = { A.observed(Vs[1]), A.observed(Vs[2]), A.observed(Vs[3]) } })
        local new, prov = out.values.commit('all')
        assert.equals('observed', prov[1].x.src)
        assert.equals('supplied', prov[2].x.src); assert.truthy(prov[2].x.journal); assert.equals(1, prov[2].x.journal.from)
        assert.equals('observed', prov[2].y.src) -- untouched values keep what they had
        for j = 1, 3 do assert.is_true(A.emit(T, new[j], prov[j]).ok) end
    end)

    it('every negative answer the algebra gives classifies on the reading axis, and the licenses are the charter\'s', function()
        local T = A.template(node('f', hole 'x', hole 'x', node('g', hole 'y')), { y = A.kinds { 'lit' } })
        assert.equals('absent', A.absence_of(A.match(T, node('f', lit 'a', lit 'b', node('g', lit 'c')))).absence)   -- store law
        assert.equals('absent', A.absence_of(A.match(T, node('h', lit 'a'))).absence)                                 -- kind
        assert.equals('act', A.absence_of(A.match(T, node('h', lit 'a'))).licenses)
        assert.equals('refused', A.absence_of(A.match(T, node('f', lit 'a', lit 'a', node('g', name 'n')))).absence) -- domain
        assert.equals('frontier', A.absence_of(A.instantiate(T, { x = lit 'a' })).absence)                            -- unfilled hole
        assert.equals('refused', A.absence_of(A.instantiate(T, { x = lit 'a', y = name 'n' })).absence)
        -- ~~a repetition hole made classify unavailable~~ since CLASSIFY.md it classifies; a context hole still does not
        local R = A.template(node('f', hole('r', true)))
        assert.equals('value', A.classify(R, { r = A.seq { lit 'a' } }, node('f', lit 'b')).kind)
        assert.equals('unavailable', A.absence_of(A.classify(A.template(node('f', A.ctx 'c')), {}, node('f', lit 'b'))).absence)
        assert.has_error(function() A.absence_of({ why = 'banana' }) end)
        -- every dropped member of random migrations classifies (no negative falls through)
        local n = 0
        for seed = 1, 60 do
            local T0 = A.template(node('f', hole 'a', hole 'b', hole 'a'))
            local Vs = {}
            for i = 1, 4 do Vs[i] = { a = lit(({ 'p', 'q' })[(seed + i) % 2 + 1]), b = lit(({ 'u', 'v' })[(seed * i) % 2 + 1]) } end
            local T1 = A.pin(A.merge(T0, 'b', 'a'), 'b', lit 'p')
            local r = A.migrate(T0, T1, Vs)
            for _, d in ipairs(r.dropped) do assert.is_true(A.is_absence(A.absence_of(d).absence)); n = n + 1 end
        end
        assert.is_true(n > 50)
    end)

    it('validity: values are stamped with the edit log; every edit invalidates, migrate re-stamps, a stale stamp is `unavailable`', function()
        local T = A.template(node('f', hole 'x', node('g', lit 'k'), hole 'y'))
        local V = { x = lit 'a', y = lit 'b' }
        local S = A.stamp(T, V)
        assert.is_true(A.valid(T, S))
        assert.is_true(A.instantiate_stamped(T, S).ok)
        local edits = {
            A.pin(T, 'x', lit 'a'), A.open_hole(A.pin(T, 'x', lit 'a'), 'x'), A.dig(T, { 2 }, 'z'),
            A.merge(A.template(node('f', hole 'x', hole 'y')), 'y', 'x'), A.split(A.template(node('f', hole 'x', hole 'x')), 'x', 2, 'x2'),
            A.rewrite(T, { 2 }, node('h', lit 'k')),
            A.join(T, node('f', lit 'a', node('g', lit 'k'), node('q', lit 'z'))).template,
        }
        assert.equals(7, #edits)
        for i, T2 in ipairs(edits) do
            assert.is_false((A.valid(T2, S)), 'edit ' .. i .. ' left the stamp valid')
            assert.is_not.equals(A.edit_key(T), A.edit_key(T2))
        end
        -- the key reads the edit's content, not only its count or op
        assert.is_not.equals(A.edit_key(A.pin(T, 'x', lit 'a')), A.edit_key(A.pin(T, 'x', lit 'b')))
        assert.is_not.equals(A.edit_key(A.pin(T, 'x', lit 'a')), A.edit_key(A.pin(T, 'y', lit 'a')))
        -- pin-then-open restores the body but NOT the key: the history is the key, not the shape
        local back = A.open_hole(A.pin(T, 'x', lit 'a'), 'x')
        assert.is_true(A.eq(back.body, T.body)); assert.is_false((A.valid(back, S)))
        local r = A.instantiate_stamped(back, S)
        assert.is_false(r.ok); assert.equals('unavailable', r.absence)
        assert.is_false((A.valid(T, { values = V })))
        -- migrate hands back values stamped for the new template
        local m = A.migrate(T, back, { V })
        assert.is_true(A.valid(back, m.stamped[1]))
        assert.is_true(A.instantiate_stamped(back, m.stamped[1]).ok)
    end)
end)

describe('demand-keyed invalidation (Mokhov, Mitchell, Peyton Jones, Build Systems à la Carte, ICFP 2018)', function()
    local function sprsh1()
        return {
            B1 = function(fetch) return fetch 'A1' + fetch 'A2' end,
            B2 = function(fetch) return fetch 'B1' * 2 end,
        }
    end
    local function sprsh2()
        return {
            B1 = function(fetch) local c1 = fetch 'C1'; if c1 == 1 then return fetch 'B2' else return fetch 'A2' end end,
            B2 = function(fetch) local c1 = fetch 'C1'; if c1 == 1 then return fetch 'A1' else return fetch 'B1' end end,
        }
    end
    local function has(list, k) for _, x in ipairs(list) do if x == k then return true end end; return false end

    it('§3.2/3.3 sprsh1: B1 = 30, B2 = 60; the second build executes nothing; a changed input reruns its dependents only', function()
        for _, rb in ipairs { 'busy', 'vt', 'ct' } do
            local s = A.new_store { A1 = 10, A2 = 20 }
            local log = A.build(sprsh1(), 'B2', s, { rebuilder = rb })
            assert.equals(30, s.values.B1); assert.equals(60, s.values.B2)
            assert.equals(2, #log.executed)
            assert.is_true((A.build_correct(sprsh1(), log, { A1 = 10, A2 = 20 })))
            local again = A.build(sprsh1(), 'B2', s, { rebuilder = rb })
            if rb == 'busy' then assert.equals(2, #again.executed) else assert.equals(0, #again.executed) end
        end
        local s = A.new_store { A1 = 10, A2 = 20 }
        A.build(sprsh1(), 'B2', s)
        s.values.A2 = 25
        local log = A.build(sprsh1(), 'B2', s)
        assert.same({ 'B1', 'B2' }, log.executed); assert.equals(70, s.values.B2)
    end)

    it('§2.3/Fig. 3 early cutoff: an unchanged intermediate result stops the rebuild', function()
        local s = A.new_store { A1 = 10, A2 = 20 }
        A.build(sprsh1(), 'B2', s)
        s.values.A1, s.values.A2 = 15, 15 -- the sum is still 30
        local log = A.build(sprsh1(), 'B2', s)
        assert.same({ 'B1' }, log.executed); assert.is_true(has(log.verified, 'B2'))
        -- the paper's shape: a comment added to main.c reruns main.o and not main.exe
        local strip = function(src) return (src:gsub('/%*.-%*/', '')) end
        local tasks = {
            ['main.o'] = function(fetch) return 'obj(' .. strip(fetch 'main.c') .. fetch 'util.h' .. ')' end,
            ['util.o'] = function(fetch) return 'obj(' .. strip(fetch 'util.c') .. fetch 'util.h' .. ')' end,
            ['main.exe'] = function(fetch) return fetch 'main.o' .. '+' .. fetch 'util.o' end,
        }
        local st = A.new_store { ['main.c'] = 'int main(){}', ['util.c'] = 'int u(){}', ['util.h'] = 'int u();' }
        assert.equals(3, #A.build(tasks, 'main.exe', st).executed)
        st.values['main.c'] = '/* a comment */int main(){}'
        local l2 = A.build(tasks, 'main.exe', st)
        assert.same({ 'main.o' }, l2.executed)
        st.values['util.h'] = 'int u(int);'
        assert.equals(3, #A.build(tasks, 'main.exe', st).executed) -- Fig. 1(b): everything depends on util.h
    end)

    it('§3.5/3.7 sprsh2: dynamic dependencies are the ones demanded; a key not read does not rerun (against Excel\'s rule)', function()
        local s = A.new_store { A1 = 10, A2 = 20, C1 = 1 }
        local fetch = function(k) return s.values[k] end
        local v, deps = A.track(sprsh2().B1, function(k) if k == 'B2' then return 10 end; return fetch(k) end)
        assert.equals(10, v); assert.same({ { k = 'C1', hash = A.hash(1) }, { k = 'B2', hash = A.hash(10) } }, deps)
        s.values.C1 = 2
        local v2, deps2 = A.track(sprsh2().B1, fetch)
        assert.equals(20, v2); assert.same({ { k = 'C1', hash = A.hash(2) }, { k = 'A2', hash = A.hash(20) } }, deps2)
        -- statically B1 and B2 form a cycle; dynamically they do not
        s.values.C1 = 1
        local log = A.build(sprsh2(), 'B1', s)
        assert.equals(10, s.values.B1); assert.same({ 'B2', 'B1' }, log.executed)
        s.values.A2 = 99 -- not demanded while C1 = 1
        assert.equals(0, #A.build(sprsh2(), 'B1', s).executed)
        s.values.C1 = 2 -- now B1 reads A2, and B2 reads B1
        local l3 = A.build(sprsh2(), 'B2', s)
        assert.equals(99, s.values.B1); assert.equals(99, s.values.B2)
        assert.is_true(has(l3.executed, 'B1') and has(l3.executed, 'B2'))
        -- a real cycle is refused by name
        local cyc = { X = function(fetch) return fetch 'Y' end, Y = function(fetch) return fetch 'X' end }
        assert.has_error(function() A.build(cyc, 'X', A.new_store {}) end)
    end)

    it('§6.5 self-tracking: the formula is a key, so editing it reruns the cell', function()
        local tasks = {
            B1 = function(fetch)
                local f = fetch 'B1-formula'
                if f == '+' then return fetch 'A1' + fetch 'A2' else return fetch 'A1' * fetch 'A2' end
            end,
        }
        local s = A.new_store { A1 = 20, A2 = 10, ['B1-formula'] = '+' }
        A.build(tasks, 'B1', s); assert.equals(30, s.values.B1)
        s.values['B1-formula'] = '*'
        assert.same({ 'B1' }, A.build(tasks, 'B1', s).executed); assert.equals(200, s.values.B1)
    end)

    it('§4.2.2 verifyVT takes the current value\'s hash: a corrupted intermediate is rebuilt even when its dependencies verify', function()
        local s = A.new_store { A1 = 10, A2 = 20 }
        A.build(sprsh1(), 'B2', s)
        s.values.B1 = 999 -- an intermediate overwritten behind the build system's back
        local log = A.build(sprsh1(), 'B2', s)
        assert.same({ 'B1' }, log.executed); assert.equals(30, s.values.B1); assert.equals(60, s.values.B2)
    end)

    it('§4.2.3 constructive traces restore a value without a run when an input flips back', function()
        local s = A.new_store { A1 = 10, A2 = 20 }
        A.build(sprsh1(), 'B2', s, { rebuilder = 'ct' })
        s.values.A2 = 25
        assert.equals(2, #A.build(sprsh1(), 'B2', s, { rebuilder = 'ct' }).executed)
        s.values.A2 = 20
        local log = A.build(sprsh1(), 'B2', s, { rebuilder = 'ct' })
        assert.equals(0, #log.executed); assert.same({ 'B1', 'B2' }, log.restored); assert.equals(60, s.values.B2)
    end)

    it('§7.3 edit distance as a build: one changed symbol reruns only the affected cells', function()
        local a, b = 'kitten', 'sitting'
        local tasks = {}
        local function C(i, j) return 'C' .. i .. ',' .. j end
        for i = 0, #a do for j = 0, #b do
            if i == 0 then tasks[C(i, j)] = function() return j end
            elseif j == 0 then tasks[C(i, j)] = function() return i end
            else
                tasks[C(i, j)] = function(fetch)
                    if fetch('A' .. i) == fetch('B' .. j) then return fetch(C(i - 1, j - 1)) end
                    return 1 + math.min(fetch(C(i, j - 1)), fetch(C(i - 1, j)), fetch(C(i - 1, j - 1)))
                end
            end
        end end
        local inputs = {}
        for i = 1, #a do inputs['A' .. i] = a:sub(i, i) end
        for j = 1, #b do inputs['B' .. j] = b:sub(j, j) end
        local s = A.new_store(inputs)
        local log = A.build(tasks, C(#a, #b), s)
        assert.equals(3, s.values[C(#a, #b)])
        local total = #log.executed
        -- demand-driven: when a_i == b_j only the diagonal is fetched, so fewer than the full
        -- (#a+1)(#b+1) = 56 cells are ever built
        assert.is_true(total < (#a + 1) * (#b + 1) and total > 20, 'built ' .. total)
        s.values.A6 = 'g' -- "kitteg"
        local l2 = A.build(tasks, C(#a, #b), s)
        assert.equals(3, s.values[C(#a, #b)]) -- kitteg vs sitting: k/s, e/i, g/n, +g
        assert.is_true(#l2.executed < total and #l2.executed > 0, 'reran ' .. #l2.executed .. ' of ' .. total)
        for _, k in ipairs(l2.executed) do assert.truthy(k:match('^C6,'), k .. ' does not depend on A6') end
    end)

    it('LAW over random dynamic task graphs: Def 3.1 correctness and Def 2.1 minimality, busy and vt agree', function()
        local s0 = 4242
        local function rnd(n) s0 = (s0 * 1103515245 + 12345) % 2147483648; return math.floor(s0 / 65536) % n + 1 end
        local checked, reruns, cutoffs = 0, 0, 0
        for seed = 1, 120 do
            local nin, ntask = 2 + rnd(3), 3 + rnd(5)
            local inputs, keys = {}, {}
            for i = 1, nin do inputs['i' .. i] = rnd(4); keys[#keys + 1] = 'i' .. i end
            local tasks = {}
            for t = 1, ntask do
                local k = 't' .. t
                local a, b, c = keys[rnd(#keys)], keys[rnd(#keys)], keys[rnd(#keys)]
                local dyn = rnd(2) == 1
                tasks[k] = function(fetch)
                    local x = fetch(a)
                    if dyn then
                        if x % 2 == 0 then return math.floor((x + fetch(b)) / 2) end
                        return math.floor((x + fetch(c)) / 2)
                    end
                    return math.floor((x + fetch(b) + fetch(c)) / 3)
                end
                keys[#keys + 1] = k
            end
            local target = 't' .. ntask
            local s = A.new_store(inputs)
            local log = A.build(tasks, target, s)
            assert.is_true((A.build_correct(tasks, log, inputs)), 'seed ' .. seed .. ' correctness')
            assert.equals(0, #A.build(tasks, target, s).executed, 'seed ' .. seed .. ' second build')
            -- change one input; every executed task must transitively depend on it (per the previous traces)
            local ch = 'i' .. rnd(nin)
            local before = A.dependents(s, { [ch] = true })
            local had_trace = {}
            for k in pairs(s.info.vt) do had_trace[k] = true end
            s.values[ch] = s.values[ch] + 1
            local l2 = A.build(tasks, target, s)
            local seen = {}
            for _, k in ipairs(l2.executed) do
                assert.is_nil(seen[k], 'seed ' .. seed .. ' ran ' .. k .. ' twice'); seen[k] = true
                -- Def 2.1: only if it transitively depends on the changed input; a task reached
                -- for the first time through a newly discovered dynamic dependency (Fig. 2) has
                -- no trace and must run
                assert.is_true(before[k] == true or not had_trace[k], 'seed ' .. seed .. ' ran ' .. k .. ' which did not depend on ' .. ch)
            end
            assert.is_true((A.build_correct(tasks, l2, s.values)), 'seed ' .. seed .. ' correctness after edit')
            -- busy agrees on every value
            local sb = A.new_store(s.values)
            for k in pairs(tasks) do sb.values[k] = nil end
            A.build(tasks, target, sb, { rebuilder = 'busy' })
            local touched = {}
            for _, list in ipairs { l2.executed, l2.verified, l2.restored } do for _, k in ipairs(list) do touched[k] = true end end
            for k in pairs(touched) do assert.equals(sb.values[k], s.values[k], 'seed ' .. seed .. ' key ' .. k) end
            checked = checked + 1; reruns = reruns + #l2.executed
            local dep_count = 0
            for k in pairs(before) do if tasks[k] then dep_count = dep_count + 1 end end
            if #l2.executed < dep_count then cutoffs = cutoffs + 1 end
        end
        assert.equals(120, checked)
        assert.is_true(cutoffs > 10, 'early cutoff observed in ' .. cutoffs .. ' of 120')
    end)

    it('a family: an analyzer that reads only fixed sites runs once; one that reads holes runs once per distinct projection', function()
        local T = A.template(node('f', node('g', lit 'k'), hole 'x', hole 'y'))
        local Vs = {}
        for i = 1, 12 do Vs[i] = { x = lit(({ 'a', 'b', 'c' })[i % 3 + 1]), y = lit('v' .. i) } end
        local fixed_only = function(read) return A.show(read { path = { 1 } }) end
        local r = A.family_analyze(T, Vs, fixed_only)
        assert.equals(1, #r.runs); assert.equals(11, #r.reused)
        for i = 1, 12 do assert.equals('(g "k")', r.results[i]) end
        local reads_x = function(read) return A.show(read { path = { 1 } }) .. '/' .. A.show(read { hole = 'x' }) end
        local r2 = A.family_analyze(T, Vs, reads_x)
        assert.equals(3, #r2.runs) -- three distinct values of x
        for i = 1, 12 do assert.equals(reads_x(function(spec) if spec.hole then return Vs[i][spec.hole] end; return node('g', lit 'k') end), r2.results[i]) end
        -- dynamic demand: y is read only when x is "a"; members with other x share one trace regardless of y
        local dyn = function(read)
            local x = read { hole = 'x' }
            if x.v == 'a' then return 'a:' .. read({ hole = 'y' }).v end
            return 'not-a'
        end
        local r3 = A.family_analyze(T, Vs, dyn)
        assert.equals(4 + 2, #r3.runs) -- four members with x=a (each y distinct) + one run each for b and c
    end)

    it('edits: a rewrite outside every demanded site costs zero reruns, a rewrite inside reruns all, a value edit reruns one member', function()
        local T = A.template(node('f', node('g', lit 'k'), node('h', lit 'm'), hole 'x'))
        local Vs = { { x = lit 'a' }, { x = lit 'b' }, { x = lit 'a' } }
        local an = function(read) return A.show(read { path = { 1 } }) .. '/' .. A.show(read { hole = 'x' }) end
        local r = A.family_analyze(T, Vs, an)
        assert.equals(2, #r.runs)
        -- rewrite path 2, which nobody reads: the cache still verifies every member
        local T2 = A.rewrite(T, { 2 }, node('h', lit 'changed'))
        local m = A.migrate(T, T2, Vs)
        local r2 = A.family_analyze(T2, m.values, an, r.cache)
        assert.equals(0, #r2.runs); assert.equals(3, #r2.reused)
        -- rewrite path 1, which everyone reads: every distinct projection reruns
        local T3 = A.rewrite(T, { 1 }, node('g', lit 'K'))
        local r3 = A.family_analyze(T3, A.migrate(T, T3, Vs).values, an, r.cache)
        assert.equals(2, #r3.runs)
        -- a value edit on one member: only its new projection runs
        local Vs2 = { { x = lit 'a' }, { x = lit 'b' }, { x = lit 'z' } }
        local r4 = A.family_analyze(T, Vs2, an, r.cache)
        assert.same({ 3 }, r4.runs)
        -- and the edit-log stamp is the coarse key: it invalidates on the rewrite the demand key survives
        assert.is_false((A.valid(T2, A.stamp(T, Vs[1]))))
    end)
end)

describe('derived domains: a hole\'s domain is a summary of its value column unless supplied (DOMAINS.md)', function()
    local function call(f, ...) return node('call', name(f), ...) end
    local Is = { call('register', lit 'on_tick', name 'tick'), call('register', lit 'on_draw', name 'draw'), call('register', lit 'on_key', name 'key') }

    it('origins: bare API domains, pins and digs with a domain are supplied; everything an operator computes is derived', function()
        local T = A.template(call('register', hole 'key', hole 'fn'), { key = A.kinds { 'lit' } })
        assert.equals('supplied', T.holes.key.origin); assert.equals('derived', T.holes.fn.origin)
        local g = A.generalize(Is, { need = 100 })
        for h, e in pairs(g.template.holes) do assert.equals('derived', e.origin, h) end
        local P = A.pin(g.template, 'h1', lit 'on_tick')
        assert.equals('supplied', P.holes.h1.origin); assert.equals('derived', P.holes.h1.was_origin)
        local O = A.open_hole(P, 'h1')
        assert.equals('derived', O.holes.h1.origin); assert.is_nil(O.holes.h1.was_origin)
        local D1 = A.dig(T, { 1 }, 'callee'); assert.equals('derived', D1.holes.callee.origin)
        local D2 = A.dig(T, { 1 }, 'callee', A.kinds { 'name' }); assert.equals('supplied', D2.holes.callee.origin)
        local M2 = A.merge(A.template(node('f', hole 'a', hole 'b'), { a = A.kinds { 'lit' } }), 'a', 'b')
        assert.equals('supplied', M2.holes.a.origin) -- a premise survives a merge
        local S = A.split(A.template(node('f', hole 'a', hole 'a')), 'a', 2, 'a2')
        assert.equals('derived', S.holes.a2.origin)
    end)

    it('origins travel: a derived family stays derived through apply, fill, abstract, match, join and migrate', function()
        local g = A.generalize(Is, { need = 100 })
        local T = g.template
        local A1 = A.apply(T, { h1 = lit 'x' }); assert.equals('derived', A1.holes.h2.origin)
        local F = A.fill(T, 'h1', A.template(node('wrap', hole 'w'))); assert.equals('derived', F.holes.h2.origin); assert.equals('derived', F.holes.w.origin)
        local m = A.match(T, Is[1]); local Ab = A.abstract(Is[1], m.sites)
        for h, e in pairs(Ab.holes) do assert.equals('derived', e.origin, h) end
        local J = A.join(T, call('subscribe', lit 'a', name 'b')).template
        for h, e in pairs(J.holes) do assert.equals('derived', e.origin, h) end
        local P = A.pin(T, 'h1', lit 'on_tick')
        local J2 = A.join(P, Is[1]).template
        assert.equals('supplied', J2.holes.h1.origin); assert.equals('derived', J2.holes.h2.origin)
        local mg = A.migrate(T, A.rewrite(T, { 1 }, name 'reg'), g.values)
        for h, e in pairs(mg.template.holes) do assert.equals('derived', e.origin, h) end
    end)

    it('the one summary function: summarize is the fold of widen, and generalize equals the fold of join on DOMAINS, not only bodies', function()
        local s0 = 31337
        local function rnd(n) s0 = (s0 * 1103515245 + 12345) % 2147483648; return math.floor(s0 / 65536) % n + 1 end
        local pool = { lit 'a', lit 'b', lit 'c', lit 'd', name 'x', name 'y', node('g', lit 'k'), node('g', lit 'm') }
        for seed = 1, 200 do
            local col = {}
            for i = 1, 1 + rnd(6) do col[i] = pool[rnd(#pool)] end
            local D = A.closed(col[1])
            for i = 2, #col do D = A.widen(D, col[i]) end
            assert.equals(A.show_domain(D), A.show_domain(A.summarize(col)), 'seed ' .. seed)
            local E = { summary = 'enumerate' }
            local DE = A.closed(col[1])
            for i = 2, #col do DE = A.widen(DE, col[i], E) end
            assert.equals(A.show_domain(DE), A.show_domain(A.summarize(col, E)), 'seed ' .. seed .. ' enumerate')
        end
        -- generalize's domains are the column's summaries; the fold of join (adjoin) lands on the same domains
        for seed = 1, 60 do
            local n = 2 + rnd(3)
            local members = {}
            for i = 1, n do members[i] = node('f', pool[rnd(#pool)], pool[rnd(#pool)], lit 'fixed') end
            local g = A.generalize(members, { need = 100 })
            for h, e in pairs(g.template.holes) do
                local col = {}
                for i = 1, n do col[i] = g.values[i][h] end
                assert.equals(A.show_domain(A.summarize(col)), A.show_domain(e.domain), 'seed ' .. seed .. ' hole ' .. h)
            end
            local T, Vs = A.template(A.copy(members[1])), { {} }
            for i = 2, n do
                local r = A.adjoin(T, Vs, members[i])
                T, Vs = r.template, r.values
            end
            assert.is_true(A.iso(T, g.template, { domains = true }), 'seed ' .. seed .. ' fold domains')
        end
    end)

    it('migrate recomputes derived domains from the survivors: a dig without a domain gets its summary, a pin-then-open returns to the column', function()
        local g = A.generalize(Is, { need = 100 })
        local T = g.template
        local D = A.dig(T, { 1 }, 'callee')
        local m = A.migrate(T, D, g.values)
        assert.equals('derived', m.template.holes.callee.origin)
        -- every member's callee is `register`: the summary of a constant column is that value,
        -- derived (so an observation widens it) rather than pinned
        assert.equals('=register', A.show_domain(m.template.holes.callee.domain))
        local C = A.classify(m.template, m.values[1], call('subscribe', lit 'on_tick', name 'tick'))
        assert.equals('value', C.kind); assert.equals('{name}', A.show_domain(C.template.holes.callee.domain))
        local Dd = A.dig(T, { 1 }, 'callee', A.kinds { 'lit' })
        local md = A.migrate(T, Dd, g.values)
        assert.equals(0, #md.kept); assert.truthy(md.dropped[1].why:find('domain refuses'))
        -- pin then open: the domain comes back as the column's summary, derived, not as the pinned record
        local P = A.pin(T, 'h1', lit 'on_tick')
        local O = A.open_hole(P, 'h1')
        local mo = A.migrate(T, O, g.values)
        assert.equals(1, #mo.kept) -- pin dropped two members at its step
        assert.equals('derived', mo.template.holes.h1.origin)
        -- one survivor, so the column's summary is its one value: derived, not the pinned record
        assert.equals('="on_tick"', A.show_domain(mo.template.holes.h1.domain))
        assert.is_nil(mo.template.holes.h1.was)
    end)

    it('a template-part commit is a membership change: each of the two families gets summaries of its own column', function()
        local members = { call('register', lit 'a', name 'x'), call('register', lit 'b', name 'y'), call('register', name 'c', name 'z') }
        local g = A.generalize(members, { need = 100 })
        assert.equals('{lit|name}', A.show_domain(g.template.holes.h1.domain)) -- a mixed column summarises as the union of kinds
        local C = A.classify(g.template, g.values[1], call('subscribe', lit 'a', name 'x'))
        assert.equals('template', C.kind)
        local P = A.propagate(g.template, C, g.values, 1)
        local R = P.template.commit({ 1, 2 })
        assert.equals('{lit}', A.show_domain(R.families[1].template.holes.h1.domain)) -- members 1,2: literals only
        assert.equals('=c', A.show_domain(R.families[2].template.holes.h1.domain))   -- member 3 alone
        assert.equals('{lit|name}', A.show_domain(g.template.holes.h1.domain))         -- the caller's template untouched
        assert.equals('{lit|name}', A.show_domain(R.link.holes.h1.domain))             -- the link still spans both
    end)

    it('the re-derivation finding is closed: a family built by join and one built by generalize classify a third variant alike', function()
        local a, b = node('f', lit(1), lit 'k'), node('f', lit(2), lit 'k')
        local G = A.generalize({ a, b }, { need = 100 })
        local J = A.adjoin(A.template(A.copy(a)), { {} }, b)
        assert.is_true(A.iso(G.template, J.template, { domains = true }))
        local Cg = A.classify(G.template, G.values[1], node('f', lit(99), lit 'k'))
        local Cj = A.classify(J.template, J.values[1], node('f', lit(99), lit 'k'))
        assert.equals('value', Cg.kind); assert.equals('value', Cj.kind)
    end)
end)

describe('hedge-aware join: alignment is forced by one hedge hole, else by identical ends (HEDGEJOIN.md)', function()
    local counter = 0
    local function list(n)
        local xs = { name 'f' }
        for _ = 1, n do counter = counter + 1; xs[#xs + 1] = lit(counter) end
        return node('call', unpack(xs))
    end
    local function wrap(n, leaf)
        local t = leaf or lit 'x'
        for _ = 1, n do t = node('wrap', t) end
        return t
    end
    local function hole_rep(h) return A.hole(h, true) end

    it('FORCED: a family with one hedge hole adopts a longer member with the hole kept, nothing widened', function()
        local g = A.generalize { list(3), list(4), list(5) }
        assert.equals('@h1.elem{0,}', A.show_domain(g.template.holes.h1.domain))
        local r = A.join(g.template, list(9), { env = g.env })
        assert.same({ 'h1' }, r.kept); assert.same({}, r.new); assert.same({}, r.split)
        assert.same({}, r.widened) -- an instance of the claim widens nothing
        assert.same({}, r.absorbed)
        assert.equals(9, #r.right({}).h1.kids)
        assert.equals('(call f ?h1...)', A.show(r.template.body))
    end)

    it('FORCED: the fixed parts before and after the hedge hole align positionally, the hole takes the middle', function()
        local T = A.template(node('call', name 'f', hole_rep 'X', name 'g', hole 'y'))
        local r = A.join(T, node('call', name 'f', lit(1), lit(2), name 'g', lit(3)))
        assert.equals('(call f ?X... g ?y)', A.show(r.template.body))
        assert.same({ 'X', 'y' }, (function(k) table.sort(k); return k end)(r.kept))
        local V = r.right({})
        assert.equals('(seq 1 2)', A.show(V.X)); assert.equals('3', A.show(V.y))
        -- an empty middle is a legal slice
        local r0 = A.join(T, node('call', name 'f', name 'g', lit(3)))
        assert.equals(0, #r0.right({}).X.kids)
        -- a suffix that differs: the fixed part becomes a hole, the hedge hole is still kept
        local r2 = A.join(T, node('call', name 'f', lit(1), lit(2), name 'q', lit(3)))
        assert.equals('(call f ?X... ?j1 ?y)', A.show(r2.template.body))
        assert.same({ 'j1' }, r2.new)
    end)

    it('ENDS: two ground lists of unequal length keep the identical prefix and suffix; the middle is a hedge hole', function()
        local r = A.join(node('f', lit(1), lit(2), name 'z'), node('f', lit(1), lit(2), lit(3), name 'z'))
        assert.equals('(f 1 2 ?j1... z)', A.show(r.template.body))
        assert.equals('=3{0,}', A.show_domain(r.template.holes.j1.domain)) -- one element seen: closed
        assert.equals('(seq 3)', A.show(r.right({}).j1)); assert.equals('(seq)', A.show(r.left({}).j1)) -- left is the empty slice
        -- the hedge domain is a summary of the ELEMENTS, widened by the next member
        local j = A.adjoin(r.template, { r.left({}), r.right({}) }, node('f', lit(1), lit(2), name 'a', lit(4), name 'z'))
        assert.equals('{lit|name}{0,}', A.show_domain(j.template.holes.j1.domain))
        assert.same({}, j.join.new)
        assert.equals('(seq a 4)', A.show(j.values[3].j1))
    end)

    it('a hedge hole swallowed by a wider middle is reported as absorbed, and the mappers still splice it', function()
        local T = A.template(node('f', name 'a', hole_rep 'X', name 'g', name 'h'))
        -- with room for the fixed parts the alignment is forced and a differing fixed part is a term hole
        assert.equals('(f a ?X... ?j1 h)', A.show(A.join(T, node('f', name 'a', lit(1), name 'q', name 'h')).template.body))
        -- without room (the newcomer is shorter than the fixed parts) the ends rule runs and the middle swallows X
        local r = A.join(T, node('f', name 'a', name 'h'))
        assert.equals('(f a ?j1... h)', A.show(r.template.body))
        assert.same({ { from = 'X', to = 'j1' } }, r.absorbed)
        assert.same({ 'j1' }, r.new)
        local W = r.left({ X = A.seq { lit(7), lit(8) } })
        assert.equals('(seq 7 8 g)', A.show(W.j1)) -- X spliced into the wider slice
    end)

    it('several hedge holes in one list: join places the fixed segment between them at its leftmost fit (LCSJOIN.md), as the matchers do; the derived match searches the split (DMATCH.md)', function()
        local T = A.template(node('f', hole_rep 'X', name 'a', hole_rep 'Y'))
        local r = A.join(T, node('f', name 'b', name 'a', name 'c'))
        -- ~~'?j1' (the node became a hole)~~ since LCSJOIN.md the k-hedge forced rule keeps the template
        assert.equals('(f ?X... a ?Y...)', A.show(r.template.body))
        assert.same({}, r.new)
        local W = A.match(r.template, node('f', name 'b', name 'a', name 'c')).values
        assert.equals('(seq b)', A.show(W.X)); assert.equals('(seq c)', A.show(W.Y))
        -- the original matcher backtracks and finds the split; ~~the derived one refuses by name~~
        -- since DMATCH.md the derived one enumerates the widths (Kutsia's Projection and Widening)
        -- and closes each candidate with this join, so it finds the same split
        assert.is_true(A.match(T, node('f', name 'b', name 'a', name 'c')).ok)
        local D = require 'derive'
        local M2 = dofile('algebra.lua')
        D.apply_to(M2, 'match')
        local m = M2.match(T, node('f', name 'b', name 'a', name 'c'))
        D.apply_to(A, os.getenv('DERIVE') or '') -- rebind the basis to the suite's module
        assert.is_true(m.ok, m.refusal and m.refusal.why)
        assert.equals('(seq b)', A.show(m.values.X)); assert.equals('(seq c)', A.show(m.values.Y))
        assert.equals(1, m.sites.X.sites[1].n); assert.equals(1, m.sites.Y.sites[1].n)
    end)

    it("the 'none' rigidity is the fixed-arity lgg: unequal lists make a node hole (what the classify diff reads)", function()
        local r = A.join(node('f', lit(1), lit(2)), node('f', lit(1), lit(2), lit(3)), { align = 'none' })
        assert.equals('?j1', A.show(r.template.body))
        local r2 = A.join(node('f', lit(1), lit(2)), node('f', lit(1), lit(2), lit(3)))
        assert.equals('(f 1 2 ?j1...)', A.show(r2.template.body))
    end)

    it("adjoin under the 'none' rigidity keeps the old shape (a node hole), so classify still works on an arity-divergent family", function()
        local T, Vs = A.template(node('f', hole 'a', lit(2))), { { a = lit(1) } }
        local j = A.adjoin(T, Vs, node('f', lit(1), lit(2), lit(3)))
        assert.equals('(f ?a 2 ?j1...)', A.show(j.template.body)) -- default: ~~'(f ?j1...)'~~ since LCSJOIN.md the 2 anchors and ?a aligns with 1
        -- ~~the hedge is what classify refuses~~ since CLASSIFY.md the hedge family classifies too: a value edit of ?a
        assert.equals('value', A.classify(j.template, j.values[1], node('f', lit(5), lit(2), lit(3))).kind)
        local jn = A.adjoin(T, Vs, node('f', lit(1), lit(2), lit(3)), { align = 'none' })
        assert.equals('?j1', A.show(jn.template.body))
        assert.equals('value', A.classify(jn.template, jn.values[1], node('f', lit(5), lit(2))).kind)
    end)

    it('the repetition claim is a summary over the column: a fold of join plus rederive equals generalize', function()
        local i3, i4, i5 = list(3), list(4), list(5)
        local env = { defs = {} }
        local r1 = A.join(A.template(i3), i4, { prefix = 'h', env = env })
        local values = { r1.left({}), r1.right({}) }
        local r2 = A.join(r1.template, i5, { prefix = 'h', env = env })
        values = { r2.left(values[1]), r2.left(values[2]), r2.right({}) }
        local T = r2.template
        assert.equals('{lit}{0,}', A.show_domain(T.holes.h1.domain)) -- join wrote the element summary
        local _, notes = A.rederive_domains(T, values, { env = env })
        assert.equals('@h1.elem{0,}', A.show_domain(T.holes.h1.domain)) -- rederive made the claim
        assert.equals('rep', notes.h1.claimed); assert.equals(3, notes.h1.distinct)
        assert.is_true(A.match(T, list(9), env).ok)
        -- idempotent: a second pass reads the same column and writes the same claim
        A.rederive_domains(T, values, { env = env })
        assert.equals('@h1.elem{0,}', A.show_domain(T.holes.h1.domain))
        -- without an env the claim is left as it stands, never demoted
        A.rederive_domains(T, values)
        assert.equals('@h1.elem{0,}', A.show_domain(T.holes.h1.domain))
        -- and generalize proper says the same
        local g = A.generalize { i3, i4, i5 }
        assert.equals(A.show(g.template.body), A.show(T.body))
        assert.equals(A.show_domain(g.template.holes.h1.domain), A.show_domain(T.holes.h1.domain))
    end)

    it('below `need` the hedge domain is the element summary, not open (was rep(open) before HEDGEJOIN.md)', function()
        local g = A.generalize { list(3), list(4) }
        assert.equals('open', g.notes.h1.claimed); assert.is_true(g.notes.h1.under_determined)
        assert.equals('{lit}{0,}', A.show_domain(g.template.holes.h1.domain))
        assert.is_false(A.match(g.template, node('call', name 'f', lit(1), name 'oops'), g.env).ok) -- a name is not a literal
    end)

    it('the recursion claim is a summary too: rederive with an env claims, re-claims idempotently, and reads depths with the hole open', function()
        local env = { defs = {} }
        local r1 = A.join(A.template(wrap(1)), wrap(2), { prefix = 'h', env = env })
        local values = { r1.left({}), r1.right({}) }
        local r2 = A.join(r1.template, wrap(3), { prefix = 'h', env = env })
        values = { r2.left(values[1]), r2.left(values[2]), r2.right({}) }
        local T = r2.template
        local _, notes = A.rederive_domains(T, values, { env = env })
        assert.equals('(@h1.base | @self)', A.show_domain(T.holes.h1.domain))
        assert.equals('rec', notes.h1.claimed); assert.same({ 0, 1, 2 }, notes.h1.depths)
        assert.is_true(A.match(T, wrap(7), env).ok)
        A.rederive_domains(T, values, { env = env })
        assert.equals('(@h1.base | @self)', A.show_domain(T.holes.h1.domain))
        -- a matching newcomer widens nothing, not even a claim written as (@base | @self)
        assert.same({}, A.join(T, wrap(4), { env = env }).widened)
        -- a newcomer with another leaf: depths are read with the hole OPEN, so the base widens to both leaves
        -- (read with the hole closed, (wrap y) is depth 0 and the base would swallow a wrap)
        local col = { values[1], values[2], values[3], { h1 = wrap(1, lit 'y') } }
        A.rederive_domains(T, col, { env = env })
        local base0 = env.defs['h1.base']
        assert.equals('{lit}', A.show_domain(base0.holes[base0.body.h].domain))
        local j = A.adjoin(T, values, wrap(2, lit 'y'), { env = env })
        assert.same({}, j.join.new)
        assert.equals('(@h1.base | @self)', A.show_domain(j.template.holes.h1.domain))
        assert.is_true(A.match(j.template, wrap(5, lit 'y'), env).ok)
        assert.is_true(A.match(j.template, wrap(5), env).ok)
        -- the base is the summary of the two LEAVES; read with the hole closed it would swallow a wrap
        local base = env.defs['h1.base']
        assert.equals('{lit}', A.show_domain(base.holes[base.body.h].domain))
    end)

    it('adjoin never refuses on a derived hedge domain: a heterogeneous newcomer widens the claim back to a summary', function()
        local g = A.generalize { list(3), list(4), list(5) }
        local j = A.adjoin(g.template, g.values, node('call', name 'f', lit(1), node('q')), { env = g.env })
        assert.same({}, j.join.new)
        assert.equals('{lit|q}{0,}', A.show_domain(j.template.holes.h1.domain))
        assert.equals(1, #j.join.widened)
    end)

    it('join takes the options generalize had: keyed tables, the linear variant, and grammars with boundary-named holes', function()
        local function pr(k, v) return node('pair', lit(k), v) end
        local r = A.join(node('table', pr('a', lit(1)), pr('b', lit(2)), pr('c', lit(3))), node('table', pr('a', lit(9)), pr('c', lit(3)), pr('d', lit(4))))
        assert.equals('(table (pair "a" ?j1) (pair "c" 3) ?j2...)', A.show(r.template.body))
        assert.equals('(seq (pair "b" 2))', A.show(r.left({}).j2))
        local rp = A.join(node('table', pr('a', lit(1)), pr('b', lit(2))), node('table', pr('a', lit(9)), pr('c', lit(3))), { positional = true })
        assert.equals('(table (pair "a" ?j1) (pair ?j2 ?j3))', A.show(rp.template.body))
        assert.equals('(f ?j1 ?j1)', A.show(A.join(node('f', lit(1), lit(1)), node('f', lit(2), lit(2))).template.body))
        assert.equals('(f ?j1 ?j2)', A.show(A.join(node('f', lit(1), lit(1)), node('f', lit(2), lit(2)), { linear = true }).template.body))
        -- the derived match and diff stay POSITIONAL, like the originals: swapped keys are a refusal, not a match
        local Tk = A.template(node('table', pr('a', hole 'x'), pr('b', lit(2))))
        local swapped = node('table', pr('b', lit(2)), pr('a', lit(1)))
        assert.is_false(A.match(Tk, swapped).ok)
        local D = require 'derive'
        local M2 = dofile('algebra.lua')
        D.apply_to(M2, 'match')
        local mk = M2.match(Tk, swapped)
        D.apply_to(A, os.getenv('DERIVE') or '')
        assert.is_false(mk.ok)
        local function doc(cmd) return node('doc', node('command', lit(cmd))) end
        local rg = A.join(doc('run fast'), doc('run slow'), { grammars = { command = 'sh' } })
        assert.equals('(doc (command (embed (cmd run ?j1.1))))', A.show(rg.template.body))
        assert.equals('fast', rg.left({})['j1.1'].v)
    end)
end)

describe('unification: the meet of the generality order (UNIFY.md; Martelli & Montanari 1982 §2)', function()
    it('a repeated hedge variable is infinitary: x·a = a·x stops by name instead of looping (found through DERIVE=instance_of in VMIN.md)', function()
        local xs, ys = A.hole('x', true), A.hole('y', true)
        local T1 = A.template(node('g', node('f', xs), node('f', node 'c', xs, node 'a')))
        local T2 = A.template(node('g', node('f', ys), node('f', node 'c', node 'a', ys)))
        local t0 = os.clock()
        local U, why = A.unify(T1, T2)
        assert.is_nil(U); assert.matches('infinitary', why)
        assert.is_true(os.clock() - t0 < 5)
        -- the same shape with a solution is still solved: (c x a) = (c a y) has x = a·w, y = w·a
        local U2 = A.unify(A.template(node('f', node 'c', xs, node 'a')), A.template(node('f', node 'c', node 'a', ys)))
        assert.is_truthy(U2)
        assert.equals('(f (c) (a) ?w1... (a))', A.show(U2.template.body))
    end)

    local function lcg(seed)
        local s = seed
        return function(n) s = (s * 1103515245 + 12345) % 2147483648; return math.floor(s / 65536) % n + 1 end
    end
    local function rep_hole(h) return A.hole(h, true) end
    local function f(...) return node('f', ...) end
    local function g(...) return node('g', ...) end
    local function h(...) return node('h', ...) end
    local x1, x2, x3, x4 = hole 'x1', hole 'x2', hole 'x3', hole 'x4'

    it('MM82 §2, the worked example: two equations solve to {x1 = g(x3), x2 = x3, x4 = h(g(x3))}', function()
        local S = A.solve({ { g(x2), x1 }, { f(x1, h(x1), x2), f(g(x3), x4, x3) } }, { x1 = {}, x2 = {}, x3 = {}, x4 = {} })
        assert.equals('(g ?x3)', A.show(S.sigma.x1))
        assert.equals('?x3', A.show(S.sigma.x2))
        assert.equals('(h (g ?x3))', A.show(S.sigma.x4))
        assert.same({ 'x3' }, S.free)
        -- the solved form is idempotent: no solved variable occurs in any right-hand side
        for _, t in pairs(S.sigma) do for k in pairs(S.sigma) do assert.is_false(A.show(t):find('?' .. k, 1, true) ~= nil, k .. ' in ' .. A.show(t)) end end
    end)

    it('MM82 §2: the first unifier is the mgu, the second is an instance of it (composition with {x3 = a})', function()
        local r = A.unify(A.template(f(x1, h(x1), x2)), A.template(f(g(x3), x4, x3)))
        assert.equals('(f (g ?x3) (h (g ?x3)) ?x3)', A.show(r.template.body))
        assert.equals('(g ?x3)', A.show(r.left.x1)); assert.equals('?x3', A.show(r.left.x2)); assert.equals('(h (g ?x3))', A.show(r.right.x4))
        local I = A.instantiate(r.template, { x3 = name 'a' }).term
        assert.equals('(f (g a) (h (g a)) a)', A.show(I))
        assert.is_true(A.match(A.template(f(x1, h(x1), x2)), I).ok); assert.is_true(A.match(A.template(f(g(x3), x4, x3)), I).ok)
    end)

    it('the occurs check (Thm 2.2): x = f(x) has no finite instance; symbol clash and arity fail by name', function()
        local S, why = A.solve({ { x1, f(x1) } }, { x1 = {} })
        assert.is_nil(S); assert.matches('occurs', why)
        local _, w2 = A.unify(A.template(f(lit 'a')), A.template(f(lit 'b'))); assert.matches('literal', w2)
        local _, w3 = A.unify(A.template(f(x1)), A.template(g(x1))); assert.matches('kind f vs g', w3)
        local _, w4, at = A.unify(A.template(f(x1, x2)), A.template(f(x1))); assert.matches('arity', w4); assert.equals('root', at)
    end)

    it('non-linear holes and renaming apart: (f ?x ?x) meets (f ?y (g ?z)); shared names are renamed and reported', function()
        local r = A.unify(A.template(f(hole 'x', hole 'x')), A.template(f(hole 'y', g(hole 'z'))))
        assert.equals('(f (g ?z) (g ?z))', A.show(r.template.body))
        assert.equals('(g ?z)', A.show(r.left.x)); assert.equals('(g ?z)', A.show(r.right.y)); assert.equals('?z', A.show(r.right.z))
        local r2 = A.unify(A.template(f(hole 'x', hole 'y')), A.template(f(hole 'y', hole 'x')))
        assert.same({ x = "x'", y = "y'" }, r2.renamed)
        assert.equals(2, #A.hole_names(r2.template)) -- a renaming, not a collapse to one hole
        -- both mappers reproduce the meet's body
        assert.is_true(A.eq(A.apply(A.template(f(hole 'x', hole 'y')), r2.left).body, r2.template.body))
    end)

    it('domains are equations: kinds meet or are disjoint, a pin is an equation, a kind refuses a term by name, supplied travels', function()
        local Tl = A.template(f(hole 'x'), { x = A.kinds { 'lit' } })
        local _, why = A.unify(Tl, A.template(f(hole 'y'), { y = A.kinds { 'name' } })); assert.matches('domains disjoint', why)
        local r = A.unify(Tl, A.template(f(hole 'y')))
        assert.equals('{lit}', A.show_domain(r.template.holes.y.domain)); assert.equals('supplied', r.template.holes.y.origin)
        local _, w2 = A.unify(A.template(f(hole 'x'), { x = A.closed(lit 'a') }), A.template(f(hole 'y'), { y = A.closed(lit 'b') })); assert.matches('literal', w2)
        local r3 = A.unify(A.template(f(hole 'x'), { x = A.closed(lit 'a') }), A.template(f(hole 'y'), { y = A.kinds { 'lit' } }))
        assert.equals('(f "a")', A.show(r3.template.body)); assert.same({}, A.hole_names(r3.template))
        local _, w4 = A.unify(Tl, A.template(f(g(hole 'z')))); assert.matches('kind g not in {lit}', w4)
        -- the meet sits below both and both sit below the join: unify ≤ T1, T2 ≤ join
        local T2 = A.template(f(hole 'y'), { y = A.kinds { 'lit', 'name' } })
        local U = A.unify(Tl, T2).template
        assert.is_true(A.instance_of(U, Tl)); assert.is_true(A.instance_of(U, T2))
        local J = A.join(Tl, T2).template
        assert.is_true(A.instance_of(Tl, J)); assert.is_true(A.instance_of(T2, J))
    end)

    it('a @ref domain unfolds into equations (unification with the grammar), and an alt takes the one alternative that fits', function()
        local defs = {}
        defs.expr = A.template(hole 'e', { e = A.alt(A.kinds { 'lit', 'name' }, A.ref 'bin') })
        defs.bin = A.template(node('bin', hole 'l', hole 'r'), { l = A.ref 'expr', r = A.ref 'expr' })
        local env = { defs = defs }
        local T = A.template(node('ret', hole 'e'), { e = A.ref 'expr' })
        local r = A.unify(T, A.template(node('ret', node('bin', hole 'p', hole 'q'))), { env = env })
        assert.equals('(ret (bin ?p ?q))', A.show(r.template.body))
        assert.equals('@expr', A.show_domain(r.template.holes.p.domain)) -- the grammar's constraint reached the query's holes
        assert.is_true(A.match(r.template, node('ret', node('bin', lit(1), name 'a')), env).ok)
        assert.is_false(A.match(r.template, node('ret', node('bin', lit(1), node('call', name 'f'))), env).ok)
        local _, why = A.unify(T, A.template(node('ret', node('call', hole 'c'))), { env = env })
        assert.matches('no alternative', why)
        -- a structural claim meeting a kinds summary is a conjunction, and the meet still sits below BOTH inputs
        local Tk = A.template(node('ret', hole 'k'), { k = A.kinds { 'lit', 'name' } })
        local rc = A.unify(T, Tk, { env = env })
        assert.equals('@expr & {lit|name}', A.show_domain(rc.template.holes.k.domain))
        assert.is_true(A.instance_of(rc.template, T, env)); assert.is_true(A.instance_of(rc.template, Tk, env))
        assert.is_true(A.match(rc.template, node('ret', lit(1)), env).ok)
        assert.is_false(A.match(rc.template, node('ret', node('bin', lit(1), lit(2))), env).ok) -- the kinds half refuses
        -- several alternatives whose roots both fit a term with holes: refused by name, never accepted silently
        defs.fdef = A.template(node('f', hole 'a'), { a = A.kinds { 'lit' } })
        local Ta = A.template(node('g', hole 'x'), { x = A.alt(A.kinds { 'f' }, A.ref 'fdef') })
        local _, w2 = A.unify(Ta, A.template(node('g', node('f', hole 'p'))), { env = env })
        assert.matches('several alternatives', w2)
        assert.is_truthy(A.unify(Ta, node('g', node('f', lit(1))), { env = env })) -- ground: admits decides
        -- a recursive claim: the query (wrap (wrap ?q)) falls under the family, q inheriting base | self
        local g3 = A.generalize { node('wrap', lit 'x'), node('wrap', node('wrap', lit 'x')), node('wrap', node('wrap', node('wrap', lit 'x'))) }
        local rq = A.unify(g3.template, A.template(node('wrap', node('wrap', hole 'q'))), { env = g3.env })
        assert.equals('(wrap (wrap ?q))', A.show(rq.template.body))
        assert.equals('(@h1.base | @self)', A.show_domain(rq.template.holes.q.domain))
    end)

    it('hedges: one hedge hole binds the forced slice; one on each side leaves a fresh hedge hole between the common ends', function()
        local r = A.unify(A.template(call('f', rep_hole 'X', name 'c')), A.template(call('f', lit(1), lit(2), name 'c')))
        assert.equals('(seq 1 2)', A.show(r.left.X)); assert.equals('(call f 1 2 c)', A.show(r.template.body))
        local T1, T2 = A.template(call('f', rep_hole 'X', name 'c')), A.template(call('f', name 'a', rep_hole 'Y'))
        local r2 = A.unify(T1, T2)
        assert.equals('(call f a ?w1... c)', A.show(r2.template.body))
        assert.equals('(seq a ?w1...)', A.show(r2.left.X)); assert.equals('(seq ?w1... c)', A.show(r2.right.Y))
        -- verified by substitution: both sides become the meet
        assert.is_true(A.eq(A.apply(T1, r2.left).body, r2.template.body)); assert.is_true(A.eq(A.apply(T2, r2.right).body, r2.template.body))
        local w = r2.template.holes.w1; assert.is_true(w.rep)
        -- the same hole on both sides at the same offsets: X = Y, no fresh hole
        local r3 = A.unify(A.template(call('f', rep_hole 'X')), A.template(call('f', rep_hole 'Y')))
        assert.same({}, r3.fresh); assert.equals(1, #A.hole_names(r3.template))
        -- several hedge holes in one list: refused by name
        local _, why = A.unify(A.template(f(rep_hole 'X', name 'a', rep_hole 'Y')), A.template(f(name 'b', name 'a', name 'c')))
        assert.matches('several hedge holes', why)
        -- a hedge hole's element domain constrains the slice
        local _, w2 = A.unify(A.template(call('f', rep_hole 'X'), { X = A.rep(A.kinds { 'lit' }) }), A.template(call('f', lit(1), name 'z')))
        assert.matches('kind name not in {lit}', w2)
    end)

    it('pins inside repetition domains are compared, not conjoined; and merge no longer keeps a pin the other hole refuses', function()
        local T1 = A.template(call('f', rep_hole 'X'), { X = A.rep(A.closed(lit(3))) })
        local T2 = A.template(call('f', rep_hole 'Y'), { Y = A.rep(A.closed(lit(4))) })
        local _, why = A.unify(T1, T2); assert.matches('domains disjoint', why)
        local r = A.unify(T1, A.template(call('f', rep_hole 'Y'), { Y = A.rep(A.kinds { 'lit' }) }))
        assert.equals('=3{0,}', A.show_domain(r.template.holes.Y.domain))
        -- M.meet, merge's only caller: =a ∧ {name} used to return =a and admit what the second hole refused
        assert.is_false(A.admits(A.meet(A.closed(lit 'a'), A.kinds { 'name' }), lit 'a'))
        assert.equals('="a"', A.show_domain(A.meet(A.closed(lit 'a'), A.kinds { 'lit' })))
        local T = A.template(f(hole 'x', hole 'y'), { x = A.closed(lit 'a'), y = A.kinds { 'name' } })
        local Mg = A.merge(T, 'x', 'y')
        assert.is_false(A.match(Mg, f(lit 'a', lit 'a')).ok)
    end)

    it('the ticket\'s query: which stored family does this snippet fall under, through a repetition claim and a boundary', function()
        local counter = 0
        local function list(n) local xs = { name 'f' }; for _ = 1, n do counter = counter + 1; xs[#xs + 1] = lit(counter) end; return node('call', unpack(xs)) end
        local g3 = A.generalize { list(3), list(4), list(5) }
        assert.equals('@h1.elem{0,}', A.show_domain(g3.template.holes.h1.domain))
        local r = A.unify(g3.template, A.template(call('f', lit(1), hole 'q', lit(3))), { env = g3.env })
        assert.equals('(call f 1 ?q 3)', A.show(r.template.body))
        assert.equals('@h1.elem', A.show_domain(r.template.holes.q.domain)) -- the element claim reached the query's hole
        assert.is_true(A.match(r.template, call('f', lit(1), lit(2), lit(3)), g3.env).ok)
        assert.is_false(A.match(r.template, call('f', lit(1), name 'z', lit(3)), g3.env).ok)
        local _, why = A.unify(g3.template, call('f', lit(1), name 'z'), { env = g3.env }); assert.matches('element 2', why)
        -- across a boundary: the family's command is a template inside the string, the query's is another string
        local function doc(img, cmd) return node('doc', node('image', lit(img)), node('command', lit(cmd))) end
        local gd = A.generalize({ doc('x:1', 'run fast'), doc('x:2', 'run slow') }, { need = 100, grammars = { command = 'sh' } })
        local rd = A.unify(gd.template, doc('x:9', 'run fast'))
        -- the inner equation fired (h2.1 = fast); a ground boundary prints back to its text, as apply does
        assert.equals('(doc (image "x:9") (command "run fast"))', A.show(rd.template.body))
        assert.equals('fast', rd.left['h2.1'].v)
        local _, w2 = A.unify(gd.template, doc('x:9', 'ls')); assert.matches('arity: 2 vs 1', w2) -- (cmd run ?h2.1) against (cmd ls): the inner equation clashes
        local _, w3 = A.unify(gd.template, doc('x:9', '')); assert.matches('not a string of that grammar', w3)
    end)

    it('query mode: relax turns derived summaries into their kinds envelope; a supplied pin stays a pin', function()
        local T = A.template(call('f', hole 'x'))
        local j = A.adjoin(T, { { x = lit(1) } }, call('f', lit(1))) -- the column {1} summarises as =1, derived
        assert.equals('=1', A.show_domain(j.template.holes.x.domain)); assert.equals('derived', j.template.holes.x.origin)
        local _, why = A.unify(j.template, call('f', lit(2))); assert.matches('pinned to 1, got 2', why)
        local r = A.unify(j.template, call('f', lit(2)), { relax = 'derived' })
        assert.equals('(call f 2)', A.show(r.template.body))
        local _, w2 = A.unify(j.template, call('f', name 'z'), { relax = 'derived' }); assert.matches('kind name not in {lit}', w2)
        local P = A.pin(j.template, 'x', lit(1)) -- supplied: relax leaves it
        local _, w3 = A.unify(P, call('f', lit(2)), { relax = 'derived' }); assert.matches('pinned to 1, got 2', w3)
    end)

    it('LAW on random typed pairs: instances(meet) = instances(T1) ∩ instances(T2); symmetric up to iso; the meet with yourself is you', function()
        local consts = { lit 'a', lit 'b', name 'x', name 'y' }
        local function ground(rnd, d)
            if d == 0 or rnd(3) == 1 then return consts[rnd(4)] end
            local k = ({ 'f', 'g', 'h' })[rnd(3)]
            local kids = {}
            for i = 1, rnd(3) do kids[i] = ground(rnd, d - 1) end
            return node(k, unpack(kids))
        end
        local function templ(rnd, d)
            if rnd(5) == 1 then return hole(({ 'p', 'q' })[rnd(2)]) end
            if d == 0 or rnd(3) == 1 then return ground(rnd, 0) end
            local k = ({ 'f', 'g', 'h' })[rnd(3)]
            local kids = {}
            for i = 1, rnd(3) do kids[i] = templ(rnd, d - 1) end
            return node(k, unpack(kids))
        end
        local function domain(rnd)
            local r = rnd(5)
            if r == 1 then return A.open() end
            if r == 2 then return A.kinds { 'lit' } end
            if r == 3 then return A.kinds { 'f', 'g' } end
            if r == 4 then return A.kinds { 'name', 'h' } end
            return A.closed(lit 'a')
        end
        local function template(rnd)
            local body = templ(rnd, 2)
            local doms = {}
            for _, hn in ipairs(A.hole_names(A.template(body))) do doms[hn] = domain(rnd) end
            return A.template(body, doms)
        end
        local function instances(rnd, T, n) -- up to n random instances of T
            local out = {}
            for _ = 1, n do
                local V, ok = {}, true
                for _, hn in ipairs(A.hole_names(T)) do
                    local v
                    for _ = 1, 12 do local c = ground(rnd, 1); if A.admits(T.holes[hn].domain, c) then v = c; break end end
                    if not v then ok = false; break end
                    V[hn] = v
                end
                if ok then local I = A.instantiate(T, V); if I.ok then out[#out + 1] = I.term end end
            end
            return out
        end
        local checked, both, met, failed, sym, selfiso = 0, 0, 0, 0, 0, 0
        for seed = 1, 250 do
            local rnd = lcg(seed)
            local T1, T2 = template(rnd), template(rnd)
            local r, why = A.unify(T1, T2)
            if r then met = met + 1 else failed = failed + 1 end
            local pool = instances(rnd, T1, 6)
            for _, I in ipairs(instances(rnd, T2, 6)) do pool[#pool + 1] = I end
            if r then for _, I in ipairs(instances(rnd, r.template, 6)) do pool[#pool + 1] = I end end
            for _, I in ipairs(pool) do
                local inboth = A.match(T1, I).ok and A.match(T2, I).ok
                local inmeet = r ~= nil and A.match(r.template, I).ok
                assert.equals(inboth, inmeet, ('seed %d: %s vs %s on %s (%s)'):format(seed, A.show(T1.body), A.show(T2.body), A.show(I), tostring(why)))
                checked = checked + 1
                if inboth then both = both + 1 end
            end
            if r then
                local r2 = A.unify(T2, T1)
                assert.is_truthy(r2, 'seed ' .. seed .. ' asymmetric')
                if A.iso(r.template, r2.template, { domains = true }) then sym = sym + 1 end
                assert.is_true(A.instance_of(r.template, T1)); assert.is_true(A.instance_of(r.template, T2))
            end
            -- the meet with yourself is you (for templates without pins: a pin instantiates itself)
            local pinned = false
            for _, e in pairs(T1.holes) do if e.domain.kind == 'closed' then pinned = true end end
            if not pinned then
                local rs = A.unify(T1, T1)
                assert.is_true(A.iso(rs.template, T1, { domains = true }), 'seed ' .. seed .. ' self')
                selfiso = selfiso + 1
            end
        end
        assert.is_true(both >= 150, 'vacuity: only ' .. both .. ' instances of both')
        assert.is_true(met >= 40 and failed >= 40, ('met %d failed %d'):format(met, failed))
        assert.equals(met, sym); assert.is_true(selfiso >= 100)
    end)

    it('instance_of is the meet being a renaming: the derived instance_of agrees with the original on random typed pairs', function()
        local function below(T1, T2) -- T1 ≤ T2  iff  meet(T1, T2) ≅ T1: the left map is a renaming, pins allowed to instantiate
            local r = A.unify(T1, T2)
            if not r then return false end
            local seen = {}
            for hn, e in pairs(T1.holes) do
                local t = r.left[hn]
                if is_hole_term(t) then
                    if seen[t.h] then return false end
                    seen[t.h] = true
                    if A.show_domain(r.template.holes[t.h].domain) ~= A.show_domain(e.domain) then return false end
                elseif not (e.domain.kind == 'closed' and A.eq(t, e.domain.value)) then return false end
            end
            return true
        end
        local agree, total, pins = 0, 0, 0
        for seed = 1, 300 do
            local rnd = lcg(seed)
            local function templ(d)
                if rnd(4) == 1 then return hole(({ 'p', 'q', 'r' })[rnd(3)]) end
                if d == 0 or rnd(3) == 1 then return ({ lit 'a', lit 'b', name 'x' })[rnd(3)] end
                local kids = {}
                for i = 1, rnd(3) do kids[i] = templ(d - 1) end
                return node(({ 'f', 'g' })[rnd(2)], unpack(kids))
            end
            local function domain()
                local k = rnd(4)
                if k == 1 then return A.open() elseif k == 2 then return A.kinds { 'lit' } elseif k == 3 then return A.kinds { 'lit', 'name' } end
                return A.closed(lit 'a')
            end
            local function T() local b = templ(2); local d = {}; for _, hn in ipairs(A.hole_names(A.template(b))) do d[hn] = domain() end; return A.template(b, d) end
            local T1, T2 = T(), T()
            total = total + 1
            local o, d = A.instance_of(T1, T2), below(T1, T2)
            if o == d then agree = agree + 1
            else
                -- the one disagreement the meet is RIGHT about: a hole pinned to a value against that value.
                -- The original order is syntactic (a hole never matches a fixed part); by instances ?p=a ≤ a.
                assert.is_false(o); assert.is_true(d)
                local pinned = false
                for _, e in pairs(T1.holes) do if e.domain.kind == 'closed' then pinned = true end end
                assert.is_true(pinned, 'seed ' .. seed .. ': ' .. A.show(T1.body) .. ' vs ' .. A.show(T2.body))
                pins = (pins or 0) + 1
            end
        end
        assert.is_true(agree >= 290 and agree + (pins or 0) == total, ('agree %d of %d'):format(agree, total))
    end)
end)

describe('transplant: apply the edit a → b to c (TRANSPLANT.md; Meng, Kim, McKinley 2011 in the algebra\'s terms)', function()
    local function lcg(seed)
        local s = seed
        return function(n) s = (s * 1103515245 + 12345) % 2147483648; return math.floor(s / 65536) % n + 1 end
    end
    local function f(...) return node('f', ...) end
    local function g(...) return node('g', ...) end

    it('a template edit carries to c through the shared context, with c\'s own identifiers (Sydit\'s concretization)', function()
        local r = A.transplant(call('f', name 'x', lit(1)), call('f', name 'x', lit(2)), call('f', name 'y', lit(1)))
        assert.equals('template', r.kind); assert.equals('(call f y 2)', A.show(r.result))
        assert.equals('(call f ?t1 1)', A.show(r.context.body)) -- the context: the lgg of a and c
        assert.same({}, r.dropped)
        -- an inserted argument: the relocation rule positions c's values around it
        local r2 = A.transplant(call('f', name 'x', lit(1)), call('f', name 'x', lit(1), lit(9)), call('f', name 'y', lit(1)))
        assert.equals('(call f y 1 9)', A.show(r2.result))
    end)

    it('the value part is Sydit\'s concretization: b\'s new value with a\'s old value replaced by c\'s, everywhere', function()
        -- under a supplied context (REFLECT's idiom template) a hole may hold the same value in a and c: it takes b's
        local Tk = A.template(call('f', hole 'k', hole 'n'))
        local eq = A.transplant(call('f', name 'x', lit(1)), call('f', name 'z', lit(1)), call('f', name 'x', lit(5)), { context = Tk })
        assert.equals('(call f z 5)', A.show(eq.result)); assert.equals('value', eq.kind)
        -- a value that differs in c and does not contain a's old value: the replacement applies (z stays z)
        local rp = A.transplant(call('f', name 'x', lit(1)), call('f', name 'z', lit(1)), call('f', name 'y', lit(5)), { context = Tk })
        assert.equals('(call f z 5)', A.show(rp.result)); assert.equals(1, #rp.replaced)
        local w = A.transplant(call('f', name 'x'), call('f', g(name 'x')), call('f', name 'y'))
        assert.equals('(call f (g y))', A.show(w.result)); assert.equals(1, #w.lifted); assert.equals('value', w.kind)
        -- every occurrence is abstracted: (h x x) over y is (h y y)
        local w2 = A.transplant(call('f', name 'x'), call('f', node('h', name 'x', name 'x')), call('f', name 'y'))
        assert.equals('(call f (h y y))', A.show(w2.result)); assert.equals(2, w2.lifted[1].at)
        -- with the lgg context the same replacement is a template edit (x was the shared part's varying position)
        local sk = A.transplant(call('f', name 'x'), call('f', name 'z'), call('f', name 'y'))
        assert.equals('(call f z)', A.show(sk.result))
    end)

    it('identity and triviality: the exemplar transplanted onto itself is b; an empty edit leaves c', function()
        local a, b, c = call('f', name 'x', lit(1)), call('f', g(name 'x'), lit(2)), call('f', name 'y', lit(1))
        assert.is_true(A.eq(A.transplant(a, b, a).result, b))
        local t = A.transplant(a, a, c); assert.equals('none', t.kind); assert.is_true(A.eq(t.result, c))
    end)

    it('when classify straddles, Sydit\'s own route runs: abstract b by a\'s values, every occurrence a site; ambiguity is refused by name', function()
        -- a = (f x x): the shared context with c = (f y y) is (f ?t1 ?t1); b changes one occurrence only (a straddle for classify)
        local r = A.transplant(f(name 'x', name 'x'), f(name 'x', name 'z'), f(name 'y', name 'y'))
        assert.equals('abstracted', r.route); assert.equals('straddle', r.kind); assert.equals('split', r.straddle.proposal.op)
        assert.equals('(f y z)', A.show(r.result)) -- the split, executed
        -- a's varying value also occurs in the shared part: b's mentions of it cannot be attributed
        local _, why = A.transplant(f(name 'x', name 'x', lit(1)), f(name 'x', name 'q', lit(1), name 'x'), f(name 'y', name 'x', lit(1)))
        assert.matches('ambiguous', why)
        -- a hole whose value has no site in b: c's value has nowhere to go, reported dropped
        local r2 = A.transplant(f(name 'x', name 'x'), f(lit(0)), f(name 'y', name 'y'))
        assert.equals('(f 0)', A.show(r2.result)); assert.equals(1, #r2.dropped)
        -- nested values abstract larger first: (g x) is hole t1, the bare x is hole t2
        local r3 = A.transplant(f(g(name 'x'), name 'x', name 'x'), f(g(name 'x'), name 'x', name 'z'), f(node('k', name 'x'), name 'y', name 'y'))
        assert.equals('abstracted', r3.route); assert.equals('(f (k x) y z)', A.show(r3.result))
        -- two holes holding the same value in a cannot be told apart by value (t1: x/y, t2: x/z at two sites; b straddles t2)
        local _, w4 = A.transplant(f(name 'x', name 'x', name 'x'), f(name 'x', name 'x', name 'q'), f(name 'y', name 'z', name 'z'))
        assert.matches('ambiguous: holes', w4)
    end)

    it('Sydit §2 in miniature: the exemplar edit on mA replays on mB with mB\'s names; the signatures differ in arity (a node hole under align none)', function()
        -- mA: getLaunchConfigurations() { iter = all().iterator(); configs = new List; while (iter.hasNext()) { config = (T) iter.next(); configs.add(config) } return configs }
        local function method(params, v_iter, v_list, v_cfg, edited)
            local body = {
                node('decl', name(v_iter), call('iterator', call('all'))),
                node('decl', name(v_list), call('new', name 'List')) }
            if edited then body[#body + 1] = node('decl', name(v_cfg), name 'null') end
            local loop = { }
            if edited then
                loop[#loop + 1] = node('assign', name(v_cfg), node('cast', name 'T', call('next', name(v_iter))))
                loop[#loop + 1] = node('if', node('not', call('inValid', name(v_cfg))), call('reset', name(v_cfg)))
            else
                loop[#loop + 1] = node('decl', name(v_cfg), node('cast', name 'T', call('next', name(v_iter))))
            end
            loop[#loop + 1] = call('add', name(v_list), name(v_cfg))
            body[#body + 1] = node('while', call('hasNext', name(v_iter)), node('block', unpack(loop)))
            body[#body + 1] = node('return', name(v_list))
            return node('method', node('params', unpack(params)), node('block', unpack(body)))
        end
        local mA_old = method({}, 'iter', 'configs', 'config', false)
        local mA_new = method({}, 'iter', 'configs', 'config', true)
        local mB_old = method({ name 'project' }, 'iter', 'cfgs', 'cfg', false)
        local mB_expected = method({ name 'project' }, 'iter', 'cfgs', 'cfg', true)
        local r = A.transplant(mA_old, mA_new, mB_old)
        assert.is_truthy(r)
        -- config occurs at several sites of the rewritten block, so the positional frame straddles and Sydit's route runs
        assert.equals('abstracted', r.route)
        assert.is_true(A.eq(r.result, mB_expected), A.show(r.result))
        assert.same({}, r.dropped)
        -- the params list differs in arity: under the default 'none' rigidity it is one node hole of the context
        local shown = {}
        for h, v in pairs(r.values) do shown[#shown + 1] = A.show(v) end
        table.sort(shown)
        assert.same({ '(params project)', 'cfg', 'cfgs' }, shown)
        -- coverage in Sydit's sense: the context matched (join is total); accuracy: the result equals the oracle
    end)

    it('LAW: transplant agrees with propagate on a family for template edits; central permutation a:b::c:d ⇔ a:c::b:d measured', function()
        local consts = { lit 'a', lit 'b', name 'x', name 'y' }
        local function ground(rnd, d)
            if d == 0 or rnd(3) == 1 then return consts[rnd(4)] end
            local kids = {}
            for i = 1, rnd(3) do kids[i] = ground(rnd, d - 1) end
            return node(({ 'f', 'g' })[rnd(2)], unpack(kids))
        end
        local agree, total, perm_agree, perm_total, refused, perm_replaced, perm_other = 0, 0, 0, 0, 0, 0, 0
        for seed = 1, 300 do
            local rnd = lcg(seed)
            local base = ground(rnd, 3)
            -- a family: the base with two positions varied per member
            local paths = A.positions(base)
            local function vary(t)
                local out = t
                for _ = 1, 2 do
                    local p = paths[rnd(#paths)].path
                    if #p > 0 then out = A.put(out, p, ground(rnd, 1)) end
                end
                return out
            end
            local a, c = vary(base), vary(base)
            -- the family under the same rigidity transplant uses for its context (a hedge family would
            -- migrate an arity divergence positionally where transplant concretizes a node hole)
            local jf = A.join(A.template(a), c, { align = 'none', prefix = 't' })
            local T, Va, Vc = jf.template, jf.left({}), jf.right({})
            T.edits = {}
            -- a template edit: rewrite one fixed position with a random ground term (a dig would leave the
            -- instances where they are: an exemplar edit is a pair of instances, so a dig is the null case)
            local fixed = {}
            for _, q in ipairs(A.positions(T.body)) do if q.node.k ~= 'hole' and #q.path > 0 then fixed[#fixed + 1] = q.path end end
            if #fixed > 0 and next(T.holes) then
                local path = fixed[rnd(#fixed)]
                local T2 = A.rewrite(T, path, ground(rnd, 1))
                if T2 then
                    local mig = A.migrate(T, T2, { Va, Vc })
                    if mig.values[1] and mig.values[2] then
                        local b = A.instantiate(T2, mig.values[1]).term
                        local expected = A.instantiate(T2, mig.values[2]).term
                        local r = A.transplant(a, b, c)
                        total = total + 1
                        if r and A.eq(r.result, expected) then agree = agree + 1 elseif not r then refused = refused + 1 end
                    end
                end
            end
            -- central permutation on a value edit: a→b onto c against a→c onto b
            local b2 = vary(a)
            local r1, r2 = A.transplant(a, b2, c), A.transplant(a, c, b2)
            if r1 and r2 then
                perm_total = perm_total + 1
                if A.eq(r1.result, r2.result) then perm_agree = perm_agree + 1
                elseif #r1.replaced + #r2.replaced + #r1.lifted + #r2.lifted > 0 or r1.route == 'abstracted' or r2.route == 'abstracted' then perm_replaced = (perm_replaced or 0) + 1
                else perm_other = perm_other + 1 end
            end
        end
        assert.is_true(total >= 60, 'vacuity: ' .. total)
        assert.equals(total, agree + refused, ('agree %d refused %d of %d'):format(agree, refused, total)) -- never a different answer
        assert.is_true(agree >= total * 0.8, ('agree %d of %d'):format(agree, total))
        assert.is_true(perm_total >= 60)
        -- measured, not asserted as a law: the residue is reported in TRANSPLANT.md
        -- the LAW: central permutation holds whenever neither direction concretizes a value (a replacement or a
        -- wrap) or takes the abstracted route; there the proportion a:b::c:d has no unique fourth term
        assert.equals(0, perm_other)
        if os.getenv('TRANSPLANT_LAW') then print(('TRANSPLANT LAW: propagate agreement %d of %d (refused %d); central permutation %d of %d, the rest (%d) concretize a value or take the abstracted route'):format(agree, total, refused, perm_agree, perm_total, perm_replaced)) end
    end)
end)


describe('link by value: a family is a relation (LINK.md; Codd 1970 §1.3, §1.4, §2.1.3)', function()
    local function emb(g, inner) return { k = 'embed', g = g, kids = { inner } } end
    local function fam(T, rows) return { template = T, values = rows } end
    -- grammars for the storage fixtures: a slash path (trailing slash dropped) and an NFS source host:path.
    -- Both PARSE ONLY (print returns nil): they serve readers, and nothing instantiates through them
    A.grammar('path', {
        parse = function(s)
            if type(s) ~= 'string' or s == '' then return nil end
            local segs = {}
            for seg in s:gmatch('[^/]+') do segs[#segs + 1] = lit(seg) end
            return node('path', unpack(segs))
        end,
        print = function() return nil end,
    })
    A.grammar('nfs_source', {
        parse = function(s)
            if type(s) ~= 'string' then return nil end
            local host, path = s:match('^([^:]+):(.+)$')
            if not host then return nil end
            return node('src', lit(host), lit(path))
        end,
        print = function() return nil end,
    })
    local segs = A.hole('segs', true)
    local path_reader = { template = A.template(emb('path', node('path', segs))), hole = 'segs' }

    it("Codd Figure 5 and 6: R(supplier, part) * S(part, project) is his five tuples; the projections give R and S back; part 1 is the point of ambiguity", function()
        local R = fam(A.template(node('R', hole 'supplier', hole 'part')), { { supplier = lit(1), part = lit(1) }, { supplier = lit(2), part = lit(1) }, { supplier = lit(2), part = lit(2) } })
        local S = fam(A.template(node('S', hole 'part', hole 'project')), { { part = lit(1), project = lit(1) }, { part = lit(1), project = lit(2) }, { part = lit(2), project = lit(1) } })
        local L = A.link(R, S, { from = 'part', to = 'part' })
        assert.equals(5, #L.tuples)
        local rows = {}
        for _, t in ipairs(L.tuples) do rows[#rows + 1] = ('%d %d %d'):format(R.values[t.a].supplier.v, t.key.v, S.values[t.b].project.v) end
        table.sort(rows)
        assert.same({ '1 1 1', '1 1 2', '2 1 1', '2 1 2', '2 2 1' }, rows) -- Figure 6, not Figure 7's three
        -- π12(R*S) = R and π23(R*S) = S (his lossless property of the natural join)
        local p12, p23 = {}, {}
        for _, t in ipairs(L.tuples) do p12[t.a] = true; p23[t.b] = true end
        assert.same({ true, true, true }, p12); assert.same({ true, true, true }, p23)
        -- the point of ambiguity: part 1 has several relatives under R and under S
        assert.equals(1, #L.ambiguity); assert.equals(1, L.ambiguity[1].key.v)
        assert.same({ 1, 2 }, L.ambiguity[1].a); assert.same({ 1, 2 }, L.ambiguity[1].b)
        assert.is_false(L.is_function); assert.equals(2, L.fan); assert.equals(0, #L.dangling)
        -- part is a primary key of neither; supplier+part would be, but composite keys are out of scope for primary_key
        assert.is_false(A.primary_key(R, 'part')); assert.is_false(A.primary_key(S, 'project'))
        -- swap: link(S, R) has the same tuples with a and b exchanged
        local L2 = A.link(S, R, { from = 'part', to = 'part' })
        local sw, fw = {}, {}
        for _, t in ipairs(L2.tuples) do sw[#sw + 1] = t.b .. '-' .. t.a end
        for _, t in ipairs(L.tuples) do fw[#fw + 1] = t.a .. '-' .. t.b end
        table.sort(sw); table.sort(fw); assert.same(fw, sw)
    end)

    it('Codd Figure 3: employee with nonsimple jobhistory and children normalizes to his 3(b) set, keys copied down', function()
        local T_emp = A.template(node('employee', hole 'man', hole 'name', hole 'birthdate', node('jobhistory', A.hole('jobs', true)), node('children', A.hole('kids', true))))
        local function job(d, t, ...) return node('job', lit(d), lit(t), node('salaryhistory', ...)) end
        local function sal(d, s) return node('sal', lit(d), lit(s)) end
        local emp = fam(T_emp, {
            { man = lit(7), name = lit 'ada', birthdate = lit(1960), jobs = seq { job(1990, 'eng', sal(1990, 100), sal(1991, 110)), job(1995, 'lead', sal(1995, 150)) }, kids = seq { node('child', lit 'bo', lit(1988)) } },
            { man = lit(8), name = lit 'cy', birthdate = lit(1970), jobs = seq { job(2000, 'eng', sal(2000, 120)) }, kids = seq {} },
        })
        local T_job = A.template(node('job', hole 'jobdate', hole 'title', node('salaryhistory', A.hole('sals', true))))
        local jobs = assert(A.normalize(emp, 'jobs', T_job, { key = 'man' }))
        assert.equals(3, #jobs.values)
        assert.equals(7, jobs.values[1].man.v); assert.equals(1990, jobs.values[1].jobdate.v); assert.equals(1, jobs.rows[1].parent)
        assert.equals(8, jobs.values[3].man.v); assert.equals(2, jobs.rows[3].parent); assert.equals(1, jobs.rows[3].index)
        assert.is_true(A.primary_key(emp, 'man')); assert.is_false(A.primary_key(jobs, 'man')) -- jobhistory' is keyed by (man#, jobdate)
        -- salaryhistory' (man#, jobdate, salarydate, salary): the composite key copied down
        local sals = assert(A.normalize(jobs, 'sals', A.template(node('sal', hole 'salarydate', hole 'salary')), { key = { 'man', 'jobdate' } }))
        assert.equals(4, #sals.values)
        assert.equals(7, sals.values[2].man.v); assert.equals(1990, sals.values[2].jobdate.v); assert.equals(1991, sals.values[2].salarydate.v); assert.equals(110, sals.values[2].salary.v)
        local kids = assert(A.normalize(emp, 'kids', A.template(node('child', hole 'childname', hole 'birthyear')), { key = 'man' }))
        assert.equals(1, #kids.values); assert.equals('bo', kids.values[1].childname.v); assert.equals(7, kids.values[1].man.v)
        -- his condition 2: a nonsimple key is refused by name; a simple domain needs no normalization
        local _, why = A.normalize(emp, 'jobs', T_job, { key = 'kids' })
        assert.matches('nonsimple', why)
        local _, why2 = A.normalize(emp, 'name', T_job, { key = 'man' })
        assert.matches('not a sequence', why2)
        -- the copied key links the child back to its parent as a function: Codd's foreign key
        local back = A.link(jobs, emp, { from = 'man', to = 'man' })
        assert.is_true(back.is_function); assert.equals(0, #back.dangling); assert.equals(1, back.fan)
    end)

    it('the storage stack: from a pod volume to the disks of the pool, links through readers, one Pending PVC as a typed absence', function()
        local T_pod = A.template(node('pod', hole 'name', hole 'ns', node('volumes', A.hole('vols', true))))
        local function vol(n, claim) return node('vol', lit(n), node('pvc', lit(claim))) end
        local pods = fam(T_pod, {
            { name = lit 'web', ns = lit 'default', vols = seq { vol('data', 'web-data') } },
            { name = lit 'api', ns = lit 'default', vols = seq { vol('cache', 'api-cache') } },
            { name = lit 'batch', ns = lit 'jobs', vols = seq { vol('scratch', 'batch-scratch') } },
        })
        local pvcs = fam(A.template(node('pvc', hole 'name', hole 'ns', hole 'phase', hole 'volume')), {
            { name = lit 'web-data', ns = lit 'default', phase = lit 'Bound', volume = lit 'pvc-1' },
            { name = lit 'api-cache', ns = lit 'default', phase = lit 'Bound', volume = lit 'pvc-2' },
            { name = lit 'batch-scratch', ns = lit 'jobs', phase = lit 'Pending', volume = lit '' },
        })
        local pvs = fam(A.template(node('pv', hole 'name', node('nfs', hole 'server', hole 'path'))), {
            { name = lit 'pvc-1', server = lit '10.0.0.5', path = lit '/tank/k8s/default/web-data' },
            { name = lit 'pvc-2', server = lit '10.0.0.5', path = lit '/tank/k8s/default/api-cache' },
        })
        local mounts = fam(A.template(node('mount', hole 'src', hole 'target')), {
            { src = lit '10.0.0.5:/tank/k8s/default/web-data', target = lit '/var/lib/kubelet/pods/u1/volumes/kubernetes.io~nfs/pvc-1' },
            { src = lit '10.0.0.5:/tank/k8s/default/api-cache', target = lit '/var/lib/kubelet/pods/u2/volumes/kubernetes.io~nfs/pvc-2' },
        })
        local exports = fam(A.template(node('export', hole 'path', hole 'clients')), {
            { path = lit '/tank/k8s/default/web-data/', clients = lit '10.0.1.0/24' }, -- the trailing slash the reader normalizes
            { path = lit '/tank/k8s/default/api-cache', clients = lit '10.0.1.0/24' },
        })
        local datasets = fam(A.template(node('ds', hole 'name', hole 'mountpoint')), {
            { name = lit 'tank/k8s/default/web-data', mountpoint = lit '/tank/k8s/default/web-data' },
            { name = lit 'tank/k8s/default/api-cache', mountpoint = lit '/tank/k8s/default/api-cache' },
            { name = lit 'tank/k8s/default/old', mountpoint = lit '/tank/k8s/default/old' },
        })
        local function disk(d, st) return node('disk', lit(d), lit(st)) end
        local pools = fam(A.template(node('pool', hole 'name', hole 'health', node('vdevs', A.hole('vdevs', true)))), {
            { name = lit 'tank', health = lit 'ONLINE', vdevs = seq { node('mirror', lit 'mirror-0', node('disks', disk('sda', 'ONLINE'), disk('sdb', 'ONLINE'))), node('mirror', lit 'mirror-1', node('disks', disk('sdc', 'ONLINE'), disk('sdd', 'DEGRADED'))) } },
            { name = lit 'backup', health = lit 'ONLINE', vdevs = seq { node('mirror', lit 'mirror-0b', node('disks', disk('sde', 'ONLINE'))) } },
        })
        -- Codd §1.4: the pod's volumes are a nonsimple domain; so are the pool's vdevs and each vdev's disks
        local vols = assert(A.normalize(pods, 'vols', A.template(node('vol', hole 'vname', node('pvc', hole 'claim'))), { key = 'name' }))
        local vdevs = assert(A.normalize(pools, 'vdevs', A.template(node('mirror', hole 'vname', node('disks', A.hole('disks', true)))), { key = 'name' }))
        local disks = assert(A.normalize(vdevs, 'disks', A.template(node('disk', hole 'dev', hole 'state')), { key = 'vname' }))
        assert.equals(3, #vols.values); assert.equals(3, #vdevs.values); assert.equals(5, #disks.values)
        -- the links; a reader with an embed turns a string of one domain into the key of another
        local L1 = A.link(vols, pvcs, { from = 'claim', to = 'name', complete = true })
        local L2 = A.link(pvcs, pvs, { from = 'volume', to = 'name', complete = true })
        local L3 = A.link(pvs, exports, { from = 'path', to = 'path', read_from = path_reader, read_to = path_reader, complete = true })
        local L4 = A.link(exports, datasets, { from = 'path', to = 'mountpoint', read_from = path_reader, read_to = path_reader, complete = true })
        local pool_of = { template = A.template(emb('path', node('path', hole 'pool', segs))), hole = 'pool' }
        local L5 = A.link(datasets, pools, { from = 'name', to = 'name', read_from = pool_of, complete = true })
        local L6 = A.link(pools, vdevs, { from = 'name', to = 'name', complete = true })
        local L7 = A.link(vdevs, disks, { from = 'vname', to = 'vname', complete = true })
        assert.is_true(L1.is_function and L2.is_function and L3.is_function and L4.is_function)
        assert.is_false(L6.is_function); assert.equals(2, L6.fan); assert.equals(2, L7.fan) -- the fan-out: a dataset spans the pool's vdevs
        assert.equals(2, #L3.tuples) -- the trailing slash on the export is the reader's business, not the link's
        assert.is_true(A.eq(L3.tuples[1].key, seq { lit 'tank', lit 'k8s', lit 'default', lit 'web-data' }))
        -- the node's mount table agrees with the PVs through a two-level boundary: host:path, then the path
        local src_reader = { template = A.template(emb('nfs_source', node('src', hole 'host', emb('path', node('path', segs))))), hole = 'segs' }
        local Lm = A.link(pvs, mounts, { from = 'path', to = 'src', read_from = path_reader, read_to = src_reader })
        assert.equals(2, #Lm.tuples); assert.equals(0, #Lm.dangling); assert.is_true(Lm.is_function)
        -- the chain from web's volume down to the disks: a set of four
        local web_vol
        for i, r in ipairs(vols.rows) do if r.parent == 1 then web_vol = i end end
        local ch = A.chain(web_vol, { L1, L2, L3, L4, L5, L6, L7 })
        assert.is_true(ch.ok); assert.equals(0, #ch.absences)
        local devs = {}
        for _, i in ipairs(ch.members) do devs[#devs + 1] = disks.values[i].dev.v end
        table.sort(devs); assert.same({ 'sda', 'sdb', 'sdc', 'sdd' }, devs)
        assert.equals(1, #ch.steps[2].members); assert.equals(1, #ch.steps[6].members); assert.equals(2, #ch.steps[7].members); assert.equals(4, #ch.steps[8].members)
        -- the Pending PVC: its volume is empty, so the PV step has no relative; the PV family was declared
        -- complete, so the absence is `absent` (licenses act); without the claim it is `frontier`
        local batch_vol
        for i, r in ipairs(vols.rows) do if r.parent == 3 then batch_vol = i end end
        local chb = A.chain(batch_vol, { L1, L2, L3, L4, L5, L6, L7 })
        assert.is_false(chb.ok); assert.equals(1, #chb.absences)
        assert.equals('absent', chb.absences[1].absence); assert.equals(2, chb.absences[1].at); assert.equals('act', chb.absences[1].licenses)
        local L2f = A.link(pvcs, pvs, { from = 'volume', to = 'name' })
        local chf = A.chain(batch_vol, { L1, L2f })
        assert.equals('frontier', chf.absences[1].absence); assert.equals('nothing', chf.absences[1].licenses)
        -- the provisioner's naming is a template: the dataset name reads back the namespace and the claim,
        -- and they agree with the PVC the chain passed through
        local naming = A.template(emb('path', node('path', lit 'tank', lit 'k8s', hole 'ns', hole 'pvc')))
        local m = A.match(naming, datasets.values[ch.steps[5].members[1]].name)
        assert.is_true(m.ok); assert.equals('default', m.values.ns.v); assert.equals('web-data', m.values.pvc.v)
        local pvc_i = ch.steps[2].members[1]
        assert.is_true(A.eq(m.values.pvc, pvcs.values[pvc_i].name) and A.eq(m.values.ns, pvcs.values[pvc_i].ns))
        -- an unreferenced dataset is not an error of the link; it is simply not a relative of any export
        local back = A.link(datasets, exports, { from = 'mountpoint', to = 'path', read_from = path_reader, read_to = path_reader })
        assert.same({ 3 }, back.dangling)
        -- provenance: every tuple names the two holes; sites(T) turns (member, hole) into paths in the text
        assert.equals('claim', L1.tuples[1].from); assert.equals('name', L1.tuples[1].to)
        assert.is_truthy(A.sites(pvcs.template).name.sites[1].path)
    end)

    it('LAW: link equals the brute-force natural join; swap; a primary key links a family to itself as the identity; chain composes the join', function()
        local function lcg(seed)
            local s = seed
            return function(n) s = (s * 1103515245 + 12345) % 2147483648; return math.floor(s / 65536) % n + 1 end
        end
        local T = A.template(node('r', hole 'k', hole 'f'))
        local function rfam(rnd, n) -- n rows, keys and foreign keys from a small alphabet so relatives repeat
            local rows = {}
            for i = 1, n do rows[i] = { k = lit(rnd(5)), f = lit(rnd(5)) } end
            return fam(T, rows)
        end
        local checked, ambiguous, dangling, fanout = 0, 0, 0, 0
        for seed = 1, 150 do
            local rnd = lcg(seed)
            local X, Y, Z = rfam(rnd, rnd(5)), rfam(rnd, rnd(5)), rfam(rnd, rnd(5))
            local L = A.link(X, Y, { from = 'f', to = 'k' })
            -- brute force: R*S = {(a, b) : X.f(a) = Y.k(b)}
            local brute, got = {}, {}
            for i, x in ipairs(X.values) do for j, y in ipairs(Y.values) do if A.eq(x.f, y.k) then brute[#brute + 1] = i .. '-' .. j end end end
            for _, t in ipairs(L.tuples) do got[#got + 1] = t.a .. '-' .. t.b end
            table.sort(brute); table.sort(got); assert.same(brute, got, 'seed ' .. seed)
            -- dangling and fan agree with the brute force
            local dang, fan = {}, 0
            for i, x in ipairs(X.values) do
                local c = 0
                for _, y in ipairs(Y.values) do if A.eq(x.f, y.k) then c = c + 1 end end
                if c == 0 then dang[#dang + 1] = i end
                if c > fan then fan = c end
            end
            assert.same(dang, L.dangling); assert.equals(fan, L.fan)
            -- is_function iff k is unique in Y; a point of ambiguity has two relatives on both sides
            assert.equals(A.primary_key(Y, 'k'), L.is_function)
            local amb = false
            for _, r in ipairs(L.ambiguity) do assert.is_true(#r.a > 1 and #r.b > 1); amb = true end
            -- swap
            local Ls = A.link(Y, X, { from = 'k', to = 'f' })
            local sw = {}
            for _, t in ipairs(Ls.tuples) do sw[#sw + 1] = t.b .. '-' .. t.a end
            table.sort(sw); assert.same(got, sw)
            -- identity: a family with unique keys linked to itself on the key
            if A.primary_key(X, 'k') then
                local Li = A.link(X, X, { from = 'k', to = 'k' })
                assert.is_true(Li.is_function); assert.equals(0, #Li.dangling)
                for _, pr in ipairs(Li.pairs) do assert.same({ pr.a }, pr.b) end
            end
            -- chain composes: X → Y → Z from member 1 equals the nested brute force
            local L2 = A.link(Y, Z, { from = 'f', to = 'k' })
            if #X.values > 0 then
                local ch = A.chain(1, { L, L2 })
                local comp = {}
                for _, y in ipairs(Y.values) do
                    if A.eq(X.values[1].f, y.k) then
                        for l, z in ipairs(Z.values) do if A.eq(y.f, z.k) then comp[l] = true end end
                    end
                end
                local want = {}
                for l in pairs(comp) do want[#want + 1] = l end
                table.sort(want); assert.same(want, ch.members, 'seed ' .. seed .. ' chain')
                assert.equals(#want > 0, ch.ok)
            end
            checked = checked + 1
            if amb then ambiguous = ambiguous + 1 end
            if #L.dangling > 0 then dangling = dangling + 1 end
            if L.fan > 1 then fanout = fanout + 1 end
        end
        assert.equals(150, checked); assert.is_true(ambiguous > 5 and dangling > 30 and fanout > 25, ('%d %d %d'):format(ambiguous, dangling, fanout)) -- 7, 120, 34 when written
    end)
end)

describe('vertical minimization across alignments (VMIN.md; BK 2014 §1 and §2, RISC library paper §4)', function()
    local function f(...) return node('f', ...) end
    local function g(...) return node('g', ...) end
    local a, b, c = node 'a', node 'b', node 'c'
    local X = function(...) return A.ctx('X', { ... }) end
    local Y = function(...) return A.ctx('Y', { ... }) end
    local Z = function(...) return A.ctx('Z', { ... }) end
    local function T1(t) return A.template(seq { t }) end
    local function lcg(seed)
        local s = seed
        return function(n) s = (s * 1103515245 + 12345) % 2147483648; return math.floor(s / 65536) % n + 1 end
    end
    local function rebuilds(T, s, q)
        return A.eq(A.instantiate(T, T.values[1]).term, s) and A.eq(A.instantiate(T, T.values[2]).term, q)
    end
    -- rename every hole of a template apart (prefix r), keeping rep/ctx; the domains are the defaults, as vertical's are
    local function renamed(U)
        local function go(t)
            if t.k == 'hole' then
                local kids = {}
                for i, k in ipairs(t.kids or {}) do kids[i] = go(k) end
                if t.ctx then return A.ctx('r' .. t.h, kids) end
                return A.hole('r' .. t.h, t.rep or nil)
            end
            if not t.kids then return t end
            local kids = {}
            for i, k in ipairs(t.kids) do kids[i] = go(k) end
            return A.rebuild(t, kids)
        end
        return A.template(go(U.body))
    end

    it('two longest admissible alignments, one rigid lgg strictly more general than the other: it is dropped and named', function()
        local s, q = seq { g(g(a, c, c), f(a), c) }, seq { g(b) }
        local every = A.vertical(s, q, { minimize = false })
        assert.equals(2, #every.templates)
        local shown = { A.show(every.templates[1].body), A.show(every.templates[2].body) }
        table.sort(shown)
        assert.same({ '(seq (g ?x1...))', '(seq ?X1((g ?x1...)))' }, shown)
        local r = A.vertical(s, q)
        assert.equals(2, r.candidates); assert.equals(1, #r.templates); assert.equals(1, #r.dropped)
        assert.equals('(seq (g ?x1...))', A.show(r.templates[1].body))
        assert.equals('(seq ?X1((g ?x1...)))', A.show(r.dropped[1].template.body))
        assert.equals(A.show(r.templates[1].body), A.show(every.templates[r.dropped[1].by].body))
        assert.is_true(rebuilds(r.templates[1], s, q)) -- Theorem 3 survives the minimization
        -- the drop is a real substitution: X1 ↦ ◦ takes the dropped (more general) template to the kept one
        local m = A.match(r.dropped[1].template, r.templates[1].body, { hole_domains = r.templates[1].holes })
        assert.is_true(m.ok); assert.equals('(seq ◦)', A.show(m.values.X1))
        assert.is_true(A.eq(A.instantiate(r.dropped[1].template, m.values).term, r.templates[1].body))
        assert.is_false(A.match(r.templates[1], r.dropped[1].template.body, { hole_domains = r.dropped[1].template.holes }).ok)
        assert.equals(0, r.budget_refusals)
        -- the matching budget of the comparisons is match_cap, not cap (cap bounds the alignment enumeration):
        -- starved, the comparison refuses, counts it, and keeps the dominated candidate (sound, not complete)
        local starved = A.vertical(s, q, { match_cap = 3 })
        assert.is_true(starved.budget_refusals > 0); assert.equals(2, #starved.templates)
        assert.equals(2, A.vertical(s, q, { cap = 3 }).candidates); assert.equals(1, #A.vertical(s, q, { cap = 3 }).templates)
    end)

    it('two incomparable rigid lggs both survive: X1(c) and X1(a) for (f c (f b a)) against (g (g a c))', function()
        local s, q = seq { f(c, f(b, a)) }, seq { g(g(a, c)) }
        local r = A.vertical(s, q)
        assert.equals(2, r.candidates); assert.equals(2, #r.templates); assert.equals(0, #r.dropped)
        local shown = { A.show(r.templates[1].body), A.show(r.templates[2].body) }
        table.sort(shown)
        assert.same({ '(seq ?X1((a)))', '(seq ?X1((c)))' }, shown)
        assert.is_false(A.instance_of(r.templates[1], r.templates[2]))
        assert.is_false(A.instance_of(r.templates[2], r.templates[1]))
        for _, T in ipairs(r.templates) do assert.is_true(rebuilds(T, s, q)) end
    end)

    it('the order composes contexts: X(a) ≃ Y(a) by X ↦ Y(◦), X(f a) < X(a), and a vertical chain X(Y(a)) ≃ Z(a)', function()
        assert.is_true(A.instance_of(T1(X(a)), T1(Y(a)))); assert.is_true(A.instance_of(T1(Y(a)), T1(X(a))))
        assert.equals('(seq ?Y(◦))', A.show(A.match(T1(X(a)), seq { Y(a) }).values.X))
        assert.is_true(A.instance_of(T1(X(f(a))), T1(X(a)))); assert.is_false(A.instance_of(T1(X(a)), T1(X(f(a)))))
        -- BK's RC condition 4 forbids vertical chains of variables in a rigid generalization: the
        -- chain is equivalent to one context variable, which the order sees
        assert.is_true(A.instance_of(T1(Z(a)), T1(X(Y(a))))); assert.is_true(A.instance_of(T1(X(Y(a))), T1(Z(a))))
        -- without the descent into an instance-side context node X(a) and Y(a) were incomparable: the
        -- placement that makes them equal has the cursor inside Y's applied hedge
        local m = A.match(T1(X(a)), seq { Y(a) })
        assert.same({ 1 }, m.sites.X.sites[1].cursor.path)
    end)

    it('the comparison is under the hedge-context order: (x... c) is below (X1(c) x...) only because X1 may own top-level siblings', function()
        local s = seq { c }
        local q = seq { g(f(a, b, a), f(b, b), g(c, a)), f(f(a, c, b)), c }
        local every = A.vertical(s, q, { minimize = false })
        local lo, hi
        for _, T in ipairs(every.templates) do
            local sh = A.show(T.body)
            if sh == '(seq ?x1... (c))' then lo = T elseif sh == '(seq ?X1((c)) ?x1...)' then hi = T end
        end
        assert.is_truthy(lo); assert.is_truthy(hi)
        assert.is_true(A.instance_of(lo, hi)); assert.is_false(A.instance_of(hi, lo))
        local m = A.match(hi, lo.body, { hole_domains = lo.holes })
        assert.equals('(seq ?x1... ◦)', A.show(m.values.X1)) -- a top-level sibling beside the cursor: not a singleton context
        assert.same({}, m.sites.X1.sites[1].cursor.path)
        local r = A.vertical(s, q)
        for _, T in ipairs(r.templates) do assert.are_not.equal('(seq ?X1((c)) ?x1...)', A.show(T.body)) end
    end)

    it('LAW: on random pairs the kept set is pairwise incomparable and complete, every kept lgg still rebuilds both inputs, minimize is idempotent, and clashing names do not matter', function()
        local leaves = { a, b, c }
        local function rand(rnd, dpt)
            if dpt == 0 or rnd(3) == 1 then return leaves[rnd(3)] end
            local kids = {}
            for i = 1, rnd(3) do kids[i] = rand(rnd, dpt - 1) end
            return node(({ 'f', 'g' })[rnd(2)], unpack(kids))
        end
        local multi, drops, kept_multi, refusals, compared = 0, 0, 0, 0, 0
        for seed = 1, 400 do
            local rnd = lcg(seed)
            local sk, qk = {}, {}
            for i = 1, rnd(3) do sk[i] = rand(rnd, 2) end
            for i = 1, rnd(3) do qk[i] = rand(rnd, 2) end
            local s, q = seq(sk), seq(qk)
            local r = A.vertical(s, q)
            refusals = refusals + r.budget_refusals
            if r.candidates > 0 then assert.is_true(#r.templates > 0, 'seed ' .. seed .. ': nothing kept') end
            if r.candidates > 1 then multi = multi + 1 end
            if #r.dropped > 0 then drops = drops + 1 end
            if #r.templates > 1 then kept_multi = kept_multi + 1 end
            for i, T in ipairs(r.templates) do
                assert.is_true(rebuilds(T, s, q), 'seed ' .. seed .. ' Theorem 3')
                for j, U in ipairs(r.templates) do
                    if i ~= j then
                        assert.is_false(A.instance_of(U, T), ('seed %d: kept %s below kept %s'):format(seed, A.show(U.body), A.show(T.body)))
                        compared = compared + 1
                    end
                end
            end
            for _, d in ipairs(r.dropped) do
                -- complete: some kept template is at or below the dropped one, and the substitution rebuilds it
                local found = false
                for _, K in ipairs(r.templates) do
                    local m = A.match(d.template, K.body, { hole_domains = K.holes })
                    if m.ok then
                        found = true
                        assert.is_true(A.eq(A.instantiate(d.template, m.values).term, K.body), 'seed ' .. seed .. ' PutGet on templates')
                        break
                    end
                end
                assert.is_true(found, ('seed %d: dropped %s has no kept dominator'):format(seed, A.show(d.template.body)))
            end
            -- idempotent
            local again = A.minimize(r.templates)
            assert.equals(#r.templates, #again)
            -- names clash across the two templates of one call (both use x1, X1, ..): renaming the instance side apart changes nothing
            if r.candidates > 1 and seed % 4 == 0 then
                local every = A.vertical(s, q, { minimize = false })
                for i, T in ipairs(every.templates) do
                    for j, U in ipairs(every.templates) do
                        if i ~= j then
                            assert.equals(A.instance_of(U, T), A.instance_of(renamed(U), T), ('seed %d: renaming changed the order'):format(seed))
                        end
                    end
                end
            end
        end
        assert.equals(0, refusals)
        assert.is_true(multi > 100 and drops > 80 and kept_multi > 50, ('%d multi, %d with drops, %d kept several'):format(multi, drops, kept_multi))
        assert.is_true(compared > 100)
    end)
end)

describe('cutting a context out of an instance (CTXCUT.md; Huet, The Zipper, 1997)', function()
    local function f(...) return node('f', ...) end
    local function g(...) return node('g', ...) end
    local function h(...) return node('h', ...) end
    local a, b, c, d = node 'a', node 'b', node 'c', node 'd'
    local X = function(...) return A.ctx('X', { ... }) end
    local Y = function(...) return A.ctx('Y', { ... }) end
    local xs = A.hole('x', true)
    local function lcg(seed)
        local s = seed
        return function(n) s = (s * 1103515245 + 12345) % 2147483648; return math.floor(s / 65536) % n + 1 end
    end
    -- a hand-built context site: the slice starts at `path`, is `n` wide; the cursor list is reached
    -- inside the slice by cursor.path and the focus is cursor.from .. cursor.from + cursor.n - 1
    local function site(path, n, cpath, from, cn)
        return { X = { sites = { { path = path, n = n, cursor = { path = cpath, from = from, n = cn } } }, domain = A.context(), ctx = true } }
    end
    local function roundtrip(I, H) -- GetPut: cut, then plug the focus back; and instantiate(abstract, values_at) = I
        local V, conflicts = A.values_at(I, H)
        assert.equals(0, #conflicts)
        local T = A.abstract(I, H)
        local r = A.instantiate(T, V)
        assert.is_true(r.ok, r.ok or (table.concat(r.unfilled or {}, ',') .. table.concat(r.rejected or {}, ',')))
        assert.is_true(A.eq(r.term, I))
        return V, T
    end

    it("Huet's example: the location of the second * in a×b+c×d is its context, and go_up (plug) rebuilds the tree", function()
        local star, plus = lit '*', lit '+'
        local I = seq { seq { lit 'a', star, lit 'b' }, plus, seq { lit 'c', star, lit 'd' } }
        -- Loc(Item "*", Node([Item "c"], Node([Item "+"; Section[a;*;b]], Top, []), [Item "d"])): the whole
        -- tree is the slice (path {1}, three wide), the cursor list is the third element, focus its second
        local H = site({ 1 }, 3, { 3 }, 2, 1)
        local V, T = roundtrip(I, H)
        assert.equals('(seq (seq "a" "*" "b") "+" (seq "c" ◦ "d"))', A.show(V.X))
        assert.is_true(A.eq(A.plug(V.X, { star }), I)) -- go_up three times, closing the zipper
        assert.is_true(A.eq(T.body, seq { X(star) }))
        -- the derived third leg (locate_at, put, seq, cursor, rebuild) runs this test under DERIVE=values_at,abstract
    end)

    it('the focus may be a hedge, empty, or the whole slice; Top may own siblings (BK contexts are wider than Huet\'s)', function()
        local I = seq { a, f(b, c, d), b }
        -- Top owns siblings: slice {1..3}, cursor at top level around f(...)
        local V = roundtrip(I, site({ 1 }, 3, {}, 2, 1))
        assert.equals('(seq (a) ◦ (b))', A.show(V.X))
        -- a hedge focus inside f: c d
        V = roundtrip(I, site({ 2 }, 1, { 1 }, 2, 2))
        assert.equals('(seq (f (b) ◦))', A.show(V.X))
        -- an empty focus: the arc between b and c (Huet: a location points to an arc, not an occurrence)
        V = roundtrip(I, site({ 2 }, 1, { 1 }, 2, 0))
        assert.equals('(seq (f (b) ◦ (c) (d)))', A.show(V.X))
        -- a zero-width slice: the context is the bare cursor
        V = roundtrip(I, site({ 2 }, 0, {}, 1, 0))
        assert.equals('(seq ◦)', A.show(V.X))
        -- the focus is the whole slice
        V = roundtrip(I, site({ 1 }, 3, {}, 1, 3))
        assert.equals('(seq ◦)', A.show(V.X))
    end)

    it('LAW (GetPut, no matching): on random ground hedges, random slice, cursor list and focus, cut then plug rebuilds', function()
        local leaves = { a, b, c }
        local function rand(rnd, dpt)
            if dpt == 0 or rnd(3) == 1 then return leaves[rnd(3)] end
            local kids = {}
            for i = 1, rnd(4) - 1 do kids[i] = rand(rnd, dpt - 1) end
            return node(({ 'f', 'g' })[rnd(2)], unpack(kids))
        end
        local checked, deep, empty = 0, 0, 0
        for seed = 1, 200 do
            local rnd = lcg(seed)
            local kids = {}
            for i = 1, rnd(4) do kids[i] = rand(rnd, 3) end
            local I = seq(kids)
            local n = rnd(#kids + 1) - 1
            local ii = rnd(#kids - n + 1)
            -- a random list inside the slice: descend while the current node has kids
            local p, L = {}, nil
            do
                local slice = {}
                for j = ii, ii + n - 1 do slice[#slice + 1] = kids[j] end
                L = slice
                while #L > 0 and rnd(2) == 1 do
                    local i = rnd(#L)
                    if not L[i].kids or #L[i].kids == 0 then break end
                    p[#p + 1] = i; L = L[i].kids
                end
            end
            local from = rnd(#L + 1)
            local cn = rnd(#L - from + 2) - 1
            local H = site({ ii }, n, p, from, cn)
            local V = roundtrip(I, H)
            local focus = {}
            for j = from, from + cn - 1 do focus[#focus + 1] = L[j] end
            local slice = {}
            for j = ii, ii + n - 1 do slice[#slice + 1] = kids[j] end
            assert.is_true(A.eq(A.plug(V.X, focus), seq(slice)), 'seed ' .. seed)
            assert.is_true(A.admits(A.context(), V.X))
            checked = checked + 1
            if #p > 0 then deep = deep + 1 end
            if cn == 0 then empty = empty + 1 end
        end
        assert.equals(200, checked); assert.is_true(deep > 25); assert.is_true(empty > 40) -- 35 deep cursors, 152 empty focuses when written
    end)

    it('the gate agrees on all three legs for BK Example 1, Kutsia\'s three matchers and the wider-space cases', function()
        local T = A.template(seq { X(a), f(X(g(a, xs), c), xs) })
        for _, I in ipairs { seq { h(a), f(h(g(a, b, b), c), b, b) }, seq { a, f(g(a, d), c, d) } } do
            local m = A.match(T, I)
            local gt = A.gate(T, m.values, I, nil, m.sites)
            assert.equals('unrefuted', gt.verdict, table.concat(gt.failed, ','))
        end
        local K = A.template(seq { A.ctx('C', { f(xs) }) })
        local I = seq { g(f(a, b), h(f(a), f())) }
        local r = A.match_all(K, I)
        assert.equals(3, #r.all)
        for _, m in ipairs(r.all) do
            assert.is_true(A.eq(A.abstract(I, m.sites).body, K.body))
            assert.is_true(A.values_eq(A.values_at(I, m.sites), m.values))
        end
        for _, case in ipairs {
            { A.template(seq { X(c) }), seq { b, c, d } },
            { A.template(seq { A.ctx('X', {}) }), seq { b } },
            { A.template(seq { X(), b }), seq { b } },
            { A.template(seq { X(f(xs)), A.hole('y', true) }), seq { g(f(a, b)), c, d } },
        } do
            local m = A.match(case[1], case[2])
            assert.is_true(m.ok)
            local gt = A.gate(case[1], m.values, case[2], nil, m.sites)
            assert.equals('unrefuted', gt.verdict, A.show(case[1].body) .. ': ' .. table.concat(gt.failed, ','))
        end
    end)

    it('coinciding sites need the enclosure: X(Y(a)) vs Y(X(a)) and (x... X(a)) vs X(x... a) on (a) have one geometry', function()
        local I = seq { a }
        for _, T in ipairs { A.template(seq { X(Y(a)) }), A.template(seq { Y(X(a)) }),
                             A.template(seq { xs, X(a) }), A.template(seq { X(xs, a) }) } do
            local m = A.match(T, I)
            assert.is_true(m.ok)
            assert.is_true(A.eq(A.abstract(I, m.sites).body, T.body), A.show(T.body))
        end
        -- the two nested templates bind identical sites but for `within`
        local m1, m2 = A.match(A.template(seq { X(Y(a)) }), I), A.match(A.template(seq { Y(X(a)) }), I)
        local s1, s2 = m1.sites.X.sites[1], m2.sites.X.sites[1]
        assert.same(s1.path, s2.path); assert.equals(s1.n, s2.n); assert.same(s1.cursor, s2.cursor)
        assert.is_nil(s1.within); assert.equals(m2.sites.Y.sites[1].id, s2.within)
        -- nested contexts with real content: X(Y(a)) against (h (g a)) has three matchers (X takes the
        -- cursor alone, h, or h and g); each cuts back to T, and one is X = (h ◦), Y = (g ◦)
        local T = A.template(seq { X(Y(a)) })
        local J = seq { h(g(a)) }
        local r = A.match_all(T, J)
        assert.equals(3, #r.all)
        local seen = false
        for _, m in ipairs(r.all) do
            local V = A.values_at(J, m.sites)
            assert.is_true(A.values_eq(V, m.values))
            assert.is_true(A.eq(A.abstract(J, m.sites).body, T.body), A.show(V.X) .. ' ' .. A.show(V.Y))
            if A.show(V.X) == '(seq (h ◦))' then seen = true; assert.equals('(seq (g ◦))', A.show(V.Y)) end
        end
        assert.is_true(seen)
        -- three levels: a term hole inside Y inside X; the enclosure is transitive
        local T3 = A.template(seq { X(Y(hole 'p')) })
        local r3 = A.match_all(T3, J)
        assert.is_true(#r3.all >= 3)
        for _, m in ipairs(r3.all) do
            assert.is_true(A.eq(A.abstract(J, m.sites).body, T3.body), A.show(m.values.X) .. ' ' .. A.show(m.values.Y) .. ' ' .. A.show(m.values.p))
            assert.is_true(A.values_eq(A.values_at(J, m.sites), m.values))
        end
    end)

    it('sites at one path and width are ordered by binding: three empty hedge holes before a, in every naming', function()
        -- (?p... ?q... ?r... a) against (a): three zero-width sites at {1}; geometry cannot order them, the ids do
        local I = seq { a }
        for _, names in ipairs { { 'x', 'y', 'z' }, { 'z', 'y', 'x' }, { 'y', 'z', 'x' }, { 'x', 'z', 'y' }, { 'z', 'x', 'y' }, { 'y', 'x', 'z' } } do
            local T = A.template(seq { A.hole(names[1], true), A.hole(names[2], true), A.hole(names[3], true), a })
            local m = A.match(T, I)
            assert.is_true(m.ok)
            assert.is_true(A.eq(A.abstract(I, m.sites).body, T.body), table.concat(names, ' '))
        end
        -- the same with empty contexts: (X() Y() a)
        local T = A.template(seq { A.ctx('X', {}), A.ctx('Y', {}), a })
        for _, m in ipairs(A.match_all(T, I).all) do
            assert.is_true(A.eq(A.abstract(I, m.sites).body, T.body), A.show(m.values.X) .. ' ' .. A.show(m.values.Y))
        end
    end)

    it('a repetition hole inside the applied hedge with a top-level cursor: the cut is taken on original coordinates', function()
        local T = A.template(seq { X(xs) })
        local I = seq { b, a, a, d }
        local r = A.match_all(T, I)
        local seen = false
        for _, m in ipairs(r.all) do
            assert.is_true(A.eq(A.abstract(I, m.sites).body, T.body), A.show(m.values.X)) -- never X(?x... d)
            assert.is_true(A.values_eq(A.values_at(I, m.sites), m.values))
            if A.show(m.values.X) == '(seq (b) ◦ (d))' then seen = true; assert.equals('(seq (a) (a))', A.show(m.values.x)) end
        end
        assert.is_true(seen)
        -- and a context after a context in one list, each with an inner hole: sites after a slice shift by its width
        local T2 = A.template(seq { X(hole 'p'), Y(hole 'q') })
        local I2 = seq { f(a), g(b), c }
        for _, m in ipairs(A.match_all(T2, I2).all) do
            assert.is_true(A.eq(A.abstract(I2, m.sites).body, T2.body), A.show(m.values.X) .. ' ' .. A.show(m.values.Y))
        end
    end)
end)

describe('matching with context variables (CTXMATCH.md; Kutsia WWV\'05 slides, BK 2014 contexts)', function()
    local function f(...) return node('f', ...) end
    local function g(...) return node('g', ...) end
    local function h(...) return node('h', ...) end
    local a, b, c, d = node 'a', node 'b', node 'c', node 'd'
    local X = function(...) return A.ctx('X', { ... }) end
    local xs = A.hole('x', true)
    local function lcg(seed)
        local s = seed
        return function(n) s = (s * 1103515245 + 12345) % 2147483648; return math.floor(s / 65536) % n + 1 end
    end

    it('BK Example 1 read backwards: (X(a), f(X(g(a,x), c), x)) matches both inputs and instantiate rebuilds them (PutGet)', function()
        local T = A.template(seq { X(a), f(X(g(a, xs), c), xs) })
        local s = seq { h(a), f(h(g(a, b, b), c), b, b) }
        local q = seq { a, f(g(a, d), c, d) }
        local ms = A.match(T, s)
        assert.is_true(ms.ok, ms.refusal and ms.refusal.why)
        assert.equals('(seq (h ◦))', A.show(ms.values.X)); assert.equals('(seq (b) (b))', A.show(ms.values.x))
        assert.is_true(A.eq(A.instantiate(T, ms.values).term, s))
        local mq = A.match(T, q)
        assert.is_true(mq.ok); assert.equals('(seq ◦)', A.show(mq.values.X)); assert.equals('(seq (d))', A.show(mq.values.x))
        assert.is_true(A.eq(A.instantiate(T, mq.values).term, q))
        -- X occurs twice: the two contexts must be EQUAL (non-linear), so h around one and not the other refuses
        local m3 = A.match(T, seq { h(a), f(g(a, d), c, d) })
        assert.is_false(m3.ok) -- the refusal reported is the last alternative's; the equality refusal is among those tried
        assert.equals(0, #A.match_all(T, seq { h(a), f(g(a, d), c, d) }).all)
        -- the site records the slice and where the wrapped content resumes
        local site = ms.sites.X.sites[1]
        assert.same({ 1 }, site.path); assert.equals(1, site.n); assert.same({ 1 }, site.cursor.path); assert.equals(1, site.cursor.from)
    end)

    it('Kutsia\'s example: C(f(x)) against g(f(a,b), h(f(a), f)) has exactly the three matchers of the slides', function()
        local K = A.template(seq { A.ctx('C', { f(xs) }) })
        local I = seq { g(f(a, b), h(f(a), f())) }
        local r = A.match_all(K, I)
        assert.equals(3, #r.all)
        local got = {}
        for _, m in ipairs(r.all) do got[#got + 1] = A.show(m.values.C) .. ' / ' .. A.show(m.values.x) end
        table.sort(got)
        assert.same({
            '(seq (g (f (a) (b)) (h (f (a)) ◦))) / (seq)',
            '(seq (g (f (a) (b)) (h ◦ (f)))) / (seq (a))',
            '(seq (g ◦ (h (f (a)) (f)))) / (seq (a) (b))',
        }, got)
        for _, m in ipairs(r.all) do assert.is_true(A.eq(A.instantiate(K, m.values).term, I)) end
        assert.is_true(got[1] ~= got[2] and got[2] ~= got[3]) -- pairwise distinct: match_all does not deduplicate, placements do
        -- the first matcher is what match returns
        assert.is_true(A.match(K, I).ok)
        -- and a template with no context hole enumerates its one matcher
        assert.equals(1, #A.match_all(A.template(f(hole 'y')), f(a)).all)
    end)

    it('BK hedge contexts are wider than Kutsia\'s term contexts: siblings, a top-level cursor, and a context that wraps nothing', function()
        -- the cursor at the top level with siblings on both sides: X ↦ (b ◦ d)
        local T = A.template(seq { X(c) })
        local m = A.match(T, seq { b, c, d })
        assert.is_true(m.ok); assert.equals('(seq (b) ◦ (d))', A.show(m.values.X))
        -- a context that wraps nothing: X applied to the empty hedge, the cursor at an insert point
        local T0 = A.template(seq { A.ctx('X', {}) })
        local m0 = A.match(T0, seq { b })
        assert.is_true(m0.ok); assert.equals('(seq ◦ (b))', A.show(m0.values.X)) -- the first placement found
        assert.is_true(A.eq(A.instantiate(T0, m0.values).term, seq { b }))
        -- a zero-width slice: X ↦ (◦) with the applied hedge matching nothing but itself
        local mz = A.match(A.template(seq { X(), b }), seq { b })
        assert.is_true(mz.ok); assert.equals('(seq ◦)', A.show(mz.values.X))
        -- a hedge hole inside the applied hedge, and a context hole beside a repetition hole in one list
        local T2 = A.template(seq { X(f(xs)), A.hole('y', true) })
        local m2 = A.match(T2, seq { g(f(a, b)), c, d })
        assert.is_true(m2.ok); assert.equals('(seq (g ◦))', A.show(m2.values.X)); assert.equals('(seq (c) (d))', A.show(m2.values.y))
    end)

    it('the search is budgeted and refuses by name; abstract and values_at need the cursor record (CTXCUT.md)', function()
        local deep = a
        for _ = 1, 12 do deep = f(deep, deep) end
        local T = A.template(seq { X(b), A.ctx('Y', { c }), A.ctx('Z', { d }) })
        local m = A.match(T, seq { deep }, { cap = 2000 })
        assert.is_false(m.ok); assert.matches('budget', m.refusal.why)
        local ok = A.match(A.template(seq { X(a) }), seq { h(a) })
        assert.equals('(seq (h ◦))', A.show(A.values_at(seq { h(a) }, ok.sites).X))
        assert.is_true(A.eq(A.template(seq { X(a) }).body, A.abstract(seq { h(a) }, ok.sites).body))
        -- H from sites(T) has no cursor record: refused by name, not misplaced
        assert.has_error(function() A.abstract(seq { h(a) }, A.sites(A.template(seq { X(a) }))) end, nil)
        assert.has_error(function() A.values_at(seq { h(a) }, A.sites(A.template(seq { X(a) }))) end, nil)
    end)

    it('completeness, the case the old matcher missed: two variable-width holes in one list, the shared one fixed from outside', function()
        -- inside f the first split tried is x1 = (), x2 = (c c); the top-level x2 then has nothing to bind and must be ();
        -- a matcher that commits the subtree's first success refuses here; the continuation-passing one revises it
        local T = A.template(seq { f(A.hole('x1', true), c, A.hole('x2', true)), A.hole('x2', true) })
        local m = A.match(T, seq { f(c, c, c) })
        assert.is_true(m.ok, m.refusal and m.refusal.why)
        assert.equals('(seq (c) (c))', A.show(m.values.x1)); assert.equals('(seq)', A.show(m.values.x2))
        assert.equals(1, #A.match_all(T, seq { f(c, c, c) }).all)
        -- the gate's three legs agree on a context template when H comes from match (CTXCUT.md)
        local Tc = A.template(seq { X(a) })
        local mc = A.match(Tc, seq { h(a) })
        local gt = A.gate(Tc, mc.values, seq { h(a) }, nil, mc.sites)
        assert.equals('unrefuted', gt.verdict, table.concat(gt.failed, ','))
    end)

    it('LAW: every rigid lgg M.vertical builds on random pairs matches both of its inputs, and instantiate rebuilds them (BK Theorem 3 through match)', function()
        local leaves = { a, b, c }
        local function rand(rnd, dpt)
            if dpt == 0 or rnd(3) == 1 then return leaves[rnd(3)] end
            local kids = {}
            for i = 1, rnd(3) do kids[i] = rand(rnd, dpt - 1) end
            return node(({ 'f', 'g' })[rnd(2)], unpack(kids))
        end
        local checked, withctx, pairs_ = 0, 0, 0
        for seed = 1, 120 do
            local rnd = lcg(seed)
            local sk, qk = {}, {}
            for i = 1, rnd(2) do sk[i] = rand(rnd, 2) end
            for i = 1, rnd(2) do qk[i] = rand(rnd, 2) end
            local s, q = seq(sk), seq(qk)
            local r = A.vertical(s, q)
            if r and r.templates then
                pairs_ = pairs_ + 1
                for _, T in ipairs(r.templates) do
                    local hasctx = false
                    for _, e in pairs(A.sites(T)) do if e.ctx then hasctx = true end end
                    for _, I in ipairs { s, q } do
                        local m = A.match(T, I, { cap = 50000 })
                        assert.is_true(m.ok, ('seed %d: %s vs %s: %s'):format(seed, A.show(T.body), A.show(I), tostring(m.refusal and m.refusal.why)))
                        assert.is_true(A.eq(A.instantiate(T, m.values).term, I), 'seed ' .. seed .. ' PutGet')
                        -- CTXCUT.md: the third leg crosses contexts, so the gate agrees on all three legs,
                        -- and every matcher of match_all cuts back to T and to its own values
                        local gt = A.gate(T, m.values, I, nil, m.sites)
                        assert.equals('unrefuted', gt.verdict, ('seed %d: %s vs %s: %s'):format(seed, A.show(T.body), A.show(I), table.concat(gt.failed, ',')))
                        for _, mm in ipairs(A.match_all(T, I, { cap = 50000 }).all) do
                            assert.is_true(A.eq(A.abstract(I, mm.sites).body, T.body), 'seed ' .. seed .. ' abstract of a matcher')
                            local W, conflicts = A.values_at(I, mm.sites)
                            assert.equals(0, #conflicts); assert.is_true(A.values_eq(W, mm.values), 'seed ' .. seed .. ' values_at of a matcher')
                        end
                        checked = checked + 1
                        if hasctx then withctx = withctx + 1 end
                    end
                end
            end
        end
        assert.is_true(checked >= 100 and withctx >= 30, ('checked %d with context holes %d over %d pairs'):format(checked, withctx, pairs_))
    end)
end)

describe('a database is a family read live (SQLITE.md; SQLite datatype3 §3, fileformat2 §1.3, pragma; Codd Figures 5 and 6 as tables)', function()
    local function emb(g, inner) return { k = 'embed', g = g, kids = { inner } } end
    -- the reader module lives beside the prototype; a re-vendored spec without experiments/ pends by name
    local okR, R = pcall(require, 'experiments.sqlite_reader')
    local have, ver
    if okR then have, ver = R.available() else have, ver = false, 'experiments/sqlite_reader.lua not found: ' .. tostring(R) end
    local tmp = (os.getenv('SQLITE_READER_TMP') or os.getenv('TMPDIR') or '/tmp')
    local db = tmp .. '/algebra_sqlite_fixture.db'
    local built
    local function need()
        if not have then pending('sqlite3 shell not available: ' .. tostring(ver)) return nil end
        if built == nil then built = assert(R.build(db, 'experiments/sqlite_fixture.sql')) end
        return R.open(db)
    end
    local function class_row(F, i)
        local out = {}
        for _, c in ipairs { 't', 'nu', 'i', 'r', 'no' } do out[#out + 1] = F.values[i][c].k end
        return table.concat(out, '|')
    end

    it('datatype3 §3.1.1: the affinity of every example typename, by the five rules in order', function()
        local ex = {
            INT = 'integer', INTEGER = 'integer', TINYINT = 'integer', SMALLINT = 'integer', MEDIUMINT = 'integer', BIGINT = 'integer',
            ['UNSIGNED BIG INT'] = 'integer', INT2 = 'integer', INT8 = 'integer',
            ['CHARACTER(20)'] = 'text', ['VARCHAR(255)'] = 'text', ['VARYING CHARACTER(255)'] = 'text', ['NCHAR(55)'] = 'text',
            ['NATIVE CHARACTER(70)'] = 'text', ['NVARCHAR(100)'] = 'text', TEXT = 'text', CLOB = 'text',
            BLOB = 'blob', [''] = 'blob',
            REAL = 'real', DOUBLE = 'real', ['DOUBLE PRECISION'] = 'real', FLOAT = 'real',
            NUMERIC = 'numeric', ['DECIMAL(10,5)'] = 'numeric', BOOLEAN = 'numeric', DATE = 'numeric', DATETIME = 'numeric',
            -- the two the document calls out: the order of the rules decides
            ['FLOATING POINT'] = 'integer', STRING = 'numeric',
        }
        for decl, aff in pairs(ex) do assert.equals(aff, A.affinity(decl), decl) end
        -- the supplied domain: an affinity's storage classes, NULL unless NOT NULL; exact under STRICT
        assert.equals('{blob|null|text}', A.show_domain(A.column_domain({ type = 'VARCHAR(20)' })))
        assert.equals('{blob|text}', A.show_domain(A.column_domain({ type = 'TEXT', notnull = 1 })))
        assert.equals('{integer}', A.show_domain(A.column_domain({ type = 'INTEGER', notnull = 1 }, true)))
        assert.equals('{blob|integer|null|real|text}', A.show_domain(A.column_domain({ type = 'INTEGER' })))
    end)

    it('datatype3 §3.4: the affinity example table, loaded five ways, stores the classes the document prints', function()
        local rd = need(); if not rd then return end
        local want = { t1_a = 'text|integer|integer|real|text', t1_b = 'text|integer|integer|real|real',
            t1_c = 'text|integer|integer|real|integer', t1_d = 'blob|blob|blob|blob|blob', t1_e = 'null|null|null|null|null' }
        for t, w in pairs(want) do
            local F = A.read(rd, t)
            assert.is_true(F.ok, t); assert.equals(1, F.n)
            assert.equals(w, class_row(F, 1), t)
        end
        -- a blob carries its class and no payload; a null is a node of its own
        local Fd = A.read(rd, 't1_d')
        assert.equals(0, #(Fd.values[1].t.kids or {})); assert.equals(0, #Fd.refused)
        -- a TEXT column that received the number 42 holds text '42' (TEXT affinity converts on the way in)
        local Fs = A.read(rd, 's')
        assert.equals('text', Fs.values[4].sname.k); assert.equals('42', Fs.values[4].sname.kids[1].v)
    end)

    it('the supplied template is the declaration, the derived one is the rows: the rows never say more than an affinity admits, and `narrowed` says where they say less', function()
        local rd = need(); if not rd then return end
        local F = A.read(rd, 'spj')
        assert.is_true(F.ok); assert.equals(4, F.n); assert.same({ 'sno', 'pno', 'jno' }, F.keys)
        for h, e in pairs(F.template.holes) do
            assert.equals('supplied', e.origin); assert.equals('derived', F.derived.holes[h].origin)
            assert.is_true(A.entails(F.derived.holes[h].domain, e.domain), h)
        end
        assert.is_true(A.instance_of(F.derived, F.template))
        assert.same({ 'jno', 'pno', 'qty', 'sno' }, F.narrowed)
        assert.equals('{integer|null}', A.show_domain(F.derived.holes.qty.domain)) -- one NULL quantity
        assert.equals('{integer}', A.show_domain(F.derived.holes.sno.domain))     -- '300' arrived as text and was stored as integer (INTEGER affinity)
        -- STRICT: the declared type is exact, so the supplied domain is one class, and the rows agree
        local S = A.read(rd, 'st')
        assert.equals('{integer}', A.show_domain(S.template.holes.n.domain))
        assert.equals('{null|text}', A.show_domain(S.template.holes.label.domain))
        assert.same({ 'id' }, S.narrowed) -- INTEGER PRIMARY KEY is never null in the rows, though table_info says notnull = 0
        -- an empty table is a family with no members, not an absence; with no rows the derived domain is open
        local E = A.read(rd, 'empty_t')
        assert.is_true(E.ok); assert.equals(0, E.n); assert.is_true(E.complete); assert.same({}, E.narrowed)
        assert.equals('open', E.derived.holes.a.domain.kind)
    end)

    it('Codd Figures 5 and 6 read from tables: the same five tuples, projections and point of ambiguity as the LINK.md test', function()
        local rd = need(); if not rd then return end
        local Rf, Sf = A.read(rd, 'codd_r'), A.read(rd, 'codd_s')
        assert.is_true(Rf.ok and Sf.ok)
        local L = A.link(Rf, Sf, { from = 'part', to = 'part', complete = true })
        assert.equals(5, #L.tuples)
        local rows = {}
        for _, t in ipairs(L.tuples) do
            rows[#rows + 1] = ('%d %d %d'):format(Rf.values[t.a].supplier.kids[1].v, t.key.kids[1].v, Sf.values[t.b].project.kids[1].v)
        end
        table.sort(rows)
        assert.same({ '1 1 1', '1 1 2', '2 1 1', '2 1 2', '2 2 1' }, rows)
        local p12, p23 = {}, {}
        for _, t in ipairs(L.tuples) do p12[t.a] = true; p23[t.b] = true end
        assert.same({ true, true, true }, p12); assert.same({ true, true, true }, p23) -- the two projections give R and S back
        assert.equals(1, #L.ambiguity); assert.same({ 1, 2 }, L.ambiguity[1].a); assert.same({ 1, 2 }, L.ambiguity[1].b)
        assert.is_false(L.is_function); assert.equals(2, L.fan); assert.equals(0, #L.dangling)
        assert.is_false(A.primary_key(Rf, 'part'))
    end)

    it('a foreign key is a link, and its dangling members are exactly what PRAGMA foreign_key_check reports', function()
        local rd = need(); if not rd then return end
        local spj, s, p = A.read(rd, 'spj'), A.read(rd, 's'), A.read(rd, 'p')
        local fks = rd.foreign_keys('spj')
        assert.equals(2, #fks)
        local links, viol = {}, {}
        for _, fk in ipairs(fks) do
            local parent = fk.table == 's' and s or p
            local L = A.link(spj, parent, { from = fk.from, to = fk.to, complete = true })
            links[fk.table] = L
            assert.is_true(L.is_function, fk.table .. ': the parent key is a primary key, so the link is a function (Codd: a foreign key)')
            for _, i in ipairs(L.dangling) do viol[#viol + 1] = ('%s %d %s'):format('spj', spj.rowid[i], fk.table) end
        end
        table.sort(viol)
        -- the database's own oracle: one violation, the shipment by supplier 9
        local oracle = {}
        for _, r in ipairs(rd.foreign_key_check()) do oracle[#oracle + 1] = ('%s %d %s'):format(r.table, r.rowid, r.parent) end
        table.sort(oracle)
        assert.same(oracle, viol); assert.same({ 'spj 4 s' }, viol)
        -- the chain from a shipment to its supplier row, and the dangling one as `absent` (the family is complete)
        local ch = A.chain(1, { links.s })
        assert.is_true(ch.ok); assert.same({ 1 }, ch.members)
        local chd = A.chain(4, { links.s })
        assert.is_false(chd.ok); assert.equals('absent', chd.absences[1].absence)
        -- read with a cap: the family is not complete, so the same miss is a `frontier`
        local s2 = A.read(rd, 's', { limit = 2 })
        assert.equals(2, s2.n); assert.is_false(s2.complete); assert.is_true(s2.source.truncated)
        local L2 = A.link(spj, s2, { from = 'sno', to = 'sno', complete = s2.complete })
        assert.equals('frontier', A.chain(4, { L2 }).absences[1].absence)
    end)

    it('absences: an unreachable file is `unavailable`, a missing table is `absent`, and a reader without a stamp is refused before it reads', function()
        local rd = need(); if not rd then return end
        local gone = A.read(R.open(tmp .. '/no/such/dir/x.db'), 's')
        assert.is_false(gone.ok); assert.equals('unavailable', gone.absence); assert.truthy(gone.why:find('no stamp'))
        -- and the shell's own refusal to open, reached when a stamp is supplied from elsewhere, is `unavailable` too
        local _, kind, why = R.exec(tmp .. '/no/such/dir/x.db', 'select 1;')
        assert.equals('unavailable', kind); assert.truthy(why:find('unable to open'))
        local missing = A.read(rd, 'nosuch')
        assert.is_false(missing.ok); assert.equals('absent', missing.absence); assert.truthy(missing.why:find('no such table'))
        -- a SQL error the shell reports is a refusal, passed through by name
        local sqlerr = R.open(db); local inner = sqlerr.read
        sqlerr.read = function(k, o) if k == 'bad' then local _, kind, why = R.exec(db, 'select * from s where;'); return { ok = false, absence = kind, why = why } end return inner(k, o) end
        assert.equals('refused', A.read(sqlerr, 'bad').absence)
        -- the same miss through a reader that does not claim completeness is a frontier
        local partial = R.open(db); partial.complete = false
        assert.equals('frontier', A.read(partial, 'nosuch').absence)
        -- a reader with no stamp function: refused by name, nothing read
        local reads = 0
        local nostamp = { via = 'x', complete = true, read = function() reads = reads + 1; return { ok = true, columns = {}, rows = {} } end }
        local r = A.read(nostamp, 't')
        assert.equals('unavailable', r.absence); assert.equals(0, reads)
        -- WAL: the header's write version is 2 and the change counter is not a stamp (fileformat2 §1.3.6)
        local wal = tmp .. '/algebra_sqlite_wal.db'
        assert(R.build(wal, 'experiments/sqlite_fixture.sql'))
        assert(R.exec(wal, 'pragma journal_mode=wal; insert into empty_t values (1, \'x\');'))
        assert.equals(2, R.header(wal).write_version)
        local w = A.read(R.open(wal), 's')
        assert.equals('unavailable', w.absence); assert.truthy(w.why:find('WAL'))
    end)

    it('the stamp is the header: the change counter moves on a write, the schema cookie on a schema change, and a read family goes stale, never silently', function()
        local rd = need(); if not rd then return end
        local F = A.read(rd, 's')
        assert.is_true(A.fresh(F, rd))
        local h0 = R.header(db)
        assert(R.exec(db, "insert into s values (5, 'Clark', 'Oslo');"))
        local h1 = R.header(db)
        assert.is_true(h1.change_counter > h0.change_counter); assert.equals(h0.schema_cookie, h1.schema_cookie)
        local ok, why = A.fresh(F, rd)
        assert.is_false(ok); assert.truthy(why:find('stale'))
        assert(R.exec(db, 'alter table s add column phone TEXT;'))
        local h2 = R.header(db)
        assert.is_true(h2.schema_cookie > h1.schema_cookie)
        -- the fixture is rebuilt for the tests after this one
        built = nil
        -- an unstamped family is not fresh, whatever the source says
        assert.is_false(A.fresh({ source = {} }, rd))
    end)

    it('demand: a verifying trace keyed on the stamp reruns the read only when the source moved (DEMAND.md)', function()
        local rd = need(); if not rd then return end
        local store = A.new_store { ['stamp:s'] = rd.stamp() }
        local reads = 0
        local tasks = { ['rows:s'] = function(fetch) fetch('stamp:s'); reads = reads + 1; return A.read(rd, 's') end }
        local log1 = A.build(tasks, 'rows:s', store)
        assert.same({ 'rows:s' }, log1.executed); assert.equals(1, reads)
        store.values['stamp:s'] = rd.stamp()
        local log2 = A.build(tasks, 'rows:s', store)
        assert.same({}, log2.executed); assert.same({ 'rows:s' }, log2.verified); assert.equals(1, reads)
        assert(R.exec(db, "insert into s values (6, 'Adams', 'Kyiv');"))
        store.values['stamp:s'] = rd.stamp()
        local log3 = A.build(tasks, 'rows:s', store)
        assert.same({ 'rows:s' }, log3.executed); assert.equals(2, reads); assert.equals(5, store.values['rows:s'].n)
        built = nil
    end)

    it('code to catalog: SQL strings in a code family link to the tables the database has, and a misspelt table is dangling (the dblink audit)', function()
        local rd = need(); if not rd then return end
        local cat = rd.catalog()
        local catalog = { template = A.template(node('tbl', hole 'name', hole 'type')), values = {} }
        for i, r in ipairs(cat) do catalog.values[i] = { name = lit(r.name), type = lit(r.type) } end
        local code = { template = A.template(node('call', name 'db_query', hole 'q')), values = {
            { q = lit 'SELECT sname, city FROM s WHERE sno = ?' },
            { q = lit 'insert into spj values (?, ?, ?, ?)' },
            { q = lit 'UPDATE "p" SET color = ? WHERE pno = ?' },
            { q = lit 'select count(*) from "spj"' },             -- a quoted table name
            { q = lit 'DELETE FROM shipments WHERE jno = ?' }, -- the typo
            { q = lit 'PRAGMA user_version' },                 -- not a statement the grammar names a table for
        } }
        local sql_reader = { template = A.template(emb('sql', node('sql', hole 'verb', hole 'table'))), hole = 'table' }
        local L = A.link(code, catalog, { from = 'q', to = 'name', read_from = sql_reader, complete = true })
        assert.equals(4, #L.tuples); assert.same({ 5 }, L.dangling); assert.same({ 6 }, L.unreadable.a)
        assert.is_true(L.is_function) -- a table name is the catalog's primary key
        local ch = A.chain(5, { L })
        assert.equals('absent', ch.absences[1].absence) -- the catalog is complete: the table is not there
    end)
end)

describe('keyed alignment: a node declares how its children align (KEYED.md; Kubernetes strategic merge patch; Plotkin per key)', function()
    local P, K, opt = A.pair, A.keyed, A.optional
    local function obj(list, o) return K('obj', list, o) end
    local function vals(V) local vs = {} for h, v in pairs(V) do vs[#vs + 1] = h .. '=' .. A.show(v) end table.sort(vs) return table.concat(vs, ' ') end

    it('a permutation of a keyed node is the same instance: eq, match (equal values, key-step sites), the gate; keyed-ordered tells them apart', function()
        local T = A.template(obj { P('a', hole 'x'), P('b', hole 'y') })
        local I1 = obj { P('a', lit(1)), P('b', lit(2)) }
        local I2 = obj { P('b', lit(2)), P('a', lit(1)) }
        assert.is_true(A.eq(I1, I2)); assert.equals(A.show(I1), A.show(I2))
        local m1, m2 = A.match(T, I1), A.match(T, I2)
        assert.is_true(m1.ok and m2.ok); assert.equals(vals(m1.values), vals(m2.values))
        assert.equals('a/2', A.key(m1.sites.x.sites[1].path)); assert.equals('a/2', A.key(m2.sites.x.sites[1].path))
        for _, I in ipairs { I1, I2 } do
            local m = A.match(T, I)
            local g = A.gate(T, m.values, I, nil, m.sites)
            assert.is_true(g.instance.ok and g.instance.agree); assert.is_true(g.values.ok and g.values.agree); assert.is_true(g.template.ok and g.template.agree)
        end
        -- declared order: the same two instances are now distinct, and the permuted one refuses by name
        local To = A.template(obj({ P('a', hole 'x'), P('b', hole 'y') }, { ordered = true }))
        local O1 = obj({ P('a', lit(1)), P('b', lit(2)) }, { ordered = true })
        local O2 = obj({ P('b', lit(2)), P('a', lit(1)) }, { ordered = true })
        assert.is_false(A.eq(O1, O2)); assert.is_true(A.match(To, O1).ok)
        local r = A.match(To, O2)
        assert.is_false(r.ok); assert.truthy(r.refusal.why:find('out of order')); assert.equals('absent', A.absence_of(r).absence)
        -- and a keyed instance never matches a positional template of the same shape, by name
        local r2 = A.match(T, A.node('obj', P('a', lit(1)), P('b', lit(2))))
        assert.is_false(r2.ok); assert.truthy(r2.refusal.why:find('^alignment'))
        -- the discipline is part of the node's identity: the same kids under two disciplines are two terms
        assert.is_false(A.eq(I1, A.node('obj', P('a', lit(1)), P('b', lit(2)))))
        assert.is_false(A.eq(I1, O1))
        -- the lens through a key step: put and rewrite reach a kid by its key, whatever its position
        local put = A.put(I2, { 'a', 2 }, lit(9))
        assert.is_true(A.eq(put, obj { P('a', lit(9)), P('b', lit(2)) }))
        local Tf = A.template(obj { P('a', hole 'x'), P('b', A.node('f', lit(1))) })
        local Tr, rwhy = A.rewrite(Tf, { 'b', 2 }, lit(7))
        assert.truthy(Tr, rwhy)
        assert.is_true(A.eq(Tr.body, obj { P('a', hole 'x'), P('b', lit(7)) }))
    end)

    it('strategic merge patch: containers merge by name; a container the template does not name is refused; an optional one binds present or absent', function()
        -- the document's pod: containers merged on `name` (patchStrategy merge, patchMergeKey name)
        local function c(kids) return A.node('container', unpack(kids)) end
        local function containers(list) return K('containers', list, { key = 'name' }) end
        local T = A.template(A.node('spec', P('containers', containers {
            c { P('name', lit 'nginx'), P('image', hole 'img') },
            opt(c { P('name', lit 'log-tailer'), P('image', hole 'timg') }, 'tailer'),
        })))
        local before = A.node('spec', P('containers', containers { c { P('name', lit 'nginx'), P('image', lit 'nginx-1.0') } }))
        local after = A.node('spec', P('containers', containers {
            c { P('name', lit 'log-tailer'), P('image', lit 'log-tailer-1.0') },
            c { P('name', lit 'nginx'), P('image', lit 'nginx-1.0') },
        }))
        local mb, ma = A.match(T, before), A.match(T, after)
        assert.is_true(mb.ok and ma.ok)
        assert.equals('img="nginx-1.0" tailer=(absent)', vals(mb.values))
        assert.equals('img="nginx-1.0" tailer=(present) timg="log-tailer-1.0"', vals(ma.values))
        -- the presence site sits at the key step; the body site under it
        assert.equals('1/2/log-tailer', A.key(ma.sites.tailer.sites[1].path))
        assert.equals('1/2/log-tailer/2/2', A.key(ma.sites.timg.sites[1].path))
        assert.equals('tailer', ma.sites.timg.sites[1].under[1].h)
        -- instantiate drops the absent container and rebuilds both pods (order is not identity)
        assert.is_true(A.eq(A.instantiate(T, mb.values).term, before))
        assert.is_true(A.eq(A.instantiate(T, ma.values).term, after))
        -- a third container is a key with no counterpart: refused, and the reading is complete
        local extra = A.node('spec', P('containers', containers { c { P('name', lit 'nginx'), P('image', lit 'x') }, c { P('name', lit 'sidecar'), P('image', lit 'y') } }))
        local r = A.match(T, extra)
        assert.is_false(r.ok); assert.truthy(r.refusal.why:find('sidecar has no counterpart')); assert.equals('absent', A.absence_of(r).absence)
        -- a required container missing is a refusal by name
        local none = A.node('spec', P('containers', containers { c { P('name', lit 'log-tailer'), P('image', lit 'y') } }))
        local r3 = A.match(T, none)
        assert.is_false(r3.ok); assert.truthy(r3.refusal.why:find('^key nginx is missing'))
    end)

    it('the gate through an optional pair: values_at and abstract work from a member carrying it; abstract refuses by name from one that lacks it', function()
        local T = A.template(obj { P('a', hole 'x'), opt(P('b', hole 'y'), 'p') })
        local I1, I2 = obj { P('a', lit(1)) }, obj { P('b', lit(2)), P('a', lit(1)) }
        local H = A.sites(T)
        assert.is_true(H.p.presence); assert.equals('{absent|present}', A.show_domain(H.p.domain))
        local V1 = A.values_at(I1, H); assert.equals('p=(absent) x=1', vals(V1))
        local V2 = A.values_at(I2, H); assert.equals('p=(present) x=1 y=2', vals(V2))
        -- a body hole under an absent pair owes no value: I1 instantiates without y
        local r1 = A.instantiate(T, V1); assert.is_true(r1.ok); assert.is_true(A.eq(r1.term, I1))
        assert.is_false(A.instantiate(T, { x = lit(1) }).ok) -- but the presence hole itself is owed
        local T2 = A.abstract(I2, H)
        assert.is_true(A.eq(T2.body, T.body)); assert.equals('p', T2.body.kids[2].opt == 'p' and 'p' or T2.body.kids[1].opt)
        local ok, why = pcall(A.abstract, I1, H)
        assert.is_false(ok); assert.truthy(tostring(why):find('optional pair b %(hole p%) is absent'))
    end)

    it('an unordered set of primitives (finalizers, patchStrategy merge) is a keyed node whose keys are its values; setElementOrder is the keyed-ordered reading', function()
        local function fin(list, o) local kids = {} for i, v in ipairs(list) do kids[i] = lit(v) end return K('finalizers', kids, { key = true, ordered = o }) end
        assert.is_true(A.eq(fin { 'a', 'b', 'c' }, fin { 'b', 'c', 'a' }))
        assert.is_false(A.eq(fin({ 'a', 'b', 'c' }, true), fin({ 'b', 'c', 'a' }, true)))
        assert.equals('(finalizers[key=true] "a" "b" "c")', A.show(fin { 'c', 'a', 'b' }))
        -- construction refuses a duplicate key, a kid without the merge key, and a hole in a merge-keyed list
        assert.has_error(function() obj { P('a', lit(1)), P('a', lit(2)) } end)
        assert.has_error(function() K('containers', { A.node('c', P('image', lit 'x')) }, { key = 'name' }) end)
        assert.has_error(function() K('containers', { hole 'h' }, { key = 'name' }) end)
    end)

    it('the positional operators refuse a keyed node by name: classify, unify, trace (join has its own arm)', function()
        local T = A.template(obj { P('a', hole 'x') })
        local I = obj { P('a', lit(1)) }
        assert.equals('unsupported', A.classify(T, { x = lit(1) }, obj { P('a', lit(2)) }).kind)
        local _, uw = A.unify(T, A.template(obj { P('a', lit(1)) })); assert.truthy(tostring(uw):find('keyed nodes'))
        local tw = A.trace(T, { x = lit(1) }).why; assert.truthy(tw:find('keyed nodes'))
        assert.equals('unavailable', A.absence_of({ why = tw }).absence)
        -- a keyed template against a positional instance of the same kind is a refusal inside join, not an error
        local r = A.join(T, A.node('obj', P('a', lit(1))))
        assert.truthy(r); assert.is_true(A.is_hole(r.template.body)) -- the two disciplines disagree: the whole node is a hole
    end)

    it('generalize over keyed nodes: strategic merge patch\'s two pods give the nginx image as a hole and the log-tailer as an optional container', function()
        local function c(kids) return A.node('container', unpack(kids)) end
        local function containers(list) return K('containers', list, { key = 'name' }) end
        local before = A.node('spec', P('containers', containers { c { P('name', lit 'nginx'), P('image', lit 'nginx-1.0') } }))
        local after = A.node('spec', P('containers', containers {
            c { P('name', lit 'log-tailer'), P('image', lit 'log-tailer-1.0') },
            c { P('name', lit 'nginx'), P('image', lit 'nginx-1.1') },
        }))
        local g = A.generalize({ before, after }, {})
        local T = g.template
        assert.equals('(spec (pair "containers" (containers[key=name] (?h2:container (pair "name" "log-tailer") (pair "image" "log-tailer-1.0")) (container (pair "name" "nginx") (pair "image" ?h1)))))', A.show(T.body))
        assert.is_true(T.holes.h2.presence); assert.equals('{absent|present}', A.show_domain(T.holes.h2.domain)); assert.equals('presence', g.notes.h2.why)
        assert.equals('h1="nginx-1.0" h2=(absent)', vals(g.values[1])); assert.equals('h1="nginx-1.1" h2=(present)', vals(g.values[2]))
        for i, I in ipairs { before, after } do
            assert.is_true(A.eq(A.instantiate(T, g.values[i]).term, I))
            local m = A.match(T, I); assert.is_true(m.ok); assert.equals(vals(g.values[i]), vals(m.values))
        end
        -- the order note: two members, keys in different orders, so the order is not stable
        local list = T.body.kids[1].kids[2]
        assert.is_false(list.order.stable); assert.equals(2, list.order.support); assert.is_false(list.order.claimed)
        -- three members that agree on the key order: stable, and claimed at need = 3
        local o = function(x, y) return obj { P('a', lit(x)), P('b', lit(y)) } end
        local g3 = A.generalize({ o(1, 2), o(3, 4), o(5, 6) }, {})
        assert.is_true(g3.template.body.order.stable and g3.template.body.order.claimed); assert.equals(3, g3.template.body.order.support)
        -- a permuted third member: stable is false, and the template still rebuilds it (keyed, so order is not identity)
        local g3p = A.generalize({ o(1, 2), o(3, 4), obj { P('b', lit(6)), P('a', lit(5)) } }, {})
        assert.is_false(g3p.template.body.order.stable)
        assert.is_true(A.eq(A.instantiate(g3p.template, g3p.values[3]).term, obj { P('a', lit(5)), P('b', lit(6)) }))
        -- a nested optional: a key present only under a pair that is itself optional is not doubly optional
        local i1 = obj { P('a', lit(1)) }
        local i2 = obj { P('a', lit(1)), P('m', obj { P('x', lit(1)) }) }
        local i3 = obj { P('a', lit(1)), P('m', obj { P('x', lit(2)), P('y', lit(3)) }) }
        local gn = A.generalize({ i1, i2, i3 }, {})
        local hs, valueh = {}, nil
        for h, e in pairs(gn.template.holes) do
            hs[#hs + 1] = (e.presence and 'presence' or 'value') .. ':' .. A.show_domain(e.domain)
            if not e.presence then valueh = h end
        end
        table.sort(hs)
        assert.same({ 'presence:{absent|present}', 'presence:{absent|present}', 'value:{lit}' }, hs)
        assert.is_true(gn.notes[valueh].under_optional) -- its column has a gap: no recursion claim is made over it
        for i, I in ipairs { i1, i2, i3 } do assert.is_true(A.eq(A.instantiate(gn.template, gn.values[i]).term, I), 'member ' .. i) end
    end)

    it('MANIFESTS.md as the oracle: generalize over the keyed terms of the Kubernetes manifests reproduces kv_generalize hole for hole', function()
        local O = dofile('experiments/keyed_oracle.lua')
        local core = { ['redis-cart'] = true, loadgenerator = true, ['frontend-external'] = true }
        local want = { -- MANIFESTS.md's table: holes / value / presence / sites / shared / rebuild
            { 'Deployment', {}, 31, 13, 18, 51, 10, 12 }, { 'Deployment', core, 24, 11, 13, 43, 8, 10 },
            { 'Service', {}, 8, 5, 3, 9, 1, 12 }, { 'Service', core, 5, 3, 2, 7, 1, 10 }, { 'ServiceAccount', {}, 1, 1, 0, 1, 0, 11 },
        }
        for _, w in ipairs(want) do
            local kv, t = O.run(w[1], w[2], function() end)
            local tag = w[1] .. (next(w[2]) and ' core' or ' all')
            assert.equals(w[3], kv.value + kv.presence + kv.array + kv.mixed, tag .. ' kv holes'); assert.equals(w[3], t.value + t.presence + t.array + t.mixed, tag .. ' holes')
            assert.equals(w[4], t.value, tag .. ' value'); assert.equals(w[5], t.presence, tag .. ' presence')
            assert.equals(w[6], t.sites, tag .. ' sites'); assert.equals(w[7], t.shared, tag .. ' shared'); assert.equals(w[8], t.rebuild, tag .. ' rebuild')
            assert.equals(0, t.array + t.mixed, tag .. ' no array/mixed holes')
        end
        -- and per group the two agree on every column, not only the totals asserted above
        for _, w in ipairs(want) do
            local kv, t = O.run(w[1], w[2], function() end)
            for _, f in ipairs { 'value', 'presence', 'array', 'mixed', 'sites', 'shared', 'rebuild' } do assert.equals(kv[f], t[f], w[1] .. ' ' .. f) end
        end
    end)

    it('join over keyed nodes: a key on one side is carried under a new presence hole; rejoining a member changes nothing; the fold of join reproduces the oracle', function()
        local function c(kids) return A.node('container', unpack(kids)) end
        local function containers(list) return K('containers', list, { key = 'name' }) end
        local before = A.node('spec', P('containers', containers { c { P('name', lit 'nginx'), P('image', lit 'nginx-1.0') } }))
        local after = A.node('spec', P('containers', containers {
            c { P('name', lit 'log-tailer'), P('image', lit 'log-tailer-1.0') },
            c { P('name', lit 'nginx'), P('image', lit 'nginx-1.1') },
        }))
        local r = A.join(A.template(before), after)
        assert.truthy(r, 'join refused')
        assert.equals('(spec (pair "containers" (containers[key=name] (?j2:container (pair "name" "log-tailer") (pair "image" "log-tailer-1.0")) (container (pair "name" "nginx") (pair "image" ?j1)))))', A.show(r.template.body))
        assert.same({ 'j1', 'j2' }, r.new); assert.is_true(r.template.holes.j2.presence)
        local W1, W2 = r.left({}), r.right({})
        assert.equals('j1="nginx-1.0" j2=(absent)', vals(W1)); assert.equals('j1="nginx-1.1" j2=(present)', vals(W2))
        assert.is_true(A.eq(A.instantiate(r.template, W1).term, before)); assert.is_true(A.eq(A.instantiate(r.template, W2).term, after))
        -- match = join with nothing new: a member already admitted moves nothing
        for _, I in ipairs { before, after } do
            local r2 = A.join(r.template, I)
            assert.equals(0, #r2.new + #r2.split + #r2.widened, 'rejoin')
            local kept = { unpack(r2.kept) }; table.sort(kept)
            assert.same({ 'j1', 'j2' }, kept)
        end
        -- two templates whose optional pairs already carry presence holes: the names are kept
        local Ta = A.template(obj { P('a', hole 'x'), opt(P('b', hole 'y'), 'p') })
        local Tb = A.template(obj { P('a', hole 'x2'), opt(P('b', hole 'y2'), 'q'), P('c', lit(3)) })
        local rj = A.join(Ta, Tb)
        assert.equals('(obj[keyed] (pair "a" ?x) (?p:pair "b" ?y) (?j1:pair "c" 3))', A.show(rj.template.body))
        assert.same({ 'p', 'x', 'y' }, (function() local k = {} for _, h in ipairs(rj.kept) do k[#k + 1] = h end table.sort(k) return k end)())
        -- the FOLD LAW on the manifests: adjoining the Deployments one by one lands on the oracle's numbers
        local KV = dofile('experiments/kv_terms.lua')
        local data = dofile('experiments/manifests-data-2026-09-11.lua')
        for _, w in ipairs { { 'Deployment', 31, 18, 51, 10, 12 }, { 'Service', 8, 3, 9, 1, 12 } } do
            local docs = {}
            for _, e in ipairs(data[w[1]]) do docs[#docs + 1] = e.doc end
            local terms = KV.of_all(docs, A)
            local T0, Vs = A.template(A.copy(terms[1])), { {} }
            for i = 2, #terms do local ad, why = A.adjoin(T0, Vs, terms[i]); assert.truthy(ad, w[1] .. ' member ' .. i .. ': ' .. tostring(why)); T0, Vs = ad.template, ad.values end
            local nh, np, ns, sh, rb = 0, 0, 0, 0, 0
            local HF = A.sites(T0)
            for _, e in pairs(HF) do nh = nh + 1; if e.presence then np = np + 1 end; ns = ns + #e.sites; if #e.sites > 1 then sh = sh + 1 end end
            for i = 1, #terms do local ri = A.instantiate(T0, Vs[i]); if ri.ok and A.eq(ri.term, terms[i]) then rb = rb + 1 end end
            -- the same SITES and every member rebuilt; the fold's template is the n-ary one up to renaming
            -- in shape, and it may hold FEWER holes: two columns whose values agree wherever both are
            -- defined, differing only in which members lack the optional pair above one of them, are
            -- one hole to the fold and two to the n-ary rule (one hole per value vector, the gap
            -- counted). The fold's answer is more specific and depends on member order; the n-ary
            -- answer is the keyed generalizer's and order-free. Measured: 27 against 31 on the
            -- Deployments, all four merges of that shape; 8 against 8 on the Services.
            assert.equals(w[4], ns, w[1] .. ' fold sites'); assert.equals(w[6], rb, w[1] .. ' fold rebuild'); assert.equals(w[5], sh, w[1] .. ' fold shared')
            assert.is_true(nh <= w[2] and np <= w[3], w[1] .. (' fold holes %d presence %d'):format(nh, np))
            local g = A.generalize(terms, {})
            local function erase(str) return (str:gsub("%?[%w_.']+", '?')) end
            assert.equals(erase(A.show(g.template.body)), erase(A.show(T0.body)), w[1] .. ' fold = generalize up to renaming')
            -- every merge the fold made is gap-compatible: the n-ary holes under one fold hole agree wherever both hold a value
            local gm = {}
            for h, e in pairs(A.sites(g.template)) do for _, st in ipairs(e.sites) do gm[A.key(st.path)] = h end end
            local merges = 0
            for fh, e in pairs(HF) do
                local seen = {}
                for _, st in ipairs(e.sites) do seen[gm[A.key(st.path)]] = true end
                local list = {}
                for h in pairs(seen) do list[#list + 1] = h end
                if #list > 1 then
                    merges = merges + 1
                    for i = 1, #terms do
                        local ref
                        for _, h in ipairs(list) do
                            local v = g.values[i][h]
                            if v ~= nil then
                                if ref and not A.eq(ref, v) then error(('fold hole %s merges n-ary holes that disagree on member %d'):format(fh, i)) end
                                ref = ref or v
                            end
                        end
                    end
                end
            end
            if w[1] == 'Deployment' then assert.equals(3, merges) else assert.equals(0, merges) end
        end
    end)

    it('a merge-keyed list whose elements under one key diverge in kind: the whole list is the hole, in generalize and in join, and nothing raises later', function()
        local function list(kids) return K('list', kids, { key = 'name' }) end
        local a = list { A.node('container', P('name', lit 'x'), P('image', lit 'i1')), A.node('container', P('name', lit 'y'), P('image', lit 'i2')) }
        local b = list { A.node('container', P('name', lit 'x'), P('image', lit 'i3')), A.node('sidecar', P('name', lit 'y'), P('image', lit 'i2')) }
        local g = A.generalize({ a, b }, {})
        assert.is_true(A.is_hole(g.template.body)); assert.equals('alignment', g.notes[g.template.body.h].why)
        assert.is_true(A.eq(A.instantiate(g.template, g.values[2]).term, b))
        local r = A.join(A.template(a), b)
        assert.is_true(A.is_hole(r.template.body)); assert.is_true(A.eq(r.right({})[r.template.body.h], b))
        -- and the no-raise property: show, eq and match all answer
        assert.truthy(A.show(g.template.body)); assert.is_true(A.match(g.template, a).ok)
        -- the same two lists with the kinds agreeing generalize per key as before
        local b2 = list { A.node('container', P('name', lit 'x'), P('image', lit 'i3')), A.node('container', P('name', lit 'y'), P('image', lit 'i2')) }
        local g2 = A.generalize({ a, b2 }, {})
        assert.equals('(list[key=name] (container (pair "name" "x") (pair "image" ?h1)) (container (pair "name" "y") (pair "image" "i2")))', A.show(g2.template.body))
    end)

    it('removing a member: pin its presence hole to absent and migrate; rewrite the parent without it; an edit that would leave an unkeyed kid is refused by name', function()
        local function cls(list) return K('class', list) end
        local c1 = cls { P('run', A.node('body', lit(1))), P('log', A.node('body', lit 'x')) }
        local c2 = cls { P('run', A.node('body', lit(2))), P('log', A.node('body', lit 'x')) }
        local c3 = cls { P('run', A.node('body', lit(3))) }
        local g = A.generalize({ c1, c2, c3 }, {})
        local T, Vs = g.template, g.values
        local pres; for h, e in pairs(T.holes) do if e.presence then pres = h end end
        -- 1. the family stops describing the member: pin its presence to absent; the classes carrying it fall out, by name
        local T2 = A.pin(T, pres, A.absent())
        local mig = A.migrate(T, T2, Vs)
        assert.equals(1, #mig.kept); assert.equals(2, #mig.dropped); assert.truthy(mig.dropped[1].why:find('value differs'))
        assert.is_true(A.eq(A.instantiate(mig.template, mig.values[3]).term, c3))
        -- and open undoes it: the pin's premise is gone, the member is optional again
        local T2b = A.open_hole(T2, pres)
        assert.is_true(A.match(T2b, c1).ok)
        -- 2. a hole-free member is removed by rewriting the parent without it
        local T3 = A.template(cls { P('run', hole 'r'), P('log', A.node('body', lit 'x')) })
        local T4, why = A.rewrite(T3, {}, cls { P('run', hole 'r') })
        assert.truthy(T4, why); assert.equals('(class[keyed] (pair "run" ?r))', A.show(T4.body))
        -- renaming a member through its key step is a rewrite of the pair; a duplicate key is refused
        local T5 = assert(A.rewrite(T3, { 'log' }, P('trace', A.node('body', lit 'x'))))
        assert.equals('(class[keyed] (pair "run" ?r) (pair "trace" (body "x")))', A.show(T5.body))
        local _, dup = A.rewrite(T3, { 'log' }, P('run', A.node('body', lit 'y'))); assert.truthy(dup:find('already a kid'))
        -- 3. an edit that would leave an unkeyed kid in a keyed node is refused by name, in rewrite and in dig
        local _, w1 = A.rewrite(T3, { 'log' }, A.node('nothing')); assert.truthy(w1:find('must carry a key'))
        local _, w2 = A.dig(T3, { 'log' }, 'g'); assert.truthy(w2:find('must carry a key') and w2:find("pair's value"))
        local T6 = assert(A.dig(T3, { 'log', 2 }, 'g')); assert.equals('(class[keyed] (pair "log" ?g) (pair "run" ?r))', A.show(T6.body))
        local malformed = { k = 'm', align = 'keyed', kids = { A.node('x') } } -- built by hand: the constructor would have refused it
        local _, w3 = A.rewrite(T3, { 'log', 2 }, malformed); assert.truthy(w3:find('^rewrite: .*keyed m'))
        -- 4. detection: a class lacking a required member refuses by name (absent); classifying the removal is still refused
        local m = A.match(T3, cls { P('run', A.node('body', lit(9))) })
        assert.is_false(m.ok); assert.truthy(m.refusal.why:find('^key log is missing')); assert.equals('absent', A.absence_of(m).absence)
        assert.equals('unsupported', A.classify(T3, { r = A.node('body', lit(1)) }, cls { P('run', A.node('body', lit(1))) }).kind)
        -- 5. removing an INSTANCE from a family is a membership change: the derived domains follow the survivors
        local T7 = A.rederive_domains(A.copy(T), { Vs[1], Vs[2] })
        assert.equals('=(present)', A.show_domain(T7.holes[pres].domain))
    end)

    it('law: over random keyed objects with optional pairs, a permutation of the kids leaves match values and the gate unchanged (200 seeds)', function()
        local seeds, checked, absent_seen, nested = 200, 0, 0, 0
        for seed = 1, seeds do
            local rnd = A.rng and A.rng(seed) or nil
            math.randomseed(seed)
            local nk = 2 + (seed % 3)
            local tkids, ikids, V = {}, {}, {}
            for i = 1, nk do
                local key = string.char(96 + i)
                local v = lit(seed * 7 + i)
                local body = hole('h' .. i)
                V['h' .. i] = v
                if i == nk and seed % 2 == 0 then
                    -- a nested keyed object as the value
                    body = obj { P('n', hole('h' .. i)) }
                    v = obj { P('n', lit(seed)) }
                    V['h' .. i] = lit(seed)
                    nested = nested + 1
                end
                local pair = P(key, body)
                if i == 2 then
                    pair = opt(pair, 'p')
                    if seed % 3 == 0 then V.p = A.absent(); V['h' .. i] = nil; pair = pair else V.p = A.present() end
                end
                tkids[#tkids + 1] = pair
                if not (i == 2 and seed % 3 == 0) then ikids[#ikids + 1] = P(key, v) end
            end
            local T = A.template(obj(tkids))
            local I = obj(ikids)
            -- a random permutation of the instance's kids
            local perm = {}
            for i = 1, #ikids do perm[i] = ikids[i] end
            for i = #perm, 2, -1 do local j = 1 + (seed * 31 + i * 17) % i; perm[i], perm[j] = perm[j], perm[i] end
            local Ip = obj(perm)
            assert.is_true(A.eq(I, Ip))
            local m, mp = A.match(T, I), A.match(T, Ip)
            assert.is_true(m.ok and mp.ok, 'seed ' .. seed .. ': ' .. tostring(m.refusal and m.refusal.why) .. ' / ' .. tostring(mp.refusal and mp.refusal.why))
            assert.equals(vals(m.values), vals(mp.values))
            assert.equals(vals(V), vals(m.values), 'seed ' .. seed)
            local g = A.gate(T, mp.values, Ip, nil, mp.sites)
            assert.is_true(g.instance.ok and g.instance.agree and g.values.ok and g.values.agree, 'seed ' .. seed)
            if seed % 3 == 0 then
                -- the optional pair is absent here: the third leg cannot recover its body and says so
                assert.is_false(g.template.ok); assert.truthy(tostring(g.template.why):find('optional pair b'), 'seed ' .. seed .. ': ' .. tostring(g.template.why))
            else
                assert.is_true(g.template.ok and g.template.agree, 'seed ' .. seed .. ': ' .. tostring(g.template.why))
            end
            checked = checked + 1
            if seed % 3 == 0 then absent_seen = absent_seen + 1 end
        end
        assert.is_true(checked == seeds and absent_seen > 50 and nested > 80, ('checked %d absent %d nested %d'):format(checked, absent_seen, nested))
    end)

    -- ── composite keys (KEYED.md "Composite keys"; JLS §8.4.2; Erlang reference manual §Functions; Kubernetes server-side apply, x-kubernetes-list-map-keys)
    local function prm(ty, nm) return A.node('param', P('type', lit(ty)), P('name', lit(nm))) end
    local function meth(nm, params, body) return A.node('method', P('name', lit(nm)), P('params', seq(params)), P('body', body or lit 'x')) end
    local SIG = { key = { 'name', { field = 'params', by = 'types' } } }
    local ARITY = { key = { 'name', { field = 'params', by = 'arity' } } }

    it('Kubernetes list-map-keys: ports keyed by (port, protocol) are two entries, keyed by port alone a duplicate; the tuple is compared componentwise, never as a concatenated string', function()
        local function port(p, proto) return A.node('port', P('port', lit(p)), P('protocol', lit(proto))) end
        local ports = K('ports', { port(80, 'TCP'), port(80, 'UDP') }, { key = { 'port', 'protocol' } })
        assert.equals('port=80,protocol=TCP', A.key_of(ports, ports.kids[1]))
        assert.matches('%[key=port%+protocol%]', A.show(ports))
        local ok, why = pcall(K, 'ports', { port(80, 'TCP'), port(80, 'UDP') }, { key = 'port' })
        assert.is_false(ok); assert.matches('duplicate key 80', why)
        -- a permutation is the same instance, and the key is a path step
        assert.is_true(A.eq(ports, K('ports', { port(80, 'UDP'), port(80, 'TCP') }, { key = { 'port', 'protocol' } })))
        local T = A.template(K('ports', { A.node('port', P('port', lit(80)), P('protocol', lit 'TCP'), P('name', hole 'n')) }, { key = { 'port', 'protocol' } }))
        local m = A.match(T, K('ports', { A.node('port', P('port', lit(80)), P('protocol', lit 'TCP'), P('name', lit 'http')) }, { key = { 'port', 'protocol' } }))
        assert.is_true(m.ok); assert.equals('http', m.values.n.v); assert.equals('port=80,protocol=TCP/3/2', A.key(m.sites.n.sites[1].path))
        -- the key fields must be scalars; a missing component is a refusal by name, not an empty component
        local ok2, why2 = pcall(K, 'ports', { A.node('port', P('port', lit(80))) }, { key = { 'port', 'protocol' } })
        assert.is_false(ok2); assert.matches('no field protocol', why2)
        local ok3, why3 = pcall(K, 'ports', { A.node('port', P('port', lit(80)), P('protocol', A.node('x'))) }, { key = { 'port', 'protocol' } })
        assert.is_false(ok3); assert.matches('protocol is not a scalar', why3)
        -- a hole is never a key component, plain or measured: a key is an identity, not a variable
        local ok4, why4 = pcall(K, 'ports', { A.node('port', P('port', hole 'p'), P('protocol', lit 'TCP')) }, { key = { 'port', 'protocol' } })
        assert.is_false(ok4); assert.matches('key field port is a hole', why4)
        local ok5, why5 = pcall(K, 'mod', { A.node('method', P('name', lit 'f'), P('params', hole 'ps')) }, { key = { 'name', { field = 'params', by = 'arity' } } })
        assert.is_false(ok5); assert.matches('key field params is a hole', why5) -- not f/0
        -- ("x,b=y", "z") and ("x", "y,b=z") are different tuples although their naive concatenations agree
        local e1 = A.node('r', P('a', lit 'x,b=y'), P('b', lit 'z')); local e2 = A.node('r', P('a', lit 'x'), P('b', lit 'y,b=z'))
        local rs = K('rs', { e1, e2 }, { key = { 'a', 'b' } })
        assert.equals(2, #A.keys(rs)); assert.is_true(A.key_of(rs, e1) ~= A.key_of(rs, e2))
        assert.equals('a=x\\,b\\=y,b=z', A.key_of(rs, e1))
        local e3 = A.node('r', P('a', lit 'p\\'), P('b', lit 'q')); local e4 = A.node('r', P('a', lit 'p'), P('b', lit '\\q'))
        assert.is_true(A.key_of(rs, e3) ~= A.key_of(rs, e4))
    end)

    it('JLS 8.4.2: the signature is the name and the formal parameter types; two override-equivalent methods in one class are a compile-time error (Example 8.4.2-1), the names of the parameters do not enter; move(int,int) and move(String) are two members', function()
        -- Example 8.4.2-1: class Point { abstract void move(int dx, int dy); void move(int dx, int dy) {} } is an error
        local ok, why = pcall(K, 'Point', { meth('move', { prm('int', 'dx'), prm('int', 'dy') }, lit 'abstract'), meth('move', { prm('int', 'dx'), prm('int', 'dy') }, lit 'concrete') }, SIG)
        assert.is_false(ok); assert.matches('duplicate key name=move,params/types=int|int', why, 1, true)
        -- the parameter names do not enter: move(int a, int b) is the same signature
        local ok2 = pcall(K, 'Point', { meth('move', { prm('int', 'dx'), prm('int', 'dy') }), meth('move', { prm('int', 'a'), prm('int', 'b') }) }, SIG)
        assert.is_false(ok2)
        -- overloads: move(int,int) and move(String) are two keys, and the order in the class does not matter
        local A1 = K('Point', { meth('move', { prm('int', 'dx'), prm('int', 'dy') }, lit(1)), meth('move', { prm('String', 's') }, lit(2)) }, SIG)
        local A2 = K('Point', { meth('move', { prm('String', 's') }, lit(3)), meth('move', { prm('int', 'dx'), prm('int', 'dy') }, lit(4)) }, SIG)
        local B = K('Point', { meth('move', { prm('int', 'dx'), prm('int', 'dy') }, lit(5)) }, SIG)
        assert.matches('%[key=name%+params/types%]', A.show(A1))
        assert.same({ 'name=move,params/types=String', 'name=move,params/types=int|int' }, (function() local ks = {} for _, e in ipairs(A.keys(A1)) do ks[#ks + 1] = e.key end return ks end)())
        -- generalize: the two-int body is a hole over three classes, the String overload's presence is a hole (present, present, absent)
        local g = A.generalize({ A1, A2, B }, {})
        local pres, bodies = 0, 0
        for h, e in pairs(g.template.holes) do if e.presence then pres = pres + 1 else bodies = bodies + 1 end end
        assert.equals(1, pres); assert.equals(2, bodies)
        for i, V in ipairs(g.values) do for h, e in pairs(g.template.holes) do if e.presence then assert.equals(i == 3 and 'absent' or 'present', V[h].k) end end end
        assert.is_true(A.eq(A1, A.instantiate(g.template, g.values[1]).term)); assert.is_true(A.eq(B, A.instantiate(g.template, g.values[3]).term))
        -- a class whose method has a parameter without a type is refused by name
        local ok3, why3 = pcall(K, 'C', { A.node('method', P('name', lit 'f'), P('params', seq { A.node('param', P('name', lit 'x')) })) }, SIG)
        assert.is_false(ok3); assert.matches('parameter 1 of params has no type', why3)
    end)

    it('Erlang: a function is uniquely defined by module, name and arity (mod:f/N); f/1 and f/2 are two members of one module; f/2 twice is refused', function()
        local m = K('mod', { meth('f', { prm('any', 'X') }, lit(1)), meth('f', { prm('any', 'X'), prm('any', 'Y') }, lit(2)) }, ARITY)
        assert.equals('name=f,params/arity=1', A.key_of(m, m.kids[1])); assert.equals('name=f,params/arity=2', A.key_of(m, m.kids[2]))
        assert.matches('%[key=name%+params/arity%]', A.show(m))
        -- the types do not enter under arity: f(X) and f(Y) of different declared types are the same f/1
        local ok, why = pcall(K, 'mod', { meth('f', { prm('int', 'X') }), meth('f', { prm('atom', 'Y') }) }, ARITY)
        assert.is_false(ok); assert.matches('duplicate key name=f,params/arity=1', why, 1, true)
        -- mod:f/N is rendered from the key: the string is the tuple, the tuple is the string
        local function mfa(mod, key) local n, a = key:match('^name=(.-),params/arity=(%d+)$') return mod .. ':' .. n .. '/' .. a end
        assert.equals('mod:f/2', mfa('mod', A.key_of(m, m.kids[2])))
        -- a module that lacks f/1 aligns by key with one that has it: a presence hole, no positional shift of f/2
        local m2 = K('mod', { meth('f', { prm('any', 'X'), prm('any', 'Y') }, lit(2)) }, ARITY)
        local g = A.generalize({ m, m2 }, {})
        local pres, other = 0, 0
        for h, e in pairs(g.template.holes) do if e.presence then pres = pres + 1 else other = other + 1 end end
        assert.equals(1, pres); assert.equals(0, other) -- f/2 agrees exactly, f/1 is present then absent
    end)

    it("Codd's composite primary key: salaryhistory' is keyed by (man#, jobdate); primary_key over man alone is false, over the pair true; link over the pair is a function and never matches on a prefix of the tuple", function()
        local function fam(T, rows) return { template = T, values = rows } end
        local jobs = fam(A.template(A.node('job', hole 'man', hole 'jobdate', hole 'title')), {
            { man = lit(7), jobdate = lit(1990), title = lit 'eng' }, { man = lit(7), jobdate = lit(1995), title = lit 'lead' }, { man = lit(8), jobdate = lit(1990), title = lit 'eng' } })
        local sals = fam(A.template(A.node('sal', hole 'man', hole 'jobdate', hole 'salarydate', hole 'salary')), {
            { man = lit(7), jobdate = lit(1990), salarydate = lit(1990), salary = lit(100) }, { man = lit(7), jobdate = lit(1990), salarydate = lit(1991), salary = lit(110) },
            { man = lit(7), jobdate = lit(1995), salarydate = lit(1995), salary = lit(150) }, { man = lit(8), jobdate = lit(1990), salarydate = lit(2000), salary = lit(120) },
            { man = lit(9), jobdate = lit(1990), salarydate = lit(1990), salary = lit(90) } }) -- man 9 dangles: jobdate 1990 alone would match man 7's job
        assert.is_false(A.primary_key(jobs, 'man')); assert.is_false(A.primary_key(jobs, 'jobdate'))
        assert.is_true(A.primary_key(jobs, { 'man', 'jobdate' }))
        assert.is_false(A.primary_key(sals, { 'man', 'jobdate' })); assert.is_true(A.primary_key(sals, { 'man', 'jobdate', 'salarydate' }))
        local ok, dups = A.primary_key(jobs, { 'man', 'title' }) -- (7, eng) is unique, but (man, title) is not the key: (7,eng),(7,lead),(8,eng) are distinct: true
        assert.is_true(ok)
        local L = A.link(sals, jobs, { from = { 'man', 'jobdate' }, to = { 'man', 'jobdate' } })
        assert.is_true(L.is_function); assert.equals(4, #L.tuples); assert.equals(1, #L.dangling); assert.equals(5, L.dangling[1])
        -- a prefix or a permutation of the tuple is not the tuple
        local Lp = A.link(sals, jobs, { from = { 'jobdate', 'man' }, to = { 'man', 'jobdate' } })
        assert.equals(0, #Lp.tuples)
        -- readers apply per component: a reader for jobdate normalizing a string year
        local sals2 = fam(sals.template, { { man = lit(7), jobdate = lit '1990', salarydate = lit(1990), salary = lit(100) } })
        local year = function(v) return v.k == 'lit' and lit(tonumber(v.v)) or v end
        local Lr = A.link(sals2, jobs, { from = { 'man', 'jobdate' }, to = { 'man', 'jobdate' }, read_from = { nil, year } })
        assert.equals(1, #Lr.tuples) -- a list of readers indexed like the holes: nil for man reads the value as it is, year for jobdate
        local Lr0 = A.link(sals2, jobs, { from = { 'man', 'jobdate' }, to = { 'man', 'jobdate' } })
        assert.equals(0, #Lr0.tuples) -- without the reader "1990" and 1990 are different values
        -- a chain through a composite link names the tuple in its absence, not a table address
        local Lc = A.link(sals, jobs, { from = { 'man', 'jobdate' }, to = { 'man', 'jobdate' }, complete = true })
        local ch = A.chain({ 1, 5 }, { Lc })
        assert.equals(1, #ch.absences); assert.equals('absent', ch.absences[1].absence)
        assert.matches('member 5: no %(man, jobdate%) with %(man, jobdate%) equal to its %(man, jobdate%)', ch.absences[1].why)
    end)

    it('the key oracle (KEYED.md "Oracle"): key_of via match and readers partitions the kids as the algebra does; deriving the key over the fixtures gives the signature among the minimal keys and never the name alone', function()
        local okm, O = pcall(dofile, 'experiments/key_oracle.lua')
        if not okm or type(O) ~= 'table' then return pending('experiments/key_oracle.lua not readable') end
        local function port(p, proto) return A.node('port', P('port', lit(p)), P('protocol', lit(proto))) end
        local ports = K('ports', { port(80, 'TCP'), port(80, 'UDP') }, { key = { 'port', 'protocol' } })
        local A1 = K('Point', { meth('move', { prm('int', 'dx'), prm('int', 'dy') }, lit(1)), meth('move', { prm('String', 's') }, lit(2)) }, SIG)
        local m = K('mod', { meth('f', { prm('any', 'X') }, lit(1)), meth('f', { prm('any', 'X'), prm('any', 'Y') }, lit(2)) }, ARITY)
        local obj = K('obj', { P('a', lit(1)), P('b', lit(2)) })
        local esc = K('rs', { A.node('r', P('a', lit 'x,b=y'), P('b', lit 'z')), A.node('r', P('a', lit 'x'), P('b', lit 'y,b=z')) }, { key = { 'a', 'b' } })
        for _, t in ipairs { ports, A1, m, obj, esc } do
            local r = O.check(t)
            assert.is_true(r.ok, table.concat(r.disagreements, '; '))
            assert.equals(r.pairs, r.pairs_agree); assert.equals(0, r.refused_alg_only + r.refused_oracle_only)
        end
        -- the oracle reads a positional kid with two repetition holes around the pair and a keyed kid through the lens
        local _, how = O.field(ports.kids[1], 'protocol'); assert.equals('hedge', how)
        local _, how2 = O.field(obj, 'a'); assert.equals('lens', how2)
        -- the oracle refuses what the algebra refuses: a hole in a key field, a missing field, a non-scalar
        local malformed = { k = 'ports', align = 'keyed', key = { 'port', 'protocol' }, kids = { A.node('port', P('port', hole 'p'), P('protocol', lit 'TCP')), A.node('port', P('port', lit(1))), A.node('port', P('port', lit(1)), P('protocol', A.node('x'))) } }
        local r = O.check(malformed); assert.equals(3, r.refused_both); assert.is_true(r.ok)
        -- deriving: Shape has two names, so name alone is not a key and the signature's types are
        local C = K('Shape', { meth('draw', {}, lit(1)), meth('move', { prm('int', 'dx'), prm('int', 'dy') }, lit(1)), meth('move', { prm('String', 's') }, lit(1)) }, SIG)
        local d = O.derive { C }
        assert.is_false(d.is_key { 'name' }); assert.is_true(d.is_key { 'params/types' }); assert.is_true(d.is_key { 'name', 'params/types' })
        assert.equals(1, d.keysize); assert.is_true(d.spec.is_key); assert.is_false(d.spec.minimal) -- the JLS signature is a superkey of the data's key
        -- Erlang: over two modules, name alone and arity alone are not keys; name+arity is a minimal key, and so is name+body: the data cannot choose, the schema does
        local m2 = K('mod', { meth('f', { prm('any', 'X'), prm('any', 'Y') }, lit(2)), meth('g', { prm('any', 'X'), prm('any', 'Y') }, lit(2)) }, ARITY)
        local e = O.derive { m, m2 }
        assert.is_false(e.is_key { 'name' }); assert.is_false(e.is_key { 'params/arity' }); assert.is_true(e.is_key { 'name', 'params/arity' }); assert.is_true(e.is_key { 'body', 'name' })
        assert.equals(2, e.keysize); assert.is_true(e.spec.is_key and e.spec.minimal)
        -- ports: over two lists neither field alone is a key and the pair is the only minimal key
        local p2 = O.derive { ports, K('ports', { port(80, 'TCP'), port(443, 'TCP') }, { key = { 'port', 'protocol' } }) }
        assert.equals(1, #p2.keys); assert.same({ 'port', 'protocol' }, p2.keys[1])
    end)
end)

describe('repetition: the period is the unit (Kolpakov and Kucherov 1999, REPETITION.md)', function()
    local A = require 'algebra'
    local node, lit, hole, seq = A.node, A.lit, A.hole, A.seq
    local function word(s) local ks = {}; for c in s:gmatch('%S+') do ks[#ks + 1] = lit(c) end; return ks end
    local function w(s) return node('w', unpack(word(s))) end

    it('page 1: period, exponent and every maximal repetition of 1011010110110', function()
        local letters = word('1 0 1 1 0 1 0 1 1 0 1 1 0')
        assert.equals(2, A.period(word('1 0 1 0 1')))       -- 10101 has period 2
        assert.equals(2.5, A.exponent(word('1 0 1 0 1')))
        assert.equals(2, A.exponent(word('a b a b')))        -- a square
        assert.equals(2, A.period(word('1 0 1')))            -- 101 has period 2 (exponent 1.5: not a repetition)
        assert.equals(3, A.period(word('1 0 0')))            -- primitive: the period is the length
        assert.equals(0, A.period({}))
        local got = {}
        for _, r in ipairs(A.maximal_repetitions(letters)) do got[#got + 1] = { r.from, r.to, r.period } end
        -- the paper's list: 10101 (period 2), the prefix 10110101101 (5), the suffix 10110110 (3),
        -- the prefix 101101 (3), and the three occurrences of 11 (1); 1010 at 4-7 is not maximal
        assert.same({ { 1, 6, 3 }, { 1, 11, 5 }, { 3, 4, 1 }, { 4, 8, 2 }, { 6, 13, 3 }, { 8, 9, 1 }, { 11, 12, 1 } }, got)
    end)

    it('a b, a b a b, a b a b a b: the unit is the period (a b), not "a literal"', function()
        local g = A.generalize { w 'a b', w 'a b a b', w 'a b a b a b' }
        assert.equals('(w "a" "b" ?h1...)', A.show(g.template.body))
        assert.equals('rep', g.notes.h1.claimed)
        assert.equals(2, g.notes.h1.period)
        assert.equals('@h1.unit/2{0,}', A.show_domain(g.template.holes.h1.domain))
        assert.equals('(seq "a" "b")', A.show(g.env.defs['h1.unit'].body))
        assert.is_true(A.match(g.template, w 'a b a b a b a b a b', g.env).ok)
        local m = A.match(g.template, w 'a b a', g.env)
        assert.is_false(m.ok); assert.matches('length 1 is not a multiple of the period 2', m.refusal.why)
        m = A.match(g.template, w 'a b b a', g.env)
        assert.is_false(m.ok); assert.matches('chunk 1', m.refusal.why)
        assert.is_true(A.eq(A.instantiate(g.template, g.values[3], g.env).term, w 'a b a b a b'))
        local chunks = A.unit_values(g.template, 'h1', g.values[3], g.env)
        assert.equals(2, #chunks)
    end)

    it('a varying leaf inside the unit: (a ?v) with period 2, the chunks carry the values', function()
        local g = A.generalize { w 'a 1 a 2', w 'a 3', w 'a 4 a 5 a 6' }
        assert.equals('(w "a" ?h1... ?h2)', A.show(g.template.body))
        assert.equals('@h1.unit/2{0,}', A.show_domain(g.template.holes.h1.domain))
        assert.equals('(seq ?h1.1 "a")', A.show(g.env.defs['h1.unit'].body))
        local chunks = A.unit_values(g.template, 'h1', g.values[3], g.env)
        assert.equals(2, #chunks)
        assert.equals('4', tostring(chunks[1]['h1.1'].v)); assert.equals('5', tostring(chunks[2]['h1.1'].v))
        assert.equals('6', tostring(g.values[3].h2.v))
        assert.is_true(A.match(g.template, w 'a 7 a 8 a 9 a 10', g.env).ok)
        assert.is_false(A.match(g.template, w 'a 7 a', g.env).ok)
    end)

    it('two lengths: under-determined, the hypothesis names the period', function()
        local g = A.generalize { w 'a b', w 'a b a b a b' }
        assert.equals('open', g.notes.h1.claimed); assert.is_true(g.notes.h1.under_determined)
        assert.equals(2, g.notes.h1.hypothesis.period)
        -- KK: a b seen once beside nothing is exponent 1, no repetition: the hypothesis falls back to the element
        assert.equals(1, A.generalize({ w 'a b', w 'a b a b' }).notes.h1.hypothesis.period)
        assert.equals('(w "a" "b" ?h1...)', A.show(g.template.body))
    end)

    it('KK: a repetition has exponent at least 2, so one chunk is no period (need = 2)', function()
        local g = A.generalize({ w '', w 'a b c' }, { need = 2 })
        assert.equals('rep', g.notes.h1.claimed)
        assert.equals(1, g.notes.h1.period) -- three literals are elements, not a unit of period 3 seen once
        assert.equals('@h1.elem{0,}', A.show_domain(g.template.holes.h1.domain))
    end)

    it('KK: the period is the SMALLEST p; (a b) beats (a b a b) when both divide every run', function()
        local g = A.generalize { w '', w 'a b a b', w 'a b a b a b a b' }
        assert.equals(2, g.notes.h1.period)
        assert.equals('(seq "a" "b")', A.show(g.env.defs['h1.unit'].body))
    end)

    it('a head column of mixed kinds does not align: no split, no claim (the identical suffix is committed before any anchor)', function()
        local g = A.generalize { node('w', lit(1), lit 'a', lit 'b'), node('w', A.name 'x', lit 'a', lit 'b', lit 'a', lit 'b'), node('w', node('q'), lit 'a', lit 'b', lit 'a', lit 'b', lit 'a', lit 'b') }
        assert.equals('(w ?h1... "a" "b")', A.show(g.template.body)) -- the identical suffix is committed first (LCSJOIN.md keeps the ends rule ahead of the anchors)
        assert.equals('open', g.notes.h1.claimed) -- middles 1 / x a b / (q) a b a b: the mixed column never aligns
        assert.is_false(g.notes.h1.homogeneous)
    end)

    it('the element rule stands: distinct literals at three lengths still claim @h1.elem', function()
        local g = A.generalize { w '1 2 3', w '4 5 6 7', w '8 9 10 11 12' }
        assert.equals('(w ?h1...)', A.show(g.template.body))
        assert.equals('@h1.elem{0,}', A.show_domain(g.template.holes.h1.domain))
        assert.is_true(g.notes.h1.trivial)
    end)

    it('a fold of join plus rederive claims the same unit; behind a head or tail it claims the shape', function()
        local env = { defs = {} }
        local i1, i2, i3 = w 'a b', w 'a b a b', w 'a b a b a b'
        local r1 = A.join(A.template(i1), i2, { prefix = 'h', env = env })
        local values = { r1.left({}), r1.right({}) }
        local r2 = A.join(r1.template, i3, { prefix = 'h', env = env })
        values = { r2.left(values[1]), r2.left(values[2]), r2.right({}) }
        local T = r2.template
        local _, notes = A.rederive_domains(T, values, { env = env })
        assert.equals('@h1.unit/2{0,}', A.show_domain(T.holes.h1.domain))
        assert.equals(2, notes.h1.period)
        assert.is_true(A.match(T, w 'a b a b a b a b', env).ok)
        assert.is_false(A.match(T, w 'a b a', env).ok)
        -- the tail case: rederive keeps the hedge whole and claims a seq template (the shape)
        env = { defs = {} }
        local j1, j2, j3 = w 'a 1 a 2', w 'a 3', w 'a 4 a 5 a 6'
        r1 = A.join(A.template(j1), j2, { prefix = 'h', env = env })
        values = { r1.left({}), r1.right({}) }
        r2 = A.join(r1.template, j3, { prefix = 'h', env = env })
        values = { r2.left(values[1]), r2.left(values[2]), r2.right({}) }
        T = r2.template
        A.rederive_domains(T, values, { env = env })
        assert.equals('@h1.shape', A.show_domain(T.holes.h1.domain))
        assert.equals('(seq ?h1.run... ?h1.tail1.1)', A.show(env.defs['h1.shape'].body))
        assert.equals('@h1.unit/2{0,}', A.show_domain(env.defs['h1.shape'].holes['h1.run'].domain))
        assert.is_true(A.match(T, w 'a 7 a 8 a 9 a 10', env).ok)
        assert.is_false(A.match(T, w 'a 7 a', env).ok)
        -- generalize proper describes the same sequences with the columns in the body
        local g = A.generalize { j1, j2, j3 }
        assert.is_true(A.match(g.template, w 'a 7 a 8 a 9 a 10', g.env).ok)
    end)

    it('the period survives relax and refuses to meet a different one', function()
        assert.equals('@u/3{0,}', A.show_domain(A.relax(A.rep(A.ref 'u', 0, nil, 3))))
        -- unify: an open hedge takes the claim, period included; two explicit claims with
        -- different periods refuse by name
        local env = { defs = { u = A.template(seq { lit 'a', lit 'b' }) } }
        local T = A.template(node('w', hole('h', true)), { h = { domain = A.rep(A.ref 'u', 0, nil, 2), origin = 'derived' } })
        local U = A.unify(A.template(node('w', hole('q', true))), T, env)
        assert.is_truthy(U and U.ok ~= false)
        local _, e = next(U.template.holes)
        assert.equals('@u/2{0,}', A.show_domain(e.domain))
        local T1 = A.template(node('w', hole('h', true)), { h = { domain = A.rep(A.kinds { 'lit' }), origin = 'derived' } })
        local R, why = A.unify(T1, T, env)
        assert.is_nil(R); assert.matches('periods differ: 1 and 2', why)
        local defs = { u = A.template(seq { lit 'a', lit 'b' }) }
        assert.is_true(A.admits(A.rep(A.ref 'u', 0, nil, 2), seq { lit 'a', lit 'b', lit 'a', lit 'b' }, { defs = defs }))
        local ok, why = A.admits(A.rep(A.ref 'u', 0, nil, 2), seq { lit 'a', lit 'b', lit 'a' }, { defs = defs })
        assert.is_false(ok); assert.matches('not a multiple of the period 2', why)
        ok, why = A.admits(A.rep(A.ref 'u', 0, nil, 2), seq { lit 'a', lit 'b', lit 'b', lit 'a' }, { defs = defs })
        assert.is_false(ok); assert.matches('chunk 2', why)
    end)

    it('the composite generator (experiments/key_gen.lua): its instances generalize to the fragment', function()
        local ok, G = pcall(dofile, 'experiments/key_gen.lua')
        if not ok then return pending('experiments/key_gen.lua not loadable: ' .. tostring(G)) end
        local function comp(c) return A.instantiate(G.COMP_PLAIN, { c = lit(c), label = lit(c) }).term end
        local function many(fields)
            local frags = {}
            for _, c in ipairs(fields) do frags[#frags + 1] = comp(c) end
            return A.instantiate(G.MANY, { spec = lit(table.concat(fields, '+')), comps = seq(frags) }).term
        end
        local i1, i2, i3 = many { 'a' }, many { 'port', 'protocol' }, many { 'x', 'y', 'z' }
        local g = A.generalize { i1, i2, i3 }
        local b = g.template.body
        assert.equals(5, #b.kids)
        assert.is_true(A.is_hole(b.kids[2]) and not b.kids[2].rep) -- the spec, a term column inside the old middle
        assert.equals('src', b.kids[3].k)
        assert.is_true(A.is_hole(b.kids[4]) and b.kids[4].rep == true) -- the components, a run of period 1
        local run = b.kids[4].h
        assert.equals('rep', g.notes[run].claimed); assert.equals(1, g.notes[run].period)
        -- ~~head == 2: the spec literal and the chunk after it moved out of the middle~~ since LCSJOIN.md
        -- the chunk after the spec anchors and the spec is a column; nothing is left to move out
        assert.equals(0, g.notes[run].head)
        local unit = g.env.defs[run .. '.elem']
        -- the derived fragment sits BELOW the authored one: one hole where the author wrote two
        -- (field name and label coincide in every instance; the same underdetermination the key
        -- oracle found), so it is an instance of the authored fragment and not the other way round
        assert.is_true(A.instance_of(unit, G.COMP_PLAIN))
        assert.is_false(A.instance_of(G.COMP_PLAIN, unit))
        local chunks = A.unit_values(g.template, run, g.values[2], g.env)
        assert.equals(2, #chunks)
        local names = {}
        for _, ch in ipairs(chunks) do for _, v in pairs(ch) do names[#names + 1] = v.v end end
        assert.same({ 'port', 'protocol' }, names)
        -- the instance rebuilt from the derived generator prints the same source
        local back = A.instantiate(g.template, g.values[2], g.env).term
        assert.is_true(A.eq(back, i2))
        assert.equals(G.print_lua(back), G.print_lua(i2))
        -- flattened (each component's kids spliced into the list): the period is the block length
        local function flat(t)
            local kids = {}
            for _, k in ipairs(t.kids) do
                if k.k == 'comp' then for _, kk in ipairs(k.kids) do kids[#kids + 1] = kk end else kids[#kids + 1] = k end
            end
            return A.rebuild(t, kids)
        end
        local f = A.generalize { flat(i1), flat(i2), flat(i3) }
        local fr
        for _, h in ipairs(A.hole_names(f.template)) do if f.template.holes[h].rep then fr = h end end
        assert.equals(6, f.notes[fr].period)
        -- since LCSJOIN.md the identical chunks of the first component anchor, so one period stands
        -- unrolled as fixed columns (its field name a term hole) and the run claims the periods after
        -- it: ~~a unit of 2 holes across a component boundary~~ one hole, the unit on the boundary
        assert.equals(1, f.notes[fr].head)
        assert.equals(1, #A.hole_names(f.env.defs[fr .. '.unit']))
        assert.equals('@' .. fr .. '.unit/6{0,}', A.show_domain(f.template.holes[fr].domain))
        assert.is_true(A.match(f.template, flat(many { 'p' }), f.env).ok) -- one component: the run empty
        assert.is_true(A.match(f.template, flat(many { 'p', 'q', 'r', 's' }), f.env).ok)
        assert.is_true(A.eq(A.instantiate(f.template, f.values[3], f.env).term, flat(i3)))
    end)
end)

describe('the lossless lua reader (READER.md): tree-sitter terms, unfolded byte for byte', function()
    local A = require 'algebra'
    local okf, FX = pcall(dofile, 'experiments/lua-terms-2026-09-18.lua')
    local function fixture() if not okf then return pending('experiments/lua-terms-2026-09-18.lua not loadable: ' .. tostring(FX)) end return FX end

    it('print after parse is the identity on every member and on a whole file', function()
        local F = fixture(); if not F then return end
        for _, m in ipairs(F.members) do assert.equals(m.source, A.cst_print(m.term)) end
        assert.equals(F.file.source, A.cst_print(F.file.term))
        assert.equals(F.file.source, A.grammars.lua.print(F.file.term)) -- the `lua` grammar's print is cst_print
        assert.is_nil(A.grammars.lua.parse('return 1')) -- without the bridge the grammar reads nothing
    end)

    it('cst_print concatenates every leaf in order: literals, names, nested kids', function()
        local t = A.node('call', A.name 'f', A.lit '(', A.node('args', A.name 'x', A.lit ', ', A.lit '1'), A.lit ')')
        assert.equals('f(x, 1)', A.cst_print(t))
        assert.has_error(function() A.cst_print(A.node('x', A.hole 'h')) end)
    end)

    it('the split search of the repetition analysis stops at its budget and says so', function()
        local w = function(s) local ks = {}; for c in s:gmatch('%S+') do ks[#ks + 1] = A.lit(c) end; return A.node('w', unpack(ks)) end
        local full = A.generalize { w 'a 1 a 2', w 'a 3', w 'a 4 a 5 a 6' }
        assert.equals(2, full.notes.h1.period); assert.is_nil(full.notes.h1.truncated)
        local cut = A.generalize({ w 'a 1 a 2', w 'a 3', w 'a 4 a 5 a 6' }, { split_cap = 1 })
        assert.is_true(cut.notes.h1.truncated)
        assert.are_not.equal(2, cut.notes.h1.period)
        -- the memo does not keep a truncated answer: the same env with the default budget finds the period
        local env = { defs = {} }
        A.generalize({ w 'a 1 a 2', w 'a 3', w 'a 4 a 5 a 6' }, { split_cap = 1, env = env })
        local again = A.generalize({ w 'a 1 a 2', w 'a 3', w 'a 4 a 5 a 6' }, { env = env })
        assert.equals(2, again.notes.h1.period); assert.is_nil(again.notes.h1.truncated)
    end)

    it('the first fold: six callbacks generalize to two holes, the module and the report function, and unfold byte-exact', function()
        local F = fixture(); if not F then return end
        local six, src = {}, {}
        for _, m in ipairs(F.members) do if m.line ~= 84 then six[#six + 1] = m.term; src[#src + 1] = m.source end end
        assert.equals(6, #six)
        local g = A.generalize(six, { need = 100 })
        local names = A.hole_names(g.template); table.sort(names)
        assert.same({ 'h1', 'h2' }, names)
        local mods, fns = {}, {}
        for i = 1, 6 do mods[i] = A.cst_print(g.values[i].h1); fns[i] = A.cst_print(g.values[i].h2) end
        assert.same({ 'cartograph.untangle', 'cartograph.optimize', 'cartograph.narrow', 'cartograph.narrow', 'cartograph.narrow', 'cartograph.lens' }, mods)
        assert.same({ 'report_blocks', 'report', 'report', 'param_report', 'devirt_report', 'report' }, fns)
        for i = 1, 6 do assert.equals(src[i], A.cst_print(A.instantiate(g.template, g.values[i]).term)) end
        -- the statement alignment came from the tree: the holes sit inside string_content and identifier nodes
        local kinds = {}
        for _, p in ipairs(A.positions(g.template.body)) do if A.is_hole(p.node) then kinds[#kinds + 1] = A.locate_at(g.template.body, { unpack(p.path, 1, #p.path - 1) }).k end end
        table.sort(kinds); assert.same({ 'identifier', 'string_content' }, kinds)
    end)

    it('the seventh callback, without the mat_df line, joins through one hedge', function()
        local F = fixture(); if not F then return end
        local six, seventh = {}, nil
        for _, m in ipairs(F.members) do if m.line ~= 84 then six[#six + 1] = m.term else seventh = m.term end end
        local g = A.generalize(six, { need = 100 })
        local j = A.join(g.template, seventh, { env = g.env })
        assert.is_truthy(j); assert.equals(1, #j.new)
        assert.is_true(j.template.holes[j.new[1]].rep)
        assert.is_true(A.match(j.template, seventh, g.env).ok)
        for _, t in ipairs(six) do assert.is_true(A.match(j.template, t, g.env).ok) end
    end)

    it('one edit on the template, propagated: every member re-instantiates, compiles, and differs only at that site', function()
        local F = fixture(); if not F then return end
        local six, src = {}, {}
        for _, m in ipairs(F.members) do if m.line ~= 84 then six[#six + 1] = m.term; src[#src + 1] = m.source end end
        local g = A.generalize(six, { need = 100 })
        local path
        for _, p in ipairs(A.positions(g.template.body)) do if p.node.k == 'identifier' and p.node.kids[1].v == 'WARN' then path = p.path end end
        assert.is_truthy(path)
        local T2, why = A.rewrite(g.template, path, A.node('identifier', A.lit 'ERROR'))
        assert.is_truthy(T2, why); assert.equals(1, #T2.edits); assert.equals('rewrite', T2.edits[1].op)
        for i = 1, 6 do
            local new = A.cst_print(A.instantiate(T2, g.values[i]).term)
            assert.equals((src[i]:gsub('vim%.log%.levels%.WARN', 'vim.log.levels.ERROR', 1)), new)
            assert.is_truthy((loadstring or load)(new), 'member ' .. i .. ' does not compile')
        end
    end)
end)

describe('the recursive fold (FOLD.md; Nevill-Manning and Witten 1997: rule utility, priced by MDL)', function()
    local A = require 'algebra'
    local node, lit = A.node, A.lit
    local okf, FX = pcall(dofile, 'experiments/lua-terms-2026-09-18.lua')
    local function fixture() if not okf then return pending('experiments/lua-terms-2026-09-18.lua not loadable: ' .. tostring(FX)) end return FX end

    it('text_size prices a term in bytes, a hole counting one', function()
        assert.equals(7, A.text_size(node('call', A.name 'f', lit '(', lit 'x', lit ', 1', lit ')')))
        assert.equals(3, A.text_size(node('x', lit 'ab', A.hole 'h')))
    end)

    it('p2, rule utility: a column of one member is never a family, and a nested template that does not shorten is refused', function()
        -- two members whose hole values share a kind but nothing else: (f 1 2 3) vs (f 4 5 6) nested
        -- would cost the template plus six values, more than the two values as they stand
        local i1, i2 = node('g', node('f', lit(1), lit(2), lit(3))), node('g', node('f', lit(4), lit(5), lit(6)))
        local F = A.fold { i1, i2 }
        assert.is_nil(next(F.families)); assert.equals(F.flat, F.dl)
        -- a hole present in one member only (under nothing shared) cannot nest: one value is no column
        local F1 = A.fold({ node('g', node('f', lit(1))), node('g', lit 'x') })
        assert.is_nil(next(F1.families))
    end)

    it('recursion lives at the hedges: a varying tail of (h n) elements nests into (h ?x), priced once', function()
        local function g(...) return node('g', node('f', lit 'a'), ...) end
        local function h(n) return node('h', lit(n), lit 'x', lit 'y', lit 'z') end
        local a, b, c = g(h(1), h(2)), g(h(3)), g(h(4), h(5), h(6))
        local F = A.fold({ a, b, c }, { need = 100 })
        local hh = next(F.families)
        assert.is_truthy(hh, 'a nested family at the hedge')
        local fam = F.families[hh]
        assert.is_truthy(fam.kinds and fam.kinds.h)
        assert.equals('(h ?' .. hh .. '.h.1 "x" "y" "z")', A.show(fam.kinds.h.template.body))
        assert.equals(6, #fam.kinds.h.members)
        -- priced: the template once plus six inner values, plus six references, against six 5-node terms
        assert.equals(A.size(fam.kinds.h.template.body) + 1 + 6, fam.kinds.h.dl)
        assert.is_true(fam.kinds.h.dl + 6 < 30)
        -- a unit too small to pay for its references is refused: (h n) costs 2, a reference plus an inner value costs 2
        local small = A.fold({ g(node('h', lit(1)), node('h', lit(2))), g(node('h', lit(3))), g(node('h', lit(4)), node('h', lit(5)), node('h', lit(6))) }, { need = 100 })
        assert.is_nil(next(small.families))
        -- the parent pays the template, three sequence formers, six references, and the nested family once
        assert.equals(A.size(F.template.body) + 1 + 3 + 6 + fam.kinds.h.dl, F.dl)
        assert.is_true(F.dl < F.flat)
        for _, I in ipairs { a, b, c } do assert.is_true(A.match(F.template, I, F.env).ok) end
        -- with positional generalize a TERM hole never holds nodes of one kind (same-kind nodes are
        -- descended into), so the term branch is reached only where generalize refuses to align
        -- the depth bound: at depth 0 nothing nests
        local F0 = A.fold({ a, b, c }, { need = 100, depth = 0 })
        assert.is_nil(next(F0.families)); assert.equals(F0.flat, F0.dl)
        -- rule utility at the hedge: one element of a kind is no family
        local G1 = A.fold({ g(h(1), node('k', lit 'x')), g(h(2)) }, { need = 100 })
        local fam1 = G1.families[next(G1.families) or '']
        assert.is_true(fam1 == nil or fam1.kinds.k == nil)
    end)

    it('the seven callbacks fold to two leaf holes: nothing nests and the description length is the flat one', function()
        local F = fixture(); if not F then return end
        local six = {}
        for _, m in ipairs(F.members) do if m.line ~= 84 then six[#six + 1] = m.term end end
        local Fd = A.fold(six, { need = 100 })
        assert.is_nil(next(Fd.families)); assert.equals(Fd.flat, Fd.dl)
        assert.same({ 'h1', 'h2' }, (function() local n = A.hole_names(Fd.template); table.sort(n); return n end)())
    end)

    it('the 14 cmd statements of commands/analysis.lua: the block hedge nests its statements by kind, raw > flat > nested, members unfold byte-exact', function()
        local F = fixture(); if not F then return end
        local statements = {}
        for _, p in ipairs(A.positions(F.analysis.term)) do
            if p.node.k == 'function_call' and A.cst_print(p.node):sub(1, 4) == 'cmd(' then statements[#statements + 1] = p.node end
        end
        assert.equals(14, #statements)
        for _, cost in ipairs { A.size, A.text_size } do
            local raw = 0
            for _, s in ipairs(statements) do raw = raw + cost(s) + 1 end
            local Fd = A.fold(statements, { need = 100, cost = cost })
            assert.is_true(Fd.flat < raw, 'flat below raw')
            assert.is_true(Fd.dl < Fd.flat, 'nested below flat')
            -- the callback body is a hedge over block statements; its if_statement and function_call elements each form a family
            -- ~~one block hedge with 14 or more if statements~~ since LCSJOIN.md the shared statements
            -- anchor and the block is two hedges; the if statements and calls are spread over them
            local ifs, calls = 0, false
            for _, f in pairs(Fd.families) do
                if f.kinds and f.kinds.if_statement then ifs = ifs + #f.kinds.if_statement.members end
                if f.kinds and f.kinds.function_call then calls = true end
            end
            assert.is_true(ifs >= 14, 'nested families of if statements'); assert.is_true(calls)
            assert.is_nil(next(A.fold(statements, { need = 100, cost = cost, depth = 0 }).families))
            for i, s in ipairs(statements) do
                assert.equals(A.cst_print(s), A.cst_print(A.instantiate(Fd.template, Fd.values[i], Fd.env).term))
            end
        end
    end)

    it('MDL partition of the 14 callbacks finds the six report callbacks as one family, and partition-then-fold is shorter still', function()
        local F = fixture(); if not F then return end
        local callbacks = {}
        for _, p in ipairs(A.positions(F.analysis.term)) do
            if p.node.k == 'function_call' and A.cst_print(p.node):sub(1, 4) == 'cmd(' then
                for _, q in ipairs(A.positions(p.node)) do if q.node.k == 'function_definition' then callbacks[#callbacks + 1] = q.node; break end end
            end
        end
        assert.equals(14, #callbacks)
        local one = A.fold(callbacks, { need = 100 })
        local P = A.partition(callbacks, { need = 100 })
        local sizes = {}
        for _, fam in ipairs(P.families) do sizes[#sizes + 1] = #(fam.members or fam.instances or {}) end
        table.sort(sizes, function(x, y) return x > y end)
        assert.equals(6, sizes[1])
        local total = 0
        for _, fam in ipairs(P.families) do
            local insts = {}
            for _, i in ipairs(fam.members or fam.instances or {}) do insts[#insts + 1] = callbacks[i] end
            if #insts >= 2 then total = total + A.fold(insts, { need = 100 }).dl else total = total + A.size(insts[1]) + 1 end
        end
        assert.is_true(total < one.dl); assert.is_true(one.dl < one.flat)
    end)
end)

describe('shotgun surgery from a template (SURGERY.md; Toomim, Begel, Graham 2004: linked editing)', function()
    local A = require 'algebra'
    local okf, FX = pcall(dofile, 'experiments/lua-terms-2026-09-18.lua')
    local function fixture() if not okf then return pending('experiments/lua-terms-2026-09-18.lua not loadable: ' .. tostring(FX)) end return FX end
    local function id(s) return A.node('identifier', A.lit(s)) end
    local function call(fn, ...)
        local kids = { A.lit '(' }
        for i, a in ipairs({ ... }) do if i > 1 then kids[#kids + 1] = A.lit ', ' end; kids[#kids + 1] = a end
        kids[#kids + 1] = A.lit ')'
        return A.node('function_call', id(fn), A.node('arguments', unpack(kids)))
    end
    local function find(body, pred) for _, p in ipairs(A.positions(body)) do if pred(p.node) then return p.path, p.node end end end
    local function copy(V) local W = {}; for h, v in pairs(V) do W[h] = v end; return W end
    -- Figure 1 of the paper: wake() and wakeAll(), alike but for an `if` where the other has a `while`
    local function method(name, loop)
        return A.node('method', A.lit 'void ', A.node('identifier', A.lit(name)), A.lit '() {\n  ',
            A.node('block', A.node('statement', A.lit 'lock();'), A.lit '\n  ',
                A.node(loop, A.lit(loop .. ' ('), A.lit 'waiting', A.lit ') ', A.lit 'notify();'), A.lit '\n  ',
                A.node('statement', A.lit 'unlock();')),
            A.lit '\n}')
    end
    local function family() local g = A.generalize({ method('wake', 'if'), method('wakeAll', 'while') }, { need = 100 }); return g.template, g.values end
    local function six()
        local F = fixture(); if not F then return end
        local ms, insts = {}, {}
        for _, m in ipairs(F.members) do if m.line ~= 84 then ms[#ms + 1] = m; insts[#insts + 1] = m.term end end
        local g = A.generalize(insts, { need = 100 })
        return g.template, g.values, ms
    end

    it('spans: every position of the whole-file term lies where cst_print puts it', function()
        local F = fixture(); if not F then return end
        local S, X = A.spans(F.analysis.term)
        assert.equals(F.analysis.source, X)
        for _, p in ipairs(A.positions(F.analysis.term)) do
            local s = S[A.key(p.path)]
            assert.equals(A.cst_print(p.node), X:sub(s.from, s.to))
        end
        local S2 = A.spans(A.node('x', A.lit 'ab', A.node('empty'), A.name 'n'))
        assert.same({ from = 3, to = 2 }, S2['2']) -- an empty node sits between its neighbours
        assert.same({ from = 3, to = 3 }, S2['3'])
        assert.has_error(function() A.spans(A.node('x', A.hole 'h')) end)
    end)

    it('Figure 1: linking wake() and wakeAll() finds the name and the loop statement; the loop is one hole, coarser than the paper\'s LCS', function()
        local T, V = family()
        local names = A.hole_names(T)
        assert.equals(2, #names)
        local kinds = {}
        for _, h in ipairs(names) do kinds[V[1][h].k] = true end
        assert.is_true(kinds.lit) -- the name
        assert.is_true(kinds['if']) -- the whole statement: positional generalize does not align an `if` node with a `while` node
        assert.equals('void wake() {\n  lock();\n  if (waiting) notify();\n  unlock();\n}', A.cst_print(A.instantiate(T, V[1]).term))
        assert.equals(0, #A.hunks(T, V[1])) -- no edit, no surgery
    end)

    it('Figure 2.1: a line typed in one clone lands in every clone, at each clone\'s own offset (a template edit)', function()
        local T, V = family()
        local bp, bn = find(T.body, function(n) return n.k == 'block' end)
        local kids = {}
        for i, c in ipairs(bn.kids) do kids[#kids + 1] = c; if i == 1 then kids[#kids + 1] = A.lit '\n  '; kids[#kids + 1] = A.node('statement', A.lit 'log("wake");') end end
        local T2 = assert(A.rewrite(T, bp, A.rebuild(bn, kids)))
        local hs1, new1 = A.hunks(T, V[1], T2)
        local hs2, new2 = A.hunks(T, V[2], T2)
        assert.equals(1, #hs1); assert.equals(1, #hs2)
        assert.equals('', hs1[1].old); assert.matches('log%("wake"%);', hs1[1].new) -- the gap it takes with it is the LCS tie-break
        assert.equals(hs1[1].new, hs2[1].new)
        assert.equals('template', hs1[1].src); assert.equals(1, hs1[1].edit)
        assert.equals(hs1[1].from + 3, hs2[1].from) -- wakeAll is three bytes longer than wake
        assert.equals(hs1[1].from - 1, hs1[1].to) -- an insertion
        assert.equals(new1, A.apply_hunks(A.cst_print(A.instantiate(T, V[1]).term), hs1))
        assert.equals(new2, A.apply_hunks(A.cst_print(A.instantiate(T, V[2]).term), hs2))
        assert.equals('void wake() {\n  lock();\n  log("wake");\n  if (waiting) notify();\n  unlock();\n}', new1)
    end)

    it('Figure 2.2: a change to one clone alone is a value edit: one hunk in that member, none in the other', function()
        local T, V = family()
        local h
        for _, g in ipairs(A.hole_names(T)) do if V[1][g].k == 'lit' then h = g end end
        local V2 = copy(V[1]); V2[h] = A.lit 'wakeOne'
        local hs, new = A.hunks(T, V[1], T, V2)
        assert.equals(1, #hs)
        assert.equals('wake', hs[1].old); assert.equals('wakeOne', hs[1].new)
        assert.equals('value', hs[1].src); assert.equals(h, hs[1].hole); assert.is_nil(hs[1].edit)
        assert.equals(new, A.apply_hunks(A.cst_print(A.instantiate(T, V[1]).term), hs))
        assert.equals(0, #A.hunks(T, V[2], T, V[2]))
    end)

    it('Figure 2.3: deleting a line in one clone is a dig and an empty value: a deletion hunk there, nothing elsewhere', function()
        local T, V = family()
        local sp = find(T.body, function(n) return n.k == 'statement' and n.kids[1].v == 'lock();' end)
        local T2 = assert(A.dig(T, sp, 'lock'))
        local V1 = copy(V[1]); V1.lock = A.seq {}
        local hs, new = A.hunks(T, V[1], T2, V1)
        assert.equals(1, #hs)
        assert.equals('lock();', hs[1].old); assert.equals('', hs[1].new)
        assert.equals('value', hs[1].src); assert.equals('lock', hs[1].hole); assert.equals(1, hs[1].edit)
        assert.equals(new, A.apply_hunks(A.cst_print(A.instantiate(T, V[1]).term), hs))
        local V2 = copy(V[2]); V2.lock = A.locate_at(T.body, sp)
        assert.equals(0, #A.hunks(T, V[2], T2, V2)) -- the dig alone is a crease, not a cut
    end)

    it('crease-only edits make no hunks: dig, split, pin and open leave every member\'s sheet as it was', function()
        local g = A.generalize({ A.node('f', A.lit 'a', A.lit '+', A.lit 'a'), A.node('f', A.lit 'b', A.lit '+', A.lit 'b') }, { need = 100 })
        local T, V = g.template, g.values
        local h = A.hole_names(T)[1]
        assert.equals(2, #A.sites(T)[h].sites) -- Plotkin's rule: one hole, two sites
        local Ts = assert(A.split(T, h, 2, 'h2'))
        local Vs = copy(V[1]); Vs.h2 = V[1][h]
        assert.equals(0, #A.hunks(T, V[1], Ts, Vs))
        local Tp = assert(A.pin(T, h, A.lit 'a')) -- the pinned hole still takes its one value
        assert.equals(0, #A.hunks(T, V[1], Tp, V[1]))
        local To = assert(A.open_hole(Tp, h))
        assert.equals(0, #A.hunks(Tp, V[1], To, V[1]))
        local Td = assert(A.dig(T, { 2 }, 'op'))
        local Vd = copy(V[1]); Vd.op = A.lit '+'
        assert.equals(0, #A.hunks(T, V[1], Td, Vd))
    end)

    it('applying hunks refuses a sheet that moved, by name, and overlapping hunks', function()
        local T, V = family()
        local h
        for _, g in ipairs(A.hole_names(T)) do if V[1][g].k == 'lit' then h = g end end
        local V2 = copy(V[1]); V2[h] = A.lit 'wakeOne'
        local hs = A.hunks(T, V[1], T, V2)
        local text = A.cst_print(A.instantiate(T, V[1]).term)
        local ok, why = A.apply_hunks(text:gsub('wake', 'sleep'), hs)
        assert.is_nil(ok); assert.matches('expected "wake", the sheet holds "slee"', why, 1, true)
        local ok2, why2 = A.apply_hunks(text, { { from = 6, to = 9, old = 'wake', new = 'x' }, { from = 8, to = 12, old = 'ke() ', new = 'y' } })
        assert.is_nil(ok2); assert.matches('overlaps', why2)
        assert.equals(text, A.apply_hunks(text, {}))
    end)

    it('the refinement is an LCS over kids: two edits in one list are two hunks, an insertion and a leaf', function()
        local T, V, ms = six(); if not T then return end
        local bp, bn = find(T.body, function(n) return n.k == 'block' end)
        local kids = {}
        for i, c in ipairs(bn.kids) do kids[#kids + 1] = c; if i == 4 then kids[#kids + 1] = call('assert', id 'store'); kids[#kids + 1] = A.lit '\n        ' end end
        local T2 = assert(A.rewrite(T, bp, A.rebuild(bn, kids)))
        local wp = find(T2.body, function(n) return n.k == 'identifier' and n.kids[1].v == 'WARN' end)
        local T3 = assert(A.rewrite(T2, wp, id 'ERROR'))
        for i = 1, #ms do
            local hs, new = A.hunks(T, V[i], T3)
            assert.equals(2, #hs)
            assert.equals('', hs[1].old); assert.equals('assert(store)\n        ', hs[1].new); assert.equals(1, hs[1].edit)
            assert.equals('WARN', hs[2].old); assert.equals('ERROR', hs[2].new); assert.equals(2, hs[2].edit)
            assert.equals('template', hs[1].src); assert.equals('template', hs[2].src)
            assert.equals(new, A.apply_hunks(ms[i].source, hs))
            assert.is_truthy(loadstring(new))
        end
    end)

    it('the first fold\'s edit as surgery: WARN to ERROR is one four-byte hunk in each of the six, and the refold gives the edited crease pattern', function()
        local T, V, ms = six(); if not T then return end
        local wp = find(T.body, function(n) return n.k == 'identifier' and n.kids[1].v == 'WARN' end)
        local T2 = assert(A.rewrite(T, wp, id 'ERROR'))
        local news = {}
        for i = 1, #ms do
            local hs, new = A.hunks(T, V[i], T2)
            assert.equals(1, #hs)
            assert.equals('WARN', hs[1].old); assert.equals('ERROR', hs[1].new); assert.equals('template', hs[1].src)
            assert.equals(4, hs[1].to - hs[1].from + 1)
            assert.equals(new, A.apply_hunks(ms[i].source, hs))
            assert.equals(A.cst_print(A.instantiate(T2, V[i]).term), new)
            news[i] = A.instantiate(T2, V[i]).term
        end
        -- the paper's guarantee: the common regions stay identical after a simultaneous edit
        local g2 = A.generalize(news, { need = 100 })
        assert.is_true(A.instance_of(g2.template, T2))
        assert.is_true(A.instance_of(T2, g2.template))
    end)

    it('a hunk behind a hedge lands at each member\'s own offset: the 14 command statements, then the whole file', function()
        local F = fixture(); if not F then return end
        local st, paths = {}, {}
        for _, p in ipairs(A.positions(F.analysis.term)) do
            if p.node.k == 'function_call' and A.cst_print(p.node):sub(1, 4) == 'cmd(' then st[#st + 1] = p.node; paths[#paths + 1] = p.path end
        end
        assert.equals(14, #st)
        local g = A.generalize(st, { need = 100 })
        local T = g.template
        local up = find(T.body, function(n) return n.k == 'unary_expression' and A.cst_print(n) == 'not store' end)
        assert.is_truthy(up)
        local hedge_before = false -- the parameters hedge precedes the guard in preorder
        for h, e in pairs(A.sites(T)) do if e.rep and A.key(e.sites[1].path) < A.key(up) then hedge_before = true end end
        assert.is_true(hedge_before)
        local T2 = assert(A.rewrite(T, up, A.node('binary_expression', id 'store', A.lit ' ', A.lit '==', A.lit ' ', A.node('nil', A.lit 'nil'))))
        local SF = A.spans(F.analysis.term)
        local file_hunks, whole = {}, {}
        local offsets = {}
        for i = 1, 14 do
            local hs, new = A.hunks(T, g.values[i], T2)
            assert.equals(1, #hs)
            assert.equals('not store', hs[1].old); assert.equals('store == nil', hs[1].new); assert.equals('template', hs[1].src)
            assert.equals(new, A.apply_hunks(A.cst_print(st[i]), hs))
            offsets[hs[1].from] = true
            local s = SF[A.key(paths[i])]
            for _, h in ipairs(A.shift_hunks(hs, s.from - 1)) do file_hunks[#file_hunks + 1] = h end
            whole[#whole + 1] = { from = s.from, to = s.to, old = A.cst_print(st[i]), new = new }
        end
        local n = 0; for _ in pairs(offsets) do n = n + 1 end
        assert.is_true(n > 1) -- `function (o)` members put the guard further in
        local patched = assert(A.apply_hunks(F.analysis.source, file_hunks))
        assert.equals(assert(A.apply_hunks(F.analysis.source, whole)), patched) -- the surgery equals the whole re-instantiation
        assert.is_truthy(loadstring(patched))
        assert.equals(#F.analysis.source + 14 * 3, #patched)
    end)

    it('the surgery reaches the family\'s sites only: renaming mat_df covers 6 of the file\'s 11 occurrences', function()
        local T, V, ms = six(); if not T then return end
        local F = fixture()
        local mp = find(T.body, function(n) return n.k == 'identifier' and n.kids[1].v == 'mat_df' end)
        local T2 = assert(A.rewrite(T, mp, id 'material_df'))
        local total = 0
        for i = 1, #ms do local hs = A.hunks(T, V[i], T2); total = total + #hs; assert.equals('mat_df', hs[1].old) end
        local _, n = F.analysis.source:gsub('mat_df', '')
        assert.equals(6, total); assert.equals(11, n)
    end)

    it('a value the domain refuses is named in the refusal, not silently unfolded', function()
        local T, V, ms = six(); if not T then return end
        local V2 = copy(V[1])
        local h = A.hole_names(T)[1]
        V2[h] = A.node('identifier', A.lit 'x') -- the hole holds a literal, not a node
        local hs, why = A.hunks(T, V[1], T, V2)
        assert.is_nil(hs); assert.matches('^after: rejected ' .. h, why)
    end)

    it('a value edit inside a hedge is the element\'s own hunk, attributed to the hedge, behind the fixed kid before it', function()
        local w = function(s) local ks = {}; for c in s:gmatch('%S+') do ks[#ks + 1] = A.lit(c .. ' ') end; return A.node('w', unpack(ks)) end
        local g = A.generalize({ w 'x a b c y', w 'x a y', w 'x a b y' }, { need = 100 })
        local T, V = g.template, g.values
        local h
        for _, n in ipairs(A.hole_names(T)) do if T.holes[n].rep then h = n end end
        assert.is_truthy(h)
        local V2 = copy(V[1])
        local kids = {}
        for i, k in ipairs(V[1][h].kids) do kids[i] = k end
        kids[2] = A.lit 'q '
        V2[h] = A.seq(kids)
        local hs, new = A.hunks(T, V[1], T, V2)
        assert.equals(1, #hs)
        assert.equals('c ', hs[1].old); assert.equals('q ', hs[1].new) -- `a` is fixed in every member, the hedge is `b c`
        assert.equals('value', hs[1].src); assert.equals(h, hs[1].hole)
        assert.equals(new, A.apply_hunks('x a b c y ', hs))
        assert.equals('x a b q y ', new)
        assert.equals(0, #A.hunks(T, V[2], T, V[2]))
    end)

    it('the first element added to an empty hedge is an insertion attributed from the new side', function()
        local w = function(s) local ks = {}; for c in s:gmatch('%S+') do ks[#ks + 1] = A.lit(c .. ' ') end; return A.node('w', unpack(ks)) end
        local g = A.generalize({ w 'x a b c y', w 'x a y', w 'x a b y' }, { need = 100 })
        local T, V = g.template, g.values
        local h
        for _, n in ipairs(A.hole_names(T)) do if T.holes[n].rep then h = n end end
        assert.equals(0, #V[2][h].kids)
        local V2 = copy(V[2]); V2[h] = A.seq { A.lit 'b ' }
        local hs, new = A.hunks(T, V[2], T, V2)
        assert.equals(1, #hs)
        assert.equals('', hs[1].old); assert.equals('b ', hs[1].new)
        assert.equals('value', hs[1].src); assert.equals(h, hs[1].hole)
        assert.equals('x a b y ', new)
        assert.equals(new, A.apply_hunks('x a y ', hs))
    end)
end)

describe('a query template with hedges as the instance (a fix after SURGERY.md): instance_of is reflexive and reads the hedge domains', function()
    local A = require 'algebra'
    local okf, FX = pcall(dofile, 'experiments/lua-terms-2026-09-18.lua')
    local function fixture() if not okf then return pending('experiments/lua-terms-2026-09-18.lua not loadable: ' .. tostring(FX)) end return FX end
    local function w(s) local ks = {}; for c in s:gmatch('%S+') do ks[#ks + 1] = A.lit(c) end; return A.node('w', unpack(ks)) end
    local function hedged(D, extra) -- (w x ?h... y), optionally with a plain kid beside the hedge
        local kids = { A.lit 'x', A.hole('h', true) }
        if extra then kids[#kids + 1] = extra end
        kids[#kids + 1] = A.lit 'y'
        return A.template(A.node('w', unpack(kids)), { h = D })
    end
    local function why(T1, T2) local m = A.match(T2, T1.body, { hole_domains = T1.holes }); return m.ok, m.refusal and m.refusal.why end

    it('a hedge template is an instance of itself: the toy and the 14 command statements', function()
        local g = A.generalize({ w 'x a b y', w 'x a y' }, { need = 100 })
        assert.is_true(A.instance_of(g.template, g.template))
        local F = fixture(); if not F then return end
        local st = {}
        for _, p in ipairs(A.positions(F.analysis.term)) do if p.node.k == 'function_call' and A.cst_print(p.node):sub(1, 4) == 'cmd(' then st[#st + 1] = p.node end end
        local T = A.generalize(st, { need = 100 }).template
        assert.is_true(A.instance_of(T, T))
    end)

    it('subsumption reads the hedge domains: a narrower repetition is an instance of a wider one, not the reverse', function()
        local narrow = hedged(A.rep(A.kinds { 'lit' }))
        local wide = hedged(A.rep(A.kinds { 'lit', 's' }))
        assert.is_true(A.instance_of(narrow, wide))
        local ok, r = why(wide, narrow)
        assert.is_false(ok); assert.matches('does not entail', r)
        assert.is_true(A.entails(A.rep(A.kinds { 'lit' }), A.rep(A.kinds { 'lit', 's' })))
        assert.is_false(A.entails(A.rep(A.kinds { 'lit', 's' }), A.rep(A.kinds { 'lit' })))
    end)

    it('the lengths a hedge variable allows are counted against the bounds, plain elements included', function()
        local at_least_two = hedged(A.rep(A.kinds { 'lit' }, 2))
        assert.is_false(A.instance_of(hedged(A.rep(A.kinds { 'lit' }, 0), A.lit 'a'), at_least_two)) -- one plain kid plus a possibly empty hedge
        assert.is_true(A.instance_of(hedged(A.rep(A.kinds { 'lit' }, 1), A.lit 'a'), at_least_two)) -- one plain kid plus at least one
        local ok, r = why(hedged(A.rep(A.kinds { 'lit' }, 0), A.lit 'a'), at_least_two)
        assert.is_false(ok); assert.matches('count at least 1, below {2,}', r, 1, true)
        local at_most_two = hedged(A.rep(A.kinds { 'lit' }, 0, 2))
        assert.is_false(A.instance_of(hedged(A.rep(A.kinds { 'lit' }, 0)), at_most_two))
        assert.is_true(A.instance_of(hedged(A.rep(A.kinds { 'lit' }, 0, 1), A.lit 'a'), at_most_two))
        assert.is_true(A.entails(A.rep(A.kinds { 'lit' }, 1, 1), A.rep(A.kinds { 'lit' }, 0, 2)))
        assert.is_false(A.entails(A.rep(A.kinds { 'lit' }, 0), A.rep(A.kinds { 'lit' }, 0, 2)))
    end)

    it('a period claim is not checked across a hedge variable, and says so; an open hedge admits any variable', function()
        local ok, r = why(hedged(A.rep(A.kinds { 'lit' })), hedged(A.rep(A.kinds { 'lit' }, 0, nil, 2)))
        assert.is_false(ok); assert.matches('period claim', r)
        assert.is_true(A.instance_of(hedged(A.rep(A.kinds { 'lit' })), hedged(A.open())))
        assert.is_false(A.instance_of(hedged(A.open()), hedged(A.rep(A.kinds { 'lit' })))) -- an open variable may hold anything
        local ok2, r2 = why(hedged(A.open()), hedged(A.rep(A.kinds { 'lit' })))
        assert.is_false(ok2); assert.matches('does not entail', r2)
        local ok3 = A.admits_slice(A.rep(A.kinds { 'lit' }), { A.lit 'a' }, {}, {})
        assert.is_true(ok3) -- no variables: plain admits
    end)

    it('a template with a period claim is still an instance of itself: identity before the period refusal', function()
        local insts = { w 'w a 7 a', w 'w a 7 a 8 a', w 'w a 7 a 8 a 9 a' }
        local J, env = A.template(insts[1]), { defs = {} }
        for i = 2, #insts do local r = A.join(J, insts[i], { env = env }); J = r.template; env = r.env or env end
        local values = {}
        for i, I in ipairs(insts) do values[i] = A.match(J, I, { defs = env.defs }).values end
        A.rederive_domains(J, values, { env = env })
        local h = A.hole_names(J)[1]
        assert.equals(2, J.holes[h].domain.period) -- the fold of join claims the unit with its period (REPETITION.md)
        assert.is_true(A.instance_of(J, J, env))
        local with_kid = A.template(A.node('w', A.lit 'w', A.lit 'a', A.lit '7', A.lit 'a', A.hole('q', true), A.lit 'b'), { q = J.holes[h].domain })
        local m = A.match(J, with_kid.body, { defs = env.defs, hole_domains = with_kid.holes })
        assert.is_false(m.ok); assert.matches('period claim', m.refusal.why)
    end)
end)

describe('the LCS inside join (LCSJOIN.md; Myers 1986: traces, the LCS and the shortest edit script)', function()
    local A = require 'algebra'
    local okf, FX = pcall(dofile, 'experiments/lua-terms-2026-09-18.lua')
    local function fixture() if not okf then return pending('experiments/lua-terms-2026-09-18.lua not loadable: ' .. tostring(FX)) end return FX end
    local lit, node, name = A.lit, A.node, A.name
    local function w(s) local ks = {}; for c in s:gmatch('%S+') do ks[#ks + 1] = lit(c) end; return node('w', unpack(ks)) end
    local function letters(s) local t = {}; for c in s:gmatch('.') do t[#t + 1] = lit(c) end; return t end
    local function H(h) return A.hole(h, true) end
    local function values(T, I) local m = A.match(T, I); assert.is_true(m.ok, m.refusal and m.refusal.why); return m.values end

    it('Myers Figure 1: abcabba against cbabac has an LCS of length 4 and a shortest edit script of length 5', function()
        local P = A.lcs(letters 'abcabba', letters 'cbabac')
        assert.equals(4, #P)
        local a, b = {}, {}
        for _, pr in ipairs(P) do a[#a + 1] = ('abcabba'):sub(pr[1], pr[1]); b[#b + 1] = ('cbabac'):sub(pr[2], pr[2]) end
        assert.equals(table.concat(a), table.concat(b)) -- a trace: a common subsequence
        for k = 2, #P do assert.is_true(P[k][1] > P[k - 1][1] and P[k][2] > P[k - 1][2]) end
        assert.equals(5, 7 + 6 - 2 * #P) -- D = N + M - 2L (the paper's 1D 2D 3IB 6D 7IC)
        assert.equals('cbba', table.concat(a)) -- this prototype's tie-break: the earliest match on both sides
        assert.same({}, A.lcs(letters 'abc', letters 'xyz'))
    end)

    it('join anchors the common kids: a changed kid is a term hole, an extra one an insertion hedge, in one list', function()
        local r = A.join(A.template(w 'x a b y'), w 'x c b d y')
        assert.equals('(w "x" ?j1 "b" ?j2... "y")', A.show(r.template.body))
        assert.same({ 'j1', 'j2' }, r.new)
        assert.equals('(seq)', A.show(values(r.template, w 'x a b y').j2))
        assert.equals('(seq "d")', A.show(values(r.template, w 'x c b d y').j2))
        -- the identical-ends rule is the case with no anchor inside
        assert.equals('(w "x" "a" ?j1...)', A.show(A.join(A.template(w 'x a'), w 'x a b c').template.body))
        assert.equals('?j1', A.show(A.join(w 'x a', w 'x a b c', { align = 'none' }).template.body)) -- the rigidity stands
    end)

    it('the forced rule with k hedges places each fixed segment at its leftmost fit, which is the matchers\' first solution', function()
        local T = A.template(node('f', H 'A', lit 'm', H 'B', lit 'z'))
        local I = node('f', lit '1', lit '2', lit 'm', lit '3', lit 'z')
        local r = A.join(T, I)
        assert.equals('(f ?A... "m" ?B... "z")', A.show(r.template.body)); assert.same({}, r.new)
        local W, W2 = values(r.template, I), A.match(T, I).values
        assert.equals(A.show(W2.A), A.show(W.A)); assert.equals(A.show(W2.B), A.show(W.B))
        local T3 = A.template(node('f', H 'A', lit 'm', H 'B'))
        local I3 = node('f', lit 'm', lit 'm', lit 'm')
        local r3 = A.join(T3, I3)
        assert.equals('(seq)', A.show(r3.frags.A.right)) -- join's own placement: leftmost hedge shortest, A empty, B takes m m
        assert.equals('(seq "m" "m")', A.show(r3.frags.B.right))
        assert.equals('(seq)', A.show(values(r3.template, I3).A))
        assert.equals('(seq)', A.show(A.match(T3, I3).values.A))
        -- a segment with a term hole inside fits any kid there
        local T4 = A.template(node('f', H 'A', node('g', A.hole 'p'), H 'B'))
        local r4 = A.join(T4, node('f', lit '1', node('g', lit 'q'), lit '2'))
        assert.equals('(f ?A... (g ?p) ?B...)', A.show(r4.template.body)); assert.same({}, r4.new)
    end)

    it('when no placement fits, the hedges are swallowed by the run they lie in and reported absorbed', function()
        local T = A.template(node('f', H 'A', lit 'm', H 'B', lit 'z'))
        local I = node('f', lit '1', lit 'q', lit '3', lit 'z')
        local r = A.join(T, I)
        assert.equals('(f ?j1... "z")', A.show(r.template.body))
        assert.same({ 'j1' }, r.new)
        assert.equals(2, #r.absorbed)
        assert.is_true(A.match(r.template, I).ok)
        assert.is_true(A.match(r.template, node('f', lit 'a', lit 'm', lit 'b', lit 'z')).ok)
    end)

    it('both sides hedged with the same shape align hedge against hedge; a node with holes anchors by fit, a bare hole never', function()
        local r = A.join(A.template(node('f', lit 'a', H 'X', lit 'z')), A.template(node('f', lit 'a', H 'Y', lit 'z')))
        assert.equals('(f "a" ?X... "z")', A.show(r.template.body))
        local r2 = A.join(A.template(node('f', node('g', A.hole 'h'), lit 'a')), node('f', lit 'x', node('g', lit 'y'), lit 'a'))
        assert.equals('(f ?j1... (g ?h) "a")', A.show(r2.template.body)) -- the node with a hole inside anchors by fit; x is the insertion
        local r3 = A.join(A.template(node('f', A.hole 'h', lit 'a')), node('f', lit 'x', lit 'y', lit 'a'))
        assert.equals('(f ?j1... "a")', A.show(r3.template.body)) -- a bare hole never anchors: absorbed, as HEDGEJOIN.md had it
    end)

    it('generalize anchors n members: a common subsequence intersected member by member', function()
        local g = A.generalize({ w 'x a b y', w 'x c b d y', w 'x f b y' }, { need = 100 })
        assert.equals('(w "x" ?h1 "b" ?h2... "y")', A.show(g.template.body))
        assert.equals('(seq "d")', A.show(g.values[2].h2)); assert.equals('(seq)', A.show(g.values[3].h2))
        local g2 = A.generalize({ w 'x a b y', w 'x c b d y', w 'x e y' }, { need = 100 })
        assert.equals('(w "x" ?h1... "y")', A.show(g2.template.body)) -- b is not in the third member: no anchor inside
        -- the order dependence the intersection has: the same three members, another order, the same anchors here
        local g3 = A.generalize({ w 'x e y', w 'x c b d y', w 'x a b y' }, { need = 100 })
        assert.equals('(w "x" ?h1... "y")', A.show(g3.template.body))
        for _, G in ipairs { g, g2, g3 } do
            for i, V in ipairs(G.values) do assert.is_truthy(A.instantiate(G.template, V, G.env).ok, 'member ' .. i) end
        end
    end)

    it('the repetition families keep their claims: anchors at the ends only', function()
        local g = A.generalize({ w 'w a b', w 'w a b a b', w 'w a b a b a b' }, { need = 3 })
        assert.equals('(w "w" "a" "b" ?h1...)', A.show(g.template.body))
        assert.equals(2, g.notes.h1.period)
        local g4 = A.generalize({ w 'a 7 a', w 'a 7 a 8 a', w 'a 7 a 8 a 9 a' }, { need = 3 })
        assert.equals('(w "a" "7" "a" ?h1...)', A.show(g4.template.body)); assert.equals(2, g4.notes.h1.period)
    end)

    it('the seventh callback joins over the one missing line (READER.md had one hedge over three statements)', function()
        local F = fixture(); if not F then return end
        local six, seventh = {}, nil
        for _, m in ipairs(F.members) do if m.line ~= 84 then six[#six + 1] = m.term else seventh = m.term end end
        local g = A.generalize(six, { need = 100 })
        local j = A.join(g.template, seventh, { env = g.env })
        assert.same({ 'j1' }, j.new)
        local f = j.frags.j1
        assert.equals(2, #f.left.kids); assert.equals(0, #f.right.kids)
        assert.equals('mat_df(store, n.file)', A.cst_print(f.left.kids[1]))
        for _, m in ipairs(F.members) do assert.is_true(A.match(j.template, m.term, { defs = g.env.defs }).ok) end
    end)

    it('the 14 statements: the shared guard anchors, the block is two hedges, every member unfolds and the template is an instance of itself', function()
        local F = fixture(); if not F then return end
        local st = {}
        for _, p in ipairs(A.positions(F.analysis.term)) do if p.node.k == 'function_call' and A.cst_print(p.node):sub(1, 4) == 'cmd(' then st[#st + 1] = p.node end end
        local g = A.generalize(st, { need = 100 })
        local hedges = 0
        for _, e in pairs(g.template.holes) do if e.rep then hedges = hedges + 1 end end
        assert.equals(7, #A.hole_names(g.template)); assert.equals(4, hedges) -- FOLD.md's ends rule gave 4 holes, 3 hedges
        for i, s in ipairs(st) do assert.equals(A.cst_print(s), A.cst_print(A.instantiate(g.template, g.values[i], g.env).term)) end
        assert.is_true(A.instance_of(g.template, g.template, g.env))
    end)
end)

describe('classify from hunks (CLASSIFY.md): an edit on one member read through attributed hunks, hedges included', function()
    local A = require 'algebra'
    local okf, FX = pcall(dofile, 'experiments/lua-terms-2026-09-18.lua')
    local function fixture() if not okf then return pending('experiments/lua-terms-2026-09-18.lua not loadable: ' .. tostring(FX)) end return FX end
    local lit, node, hole = A.lit, A.node, A.hole
    local function w(s) local ks = {}; for c in s:gmatch('%S+') do ks[#ks + 1] = lit(c) end; return node('w', unpack(ks)) end
    local function family() local g = A.generalize({ w 'x a b c y', w 'x a y', w 'x a b y' }, { need = 100 }); return g.template, g.values end
    local function rebuilds(C, I2) local r = A.instantiate(C.template, C.values); return r.ok and A.eq(r.term, I2) end
    local function id(s) return node('identifier', lit(s)) end

    it('an edit inside a hedge is a value edit of the hedge: an element replaced, one inserted, the slice emptied', function()
        local T, V = family()
        assert.equals('(w "x" "a" ?h1... "y")', A.show(T.body))
        local C = A.classify(T, V[1], w 'x a b q y')
        assert.equals('value', C.kind); assert.equals('(seq "b" "q")', A.show(C.changed[1].to)); assert.is_true(rebuilds(C, w 'x a b q y'))
        local C2 = A.classify(T, V[1], w 'x a b z c y')
        assert.equals('value', C2.kind); assert.equals('(seq "b" "z" "c")', A.show(C2.values.h1))
        local C3 = A.classify(T, V[1], w 'x a y')
        assert.equals('value', C3.kind); assert.equals('(seq)', A.show(C3.values.h1))
        assert.equals(0, #C.regions); assert.equals(0, #C.relocated)
        local P = A.propagate(T, C, V, 1)
        assert.same({ 1 }, P.values.holes[1].class) -- only the witness held (b c)
    end)

    it('an insertion touching a hedge boundary belongs to the hedge, on either side; an empty hedge takes its first element', function()
        local T, V = family()
        assert.equals('(seq "z" "b" "c")', A.show(A.classify(T, V[1], w 'x a z b c y').values.h1))
        assert.equals('(seq "b" "c" "z")', A.show(A.classify(T, V[1], w 'x a b c z y').values.h1))
        local C = A.classify(T, V[2], w 'x a q y')
        assert.equals('value', C.kind); assert.equals('(seq "q")', A.show(C.values.h1))
        assert.is_true(rebuilds(C, w 'x a q y'))
    end)

    it('a fixed kid changed or added in a list that holds a hedge is a template edit: a rewrite carrying the template\'s own hedge', function()
        local T, V = family()
        local C = A.classify(T, V[1], w 'x q b c y')
        assert.equals('template', C.kind); assert.same({ { 2 } }, C.regions) -- template coordinates
        assert.equals('(w "x" "q" ?h1... "y")', A.show(C.template.body))
        assert.equals('rewrite', C.template.edits[#C.template.edits].op)
        local P = A.propagate(T, C, V, 1)
        assert.same({ 1, 2, 3 }, P.template.clean)
        assert.equals('(w "x" "q" "b" "y")', A.show(P.template.preview(3)))
        local C2 = A.classify(T, V[2], w 'x a y z')
        assert.equals('template', C2.kind); assert.same({ {} }, C2.regions)
        assert.equals('(w "x" "a" ?h1... "y" "z")', A.show(C2.template.body))
        assert.is_true(rebuilds(C2, w 'x a y z'))
        local C3 = A.classify(T, V[1], w 'w x a b c y')
        assert.equals('(w "w" "x" "a" ?h1... "y")', A.show(C3.template.body))
        assert.equals(1, #C3.relocated); assert.same({ 3 }, C3.relocated[1].from); assert.same({ 4 }, C3.relocated[1].to)
        -- the same rewrite by hand: rewrite admits the template's own hedge and refuses one it lacks
        assert.is_truthy(A.rewrite(T, {}, node('w', lit 'x', lit 'q', hole('h1', true), lit 'y')))
        local bad, why = A.rewrite(T, {}, node('w', lit 'x', hole('h9', true), lit 'y'))
        assert.is_nil(bad); assert.matches('unknown hole', why)
        local bad2, why2 = A.rewrite(A.template(node('w', hole 'p', lit 'y')), {}, node('w', hole('p', true), lit 'y'))
        assert.is_nil(bad2); assert.matches('repetition/context holes not supported', why2)
    end)

    it('an edit that crosses a hedge boundary is a straddle naming the hedge; the store law binds a non-linear hedge', function()
        local T, V = family()
        local C = A.classify(T, V[1], w 'x c y')
        assert.equals('straddle', C.kind); assert.equals('h1', C.hole); assert.matches('crossed the boundary of hedge h1', C.why)
        assert.equals('absent', A.absence_of(C).absence)
        local g = A.generalize({ node('f', node('l', lit 'a', lit 'b'), node('l', lit 'a', lit 'b')), node('f', node('l', lit 'a'), node('l', lit 'a')), node('f', node('l', lit 'a', lit 'b', lit 'c'), node('l', lit 'a', lit 'b', lit 'c')) }, { need = 100 })
        assert.equals('(f (l "a" ?h1...) (l "a" ?h1...))', A.show(g.template.body))
        local one = A.classify(g.template, g.values[1], node('f', node('l', lit 'a', lit 'z'), node('l', lit 'a', lit 'b')))
        assert.equals('straddle', one.kind); assert.equals('split', one.proposal.op); assert.same({ 1 }, one.sites)
        local both = A.classify(g.template, g.values[1], node('f', node('l', lit 'a', lit 'z'), node('l', lit 'a', lit 'z')))
        assert.equals('value', both.kind); assert.equals('(seq "z")', A.show(both.values.h1))
    end)

    it('a list behind a hedge: the region is reported in template coordinates, not the instance\'s', function()
        local T = A.template(node('f', hole('h', true), node('l', lit 'a', lit 'b')))
        local V = { h = A.seq { lit 'x', lit 'y' } }
        local C = A.classify(T, V, node('f', lit 'x', lit 'y', node('l', lit 'a', lit 'b', lit 'c')))
        assert.equals('template', C.kind)
        assert.same({ { 2 } }, C.regions) -- the list sits at instance path 3 behind the two spliced kids
        assert.equals('(f ?h... (l "a" "b" "c"))', A.show(C.template.body))
        assert.is_true(rebuilds(C, node('f', lit 'x', lit 'y', node('l', lit 'a', lit 'b', lit 'c'))))
        local C2 = A.classify(T, V, node('f', lit 'x', lit 'y', node('l', lit 'a', lit 'q')))
        assert.equals('template', C2.kind); assert.same({ { 2, 2 } }, C2.regions)
    end)

    it('trace origins carry the site index and the template path', function()
        local T = A.template(node('f', hole 'x', hole 'x', node('g', hole('r', true))))
        local r = A.trace(T, { x = lit 'a', r = A.seq { lit 'p', lit 'q' } })
        assert.equals(1, r.origins['1'].site); assert.equals(2, r.origins['2'].site)
        assert.same({ 2 }, r.origins['2'].tpath)
        assert.equals(1, r.origins['3/1'].site); assert.equals(1, r.origins['3/2'].site); assert.same({ 3, 1 }, r.origins['3/2'].tpath)
    end)

    it('the 14 command statements: one member edited at the shared guard is a template edit that propagates to all; a changed command name is a value edit', function()
        local F = fixture(); if not F then return end
        local st = {}
        for _, p in ipairs(A.positions(F.analysis.term)) do if p.node.k == 'function_call' and A.cst_print(p.node):sub(1, 4) == 'cmd(' then st[#st + 1] = p.node end end
        local g = A.generalize(st, { need = 100 })
        local T, Vs = g.template, g.values
        local hedges = 0
        for _, e in pairs(T.holes) do if e.rep then hedges = hedges + 1 end end
        assert.equals(4, hedges)
        -- the member's instance edited: the unary `not store` becomes `store == nil` (as SURGERY.md did on the template)
        local up
        for _, p in ipairs(A.positions(st[3])) do if p.node.k == 'unary_expression' and A.cst_print(p.node) == 'not store' then up = p.path end end
        local I2 = A.put(st[3], up, node('binary_expression', id 'store', lit ' ', lit '==', lit ' ', node('nil', lit 'nil')))
        local C = A.classify(T, Vs[3], I2, g.env)
        assert.equals('template', C.kind, C.why)
        assert.equals(1, #C.regions); assert.equals(0, #C.changed)
        assert.is_true(rebuilds(C, I2))
        local P = A.propagate(T, C, Vs, 3, g.env)
        assert.equals(14, #P.template.clean); assert.same({}, P.template.refused)
        for i = 1, 14 do
            local prev = A.cst_print(P.template.preview(i))
            assert.equals(1, select(2, prev:gsub('store == nil', '')))
            assert.equals(A.cst_print(st[i]):gsub('not store', 'store == nil', 1), prev)
        end
        local R = P.template.commit({ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14 })
        assert.equals(14, #R.families[1].values)
        -- the command name is the string_content hole: a value edit, member-local
        local np
        for _, p in ipairs(A.positions(st[3])) do if p.node.k == 'string_content' then np = p.path; break end end
        local I3 = A.put(st[3], np, node('string_content', lit 'CartographExtractBlocksX'))
        local C3 = A.classify(T, Vs[3], I3, g.env)
        assert.equals('value', C3.kind, C3.why); assert.equals(1, #C3.changed)
        local P3 = A.propagate(T, C3, Vs, 3, g.env)
        assert.same({ 3 }, P3.values.holes[1].class)
    end)
end)

describe('cascade: the update rule over a link (CASCADE.md; SQL-92 §11.8 ON UPDATE CASCADE)', function()
    local A = require 'algebra'
    local lit, node, hole = A.lit, A.node, A.hole
    local okf, FX = pcall(dofile, 'experiments/lua-defs-2026-09-18.lua')
    local function fixture() if not okf then return pending('experiments/lua-defs-2026-09-18.lua not loadable: ' .. tostring(FX)) end return FX end
    -- department(id, name) referenced by employee(who, dept)
    local function families()
        local D = { template = A.template(node('dept', hole 'id', hole 'name')), values = { { id = lit '7', name = lit 'ops' }, { id = lit '8', name = lit 'dev' } } }
        local E = { template = A.template(node('emp', hole 'who', node('ref', lit 'dept:', hole 'dept'))), values = { { who = lit 'ann', dept = lit '7' }, { who = lit 'bob', dept = lit '8' }, { who = lit 'cy', dept = lit '7' } } }
        return D, E
    end
    local function edit(D, j, W) local V = {}; for h, v in pairs(D.values[j]) do V[h] = v end; for h, v in pairs(W) do V[h] = v end; return A.classify(D.template, D.values[j], A.instantiate(D.template, V).term) end

    it('a referenced key updated reaches every matching row, fixed before the edit; the others keep their key', function()
        local D, E = families()
        local L = A.link(E, D, { from = 'dept', to = 'id' })
        assert.is_true(L.is_function); assert.equals(3, #L.tuples)
        local C = edit(D, 1, { id = lit '9' })
        assert.equals('value', C.kind)
        local R = assert(A.cascade(L, E, D, 1, C))
        assert.same({ 1, 3 }, R.rows)
        assert.equals('"7"', A.show(R.key.from)); assert.equals('"9"', A.show(R.key.to))
        assert.equals('(emp "cy" (ref "dept:" "9"))', A.show(R.preview(3)))
        local new = R.commit()
        assert.equals('"9"', A.show(new[1].dept)); assert.equals('"8"', A.show(new[2].dept)); assert.equals('"9"', A.show(new[3].dept))
        local partial = R.commit({ 1 })
        assert.equals('"7"', A.show(partial[3].dept)) -- commitment scopes the rows, all by default
        -- the matching rows are the link's, read before the edit: a later link on the new values agrees
        local L2 = A.link({ template = E.template, values = new }, { template = D.template, values = { C.values, D.values[2] } }, { from = 'dept', to = 'id' })
        assert.equals(3, #L2.tuples); assert.equals(0, #L2.dangling)
    end)

    it('refusals by name: the referenced columns not a key, a collision, a non-value edit, an unchanged key', function()
        local D, E = families()
        local L = A.link(E, D, { from = 'dept', to = 'id' })
        local C = edit(D, 1, { id = lit '8' })
        local r, why = A.cascade(L, E, D, 1, C)
        assert.is_nil(r); assert.matches('already the key of member 2', why)
        local Lr = A.link(D, E, { from = 'id', to = 'dept' }) -- dept is not a key of the employees
        local r2, why2 = A.cascade(Lr, D, E, 1, C)
        assert.is_nil(r2); assert.matches('not a key of the referenced family', why2)
        local Cn = edit(D, 1, { name = lit 'operations' })
        local r3, why3 = A.cascade(L, E, D, 1, Cn)
        assert.is_nil(r3); assert.matches('no component of the key id changed', why3)
        local Ct = A.classify(D.template, D.values[1], node('dept', lit '7', lit 'ops', lit 'x'))
        local r4, why4 = A.cascade(L, E, D, 1, Ct)
        assert.is_nil(r4); assert.matches('not a value edit', why4)
    end)

    it('a key read through a reader is written through its inverse: the value\'s other parts survive; a function reader has none', function()
        local D = families()
        local RD = A.template(node('ref', hole 'host', lit ':', hole 'n'))
        local E = { template = A.template(node('emp', hole 'who', hole 'r')), values = { { who = lit 'ann', r = node('ref', lit 'hq', lit ':', lit '7') }, { who = lit 'bob', r = node('ref', lit 'lab', lit ':', lit '7') } } }
        local L = A.link(E, D, { from = 'r', to = 'id', read_from = { template = RD, hole = 'n' } })
        assert.equals(2, #L.tuples)
        local C = edit(D, 1, { id = lit '9' })
        local R = assert(A.cascade(L, E, D, 1, C))
        assert.equals('(ref "hq" ":" "9")', A.show(R.values[1].r)); assert.equals('(ref "lab" ":" "9")', A.show(R.values[2].r))
        local Lf = A.link(E, D, { from = 'r', to = 'id', read_from = function(v) return v.kids[3] end })
        local r, why = A.cascade(Lf, E, D, 1, C)
        assert.is_nil(r); assert.matches('a function reader has no inverse', why)
    end)

    it('a composite key writes only the changed component, each through its own reader', function()
        local J = { template = A.template(node('job', hole 'man', hole 'date', hole 'title')), values = { { man = lit 'm1', date = lit '1970', title = lit 'clerk' }, { man = lit 'm1', date = lit '1975', title = lit 'lead' } } }
        local S = { template = A.template(node('sal', hole 'man', node('at', lit 'y', hole 'year'), hole 'amount')), values = { { man = lit 'm1', year = lit '1970', amount = lit '10' }, { man = lit 'm1', year = lit '1975', amount = lit '20' } } }
        local L = A.link(S, J, { from = { 'man', 'year' }, to = { 'man', 'date' } })
        assert.is_true(L.is_function); assert.equals(2, #L.tuples)
        local C = edit(J, 2, { date = lit '1976' })
        local R = assert(A.cascade(L, S, J, 2, C))
        assert.same({ 2 }, R.rows)
        assert.equals('"1976"', A.show(R.values[2].year)); assert.equals('"m1"', A.show(R.values[2].man))
        assert.equals('(sal "m1" (at "y" "1976") "20")', A.show(R.preview(2)))
        -- only the changed component is written: a function reader on the unchanged one (no inverse) is never asked
        local Lf = A.link(S, J, { from = { 'man', 'year' }, to = { 'man', 'date' }, read_from = { function(v) return v end, nil } })
        local Rf = assert(A.cascade(Lf, S, J, 2, C))
        assert.equals('"1976"', A.show(Rf.values[2].year))
    end)

    it('the referencing domain follows PROPAGATE.md: derived widens and says so, supplied refuses', function()
        local D, E = families()
        local hd = 'dept' -- a derived enumerated domain (DOMAINS.md's `enumerate` policy), stated as a hole record
        local Ef = { template = A.template(node('emp', hole 'who', node('ref', lit 'dept:', hole 'dept')), { dept = { domain = A.alt(A.closed(lit '7'), A.closed(lit '8')), origin = 'derived' } }), values = E.values }
        local L = A.link(Ef, D, { from = hd, to = 'id' })
        local C = edit(D, 1, { id = lit '9' })
        local R = assert(A.cascade(L, Ef, D, 1, C))
        assert.equals(1, #R.widened); assert.equals(hd, R.widened[1].h)
        assert.is_true(A.instantiate(R.template, R.values[1]).ok)
        local Es = { template = A.template(node('emp', hole 'who', node('ref', lit 'dept:', hole 'dept')), { dept = A.alt(A.closed(lit '7'), A.closed(lit '8')) }), values = E.values }
        local Ls = A.link(Es, D, { from = 'dept', to = 'id' })
        local r, why = A.cascade(Ls, Es, D, 1, C)
        assert.is_nil(r); assert.matches('a supplied domain refuses', why)
    end)

    it('the delete rule: a referenced member dropped names the rows that would dangle', function()
        local D, E = families()
        local L = A.link(E, D, { from = 'dept', to = 'id' })
        assert.same({ 1, 3 }, A.cascade_delete(L, 1).rows)
        assert.same({}, A.cascade_delete(L, 3).rows)
        assert.matches('no matching row', A.cascade_delete(L, 3).why)
    end)

    it('the six report callbacks and the seven declarations: (module, name) is the key, a rename cascades to one call site and only one', function()
        local F = fixture(); if not F then return end
        local six, defs = {}, {}
        for i, m in ipairs(F.six) do six[i] = m.term end
        for i, d in ipairs(F.defs) do defs[i] = node('def', d.term, node('module', lit(d.module))) end
        local gA = A.generalize(six, { need = 100 })
        local gB = A.generalize(defs, { need = 100 })
        local hmod, hfn
        for h in pairs(gA.template.holes) do if A.cst_print(gA.values[1][h]):find('^cartograph%.') then hmod = h else hfn = h end end
        local bmod, bname
        for h, e in pairs(gB.template.holes) do if not e.rep then local v = gB.values[1][h]; if A.cst_print(v):find('^cartograph%.') then bmod = h elseif v.k == 'lit' then bname = h end end end
        local L1 = A.link(gA, gB, { from = hfn, to = bname })
        assert.is_false(L1.is_function); assert.equals(1, #L1.ambiguity) -- report is defined four times
        local L = A.link(gA, gB, { from = { hmod, hfn }, to = { bmod, bname } })
        assert.is_true(L.is_function); assert.equals(6, #L.tuples); assert.equals(0, #L.dangling)
        local j
        for i, d in ipairs(F.defs) do if d.module == 'cartograph.optimize' and d.name == 'report' then j = i end end
        local W = {}
        for h, v in pairs(gB.values[j]) do W[h] = v end
        W[bname] = lit 'optimize_report'
        local C = A.classify(gB.template, gB.values[j], A.instantiate(gB.template, W, gB.env).term, gB.env)
        assert.equals('value', C.kind)
        local R = assert(A.cascade(L, gA, gB, j, C, { env = gB.env }))
        assert.equals(1, #R.rows)
        assert.equals('cartograph.optimize', A.cst_print(gA.values[R.rows[1]][hmod]))
        assert.equals('optimize_report', A.cst_print(R.values[R.rows[1]][hfn]))
        -- the surgery: one hunk in the call site, at the function name
        local hs = A.hunks(R.template, gA.values[R.rows[1]], R.template, R.values[R.rows[1]], gA.env)
        assert.equals(1, #hs); assert.equals('report', hs[1].old); assert.equals('optimize_report', hs[1].new)
        -- a rename onto an existing key in the same module refuses
        local j3
        for i, d in ipairs(F.defs) do if d.module == 'cartograph.narrow' and d.name == 'report' then j3 = i end end
        local W3 = {}
        for h, v in pairs(gB.values[j3]) do W3[h] = v end
        W3[bname] = lit 'param_report'
        local C3 = A.classify(gB.template, gB.values[j3], A.instantiate(gB.template, W3, gB.env).term, gB.env)
        local r, why = A.cascade(L, gA, gB, j3, C3, { env = gB.env })
        assert.is_nil(r); assert.matches('already the key of member', why)
    end)
end)

describe('a registry in a table (REGISTRY.md; SQL-92 §13.10): the first writer for a non-text store, and a rename across the two stores', function()
    local A = require 'algebra'
    local lit, node, hole = A.lit, A.node, A.hole
    local okR, R = pcall(require, 'experiments.sqlite_reader')
    local have, ver
    if okR then have, ver = R.available() else have, ver = false, 'experiments/sqlite_reader.lua not found: ' .. tostring(R) end
    local tmp = (os.getenv('SQLITE_READER_TMP') or os.getenv('TMPDIR') or '/tmp')
    local n = 0
    local function fresh_db() -- a fresh copy per test that writes, so no later test reads a mutated row
        if not have then pending('sqlite3 shell not available: ' .. tostring(ver)) return nil end
        n = n + 1
        local db = ('%s/algebra_registry_%d.db'):format(tmp, n)
        assert(R.build(db, 'experiments/registry_fixture.sql'))
        return R.open(db), db
    end
    local function cell(s) return node('text', lit(s)) end
    -- code in the reader's shape: reg('flags') as tree-sitter reads it, the key a string_content literal
    local function call(key) return node('function_call', node('identifier', lit 'reg'), node('arguments', lit '(', node('string', lit "'", node('string_content', lit(key)), lit "'"), lit ')')) end
    local unwrap = { template = A.template(node('text', hole 'k')), hole = 'k' } -- the table side's reader: a cell to its text

    it('the sql_q grammar prints cells by storage class and identifiers quoted, refuses a blob, and reads its own statement back', function()
        local st = node('update', node('ident', lit 'registry'), node('set', node('assign', node('ident', lit 'name'), cell "it's"), node('assign', node('ident', lit 'n'), node('integer', lit(3)))), node('where', node('eq', node('ident', lit 'key'), cell 'a'), node('eq', node('ident', lit 'x'), node('null'))))
        local sql = A.grammars.sql_q.print(st)
        assert.equals([[UPDATE "registry" SET "name" = 'it''s', "n" = 3 WHERE "key" = 'a' AND "x" = NULL;]], sql)
        local back = A.grammars.sql_q.parse(sql)
        assert.equals('update', back.kids[1].n); assert.equals('registry', back.kids[2].v)
        -- an identifier holding a quote prints doubled (the toy parse does not undo it: a limit of the `sql` grammar's parse)
        assert.matches('^UPDATE "reg""istry"', A.grammars.sql_q.print(node('update', node('ident', lit 'reg"istry'), node('set', node('assign', node('ident', lit 'n'), node('integer', lit(3)))), node('where', node('eq', node('ident', lit 'k'), cell 'a')))))
        assert.is_nil(A.grammars.sql_q.print(node('update', node('ident', lit 't'), node('set', node('assign', node('ident', lit 'c'), node('blob'))), node('where', node('eq', node('ident', lit 'k'), node('integer', lit(1)))))))
        assert.is_nil(A.grammars.sql_q.print(node('update', hole 'table', node('set'), node('where'))))
    end)

    it('the UPDATE is the row\'s surgery: the changed columns in SET, the old primary key in WHERE, rowid when none is declared, no data when nothing changed', function()
        local rd = fresh_db(); if not rd then return end
        local F = A.read(rd, 'registry')
        assert.is_true(F.ok); assert.equals('registry', F.table); assert.same({ 'key' }, F.keys)
        assert.equals('(row ?key ?handler ?enabled)', A.show(F.template.body))
        local W = {}
        for h, v in pairs(F.values[1]) do W[h] = v end
        W.key = cell 'feature_flags'
        local u = assert(A.table_update(F, 1, W))
        assert.equals([[UPDATE "registry" SET "key" = 'feature_flags' WHERE "key" = 'flags';]], u.sql)
        assert.is_true(u.verified); assert.same({ 'key' }, u.columns)
        W.enabled = node('integer', lit(0))
        local u2 = assert(A.table_update(F, 1, W))
        assert.same({ 'enabled', 'key' }, (function() table.sort(u2.columns); return u2.columns end)())
        local N = A.read(rd, 'notes')
        assert.same({}, N.keys)
        local u3 = assert(A.table_update(N, 2, { body = cell "isn't" }))
        assert.equals([[UPDATE "notes" SET "body" = 'isn''t' WHERE "rowid" = 2;]], u3.sql)
        local r, why = A.table_update(F, 1, F.values[1])
        assert.is_nil(r); assert.matches('no data', why)
        local r2, why2 = A.table_update({ template = F.template, values = F.values, keys = F.keys }, 1, W)
        assert.is_nil(r2); assert.matches('names no table', why2)
        -- the reader verifies the writer: a table name the parse cannot read back (a doubled quote) leaves the statement unverified
        local uq = assert(A.table_update({ template = F.template, values = F.values, keys = F.keys, table = 'reg"istry' }, 1, W))
        assert.is_false(uq.verified); assert.matches('^UPDATE "reg""istry"', uq.sql)
        assert.equals('absent', A.absence_of({ why = why }).absence)
    end)

    it('the stamp is the precondition: fresh before the write, stale after it, and a re-read shows the row', function()
        local rd, db = fresh_db(); if not rd then return end
        local F = A.read(rd, 'registry')
        local W = {}
        for h, v in pairs(F.values[2]) do W[h] = v end
        W.handler = cell 'handlers.routing'
        local u = assert(A.table_update(F, 2, W))
        assert.is_true(A.fresh(F, rd))
        assert.is_truthy(R.exec(db, u.sql))
        local ok, why = A.fresh(F, rd)
        assert.is_false(ok); assert.matches('^stale', why)
        assert.equals('frontier', A.absence_of({ why = why }).absence)
        local F2 = A.read(rd, 'registry')
        assert.equals('handlers.routing', F2.values[2].handler.kids[1].v)
        assert.are_not.equal(F.source.stamp, F2.source.stamp)
        -- a supplied domain from the DDL refuses a key of the wrong storage class instead of widening
        local bad = {}
        for h, v in pairs(F.values[1]) do bad[h] = v end
        bad.key = node('integer', lit(7))
        assert.is_false(A.instantiate(F.template, bad).ok)
    end)

    it('the rename across the two stores: a registry key row renamed cascades into the code, the UPDATE is the table\'s surgery, and the link holds on the re-read', function()
        local rd, db = fresh_db(); if not rd then return end
        local F = A.read(rd, 'registry')
        local src = { "reg('flags')", "reg('routes')", "reg('flags')", "reg('audit')" }
        local code = A.generalize({ call 'flags', call 'routes', call 'flags', call 'audit' }, { need = 100 })
        local hk = A.hole_names(code.template)[1]
        assert.equals('flags', code.values[1][hk].v)
        local L = A.link(code, F, { from = hk, to = 'key', read_to = unwrap, complete = true })
        assert.is_true(L.is_function); assert.equals(4, #L.tuples); assert.same({}, L.dangling)
        -- the table side: row 1 renamed
        local W = {}
        for h, v in pairs(F.values[1]) do W[h] = v end
        W.key = cell 'feature_flags'
        local C = A.classify(F.template, F.values[1], A.instantiate(F.template, W).term)
        assert.equals('value', C.kind); assert.equals('key', C.changed[1].h)
        local Rc = assert(A.cascade(L, code, F, 1, C))
        assert.same({ 1, 3 }, Rc.rows)
        assert.equals('feature_flags', Rc.values[1][hk].v)
        -- the code's surgery: one hunk per matching member, at the string
        for _, a in ipairs(Rc.rows) do
            local hs = A.hunks(Rc.template, code.values[a], Rc.template, Rc.values[a])
            assert.equals(1, #hs); assert.equals('flags', hs[1].old); assert.equals('feature_flags', hs[1].new)
            assert.equals("reg('feature_flags')", A.apply_hunks(src[a], hs))
        end
        -- the table's surgery: the UPDATE, executed on the scratch database once the stamp still holds
        local u = assert(A.table_update(F, 1, C.values))
        assert.is_true(A.fresh(F, rd))
        assert.is_truthy(R.exec(db, u.sql))
        assert.is_false((A.fresh(F, rd)))
        -- both stores re-read: the link is intact; without the cascade the code dangles
        local F2 = A.read(rd, 'registry')
        local new = Rc.commit()
        local L2 = A.link({ template = Rc.template, values = new }, F2, { from = hk, to = 'key', read_to = unwrap, complete = true })
        assert.equals(4, #L2.tuples); assert.same({}, L2.dangling)
        local Lneg = A.link(code, F2, { from = hk, to = 'key', read_to = unwrap, complete = true })
        assert.same({ 1, 3 }, Lneg.dangling)
        assert.equals('absent', A.chain(1, { Lneg }).absences[1].absence) -- the registry is complete: the key is gone
        -- a collision onto an existing key refuses
        local Wc = {}
        for h, v in pairs(F.values[1]) do Wc[h] = v end
        Wc.key = cell 'routes'
        local Cc = A.classify(F.template, F.values[1], A.instantiate(F.template, Wc).term)
        local r, why = A.cascade(L, code, F, 1, Cc)
        assert.is_nil(r); assert.matches('already the key of member 2', why)
        -- the reverse direction is a check: the code renames a key the registry lacks, the link says so
        local Cr = A.classify(code.template, code.values[2], call 'routing')
        assert.equals('value', Cr.kind)
        local vals = {}
        for i, V in ipairs(code.values) do vals[i] = V end
        vals[2] = Cr.values
        local Lr = A.link({ template = code.template, values = vals }, F, { from = hk, to = 'key', read_to = unwrap, complete = true })
        assert.same({ 2 }, Lr.dangling)
    end)

    it('dig declares a single-use reference: a one-member family has no hole until the string is dug, then it links like any other', function()
        local rd = fresh_db(); if not rd then return end
        local F = A.read(rd, 'registry')
        local one = A.generalize({ call 'users' }, { need = 100 })
        assert.same({}, A.hole_names(one.template))
        local p
        for _, q in ipairs(A.positions(one.template.body)) do if q.node.k == 'lit' and q.node.v == 'users' then p = q.path end end
        local T2 = assert(A.dig(one.template, p, 'key', A.kinds { 'lit' }))
        local V2 = { key = lit 'users' }
        assert.is_true(A.eq(A.instantiate(T2, V2).term, call 'users'))
        local L = A.link({ template = T2, values = { V2 } }, F, { from = 'key', to = 'key', read_to = unwrap, complete = true })
        assert.equals(1, #L.tuples); assert.equals(3, L.tuples[1].b)
        assert.equals('{lit}', A.show_domain(T2.holes.key.domain)) -- the dug hole's domain is the one given; the key column's is the table's
    end)
end)

describe('expressibility (EXPRESS.md; mustache(5), the Handlebars guide): the hbs grammar as a store, and a Lua expression generated as a template', function()
    local A = require 'algebra'
    local lit, node, hole = A.lit, A.node, A.hole
    local G = A.grammars.hbs
    local function R(tpl, data, partials) return A.hbs_render(assert(G.parse(tpl), 'parse: ' .. tpl), data, partials) end
    local okf, FX = pcall(dofile, 'experiments/lua-terms-2026-09-18.lua')
    local function fixture() if not okf then return pending('experiments/lua-terms-2026-09-18.lua not loadable: ' .. tostring(FX)) end return FX end
    -- Lua terms in the reader's shape
    local function str(s) return node('string', lit "'", node('string_content', lit(s)), lit "'") end
    local function id(s) return node('identifier', lit(s)) end
    local function dot(a, b) return node('dot_index_expression', a, lit '.', id(b)) end
    local function cat(a, b) return node('binary_expression', a, lit ' ', lit '..', lit ' ', b) end
    local function bor(a, b) return node('binary_expression', a, lit ' ', lit 'or', lit ' ', b) end
    local function call(fn, ...) local kids = { lit '(' }; for i, a in ipairs({ ... }) do if i > 1 then kids[#kids + 1] = lit ', ' end; kids[#kids + 1] = a end; kids[#kids + 1] = lit ')'; return node('function_call', fn, node('arguments', unpack(kids))) end
    local function fmt(f, ...) return call(node('method_index_expression', node('parenthesized_expression', lit '(', str(f), lit ')'), lit ':', id 'format'), ...) end
    local sample_law = A.hbs_sample_law

    it('mustache(5): variables escape, triple-stash does not, dotted names descend, a miss is empty', function()
        assert.equals('* Chris\n* \n* &lt;b&gt;GitHub&lt;/b&gt;\n* <b>GitHub</b>\n', R('* {{name}}\n* {{age}}\n* {{company}}\n* {{{company}}}\n', { name = 'Chris', company = '<b>GitHub</b>' }))
        assert.equals('* Chris &amp; Friends\n* \n* \n* <b>GitHub</b>\n', R('* {{client.name}}\n* {{age}}\n* {{client.company.name}}\n* {{{company.name}}}\n', { client = { name = 'Chris & Friends', age = 50 }, company = { name = '<b>GitHub</b>' } }))
        assert.equals('* Hello!', R('* {{.}}', 'Hello!'))
        assert.equals('a &#39;q&#39; &quot;d&quot;', R('{{x}}', { x = "a 'q' \"d\"" }))
    end)

    it('mustache(5): sections over false, a list, an implicit iterator and an object; the inverted section; the comment; the standalone line', function()
        assert.equals('Shown.\n', R('Shown.\n{{#person}}\n  Never shown!\n{{/person}}\n', { person = false }))
        assert.equals('  <b>resque</b>\n  <b>hub</b>\n  <b>rip</b>\n', R('{{#repo}}\n  <b>{{name}}</b>\n{{/repo}}\n', { repo = { { name = 'resque' }, { name = 'hub' }, { name = 'rip' } } }))
        assert.equals('  <b>resque</b>\n  <b>hub</b>\n  <b>rip</b>\n', R('{{#repo}}\n  <b>{{.}}</b>\n{{/repo}}\n', { repo = { 'resque', 'hub', 'rip' } }))
        assert.equals('  Hi Jon!\n', R('{{#person?}}\n  Hi {{name}}!\n{{/person?}}\n', { ['person?'] = { name = 'Jon' } }))
        assert.equals('  No repos :(\n', R('{{#repo}}\n  <b>{{name}}</b>\n{{/repo}}\n{{^repo}}\n  No repos :(\n{{/repo}}\n', { repo = {} }))
        assert.equals('<h1>Today.</h1>', R('<h1>Today{{! ignore me }}.</h1>', {}))
        assert.equals('a {{x}} b', R('a {{! not standalone }}{{x}} b', { x = '{{x}}' })) -- an inline comment consumes nothing
    end)

    it('mustache(5): partials inherit the context and keep the indentation of a standalone tag', function()
        assert.equals('<h2>Names</h2>\n  <strong>a</strong>\n  <strong>b</strong>\n', R('<h2>Names</h2>\n{{#names}}\n  {{> user}}\n{{/names}}\n', { names = { { name = 'a' }, { name = 'b' } } }, { user = '<strong>{{name}}</strong>\n' }))
    end)

    it('Handlebars: #if with else, #unless, #each with this, @index, @first and @last, #with; falsiness includes "", 0 and []', function()
        assert.equals('<h1>Yehuda</h1>', R('{{#if author}}<h1>{{firstName}}</h1>{{else}}<h1>Unknown</h1>{{/if}}', { author = true, firstName = 'Yehuda' }))
        assert.equals('<h1>Unknown</h1>', R('{{#if author}}<h1>{{firstName}}</h1>{{else}}<h1>Unknown</h1>{{/if}}', {}))
        assert.equals('no', R('{{#if n}}yes{{else}}no{{/if}}', { n = 0 })); assert.equals('no', R('{{#if s}}yes{{else}}no{{/if}}', { s = '' })); assert.equals('no', R('{{#if l}}yes{{else}}no{{/if}}', { l = {} }))
        assert.equals('WARNING', R('{{#unless license}}WARNING{{/unless}}', {}))
        assert.equals(' 0: x  1: y ', R('{{#each array}} {{@index}}: {{this}} {{/each}}', { array = { 'x', 'y' } }))
        assert.equals('a, b, c', R('{{#each items}}{{this}}{{#unless @last}}, {{/unless}}{{/each}}', { items = { 'a', 'b', 'c' } }))
        assert.equals('[a]bc', R('{{#each items}}{{#if @first}}[{{this}}]{{else}}{{this}}{{/if}}{{/each}}', { items = { 'a', 'b', 'c' } }))
        assert.equals('empty', R('{{#each items}}{{this}}{{else}}empty{{/each}}', { items = {} }))
        assert.equals('Yehuda Katz', R('{{#with person}}{{firstname}} {{lastname}}{{/with}}', { person = { firstname = 'Yehuda', lastname = 'Katz' } }))
    end)

    it('print then parse is the identity on every term, and a malformed template reads nothing', function()
        for _, tpl in ipairs { 'a {{x}} {{{y}}} {{#if z}}p{{else}}q{{/if}} {{#each l}}{{this}}{{/each}}{{! c}}{{> p}}', '{{#repo}}<b>{{name}}</b>{{/repo}}{{^repo}}none{{/repo}}', 'plain text only' } do
            local t = assert(G.parse(tpl))
            assert.equals(tpl, G.print(t)); assert.is_true(A.eq(G.parse(G.print(t)), t))
        end
        assert.is_nil(G.parse('{{#if x}}open')); assert.is_nil(G.parse('{{x')); assert.is_nil(G.parse('{{/x}}'))
        assert.is_nil(G.print(node('hbs', hole 'h')))
    end)

    it('the generator: text, raw lookups, concatenation, format directives, table.concat as #each; each as-is claim holds on the samples', function()
        local H = A.hbs_of(cat(str 'cartograph: no files under ', id 'arg'))
        assert.equals('as-is', H.kind); assert.equals('cartograph: no files under {{{arg}}}', G.print(H.term)); assert.same({ 'arg' }, H.lookups)
        local tried, agree = sample_law(H, "'cartograph: no files under ' .. arg")
        assert.is_true(tried >= 5); assert.equals(tried, agree)
        local H2 = A.hbs_of(fmt('%s has %d ports', dot(id 'n', 'name'), dot(id 'n', 'count')))
        assert.equals('as-is', H2.kind); assert.equals('{{{n.name}}} has {{{n.count}}} ports', G.print(H2.term))
        local H3 = A.hbs_of(call(dot(id 'table', 'concat'), id 'params', str ', '))
        assert.equals('as-is', H3.kind); assert.equals('{{#each params}}{{{this}}}{{#unless @last}}, {{/unless}}{{/each}}', G.print(H3.term))
        assert.equals('a, b', A.hbs_render(H3.term, { params = { 'a', 'b' } }))
        local H4 = A.hbs_of(fmt('100%% of %s', id 'x'))
        assert.equals('100% of {{{x}}}', G.print(H4.term))
        local H5 = A.hbs_of(cat(str 'n=', call(id 'tostring', id 'n')))
        assert.equals('as-is', H5.kind); assert.equals('n={{{n}}}', G.print(H5.term))
    end)

    it('the generator: an `or`, a width directive, a length, a call and arithmetic are staged, and a bare computation is not a template', function()
        local H = A.hbs_of(fmt('%s has no ports.', bor(dot(id 'n', 'name'), str '?')))
        assert.equals('staged', H.kind); assert.equals('{{{name}}} has no ports.', G.print(H.term)); assert.equals('or', H.staged[1].kind) -- the staged lookup named after the path it reads
        -- why the `or` is staged: Lua's falsiness is not Handlebars': the empty string is truthy in Lua and falsy in Handlebars
        assert.equals('?', A.hbs_render(assert(G.parse('{{#if n.name}}{{{n.name}}}{{else}}?{{/if}}')), { n = { name = '' } }))
        assert.equals('', (loadstring("return (function(n) return n.name or '?' end)({ name = '' })")()))
        assert.equals('?', A.hbs_render(assert(G.parse('{{#if n.name}}{{{n.name}}}{{else}}?{{/if}}')), { n = { name = 0 } })) -- 0 is falsy in Handlebars, not in Lua
        -- the law itself refutes the if/else translation of the idiom on the empty string, so the census cannot claim it as-is
        local Hif = { term = assert(G.parse('{{#if n.name}}{{{n.name}}}{{else}}?{{/if}}')), lookups = { 'n.name' }, staged = {}, kind = 'as-is' }
        local tried, agree, bad = A.hbs_sample_law(Hif, "n.name or '?'")
        assert.equals(6, tried); assert.is_true(agree < tried); assert.matches('lua "", template "%?"', bad[1])
        -- a table.concat with a range is a computation, not an #each over the whole list
        assert.equals('not', A.hbs_of(call(dot(id 'table', 'concat'), id 'segs', str '/', id 'i', id 'j')).kind) -- the whole call is one computation: no template
        assert.equals('staged', A.hbs_of(cat(str 'path ', call(dot(id 'table', 'concat'), id 'segs', str '/', id 'i', id 'j'))).kind)
        local H2 = A.hbs_of(fmt('%-44s %s', id 'pt', id 'sz'))
        assert.equals('staged', H2.kind); assert.equals('format:%-44s', H2.staged[1].kind); assert.equals('{{{pt_text}}} {{{sz}}}', G.print(H2.term))
        local H3 = A.hbs_of(cat(str 'ports (', node('unary_expression', lit '#', id 'ports')))
        assert.equals('staged', H3.kind); assert.equals('length', H3.staged[1].kind)
        local H4 = A.hbs_of(call(id 'report', id 'x'))
        assert.equals('not', H4.kind); assert.equals('call', H4.staged[1].kind)
        local H5 = A.hbs_of(cat(str 'total ', node('binary_expression', id 'a', lit ' ', lit '+', lit ' ', id 'b')))
        assert.equals('staged', H5.kind); assert.equals('arith', H5.staged[1].kind)
        assert.equals('not', A.hbs_of(bor(id 'a', id 'b')).kind)
    end)

    it('the staging split: a staged computation gets a readable name and its read paths, and the law holds for the pair, template plus producing side, a missing value included', function()
        local H = A.hbs_of(fmt('%s has no ports.', bor(dot(id 'n', 'name'), str '?')))
        assert.equals('staged', H.kind); assert.equals('{{{name}}} has no ports.', G.print(H.term))
        assert.equals('name', H.staged[1].name); assert.equals('or', H.staged[1].kind); assert.same({ 'n.name' }, H.staged[1].refs)
        assert.equals("n.name or '?'", H.staged[1].text)
        local tried, agree, bad = A.hbs_sample_law(H, "('%s has no ports.'):format(n.name or '?')")
        assert.equals(6, tried); assert.equals(6, agree, bad[1]) -- the sixth sample is the missing value: Lua gives ?, the producing side gives ?
        -- a length is `<path>_count`; a computation that reads the variable it would be named after takes `_text`
        local H2 = A.hbs_of(fmt('ports of %s (%d)', bor(dot(id 'n', 'name'), str '?'), node('unary_expression', lit '#', id 'ports')))
        assert.equals('ports of {{{name}}} ({{{ports_count}}})', G.print(H2.term)); assert.equals('length', H2.staged[2].kind)
        local band = node('binary_expression', node('binary_expression', id 'size', lit ' ', lit '>', lit ' ', node('number', lit '1')), lit ' ', lit 'and', lit ' ', str 'big')
        local H3 = A.hbs_of(fmt('%-44s %s', id 'pt', bor(band, str 'small')))
        assert.equals('{{{pt_text}}} {{{size_text}}}', G.print(H3.term))
        -- a width directive stages the FORMATTING of its argument, so the producing side pads and the law agrees
        assert.equals("('%-44s'):format(pt)", H3.staged[1].text); assert.same({ 'pt' }, H3.staged[1].refs)
        local t3, a3, b3 = A.hbs_sample_law(H3, "('%-44s %s'):format(pt, size > 1 and 'big' or 'small')")
        assert.equals(2, t3); assert.equals(2, a3, b3[1]) -- only the numeric samples compare with 1; a string or a missing value errors in Lua and is not tried
        -- a name already a template lookup falls back to sN
        local H4 = A.hbs_of(cat(cat(id 'name', str ': '), bor(dot(id 'n', 'name'), str '?')))
        assert.equals('{{{name}}}: {{{s1}}}', G.print(H4.term))
        -- the sixth sample is a MISSING value: a `%s` lookup prints nil in Lua and nothing in a template, so the claim is as-is when present only
        local H5 = A.hbs_of(fmt('%s!', id 'x'))
        assert.equals('as-is', H5.kind)
        local t5, a5 = A.hbs_sample_law(H5, "('%s!'):format(x)", { samples = 5 })
        assert.equals(5, t5); assert.equals(5, a5)
        local t6, a6, b6 = A.hbs_sample_law(H5, "('%s!'):format(x)")
        if jit then -- LuaJIT (and Lua 5.2+) format nil as "nil"; Lua 5.1's %s refuses a nil and the sample is not tried
            assert.equals(6, t6); assert.equals(5, a6); assert.matches('lua "nil!", template "!"', b6[1])
        else
            assert.equals(5, t6); assert.equals(5, a6)
        end
        -- the callee of a call is not a path the computation reads; the name avoids the variable read (`_text`)
        local H6 = A.hbs_of(cat(str 'n=', call(id 'count', id 'items')))
        assert.equals('staged', H6.kind); assert.equals('call', H6.staged[1].kind); assert.same({ 'items' }, H6.staged[1].refs); assert.equals('items_text', H6.staged[1].name)
    end)

    it('the census over commands/analysis.lua: every maximal string-building expression classed, every as-is claim holding on the samples', function()
        local F = fixture(); if not F then return end
        local root = F.analysis.term
        local parent = {}
        local pos = A.positions(root)
        local nodes_at = {}
        for _, p in ipairs(pos) do nodes_at[A.key(p.path)] = p.node end
        local function is_cat(n) if n.k ~= 'binary_expression' then return false end; for _, c in ipairs(n.kids) do if c.k == 'lit' and c.v == '..' then return true end end; return false end
        -- a census unit is a MAXIMAL string-building expression: a `..` chain, a format call or a
        -- table.concat with no such expression above it
        local function candidate(n)
            if is_cat(n) then return true end
            if n.k ~= 'function_call' then return false end
            local text = A.cst_print(n)
            return text:find('^%(.-%):format%(') or text:find('^string%.format%(') or text:find('^table%.concat%(')
        end
        local cands = {}
        for _, p in ipairs(pos) do if candidate(p.node) then cands[#cands + 1] = p end end
        local counts, units = { ['as-is'] = 0, staged = 0, ['not'] = 0 }, 0
        for _, p in ipairs(cands) do
            local nested = false
            for _, q in ipairs(cands) do
                if #q.path < #p.path then
                    local pre = true
                    for i = 1, #q.path do if q.path[i] ~= p.path[i] then pre = false end end
                    if pre then nested = true end
                end
            end
            if not nested then
                units = units + 1
                local H = A.hbs_of(p.node)
                counts[H.kind] = counts[H.kind] + 1
                assert.is_true(A.eq(G.parse(G.print(H.term)), H.term))
                if H.kind == 'as-is' then local tried, agree = sample_law(H, A.cst_print(p.node)); assert.equals(tried, agree, A.cst_print(p.node)) end
            end
        end
        assert.equals(12, units)
        assert.equals(8, counts['as-is']); assert.equals(4, counts.staged); assert.equals(0, counts['not'])
    end)
end)

describe('the render call generator (RENDER.md): the producing side written by a template, read back through it, the move composed', function()
    local A = require 'algebra'
    local lit, node, hole = A.lit, A.node, A.hole
    local G = A.grammars.hbs
    local okf, FX = pcall(dofile, 'experiments/lua-terms-2026-09-18.lua')
    local function fixture() if not okf then return pending('experiments/lua-terms-2026-09-18.lua not loadable: ' .. tostring(FX)) end return FX end
    local function str(s) return node('string', lit "'", node('string_content', lit(s)), lit "'") end
    local function id(s) return node('identifier', lit(s)) end
    local function dot(a, b) return node('dot_index_expression', a, lit '.', id(b)) end
    local function cat(a, b) return node('binary_expression', a, lit ' ', lit '..', lit ' ', b) end
    local function bor(a, b) return node('binary_expression', a, lit ' ', lit 'or', lit ' ', b) end
    local function call(fn, ...) local kids = { lit '(' }; for i, a in ipairs({ ... }) do if i > 1 then kids[#kids + 1] = lit ', ' end; kids[#kids + 1] = a end; kids[#kids + 1] = lit ')'; return node('function_call', fn, node('arguments', unpack(kids))) end
    local function fmt(f, ...) return call(node('method_index_expression', node('parenthesized_expression', lit '(', str(f), lit ')'), lit ':', id 'format'), ...) end

    it('the generator prints the call in the reader\'s shape for zero, one and several fields, and the reader is a match through the same template', function()
        assert.equals("render('x', {})", A.cst_print(A.render_call('x', {})))
        local one = A.render_call('no_files', { { key = 'arg', value = id 'arg' } })
        assert.equals("render('no_files', { arg = arg })", A.cst_print(one))
        local two = A.render_call('ports', { { key = 'name', value = bor(dot(id 'n', 'name'), str '?') }, { key = 'ports_count', value = node('unary_expression', lit '#', id 'ports') } })
        assert.equals("render('ports', { name = n.name or '?', ports_count = #ports })", A.cst_print(two))
        local back = assert(A.render_call_of(two))
        assert.equals('ports', back.name); assert.equals(2, #back.fields)
        assert.equals('name', back.fields[1].key); assert.equals("n.name or '?'", A.cst_print(back.fields[1].value))
        assert.equals('ports_count', back.fields[2].key); assert.equals('#ports', A.cst_print(back.fields[2].value))
        assert.equals(0, #A.render_call_of(A.render_call('x', {})).fields)
        assert.is_nil(A.render_call_of(call(id 'notify', str 'x')))
        -- a field holding a comment cannot be inlined on the call's line: refused by name, classed refused
        local commented = node('binary_expression', id 'a', lit ' ', lit 'or', lit ' ', node('comment', lit '-- default'), lit '\n', str 'x')
        local r, why = A.render_call('c', { { key = 'a', value = commented } })
        assert.is_nil(r); assert.matches('holds a comment and cannot be inlined', why)
        assert.equals('refused', A.absence_of({ why = why }).absence)
        local mvc, whyc = A.move_to_template(cat(str 'v=', commented), 'c')
        assert.is_nil(mvc); assert.matches('holds a comment', whyc)
        -- the instance is its own reading: generate, read back, generate again
        local again = A.render_call(back.name, back.fields)
        assert.is_true(A.eq(two, again))
    end)

    it('the move: lookups flattened to field keys, a staged computation carried as its own node, the call and the template one pair, the law holding on it', function()
        local mv = A.move_to_template(cat(str 'cartograph: no files under ', id 'arg'), 'no_files')
        assert.equals('as-is', mv.kind); assert.equals('cartograph: no files under {{{arg}}}', mv.text)
        assert.equals("render('no_files', { arg = arg })", A.cst_print(mv.call))
        local mv2 = A.move_to_template(fmt('%s has no ports.', bor(dot(id 'n', 'name'), str '?')), 'no_ports')
        assert.equals('{{{name}}} has no ports.', mv2.text); assert.equals("render('no_ports', { name = n.name or '?' })", A.cst_print(mv2.call))
        local t, a, b = A.move_law(mv2, "('%s has no ports.'):format(n.name or '?')")
        assert.equals(6, t); assert.equals(6, a, b[1])
        -- a dotted lookup becomes a flat key named by its last segment; the field holds the dotted expression
        local mv3 = A.move_to_template(fmt('ports of %s (%d) at %s', bor(dot(id 'n', 'name'), str '?'), node('unary_expression', lit '#', id 'ports'), dot(id 'n', 'file')), 'ports')
        assert.equals('ports of {{{name}}} ({{{ports_count}}}) at {{{file}}}', mv3.text)
        assert.equals("render('ports', { name = n.name or '?', ports_count = #ports, file = n.file })", A.cst_print(mv3.call))
        local t3, a3, b3 = A.move_law(mv3, "('ports of %s (%d) at %s'):format(n.name or '?', #ports, n.file)")
        assert.is_true(t3 >= 3); assert.equals(t3, a3, b3[1])
        -- a width directive's field is the formatting call as a term, so the call prints it
        local mv4 = A.move_to_template(fmt('%-44s %s', id 'pt', id 'sz'), 'row')
        assert.equals("render('row', { pt_text = ('%-44s'):format(pt), sz = sz })", A.cst_print(mv4.call))
        local t4, a4 = A.move_law(mv4, "('%-44s %s'):format(pt, sz)", { samples = 5 })
        assert.equals(5, t4); assert.equals(5, a4)
        -- two lookups sharing a last segment: the second joins its segments
        local mv5 = A.move_to_template(cat(cat(dot(id 'a', 'name'), str '/'), dot(id 'b', 'name')), 'pair')
        assert.equals('{{{name}}}/{{{b_name}}}', mv5.text); assert.equals("render('pair', { name = a.name, b_name = b.name })", A.cst_print(mv5.call))
        -- a table.concat keeps its #each over the flattened key
        local mv6 = A.move_to_template(cat(str 'items: ', call(dot(id 'table', 'concat'), dot(id 'r', 'items'), str ', ')), 'items')
        assert.equals('items: {{#each items}}{{{this}}}{{#unless @last}}, {{/unless}}{{/each}}', mv6.text)
        assert.equals("render('items', { items = r.items })", A.cst_print(mv6.call))
        local t6, a6, b6 = A.move_law(mv6, "'items: ' .. table.concat(r.items, ', ')")
        assert.is_true(t6 >= 3); assert.equals(t6, a6, b6[1])
    end)

    it('over the fixture\'s analysis.lua: every as-is and staged expression generates a call that reads back to its own fields, and the pair holds on the defined samples', function()
        local F = fixture(); if not F then return end
        local root = F.analysis.term
        local pos = A.positions(root)
        local function is_cat(n) if n.k ~= 'binary_expression' then return false end; for _, c in ipairs(n.kids) do if c.k == 'lit' and c.v == '..' then return true end end; return false end
        local function candidate(n)
            if is_cat(n) then return true end
            if n.k ~= 'function_call' then return false end
            local text = A.cst_print(n)
            return text:find('^%(.-%):format%(') or text:find('^string%.format%(') or text:find('^table%.concat%(')
        end
        local cands = {}
        for _, p in ipairs(pos) do if candidate(p.node) then cands[#cands + 1] = p end end
        local moved, held = 0, 0
        for _, p in ipairs(cands) do
            local nested = false
            for _, q in ipairs(cands) do
                if #q.path < #p.path then
                    local pre = true
                    for i = 1, #q.path do if q.path[i] ~= p.path[i] then pre = false end end
                    if pre then nested = true end
                end
            end
            if not nested then
                local mv = assert(A.move_to_template(p.node, 'm' .. moved))
                if mv.kind ~= 'not' then
                    moved = moved + 1
                    local back = assert(A.render_call_of(mv.call))
                    assert.equals(#mv.fields, #back.fields)
                    for i, f in ipairs(mv.fields) do assert.equals(f.key, back.fields[i].key); assert.is_true(A.eq(f.value, back.fields[i].value)) end
                    assert.is_true(A.eq(G.parse(mv.text), mv.template))
                    local t, a, b = A.move_law(mv, A.cst_print(p.node), { samples = 5 })
                    if t > 0 and a == t then held = held + 1 end
                    assert.is_true(t == 0 or a == t, A.cst_print(p.node) .. ' ' .. tostring(b[1]))
                end
            end
        end
        assert.equals(12, moved); assert.equals(12, held)
    end)
end)

describe('the first loop iteration (LOOP.md; Fowler, Extract Function, the catalog example): a family\'s template becomes a helper, its values the calls', function()
    local okf, FX = pcall(dofile, 'experiments/lua-terms-2026-09-18.lua')
    local function fixture() if not okf then return pending('experiments/lua-terms-2026-09-18.lua not loadable: ' .. tostring(FX)) end return FX end
    -- the six report callbacks (the fixture's members 1, 2, 4, 5, 6, 7; member 3 at line 84 is a
    -- neighbour of another shape): each member is `return function () .. end`, the function_definition inside
    local SIX = { 1, 2, 4, 5, 6, 7 }
    local function six_of(F)
        local six = {}
        for i, m in ipairs(SIX) do six[i] = F.members[m].term.kids[1].kids[3].kids[1]; assert.equals('function_definition', six[i].k) end
        return six
    end
    local OPTS = { name = 'report_cmd', params = { h1 = 'mod', h2 = 'fn' }, indent = '    ', reindent = '    ' }
    local function extracted(F)
        local g = A.generalize(six_of(F), { need = 100 })
        local X, why = A.extract(g.template, OPTS)
        assert.is_truthy(X, why)
        return X, g
    end
    local function id(s) return node('identifier', lit(s)) end
    local function str(x) return node('string', lit "'", node('string_content', x), lit "'") end
    local function fdef(...) return node('function_definition', lit 'function', lit ' ', node('parameters', lit '(', lit ')'), lit ' ', node('block', ...), lit ' ', lit 'end') end
    local function fcall(f, ...) local ks = { lit '(' }; for i, a in ipairs({ ... }) do if i > 1 then ks[#ks + 1] = lit ', ' end; ks[#ks + 1] = a end; ks[#ks + 1] = lit ')'; return node('function_call', id(f), node('arguments', unpack(ks))) end
    local function ret(e) return node('return_statement', lit 'return', lit ' ', node('expression_list', e)) end

    it('conservation: the call template carries the family\'s holes once each and the helper names the parameter at every lift site', function()
        local F = fixture(); if not F then return end
        local X, g = extracted(F)
        assert.same(A.hole_names(g.template), A.hole_names(X.call))
        local CS = A.sites(X.call)
        for _, h in ipairs(A.hole_names(X.call)) do assert.equals(1, #CS[h].sites, h) end
        assert.equals(2, #X.lifts)
        local rules = {}
        for _, l in ipairs(X.lifts) do
            rules[l.hole] = l.rule
            -- the helper's body sits under local function <name>(..) return <body> end: kids[8] the block, [1] the return, [3] the expression_list, [1] the body
            local body = X.helper.kids[8].kids[1].kids[3].kids[1]
            local there = A.locate_at(body, l.at)
            assert.is_truthy(A.cst_print(there):find(l.param, 1, true), l.hole .. ' lifted at ' .. A.key(l.at) .. ': ' .. A.cst_print(there))
        end
        assert.same({ h1 = 'string', h2 = 'field' }, rules)
        assert.equals("scratch(require(mod)[fn](store, id))", A.cst_print(A.locate_at(X.helper.kids[8].kids[1].kids[3].kids[1], { 5, 13 })))
        -- the helper's text is a Lua chunk; the call it builds is a function that has not run
        local src = 'local cmd, live, whole_graph, mat_df, scratch = ...\n' .. A.cst_print(X.helper) .. '\nreturn report_cmd'
        local chunk = assert(loadstring(src))
        local report_cmd = chunk(nil, function() return nil end, nil, nil, nil)
        assert.equals('function', type(report_cmd('cartograph.untangle', 'report_blocks')))
    end)

    it('the six members become six calls, each verified by the reader and reading back the member\'s own values', function()
        local F = fixture(); if not F then return end
        local X, g = extracted(F)
        local want = { "report_cmd('cartograph.untangle', 'report_blocks')", "report_cmd('cartograph.optimize', 'report')", "report_cmd('cartograph.narrow', 'report')",
            "report_cmd('cartograph.narrow', 'param_report')", "report_cmd('cartograph.narrow', 'devirt_report')", "report_cmd('cartograph.lens', 'report')" }
        local calls = {}
        for i = 1, 6 do
            local r = A.extract_call(X, g.values[i])
            assert.is_true(r.ok, r.why); assert.is_true(r.verified)
            assert.equals(want[i], A.cst_print(r.term))
            calls[i] = r.term
            local back = A.extract_call_of(X, r.term)
            for h, v in pairs(g.values[i]) do assert.is_true(A.eq(back[h], v), h) end
        end
        -- the calls are a family whose template is the call template, the values unchanged
        local g2 = A.generalize(calls, { need = 100 })
        assert.equals(A.show(X.call.body), A.show(g2.template.body))
        assert.is_true(A.instance_of(g2.template, X.call) and A.instance_of(X.call, g2.template))
        for i = 1, 6 do for h, v in pairs(g.values[i]) do assert.is_true(A.eq(g2.values[i][h], v)) end end
        assert.is_nil(A.extract_call_of(X, calls[1].kids[1])) -- an identifier is not a call of the helper
    end)

    it('semantics: under one fake environment the extracted call behaves as the callback did, and the require stays inside the callback', function()
        local F = fixture(); if not F then return end
        local X, g = extracted(F)
        local function run(body_src, mod, fn)
            local log = {}
            local env = {
                live = function() return { focused = 7, node = function(id) return { kind = 'function', file = 'f.lua', id = id } end } end,
                mat_df = function(_, file) log[#log + 1] = 'mat_df ' .. file end,
                scratch = function(x) log[#log + 1] = 'scratch ' .. tostring(x) end,
                require = function(m) log[#log + 1] = 'require ' .. m; return setmetatable({}, { __index = function(_, k) return function(_, id) return m .. '.' .. k .. '(' .. tostring(id) .. ')' end end }) end,
                vim = { notify = function(msg) log[#log + 1] = 'notify ' .. msg end, log = { levels = { WARN = 2 } } },
                setmetatable = setmetatable, tostring = tostring, type = type,
            }
            local chunk = assert(loadstring(body_src))
            setfenv(chunk, env)
            local f = chunk(mod, fn)
            log[#log + 1] = 'built'
            f()
            return log
        end
        local helper = A.cst_print(X.helper)
        for i = 1, 6 do
            local V = g.values[i]
            local orig = run(F.members[SIX[i]].source, nil, nil)
            local call = run(helper .. '\nreturn ' .. A.cst_print(A.extract_call(X, V).term), nil, nil)
            assert.same(orig, call)
            assert.equals('built', call[1]) -- the require happens when the callback runs, not when the call is made
            local req
            for k, l in ipairs(call) do if l == 'require ' .. V.h1.v then req = k end end
            assert.is_true(req ~= nil and req > 1)
            assert.equals('scratch ' .. V.h1.v .. '.' .. V.h2.v .. '(7)', call[#call])
        end
    end)

    it('the lift rules by name: string content, a field name, a number; a variable, a hedge, a computed value and two ways refused', function()
        -- string and number
        local T = A.template(fdef(ret(fcall('g', str(hole 'h1'), node('number', hole 'h2')))))
        local X = assert(A.extract(T, { name = 'mk' }))
        assert.equals("local function mk(p1, p2)\n    return function () return g(p1, p2) end\nend", A.cst_print(X.helper))
        local r = A.extract_call(X, { h1 = lit 'a', h2 = lit '3' })
        assert.is_true(r.ok); assert.equals("mk('a', 3)", A.cst_print(r.term))
        -- a field name becomes a bracket index and is passed quoted
        local T2 = A.template(fdef(ret(fcall('g', node('dot_index_expression', id 'x', lit '.', node('identifier', hole 'h'))))))
        local X2 = assert(A.extract(T2, { name = 'mk' }))
        assert.equals("local function mk(p1)\n    return function () return g(x[p1]) end\nend", A.cst_print(X2.helper))
        assert.equals("mk('f')", A.cst_print(A.extract_call(X2, { h = lit 'f' }).term))
        assert.same({ h = lit 'f' }, A.extract_call_of(X2, A.extract_call(X2, { h = lit 'f' }).term))
        -- a variable: refused by name
        local T3 = A.template(fdef(ret(fcall('g', node('identifier', hole 'h')))))
        local X3, why3 = A.extract(T3, { name = 'mk' })
        assert.is_nil(X3); assert.is_truthy(why3:find('names a variable', 1, true), why3)
        -- the object of a dot index is a variable too
        local T3b, why3b = A.extract(A.template(fdef(ret(fcall('g', node('dot_index_expression', node('identifier', hole 'h'), lit '.', id 'f'))))), { name = 'mk' })
        assert.is_nil(T3b); assert.is_truthy(why3b:find('names a variable', 1, true), why3b)
        -- a hedge: refused
        local T4 = A.template(fdef(ret(fcall('g', hole('h', true)))))
        local X4, why4 = A.extract(T4, { name = 'mk' })
        assert.is_nil(X4); assert.is_truthy(why4:find('is a hedge', 1, true), why4)
        -- the same hole lifted two ways: refused
        local T5 = A.template(fdef(ret(fcall('g', str(hole 'h'), node('number', hole 'h')))))
        local X5, why5 = A.extract(T5, { name = 'mk' })
        assert.is_nil(X5); assert.is_truthy(why5:find('lifted two ways', 1, true), why5)
        -- the same hole quoted twice is one argument
        local T6 = A.template(fdef(ret(fcall('g', str(hole 'h'), node('dot_index_expression', id 'x', lit '.', node('identifier', hole 'h'))))))
        local X6 = assert(A.extract(T6, { name = 'mk' }))
        assert.equals("local function mk(p1)\n    return function () return g(p1, x[p1]) end\nend", A.cst_print(X6.helper))
        assert.equals(1, #A.sites(X6.call).h.sites)
        -- not a function: refused; a computed value: the writer refuses
        local X7, why7 = A.extract(A.template(fcall('g', str(hole 'h'))), { name = 'mk' })
        assert.is_nil(X7); assert.is_truthy(why7:find('not a function_definition', 1, true), why7)
        local r8 = A.extract_call(X, { h1 = fcall('name'), h2 = lit '3' })
        assert.is_false(r8.ok); assert.equals('refused', r8.absence); assert.is_truthy(r8.why:find('not a literal', 1, true), r8.why)
        local r9 = A.extract_call(X, { h1 = lit 'a' })
        assert.is_false(r9.ok); assert.equals('absent', r9.absence)
    end)

    it('reindent moves the body\'s own newlines and leaves strings and comments alone', function()
        local body = fdef(lit '\n    ', node('comment', lit '-- a\n'), node('string', lit '[[', node('string_content', lit 'x\ny'), lit ']]'), lit '\n')
        local t = A.reindent(body, '  ')
        assert.equals("function () \n      -- a\n[[x\ny]]\n   end", A.cst_print(t))
        assert.equals(A.show(body), A.show(A.reindent(body, '')))
    end)

    it('the price on the fixture (FOLD.md\'s units): far below the six as they stand, above the family record by the helper\'s own words', function()
        local F = fixture(); if not F then return end
        local X, g = extracted(F)
        local six = six_of(F)
        local raw_n, raw_b = 0, 0
        for _, m in ipairs(six) do raw_n = raw_n + A.size(m); raw_b = raw_b + A.text_size(m) end
        local before_n = A.family_dl(g.template, g.values)
        local before_b = A.family_dl(g.template, g.values, { cost = A.text_size })
        local after_n = A.size(X.helper) + A.family_dl(X.call, g.values)
        local after_b = A.text_size(X.helper) + A.family_dl(X.call, g.values, { cost = A.text_size })
        assert.same({ 1392, 2614 }, { raw_n, raw_b })
        assert.same({ 245, 572 }, { before_n, before_b })
        assert.same({ 285, 692 }, { after_n, after_b })
        assert.is_true(after_n < raw_n and after_b < raw_b)
        assert.is_true(after_n > before_n and after_b > before_b) -- the declaration, the parameters and one reference per use are the program's own price
    end)
end)

describe('destinations (DESTINATION.md; Tsantalis and Chatzigeorgiou 2009, Move Method identification): where a moved text may go, ranked, with the preconditions as refusals', function()
    local okf, FX = pcall(dofile, 'experiments/lua-terms-2026-09-18.lua')
    local function fixture() if not okf then return pending('experiments/lua-terms-2026-09-18.lua not loadable: ' .. tostring(FX)) end return FX end
    local function set(...) local S = {}; for _, k in ipairs({ ... }) do S[k] = true end; return S end
    local function sorted(S) local r = {}; for k in pairs(S) do r[#r + 1] = k end; table.sort(r); return r end
    local function id(s) return node('identifier', lit(s)) end
    local function decl(names, ...) -- local a, b = e1, e2
        local vl = {}
        for i, n in ipairs(names) do if i > 1 then vl[#vl + 1] = lit ', ' end; vl[#vl + 1] = id(n) end
        local el = {}
        for i, e in ipairs({ ... }) do if i > 1 then el[#el + 1] = lit ', ' end; el[#el + 1] = e end
        return node('variable_declaration', lit 'local', lit ' ', node('assignment_statement', node('variable_list', unpack(vl)), lit ' ', lit '=', lit ' ', node('expression_list', unpack(el))))
    end
    local function fcall(f, ...) local ks = { lit '(' }; for i, a in ipairs({ ... }) do if i > 1 then ks[#ks + 1] = lit ', ' end; ks[#ks + 1] = a end; ks[#ks + 1] = lit ')'; return node('function_call', id(f), node('arguments', unpack(ks))) end
    local function localfn(name, body) return node('function_declaration', lit 'local', lit ' ', lit 'function', lit ' ', id(name), node('parameters', lit '(', id 'p', lit ')'), lit ' ', node('block', body), lit ' ', lit 'end') end

    it('lua_names on the fixture callback: free = the helpers it calls plus the library, binds its locals, no assignment', function()
        local F = fixture(); if not F then return end
        local N = A.lua_names(F.members[1].term)
        assert.same({ 'live', 'mat_df', 'require', 'scratch', 'vim' }, sorted(N.free))
        assert.same({ 'id', 'n', 'store' }, sorted(N.binds))
        assert.same({}, sorted(N.assigns))
        assert.same({ 'cartograph.untangle' }, N.requires)
        -- the field after a dot and a table key are not reads; a for variable and a parameter are binds
        local t = node('chunk', decl({ 'a' }, node('dot_index_expression', id 'x', lit '.', id 'field')),
            node('for_generic_clause', node('variable_list', id 'k', lit ', ', id 'v'), lit ' ', lit 'in', lit ' ', node('expression_list', fcall('pairs', id 'a'))),
            node('table_constructor', lit '{', node('field', id 'key', lit ' = ', id 'val'), lit '}'),
            node('assignment_statement', node('variable_list', id 'g'), lit ' = ', node('expression_list', id 'a')))
        local M2 = A.lua_names(t)
        assert.same({ 'g', 'pairs', 'val', 'x' }, sorted(M2.free)) -- g is assigned: a free name and an assignment, not a bind; a is local
        assert.is_true(M2.assigns.g == true and M2.binds.g == nil)
        assert.same({ 'a', 'k', 'v' }, sorted(M2.binds))
        -- the block's own scope: nested binds do not count
        local blk = node('block', decl({ 'outer' }, (lit '1')), localfn('helper', decl({ 'inner' }, (lit '2'))), fcall('use', id 'outer'))
        assert.same({ 'helper', 'outer' }, sorted(A.lua_scope_binds(blk)))
        assert.same({ 'inner', 'outer', 'p', 'helper' }, (function() local r = sorted(A.lua_names(blk).binds); table.sort(r, function(a, b) return ({ inner = 1, outer = 2, p = 3, helper = 4 })[a] < ({ inner = 1, outer = 2, p = 3, helper = 4 })[b] end); return r end)())
    end)

    it('the paper\'s Figure 2 shape: three targets with one accessed entity each tie, the smaller home first, all tied suggested', function()
        local m = { name = 'removeLocation', entities = set('taskManager_x', 'locationManager_remove', 'location_y'), free = {}, calls = { { home = 'Task' } } }
        local homes = {
            { id = 'TaskManager', entities = set('taskManager_x', 'a', 'b', 'c'), bound = {}, reach = set('Task', 'TaskManager') },
            { id = 'LocationManager', entities = set('locationManager_remove', 'd'), bound = {}, reach = set('Task', 'LocationManager') },
            { id = 'Location', entities = set('location_y', 'e'), bound = {}, reach = set('Task', 'Location') },
            { id = 'Elsewhere', entities = set('z'), bound = {}, reach = set('Task') },
        }
        local r = A.destinations(m, homes, {})
        assert.same({ 'Location', 'LocationManager', 'TaskManager' }, { r.candidates[1].id, r.candidates[2].id, r.candidates[3].id }) -- 1 - 1/4, 1 - 1/4, 1 - 1/6
        assert.equals(3, #r.candidates) -- Elsewhere holds no accessed entity: not a candidate (step 1)
        assert.equals(2, #r.suggested) -- the two smallest tie at distance 0.75 and are both suggested
        assert.same({ 'Location', 'LocationManager' }, { r.suggested[1].id, r.suggested[2].id })
        assert.equals(0.75, r.candidates[1].distance)
        -- with `all`, a home holding nothing accessed is listed as the prototype's candidate, last
        local r2 = A.destinations(m, homes, { all = true })
        assert.equals('Elsewhere', r2.candidates[4].id); assert.equals('prototype', r2.candidates[4].provenance); assert.equals('paper', r2.candidates[1].provenance)
        -- Definition 2: a home the text already belongs to does not count the text among its entities
        local r3 = A.destinations({ name = 'f', entities = set('a'), free = {}, calls = {} }, { { id = 'H', entities = set('a', 'f'), bound = {}, holds = true }, { id = 'K', entities = set('a', 'g'), bound = {} } }, {})
        assert.equals(0, r3.candidates[1].distance); assert.equals('H', r3.candidates[1].id)
        -- the access count sorts before the distance: a home holding more of the text's entities comes first even when farther
        local r4 = A.destinations({ name = 'f', entities = set('a', 'b'), free = {}, calls = {} },
            { { id = 'Near', entities = set('a'), bound = {} }, { id = 'Holds2', entities = set('a', 'b', 'c', 'd', 'e', 'f'), bound = {} } }, {})
        assert.same({ 'Holds2', 'Near' }, { r4.candidates[1].id, r4.candidates[2].id })
        assert.is_true(r4.candidates[2].distance < r4.candidates[1].distance)
    end)

    it('the preconditions refuse by name: a clashing local, an unbound name, an unreachable call, an assigned outer name; plumbing and passing turn refusals into prices', function()
        local m = { name = 'helper', entities = set('live', 'scratch'), free = set('live', 'scratch', 'vim'), calls = { { home = 'A' }, { home = 'B' } } }
        local homes = {
            { id = 'A', entities = set('live', 'scratch', 'x'), bound = set('live', 'scratch', 'x') },
            { id = 'B', entities = set('live', 'scratch'), bound = set('live', 'scratch', 'helper') },
            { id = 'C', entities = set('live', 'scratch'), bound = set('live', 'scratch'), reach = set('A', 'B', 'C') },
            { id = 'D', entities = set('live'), bound = set('live'), reach = set('A', 'B', 'D') },
            { id = 'E', entities = set('live', 'scratch'), bound = set('live', 'scratch'), plumbing = 7 },
        }
        local r = A.destinations(m, homes, { helper_cost = 100, call_extra = 2 })
        local by = {}
        for _, c in ipairs(r.candidates) do by[c.id] = c end
        assert.is_false(by.A.ok); assert.equals('not visible from the call in B', by.A.why[1])
        assert.is_false(by.B.ok); assert.equals('a local helper is already bound at B', by.B.why[1])
        assert.is_true(by.C.ok); assert.equals(100, by.C.cost)
        assert.is_false(by.D.ok); assert.equals('scratch not bound at D', by.D.why[1])
        assert.is_true(by.E.ok); assert.equals(107, by.E.cost); assert.same({ 'A', 'B' }, by.E.after_plumbing)
        assert.equals('C', r.suggested[1].id) -- the first ok candidate in the paper's order; E has the same access count and a greater distance
        assert.same({ 'C', 'E' }, { r.by_price[1].id, r.by_price[2].id })
        -- vim is outside the system boundary: not required to be bound anywhere
        -- passing: the unbound name becomes a parameter at a cost per call
        local r2 = A.destinations(m, homes, { helper_cost = 100, call_extra = 2, parameterize = true })
        for _, c in ipairs(r2.candidates) do by[c.id] = c end
        assert.is_true(by.D.ok); assert.same({ 'scratch' }, by.D.parameterized); assert.equals(104, by.D.cost)
        -- quality precondition 1: an assigned outer name refuses everywhere
        local r3 = A.destinations({ name = 'h', entities = set('live'), free = set('live'), assigns = set('count'), calls = {} }, homes, {})
        assert.is_truthy(r3.refused_all:find('assigns an outer name (count)', 1, true))
        for _, c in ipairs(r3.candidates) do assert.is_false(c.ok) end
        assert.equals(0, #r3.suggested)
        -- copies: a composite home pays the helper per copy
        local r4 = A.destinations(m, { { id = 'two', entities = set('live', 'scratch'), bound = set('live', 'scratch'), reach = set('A', 'B'), copies = 2 } }, { helper_cost = 100 })
        assert.equals(200, r4.candidates[1].cost)
        -- the Jaccard distance itself
        assert.equals(0.5, A.jaccard_distance(set('a', 'b'), set('a', 'b', 'c', 'd'))); assert.equals(0, A.jaccard_distance({}, {})); assert.equals(1, A.jaccard_distance(set 'a', set 'b'))
    end)

    it('lua_positions: the range after the last needed binding and before the first use, with the four picks named; refusals by name', function()
        local blk = node('block',
            decl({ 'live', 'scratch' }, id 'H_live', id 'H_scratch'),   -- 1
            lit '\n', node('comment', lit '-- c'),                       -- 2, 3
            decl({ 'other' }, (lit '1')),                                -- 4
            localfn('reorder', fcall('x')),                              -- 5
            decl({ 'late' }, (lit '2')),                                 -- 6: a declaration after the opening run is not part of it
            fcall('cmd', (lit "'A'"), fcall('other_thing')),             -- 7
            node('comment', lit '-- the use'),                           -- 8
            fcall('cmd', (lit "'B'"), fcall('helper')),                  -- 9
            fcall('cmd', (lit "'C'"), fcall('helper')))                  -- 10
        local P = assert(A.lua_positions(blk, { needs = set('live', 'scratch', 'vim'), calls = { 9, 10 }, name = 'helper' }))
        assert.same({ from = 1, to = 9 }, { from = P.from, to = P.to })
        assert.same({ after_needed = 1, after_opening = 4, with_helpers = 5, before_use = 7 }, P.picks)
        -- a needed name bound only after the first use: refused; a clash: refused; no call: refused
        local _, why = A.lua_positions(node('block', fcall('cmd', fcall('helper')), decl({ 'live' }, id 'x')), { needs = set('live'), calls = { 1 } })
        assert.is_truthy(why and why:find('precedes the binding of live', 1, true), tostring(why))
        local _, why2 = A.lua_positions(blk, { needs = {}, calls = { 9 }, name = 'reorder' })
        assert.is_truthy(why2:find('reorder is already bound at kid 5', 1, true), why2)
        local _, why3 = A.lua_positions(blk, { needs = {}, calls = {} })
        assert.is_truthy(why3:find('no call', 1, true))
        -- the opening run never reaches past the needed binding when nothing else is bound
        local P2 = assert(A.lua_positions(node('block', decl({ 'live' }, id 'x'), fcall('cmd', fcall('helper'))), { needs = set('live'), calls = { 2 } }))
        assert.same({ after_needed = 1, after_opening = 1, before_use = 1 }, P2.picks)
    end)
end)

describe('resolution (RESOLVE.md; Néron, Tolmach, Visser, Wachsmuth 2015: scope graphs, resolution paths, the algorithm of Fig. 18)', function()
    local okf, FX = pcall(dofile, 'experiments/lua-terms-2026-09-18.lua')
    local function fixture() if not okf then return pending('experiments/lua-terms-2026-09-18.lua not loadable: ' .. tostring(FX)) end return FX end
    local function sorted(S) local r = {}; for k in pairs(S) do r[#r + 1] = k end; table.sort(r); return r end
    -- a resolution as `name#site by path`, ABSENT, or AMBIGUOUS{..}
    local function res(G, r)
        local R = A.resolve(G, r)
        if R.absent then return 'ABSENT' end
        local t = {}
        for _, e in ipairs(R.entries) do t[#t + 1] = G.decls[e.decl].name .. tostring(G.decls[e.decl].site) .. ' by ' .. A.show_path(G, e.path) end
        table.sort(t)
        return (R.ambiguous and 'AMBIGUOUS ' or '') .. table.concat(t, ' | ')
    end
    local id = function(s) return node('identifier', lit(s)) end
    local function decl(names, ...) local vl = {}; for i, n in ipairs(names) do if i > 1 then vl[#vl + 1] = lit ', ' end; vl[#vl + 1] = id(n) end; local el = {}; for i, e in ipairs({ ... }) do if i > 1 then el[#el + 1] = lit ', ' end; el[#el + 1] = e end; return node('variable_declaration', lit 'local', lit ' ', node('assignment_statement', node('variable_list', unpack(vl)), lit ' ', lit '=', lit ' ', node('expression_list', unpack(el)))) end
    local function fcall(f, ...) local ks = { lit '(' }; for i, a in ipairs({ ... }) do if i > 1 then ks[#ks + 1] = lit ', ' end; ks[#ks + 1] = a end; ks[#ks + 1] = lit ')'; return node('function_call', type(f) == 'string' and id(f) or f, node('arguments', unpack(ks))) end
    local function fdef(params, ...) local pk = { lit '(' }; for i, p in ipairs(params) do if i > 1 then pk[#pk + 1] = lit ', ' end; pk[#pk + 1] = id(p) end; pk[#pk + 1] = lit ')'; return node('function_definition', lit 'function', lit ' ', node('parameters', unpack(pk)), lit ' ', node('block', ...), lit ' ', lit 'end') end
    local function localfn(name, params, ...) local pk = { lit '(' }; for i, p in ipairs(params) do if i > 1 then pk[#pk + 1] = lit ', ' end; pk[#pk + 1] = id(p) end; pk[#pk + 1] = lit ')'; return node('function_declaration', lit 'local', lit ' ', lit 'function', lit ' ', id(name), node('parameters', unpack(pk)), lit ' ', node('block', ...), lit ' ', lit 'end') end
    local function dot(a, b) return node('dot_index_expression', type(a) == 'string' and id(a) or a, lit '.', id(b)) end
    local function str(s) return node('string', lit "'", node('string_content', lit(s)), lit "'") end
    local function ret(e) return node('return_statement', lit 'return', lit ' ', node('expression_list', e)) end
    local function chunk(...) return node('chunk', ...) end
    -- the class and the end of a reference named `name` under a term path, alias hops followed
    local function where(G, file, name)
        for rid, r in pairs(G.refs) do
            if r.name == name and r.file == file and r.kind ~= 'field' and r.kind ~= 'probe' then
                local T = A.resolve_through(G, rid)
                local d = T.ends[1] and G.decls[T.ends[1].decl]
                return A.resolution_class(G, T), d and (d.name .. '@' .. tostring(d.file) .. ':' .. d.kind) or nil, T
            end
        end
    end

    it('Fig. 5 and Fig. 6: duplicate declarations resolve to both; lexical shadowing by the shorter path', function()
        -- Fig. 5: def a1 = 0; def b2 = a3 + c4; def b5 = b6 + d7; def c8 = 0
        local G = A.scope_graph()
        local s1 = A.sg_scope(G, nil, 'global')
        A.sg_decl(G, s1, 'a', { site = 1 }); A.sg_decl(G, s1, 'b', { site = 2 }); A.sg_decl(G, s1, 'b', { site = 5 }); A.sg_decl(G, s1, 'c', { site = 8 })
        local a3, c4, b6, d7 = A.sg_ref(G, s1, 'a', { site = 3 }), A.sg_ref(G, s1, 'c', { site = 4 }), A.sg_ref(G, s1, 'b', { site = 6 }), A.sg_ref(G, s1, 'd', { site = 7 })
        assert.equals('a1 by D(a)', res(G, a3)); assert.equals('c8 by D(c)', res(G, c4))
        assert.equals('AMBIGUOUS b2 by D(b) | b5 by D(b)', res(G, b6))
        assert.equals('ABSENT', res(G, d7))
        -- Fig. 6: def f1 = fix f2 { fun n3 { ifz n4 then 1 else n5*f6(n7-1) } }; def n8 = f9 5
        G = A.scope_graph()
        s1 = A.sg_scope(G, nil, 'global'); local s2 = A.sg_scope(G, s1, 'fix'); local s3 = A.sg_scope(G, s2, 'fun')
        A.sg_decl(G, s1, 'f', { site = 1 }); A.sg_decl(G, s2, 'f', { site = 2 }); A.sg_decl(G, s3, 'n', { site = 3 }); A.sg_decl(G, s1, 'n', { site = 8 })
        local n4, f6, n7, f9 = A.sg_ref(G, s3, 'n', { site = 4 }), A.sg_ref(G, s3, 'f', { site = 6 }), A.sg_ref(G, s3, 'n', { site = 7 }), A.sg_ref(G, s1, 'f', { site = 9 })
        assert.equals('f2 by P·D(f)', res(G, f6)) -- P·D beats P·P·D
        assert.equals('n3 by D(n)', res(G, n4)); assert.equals('n3 by D(n)', res(G, n7))
        assert.equals('f1 by D(f)', res(G, f9))
        assert.is_true(A.path_less({ { k = 'D' } }, { { k = 'P' }, { k = 'D' } }))
        assert.is_true(A.path_less({ { k = 'I' }, { k = 'I' }, { k = 'D' } }, { { k = 'P' }, { k = 'D' } })) -- IP
        assert.is_false(A.path_less({ { k = 'P' }, { k = 'D' } }, { { k = 'P' }, { k = 'D' } }))
    end)

    it('Fig. 7, 8, 9: imports beat parents, local declarations beat imports, no parent step after an import', function()
        -- Fig. 7: def c1; module A2 { import B3; def a4 = b5 + c6 }; module B7 { import C8; def b9 = 0 }; module C10 { def b11 = 1; def c12 = b13 }
        local G = A.scope_graph()
        local s1 = A.sg_scope(G, nil, 'global')
        A.sg_decl(G, s1, 'c', { site = 1 })
        local s2, s3, s4 = A.sg_scope(G, s1, 'A'), A.sg_scope(G, s1, 'B'), A.sg_scope(G, s1, 'C')
        A.sg_decl(G, s1, 'A', { site = 2, assoc = s2 }); A.sg_decl(G, s1, 'B', { site = 7, assoc = s3 }); A.sg_decl(G, s1, 'C', { site = 10, assoc = s4 })
        local B3 = A.sg_ref(G, s2, 'B', { site = 3 }); A.sg_import(G, s2, B3)
        A.sg_decl(G, s2, 'a', { site = 4 }); local b5, c6 = A.sg_ref(G, s2, 'b', { site = 5 }), A.sg_ref(G, s2, 'c', { site = 6 })
        local C8 = A.sg_ref(G, s3, 'C', { site = 8 }); A.sg_import(G, s3, C8); A.sg_decl(G, s3, 'b', { site = 9 })
        A.sg_decl(G, s4, 'b', { site = 11 }); A.sg_decl(G, s4, 'c', { site = 12 }); local b13 = A.sg_ref(G, s4, 'b', { site = 13 })
        assert.equals('c12 by I(B)·I(C)·D(c)', res(G, c6)) -- the paper's ordering: I·I·D beats P·D
        assert.equals('b9 by I(B)·D(b)', res(G, b5))         -- D < I at the second step
        assert.equals('b11 by D(b)', res(G, b13))
        assert.equals('B7 by P·D(B)', res(G, B3)); assert.equals('C10 by P·D(C)', res(G, C8))
        -- Fig. 8: def a1; module A2 { def a3; def b4 }; module C5 { import A6; def b7 = a8; def c9 = b10 }
        G = A.scope_graph(); s1 = A.sg_scope(G, nil, 'global')
        A.sg_decl(G, s1, 'a', { site = 1 })
        local sA, sC = A.sg_scope(G, s1, 'A'), A.sg_scope(G, s1, 'C')
        A.sg_decl(G, s1, 'A', { site = 2, assoc = sA }); A.sg_decl(G, sA, 'a', { site = 3 }); A.sg_decl(G, sA, 'b', { site = 4 })
        A.sg_decl(G, s1, 'C', { site = 5, assoc = sC })
        local A6 = A.sg_ref(G, sC, 'A', { site = 6 }); A.sg_import(G, sC, A6)
        A.sg_decl(G, sC, 'b', { site = 7 }); local a8, b10 = A.sg_ref(G, sC, 'a', { site = 8 }), A.sg_ref(G, sC, 'b', { site = 10 })
        assert.equals('b7 by D(b)', res(G, b10))      -- D < I
        assert.equals('a3 by I(A)·D(a)', res(G, a8))  -- I < P
        -- Fig. 9: def a1; module B2 {}; module C3 { def a4; module D5 { import B6; def e7 = a8 } }
        G = A.scope_graph(); s1 = A.sg_scope(G, nil, 'global')
        A.sg_decl(G, s1, 'a', { site = 1 })
        local sB, sC3 = A.sg_scope(G, s1, 'B'), A.sg_scope(G, s1, 'C')
        A.sg_decl(G, s1, 'B', { site = 2, assoc = sB }); A.sg_decl(G, s1, 'C', { site = 3, assoc = sC3 })
        A.sg_decl(G, sC3, 'a', { site = 4 })
        local sD = A.sg_scope(G, sC3, 'D'); A.sg_decl(G, sC3, 'D', { site = 5, assoc = sD })
        local B6 = A.sg_ref(G, sD, 'B', { site = 6 }); A.sg_import(G, sD, B6)
        A.sg_decl(G, sD, 'e', { site = 7 }); local a8b = A.sg_ref(G, sD, 'a', { site = 8 })
        assert.equals('a4 by P·D(a)', res(G, a8b)) -- I(B)·P·D(a1) is not well-formed
    end)

    it('Fig. 11, 14, 15: an import never resolves itself; the three let flavours; a qualified name through an anonymous scope', function()
        -- Fig. 11: module A1 { module A2 { def a3 } }; import A4; def b5 = a6
        local G = A.scope_graph()
        local s1 = A.sg_scope(G, nil, 'root'); local sA1 = A.sg_scope(G, s1, 'A1'); local sA2 = A.sg_scope(G, sA1, 'A2')
        A.sg_decl(G, s1, 'A', { site = 1, assoc = sA1 }); A.sg_decl(G, sA1, 'A', { site = 2, assoc = sA2 }); A.sg_decl(G, sA2, 'a', { site = 3 })
        local A4 = A.sg_ref(G, s1, 'A', { site = 4 }); A.sg_import(G, s1, A4)
        A.sg_decl(G, s1, 'b', { site = 5 }); local a6 = A.sg_ref(G, s1, 'a', { site = 6 })
        assert.equals('A1 by D(A)', res(G, A4)); assert.equals('ABSENT', res(G, a6))
        -- Fig. 14: def a1 = 0; def b2 = 1; def c3 = 2; let/letrec/letpar a4 = c5, b6 = a7, c8 = b9 in a10 + b11 + c12
        local function lets(flavour)
            local G_ = A.scope_graph(); local g = A.sg_scope(G_, nil, 'global')
            A.sg_decl(G_, g, 'a', { site = 1 }); A.sg_decl(G_, g, 'b', { site = 2 }); A.sg_decl(G_, g, 'c', { site = 3 })
            local refs = {}
            if flavour == 'letrec' then
                local s = A.sg_scope(G_, g, 'letrec')
                A.sg_decl(G_, s, 'a', { site = 4 }); A.sg_decl(G_, s, 'b', { site = 6 }); A.sg_decl(G_, s, 'c', { site = 8 })
                refs.c5 = A.sg_ref(G_, s, 'c', { site = 5 }); refs.a7 = A.sg_ref(G_, s, 'a', { site = 7 }); refs.b9 = A.sg_ref(G_, s, 'b', { site = 9 })
            elseif flavour == 'letpar' then
                local s = A.sg_scope(G_, g, 'letpar')
                A.sg_decl(G_, s, 'a', { site = 4 }); A.sg_decl(G_, s, 'b', { site = 6 }); A.sg_decl(G_, s, 'c', { site = 8 })
                refs.c5 = A.sg_ref(G_, g, 'c', { site = 5 }); refs.a7 = A.sg_ref(G_, g, 'a', { site = 7 }); refs.b9 = A.sg_ref(G_, g, 'b', { site = 9 })
            else -- sequential: one scope per binding, the initializer in the scope before it
                local s2 = A.sg_scope(G_, g, 'let1'); refs.c5 = A.sg_ref(G_, g, 'c', { site = 5 }); A.sg_decl(G_, s2, 'a', { site = 4 })
                local s3 = A.sg_scope(G_, s2, 'let2'); refs.a7 = A.sg_ref(G_, s2, 'a', { site = 7 }); A.sg_decl(G_, s3, 'b', { site = 6 })
                local s4 = A.sg_scope(G_, s3, 'let3'); refs.b9 = A.sg_ref(G_, s3, 'b', { site = 9 }); A.sg_decl(G_, s4, 'c', { site = 8 })
            end
            return { c5 = res(G_, refs.c5), a7 = res(G_, refs.a7), b9 = res(G_, refs.b9) }
        end
        assert.same({ c5 = 'c3 by D(c)', a7 = 'a4 by D(a)', b9 = 'b6 by D(b)' }, lets('let'))
        assert.same({ c5 = 'c8 by D(c)', a7 = 'a4 by D(a)', b9 = 'b6 by D(b)' }, lets('letrec'))
        assert.same({ c5 = 'c3 by D(c)', a7 = 'a1 by D(a)', b9 = 'b2 by D(b)' }, lets('letpar'))
        -- Fig. 15: module B1 { module C2 { def c3 = D4.f5(3) }; module D6 { def f7 } }: an anonymous scope with no parent imports D4
        G = A.scope_graph(); s1 = A.sg_scope(G, nil, 'root')
        local sB = A.sg_scope(G, s1, 'B'); A.sg_decl(G, s1, 'B', { site = 1, assoc = sB })
        local sC = A.sg_scope(G, sB, 'C'); A.sg_decl(G, sB, 'C', { site = 2, assoc = sC })
        local sD = A.sg_scope(G, sB, 'D'); A.sg_decl(G, sB, 'D', { site = 6, assoc = sD }); A.sg_decl(G, sD, 'f', { site = 7 })
        A.sg_decl(G, sC, 'c', { site = 3 })
        local D4 = A.sg_ref(G, sC, 'D', { site = 4 })
        local anon = A.sg_scope(G, nil, 'qualified'); A.sg_import(G, anon, D4)
        local f5 = A.sg_ref(G, anon, 'f', { site = 5 })
        assert.equals('f7 by I(D)·D(f)', res(G, f5))
        assert.equals('D6 by P·D(D)', res(G, D4))
        -- with a parent, the anonymous scope would leak the lexical context: a name of C's own is not reachable through it
        local c_in_anon = A.sg_ref(G, anon, 'c', { site = 99 })
        assert.equals('ABSENT', res(G, c_in_anon))
        -- two imports of one scope: a declaration one import away beats one two imports away (D < I at the second step)
        G = A.scope_graph(); s1 = A.sg_scope(G, nil, 'root')
        local sA, sB2, sD2, sC2 = A.sg_scope(G, s1, 'A'), A.sg_scope(G, s1, 'B'), A.sg_scope(G, s1, 'D'), A.sg_scope(G, s1, 'C')
        A.sg_decl(G, s1, 'A', { site = 1, assoc = sA }); A.sg_decl(G, s1, 'B', { site = 2, assoc = sB2 }); A.sg_decl(G, s1, 'D', { site = 3, assoc = sD2 }); A.sg_decl(G, s1, 'C', { site = 4, assoc = sC2 })
        A.sg_decl(G, sA, 'x', { site = 5 }); A.sg_decl(G, sD2, 'x', { site = 6 })
        local Dref = A.sg_ref(G, sB2, 'D', { site = 7 }); A.sg_import(G, sB2, Dref)
        local Aref, Bref = A.sg_ref(G, sC2, 'A', { site = 8 }), A.sg_ref(G, sC2, 'B', { site = 9 }); A.sg_import(G, sC2, Aref); A.sg_import(G, sC2, Bref)
        local x10 = A.sg_ref(G, sC2, 'x', { site = 10 })
        assert.equals('x5 by I(A)·D(x)', res(G, x10))
    end)

    it('the Lua mapping: local is the sequential let, local function is self-visible, fields through records, aliases followed, a module across chunks, the call edge as data', function()
        -- local x = x reads the outer x; local f = function() f() end reads the OUTER f; local function g() g() end reads itself
        local t = chunk(decl({ 'x' }, (lit '1')), decl({ 'x' }, id 'x'), decl({ 'f' }, fdef({}, fcall 'f')), localfn('g', {}, fcall 'g'))
        local G = A.lua_scope_graph(t, nil, { file = 'a' }); A.sg_link(G)
        local seen = {}
        for _, r in pairs(G.refs) do
            if r.kind ~= 'probe' then
                local Rr = A.resolve(G, r.id)
                local d = Rr.entries[1] and G.decls[Rr.entries[1].decl]
                seen[#seen + 1] = r.name .. '->' .. (d and (d.name .. ':' .. table.concat(d.site or {}, '/')) or 'absent')
            end
        end
        table.sort(seen)
        assert.same({ 'f->absent', 'g->g:4/5', 'x->x:1/3/1/1' }, seen) -- x on the right reads the first x (its identifier's true path); the inner f finds no f; g finds itself
        -- shadowing in a nested function, a parameter, a for variable, a bare assignment
        local t2 = chunk(decl({ 'store' }, (lit '1')), decl({ 'h' }, fdef({ 'p' }, decl({ 'store' }, fcall('live')), fcall('use', id 'store', id 'p'), node('assignment_statement', node('variable_list', id 'count'), lit ' = ', node('expression_list', (lit '1'))))),
            node('for_statement', node('for_generic_clause', node('variable_list', id 'k', lit ', ', id 'v'), lit ' ', lit 'in', lit ' ', node('expression_list', fcall('pairs', id 'store'))), node('block', fcall('use', id 'k', id 'v')), lit 'end'))
        G = A.lua_scope_graph(t2, nil, { file = 'b' }); A.sg_link(G)
        local by = {}
        for _, r in pairs(G.refs) do if r.kind ~= 'probe' then local T = A.resolve_through(G, r.id); local d = T.ends[1] and G.decls[T.ends[1].decl]; by[#by + 1] = r.name .. (r.kind == 'assign' and '=' or '') .. '->' .. (d and (d.kind .. ':' .. table.concat(d.site or {}, '/')) or A.resolution_class(G, T)) end end
        table.sort(by)
        assert.same({ 'count=->unresolved', 'k->loop:3/1/1/1', 'live->unresolved', 'p->parameter:2/3/5/1/3/2', 'pairs->library:', 'store->lexical:1/3/1/1', 'store->lexical:2/3/5/1/5/1/3/1/1', 'use->unresolved', 'use->unresolved', 'v->loop:3/1/1/3' }, by)
        -- a loop variable is not visible after the loop; a field of an empty record is opaque, never the lexical name
        local t3 = chunk(decl({ 'a' }, (lit '1')), decl({ 't' }, node('table_constructor', lit '{', lit '}')),
            node('for_statement', node('for_generic_clause', node('variable_list', id 'k'), lit ' ', lit 'in', lit ' ', node('expression_list', fcall('pairs', id 't'))), node('block', fcall('use', id 'k')), lit 'end'),
            fcall('use', id 'k', dot('t', 'a')))
        G = A.lua_scope_graph(t3, nil, { file = 'c' }); A.sg_link(G)
        local after_loop, field_a = {}, nil
        for _, r in pairs(G.refs) do
            if r.name == 'k' and r.site[1] == 4 then after_loop[#after_loop + 1] = A.resolution_class(G, A.resolve_through(G, r.id)) end
            if r.name == 'a' and r.kind == 'field' then field_a = A.resolution_class(G, A.resolve_through(G, r.id)) end
        end
        assert.same({ 'unresolved' }, after_loop)
        assert.equals('opaque', field_a)
    end)

    it('records, aliases, modules and the call edge: H.live resolves through the record to the constructor and on to the local function', function()
        -- commands.lua: local function live() end; local H = { live = live }; return M (M holds register calls) -- and the group: function M.register(H) local live = H.live; live() end
        local commands = chunk(localfn('live', {}, ret((lit '1'))), decl({ 'M' }, node('table_constructor', lit '{', lit '}')), decl({ 'H' }, node('table_constructor', lit '{', node('field', id 'live', lit ' = ', id 'live'), lit '}')),
            node('function_declaration', lit 'function', lit ' ', dot('M', 'register'), node('parameters', lit '(', lit ')'), lit ' ', node('block', fcall(dot(fcall('require', str 'group'), 'register'), id 'H')), lit ' ', lit 'end'), ret(id 'M'))
        local group = chunk(decl({ 'M' }, node('table_constructor', lit '{', lit '}')),
            node('function_declaration', lit 'function', lit ' ', dot('M', 'register'), node('parameters', lit '(', id 'H', lit ')'), lit ' ', node('block', decl({ 'live' }, dot('H', 'live')), fcall('live')), lit ' ', lit 'end'), ret(id 'M'))
        local G = A.lua_scope_graph(commands, nil, { file = 'commands', module = 'commands' })
        A.lua_scope_graph(group, G, { file = 'group', module = 'group' })
        A.sg_link(G)
        assert.is_truthy(G.modules.group and G.modules.commands)
        -- without the call edge: live inside register is an alias of a field of a parameter without a record: opaque
        local cls, at = where(G, 'group', 'live')
        assert.equals('opaque', cls)
        -- the module edge: require('group').register resolves to the field declared by `function M.register`
        local mcls
        for _, r in pairs(G.refs) do if r.name == 'register' and r.file == 'commands' then local T = A.resolve_through(G, r.id); mcls = A.resolution_class(G, T); assert.equals('register@group:field', G.decls[T.ends[1].decl].name .. '@' .. G.decls[T.ends[1].decl].file .. ':' .. G.decls[T.ends[1].decl].kind) end end
        assert.equals('module', mcls)
        -- the call edge, supplied as data: H's parameter in group gets the record commands.lua built
        local Hd
        for _, d in pairs(G.decls) do if d.name == 'H' and d.assoc and d.file == 'commands' then Hd = d end end
        local md = G.decls[G.modules.group]
        for _, d in ipairs(G.scopes[md.assoc].decls.register) do for _, p in ipairs(G.scopes[d.fn_scope].decls.H) do A.sg_bind_param(G, p.id, Hd.assoc) end end
        G.memo = nil
        local cls2, at2, T = where(G, 'group', 'live')
        assert.equals('call', cls2)
        assert.equals('live@commands:function', at2)
        assert.equals(3, #T.hops) -- the local alias, the record field, the constructor's value reference
        -- the paper's end is the first hop: the local alias in the group
        local d1 = G.decls[T.hops[1].entries[1].decl]
        assert.equals('live', d1.name); assert.equals('group', d1.file)
        -- resolve_name: what would `live` mean at the group's chunk scope? nothing lexical there
        local probe = A.resolve_name(G, G.chunks[2].scope, 'live')
        assert.is_true(probe.absent)
        -- an unloaded module is a module reference with no declaration
        local G2 = A.lua_scope_graph(chunk(decl({ 'u' }, fcall('require', str 'nowhere'))), nil, { file = 'c' }); A.sg_link(G2)
        local cnt = A.resolve_census(G2)
        assert.equals(1, cnt.by_class.module); assert.is_nil(cnt.by_class.unresolved); assert.equals(1, cnt.by_class.library) -- the module name stays a module reference (unloaded), `require` itself is library
        assert.is_true(A.resolve_through(G2, (function() for id, r in pairs(G2.refs) do if r.kind == 'module' then return id end end end)()).absent)
    end)

    it('the fixture: the builder places a reference for every read of lua_names and a declaration for every bind; clones.lua resolves with no ambiguity', function()
        local F = fixture(); if not F then return end
        for _, m in ipairs(F.members) do
            local N = A.lua_names(m.term)
            local G = A.lua_scope_graph(m.term, nil, { file = 'm' }); A.sg_link(G)
            local reads, binds = {}, {}
            for _, r in pairs(G.refs) do if r.kind ~= 'field' and r.kind ~= 'probe' and r.kind ~= 'module' then reads[r.name] = true end end
            for _, d in pairs(G.decls) do if d.kind ~= 'library' and d.kind ~= 'field' then binds[d.name] = true end end
            assert.same(sorted(N.reads), sorted(reads))
            assert.same(sorted(N.binds), sorted(binds))
        end
        local G = A.lua_scope_graph(F.file.term, nil, { file = 'clones', module = 'cartograph.commands.clones' }); A.sg_link(G)
        local C = A.resolve_census(G)
        assert.is_nil(C.by_class.ambiguous)
        local un = {}
        for id, e in pairs(C.refs) do if e.class == 'unresolved' and G.refs[id].kind ~= 'field' then un[G.refs[id].name] = true end end
        -- the file alone: its H aliases and its required modules are outside it, nothing else (a field of an unresolved object is unresolved with it)
        for _, n in ipairs(sorted(un)) do assert.is_true(n:match('^cartograph%.') ~= nil or ({ cmd = 1, live = 1, whole_graph = 1, mat_df = 1, scratch = 1, txn_module = 1, reveal_at = 1 })[n] ~= nil or n == 'H', n) end
        assert.is_true(C.by_class.lexical > 40 and C.by_class.opaque > 0)
    end)
end)

describe('the primitives audit (PRIMITIVES.md; REDERIVE.md\'s rule applied to the additions): the preference primitive, paths as terms, resolve from the calculus', function()
    local okf, FX = pcall(dofile, 'experiments/lua-terms-2026-09-18.lua')
    local function fixture() if not okf then return pending('experiments/lua-terms-2026-09-18.lua not loadable: ' .. tostring(FX)) end return FX end
    local function set(...) local S = {}; for _, k in ipairs({ ... }) do S[k] = true end; return S end

    it('best: the refused are never compared, a singleton returns itself, ties come back together, best is idempotent', function()
        local byv = A.by(function(c) return c.v end)
        local cands = { { id = 'a', v = 3 }, { id = 'b', v = 1, ok = false, why = { 'no' } }, { id = 'c', v = 2 }, { id = 'd', v = 2 } }
        local r = A.best(cands, byv)
        local ids = {}
        for _, c in ipairs(r) do ids[#ids + 1] = c.id end
        table.sort(ids)
        assert.same({ 'c', 'd' }, ids)                      -- b is refused although smallest; c and d tie
        assert.same(r, A.best(r, byv))                       -- idempotent
        assert.same({ cands[1] }, A.best({ cands[1] }, byv)) -- a singleton
        assert.same({}, A.best({ cands[2] }, byv))           -- a refused singleton: nothing admitted
        assert.equals(1, #A.best(cands, byv, { keep_refused = true })) -- kept, b is the minimum
        -- lex_order: Fig. 2's order over label sequences, shorter-prefix ties not ordered
        local lt = A.lex_order({ D = 1, I = 2, P = 3 })
        assert.is_true(lt({ 'D' }, { 'P', 'D' })); assert.is_true(lt({ 'I', 'I', 'D' }, { 'P', 'D' })); assert.is_false(lt({ 'P', 'D' }, { 'P', 'D' }))
        assert.is_true(lt({ { k = 'I' }, { k = 'D' } }, { { k = 'I' }, { k = 'I' }, { k = 'D' } }))
        -- then_: lexicographic composition; by with desc
        local o = A.then_(A.by(function(c) return c.acc end, true), A.by(function(c) return c.d end))
        assert.is_true(o({ acc = 2, d = 0.9 }, { acc = 1, d = 0.1 })); assert.is_true(o({ acc = 1, d = 0.1 }, { acc = 1, d = 0.2 })); assert.is_false(o({ acc = 1, d = 0.2 }, { acc = 1, d = 0.1 }))
    end)

    it('paths as terms: the language P*·I*·D is a template with two hedges and match decides well-formedness', function()
        local P, I, D_ = { k = 'P' }, { k = 'I', ref = 1 }, { k = 'D', decl = 2 }
        assert.is_true(A.well_formed_path({ D_ })); assert.is_true(A.well_formed_path({ P, P, D_ })); assert.is_true(A.well_formed_path({ I, I, D_ })); assert.is_true(A.well_formed_path({ P, I, D_ }))
        assert.is_false(A.well_formed_path({ I, P, D_ })) -- Fig. 9's forbidden shape
        assert.is_false(A.well_formed_path({ P, I }))     -- no declaration at the end
        assert.equals('(path (P) (I "1") (D "2"))', A.show(A.path_term({ P, I, D_ })))
        assert.equals(2, #A.hole_names(A.WF_PATH) - 1)
    end)

    it('the differential: resolve from the calculus (derive.lua) agrees with the algorithm of Fig. 18 on every reference of the fixture', function()
        local F = fixture(); if not F then return end
        local Dv = require 'derive'
        local hand = A.resolve
        Dv.apply_to(A, 'resolve')
        local derived = A.resolve
        A.resolve = hand
        if not (os.getenv('DERIVE') or ''):match('all') and not (os.getenv('DERIVE') or ''):match('resolve') then assert.is_true(derived ~= hand) end -- under DERIVE the hand-built one is already the derived one
        local function answer(f, G, r)
            local R = f(G, r)
            local t = {}
            for _, e in ipairs(R.entries) do t[#t + 1] = tostring(e.decl) .. ':' .. A.show_path(G, e.path) end
            table.sort(t)
            return (R.absent and 'absent' or R.ambiguous and 'ambiguous ' or '') .. table.concat(t, '|')
        end
        local n, same = 0, 0
        for _, m in ipairs(F.members) do
            local G = A.lua_scope_graph(m.term, nil, { file = 'm' }); A.sg_link(G)
            for id in pairs(G.refs) do n = n + 1; if answer(hand, G, id) == answer(derived, G, id) then same = same + 1 end end
        end
        local G = A.lua_scope_graph(F.file.term, nil, { file = 'clones', module = 'cartograph.commands.clones' }); A.sg_link(G)
        for id in pairs(G.refs) do n = n + 1; if answer(hand, G, id) == answer(derived, G, id) then same = same + 1 end end
        assert.is_true(n > 300, 'references compared: ' .. n)
        assert.equals(n, same)
        -- the seen-imports set in the derived form: Fig. 11's self import does not resolve itself
        local G2 = A.scope_graph()
        local s1 = A.sg_scope(G2, nil, 'root'); local sA1 = A.sg_scope(G2, s1, 'A1'); local sA2 = A.sg_scope(G2, sA1, 'A2')
        A.sg_decl(G2, s1, 'A', { site = 1, assoc = sA1 }); A.sg_decl(G2, sA1, 'A', { site = 2, assoc = sA2 }); A.sg_decl(G2, sA2, 'a', { site = 3 })
        local A4 = A.sg_ref(G2, s1, 'A', { site = 4 }); A.sg_import(G2, s1, A4); local a6 = A.sg_ref(G2, s1, 'a', { site = 6 })
        assert.equals(answer(hand, G2, A4), answer(derived, G2, A4)); assert.is_true(derived(G2, a6).absent)
        -- the review's trap: a declaration added after a resolve is seen by the next resolve (the memo is cleared)
        local G3 = A.scope_graph(); local g = A.sg_scope(G3, nil, 'g'); local x = A.sg_ref(G3, g, 'x', { site = 1 })
        assert.is_true(hand(G3, x).absent)
        A.sg_decl(G3, g, 'x', { site = 2 })
        assert.is_false(hand(G3, x).absent); assert.equals(1, #hand(G3, x).entries)
        local y = A.sg_ref(G3, g, 'x', { site = 3 })
        assert.equals(1, #hand(G3, y).entries)
        -- and a parameter bound to a record after a resolve: the field goes from opaque to resolved
        local G4 = A.scope_graph(); local root = A.sg_scope(G4, nil, 'root'); local rec = A.sg_scope(G4, nil, 'record')
        A.sg_decl(G4, rec, 'live', { site = 1, kind = 'field' })
        local fn = A.sg_scope(G4, root, 'function'); local H = A.sg_decl(G4, fn, 'H', { site = 2, kind = 'parameter' })
        local Href = A.sg_ref(G4, fn, 'H', { site = 3 }); local anon = A.sg_scope(G4, nil, 'field'); A.sg_import(G4, anon, Href, 'field')
        local lref = A.sg_ref(G4, anon, 'live', { site = 4, kind = 'field' })
        assert.equals('opaque', A.resolution_class(G4, A.resolve_through(G4, lref)))
        A.sg_bind_param(G4, H, rec)
        assert.equals('call', A.resolution_class(G4, A.resolve_through(G4, lref)))
    end)

    it('destinations on the preference primitive: suggested is best under the paper\'s order, cheapest under the price, the block\'s answers unchanged', function()
        local m = { name = 'h', entities = set('live', 'scratch'), free = set('live', 'scratch'), calls = { { home = 'A' } } }
        local homes = { { id = 'A', entities = set('live', 'scratch', 'x'), bound = set('live', 'scratch') }, { id = 'C', entities = set('live', 'scratch'), bound = set('live', 'scratch'), plumbing = 7 } }
        local r = A.destinations(m, homes, { helper_cost = 100 })
        assert.equals('C', r.suggested[1].id); assert.equals(1, #r.suggested) -- 1 - 2/2 = 0 beats 1 - 2/3; C reaches A after plumbing
        assert.equals('A', r.cheapest[1].id); assert.equals(1, #r.cheapest)     -- 100 against 107
        local Dv = require 'derive'
        local hand = A.destinations
        Dv.apply_to(A, 'destinations')
        local r2 = A.destinations(m, homes, { helper_cost = 100 })
        A.destinations = hand
        assert.same({ r.suggested[1].id, r.cheapest[1].id, #r.candidates, r.by_price[2].cost }, { r2.suggested[1].id, r2.cheapest[1].id, #r2.candidates, r2.by_price[2].cost })
    end)
end)

describe('the Lua mapping as templates (PRIMITIVES.md, the second check): locals.scm\'s captures as the algebra\'s data, a generic builder, judged against the hand-written mapping', function()
    local okf, FX = pcall(dofile, 'experiments/lua-terms-2026-09-18.lua')
    local function fixture() if not okf then return pending('experiments/lua-terms-2026-09-18.lua not loadable: ' .. tostring(FX)) end return FX end
    local id = function(s) return node('identifier', lit(s)) end
    local function decl(names, ...) local vl = {}; for i, n in ipairs(names) do if i > 1 then vl[#vl + 1] = lit ', ' end; vl[#vl + 1] = id(n) end; local el = {}; for i, e in ipairs({ ... }) do if i > 1 then el[#el + 1] = lit ', ' end; el[#el + 1] = e end; return node('variable_declaration', lit 'local', lit ' ', node('assignment_statement', node('variable_list', unpack(vl)), lit ' ', lit '=', lit ' ', node('expression_list', unpack(el)))) end
    local function fcall(f, ...) local ks = { lit '(' }; for i, a in ipairs({ ... }) do if i > 1 then ks[#ks + 1] = lit ', ' end; ks[#ks + 1] = a end; ks[#ks + 1] = lit ')'; return node('function_call', type(f) == 'string' and id(f) or f, node('arguments', unpack(ks))) end
    local function fdef(params, ...) local pk = { lit '(' }; for i, p in ipairs(params) do if i > 1 then pk[#pk + 1] = lit ', ' end; pk[#pk + 1] = id(p) end; pk[#pk + 1] = lit ')'; return node('function_definition', lit 'function', lit ' ', node('parameters', unpack(pk)), lit ' ', node('block', ...), lit ' ', lit 'end') end
    local function localfn(name, params, ...) local pk = { lit '(' }; for i, p in ipairs(params) do if i > 1 then pk[#pk + 1] = lit ', ' end; pk[#pk + 1] = id(p) end; pk[#pk + 1] = lit ')'; return node('function_declaration', lit 'local', lit ' ', lit 'function', lit ' ', id(name), node('parameters', unpack(pk)), lit ' ', node('block', ...), lit ' ', lit 'end') end
    local function chunk(...) return node('chunk', ...) end

    it('the fixture: identical declarations, identical references, the same binder for every shared reference; the classes differ only by the alias chain', function()
        local F = fixture(); if not F then return end
        local total, same_b, same_c, diffs = 0, 0, 0, {}
        for _, m in ipairs(F.members) do
            local c = A.compare_mappings(m.term)
            assert.same({}, c.decl_only_code); assert.same({}, c.decl_only_templates); assert.same({}, c.ref_only_code); assert.same({}, c.ref_only_templates)
            total, same_b, same_c = total + c.shared, same_b + c.same_binder, same_c + c.same_class
        end
        local c = A.compare_mappings(F.file.term)
        assert.same({}, c.decl_only_code); assert.same({}, c.decl_only_templates); assert.same({}, c.ref_only_code); assert.same({}, c.ref_only_templates)
        assert.equals(29, c.decls.code)
        total, same_b, same_c = total + c.shared, same_b + c.same_binder, same_c + c.same_class
        assert.equals(total, same_b)
        assert.is_true(total > 150)
        assert.is_true(same_c < total) -- the alias chain (module, opaque) is not in the lexical mapping
        for _, d in ipairs(c.class_diffs) do local a, b = d:match(': (%w+) / (%w+)'); assert.equals('lexical', b); assert.is_true(a == 'module' or a == 'opaque', d) end
    end)

    it('the regions: local x = x reads the outer x, local function sees itself, a loop variable stays in its loop, the in-list is outside it', function()
        local t = chunk(decl({ 'x' }, (lit '1')), decl({ 'x' }, id 'x'), localfn('g', { 'p' }, fcall('g', id 'p')),
            node('for_statement', lit 'for', lit ' ', node('for_generic_clause', node('variable_list', id 'k'), lit ' ', lit 'in', lit ' ', node('expression_list', fcall('pairs', id 'k'))), lit ' ', lit 'do', lit ' ', node('block', fcall('use', id 'k')), lit ' ', lit 'end'),
            fcall('use', id 'k'))
        local G = A.scope_graph_from_templates(t, A.SCOPE_TEMPLATES.lua, nil, { file = 't' })
        local seen = {}
        for _, r in pairs(G.refs) do
            local Rr = A.resolve(G, r.id)
            local d = Rr.entries[1] and G.decls[Rr.entries[1].decl]
            seen[#seen + 1] = r.name .. '@' .. table.concat(r.site, '/') .. '->' .. (d and (d.kind .. ':' .. table.concat(d.site or {}, '/')) or 'absent')
        end
        table.sort(seen)
        assert.same({ 'g@3/8/1/1->function:3/5',        -- g inside its own body: the local function is self-visible
            'k@4/3/5/1/2/2->absent',                     -- k in the in-list: outside the loop scope
            'k@4/7/1/2/2->loop:4/3/1/1',                 -- k in the body: the loop variable
            'k@5/2/2->absent',                           -- k after the loop: gone
            'p@3/8/1/2/2->parameter:3/6/2', 'pairs@4/3/5/1/1->library:', 'use@4/7/1/1->absent', 'use@5/1->absent',
            'x@2/3/5/1->lexical:1/3/1/1' }, seen)        -- local x = x: the right-hand side reads the first x
        -- the same term through the hand-written mapping: the same binders
        local c = A.compare_mappings(t)
        assert.same({}, c.ref_only_code); assert.same({}, c.ref_only_templates); assert.equals(c.shared, c.same_binder)
        -- repeat .. until: the condition sees the block's tail scope, in both mappings
        local rp = chunk(node('repeat_statement', lit 'repeat', lit ' ', node('block', decl({ 'w' }, fcall 'step')), lit ' ', lit 'until', lit ' ', fcall('done', id 'w')))
        local G2 = A.scope_graph_from_templates(rp, A.SCOPE_TEMPLATES.lua, nil, { file = 'r' })
        local wref
        for _, r in pairs(G2.refs) do if r.name == 'w' then wref = r end end
        local Rw = A.resolve(G2, wref.id)
        assert.is_false(Rw.absent); assert.equals('lexical', G2.decls[Rw.entries[1].decl].kind)
        local c2 = A.compare_mappings(rp)
        assert.equals(c2.shared, c2.same_binder); assert.is_true(c2.shared >= 3)
        -- an if branch's locals do not leak into the elseif condition
        local ife = chunk(node('if_statement', lit 'if', lit ' ', id 'a', lit ' ', lit 'then', lit ' ', node('block', decl({ 'y' }, (lit '1'))), lit ' ', node('elseif_statement', lit 'elseif', lit ' ', id 'y', lit ' ', lit 'then', lit ' ', node('block', fcall 'z')), lit ' ', lit 'end'))
        local G3 = A.scope_graph_from_templates(ife, A.SCOPE_TEMPLATES.lua, nil, { file = 'i' })
        for _, r in pairs(G3.refs) do if r.name == 'y' then assert.is_true(A.resolve(G3, r.id).absent) end end
        -- the templates are the algebra's own: the local rule is what generalize makes of two declarations
        local g = A.generalize({ decl({ 'a' }, (lit '1')), decl({ 'b', 'c' }, id 'x', fcall 'f') }, { need = 100 })
        assert.is_truthy(A.match(A.SCOPE_TEMPLATES.lua.declarations[1].template, decl({ 'a' }, (lit '1'))).ok)
        assert.is_truthy(A.match(A.SCOPE_TEMPLATES.lua.declarations[1].template, A.instantiate(g.template, g.values[2]).term).ok)
    end)
end)
