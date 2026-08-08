-- CLONES: structural duplication across a tree, as one command.
--   nvim --headless -u NONE -l tools/clones.lua [dir] [--min-rows N]
--                                               [--blocks [--min-len N]]
--                                               [--near [--max-dist N]]
-- Rides the shipped expression-IR (cartograph.expr) — two functions are clones iff
-- their per-row canonical key sequences match, ALPHA-INVARIANT on locals (callees /
-- globals / operators / literals kept). Three tiers:
--   default    FUNCTION-granular exact-structural clones.
--   --blocks   contiguous statement BLOCKS shared across/within functions (window-local
--              alpha-invariance; catches the extract↔relink resolve dup a fn-tier misses).
--   --near     NEAR-clones: whole functions whose row sequences differ by ≤ max-dist edits
--              (anti-unification — matched rows = shared template, differing rows = holes).
-- Defaults to the whole repo (lua + tests + tools), where the spec-helper duplication lives
-- — the routine self-analysis scopes lua/ only, so this is the surface that SEES it.
-- [[cartograph-record-fold-arc]] near-clone arc (exact + block + near tiers).

local here = debug.getinfo(1, 'S').source:sub(2)
local repo = vim.fn.fnamemodify(here, ':p:h:h')
vim.opt.rtp:prepend(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
package.path = repo .. '/lua/?.lua;' .. repo .. '/lua/?/init.lua;' .. package.path

local root, min_rows, mode, min_len, max_dist = repo, 3, 'exact', 6, 2
local i = 1
while arg and arg[i] do
    if arg[i] == '--min-rows' then i = i + 1; min_rows = tonumber(arg[i]) or min_rows
    elseif arg[i] == '--blocks' then mode = 'blocks'
    elseif arg[i] == '--near' then mode = 'near'
    elseif arg[i] == '--min-len' then i = i + 1; min_len = tonumber(arg[i]) or min_len
    elseif arg[i] == '--max-dist' then i = i + 1; max_dist = tonumber(arg[i]) or max_dist
    else root = vim.fn.expand(arg[i]) end
    i = i + 1
end

local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local clones = require 'cartograph.clones'

store.ingest(ts.extract(root))
local lines
if mode == 'blocks' then
    lines = clones.blocks_report(
        clones.classify_blocks(store, clones.blocks(store, { min_len = min_len })))
elseif mode == 'near' then
    lines = clones.near_report(clones.near(store, { max_dist = max_dist }), store)
else
    lines = clones.report(clones.exact(store, { min_rows = min_rows }))
end
for _, line in ipairs(lines) do print(line) end
