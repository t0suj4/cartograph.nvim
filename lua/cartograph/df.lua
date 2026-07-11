-- Dataflow, eager-but-FOLDED. df (per-function statement dataflow:
-- { inputs = {names}, stmts = { {l, def={names}, use={names},
-- dep={{from=si, var=name}}, defr={[di]=tag}?} } }) is the LARGEST foldable
-- datum (~132 MB deep on server as nested tables: every statement is five
-- small tables). The fold collapses it to ONE global columnar store per
-- graph — flat line/offset/count arrays plus name-ref pools — and each
-- node carries an offset+count slice (_df0/_dfn into stmts, _dfi0/_dfin
-- into inputs). Statement VIEWS materialize on demand, shaped exactly like
-- the raw records, so every consumer (witness, trace, lint, clone groups,
-- extract.plan, untangle) reads identically.
--
-- The accessors are DUAL-MODE (folded slice when n._df is set, raw n.df
-- otherwise), so refresh's fresh per-file nodes and un-ingested graphs
-- work unchanged — the argv fold's lifecycle, exactly: fold at ingest,
-- AFTER cache.save encoded the raw form (shards never carry the shared
-- column store), idempotent under re-ingest ([[cartograph-scaling-sharded-index]]).

local M = {}

-- ── dual-mode accessors ──────────────────────────────────────────────────

-- does this node carry (non-empty) dataflow?
function M.has(n)
    if not n then return false end
    if n._df then return n._dfn > 0 end
    return n.df and n.df.stmts and #n.df.stmts > 0 or false
end

-- has a df record at all (may be 0-stmt) — the absent-vs-empty distinction
-- refs.witness needs (a 0-stmt fn still gets a param-only witness; a
-- df-less block/var gets none)
function M.present(n)
    if not n then return false end
    if n._df then return true end
    return n.df and n.df.stmts ~= nil or false
end

-- statement count (the common size query — clone detection, lint)
function M.count(n)
    if not n then return 0 end
    if n._df then return n._dfn end
    return (n.df and n.df.stmts) and #n.df.stmts or 0
end

-- materialize one statement view from the columns (raw-identical shape).
-- Counts are DERIVED (the end-derivation lesson): defs then uses pack
-- contiguously per stmt, so def count = u0[g] - d0[g] and use count =
-- d0[g+1] - u0[g] (sentinel rows close the last stmt); dep/defr likewise.
local function stmt_view(col, g)
    local st = { l = col.l[g], def = {}, use = {}, dep = {} }
    local b, e = col.d0[g], col.u0[g]
    for j = 1, e - b do st.def[j] = col.nm[b + j] end
    b, e = e, col.d0[g + 1]
    for j = 1, e - b do st.use[j] = col.nm[b + j] end
    b, e = col.p0[g], col.p0[g + 1]
    for j = 1, e - b do st.dep[j] = { from = col.depf[b + j], var = col.depv[b + j] } end
    b, e = col.r0[g], col.r0[g + 1]
    if e > b then
        local defr = {}
        for j = 1, e - b do defr[col.rdi[b + j]] = col.rtag[b + j] end
        st.defr = defr
    end
    return st
end

-- the statement list for a node (empty when none), for ipairs iteration.
-- Folded nodes materialize views FRESH per call (transient, raw-shaped).
function M.stmts(n)
    if not n then return {} end
    local col = n._df
    if col then
        local out = {}
        for i = 1, n._dfn do out[i] = stmt_view(col, n._df0 + i) end
        return out
    end
    return (n.df and n.df.stmts) or {}
end

-- the whole df record (for consumers that take it as a PARAM — extract.plan,
-- untangle.analyze): raw-identical { inputs, stmts }, materialized when folded
function M.get(n)
    if not n then return nil end
    local col = n._df
    if col then
        local inputs = {}
        for i = 1, n._dfin do inputs[i] = col.inm[n._dfi0 + i] end
        return { inputs = inputs, stmts = M.stmts(n) }
    end
    return n.df
end

-- ── the fold: nested df records → one columnar store, records dropped ────
-- Columns per stmt: l + THREE offsets (d0 into nm where its defs start,
-- p0 into depf/depv, r0 into rdi/rtag) + u0 (where uses start = where defs
-- end). All counts derive from the NEXT stmt's offsets — stmts are laid
-- down in one global order, so offsets are monotone and a final sentinel
-- row closes the last stmt (end-derivation, the at-fold lesson). Pools:
-- nm (def+use names), depf/depv (LOCAL stmt index + var name), rdi/rtag
-- (sparse defr binder tags, ~6% of stmts), inm (per-node inputs). Name
-- "interning" is Lua's own string interning: columns hold refs.
function M.fold(data)
    if data._dfcol then return 0 end -- already folded (idempotent)
    local col = {
        l = {}, d0 = {}, u0 = {}, p0 = {}, r0 = {},
        nm = {}, depf = {}, depv = {}, rdi = {}, rtag = {}, inm = {},
    }
    local ns, nn, np, nr, ni = 0, 0, 0, 0, 0
    for _, node in ipairs(data.nodes or {}) do
        local df = node.df
        if df and df.stmts and not node._df then
            local s0 = ns
            for _, st in ipairs(df.stmts) do
                ns = ns + 1
                col.l[ns] = st.l
                col.d0[ns] = nn
                for _, d in ipairs(st.def) do nn = nn + 1; col.nm[nn] = d end
                col.u0[ns] = nn
                for _, u in ipairs(st.use) do nn = nn + 1; col.nm[nn] = u end
                col.p0[ns] = np
                for _, dp in ipairs(st.dep or {}) do
                    np = np + 1
                    col.depf[np] = dp.from
                    col.depv[np] = dp.var
                end
                col.r0[ns] = nr
                if st.defr then
                    for di, tag in pairs(st.defr) do
                        nr = nr + 1
                        col.rdi[nr] = di
                        col.rtag[nr] = tag
                    end
                end
            end
            local i0 = ni
            for _, x in ipairs(df.inputs or {}) do
                ni = ni + 1
                col.inm[ni] = x
            end
            node._df = col
            node._df0, node._dfn = s0, ns - s0
            node._dfi0, node._dfin = i0, ni - i0
            node.df = nil -- the nested record, gone
        end
    end
    -- sentinels: close the last stmt's derived counts
    col.d0[ns + 1], col.p0[ns + 1], col.r0[ns + 1] = nn, np, nr
    data._dfcol = col
    return ns
end

return M
