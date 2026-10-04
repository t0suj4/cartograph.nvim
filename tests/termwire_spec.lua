-- the TERM WIRE (CART-1366): a term as a DAG of node records (what eq compares) plus a side map of per-occurrence
-- fields by path. The oracle is the round trip: wire_decode(wire_encode(t)) deep-equals t, through JSON text too.
-- MEASURED: 536 terms (60 lua/cartograph files, every jenkins-infra yaml document, a template) round trip 536/536
-- through JSON; 743,253 occurrences -> 230,395 wire nodes (3.2x). v = 3 (2026-10-04): message-local indices and one
-- digest per message instead of a sha256 per node — 65.8 -> 16.6 MB JSON, encode 4.89 -> 2.79 s.
local A = require('cartograph.algebra').load()

local function rt(t)
    local w = assert(A.wire_encode(t))
    return A.wire_decode(vim.json.decode(vim.json.encode(w))), w
end
local function O(keys, vals) local o = {}; for i, k in ipairs(keys) do o[k] = vals[i] end; return { o = o, keys = keys } end

test('term wire: a term ROUND TRIPS through JSON — code, keyed values, a template with holes and presence marks', function ()
    local code = A.node('call', A.name('f'), A.lit('1'), A.lit(1), A.lit(true), A.node('args'))
    local tpl = A.generalize({ A.kv_term(O({ 'a', 'b' }, { '1', 'x' })), A.kv_term(O({ 'a' }, { '2' })) }, { align = 'none' }).template.body
    for _, t in ipairs({ code, A.kv_term(O({ 'z', 'a' }, { '1', 2 })), tpl }) do eq(t, (rt(t))) end
end)

test('term wire: a subterm occurring twice is ONE node; per-occurrence fields (a span, a keyed node\'s written order) ride beside it', function ()
    local function at(t, line) local c = A.copy(t); c.at = { line = line }; return c end
    local g = A.node('g', A.lit('deep'))
    local t = A.node('f', at(g, 3), at(g, 9))
    local back, w = rt(t)
    eq(t, back)
    eq(w.nodes[w.root].kids[1], w.nodes[w.root].kids[2], 'two spans, one node')
    eq(3, back.kids[1].at.line); eq(9, back.kids[2].at.line)
    -- ★ a keyed node's id ignores order: two occurrences written in different orders share a record, each keeps its own
    local p, q = A.kv_term(O({ 'a', 'b' }, { '1', '2' })), A.kv_term(O({ 'b', 'a' }, { '2', '1' }))
    local both = A.node('pair', p, q)
    local b2, w2 = rt(both)
    eq(both, b2, 'each occurrence comes back in its own written order')
    eq(w2.nodes[w2.root].kids[1], w2.nodes[w2.root].kids[2], 'and they are one record')
end)

test('term wire: the decoded term is a fresh TREE (an edit in place touches one occurrence), and a non-JSON field is refused by name', function ()
    local g = A.node('g', A.lit(1))
    local back = rt(A.node('f', g, A.copy(g)))
    back.kids[1].kids[1].v = 99
    eq(1, back.kids[2].kids[1].v)
    local bad = A.node('f', A.lit(1)); bad.fn = function () end
    local w, why = A.wire_encode(bad)
    eq(nil, w); ok(why:find('`fn`', 1, true), why)
end)
test('term wire: NUMBERS — one canonical text per number eq tells apart, exact through JSON; NaN refused', function ()
    ok(A.content_id(A.lit(0.1 + 0.2)) ~= A.content_id(A.lit(0.3)), '0.1 + 0.2 is not 0.3 (eq says so; tostring printed both alike)')
    eq(A.content_id(A.lit(-0)), A.content_id(A.lit(0)), '-0 is 0')
    for _, v in ipairs({ 0.1 + 0.2, 1e300, -2.5e-12, 2 ^ 53 + 2, 7 }) do
        local t = A.node('f', A.lit(v))
        eq(t, (rt(t)), 'exact through JSON: ' .. ('%.17g'):format(v))
    end
    local w, why = A.wire_encode(A.node('f', A.lit(0 / 0)))
    eq(nil, w); ok(why:find('NaN', 1, true), why)
end)

test('term wire: the RECORD holds exactly what the id hashes — a presence mark on a LITERAL, a stray field, ride per occurrence', function ()
    -- a keyed SET of primitives generalized under presence puts the mark on a literal (eq ignores it there)
    local s1 = A.keyed('set', { A.lit('a'), A.lit('b') }, { key = true })
    local s2 = A.keyed('set', { A.lit('a') }, { key = true })
    local body = A.generalize({ s1, s2 }).template.body
    local marked = 0
    for _, k in ipairs(body.kids) do if k.k == 'lit' and k.opt then marked = marked + 1 end end
    eq(1, marked, 'the premise: a literal carries a presence mark')
    eq(body, (rt(body)))
    -- two literals with different marks are two NODES since a mark is identity on every kind (CART-1397: it was ignored
    -- on a literal, and they shared one record with the mark per occurrence)
    local t = A.node('f', { k = 'lit', v = 'b', opt = 'h1' }, { k = 'lit', v = 'b', opt = 'h2' })
    local back, w = rt(t)
    eq(t, back)
    ok(w.nodes[w.root].kids[1] ~= w.nodes[w.root].kids[2], 'two marks, two records')
    ok(not A.eq(t.kids[1], t.kids[2]), 'and eq tells them apart')
    -- a field eq does not read on this kind (a stray `v` on a node) is not dropped
    local stray = A.node('f', A.lit(1)); stray.v = 3
    eq(stray, (rt(stray)))
end)
-- ── v = 3: message-local indices, ONE digest per message (CART-1366; the user: "sha256 is overkill") ──
test('term wire v3: the numbering is CANONICAL — two eq-equal terms (other spans, keyed kids written in another order) are the same records and the same digest', function ()
    local function at(t, line) local c = A.copy(t); c.at = { line = line }; return c end
    local p = A.node('f', at(A.kv_term(O({ 'a', 'b' }, { '1', '2' })), 1), A.lit(3))
    local q = A.node('f', at(A.kv_term(O({ 'b', 'a' }, { '2', '1' })), 7), A.lit(3))
    ok(A.eq(p, q), 'the premise: eq says they are one term')
    local wp, wq = assert(A.wire_encode(p)), assert(A.wire_encode(q))
    eq(wp.nodes, wq.nodes, 'the same records at the same indices')
    eq(wp.root, wq.root); eq(wp.digest, wq.digest)
    ok(next(wq.side) ~= nil, 'and what differs rides in the side map')
    -- ★ and the other side: a term eq tells apart has another digest (a dead digest would pass every line above)
    local r = A.node('f', A.kv_term(O({ 'a', 'b' }, { '1', '2' })), A.lit('3'))
    ok(not A.eq(p, r)); ok(assert(A.wire_encode(r)).digest ~= wp.digest, 'the literal 3 against the string "3"')
    -- every kid is an earlier node: the order a decoder can check without building anything
    for i, rec in ipairs(wp.nodes) do for _, c in ipairs(rec.kids or {}) do ok(c < i, ('node %d kid %d'):format(i, c)) end end
end)

test('term wire v3: a wire changed in transit is REFUSED by name — a record edited, a forward kid, a v = 2 wire', function ()
    local t = A.node('f', A.node('g', A.lit(1)), A.name('x'))
    local function fresh() return vim.json.decode(vim.json.encode(assert(A.wire_encode(t)))) end
    eq(t, (A.wire_decode(fresh())), 'the unchanged wire decodes')
    local w = fresh()
    for _, rec in ipairs(w.nodes) do if rec.k == 'name' then rec.n = 'y' end end
    local back, why = A.wire_decode(w)
    eq(nil, back); ok(why:find('digest does not match', 1, true), why)
    w = fresh(); w.nodes[1].kids = { #w.nodes }
    back, why = A.wire_decode(w)
    eq(nil, back); ok(why:find('a kid is an earlier node', 1, true), why)
    w = fresh(); w.v = 2
    back, why = A.wire_decode(w)
    eq(nil, back); ok(why:find('v = 3', 1, true), why)
end)
