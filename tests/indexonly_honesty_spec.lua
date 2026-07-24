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

-- The command layer's twin of the LSP withholding: the call-graph SUMMARY verbs
-- (census/ladder/externals/escalate) would each render an all-zero whole-graph
-- report on the thin index (census "nodes 0", ladder "0 calls", externals "0
-- external") that reads as an authoritative "none". commands.whole_graph refuses
-- with a pointer to the full open instead. Escalate's guard also fires BEFORE the
-- async lua-ls spin-up, so a thin graph never drives lua-ls for an empty work-list.
test('index-only: call-graph summary verbs refuse instead of faking zeros', function ()
    store.ingest(thin())
    require('cartograph.commands').register()
    local orig, msgs = vim.notify, {}
    vim.notify = function (m) msgs[#msgs + 1] = m end
    local run_ok = pcall(function ()
        for _, name in ipairs({ 'CartographCensus', 'CartographLadder',
            'CartographExternals', 'CartographEscalate' }) do
            msgs = {}
            vim.cmd(name)
            ok(msgs[1] and msgs[1]:find('call graph'),
                name .. ' refuses with the call-graph pointer, not a faked answer')
        end
    end)
    vim.notify = orig
    ok(run_ok, 'probing the guarded summary verbs raised no error')
    -- a full graph lets them through (guard is index-only-scoped, not a blanket block)
    store.ingest(full())
    ok(not store.is_index_only(), 'full re-ingest clears the marker so the verbs run')
end)
