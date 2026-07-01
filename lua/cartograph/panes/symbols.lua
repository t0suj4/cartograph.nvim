-- LEFT pane: the movable definitions (functions/methods) grouped by file, in
-- source order. Not a flat alphabetical dump — the ordering is the file's, and
-- moving the cursor writes focus to the store (which drives the source pane).

local store = require 'cartograph.store'

-- The cockpit's unit is the function. documentSymbol emits every local/field/
-- constant too; we show only the movable units here (richer nodes stay in the
-- dump for later panes).
local SHOWN = { ['function'] = true, method = true }

local M = { line_node = {} }

function M.create()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = 'wipe'
    vim.bo[buf].filetype  = 'cartograph-symbols'

    local lines, line_node = {}, {}
    for _, file in ipairs(store.files) do
        local defs = {}
        for _, n in ipairs(store.by_file[file] or {}) do
            if SHOWN[n.kind] then defs[#defs + 1] = n end
        end
        if #defs > 0 then
            lines[#lines + 1] = ('▸ %s  (%d)'):format(file, #defs)
            line_node[#lines] = false -- header row
            for _, n in ipairs(defs) do
                local icon = n.kind == 'method' and ':' or 'ƒ'
                lines[#lines + 1] = ('  %s %-24s L%d'):format(icon, n.name or '?', n.range.start.line + 1)
                line_node[#lines] = n.id
            end
        end
    end

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    M.buf = buf
    M.line_node = line_node
    return buf
end

--- Wire cursor movement in `win` to focus, so the source pane follows.
function M.attach(win)
    vim.api.nvim_create_autocmd('CursorMoved', {
        buffer = M.buf,
        callback = function ()
            local row = vim.api.nvim_win_get_cursor(win)[1]
            local id  = M.line_node[row]
            if id then store.set_focus(id) end
        end,
    })
end

return M
