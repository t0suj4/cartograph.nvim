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

-- build a column store from a call-record list (over `schema`, default the call
-- scalar schema). Strings are pooled once; each str field is a rank column
-- (rank = pool id + 1, 0 = absent).
function M.build(calls, schema)
    schema = schema or segment.CALL_SCHEMA
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

-- reconstruct a call's schema-field record (for parity checks / a full read)
function M.record(cc, i)
    local s, out = cc.schema, {}
    for _, f in ipairs(s.strs) do out[f] = M.str(cc, f, i) end
    for _, f in ipairs(s.ints or {}) do out[f] = M.int(cc, f, i) end
    for _, f in ipairs(s.flags or {}) do if M.flag(cc, f, i) then out[f] = true end end
    for _, rf in ipairs(s.ranges or {}) do out[rf] = M.range(cc, rf, i) end
    return out
end

return M
