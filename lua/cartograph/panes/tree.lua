-- CENTER pane: the focus+context dependency tree. For the focused function it
-- shows `uses ▾` (functions it references) and `used by ▾` (functions that
-- reference it) — cross-file edges marked. <CR> on an entry PIVOTS: re-roots the
-- whole cockpit on that node (navigation = re-rooting).

local store = require 'cartograph.store'

local M = { line_node = {}, line_dir = {} }

function M.create()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = 'wipe'
    vim.bo[buf].filetype  = 'cartograph-tree'
    M.buf = buf
    store.on_focus(function (id) M.render(id) end)

    local function pivot()
        local row = vim.api.nvim_win_get_cursor(0)[1]
        local id  = M.line_node[row]
        if id then store.pivot(id) end
    end
    vim.keymap.set('n', '<CR>',  pivot, { buffer = buf, nowait = true, desc = 'cartograph: pivot to this node' })
    vim.keymap.set('n', '<C-]>', pivot, { buffer = buf, desc = 'cartograph: pivot to this node' })
    vim.keymap.set('n', 'gf', function ()
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
local function branch(lines, line_node, line_dir, label, dir, ids, from)
    local list = {}
    for _, id in ipairs(ids or {}) do
        local n = store.node(id)
        list[#list + 1] = { id = id, node = n, name = n and n.name or id }
    end
    table.sort(list, function (a, b) return a.name < b.name end)

    lines[#lines + 1] = ('%s ▾  (%d)'):format(label, #list)
    line_node[#lines] = false
    if #list == 0 then
        lines[#lines + 1] = '    ·'
        line_node[#lines] = false
        return
    end
    for _, x in ipairs(list) do
        local cross = x.node and from and x.node.file ~= from.file
        lines[#lines + 1] = ('  %s %s%s'):format(
            cross and '→' or '·',
            x.name,
            (cross and x.node) and ('   [' .. x.node.file .. ']') or '')
        line_node[#lines] = x.id
        line_dir[#lines]  = dir
    end
end

---@param id string?
function M.render(id)
    local node = store.node(id)
    local lines, line_node, line_dir = {}, {}, {}
    if not node then
        lines = { '(no selection)' }
    else
        lines[#lines + 1] = (node.kind == 'method' and ': ' or 'ƒ ') .. node.name
        line_node[#lines] = false
        lines[#lines + 1] = ''
        line_node[#lines] = false
        branch(lines, line_node, line_dir, 'uses',    'uses',   store.uses[id],   node)
        lines[#lines + 1] = ''
        line_node[#lines] = false
        branch(lines, line_node, line_dir, 'used by', 'usedby', store.usedby[id], node)
    end
    M.line_node = line_node
    M.line_dir  = line_dir
    vim.bo[M.buf].modifiable = true
    vim.api.nvim_buf_set_lines(M.buf, 0, -1, false, lines)
    vim.bo[M.buf].modifiable = false
end

return M
