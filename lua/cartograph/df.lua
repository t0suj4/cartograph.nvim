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

local char, byte, concat = string.char, string.byte, table.concat

-- DYNAMIC-WIDTH packed column (u16 where values fit, u32 otherwise — matching
-- flow/callcols; df was the fixed-u32 outlier, ~40-50% overhead on its name-id
-- columns whose pools are < 65536). A column is plain data { s = byte-string, w = 2|4 },
-- not a closure — so the folded store SERIALIZES (the cache round-trips the folded form).
local function pack(arr, len, w)
    local parts = {}
    if w == 1 then
        for i = 1, len do parts[i] = char(arr[i] % 256) end
    elseif w == 2 then
        for i = 1, len do local v = arr[i]; parts[i] = char(v % 256, (v - v % 256) / 256 % 256) end
    else
        for i = 1, len do
            local v = arr[i]
            local lo = v % 65536
            parts[i] = char(lo % 256, (lo - lo % 256) / 256,
                (v - v % 65536) / 65536 % 256, (v - v % 16777216) / 16777216 % 256)
        end
    end
    return concat(parts)
end
-- 3-tier width (u8/u16/u32), matching callcols — df was 2-tier (missed u8 on small cols).
local function width_for(maxv) return maxv < 256 and 1 or (maxv < 65536 and 2 or 4) end
-- pack an array, auto-selecting width from its max value → { s, w }.
local function packcol(arr, len)
    local mx = 0
    for i = 1, len do if arr[i] > mx then mx = arr[i] end end
    local w = width_for(mx)
    return { s = pack(arr, len, w), w = w }
end
-- read a 1-based value from a { s, w } column (u16 or u32). One reader, all columns.
local function rd(c, i)
    local s, w = c.s, c.w
    if w == 1 then return byte(s, i) end
    if w == 2 then
        local p = (i - 1) * 2 + 1
        local a, b = byte(s, p, p + 1)
        return a + b * 256
    end
    local p = (i - 1) * 4 + 1
    local a, b, cc, d = byte(s, p, p + 3)
    return a + b * 256 + cc * 65536 + d * 16777216
end

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
-- d0[g+1] - u0[g] (sentinel rows close the last stmt); dep likewise.
local function stmt_view(col, g)
    local nms = col.names
    local st = { l = rd(col.l, g), def = {}, use = {}, dep = {} }
    local b, e = rd(col.d0, g), rd(col.u0, g)
    for j = 1, e - b do st.def[j] = nms[rd(col.nm, b + j)] end
    b, e = e, rd(col.d0, g + 1)
    for j = 1, e - b do st.use[j] = nms[rd(col.nm, b + j)] end
    b, e = rd(col.p0, g), rd(col.p0, g + 1)
    for j = 1, e - b do
        st.dep[j] = { from = rd(col.depf, b + j), var = nms[rd(col.depv, b + j)] }
    end
    return st
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
function M.fold(data)
    if data._dfcol then return 0 end -- already folded (idempotent)
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
    for _, node in ipairs(data.nodes or {}) do
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
            node._df = col
            node._df0, node._dfn = s0, ns - s0
            node._dfi0, node._dfin = i0, ni - i0
            node.df = nil -- the nested record, gone
        end
    end
    -- sentinels: close the last stmt's derived counts
    col.d0[ns + 1], col.p0[ns + 1] = nn, np
    -- pack: number arrays -> LE-u32 byte strings; name pools -> id columns
    -- over ONE interned names array (Lua interning made repeats free as
    -- refs; the id column makes them free as 4 BYTES)
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
    for _, node in ipairs(data.nodes or {}) do
        if node._df == col then node._df = packed end
    end
    data._dfcol = packed
    return ns
end

return M
