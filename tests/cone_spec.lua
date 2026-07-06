-- Reachability cones: the pure BFS, and the store's toggle/in_cone/cone_files
-- state over a small ingested graph.

local cone = require 'cartograph.cone'
local store = require 'cartograph.store'

-- ── pure BFS ────────────────────────────────────────────────────────────────

test('cone.reachable: transitive, anchor excluded', function ()
    eq({ b = true, c = true }, cone.reachable('a', { a = { 'b' }, b = { 'c' }, c = {} }))
end)

test('cone.reachable: cycle-safe (anchor excluded even if reachable back)', function ()
    eq({ b = true }, cone.reachable('a', { a = { 'b' }, b = { 'a' } }))
end)

test('cone.reachable: a diamond visits each node once', function ()
    eq({ b = true, c = true, d = true },
        cone.reachable('a', { a = { 'b', 'c' }, b = { 'd' }, c = { 'd' }, d = {} }))
end)

test('cone.reachable: a disconnected node -> empty set', function ()
    eq({}, cone.reachable('x', { x = {} }))
end)

-- ── store integration ───────────────────────────────────────────────────────

local R0 = { start = { line = 0, char = 0 }, ['end'] = { line = 0, char = 0 } }
local function node(id, name, file)
    return { id = id, name = name, kind = 'function', file = file or 'm.lua', range = R0, order = 0 }
end
local function ref(from, to) return { from = from, to = to, kind = 'ref', at = {} } end
local function graph(nodes, edges) store.ingest({ schema = 1, root = '/x', nodes = nodes, edges = edges or {} }) end

test('store cone: the descendant cone marks what the anchor reaches', function ()
    graph({ node('a', 'a', 'a.lua'), node('b', 'b', 'b.lua'), node('c', 'c', 'c.lua') },
        { ref('a', 'b'), ref('b', 'c') })
    eq(2, store.set_cone('a', 'out')) -- a -> b -> c
    ok(store.in_cone('b'), 'b is reached')
    ok(store.in_cone('c'), 'c is reached transitively')
    ok(not store.in_cone('a'), 'the anchor is not in its own cone')
    eq({ ['b.lua'] = true, ['c.lua'] = true }, store.cone_files())
end)

test('store cone: the ancestor cone marks what reaches the anchor', function ()
    graph({ node('a', 'a'), node('b', 'b'), node('c', 'c') }, { ref('a', 'b'), ref('b', 'c') })
    eq(2, store.set_cone('c', 'in')) -- c <- b <- a
    ok(store.in_cone('a') and store.in_cone('b'), 'both callers reach c')
    ok(not store.in_cone('c'), 'anchor excluded')
end)

test('store cone: re-toggling the same anchor+dir clears it', function ()
    graph({ node('a', 'a'), node('b', 'b') }, { ref('a', 'b') })
    store.set_cone('a', 'out')
    eq(0, store.set_cone('a', 'out')) -- toggle off
    eq(nil, store.cone)
    ok(not store.in_cone('b'), 'cleared')
end)

test('store cone: an unknown id is a no-op', function ()
    graph({ node('a', 'a') }, {})
    eq(0, store.set_cone('nope', 'out'))
    eq(nil, store.cone)
end)
