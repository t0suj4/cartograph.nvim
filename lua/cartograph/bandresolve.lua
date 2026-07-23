-- BANDRESOLVE — federated call resolution (federation F2, [[cartograph-band-federation]]
-- / [[cartograph-merging-strategies]]). The production seam F2 wires in: resolve a call
-- against its SOURCE BAND's index first (in-band, the 93-100% bandlocality measured),
-- and only the residual through bandlink (cross-band const→band + ancestor/extends hops).
-- NO whole-graph index — the scale unlock the peak arc pointed at (the merge peak was the
-- one global index + its ref-edge working set).
--
-- This module is the IN-BAND half + the composition; bandlink is the cross-band half.
-- It is ADDITIVE and OFF the production path until f2gate proves it reproduces whole-graph
-- relink (WRONG=0, MISS characterized). The in-band fit mirrors relink's `resolve` core:
-- EXACT key first — present-but-non-unique REFUSES (no tail fallback); tail (last segment)
-- only when the exact key is ABSENT. Language-fit always (a name never crosses langs).
--
-- KNOWN CONSERVATISM (measured as a LOWER bound): this applies the lang filter + uniqueness
-- but not yet the per-spec dotted/scope refinements (dot_calls_are_methods, qualified_scope_
-- local, literal_names/apertures). Those only ADD refusals, so real reproduction ≥ measured;
-- and they could only turn a reported WRONG into a MISS, never hide one — so f2gate's WRONG
-- set is an UPPER bound on hazards, each surfaced with an example for verification.

local M = {}

-- unique language-fitting node among candidates, or (nil, dup?) — dup = >1 distinct.
local function unique_langfit(cands, clang, lang_of)
    local fit, dup = nil, false
    for _, n in ipairs(cands or {}) do
        if lang_of(n.file) == clang then
            if fit and fit.id ~= n.id then dup = true else fit = n end
        end
    end
    return fit, dup
end

-- resolve `key` within a single band's index (build_index shape). Mirrors relink's
-- resolve core: EXACT wins if uniquely lang-fitting; exact-present-but-non-unique is a
-- refusal (NO tail fallback — the exact-then-refuse semantics); tail (last segment) only
-- when the exact key is absent. Returns (node, 'exact'|'tail') or (nil, why):
-- 'no-band' (band absent), 'ambiguous' (>1 fit), 'absent' (no fit under key or tail).
function M.in_band_fit(key, index, clang, lang_of)
    if not index then return nil, 'no-band' end
    local ec = index.exact[key]
    if ec and ec[1] then
        local fit, dup = unique_langfit(ec, clang, lang_of)
        if fit and not dup then return fit, 'exact' end
        return nil, dup and 'ambiguous' or 'absent'
    end
    local tl = key:match('([%w_]+)$')
    local tc = tl and (index.tail[tl] or index.exact[tl])
    if tc and tc[1] then
        local fit, dup = unique_langfit(tc, clang, lang_of)
        if fit and not dup then return fit, 'tail' end
        return nil, dup and 'ambiguous' or 'absent'
    end
    return nil, 'absent'
end

-- the global TAIL-WITNESS (linkage band): per language, tail segment -> the UNIQUE def
-- id bearing it corpus-wide, or `false` if >1. The sound replacement for a per-band tail
-- guess — tail uniqueness is a GLOBAL property (a band-local tail-unique may not be
-- global-unique; the same union insight as interface→impl). Tiny (tail→id), not a global
-- node index. Built once over the linkage band; production's promiscuous tail path is
-- reproduced ONLY where it was globally decidable — a non-unique tail defers to MISS
-- (production disambiguated by scope / module-alias binding, a later linkage facet).
function M.tail_witness(data, lang_of)
    local w = {}
    for _, n in ipairs(data.nodes or {}) do
        if (n.kind == 'function' or n.kind == 'method') and not n.torn and not n.decl and n.file then
            local tl = n.name:match('([%w_]+)$')
            if tl then
                local lang = lang_of(n.file)
                local m = w[lang]; if not m then m = {}; w[lang] = m end
                if m[tl] == nil then m[tl] = n.id
                elseif m[tl] ~= n.id then m[tl] = false end
            end
        end
    end
    return w
end

-- resolve a single call's key, mirroring whole-graph relink's EXACT-before-TAIL order
-- lifted across the federation — the ordering is load-bearing for WRONG=0:
--   1. EXACT in the SOURCE band (unique lang-fit). exact-present-but-non-unique REFUSES.
--   2. cross-band EXACT via bandlink (const→band routing + ancestor/extends hops).
--   3. TAIL (last segment) in the source band — ONLY now, when the exact key is absent
--      everywhere AND no owner constant routed it. A qualified key (`Owner::m`) is
--      authoritative: it MUST route by its owner (step 2) before any fuzzy tail, else the
--      source band's same-tailed SIBLING is grabbed over the true cross-band target (the
--      WRONG f2gate caught: ShardId::getIndex → a sibling getIndex).
-- `idx` = per-band indexes (bandlink.indexes); `chains` = bandlink.chains(data).
-- Returns (id, tier) or (nil, why). tier ∈ 'in-band-exact'|'xband-<why>'|'in-band-tail'.
-- Step 3 is the global TAIL-WITNESS (NOT a per-band tail guess): only a globally-unique
-- tail resolves (soundly, to its one owner in whatever band); a non-unique tail defers to
-- MISS. `witness` = M.tail_witness(data, lang_of). f2gate's remaining WRONG, if any, is
-- then the receiver-typed-override frontier (production narrowed the receiver past the
-- syntactic owner) — out of this fast-path's claimed scope, deferred to a fuller pass.
function M.resolve_call(key, sband, idx, const_index, chains, witness, clang, lang_of, bandlink)
    local si = idx[sband]
    -- 1. EXACT, source band (no tail here — exact-present-non-unique refuses, as relink)
    if si then
        local ec = si.exact[key]
        if ec and ec[1] then
            local fit, dup = unique_langfit(ec, clang, lang_of)
            if fit and not dup then return fit.id, 'in-band-exact' end
            return nil, 'ambiguous'
        end
    end
    -- 2. cross-band EXACT via const routing + ancestor/extends (authoritative for a
    --    qualified key — BEFORE any fuzzy tail)
    local id, xwhy = bandlink.resolve(key, const_index, idx, chains, clang, lang_of)
    if id then return id, 'xband-' .. xwhy end
    -- 3. TAIL-WITNESS: globally-unique tail only (sound); non-unique → MISS
    local tl = key:match('([%w_]+)$')
    local wl = tl and witness and witness[clang]
    local wid = wl and wl[tl]
    if wid then return wid, 'tail-witness' end
    return nil, wid == false and 'tail-ambiguous' or (xwhy or 'absent')
end

return M
