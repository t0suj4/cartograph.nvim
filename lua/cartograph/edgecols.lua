-- EDGECOLS — the RESIDENT columnar EDGE store (record-fold arc; the edge twin of
-- callcols/nodecols). data.edges is the LARGEST record array at scale, and the
-- same lever wins: the scalar fields (from/to/kind/bind + the inferred/self/tinf
-- flags) are ~68-74% of edge resident and columnarize ~12× (self/zig) — from/to
-- are node-id strings that pool hard. The detail rides the residual: `at` (a LIST
-- of ranges, not a single range) and `flds` (the field-access table), plus the
-- SPARSE write-axis ints gw/rw (Lua/PHP only) — kept out of int columns because a
-- fixed-width int column reads 0 for absent, which would conflate with a genuine
-- absence (unlike calls' always-present `line`). This is the PRIMITIVE + its
-- parity gate (tools/edgegate.lua); live wiring + the ints (via a presence bit or
-- bias) are follow-ons, gated the same way. Edges are read-only post-build for the
-- columnarized fields (the two-phase overlay is empty until a live-wiring
-- increment finds a post-ingest edge write — addref's e.at/e.inferred writes are
-- resolution-era, before any store install).

local callcols = require 'cartograph.callcols'

local M = {}

M.EDGE_SYN = {
    strs = { 'from', 'to', 'kind', 'bind' },
    ints = {}, -- gw/rw are sparse (0≡absent ambiguity) → residual; at is a LIST → residual
    flags = { 'self' }, -- parse-fixed (from==to); inferred/tinf are resolution-written
    ranges = {},
}
-- inferred/tinf are WRITTEN post-ingest by addref (refresh re-runs relink →
-- e.inferred=nil / e.tinf=true on existing edges) → mutable overlay. `to` remap
-- (refresh) REBUILDS the edge instead of mutating the immutable column.
M.EDGE_RES = { strs = {}, flags = { 'inferred', 'tinf' } }

-- a full drop-in view of an edge-record list: columnar scalars + a per-row
-- residual (at/flds/gw/rw + lang marks) + proxy row-handles. Mirrors nodecols.view.
function M.view(edges) return callcols.view(edges, M.EDGE_SYN, M.EDGE_RES) end

-- reconstruct edge i's full record (scalar columns + residual)
function M.record(view, i)
    return callcols.record_resid(view.cc, i, view.residual[i])
end

return M
