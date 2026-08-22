-- LSP WIRE positions — the OTHER range representation, and the reason the seam
-- guard cannot tell it from ours.
--
-- An `at` range ([[at.lua]]) and an LSP protocol range are the same SHAPE:
-- `{ start = {…}, ['end'] = {…} }`. They differ in exactly one field name:
--
--     ours   { start = { line = N, char = N      } }   -- at.sc / at.ec
--     wire   { start = { line = N, character = N } }   -- lsppos.sc / lsppos.ec
--
-- ★ AND `.line` IS SPELLED IDENTICALLY, which is the whole problem. The seam
-- guard is a LINE-PATTERN scan (`%.start%.line`), so the one coordinate the two
-- representations share is the only one it can match — it flags every wire read
-- as a raw read of our fold and cannot possibly distinguish them. That is the
-- same defect consumers.lua names for the call-record seam ("a record field like
-- `c.file` is OVERLOADED … so regex can't fence it") and answers with a taint
-- roster; here the answer is cheaper, because the ambiguity is resolvable by
-- NAMING the representation at the read.
--
-- MEASURED, and it is why this is a module rather than an exemption: six reads
-- across four files, and two of them sit LINES away from a read of the other
-- representation --
--   providers/luals.lua:152  `loc.range.start.line` … then `atr.sc(c.at)` on 154
--   dogfood.lua:55           `atr.sl(n.range)` … then `loc.range.start.line` on 58
-- Marking either file an OWNER of the `at` seam would have exempted its real
-- breaches too. A file is the wrong granularity for this distinction; the
-- representation is the right one, so it gets an accessor of its own and THIS
-- file goes in the owner list.
--
-- Nothing here folds: the wire form is short-lived JSON handed back by a language
-- server, never stored. The accessors exist to say WHICH representation is being
-- read, and the seam guard's owner entry for this file is the record of that.

local M = {}

-- start line / start char / end line / end char of a WIRE range
function M.sl(r) return r.start.line end
function M.sc(r) return r.start.character end
function M.el(r) return r['end'].line end
function M.ec(r) return r['end'].character end

--- The range out of a location, whichever form the server sent: a LocationLink
--- (`targetSelectionRange` preferred over `targetRange` — the identifier rather
--- than the whole definition) or a plain Location (`range`). Nil if neither.
--- Open-coded in fieldharvest before this file existed.
function M.range(loc)
    return loc and (loc.targetSelectionRange or loc.targetRange or loc.range)
end

--- The 0-based start line of a location's range, or nil.
function M.line(loc)
    local r = M.range(loc)
    return r and M.sl(r)
end

return M
