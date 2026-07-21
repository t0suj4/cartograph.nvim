-- COLUMNAR RECORD SEGMENT — the wire/cache form of a record list (record-fold
-- arc step 5, [[cartograph-record-fold-arc]]). Resident-folding string fields is
-- DEAD (Lua interns them), but the WIRE repeats the bytes — mpack writes every
-- `c.file` string on every call — so a columnar segment that pools each distinct
-- string ONCE and stores per-field FREQUENCY-ORDERED VARINT indices is 5-10×
-- smaller than raw mpack (MEASURED) and GROWS with corpus size. It is also the
-- step-5 PEAK lever: a worker ships this segment (bytes), the parent CONCATs
-- columns (M.merge), never materializing the raw graph.
--
-- Schema-driven (reusable for calls/edges/nodes): { strs, ints, flags, ranges }.
-- strs → shared rank-ordered pool + varint columns (0 = absent); ints → varint
-- columns; flags → one bit-packed byte per record (≤8); ranges → {start,end}
-- table → presence bit + 4 coord columns (the at.lua fold on the wire).
--
-- encode / decode / merge all route through a COLUMNS intermediate, so:
--   * encode(records)          = write_cols(cols_of_records(records))
--   * decode(blob)             = records_of_cols(read_cols(blob))
--   * merge({blobs})           = write_cols(merge_cols(map(read_cols, blobs)))
-- and merge is by construction BYTE-IDENTICAL to encode(concat of the records) —
-- the ⊤ of the merge lattice for records, the record analog of fold.merge: the
-- parent concats worker segment COLUMNS without materializing record tables.
-- M.CALL_SCHEMA carries the full scalar field set; the detail tables (argv/at*/
-- refused, *at folds here) ride their own folds/residual. Verify the field
-- union per language before a cache swap. (*at is a range, folded here.)

local reg = require 'cartograph.registry'
local csr = require 'cartograph.csr'

local M = {}

local char, byte, floor = string.char, string.byte, math.floor

M.CALL_SCHEMA = {
    strs = { 'file', 'callee', 'fn', 'full', 'to', 'prov',
        'recv', 'recvpath', 'recvroot', 'chainfield', 'chainroot', 'chainty', 'stdpath' },
    ints = { 'line' },
    flags = { 'method', 'inferred', 'tinf', 'rtfull', 'top' },
    ranges = { 'at' },
}

-- TWO-PHASE split of the call schema (for the RESIDENT store, callcols.lua):
-- SYNTACTIC fields are set at parse and never rewritten → immutable columns;
-- RESOLUTION fields are written DURING resolution (c.to/prov/inferred/…) → a
-- mutable overlay. (CALL_SCHEMA above stays the FULL post-resolution snapshot
-- the wire/cache use — a save happens after resolution, so one segment is fine.)
M.CALL_SYNTACTIC = {
    strs = { 'file', 'callee', 'fn', 'full',
        'recv', 'recvpath', 'recvroot', 'chainfield', 'chainroot', 'chainty' },
    ints = { 'line' },
    flags = { 'method' },
    ranges = { 'at' },
}
M.CALL_RESOLUTION = {
    strs = { 'to', 'prov', 'stdpath' },
    flags = { 'inferred', 'tinf', 'rtfull', 'top' },
}

-- ── the COLUMNS intermediate ─────────────────────────────────────────────
-- cols = { n, pool = {rank→string}, str = {field→{rank|0}}, int = {field→{v}},
--          flag = {field→{bool}}, rng = {field→{pres,sl,sc,el,ec}} }

-- records → cols. Mentions collected field-outer, record-inner (the canonical
-- order merge_cols reproduces over the concatenation, so a merged blob equals
-- encode of the concatenated records).
local function cols_of_records(records, schema)
    local n = #records
    local it = csr.interner()
    local mentions, mk = {}, 0
    for _, f in ipairs(schema.strs) do
        for i = 1, n do
            local v = records[i][f]
            if type(v) == 'string' then mk = mk + 1; mentions[mk] = it.id(v) end
        end
    end
    local rank, inv = reg.freq_order(mentions)
    local pool = {}
    for r = 1, #inv do pool[r] = it.name(inv[r]) end
    local cols = { n = n, pool = pool, str = {}, int = {}, flag = {}, rng = {} }
    for _, f in ipairs(schema.strs) do
        local c = {}
        for i = 1, n do
            local v = records[i][f]
            c[i] = (type(v) == 'string') and rank[it.get(v)] or 0
        end
        cols.str[f] = c
    end
    for _, f in ipairs(schema.ints or {}) do
        local c = {}
        for i = 1, n do c[i] = records[i][f] or 0 end
        cols.int[f] = c
    end
    for _, f in ipairs(schema.flags or {}) do
        local c = {}
        for i = 1, n do c[i] = records[i][f] and true or false end
        cols.flag[f] = c
    end
    for _, rf in ipairs(schema.ranges or {}) do
        local pres, sl, sc, el, ec = {}, {}, {}, {}, {}
        for i = 1, n do
            local r = records[i][rf]
            if type(r) == 'table' and r.start and r['end'] then
                pres[i] = 1
                sl[i] = r.start.line or 0; sc[i] = r.start.char or 0
                el[i] = r['end'].line or 0; ec[i] = r['end'].char or 0
            else
                pres[i], sl[i], sc[i], el[i], ec[i] = 0, 0, 0, 0, 0
            end
        end
        cols.rng[rf] = { pres = pres, sl = sl, sc = sc, el = el, ec = ec }
    end
    return cols
end

-- cols → packed bytes
local function write_cols(cols, schema)
    local n = cols.n
    local parts, pk = {}, 0
    local function put(s) pk = pk + 1; parts[pk] = s end
    put(reg.uvarint(n))
    put(reg.uvarint(#cols.pool))
    for r = 1, #cols.pool do
        local s = cols.pool[r]; put(reg.uvarint(#s)); put(s)
    end
    for _, f in ipairs(schema.strs) do put(reg.pack_varints(cols.str[f])) end
    for _, f in ipairs(schema.ints or {}) do put(reg.pack_varints(cols.int[f])) end
    if schema.flags and #schema.flags > 0 then
        local fb = {}
        for i = 1, n do
            local b = 0
            for j, f in ipairs(schema.flags) do
                if cols.flag[f][i] then b = b + 2 ^ (j - 1) end
            end
            fb[i] = char(b)
        end
        put(table.concat(fb))
    end
    for _, rf in ipairs(schema.ranges or {}) do
        local r = cols.rng[rf]
        put(reg.pack_varints(r.pres)); put(reg.pack_varints(r.sl)); put(reg.pack_varints(r.sc))
        put(reg.pack_varints(r.el)); put(reg.pack_varints(r.ec))
    end
    return table.concat(parts)
end

-- packed bytes → cols
local function read_cols(blob, schema)
    local pos = 1
    local n, np
    n, pos = reg.read_uvarint(blob, pos)
    np, pos = reg.read_uvarint(blob, pos)
    local pool = {}
    for r = 1, np do
        local len; len, pos = reg.read_uvarint(blob, pos)
        pool[r] = blob:sub(pos, pos + len - 1); pos = pos + len
    end
    local function col()
        local c = {}; for i = 1, n do c[i], pos = reg.read_uvarint(blob, pos) end; return c
    end
    local cols = { n = n, pool = pool, str = {}, int = {}, flag = {}, rng = {} }
    for _, f in ipairs(schema.strs) do cols.str[f] = col() end
    for _, f in ipairs(schema.ints or {}) do cols.int[f] = col() end
    if schema.flags and #schema.flags > 0 then
        for _, f in ipairs(schema.flags) do cols.flag[f] = {} end
        for i = 1, n do
            local b = byte(blob, pos); pos = pos + 1
            for j, f in ipairs(schema.flags) do
                cols.flag[f][i] = floor(b / 2 ^ (j - 1)) % 2 == 1
            end
        end
    end
    for _, rf in ipairs(schema.ranges or {}) do
        cols.rng[rf] = { pres = col(), sl = col(), sc = col(), el = col(), ec = col() }
    end
    return cols
end

-- cols → the record list (str absent → nil; int absent → 0; flag false → nil;
-- range presence 0 → nil — the segment carries presence, not the falsy shape)
local function records_of_cols(cols, schema)
    local n = cols.n
    local recs = {}
    for i = 1, n do recs[i] = {} end
    for _, f in ipairs(schema.strs) do
        local c = cols.str[f]
        for i = 1, n do if c[i] > 0 then recs[i][f] = cols.pool[c[i]] end end
    end
    for _, f in ipairs(schema.ints or {}) do
        local c = cols.int[f]
        for i = 1, n do recs[i][f] = c[i] end
    end
    for _, f in ipairs(schema.flags or {}) do
        local c = cols.flag[f]
        for i = 1, n do if c[i] then recs[i][f] = true end end
    end
    for _, rf in ipairs(schema.ranges or {}) do
        local r = cols.rng[rf]
        for i = 1, n do
            if r.pres[i] == 1 then
                recs[i][rf] = { start = { line = r.sl[i], char = r.sc[i] },
                    ['end'] = { line = r.el[i], char = r.ec[i] } }
            end
        end
    end
    return recs
end

-- concat several cols into one, RE-POOLING the strings (the ⊤ merge: columns
-- are concatenated, never expanded to records). Mentions are re-collected in
-- the SAME field-outer/record-inner order as cols_of_records would over the
-- concatenation, so write_cols(merge_cols(...)) == encode(concat of records).
local function merge_cols(list, schema)
    local it = csr.interner()
    local mentions, mk = {}, 0
    for _, f in ipairs(schema.strs) do
        for _, cs in ipairs(list) do
            local pool, c = cs.pool, cs.str[f]
            for i = 1, cs.n do
                local rk = c[i]
                if rk > 0 then mk = mk + 1; mentions[mk] = it.id(pool[rk]) end
            end
        end
    end
    local rank, inv = reg.freq_order(mentions)
    local pool = {}
    for r = 1, #inv do pool[r] = it.name(inv[r]) end

    local out = { n = 0, pool = pool, str = {}, int = {}, flag = {}, rng = {} }
    for _, cs in ipairs(list) do out.n = out.n + cs.n end
    for _, f in ipairs(schema.strs) do
        local mc = {}
        for _, cs in ipairs(list) do
            local cpool, c = cs.pool, cs.str[f]
            for i = 1, cs.n do
                local rk = c[i]
                mc[#mc + 1] = (rk > 0) and rank[it.get(cpool[rk])] or 0
            end
        end
        out.str[f] = mc
    end
    local function catcol(kind, f, sub)
        local mc = {}
        for _, cs in ipairs(list) do
            local c = sub and cs[kind][f][sub] or cs[kind][f]
            for i = 1, cs.n do mc[#mc + 1] = c[i] end
        end
        return mc
    end
    for _, f in ipairs(schema.ints or {}) do out.int[f] = catcol('int', f) end
    for _, f in ipairs(schema.flags or {}) do out.flag[f] = catcol('flag', f) end
    for _, rf in ipairs(schema.ranges or {}) do
        out.rng[rf] = { pres = catcol('rng', rf, 'pres'), sl = catcol('rng', rf, 'sl'),
            sc = catcol('rng', rf, 'sc'), el = catcol('rng', rf, 'el'),
            ec = catcol('rng', rf, 'ec') }
    end
    return out
end

-- ── public API ───────────────────────────────────────────────────────────
function M.encode(records, schema) return write_cols(cols_of_records(records, schema), schema) end
function M.decode(blob, schema) return records_of_cols(read_cols(blob, schema), schema) end

-- concat-merge a list of segment blobs into one, columns-only (no record
-- materialization) — the ⊤ record merge. Result == encode(concat of records).
function M.merge(blobs, schema)
    local cs = {}
    for i = 1, #blobs do cs[i] = read_cols(blobs[i], schema) end
    return write_cols(merge_cols(cs, schema), schema)
end

return M
