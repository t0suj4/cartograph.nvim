-- CALLCOLS — the RESIDENT columnar call-store (record-fold arc, the store-on-
-- columns endgame). segment.lua is the WIRE form (varint, decode-on-read, small
-- on disk); this is the RESIDENT form (FIXED-WIDTH columns, O(1) indexed reads)
-- — the fold's u32_reader model applied to call records. The encoding-strategy
-- MATRIX (measured) chose it: packed/ffi columns are BOTH far smaller than record
-- tables AND faster to read (records pay a 26-field hash lookup per access + the
-- per-table overhead; a column is one indexed read + a pool deref). ffi arrays
-- when available, packed byte-strings otherwise — same getter interface (like
-- csr.lua's two backends).
--
-- Each column picks its NARROWEST fixed width (u8/u16/u32) from its own max value
-- (widthcol): most columns are far under u32 — empty receiver/chain fields → u8,
-- ranks/lines → u16 — so this is ~2.4× smaller than a flat u32 with the SAME O(1)
-- getter (the width is private to the closure; consumers are width-agnostic). The
-- columns are IMMUTABLE (built once from parse-fixed data + the resolution snapshot
-- at build time), so the pool is complete and each width is FINAL — no upgrade
-- path is needed here. The measurement is scoped to the RESIDENT store; the WIRE
-- form (segment.lua) uses freq-ordered varint independently.
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

-- a fixed-width column over vals[1..n] (non-negative ints) → a getter col(i)
-- (1-based). The width is chosen PER COLUMN from its max value: u8 (<256),
-- u16 (<65536), else u32. ffi cdata (fastest) or a packed LE byte string +
-- reader (any Lua) — same getter interface either way. The getter closes over
-- the backing store (and its width), keeping it alive; consumers never see the
-- width. Immutable column → the width is final at build.
local function widthcol(vals, n)
    local mx = 0
    for i = 1, n do local v = vals[i]; if v > mx then mx = v end end
    local w = mx < 256 and 1 or (mx < 65536 and 2 or 4)
    if ok_ffi then
        local ctype = (w == 1 and 'uint8_t[?]') or (w == 2 and 'uint16_t[?]') or 'uint32_t[?]'
        local a = ffi.new(ctype, n > 0 and n or 1)
        for i = 1, n do a[i - 1] = vals[i] end
        return function (i) return a[i - 1] end
    end
    local p = {}
    if w == 1 then
        for i = 1, n do p[i] = char(vals[i] % 256) end
    elseif w == 2 then
        for i = 1, n do local x = vals[i]; p[i] = char(x % 256, floor(x / 256) % 256) end
    else
        for i = 1, n do
            local x = vals[i]
            p[i] = char(x % 256, floor(x / 256) % 256, floor(x / 65536) % 256,
                floor(x / 16777216) % 256)
        end
    end
    local s = table.concat(p)
    if w == 1 then
        return function (i) return byte(s, i) end
    elseif w == 2 then
        return function (i) local q = (i - 1) * 2 + 1; local a, b = byte(s, q, q + 1); return a + b * 256 end
    end
    return function (i)
        local q = (i - 1) * 4 + 1
        local a, b, c, d = byte(s, q, q + 3)
        return a + b * 256 + c * 65536 + d * 16777216
    end
end

-- ── MUTABLE columns (the resolution overlay) ──────────────────────────────
-- Resolution writes to/full/prov/inferred/… AFTER build, so these can't be
-- immutable columns. They are still COLUMNAR (the resident win) — ffi-backed,
-- mutable in place — with a plain-Lua fallback (correct, no win) where ffi is
-- absent. A str field grows a per-field interner as resolution mints new ids; if
-- a rank overflows the column width it REBUILDS one width wider (rare — pools
-- stay <65536 to ~59k calls). Flags pack into ONE bit column (bit j = flag j).
local function width_for(mx) return mx < 256 and 1 or (mx < 65536 and 2 or 4) end
local function ffi_arr(w, n)
    local ct = (w == 1 and 'uint8_t[?]') or (w == 2 and 'uint16_t[?]') or 'uint32_t[?]'
    return ffi.new(ct, n > 0 and n or 1)
end

-- mutable str column: { it, a, w, cap, n }. a = ffi width array (0-based) or,
-- without ffi, a plain Lua rank array (1-based). rank = id+1 (0 = absent).
local function mutstr_new(it, ranks, n, mx)
    local w = width_for(mx)
    local ms = { it = it, n = n, w = w, cap = 2 ^ (w * 8) }
    if ok_ffi then
        local a = ffi_arr(w, n)
        for i = 1, n do a[i - 1] = ranks[i] end
        ms.a = a
    else
        ms.a = ranks
    end
    return ms
end
local function mutstr_get(ms, i)
    local r = ok_ffi and ms.a[i - 1] or ms.a[i]
    if not r or r == 0 then return nil end
    return ms.it.list[r]
end
local function mutstr_set(ms, i, v)
    if v == nil then
        if ok_ffi then ms.a[i - 1] = 0 else ms.a[i] = nil end
        return
    end
    local rank = ms.it.id(v) + 1
    if ok_ffi then
        if rank >= ms.cap then -- REBUILD one width wider (rare)
            local neww = width_for(rank)
            local na = ffi_arr(neww, ms.n)
            for k = 0, ms.n - 1 do na[k] = ms.a[k] end
            ms.a, ms.w, ms.cap = na, neww, 2 ^ (neww * 8)
        end
        ms.a[i - 1] = rank
    else
        ms.a[i] = rank
    end
end

-- mutable flag column: one bit-packed int per call (bit = mflagbit[f]); ffi
-- u8/u16 (mutable in place) or a plain Lua int array. Fixed set → no rebuild.
local function mflag_get(cc, f, i)
    local idx = cc.mflagbit[f]
    local b = (ok_ffi and cc.mflag[i - 1]) or cc.mflag[i] or 0
    return floor(b / 2 ^ idx) % 2 == 1 or nil
end
local function mflag_set(cc, f, i, v)
    local idx = cc.mflagbit[f]
    local b = (ok_ffi and cc.mflag[i - 1]) or cc.mflag[i] or 0
    local has = floor(b / 2 ^ idx) % 2 == 1
    if v and not has then b = b + 2 ^ idx
    elseif (not v) and has then b = b - 2 ^ idx end
    if ok_ffi then cc.mflag[i - 1] = b elseif b > 0 then cc.mflag[i] = b else cc.mflag[i] = nil end
end

-- ── STREAMING ACCUMULATOR (record-fold step 2 — the parent-merge peak lever) ──
-- Append records BATCH-BY-BATCH, dropping each batch after add(), and finalize
-- ONCE into the same immutable store build() produces. The win: a caller folds a
-- worker chunk's calls into COMPACT value arrays (ranks/ints/packed bits — dense,
-- ~8-16 B/row/field) then frees the chunk's record tables (~500 B/record + argv
-- subtables), so the parent never holds the full record array at the merge peak.
-- finalize(perm) applies an optional CALL permutation (canonical reorder — the
-- parent's chunks arrive out of order) before choosing widths, so the result is
-- byte-identical to build() over the same rows in that order. opts.residual keeps
-- a per-row residual (non-covered fields); opts.skip_argv drops `argv` from it
-- (rescols serves argv from the argv store, matching rescols.view). A SEPARATE
-- path from build() (not a refactor of it) — tools/rescolacc.lua gates the two
-- equal, so build() stays untouched.
function M.new_colacc(syn, res, opts)
    local schema = syn or segment.CALL_SYNTACTIC
    res = res or segment.CALL_RESOLUTION
    local want_resid = opts and opts.residual
    local skip_argv = opts and opts.skip_argv
    local it = csr.interner()
    local str = {}; for _, f in ipairs(schema.strs) do str[f] = {} end
    local int = {}; for _, f in ipairs(schema.ints or {}) do int[f] = {} end
    local hasflags = schema.flags and #schema.flags > 0
    local flag = {}
    local rng = {}
    for _, rf in ipairs(schema.ranges or {}) do rng[rf] = { p = {}, sl = {}, sc = {}, el = {}, ec = {} } end
    local res_it, res_rank = {}, {}
    for _, f in ipairs(res.strs or {}) do res_it[f] = csr.interner(); res_rank[f] = {} end
    local hasresflags = res.flags and #res.flags > 0
    local resflag = {}
    local cov
    if want_resid then
        cov = {}
        for _, f in ipairs(schema.strs) do cov[f] = true end
        for _, f in ipairs(schema.ints or {}) do cov[f] = true end
        for _, f in ipairs(schema.flags or {}) do cov[f] = true end
        for _, rf in ipairs(schema.ranges or {}) do cov[rf] = true end
        for _, f in ipairs(res.strs or {}) do cov[f] = true end
        for _, f in ipairs(res.flags or {}) do cov[f] = true end
    end
    local resid = {}
    local n = 0
    local acc = {}
    function acc.add(rec)
        n = n + 1
        for _, f in ipairs(schema.strs) do
            local v = rec[f]; str[f][n] = (type(v) == 'string') and it.id(v) + 1 or 0
        end
        for _, f in ipairs(schema.ints or {}) do int[f][n] = rec[f] or 0 end
        if hasflags then
            local b = 0
            for j, f in ipairs(schema.flags) do if rec[f] then b = b + 2 ^ (j - 1) end end
            flag[n] = b
        end
        for _, rf in ipairs(schema.ranges or {}) do
            local r, c = rec[rf], rng[rf]
            if type(r) == 'table' and r.start and r['end'] then
                c.p[n] = 1; c.sl[n] = r.start.line or 0; c.sc[n] = r.start.char or 0
                c.el[n] = r['end'].line or 0; c.ec[n] = r['end'].char or 0
            else c.p[n], c.sl[n], c.sc[n], c.el[n], c.ec[n] = 0, 0, 0, 0, 0 end
        end
        for _, f in ipairs(res.strs or {}) do
            local v = rec[f]; res_rank[f][n] = (type(v) == 'string') and res_it[f].id(v) + 1 or 0
        end
        if hasresflags then
            local b = 0
            for j, f in ipairs(res.flags) do if rec[f] then b = b + 2 ^ (j - 1) end end
            resflag[n] = b
        end
        if want_resid then
            local extra
            for key, v in pairs(rec) do
                if not cov[key] and not (skip_argv and key == 'argv') then
                    extra = extra or {}; extra[key] = v
                end
            end
            resid[n] = extra
        end
    end
    function acc.count() return n end
    function acc.finalize(perm)
        local N = n
        local function permd(arr)
            if not perm then return arr end
            local out = {}; for i = 1, N do out[i] = arr[perm[i]] end; return out
        end
        local cc = { n = N, schema = schema, str = {}, int = {}, rng = {} }
        for _, f in ipairs(schema.strs) do cc.str[f] = widthcol(permd(str[f]), N) end
        cc.pool = it.list
        cc.intbias = {}
        for _, f in ipairs(schema.ints or {}) do
            local vals, mn = permd(int[f]), 0
            for i = 1, N do if vals[i] < mn then mn = vals[i] end end
            if mn < 0 then for i = 1, N do vals[i] = vals[i] - mn end end
            cc.intbias[f] = mn; cc.int[f] = widthcol(vals, N)
        end
        if hasflags then cc.flagcol, cc.flags = widthcol(permd(flag), N), schema.flags end
        for _, rf in ipairs(schema.ranges or {}) do
            local c = rng[rf]
            cc.rng[rf] = { pres = widthcol(permd(c.p), N), sl = widthcol(permd(c.sl), N),
                sc = widthcol(permd(c.sc), N), el = widthcol(permd(c.el), N), ec = widthcol(permd(c.ec), N) }
        end
        cc.isflag = {}
        for _, f in ipairs(schema.flags or {}) do cc.isflag[f] = true end
        cc.res, cc.resf, cc.mutstr = res, {}, {}
        for _, f in ipairs(res.strs or {}) do
            local ranks, mx = permd(res_rank[f]), 0
            for i = 1, N do if ranks[i] > mx then mx = ranks[i] end end
            cc.mutstr[f] = mutstr_new(res_it[f], ranks, N, mx); cc.resf[f] = true
        end
        if hasresflags then
            cc.mflagbit = {}
            for j, f in ipairs(res.flags) do cc.mflagbit[f] = j - 1; cc.resf[f] = true end
            local w = #res.flags <= 8 and 1 or 2
            cc.mflag = ok_ffi and ffi_arr(w, N) or {}
            local pf = permd(resflag)
            for i = 1, N do
                local b = pf[i] or 0
                if ok_ffi then cc.mflag[i - 1] = b elseif b > 0 then cc.mflag[i] = b end
            end
        end
        return cc, (want_resid and permd(resid) or nil)
    end
    return acc
end

-- build a column store from a call-record list. `syn` = the SYNTACTIC schema →
-- immutable width columns (the resident win); `res` = the RESOLUTION schema → the
-- MUTABLE columnar overlay above (resolution writes c.to/prov/inferred/… AFTER
-- build). Defaults: the call syntactic / resolution schemas. Strings pooled once;
-- each str col is a rank (id+1, 0=absent).
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
        cc.str[f] = widthcol(ranks, n)
    end
    cc.pool = it.list -- pool[rank] = the string (rank = id + 1, list is 1-based)
    -- int columns AUTO-BIAS: a field with negative values (e.g. node `order`,
    -- which is -1 for module/unparsed nodes) shifts by -min so the width column
    -- stays unsigned; M.int adds the bias back. Non-negative columns (line) get
    -- bias 0 (no-op). The column must be DENSE (every row has the field) — a
    -- sparse int would read the bias for absent rows, so sparse ints ride the
    -- residual, not here.
    cc.intbias = {}
    for _, f in ipairs(schema.ints or {}) do
        local vals, mn = {}, 0
        for i = 1, n do local v = calls[i][f] or 0; vals[i] = v; if v < mn then mn = v end end
        if mn < 0 then for i = 1, n do vals[i] = vals[i] - mn end end
        cc.intbias[f] = mn
        cc.int[f] = widthcol(vals, n)
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
        cc.flagcol, cc.flags = widthcol(vals, n), schema.flags
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
        cc.rng[rf] = { pres = widthcol(p, n), sl = widthcol(sl, n), sc = widthcol(sc, n),
            el = widthcol(el, n), ec = widthcol(ec, n) }
    end
    -- the MUTABLE resolution overlay (columnar — see the helpers above), seeded
    -- from the calls and WRITABLE by resolution. A field here is looked up here
    -- first (M.get), so writes win.
    cc.isflag = {}
    for _, f in ipairs(schema.flags or {}) do cc.isflag[f] = true end
    cc.res, cc.resf, cc.mutstr = res, {}, {}
    for _, f in ipairs(res.strs or {}) do
        local it = csr.interner()
        local ranks, mx = {}, 0
        for i = 1, n do
            local v = calls[i][f]
            local r = (type(v) == 'string') and it.id(v) + 1 or 0
            ranks[i] = r; if r > mx then mx = r end
        end
        cc.mutstr[f] = mutstr_new(it, ranks, n, mx)
        cc.resf[f] = true
    end
    if res.flags and #res.flags > 0 then
        cc.mflagbit = {}
        for j, f in ipairs(res.flags) do cc.mflagbit[f] = j - 1; cc.resf[f] = true end
        local w = #res.flags <= 8 and 1 or 2
        cc.mflag = ok_ffi and ffi_arr(w, n) or {}
        for i = 1, n do
            local b = 0
            for j, f in ipairs(res.flags) do if calls[i][f] then b = b + 2 ^ (j - 1) end end
            if ok_ffi then cc.mflag[i - 1] = b elseif b > 0 then cc.mflag[i] = b end
        end
    end
    return cc
end

-- ── field accessors (0 rank / absent → the record's falsy value) ──────────
function M.str(cc, f, i) local r = cc.str[f](i); return r > 0 and cc.pool[r] or nil end
function M.int(cc, f, i) return cc.int[f](i) + (cc.intbias and cc.intbias[f] or 0) end
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
    if cc.resf[f] then
        local ms = cc.mutstr[f]
        if ms then return mutstr_get(ms, i) end
        return mflag_get(cc, f, i)
    end
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
    local ms = cc.mutstr[f]
    if ms then mutstr_set(ms, i, v) else mflag_set(cc, f, i, v) end
end

-- reconstruct a call's full record (syntactic columns + resolution overlay) —
-- for parity checks / a full read
function M.record(cc, i)
    local s, out = cc.schema, {}
    for _, f in ipairs(s.strs) do out[f] = M.str(cc, f, i) end
    for _, f in ipairs(s.ints or {}) do out[f] = M.int(cc, f, i) end
    for _, f in ipairs(s.flags or {}) do if M.flag(cc, f, i) then out[f] = true end end
    for _, rf in ipairs(s.ranges or {}) do out[rf] = M.range(cc, rf, i) end
    for _, f in ipairs(cc.res.strs or {}) do local v = mutstr_get(cc.mutstr[f], i); if v then out[f] = v end end
    for _, f in ipairs(cc.res.flags or {}) do if mflag_get(cc, f, i) then out[f] = true end end
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
-- SHARED proxy dispatch over a backing `st` = { cc, i, res, cov } (the same shape
-- callcols' __cc and rescols' __rc rows carry). ONE home for the read/write rules
-- so a fix (e.g. the residual-FALSE preserve, the immutable-write assert) lands
-- once, not per proxy — rescols' row_mt delegates here (with its argv special-case
-- layered on top). A COVERED field routes to the column/overlay, else the residual.
function M.proxy_index(st, k)
    if st.cov[k] then return M.get(st.cc, k, st.i) end
    local r = st.res
    -- return r[k] directly — `r[k] or nil` would collapse a residual FALSE (a
    -- tristate field like node exported/effects) to nil
    if r then return r[k] end
end
function M.proxy_newindex(st, k, v)
    if st.cc.resf[k] then M.set(st.cc, k, st.i, v); return end
    -- a write to a covered IMMUTABLE (syntactic) column is a resolver bug —
    -- surface it, same as M.set's assert (parse facts are never rewritten)
    assert(not st.cov[k], 'callcols: write to immutable syntactic field: ' .. tostring(k))
    local r = st.res
    if not r then r = {}; st.res = r end
    r[k] = v
end

local row_mt = {
    __index = function (self, k) return M.proxy_index(rawget(self, '__cc'), k) end,
    __newindex = function (self, k, v) M.proxy_newindex(rawget(self, '__cc'), k, v) end,
}

-- reconstruct a call/node/edge record from its columns + a per-row RESIDUAL table
-- (the record() body every columnar module shares: callcols.record + merge the
-- residual). rescols adds argv on top; nodecols/edgecols use this verbatim.
function M.record_resid(cc, i, resid)
    local out = M.record(cc, i)
    if resid then for k, v in pairs(resid) do out[k] = v end end
    return out
end

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
