-- TRACE pane: where does this parameter's value come from? An incrementally
-- expandable origin tree — one row per value source, <CR> expands a row into
-- its next hop (up the call graph, through a return, into a local's defs).
-- Frontiers that can't be traced statically (fields/globals, dynamic calls,
-- varargs) stay visible with the reason, instead of silently vanishing.
--
-- Borrows the tree pane's window while open; `q` gives it back.

local store = require 'cartograph.store'
local trace = require 'cartograph.trace'

local M = { rows = {} } -- rows[i] = { origin, depth, open, note }

local function set_lines(buf, lines)
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
end

local HEADER = 2 -- title + rule, before the first row

local function render()
    if not (M.buf and vim.api.nvim_buf_is_valid(M.buf)) then return end
    local lines = {
        ('trace: where does `%s` (param #%d of %s) come from?'):format(M.pname, M.pidx, M.fname),
        '─────────────────────────────────────────────',
    }
    for _, r in ipairs(M.rows) do
        local desc, expandable = trace.describe(store, r.origin)
        local mark = r.note and '⊘' or (expandable and (r.open and '▾' or '▸') or '·')
        local where = r.origin.site
            and ('%s:%d'):format(r.origin.site.file, r.origin.site.line + 1) or ''
        local infn = r.origin.fn and ('  (in %s)'):format(trace.short(store, r.origin.fn)) or ''
        lines[#lines + 1] = ('%s%s %-38s %s%s'):format(
            string.rep('  ', r.depth), mark, desc, where, infn)
        if r.note then
            lines[#lines + 1] = ('%s   └ %s'):format(string.rep('  ', r.depth), r.note)
        end
    end
    if #M.rows == 0 then
        lines[#lines + 1] = '(no resolved call sites)'
        if M.note then lines[#lines + 1] = '└ ' .. M.note end
    end
    set_lines(M.buf, lines)
end

-- map a buffer line back to its row index (notes belong to the row above)
local function row_at(lnum)
    local i = HEADER
    for ri, r in ipairs(M.rows) do
        i = i + 1
        if lnum == i then return ri end
        if r.note then
            i = i + 1
            if lnum == i then return ri end
        end
    end
end

local function toggle(ri)
    local r = M.rows[ri]
    if not r then return end
    if r.open then -- collapse: drop everything deeper that follows
        local j = ri + 1
        while M.rows[j] and M.rows[j].depth > r.depth do table.remove(M.rows, j) end
        r.open = false
    else
        local kids, note = trace.expand(store, r.origin)
        if not kids then
            r.note = note -- nil for terminals: nothing to add, and no complaint
        else
            for i = #kids, 1, -1 do
                table.insert(M.rows, ri + 1, { origin = kids[i], depth = r.depth + 1 })
            end
            r.open = true
        end
    end
    render()
end

function M.close()
    if M.borrowed_win and vim.api.nvim_win_is_valid(M.borrowed_win) then
        local tree = require 'cartograph.panes.tree'
        if tree.buf and vim.api.nvim_buf_is_valid(tree.buf) then
            vim.api.nvim_win_set_buf(M.borrowed_win, tree.buf)
        end
    end
end

local function create()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = 'wipe'
    vim.bo[buf].filetype  = 'cartograph-trace'
    M.buf = buf
    local function cur_row() return row_at(vim.api.nvim_win_get_cursor(0)[1]) end
    vim.keymap.set('n', '<CR>', function ()
        local ri = cur_row()
        if ri then toggle(ri) end
    end, { buffer = buf, nowait = true, desc = 'cartograph: expand / collapse this origin' })
    vim.keymap.set('n', 'gf', function ()
        local r = M.rows[cur_row() or -1]
        if not (r and r.origin.site) then return end
        vim.cmd('tab drop ' .. vim.fn.fnameescape(store.data.root .. '/' .. r.origin.site.file))
        pcall(vim.api.nvim_win_set_cursor, 0, { r.origin.site.line + 1, 0 })
    end, { buffer = buf, desc = 'cartograph: open the real file at this origin' })
    vim.keymap.set('n', '<C-]>', function ()
        local r = M.rows[cur_row() or -1]
        if r and r.origin.fn then store.pivot(r.origin.fn) end
    end, { buffer = buf, desc = 'cartograph: pivot the cockpit to this origin\'s function' })
    vim.keymap.set('n', 'q', M.close, { buffer = buf, desc = 'cartograph: close the trace' })
    vim.keymap.set('n', '<C-o>', store.back,    { buffer = buf, desc = 'cartograph: back' })
    vim.keymap.set('n', '<C-t>', store.back,    { buffer = buf, desc = 'cartograph: back' })
    vim.keymap.set('n', '<C-i>', store.forward, { buffer = buf, desc = 'cartograph: forward' })
    return buf
end

--- Open the trace for parameter `i` (1-based, self included) of function `fn_id`.
function M.open(fn_id, i, pname)
    local node = store.node(fn_id)
    if not node then return end
    M.fname, M.pidx, M.pname = node.name or '?', i, pname or '?'
    local origins, note = trace.origins(store, fn_id, i)
    M.rows, M.note = {}, note
    for _, o in ipairs(origins) do M.rows[#M.rows + 1] = { origin = o, depth = 0 } end

    if not (M.buf and vim.api.nvim_buf_is_valid(M.buf)) then create() end
    -- borrow the tree pane's window (or split if it isn't visible)
    local tree = require 'cartograph.panes.tree'
    local wins = tree.buf and vim.fn.win_findbuf(tree.buf) or {}
    M.borrowed_win = wins[1]
    if not M.borrowed_win then
        vim.cmd('botright vsplit')
        M.borrowed_win = vim.api.nvim_get_current_win()
    end
    vim.api.nvim_win_set_buf(M.borrowed_win, M.buf)
    vim.api.nvim_set_current_win(M.borrowed_win)
    render()
    pcall(vim.api.nvim_win_set_cursor, M.borrowed_win, { HEADER + 1, 0 })
end

return M
