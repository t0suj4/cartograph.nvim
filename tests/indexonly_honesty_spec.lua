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

-- ── EVERY needs_calls VERB REFUSES HERE, AND THE SWEEP IS THE POINT (CART-0978) ─
-- A per-verb test would only pin the verbs someone remembered. This sweeps the
-- catalogue, so a verb added later either declares `needs_calls` truthfully or is
-- caught here. It was written because a neutralisation exposed the gap: flipping
-- `txn_plan_clonemerge`'s declaration to false cost ZERO failures, which means every
-- OTHER needs_calls declaration was equally unguarded at the verb level.
--
-- ⚠ AND FOR THE MERGE VERB IT IS A SOUNDNESS REQUIREMENT, NOT A QUALITY ONE. The
-- transaction DELETES the copies and points their callers at the survivor. With no call
-- graph there are no rewrites to compute, so it would delete the copies and leave every
-- caller pointing at a function that is gone — past the parse gate, since the result
-- still parses.
test('index-only: every verb that declares needs_calls REFUSES with thin-index', function ()
    local agent = require 'cartograph.agent'
    store.ingest(thin())
    agent.set_writable(true)   -- so `mutates` cannot be the reason instead
    local swept = 0
    for _, name in ipairs(agent.ORDER) do
        local v = agent.VERBS[name]
        -- ★ THE ARGUMENTS COME FROM THE `subject` COLUMN (CART-0972), not from a
        -- guess. The first cut fed every verb a node and `why` — which declares
        -- needs_calls and takes a POSITION — failed on usage before it ever reached
        -- the capability check. A sweep that cannot address its subjects measures
        -- nothing, and the axis that says how to address them shipped an hour before
        -- this test needed it.
        local ARGS = {
            node = { node = 'a.lua::foo' },
            ['node-handle'] = { node = 'a.lua::foo' },
            position = { file = 'a.lua', line = 1 },
            graph = {},
        }
        if v.needs_calls and ARGS[v.subject] then
            swept = swept + 1
            local a = vim.deepcopy(ARGS[v.subject])
            -- ⚠ AND THE REQUIRED PAYLOAD TOO, DERIVED FROM THE DECLARATION. A usage
            -- fault is answered BEFORE the capability check, so a verb missing a
            -- required argument never reaches the refusal this test is about —
            -- txn_plan_optimize needs `kind`. Filling them from the arg table's own
            -- types and enums keeps this a sweep instead of a second hand-written list.
            for _, arg in ipairs(v.args or {}) do
                if arg.required and a[arg.name] == nil then
                    a[arg.name] = (arg.enum and arg.enum[1])
                        or (arg.type == 'integer' and 1)
                        or (arg.type == 'array' and {})
                        or 'x'
                end
            end
            local doc = agent.answer(store, name, a)
            eq(false, doc.ok, name .. ' declares needs_calls, so a thin index refuses it')
            ok(type(doc.refusal) == 'table' and doc.refusal.rule == 'thin-index',
                name .. ' refuses under `thin-index`, not something else: '
                .. vim.inspect(doc.refusal))
        end
    end
    ok(swept > 0, 'the sweep actually ran over some verbs')
    agent.set_writable(false)
    store.ingest(full())
end)

-- ⚠ THE SWEEP ABOVE PINS "DECLARED true => REFUSES", WHICH IS ONLY HALF. It iterates
-- the verbs that declare `needs_calls`, so a verb that wrongly declares FALSE is simply
-- skipped — flipping txn_plan_clonemerge's declaration cost the sweep zero failures.
-- The other half has to be asserted per verb, and it is worth asserting for this one
-- because the consequence is not a weak answer, it is a broken tree.
test('index-only: the MERGE verb refuses here, because a merge without callers deletes', function ()
    local agent = require 'cartograph.agent'
    store.ingest(thin())
    agent.set_writable(true)
    local doc = agent.answer(store, 'txn_plan_clonemerge', { node = 'a.lua::foo' })
    eq(false, doc.ok, 'a thin index cannot answer a merge')
    ok(type(doc.refusal) == 'table' and doc.refusal.rule == 'thin-index',
        'and it REFUSES rather than planning one: ' .. vim.inspect(doc.refusal))
    -- ★ WHY THIS ONE IS NOT A QUALITY QUESTION. The transaction deletes the copies and
    -- points their callers at the survivor. With no call graph there are no rewrites to
    -- compute, so it would delete the copies and leave every caller naming a function
    -- that is gone — and the result still PARSES, so the parse gate would pass it.
    agent.set_writable(false)
    store.ingest(full())
end)
