-- cartograph.nvim — a dependency/definition cockpit for navigating a codebase's
-- symbol graph and staging multi-file function moves. Early / experimental.
--
-- The real machinery lives behind three seams (see README): a GraphProvider
-- (data in), an ImpactEngine (transforms), and the pane/store UI. This first
-- slice implements only: load a static dump → render the symbols + source panes
-- in one hardcoded layout. No hover-events beyond cursor→focus, no staging.

local M = {}

---@class cartograph.Config
local defaults = {}

---@param opts cartograph.Config?
function M.setup(opts)
    M.config = vim.tbl_deep_extend('force', defaults, opts or {})
end

--- Open the cockpit on a graph dump (neutral-schema JSON produced by the
--- provider). ONE hardcoded layout for now: symbols left, source right.
---@param dump_path string
function M.open(dump_path)
    local store   = require 'cartograph.store'
    local symbols = require 'cartograph.panes.symbols'
    local source  = require 'cartograph.panes.source'
    local tree    = require 'cartograph.panes.tree'

    store.load(vim.fn.expand(dump_path))

    -- ONE hardcoded layout for now: symbols | source | tree (left to right).
    vim.cmd('tabnew')
    local w_symbols = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(w_symbols, symbols.create())

    vim.cmd('rightbelow vsplit')
    local w_source = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(w_source, source.create())

    vim.cmd('rightbelow vsplit')
    local w_tree = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(w_tree, tree.create())

    vim.api.nvim_win_set_width(w_symbols, 34)
    vim.api.nvim_win_set_width(w_tree, 40)

    source.attach(w_source)
    vim.api.nvim_set_current_win(w_symbols)
    symbols.attach(w_symbols)
    tree.attach(w_tree)

    -- focus the first real symbol so source/tree aren't blank
    vim.api.nvim_exec_autocmds('CursorMoved', { buffer = symbols.buf })
end

return M
