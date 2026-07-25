-- bytecol fixed-width u32 columns: the LE-packing primitive shared by at.lua
-- (1-based range coords) and csr/fold (0-based offsets & permutations). These
-- pin the pack↔read round-trip across the width boundaries so the shared helper
-- can't drift from the specialised copies it replaced.

local bc = require 'cartograph.bytecol'

-- values straddling every byte boundary, incl. the full u32 range
local VALS = { 0, 1, 255, 256, 257, 65535, 65536, 65537,
    16777215, 16777216, 16777217, 4294967295 }

test('bytecol.pack_u32/reader_u32: 1-based round-trip across all widths', function ()
    local arr = {}
    for i, v in ipairs(VALS) do arr[i] = v end
    local rd = bc.reader_u32(bc.pack_u32(arr, #arr))
    for i, v in ipairs(VALS) do eq(v, rd(i), '1-based index ' .. i) end
end)

test('bytecol.pack_u32_0/reader_u32_0: 0-based round-trip across all widths', function ()
    local arr, n = {}, #VALS
    for i = 0, n - 1 do arr[i] = VALS[i + 1] end
    local rd = bc.reader_u32_0(bc.pack_u32_0(arr, n))
    for i = 0, n - 1 do eq(VALS[i + 1], rd(i), '0-based index ' .. i) end
end)

test('bytecol: pack_u32 is M.pack at width 4, and the two bases agree byte-for-byte', function ()
    local one, zero, n = {}, {}, #VALS
    for i = 1, n do one[i] = VALS[i] end
    for i = 0, n - 1 do zero[i] = VALS[i + 1] end
    eq(bc.pack(one, n, 4), bc.pack_u32(one, n), 'pack_u32 == M.pack(.,.,4)')
    -- same ordered values, different index base → identical bytes
    eq(bc.pack_u32(one, n), bc.pack_u32_0(zero, n), '1-based and 0-based packs match')
end)

test('bytecol: the 1-based reader agrees with the dispatching M.rd at width 4', function ()
    local arr = {}
    for i, v in ipairs(VALS) do arr[i] = v end
    local col = { s = bc.pack_u32(arr, #arr), w = 4 }
    local rd = bc.reader_u32(col.s)
    for i = 1, #arr do eq(bc.rd(col, i), rd(i), 'index ' .. i) end
end)
