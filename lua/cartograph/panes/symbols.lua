-- LEFT pane: a zoomable ALTITUDE browser over the project. Three levels, all
-- navigated with two keys — <CR> descends, `-` ascends (the dirvish idiom):
--
--   files   one row per file (with usage-classification gutter signs)
--   file    one file's definitions in source order: functions, methods, AND
--           module-level vars/fields — the whole file, not just the movable units
--   fn      inside one function: its statement-level locals (from the data
--           flow), each row hover-highlighting the real line in the source pane
--
-- At the `file` level the cursor row IS the focus (drives source/tree), and
-- staging (dd / p / u) lives here, on the movable units.

local store  = require 'cartograph.store'
local heat   = require 'cartograph.heat'
local config = require 'cartograph.config'

local SHOW_L2   = { ['function'] = true, method = true, var = true }
local STAGEABLE = { ['function'] = true, method = true }
local ICON      = { ['function'] = 'ƒ', method = ':', var = '·' }

local ns       = vim.api.nvim_create_namespace('cartograph_symbols_dep')
local ns_class = vim.api.nvim_create_namespace('cartograph_symbols_class')
local ns_stage = vim.api.nvim_create_namespace('cartograph_symbols_stage')
local ns_heat  = vim.api.nvim_create_namespace('cartograph_symbols_heat')
local ns_ui    = vim.api.nvim_create_namespace('cartograph_symbols_ui')

-- File-usage markers, shown in the gutter on file rows.
--   ○ orphan (no inbound)   ⚠ unused import (pure module)   ↻ side-effect
local SIGN = {
    entry      = { text = '▶ ', hl = 'DiagnosticOk' },   -- runtime-loaded root, by design
    orphan     = { text = '○ ', hl = 'DiagnosticWarn' }, -- nothing loads it, NOT an entry point
    deadimport = { text = '⚠ ', hl = 'DiagnosticWarn' },
    sideeffect = { text = '↻ ', hl = 'Comment' },
    -- 'value' and 'used' are genuinely used → no marker (keeps the list quiet)
}

local M = {
    view = { level = 'files', file = nil, fn = nil },
    files_mode = 'flat', -- 'flat' (alphabetical) | 'tree' (include tree); <Tab> toggles
    line_node = {}, node_line = {}, line_file = {}, file_header = {}, line_stmt = {},
}

-- Relationship tints: dependencies (things the focus uses) in green, dependents
-- (things that use the focus) in amber; depth-1 saturated, depth-2 muted. Each
-- is a whole-line background blended over the real Normal bg so it tracks the
-- colorscheme rather than fighting it.
local function hl_setup()
    local normal = vim.api.nvim_get_hl(0, { name = 'Normal', link = false })
    local bg = normal.bg or 0x222436
    local function blend(hue, alpha)
        local function ch(c, n) return math.floor(c / n) % 256 end
        local r = math.floor(ch(hue, 65536) * alpha + ch(bg, 65536) * (1 - alpha) + 0.5)
        local g = math.floor(ch(hue, 256) * alpha + ch(bg, 256) * (1 - alpha) + 0.5)
        local b = math.floor((hue % 256) * alpha + (bg % 256) * (1 - alpha) + 0.5)
        return string.format('#%02x%02x%02x', r, g, b)
    end
    local GREEN, AMBER = 0x9ece6a, 0xff9e64
    vim.api.nvim_set_hl(0, 'CartographDep1',  { bg = blend(GREEN, 0.24) })
    vim.api.nvim_set_hl(0, 'CartographDep2',  { bg = blend(GREEN, 0.11) })
    vim.api.nvim_set_hl(0, 'CartographRdep1', { bg = blend(AMBER, 0.24) })
    vim.api.nvim_set_hl(0, 'CartographRdep2', { bg = blend(AMBER, 0.11) })
end

-- ── per-level renderers (fill ctx.lines/marks/vnums/signs + row mappings) ────

local function shown_defs(file)
    local defs = {}
    for _, n in ipairs(store.by_file[file] or {}) do
        if SHOW_L2[n.kind] then defs[#defs + 1] = n end
    end
    return defs
end

local function file_row(ctx, file, depth, dim)
    local indent = string.rep('  ', depth or 0)
    ctx.lines[#ctx.lines + 1] = ('%s%s  (%d)%s'):format(indent, file, #shown_defs(file), dim and ' …' or '')
    ctx.marks[#ctx.lines] = dim and { { 0, -1, 'CartographDim' } }
        or { { #indent, #indent + #file, 'CartographSection' }, { #indent + #file, -1, 'CartographDim' } }
    ctx.line_file[#ctx.lines] = file
    local sign = SIGN[store.classify(file)]
    if sign then ctx.signs[#ctx.signs + 1] = { row = #ctx.lines - 1, sign = sign } end
end

local function render_files(ctx)
    for _, file in ipairs(store.files) do
        file_row(ctx, file, 0)
    end
end

-- Include tree: files organized by who requires whom. Roots are the files
-- nothing requires (entry points / orphans); a file already shown appears dim
-- with `…` and is not expanded again (which also makes require-cycles safe).
local function render_files_tree(ctx)
    local shown = {}
    local function add(file, depth)
        if shown[file] then
            file_row(ctx, file, depth, true)
            return
        end
        shown[file] = true
        file_row(ctx, file, depth)
        local kids = {}
        for _, k in ipairs(store.imports_out[file] or {}) do kids[#kids + 1] = k end
        table.sort(kids)
        for _, k in ipairs(kids) do add(k, depth + 1) end
    end
    -- entry points first among the roots, then the accidental ones
    local roots = {}
    for _, f in ipairs(store.files) do
        if not (store.imports_in[f] and #store.imports_in[f] > 0) then roots[#roots + 1] = f end
    end
    table.sort(roots, function (a, b)
        local ea, eb = store.is_entrypoint(a), store.is_entrypoint(b)
        if ea ~= eb then return ea end
        return a < b
    end)
    for _, f in ipairs(roots) do add(f, 0) end
    -- anything left is only reachable through a cycle: show it as a root too
    for _, f in ipairs(store.files) do
        if not shown[f] then add(f, 0) end
    end
end

local function render_file(ctx, file)
    ctx.lines[1] = ('%s  (%d)'):format(file, #shown_defs(file))
    ctx.marks[1] = { { 0, #file, 'CartographSection' }, { #file, -1, 'CartographDim' } }
    ctx.line_file[1] = file
    ctx.file_header[file] = 1
    local sign = SIGN[store.classify(file)]
    if sign then ctx.signs[#ctx.signs + 1] = { row = 0, sign = sign } end
    for _, n in ipairs(shown_defs(file)) do
        local icon = ICON[n.kind] or '?'
        ctx.lines[#ctx.lines + 1] = ('  %s %s'):format(icon, n.name or '?')
        ctx.marks[#ctx.lines] = { { 2, 2 + #icon, 'CartographDim' } }
        ctx.vnums[#ctx.lines] = tostring(n.range.start.line + 1)
        ctx.line_node[#ctx.lines] = n.id
        ctx.node_line[n.id]       = #ctx.lines
        ctx.line_file[#ctx.lines] = file
    end
end

local function render_fn(ctx, id)
    local node = store.node(id)
    if not node then ctx.lines[1] = '(gone)'; return end
    local pre = ICON[node.kind] or 'ƒ'
    ctx.lines[1] = ('%s %s'):format(pre, node.name or '?')
    ctx.marks[1] = { { 0, #pre, 'CartographDim' }, { #pre, -1, 'CartographTitle' } }
    local df = node.df
    if not df then
        ctx.lines[2] = '  (no data-flow info)'
        ctx.marks[2] = { { 0, -1, 'CartographDim' } }
        return
    end
    ctx.lines[2] = ('inputs: %s'):format(#df.inputs > 0 and table.concat(df.inputs, ', ') or '(none)')
    ctx.marks[2] = { { 0, -1, 'CartographDim' } }
    for _, s in ipairs(df.stmts) do
        local defs = table.concat(s.def, ', ')
        local uses = table.concat(s.use, ', ')
        local text, dim_from
        if defs ~= '' and uses ~= '' then
            text = ('  %s  ← %s'):format(defs, uses); dim_from = 2 + #defs
        elseif defs ~= '' then
            text = '  ' .. defs
        else
            text = '  · ' .. uses; dim_from = 0
        end
        ctx.lines[#ctx.lines + 1] = text
        if dim_from then ctx.marks[#ctx.lines] = { { dim_from, -1, 'CartographDim' } } end
        ctx.vnums[#ctx.lines] = tostring(s.l)
        ctx.line_stmt[#ctx.lines] = s.l -- 1-based file line
    end
end

function M.render()
    if not (M.buf and vim.api.nvim_buf_is_valid(M.buf)) then return end
    local ctx = { lines = {}, marks = {}, vnums = {}, signs = {},
        line_node = {}, node_line = {}, line_file = {}, file_header = {}, line_stmt = {} }
    local v = M.view
    if v.level == 'files' then
        if M.files_mode == 'tree' then render_files_tree(ctx) else render_files(ctx) end
    elseif v.level == 'file' then render_file(ctx, v.file)
    else render_fn(ctx, v.fn) end

    M.line_node, M.node_line = ctx.line_node, ctx.node_line
    M.line_file, M.file_header, M.line_stmt = ctx.line_file, ctx.file_header, ctx.line_stmt

    vim.bo[M.buf].modifiable = true
    vim.api.nvim_buf_set_lines(M.buf, 0, -1, false, ctx.lines)
    vim.bo[M.buf].modifiable = false
    for _, n in ipairs({ ns_ui, ns_class }) do vim.api.nvim_buf_clear_namespace(M.buf, n, 0, -1) end
    for _, s in ipairs(ctx.signs) do
        vim.api.nvim_buf_set_extmark(M.buf, ns_class, s.row, 0,
            { sign_text = s.sign.text, sign_hl_group = s.sign.hl })
    end
    for row, ms in pairs(ctx.marks) do
        for _, m in ipairs(ms) do
            local endc = m[2] >= 0 and m[2] or #ctx.lines[row]
            pcall(vim.api.nvim_buf_set_extmark, M.buf, ns_ui, row - 1, m[1],
                { end_col = endc, hl_group = m[3] })
        end
    end
    for row, num in pairs(ctx.vnums) do
        pcall(vim.api.nvim_buf_set_extmark, M.buf, ns_ui, row - 1, 0,
            { virt_text = { { num .. ' ', 'CartographDim' } }, virt_text_pos = 'right_align' })
    end
    M.restage()
    M.render_heat()
    M.paint(store.focused)
end

--- Switch level (re-rendering) and land the cursor on the first useful row.
function M.show(level, ctx_val)
    M.view.level = level
    if level == 'file' then M.view.file = ctx_val
    elseif level == 'fn' then M.view.fn = ctx_val end
    M.render()
    if M.win and vim.api.nvim_win_is_valid(M.win) then
        local first = 1
        for row = 1, vim.api.nvim_buf_line_count(M.buf) do
            if M.line_node[row] or M.line_stmt[row]
                or (level == 'files' and M.line_file[row]) then
                first = row
                break
            end
        end
        pcall(vim.api.nvim_win_set_cursor, M.win, { first, 2 })
    end
end

function M.create()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = 'wipe'
    vim.bo[buf].filetype  = 'cartograph-symbols'
    M.buf = buf
    hl_setup()
    require('cartograph.hl').ui()
    vim.api.nvim_create_autocmd('ColorScheme', { callback = hl_setup })
    return buf
end

-- Redraw the staging marks: a ✓ in the gutter on each staged symbol, and a
-- "◀ destination" tag on the destination file row. Driven by the store's
-- plan channel so it stays in sync however staging is changed.
function M.restage()
    if not M.buf or not vim.api.nvim_buf_is_valid(M.buf) then return end
    vim.api.nvim_buf_clear_namespace(M.buf, ns_stage, 0, -1)
    for _, id in ipairs(store.staged_ids()) do
        local r = M.node_line[id]
        if r then
            vim.api.nvim_buf_set_extmark(M.buf, ns_stage, r - 1, 0,
                { sign_text = '✓ ', sign_hl_group = 'DiagnosticOk' })
        end
    end
    if store.dest then
        local dr = M.file_header[store.dest]
        if not dr and M.view.level == 'files' then
            for row, f in pairs(M.line_file) do
                if f == store.dest then dr = row break end
            end
        end
        if dr then
            vim.api.nvim_buf_set_extmark(M.buf, ns_stage, dr - 1, 0,
                { virt_text = { { '  ◀ destination', 'DiagnosticInfo' } }, virt_text_pos = 'eol' })
        end
    end
end

-- Tint the list by each row's relationship to `id`: dependencies (uses) and
-- dependents (used-by), out to 2 levels, with depth-1 stronger than depth-2.
-- Priority (high wins): uses¹ > used-by¹ > uses² > used-by². The focus row is
-- left to the cursorline.
function M.paint(id)
    if not M.buf or not vim.api.nvim_buf_is_valid(M.buf) then return end
    vim.api.nvim_buf_clear_namespace(M.buf, ns, 0, -1)
    if not id or M.view.level ~= 'file' then return end

    local uses1, uses2, rdep1, rdep2 = {}, {}, {}, {}
    for _, t in ipairs(store.uses[id]   or {}) do uses1[t] = true end
    for _, f in ipairs(store.usedby[id] or {}) do rdep1[f] = true end
    for t in pairs(uses1) do
        for _, t2 in ipairs(store.uses[t] or {}) do
            if t2 ~= id and not uses1[t2] then uses2[t2] = true end
        end
    end
    for f in pairs(rdep1) do
        for _, f2 in ipairs(store.usedby[f] or {}) do
            if f2 ~= id and not rdep1[f2] then rdep2[f2] = true end
        end
    end

    local focus_row = M.node_line[id]
    local mark = {} -- row -> { g = group, p = priority }
    local function put(nid, group, prio)
        local r = M.node_line[nid]
        if not r or r == focus_row then return end
        if not mark[r] or prio > mark[r].p then mark[r] = { g = group, p = prio } end
    end
    for nid in pairs(uses2) do put(nid, 'CartographDep2',  20) end
    for nid in pairs(rdep2) do put(nid, 'CartographRdep2', 10) end
    for nid in pairs(uses1) do put(nid, 'CartographDep1',  40) end
    for nid in pairs(rdep1) do put(nid, 'CartographRdep1', 30) end

    for r, m in pairs(mark) do
        vim.api.nvim_buf_set_extmark(M.buf, ns, r - 1, 0, { line_hl_group = m.g })
    end
end

-- Hub/heat overlay: annotate each symbol with fan-in / fan-out and its role
-- (hub / coordinator / leaf / api / unused? / isolated). Static, toggled on
-- demand so it doesn't clutter navigation. Shown as end-of-line virtual text.
M.heat_on = false
function M.render_heat()
    if not M.buf or not vim.api.nvim_buf_is_valid(M.buf) then return end
    vim.api.nvim_buf_clear_namespace(M.buf, ns_heat, 0, -1)
    if not M.heat_on or M.view.level ~= 'file' then return end
    for id, row in pairs(M.node_line) do
        local n = store.node(id)
        if n and STAGEABLE[n.kind] then
            local fanin  = #(store.usedby[id] or {})
            local fanout = #(store.uses[id] or {})
            local exported = n.kind == 'method' or (n.name and n.name:find('%.') ~= nil)
            local r = heat.role(fanin, fanout, exported)
            local text = ('  in:%d out:%d%s'):format(fanin, fanout, r.tag ~= '' and ('  ◀ ' .. r.tag) or '')
            vim.api.nvim_buf_set_extmark(M.buf, ns_heat, row - 1, 0,
                { virt_text = { { text, r.hl } }, virt_text_pos = 'eol' })
        end
    end
end

function M.toggle_heat()
    M.heat_on = not M.heat_on
    M.render_heat()
    vim.notify('cartograph: heat overlay ' .. (M.heat_on and 'on' or 'off'), vim.log.levels.INFO)
end

--- Wire cursor movement in `win` to focus (so source/tree follow), the zoom
--- keys, staging, and keep the cursor synced to pivots from elsewhere.
function M.attach(win)
    M.win = win
    vim.wo[win].signcolumn = 'yes:1' -- stable-width gutter for the class markers
    vim.wo[win].cursorline = true    -- the cursor row IS the focus
    local keys = config.keys
    local function row() return vim.api.nvim_win_get_cursor(win)[1] end

    -- debounced: focus (or statement highlight) follows where the cursor SETTLES
    local gen = 0
    vim.api.nvim_create_autocmd('CursorMoved', {
        buffer = M.buf,
        callback = function ()
            gen = gen + 1
            local g = gen
            vim.defer_fn(function ()
                if g ~= gen or not vim.api.nvim_win_is_valid(win) then return end
                local r = row()
                if M.view.level == 'file' then
                    local id = M.line_node[r]
                    if id then store.set_focus(id) end
                elseif M.view.level == 'fn' then
                    local l = M.line_stmt[r]
                    local n = store.node(M.view.fn)
                    if l and n then
                        store.set_highlight({ file = n.file, ranges = {
                            { start = { line = l - 1, char = 0 }, ['end'] = { line = l, char = 0 } } } })
                    end
                end
            end, 60)
        end,
    })

    store.on_focus(function (id)
        local n = store.node(id)
        if M.view.level == 'file' and n and not M.node_line[id] and n.file ~= M.view.file then
            M.show('file', n.file) -- a pivot into another file re-scopes the browser
        end
        local ln = M.node_line[id]
        if ln and M.win and vim.api.nvim_win_is_valid(M.win)
            and vim.api.nvim_win_get_buf(M.win) == M.buf then
            -- set_focus is idempotent, so the CursorMoved this triggers no-ops
            vim.api.nvim_win_set_cursor(M.win, { ln, 2 })
        end
        M.paint(id)
    end)

    -- zoom: l / <CR> descend (files -> file -> inside a function), h ascends —
    -- h/l are free in a linear list, so sideways becomes altitude
    local function descend()
        local r = row()
        if M.view.level == 'files' then
            local f = M.line_file[r]
            if f then M.show('file', f) end
        elseif M.view.level == 'file' then
            local n = store.node(M.line_node[r])
            if n and STAGEABLE[n.kind] then
                store.set_focus(n.id)
                M.show('fn', n.id)
            end
        end
    end
    vim.keymap.set('n', keys.descend, descend,
        { buffer = M.buf, desc = 'cartograph: descend (into file / into function)' })
    vim.keymap.set('n', keys.pivot, descend,
        { buffer = M.buf, nowait = true, desc = 'cartograph: descend (into file / into function)' })
    -- ascending lands the cursor ON what we came from (the file-manager rule),
    -- not on the first row of the wider view
    vim.keymap.set('n', keys.ascend, function ()
        if M.view.level == 'fn' then
            store.set_highlight(nil)
            local id = M.view.fn
            local n = store.node(id)
            M.show('file', n and n.file or M.view.file)
            local r = M.node_line[id]
            if r then pcall(vim.api.nvim_win_set_cursor, win, { r, 2 }) end
        elseif M.view.level == 'file' then
            local from = M.view.file
            M.show('files')
            -- numeric scan: in tree mode a file can appear twice; land on the
            -- first (expanded) occurrence, deterministically
            for r = 1, vim.api.nvim_buf_line_count(M.buf) do
                if M.line_file[r] == from then
                    pcall(vim.api.nvim_win_set_cursor, win, { r, 0 })
                    break
                end
            end
        end
    end, { buffer = M.buf, desc = 'cartograph: ascend (to file / to file tree)' })

    -- <Tab> at the files level: flat list <-> include tree (who requires whom).
    -- Note this shadows <C-i>-forward here (terminals conflate Tab/C-i), the
    -- same trade the source pane makes for the lens.
    vim.keymap.set('n', keys.cycle, function ()
        if M.view.level ~= 'files' then return end
        local under = M.line_file[row()]
        M.files_mode = M.files_mode == 'tree' and 'flat' or 'tree'
        M.show('files')
        for r = 1, vim.api.nvim_buf_line_count(M.buf) do
            if M.line_file[r] == under then
                pcall(vim.api.nvim_win_set_cursor, win, { r, 0 })
                break
            end
        end
    end, { buffer = M.buf, desc = 'cartograph: toggle file view (flat / include tree)' })

    -- staging as cut & paste: dd cuts a function into the move-set, visual d
    -- cuts a selection, p pastes at the file under the cursor (= destination),
    -- u unstages the last. Marks live on the movable units (functions/methods).
    vim.keymap.set('n', keys.cut, function ()
        local n = store.node(M.line_node[row()])
        if n and STAGEABLE[n.kind] then store.toggle_stage(n.id) end
    end, { buffer = M.buf, desc = 'cartograph: cut (stage) this function for moving' })
    vim.keymap.set('x', keys.cut_visual, function ()
        local a, b = vim.fn.line('v'), vim.fn.line('.')
        if a > b then a, b = b, a end
        for r = a, b do
            local n = store.node(M.line_node[r])
            if n and STAGEABLE[n.kind] then store.stage(n.id) end
        end
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 'n', false)
    end, { buffer = M.buf, desc = 'cartograph: cut (stage) the selected functions' })
    vim.keymap.set('n', keys.paste, function ()
        local file = M.line_file[row()]
        if file then store.set_dest(file) end
    end, { buffer = M.buf, desc = 'cartograph: paste — set move destination to this file' })
    vim.keymap.set('n', keys.unstage, function ()
        store.unstage_last()
    end, { buffer = M.buf, desc = 'cartograph: unstage the last cut function' })
    vim.keymap.set('n', keys.open_file, function ()
        local r = row()
        local n = store.node(M.line_node[r])
        local file = n and n.file or M.line_file[r] or (M.view.level == 'fn'
            and store.node(M.view.fn) and store.node(M.view.fn).file)
        if not file then return end
        local lnum = (M.view.level == 'fn' and M.line_stmt[r])
            or (n and n.range.start.line + 1) or 1
        vim.cmd('tab drop ' .. vim.fn.fnameescape(store.data.root .. '/' .. file))
        pcall(vim.api.nvim_win_set_cursor, 0, { lnum, 0 })
    end, { buffer = M.buf, desc = 'cartograph: open the real file here' })

    store.on_plan(function () M.restage() end)

    vim.api.nvim_buf_create_user_command(M.buf, 'CartographHeat', function () M.toggle_heat() end,
        { desc = 'cartograph: toggle the hub/heat overlay (fan-in/out + role)' })
end

return M
