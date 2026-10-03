-- content ids as a view (CART-1390, one representation): a term's MERKLE id over the stored tree, the oracle being the
-- algebra's own equality — eq(a, b) <=> content_id(a) == content_id(b). MEASURED 2026-10-03: 79,221 subterms (three
-- lua/cartograph files + jenkins-infra kv terms) -> 17,604 ids (4.5x), 0 violations either way, 0.32 s.
local A = require('cartograph.algebra').load()
local R = require 'cartograph.algebraread'

test('content id: eq <=> same id over EVERY pair of subterms of a chunk', function ()
    if not pcall(vim.treesitter.get_string_parser, '', 'lua') then skip 'no lua parser' end
    local t = assert(R.read('local function f(x) return x + 1 end\nlocal y = f(1) + f(1)\nlocal z = { a = 1, b = "1" }\nreturn y, z\n', 'lua'))
    local subs = {}
    local function collect(u) subs[#subs + 1] = u; for _, c in ipairs(u.kids or {}) do collect(c) end end
    collect(t)
    local memo, shared, distinct = {}, 0, {}
    for _, s in ipairs(subs) do distinct[A.content_id(s, memo)] = true end
    for i = 1, #subs do
        for j = i + 1, #subs do
            local e = A.eq(subs[i], subs[j])
            eq(e, memo[subs[i]] == memo[subs[j]], ('pair %d,%d: %s / %s'):format(i, j, A.show(subs[i]), A.show(subs[j])))
            if e then shared = shared + 1 end
        end
    end
    ok(shared > 10, 'the known-nonzero half: equal subterms at different positions (' .. shared .. ' pairs)')
    eq(vim.tbl_count(distinct), A.content_dag(t).count, 'the DAG holds each distinct subterm once')
end)

test('content id: what eq compares is in the id, what it ignores is not', function ()
    local function kv(keys) return A.kv_term({ o = { a = '1', b = '2' }, keys = keys }) end
    eq(A.content_id(kv({ 'a', 'b' })), A.content_id(kv({ 'b', 'a' })), 'a KEYED node is a set by key')
    local o1, o2 = A.keyed('obj', { kv({ 'a' }).kids[1], kv({ 'b' }).kids[1] }, { ordered = true }), nil
    o2 = A.keyed('obj', { kv({ 'b' }).kids[1], kv({ 'a' }).kids[1] }, { ordered = true })
    ok(A.content_id(o1) ~= A.content_id(o2), 'a keyed-ORDERED node keeps its order')
    ok(A.content_id(A.lit('1')) ~= A.content_id(A.lit(1)), 'a literal keeps its type')
    local s = A.node('f', A.lit(1)); s.at = { start = { line = 3 } }
    eq(A.content_id(A.node('f', A.lit(1))), A.content_id(s), 'a span is not identity')
    ok(A.content_id(A.hole('x')) ~= A.content_id(A.hole('x', true)), 'a hedge hole is not a term hole')
    local p = A.node('pair', A.lit('k'), A.lit(1)); local q = A.copy(p); q.opt = 'h1'
    ok(A.content_id(p) ~= A.content_id(q), 'a presence mark is identity')
end)

test('content dag: a subterm two trees share is ONE node, and every node re-hashes to its own id (a peer can verify)', function ()
    local shared = A.node('g', A.lit('deep'), A.node('h', A.lit(2)))
    local t = A.node('f', shared, A.copy(shared), A.node('k', A.copy(shared)))
    local d = A.content_dag(t)
    eq(6, d.count, 'f, k, g, h, "deep", 2 — the three copies of g are one node')
    local root = d.nodes[d.root]
    eq(root.kids[1], root.kids[2])
    eq(root.kids[1], d.nodes[root.kids[3]].kids[1], 'the copy under k is the same node')
    for id, n in pairs(d.nodes) do eq(id, vim.fn.sha256(n.label .. '(' .. table.concat(n.kids, ',') .. ')'), 'node ' .. n.label) end
end)