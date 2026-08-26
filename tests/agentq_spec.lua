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
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
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

-- REFUSED: the same-named nested helper, twice. `walk(...)` cannot be resolved to
-- one of them, so the call is REFUSED with a candidate list — and each `walk` then
-- reads as callerless while being perfectly alive. The measured false-positive
-- idiom the dead-confined rule's premise 3 exists for.
local REFUSED = [[
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
