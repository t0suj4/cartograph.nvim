-- INDEX-ONLY honesty ([[cartograph-thin-index]]): the thin index has no call graph, so
-- the whole-graph surfaces must be WITHHELD, not faked. Transport-free: a graph carries
-- data.index_only; store.is_index_only() reports it; the LSP initialize handler drops
-- references / call-hierarchy from the advertised capabilities; a full re-ingest clears it.

local store = require 'cartograph.store'
local lsp = require 'cartograph.lsp'

local function rng(sl, sc, el, ec)
    return { start = { line = sl, char = sc }, ['end'] = { line = el, char = ec } }
end
-- a minimal defs-only graph (what index_only produces: nodes, no calls)
local function thin()
    return {
        root = '/x', index_only = true,
        nodes = {
            { id = 'a.lua', name = 'a.lua', kind = 'module', file = 'a.lua', range = rng(0, 0, 9, 0), order = 0 },
            { id = 'a.lua::foo', name = 'foo', kind = 'function', file = 'a.lua', range = rng(0, 0, 3, 0), order = 0 },
        },
        edges = {}, calls = {},
    }
end
local function full()
    local d = thin(); d.index_only = nil; return d
end
local function caps()
    return lsp.handlers['initialize'](store).capabilities
end

test('index-only: the marker rides on data and store reports it', function ()
    store.ingest(thin())
    ok(store.is_index_only(), 'a thin-index graph is index-only')
    store.ingest(full())
    ok(not store.is_index_only(), 'a full re-ingest clears the marker')
end)

test('index-only: LSP withholds references + call-hierarchy, keeps the Tier-0 surface', function ()
    store.ingest(thin())
    local c = caps()
    -- withheld: a client can't render an empty answer as an authoritative "none"
    ok(not c.referencesProvider, 'references withheld on the thin index')
    ok(not c.callHierarchyProvider, 'call-hierarchy withheld on the thin index')
    -- kept: go-to-def-on-a-def, symbols, hover are Tier-0 faithful
    ok(c.definitionProvider, 'definition still served (def-on-a-def)')
    ok(c.documentSymbolProvider, 'documentSymbol still served')
    ok(c.hoverProvider, 'hover still served')
    ok(c.workspaceSymbolProvider, 'workspaceSymbol still served')
end)

test('index-only: a full graph advertises the whole-graph surfaces', function ()
    store.ingest(full())
    local c = caps()
    ok(c.referencesProvider, 'references advertised on a full graph')
    ok(c.callHierarchyProvider, 'call-hierarchy advertised on a full graph')
end)
