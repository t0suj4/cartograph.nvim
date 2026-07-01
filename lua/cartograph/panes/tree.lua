-- CENTER pane: the focus+context dependency tree. For the focused function it
-- shows `uses ▾` (functions it references) and `used by ▾` (functions that
-- reference it) — cross-file edges marked. <CR> on an entry PIVOTS: re-roots the
-- whole cockpit on that node (navigation = re-rooting).

local store = require 'cartograph.store'

local M = { line_node = {} }

function M.create()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = 'wipe'
    vim.bo[buf].filetype  = 'cartograph-tree'
    M.buf = buf
    store.on_focus(function (id) M.render(id) end)

    vim.keymap.set('n', '<CR>', function ()
        local row = vim.api.nvim_win_get_cursor(0)[1]
        local id  = M.line_node[row]
        if id then store.set_focus(id) end
    end, { buffer = buf, nowait = true, desc = 'cartograph: pivot to this node' })

    return buf
end

--- Hovering a `uses` entry highlights its call site(s) in the source pane.
function M.attach(win)
    vim.api.nvim_create_autocmd('CursorMoved', {
        buffer = M.buf,
        callback = function ()
            local row     = vim.api.nvim_win_get_cursor(win)[1]
            local id      = M.line_node[row]
            local focused = store.focused
            -- a `uses` entry has occurrences of `id` inside the focused function
            local occ = id and focused and store.occurrences(focused, id)
            if occ then
                store.set_highlight({ file = store.node(focused).file, ranges = occ })
            else
                store.set_highlight(nil)
            end
        end,
    })
end

-- append a labelled branch; record entry rows -> node id in `line_node`
local function branch(lines, line_node, label, ids, from)
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
    end
end

---@param id string?
function M.render(id)
    local node = store.node(id)
    local lines, line_node = {}, {}
    if not node then
        lines = { '(no selection)' }
    else
        lines[#lines + 1] = (node.kind == 'method' and ': ' or 'ƒ ') .. node.name
        line_node[#lines] = false
        lines[#lines + 1] = ''
        line_node[#lines] = false
        branch(lines, line_node, 'uses',    store.uses[id],   node)
        lines[#lines + 1] = ''
        line_node[#lines] = false
        branch(lines, line_node, 'used by', store.usedby[id], node)
    end
    M.line_node = line_node
    vim.bo[M.buf].modifiable = true
    vim.api.nvim_buf_set_lines(M.buf, 0, -1, false, lines)
    vim.bo[M.buf].modifiable = false
end

return M
