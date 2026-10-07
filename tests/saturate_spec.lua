-- saturate: rules over fact terms to a fixpoint (CART-1525) — semi-naive closure, stratified negation, the refusals
-- compile owes (unsafe, unstratified), the round cap that RAISES, order independence, both premise paths (flat via the
-- index and values_at, nested via A.match).

local S = require 'cartograph.saturate'
local A = require('cartograph.algebra').load()
local H, N, L = A.hole, A.node, A.lit

local function shown(db, kind)
    local out = {}
    for _, f in ipairs(db.by[kind] or {}) do out[#out + 1] = A.show(f) end
    table.sort(out)
    return out
end
local function edges(list) local fs = {}; for _, e in ipairs(list) do fs[#fs + 1] = N('edge', L(e[1]), L(e[2])) end; return fs end
local PATH = {
    { stratum = 1, head = N('path', H('x'), H('y')), body = { N('edge', H('x'), H('y')) } },
    { stratum = 1, head = N('path', H('x'), H('z')), body = { N('path', H('x'), H('y')), N('edge', H('y'), H('z')) } },
}

test('saturate: a recursive rule reaches its fixpoint — the transitive closure of a chain', function ()
    local db = S.run(S.compile(A, PATH), edges { { 1, 2 }, { 2, 3 }, { 3, 4 }, { 4, 5 } })
    eq(10, #shown(db, 'path'), 'a chain of 5 has 10 paths: ' .. table.concat(shown(db, 'path'), ' '))
    ok(db.has(N('path', L(1), L(5))), 'path(1, 5) is derived')
    eq(false, db.has(N('path', L(5), L(1))), 'and path(5, 1) is not')
    ok(db.stats.rounds >= 4, 'the chain needs one round per step: ' .. db.stats.rounds)
end)

test('saturate: negation is stratified — the unreachable nodes, read after reachability is complete', function ()
    local rules = {
        { stratum = 1, head = N('reach', H('y')), body = { N('root', H('x')), N('edge', H('x'), H('y')) } },
        { stratum = 1, head = N('reach', H('z')), body = { N('reach', H('y')), N('edge', H('y'), H('z')) } },
        { stratum = 2, head = N('dead', H('n')), body = { N('node', H('n')) }, absent = { N('reach', H('n')), N('root', H('n')) } },
    }
    local facts = edges { { 1, 2 }, { 2, 3 }, { 4, 5 } }
    for i = 1, 5 do facts[#facts + 1] = N('node', L(i)) end
    facts[#facts + 1] = N('root', L(1))
    eq({ '(dead 4)', '(dead 5)' }, shown(S.run(S.compile(A, rules), facts), 'dead'))
end)

test('saturate: compile refuses an UNSAFE rule and an UNSTRATIFIED negation by name', function ()
    local fine, err = pcall(S.compile, A, { { stratum = 1, head = N('p', H('x'), H('y')), body = { N('q', H('x')) } } })
    eq(false, fine); ok(tostring(err):find('head hole `y` is not bound', 1, true), err)
    fine, err = pcall(S.compile, A, { { stratum = 1, head = N('p', H('x')), body = { N('q', H('x')) }, absent = { N('r', H('z')) } } })
    eq(false, fine); ok(tostring(err):find('negated hole `z` is not bound', 1, true), err)
    fine, err = pcall(S.compile, A, {
        { stratum = 1, head = N('p', H('x')), body = { N('q', H('x')) }, absent = { N('p2', H('x')) } },
        { stratum = 1, head = N('p2', H('x')), body = { N('q', H('x')) } },
    })
    eq(false, fine); ok(tostring(err):find('not earlier than', 1, true), err)
    fine, err = pcall(S.compile, A, {
        { stratum = 1, head = N('p', H('x')), body = { N('later', H('x')) } },
        { stratum = 2, head = N('later', H('x')), body = { N('q', H('x')) } },
    })
    eq(false, fine); ok(tostring(err):find('LATER stratum', 1, true), err)
end)

test('saturate: a stratum that does not converge within the cap RAISES — never a partial answer (CART-1527)', function ()
    local C = S.compile(A, PATH)
    local chain = edges { { 1, 2 }, { 2, 3 }, { 3, 4 }, { 4, 5 }, { 5, 6 } }
    local fine, err = pcall(S.run, C, chain, { rounds = 2 })
    eq(false, fine); ok(tostring(err):find('did not converge in 2 rounds', 1, true), err)
    ok(pcall(S.run, C, chain, { rounds = 20 }), 'with room it converges')
end)

test('saturate: the answer does not depend on the order the facts arrive in', function ()
    local C = S.compile(A, PATH)
    local fw = edges { { 1, 2 }, { 2, 3 }, { 3, 1 }, { 3, 4 } }
    local bw = {}
    for i = #fw, 1, -1 do bw[#bw + 1] = fw[i] end
    bw[#bw + 1] = fw[1] -- (a duplicate is one fact)
    local a, b = S.run(C, fw), S.run(C, bw)
    local function all(db) local o = {}; for _, f in ipairs(db.facts) do o[#o + 1] = A.show(f) end; return o end
    eq(all(a), all(b), 'the same facts, in the same canonical order')
    eq(a.stats, b.stats, 'and the same work')
end)

test('saturate: a NESTED premise goes through A.match, a repeated hole is non-linear on both paths', function ()
    local rules = {
        { stratum = 1, head = N('calls', H('f'), H('a')), body = { N('call', H('f'), N('args', H('a'))) } }, -- nested
        { stratum = 1, head = N('loop', H('x')), body = { N('edge', H('x'), H('x')) } },                      -- flat, x twice
        { stratum = 1, head = N('self', H('f')), body = { N('call', H('f'), N('args', H('f'))) } },           -- nested, f twice
    }
    local facts = { N('call', L('g'), N('args', L('h'))), N('call', L('k'), N('args', L('k'))) }
    for _, f in ipairs(edges { { 1, 1 }, { 2, 3 } }) do facts[#facts + 1] = f end -- (edge(2, 3) would read as loop(2) if x's two sites were not compared)
    local db = S.run(S.compile(A, rules), facts)
    eq({ '(calls "g" "h")', '(calls "k" "k")' }, shown(db, 'calls'))
    eq({ '(loop 1)' }, shown(db, 'loop'))
    eq({ '(self "k")' }, shown(db, 'self'))
end)

test('saturate: a literal in a premise filters — on the scanned first premise and through the index', function ()
    local rules = {
        { stratum = 1, head = N('hot', H('x')), body = { N('flag', H('x'), L(true)) } },
        { stratum = 1, head = N('both', H('x')), body = { N('item', H('x')), N('flag', H('x'), L(true)) } },
    }
    local facts = { N('flag', L(1), L(true)), N('flag', L(2), L(false)), N('item', L(1)), N('item', L(2)) }
    local db = S.run(S.compile(A, rules), facts)
    eq({ '(hot 1)' }, shown(db, 'hot'))
    eq({ '(both 1)' }, shown(db, 'both'))
end)
