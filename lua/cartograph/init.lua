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

    store.load(vim.fn.expand(dump_path))

    vim.cmd('tabnew')
    local left = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(left, symbols.create())

    vim.cmd('rightbelow vsplit')
    local right = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(right, source.create())

    vim.api.nvim_set_current_win(left)
    vim.api.nvim_win_set_width(left, 40)
    symbols.attach(left)

    -- focus the first real symbol so the source pane isn't blank
    vim.api.nvim_exec_autocmds('CursorMoved', { buffer = symbols.buf })
end

vim.api.nvim_create_user_command('Cartograph', function (o)
    M.open(o.args)
end, { nargs = 1, complete = 'file', desc = 'Open the cartograph cockpit on a graph dump' })

return M
