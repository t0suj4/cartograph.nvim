-- CENTER pane: the focus+context dependency tree. For the focused function it
-- shows `uses` (functions it references) and `used by` (functions that
-- reference it). <CR> on an entry PIVOTS: re-roots the whole cockpit on that
-- node (navigation = re-rooting).
--
-- Presentation: the pane is narrow, so locations live in right-aligned virtual
-- text (dim, clipped by nvim) instead of eating line columns, and structure is
-- carried by highlight groups rather than ASCII markers.

local store  = require 'cartograph.store'
local hl     = require 'cartograph.hl'
local config = require 'cartograph.config'

local ns = vim.api.nvim_create_namespace('cartograph_tree')

local M = { line_node = {}, line_dir = {} }

function M.create()
    local buf = vim.api.nvim_create_buf(false, true)
    -- 'hide', not 'wipe': the trace pane borrows this window, and 'wipe' would
    -- destroy the tree buffer the moment it stops being displayed
    vim.bo[buf].bufhidden = 'hide'
    vim.bo[buf].filetype  = 'cartograph-tree'
    M.buf = buf
    hl.ui()
    store.on_focus(function (id) M.render(id) end)

    local keys = config.keys
    local function pivot()
        local row = vim.api.nvim_win_get_cursor(0)[1]
        local id  = M.line_node[row]
        if id then store.pivot(id) end
    end
    vim.keymap.set('n', keys.pivot, pivot, { buffer = buf, nowait = true, desc = 'cartograph: pivot to this node' })
    vim.keymap.set('n', keys.jump,  pivot, { buffer = buf, desc = 'cartograph: pivot to this node' })
    vim.keymap.set('n', keys.open_file, function ()
        local n = store.node(M.line_node[vim.api.nvim_win_get_cursor(0)[1]])
        if not n then return end
        vim.cmd('tab drop ' .. vim.fn.fnameescape(store.abspath(n)))
        pcall(vim.api.nvim_win_set_cursor, 0, { n.range.start.line + 1, 0 })
    end, { buffer = buf, desc = 'cartograph: open the real file at this node' })

    return buf
end

--- Hovering an entry drives the split source pane. A `uses` entry highlights the
--- call site inside the focused function (top) and shows the callee's def
--- (bottom). A `used by` entry shows the caller's body (bottom) with the call
--- site highlighted there.
function M.attach(win)
    vim.wo[win].cursorline = true
    -- debounced: reading the cursor after a short settle keeps held-j scrolling
    -- from re-rendering the bottom source view on every line passed through
    local gen = 0
    vim.api.nvim_create_autocmd('CursorMoved', {
        buffer = M.buf,
        callback = function ()
            gen = gen + 1
            local g = gen
            vim.defer_fn(function ()
                if g ~= gen or not vim.api.nvim_win_is_valid(win) then return end
                M.hover(win)
            end, 60)
        end,
    })
end

function M.hover(win)
    local row     = vim.api.nvim_win_get_cursor(win)[1]
    local id      = M.line_node[row]
    local dir     = M.line_dir[row]
    local focused = store.focused
    if not (id and focused) then
        store.set_highlight(nil); store.set_context(nil); return
    end
    if dir == 'uses' then
        -- call site lives in the focused function; callee below
        local occ = store.occurrences(focused, id)
        store.set_highlight(occ and { file = store.node(focused).file, ranges = occ } or nil)
        store.set_context({ node = id })
    elseif dir == 'usedby' then
        -- call site lives in the caller's body; show it below, highlighted
        local occ = store.occurrences(id, focused)
        store.set_highlight(nil)
        store.set_context({ node = id, ranges = occ })
    else
        store.set_highlight(nil); store.set_context(nil)
    end
end

-- append a labelled branch; record entry rows -> node id in `line_node` and the
-- branch direction ('uses'/'usedby') in `line_dir`.
local function branch(ctx, label, dir, ids, from)
    local list = {}
    for _, id in ipairs(ids or {}) do
        local n = store.node(id)
        list[#list + 1] = { id = id, node = n, name = n and n.name or id }
    end
    table.sort(list, function (a, b) return a.name < b.name end)

    local L = ctx.lines
    L[#L + 1] = ('%s (%d)'):format(label, #list)
    ctx.marks[#L] = { { 0, #label, 'CartographSection' }, { #label, -1, 'CartographDim' } }
    for _, x in ipairs(list) do
        -- ~ = resolved by unique method name, not type inference (vm couldn't
        -- type the receiver, e.g. an instance fetched out of a storage table)
        local inf = from and store.edge_inferred[
            dir == 'uses' and (from.id .. '\31' .. x.id) or (x.id .. '\31' .. from.id)]
        local line = '  ' .. x.name .. (inf and ' ~' or '')
        L[#L + 1] = line
        if inf then ctx.marks[#L] = { { #line - 2, -1, 'CartographDim' } } end
        ctx.line_node[#L] = x.id
        ctx.line_dir[#L]  = dir
        if x.node and from and x.node.file ~= from.file then
            ctx.virt[#L] = x.node.file
        end
    end
end

---@param id string?
function M.render(id)
    if not (M.buf and vim.api.nvim_buf_is_valid(M.buf)) then return end
    local node = store.node(id)
    local ctx = { lines = {}, line_node = {}, line_dir = {}, marks = {}, virt = {} }
    if not node then
        ctx.lines[1] = '(no selection)'
        ctx.marks[1] = { { 0, -1, 'CartographDim' } }
    else
        local pre = node.kind == 'method' and ': ' or 'ƒ '
        ctx.lines[1] = pre .. (node.name or '?')
        ctx.marks[1] = { { 0, #pre, 'CartographDim' }, { #pre, -1, 'CartographTitle' } }
        ctx.lines[2] = ''
        branch(ctx, 'uses', 'uses', store.uses[id], node)
        ctx.lines[#ctx.lines + 1] = ''
        branch(ctx, 'used by', 'usedby', store.usedby[id], node)
    end
    M.line_node, M.line_dir = ctx.line_node, ctx.line_dir

    vim.bo[M.buf].modifiable = true
    vim.api.nvim_buf_set_lines(M.buf, 0, -1, false, ctx.lines)
    vim.bo[M.buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(M.buf, ns, 0, -1)
    for row, ms in pairs(ctx.marks) do
        for _, m in ipairs(ms) do
            local endc = m[2] >= 0 and m[2] or #ctx.lines[row]
            pcall(vim.api.nvim_buf_set_extmark, M.buf, ns, row - 1, m[1],
                { end_col = endc, hl_group = m[3] })
        end
    end
    for row, file in pairs(ctx.virt) do
        pcall(vim.api.nvim_buf_set_extmark, M.buf, ns, row - 1, 0,
            { virt_text = { { file .. ' ', 'CartographDim' } }, virt_text_pos = 'right_align' })
    end
end

return M
