-- fedgate — CART-1160 step 9a's acceptance on a REAL tree: the linkage a namespace DERIVES (a project band extracted
-- with profile_mint = false, a profile mounted read-only as its own band) against the edges the in-graph MINT writes.
-- Row = (from fn, to export, occurrences). MATCH / MISS (mint wrote it, linkage did not) / EXTRA (the reverse).
--
--   nvim --headless -u NONE -l tools/fedgate.lua <root> <profile>
-- Reads the tree only; writes nothing. Two extractions of the same tree.
local REPO = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(REPO)
vim.opt.rtp:append(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
local ts = require 'cartograph.providers.treesitter'
local F = require 'cartograph.federation'
local NS = require 'cartograph.namespace'
local root = vim.fn.fnamemodify(assert(arg[1], 'usage: <root> <profile>'), ':p'):gsub('/$', '')
local runtime = assert(arg[2], 'usage: <root> <profile>')

local t0 = vim.uv.hrtime()
local mint = ts.extract(root, { profile = runtime })
local minted = {}
for _, e in ipairs(mint.edges) do if e.stdlib then minted[e.from .. '\31' .. e.to] = #(e.at or {}) end end
local t1 = vim.uv.hrtime()
local fed = ts.extract(root, { profile = runtime, profile_mint = false })
local band = assert(F.profile_band(runtime))
local ns = NS.mount(NS.mount(NS.empty(), root, fed, { share = { runtime } }), band.root, band, { ro = true })
local L = F.linkage(ns)
local linked = {}
for _, r in ipairs(L.rows) do linked[r.from .. '\31' .. r.to] = #r.at end
local t2 = vim.uv.hrtime()

local match, occ_diff, miss, extra, ex_miss, ex_extra = 0, 0, 0, 0, {}, {}
for k, n in pairs(minted) do
    if linked[k] == nil then miss = miss + 1; if #ex_miss < 8 then ex_miss[#ex_miss + 1] = k:gsub('\31', ' -> ') end
    elseif linked[k] ~= n then occ_diff = occ_diff + 1
    else match = match + 1 end
end
for k in pairs(linked) do
    if minted[k] == nil then extra = extra + 1; if #ex_extra < 8 then ex_extra[#ex_extra + 1] = k:gsub('\31', ' -> ') end end
end
local nmint, nlink = vim.tbl_count(minted), vim.tbl_count(linked)
io.write(('%s under profile %s: %d mint edge(s), %d linkage row(s); %d misses (frontier left unlinked)\n')
    :format(root, runtime, nmint, nlink, #L.misses))
io.write(('MATCH %d · OCCURRENCES DIFFER %d · MISS %d · EXTRA %d   (mint %.0f ms, federated %.0f ms)\n')
    :format(match, occ_diff, miss, extra, (t1 - t0) / 1e6, (t2 - t1) / 1e6))
for _, x in ipairs(ex_miss) do io.write('  MISS  ', x, '\n') end
for _, x in ipairs(ex_extra) do io.write('  EXTRA ', x, '\n') end
os.exit((miss == 0 and extra == 0 and occ_diff == 0 and nmint > 0) and 0 or 1)
