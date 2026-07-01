-- RIGHT pane: the real code at the focused location — the "have I seen this?"
-- recognition anchor. Subscribes to focus; reads the node's line range from disk.
-- Also subscribes to the highlight channel: when a `uses` entry is hovered in the
-- tree, the call site(s) inside this body get highlighted.

local store = require 'cartograph.store'

local HEADER_ROWS = 2 -- header line + blank before the code body
local ns = vim.api.nvim_create_namespace('cartograph_source_hl')

local M = { cur = nil }

function M.create()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = 'wipe'
    vim.bo[buf].filetype  = 'lua'
    M.buf = buf
    store.on_focus(function (id) M.render(id) end)
    store.on_highlight(function (hl) M.highlight(hl) end)
    return buf
end

---@param id string?
function M.render(id)
    local node = store.node(id)
    M.cur = node
    if not node then return end
    local ok, all = pcall(vim.fn.readfile, store.abspath(node))
    if not ok then return end

    local s = node.range.start.line + 1     -- schema line is 0-based
    local e = node.range['end'].line + 1
    local body = { ('── %s   %s:%d-%d'):format(node.name or '?', node.file, s, e), '' }
    for i = math.max(1, s), math.min(#all, e) do
        body[#body + 1] = all[i]
    end

    vim.bo[M.buf].modifiable = true
    vim.api.nvim_buf_set_lines(M.buf, 0, -1, false, body)
    vim.bo[M.buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(M.buf, ns, 0, -1)
end

-- Map a 0-based file line to a 0-based buffer row in this pane (or nil if the
-- line isn't within the displayed body).
local function buf_row(node, file_line)
    local start = node.range.start.line
    if file_line < start or file_line > node.range['end'].line then return nil end
    return HEADER_ROWS + (file_line - start)
end

---@param hl {file:string, ranges:table}?
function M.highlight(hl)
    if not vim.api.nvim_buf_is_valid(M.buf) then return end
    vim.api.nvim_buf_clear_namespace(M.buf, ns, 0, -1)
    if not hl or not M.cur or hl.file ~= M.cur.file then return end
    for _, r in ipairs(hl.ranges or {}) do
        local row = buf_row(M.cur, r.start.line)
        if row then
            local col_end = (r['end'].line == r.start.line) and r['end'].char or -1
            pcall(vim.api.nvim_buf_set_extmark, M.buf, ns, row, r.start.char, {
                end_col = col_end >= 0 and col_end or nil,
                end_row = col_end < 0 and (row + 1) or nil,
                hl_group = 'IncSearch',
            })
        end
    end
end

return M
