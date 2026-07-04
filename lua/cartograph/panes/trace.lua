-- TRACE pane: where does this parameter's value come from? An incrementally
-- expandable origin tree — one row per value source, <CR> expands a row into
-- its next hop (up the call graph, through a return, into a local's defs).
-- Frontiers that can't be traced statically (fields/globals, dynamic calls,
-- varargs) stay visible with the reason, instead of silently vanishing.
--
-- Presentation: descriptions are compact (a literal is shown as itself — it IS
-- the answer), locations are dim virtual text after the row, kinds are
-- distinguished by highlight, not by longer words.
--
-- Borrows the tree pane's window while open; `q` gives it back.

local store  = require 'cartograph.store'
local trace  = require 'cartograph.trace'
local hl     = require 'cartograph.hl'
local config = require 'cartograph.config'

local ns = vim.api.nvim_create_namespace('cartograph_trace')

local M = { rows = {} } -- rows[i] = { origin, depth, open, note }

local HEADER = 2 -- title + blank, before the first row

local MARK = {
    open     = { '▾', 'CartographMarker' },
    closed   = { '▸', 'CartographMarker' },
    terminal = { '·', 'CartographLit' },
    frontier = { '⊘', 'CartographFrontier' },
}

local function render()
    if not (M.buf and vim.api.nvim_buf_is_valid(M.buf)) then return end
    local lines, marks, virt = {}, {}, {}
    local pre = M.dispatch and 'dispatch of ' or 'origins of '
    lines[1] = ('%s%s   (%s)'):format(pre, M.pname, M.fname)
    marks[1] = { { 0, #pre, 'CartographDim' }, { #pre, #pre + #M.pname, 'CartographTitle' },
                 { #pre + #M.pname, -1, 'CartographDim' } }
    lines[2] = ''

    for _, r in ipairs(M.rows) do
        local desc, expandable, class = trace.describe(store, r.origin)
        local mark = r.note and MARK.frontier
            or (expandable and (r.open and MARK.open or MARK.closed) or MARK.terminal)
        local indent = string.rep('  ', r.depth)
        lines[#lines + 1] = ('%s%s %s'):format(indent, mark[1], desc)
        local mstart = #indent
        local dstart = mstart + #mark[1] + 1
        marks[#lines] = { { mstart, dstart, mark[2] } }
        if class == 'lit' then
            marks[#lines][#marks[#lines] + 1] = { dstart, -1, 'CartographLit' }
        elseif class == 'dim' then
            marks[#lines][#marks[#lines] + 1] = { dstart, -1, 'CartographDim' }
        end
        local s = r.origin.site
        if s then
            local loc = ('%s:%d'):format(s.file, s.line + 1)
            local fn = r.origin.fn and trace.short(store, r.origin.fn)
            virt[#lines] = fn and (loc .. ' · ' .. fn) or loc
        end
        if r.note then
            lines[#lines + 1] = ('%s   └ %s'):format(indent, r.note)
            marks[#lines] = { { 0, -1, 'CartographDim' } }
        end
    end
    if #M.rows == 0 then
        lines[#lines + 1] = '(no resolved call sites)'
        marks[#lines] = { { 0, -1, 'CartographDim' } }
        if M.note then
            lines[#lines + 1] = '└ ' .. M.note
            marks[#lines] = { { 0, -1, 'CartographDim' } }
        end
    end

    vim.bo[M.buf].modifiable = true
    for j, l in ipairs(lines) do
        if l:find('[\n\r]') then lines[j] = l:gsub('[\n\r]+', ' \u{B6} ') end
    end
    vim.api.nvim_buf_set_lines(M.buf, 0, -1, false, lines)
    vim.bo[M.buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(M.buf, ns, 0, -1)
    for row, ms in pairs(marks) do
        for _, m in ipairs(ms) do
            local endc = m[2] >= 0 and m[2] or #lines[row]
            pcall(vim.api.nvim_buf_set_extmark, M.buf, ns, row - 1, m[1],
                { end_col = endc, hl_group = m[3] })
        end
    end
    for row, text in pairs(virt) do
        pcall(vim.api.nvim_buf_set_extmark, M.buf, ns, row - 1, 0,
            { virt_text = { { text, 'CartographDim' } }, virt_text_pos = 'eol' })
    end
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

-- Hovering a row drives the BOTTOM source view, like the dependency tree's
-- hover: show the origin's function with the origin line highlighted.
local function hover(win)
    local r = M.rows[row_at(vim.api.nvim_win_get_cursor(win)[1]) or -1]
    if r and r.origin.fn and r.origin.site then
        store.set_context({ node = r.origin.fn, ranges = {
            { start = { line = r.origin.site.line, char = 0 },
              ['end'] = { line = r.origin.site.line + 1, char = 0 } },
        } })
    else
        store.set_context(nil)
    end
end

function M.close()
    store.set_context(nil)
    if M.win and vim.api.nvim_win_is_valid(M.win)
        and #vim.api.nvim_tabpage_list_wins(0) > 1 then
        vim.api.nvim_win_close(M.win, true)
    end
    M.win = nil
end

local function create()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = 'wipe'
    vim.bo[buf].filetype  = 'cartograph-trace'
    M.buf = buf
    hl.ui()
    local keys = config.keys
    local function cur_row() return row_at(vim.api.nvim_win_get_cursor(0)[1]) end
    vim.keymap.set('n', keys.pivot, function ()
        local ri = cur_row()
        if ri then toggle(ri) end
    end, { buffer = buf, nowait = true, desc = 'cartograph: expand / collapse this origin' })
    vim.keymap.set('n', keys.open_file, function ()
        local r = M.rows[cur_row() or -1]
        if not (r and r.origin.site) then return end
        vim.cmd('tab drop ' .. vim.fn.fnameescape(store.data.root .. '/' .. r.origin.site.file))
        pcall(vim.api.nvim_win_set_cursor, 0, { r.origin.site.line + 1, 0 })
    end, { buffer = buf, desc = 'cartograph: open the real file at this origin' })
    vim.keymap.set('n', keys.jump, function ()
        local r = M.rows[cur_row() or -1]
        if r and r.origin.fn then store.pivot(r.origin.fn) end
    end, { buffer = buf, desc = 'cartograph: pivot the cockpit to this origin\'s function' })
    vim.keymap.set('n', keys.pin, function ()
        local r = M.rows[cur_row() or -1]
        if not M.dispatch then
            return vim.notify('cartograph: not a dispatch trace — nothing to pin',
                vim.log.levels.WARN)
        end
        local v = r and r.origin.v
        if not (v and v.k == 'lit' and type(v.v) == 'string') then
            return vim.notify('cartograph: pin a LITERAL origin (the string is the target)',
                vim.log.levels.WARN)
        end
        M.pin(v.v)
    end, { buffer = buf, desc = 'cartograph: pin this literal as the dispatch target' })
    vim.keymap.set('n', keys.close, M.close, { buffer = buf, desc = 'cartograph: close the trace' })
    vim.keymap.set('n', keys.back,     store.back,    { buffer = buf, desc = 'cartograph: back' })
    vim.keymap.set('n', keys.back_alt, store.back,    { buffer = buf, desc = 'cartograph: back' })
    vim.keymap.set('n', keys.forward,  store.forward, { buffer = buf, desc = 'cartograph: forward' })

    -- debounced hover -> bottom source view (same pattern as the tree pane)
    local gen = 0
    vim.api.nvim_create_autocmd('CursorMoved', {
        buffer = buf,
        callback = function ()
            gen = gen + 1
            local g = gen
            vim.defer_fn(function ()
                if g ~= gen then return end
                local win = (vim.fn.win_findbuf(buf) or {})[1]
                if win then hover(win) end
            end, 60)
        end,
    })
    return buf
end

--- Open the trace for parameter `i` (1-based, self included) of function `fn_id`.
--- `dispatch` marks this as a dispatch trace: the call whose dynamic callee
--- is the traced parameter — literal origins become pinnable targets.
function M.open(fn_id, i, pname, dispatch)
    local node = store.node(fn_id)
    if not node then return end
    M.dispatch = dispatch
    M.fname, M.pidx, M.pname = node.name or '?', i, pname or '?'
    local origins, note = trace.origins(store, fn_id, i)
    M.rows, M.note = {}, note
    for _, o in ipairs(origins) do M.rows[#M.rows + 1] = { origin = o, depth = 0 } end

    if not (M.buf and vim.api.nvim_buf_is_valid(M.buf)) then create() end
    -- the trace owns a right-hand split, opened on demand and reused
    if not (M.win and vim.api.nvim_win_is_valid(M.win)) then
        vim.cmd('botright vsplit')
        M.win = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_width(M.win, 44)
    end
    vim.api.nvim_win_set_buf(M.win, M.buf)
    vim.api.nvim_set_current_win(M.win)
    vim.wo[M.win].cursorline = true
    render()
    pcall(vim.api.nvim_win_set_cursor, M.win, { HEADER + 1, 0 })
    hover(M.win) -- show the first origin's context immediately
end

--- Open the dispatch/origin trace for LOCAL `name` used at `line0` in
--- `fn_id`. Same pane, different root: the local's defining statements
--- (literal defs flattened to their pinnable values).
function M.open_local(fn_id, name, line0, dispatch)
    local node = store.node(fn_id)
    if not node then return end
    M.dispatch = dispatch
    M.fname, M.pidx, M.pname = node.name or '?', nil, name or '?'
    local origins, note = trace.origins_local(store, fn_id, name, line0)
    M.rows, M.note = {}, note
    for _, o in ipairs(origins) do M.rows[#M.rows + 1] = { origin = o, depth = 0 } end
    if not (M.buf and vim.api.nvim_buf_is_valid(M.buf)) then create() end
    if not (M.win and vim.api.nvim_win_is_valid(M.win)) then
        vim.cmd('botright vsplit')
        M.win = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_width(M.win, 44)
    end
    vim.api.nvim_win_set_buf(M.win, M.buf)
    vim.api.nvim_set_current_win(M.win)
    vim.wo[M.win].cursorline = true
    render()
    pcall(vim.api.nvim_win_set_cursor, M.win, { HEADER + 1, 0 })
    hover(M.win)
end

--- Pin `name` as the target of the dispatch call this trace was opened
--- for: runtime config entry, real edge, descend target — and a snippet to
--- make it durable.
function M.pin(name)
    local c = M.dispatch
    local target
    for _, n in ipairs(store.data.nodes) do
        if (n.kind == 'function' or n.kind == 'method') and n.name == name then
            if target then
                return vim.notify(('cartograph: %q is ambiguous (%s and %s)')
                    :format(name, target.file, n.file), vim.log.levels.WARN)
            end
            target = n
        end
    end
    if not target then
        return vim.notify(('cartograph: no function named %q in the graph'):format(name),
            vim.log.levels.WARN)
    end
    local cfg = require('cartograph.config')
    cfg.pins = cfg.pins or {}
    cfg.pins[#cfg.pins + 1] = { file = c.file, line = c.line + 1, to = name }
    -- apply surgically: the call resolves, the edge exists, views know
    for _, call in ipairs(store.data.calls or {}) do
        if call.file == c.file and call.line == c.line
            and call.callee == c.callee then
            call.to = target.id
            call.dynamic = nil
        end
    end
    local from = c.fn
    if from then
        store.add_edge({ from = from, to = target.id, kind = 'ref', xlang = true,
            at = { { start = { line = c.line, char = 0 },
                ['end'] = { line = c.line, char = 0 } } } })
    end
    require('cartograph.panes.symbols').render()
    vim.notify(("cartograph: pinned %s:%d -> %s — make it durable with:\n"
        .. "  setup{ pins = { { file = '%s', line = %d, to = '%s' } } }")
        :format(c.file, c.line + 1, name, c.file, c.line + 1, name),
        vim.log.levels.INFO)
end

return M
