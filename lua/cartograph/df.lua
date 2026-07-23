-- Dataflow, eager-but-FOLDED. Since df-strangler step 6 df is a COARSE
-- PROJECTION of flow (flow.coarse, derived at extract — no separate build);
-- this module is now just its columnar storage + read API. df
-- (per-function statement dataflow:
-- { inputs = {names}, stmts = { {l, def={names}, use={names},
-- dep={{from=si, var=name}}} } }) is the LARGEST foldable
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

-- shared serializable width columns (u8/u16/u32 { s, w }); flow uses the same module.
local bytecol = require 'cartograph.bytecol'
local packcol, rd = bytecol.packcol, bytecol.rd

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


-- the statement list for a node (empty when none), for ipairs iteration.
-- Folded nodes materialize views FRESH per call (transient, raw-shaped).
-- Offsets ROLL across consecutive stmts (each boundary decoded once): for
-- the common small statement the offset reads dominate the element reads.
function M.stmts(n)
    if not n then return {} end
    local col = n._df
    if col then
        local out = {}
        local nms = col.names
        local g = n._df0
        local d1 = rd(col.d0, g + 1)
        local p1 = rd(col.p0, g + 1)
        for i = 1, n._dfn do
            g = g + 1
            local d0, p0 = d1, p1
            d1, p1 = rd(col.d0, g + 1), rd(col.p0, g + 1)
            local st = { l = rd(col.l, g), def = {}, use = {}, dep = {} }
            local u0 = rd(col.u0, g)
            for j = 1, u0 - d0 do st.def[j] = nms[rd(col.nm, d0 + j)] end
            for j = 1, d1 - u0 do st.use[j] = nms[rd(col.nm, u0 + j)] end
            for j = 1, p1 - p0 do
                st.dep[j] = { from = rd(col.depf, p0 + j), var = nms[rd(col.depv, p0 + j)] }
            end
            out[i] = st
        end
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
        for i = 1, n._dfin do inputs[i] = col.names[rd(col.inm, n._dfi0 + i)] end
        return { inputs = inputs, stmts = M.stmts(n) }
    end
    return n.df
end

-- ── the fold: nested df records → one columnar store, records dropped ────
-- Columns per stmt: l + TWO offsets (d0 into nm where its defs start,
-- p0 into depf/depv) + u0 (where uses start = where defs end). All counts
-- derive from the NEXT stmt's offsets — stmts are laid down in one global
-- order, so offsets are monotone and a final sentinel row closes the last
-- stmt (end-derivation, the at-fold lesson). Pools: nm (def+use names),
-- depf/depv (LOCAL stmt index + var name), inm (per-node inputs). Name
-- "interning" is Lua's own string interning: columns hold refs.
-- The fold as an ACCUMULATOR: add(nodes) folds a batch of nodes' df into the growing
-- columnar state; finalize() packs it and stamps _df on the folded nodes. M.fold is
-- add(all-nodes)+finalize (whole-graph, inline/ingest); the PARALLEL merge calls add() per
-- CHUNK so the parent never holds all the fat df at once (the merge-peak lever). Byte-
-- identical to one whole-graph fold: ONE shared interner + monotone global offsets, so
-- chunk order is the only difference and the fileset-ordered merge fixes that.
function M.accumulator()
    local col = {
        l = {}, d0 = {}, u0 = {}, p0 = {},
        nm = {}, depf = {}, depv = {}, inm = {},
        names = {},
    }
    local nid = {} -- name -> interned id (build-time only)
    local function id(nm)
        local i = nid[nm]
        if not i then
            i = #col.names + 1
            col.names[i] = nm
            nid[nm] = i
        end
        return i
    end
    local ns, nn, np, ni = 0, 0, 0, 0
    local folded = {} -- nodes folded here → stamp _df at finalize
    local A = {}
    function A.add(nodes)
        for _, node in ipairs(nodes or {}) do
            local df = node.df
            if df and df.stmts and not node._df then
                local s0 = ns
                for _, st in ipairs(df.stmts) do
                    ns = ns + 1
                    col.l[ns] = st.l
                    col.d0[ns] = nn
                    for _, d in ipairs(st.def) do nn = nn + 1; col.nm[nn] = id(d) end
                    col.u0[ns] = nn
                    for _, u in ipairs(st.use) do nn = nn + 1; col.nm[nn] = id(u) end
                    col.p0[ns] = np
                    for _, dp in ipairs(st.dep or {}) do
                        np = np + 1
                        col.depf[np] = dp.from
                        col.depv[np] = id(dp.var)
                    end
                end
                local i0 = ni
                for _, x in ipairs(df.inputs or {}) do
                    ni = ni + 1
                    col.inm[ni] = id(x)
                end
                node._df0, node._dfn = s0, ns - s0
                node._dfi0, node._dfin = i0, ni - i0
                node.df = nil -- the nested record, gone
                folded[#folded + 1] = node
            end
        end
    end
    function A.finalize()
        col.d0[ns + 1], col.p0[ns + 1] = nn, np -- sentinels close the last stmt's counts
        local packed = {
            l = packcol(col.l, ns),
            d0 = packcol(col.d0, ns + 1),
            u0 = packcol(col.u0, ns),
            p0 = packcol(col.p0, ns + 1),
            nm = packcol(col.nm, nn),
            depf = packcol(col.depf, np),
            depv = packcol(col.depv, np),
            inm = packcol(col.inm, ni),
            names = col.names,
        }
        for _, node in ipairs(folded) do node._df = packed end
        return packed, ns
    end
    return A
end

-- fold the WHOLE graph (inline extract / ingest): add all nodes, finalize.
-- Idempotent AND multi-store-safe via the data._dfcol guard: the FIRST fold folds every
-- raw node into the whole-graph store (fallback/demand stragglers included) and stamps it;
-- every later call is a true no-op, so refresh's fresh RAW nodes stay raw (read via the
-- dual-mode accessors) rather than being re-folded onto a new store. In the worker-fold
-- path data._dfcol starts nil, so this proceeds once (folds the raw stragglers, leaves the
-- worker-folded nodes on their own per-chunk stores — add() skips any node with _df set).
function M.fold(data)
    if data._dfcol then return 0 end -- already folded (whole-graph store)
    local a = M.accumulator()
    a.add(data.nodes or {})
    local packed, ns = a.finalize()
    data._dfcol = packed
    return ns
end

-- ── multi-store IPC: detach / attach (worker fold-emit, [[cartograph-thin-index]]) ──
-- After a fold every folded node holds n._df = the ONE store (a ref). Serializing that
-- per node DUPLICATES the store — string.buffer.encode does not dedup shared refs (the
-- same bug fix A killed for the disk cache). So a worker that ships a FOLDED chunk DETACHes
-- first: drop the per-node ref, keep the offsets (_df0/_dfn/_dfi0/_dfin), and let the store
-- ride ONCE as data._dfcol. The parent ATTACHes on receipt — re-hangs that one store on
-- every folded node — before any df read. A folded node is marked by _df0 (set even at 0
-- stmts); raw / df-less nodes have none and are skipped, so both are no-ops on a raw chunk.
function M.detach(data)
    if not data._dfcol then return end
    for _, n in ipairs(data.nodes or {}) do n._df = nil end
end
function M.attach(data)
    local store = data._dfcol
    if not store then return end
    for _, n in ipairs(data.nodes or {}) do
        if n._df0 ~= nil then n._df = store end
    end
end

return M
