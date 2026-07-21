-- Call-record field ACCESSORS — the read seam over data.calls records
-- (record-fold arc step 2, [[cartograph-record-fold-arc]]). Today these are
-- IDENTITY passthroughs (return c.field); their sole job is to be the single
-- place a reader touches a call's core fields, so step 3 can fold those fields
-- into columns behind them WITHOUT touching any consumer — exactly the dual-
-- mode swap at.lua/argv.lua/df.lua already made for the detail fields (c.at/
-- c.argv/df). Reads only: resolution WRITES (c.to = …, c.refused = …) stay
-- direct on the record — they are the producer's concern (step 4), and the
-- syntactic-vs-resolution-era split lives there, not here.
--
-- Field set = the SYNTACTIC, IMMUTABLE call fields — the only fold candidates.
-- (Resolution-era fields c.to/c.refused/c.conf/c.inferred are MUTATED post-
-- ingest by resolve/confirm, so they can't fold into an immutable column and
-- are deliberately NOT seamed here.) The string fields (fn/callee/file/full)
-- are the fold-worthy weight — node-id / path strings repeated per call; line
-- is the one scalar. THE SEAM MUST BE COMPLETE PER FIELD: step 3 can only fold
-- a field once EVERY reader goes through its accessor (a raw reader left behind
-- would see the index instead of the value). So migration proceeds field-by-
-- field to completion, not file-by-file.

local M = {}

-- the enclosing function's node id (syntactic, immutable; nil at top level)
function M.fn(c) return c.fn end
-- the called name as written (syntactic, immutable)
function M.callee(c) return c.callee end
-- the fully-qualified callee, when the spec built one (syntactic, immutable)
function M.full(c) return c.full end
-- the method segment of a method call (syntactic, immutable)
function M.method(c) return c.method end
-- the file the call sits in (syntactic, immutable — highest fold dedup)
function M.file(c) return c.file end
-- the 0-based line of the call site (syntactic, immutable scalar)
function M.line(c) return c.line end

return M
