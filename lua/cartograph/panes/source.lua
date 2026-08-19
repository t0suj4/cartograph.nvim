-- SOURCE pane: the real code — the "have I seen this?" recognition anchor. It is
-- a horizontal SPLIT:
--   TOP    = the focused function's definition. Subscribes to focus.
--   BOTTOM = the *other end* of the hovered dependency edge. For a `uses` entry
--            that's the callee's definition; for a `used by` entry it's the
--            caller's body with the call site highlighted.
-- Together: def above, call site below — compare where you are with where a
-- reference actually happens, without leaving the focused node.

local store    = require 'cartograph.store'
local hl       = require 'cartograph.hl'
local atr = require 'cartograph.at'

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
            and atr.sl(n.range) <= atr.sl(node.range)
            and atr.el(n.range) >= atr.el(node.range)
            and (not reg or (atr.el(n.range) - atr.sl(n.range))
                < (atr.el(reg.range) - atr.sl(reg.range))) then
            reg = n
        end
    end
    return reg
end

-- ── ALTERNATE VIEWS of the subject ───────────────────────────────────────────
-- This pane has only ever rendered ONE thing about its subject: the source. A
-- view names a different RENDERING of the same subject, so `M.ctx` stays the
-- single owner of what is showing and the restore path is untouched.
--
-- The first one exists because the files altitude is the case the source pane
-- cannot serve: a whole file is not a recognition anchor, and what a file row
-- actually has — its PLACE in the import graph — is exactly what the 30-column
-- browser cannot hold. Measured across two corpora, a file's ONE-LEVEL
-- neighbourhood is 6 rows at the median and 36 at p90 (max 91), so it fits here
-- whole, untruncated, both directions at once, and descending stops being blind.
-- The payload is a TABLE (`view = { name = 'nbhd' }`) so a later view can carry
-- parameters — a second hop, a direction filter — without a migration.
local VIEWS = {}

--- The module NODE for a file path. A module's id is usually the path itself,
--- but that is a provider convention, not a guarantee — so look it up.
function M._module_of(file)
    for _, x in ipairs(store.by_file[file] or {}) do
        if x.kind == 'module' then return x.id end
    end
    return file
end

local function defs_in(file)
    local n = 0
    for _, x in ipairs(store.by_file[file] or {}) do
        if x.kind ~= 'module' then n = n + 1 end
    end
    return n
end

--- Returns `lines, rows` where `rows[buffer_row] = file`, so a jump from a
--- preview row goes where the row plainly says it goes.
function VIEWS.nbhd(node)
    local lines, rows = { node.name or node.id, '' }, {}
    -- A lazy or unparsed module's imports are UNKNOWN, not absent: rendering
    -- `requires (0)` there would be a fabricated fact, the same invented
    -- absence the browser refuses everywhere else.
    if node.lazy or node.unparsed then
        lines[#lines + 1] = node.lazy
            and '  (lazy — its imports are unknown until it is loaded)'
            or  '  (unparsed — its imports are unknown, not absent)'
        return lines, rows
    end
    local topo = store.topo()
    local function section(title, list, empty)
        table.sort(list)
        lines[#lines + 1] = ('%s (%d)'):format(title, #list)
        if #list == 0 then
            lines[#lines + 1] = '    ' .. empty
        else
            local w = 0
            for _, f in ipairs(list) do w = math.max(w, #f) end
            for _, f in ipairs(list) do
                local d = defs_in(f)
                lines[#lines + 1] = ('    %-' .. w .. 's   %d def%s')
                    :format(f, d, d == 1 and '' or 's')
                rows[#lines] = f
            end
        end
        lines[#lines + 1] = ''
    end
    section('requires', topo:imports_out(node.id), 'nothing')
    section('required by', topo:imports_in(node.id),
        'nobody — an entry point, or an orphan')
    return lines, rows
end

-- Lines for a node's body: a hard-context header + the real source range.
local function body_lines(node)
    if not node then return { '(nothing)' } end
    local all = store.content(node)
    if not all then return { ('── %s   %s  (unreadable)'):format(node.name or '?', node.file) } end
    -- a top-level statement widens to the region it belongs to
    local shown = enclosing_region(node) or node
    local s = atr.sl(shown.range) + 1     -- schema line is 0-based
    local e = atr.el(shown.range) + 1
    -- show the def WITH its leading doc comment: walk up over the block that
    -- adheres to it (the same per-language patterns + file-header decline the
    -- edit verbs use), so focusing a symbol shows what it's FOR, not just its
    -- signature. Python-style docstrings live inside [s,e] and already show.
    local ds = atr.sl(shown.range) -- 0-based first shown line
    local pats = require('cartograph.providers.treesitter').attach_pats(node.file)
    if #pats > 0 then
        local up, header = require('cartograph.txn').attach_above(
            all, atr.sl(shown.range), pats)
        if not header then ds = up end
    end
    M._shown_start[node.id] = ds
    M._shown_end[node.id] = atr.el(shown.range)
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
    local start = M._shown_start[node.id] or atr.sl(node.range)
    local last = M._shown_end[node.id] or atr.el(node.range)
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
        local row = buf_row(node, atr.sl(r))
        if row then
            local col_end = atr.oneline(r) and atr.ec(r) or -1
            pcall(vim.api.nvim_buf_set_extmark, buf, ns, row, atr.sc(r), {
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
    for _, to in ipairs(store.topo():callees(node.id)) do
        for _, r in ipairs(store.occurrences(node.id, to) or {}) do
            if atr.sl(r) == file_line and col >= atr.sc(r)
                and (atr.el(r) > file_line or col < atr.ec(r)) then
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
    local fl = atr.sl(node.range) + (row0 - HEADER_ROWS)
    if fl > atr.el(node.range) then return nil end
    return fl
end

-- gf: leave the cockpit — open the real file in a (reused) tab, at the line the
-- cursor corresponds to (the node's first line when on a header row).
local function goto_real(win, node)
    if not node then return end
    local fl = cursor_file_line(win, node) or atr.sl(node.range)
    vim.cmd('tab drop ' .. vim.fn.fnameescape(store.abspath(node)))
    pcall(vim.api.nvim_win_set_cursor, 0, { fl + 1, 0 })
end

-- Navigation verbs for a source buffer: <C-]> pivots to the definition of the
-- call under the cursor (tags idiom), gf opens the real file. `which` picks the
-- node the buffer renders (focused def on top, hovered context below).
local function bind_nav(buf, which)
    local keys = require('cartograph.config').keys
    vim.keymap.set('n', keys.jump, function ()
        -- in an alternate view the rows are not source: a row that plainly
        -- names a file is a DOOR to it, so follow it rather than refusing
        local vr = M._view_rows
        if vr then
            local f = vr[vim.api.nvim_win_get_cursor(vim.api.nvim_get_current_win())[1]]
            local n = f and (store.node(f) or store.node(M._module_of(f)))
            if n then return store.pivot(n.id) end
            return vim.notify('cartograph: this row is not a file',
                vim.log.levels.INFO)
        end
        local node = which()
        if not node then return end
        local win = vim.api.nvim_get_current_win()
        local fl  = cursor_file_line(win, node)
        local col = vim.api.nvim_win_get_cursor(win)[2]
        local to  = M.resolve_jump(node, fl, col, vim.fn.expand('<cword>'))
        if to then return store.pivot(to) end
        -- "no known callee" is a CLAIM about the call graph, so it may only be
        -- made when there is one: resolve_jump reads topo():callees, which the
        -- thin index does not carry, so on it every jump would report a
        -- confident absence. Same fabrication the callers altitude had (see
        -- cartograph.panes.concerns) — a second surface, one layer over: here
        -- the manufactured fact is a notification rather than a rendered count.
        local why = require('cartograph.panes.concerns').needs_edges(store)
        vim.notify(why and ('cartograph: jump needs the call graph — ' .. why)
            or 'cartograph: no known callee under the cursor',
            why and vim.log.levels.WARN or vim.log.levels.INFO)
    end, { buffer = buf, desc = 'cartograph: jump to the definition under the cursor' })
    vim.keymap.set('n', keys.open_file, function ()
        local win = vim.api.nvim_get_current_win()
        local vr = M._view_rows
        local f = vr and vr[vim.api.nvim_win_get_cursor(win)[1]]
        local n = f and (store.node(f) or store.node(M._module_of(f)))
        goto_real(win, n or (not vr and which() or nil))
    end,
        { buffer = buf, desc = 'cartograph: open the real file here' })
    -- (parameter-origin tracing lived here via the retired trace pane; the
    -- sources axis will re-home it — see the cartograph-trace-axes design)
end

-- Extract the selected TOP-pane lines into a new local function. `line1`/`line2`
-- are 1-based rows in the top buffer; the body starts at row HEADER_ROWS. Shows
-- the computed interface in the pane, then STAGES a transaction — this verb used
-- to vim.fn.writefile straight to disk (no journal, no CAS, no parse gate, and a
-- graph left stale enough that it told you to regenerate the dump by hand). It
-- now rides extractapply like every other write verb, so the commit is
-- :CartographApply and the undo is :CartographUndo (CART-0125).
function M.extract(line1, line2, name)
    local node = M.cur
    if not node then return vim.notify('cartograph: no function focused', vim.log.levels.WARN) end
    if store.txn then
        return vim.notify('cartograph: a transaction is already staged'
            .. ' — :CartographApply or :CartographTxnClear first', vim.log.levels.WARN)
    end
    local fn_start = atr.sl(node.range) + 1        -- 1-based
    -- top buffer row 3 (1-based) shows file line fn_start
    local file_first = fn_start + (line1 - (HEADER_ROWS + 1))
    local file_last  = fn_start + (line2 - (HEADER_ROWS + 1))

    local ea = require 'cartograph.extractapply'
    local plan, why = ea.plan(store, node.id,
        { first = file_first, last = file_last }, name)
    local function show_then_restore(lines)
        set_lines(M.buf, lines)
        scroll_top(M.win_top)
        vim.fn.confirm('(press Enter)', '&Ok', 1)
        set_lines(M.buf, body_lines(M.cur))
        scroll_top(M.win_top)
    end
    if not plan then
        local msg = { ('── cannot extract lines %d-%d'):format(file_first, file_last), '' }
        msg[#msg + 1] = tostring(why)
        msg[#msg + 1] = ''
        msg[#msg + 1] = 'Extract works on whole top-level statements of a function.'
        vim.notify('cartograph: cannot extract — ' .. tostring(why), vim.log.levels.WARN)
        show_then_restore(msg)
        return
    end

    -- the computed interface in the pane; the exact bytes are :CartographDiff
    local prev = { ('── extract staged: %s(%s)%s'):format(name, table.concat(plan.params, ', '),
        #plan.returns > 0 and ('  ->  ' .. table.concat(plan.returns, ', ')) or ''), '' }
    for _, l in ipairs(plan.new_fn) do prev[#prev + 1] = l end
    prev[#prev + 1] = ''
    prev[#prev + 1] = ('call replaces %s:%d-%d:'):format(node.file, plan.replace.first, plan.replace.last)
    for _, l in ipairs(plan.call) do prev[#prev + 1] = l end
    for _, h in ipairs(plan.hazards) do prev[#prev + 1] = '⚠ ' .. h end
    prev[#prev + 1] = ''
    prev[#prev + 1] = 'nothing is written yet — :CartographDiff reviews, :CartographApply commits'
    show_then_restore(prev)
    store.set_txn(plan)
    vim.notify(('cartograph: extract staged — %d line(s) → %s(%d param%s).'
        .. ' Review with :CartographDiff, then :CartographApply'):format(
        file_last - file_first + 1, name, #plan.params,
        #plan.params == 1 and '' or 's'), vim.log.levels.INFO)
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
    M._view, M._view_rows = nil, nil
    set_lines(M.buf, body_lines(node))
    scroll_top(M.win_top) -- a fresh body starts at its header
end

---@param hl {file:string, ranges:table}?
function M.highlight(hl)
    if not vim.api.nvim_buf_is_valid(M.buf) then return end
    -- an alternate view's lines are GENERATED: source ranges do not address
    -- them, so painting one here would highlight an arbitrary row
    if M._view then return end
    vim.api.nvim_buf_clear_namespace(M.buf, ns, 0, -1)
    local shown = M.ctx or M.cur
    if not hl or not shown or hl.file ~= shown.file then return end
    apply_hl(M.buf, shown, hl.ranges)
    local r = hl.ranges and hl.ranges[1]
    if r then ensure_visible(M.win_top, buf_row(shown, atr.sl(r))) end
end

--- The "other end" temporarily takes over the pane: a hovered call site /
--- var read / trace origin renders here (its line highlighted); clearing the
--- context restores the focused body. One window, two moments.
---@param ctx {node:string, ranges:table?}?
function M.context(ctx)
    if not (M.buf and vim.api.nvim_buf_is_valid(M.buf)) then return end
    local prev = M.ctx
    M.ctx = ctx and store.node(ctx.node) or nil
    M._view, M._view_rows = nil, nil
    if not M.ctx then
        if prev then -- restore the focused body only if a context was showing
            set_lines(M.buf, body_lines(M.cur))
            scroll_top(M.win_top)
        end
        return
    end
    local render = ctx.view and ctx.view.name and VIEWS[ctx.view.name]
    if render then
        local lines, rows = render(M.ctx, ctx.view)
        M._view, M._view_rows = ctx.view.name, rows
        set_lines(M.buf, lines)
        scroll_top(M.win_top)
        return -- `ranges` address source, not this
    end
    set_lines(M.buf, body_lines(M.ctx))
    scroll_top(M.win_top)
    if ctx.ranges then
        apply_hl(M.buf, M.ctx, ctx.ranges)
        local r = ctx.ranges[1]
        if r then ensure_visible(M.win_top, buf_row(M.ctx, atr.sl(r))) end
    end
end

-- test seam: the def's rendered body lines (doc-comment included), without a
-- window. Also populates M._shown_start[node.id].
M._body_lines = body_lines

return M
