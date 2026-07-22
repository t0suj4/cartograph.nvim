-- NODECOLS — the RESIDENT columnar NODE store (record-fold arc; the node twin of
-- callcols). data.nodes is the other fat record array (with data.calls/edges);
-- remeasuring the deferred node-columnar arc after callcols landed showed the same
-- lever wins: the SCALAR fields (id/name/kind/file/order/flags/range) are ~63-77%
-- of node resident and columnarize 4.8-5.6× (self/zig) via callcols' width-
-- autoselect + pool. The TABLE detail (df/flow/params/data/pw/locals) rides the
-- residual — those fold separately at ingest (df.fold/flow.fold), exactly as argv
-- did for calls. This is the PRIMITIVE + its parity gate (tools/nodegate.lua); the
-- live wiring (consumers by_id/by_file/LSP through the store, + the id-drop
-- corollary — reconstruct file::name@line via the registry instead of pooling the
-- unique id, another ~37%) are follow-ons, gated the same way.
--
-- Nodes are (today) READ-ONLY post-build for the fields we columnarize, so the
-- overlay is empty: all scalars are immutable columns. When a live-wiring
-- increment finds a post-ingest node write, that field moves to the resolution
-- (mutable) overlay — the same two-phase split callcols/rescols use.

local callcols = require 'cartograph.callcols'

local M = {}

-- SCALAR node fields → immutable columns (the resident win). Everything else on a
-- node (the detail TABLES df/flow/params/data/pw/locals + any lang-specific mark)
-- rides the residual, reference-faithful. ctype/ret are rare (absent → nil).
-- NOTE: `order` is NOT columnarized — it is -1 for module/unparsed nodes, and the
-- width columns are UNSIGNED (u8/u16 would wrap a negative). It rides the residual
-- (raw int, faithful). A signed/biased int column is a follow-on if it matters.
M.NODE_SYN = {
    strs = { 'id', 'name', 'kind', 'file', 'ctype', 'ret' },
    ints = {},
    flags = { 'arrow', 'cbarg', 'decl', 'effects', 'entry', 'exported',
        'macro', 'top', 'torn', 'unparsed' },
    ranges = { 'range' },
}
M.NODE_RES = { strs = {}, flags = {} } -- no mutable node fields yet (foundation)

-- a full drop-in view of a node-record list: columnar scalars + a per-row residual
-- (the table detail) + proxy row-handles. view.rows[i] reads identically to
-- data.nodes[i]. Mirrors callcols.view / rescols.view.
function M.view(nodes) return callcols.view(nodes, M.NODE_SYN, M.NODE_RES) end

-- reconstruct node i's full record (scalar columns + residual tables)
function M.record(view, i)
    local out = callcols.record(view.cc, i)
    local resid = view.residual[i]
    if resid then for k, v in pairs(resid) do out[k] = v end end
    return out
end

return M
