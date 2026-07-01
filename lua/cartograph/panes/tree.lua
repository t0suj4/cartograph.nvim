-- CENTER pane: the focus+context dependency tree. For the focused function it
-- shows `uses ▾` (functions it references) and `used by ▾` (functions that
-- reference it) — cross-file edges marked. First consumer of the graph `edges`.
-- Display-only for now; pivoting (re-root on an entry) comes next.

local store = require 'cartograph.store'

local M = {}

function M.create()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = 'wipe'
    vim.bo[buf].filetype  = 'cartograph-tree'
    M.buf = buf
    store.on_focus(function (id) M.render(id) end)
    return buf
end

-- sorted, with a cross-file marker relative to `from` node
local function branch(lines, label, ids, from)
    local list = {}
    for _, id in ipairs(ids or {}) do
        local n = store.node(id)
        list[#list + 1] = { id = id, node = n, name = n and n.name or id }
    end
    table.sort(list, function (a, b) return a.name < b.name end)
    lines[#lines + 1] = ('%s ▾  (%d)'):format(label, #list)
    if #list == 0 then
        lines[#lines + 1] = '    ·'
        return
    end
    for _, x in ipairs(list) do
        local cross = x.node and from and x.node.file ~= from.file
        lines[#lines + 1] = ('  %s %s%s'):format(
            cross and '→' or '·',
            x.name,
            (cross and x.node) and ('   [' .. x.node.file .. ']') or '')
    end
end

---@param id string?
function M.render(id)
    local node = store.node(id)
    local lines = {}
    if not node then
        lines = { '(no selection)' }
    else
        lines[#lines + 1] = (node.kind == 'method' and ': ' or 'ƒ ') .. node.name
        lines[#lines + 1] = ''
        branch(lines, 'uses',    store.uses[id],   node)
        lines[#lines + 1] = ''
        branch(lines, 'used by', store.usedby[id], node)
    end
    vim.bo[M.buf].modifiable = true
    vim.api.nvim_buf_set_lines(M.buf, 0, -1, false, lines)
    vim.bo[M.buf].modifiable = false
end

return M
