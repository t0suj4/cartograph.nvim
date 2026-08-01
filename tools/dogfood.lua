-- dogfood — cartograph on cartograph, headless (CI / pre-commit). Extracts our
-- OWN engine (lua/) and renders the self-analysis dashboard
-- ([[cartograph.dogfood]]): RESOLUTION (census + by_prov), SERVING (the LSP on
-- its own graph), LINT incl. the BAND SEAM-GUARD. Exits NON-ZERO on a seam
-- breach — the P2b migration as a regression fence.
--
--   nvim --headless -u NONE -l tools/dogfood.lua

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
pcall(vim.treesitter.language.add, 'lua')
package.path = repo .. '/lua/?.lua;' .. repo .. '/lua/?/init.lua;' .. package.path

local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local dogfood = require 'cartograph.dogfood'

local root = repo .. '/lua'
local data = ts.extract(root)
data.root = data.root or root
store.ingest(data)

local lines, counts = dogfood.run(store)
print(table.concat(lines, '\n'))
-- THE FENCE IS THE AUTHORITATIVE SET, not seam-guard alone (CART-0192). Every other
-- count is printed and not enforced, deliberately: a suggestive rule finds more when a
-- language becomes visible, and gating that would reward keeping languages opaque.
-- NOTE it needs no pinned baseline — the authoritative set is currently EMPTY on self,
-- so the rule is "stays 0" rather than "no worse than N". That is on purpose: four
-- separate stale baselines cost real time this session, and a fence with nothing to
-- calibrate cannot go stale.
os.exit((counts.authoritative or counts.seam) == 0 and 0 or 1)
