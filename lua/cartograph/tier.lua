-- The canonical TIER LADDER — the graph's epistemic precedence, in ONE place.
-- A resolved ref edge's trust is a set of boolean flags; its tier is the
-- HIGHEST flag set. Historically that if-chain was hand-copied into census,
-- ladder, graphdiff and (bit-packed) fold — four spellings that had already
-- drifted: graphdiff silently omitted `conf`/`tinf` (folding them into
-- 'matched'), ladder folds `xlang` into 'proven'. This module is the single
-- source of truth: census + graphdiff read M.of(); federation's tier-based
-- precedence (never band-rank, [[cartograph-band-federation]]) reads M.rank();
-- a banked tier inserts as ONE row in M.LADDER, not N edits across N if-chains
-- — stdlib has landed that way; `convention` is the one still banked, and per
-- the ★ capacity note below it is no longer a one-row edit on its own.
-- Invariant #3 (uniform honesty): a
-- tier can never mean two different orders in two different places — which
-- this file does NOT currently satisfy: ladder.lua orders the same two bottom
-- rungs the other way round, and neither order is agreed. See the ★ note on
-- M.LADDER and CART-0545 before trusting a comparison across the pair.

local M = {}

-- Highest trust → lowest. `flag` = the boolean field on a ref edge that puts
-- the edge on this rung; the tail rung is the FLAGLESS one — an edge that
-- resolved with NO hedge recorded on it. That is the extractor's same-file
-- exact binder match (providers/treesitter.lua `return same, false`, kept
-- flagless by ref_adder) or a candidate the user pinned out of a refusal
-- (panes/symbols.lua). It is NOT "a bare unique-name match": the bare
-- workspace-unique cross-file match sets `inferred` and is the rung ABOVE it.
--
-- ★ THE TAIL POSITION IS A MECHANISM, AND IT CURRENTLY READS AS A VERDICT
-- (CART-0545). One index does three jobs here. (1) M.of walks the table in
-- order, so the flagless rung MUST be last or it swallows every edge.
-- (2) M.RANK *is* that index, so last also means least-trusted. (3) fold.lua
-- packs M.RANK into bits 1-3 of a ref row (fold.lua:353) and decodes by index
-- (fold.lua:141/156), so the order is an encoding too — in-memory only, the
-- fold is rebuilt per store generation, so there is nothing on disk to
-- migrate, but a reorder changes what a rank byte means mid-run. The visible
-- consequence of (1)+(2) is that an UNHEDGED link ranks BELOW the `~`
-- cross-file guess it is stronger than. Nothing reads that comparison in
-- production yet: M.at_least has no caller outside tests/tier_spec.lua. Read
-- CART-0545 before wiring band federation to it and before changing a number
-- here — prising rank apart from position is a design decision, not an edit.
--
-- ★ AND THE TABLE IS FULL. fold.lua's 3-bit rank field encodes 1..7 (0 means
-- "no rank recorded"), and there are exactly 7 rungs. An 8th would pack as
-- 8 and decode as 8 % 8 == 0 — read back as no tier at all. So the insertion
-- points below are one line in THIS file and a widened fold field.
--
-- INSERTION POINTS for the banked tiers — a new rung is
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
    { name = 'stdlib',    flag = 'stdlib' },   -- external stdlib resolution: an
                                               -- explicit `const X = std....` alias
                                               -- (or an active env profile) names
                                               -- the symbol — authoritative (above
                                               -- name-match) but no local def
                                               -- (below the static tiers)
    { name = 'inferred',  flag = 'inferred' }, -- ~ unique-name hypothesis: the
                                               -- workspace-unique CROSS-FILE
                                               -- guess (~10% wrong,
                                               -- [[cartograph-linker]])
    { name = 'matched' },                      -- no flag at all: resolved
                                               -- WITHOUT a hedge (same-file
                                               -- exact binder, or user-pinned).
                                               -- Last because M.of needs the
                                               -- flagless rung last — NOT
                                               -- because it is the weakest.
                                               -- See the ★ note above.
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
--- rule — trust decides, band rank never does). NO PRODUCTION CALLER yet, and
--- it answers the bottom pair the wrong way round today ('inferred' beats
--- 'matched'); CART-0545 owns that decision.
function M.at_least(a, b)
    local ra, rb = M.RANK[a], M.RANK[b]
    return ra ~= nil and rb ~= nil and ra <= rb
end

return M
