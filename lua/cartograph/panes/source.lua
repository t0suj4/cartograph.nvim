-- SOURCE pane: the real code — the "have I seen this?" recognition anchor. It is
-- a horizontal SPLIT:
--   TOP    = the focused function's definition. Subscribes to focus.
--   BOTTOM = the *other end* of the hovered dependency edge. For a `uses` entry
--            that's the callee's definition; for a `used by` entry it's the
--            caller's body with the call site highlighted.
-- Together: def above, call site below — compare where you are with where a
-- reference actually happens, without leaving the focused node.

local store    = require 'cartograph.store'
local untangle = require 'cartograph.untangle'
local extract  = require 'cartograph.extract'
local hl       = require 'cartograph.hl'

local HEADER_ROWS = 2 -- header line + blank before the code body
local ns = vim.api.nvim_create_namespace('cartograph_source_hl')
local ns_concern = vim.api.nvim_create_namespace('cartograph_source_concern')

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

-- Smart scroll: keep buffer row `row0` visible in `win`. No motion while it's
-- on-screen; once off-screen, center it — centering naturally tops out at the
-- buffer start, so early lines keep the header in view instead of leaving
-- blank space above.
local function ensure_visible(win, row0)
    if not (win and vim.api.nvim_win_is_valid(win)) or not row0 then return end
    local lnum = row0 + 1
    if lnum >= vim.fn.line('w0', win) and lnum <= vim.fn.line('w$', win) then return end
    vim.api.nvim_win_call(win, function ()
        pcall(vim.api.nvim_win_set_cursor, win, { lnum, 0 })
        vim.cmd('normal! zz')
    end)
end

-- A fresh body render must not inherit the window's old scroll position.
local function scroll_top(win)
    if win and vim.api.nvim_win_is_valid(win) then
        pcall(vim.api.nvim_win_set_cursor, win, { 1, 0 })
    end
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

-- Untangle lens: colour the TOP body's lines by concern (the untangle
-- partition of the focused function). Each statement colours the line range
-- from its line up to the next statement's, so concerns read as bands over the
-- real code. Active while the 'concerns' lens is on (<Tab> here toggles it);
-- the tangle metrics ride the header line as virtual text.
local function apply_concerns(node)
    if not vim.api.nvim_buf_is_valid(M.buf) then return end
    vim.api.nvim_buf_clear_namespace(M.buf, ns_concern, 0, -1)
    if store.lens ~= 'concerns' or not node or not node.df then return end
    local a = untangle.analyze(node.df)
    pcall(vim.api.nvim_buf_set_extmark, M.buf, ns_concern, 0, 0, {
        virt_text = { { ('concerns %d · tangle %d · span %d'):format(a.ncomp, a.tangle, a.maxspan),
            'CartographDim' } },
        virt_text_pos = 'eol',
    })
    local stmts, endLine = node.df.stmts, node.range['end'].line + 1 -- 1-based
    for i, s in ipairs(stmts) do
        local last = (stmts[i + 1] and stmts[i + 1].l - 1) or endLine
        local group = hl.concern(a.comp[i])
        for fl = s.l, last do
            local row = buf_row(node, fl - 1) -- buf_row takes 0-based file line
            if row then
                pcall(vim.api.nvim_buf_set_extmark, M.buf, ns_concern, row, 0,
                    { line_hl_group = group })
            end
        end
    end
end

-- Resolve a <C-]> jump target under the cursor: prefer the recorded occurrence
-- range at (file_line, col); fall back to matching the cursor word against the
-- names of `node`'s uses-edges (last path segment, so `M.foo` matches `foo`) —
-- nil when nothing matches or the word is ambiguous.
function M.resolve_jump(node, file_line, col, cword)
    if not node then return nil end
    local byword
    for _, to in ipairs(store.uses[node.id] or {}) do
        for _, r in ipairs(store.occurrences(node.id, to) or {}) do
            if r.start.line == file_line and col >= r.start.char
                and (r['end'].line > file_line or col < r['end'].char) then
                return to
            end
        end
        local tn = store.node(to)
        local last = tn and tn.name and tn.name:match('([%w_]+)$')
        if cword and cword ~= '' and last == cword then
            byword = byword == nil and to or false -- false = ambiguous
        end
    end
    return byword or nil
end

-- The file line (0-based) the cursor in `win` is sitting on, given the node the
-- buffer renders; nil on the header rows.
local function cursor_file_line(win, node)
    if not node then return nil end
    local row0 = vim.api.nvim_win_get_cursor(win)[1] - 1
    if row0 < HEADER_ROWS then return nil end
    local fl = node.range.start.line + (row0 - HEADER_ROWS)
    if fl > node.range['end'].line then return nil end
    return fl
end

-- gf: leave the cockpit — open the real file in a (reused) tab, at the line the
-- cursor corresponds to (the node's first line when on a header row).
local function goto_real(win, node)
    if not node then return end
    local fl = cursor_file_line(win, node) or node.range.start.line
    vim.cmd('tab drop ' .. vim.fn.fnameescape(store.abspath(node)))
    pcall(vim.api.nvim_win_set_cursor, 0, { fl + 1, 0 })
end

-- Navigation verbs for a source buffer: <C-]> pivots to the definition of the
-- call under the cursor (tags idiom), gf opens the real file. `which` picks the
-- node the buffer renders (focused def on top, hovered context below).
local function bind_nav(buf, which)
    local keys = require('cartograph.config').keys
    vim.keymap.set('n', keys.jump, function ()
        local node = which()
        if not node then return end
        local win = vim.api.nvim_get_current_win()
        local fl  = cursor_file_line(win, node)
        local col = vim.api.nvim_win_get_cursor(win)[2]
        local to  = M.resolve_jump(node, fl, col, vim.fn.expand('<cword>'))
        if to then store.pivot(to)
        else vim.notify('cartograph: no known callee under the cursor', vim.log.levels.INFO) end
    end, { buffer = buf, desc = 'cartograph: jump to the definition under the cursor' })
    vim.keymap.set('n', keys.open_file, function () goto_real(vim.api.nvim_get_current_win(), which()) end,
        { buffer = buf, desc = 'cartograph: open the real file here' })
    -- trace where the parameter under the cursor comes from ("references"
    -- flavoured — the places that feed this value)
    vim.keymap.set('n', keys.trace, function ()
        local node = which()
        if not node then return end
        local cword = vim.fn.expand '<cword>'
        for i, p in ipairs(node.params or {}) do
            if p == cword then
                return require('cartograph.panes.trace').open(node.id, i, p)
            end
        end
        vim.notify(('cartograph: %q is not a parameter of %s'):format(cword, node.name or '?'),
            vim.log.levels.INFO)
    end, { buffer = buf, desc = 'cartograph: trace where this parameter comes from' })
end

-- The flow lens lives in the code pane, where the concern colours land on the
-- real code: <Tab> toggles it without leaving the source you're reading.
local function bind_cycle(buf)
    local keys = require('cartograph.config').keys
    local function toggle()
        store.set_lens(store.lens ~= 'concerns' and 'concerns' or nil)
    end
    vim.keymap.set('n', keys.cycle, toggle, { buffer = buf, desc = 'cartograph: toggle the flow (concern) lens' })
    vim.keymap.set('n', keys.cycle_back, toggle, { buffer = buf, desc = 'cartograph: toggle the flow (concern) lens' })
end

-- Extract the selected TOP-pane lines into a new local function. `line1`/`line2`
-- are 1-based rows in the top buffer; the body starts at row HEADER_ROWS. Shows
-- a preview in the bottom pane and asks before writing anything to disk.
function M.extract(line1, line2, name)
    local node = M.cur
    if not node then return vim.notify('cartograph: no function focused', vim.log.levels.WARN) end
    local fn_start = node.range.start.line + 1        -- 1-based
    local body_end = node.range['end'].line           -- last body line (before `end`)
    -- top buffer row 3 (1-based) shows file line fn_start
    local file_first = fn_start + (line1 - (HEADER_ROWS + 1))
    local file_last  = fn_start + (line2 - (HEADER_ROWS + 1))

    local ok, all = pcall(vim.fn.readfile, store.abspath(node))
    if not ok then return vim.notify('cartograph: cannot read ' .. node.file, vim.log.levels.ERROR) end

    local plan = extract.plan { df = node.df, sel = { first = file_first, last = file_last },
        fn_start = fn_start, body_end = body_end, file_lines = all, name = name }
    if not plan.ok then
        -- persist the reason in the bottom pane (a transient notify is easy to miss)
        if M.buf_bot and vim.api.nvim_buf_is_valid(M.buf_bot) then
            local msg = { ('── cannot extract lines %d-%d'):format(file_first, file_last), '' }
            msg[#msg + 1] = plan.reason
            msg[#msg + 1] = ''
            msg[#msg + 1] = 'Extract works on whole top-level statements of a function.'
            set_lines(M.buf_bot, msg)
        end
        return vim.notify('cartograph: cannot extract — ' .. plan.reason, vim.log.levels.WARN)
    end

    -- preview in the bottom pane
    local prev = { ('── extract preview: %s(%s)%s'):format(name, table.concat(plan.params, ', '),
        #plan.returns > 0 and ('  ->  ' .. table.concat(plan.returns, ', ')) or ''), '' }
    for _, l in ipairs(plan.new_fn) do prev[#prev + 1] = l end
    prev[#prev + 1] = ''
    prev[#prev + 1] = ('call replaces %s:%d-%d:'):format(node.file, plan.replace.first, plan.replace.last)
    for _, l in ipairs(plan.call) do prev[#prev + 1] = l end
    for _, h in ipairs(plan.hazards) do prev[#prev + 1] = '⚠ ' .. h end
    if M.buf_bot and vim.api.nvim_buf_is_valid(M.buf_bot) then set_lines(M.buf_bot, prev) end

    if vim.fn.confirm(('Extract %d line(s) into %s()?'):format(file_last - file_first + 1, name),
            '&Apply\n&Cancel', 2) ~= 1 then
        return vim.notify('cartograph: extract cancelled', vim.log.levels.INFO)
    end
    vim.fn.writefile(extract.apply(plan, all), store.abspath(node))
    vim.notify(('cartograph: extracted %s(). Regenerate the graph dump to refresh the cockpit.'):format(name),
        vim.log.levels.INFO)
end

function M.create()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = 'wipe'
    vim.bo[buf].filetype  = 'lua'
    M.buf = buf
    vim.api.nvim_buf_create_user_command(buf, 'CartographExtract', function (o)
        M.extract(o.line1, o.line2, o.fargs[1])
    end, { range = true, nargs = 1, desc = 'cartograph: extract selected lines into a function' })
    hl.setup()
    vim.api.nvim_create_autocmd('ColorScheme', { callback = hl.setup })
    store.on_focus(function (id) M.render(id) end)
    store.on_highlight(function (hlv) M.highlight(hlv) end)
    store.on_context(function (ctx) M.context(ctx) end)
    store.on_lens(function () apply_concerns(M.cur) end)
    bind_cycle(buf)
    bind_nav(buf, function () return M.cur end)
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
    bind_cycle(b)
    bind_nav(b, function () return M.ctx end)

    vim.api.nvim_set_current_win(win)
    M.context(nil)
end

---@param id string?
function M.render(id)
    local node = store.node(id)
    M.cur = node
    set_lines(M.buf, body_lines(node))
    scroll_top(M.win_top) -- a fresh body starts at its header
    apply_concerns(node)  -- repaint concern bands if the lens is on
    M.context(nil) -- a new focus clears the stale bottom view
end

---@param hl {file:string, ranges:table}?
function M.highlight(hl)
    if not vim.api.nvim_buf_is_valid(M.buf) then return end
    vim.api.nvim_buf_clear_namespace(M.buf, ns, 0, -1)
    if not hl or not M.cur or hl.file ~= M.cur.file then return end
    apply_hl(M.buf, M.cur, hl.ranges)
    local r = hl.ranges and hl.ranges[1]
    if r then ensure_visible(M.win_top, buf_row(M.cur, r.start.line)) end
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
    scroll_top(M.win_bot)
    if ctx.ranges then
        apply_hl(M.buf_bot, M.ctx, ctx.ranges)
        local r = ctx.ranges[1]
        if r then ensure_visible(M.win_bot, buf_row(M.ctx, r.start.line)) end
    end
end

return M
