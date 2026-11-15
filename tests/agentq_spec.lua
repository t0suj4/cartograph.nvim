-- THE AGENT ENVELOPE (CART-0143) — tools/agentq.lua and the lint.alibi classifier
-- behind it. What these specs fence is ONE property, and it is the property the
-- whole envelope exists for:
--
--   ABSENT, REFUSED, FRONTIER AND UNAVAILABLE MUST RENDER DIFFERENTLY.
--
-- An agent that reads an empty alibi list has to know whether it may DELETE the
-- function. "nothing keeps this alive" licenses the edit; "a rule declined to pick
-- between candidates" and "nothing was looked at" forbid it. Before this envelope
-- all three were the same empty list, which is why 229 of this repo's 266 dead-code
-- findings are refusals wearing an absence's clothes.
--
-- Two layers, on purpose. The classifier is exercised IN PROCESS (pure, fast, and
-- it is where the taxonomy lives); the tool is exercised END TO END exactly once,
-- because "one JSON document on stdout and nothing else" is a property of the
-- process, not of a function, and cannot be asserted any other way.

local lint = require 'cartograph.lint'
local store = require 'cartograph.store'
local tier = require 'cartograph.tier'
local ts = require 'cartograph.providers.treesitter'

local function ready()
    return pcall(vim.treesitter.get_string_parser, '', 'lua')
end

--- extract a one-file root and return the alibi verdict for the fn named `name`
local function verdict(fname, src, name)
    local root = mkroot(fname, src)
    local data = ts.extract(root)
    data.root = root
    store.ingest(data)
    local ctx = lint.alibi(store)
    for _, n in ipairs(store.data.nodes) do
        if n.name == name and (n.kind == 'function' or n.kind == 'method') then
            local v = ctx(n)
            v.node, v.root = n, root
            return v
        end
    end
    vim.fn.delete(root, 'rf')
    error('no function named ' .. name .. ' in the fixture')
end

--- the absence value the envelope would report (agentq's own rule, in one place)
local function absence_of(v)
    if #v.alibis > 0 then return nil end
    if v.dead then return 'absent' end
    return v.blockers[1] and v.blockers[1].absence or 'UNCLASSIFIED'
end

-- ── the four fixtures, one per bucket ────────────────────────────────────────

-- ABSENT: a file-local nothing mentions. The only shape that licenses a deletion.
local ABSENT = [[
local M = {}
local function genuinely_dead(y) return y end
function M.pub(z) return z end
return M
]]

-- REFUSED: the same-named file-local helper, declared twice, AFTER the calls. Neither
-- declaration precedes `walk(...)`, so lexical scope cannot pick one (CART-1059) and each
-- call is REFUSED with a candidate list — and each `walk` then reads as callerless while
-- possibly alive. The measured false-positive idiom the dead-confined rule's premise 3
-- exists for. (It was two NESTED helpers until CART-1059: lexical scope now resolves
-- those, each to its own.)
local REFUSED = [[
local M = {}
function M.a() return walk({}) end
function M.b() return walk({}) end
local function walk(t) return t end
local function walk(t) return { t } end
return M
]]

-- FRONTIER: the name occurs a second time in a construct the extractor produced no
-- call record for. Nothing was looked at there, so nothing can be concluded.
local FRONTIER = [[
local M = {}
-- handler is wired up by the engine, not called from lua
local function handler(x) return x end
function M.go() return 1 end
return M
]]

-- UNAVAILABLE: a language that declares no visibility rule. "file-local" cannot be
-- read from the source at all, so no-callers is a statement about our coverage.
local UNAVAILABLE = [[
static int helper_unused(int x) { return x + 1; }
int main(void) { return 0; }
]]

test('alibi: the four absence values are pairwise distinct', function ()
    if not ready() then skip('no treesitter') end
    local got = {
        absent      = absence_of(verdict('m.lua', ABSENT, 'genuinely_dead')),
        refused     = absence_of(verdict('w.lua', REFUSED, 'walk')),
        frontier    = absence_of(verdict('f.lua', FRONTIER, 'handler')),
    }
    eq('absent', got.absent, 'a local nothing mentions is an ABSENCE — deleting it is safe')
    eq('refused', got.refused, 'a refused call could be this fn — a REFUSAL, not an absence')
    eq('frontier', got.frontier, 'an unmodelled mention means nothing was looked at — FRONTIER')
    -- the whole point: three empty results, three different answers
    local seen = {}
    for _, a in pairs(got) do
        ok(not seen[a], ('two buckets both report %q — they render the same, which is the defect'):format(a))
        seen[a] = true
    end
end)

test('alibi: a language with no visibility rule reports UNAVAILABLE, not absent', function ()
    if not ready() then skip('no treesitter') end
    local okc = pcall(vim.treesitter.get_string_parser, '', 'c')
    if not okc then skip('no c parser') end
    local v = verdict('u.c', UNAVAILABLE, 'helper_unused')
    eq('unavailable', absence_of(v), 'no spec.exported_def: our coverage, not the code')
    eq('visibility-undeclared', v.blockers[1].kind, 'the failed premise is NAMED')
    eq('spec.exported_def', v.blockers[1].evidence.capability,
        'and it names the missing CAPABILITY, so a caller knows what would fix it')
end)

test('alibi: a refusal is never masked by the generic occurrence premise', function ()
    if not ready() then skip('no treesitter') end
    -- REGRESSION, and it is not hypothetical: a refusal shadow means a call site
    -- SPELLED this name, so `name-occurs-again` is true whenever `refusal-shadow`
    -- is. Ordered by provably_dead's premise order the generic one wins every time
    -- and `refused` becomes unreportable. Measured on the fixture below before the
    -- reporting precedence was separated from the premise order.
    local v = verdict('w.lua', REFUSED, 'walk')
    eq('refusal-shadow', v.blockers[1].kind, 'the SPECIFIC premise decides')
    -- and it is a QUESTION, not a wall (CART-0576): the sites are named, so the
    -- caller can go and look instead of guessing what "candidates existed" meant
    local ev = v.blockers[1].evidence
    ok(#ev.sites >= 2, 'the refusal names WHERE the candidates were')
    for _, s in ipairs(ev.sites) do
        ok(type(s.line) == 'number' and s.line > 0, 'each site carries a line')
        ok(s.candidates and s.candidates > 1, 'and how many candidates the rule saw')
    end
    local rest = {}
    for i = 2, #v.blockers do rest[#rest + 1] = v.blockers[i].kind end
    ok(vim.tbl_contains(rest, 'name-occurs-again'),
        'and the masked premise is still reported, so discharging one shows the next')
end)

test('alibi: every blocker names its premise, its why and its evidence', function ()
    if not ready() then skip('no treesitter') end
    -- CART-0576's rule: a refusal aimed at an agent that does not say WHICH premise
    -- failed is a wall, not a question.
    for _, case in ipairs({ { 'w.lua', REFUSED, 'walk' }, { 'f.lua', FRONTIER, 'handler' } }) do
        local v = verdict(case[1], case[2], case[3])
        for _, b in ipairs(v.blockers) do
            ok(type(b.kind) == 'string' and #b.kind > 0, 'blocker names its premise')
            ok(type(b.why) == 'string' and #b.why > 20, 'blocker explains itself: ' .. b.kind)
            ok(b.absence ~= nil, 'blocker carries an absence value: ' .. b.kind)
        end
    end
end)

test('alibi: a live function returns witnesses, each with its own rung', function ()
    if not ready() then skip('no treesitter') end
    local v = verdict('m.lua', ABSENT, 'M.pub')
    ok(#v.alibis > 0, 'an exported function has an alibi')
    ok(not v.dead, 'and is not provably dead')
    for _, a in ipairs(v.alibis) do
        ok(tier.rank(a.tier) ~= nil,
            ('alibi %q carries a rung from tier.LADDER, never a minted one (got %q)')
                :format(a.kind, tostring(a.tier)))
    end
end)

test('alibi: the graph never reports absent where the authoritative lint would not', function ()
    if not ready() then skip('no treesitter') end
    -- provably_dead is the SOLE authority for `absent`. If this ever drifts, the
    -- envelope starts licensing deletions :CartographLint refuses.
    for _, case in ipairs({ { 'w.lua', REFUSED, 'walk' }, { 'f.lua', FRONTIER, 'handler' },
                            { 'm.lua', ABSENT, 'genuinely_dead' } }) do
        local v = verdict(case[1], case[2], case[3])
        if absence_of(v) == 'absent' then ok(v.dead, 'absent implies provably_dead') end
    end
end)

-- ── the tool: one JSON document, and the envelope's mutual exclusion ─────────

local function run(root, ...)
    local out = vim.fn.system(vim.iter({ vim.v.progpath, '--headless', '-u', 'NONE',
        '-l', repo('tools/agentq.lua'), root, ... }):flatten():totable())
    return out, vim.v.shell_error
end

test('agentq: one JSON document on stdout, and tier/absence are mutually exclusive', function ()
    if not ready() then skip('no treesitter') end
    local root = mkroot('m.lua', ABSENT)

    local live, rc = run(root, 'alibi', 'm.lua', '3')
    eq(0, rc, 'an answer exits 0')
    eq(1, select(2, live:gsub('\n', '\n')), 'exactly ONE line — nothing but the document')
    local okj, d = pcall(vim.json.decode, live)
    ok(okj, 'stdout parses as JSON: ' .. tostring(d))
    eq(true, d.ok)
    eq('alibi', d.verb)
    ok(#d.result > 0, 'the exported fn has an alibi')
    eq(vim.NIL, d.absence, 'a non-empty result carries NO absence')
    ok(tier.rank(d.tier) ~= nil, 'and carries a real rung, got ' .. tostring(d.tier))

    -- CART-0581: WHICH QUANTIFIER made that headline. This verb takes the PEAK
    -- (an alibi is existential — one strong witness decides); agent.lua's
    -- edges_callers takes the FLOOR over the same field name. Without this
    -- field the two are merely different; with it they are comparable.
    eq('peak', d.tier_headline,
        'a summary over rows is a quantifier choice, and the choice is part of the answer')

    -- TWO HANDLES, under their true names: the session id and the durable ref.
    ok(type(d.subject.id) == 'string' and #d.subject.id > 0, 'the subject carries its id')
    ok(type(d.subject.ref) == 'table' and type(d.subject.ref.name) == 'string',
        'and its durable ref — refs.lua shape, not the id again: ' .. vim.inspect(d.subject.ref))
    eq('m.lua', d.subject.ref.file)

    local dead = vim.json.decode((run(root, 'alibi', 'm.lua', '2')))
    eq(true, dead.ok, 'an absence is an ANSWER, not a failure')
    eq(0, #dead.result)
    eq('absent', dead.absence, 'an empty result is NEVER a bare [] — it carries its absence')
    eq(vim.NIL, dead.tier, 'and no rung, because nothing was resolved to rank')
    eq('peak', dead.tier_headline,
        'the quantifier is a property of the VERB, so it is stated even when there is no rung')
    ok(dead.absence_why and #dead.absence_why.why > 20, 'the absence explains WHICH premise')

    vim.fn.delete(root, 'rf')
end)

test('agentq: a REFUSAL is not an empty result and not an error', function ()
    if not ready() then skip('no treesitter') end
    local root = mkroot('m.lua', ABSENT)

    -- no function encloses line 1: the verb cannot answer at all. That is a
    -- different fact from "answered, and the answer is empty", and it must not
    -- arrive wearing the same shape.
    local out, rc = run(root, 'alibi', 'm.lua', '1')
    eq(3, rc, 'a refusal has its own exit code — stable, do not retry')
    local d = vim.json.decode(out)
    eq(false, d.ok)
    eq('no-subject', d.refusal.rule, 'the refusal names its RULE')
    eq('peak', d.tier_headline, 'and the document shape does not change under a refusal')
    ok(#d.refusal.remedy > 10, 'and a remedy, so an agent can fix the call')
    eq(vim.NIL, d.result, 'a refusal has no result at all — not an empty one')

    local bad, brc = run(root, 'nosuchverb', 'm.lua', '2')
    eq(2, brc, 'a protocol fault is neither an answer nor a refusal')
    eq('usage', vim.json.decode(bad).error.kind)

    vim.fn.delete(root, 'rf')
end)

-- ── THE SET WAS A SENTENCE, AND NOTHING CHECKED IT (CART-0831) ─────────────
-- agent.lua's header has declared `absence ∈ absent | refused | frontier |
-- unavailable` since CART-0581, and the invariant at the bottom of M.answer
-- enforced everything EXCEPT membership: a verb returning `absence = 'banana'`
-- passed straight through, and a fifth spelling renders as nothing at all to a
-- reader who knows the four. tier.ABSENCE is the table now.

test('agent: an undeclared absence kind is an envelope bug, not a new kind', function ()
    local agent = require 'cartograph.agent'
    local tiers = require 'cartograph.tier'
    -- the taxonomy is reachable from the one place tiers live...
    ok(tiers.is_absence('frontier'))
    ok(not tiers.is_absence('banana'))
    -- ...and the envelope's own classifier is what consumes it. Drive a verb
    -- that must come back empty on an empty store: whatever it names, the
    -- envelope may only carry a DECLARED kind.
    store.ingest({ schema = 1, root = '/x', nodes = {}, edges = {}, calls = {} })
    -- ★★ AND THE ENFORCEMENT IS EXERCISED, NOT MERELY ITS OUTCOME. A first cut
    -- of this spec drove a real verb and asserted the envelope named a declared
    -- kind — which it did whether or not the check existed, because no shipped
    -- verb returns a bad one. Deleting the check failed ZERO specs: a guard that
    -- never fires reads exactly like a passing test. So the bad kind is INJECTED
    -- through the open verb table, which is the only way to reach the branch.
    local BAD = 'banana'
    agent.VERBS.__spec_badabsence = {
        summary = 'test-only: names an undeclared absence kind',
        tier_basis = 'observation', absences = {}, args = {},
        run = function () return { result = {}, absence = BAD,
            absence_why = { premise = 'test', why = 'test', evidence = {} } } end,
    }
    local env = agent.answer(store, '__spec_badabsence', {})
    agent.VERBS.__spec_badabsence = nil
    ok(env and env.ok, 'an envelope bug must still produce an ENVELOPE, never a throw')
    ok(tiers.is_absence(env.absence),
        ('the envelope carried %q, which is not a declared kind'):format(tostring(env.absence)))
    ok(env.absence ~= BAD, 'the undeclared kind was coerced, not passed through')
    local bug = false
    for _, n in ipairs(env.notes or {}) do
        if n.kind == 'envelope-bug' and tostring(n.why):find(BAD, 1, true) then bug = true end
    end
    ok(bug, 'the coercion is DISCLOSED as an envelope bug naming the bad value')
    -- ★ AND THE OBSERVATION AXIS IS STAMPED. Every verb in agent.lua is static;
    -- nothing observed anything; `unprobed` was already true and merely unsaid.
    -- Additive — a caller written before this reads it unchanged.
    eq('unprobed', env.warrant)
    eq('nothing', tiers.licenses(env.warrant))
end)

-- (CART-0673: the occurrence premise read the DEFINING FILE only, and the absent verdict said "the name occurs only at its
-- own definition" — Style.getOptlckVersion occurred once in Style.java and in 246 other files. A definition another file
-- can name now checks the other files: the name there is a frontier; a file-local one is decided by its file, and the
-- wording says which scope it read)
test('agentq: a definition another file can name is not absent while another file mentions it; a file-local one is (CART-0673)', function ()
    if not ready() then skip 'no lua parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local function w(rel, t) local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(t); fd:close() end
    w('a.lua', 'local M = {}\nfunction M.helper() return 1 end\nfunction M.quiet() return 3 end\nlocal function lone() return 2 end\nreturn M\n')
    -- (b names `helper` without a resolvable call: a member of an untyped value — and `lone`, its own local of that
    -- name, which cannot be a's file-local lone)
    w('b.lua', 'local cfg = ...\nlocal x = cfg.helper\nlocal lone = 4\nreturn x, lone\n')
    local data = ts.extract(root); data.root = root
    store.ingest(data)
    local agent = require 'cartograph.agent'
    local function callers(name)
        for _, n in ipairs(store.data.nodes) do
            if n.name == name and n.file == 'a.lua' then return agent.answer(store, 'edges_callers', { node = n.id }), n end
        end
    end
    local h = callers('M.helper')
    eq('frontier', h.absence, 'helper: b.lua mentions it — ' .. vim.inspect(h.absence_why))
    eq('name-occurs-elsewhere', h.absence_why.premise)
    eq(1, h.absence_why.evidence.n_files)
    eq({ 'b.lua' }, h.absence_why.evidence.files)
    local q = callers('M.quiet')
    eq('absent', q.absence, 'quiet: no file but its own names it')
    ok(q.absence_why.why:find('in no other file', 1, true), 'and the clause says it read the other files: ' .. q.absence_why.why)
    local l, ln = callers('lone')
    -- (no mention index — the thin index: a definition another file can name cannot be cleared, a file-local one can)
    local hmi = store.has_mention_index
    store.has_mention_index = function () return false end
    local qt = callers('M.quiet')
    local lt = callers('lone')
    store.has_mention_index = hmi
    eq('unavailable', qt.absence, 'quiet without an index: unavailable, not absent')
    eq('mention-index-absent', qt.absence_why.premise)
    eq('absent', lt.absence, 'a file-local def needs no index')
    eq(false, ln.exported, 'the fixture\'s local function is file-local')
    eq('absent', l.absence, 'a file-local def is decided by its own file')
    ok(l.absence_why.why:find('file-local', 1, true), 'and says why the other files were not read')
    vim.fn.delete(root, 'rf')
end)

-- (CART-0683: a caller / callee row carries `prov` — WHICH resolver landed its edge — beside its tier. Two rows of the
-- same tier `inferred`, one landed by the base name lookup and one by the super chain, were indistinguishable: a
-- working analyzer and a bug looked the same in every edges_callers answer)
test('agentq: caller and callee rows carry prov — the resolver behind the edge, beside its tier (CART-0683)', function ()
    if not parser_available('java') then skip 'no java parser' end
    local root = vim.fn.tempname()
    local function w(rel, t)
        vim.fn.mkdir(vim.fs.dirname(root .. '/' .. rel), 'p')
        local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(t); fd:close()
    end
    local J = 'src/main/java/'
    w(J .. 'p/b/Base.java', 'package p.b;\npublic class Base { public void reg(int x) {} public void solo(int x) {} }\n')
    w(J .. 'p/q/Other.java', 'package p.q;\npublic class Other { public void reg(int x) {} }\n')
    w(J .. 'p/a/Sub.java', 'package p.a;\nimport p.b.Base;\npublic class Sub extends Base { void g() { reg(1); } void h() { solo(2); } }\n')
    local data = ts.extract(root); data.root = root
    store.ingest(data)
    vim.fn.delete(root, 'rf')
    local agent = require 'cartograph.agent'
    local id = {}
    for _, n in ipairs(store.data.nodes) do id[n.name] = n.id end
    local function row(verb, subj, other)
        for _, r in ipairs(agent.answer(store, verb, { node = id[subj] }).result) do if r.name == other then return r end end
    end
    local viasuper, viabase = row('edges_callers', 'Base::reg', 'Sub::g'), row('edges_callers', 'Base::solo', 'Sub::h')
    ok(viasuper and viabase, 'both caller rows')
    eq(viasuper.tier, viabase.tier, 'the same tier — which is why the tier alone could not tell them apart')
    eq({ 'super' }, viasuper.prov, 'reg: ambiguous by name (Other.reg), landed by the super chain')
    eq({ 'base' }, viabase.prov, 'solo: unique by name, landed by the base lookup')
    eq({ 'super' }, row('edges_callees', 'Sub::g', 'Base::reg').prov, 'and on the callee side')
    -- (a ref edge no call record lies behind — a function REFERENCE — says so, never an empty list)
    local root2 = vim.fn.tempname(); vim.fn.mkdir(root2, 'p')
    local fd = assert(io.open(root2 .. '/m.lua', 'w'))
    fd:write('local M = {}\nlocal function helper() return 1 end\nfunction M.user() local cb = helper; return cb end\nfunction M.caller() return helper() end\nreturn M\n')
    fd:close()
    local d2 = ts.extract(root2); d2.root = root2
    store.ingest(d2)
    vim.fn.delete(root2, 'rf')
    id = {}
    for _, n in ipairs(store.data.nodes) do id[n.name] = n.id end
    eq({ 'not-a-call' }, row('edges_callers', 'helper', 'M.user').prov, 'a reference, not a call')
    eq({ 'base' }, row('edges_callers', 'helper', 'M.caller').prov, 'the call beside it')
end)

-- CART-1979: a candidate is a verb answering the SAME question that THIS host and graph can serve. A full graph whose
-- languages opted out of the mention index refuses mentions and offers edges_callers — the alternative its remedy
-- names in prose — marked as needing a different handle (a node, not a name). On a thin graph it is unavailable too.
test('agent: refusal candidates are same-question verbs this host can serve, with their subject stated', function ()
    local agent = require 'cartograph.agent'
    local function stub(thin, mi)
        return { is_index_only = function () return thin end, data = { calls = (not thin) and {} or nil },
            has_mention_index = function () return mi end }
    end
    local full = agent.candidates(stub(false, false), 'mentions')
    eq(2, #full, vim.inspect(full))
    eq('edges_callers', full[1].name)
    eq('who-uses-it', full[1].question)
    eq(false, full[1].same_subject, 'mentions takes a name, edges_callers a node: stated, not filtered')
    eq('node', full[1].subject)
    -- (CART-1933: sites answers the same question from the CALL records — no mention index needed — and takes a NAME,
    -- the subject mentions was asked with)
    eq('sites', full[2].name)
    eq(true, full[2].same_subject, 'sites takes the same name')
    eq({}, agent.candidates(stub(true, false), 'mentions'), 'on a thin graph the sibling is unavailable too')
    -- language: a lua-only sibling is not offered for a ruby subject, and is for a lua one
    local rb, lua = {}, {}
    for _, c in ipairs(agent.candidates(stub(false, true), 'clones_find', 'ruby')) do rb[c.name] = true end
    for _, c in ipairs(agent.candidates(stub(false, true), 'clones_find', 'lua')) do lua[c.name] = true end
    eq(nil, rb.txn_plan_extract_family, 'extract_family serves lua/javascript, not ruby')
    ok(lua.txn_plan_extract_family, 'and is offered for a lua subject')
    eq(nil, lua.clones_find, 'an AVAILABLE verb asked directly is still never its own candidate')
end)

-- CART-0718 (design corpus agent-surface/07): a ref whose name node_find TAIL-matches (`solo` ~ `M.solo`) refused as
-- stale-ref/missing with a remedy saying the definition was "gone or moved" — false, and the graph could see it.
test('agent: an underqualified ref resolves by node_find\'s tail rule, refuses as AMBIGUOUS, and claims "gone" only after checking', function ()
    local agent = require 'cartograph.agent'
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local function w(name, src) local fd = assert(io.open(root .. '/' .. name, 'w')); fd:write(src); fd:close() end
    w('m.lua', 'local M = {}\nlocal T = {}\nfunction M.solo(x) return x end\nfunction M.dup(x) return x end\nfunction T.dup(x) return x end\nfunction M.user() return M.solo(1) end\nreturn M\n')
    w('o.lua', 'local O = {}\nfunction O.other() return 1 end\nreturn O\n')
    store.ingest(ts.extract(root))
    local found = agent.answer(store, 'node_find', { query = 'solo' }).result[1]
    eq('tail', found.match, 'node_find tail-matches the bare name (unchanged)')
    local kind = found.ref.kind
    -- one tail match in the file: RESOLVED, and the answer says how
    local d = agent.answer(store, 'edges_callers', { ref = { file = 'm.lua', kind = kind, name = 'solo' } })
    eq(true, d.ok, 'an underqualified ref is not a missing definition: ' .. vim.inspect(d.refusal))
    ok(#d.result >= 1 and d.result[1].name == 'M.user', 'and the caller the graph knows is answered')
    local note
    for _, n in ipairs(d.notes or {}) do if n.kind == 'ref-tail-match' then note = n end end
    ok(note, 'the tail resolution is DISCLOSED, never silent')
    eq('M.solo', note.evidence.name); eq('M.solo', note.evidence.qualified_ref.name)
    -- several tail matches: AMBIGUOUS, with the candidates' refs — never "missing"
    local a = agent.answer(store, 'edges_callers', { ref = { file = 'm.lua', kind = kind, name = 'dup' } })
    eq('stale-ref', a.refusal.rule)
    ok(a.refusal.why:find('^ambiguous%-tail'), a.refusal.why)
    ok(not a.refusal.remedy:find('gone from that file', 1, true) and a.refusal.remedy:find('UNDERQUALIFIED', 1, true),
        'the remedy names the cause, not the old "gone or moved" claim: ' .. a.refusal.remedy)
    local names = {}
    for _, c in ipairs(a.refusal.candidates) do if c.kind == 'argument' then names[#names + 1] = c.value.name end end
    table.sort(names)
    eq({ 'M.dup', 'T.dup' }, names, 'each candidate is a qualified ref')
    -- not in that file, but elsewhere: the remedy names where, as data
    local e = agent.answer(store, 'edges_callers', { ref = { file = 'o.lua', kind = kind, name = 'solo' } })
    eq('missing', e.refusal.why)
    ok(e.refusal.remedy:find('another file', 1, true), e.refusal.remedy)
    eq('M.solo', e.refusal.candidates[1].value.name)
    -- nowhere at all: only now is "deleted or renamed" said, and it says the graph was searched
    local g = agent.answer(store, 'edges_callers', { ref = { file = 'm.lua', kind = kind, name = 'nowhere' } })
    eq('missing', g.refusal.why)
    ok(g.refusal.remedy:find('anywhere in this graph', 1, true), g.refusal.remedy)
    -- the WRITE side still refuses a caveated ref, now handing over the qualified one
    local wr = agent.answer(store, 'txn_plan_annotate', { ref = { file = 'm.lua', kind = kind, name = 'solo' }, text = 'x' })
    eq('ref-caveat', wr.refusal.rule)
    eq('M.solo', wr.refusal.candidates[1].value.name)
    vim.fn.delete(root, 'rf')
end)

-- CART-1936 (the BNW 2.1 port bot): node_find{name = …} was invalid params — its argument is `query`, while mentions /
-- why spell the same subject `name`, and an agent guesses from the sibling verb. An argument now DECLARES its aliases:
-- node_find's `query` takes `name`, mentions' `name` takes `query`. The alias answers as the argument does; both
-- spellings with different values are a usage error; the schema publishes the alias, graph_info lists it.
test('agent: node_find takes `name` as an alias of `query`, mentions `query` as an alias of `name` — declared, published (CART-1936)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local agent = require 'cartograph.agent'
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/m.lua', 'w')); fd:write('local M = {}\nfunction M.solo() return 1 end\nreturn M\n'); fd:close()
    store.ingest(ts.extract(root))
    vim.fn.delete(root, 'rf')
    local q = agent.answer(store, 'node_find', { query = 'solo' })
    local n, status = agent.answer(store, 'node_find', { name = 'solo' })
    eq('ok', status, vim.inspect(n.error))
    eq(vim.inspect(q.result), vim.inspect(n.result), 'the alias answers as the argument does')
    local args = { name = 'solo' }
    agent.answer(store, 'node_find', args)
    eq({ name = 'solo' }, args, 'the caller\'s table is not rewritten')
    local m1 = agent.answer(store, 'mentions', { name = 'solo' })
    local m2, s2 = agent.answer(store, 'mentions', { query = 'solo' })
    eq('ok', s2, vim.inspect(m2.error))
    eq(vim.inspect(m1.result), vim.inspect(m2.result), 'mentions takes node_find\'s spelling too')
    local b, bs = agent.answer(store, 'node_find', { query = 'solo', name = 'other' })
    eq('usage', bs); ok(b.error.reason:find('alias of `query`', 1, true), b.error.reason)
    local same, ss = agent.answer(store, 'node_find', { query = 'solo', name = 'solo' })
    eq('ok', ss, 'both spellings with ONE value are fine: ' .. vim.inspect(same.error))
    -- published: the schema has the alias as its own property, graph_info lists it
    local sch = agent.schema('node_find')
    ok(sch.properties.name and sch.properties.name.description:find('alias of `query`', 1, true), vim.inspect(sch.properties.name))
    eq({ 'query' }, sch.required, 'the alias is never required')
    local gi = agent.answer(store, 'graph_info', {})
    local row
    for _, r in ipairs(gi.result) do if r.verb == 'node_find' then row = r end end
    eq({ 'name -> query' }, row and row.aliases)
end)

-- CART-0684: `why` with no `col` defaulted to column 1, landed on the ENCLOSING DEFINITION and answered kind 'def' —
-- which read as "this verb cannot see calls" and produced two wrong findings. No col = every call on the line, in
-- column order, each carrying its col; the definition rides BESIDE them, and a call-free line says so.
test('why: no col answers EVERY call on the line in column order, the def beside them, never instead (CART-0684)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local L4 = 'function M.f() return b(a()) end'
    local src = table.concat({ 'local M = {}', 'local function a() return 1 end', 'local function b(x) return x end',
        L4, 'function M.h()', '  local x = 1', '  return x', 'end', 'return M' }, '\n') .. '\n'
    local fd = assert(io.open(root .. '/m.lua', 'w')); fd:write(src); fd:close()
    local data = ts.extract(root); data.root = root
    store.ingest(data)
    -- (the fixture stays on disk until the end: since agent protocol 2 a column is converted to CHARACTERS through
    -- the line's text, CART-2086)
    local agent = require 'cartograph.agent'
    local d = agent.answer(store, 'why', { file = 'm.lua', line = 4 })
    local shape = {}
    for _, r in ipairs(d.result) do
        shape[#shape + 1] = r.kind == 'call' and (r.callee .. '@' .. r.col .. ':' .. r.status) or ('def ' .. r.name)
    end
    eq({ 'b@' .. L4:find('b%(') .. ':resolved', 'a@' .. L4:find('a%(') .. ':resolved', 'def M.f' }, shape)
    ok(d.tier ~= nil and d.tier ~= vim.NIL, 'the headline is the floor over the calls\' rungs')
    local kinds = {}
    for _, n in ipairs(d.notes or {}) do kinds[n.kind] = true end
    ok(kinds['line-mode'], 'a note says no col was given and what was answered instead')
    -- an explicit col keeps its position answer: col 1 is the definition
    local p = agent.answer(store, 'why', { file = 'm.lua', line = 4, col = 1 })
    eq(1, #p.result); eq('def', p.result[1].kind)
    -- a line with no call record: the def row, and a note that it is context, not an absence of calls
    local e = agent.answer(store, 'why', { file = 'm.lua', line = 6 })
    eq(1, #e.result); eq('def', e.result[1].kind); eq('M.h', e.result[1].name)
    local nc = false
    for _, n in ipairs(e.notes or {}) do if n.kind == 'no-call-on-line' then nc = true end end
    ok(nc, 'a call-free line says no call record starts there')
    -- the audit's other substituting default: cone's omitted direction is SAID (out vs in are opposite answers)
    local fid
    for _, n in ipairs(store.data.nodes) do if n.name == 'M.f' then fid = n.id end end
    local function has(dd, k) for _, n in ipairs(dd.notes or {}) do if n.kind == k then return true end end end
    ok(has(agent.answer(store, 'cone', { node = fid }), 'defaulted-direction'), 'an omitted direction is named')
    ok(not has(agent.answer(store, 'cone', { node = fid, direction = 'out' }), 'defaulted-direction'), 'a given one is not')
    vim.fn.delete(root, 'rf')
end)

-- CART-1008: the mention index skips a 1-2 character name (its documented rule) and a MEMBER / PROPERTY key
-- (`jQuery.getJSON = function`), so a defined name could come back as a confident "0 files mention this". A name is
-- written where it is defined: a definition whose file the index does not list means the INDEX skipped it.
test('mentions: a DEFINED name the index skipped is a frontier naming the definition, never "absent" (CART-1008)', function ()
    if not (parser_available('lua') and parser_available('javascript')) then skip 'no lua/javascript parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local function w(rel, t) local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(t); fd:close() end
    -- (an OBJECT-LITERAL key is the shape still skipped; `jQuery.getJSON = function` is indexed since the ticket was filed)
    w('a.js', 'var hooks = { getScript: function (u) { return u; }, setProp: function (v) { return v; } };\n')
    w('c.js', 'var setProp = 1;\nconsole.log(setProp);\n')
    w('m.lua', 'local M = {}\nfunction M.ab() return 1 end\nfunction M.solo() return 2 end\nreturn M\n')
    local data = ts.extract(root); data.root = root
    store.ingest(data)
    vim.fn.delete(root, 'rf')
    local agent = require 'cartograph.agent'
    -- a member-defined name no other file writes: the index skipped it
    local g = agent.answer(store, 'mentions', { name = 'getScript' })
    eq('frontier', g.absence, vim.inspect(g.absence_why))
    eq('name-not-indexed', g.absence_why.premise)
    eq('getScript', g.absence_why.evidence.defs[1].name)
    ok(g.absence_why.why:find('member / property key', 1, true), g.absence_why.why)
    -- a 2-character name: the documented length rule, said as such
    local s = agent.answer(store, 'mentions', { name = 'ab' })
    eq('frontier', s.absence); ok(s.absence_why.why:find('3+ characters', 1, true), s.absence_why.why)
    -- indexed elsewhere, skipped in its defining file: the list stands, a note says it is not every writer
    local t = agent.answer(store, 'mentions', { name = 'setProp' })
    eq(1, #t.result); eq('c.js', t.result[1].file)
    local note
    for _, n in ipairs(t.notes or {}) do if n.kind == 'defining-file-not-indexed' then note = n end end
    ok(note and note.evidence.defs[1].file == 'a.js', 'the skipped defining file is named: ' .. vim.inspect(t.notes))
    -- a name defined nowhere and mentioned nowhere is still absent
    eq('absent', agent.answer(store, 'mentions', { name = 'nowhere_at_all' }).absence)
end)

-- CART-1607: an extension nothing claims fell through the walk with no counter — apollo-11's 175 `.agc` files gave
-- graph_info `files 0, unparsed 0`, silence over a non-empty tree. The walk counts them and the frontier says so.
test('graph_info: files no spec claims are COUNTED by extension in the frontier, never silently dropped (CART-1607)', function ()
    local function root_with(files)
        local root = vim.fn.tempname(); vim.fn.mkdir(root .. '/sub', 'p')
        for rel, t in pairs(files) do local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(t); fd:close() end
        return root
    end
    local agent = require 'cartograph.agent'
    -- a tree of an unsupported language only: zero files parsed, and the frontier names what was there
    local r1 = root_with({ ['a.agc'] = 'TC 1\n', ['b.agc'] = 'TC 2\n', ['sub/c.agc'] = 'TC 3\n', ['NOTES'] = 'x\n' })
    local d1 = ts.extract(r1); d1.root = r1
    store.ingest(d1)
    local g = agent.answer(store, 'graph_info', {}).graph
    eq(0, g.counts.files)
    eq(4, g.frontier.unclaimed_files)
    eq({ { ext = 'agc', files = 3 }, { ext = '', files = 1 } }, g.frontier.unclaimed)
    vim.fn.delete(r1, 'rf')
    -- a claimed file is not counted; another root re-walks (the memo is per root)
    if parser_available('lua') then
        local r2 = root_with({ ['m.lua'] = 'local M = {}\nreturn M\n', ['README.md'] = '# x\n' })
        local d2 = ts.extract(r2); d2.root = r2
        store.ingest(d2)
        local g2 = agent.answer(store, 'graph_info', {}).graph
        eq(1, g2.counts.files)
        eq({ { ext = 'md', files = 1 } }, g2.frontier.unclaimed)
        vim.fn.delete(r2, 'rf')
    end
end)

-- CART-2086 (the USER's decision 2026-11-15): the agent's column is a 1-based CHARACTER column since protocol 2 — it
-- was a 1-based BYTE column, misread by any agent counting characters on a non-ASCII line. The break is VISIBLE: every
-- answer's graph carries protocol + positions.
test('why: columns are 1-based CHARACTERS (protocol 2), converted through the line, and every answer says so (CART-2086)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local L2 = 'function M.g() local s = "é"; return b(s) end' -- `é` is 2 bytes: b's byte column is one past its char column
    local src = table.concat({ 'local M = {}', L2, 'local function b(x) return x end', 'return M' }, '\n') .. '\n'
    local fd = assert(io.open(root .. '/m.lua', 'w')); fd:write(src); fd:close()
    local data = ts.extract(root); data.root = root
    store.ingest(data)
    local agent = require 'cartograph.agent'
    local bbyte = L2:find('b%(')                            -- 1-based BYTE column of `b(`
    local bchar = vim.fn.strchars(L2:sub(1, bbyte - 1)) + 1 -- its 1-based CHARACTER column
    ok(bchar == bbyte - 1, 'the fixture really differs by one: ' .. bchar .. ' vs ' .. bbyte)
    local d = agent.answer(store, 'why', { file = 'm.lua', line = 2 })
    eq(4, d.graph.protocol, 'the envelope names the protocol')
    eq({ line = 1, col = 1, unit = 'char' }, d.graph.positions, 'and the position contract')
    local brow
    for _, r in ipairs(d.result) do if r.callee == 'b' then brow = r end end
    ok(brow, 'the call to b is a row')
    eq(bchar, brow.col, 'the row\'s col is the CHARACTER column')
    local p = agent.answer(store, 'why', { file = 'm.lua', line = 2, col = bchar })
    eq('call', p.result[1].kind, 'the character column addresses the call')
    eq('b', p.result[1].callee)
    local bad, st = agent.answer(store, 'why', { file = 'm.lua', line = 2, col = 999 })
    eq('usage', st, 'a column past the line is a loud usage error, never clamped')
    ok(tostring(bad.error.reason):find('CHARACTER', 1, true), bad.error.reason)
    vim.fn.delete(root, 'rf')
end)
