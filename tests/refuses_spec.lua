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
    eq({ 'not-applied', 'not-latest', 'undo-refused', 'unknown-entry' }, by.txn_undo.refuses)
    eq({}, by.graph_info.refuses, 'an empty set is published as a claim, not omitted')
    vim.fn.delete(root, 'rf')
end)

-- ── CART-1986: what a RUN-TIME refusal names next ──────────────────────────────
test('refuses: every declared rule has exactly ONE candidate class, and every class and producer is real', function ()
    local declared = {}
    for _, name in ipairs(agent.ORDER) do for _, r in ipairs(agent.VERBS[name].refuses) do declared[r] = true end end
    local KEYS = { arg = true, decline = true, prerequisite = true, host = true, omit = true, none = true }
    local used_kind = {}
    for r in pairs(declared) do ok(agent.RUN_RULES[r], r .. ' is declared by a verb, so it needs a candidate class') end
    for r, cls in pairs(agent.RUN_RULES) do
        ok(declared[r], r .. ' has a class but no verb declares it (dead entry)')
        local n = 0
        for k in pairs(cls) do ok(KEYS[k], r .. ': unknown class key ' .. k); n = n + 1 end
        eq(1, n, r .. ' has exactly one class')
        if cls.arg then ok(agent.ARG_PRODUCERS[cls.arg], r .. ': argument kind ' .. cls.arg .. ' has producers'); used_kind[cls.arg] = true end
        if cls.prerequisite then ok(agent.VERBS[cls.prerequisite], r .. ': prerequisite is a verb') end
        if cls.none then ok(#cls.none > 10, r .. ': a `none` class states WHY nothing helps') end
    end
    for kind, p in pairs(agent.ARG_PRODUCERS) do
        ok(used_kind[kind], 'argument kind ' .. kind .. ' is used by some rule')
        if type(p) == 'table' then for _, v in ipairs(p) do ok(agent.VERBS[v], kind .. ': producer ' .. v .. ' is a verb') end
        else eq('planners', p) end
    end
end)

local function full_stub()
    return { is_index_only = function () return false end, data = { calls = {} }, has_mention_index = function () return true end }
end
local function roles(rows)
    local o = {}
    for _, x in ipairs(rows or {}) do o[#o + 1] = (x.role or x.kind) .. ':' .. tostring(x.name) end
    return table.concat(o, ' ')
end

test('refuses: each class yields its rows — producers to RETRY with, prerequisites, alternatives, host flags, omissions', function ()
    local s = full_stub()
    eq('producer:node_find', roles(agent.run_candidates(s, 'node_at', { rule = 'unknown-file' })),
        'a wrong file: the verb that produces valid ones (node_at is never offered to itself)')
    eq('producer:node_find', roles(agent.run_candidates(s, 'node_at', { rule = 'no-address' })),
        'node_at produces nodes, but is never offered as its own producer')
    local p = agent.run_candidates(s, 'edges_callers', { rule = 'stale-ref' })
    eq('producer:node_find producer:node_at', roles(p))
    eq('node', p[1].supplies, 'a producer says which argument it supplies')
    eq('prerequisite:txn_preview', roles(agent.run_candidates(s, 'txn_apply', { rule = 'unpreviewed' })))
    eq('prerequisite:journal_get', roles(agent.run_candidates(s, 'txn_undo', { rule = 'undo-refused' })))
    local alt = agent.run_candidates(s, 'txn_plan_declare', { rule = 'does-not-fit' })
    ok(roles(alt):find('alternative:txn_plan_replace', 1, true), 'a decline offers the same-question siblings: ' .. roles(alt))
    for _, x in ipairs(alt) do eq('change-it', x.question) end
    eq('host-flag:--write', roles(agent.run_candidates(s, 'toolbelt_run', { rule = 'read-only-host' })))
    eq('omit:path', roles(agent.run_candidates(s, 'txn_save', { rule = 'unwritable-path' })))
    eq({}, agent.run_candidates(s, 'helm_chart', { rule = 'unrenderable' }), 'a `none` class is an empty list: a claim')
    -- plan handles come from the DERIVED planner set (VERB_OF_FAMILY), never a list here
    local planners = agent.run_candidates(s, 'txn_preview', { rule = 'unknown-plan' })
    local fam = {}
    for _, v in pairs(agent._families) do fam[v] = true end
    for _, x in ipairs(planners) do ok(fam[x.name], x.name .. ' mints plans') end
    eq(vim.tbl_count(fam), #planners)
    -- a site's own rows come FIRST, then the class's
    local merged = agent.run_candidates(s, 'txn_apply', { rule = 'stale-plan', candidates = {
        { kind = 'band', role = 'value', name = 'b2', change = 'pass' },
        { kind = 'verb', role = 'producer', name = 'txn_plan_optimize', supplies = 'plan' } } })
    eq('value:b2', roles({ merged[1] })); eq('producer:txn_plan_optimize', roles({ merged[2] }))
    eq(1 + vim.tbl_count(fam), #merged, 'the site\'s planner is not repeated by the class')
    -- an unclassified rule with no site rows has NO candidates field — never a false "nothing answers this"
    eq(nil, agent.run_candidates(s, 'node_at', { rule = 'never-classified' }))
end)

test('refuses: an ambiguous file names its hits under the ARGUMENT that was refused, capped, then the producer', function ()
    local root = vim.fn.tempname()
    for _, d in ipairs({ 'a', 'b' }) do
        vim.fn.mkdir(root .. '/' .. d, 'p')
        local fd = assert(io.open(root .. '/' .. d .. '/m.lua', 'w')); fd:write('local M = {}\nfunction M.f() return 1 end\nreturn M\n'); fd:close()
    end
    store.ingest(ts.extract(root))
    local d = agent.answer(store, 'node_at', { file = 'm.lua', line = 2 })
    eq('ambiguous-file', d.refusal.rule)
    local cs = d.refusal.candidates
    eq('argument', cs[1].kind); eq('file', cs[1].name); eq('argument', cs[2].kind)
    eq({ 'a/m.lua', 'b/m.lua' }, (function () local v = { cs[1].value, cs[2].value }; table.sort(v); return v end)())
    eq(2, d.refusal.candidates_total)
    eq('producer:node_find', roles({ cs[3] }))
    -- mentions refuses its `from`, and the row says so (java: lua opts out of the mention index mentions needs)
    if parser_available('java') then
        local jroot = vim.fn.tempname()
        for _, dd in ipairs({ 'a', 'b' }) do
            vim.fn.mkdir(jroot .. '/' .. dd, 'p')
            -- (the mention index holds the names a file USES from outside, so the fixture must use one)
            local jf = assert(io.open(jroot .. '/' .. dd .. '/M.java', 'w')); jf:write('class M { int f() { return Helper.compute(1); } }\n'); jf:close()
        end
        store.ingest(ts.extract(jroot))
        ok(store.has_mention_index(), 'the premise: this graph carries a mention index')
        local m = agent.answer(store, 'mentions', { name = 'Helper', from = 'M.java' })
        eq('ambiguous-file', m.refusal.rule)
        eq('from', m.refusal.candidates[1].name)
        vim.fn.delete(jroot, 'rf')
    end
    -- the CALLING SESSION decides what is offered (CART-1977): with node_find unmounted, it is not a candidate
    local ns = assert(agent.umount_verb(nil, 'node_find'))
    local u = agent.answer(store, 'node_at', { file = 'nosuch.lua', line = 1 }, { mounts = ns })
    eq('unknown-file', u.refusal.rule)
    eq({}, u.refusal.candidates, 'the only producer is unmounted in this session')
    vim.fn.delete(root, 'rf')
end)
