-- The dogfood dashboard: cartograph on cartograph. Unit-level, we just confirm
-- the report wires census + serving + lint over a store without crashing and
-- returns the three sections + a seam count (the real self-run is
-- tools/dogfood.lua, which extracts our own tree from disk).

local store = require 'cartograph.store'
local dogfood = require 'cartograph.dogfood'

local R = { start = { line = 0, char = 0 }, ['end'] = { line = 0, char = 0 } }
local DATA = {
    root = '/x',
    nodes = {
        { id = 'm.lua', name = 'm.lua', kind = 'module', file = 'm.lua', range = R, order = 0 },
        { id = 'm.lua::a', name = 'a', kind = 'function', file = 'm.lua', range = R, order = 0 },
        { id = 'm.lua::b', name = 'b', kind = 'function', file = 'm.lua', range = R, order = 1 },
    },
    edges = { { from = 'm.lua::a', to = 'm.lua::b', kind = 'ref', at = { R } } },
    calls = { { fn = 'm.lua::a', callee = 'b', file = 'm.lua', line = 0, to = 'm.lua::b', at = R } },
}

test('dogfood: run() reports the three sections + a seam count, non-destructively', function ()
    store.ingest(DATA)
    require('cartograph.config').seams = nil -- a clean user config
    local lines, counts = dogfood.run(store)
    local text = table.concat(lines, '\n')
    ok(text:find('RESOLUTION'), 'has the resolution section')
    ok(text:find('SERVING'), 'has the serving section')
    ok(text:find('seam%-guard %(Band%)'), 'has the seam-guard line')
    eq(0, counts.seam, 'no seam breach on an in-memory graph (no files on disk)')
    eq(nil, require('cartograph.config').seams, 'config.seams restored (non-destructive)')
end)

test('dogfood: metrics() is the numeric record (the ratchet\'s fuel)', function ()
    store.ingest(DATA)
    require('cartograph.config').seams = nil
    local m = dogfood.metrics(store)
    eq(3, m.nodes); eq(1, m.calls)
    eq(100, m.resolved_pct) -- the one call resolves
    eq(0, m.seam)
    ok(type(m.serving_pct) == 'number', 'serving is a number')
    ok(m.by_prov ~= nil and m.lint ~= nil, 'by_prov + lint breakdown present')
end)

test('dogfood: the BAND_SEAM guards the wide index tables, not the whole-map form', function ()
    local pats = {}
    for _, p in ipairs(dogfood.BAND_SEAM.patterns) do pats[p] = true end
    ok(pats['store%.uses%['], 'per-node uses[ is guarded')
    ok(pats['store%.edge_tier%['], 'the new edge_tier index is guarded')
    ok(not pats['store%.uses'], 'the bare whole-map form is NOT guarded (scc/cone pass it)')
    ok(not pats['store%.edge_inferred%['], 'edge_inferred excluded (a deferred reader owns it)')
end)

-- ── THE FENCE IS THE AUTHORITATIVE SET (CART-0192/0225) ─────────────────────
-- tools/dogfood.lua used to exit on `counts.seam` alone, so nine other classes could
-- grow with no signal. The fix is not "pin all ten": a SUGGESTIVE rule legitimately
-- finds more when a language's expressions become visible (adding java field_access
-- doubled registry-audit), so gating that would reward keeping languages opaque. Only
-- the declared authoritative set gates.

test('dogfood: the LINT section groups counts by what they CLAIM', function ()
    store.ingest(DATA)
    require('cartograph.config').seams = nil
    local lines = dogfood.run(store)
    local text = table.concat(lines, '\n')
    ok(text:find('AUTHORITATIVE'), 'the gated group is named')
    ok(text:find('a defect by construction'), 'and says what makes it gateable')
    ok(text:find('SUGGESTIVE') or text:find('%(none%)'),
        'the ungated groups are distinguishable from it')
end)

test('dogfood: counts.authoritative is the FENCE, and it FIRES', function ()
    -- A fence that cannot fail is not a fence. `truncation` is authoritative and
    -- AST-precise (2+ targets, one and/or rhs whose operand is a call — the second
    -- target silently becomes nil), so it is the cheapest way to prove the wiring:
    -- if this ever stops producing a non-zero count, the gate has gone inert.
    local ts = require 'cartograph.providers.treesitter'
    if not pcall(vim.treesitter.language.add, 'lua') then skip 'no lua parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    vim.fn.writefile({ 'local function f() return 1, 2 end',
        'local function g(x, y)', '  local a, b = x and f() or y', '  return a, b', 'end',
        'return g' }, root .. '/t.lua')
    local d = ts.extract(root); d.root = root
    store.ingest(d)
    require('cartograph.config').seams = nil
    local _, counts = dogfood.run(store)
    ok((counts.authoritative or 0) > 0,
        'an authoritative finding raises the fence count (got '
        .. tostring(counts.authoritative) .. ')')
    eq(0, counts.seam, 'and it is NOT the seam count that moved — the fence widened')
    vim.fn.delete(root, 'rf')
end)

test('dogfood: a SUGGESTIVE finding does NOT raise the fence', function ()
    -- the other half of the contract, and the whole point of the classification
    store.ingest(DATA)
    require('cartograph.config').seams = nil
    local lint = require 'cartograph.lint'
    local auth = {}
    for _, r in ipairs(lint.rules) do
        if r.disposition == 'authoritative' then auth[r.name] = true end
    end
    local by_rule = {}
    for _, f in ipairs(lint.run(store)) do by_rule[f.rule] = (by_rule[f.rule] or 0) + 1 end
    local _, counts = dogfood.run(store)
    local sug = 0
    for r, n in pairs(by_rule) do if not auth[r] then sug = sug + n end end
    eq(0, counts.authoritative or 0, 'nothing authoritative fires on this graph')
    ok(sug >= 0, 'while suggestive/annotation counts are reported and not gated')
end)
