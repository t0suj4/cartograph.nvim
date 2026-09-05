-- findings.lua — WHAT HAS BEEN SAID ABOUT THIS NODE, AND WHAT NOBODY HAS ASKED.
--
-- Findings are computed on demand and then thrown away: `lint` persists nothing,
-- a probe or census PRINTS and exits, and `band.lua` is a topology view over
-- typed edges, not a store. So a reader holding a node has no way to learn that
-- something was already established about it (CART-0762).
--
-- ★★ THE HARD PART IS NOT THE ATTACHMENT, IT IS THE ABSENCE. A node with no
-- finding must distinguish
--     "every census that ran looked here and said nothing"   — a RESULT
--     "no census has been run against this graph"            — UNAVAILABLE
-- and conflating them makes the READ SURFACE MANUFACTURE CLEAN BILLS OF HEALTH,
-- at exactly the moment a caller is deciding whether code is safe. The tree
-- already refuses that one rung over — on an index-only graph a call verb
-- REFUSES rather than answering "none" — and this is the same rule on a new
-- axis. Every answer therefore carries `not_run` beside `findings`.
--
-- ⚠ GENERATION-KEYED, IN MEMORY, BY DESIGN FOR THIS INCREMENT. A finding is a
-- claim about the tree it was computed against; after an edit the graph moves and
-- the claim describes a tree that is gone. Keying the record to
-- `store.generation` makes staleness STRUCTURAL rather than a policy someone must
-- remember — the same rule the write side already states for a plan handle, which
-- "dies with the generation it was planned against" (CART-0761).
-- ⚠ AND THEREFORE IT DOES NOT SURVIVE THE SESSION. Cross-session persistence is a
-- BAND question — a finding is a different lifecycle and trust class from a
-- parsed fact, and mixing them risks a candidate being read as a code fact
-- ([[cartograph-band-federation]], CART-0755). Deferred deliberately, not missed.

local M = {}

--- The declared roster of finding producers. `not_run` is computed against THIS,
--- so a census absent from here is invisible rather than reported missing —
--- which is why adding a producer means adding its name here in the same change.
M.CENSUSES = {
    lint = 'the lint rules (lint.run), all dispositions',
}

--- Record a census's findings against the CURRENT generation.
---@param store table
---@param name string  a key of M.CENSUSES
---@param rec table    { complete = 'exhaustive'|'ranked-open', scope = string,
---                      by_id = { [node id] = { text, ... } } }
function M.record(store, name, rec)
    if not M.CENSUSES[name] then
        return nil, ('unknown census %q — add it to findings.CENSUSES in the same '
            .. 'change that produces it, or `not_run` cannot mention it'):format(name)
    end
    if type(rec) ~= 'table' or type(rec.by_id) ~= 'table' then
        return nil, '`by_id` must be a table of node id -> list of finding texts'
    end
    -- ⚠ COMPLETENESS IS MANDATORY HERE TOO. A census that sampled 400 functions is
    -- `ranked-open` over the corpus, and a row it never examined must not read as
    -- a row it cleared (CART-0755).
    local sl = require 'cartograph.shortlist'
    if not sl.rank(rec.complete) then
        return nil, ('a recorded census must declare `complete` as %q or %q')
            :format(sl.EXHAUSTIVE, sl.RANKED_OPEN)
    end
    store._findings = store._findings or {}
    store._findings[name] = { generation = store.generation or 0,
        complete = rec.complete, scope = rec.scope or '(unstated)', by_id = rec.by_id }
    return true
end

--- What has run against the CURRENT generation, what is stale, what never ran.
function M.manifest(store)
    local gen = store.generation or 0
    local out = { current = {}, stale = {}, not_run = {} }
    local rec = store._findings or {}
    for name in pairs(M.CENSUSES) do
        local r = rec[name]
        if not r then out.not_run[#out.not_run + 1] = name
        elseif r.generation ~= gen then out.stale[#out.stale + 1] = name
        else out.current[#out.current + 1] = name end
    end
    for _, t in pairs(out) do table.sort(t) end
    return out
end

--- The findings on one node, WITH what was never asked.
--- ★ THE THREE-WAY ANSWER IS THE POINT. `findings` empty and `not_run` empty means
--- every declared census looked here and said nothing. `findings` empty with
--- `not_run` populated means nobody looked. They must never render alike.
function M.for_node(store, id)
    local man = M.manifest(store)
    local out = { findings = {}, not_run = man.not_run, stale = man.stale }
    for _, name in ipairs(man.current) do
        local r = store._findings[name]
        for _, text in ipairs(r.by_id[id] or {}) do
            out.findings[#out.findings + 1] = { census = name, text = text,
                complete = r.complete }
        end
    end
    return out
end

--- PRODUCER: run the lint rules and record them. Kept here rather than in lint so
--- the roster and its producer land in one file — the `fix` field shipped by one
--- rule and read by nobody is what that avoids (CART-0755).
function M.record_lint(store, opts)
    local ok, findings = pcall(require('cartograph.lint').run, store, opts)
    if not ok then return nil, tostring(findings) end
    -- ⚠ RANGE COORDS FOLD BEHIND atr.sl/el AND THE SEAM IS FENCED (guards.lua's
    -- `at` seam). My first cut read `nd.range.start.line` directly and crashed on
    -- a node whose range is not that shape — a hand-rolled accessor walking into
    -- a declared representation seam, which is the day's lesson one module over.
    local atr = require 'cartograph.at'
    -- lint answers with an ABSOLUTE path; `by_file` is keyed by the graph's own
    -- relative key. Build the inverse ONCE from store.abs rather than guessing at
    -- a prefix strip.
    local rel_of = {}
    for key in pairs(store.by_file or {}) do
        local okabs, abs = pcall(store.abs, key)
        if okabs and abs then rel_of[abs] = key end
        rel_of[key] = key
    end
    local by_id, n = {}, 0
    for _, f in ipairs(findings or {}) do
        -- SMALLEST enclosing definition wins, the same rule node_at uses: a
        -- finding inside a method belongs to the method, not to its module.
        local key = rel_of[f.file] or f.file
        local best, bestspan
        for _, nd in ipairs((store.by_file or {})[key] or {}) do
            if nd.range then
                local sl, el = atr.sl(nd.range) + 1, atr.el(nd.range) + 1
                if f.line and sl <= f.line and f.line <= el
                    and (not bestspan or (el - sl) < bestspan) then
                    best, bestspan = nd, el - sl
                end
            end
        end
        if best then
            by_id[best.id] = by_id[best.id] or {}
            table.insert(by_id[best.id], ('[%s] %s'):format(f.rule or '?', f.message or ''))
            n = n + 1
        end
    end
    local sl = require 'cartograph.shortlist'
    local okr, why = M.record(store, 'lint', { complete = sl.EXHAUSTIVE,
        scope = ('%d finding(s) over the whole graph'):format(n), by_id = by_id })
    if not okr then return nil, why end
    return n
end

return M
