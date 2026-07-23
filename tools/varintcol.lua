-- varintcol — the aggressive-varint-columnar compaction ceiling ([[cartograph-thin-index]]).
-- Three resident encodings of the call SCALAR fields, measured in bytes:
--   RECORDS   — Lua record tables (the current resident fat; per-field hash slots).
--   CALLCOLS  — u32 / packed-byte columns, O(1) random access (the measured resident columnar,
--               −19% mem / +97% query via proxy dispatch).
--   SEGMENT   — pooled strings + FREQUENCY-VARINT columns (the aggressive form; the cache/wire
--               codec). Smallest, but VARIABLE-width → sequential decode, no O(1) random access.
-- Shows how much aggressive varint actually buys over callcols, and thus whether it's a new
-- resident point or just the (already-used) serialized/disk form.
--
--   nvim --headless -u NONE -l tools/varintcol.lua [corpus]   (default: libs)

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
pcall(vim.treesitter.language.add, 'lua')
package.path = repo .. '/tools/?.lua;' .. repo .. '/lua/?.lua;' .. repo .. '/lua/?/init.lua;' .. package.path
local bench = require 'bench'
local segment = require 'cartograph.segment'
local callcols = require 'cartograph.callcols'

local name = arg[1] or 'libs'
local data = bench.extract_parallel(name)
local calls = data.calls or {}
if data._callstore then calls = require('cartograph.rescols').materialize(data._callstore) end
local N = #calls

-- SEGMENT (freq-varint): the cache/wire scalar columns
local seg = segment.encode(calls, segment.CALL_SCHEMA)
local seg_bytes = #seg

-- CALLCOLS (u32/byte columns): sum the resident column storage
local cc = callcols.build(calls, segment.CALL_SYN_RESOLVE, segment.CALL_RES_RESOLVE)
local function col_bytes(v, seen)
    local t = type(v)
    if t == 'string' then return #v
    elseif t == 'cdata' then return 0 -- ffi array; sized below via .n heuristic (skip, report note)
    elseif t == 'table' then
        if seen[v] then return 0 end; seen[v] = true
        local s = 0; for _, x in pairs(v) do s = s + col_bytes(x, seen) end; return s
    end
    return 0
end
-- callcols columns are ffi cdata or packed strings; count packed-string bytes + pooled strings
local cc_seen = {}
local cc_bytes = col_bytes(cc, cc_seen)

-- RECORDS: deep byte estimate of the scalar fields the columns cover (the compactable part)
local COVERED = callcols.covered(cc)
local rseen = {}
local function bytes(v)
    local t = type(v)
    if t == 'string' then return #v + 17
    elseif t == 'number' then return 8
    elseif t == 'boolean' then return 0
    elseif t == 'table' then
        if rseen[v] then return 0 end; rseen[v] = true
        local s = 40; for k, x in pairs(v) do s = s + (type(k) == 'string' and #k + 17 or 8) + bytes(x) end; return s
    end
    return 8
end
local rec_bytes = 0
for _, c in ipairs(calls) do
    rec_bytes = rec_bytes + 40 -- the record table header
    for k, v in pairs(c) do if COVERED[k] then rec_bytes = rec_bytes + 17 + 8 + bytes(v) end end
end

local function mb(x) return x / 1048576 end
print(('varintcol %s — %d calls (scalar fields)'):format(name, N))
print(('  RECORDS  (Lua tables, O(1) direct)  : %7.1f MB'):format(mb(rec_bytes)))
print(('  CALLCOLS (u32/byte cols, O(1) index): %7.1f MB   (%.0f%% of records)')
    :format(mb(cc_bytes), rec_bytes > 0 and 100 * cc_bytes / rec_bytes or 0))
print(('  SEGMENT  (freq-varint, sequential)  : %7.1f MB   (%.0f%% of records)')
    :format(mb(seg_bytes), rec_bytes > 0 and 100 * seg_bytes / rec_bytes or 0))
print(('  ==> aggressive varint is %.0f%% of records, %.0f%% of callcols')
    :format(rec_bytes > 0 and 100 * seg_bytes / rec_bytes or 0, cc_bytes > 0 and 100 * seg_bytes / cc_bytes or 0))
print('  NOTE: callcols ffi cdata columns are not counted by col_bytes (they show only packed/pooled')
print('        bytes); if callcols reads 0 MB it is ffi-backed — compare SEGMENT vs RECORDS as the bound.')
vim.cmd('qall!')
