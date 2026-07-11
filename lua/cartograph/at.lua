-- Range-coordinate SEAM for occurrence `at` ranges (call sites, edge
-- occurrences). Consumers read coordinates through sl/sc/el/ec instead of
-- reaching into `.start.line` / `['end'].char`, so the banked at fold
-- (columnar start-coords + derived end, [[cartograph-scaling-sharded-index]])
-- becomes a ONE-PLACE swap here — not a migration of every reader. This is
-- the API-first discipline applied ahead of the fold: seam now (behavior-
-- identical, a range is still a nested table), swap the representation
-- later (a range becomes a fold index; these accessors dispatch on type
-- and the end-derivation lands with the fold).
--
-- Scope: OCCURRENCE ranges only (the foldable 100 MB — c.at / e.at). Node
-- ranges (n.range, kept for navigation) are NOT routed here; they stay
-- nested tables and are read directly.

local M = {}

-- start line / start char / end line / end char of an occurrence range
function M.sl(r) return r.start.line end
function M.sc(r) return r.start.char end
function M.el(r) return r['end'].line end
function M.ec(r) return r['end'].char end

-- whether the range is single-line (the common token case)
function M.oneline(r) return r.start.line == r['end'].line end

return M
