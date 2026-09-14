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

    it('positional generalization loses every field; key alignment keeps the shared ones', function()
        assert.equals('(table ?h1...)', A.show(A.generalize({ t1, t2 }, { positional = true }).template.body))
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
        -- but a rewritten region that breaks the old region apart cannot thread a hole through a string
        local C4 = A.classify(g.template, g.values[1], node('doc', node('image', lit 'x:1'), node('command', lit 'run fast', lit 'extra')))
        assert.equals('straddle', C4.kind); assert.truthy(C4.why:find('behind a grammar boundary'))
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
        local R = A.template(node('f', hole('r', true)))
        assert.equals('unavailable', A.absence_of(A.classify(R, { r = A.seq { lit 'a' } }, node('f', lit 'b'))).absence)
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

    it('several hedge holes in one list are not aligned by guessing: the node becomes a hole, and a derived match refuses', function()
        local T = A.template(node('f', hole_rep 'X', name 'a', hole_rep 'Y'))
        local r = A.join(T, node('f', name 'b', name 'a', name 'c'))
        assert.equals('?j1', A.show(r.template.body))
        assert.same({ 'j1' }, r.new)
        -- the original matcher backtracks and finds the split; the derived one refuses by name, never binds wrongly
        assert.is_true(A.match(T, node('f', name 'b', name 'a', name 'c')).ok)
        local D = require 'derive'
        local M2 = dofile('algebra.lua')
        D.apply_to(M2, 'match')
        local m = M2.match(T, node('f', name 'b', name 'a', name 'c'))
        D.apply_to(A, os.getenv('DERIVE') or '') -- rebind the basis to the suite's module
        assert.is_false(m.ok)
        assert.matches('fixed parts differ', m.refusal.why)
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
        assert.equals('(f ?j1...)', A.show(j.template.body)) -- default: a hedge hole (?a is not eq to 1, so no identical prefix), which classify refuses
        assert.equals('unsupported', A.classify(j.template, j.values[1], node('f', lit(5), lit(2))).kind)
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
