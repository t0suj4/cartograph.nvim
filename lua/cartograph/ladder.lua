local callrec = require 'cartograph.callrec'
local callview = require 'cartograph.callview' -- neutral call accessor (columns/resident/raw)
-- The epistemic ladder, as a readable distribution. Every call sits on
-- a rung by HOW its target is known, and the ladder answers "how much
-- of this can I trust" — for one function's outgoing calls, or the
-- whole graph. Pure: counts over store data, no UI.
--
-- Rungs, most-known first:
--   proven   an oracle (clangd/luals) or a cross-language key resolved it
--   linked   a same-file / same-scope name match, no ~ (plain resolution)
--   inferred a cross-file unique-name guess (the ~ vocabulary)
--   dynamic  a call the graph knows it cannot see ($fn(), variable method)
--   refused  ambiguity or scope/vocab declined to pick (a navigable fork).
--            NARROWER THAN IT SOUNDS: rung_of below requires a non-empty
--            candidate list, so a refusal that recorded only its rule falls
--            through to `frontier` and is reported as unparsed/stdlib
--            territory rather than as a decision the graph made (CART-0546).
--   frontier a callee neither resolved nor refused (unparsed / stdlib) —
--            plus the candidate-less refusals just described

local M = {}

-- This is the CALL view of the ladder — a superset of the resolved-edge tiers
-- ([[cartograph.tier]]) with the unresolved rungs (dynamic/refused/frontier)
-- and a deliberate coarsening (xlang folds into 'proven' for this report,
-- 'matched' reads as 'linked').
--
-- ★ THE ORDER DOES NOT MATCH tier.lua, AND THIS COMMENT USED TO SAY IT DID
-- (CART-0545). RUNGS below runs `linked` (tier's `matched`) ABOVE `typed` and
-- `inferred`; tier.lua's M.LADDER runs the same three as typed → inferred →
-- matched, i.e. it puts the unhedged link LAST. So the two files disagree on
-- both `linked` vs `typed` and `linked` vs `inferred`, and nothing has decided
-- which is right — see tier.lua's ★ note. This file only DISPLAYS its order
-- (RUNGS is iteration order for the report); tier.lua's is also its rank, so
-- the disagreement is only visible today when a reader compares the two.
-- rung_of below is NOT a third opinion: testing `tinf` before falling through
-- to inferred/linked is exactly tier.of's precedence (typed above inferred,
-- and the two DO co-occur — see tests/tier_spec.lua's `{ tinf, inferred }`
-- case). What disagrees with tier.lua is only where `linked` sits in RUNGS.
-- 'typed': the graph-VM resolved this via a return-type summary — stronger
-- than a bare unique-name ~ guess (it used type evidence). Whether it is
-- weaker than a plain same-scope link is exactly what the two files disagree
-- about; this report renders it below `linked`.
-- 'confirmed': observed live at runtime (self://loaded, MCP) — the SOUND
-- top rung, above even a static oracle (proven).
local RUNGS = { 'confirmed', 'proven', 'linked', 'typed', 'inferred',
    'dynamic', 'refused', 'frontier' }
M.RUNGS = RUNGS

-- which rung a single call sits on. `edge_proven` = a set of
-- "from\31to" the oracle/xlang marked proven (from store).
local function rung_of(c, proven)
    if callrec.to(c) then
        if c.conf then return 'confirmed' end -- observed live: sound top rung
        if proven and callrec.fn(c) and proven[callrec.fn(c) .. '\31' .. callrec.to(c)] then return 'proven' end
        if c.tinf then return 'typed' end
        return c.inferred and 'inferred' or 'linked'
    end
    if c.dynamic then return 'dynamic' end
    if c.refused and c.refused.cands and #c.refused.cands > 0 then return 'refused' end
    return 'frontier'
end
M.rung_of = rung_of

-- proven set: xlang edges and oracle-resolved edges carry a marker on
-- the ref edge (xlang=true) or the graph capability says an oracle ran
local function proven_set(store)
    local set = {}
    for _, e in ipairs(store.data.edges or {}) do
        if e.kind == 'ref' and (e.xlang or e.proven) then
            set[e.from .. '\31' .. e.to] = true
        end
    end
    return set
end

--- Distribution over one function's outgoing calls (by id) or, with
--- no id, the whole graph. Returns { rung -> count, total = n }.
function M.tally(store, id)
    local proven = proven_set(store)
    local out = { total = 0 }
    for _, r in ipairs(RUNGS) do out[r] = 0 end
    -- per-fn: the SITE axis (Band); whole-graph: the raw call array
    local calls = id and store.topo():sites(id) or (store.data.calls or {})
    for _, c in ipairs(calls) do
        local r = rung_of(c, proven)
        out[r] = out[r] + 1
        out.total = out.total + 1
    end
    return out
end

--- A one-line summary (the fn-view header, the ladder report top).
function M.summary(t)
    local parts = {}
    local glyph = { confirmed = '⏺', proven = '✓', linked = '→', typed = 'T',
        inferred = '~', dynamic = '$', refused = '?', frontier = '·' }
    for _, r in ipairs(RUNGS) do
        if t[r] > 0 then parts[#parts + 1] = ('%s%d'):format(glyph[r], t[r]) end
    end
    return #parts > 0 and table.concat(parts, ' ') or '(no calls)'
end

--- NARROWABLE REFUSALS — rule 2 of the resolution-health analyzer. An ambiguous
--- refusal on a QUALIFIED call (`recv.member`) is narrowable by typing the
--- receiver; classify the receiver by WHICH rung would resolve it and rank the
--- receiver-typing WORK-LIST by payoff (calls unlocked × narrowability). This is
--- the df-census insight as a standing ranking: which receivers, once typed,
--- dissolve the most refusals. Returns a sorted list of
--- { file, recv, class, calls, nmembers, score }.
---   alias  = receiver is a require-import bind (module-alias, rung 1 — surest;
---            what's left here is a member the module-alias pass couldn't pick)
---   self   = self/this receiver (class-property atlas / receiver typing)
---   local  = receiver is a local/param of the enclosing fn (reaching / VM tinf)
---   unknown= a free receiver (hardest)
function M.narrowable(store)
    local alias = {} -- file -> { require-bound alias name -> true }
    for _, e in ipairs(store.data.edges or {}) do
        if e.kind == 'import' and e.bind and e.from then
            local m = alias[e.from]; if not m then m = {}; alias[e.from] = m end
            m[e.bind] = true
        end
    end
    local df = require 'cartograph.df'
    local locals = {}
    local function fn_locals(id)
        local s = locals[id]; if s then return s end
        s = {}; local n = id and store.node(id)
        if n then
            for _, p in ipairs(n.params or {}) do s[p] = true end
            for _, st in ipairs(df.stmts(n)) do for _, d in ipairs(st.def or {}) do s[d] = true end end
        end
        locals[id] = s; return s
    end
    local W = { alias = 4, self = 3, ['local'] = 2, unknown = 1 } -- narrowability
    local cv = callview.of(store.data) -- index-form: columns/resident/raw, neutral
    local agg = {}
    for i = 1, cv.n do
        local to, dynamic, refused, full =
            cv.get(i, 'to'), cv.get(i, 'dynamic'), cv.get(i, 'refused'), cv.get(i, 'full')
        if not to and not dynamic and refused and refused.rule == 'ambiguous'
            and refused.cands and #refused.cands > 0 and full then
            local recv, member = full:match('^([%w_]+)[.:]([%w_]+)$')
            if recv and member then
                local file, fn = cv.get(i, 'file'), cv.get(i, 'fn')
                local class = (recv == 'self' or recv == 'this') and 'self'
                    or (alias[file] and alias[file][recv]) and 'alias'
                    or (fn and fn_locals(fn)[recv]) and 'local'
                    or 'unknown'
                local key = file .. '\31' .. recv .. '\31' .. class
                local a = agg[key]
                if not a then a = { file = file, recv = recv, class = class,
                    calls = 0, members = {} }; agg[key] = a end
                a.calls = a.calls + 1
                a.members[member] = true
            end
        end
    end
    local out = {}
    for _, a in pairs(agg) do
        a.nmembers = 0; for _ in pairs(a.members) do a.nmembers = a.nmembers + 1 end
        a.members = nil
        a.score = a.calls * W[a.class] -- payoff = calls unlocked × narrowability
        out[#out + 1] = a
    end
    table.sort(out, function (x, y)
        if x.score ~= y.score then return x.score > y.score end
        if x.calls ~= y.calls then return x.calls > y.calls end
        -- STABLE tiebreak (file/recv/class = the agg key, unique per entry): the report
        -- is representation-independent + run-to-run deterministic, not pairs()-order luck
        if x.file ~= y.file then return x.file < y.file end
        if x.recv ~= y.recv then return x.recv < y.recv end
        return x.class < y.class
    end)
    return out
end

--- The graph report: the distribution, then the heaviest refusal sites
--- (the forks worth resolving), each as { file, line, callee, n }.
function M.report(store)
    local t = M.tally(store)
    local lines = { ('epistemic ladder — %d calls'):format(t.total) }
    -- a ladder over call records understates a graph whose provider aggregates
    -- them into reference edges: say so, so the count is not read as the whole
    -- call structure ([[cartograph-stack-languages]])
    if not require('cartograph.source').caps(store.data or {}).per_site_calls then
        lines[#lines + 1] = '  NOTE: this graph aggregates references into edges'
            .. ' (capabilities.calls = aggregated) —'
        lines[#lines + 1] = '  only true call records are laddered below;'
            .. ' word-to-word references are not among them'
    end
    local label = { confirmed = 'confirmed (observed live at runtime)',
        proven = 'proven (oracle / cross-language)',
        linked = 'linked (a binding, or same scope, plain)',
        typed = 'typed (graph-VM return-type summary)',
        inferred = 'inferred (~ unique name)',
        dynamic = 'dynamic (unseeable frontier)',
        refused = 'refused (ambiguous fork)',
        frontier = 'frontier (stdlib / unparsed)' }
    for _, r in ipairs(RUNGS) do
        if t[r] > 0 then
            lines[#lines + 1] = ('  %5d  %s'):format(t[r], label[r])
        end
    end
    -- the heaviest refusals: where resolving one fork buys the most. INDEX FORM via
    -- callview (columns/residual when the store is columnar, raw records otherwise) — no
    -- proxy dispatch; refs holds the index + refusal, not the call.
    local cv = callview.of(store.data)
    local refs = {}
    for i = 1, cv.n do
        local to, dynamic, refused = cv.get(i, 'to'), cv.get(i, 'dynamic'), cv.get(i, 'refused')
        if not to and not dynamic and refused and refused.cands and #refused.cands > 0 then
            refs[#refs + 1] = { i = i, refused = refused }
        end
    end
    table.sort(refs, function (a, b)
        local an, bn = a.refused.n or 0, b.refused.n or 0
        if an ~= bn then return an > bn end
        return a.i < b.i -- STABLE tiebreak by call index (deterministic across reps)
    end)
    if #refs > 0 then
        lines[#lines + 1] = ''
        lines[#lines + 1] = 'heaviest refusals (descend a `?callee` in its fn to resolve):'
        for k = 1, math.min(12, #refs) do
            local ref = refs[k]
            lines[#lines + 1] = ('  %s:%d  %s  (%d candidates)')
                :format(cv.get(ref.i, 'file'), cv.get(ref.i, 'line') + 1,
                    cv.get(ref.i, 'callee'), ref.refused.n or 0)
        end
    end
    -- the receiver-typing WORK-LIST: which receivers, typed, dissolve the most
    -- ambiguous forks (rule 2 of the resolution-health analyzer)
    local nb = M.narrowable(store)
    if #nb > 0 then
        lines[#lines + 1] = ''
        lines[#lines + 1] = 'narrowable by receiver (type the receiver → resolve the fork):'
        for i = 1, math.min(12, #nb) do
            local a = nb[i]
            lines[#lines + 1] = ('  %-12s [%-7s] %s  (%d call%s, %d member%s)')
                :format(a.recv, a.class, a.file, a.calls, a.calls == 1 and '' or 's',
                    a.nmembers, a.nmembers == 1 and '' or 's')
        end
    end
    return lines
end

return M
