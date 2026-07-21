-- CALLCOLS — the RESIDENT columnar call-store (record-fold arc, the store-on-
-- columns endgame). segment.lua is the WIRE form (varint, decode-on-read, small
-- on disk); this is the RESIDENT form (FIXED-WIDTH u32 columns, O(1) indexed
-- reads) — the fold's u32_reader model applied to call records. The encoding-
-- strategy MATRIX (measured) chose it: packed/ffi-u32 columns are BOTH far
-- smaller than record tables AND faster to read (records pay a 26-field hash
-- lookup per access + the per-table overhead; a column is one indexed read + a
-- pool deref). ffi arrays when available, packed byte-strings otherwise — same
-- getter interface (like csr.lua's two backends).
--
-- This first cut is a READ-ONLY snapshot over the segment schema's SCALAR fields
-- (strs pooled → rank column, ints, flags bit-packed, ranges → coord columns).
-- The detail tables (argv/at-table/refused) and the MUTABLE resolution overlay
-- (c.to/conf written DURING resolution) ride separate structures — the two-phase
-- split — added as the store wiring lands. Accessors return the SAME values a
-- record read would (absent str → nil, absent int → 0, flag false → nil).

local csr = require 'cartograph.csr'
local segment = require 'cartograph.segment'

local M = {}

local ok_ffi, ffi = pcall(require, 'ffi')
local char, byte, floor = string.char, string.byte, math.floor

-- a fixed-width u32 column over vals[1..n] → a getter col(i) (1-based). ffi
-- cdata (fastest) or a packed LE-u32 byte string + reader (any Lua). The getter
-- closes over the backing store, keeping it alive.
local function u32col(vals, n)
    if ok_ffi then
        local a = ffi.new('uint32_t[?]', n > 0 and n or 1)
        for i = 1, n do a[i - 1] = vals[i] end
        return function (i) return a[i - 1] end
    end
    local p = {}
    for i = 1, n do
        local x = vals[i]
        p[i] = char(x % 256, floor(x / 256) % 256, floor(x / 65536) % 256,
            floor(x / 16777216) % 256)
    end
    local s = table.concat(p)
    return function (i)
        local q = (i - 1) * 4 + 1
        local a, b, c, d = byte(s, q, q + 3)
        return a + b * 256 + c * 65536 + d * 16777216
    end
end

-- build a column store from a call-record list. `syn` = the SYNTACTIC schema →
-- immutable u32 columns (the resident win); `res` = the RESOLUTION schema → a
-- MUTABLE Lua-array overlay (resolution writes c.to/prov/inferred/… AFTER build,
-- so those cannot be packed) — the two-phase split. Defaults: the call syntactic
-- / resolution schemas. Strings pooled once; each str col is a rank (id+1, 0=absent).
function M.build(calls, syn, res)
    local schema = syn or segment.CALL_SYNTACTIC
    res = res or segment.CALL_RESOLUTION
    local n = #calls
    local it = csr.interner()
    local cc = { n = n, schema = schema, str = {}, int = {}, rng = {} }
    for _, f in ipairs(schema.strs) do
        local ranks = {}
        for i = 1, n do
            local v = calls[i][f]
            ranks[i] = (type(v) == 'string') and it.id(v) + 1 or 0
        end
        cc.str[f] = u32col(ranks, n)
    end
    cc.pool = it.list -- pool[rank] = the string (rank = id + 1, list is 1-based)
    for _, f in ipairs(schema.ints or {}) do
        local vals = {}
        for i = 1, n do vals[i] = calls[i][f] or 0 end
        cc.int[f] = u32col(vals, n)
    end
    if schema.flags and #schema.flags > 0 then
        local vals = {}
        for i = 1, n do
            local b = 0
            for j, f in ipairs(schema.flags) do
                if calls[i][f] then b = b + 2 ^ (j - 1) end
            end
            vals[i] = b
        end
        cc.flagcol, cc.flags = u32col(vals, n), schema.flags
    end
    for _, rf in ipairs(schema.ranges or {}) do
        local p, sl, sc, el, ec = {}, {}, {}, {}, {}
        for i = 1, n do
            local r = calls[i][rf]
            if type(r) == 'table' and r.start and r['end'] then
                p[i] = 1
                sl[i] = r.start.line or 0; sc[i] = r.start.char or 0
                el[i] = r['end'].line or 0; ec[i] = r['end'].char or 0
            else
                p[i], sl[i], sc[i], el[i], ec[i] = 0, 0, 0, 0, 0
            end
        end
        cc.rng[rf] = { pres = u32col(p, n), sl = u32col(sl, n), sc = u32col(sc, n),
            el = u32col(el, n), ec = u32col(ec, n) }
    end
    -- the MUTABLE resolution overlay: a plain Lua array per field (str value or
    -- nil / flag true or nil), seeded from the calls and WRITABLE by resolution.
    -- A field appearing here is looked up here first (M.get), so writes win.
    cc.isflag = {}
    for _, f in ipairs(schema.flags or {}) do cc.isflag[f] = true end
    cc.res, cc.mut, cc.resf = res, {}, {}
    for _, f in ipairs(res.strs or {}) do
        local a = {}
        for i = 1, n do local v = calls[i][f]; a[i] = type(v) == 'string' and v or nil end
        cc.mut[f] = a; cc.resf[f] = true
    end
    for _, f in ipairs(res.flags or {}) do
        local a = {}
        for i = 1, n do a[i] = calls[i][f] and true or nil end
        cc.mut[f] = a; cc.resf[f] = true
    end
    return cc
end

-- ── field accessors (0 rank / absent → the record's falsy value) ──────────
function M.str(cc, f, i) local r = cc.str[f](i); return r > 0 and cc.pool[r] or nil end
function M.int(cc, f, i) return cc.int[f](i) end
function M.flag(cc, f, i)
    local j
    for k, name in ipairs(cc.flags) do if name == f then j = k break end end
    if not j then return nil end
    return floor(cc.flagcol(i) / 2 ^ (j - 1)) % 2 == 1 or nil
end
function M.range(cc, rf, i)
    local r = cc.rng[rf]
    if r.pres(i) ~= 1 then return nil end
    return { start = { line = r.sl(i), char = r.sc(i) },
        ['end'] = { line = r.el(i), char = r.ec(i) } }
end

-- generic read: an overlay (resolution) field wins, else the right column. The
-- accessor a consumer calls — the same value a `c.field` record read gives.
function M.get(cc, f, i)
    if cc.resf[f] then return cc.mut[f][i] end
    if cc.str[f] then return M.str(cc, f, i) end
    if cc.int[f] then return M.int(cc, f, i) end
    if cc.rng[f] then return M.range(cc, f, i) end
    if cc.isflag and cc.isflag[f] then return M.flag(cc, f, i) end
    return nil
end

-- WRITE a resolution-era field (the only mutable ones — the immutable syntactic
-- columns error, catching a bug where resolution tries to rewrite a parse fact)
function M.set(cc, f, i, v)
    assert(cc.resf[f], 'callcols: field is not a mutable resolution field: ' .. tostring(f))
    cc.mut[f][i] = v ~= nil and v or nil
end

-- reconstruct a call's full record (syntactic columns + resolution overlay) —
-- for parity checks / a full read
function M.record(cc, i)
    local s, out = cc.schema, {}
    for _, f in ipairs(s.strs) do out[f] = M.str(cc, f, i) end
    for _, f in ipairs(s.ints or {}) do out[f] = M.int(cc, f, i) end
    for _, f in ipairs(s.flags or {}) do if M.flag(cc, f, i) then out[f] = true end end
    for _, rf in ipairs(s.ranges or {}) do out[rf] = M.range(cc, rf, i) end
    for _, f in ipairs(cc.res.strs or {}) do if cc.mut[f][i] then out[f] = cc.mut[f][i] end end
    for _, f in ipairs(cc.res.flags or {}) do if cc.mut[f][i] then out[f] = true end end
    return out
end

-- the set of fields this store's columns/overlay COVER (schema union). Any
-- record field outside this rides the residual (M.view) — the honest coverage
-- boundary the parity gate discloses.
function M.covered(cc)
    local set = {}
    for _, f in ipairs(cc.schema.strs) do set[f] = true end
    for _, f in ipairs(cc.schema.ints or {}) do set[f] = true end
    for _, f in ipairs(cc.schema.flags or {}) do set[f] = true end
    for _, rf in ipairs(cc.schema.ranges or {}) do set[rf] = true end
    for _, f in ipairs(cc.res.strs or {}) do set[f] = true end
    for _, f in ipairs(cc.res.flags or {}) do set[f] = true end
    return set
end

-- ── the COMPAT ACCESS MODEL — a proxy row-handle ─────────────────────────
-- brick 3's transparent path: a call becomes a proxy whose __index routes a
-- COVERED field to its column/overlay and everything else to a per-row RESIDUAL
-- table; __newindex routes a resolution write to the overlay (via M.set) and any
-- other write to the residual. So a consumer that reads `c.file` (seamed) OR
-- `c.strarg`/`c.at`/`c.argv` (not yet columnar) OR writes `c.to = …` (raw, e.g.
-- xlang) works UNCHANGED — the columns carry what they cover, the residual the
-- rest. This is the access model the micro-matrix ([[access-model]]) weighs
-- against index-based; it is the safe default because it needs no consumer edit.
local row_mt = {
    __index = function (self, k)
        local st = rawget(self, '__cc')
        if st.cov[k] then return M.get(st.cc, k, st.i) end
        local r = st.res
        return r and r[k] or nil
    end,
    __newindex = function (self, k, v)
        local st = rawget(self, '__cc')
        if st.cc.resf[k] then M.set(st.cc, k, st.i, v); return end
        -- a write to a covered IMMUTABLE (syntactic) column is a resolver bug —
        -- surface it, same as M.set's assert (parse facts are never rewritten)
        assert(not st.cov[k], 'callcols: write to immutable syntactic field: ' .. tostring(k))
        local r = st.res
        if not r then r = {}; st.res = r end
        r[k] = v
    end,
}

-- a proxy row-handle over store `cc` at index `i`, backed by `residual` (the
-- per-row table of non-columnar fields, or nil). Cheap to mint; holds no data
-- of its own beyond the (cc,i,residual) triple. `cov` (the covered-field set)
-- may be passed in to avoid recomputing it per row (M.view does).
function M.row(cc, i, residual, cov)
    return setmetatable({ __cc = { cc = cc, i = i, res = residual, cov = cov or M.covered(cc) } }, row_mt)
end

-- a full DROP-IN VIEW of a call-record list: the columnar store + a residual
-- table per row (record fields the columns don't cover — detail tables argv/at/
-- refused, plus lang-specific marks) + a row-handle array. `data.calls = view.rows`
-- is behaviourally identical to the record list (the parity gate's contract),
-- while the heavy syntactic fields live in u32 columns. `keep` optionally holds
-- extra covered fields out of the residual (unused today; the schema covers them).
function M.view(calls, syn, res)
    local cc = M.build(calls, syn, res)
    local cov = M.covered(cc)
    local residual, rows = {}, {}
    for i = 1, #calls do
        local extra
        for k, v in pairs(calls[i]) do
            if not cov[k] then extra = extra or {}; extra[k] = v end
        end
        residual[i] = extra
        rows[i] = M.row(cc, i, extra, cov)
    end
    return { cc = cc, residual = residual, rows = rows, covered = cov }
end

return M
