-- RIGHT pane: the real code at the focused location — the "have I seen this?"
-- recognition anchor. Subscribes to focus; reads the node's line range from disk
-- (schema {file, range} is all it needs → this pane also validates the schema).
-- Split def/call-site comparison comes later; for now it shows the definition.

local store = require 'cartograph.store'

local M = {}

function M.create()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = 'wipe'
    vim.bo[buf].filetype  = 'lua'
    M.buf = buf
    store.on_focus(function (id) M.render(id) end)
    return buf
end

---@param id string?
function M.render(id)
    local node = store.node(id)
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
end

return M
