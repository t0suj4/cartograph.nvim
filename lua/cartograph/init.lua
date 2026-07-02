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
    local plan    = require 'cartograph.panes.plan'

    store.load(vim.fn.expand(dump_path))

    -- ONE hardcoded layout for now: the browser on the left, the source split
    -- taking the rest (the browser's descend covers uses/callers now, so the
    -- code gets the width; the trace pane opens its own split on demand), and
    -- a full-width plan bar along the bottom.
    vim.cmd('tabnew')
    local w_symbols = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(w_symbols, symbols.create())

    vim.cmd('rightbelow vsplit')
    local w_source = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(w_source, source.create())

    vim.api.nvim_win_set_width(w_symbols, 38)

    source.attach(w_source)

    -- full-width plan bar at the very bottom
    vim.cmd('botright split')
    local w_plan = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(w_plan, plan.create())
    vim.api.nvim_win_set_height(w_plan, 10)

    vim.api.nvim_set_current_win(w_symbols)
    symbols.attach(w_symbols)

    -- focus history, vim-jumplist style: back/back_alt everywhere, forward only
    -- where the cycle key (<Tab> = <C-i> in most terminals) isn't taken —
    -- symbols uses <Tab> for the file-view toggle, source for the lens.
    local keys = require('cartograph.config').keys
    for _, b in ipairs({ { symbols.buf }, { plan.buf, true },
                         { source.buf }, { source.buf_bot } }) do
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
    local SEV = { warn = 'W', info = 'I' }
    pcall(vim.api.nvim_del_user_command, 'CartographLint')
    vim.api.nvim_create_user_command('CartographLint', function ()
        local findings = require('cartograph.lint').run(store)
        if #findings == 0 then return vim.notify('cartograph: no lint findings', vim.log.levels.INFO) end
        local qf = {}
        for _, f in ipairs(findings) do
            qf[#qf + 1] = { filename = f.file, lnum = f.line, col = 1,
                type = SEV[f.severity] or 'E',
                text = ('[%s] %s'):format(f.rule, f.message),
                user_data = f.fix }
        end
        vim.fn.setqflist({}, ' ', { title = 'cartograph lint', items = qf })
        vim.cmd('copen')
    end, { desc = 'cartograph: graph-aware lint (dead code, redundant requires, call cycles) -> quickfix' })

    -- apply the quick fix (an annotation line) of the CURRENT quickfix entry
    pcall(vim.api.nvim_del_user_command, 'CartographLintFix')
    vim.api.nvim_create_user_command('CartographLintFix', function ()
        local qf = vim.fn.getqflist({ idx = 0, items = 1 })
        local it = qf.items[qf.idx]
        local fix = it and it.user_data
        if type(fix) ~= 'table' or not fix.text then
            return vim.notify('cartograph: no quick fix on this finding', vim.log.levels.WARN)
        end
        -- insert above the target line, via the buffer so open edits are respected
        local buf = vim.fn.bufadd(fix.file)
        vim.fn.bufload(buf)
        local target = vim.api.nvim_buf_get_lines(buf, fix.line, fix.line + 1, false)[1] or ''
        local indent = target:match('^%s*') or ''
        vim.api.nvim_buf_set_lines(buf, fix.line, fix.line, false, { indent .. fix.text })
        vim.api.nvim_buf_call(buf, function () vim.cmd('silent noautocmd write') end)
        vim.notify(('cartograph: inserted `%s` at %s:%d — regenerate the graph to re-check'):format(
            fix.text, vim.fn.fnamemodify(fix.file, ':t'), fix.line + 1), vim.log.levels.INFO)
    end, { desc = 'cartograph: apply the annotation quick fix of the current quickfix entry' })

    -- open the browser on the first file, and focus its first function
    -- explicitly (hover never focuses — pivots are conscious)
    symbols.show('file', store.files[1])
    for _, n in ipairs(store.by_file[store.files[1]] or {}) do
        if n.kind == 'function' or n.kind == 'method' then
            store.set_focus(n.id)
            break
        end
    end
end

return M
