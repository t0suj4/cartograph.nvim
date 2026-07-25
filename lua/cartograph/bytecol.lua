-- BYTECOL — serializable LE-packed WIDTH COLUMNS (u8/u16/u32), the shared primitive for
-- the folded stores that must ROUND-TRIP THE CACHE (df.lua, flow.lua). A column is PLAIN
-- DATA { s = byte-string, w = 1|2|4 } — NOT a closure over the string — so it serializes
-- (the cache holds the folded form, not fat records); the reader lives here, once, instead
-- of one closure per column. Each column picks its narrowest width from its max value.
--
-- callcols uses its OWN ffi/closure column form (widthcol/mutstr): its columns are
-- IN-MEMORY only (calls are cached via segment.encode, never callcols), so it trades
-- serializability for ffi speed + a mutable resolution overlay. That is a deliberate
-- difference, not duplication — this module is the SERIALIZABLE twin.

local char, byte, concat = string.char, string.byte, table.concat

local M = {}

-- narrowest width for a column whose max value is `mx`: u8 (<256) / u16 (<65536) / u32.
function M.width_for(mx) return mx < 256 and 1 or (mx < 65536 and 2 or 4) end

-- pack a 1-based int array (first `len` entries) into an LE byte string at width `w`.
function M.pack(arr, len, w)
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

-- pack an array auto-selecting its width from the array's own max → { s, w }.
-- w=0 = an ALL-ZERO column: store nothing (s = ''); rd returns 0 (correct — all values ARE 0).
function M.packcol(arr, len)
    local mx = 0
    for i = 1, len do if arr[i] > mx then mx = arr[i] end end
    if mx == 0 then return { s = '', w = 0 } end
    local w = M.width_for(mx)
    return { s = M.pack(arr, len, w), w = w }
end

-- read a 1-based value from a { s, w } column.
function M.rd(c, i)
    local s, w = c.s, c.w
    if w == 0 then return 0 end
    if w == 1 then return byte(s, i) end
    if w == 2 then
        local p = (i - 1) * 2 + 1
        local a, b = byte(s, p, p + 1)
        return a + b * 256
    end
    local p = (i - 1) * 4 + 1
    local a, b, c2, d = byte(s, p, p + 3)
    return a + b * 256 + c2 * 65536 + d * 16777216
end

-- ── fixed-width u32 columns (single width, SPECIALISED reader) ───────────────
-- For folded stores that keep one u32 column and want a reader with NO per-read
-- width branch: at.lua's range coords (1-based index) and the CSR / triple-store
-- offsets & permutations (0-based index). The bytes are identical to
-- M.pack(.,.,4) / M.rd(.,4) — these variants only fix the width and the index
-- base, so the hot getter is a tight closure instead of a dispatch.

-- 1-based: pack arr[1..len] → LE u32 bytes (M.pack at width 4).
function M.pack_u32(arr, len) return M.pack(arr, len, 4) end

-- 1-based u32 reader over packed bytes: reader(i) → arr[i].
function M.reader_u32(s)
    return function (i)
        local p = (i - 1) * 4 + 1
        local a, b, c, d = byte(s, p, p + 3)
        return a + b * 256 + c * 65536 + d * 16777216
    end
end

-- 0-based: pack arr[0..len-1] → LE u32 bytes.
function M.pack_u32_0(arr, len)
    local parts = {}
    for i = 0, len - 1 do
        local x = arr[i]
        parts[i + 1] = char(x % 256, (x - x % 256) / 256 % 256,
            (x - x % 65536) / 65536 % 256, (x - x % 16777216) / 16777216 % 256)
    end
    return concat(parts)
end

-- 0-based u32 reader over packed bytes: reader(i) → arr[i].
function M.reader_u32_0(s)
    return function (i)
        local p = i * 4 + 1
        local a, b, c, d = byte(s, p, p + 3)
        return a + b * 256 + c * 65536 + d * 16777216
    end
end

return M
