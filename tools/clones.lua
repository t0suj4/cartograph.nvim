-- CLONES: exact-structural duplication across a tree, as one command.
--   nvim --headless -u NONE -l tools/clones.lua [dir] [--min-rows N]
-- Rides the shipped expression-IR (cartograph.expr) — two functions are clones iff
-- their per-row canonical key sequences match, ALPHA-INVARIANT on locals (callees /
-- globals / operators / literals kept). Defaults to the whole repo (lua + tests + tools),
-- which is where the spec-helper duplication lives — the routine self-analysis scopes
-- lua/ only, so this is the surface that SEES it. [[cartograph-record-fold-arc]] near-clone
-- arc, EXACT tier. Function-granular (block/window granularity is the next increment).

local here = debug.getinfo(1, 'S').source:sub(2)
local repo = vim.fn.fnamemodify(here, ':p:h:h')
vim.opt.rtp:prepend(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
package.path = repo .. '/lua/?.lua;' .. repo .. '/lua/?/init.lua;' .. package.path

local root, min_rows = repo, 3
local i = 1
while arg and arg[i] do
    if arg[i] == '--min-rows' then i = i + 1; min_rows = tonumber(arg[i]) or min_rows
    else root = vim.fn.expand(arg[i]) end
    i = i + 1
end

local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local clones = require 'cartograph.clones'

store.ingest(ts.extract(root))
local groups = clones.exact(store, { min_rows = min_rows })
for _, line in ipairs(clones.report(groups)) do print(line) end
