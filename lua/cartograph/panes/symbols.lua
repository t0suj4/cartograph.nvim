-- LEFT pane: a zoomable ALTITUDE browser over the project. Three levels, all
-- navigated with two keys — <CR> descends, `-` ascends (the dirvish idiom):
--
--   files   one row per file (with usage-classification gutter signs)
--   file    one file's definitions in source order: functions, blocks (runs
--           of top-level statements), methods — the whole file
--   fn      inside one function: callers row + statement-level locals, each
--           row hover-highlighting the real line in the source pane
--
-- PIVOTING IS CONSCIOUS: hover only tints relationships; <CR> focuses, l
-- descends. History (store.pivot/back) snapshots the browser location.
-- Staging (dd / p / u) lives at the file level, on the movable units.

local store  = require 'cartograph.store'
local heat   = require 'cartograph.heat'
local config = require 'cartograph.config'

-- file level shows functions and BLOCKS (runs of top-level statements rolled
-- up under their first line); the individual vars live one level down
local SHOW_L2   = { ['function'] = true, method = true, block = true }
local STAGEABLE = { ['function'] = true, method = true }
local ICON      = { ['function'] = 'ƒ', method = ':', var = '·', block = '≡' }

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
    line_stmtidx = {}, line_calls = {}, line_site = {}, line_callers = {}, line_vars = {},
    trail = {},     -- descent trail: l pushes where you were, h pops (journey-back)
    fwd_trail = {}, -- ascent memory: h pushes where you left, l returns there exactly
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

-- Shared "usage sites" renderer: one row per occurrence, hover shows the site
-- in the bottom source view, descend enters the using function. Serves both
-- the var level (reads of a module var) and the callers level (calls of a fn).
local function render_sites(ctx, node, icon, label, sites, empty_note)
    -- defensive: one row per distinct (function, position)
    local seen, uniq = {}, {}
    for _, s in ipairs(sites) do
        local k = ('%s\31%d\31%d'):format(s.fn, s.line, s.range and s.range.start.char or 0)
        if not seen[k] then seen[k] = true; uniq[#uniq + 1] = s end
    end
    sites = uniq
    table.sort(sites, function (a, b)
        if a.file ~= b.file then return (a.file or '') < (b.file or '') end
        return a.line < b.line
    end)
    local name = node.name or '?'
    ctx.lines[1] = ('%s %s — %s (%d)'):format(icon, name, label, #sites)
    ctx.marks[1] = { { 0, #icon, 'CartographDim' }, { #icon + 1, #icon + 1 + #name, 'CartographTitle' },
                     { #icon + 1 + #name, -1, 'CartographDim' } }
    for _, s in ipairs(sites) do
        local text = '  ' .. s.name .. (s.inferred and ' ~' or '')
        ctx.lines[#ctx.lines + 1] = text
        if s.inferred then ctx.marks[#ctx.lines] = { { #text - 2, -1, 'CartographDim' } } end
        ctx.vnums[#ctx.lines] = tostring(s.line + 1)
        ctx.line_site[#ctx.lines] = s
    end
    if #sites == 0 then
        ctx.lines[2] = '  ' .. empty_note
        ctx.marks[2] = { { 0, -1, 'CartographDim' } }
    end
end

-- A table var's members: nodes named `T.x` / `T:y` anywhere in the file,
-- plus functions defined INSIDE the constructor span (callback tables).
local function table_members(id)
    local node = store.node(id)
    if not node or not node.name then return {} end
    local p1, p2 = node.name .. '.', node.name .. ':'
    local s, e = node.range.start.line, node.range['end'].line
    local out = {}
    for _, n in ipairs(store.by_file[node.file] or {}) do
        if n.id ~= id and n.kind ~= 'block' and n.kind ~= 'module' then
            local named = n.name and (n.name:sub(1, #p1) == p1 or n.name:sub(1, #p2) == p2)
            local inside = n.kind ~= 'var'
                and n.range.start.line >= s and n.range['end'].line <= e
            if named or inside then out[#out + 1] = n end
        end
    end
    table.sort(out, function (a, b) return a.range.start.line < b.range.start.line end)
    return out
end

-- A var's usage sites: every function that reads it.
local function render_var(ctx, id)
    local node = store.node(id)
    if not node then ctx.lines[1] = '(gone)'; return end
    local sites = {}
    for _, u in ipairs(store.var_usedby[id] or {}) do
        local fn = store.node(u.from)
        for _, r in ipairs(u.at) do
            sites[#sites + 1] = { fn = u.from, name = fn and fn.name or u.from,
                file = fn and fn.file, line = r.start.line, range = r }
        end
    end
    render_sites(ctx, node, '·', 'used by', sites,
        '(no reads found — writes only, or dynamic access)')
end

-- A function's callers: every call site, cross-referenced from the ref edges
-- (`~` = the edge was resolved by unique name, not type inference).
local function render_callers(ctx, id)
    local node = store.node(id)
    if not node then ctx.lines[1] = '(gone)'; return end
    local sites = {}
    for _, from in ipairs(store.usedby[id] or {}) do
        local fn = store.node(from)
        local inf = store.edge_inferred[from .. '\31' .. id]
        for _, r in ipairs(store.occurrences(from, id) or {}) do
            sites[#sites + 1] = { fn = from, name = fn and fn.name or from,
                file = fn and fn.file, line = r.start.line, range = r, inferred = inf }
        end
    end
    render_sites(ctx, node, ICON[node.kind] or 'ƒ', 'callers', sites,
        '(no callers found — entry point, or dynamically dispatched)')
end

-- Inside a TABLE var: its members (methods, fields, callback functions),
-- with the usage-sites view one row away.
local function render_tbl(ctx, id)
    local node = store.node(id)
    if not node then ctx.lines[1] = '(gone)'; return end
    ctx.lines[1] = ('· %s'):format(node.name or '?')
    ctx.marks[1] = { { 0, 1, 'CartographDim' }, { 1, -1, 'CartographTitle' } }
    local nsites = 0
    for _, u in ipairs(store.var_usedby[id] or {}) do nsites = nsites + #u.at end
    ctx.lines[2] = ('↖ used by (%d)'):format(nsites)
    ctx.marks[2] = { { 0, -1, 'CartographSection' } }
    ctx.line_callers[2] = id
    for _, n in ipairs(table_members(id)) do
        local icon = ICON[n.kind] or '?'
        local name = n.name or '?'
        local pref = node.name and name:sub(1, #node.name) == node.name
        if pref then name = name:sub(#node.name + 1) end -- .foo / :bar
        ctx.lines[#ctx.lines + 1] = ('  %s %s'):format(icon, name)
        ctx.marks[#ctx.lines] = { { 2, 2 + #icon, 'CartographDim' } }
        ctx.vnums[#ctx.lines] = tostring(n.range.start.line + 1)
        ctx.line_node[#ctx.lines] = n.id
        ctx.node_line[n.id]       = #ctx.lines
    end
end

-- Inside a block: its declarations (the var nodes within the block's range).
local function render_block(ctx, id)
    local node = store.node(id)
    if not node then ctx.lines[1] = '(gone)'; return end
    ctx.lines[1] = ('≡ %s'):format(node.name or '?')
    ctx.marks[1] = { { 0, #'≡', 'CartographDim' }, { #'≡', -1, 'CartographTitle' } }
    local s, e = node.range.start.line, node.range['end'].line
    for _, n in ipairs(store.by_file[node.file] or {}) do
        if n.kind == 'var' and n.range.start.line >= s and n.range.start.line <= e then
            ctx.lines[#ctx.lines + 1] = ('  · %s'):format(n.name or '?')
            ctx.marks[#ctx.lines] = { { 2, 3, 'CartographDim' } }
            ctx.vnums[#ctx.lines] = tostring(n.range.start.line + 1)
            ctx.line_node[#ctx.lines] = n.id
            ctx.node_line[n.id]       = #ctx.lines
        end
    end
    if #ctx.lines == 1 then
        ctx.lines[2] = '  (no declarations — calls / control flow only)'
        ctx.marks[2] = { { 0, -1, 'CartographDim' } }
    end
end

local function render_fn(ctx, id)
    local node = store.node(id)
    if not node then ctx.lines[1] = '(gone)'; return end
    local pre = ICON[node.kind] or 'ƒ'
    ctx.lines[1] = ('%s %s'):format(pre, node.name or '?')
    ctx.marks[1] = { { 0, #pre, 'CartographDim' }, { #pre, -1, 'CartographTitle' } }
    -- who calls this function — descend on the row to see the call sites
    local ncall = 0
    for _, from in ipairs(store.usedby[id] or {}) do
        ncall = ncall + #(store.occurrences(from, id) or {})
    end
    ctx.lines[2] = ('↖ callers (%d)'):format(ncall)
    ctx.marks[2] = { { 0, -1, 'CartographSection' } }
    ctx.line_callers[2] = id
    local df = node.df
    if not df then
        ctx.lines[3] = '  (no data-flow info)'
        ctx.marks[3] = { { 0, -1, 'CartographDim' } }
        return
    end
    ctx.lines[3] = ('inputs: %s'):format(#df.inputs > 0 and table.concat(df.inputs, ', ') or '(none)')
    ctx.marks[3] = { { 0, -1, 'CartographDim' } }
    -- callees AND module-var reads per STATEMENT, so rows can name them as
    -- descend targets. df statements are the body's top-level ones; anything
    -- nested in an if/for body belongs to the last statement starting at or
    -- before its line.
    local function stmt_of(line0)
        local li, best = line0 + 1, nil
        for i = 1, #df.stmts do
            if df.stmts[i].l <= li then best = i else break end
        end
        return best
    end
    local calls_at = {}
    for _, c in ipairs(store.calls_by_fn[id] or {}) do
        local best = stmt_of(c.line)
        if best then
            calls_at[best] = calls_at[best] or {}
            table.insert(calls_at[best], c)
        end
    end
    local vars_at = {}
    for _, u in ipairs(store.var_uses[id] or {}) do
        local vn = store.node(u.to)
        if vn then
            for _, r in ipairs(u.at) do
                local best = stmt_of(r.start.line)
                if best then
                    vars_at[best] = vars_at[best] or {}
                    table.insert(vars_at[best], { name = vn.name, id = u.to })
                end
            end
        end
    end
    for i, s in ipairs(df.stmts) do
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
        local cs = calls_at[i]
        if cs then
            local names, seen = {}, {}
            for _, c in ipairs(cs) do
                if not seen[c.callee] then seen[c.callee] = true; names[#names + 1] = c.callee end
            end
            if dim_from == nil then dim_from = #text end
            text = text .. '   → ' .. table.concat(names, ' ')
        end
        local vs = vars_at[i]
        if vs then
            local names, seen = {}, {}
            for _, v in ipairs(vs) do
                if not seen[v.name] then seen[v.name] = true; names[#names + 1] = v.name end
            end
            if dim_from == nil then dim_from = #text end
            text = text .. '   · ' .. table.concat(names, ' ')
        end
        ctx.lines[#ctx.lines + 1] = text
        if dim_from then ctx.marks[#ctx.lines] = { { dim_from, -1, 'CartographDim' } } end
        ctx.vnums[#ctx.lines] = tostring(s.l)
        ctx.line_stmt[#ctx.lines] = s.l   -- 1-based file line
        ctx.line_stmtidx[#ctx.lines] = i  -- index into df.stmts
        ctx.line_calls[#ctx.lines] = cs   -- call entries on this row's line
        ctx.line_vars[#ctx.lines]  = vs   -- module vars read by this statement
    end
end

function M.render()
    if not (M.buf and vim.api.nvim_buf_is_valid(M.buf)) then return end
    local ctx = { lines = {}, marks = {}, vnums = {}, signs = {},
        line_node = {}, node_line = {}, line_file = {}, file_header = {}, line_stmt = {},
        line_stmtidx = {}, line_calls = {}, line_site = {}, line_callers = {}, line_vars = {} }
    local v = M.view
    if v.level == 'files' then
        if M.files_mode == 'tree' then render_files_tree(ctx) else render_files(ctx) end
    elseif v.level == 'file' then render_file(ctx, v.file)
    elseif v.level == 'block' then render_block(ctx, v.block)
    elseif v.level == 'var' then render_var(ctx, v.var)
    elseif v.level == 'tbl' then render_tbl(ctx, v.tbl)
    elseif v.level == 'callers' then render_callers(ctx, v.callers)
    else render_fn(ctx, v.fn) end

    M.line_node, M.node_line = ctx.line_node, ctx.node_line
    M.line_file, M.file_header, M.line_stmt = ctx.line_file, ctx.file_header, ctx.line_stmt
    M.line_stmtidx, M.line_calls, M.line_site = ctx.line_stmtidx, ctx.line_calls, ctx.line_site
    M.line_callers, M.line_vars = ctx.line_callers, ctx.line_vars

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
    if ctx_val ~= nil then
        if level == 'file' then M.view.file = ctx_val
        elseif level == 'fn' then M.view.fn = ctx_val
        elseif level == 'block' then M.view.block = ctx_val
        elseif level == 'var' then M.view.var = ctx_val
        elseif level == 'tbl' then M.view.tbl = ctx_val
        elseif level == 'callers' then M.view.callers = ctx_val end
    end
    M.render()
    if M.win and vim.api.nvim_win_is_valid(M.win) then
        local first = 1
        for row = 1, vim.api.nvim_buf_line_count(M.buf) do
            if M.line_node[row] or M.line_stmt[row] or M.line_site[row]
                or (level == 'files' and M.line_file[row]) then
                first = row
                break
            end
        end
        pcall(vim.api.nvim_win_set_cursor, M.win, { first, 2 })
        -- landing on a row must act like arriving on it (set_cursor to the
        -- same position fires no CursorMoved of its own)
        vim.api.nvim_exec_autocmds('CursorMoved', { buffer = M.buf })
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
    vim.wo[win].cursorline = true
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
                if M.view.level == 'file' or M.view.level == 'block'
                    or M.view.level == 'tbl' then
                    -- hover TINTS relationships and PREVIEWS the row in the
                    -- source pane (context takeover, restored on leave); it
                    -- never re-roots the cockpit (pivoting stays a conscious
                    -- <CR>/l): the view follows the eye, focus follows intent
                    local id = M.line_node[r]
                    if id then
                        M.paint(id)
                        if id ~= store.focused then
                            store.set_context({ node = id })
                        else
                            store.set_context(nil)
                        end
                    end
                elseif M.view.level == 'fn' then
                    local l = M.line_stmt[r]
                    local n = store.node(M.view.fn)
                    if l and n then
                        store.set_highlight({ file = n.file, ranges = {
                            { start = { line = l - 1, char = 0 }, ['end'] = { line = l, char = 0 } } } })
                    end
                elseif M.view.level == 'var' or M.view.level == 'callers' then
                    -- hover a usage site -> its function in the bottom source
                    -- view, the read highlighted (same pattern as trace hover)
                    local s = M.line_site[r]
                    if s then store.set_context({ node = s.fn, ranges = { s.range } })
                    else store.set_context(nil) end
                end
            end, 60)
        end,
    })

    -- location history: each pivot snapshots the browser's place, so <C-o>
    -- restores WHERE you were (level, file, cursor row), not just what was
    -- focused
    local function view_loc()
        return { level = M.view.level, file = M.view.file, fn = M.view.fn,
            block = M.view.block, var = M.view.var, callers = M.view.callers,
            files_mode = M.files_mode,
            row = (M.win and vim.api.nvim_win_is_valid(M.win))
                and vim.api.nvim_win_get_cursor(M.win)[1] or 1 }
    end
    local function restore_loc(loc)
        M.files_mode = loc.files_mode or M.files_mode
        M.view.file, M.view.fn, M.view.block, M.view.var, M.view.callers =
            loc.file, loc.fn, loc.block, loc.var, loc.callers
        M.show(loc.level)
        if loc.row then pcall(vim.api.nvim_win_set_cursor, M.win, { loc.row, 2 }) end
    end
    local function push_trail() M.trail[#M.trail + 1] = view_loc() end
    -- browser-initiated pivots must not clear the trail (see on_focus)
    local function browser_pivot(id)
        M._own_pivot = true
        store.pivot(id)
        M._own_pivot = false
    end
    -- Descend into (level, ctxval): if that's exactly the place the last h
    -- left, restore it (cursor row and all); a different descend branches,
    -- which invalidates the forward memory — the two-stack h/l pair.
    -- a var with members is a TABLE: descend shows them; a scalar shows sites
    local function enter_var(id)
        if #table_members(id) > 0 then return 'tbl' end
        return 'var'
    end
    local function enter(level, ctxval, pivot_id)
        push_trail()
        if pivot_id then browser_pivot(pivot_id) end
        local top = M.fwd_trail[#M.fwd_trail]
        if top and top.level == level and top[level] == ctxval then
            table.remove(M.fwd_trail)
            restore_loc(top)
        else
            M.fwd_trail = {}
            M.show(level, ctxval)
        end
    end
    store.loc_provider = {
        get = function ()
            local l = view_loc()
            l.trail = vim.list_extend({}, M.trail)
            l.fwd_trail = vim.list_extend({}, M.fwd_trail)
            return l
        end,
        set = function (loc)
            M.trail = loc.trail and vim.list_extend({}, loc.trail) or {}
            M.fwd_trail = loc.fwd_trail and vim.list_extend({}, loc.fwd_trail) or {}
            restore_loc(loc)
        end,
    }

    store.on_focus(function (id)
        local n = store.node(id)
        -- conscious pivots re-scope the browser to where they landed; an
        -- EXTERNAL pivot (source <C-]>) starts a fresh journey, so the trail
        -- clears — h ascends structurally from there
        if n and M.view.level == 'fn' and STAGEABLE[n.kind] and M.view.fn ~= id then
            if not M._own_pivot then M.trail, M.fwd_trail = {}, {} end
            M.show('fn', id)
        elseif n and (M.view.level == 'file' or M.view.level == 'files')
            and not M.node_line[id] and n.file ~= M.view.file then
            if not M._own_pivot then M.trail, M.fwd_trail = {}, {} end
            M.show('file', n.file)
        end
        local ln = M.node_line[id]
        if ln and M.win and vim.api.nvim_win_is_valid(M.win)
            and vim.api.nvim_win_get_buf(M.win) == M.buf then
            vim.api.nvim_win_set_cursor(M.win, { ln, 2 })
        end
        M.paint(id)
    end)

    -- zoom: l / <CR> descend, h ascends — sideways is free in a linear list,
    -- so it becomes altitude. Below the fn level, descend keeps going INTO
    -- the graph: it acts on the name under the cursor (callee -> that
    -- function, param -> its origin trace, local -> its def statement),
    -- falling back to the statement's only resolvable callee; a var row
    -- descends into its usage sites, and a usage site into its function.
    local function word_at(text, col)
        local init = 1
        while true do
            local s, e = text:find('[%w_]+', init)
            if not s then return nil end
            if col + 1 >= s and col + 1 <= e then return text:sub(s, e) end
            init = e + 1
        end
    end
    local function descend_fn_row(r)
        local node = store.node(M.view.fn)
        if not node then return end
        local col  = vim.api.nvim_win_get_cursor(win)[2]
        local text = vim.api.nvim_buf_get_lines(M.buf, r - 1, r, false)[1] or ''
        local word = word_at(text, col)
        -- 1. a callee named under the cursor: follow the call
        for _, c in ipairs(M.line_calls[r] or {}) do
            if c.callee == word and c.to and store.node(c.to) then
                return enter('fn', c.to, c.to)
            end
        end
        -- 2. a parameter: where does it come from? (the origin trace)
        for pi, p in ipairs(node.params or {}) do
            if p == word then
                return require('cartograph.panes.trace').open(node.id, pi, p)
            end
        end
        -- 3. a local: jump to its defining statement (latest before this row)
        local i, df = M.line_stmtidx[r], node.df
        if word and i and df then
            local best
            for j = 1, #df.stmts do
                if j ~= i then
                    for _, d in ipairs(df.stmts[j].def) do
                        if d == word and (j < i or not best) then best = j end
                    end
                end
            end
            if best then
                for rr, jj in pairs(M.line_stmtidx) do
                    if jj == best then
                        return pcall(vim.api.nvim_win_set_cursor, win, { rr, 2 })
                    end
                end
            end
        end
        -- 4. a module var / global read named under the cursor: its usages
        for _, v in ipairs(M.line_vars[r] or {}) do
            for seg in (v.name or ''):gmatch('[%w_]+') do
                if seg == word then
                    return enter(enter_var(v.id), v.id, v.id)
                end
            end
        end
        -- 5. fallback: the statement's only resolvable callee
        local sole
        for _, c in ipairs(M.line_calls[r] or {}) do
            if c.to and store.node(c.to) then sole = (sole == nil) and c or false end
        end
        if sole and sole ~= false then
            enter('fn', sole.to, sole.to)
        end
    end
    local function descend()
        local r = row()
        if M.view.level == 'files' then
            local f = M.line_file[r]
            if f then enter('file', f) end
        elseif M.view.level == 'file' then
            local n = store.node(M.line_node[r])
            if n and STAGEABLE[n.kind] then
                enter('fn', n.id, n.id)
            elseif n and n.kind == 'block' then
                enter('block', n.id, n.id) -- source pane shows the block's span
            end
        elseif M.view.level == 'block' then
            local n = store.node(M.line_node[r])
            if n and n.kind == 'var' then
                enter(enter_var(n.id), n.id, n.id)
            end
        elseif M.view.level == 'var' or M.view.level == 'callers' then
            local s = M.line_site[r]
            if s and store.node(s.fn) then
                store.set_context(nil)
                enter('fn', s.fn, s.fn)
            end
        elseif M.view.level == 'tbl' then
            if M.line_callers[r] then
                return enter('var', M.line_callers[r])
            end
            local n = store.node(M.line_node[r])
            if n and STAGEABLE[n.kind] then
                enter('fn', n.id, n.id)
            elseif n and n.kind == 'var' then
                enter(enter_var(n.id), n.id, n.id)
            end
        elseif M.view.level == 'fn' then
            if M.line_callers[r] then
                return enter('callers', M.line_callers[r])
            end
            descend_fn_row(r)
        end
    end
    vim.keymap.set('n', keys.descend, descend,
        { buffer = M.buf, desc = 'cartograph: descend (into file / into function)' })
    vim.keymap.set('n', keys.pivot, function ()
        if M.view.level == 'file' or M.view.level == 'block' then
            local id = M.line_node[row()]
            if id then return store.pivot(id) end -- focus, stay at this altitude
        end
        descend()
    end, { buffer = M.buf, nowait = true, desc = 'cartograph: pivot here (focus without zooming)' })
    -- ascending lands the cursor ON what we came from (the file-manager rule),
    -- not on the first row of the wider view
    vim.keymap.set('n', keys.ascend, function ()
        if #M.trail == 0 and M.view.level == 'files' then return end
        -- remember exactly where we left, so l can return there (row and all)
        M.fwd_trail[#M.fwd_trail + 1] = view_loc()
        -- journey-back: return the way you came (l pushed it); structural
        -- ascent is the fallback for places you jumped into
        if #M.trail > 0 then
            local loc = table.remove(M.trail)
            store.set_highlight(nil)
            store.set_context(nil)
            return restore_loc(loc)
        end
        if M.view.level == 'var' then
            store.set_context(nil)
            local id = M.view.var
            M.show('block', M.view.block)
            local r = M.node_line[id]
            if r then pcall(vim.api.nvim_win_set_cursor, win, { r, 2 }) end
        elseif M.view.level == 'callers' then
            store.set_context(nil)
            M.show('fn', M.view.callers)
            pcall(vim.api.nvim_win_set_cursor, win, { 2, 0 })
        elseif M.view.level == 'fn' or M.view.level == 'block'
            or M.view.level == 'tbl' then
            store.set_highlight(nil)
            local id = (M.view.level == 'fn' and M.view.fn)
                or (M.view.level == 'block' and M.view.block) or M.view.tbl
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
        local site = M.line_site[r]
        local n = store.node(M.line_node[r]) or (site and store.node(site.fn))
        local file = (site and site.file) or (n and n.file) or M.line_file[r]
            or (M.view.level == 'fn' and store.node(M.view.fn) and store.node(M.view.fn).file)
        if not file then return end
        local lnum = (site and site.line + 1) or (M.view.level == 'fn' and M.line_stmt[r])
            or (n and n.range.start.line + 1) or 1
        vim.cmd('tab drop ' .. vim.fn.fnameescape(store.data.root .. '/' .. file))
        pcall(vim.api.nvim_win_set_cursor, 0, { lnum, 0 })
    end, { buffer = M.buf, desc = 'cartograph: open the real file here' })

    store.on_plan(function () M.restage() end)

    vim.api.nvim_buf_create_user_command(M.buf, 'CartographHeat', function () M.toggle_heat() end,
        { desc = 'cartograph: toggle the hub/heat overlay (fan-in/out + role)' })
end

return M
