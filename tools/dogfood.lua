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
os.exit(counts.seam == 0 and 0 or 1)
