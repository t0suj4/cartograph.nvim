-- agentq — THE AGENT ENVELOPE, phase 0 (CART-0143, under CART-0142's T3).
-- ONE verb, headless, ONE JSON document on stdout and nothing else:
--
--   nvim --headless -u NONE -l tools/agentq.lua <root> alibi <file> <line>
--
-- `alibi` answers "why is this NOT dead" for the innermost function enclosing
-- <file>:<line>. It is the deliberate first verb because it is the one an agent
-- consults before a DELETION: the difference between "nothing keeps this alive",
-- "something might and a rule declined to say which" and "nothing was looked at"
-- is the difference between a safe edit and a broken build. Today those three
-- render identically everywhere in this repo — a caller sees an empty list.
--
-- NO NEW ANALYSIS. Every fact comes from lint.alibi (the predicates the
-- dead-function and dead-confined rules already share) read through the Band
-- seam. This script is transport.
--
-- THE ENVELOPE, and the one rule that carries the weight:
--   EXACTLY ONE OF `tier` AND `absence` IS NON-NULL.
--     result non-empty -> `tier` = the strongest alibi's rung (a tier.LADDER
--                         name, never a minted one), `absence` = null
--     result empty     -> `tier` = null, `absence` = absent | refused |
--                         frontier | unavailable, and `absence_why` NAMES THE
--                         PREMISE that failed, with its evidence
--   A bare `[]` is unrepresentable: an empty result always carries an absence.
--
-- WHY tier IS NULL ON AN EMPTY RESULT, since the design draft asked for a tier on
-- every answer. tier.lua's ladder ranks HOW A NAME WAS RESOLVED. An empty alibi
-- list resolved nothing, so no rung applies, and minting one ('absent' as a tier)
-- would be the exact fabrication this envelope exists to stop. `tier` and
-- `absence` are the same axis seen from the two sides of an answer, and exactly
-- one side exists at a time. Phase 1 (CART-0144) should carry both fields with
-- this mutual exclusion, not one field that means two things.
--
-- `tier_headline = 'peak'` — WHICH QUANTIFIER PICKED THE HEADLINE (CART-0581).
-- This verb takes the STRONGEST rung in the list, and agent.lua's edges_callers
-- takes the WEAKEST. Both are right and the reason is the witness/promise
-- distinction: an alibi is EXISTENTIAL ("is there anything keeping this alive"),
-- so one strong witness decides; a caller list is UNIVERSAL as presented, so it
-- is only as good as its shakiest member. But `tier` IS THE SAME FIELD NAME ON
-- BOTH SURFACES. An agent reading `tier: inferred` from here learns "the best
-- thing supporting this is a guess"; the same string from edges_callers means
-- "at least one row is a guess, the rest may be proven". Acting on the first as
-- if it were the second UNDER-trusts, and the reverse OVER-trusts. A human
-- notices the verbs differ; an agent has only the field — so the field now says.
-- agent.lua declares it per verb and publishes it in graph_info's catalogue.
-- ★ THE GENERAL RULE: a SUMMARY OVER ROWS IS A QUANTIFIER CHOICE, and the choice
-- is part of the answer. Publishing the summary without its quantifier is the
-- same defect class as an empty list without its absence.
--
-- `absent` IS NEVER CLAIMED MORE OFTEN THAN THE AUTHORITATIVE LINT CLAIMS IT:
-- lint's `provably_dead` (four premises) is the sole authority, so this verb
-- cannot license a deletion :CartographLint's dead-confined rule would refuse.
--
-- EXIT CODES, because a refusal is not an error (design rule 2) and a shell must
-- be able to tell them apart without parsing:
--   0  ok:true      an answer
--   3  ok:false     a REFUSAL — stable, do not retry; `refusal.remedy` says what to change
--   2  usage / protocol fault
--   1  an internal error (still emitted as JSON, in `error`)

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
pcall(vim.treesitter.language.add, 'lua')
package.path = repo .. '/lua/?.lua;' .. repo .. '/lua/?/init.lua;' .. package.path

local VERBS = { alibi = true }
local NUL = vim.NIL

-- one document, one write, one exit. Nothing else in this file prints.
local function emit(doc, code)
    local ok, s = pcall(vim.json.encode, doc)
    if not ok then
        s = vim.json.encode({ ok = false, verb = doc.verb or NUL,
            error = { kind = 'encode', reason = tostring(s) } })
        code = 1
    end
    io.stdout:write(s .. '\n')
    os.exit(code or 0)
end

--- a REFUSAL: a stable answer about the world. Names the rule, the reason and the
--- remedy — CART-0576's rule, that a refusal aimed at an agent must say WHICH
--- premise failed, or the agent cannot act on it at all.
local function refuse(verb, rule, reason, remedy, graph)
    emit({ ok = false, verb = verb or NUL, graph = graph or NUL, result = NUL,
        tier = NUL, tier_headline = 'peak', absence = NUL, absence_why = NUL,
        notes = {},
        refusal = { rule = rule, reason = reason, remedy = remedy or NUL } }, 3)
end

-- ── arguments ────────────────────────────────────────────────────────────────
local root, verb, file, line = arg[1], arg[2], arg[3], tonumber(arg[4])
if not (root and verb) then
    emit({ ok = false, verb = NUL, error = { kind = 'usage',
        reason = 'usage: agentq.lua <root> alibi <file> <line>',
        verbs = vim.tbl_keys(VERBS) } }, 2)
end
if not VERBS[verb] then
    emit({ ok = false, verb = verb, error = { kind = 'usage',
        reason = ('unknown verb %q'):format(verb), verbs = vim.tbl_keys(VERBS) } }, 2)
end
if not (file and line) then
    emit({ ok = false, verb = verb, error = { kind = 'usage',
        reason = 'alibi needs <file> <line>' } }, 2)
end
if vim.fn.isdirectory(root) ~= 1 then
    emit({ ok = false, verb = verb, error = { kind = 'usage',
        reason = ('root is not a directory: %s'):format(root) } }, 2)
end

-- ── graph ────────────────────────────────────────────────────────────────────
local atr = require 'cartograph.at'
local lint = require 'cartograph.lint'
local optapply = require 'cartograph.optapply'
local store = require 'cartograph.store'
local tiers = require 'cartograph.tier'
local ts = require 'cartograph.providers.treesitter'

local okx, data = pcall(ts.extract, root)
if not okx then
    emit({ ok = false, verb = verb,
        error = { kind = 'extract', reason = tostring(data) } }, 1)
end
data.root = data.root or root
store.ingest(data)

local graph = {
    root = root,
    provider = 'treesitter',
    index = store.is_index_only() and 'index-only' or 'full',
    generation = store.generation or 0,
    partial = store.data.partial or NUL,
    counts = { nodes = #(store.data.nodes or {}), edges = #(store.data.edges or {}),
        calls = #(store.data.calls or {}) },
}

-- capability negotiation, the lsp.lua discipline: do not answer what this graph
-- cannot answer. An alibi read off a graph with no call records would report
-- "no callers" for everything alive.
if graph.index ~= 'full' or not store.data.calls then
    refuse(verb, 'thin-index',
        'the call graph was not extracted, so "no callers" would be a property of the index, not of the code',
        'open the root without index_only', graph)
end

-- ── subject ──────────────────────────────────────────────────────────────────
local id = optapply.at(store, file, line)
if not id then
    refuse(verb, 'no-subject',
        ('no function or method encloses %s:%d'):format(file, line),
        'point at a line inside a function body; `file` matches a stored path exactly or as a trailing /-segment',
        graph)
end
local n = store.node(id)
-- TWO HANDLES, under their true names (CART-0145, matching agent.lua's noderow).
-- `id` is the SESSION handle: it embeds line numbers, so the first edit above
-- this function invalidates it silently. `ref` is the DURABLE one — refs.lua's
-- {file, kind, name, ordinal?, witness?} — which survives edits elsewhere,
-- survives a body edit with a drift note, and follows a rename by witness.
-- Phase 0 shipped one field called `ref` that actually held the id; a caller
-- that pins an answer across an edit needs the other one.
local subject = { id = id, ref = store.ref_of(id) or NUL,
    name = n.name or NUL, kind = n.kind,
    file = store.abspath(n), line = atr.sl(n.range) + 1 }

-- ── the answer ───────────────────────────────────────────────────────────────
local okc, verdict = pcall(function () return lint.alibi(store)(n) end)
if not okc then
    emit({ ok = false, verb = verb, graph = graph, subject = subject,
        error = { kind = 'analysis', reason = tostring(verdict) } }, 1)
end

local notes = {}

-- every alibi renders with its own rung and its own evidence, so the rung never
-- has to be trusted on its own
local result = {}
for _, a in ipairs(verdict.alibis) do
    result[#result + 1] = { kind = a.kind, tier = a.tier, why = a.why,
        evidence = a.evidence or NUL }
end

local tier, absence, absence_why = NUL, NUL, NUL
if #result > 0 then
    -- WITNESS SEMANTICS: one alibi is enough, so the answer is as strong as the
    -- STRONGEST of them ([[cartograph-witness-and-promise]]).
    local best
    for _, a in ipairs(verdict.alibis) do
        local r, br = tiers.rank(a.tier), best and tiers.rank(best)
        if r and (not br or r < br) then best = a.tier end
    end
    tier = best or NUL
    -- DISCLOSE the one comparison this ladder does not agree with itself about:
    -- tier.lua ranks the unhedged same-file link BELOW the cross-file ~ guess.
    local has = {}
    for _, a in ipairs(verdict.alibis) do has[a.tier] = true end
    if has.inferred and has.matched then
        notes[#notes + 1] = { kind = 'tier-order-disputed',
            why = "this answer's tier was picked across 'inferred' vs 'matched', the one pair tier.lua and ladder.lua order differently (CART-0545) — read the per-alibi evidence, not the headline rung" }
    end
else
    -- EMPTY: the absence taxonomy is the whole answer. The FIRST blocker decides
    -- (lint.alibi returns them in provably_dead's own premise order); the rest are
    -- notes, so a caller that discharges one premise learns at once whether another
    -- is waiting behind it.
    local first = verdict.blockers[1]
    if verdict.dead then
        -- provably_dead: exported==false AND escapes==false AND the name occurs once
        -- AND no refused call shadows it AND no callers AND no registrants
        absence = 'absent'
        absence_why = { premise = 'provably-dead',
            why = 'the source declares it file-local, its name never escapes into a value position, it occurs only at its own definition, and no refused call could be it — a local nothing mentions cannot be reached',
            evidence = NUL }
        -- …AND YET a premise reported itself as failed. provably_dead does not test
        -- `unparsed`, so the two CAN disagree in this direction. Downgrade rather than
        -- claim a licence to delete: an absence that something contradicted is not an
        -- absence. (The inverse disagreement is handled in the `else` arm below.)
        if #verdict.blockers > 0 then
            local names = {}
            for _, b in ipairs(verdict.blockers) do names[#names + 1] = b.kind end
            absence = 'frontier'
            absence_why = { premise = 'contested-absence',
                why = ('every deletion premise held, but %d premise(s) also reported themselves failed (%s) — the two disagree, so this is NOT a licence to delete'):format(
                    #verdict.blockers, table.concat(names, ', ')),
                evidence = { blockers = names } }
        end
    elseif first then
        absence = first.absence
        absence_why = { premise = first.kind, why = first.why,
            evidence = first.evidence or NUL }
    else
        -- unreachable by construction: provably_dead false with no blocker would mean
        -- a premise failed that nothing reported. Say so rather than inventing a value.
        absence = 'unavailable'
        absence_why = { premise = 'unclassified',
            why = 'no alibi, and no premise reported itself as the reason — the classifier and provably_dead disagree; treat this as a bug in agentq/lint.alibi, not as a fact about the code',
            evidence = NUL }
    end
    -- the ones that did NOT decide. From 1 when provably_dead already supplied the
    -- absence_why, else from 2 (blockers[1] IS the absence_why).
    for i = (verdict.dead and 1 or 2), #verdict.blockers do
        local b = verdict.blockers[i]
        notes[#notes + 1] = { kind = 'also-blocked', premise = b.kind,
            absence = b.absence, why = b.why, evidence = b.evidence or NUL }
    end
end

-- a blocker beside a live alibi is not the answer, but it IS worth knowing: it says
-- how much of this function's reachability was actually looked at
if #result > 0 then
    for _, b in ipairs(verdict.blockers) do
        notes[#notes + 1] = { kind = 'unexamined', premise = b.kind,
            absence = b.absence, why = b.why, evidence = b.evidence or NUL }
    end
end

emit({ ok = true, verb = verb, graph = graph, subject = subject,
    result = result, tier = tier,
    -- STRONGEST rung, and the field that says so (CART-0581): see the header.
    tier_headline = 'peak',
    absence = absence, absence_why = absence_why,
    notes = notes }, 0)
