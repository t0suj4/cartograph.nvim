-- The workspace: eval (expression or chunk, graph in scope, errors caught) and
-- as_nodes (recognizing a node / node-list / id-set result so it can render as
-- a browsable perspective).

local ws = require 'cartograph.workspace'
local store = require 'cartograph.store'

local R0 = { start = { line = 0, char = 0 }, ['end'] = { line = 0, char = 0 } }
local function node(id, name) return { id = id, name = name, kind = 'function', file = 'm.lua', range = R0, order = 0 } end
local function graph(nodes) store.ingest({ schema = 1, root = '/x', nodes = nodes, edges = {} }) end

test('eval: an expression returns its value', function ()
    eq(2, (ws.eval('1 + 1')))
end)

test('eval: a chunk that returns works too', function ()
    eq(3, (ws.eval('local t = {}; for i = 1, 3 do t[i] = i end; return #t')))
end)

test('eval: the graph is in scope', function ()
    graph({ node('a', 'a'), node('b', 'b'), node('c', 'c') })
    eq(3, (ws.eval('return #store.data.nodes')))
end)

test('eval: a runtime error is caught, not raised', function ()
    local res, err = ws.eval('return nope_fn()')
    eq(nil, res)
    ok(err and err:find('error'), 'error surfaced as a string')
end)

test('eval: a compile error is caught', function ()
    local res, err = ws.eval('return 1 +')
    eq(nil, res)
    ok(err and err:find('compile'), 'compile error surfaced')
end)

test('as_nodes: an array of ids resolves to nodes', function ()
    graph({ node('a', 'a'), node('b', 'b') })
    local ns = ws.as_nodes({ 'a', 'b' })
    eq(2, #ns)
    eq('a', ns[1].id)
end)

test('as_nodes: a set { id = true } resolves (cone/territory shape)', function ()
    graph({ node('a', 'a'), node('b', 'b') })
    eq(2, #ws.as_nodes({ a = true, b = true }))
end)

test('as_nodes: a single node table is a one-element list', function ()
    graph({ node('a', 'a') })
    eq(1, #ws.as_nodes(store.node('a')))
end)

test('as_nodes: a non-node table is not a node list', function ()
    graph({ node('a', 'a') })
    eq(nil, ws.as_nodes({ 1, 2, 3 }))
    eq(nil, ws.as_nodes({ 'a', 'does-not-resolve' }))
    eq(nil, ws.as_nodes('a string'))
end)
