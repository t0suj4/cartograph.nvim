-- Dataflow accessor SEAM, ahead of the df fold. df (per-function
-- statement dataflow: stmts = { {l, def={names}, use={names}, dep={…}}, … })
-- is the LARGEST foldable datum (~84.5 MB on server) — kept eager because
-- algorithmic tracing is hot, but banked as eager-but-FOLDED (columnar
-- stmt store + interned def/use/dep) when wow-scale bites
-- ([[cartograph-scaling-sharded-index]]). Consumers read df through here
-- so that fold is a one-place swap, not a 7-file migration.
--
-- Today df is a nested table (accessors return it directly, zero cost).
-- Later a node carries an offset+count into columns and `stmts` materializes
-- a statement-view list — the accessors are the swap point. The loop shape
-- consumers use, `for _, s in ipairs(df.stmts(node))`, is preserved.

local M = {}

-- does this node carry (non-empty) dataflow?
function M.has(n) return n and n.df and n.df.stmts and #n.df.stmts > 0 or false end

-- the statement list for a node (empty when none), for ipairs iteration
function M.stmts(n)
    return (n and n.df and n.df.stmts) or {}
end

-- statement count (the common size query — clone detection, lint)
function M.count(n)
    return (n and n.df and n.df.stmts) and #n.df.stmts or 0
end

-- has a stmts FIELD at all (may be empty) — the absent-vs-empty
-- distinction refs.witness needs (a 0-stmt fn still gets a param-only
-- witness; a df-less block/var gets none)
function M.present(n) return n and n.df and n.df.stmts ~= nil or false end

-- the raw df record (for consumers that pass it whole — extract-fn verb)
function M.get(n) return n and n.df or nil end

return M
