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

-- ══ THE TWO ABSENCE AXES ═══════════════════════════════════════════════════
-- The ladder above grades a POSITIVE answer. Neither axis below is a rung on
-- it, and neither is comparable with it: `M.LADDER` is FULL (fold.lua packs a
-- 3-bit rank, 7 rungs, an 8th decodes as none) and a negative is a different
-- question. runtime-topology/02 says it in one line — "Not a new rung — a
-- second field."
--
-- ★★★ THERE ARE TWO QUESTIONS, NOT ONE, and merging them is the confusion this
-- exists to kill:
--   READING      why is the GRAPH silent here?      (did we look, and how well)
--   OBSERVATION  why did we not SEE IT HAPPEN?      (did anything watch, and for
--                                                    how long)
-- A plain static answer is `absent` on the first and `unprobed` on the second,
-- simultaneously. One enum could not say that.
--
-- ⚠ AND `absence` WAS ALREADY TAKEN. The shipped agent envelope (agent.lua:17)
-- calls the READING axis `absence`, and the design's prose for the OBSERVATION
-- axis also writes "absence: unprobed". Same word, two axes — the same
-- collision runtime-topology/README warns about for `torn` ("a different idea
-- wearing the same word"). So the observation field is `warrant` end to end.
--
-- ★★ A LICENSE IS AN UPPER BOUND, NEVER A FLOOR. `licenses` says the MOST a
-- consumer may do with this negative; a consumer whose world is open may only
-- weaken it. The k8s design already makes that call in its own orphan table — a
-- Service whose selector matches no Pods is tiered `~`, "flag, surface, never
-- auto-delete", because an overlay or an operator may still supply it — while
-- runtime-topology's thesis says why source differs: "over parsed source,
-- absence is near-complete". Same warrant, different claim scope.

--- THE READING AXIS: why the graph is silent. SHIPPED in agent.lua since
--- CART-0581 — as a sentence in a comment, enforced by nothing, so a verb
--- returning `absence = 'banana'` passed the invariant check. A table here is
--- what makes the set checkable, and puts it where tiers live.
M.ABSENCE = {
    -- the reading was COMPLETE and found nothing. The only one that licenses
    -- acting, and only where the world is closed (see the upper-bound rule).
    { name = 'absent',      licenses = 'act' },
    -- a rule declined to draw the edge: the graph SPEAKS about this
    { name = 'refused',     licenses = 'nothing' },
    -- the region was never analysed (no parser, unparsed file, outside the root)
    { name = 'frontier',    licenses = 'nothing' },
    -- the DATA CLASS was never extracted (a thin index, calls not materialised)
    { name = 'unavailable', licenses = 'nothing' },
}

--- THE OBSERVATION AXIS: why we did not see it happen. Not built anywhere yet —
--- this is runtime-topology/02's table, landed as Phase 0 ("settle the absence
--- warrant, with no collector at all"), because it is the only phase whose cost
--- RISES with delay: every consumer written before it invents its own words.
--- Three already had (tools/grpcjoin, tools/otelobserve, cartograph/k8s).
M.WARRANT = {
    -- ★ THE STRONGEST NEGATIVE IS NOT MADE BY WATCHING. A declaration the
    -- substrate ENFORCES (an RBAC denial, a NetworkPolicy, a Kafka ACL) says the
    -- edge cannot exist — a fact no amount of observation could establish.
    { name = 'proven-forbidden', licenses = 'act' },
    -- observed continuously for a window W and never seen: a `~` finding
    { name = 'absent-in-window', licenses = 'flag' },
    -- the window was shorter than the edge's period, or the collector cannot
    -- see this protocol
    { name = 'unsampled',        licenses = 'nothing' },
    -- ★ THE DEFAULT, and it is ALREADY TRUE OF EVERY STATIC ANSWER TODAY —
    -- merely unsaid. No observation was attempted.
    { name = 'unprobed',         licenses = 'nothing' },
    -- probing was attempted and REFUSED (no credential, no egress, policy): a
    -- located finding with a NAMED CAUSE, which is why it is not `unsampled`
    { name = 'dark',             licenses = 'nothing' },
}

M.WARRANT_DEFAULT = 'unprobed'

local function index(list)
    local by = {}
    for i, r in ipairs(list) do by[r.name] = { i = i, licenses = r.licenses } end
    return by
end
local ABS_BY, WAR_BY = index(M.ABSENCE), index(M.WARRANT)

--- Is `name` a declared reading-absence kind?
function M.is_absence(name) return ABS_BY[name] ~= nil end
--- Is `name` a declared observation warrant?
function M.is_warrant(name) return WAR_BY[name] ~= nil end

--- The MOST a consumer may do with this negative: 'act' | 'flag' | 'nothing',
--- or nil when the name is not a declared absence or warrant. ⚠ An upper bound:
--- a consumer may weaken it and must never raise it.
function M.licenses(name)
    local r = ABS_BY[name] or WAR_BY[name]
    return r and r.licenses or nil
end

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
