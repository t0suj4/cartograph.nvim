-- CART-1982 (CUI-0009 a, second half): every verb DECLARES the closed set of rules its own run may refuse with
-- (`refuses`) — the argument-dependent refusals the central gate cannot decide before the call. The declaration is
-- fenced against the CODE, derived by cartograph from agent.lua's own graph: a verb's run function, its cone out, and
-- the literal rule at every `refuse(...)` call inside that cone. Declared must EQUAL derived — a rule the code can raise
-- and the catalogue does not name is a hidden refusal; a declared rule no code raises is a promise nothing keeps.

local agent = require 'cartograph.agent'
local store = require 'cartograph.store'
local ts = require 'cartograph.providers.treesitter'

local function sorted_set(t)
    local seen, out = {}, {}
    for _, r in ipairs(t) do if not seen[r] then seen[r] = true; out[#out + 1] = r end end
    table.sort(out)
    return out
end

test('refuses: each verb DECLARES exactly the rules its run can refuse with, derived from agent.lua\'s own graph', function ()
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local src = assert(io.open('lua/cartograph/agent.lua', 'rb')):read('a')
    local fd = assert(io.open(root .. '/agent.lua', 'wb')); fd:write(src); fd:close()
    store.ingest(ts.extract(root))
    -- the literal rule at every refuse() call, by the function that makes it
    local cv = require('cartograph.callview').of(store.data)
    local argv = require 'cartograph.argv'
    local by_fn, sites, literal = {}, 0, 0
    for i = 1, cv.n do
        if cv.get(i, 'callee') == 'refuse' then
            sites = sites + 1
            local rec = { _av = cv.get(i, '_av'), _av0 = cv.get(i, '_av0'), _avn = cv.get(i, '_avn'), argv = cv.get(i, 'argv') }
            local a = argv.at(rec, 1)
            ok(a and a.k == 'lit', ('the refuse() at line %s names its rule as a LITERAL, or the set is not closed'):format(
                tostring(cv.get(i, 'line'))))
            if a and a.k == 'lit' then
                literal = literal + 1
                local f = cv.get(i, 'fn'); by_fn[f] = by_fn[f] or {}; by_fn[f][#by_fn[f] + 1] = a.v
            end
        end
    end
    ok(sites > 40, 'the instrument SAW the refuse sites (' .. sites .. ') — an empty census proves nothing')
    eq(sites, literal)
    -- each verb's run, located by its own definition line, and its cone out (the cone verb, dogfooded)
    local at = require 'cartograph.at'
    local starts = {}
    for _, n in ipairs(store.data.nodes) do
        if (n.kind == 'function' or n.kind == 'method') and n.range then starts[at.sl(n.range) + 1] = n.id end
    end
    local with_rules = 0
    for _, name in ipairs(agent.ORDER) do
        local v = agent.VERBS[name]
        local line = debug.getinfo(v.run, 'S').linedefined
        local id = starts[line]
        ok(id, name .. '\'s run is a function node of the graph (line ' .. line .. ')')
        if id then
            local d = agent.answer(store, 'cone', { node = id, direction = 'out' })
            ok(d.ok, name .. ': cone answered')
            local rules = {}
            for _, r in ipairs(by_fn[id] or {}) do rules[#rules + 1] = r end
            for _, row in ipairs(d.result or {}) do
                for _, r in ipairs(by_fn[row.id] or {}) do rules[#rules + 1] = r end
            end
            local derived = sorted_set(rules)
            if #derived > 0 then with_rules = with_rules + 1 end
            eq('table', type(v.refuses), name .. ' declares `refuses` (an empty list is a claim)')
            eq(derived, sorted_set(v.refuses or {}),
                name .. ': declared `refuses` must EQUAL what its run can raise')
        end
    end
    ok(with_rules >= 20, 'the derivation found rules for most verbs (' .. with_rules .. ')')
    vim.fn.delete(root, 'rf')
end)

-- ★ THE ENFORCEMENT IS EXERCISED, NOT MERELY ITS OUTCOME (the absences lesson, agentq_spec): no shipped verb refuses
-- with an undeclared rule, so the branch is reached by injecting a verb through the open table.
test('refuses: an UNDECLARED rule still refuses, and is disclosed as an envelope bug naming it', function ()
    store.ingest({ schema = 1, root = '/x', nodes = {}, edges = {}, calls = {} })
    agent.VERBS.__spec_badrule = { summary = 'test-only', tier_basis = 'observation', absences = {}, refuses = { 'declared-rule' },
        args = {}, run = function (_, a) return { refusal = { rule = a.rule or 'surprise-rule', reason = 'test', remedy = 'test' } } end }
    agent.VERBS.__spec_badrule.args = { { name = 'rule', type = 'string' } }
    local d = agent.answer(store, '__spec_badrule', {})
    local good = agent.answer(store, '__spec_badrule', { rule = 'declared-rule' })
    agent.VERBS.__spec_badrule = nil
    eq(false, d.ok)
    eq('surprise-rule', d.refusal.rule, 'the rule is information: it goes out unchanged')
    local bug
    for _, n in ipairs(d.notes or {}) do if n.kind == 'envelope-bug' then bug = n end end
    ok(bug and bug.why:find('surprise-rule', 1, true), 'and the drift is DISCLOSED, naming the rule')
    for _, n in ipairs(good.notes or {}) do
        ok(n.kind ~= 'envelope-bug', 'a declared rule carries no envelope-bug note')
    end
end)

test('refuses: a real argument-dependent refusal is declared, and graph_info publishes the set', function ()
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/m.lua', 'w')); fd:write('local M = {}\nfunction M.f() return 1 end\nreturn M\n'); fd:close()
    store.ingest(ts.extract(root))
    local d = agent.answer(store, 'node_at', { file = 'nope.lua', line = 1 })
    eq(false, d.ok)
    ok(vim.tbl_contains(agent.VERBS.node_at.refuses, d.refusal.rule), 'node_at declares ' .. tostring(d.refusal.rule))
    for _, n in ipairs(d.notes or {}) do ok(n.kind ~= 'envelope-bug', vim.inspect(n)) end
    local by = {}
    for _, r in ipairs(agent.answer(store, 'graph_info', {}).result) do by[r.verb] = r end
    eq({ 'undo-refused' }, by.txn_undo.refuses)
    eq({}, by.graph_info.refuses, 'an empty set is published as a claim, not omitted')
    vim.fn.delete(root, 'rf')
end)
