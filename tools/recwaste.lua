-- recwaste — exact PARTIAL-SPARSITY waste in the callcols string columns ([[cartograph-thin-index]]).
-- callcols stores each columnized STRING field as an N-long pool-index array at width_for(#pool).
-- An all-absent column is already w=0 (stores nothing); a PARTIALLY-present one still allocates a
-- slot per row → the absent rows are waste a present-only (values + bitmap) encoding would reclaim.
-- Measures, per columnized str field: presence, #distinct (pool), width, fixed bytes vs
-- present-only+bitmap, and the reclaimable waste. Sums it — the ceiling of "fixed-hot + sparse-cold".
--
--   nvim --headless -u NONE -l tools/recwaste.lua [corpus]   (default: libs)

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
pcall(vim.treesitter.language.add, 'lua')
package.path = repo .. '/tools/?.lua;' .. repo .. '/lua/?.lua;' .. repo .. '/lua/?/init.lua;' .. package.path
local bench = require 'bench'
local segment = require 'cartograph.segment'
local width_for = require('cartograph.bytecol').width_for

local name = arg[1] or 'libs'
local data = bench.extract_parallel(name)
local calls = data.calls or {}
if data._callstore then calls = require('cartograph.rescols').materialize(data._callstore) end
local N = #calls

-- the columnized STRING fields (the only ones that suffer partial-sparsity; ints/flags are dense
-- or bit-packed). Union of the two resolution-phase schemas.
local STR = {}
for _, f in ipairs(segment.CALL_SYN_RESOLVE.strs) do STR[#STR + 1] = f end
for _, f in ipairs(segment.CALL_RES_RESOLVE.strs) do STR[#STR + 1] = f end

local bitmap = math.ceil(N / 8)
local total_fixed, total_sparse, total_reclaim = 0, 0, 0
local rows = {}
for _, f in ipairs(STR) do
    local present, distinct = 0, {}
    for _, c in ipairs(calls) do
        local v = c[f]
        if v ~= nil then present = present + 1; distinct[v] = true end
    end
    local ndist = 0; for _ in pairs(distinct) do ndist = ndist + 1 end
    local w = present > 0 and width_for(ndist) or 0
    local fixed = present > 0 and (N * w) or 0            -- w=0 all-absent → 0 (already free)
    local sparse = present > 0 and (present * w + bitmap) or 0
    local reclaim = math.max(0, fixed - sparse)
    total_fixed = total_fixed + fixed
    total_sparse = total_sparse + sparse
    total_reclaim = total_reclaim + reclaim
    rows[#rows + 1] = { f = f, present = present, ndist = ndist, w = w, fixed = fixed, reclaim = reclaim }
end
table.sort(rows, function (a, b) return a.reclaim > b.reclaim end)

local function kb(x) return x / 1024 end
print(('recwaste %s — %d calls, bitmap %d KB/col'):format(name, N, math.floor(kb(bitmap))))
print('  field         present%%   #pool  w  fixed KB   reclaim KB')
for _, r in ipairs(rows) do
    print(('    %-11s %6.0f%%  %6d  %d  %8.0f   %8.0f%s')
        :format(r.f, 100 * r.present / N, r.ndist, r.w, kb(r.fixed), kb(r.reclaim),
            r.present == 0 and '  (w=0, already free)' or r.present == N and '  (dense, no waste)' or ''))
end
print(('  ── fixed str-col bytes %.1f MB → present-only+bitmap %.1f MB → RECLAIM %.1f MB (%.0f%%) ──')
    :format(total_fixed / 1048576, total_sparse / 1048576, total_reclaim / 1048576,
        total_fixed > 0 and 100 * total_reclaim / total_fixed or 0))
vim.cmd('qall!')
