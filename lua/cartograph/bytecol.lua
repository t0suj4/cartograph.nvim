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

return M
