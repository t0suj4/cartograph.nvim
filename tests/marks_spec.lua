-- Node marks (the vim-mark idiom, keyed by node) + the graph-ops key policy:
-- ops with no vim idiom are unbound by default so vim natives (m, M) survive;
-- marks keep the vim keys because their MEANING matches.

local store = require 'cartograph.store'
local config = require 'cartograph.config'

local R0 = { start = { line = 0, char = 0 }, ['end'] = { line = 0, char = 0 } }
local function node(id, name) return { id = id, name = name, kind = 'function', file = 'm.lua', range = R0, order = 0 } end
local function graph(nodes) store.ingest({ schema = 1, root = '/x', nodes = nodes, edges = {} }) end

test('marks: set a node mark and jump to it', function ()
    graph({ node('a', 'a'), node('b', 'b') })
    store.set_mark('a', 'a'); store.set_mark('z', 'b')
    eq('a', store.get_mark('a'))
    eq('b', store.get_mark('z'))
end)

test('marks: get_mark is nil for an unset mark or a vanished node', function ()
    graph({ node('a', 'a') })
    store.set_mark('q', 'not-in-graph')
    eq(nil, store.get_mark('q')) -- id no longer resolves
    eq(nil, store.get_mark('x')) -- never set
end)

test('marks: cleared on re-ingest (ids churn with the graph)', function ()
    graph({ node('a', 'a') })
    store.set_mark('a', 'a')
    eq('a', store.get_mark('a'))
    graph({ node('a', 'a') }) -- re-ingest
    eq(nil, store.get_mark('a'))
end)

test('keys: graph-ops unbound by default; marks keep the vim keys', function ()
    eq(false, config.keys.mark)     -- working-set add: command + your leader key
    eq(false, config.keys.set_view) -- frees vim's M (middle of screen)
    eq(false, config.keys.cone_in)
    eq(false, config.keys.cone_out)
    eq('m', config.keys.set_mark)   -- marks keep m/` — the meaning matches vim
    eq('`', config.keys.goto_mark)
end)
