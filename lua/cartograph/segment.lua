-- COLUMNAR RECORD SEGMENT — the wire/cache form of a record list (record-fold
-- arc step 5, [[cartograph-record-fold-arc]]). Resident-folding string fields is
-- DEAD (Lua interns them), but the WIRE repeats the bytes — mpack writes every
-- `c.file` string on every call — so a columnar segment that pools each distinct
-- string ONCE and stores per-field FREQUENCY-ORDERED VARINT indices is 5-10×
-- smaller than raw mpack (MEASURED: 6.7× self, 9.8× zig on the call records) and
-- GROWS with corpus size. It is also the step-5 PEAK lever: a worker ships this
-- segment (bytes), the parent CONCATs columns, never materializing the raw graph.
--
-- Schema-driven (reusable for calls/edges/nodes): { strs = {...}, ints = {...},
-- flags = {...} }. strs → shared rank-ordered pool + varint columns (0 = absent);
-- ints → varint columns; flags → one bit-packed byte per record (≤8 flags).
-- Layout: uvarint n · pool(uvarint np, then len-prefixed strings in RANK order)
--   · str columns · int columns · flag bytes. decode() needs the same schema.
-- M.CALL_SCHEMA carries the full SCALAR field set (13 strings + line + 5 flags,
-- empirically enumerated over zig∪self); the 7 TABLE fields (argv/at/refused/…)
-- are detail carried by their own folds, not the segment. A producer pipeline
-- (step 4) would split syntactic vs resolution-era into two phases, but the
-- post-resolution cache/wire form is one scalar segment. Verify the field union
-- per language before a cache swap ([[cartograph-record-fold-arc]] step 4).

local reg = require 'cartograph.registry'
local csr = require 'cartograph.csr'

local M = {}

local char, byte, floor = string.char, string.byte, math.floor

-- the call-record SCALAR schema (empirically the full scalar field set; the 7
-- TABLE fields — args/argv/at/ext/hedge/refused/rt — are detail carried by their
-- own folds (at/argv/refused), not the segment). Two-phase note: file/callee/fn/
-- full/recv*/chain*/method/line are SYNTACTIC; to/prov/inferred/tinf/rtfull are
-- resolution-era — a producer pipeline (step 4) fills them in a parallel column,
-- but for the post-resolution cache/wire form they ride one scalar segment.
-- (method/inferred/rtfull/tinf/top are BOOLEANS — flags, not strings.)
M.CALL_SCHEMA = {
    strs = { 'file', 'callee', 'fn', 'full', 'to', 'prov',
        'recv', 'recvpath', 'recvroot', 'chainfield', 'chainroot', 'chainty', 'stdpath' },
    ints = { 'line' },
    flags = { 'method', 'inferred', 'tinf', 'rtfull', 'top' },
    -- ranges = {start={line,char},end={line,char}} tables → 4 coord columns +
    -- a presence bit (the at.lua fold, applied to the wire). `at` is the biggest
    -- residual field (MEASURED 5.2MB on zig calls); columnarizing it here pulls
    -- it out of the raw-table residual. A non-table value stays in the residual.
    ranges = { 'at' },
}

-- records (1-based list) + schema → a packed byte string
function M.encode(records, schema)
    local n = #records
    local it = csr.interner()
    -- intern every string value; collect the mention id-sequence so the pool is
    -- FREQUENCY-ORDERED (rank 1 = most frequent = a 1-byte varint in the columns)
    local mentions, mk = {}, 0
    for _, f in ipairs(schema.strs) do
        for i = 1, n do
            local v = records[i][f]
            if type(v) == 'string' then mk = mk + 1; mentions[mk] = it.id(v) end
        end
    end
    local rank, inv = reg.freq_order(mentions)

    local parts, pk = {}, 0
    local function put(s) pk = pk + 1; parts[pk] = s end
    put(reg.uvarint(n))
    put(reg.uvarint(#inv))                     -- pool, in rank order
    for r = 1, #inv do
        local s = it.name(inv[r])
        put(reg.uvarint(#s)); put(s)
    end
    for _, f in ipairs(schema.strs) do         -- str columns: rank (0 = absent)
        local col = {}
        for i = 1, n do
            local v = records[i][f]
            col[i] = (type(v) == 'string') and rank[it.get(v)] or 0
        end
        put(reg.pack_varints(col))
    end
    for _, f in ipairs(schema.ints or {}) do   -- int columns
        local col = {}
        for i = 1, n do col[i] = records[i][f] or 0 end
        put(reg.pack_varints(col))
    end
    if schema.flags and #schema.flags > 0 then -- flags: one byte per record
        local fb = {}
        for i = 1, n do
            local b = 0
            for j, f in ipairs(schema.flags) do
                if records[i][f] then b = b + 2 ^ (j - 1) end
            end
            fb[i] = char(b)
        end
        put(table.concat(fb))
    end
    for _, rf in ipairs(schema.ranges or {}) do -- range: presence + 4 coord cols
        local pres, sl, sc, el, ec = {}, {}, {}, {}, {}
        for i = 1, n do
            local r = records[i][rf]
            if type(r) == 'table' and r.start and r['end'] then
                pres[i] = 1
                sl[i] = r.start.line or 0; sc[i] = r.start.char or 0
                el[i] = r['end'].line or 0; ec[i] = r['end'].char or 0
            else -- absent OR non-table (folded index): not carried; residual has it
                pres[i], sl[i], sc[i], el[i], ec[i] = 0, 0, 0, 0, 0
            end
        end
        put(reg.pack_varints(pres)); put(reg.pack_varints(sl)); put(reg.pack_varints(sc))
        put(reg.pack_varints(el)); put(reg.pack_varints(ec))
    end
    return table.concat(parts)
end

-- packed bytes + schema → the record list (str absent → nil; int absent → 0;
-- flag false → nil — the segment carries presence, not the original falsy shape)
function M.decode(blob, schema)
    local pos = 1
    local n, np
    n, pos = reg.read_uvarint(blob, pos)
    np, pos = reg.read_uvarint(blob, pos)
    local pool = {}
    for r = 1, np do
        local len; len, pos = reg.read_uvarint(blob, pos)
        pool[r] = blob:sub(pos, pos + len - 1); pos = pos + len
    end
    local recs = {}
    for i = 1, n do recs[i] = {} end
    for _, f in ipairs(schema.strs) do
        for i = 1, n do
            local r; r, pos = reg.read_uvarint(blob, pos)
            if r > 0 then recs[i][f] = pool[r] end
        end
    end
    for _, f in ipairs(schema.ints or {}) do
        for i = 1, n do recs[i][f], pos = reg.read_uvarint(blob, pos) end
    end
    if schema.flags and #schema.flags > 0 then
        for i = 1, n do
            local b = byte(blob, pos); pos = pos + 1
            for j, f in ipairs(schema.flags) do
                if floor(b / 2 ^ (j - 1)) % 2 == 1 then recs[i][f] = true end
            end
        end
    end
    local function col()  -- read n varints
        local c = {}; for i = 1, n do c[i], pos = reg.read_uvarint(blob, pos) end; return c
    end
    for _, rf in ipairs(schema.ranges or {}) do
        local pres, sl, sc, el, ec = col(), col(), col(), col(), col()
        for i = 1, n do
            if pres[i] == 1 then
                recs[i][rf] = { start = { line = sl[i], char = sc[i] },
                    ['end'] = { line = el[i], char = ec[i] } }
            end -- pres 0 → nil here; a non-table value comes from the residual
        end
    end
    return recs
end

return M
