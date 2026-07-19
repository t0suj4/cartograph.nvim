-- The canonical TIER LADDER — the graph's epistemic precedence, in ONE place.
-- A resolved ref edge's trust is a set of boolean flags; its tier is the
-- HIGHEST flag set. Historically that if-chain was hand-copied into census,
-- ladder, graphdiff and (bit-packed) fold — four spellings that had already
-- drifted: graphdiff silently omitted `conf`/`tinf` (folding them into
-- 'matched'), ladder folds `xlang` into 'proven'. This module is the single
-- source of truth: census + graphdiff read M.of(); federation's tier-based
-- precedence (never band-rank, [[cartograph-band-federation]]) reads M.rank();
-- the two banked tiers (stdlib, convention) each insert as ONE row in
-- M.LADDER, not N edits across N if-chains. Invariant #3 (uniform honesty): a
-- tier can never mean two different orders in two different places.

local M = {}

-- Highest trust → lowest. `flag` = the boolean field on a ref edge that puts
-- the edge on this rung; the tail rung is the flagless fallback (a bare
-- unique-name match). INSERTION POINTS for the banked tiers — a new rung is
-- one line here and every consumer follows:
--   · stdlib     ([[cartograph-stdlib-profile]]) profile-backed external
--     resolution — below the static tiers, above the name-match tiers.
--   · convention ([[cartograph-modular-specs]], `e.conv`) a pack-declared DSL
--     match — just above 'matched'.
M.LADDER = {
    { name = 'confirmed', flag = 'conf' },     -- runtime-observed (sound top)
    { name = 'proven',    flag = 'proven' },   -- static proof / oracle
    { name = 'xlang',     flag = 'xlang' },    -- cross-language key
    { name = 'typed',     flag = 'tinf' },     -- graph-VM return-type summary
    { name = 'inferred',  flag = 'inferred' }, -- ~ unique-name hypothesis
    { name = 'matched' },                      -- bare name match (fallback)
}

-- name -> rank (1 = most trusted). Precedence comparisons read this, never a
-- re-typed order.
M.RANK = {}
for i, rung in ipairs(M.LADDER) do M.RANK[rung.name] = i end

--- The tier name of a resolved ref edge. Early-exits at the highest set flag.
function M.of(e)
    for _, rung in ipairs(M.LADDER) do
        if not rung.flag or e[rung.flag] then return rung.name end
    end
    return M.LADDER[#M.LADDER].name -- unreachable: the last rung is flagless
end

--- Numeric precedence of a tier name (lower = more trusted); nil if unknown.
function M.rank(name) return M.RANK[name] end

--- Is tier `a` at least as trusted as tier `b`? (the federation precedence
--- rule — trust decides, band rank never does).
function M.at_least(a, b)
    local ra, rb = M.RANK[a], M.RANK[b]
    return ra ~= nil and rb ~= nil and ra <= rb
end

return M
