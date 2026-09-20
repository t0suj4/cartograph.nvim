-- THE T3 HOST (CART-0144) — lua/cartograph/agent.lua behind tools/mcpserve.lua.
-- What these specs fence is the property the whole agent surface exists for, now
-- carried over a wire instead of a return value:
--
--   ABSENT, REFUSED, FRONTIER AND UNAVAILABLE MUST RENDER DIFFERENTLY, AND A
--   CAPABILITY REFUSAL MUST BE REACHABLE BY A CALLER.
--
-- The second half is not decoration. agentq shipped a `thin-index` refusal that
-- no caller could reach through its interface (CART-0580), so one of the two
-- refusals the honesty contract rests on could neither be demonstrated nor
-- fenced. Here `--index-only` is a documented server mode and the refusal is
-- driven over stdio below.
--
-- TWO LAYERS, the same split agentq_spec uses. The verb table is exercised IN
-- PROCESS (pure, fast, and it is where the envelope invariant lives); the server
-- is exercised END TO END, because "newline-delimited JSON-RPC on stdout and
-- nothing else" is a property of the PROCESS and cannot be asserted any other
-- way. The end-to-end half drives it with this project's own MCP CLIENT
-- (lua/cartograph/mcp.lua) — the client and the server are now two ends of one
-- wire, so the spec is also their parity test.

local agent = require 'cartograph.agent'
local mcp = require 'cartograph.mcp'
local store = require 'cartograph.store'
local tier = require 'cartograph.tier'
local ts = require 'cartograph.providers.treesitter'

local function ready()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    return pcall(vim.treesitter.get_string_parser, '', 'lua')
end

-- ── the fixture root: one file per absence bucket ────────────────────────────

-- ABSENT (`genuinely_dead`): a file-local nothing mentions. Also the live pair
-- `M.caller` -> `M.pub`, which is the one real ref edge in the root.
local M_LUA = [[
local M = {}
local function genuinely_dead(y) return y end
function M.pub(z) return z end
function M.caller() return M.pub(1) end
return M
]]

-- REFUSED (`walk`): the same-named nested helper twice, so `walk(...)` cannot be
-- bound to one of them and each reads as callerless while being perfectly alive.
local W_LUA = [[
local M = {}
function M.a()
    local function walk(t) return t end
    return walk({})
end
function M.b()
    local function walk(t) return t end
    return walk({})
end
return M
]]

-- FRONTIER (`handler`): the name occurs a second time in a construct that
-- produced no call record, so nothing was looked at there.
local F_LUA = [[
local M = {}
-- handler is wired up by the engine, not called from lua
local function handler(x) return x end
function M.go() return 1 end
return M
]]

-- SELF-REFERENCE: the one shape that has a first hop and still reaches nothing
-- new, because a cone excludes its own anchor. Without it cone's
-- `self-reference-only` branch is a claim no caller can check.
local R_LUA = [[
local M = {}
function M.rec(n) if n > 0 then return M.rec(n - 1) end return 0 end
return M
]]

local FIXTURE = { ['m.lua'] = M_LUA, ['w.lua'] = W_LUA, ['f.lua'] = F_LUA,
    ['r.lua'] = R_LUA }

local function mkfixture()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    for name, src in pairs(FIXTURE) do
        local fd = assert(io.open(root .. '/' .. name, 'w'))
        fd:write(src); fd:close()
    end
    return root
end

-- ── layer 1: the verb table, in process ──────────────────────────────────────

local function ingest(root)
    local data = ts.extract(root)
    data.root = data.root or root
    store.ingest(data)
    return store
end

local function idof(name)
    for _, n in ipairs(store.data.nodes) do
        if n.name == name and (n.kind == 'function' or n.kind == 'method') then return n.id end
    end
end

test('agent: an empty result NEVER arrives as a bare list — every verb names its absence', function ()
    if not ready() then skip('no treesitter') end
    local root = mkfixture()
    ingest(root)
    -- one call per verb that CAN come back empty, each aimed at a subject that
    -- makes it so. The envelope invariant is asserted uniformly: no result rows
    -- => an absence value AND a named premise, and never a rung.
    local cases = {
        { 'node_find', { query = 'nosuchnamexyz' } },
        { 'node_at', { file = 'f.lua', line = 2 } }, -- a comment line: inside no definition
        { 'edges_callers', { node = idof('genuinely_dead') } },
        { 'edges_callees', { node = idof('M.pub') } },
        { 'why', { file = 'f.lua', line = 2, col = 1 } }, -- the same comment line
        { 'lint_run', { rules = { 'truncation' } } },
    }
    for _, c in ipairs(cases) do
        local d, status = agent.answer(store, c[1], c[2])
        eq('ok', status, c[1] .. ' answers')
        eq(0, #d.result, c[1] .. ' was aimed at an empty answer')
        ok(d.absence ~= vim.NIL and type(d.absence) == 'string',
            ('%s returned an empty result with NO absence — a bare [] is the defect'):format(c[1]))
        ok(vim.tbl_contains({ 'absent', 'refused', 'frontier', 'unavailable' }, d.absence),
            ('%s invented the absence value %q'):format(c[1], tostring(d.absence)))
        ok(d.absence_why ~= vim.NIL and #d.absence_why.premise > 0,
            c[1] .. ' names the premise that failed')
        ok(#d.absence_why.why > 20, c[1] .. ' explains it: ' .. tostring(d.absence_why.why))
        eq(vim.NIL, d.tier, c[1] .. ' minted a rung for an answer that resolved nothing')
        -- and the value is one the verb DECLARED it could produce. `absences` is
        -- what graph_info publishes, so a verb that emits an undeclared value has
        -- made that surface a lie.
        ok(vim.tbl_contains(agent.VERBS[c[1]].absences, d.absence),
            ('%s emitted %q, which it does not declare in `absences`'):format(c[1], d.absence))
    end
    -- THE REFUSALS ARE REACHABLE TOO (CART-0580: a refusal a caller cannot reach
    -- is not a contract). These are the input-shaped ones; the CAPABILITY refusal
    -- is driven over the wire below.
    for _, c in ipairs({
        { 'node_at', { file = 'nosuchfile.lua', line = 1 }, 'unknown-file' },
        { 'edges_callers', {}, 'no-address' },
        { 'edges_callers', { node = 'no::such::id' }, 'unknown-node' },
        { 'edges_callers', { file = 'm.lua', line = 1 }, 'no-subject' },
    }) do
        local d, status = agent.answer(store, c[1], c[2])
        eq('refusal', status, c[1] .. ' must REFUSE, not answer')
        eq(c[3], d.refusal.rule)
        ok(#d.refusal.remedy > 10, c[3] .. ' says what to change')
        eq(vim.NIL, d.result, 'a refusal has no result at all — not an empty one')
        eq(vim.NIL, d.absence, 'and it is not an absence')
    end
    vim.fn.delete(root, 'rf')
end)

test('agent: tier_basis decides which side of the axis a NON-empty answer carries', function ()
    if not ready() then skip('no treesitter') end
    local root = mkfixture()
    ingest(root)
    -- a RESOLUTION verb: rows are ref edges, so the answer carries a real rung
    local callers = agent.answer(store, 'edges_callers', { node = idof('M.pub') })
    ok(#callers.result > 0, 'M.pub is called by M.caller')
    ok(tier.rank(callers.tier) ~= nil,
        'a resolution answer carries a tier.LADDER rung, got ' .. tostring(callers.tier))
    eq(vim.NIL, callers.absence, 'and no absence — exactly one side of the axis exists')
    for _, r in ipairs(callers.result) do
        ok(tier.rank(r.tier) ~= nil, 'every ROW carries its own rung too: ' .. tostring(r.tier))
    end
    -- an OBSERVATION verb: nothing was resolved, so there is no rung to report
    -- and the null means "this question has no rung", not "unknown"
    local found = agent.answer(store, 'node_find', { query = 'walk' })
    ok(#found.result >= 2, 'both walks are found')
    eq(vim.NIL, found.tier, 'an observation answer never mints a rung')
    eq(vim.NIL, found.absence, 'and a non-empty one carries no absence')
    eq('observation', agent.VERBS.node_find.tier_basis)
    eq('resolution', agent.VERBS.edges_callers.tier_basis)
    vim.fn.delete(root, 'rf')
end)

test('agent: callers-empty is classified by the SHIPPED alibi premises, not re-decided', function ()
    if not ready() then skip('no treesitter') end
    local root = mkfixture()
    ingest(root)
    local got = {}
    for _, c in ipairs({ { 'absent', 'genuinely_dead' }, { 'refused', 'walk' },
                         { 'frontier', 'handler' } }) do
        local d = agent.answer(store, 'edges_callers', { node = idof(c[2]) })
        eq(0, #d.result, c[2] .. ' has no callers in this graph')
        got[c[1]] = d.absence
        eq(c[1], d.absence, ('callers of %s'):format(c[2]))
    end
    local seen = {}
    for _, a in pairs(got) do
        ok(not seen[a], ('two buckets both report %q — they render the same, which is the defect'):format(a))
        seen[a] = true
    end
    -- and an empty caller list is NOT a deletion licence: what else keeps it
    -- alive rides along, so the agent cannot misread the empty list
    local pub = agent.answer(store, 'edges_callers', { node = idof('M.a') })
    if #pub.result == 0 then
        local kinds = {}
        for _, n in ipairs(pub.notes) do kinds[n.kind] = true end
        ok(kinds['alive-otherwise'], 'an exported callerless fn says why it is still alive')
    end
    vim.fn.delete(root, 'rf')
end)

-- ── phase 2: refs in the envelope (CART-0145) ────────────────────────────────

test('agent: a row carries BOTH handles, and the durable one addresses the same node', function ()
    if not ready() then skip('no treesitter') end
    local root = mkfixture()
    ingest(root)
    local found = agent.answer(store, 'node_find', { query = 'M.pub' })
    ok(#found.result >= 1, 'M.pub is in the graph')
    local row = found.result[1]
    ok(type(row.id) == 'string' and #row.id > 0, 'the SESSION id is present')
    ok(type(row.ref) == 'table', 'and so is the DURABLE ref: ' .. vim.inspect(row.ref))
    -- the ref is refs.lua's shape, not a stringified id
    eq('m.lua', row.ref.file)
    eq('M.pub', row.ref.name)
    ok(row.ref.kind == 'function' or row.ref.kind == 'method', tostring(row.ref.kind))
    ok(row.ref.file ~= row.id,
        'a ref that is just the id again is the phase-1 misnomer, not a durable handle')

    -- THE POINT OF THE PAIR: the two handles must address the SAME node, or the
    -- durable one is decorative.
    local by_id = agent.answer(store, 'edges_callers', { node = row.id })
    local by_ref = agent.answer(store, 'edges_callers', { ref = row.ref })
    eq(by_id.subject.id, by_ref.subject.id, 'id and ref land on the same subject')
    eq(#by_id.result, #by_ref.result, 'and produce the same answer')
    eq(by_id.tier, by_ref.tier)
    vim.fn.delete(root, 'rf')
end)

test('agent: a STALE ref REFUSES with refs.lua own why — it never lands on a guess', function ()
    if not ready() then skip('no treesitter') end
    local root = mkfixture()
    ingest(root)
    -- MISSING: nothing in that file bears the name any more (the deletion case).
    local gone = agent.answer(store, 'edges_callers',
        { ref = { file = 'm.lua', kind = 'function', name = 'was_renamed_away' } })
    eq('stale-ref', gone.refusal.rule, 'a handle that no longer resolves is a REFUSAL')
    eq('missing', gone.refusal.why, "and it carries refs.resolve's own verdict, verbatim")
    ok(#gone.refusal.remedy > 10, 'with a remedy an agent can act on')
    eq(vim.NIL, gone.result, 'a refusal has no result at all — not an empty one')
    eq(vim.NIL, gone.absence, 'and it is NOT an absence: nothing about the code was concluded')

    -- AMBIGUOUS: w.lua holds two `walk`s, and a ref with no witness and no
    -- ordinal cannot separate them. Picking one would be silent damage on the
    -- write side, which is exactly why this lands before the write verbs.
    local amb = agent.answer(store, 'edges_callers',
        { ref = { file = 'w.lua', kind = 'function', name = 'walk' } })
    eq('stale-ref', amb.refusal.rule)
    ok(amb.refusal.why:find('ambiguous', 1, true),
        'ambiguous and missing are DIFFERENT verdicts and must not render alike: '
        .. tostring(amb.refusal.why))
    ok(amb.refusal.reason ~= gone.refusal.reason, 'and their reasons differ too')

    -- A MALFORMED REF IS A DIFFERENT FAULT: re-addressing fixes a stale handle,
    -- and nothing fixes a ref that never had a name. They must not share a rule.
    local _, status = agent.answer(store, 'edges_callers', { ref = { file = 'm.lua' } })
    eq('usage', status, 'a ref missing `kind`/`name` is a fault in the CALL, not a stale handle')
    vim.fn.delete(root, 'rf')
end)

test('agent: a ref that resolves WITH A CAVEAT answers, and says so — it does not refuse', function ()
    if not ready() then skip('no treesitter') end
    local root = mkfixture()
    ingest(root)
    local found = agent.answer(store, 'node_find', { query = 'genuinely_dead' })
    ok(#found.result >= 1)
    local ref = vim.deepcopy(found.result[1].ref)
    ok(ref.witness ~= nil, 'the ref was minted with a behaviour witness')
    ref.witness = 'deadbeef' -- as if the body had been edited under us
    local d = agent.answer(store, 'edges_callers', { ref = ref })
    eq(vim.NIL, d.refusal, 'a drifted witness still RESOLVES — it is an answer, not a refusal')
    local caveat
    for _, n in ipairs(d.notes) do if n.kind == 'ref-caveat' then caveat = n end end
    ok(caveat, 'and the caveat rides as a note rather than being swallowed: '
        .. vim.inspect(d.notes))
    ok(caveat.why:find('drift', 1, true), tostring(caveat.why))
    vim.fn.delete(root, 'rf')
end)

-- ── phase 2: the analysis catalogue (CART-0145 half B) ───────────────────────

test('agent: EVERY verb in the catalogue obeys the envelope invariant', function ()
    if not ready() then skip('no treesitter') end
    local root = mkfixture()
    ingest(root)
    -- one plausible call per verb. The assertion is uniform and it is the whole
    -- contract: a non-empty answer carries no absence, an empty one ALWAYS names
    -- a premise, and the value it names is one the verb DECLARED — a value in
    -- `absences` that no branch emits, or a branch emitting an undeclared one,
    -- is CART-0580 again.
    --
    -- ★ THE WRITE AXIS IS DRIVEN HERE TOO (CART-0146), and the reason is this
    -- test's QUANTIFIER, not coverage. tests/agentwrite_spec.lua owns the write
    -- verbs' answering paths — those need a fixture that gets MUTATED, which a
    -- spec whose other tests read this one must not do. What THIS test is, and
    -- nothing else is, is the fence saying a verb in ORDER is never UNDRIVEN. So
    -- an entry may name the disposition this read-only fixture can reach:
    -- `expect = 'refusal'` fences the refusal shape as tightly as an answer's,
    -- rather than exempting the verb from the sweep.
    local calls = {
        graph_info = {}, node_find = { query = 'walk' },
        node_at = { file = 'm.lua', line = 3 },
        edges_callers = { node = idof('M.pub') },
        edges_callees = { node = idof('M.caller') },
        why = { file = 'm.lua', line = 4, col = 26 }, lint_run = {},
        clones_find = {}, cone = { node = idof('M.caller') }, ladder = {},
        territory = {}, census = {}, mentions = { name = 'walk' }, externals = {},
        -- THE VERSION AXIS (CART-0595). This fixture reads nothing external, so
        -- both move verbs land on an ABSENCE here — which is exactly what this
        -- sweep is for: the empty answer must name a premise the verb declared.
        -- The port-specific behaviour (a worklist, a refusal carrying
        -- portability's own sentence, the read/call contrast) lives in
        -- tests/agentport_spec.lua, on a fixture that actually reads a
        -- Factorio global.
        portability_targets = {},
        portability_move = { from = 'lua-factorio-11', to = 'lua-factorio' },
        portability_move_calls = { from = 'lua-factorio-11', to = 'lua-factorio' },
        -- planning with no symbol named, and previewing / fetching a handle that
        -- was never minted: refusals reachable without touching a byte
        txn_plan_moveset = { args = { dest = 'lib/new.lua' }, expect = 'refusal' },
        txn_plan_optimize = { args = { kind = 'cse', node = idof('M.caller') } },
        -- ⚠ ABSENCE, NOT REFUSAL: this fixture's function joins no near-clone
        -- family, and "no family here" is a fact about the CODE. A refusal would
        -- be a fact about the instrument, and the two are what this envelope
        -- exists to keep apart.
        txn_plan_extract_family = { args = { node = idof('M.caller') } },
        -- naming no container and no payload: a refusal reachable without
        -- touching a byte, and the one this verb gives most often in the wild —
        -- 70.6% of containers with two or more members share no shape at all
        txn_plan_declare = { args = { member = 'x = 1' }, expect = 'refusal' },
        -- naming no subject: a refusal reachable without touching a byte
        txn_plan_annotate = { args = { text = 'note' }, expect = 'refusal' },
        txn_preview = { args = { plan = 'plan-never-minted' }, expect = 'refusal' },
        -- the handoff pair. Both refuse here without touching a byte: saving a
        -- handle this host never minted, and loading a path that does not exist.
        txn_save = { args = { plan = 'plan-never-minted' }, expect = 'refusal' },
        txn_load = { args = { path = '/nonexistent/plan.json' }, expect = 'refusal' },
        journal_list = {},
        journal_get = { args = { id = 'no-such-entry' }, expect = 'refusal' },
        -- the two mutating verbs refuse on this host whatever the handle says.
        -- WHICH rule fires (read-only vs unknown-plan) depends on how the module
        -- flag was left, so only the SHAPE is asserted: coupling this spec to
        -- another spec's teardown would be a worse fence than a looser one.
        txn_apply = { args = { plan = 'plan-never-minted' }, expect = 'refusal' },
        txn_undo = { args = {}, expect = 'refusal' },
    }
    for _, verb in ipairs(agent.ORDER) do
        local c = calls[verb]
        ok(c ~= nil, ('verb %s is in ORDER but this spec does not drive it'):format(verb))
        -- an entry is either a bare argument table (the common case) or
        -- { args = …, expect = … }; no verb has an argument called `args`
        local args, expect = c.args or c, c.expect or 'ok'
        local d, status = agent.answer(store, verb, args)
        eq(expect, status, verb .. ' answers: ' .. vim.inspect(d.refusal or d.error))
        if expect == 'refusal' then
            eq(false, d.ok, verb .. ' refused, so ok is false')
            ok(type(d.refusal.rule) == 'string' and #d.refusal.rule > 0,
                verb .. ' names the rule it refused under')
            ok(#d.refusal.reason > 20, verb .. ' says why: ' .. tostring(d.refusal.reason))
            eq(vim.NIL, d.absence,
                verb .. ': a refusal is NOT an absence — the two must never render alike')
        elseif #d.result > 0 then
            eq(vim.NIL, d.absence, verb .. ' returned rows AND an absence')
        else
            ok(type(d.absence) == 'string',
                ('%s returned an empty result with NO absence — a bare [] is the defect'):format(verb))
            ok(vim.tbl_contains(agent.VERBS[verb].absences, d.absence),
                ('%s emitted %q, which it does not declare in `absences`'):format(verb, d.absence))
            ok(#d.absence_why.premise > 0 and #d.absence_why.why > 20,
                verb .. ' names the premise: ' .. vim.inspect(d.absence_why))
        end
        -- and no verb may invent an envelope bug for itself
        for _, n in ipairs(d.notes) do
            ok(n.kind ~= 'envelope-bug', ('%s: %s'):format(verb, tostring(n.why)))
        end
    end
    -- journal_list/journal_get MKDIR this root's journal directory in the state
    -- dir just by looking. The fixture root is temp and gets deleted; its journal
    -- lives elsewhere and would outlive it, so it is removed by name.
    require('cartograph.journal').wipe(root)
    vim.fn.delete(root, 'rf')
end)

test('agent: a cone is the FIRST HOP transitively, and says what its headline quantifies over', function ()
    if not ready() then skip('no treesitter') end
    local root = mkfixture()
    ingest(root)
    local out = agent.answer(store, 'cone', { node = idof('M.caller'), direction = 'out' })
    ok(#out.result >= 1, 'M.caller reaches M.pub: ' .. vim.inspect(out))
    ok(tier.rank(out.tier) ~= nil, 'the headline is a real rung: ' .. tostring(out.tier))
    local scope
    for _, n in ipairs(out.notes) do if n.kind == 'headline-scope' then scope = n end end
    ok(scope, 'a cone MUST say that its rows carry no per-row rung and why')
    ok(scope.why:find('UNKNOWN', 1, true),
        'a null row tier here means unknown, not "no rung applies": ' .. tostring(scope.why))
    for _, r in ipairs(out.result) do
        ok(r.tier == nil, 'and no row invents one')
    end

    -- the INVERSE direction is a different question, not the same set
    local inward = agent.answer(store, 'cone', { node = idof('M.pub'), direction = 'in' })
    ok(#inward.result >= 1, 'M.pub is reached by M.caller')

    -- AN EMPTY CONE DELEGATES: the premise that hides a neighbour is the premise
    -- that hides the whole cone, so the absence is edges_*'s, not a new judgement.
    local dead = agent.answer(store, 'cone', { node = idof('genuinely_dead'), direction = 'in' })
    eq(0, #dead.result)
    eq('absent', dead.absence, 'the callerless local reads absent through the cone too')
    local deleg
    for _, n in ipairs(dead.notes) do if n.kind == 'cone-is-first-hop' then deleg = n end end
    ok(deleg, 'and the delegation is stated rather than hidden')
    -- …which is what makes the OTHER two declared absences reachable at all: the
    -- cone inherits the whole taxonomy, so refused and frontier stay distinct
    -- here instead of collapsing into one empty set.
    local seen = { absent = true }
    for _, case in ipairs({ { 'refused', 'walk' }, { 'frontier', 'handler' } }) do
        local d = agent.answer(store, 'cone', { node = idof(case[2]), direction = 'in' })
        eq(0, #d.result)
        eq(case[1], d.absence, ('the %s cone of %s'):format(case[1], case[2]))
        ok(not seen[d.absence], 'the buckets render differently through the cone too')
        seen[d.absence] = true
        ok(vim.tbl_contains(agent.VERBS.cone.absences, d.absence),
            'cone emitted an undeclared absence')
    end
    -- RECURSION reaches nothing through the cone either, and for the same reason
    -- edges_callees reports it: the delegation carries the honest premise rather
    -- than a second one written here.
    local rec = agent.answer(store, 'cone', { node = idof('M.rec'), direction = 'out' })
    eq(0, #rec.result, 'a self edge is excluded from the reachability adjacency')
    eq('only-calls-itself', rec.absence_why.premise,
        'and NOT "it calls nothing", which is what the cone would have said')

    -- direction is a CLOSED set: an unknown one is a fault in the call
    local _, status = agent.answer(store, 'cone',
        { node = idof('M.caller'), direction = 'sideways' })
    eq('usage', status, 'an undeclared direction must not be silently read as `out`')
    vim.fn.delete(root, 'rf')
end)

-- A HAND-BUILT GRAPH, because two honest answers are only reachable on one: a
-- function with NO data-flow record (nothing was comparable) and a graph with no
-- function at all (nothing to partition). Both are declared in `absences`, and a
-- declared value no branch can reach is the defect CART-0580 named.
local function synth(nodes, edges)
    store.ingest { root = '/synth', provider = 'synthetic',
        nodes = nodes, edges = edges or {}, calls = {} }
    return store
end

test('agent: a cone that reaches an id with no node is a FRONTIER, not an absence', function ()
    -- the adjacency is built from ref edges and nothing checks that the target
    -- has a node. If it does not, the cone reaches SOMETHING it cannot render —
    -- and "I found nothing" would be the wrong sentence for that.
    synth({
        { id = 'a.lua', kind = 'module', name = 'a.lua', file = 'a.lua', order = 0 },
        { id = 'a.lua::f', kind = 'function', name = 'f', file = 'a.lua', order = 1 },
    }, { { kind = 'ref', from = 'a.lua::f', to = 'ghost.lua::vanished' } })
    local d = agent.answer(store, 'cone', { node = 'a.lua::f', direction = 'out' })
    eq(0, #d.result)
    eq('frontier', d.absence)
    eq('reached-ids-are-not-nodes', d.absence_why.premise)
    eq(1, d.absence_why.evidence.reached)
    ok(vim.tbl_contains(agent.VERBS.cone.absences, d.absence))
end)

test('agent: "nothing was comparable" and "no clones" are different answers', function ()
    synth {
        { id = 'a.lua', kind = 'module', name = 'a.lua', file = 'a.lua', order = 0 },
        { id = 'a.lua::f', kind = 'function', name = 'f', file = 'a.lua', order = 1 },
        { id = 'a.lua::g', kind = 'function', name = 'g', file = 'a.lua', order = 2 },
    }
    local d = agent.answer(store, 'clones_find', {})
    eq(0, #d.result)
    eq('unavailable', d.absence,
        'two functions with no data-flow record is NOT "no clones" — nothing was compared')
    eq('no-dataflow-records', d.absence_why.premise)
    eq(2, d.absence_why.evidence.functions)
    eq(0, d.absence_why.evidence.with_dataflow)

    -- and with no function at all, the answer is a genuine absence
    synth { { id = 'a.lua', kind = 'module', name = 'a.lua', file = 'a.lua', order = 0 } }
    local e = agent.answer(store, 'clones_find', {})
    eq('absent', e.absence)
    eq('no-functions', e.absence_why.premise)
    -- the same graph has no root to partition from
    local t = agent.answer(store, 'territory', {})
    eq(0, #t.result)
    eq('absent', t.absence)
    eq('no-entry-points', t.absence_why.premise)
end)

-- EVERY DECLARED ABSENCE MUST HAVE A BRANCH THAT EMITS IT. `frontier` is the one
-- the fixture root cannot produce — every file in it parses — so the unparsed
-- frontier is built by hand. Without this the four verbs below would advertise a
-- value in `absences` that nothing can reach, which is CART-0580 verbatim.
-- ★ FOUND WHILE DRIVING THE CONE, and it is a phase-1 bug, not a phase-2 one.
-- store.lua excludes a self ref edge from uses/usedby ON PURPOSE (recursion must
-- not make a dead function look alive), which is right — but it meant a purely
-- self-recursive function came back from edges_callees as `no-call-sites`, whose
-- stated premise is "the extractor recorded no call at all inside this function
-- body". The call record exists and RESOLVED; only the row is missing. An
-- absence whose premise is false is worse than a bare empty list, because it
-- looks like it was checked.
test('agent: a self-recursive function does NOT report that it calls nothing', function ()
    if not ready() then skip('no treesitter') end
    local root = mkfixture()
    ingest(root)
    local d = agent.answer(store, 'edges_callees', { node = idof('M.rec') })
    eq(0, #d.result, 'the self edge is not in the reachability adjacency, by design')
    eq('absent', d.absence)
    eq('only-calls-itself', d.absence_why.premise,
        'the premise must be TRUE, not merely the nearest empty-list story')
    ok(d.absence_why.evidence.self_calls >= 1, 'and it counts the sites it saw')
    ok(d.absence_why.why:find('NOT', 1, true),
        'it says outright what it is not: ' .. d.absence_why.why)
    local note
    for _, n in ipairs(d.notes) do if n.kind == 'self-calls' then note = n end end
    ok(note, 'and the recursion rides as a note, since it has no row of its own')
    -- a function that really does call nothing still says so, in its own words
    local pub = agent.answer(store, 'edges_callees', { node = idof('M.pub') })
    eq('no-call-sites', pub.absence_why.premise,
        'the two must not collapse into one story')
    vim.fn.delete(root, 'rf')
end)

test('agent: an unparsed frontier makes every empty catalogue answer a FRONTIER, not an absence', function ()
    synth {
        { id = 'a.lua', kind = 'module', name = 'a.lua', file = 'a.lua', order = 0 },
        { id = 'b.bin', kind = 'module', name = 'b.bin', file = 'b.bin', order = 1,
            unparsed = true },
        -- a function that IS comparable (it carries a df record), so the clone
        -- verb reaches its frontier branch instead of stopping at "nothing was
        -- comparable" — the two are different answers and both must be reachable
        { id = 'a.lua::f', kind = 'function', name = 'f', file = 'a.lua', order = 2,
            df = { stmts = {} } },
    }
    for _, verb in ipairs({ 'clones_find', 'ladder', 'externals' }) do
        local d = agent.answer(store, verb, {})
        eq(0, #d.result, verb .. ' has nothing to report on this graph')
        eq('frontier', d.absence,
            ('%s reported %q where a file was never looked at'):format(verb, tostring(d.absence)))
        ok(vim.tbl_contains(agent.VERBS[verb].absences, d.absence),
            verb .. ' emitted an undeclared absence')
        eq(1, d.absence_why.evidence.unparsed_files)
    end
    -- territory needs a graph with no ROOT at all, so it gets its own shape
    synth {
        { id = 'a.lua', kind = 'module', name = 'a.lua', file = 'a.lua', order = 0 },
        { id = 'b.bin', kind = 'module', name = 'b.bin', file = 'b.bin', order = 1,
            unparsed = true },
    }
    local t = agent.answer(store, 'territory', {})
    eq('frontier', t.absence, 'a root may be sitting in the file nothing read')
    ok(vim.tbl_contains(agent.VERBS.territory.absences, t.absence))
end)

test('agent: the honesty verbs answer "no" as a fact, not as an empty set', function ()
    if not ready() then skip('no treesitter') end
    local root = mkfixture()
    ingest(root)
    -- MENTIONS is the weakest question the graph answers, and it still says no
    -- with a premise attached rather than handing back a bare list.
    local m = agent.answer(store, 'mentions', { name = 'nosuchidentifierxyz' })
    eq(0, #m.result)
    eq('absent', m.absence)
    eq('name-not-in-any-index', m.absence_why.premise)
    ok(m.absence_why.evidence.indexed_files >= 1,
        'and it says how many files WERE indexed, so the no is measurable')
    -- a name that IS there comes back with the contract attached
    local w = agent.answer(store, 'mentions', { name = 'walk' })
    ok(#w.result >= 1, 'walk is mentioned')
    local contract
    for _, n in ipairs(w.notes) do
        if n.kind == 'a-mention-is-not-a-reference' then contract = n end
    end
    ok(contract, 'a mention answer MUST state that it is not a reference answer')

    -- EXTERNALS on a graph with no call at all: "no boundary" because nothing
    -- calls anything, which is a different claim from "everything lands inside".
    synth { { id = 'a.lua', kind = 'module', name = 'a.lua', file = 'a.lua', order = 0 } }
    local e = agent.answer(store, 'externals', {})
    eq(0, #e.result)
    eq('absent', e.absence)
    eq('no-call-records', e.absence_why.premise)
    vim.fn.delete(root, 'rf')
end)

test('agent: territory says whether its roots are DECLARED or merely apparent', function ()
    if not ready() then skip('no treesitter') end
    local root = mkfixture()
    ingest(root)
    local d = agent.answer(store, 'territory', {})
    ok(#d.result >= 1, 'the fixture has callerless functions, so it has apparent roots')
    local basis
    for _, n in ipairs(d.notes) do if n.kind == 'entry-basis' then basis = n end end
    ok(basis, 'the partition MUST state what its roots are')
    eq('apparent', basis.premise, 'nothing declares an entry point in this fixture')
    ok(basis.why:find('refused', 1, true),
        'and it must say why apparent roots are only as good as the resolution: '
        .. tostring(basis.why))
    for _, r in ipairs(d.result) do
        ok(type(r.id) == 'string', 'an entry row is a NODE row, addressable again')
    end
    vim.fn.delete(root, 'rf')
end)

-- ── CART-0581: the headline quantifier is published, not merely reasoned ─────

test('agent: every verb that has a headline tier declares WHICH QUANTIFIER made it', function ()
    if not ready() then skip('no treesitter') end
    local root = mkfixture()
    ingest(root)
    local info = agent.answer(store, 'graph_info', {})
    local by = {}
    for _, r in ipairs(info.result) do by[r.verb] = r end
    for _, verb in ipairs(agent.ORDER) do
        ok(by[verb], 'the catalogue lists ' .. verb)
        local v = agent.VERBS[verb]
        if v.tier_basis == 'observation' then
            -- no rung is ever reported, so there is no summary to quantify
            eq(vim.NIL, by[verb].tier_headline,
                verb .. ' reports no tier, so a headline rule would be meaningless')
        else
            ok(v.tier_headline == 'floor' or v.tier_headline == 'peak',
                ('%s can report a `tier` but declares no tier_headline — the value is legible, its meaning is not (CART-0581)'):format(verb))
            eq(v.tier_headline, by[verb].tier_headline,
                verb .. ': the catalogue must publish what the verb declares')
        end
    end
    -- THE POINT: this surface is FLOOR and agentq is PEAK, under one field name.
    eq('floor', agent.VERBS.edges_callers.tier_headline)
    vim.fn.delete(root, 'rf')
end)

-- ── layer 2: the server, over stdio ──────────────────────────────────────────

local SERVERS = {}

--- a live client against a server on the fixture root (`thin` => --index-only).
--- Lazily spawned and shared: extraction is paid once per mode, and mcp.lua's
--- VimLeavePre hook kills any client a failing test left open.
local function client(thin)
    local key = thin and 'thin' or 'full'
    if SERVERS[key] then return SERVERS[key].c, SERVERS[key].root end
    local root = mkfixture()
    local cmd = { vim.v.progpath, '--headless', '-u', 'NONE', '-l',
        repo('tools/mcpserve.lua'), root }
    if thin then cmd[#cmd + 1] = '--index-only' end
    local c, err = mcp.connect { cmd = cmd, timeout = 60000 }
    ok(c ~= nil, 'mcpserve did not come up: ' .. tostring(err))
    SERVERS[key] = { c = c, root = root }
    return c, root
end

test('mcpserve: the handshake completes and tools/list advertises every verb', function ()
    if not ready() then skip('no treesitter') end
    local c = client(false)
    eq('cartograph', c.server.name, 'initialize returned our serverInfo')
    local res, why = c:request('tools/list', vim.empty_dict())
    ok(res ~= nil, 'tools/list: ' .. tostring(why))
    local by = {}
    for _, t in ipairs(res.tools) do by[t.name] = t end
    for _, name in ipairs(agent.ORDER) do
        ok(by[name], 'advertised: ' .. name)
        eq('object', by[name].inputSchema.type, name .. ' carries a JSON Schema')
        ok(by[name].description:find('absence', 1, true),
            name .. "'s description states the envelope, so a client that never reads our docs still learns it")
    end
    -- the names a client may actually use: `.` is rejected by several clients
    for _, t in ipairs(res.tools) do
        ok(t.name:match('^[%w_-]+$'), ('tool name %q is not portable'):format(t.name))
    end
end)

test('mcpserve: a successful call returns the envelope, decoded, over the wire', function ()
    if not ready() then skip('no treesitter') end
    local c = client(false)
    local found = c:call('node_find', { query = 'M.pub' })
    ok(found and found.ok, 'node_find answered: ' .. vim.inspect(found))
    ok(#found.result >= 1, 'M.pub is in the graph')
    eq('full', found.graph.index, 'every answer carries the graph it was read off')
    local id = found.result[1].id
    local callers = c:call('edges_callers', { node = id })
    eq(true, callers.ok)
    ok(#callers.result >= 1, 'M.pub has a caller over the wire')
    ok(tier.rank(callers.tier) ~= nil, 'with a real rung: ' .. tostring(callers.tier))
    eq(vim.NIL, callers.absence, 'and no absence beside it')
    -- `why` is PORTED, not reimplemented: the shipped honesty record, verbatim
    local w = c:call('why', { file = 'm.lua', line = 4, col = 26 })
    eq(true, w.ok)
    ok(#w.result == 1, 'why answers about the position: ' .. vim.inspect(w))
    ok(w.result[1].kind == 'call' or w.result[1].kind == 'def',
        'and it is the shipped shape, got ' .. tostring(w.result[1].kind))
end)

-- ⚠ THREE OF THEM, AND THE NAME USED TO SAY FOUR while the loop below ran over
-- three cases — a count in a test name that nothing checked. The other reading
-- kinds have their own homes and cannot be produced by `edges_callers`:
-- `unavailable` is the thin-index spec above ("an unshipped profile is
-- unavailable"), and `unbuilt` (CART-0831) is minted by a contract front end,
-- not by a graph query. tier_spec owns the full-set membership assertion; this
-- one owns the WIRE, which is why it names what it actually sends.
test('mcpserve: three absences survive the wire and stay distinguishable', function ()
    if not ready() then skip('no treesitter') end
    local c = client(false)
    local seen = {}
    for _, case in ipairs({ { 'absent', 'genuinely_dead' }, { 'refused', 'walk' },
                            { 'frontier', 'handler' } }) do
        local f = c:call('node_find', { query = case[2] })
        ok(#f.result >= 1, 'found ' .. case[2])
        local d = c:call('edges_callers', { node = f.result[1].id })
        eq(true, d.ok, 'an absence is an ANSWER, not a failure')
        eq(0, #d.result)
        eq(case[1], d.absence, ('callers of %s over the wire'):format(case[2]))
        ok(not seen[d.absence], 'the buckets render differently')
        seen[d.absence] = true
        ok(#d.absence_why.why > 20, 'and each says WHICH premise failed')
    end
end)

test('mcpserve: the thin-index CAPABILITY REFUSAL is reachable by a caller', function ()
    if not ready() then skip('no treesitter') end
    local c = client(true)
    -- graph_info is the negotiation surface: it says what may be asked at all
    local info = c:call('graph_info', vim.empty_dict())
    eq(true, info.ok)
    eq('index-only', info.graph.index, 'the server opened a thin graph')
    local by = {}
    for _, r in ipairs(info.result) do by[r.verb] = r end
    eq(false, by.edges_callers.available, 'and says so BEFORE the agent asks')
    ok(#by.edges_callers.unavailable_why > 20, 'with a reason')
    eq(true, by.node_find.available, 'while the observation verbs still serve')

    -- the refusal itself, over the wire — NOT an empty list, NOT an error
    local d, why, raw = c:call('edges_callers', { file = 'm.lua', line = 3 })
    ok(d ~= nil, 'a refusal must arrive as CONTENT the agent can read, not as a transport error: '
        .. tostring(why))
    eq(false, raw.isError, 'isError would flatten the refusal to a string and lose the remedy')
    eq(false, d.ok)
    eq('thin-index', d.refusal.rule, 'the refusal names its RULE')
    ok(#d.refusal.reason > 20, 'and its reason')
    ok(#d.refusal.remedy > 10, 'and a remedy, so the agent can fix the call')
    eq(vim.NIL, d.result, 'a refusal has no result at all — not an empty one')
    eq(vim.NIL, d.absence, 'and it is NOT an absence: nothing about the code was concluded')

    -- an observation verb is unaffected: a thin graph still has definitions
    local f = c:call('node_find', { query = 'genuinely_dead' })
    eq(true, f.ok)
    ok(#f.result >= 1, 'the thin index still answers what it CAN answer')
end)

test('mcpserve: a protocol fault is a JSON-RPC error, not an answer', function ()
    if not ready() then skip('no treesitter') end
    local c = client(false)
    local d, why = c:call('nosuchtool', vim.empty_dict())
    eq(nil, d, 'an unknown tool is not an answer about the code')
    ok(tostring(why):find('unknown tool', 1, true), 'and says so: ' .. tostring(why))
    local d2, why2 = c:call('node_find', vim.empty_dict())
    eq(nil, d2, 'a missing required argument is a fault in the CALL')
    ok(tostring(why2):find('requires', 1, true), 'and names the argument: ' .. tostring(why2))
    local d3, why3 = c:call('node_find', { query = 'x', nosucharg = 1 })
    eq(nil, d3, 'an unknown argument is refused rather than silently ignored')
    ok(tostring(why3):find('nosucharg', 1, true), tostring(why3))
end)

test('mcpserve: lint findings carry what they are WORTH, and refusals ride along', function ()
    if not ready() then skip('no treesitter') end
    local c = client(false)
    local d = c:call('lint_run', vim.empty_dict())
    eq(true, d.ok)
    if #d.result > 0 then
        for _, f in ipairs(d.result) do
            ok(type(f.rule) == 'string', 'a finding names its rule')
            ok(f.disposition ~= vim.NIL,
                ('%s carries no disposition — authoritative and suggestive would act alike'):format(f.rule))
        end
    else
        ok(type(d.absence) == 'string', 'an empty lint report is never a clean bill of health by default')
    end
end)

test('mcpserve: a REF survives the wire and addresses the same node as its id', function ()
    if not ready() then skip('no treesitter') end
    local c = client(false)
    local found = c:call('node_find', { query = 'M.pub' })
    ok(#found.result >= 1, 'M.pub is in the graph')
    local row = found.result[1]
    ok(type(row.id) == 'string', 'the row carries its session id')
    ok(type(row.ref) == 'table' and type(row.ref.name) == 'string',
        'and its durable ref, as an OBJECT — a stringified ref would need a parser '
        .. 'nobody wrote: ' .. vim.inspect(row.ref))
    -- handed straight back, unedited: the round trip is the contract
    local by_ref = c:call('edges_callers', { ref = row.ref })
    eq(true, by_ref.ok, 'a ref is accepted wherever an id is: ' .. vim.inspect(by_ref.refusal))
    local by_id = c:call('edges_callers', { node = row.id })
    eq(by_id.subject.id, by_ref.subject.id, 'and lands on the same node')
    eq(#by_id.result, #by_ref.result)

    -- A STALE REF IS AN ANSWER ABOUT THE WORLD, so it rides as CONTENT with the
    -- rule intact — isError would flatten it to a string and lose exactly the
    -- field an agent must branch on.
    local d, why, raw = c:call('edges_callers',
        { ref = { file = 'm.lua', kind = 'function', name = 'was_renamed_away' } })
    ok(d ~= nil, 'a stale ref must arrive as content, not a transport error: ' .. tostring(why))
    eq(false, raw.isError)
    eq(false, d.ok)
    eq('stale-ref', d.refusal.rule)
    eq('missing', d.refusal.why, "refs.resolve's own verdict survives the wire")
    ok(#d.refusal.remedy > 10)
    eq(vim.NIL, d.result, 'a refusal has no result at all — not an empty one')
end)

test('mcpserve: every catalogue verb is advertised and answers over the wire', function ()
    if not ready() then skip('no treesitter') end
    local c = client(false)
    local res = c:request('tools/list', vim.empty_dict())
    local by = {}
    for _, t in ipairs(res.tools) do by[t.name] = t end
    for _, name in ipairs({ 'clones_find', 'cone', 'ladder', 'territory', 'census',
                            'mentions', 'externals' }) do
        ok(by[name], 'advertised: ' .. name)
        eq('object', by[name].inputSchema.type, name .. ' carries a JSON Schema')
        ok(by[name].description:find('absence', 1, true),
            name .. ' states the envelope in its own description')
    end
    -- the ref argument is published as a SHAPE, so a schema-driven client can
    -- hand the object back instead of reducing it to a string
    local refp = by.edges_callers.inputSchema.properties.ref
    eq('object', refp.type)
    ok(refp.properties.witness ~= nil, 'the witness field is published: ' .. vim.inspect(refp))

    for _, case in ipairs({ { 'census', vim.empty_dict() }, { 'ladder', vim.empty_dict() },
                            { 'territory', vim.empty_dict() }, { 'externals', vim.empty_dict() },
                            { 'clones_find', vim.empty_dict() },
                            { 'mentions', { name = 'walk' } } }) do
        local d = c:call(case[1], case[2])
        eq(true, d.ok, case[1] .. ' answered: ' .. vim.inspect(d and d.refusal))
        if #d.result == 0 then
            ok(type(d.absence) == 'string',
                case[1] .. ' returned a bare [] over the wire — the defect')
        end
        ok(#d.notes >= 1, case[1] .. ' carries at least one honesty note')
    end
    -- the census counts what was EXTRACTED, and its row is the whole answer
    local cen = c:call('census', vim.empty_dict())
    eq(1, #cen.result)
    ok(cen.result[1].calls.total >= 1, 'the fixture makes calls: ' .. vim.inspect(cen.result[1].calls))
end)

test('mcpserve: the catalogue PUBLISHES the headline quantifier (CART-0581)', function ()
    if not ready() then skip('no treesitter') end
    local c = client(false)
    local info = c:call('graph_info', vim.empty_dict())
    local by = {}
    for _, r in ipairs(info.result) do by[r.verb] = r end
    eq('floor', by.edges_callers.tier_headline,
        'a caller list is UNIVERSAL as presented, so its headline is the weakest rung')
    eq('floor', by.cone.tier_headline)
    eq(vim.NIL, by.node_find.tier_headline, 'an observation verb has no headline to quantify')
    -- and the same fact reaches a client that never calls graph_info
    local res = c:request('tools/list', vim.empty_dict())
    for _, t in ipairs(res.tools) do
        if t.name == 'edges_callers' then
            ok(t.description:find('tier_headline=floor', 1, true),
                'the tool description says it too: ' .. t.description)
        end
    end
end)

test('mcpserve: mentions REFUSES on a thin index rather than reporting zero files', function ()
    if not ready() then skip('no treesitter') end
    local c = client(true)
    -- index_only skips the collect pass that builds the mention index, so an
    -- empty answer here would mean "no file mentions this" AND "there is no
    -- index" at once — opposite claims wearing one shape.
    local d, why, raw = c:call('mentions', { name = 'walk' })
    ok(d ~= nil, 'the refusal arrives as content: ' .. tostring(why))
    eq(false, raw.isError)
    eq(false, d.ok)
    eq('no-mention-index', d.refusal.rule)
    ok(#d.refusal.remedy > 10, 'and says what to change')
    eq(vim.NIL, d.absence, 'a missing INSTRUMENT is not an absence in the code')
end)

-- ── ★★★ N ROOTS ON THE AGENT SURFACE (CART-0823) ────────────────────────────
-- The cockpit has been multi-band since bands shipped; this host took exactly
-- ONE root. ~/work/brotardcast registers TWO cartograph servers in its
-- .mcp.json for that reason — two extractions, two processes, and no way to ask
-- either about the other.
-- ⚠ WHAT IS FENCED IS "SWITCHABLE", NOT "JOINED". Only one band is readable at a
-- time (a stashed band is a store.capture() snapshot), so these specs assert
-- that a verb can be POINTED at a root and says which one answered — never that
-- a verb spans two. That join is CART-0821 / CART-0026.

-- a second root whose function name exists NOWHERE in the first, so "which band
-- answered" is decidable from the ANSWER and not just from the envelope's label
local B_LUA = [[
local M = {}
function M.only_in_band_b(x) return x end
return M
]]

local function mkfixture_b()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/b.lua', 'w'))
    fd:write(B_LUA); fd:close()
    return root
end

local TWO
local function client_two()
    if TWO then return TWO.c, TWO.a, TWO.b end
    local a, b = mkfixture(), mkfixture_b()
    local c, err = mcp.connect { cmd = { vim.v.progpath, '--headless', '-u', 'NONE',
        '-l', repo('tools/mcpserve.lua'), a, b }, timeout = 60000 }
    ok(c ~= nil, 'two-root mcpserve did not come up: ' .. tostring(err))
    TWO = { c = c, a = a, b = b }
    return c, a, b
end

test('mcpserve: a SINGLE root advertises no band argument at all', function ()
    if not ready() then skip('no treesitter') end
    -- ★ THE BYTE-IDENTICAL PATH. `agent.multiband()` returns nil below two
    -- bands, so a one-root host is exactly what it was — no injected argument,
    -- no routing branch, and a client written against it sees no change. This is
    -- asserted FIRST because it is the property most easily lost.
    local c = client(false)
    local res = c:request('tools/list', vim.empty_dict())
    for _, t in ipairs(res.tools) do
        eq(nil, (t.inputSchema.properties or {}).band,
            t.name .. ' must not offer `band` on a single-root host')
    end
end)

test('mcpserve: two roots advertise a DISCOVERABLE band argument, with the roster', function ()
    if not ready() then skip('no treesitter') end
    local c = client_two()
    local res, why = c:request('tools/list', vim.empty_dict())
    ok(res ~= nil, 'tools/list: ' .. tostring(why))
    local n = 0
    for _, t in ipairs(res.tools) do
        local band = (t.inputSchema.properties or {}).band
        ok(band ~= nil, t.name .. ' must offer `band`')
        if band then
            n = n + 1
            -- ★ AN ENUM, NOT FREE TEXT: a client can offer the real band names
            -- instead of guessing them, which is the difference between a router
            -- an agent can use and one it cannot.
            eq(2, #(band.enum or {}), t.name .. '.band lists both open bands')
            ok(band.description:find('does NOT join', 1, true)
                or band.description:find('not available', 1, true),
                'the description says this selects a root rather than joining two')
        end
    end
    ok(n >= 10, 'the band argument is injected in ONE place, so every verb has it: ' .. n)
end)

test('mcpserve: the FIRST root is the default band even when argv is RELATIVE', function ()
    if not ready() then skip('no treesitter') end
    -- ⚠⚠ THE RELATIVE FORM IS THE ONE THAT BROKE SILENTLY, and it took reverting
    -- to see: `vim.fn.expand('./ra')` returns `./ra` unchanged while the provider
    -- absolutizes `data.root`, so comparing the two matched NOTHING and the
    -- LAST band stayed active — the exact opposite of the documented "first root
    -- is the default", with no error anywhere. Measured on the revert:
    --     active rb   (wrong, last root)   vs   active ra   (fixed)
    -- ★ Driven through a shell so the roots really are relative to a cwd; the
    -- MCP client harness has no cwd option, and a spec that SKIPS here would
    -- have fenced nothing. The banner on stderr is the assertion surface.
    local parent = vim.fn.tempname()
    vim.fn.mkdir(parent .. '/ra', 'p'); vim.fn.mkdir(parent .. '/rb', 'p')
    local fa = assert(io.open(parent .. '/ra/a.lua', 'w')); fa:write(M_LUA); fa:close()
    local fb = assert(io.open(parent .. '/rb/b.lua', 'w')); fb:write(B_LUA); fb:close()
    local cmd = ('cd %s && %s --headless -u NONE -l %s ./ra ./rb </dev/null 2>&1')
        :format(vim.fn.shellescape(parent), vim.fn.shellescape(vim.v.progpath),
            vim.fn.shellescape(repo('tools/mcpserve.lua')))
    local out = vim.fn.system({ 'sh', '-c', cmd })
    local active = out:match('bands %[[^%]]*%], active (%S+)')
    ok(active ~= nil, 'the host reported its roster: ' .. out:sub(1, 300))
    eq('ra', active, 'the FIRST relative root is the default band')
    vim.fn.delete(parent, 'rf')
end)

test('mcpserve: graph_info publishes the roster, each band with its root', function ()
    if not ready() then skip('no treesitter') end
    local c, a = client_two()
    local d, why = c:call('graph_info', vim.empty_dict())
    ok(d ~= nil, 'graph_info: ' .. tostring(why))
    eq(a, d.graph.root, 'argv order is the only preference the operator expressed')
    ok(d.graph.band ~= vim.NIL and d.graph.band ~= nil, 'and the envelope NAMES the band')
    -- the roster rides on the negotiation surface: the enum gives names, this
    -- gives each name its ROOT, which is what makes the choice meaningful
    local bands
    for _, note in ipairs(d.notes or {}) do if note.kind == 'bands' then bands = note end end
    ok(bands ~= nil, 'graph_info carries a bands note')
    ok(bands.why:find('2 roots', 1, true), 'and says how many are open')
    ok(bands.why:find(a, 1, true), 'naming each root, not just each band name')
end)

test('mcpserve: `band` points a verb at the other root, and the ANSWER proves which', function ()
    if not ready() then skip('no treesitter') end
    local c, a, b = client_two()
    -- band A cannot see B's function, and that is the control: without it, a
    -- passing find in band B would not distinguish "switched" from "both
    -- resident in one graph".
    local d0 = c:call('node_find', { query = 'only_in_band_b' })
    eq(0, #d0.result, 'band A does not contain band B\'s function')
    ok(d0.absence ~= vim.NIL, 'and says so as an ABSENCE, not a bare empty list')
    eq(a, d0.graph.root, 'answered from the default (first) root')
    -- ⚠ AND A BAND NAME IS ONLY ACCEPTED WHERE IT IS ADVERTISED: on a
    -- single-root host `band` stays an unknown argument rather than being
    -- silently ignored, which would let a caller believe it took effect.
    local d1, why1 = client(false):call('node_find', { query = 'M', band = 'anything' })
    eq(nil, d1, 'a single-root host does not accept `band`')
    ok(tostring(why1):find('no argument', 1, true),
        'it is a USAGE fault, not a silently ignored argument: ' .. tostring(why1))
end)

test('mcpserve: the SWITCH happens, is STICKY, and every answer says where it is', function ()
    if not ready() then skip('no treesitter') end
    local c, a, b = client_two()
    local bandnames = {}
    local res = c:request('tools/list', vim.empty_dict())
    for _, t in ipairs(res.tools) do
        if t.name == 'node_find' then bandnames = t.inputSchema.properties.band.enum end
    end
    table.sort(bandnames)
    -- find the band whose root is B, from the roster rather than by guessing
    local bname
    local gi = c:call('graph_info', vim.empty_dict())
    for _, note in ipairs(gi.notes or {}) do
        if note.kind == 'bands' then
            for name, root in note.why:gmatch('([%w_%-%.:]+)%*? %-> (%S+)') do
                if root == b then bname = name:gsub('%*$', '') end
            end
        end
    end
    ok(bname ~= nil, 'the roster names the band owning root B')

    local d = c:call('node_find', { query = 'only_in_band_b', band = bname })
    eq(b, d.graph.root, 'the answer came from root B')
    ok(#d.result >= 1, 'and it FOUND B\'s function — a label alone would not prove the switch')

    -- ★★ STICKY, ASSERTED RATHER THAN ASSUMED. Naming a band switches the
    -- session; a following call that omits `band` answers about THAT band. The
    -- alternative (scoped, switch-and-restore) would drop every BAND_TRANSIENT
    -- cache twice per call — the clone index alone is seconds repo-wide — so
    -- sticky is the deliberate choice and this is what makes it discoverable
    -- rather than surprising.
    local d2 = c:call('graph_info', vim.empty_dict())
    eq(b, d2.graph.root, 'the band is STICKY: a later call without `band` stays in B')
    eq(d.graph.band, d2.graph.band, 'and the envelope keeps naming it')

    -- back, so later specs in this file are not surprised by the cursor
    local names = {}
    for _, note in ipairs(d2.notes or {}) do
        if note.kind == 'bands' then
            for name, root in note.why:gmatch('([%w_%-%.:]+)%*? %-> (%S+)') do
                if root == a then names[#names + 1] = name:gsub('%*$', '') end
            end
        end
    end
    local back = c:call('graph_info', { band = names[1] })
    eq(a, back.graph.root, 'and it switches back the same way')
end)

test('mcpserve: an unknown band REFUSES with the roster, and does not answer from the active one', function ()
    if not ready() then skip('no treesitter') end
    local c, a = client_two()
    local d, why, raw = c:call('node_find', { query = 'M', band = 'no-such-band' })
    ok(d ~= nil, 'the refusal arrives as content: ' .. tostring(why))
    eq(false, raw.isError)
    eq(false, d.ok)
    eq('unknown-band', d.refusal.rule)
    -- ★ THE POINT OF REFUSING RATHER THAN DEFAULTING: answering from the active
    -- band would attribute a real result to the wrong root, silently. An agent
    -- that mistyped a band name must not receive a plausible answer.
    eq(vim.NIL, d.result, 'nothing was run')
    ok(d.refusal.remedy:find('|', 1, true) or d.refusal.remedy:find('graph_info', 1, true),
        'and the remedy names the open bands')
    eq(a, d.graph.root, 'the envelope reports the band the caller was ALREADY in')
end)

test('mcpserve: a duplicate root is REFUSED at startup, not silently deduped', function ()
    if not ready() then skip('no treesitter') end
    -- ⚠ CART-0837 ARRIVES AT THIS ENTRY POINT. `session.begin` accepts a
    -- duplicate root, `name_for` uniquifies the NAME, and `by_root` then returns
    -- whichever `pairs()` yields first — nondeterministically. The cockpit is
    -- safe only because init.lua's caller checks `by_root` first; argv has no
    -- such guard, which is exactly what that finding predicted.
    local a = mkfixture()
    local out = vim.fn.system({ vim.v.progpath, '--headless', '-u', 'NONE', '-l',
        repo('tools/mcpserve.lua'), a, a })
    ok(vim.v.shell_error ~= 0, 'the server refuses to start')
    ok(out:find('given twice', 1, true), 'and says why: ' .. out:sub(1, 200))
    vim.fn.delete(a, 'rf')
end)

test('mcpserve: the servers shut down cleanly', function ()
    if not ready() then skip('no treesitter') end
    for _, s in pairs(SERVERS) do
        s.c:close()
        vim.fn.delete(s.root, 'rf')
    end
    SERVERS = {}
    if TWO then
        TWO.c:close()
        vim.fn.delete(TWO.a, 'rf'); vim.fn.delete(TWO.b, 'rf')
        TWO = nil
    end
    ok(true)
end)

-- ── the agent row and the prose proposal must CLAIM the same thing ───────────
-- CART-0964. `clones_find` branched on `a.kind` alone and so told an agent "no
-- parameter list recovers the difference" about a pair whose prose proposal said
-- "NOT blocked: 2 function parameter(s) cover all 2 shape divergence(s)" — two
-- renderings of one analysis, contradicting each other in the same second. They now
-- read ONE predicate, `clones.extract_verdict`.

local function clonefix(files)
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    for name, src in pairs(files) do
        local fd = assert(io.open(root .. '/' .. name, 'w')); fd:write(src); fd:close()
    end
    ingest(root)
    return root
end

local function nearrow(res, n1, n2)
    for _, r in ipairs(res.result or {}) do
        local nm = {}
        for _, m in ipairs(r.members or {}) do nm[tostring(m.name)] = true end
        if nm[n1] and nm[n2] then return r end
    end
end

test('agent: a covered structural pair says so — the row and the proposal AGREE', function ()
    if not ready() then return end
    -- the swapped-argument shape: `occ(caller, id)` against `occ(id, callee)`, which
    -- is a rename divergence the analysis merges into ONE function parameter
    -- ⚠ THE BINDER IS THE SAME ON BOTH SIDES ON PURPOSE. A differing loop-variable
    -- name costs TWO edits (the `for` clause harvests as two rows), which puts the
    -- pair past the SHIPPED max_dist of 2 that this verb uses — and a fixture the
    -- shipped default cannot see would test a distance nobody runs.
    local base = '  local out = {}\n  local id = item_id(src)\n  local seen = {}\n'
    local a = base .. '  for _, caller in ipairs(edges(id)) do\n'
        .. '    local hits = occ(caller, id)\n    out[#out + 1] = hits\n'
        .. '    seen[caller] = true\n  end\n  return out'
    local b = base .. '  for _, caller in ipairs(edges(id)) do\n'
        .. '    local hits = occ(id, caller)\n    out[#out + 1] = hits\n'
        .. '    seen[caller] = true\n  end\n  return out'
    local function fn(name, body)
        return ('local function %s(src)\n%s\nend\nreturn %s\n'):format(name, body, name)
    end
    local root = clonefix { ['ag1.lua'] = fn('incoming_calls', a),
        ['ag2.lua'] = fn('outgoing_calls', b) }

    local res = agent.answer(store, 'clones_find', { kind = 'near' })
    local row = nearrow(res, 'incoming_calls', 'outgoing_calls')
    ok(row, 'the near pair reaches the agent surface')
    eq('structural', row and row.shape)

    -- ★ THE AGREEMENT FIRST, because it is the defect: everything below is the
    -- mechanism that makes it hold, and a mechanism assertion failing first would
    -- hide which claim actually moved.
    local clones = require 'cartograph.clones'
    local p = clones.near_of(store, row.members[1].id, {})[1]
    local prose = table.concat(clones.extract_proposal(p, store), '\n')
    local prose_covered = prose:find('NOT blocked', 1, true) ~= nil
    local row_covered = tostring(row.action):find('cover all', 1, true) ~= nil
    eq(prose_covered, row_covered,
        'the prose and the agent row agree on whether a helper is blocked:\n' .. prose
            .. '\n  action: ' .. tostring(row.action))
    ok(row_covered, 'and on this pair both say it is covered')

    ok(row and #(row.structs or {}) > 0, 'the SHAPE divergences are exported, not only the value holes')
    ok(row and #(row.fparams or {}) > 0, 'and the merged function parameters the analysis derived')
    vim.fn.delete(root, 'rf')
end)

test('agent: the FACT PRICE reaches the agent row', function ()
    if not ready() then return end
    local function fn(name, mod)
        return ('local function %s(src)\n  local m = require(%q)\n  local out = {}\n'
            .. '  local seed = load(src)\n  local n = count(seed)\n'
            .. '  out[#out + 1] = m.run(seed)\n  out[#out + 1] = n\n'
            .. '  persist(out)\n  return out\nend\nreturn %s\n'):format(name, mod, name)
    end
    local root = clonefix { ['ap1.lua'] = fn('via_alpha', 'pkg.alpha'),
        ['ap2.lua'] = fn('via_beta', 'pkg.beta') }
    local res = agent.answer(store, 'clones_find', { kind = 'near' })
    local row = nearrow(res, 'via_alpha', 'via_beta')
    ok(row, 'the pair reaches the agent surface')
    local priced
    for _, h in ipairs(row and row.holes or {}) do
        if h.literal_dep and tostring(h.literal_dep) ~= 'NUL' then priced = h end
    end
    ok(priced, 'the import-path hole carries its price, not just its value')
    vim.fn.delete(root, 'rf')
end)

-- ── the read-only -> write handoff (CART-0969) ───────────────────────────────
-- A plan handle is SESSION-scoped, which is what stops a read-only host from
-- being useful for planning: the thing it produces dies with it. txn_save /
-- txn_load make the plan an ARTIFACT, and the point is the capability split —
-- planning needs no write permission, applying does, and in between a human can
-- read the file.

test('agent: a plan survives save/load, and the LOADED handle must still be previewed', function ()
    if not ready() then return end
    local root = mkfixture()
    ingest(root)
    -- moveset rather than optimize: this fixture offers the optimizer no CSE
    -- candidate, and a test that SKIPS is not a test.
    local made = agent.answer(store, 'txn_plan_moveset',
        { seed = { idof('M.pub') }, dest = 'lib/new.lua' })
    local pid = made.ok and made.subject and made.subject.plan
    ok(pid ~= nil and pid ~= vim.NIL, 'the planner minted a handle: ' .. tostring(pid))

    local saved = agent.answer(store, 'txn_save', { plan = pid })
    ok(saved.ok, 'the recipe saves: '
        .. tostring(type(saved.refusal) == 'table' and saved.refusal.reason))
    local path = saved.result and saved.result[1] and saved.result[1].path
    ok(path ~= nil and vim.fn.filereadable(path) == 1, 'and the file exists: ' .. tostring(path))

    local loaded = agent.answer(store, 'txn_load', { path = path })
    ok(loaded.ok, 'it loads back: '
        .. tostring(type(loaded.refusal) == 'table' and loaded.refusal.reason))
    local row = loaded.result and loaded.result[1]
    ok(row and row.plan ~= nil and row.plan ~= pid,
        'under a FRESH handle, RE-DERIVED not restored: ' .. tostring(row and row.plan))
    -- ⚠ THE RESET IS THE POINT. `txn_apply` refuses a plan that has not been
    -- previewed, and preview is what re-runs the dry run against THIS graph. A
    -- loaded plan carrying a previous session's tick would skip the one step
    -- that re-derives it here.
    eq(false, row and row.previewed,
        'and unpreviewed — the write session must re-derive it before applying')
    local prev = agent.answer(store, 'txn_preview', { plan = row.plan })
    ok(prev.ok, 'the loaded handle previews like any other: '
        .. tostring(type(prev.refusal) == 'table' and prev.refusal.reason))
    vim.fn.delete(path)
    vim.fn.delete(root, 'rf')
end)

test('agent: a recipe re-derives against the CURRENT tree, never a stale offset', function ()
    if not ready() then return end
    local root = mkfixture()
    ingest(root)
    local made = agent.answer(store, 'txn_plan_moveset',
        { seed = { idof('M.pub') }, dest = 'lib/new.lua' })
    ok(made.ok and made.subject and made.subject.plan ~= nil, 'a plan was minted')
    local saved = agent.answer(store, 'txn_save', { plan = made.subject.plan })
    local path = saved.result[1].path

    -- ★★ THE WHOLE REASON THIS IS A RECIPE. A saved PLAN would carry line offsets
    -- from the tree as it was; move the file and those offsets are fiction. A
    -- recipe carries the ASKING, so the planner runs again here and either
    -- succeeds against the current text or refuses on its own terms. Neither
    -- outcome can apply a stale edit, which is the property being asserted.
    local fd = assert(io.open(root .. '/m.lua', 'a'))
    fd:write('\n-- a line that moves everything below it\n'); fd:close()
    ingest(root)   -- the write session sees the changed tree

    local loaded = agent.answer(store, 'txn_load', { path = path })
    ok(loaded.ok or (type(loaded.refusal) == 'table'),
        'the load either re-derives or refuses — never silently restores')
    if loaded.ok then
        local row = loaded.result[1]
        ok(row.plan ~= nil, 'it re-derived a plan against the CHANGED tree: '
            .. tostring(row.plan))
        eq(false, row.previewed, 'and it still must be previewed before applying')
    else
        ok(tostring(loaded.refusal.rule) == 'replan-refused',
            'and the refusal is the PLANNER\'s, carried by name: '
            .. tostring(loaded.refusal.rule))
    end
    vim.fn.delete(path)
    vim.fn.delete(root, 'rf')
end)

test('agent: a recipe that re-derives differently ASKS FOR REVIEW, it does not refuse', function ()
    if not ready() then return end
    local root = mkfixture()
    ingest(root)
    local made = agent.answer(store, 'txn_plan_moveset',
        { seed = { idof('M.pub') }, dest = 'lib/new.lua' })
    ok(made.ok and made.subject.plan ~= nil, 'a plan was minted')
    -- ★ PREVIEW FIRST — that is what makes a review exist to be checked against.
    local prev = agent.answer(store, 'txn_preview', { plan = made.subject.plan })
    ok(prev.ok, 'and previewed: '
        .. tostring(type(prev.refusal) == 'table' and prev.refusal.reason))
    local saved = agent.answer(store, 'txn_save', { plan = made.subject.plan })
    local path = saved.result[1].path

    -- unchanged tree: the derivation matches what was reviewed
    local same = agent.answer(store, 'txn_load', { path = path })
    ok(same.ok, 'an unchanged tree loads: '
        .. tostring(type(same.refusal) == 'table' and same.refusal.reason))
    eq(true, same.result[1].reviewed_match,
        'and says the derived edit IS the reviewed one')

    -- now move the tree so the same asking yields different bytes
    local fd = assert(io.open(root .. '/m.lua', 'a'))
    fd:write('\nfunction M.added(q) return q end\n'); fd:close()
    ingest(root)
    local moved = agent.answer(store, 'txn_load', { path = path })
    -- ⚠ IT ASKS FOR REVIEW, IT DOES NOT REFUSE. The plan re-derived cleanly and is
    -- valid; what it is not is READ. Refusing would throw away a usable answer to
    -- enforce a gate `txn_apply` already applies — it will not take a plan that
    -- has not been previewed here.
    ok(moved.ok, 'the load SUCCEEDS — the derived plan is valid, just unreviewed')
    eq(false, moved.result[1].reviewed_match,
        'and says plainly that it is not the edit that was reviewed')
    local names = table.concat(moved.result[1].review_changed or {}, ',')
    ok(names:find('m.lua', 1, true), 'naming the files whose edit changed: ' .. names)
    local said = table.concat(moved.notes or {}, ' ')
    ok(said:find('NOT THE ONE THAT WAS REVIEWED', 1, true),
        'in a note a caller cannot miss: ' .. said:sub(1, 70))
    eq(false, moved.result[1].previewed,
        'and it is unpreviewed, which is what actually stops an apply')
    vim.fn.delete(path)
    vim.fn.delete(root, 'rf')
end)
