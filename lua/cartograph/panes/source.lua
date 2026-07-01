-- SOURCE pane: the real code — the "have I seen this?" recognition anchor. It is
-- a horizontal SPLIT:
--   TOP    = the focused function's definition. Subscribes to focus.
--   BOTTOM = the *other end* of the hovered dependency edge. For a `uses` entry
--            that's the callee's definition; for a `used by` entry it's the
--            caller's body with the call site highlighted.
-- Together: def above, call site below — compare where you are with where a
-- reference actually happens, without leaving the focused node.

local store = require 'cartograph.store'

local HEADER_ROWS = 2 -- header line + blank before the code body
local ns = vim.api.nvim_create_namespace('cartograph_source_hl')

local M = { cur = nil, ctx = nil }

-- Lines for a node's body: a hard-context header + the real source range.
local function body_lines(node)
    if not node then return { '(nothing)' } end
    local ok, all = pcall(vim.fn.readfile, store.abspath(node))
    if not ok then return { ('── %s   %s  (unreadable)'):format(node.name or '?', node.file) } end
    local s = node.range.start.line + 1     -- schema line is 0-based
    local e = node.range['end'].line + 1
    local body = { ('── %s   %s:%d-%d'):format(node.name or '?', node.file, s, e), '' }
    for i = math.max(1, s), math.min(#all, e) do
        body[#body + 1] = all[i]
    end
    return body
end

local function set_lines(buf, lines)
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
end

-- Map a 0-based file line to a 0-based buffer row (or nil if outside the body).
local function buf_row(node, file_line)
    local start = node.range.start.line
    if file_line < start or file_line > node.range['end'].line then return nil end
    return HEADER_ROWS + (file_line - start)
end

-- Draw IncSearch extmarks for `ranges` (occurrence sites) inside `node`'s body.
local function apply_hl(buf, node, ranges)
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    for _, r in ipairs(ranges or {}) do
        local row = buf_row(node, r.start.line)
        if row then
            local col_end = (r['end'].line == r.start.line) and r['end'].char or -1
            pcall(vim.api.nvim_buf_set_extmark, buf, ns, row, r.start.char, {
                end_col = col_end >= 0 and col_end or nil,
                end_row = col_end < 0 and (row + 1) or nil,
                hl_group = 'IncSearch',
            })
        end
    end
end

function M.create()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = 'wipe'
    vim.bo[buf].filetype  = 'lua'
    M.buf = buf
    store.on_focus(function (id) M.render(id) end)
    store.on_highlight(function (hl) M.highlight(hl) end)
    store.on_context(function (ctx) M.context(ctx) end)
    return buf
end

-- Create the BOTTOM view by splitting the source window horizontally.
function M.attach(win)
    M.win_top = win
    local h = vim.api.nvim_win_get_height(win)
    vim.api.nvim_set_current_win(win)
    vim.cmd('belowright split')
    M.win_bot = vim.api.nvim_get_current_win()

    local b = vim.api.nvim_create_buf(false, true)
    vim.bo[b].bufhidden = 'wipe'
    vim.bo[b].filetype  = 'lua'
    M.buf_bot = b
    vim.api.nvim_win_set_buf(M.win_bot, b)
    vim.api.nvim_win_set_height(M.win_bot, math.max(6, math.floor(h * 0.4)))

    vim.api.nvim_set_current_win(win)
    M.context(nil)
end

---@param id string?
function M.render(id)
    local node = store.node(id)
    M.cur = node
    set_lines(M.buf, body_lines(node))
    M.context(nil) -- a new focus clears the stale bottom view
end

---@param hl {file:string, ranges:table}?
function M.highlight(hl)
    if not vim.api.nvim_buf_is_valid(M.buf) then return end
    vim.api.nvim_buf_clear_namespace(M.buf, ns, 0, -1)
    if not hl or not M.cur or hl.file ~= M.cur.file then return end
    apply_hl(M.buf, M.cur, hl.ranges)
end

---@param ctx {node:string, ranges:table?}?
function M.context(ctx)
    if not M.buf_bot or not vim.api.nvim_buf_is_valid(M.buf_bot) then return end
    M.ctx = ctx and store.node(ctx.node) or nil
    if not M.ctx then
        set_lines(M.buf_bot, { '', '   (hover a dependency to see the other side)' })
        return
    end
    set_lines(M.buf_bot, body_lines(M.ctx))
    if ctx.ranges then apply_hl(M.buf_bot, M.ctx, ctx.ranges) end
end

return M
