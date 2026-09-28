-- skeletonrss — CART-1160 step 8's residency number: the SAME dataflow query answered by a FULL graph and by a
-- SKELETON (the thin index) + generated adapters under a file budget, with the Lua heap after each and a row-by-row
-- equality check (the acceptance rule: skeleton + adapters must EQUAL the full graph).
--
--   nvim --headless -u NONE -l tools/skeletonrss.lua [<root>] [budget]      (default: lua/cartograph of this repo, 8)
-- One process per mode would be cleaner for RSS; the heap (collectgarbage 'count', after a full collect) is what
-- this in-process comparison can measure honestly, and it is labelled as such.
local REPO = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(REPO)
vim.opt.rtp:append(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
local store = require 'cartograph.store'
local ts = require 'cartograph.providers.treesitter'
local A = require 'cartograph.adapters'
local df = require 'cartograph.df'
local root = vim.fn.fnamemodify(arg[1] or (REPO .. '/lua/cartograph'), ':p'):gsub('/$', '')
local budget = tonumber(arg[2] or '8')

local function heap() collectgarbage(); collectgarbage(); return collectgarbage('count') / 1024 end
local function rows()
    local out, nst = {}, 0
    for _, n in ipairs(store.data.nodes) do
        if n.kind == 'function' or n.kind == 'method' then
            local st = {}
            for i, s in ipairs(df.stmts(n)) do
                st[i] = ('%s|%s|%s'):format(tostring(s.l), table.concat(s.def or {}, ','), table.concat(s.use or {}, ','))
                nst = nst + 1
            end
            out[n.id] = table.concat(st, ';')
        end
    end
    return out, nst
end

A.derive() -- the probe, outside both measurements
local h0 = heap()
local t0 = vim.uv.hrtime()
store.ingest(ts.extract(root))
local full, nst = rows()
local t_full = (vim.uv.hrtime() - t0) / 1e6
local h_full = heap() - h0
local nfiles = #(store.files or {})
store.ingest({ root = root, nodes = {}, edges = {}, calls = {} }) -- drop the full graph
full = full -- keep only the rows (strings) for the comparison
local h1 = heap()
A.budget = budget
local t1 = vim.uv.hrtime()
store.ingest(ts.index_only(root))
local h_skel = heap() - h1
local skel = rows()
local t_skel = (vim.uv.hrtime() - t1) / 1e6
local h_after = heap() - h1
local diff = 0
for id, v in pairs(full) do if skel[id] ~= v then diff = diff + 1 end end
for id in pairs(skel) do if full[id] == nil then diff = diff + 1 end end
io.write(('root %s: %d files, %d functions, %d statements\n'):format(root, nfiles, vim.tbl_count(full), nst))
io.write(('FULL graph            heap %7.1f MB   extract+query %6.0f ms\n'):format(h_full, t_full))
io.write(('SKELETON (thin index) heap %7.1f MB\n'):format(h_skel))
io.write(('SKELETON + adapters   heap %7.1f MB   extract+query %6.0f ms   budget %d files, resident %d, fills %d, evictions %d\n')
    :format(h_after, t_skel, budget, #A.resident(store), A.stats.fills, A.stats.evictions))
io.write(('ROWS: %d function(s) differ between the full graph and skeleton + adapters\n'):format(diff))
os.exit(diff == 0 and 0 or 1)
