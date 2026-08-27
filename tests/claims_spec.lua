-- CLAIMS: the fence over a CLAIM ABOUT THIS TREE'S OWN INVENTORY (CART-0595).
-- Two claims went stale in one session and neither could be caught: SKILL.md's
-- verb count against agent.ORDER, and portability.lua's header against the
-- profile artifacts. This spec's job is the one the ticket words as "demonstrate,
-- do not assume": it is not enough that both surfaces are correct TODAY — the
-- checker must FAIL when they stop being, so every oracle here is driven with a
-- deliberately broken input as well as the real one.
--
-- The synthetic tags below are why lua/cartograph/claims.lua's SCAN list excludes
-- tests/: a fixture claim that is meant to be false must not be evaluated as a
-- real claim about the tree.

local claims = require 'cartograph.claims'
local agent = require 'cartograph.agent'

local function skill_lines()
    local p = repo(claims.SKILL)
    ok(vim.fn.filereadable(p) == 1, claims.SKILL .. ' is tracked and must be readable')
    return vim.fn.readfile(p)
end

local function hits(list, needle)
    local n = 0
    for _, s in ipairs(list) do
        if s:find(needle, 1, true) then n = n + 1 end
    end
    return n
end

-- ── the agent surface ───────────────────────────────────────────────────────

test('claims: SKILL.md agrees with agent.ORDER at HEAD — and the check really ran', function ()
    local drifts, info = claims.agent_surface(agent.ORDER, skill_lines())
    eq({}, drifts)
    -- A clean result is worthless without evidence the parse SAW something: a
    -- renamed heading or a moved fence would otherwise read as agreement.
    ok(info.names ~= nil, 'the verb table was located')
    eq(#agent.ORDER, #info.names, 'the verb table lists one name per served verb')
    ok(#info.counts >= 2, 'both count claims (frontmatter and table lead-in) were found')
end)

test('claims: a verb added to ORDER without touching SKILL.md is CAUGHT', function ()
    local order = vim.deepcopy(agent.ORDER)
    order[#order + 1] = 'txn_rollback'
    local drifts = claims.agent_surface(order, skill_lines())
    ok(#drifts > 0, 'adding a verb must not read as a clean audit')
    eq(1, hits(drifts, 'verb table omits txn_rollback'))
    -- and the count claims go stale in the same edit, both of them
    eq(2, hits(drifts, ('claims %d verbs — agent.ORDER serves %d')
        :format(#agent.ORDER, #order)))
end)

test('claims: a verb the skill names but ORDER does not serve is CAUGHT', function ()
    local order = {}
    for _, v in ipairs(agent.ORDER) do
        if v ~= 'portability_move_calls' then order[#order + 1] = v end
    end
    local drifts = claims.agent_surface(order, skill_lines())
    eq(1, hits(drifts, 'verb table names portability_move_calls — agent.ORDER has no such verb'))
end)

test('claims: a check that CANNOT RUN is a finding, never silence', function ()
    -- the heading renamed: the verb table is unfindable
    local drifts = claims.agent_surface({ 'a_verb' }, { '# skill', 'a_verb is served' })
    eq(1, hits(drifts, 'no fenced verb table'))
    eq(1, hits(drifts, 'no "<N> verbs" claim found'))
    -- the fence markers still there, so only the count is missing
    local d2, info = claims.agent_surface({ 'a_verb' },
        { '## The verbs', '```', 'READ  a_verb', '```' })
    eq(1, hits(d2, 'no "<N> verbs" claim found'))
    eq({ 'a_verb' }, info.names)
end)

-- ── tagged claims ───────────────────────────────────────────────────────────

test('claims: a tag is parsed with its sentence and its check', function ()
    local t = claims.tags({
        '-- header prose',
        '-- @claim widget-count: the tree ships at least one widget',
        '--   check: 1 + 1 == 2',
        'local M = {}',
    }, 'x.lua')
    eq(1, #t)
    eq('widget-count', t[1].id)
    eq('the tree ships at least one widget', t[1].sentence)
    eq('1 + 1 == 2', t[1].expr)
    eq(2, t[1].line)
    ok(claims.verify(t[1]))
end)

test('claims: a tagged claim whose check goes FALSE is CAUGHT', function ()
    local t = claims.tags({ '-- @claim gone: a shipped pair still qualifies',
        '--   check: false' }, 'x.lua')
    local passed, why = claims.verify(t[1])
    eq(false, passed)
    ok(why:find('CHECK IS FALSE', 1, true), why)
end)

test('claims: the ways a check can fail are distinguished, because the fix differs', function ()
    -- a tag with no check advertises a fence it does not have
    local t = claims.tags({ '-- @claim bare: nothing checks this', 'local x = 1' }, 'x.lua')
    eq(nil, t[1].expr)
    local _, why = claims.verify(t[1])
    ok(why:find('no `check:` line', 1, true), why)
    -- a check that does not compile
    local _, w2 = claims.verify({ id = 'a', expr = 'if then', path = 'x.lua', line = 1 })
    ok(w2:find('does not compile', 1, true), w2)
    -- a check that blows up is NOT a passing check
    local _, w3 = claims.verify({ id = 'a', expr = 'error("boom")', path = 'x.lua', line = 1 })
    ok(w3:find('check errored', 1, true), w3)
end)

test('claims: a check runs in the ordinary environment, so it can call the mechanism', function ()
    ok(claims.verify({ id = 'a', path = 'x.lua', line = 1,
        expr = 'type(require("cartograph.portability").diffable_pair) == "function"' }))
end)

test('claims: a tag block ends at the first non-comment line', function ()
    local t = claims.tags({
        '-- @claim first: one',
        'local x = 1',
        '--   check: false',      -- belongs to no tag: the block already closed
    }, 'x.lua')
    eq(1, #t)
    eq(nil, t[1].expr)
end)

-- ── the mechanism's first real user ─────────────────────────────────────────

test('claims: portability.lua carries the qualifying-pair claim, and it holds', function ()
    local found
    for _, t in ipairs(claims.scan(repo())) do
        if t.id == 'qualifying-profile-pair' then found = t end
    end
    ok(found, 'the header claim CART-0595 was filed about is tagged')
    eq('lua/cartograph/portability.lua', found.path)
    local passed, why = claims.verify(found)
    ok(passed, tostring(why))
end)

test('claims: the tagged claim tracks the diff\'s OWN precondition, not a copy', function ()
    local port = require 'cartograph.portability'
    ok(port.diffable_pair('lua-factorio-11', 'lua-factorio'))
    -- and it refuses for the reasons reference_diff refuses for, which is what
    -- makes the tag a fence rather than a second opinion
    local okp, why = port.diffable_pair('ruby-core', 'lua-factorio')
    eq(false, okp)
    ok(why:find('different languages', 1, true), why)
    eq(false, (port.diffable_pair('lua-factorio', 'no-such-runtime')))
end)
