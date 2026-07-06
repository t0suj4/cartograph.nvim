-- SOURCE pane: the real code — the "have I seen this?" recognition anchor. It is
-- a horizontal SPLIT:
--   TOP    = the focused function's definition. Subscribes to focus.
--   BOTTOM = the *other end* of the hovered dependency edge. For a `uses` entry
--            that's the callee's definition; for a `used by` entry it's the
--            caller's body with the call site highlighted.
-- Together: def above, call site below — compare where you are with where a
-- reference actually happens, without leaving the focused node.

local store    = require 'cartograph.store'
local extract  = require 'cartograph.extract'
local hl       = require 'cartograph.hl'

local HEADER_ROWS = 2 -- header line + blank before the code body
local ns = vim.api.nvim_create_namespace('cartograph_source_hl')

local M = { cur = nil, ctx = nil }

-- node id -> 0-based first shown file line. A def's body is shown together
-- with its leading DOC COMMENT (the block right above the signature), so the
-- shown range starts above node.range.start; buf_row maps against this.
M._shown_start = {}
-- node id -> 0-based last shown file line (a top-level var widens to its region)
M._shown_end = {}

-- The smallest `region` node (a run of top-level statements) that encloses a
-- file-scope `var`, or nil. A lone top-level statement reads as an isolated
-- fragment; shown inside its region it has the surrounding code for context.
local function enclosing_region(node)
    if node.kind ~= 'var' then return nil end
    local reg
    for _, n in ipairs(store.by_file[node.file] or {}) do
        if n.kind == 'region'
            and n.range.start.line <= node.range.start.line
            and n.range['end'].line >= node.range['end'].line
            and (not reg or (n.range['end'].line - n.range.start.line)
                < (reg.range['end'].line - reg.range.start.line)) then
            reg = n
        end
    end
    return reg
end

-- Lines for a node's body: a hard-context header + the real source range.
local function body_lines(node)
    if not node then return { '(nothing)' } end
    local ok, all = pcall(vim.fn.readfile, store.abspath(node))
    if not ok then return { ('── %s   %s  (unreadable)'):format(node.name or '?', node.file) } end
    -- a top-level statement widens to the region it belongs to
    local shown = enclosing_region(node) or node
    local s = shown.range.start.line + 1     -- schema line is 0-based
    local e = shown.range['end'].line + 1
    -- show the def WITH its leading doc comment: walk up over the block that
    -- adheres to it (the same per-language patterns + file-header decline the
    -- edit verbs use), so focusing a symbol shows what it's FOR, not just its
    -- signature. Python-style docstrings live inside [s,e] and already show.
    local ds = shown.range.start.line -- 0-based first shown line
    local pats = require('cartograph.providers.treesitter').attach_pats(node.file)
    if #pats > 0 then
        local up, header = require('cartograph.txn').attach_above(
            all, shown.range.start.line, pats)
        if not header then ds = up end
    end
    M._shown_start[node.id] = ds
    M._shown_end[node.id] = shown.range['end'].line
    -- external edits (git checkout, codegen) never fire BufWritePost: the
    -- range below may not line up with the fresh bytes — say so
    local stale = store.stale(node.file)
        and '   ≠ changed on disk — :CartographRefresh' or ''
    local body = { ('── %s   %s:%d-%d%s'):format(node.name or '?', node.file,
        s, e, stale), '' }
    for i = math.max(1, ds + 1), math.min(#all, e) do -- ds 0-based -> 1-based
        body[#body + 1] = all[i]
    end
    return body
end

local function set_lines(buf, lines)
    -- header lines carry node names from arbitrary source text
    for i, l in ipairs(lines) do
        if l:find('[\n\r]') then lines[i] = l:gsub('[\n\r]+', ' \u{B6} ') end
    end
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
end

-- Map a 0-based file line to a 0-based buffer row (or nil if outside the body).
local function buf_row(node, file_line)
    -- map against the first SHOWN line (doc comment included), not the def's
    -- signature line — otherwise highlights/jumps are off by the doc height
    local start = M._shown_start[node.id] or node.range.start.line
    local last = M._shown_end[node.id] or node.range['end'].line
    if file_line < start or file_line > last then return nil end
    return HEADER_ROWS + (file_line - start)
end

-- Smart scroll: move the display window's cursor to the target row and let
-- vim's own topline logic do the rest — it scrolls minimally for nearby
-- targets, centers only on far jumps, and honours the user's scrolloff /
-- smoothscroll. (The windows get a small local scrolloff in attach(), so an
-- off-screen target lands with a margin, not flush against the edge.)
local function ensure_visible(win, row0)
    if not (win and vim.api.nvim_win_is_valid(win)) or not row0 then return end
    pcall(vim.api.nvim_win_set_cursor, win, { row0 + 1, 0 })
end

-- Margin for hover-highlight jumps. Capped well under half the window height:
-- scrolloff >= half-height makes vim centre on EVERY move (the 'so=999'
-- effect), which is exactly the jumpiness this is meant to avoid.
local function set_margin(win)
    local h = vim.api.nvim_win_get_height(win)
    vim.wo[win].scrolloff = math.min(3, math.max(0, math.floor((h - 1) / 4)))
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
    -- (parameter-origin tracing lived here via the retired trace pane; the
    -- sources axis will re-home it — see the cartograph-trace-axes design)
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
    local function show_then_restore(lines, prompt)
        set_lines(M.buf, lines)
        scroll_top(M.win_top)
        local choice = prompt and vim.fn.confirm(prompt, '&Apply\n&Cancel', 2)
        if not prompt then vim.fn.confirm('(press Enter)', '&Ok', 1) end
        set_lines(M.buf, body_lines(M.cur))
        scroll_top(M.win_top)
        return choice == 1
    end
    if not plan.ok then
        local msg = { ('── cannot extract lines %d-%d'):format(file_first, file_last), '' }
        msg[#msg + 1] = plan.reason
        msg[#msg + 1] = ''
        msg[#msg + 1] = 'Extract works on whole top-level statements of a function.'
        vim.notify('cartograph: cannot extract — ' .. plan.reason, vim.log.levels.WARN)
        show_then_restore(msg)
        return
    end

    -- preview in the pane, confirm before touching disk
    local prev = { ('── extract preview: %s(%s)%s'):format(name, table.concat(plan.params, ', '),
        #plan.returns > 0 and ('  ->  ' .. table.concat(plan.returns, ', ')) or ''), '' }
    for _, l in ipairs(plan.new_fn) do prev[#prev + 1] = l end
    prev[#prev + 1] = ''
    prev[#prev + 1] = ('call replaces %s:%d-%d:'):format(node.file, plan.replace.first, plan.replace.last)
    for _, l in ipairs(plan.call) do prev[#prev + 1] = l end
    for _, h in ipairs(plan.hazards) do prev[#prev + 1] = '⚠ ' .. h end
    if not show_then_restore(prev,
            ('Extract %d line(s) into %s()?'):format(file_last - file_first + 1, name)) then
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
    bind_nav(buf, function () return M.ctx or M.cur end)
    return buf
end

function M.attach(win)
    M.win_top = win
    set_margin(win)
    M.context(nil)
end

---@param id string?
function M.render(id)
    local node = store.node(id)
    M.cur, M.ctx = node, nil
    set_lines(M.buf, body_lines(node))
    scroll_top(M.win_top) -- a fresh body starts at its header
end

---@param hl {file:string, ranges:table}?
function M.highlight(hl)
    if not vim.api.nvim_buf_is_valid(M.buf) then return end
    vim.api.nvim_buf_clear_namespace(M.buf, ns, 0, -1)
    local shown = M.ctx or M.cur
    if not hl or not shown or hl.file ~= shown.file then return end
    apply_hl(M.buf, shown, hl.ranges)
    local r = hl.ranges and hl.ranges[1]
    if r then ensure_visible(M.win_top, buf_row(shown, r.start.line)) end
end

--- The "other end" temporarily takes over the pane: a hovered call site /
--- var read / trace origin renders here (its line highlighted); clearing the
--- context restores the focused body. One window, two moments.
---@param ctx {node:string, ranges:table?}?
function M.context(ctx)
    if not (M.buf and vim.api.nvim_buf_is_valid(M.buf)) then return end
    local prev = M.ctx
    M.ctx = ctx and store.node(ctx.node) or nil
    if not M.ctx then
        if prev then -- restore the focused body only if a context was showing
            set_lines(M.buf, body_lines(M.cur))
            scroll_top(M.win_top)
        end
        return
    end
    set_lines(M.buf, body_lines(M.ctx))
    scroll_top(M.win_top)
    if ctx.ranges then
        apply_hl(M.buf, M.ctx, ctx.ranges)
        local r = ctx.ranges[1]
        if r then ensure_visible(M.win_top, buf_row(M.ctx, r.start.line)) end
    end
end

-- test seam: the def's rendered body lines (doc-comment included), without a
-- window. Also populates M._shown_start[node.id].
M._body_lines = body_lines

return M
