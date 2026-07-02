-- cartograph.nvim — a dependency/definition cockpit for navigating a codebase's
-- symbol graph and staging multi-file function moves. Early / experimental.
--
-- The real machinery lives behind three seams (see README): a GraphProvider
-- (data in), an ImpactEngine (transforms), and the pane/store UI. This first
-- slice implements only: load a static dump → render the symbols + source panes
-- in one hardcoded layout. No hover-events beyond cursor→focus, no staging.

local M = {}

---@class cartograph.Config
---@field keys table<string, string>?  remap any binding (see cartograph/config.lua)
local defaults = {}

---@param opts cartograph.Config?
function M.setup(opts)
    M.config = vim.tbl_deep_extend('force', defaults, opts or {})
    require('cartograph.config').apply(opts)
end

--- Open the cockpit on a graph dump (neutral-schema JSON produced by the
--- provider). ONE hardcoded layout for now: symbols left, source right.
---@param dump_path string
function M.open(dump_path)
    local store   = require 'cartograph.store'
    local symbols = require 'cartograph.panes.symbols'
    local source  = require 'cartograph.panes.source'
    local tree    = require 'cartograph.panes.tree'
    local minimap = require 'cartograph.panes.minimap'
    local plan    = require 'cartograph.panes.plan'

    store.load(vim.fn.expand(dump_path))

    -- ONE hardcoded layout for now: symbols | source | tree across the top, and
    -- a full-width plan bar along the bottom.
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
    minimap.attach(w_tree)

    -- full-width plan bar at the very bottom
    vim.cmd('botright split')
    local w_plan = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(w_plan, plan.create())
    vim.api.nvim_win_set_height(w_plan, 10)

    vim.api.nvim_set_current_win(w_symbols)
    symbols.attach(w_symbols)
    tree.attach(w_tree)

    -- focus history, vim-jumplist style: back/back_alt everywhere, forward only
    -- where the cycle key (<Tab> = <C-i> in most terminals) isn't the lens.
    local keys = require('cartograph.config').keys
    for _, b in ipairs({ { symbols.buf, true }, { tree.buf, true }, { plan.buf, true },
                         { source.buf }, { source.buf_bot }, { minimap.buf } }) do
        local buf, fwd = b[1], b[2]
        if buf and vim.api.nvim_buf_is_valid(buf) then
            vim.keymap.set('n', keys.back,     store.back, { buffer = buf, desc = 'cartograph: back (previous pivot)' })
            vim.keymap.set('n', keys.back_alt, store.back, { buffer = buf, desc = 'cartograph: back (previous pivot)' })
            if fwd then
                vim.keymap.set('n', keys.forward, store.forward, { buffer = buf, desc = 'cartograph: forward' })
            end
        end
    end

    -- graph-aware lint -> quickfix
    pcall(vim.api.nvim_del_user_command, 'CartographLint')
    vim.api.nvim_create_user_command('CartographLint', function ()
        local findings = require('cartograph.lint').run(store)
        if #findings == 0 then return vim.notify('cartograph: no lint findings', vim.log.levels.INFO) end
        local qf = {}
        for _, f in ipairs(findings) do
            qf[#qf + 1] = { filename = f.file, lnum = f.line, col = 1,
                type = f.severity == 'warn' and 'W' or 'E',
                text = ('[%s] %s'):format(f.rule, f.message) }
        end
        vim.fn.setqflist({}, ' ', { title = 'cartograph lint', items = qf })
        vim.cmd('copen')
    end, { desc = 'cartograph: graph-aware lint (dead code, redundant requires, call cycles) -> quickfix' })

    -- focus the first real symbol so source/tree aren't blank
    vim.api.nvim_exec_autocmds('CursorMoved', { buffer = symbols.buf })
end

return M
