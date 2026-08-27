-- THE VERSION AXIS ON THE AGENT SURFACE (CART-0595) — portability_targets /
-- portability_move / portability_move_calls in lua/cartograph/agent.lua, served
-- by tools/mcpserve.lua.
--
-- WHAT THESE SPECS FENCE, and none of it is "the diff works" (tests/portability_spec
-- owns that):
--
--   1 THE TWO SURFACES ANSWER DIFFERENTLY ON ONE CORPUS, AND THE WEAK ONE SAYS SO.
--     The same fixture, the same profile pair: the READ diff returns a worklist and
--     the CALL diff returns `absent`. That contrast is the whole reason the version
--     axis was invisible for a session — a caller who reaches for the call surface
--     on a version move gets a serene 0 and concludes there is nothing to port. Both
--     halves are asserted in ONE test so neither can be "fixed" alone.
--   2 FOUR OUTCOMES, FOUR RENDERINGS. lost=0 (`absent`, a real answer), no function
--     examined (`frontier`, no answer at all), no such profile (`unavailable`, an
--     instrument gap) and two profiles that cannot be compared (a REFUSAL carrying
--     portability's own sentence VERBATIM). A lesser envelope renders all four as an
--     empty list, and that flattening is what this surface exists to prevent.
--   3 EVERY DECLARED ABSENCE IS EMITTED BY A BRANCH (CART-0580). The `absences`
--     list is a contract an agent reads; a value nothing can produce is the defect
--     that ticket names, so each one is provoked here.
--   4 THE CAPABILITY SPLIT IS REAL AND MEASURED. portability_move declares no
--     `needs_calls` because externals.references re-parses each function on demand,
--     so it ANSWERS on a thin index while portability_move_calls refuses there.
--     Asserted over the wire against an --index-only server, because "this verb
--     refuses on a thin index for no reason" is exactly the bug the ticket warned
--     about and only a live thin host can rule it out.
--
-- TWO LAYERS, the split mcpserve_spec established: the verb table IN PROCESS (fast,
-- and where the envelope invariant lives), the host END TO END (because "a client
-- reads the refusal as CONTENT, not as a transport error" is a property of the
-- process). Every byte written goes to a temp dir this file created.

local agent = require 'cartograph.agent'
local mcp = require 'cartograph.mcp'
local store = require 'cartograph.store'
local ts = require 'cartograph.providers.treesitter'

local function ready()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    return pcall(vim.treesitter.language.add, 'lua')
end

-- ── the fixture ─────────────────────────────────────────────────────────────
-- A Factorio 1.1 mod in miniature. EVERY read is INSIDE A FUNCTION BODY on
-- purpose: externals.references walks function/method nodes through expr.of, so
-- a module-level `global.x = 5` is invisible to it and would fence nothing.
--
--   global.*                 the 1.1 persisted table, renamed to `storage` in 2.0
--   game.entity_prototypes   an attribute of a FULLY ENUMERATED class, present in
--   game.active_mods         1.1 and genuinely gone in 2.0
--   game.tick                present in BOTH — the `kept` name, so an empty
--                            worklist in the reverse direction is a measured 0 and
--                            not an artefact of scoring nothing
local MOD_LUA = {
    'local M = {}',
    'function M.tick_bots()',
    '    local n = global.savedRailbots',
    '    if global.cage_sound then n = n + 1 end',
    '    return n',
    'end',
    'function M.protos()',
    '    return game.entity_prototypes, game.active_mods',
    'end',
    'function M.stable()',
    '    return game.tick',
    'end',
    -- ONE EXTERNAL CALL, so the CALL surface has a real population to score and
    -- its `0 lost` is a measured zero rather than an empty denominator. That is
    -- the sharp form of the contrast: the requirement set scores a name, keeps
    -- it, and STILL cannot see the four names the read surface lost.
    'function M.say()',
    '    game.print("hi")',
    'end',
    'return M',
}

-- an opaque frontier, by NAME rather than by content: *.min.js is never parsed,
-- so it lands as an unparsed module node in any tree. Here it makes the
-- `not-everything-was-read` note fire on a corpus that also has real functions,
-- and ALONE (below) it is a corpus with no read surface at all.
local BUNDLE_JS = { 'var a=1;' }

local function mkfixture()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    write(root, 'mod.lua', MOD_LUA)
    write(root, 'bundle.min.js', BUNDLE_JS)
    return root
end

--- a root holding NOTHING BUT an unparsed bundle: no function is examined, so the
--- read surface has no population and an empty worklist is NO ANSWER.
local function mkbundleonly()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    write(root, 'bundle.min.js', BUNDLE_JS)
    return root
end

local function ingest(root)
    local data = ts.extract(root)
    data.root = data.root or root
    store.ingest(data)
    return store
end

local FROM, TO = 'lua-factorio-11', 'lua-factorio'

-- ── layer 1: the verb table, in process ─────────────────────────────────────

test('agentport: the catalogue publishes the version axis, and its CAPABILITY split', function ()
    if not ready() then skip('no treesitter') end
    local root = mkfixture()
    ingest(root)
    local info = agent.answer(store, 'graph_info', {})
    local by = {}
    for _, r in ipairs(info.result) do by[r.verb] = r end
    for _, v in ipairs({ 'portability_targets', 'portability_move', 'portability_move_calls' }) do
        ok(by[v], 'the catalogue lists ' .. v)
        eq('observation', by[v].tier_basis,
            v .. ': a diff row is not a name resolution, so no rung on tier.LADDER applies')
        eq(vim.NIL, by[v].tier_headline,
            v .. ' reports no tier, so a headline quantifier would be meaningless (CART-0581)')
        eq(false, by[v].mutates, v .. ' writes nothing')
    end
    -- THE SPLIT, published BEFORE the agent asks. references() re-parses each
    -- function on demand, so the READ diff needs no call graph; requires() reads
    -- call records, so the CALL diff does.
    eq(false, by.portability_move.needs_calls,
        'portability_move must NOT declare needs_calls — the read surface is built by re-parsing, and declaring it would refuse a perfectly answerable question on a thin index')
    eq(true, by.portability_move_calls.needs_calls,
        'portability_move_calls scores the CALL-derived requirement set and genuinely cannot answer without one')
    eq(false, by.portability_targets.needs_calls, 'the roster is a fact about the artifacts, not about the graph')
    vim.fn.delete(root, 'rf')
end)

test('agentport: EVERY declared absence is emitted by a branch (CART-0580)', function ()
    if not ready() then skip('no treesitter') end
    local root, bundle = mkfixture(), mkbundleonly()
    local seen = {}

    ingest(root)
    -- `absent` — the reverse direction: 1.1's names are all still 2.0's, so the
    -- move loses nothing. A REAL ANSWER, and it must not read like a failure.
    local rev = agent.answer(store, 'portability_move', { from = TO, to = FROM })
    eq(true, rev.ok, 'an absence is an ANSWER: ' .. vim.inspect(rev.absence_why))
    eq(0, #rev.result)
    eq('absent', rev.absence)
    eq('no-name-lost', rev.absence_why.premise)
    seen[rev.absence] = true

    -- `unavailable` — no such artifact ships. An INSTRUMENT gap, and the roster
    -- rides in the evidence so the caller can fix the call without guessing.
    local un = agent.answer(store, 'portability_move', { from = FROM, to = 'nosuchprofile' })
    eq(true, un.ok)
    eq(0, #un.result)
    eq('unavailable', un.absence)
    eq('no-such-profile', un.absence_why.premise)
    eq({ 'nosuchprofile' }, un.absence_why.evidence.missing)
    ok(#un.absence_why.evidence.shipped > 3,
        'the shipped roster travels WITH the absence, so an agent never guesses a profile name')
    seen[un.absence] = true

    -- `frontier` — a corpus with no function to examine. The worklist is empty
    -- for want of a population, which is NOT "the move is clean".
    ingest(bundle)
    local fr = agent.answer(store, 'portability_move', { from = FROM, to = TO })
    eq(true, fr.ok)
    eq(0, #fr.result)
    eq('frontier', fr.absence)
    eq('no-function-examined', fr.absence_why.premise)
    eq(0, fr.absence_why.evidence.analysed)
    seen[fr.absence] = true

    -- THE CALL VERB SHARES THE PAIR-RESOLUTION BRANCH, and a shared branch is
    -- not a driven one: it declares `unavailable` too, so it is provoked here
    -- rather than inferred from its sibling.
    ingest(root)
    local unc = agent.answer(store, 'portability_move_calls', { from = FROM, to = 'nosuchprofile' })
    eq(true, unc.ok)
    eq(0, #unc.result)
    eq('unavailable', unc.absence)
    eq('no-such-profile', unc.absence_why.premise)
    for _, a in ipairs(agent.VERBS.portability_move_calls.absences) do
        ok(a == 'unavailable' or a == 'absent',
            'portability_move_calls declares an absence this test does not account for: ' .. a)
    end

    -- and the DECLARATION matches what the branches can produce, in both
    -- directions: nothing declared is unreachable, nothing emitted is undeclared.
    for _, a in ipairs(agent.VERBS.portability_move.absences) do
        ok(seen[a], ('portability_move declares absence %q and no branch above emitted it — a declared-but-unreachable value is CART-0580 verbatim'):format(a))
    end
    for a in pairs(seen) do
        ok(vim.tbl_contains(agent.VERBS.portability_move.absences, a),
            ('a branch emitted %q, which the verb does not declare'):format(a))
    end
    vim.fn.delete(root, 'rf'); vim.fn.delete(bundle, 'rf')
end)

test('agentport: a profile diffed with ITSELF is refused, not answered "absent"', function ()
    if not ready() then skip('no treesitter') end
    local root = mkfixture()
    ingest(root)
    local d = agent.answer(store, 'portability_move', { from = TO, to = TO })
    eq(false, d.ok, 'zero BY CONSTRUCTION must not wear the clothes of zero by measurement')
    eq('same-profile', d.refusal.rule)
    eq(vim.NIL, d.absence, 'and it is not an absence at all: nothing about the code was concluded')
    ok(#d.refusal.remedy > 10, 'with a remedy naming the roster verb')
    vim.fn.delete(root, 'rf')
end)

test('agentport: the call surface refuses on a thin index and the read surface does NOT', function ()
    if not ready() then skip('no treesitter') end
    local root = mkfixture()
    local data = ts.index_only(root)
    data.root = data.root or root
    store.ingest(data)
    eq(true, store.is_index_only(), 'the fixture opened thin')

    local reads = agent.answer(store, 'portability_move', { from = FROM, to = TO })
    eq(true, reads.ok, 'the READ diff re-parses functions on demand, so a thin index is no obstacle')
    ok(#reads.result > 0, 'and it still finds the renamed names: ' .. vim.inspect(reads.absence_why))

    local calls = agent.answer(store, 'portability_move_calls', { from = FROM, to = TO })
    eq(false, calls.ok)
    eq('thin-index', calls.refusal.rule,
        'the CALL diff reads call records and must refuse rather than report a 0 that is a property of the INDEX')
    vim.fn.delete(root, 'rf')
end)

-- ── layer 2: the server, over stdio ─────────────────────────────────────────

local SERVERS = {}

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

test('mcpserve: portability_targets is the from/to VOCABULARY, refusals included', function ()
    if not ready() then skip('no treesitter') end
    local c = client(false)
    local d = c:call('portability_targets', vim.empty_dict())
    eq(true, d.ok)
    ok(#d.result > 5, 'the whole roster arrives: ' .. tostring(#d.result))
    local by = {}
    for _, r in ipairs(d.result) do by[r.runtime] = r end
    for _, rt in ipairs({ FROM, TO }) do
        ok(by[rt], 'the pair this tool can actually demonstrate is listed: ' .. rt)
        eq(true, by[rt].names, rt .. ' can adjudicate a NAME question')
        eq('lua', by[rt].lang)
    end
    -- AND THE ONES THAT CAN BE NO TARGET ARE STILL LISTED, WITH THE MECHANISM.
    -- Dropping them would render five artifacts as silence, and a caller could
    -- not tell "no profile covers this" from "five were quietly skipped".
    local blocked = 0
    for _, r in ipairs(d.result) do
        if not r.names and not r.data then
            blocked = blocked + 1
            ok(type(r.reason) == 'string' and #r.reason > 20,
                r.runtime .. ' is on no target list and must say WHY: ' .. vim.inspect(r.reason))
        end
    end
    ok(blocked > 0, 'at least one shipped artifact is an ingredient rather than a target')
end)

test('mcpserve: THE VERSION MOVE — the READ surface answers and the CALL surface does not', function ()
    if not ready() then skip('no treesitter') end
    local c = client(false)

    -- the strong question: a worklist, one row per name the move removes
    local reads = c:call('portability_move', { from = FROM, to = TO })
    eq(true, reads.ok, 'portability_move: ' .. vim.inspect(reads))
    eq(vim.NIL, reads.absence, 'a non-empty result carries no absence')
    eq(vim.NIL, reads.tier, 'and no rung: a diff row is not a name resolution')
    local lost = {}
    for _, r in ipairs(reads.result) do
        lost[r.name] = r
        ok(r.reads >= 1, r.name .. ' carries how many reads it has')
        ok(type(r.was) == 'string' and #r.was > 0,
            r.name .. ' says what the OLD environment answered with — a status CHANGE, not an artifact gap')
        ok(type(r.files) == 'table' and #r.files >= 1, r.name .. ' carries the file(s) it is read in')
    end
    ok(lost['global.savedRailbots'], 'the `global` -> `storage` rename is the headline: ' .. vim.inspect(vim.tbl_keys(lost)))
    ok(lost['global.cage_sound'], 'one row per renamed name, not one row for the rename')
    ok(lost['game.entity_prototypes'], 'and the enumerated-class attributes 2.0 removed')
    eq('reads', reads.subject.surface)
    eq(#reads.result, reads.subject.lost)

    -- THE SAME MOVE, THE SAME CORPUS, THE WEAK QUESTION. Every name above is
    -- READ and never CALLED, so no call record exists and the requirement set
    -- has nothing to lose. A caller who reaches for this verb on a version move
    -- concludes THERE IS NOTHING TO PORT.
    local calls = c:call('portability_move_calls', { from = FROM, to = TO })
    eq(true, calls.ok, 'the call surface answers — it is not wrong, it is the wrong question')
    eq(0, #calls.result)
    eq('absent', calls.absence)
    eq('no-called-name-lost', calls.absence_why.premise)
    ok(calls.absence_why.evidence.requirement_names > 0,
        'and the zero is MEASURED, not an empty denominator: the requirement set had names to score')
    ok(calls.absence_why.why:find('read, never called', 1, true),
        'and the absence itself points at the other surface: ' .. calls.absence_why.why)
    ok(#reads.result > 0 and #calls.result == 0,
        'THE CONTRAST: the read surface reports a worklist where the call surface reports nothing')
end)

test('mcpserve: lost=0 is a REAL ANSWER and renders as `absent`, with the gained names beside it', function ()
    if not ready() then skip('no treesitter') end
    local c = client(false)
    local d = c:call('portability_move', { from = TO, to = FROM })
    eq(true, d.ok, 'an absence is an answer, not a failure')
    eq(0, #d.result)
    eq('absent', d.absence, 'nothing this code reads was removed going this way')
    eq('no-name-lost', d.absence_why.premise)
    ok(d.absence_why.why:find('real answer', 1, true), d.absence_why.why)
    ok(d.absence_why.evidence.scored > 0,
        'and it says HOW MANY names were scored — an empty worklist over an empty population is a different claim')
    -- GAINED IS NOT LOST AND IT IS NOT SILENCE: it rides as a note, because the
    -- RESULT of this verb is the port worklist and mixing the two would mean an
    -- empty worklist could never be reported as one.
    local gained
    for _, n in ipairs(d.notes) do if n.kind == 'gained' then gained = n end end
    ok(gained, 'the names the new environment ADDS are reported: ' .. vim.inspect(d.notes))
    ok(gained.evidence.gained > 0 and #gained.evidence.names > 0, vim.inspect(gained.evidence))
end)

test('mcpserve: portability REFUSES with its own sentence, verbatim, and it is not an absence', function ()
    if not ready() then skip('no treesitter') end
    local c = client(false)

    -- (a) different languages
    local lang, why, raw = c:call('portability_move', { from = FROM, to = 'ruby-rails' })
    ok(lang ~= nil, 'a refusal must arrive as CONTENT: ' .. tostring(why))
    eq(false, raw.isError, 'isError would flatten the refusal to a string and lose the reason')
    eq(false, lang.ok)
    eq('profiles-not-comparable', lang.refusal.rule)
    ok(lang.refusal.reason:find('different languages', 1, true),
        "portability's own sentence, not a paraphrase: " .. lang.refusal.reason)
    eq(vim.NIL, lang.result, 'a refusal has no result at all — not an empty one')
    eq(vim.NIL, lang.absence, 'and it is NOT an absence: nothing about the code was concluded')

    -- (b) an artifact that cannot adjudicate a DOTTED name — the refusal that
    -- matters most, because the READ surface is where a port breaks and a
    -- profile blind to dotted names would answer "nothing was removed"
    local dotted = c:call('portability_move', { from = 'ruby-core', to = 'ruby-rails' })
    eq(false, dotted.ok)
    eq('profiles-not-comparable', dotted.refusal.rule)
    ok(dotted.refusal.reason:find('DOTTED', 1, true), dotted.refusal.reason)
    ok(dotted.refusal.reason ~= lang.refusal.reason,
        'two mechanisms, two sentences — a shared rule must not flatten them')
end)

test('mcpserve: an unshipped profile is `unavailable`, and never a clean 0', function ()
    if not ready() then skip('no treesitter') end
    local c = client(false)
    local d = c:call('portability_move', { from = FROM, to = 'lua-factorio-21' })
    eq(true, d.ok)
    eq(0, #d.result)
    eq('unavailable', d.absence,
        'no artifact for that version is an INSTRUMENT gap; rendering it as `absent` would claim the port is clean')
    eq('no-such-profile', d.absence_why.premise)
    ok(#d.absence_why.evidence.shipped > 3, 'with the roster that DOES ship')
    -- and the three renderings are distinguishable from one another, over the wire
    local absent = c:call('portability_move', { from = TO, to = FROM })
    local refused = c:call('portability_move', { from = FROM, to = 'ruby-rails' })
    ok(d.absence ~= absent.absence, 'unavailable and absent do not render the same')
    eq(false, refused.ok)
    eq(true, absent.ok)
end)

test('mcpserve: on a THIN index the read diff answers and the call diff refuses', function ()
    if not ready() then skip('no treesitter') end
    local c = client(true)
    local info = c:call('graph_info', vim.empty_dict())
    eq('index-only', info.graph.index)
    local by = {}
    for _, r in ipairs(info.result) do by[r.verb] = r end
    eq(true, by.portability_move.available,
        'the catalogue says so BEFORE the agent asks: the read surface needs no call graph')
    eq(false, by.portability_move_calls.available)

    local reads = c:call('portability_move', { from = FROM, to = TO })
    eq(true, reads.ok)
    ok(#reads.result > 0,
        'and it delivers: refusing here would be the CART-0580 defect in reverse — a capability declared that the verb does not need')
    local calls = c:call('portability_move_calls', { from = FROM, to = TO })
    eq(false, calls.ok)
    eq('thin-index', calls.refusal.rule)
end)

test('mcpserve: the version-axis servers shut down cleanly', function ()
    if not ready() then skip('no treesitter') end
    for _, s in pairs(SERVERS) do
        s.c:close()
        vim.fn.delete(s.root, 'rf')
    end
    SERVERS = {}
    ok(true)
end)
