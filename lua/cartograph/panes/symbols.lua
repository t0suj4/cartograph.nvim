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
    line_group = {}, line_sep = {}, line_state = {}, line_trans = {}, line_lit = {},
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

local function pesc(s) return (tostring(s):gsub('([^%w])', '%%%1')) end

local function shown_defs(file)
    local defs = {}
    for _, n in ipairs(store.by_file[file] or {}) do
        if SHOW_L2[n.kind] then defs[#defs + 1] = n end
    end
    return defs
end

local function file_row(ctx, file, depth, dim)
    local indent = string.rep('  ', depth or 0)
    local mod = store.by_id and store.by_id[file]
    if mod and mod.unparsed then
        ctx.lines[#ctx.lines + 1] = ('%s%s  (unparsed)'):format(indent, file)
        ctx.marks[#ctx.lines] = { { 0, -1, 'CartographDim' } }
        ctx.line_file[#ctx.lines] = file
        return
    end
    ctx.lines[#ctx.lines + 1] = ('%s%s  (%d)%s'):format(indent, file, #shown_defs(file), dim and ' …' or '')
    ctx.marks[#ctx.lines] = dim and { { 0, -1, 'CartographDim' } }
        or { { #indent, #indent + #file, 'CartographSection' }, { #indent + #file, -1, 'CartographDim' } }
    ctx.line_file[#ctx.lines] = file
    local sign = SIGN[store.classify(file)]
    if sign then ctx.signs[#ctx.signs + 1] = { row = #ctx.lines - 1, sign = sign } end
end

-- The working-set altitude: what the user marked, grouped by file — the
-- place to come back to after a code dive (M lands the cursor on the
-- last-visited member). Unresolved members (renamed away, file gone)
-- stay visible as honest pending rows.
local function render_ws(ctx)
    local list = store.ws_list()
    ctx.lines[1] = ('working set (%d)'):format(#list)
    ctx.marks[1] = { { 0, -1, 'CartographSection' } }
    local lastfile
    for _, n in ipairs(list) do
        if n.file ~= lastfile then
            lastfile = n.file
            ctx.lines[#ctx.lines + 1] = n.file
            ctx.marks[#ctx.lines] = { { 0, -1, 'CartographDim' } }
            ctx.line_file[#ctx.lines] = n.file
        end
        ctx.lines[#ctx.lines + 1] = '  ' .. n.name
        ctx.line_node[#ctx.lines] = n.id
        ctx.node_line[n.id] = #ctx.lines
    end
    if #list == 0 and #(store.workset.pending or {}) == 0 then
        ctx.lines[#ctx.lines + 1] = "  (empty — 'm' on a symbol marks it)"
        ctx.marks[#ctx.lines] = { { 0, -1, 'CartographDim' } }
    end
    for _, p in ipairs(store.workset.pending or {}) do
        ctx.lines[#ctx.lines + 1] = ('  ? %s  %s — unresolved')
            :format(p.name, p.file)
        ctx.marks[#ctx.lines] = { { 0, -1, 'CartographFrontier' } }
    end
end

local function render_files(ctx)
    -- a streaming open says how far along it is — partial is not complete
    if store.data and store.data.partial then
        ctx.lines[1] = ('extracting… %d/%d batches (links partial; l on a'
            .. ' file extracts it now)')
            :format(store.data.partial.done, store.data.partial.total)
        ctx.marks[1] = { { 0, -1, 'CartographFrontier' } }
    end
    -- sampled graphs (MCP) say when they were true; disk graphs don't age
    if store.data and store.data.fetched_at then
        ctx.lines[1] = ('%s — fetched %s'):format(
            store.data.provider or 'sample',
            os.date('%H:%M:%S', store.data.fetched_at))
        ctx.marks[1] = { { 0, -1, 'CartographSection' } }
    end
    for _, file in ipairs(store.files) do
        file_row(ctx, file, 0)
        if store.toc then -- manifest project: show each file's load position
            local i = store.toc.index[file]
            ctx.vnums[#ctx.lines] = i and tostring(i) or ''
        end
    end
end

-- Manifest projects: <Tab>'s tree is the LOAD ORDER (the .toc top to
-- bottom, XML includes indented), because that IS the load structure —
-- there are no requires. Unlisted files close the view: they never load.
local function render_files_load(ctx)
    local t = store.toc
    ctx.lines[1] = ('load order — %s'):format(t.toc)
    ctx.marks[1] = { { 0, -1, 'CartographSection' } }
    for i, e in ipairs(t.entries) do
        file_row(ctx, e.file, e.depth)
        ctx.vnums[#ctx.lines] = tostring(i)
    end
    if #(t.unlisted or {}) > 0 then
        ctx.lines[#ctx.lines + 1] = '── never loaded ──'
        ctx.marks[#ctx.lines] = { { 0, -1, 'CartographDim' } }
        ctx.line_sep[#ctx.lines] = true
        for _, f in ipairs(t.unlisted) do file_row(ctx, f, 0) end
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
    -- external sites first; self/internal (the entity's own class, or itself)
    -- after, dimmed — usually the majority and the least surprising
    table.sort(sites, function (a, b)
        if (a.internal or false) ~= (b.internal or false) then return not a.internal end
        if a.file ~= b.file then return (a.file or '') < (b.file or '') end
        return a.line < b.line
    end)
    local nint = 0
    for _, s in ipairs(sites) do if s.internal then nint = nint + 1 end end
    local counts = (#sites - nint > 0 and nint > 0)
            and ('%d + %d self'):format(#sites - nint, nint)
        or (nint > 0 and ('%d self'):format(nint))
        or tostring(#sites)
    local name = node.name or '?'
    ctx.lines[1] = ('%s %s — %s (%s)'):format(icon, name, label, counts)
    ctx.marks[1] = { { 0, #icon, 'CartographDim' }, { #icon + 1, #icon + 1 + #name, 'CartographTitle' },
                     { #icon + 1 + #name, -1, 'CartographDim' } }

    -- group per using function: a single site stays one flat row; several
    -- fold into a subtree (`▸ name (n)`, l toggles) whose children are the
    -- occurrences, shown as real source-line snippets
    local groups, order = {}, {}
    for _, s in ipairs(sites) do
        local g = groups[s.fn]
        if not g then
            g = { fn = s.fn, name = s.name, internal = s.internal,
                  inferred = s.inferred, sites = {} }
            groups[s.fn] = g
            order[#order + 1] = g
        end
        g.rec = g.rec or s.rec
        g.sites[#g.sites + 1] = s
    end

    -- externals, then a chrome-only separator, then the self section — the
    -- position carries the meaning, so no dimming and no repeated prefix
    -- (internal names are stripped like the table-members view)
    local sep_pending = nint > 0 and nint < #sites
    for _, g in ipairs(order) do
        if g.internal and sep_pending then
            ctx.lines[#ctx.lines + 1] = '  ── self ' .. string.rep('─', 24)
            ctx.marks[#ctx.lines] = { { 0, -1, 'CartographDim' } }
            ctx.line_sep[#ctx.lines] = true
            sep_pending = false
        end
        local disp = (g.sites[1].short or g.name)
        if #g.sites == 1 then
            local st = g.sites[1]
            local text = '  ' .. disp .. (st.rec and ' ⟳' or '') .. (st.inferred and ' ~' or '')
            ctx.lines[#ctx.lines + 1] = text
            if st.inferred then ctx.marks[#ctx.lines] = { { #text - 2, -1, 'CartographDim' } } end
            ctx.vnums[#ctx.lines] = tostring(st.line + 1)
            ctx.line_site[#ctx.lines] = st
        else
            -- several sites: the row DESCENDS into the occurrences (no folds —
            -- the browser has altitude, l/h are the only vocabulary)
            local text = ('  %s (%d)%s%s'):format(
                disp, #g.sites, g.rec and ' ⟳' or '', g.inferred and ' ~' or '')
            ctx.lines[#ctx.lines + 1] = text
            ctx.marks[#ctx.lines] = { { 2 + #disp, -1, 'CartographDim' } }
            ctx.line_group[#ctx.lines] = g
        end
    end
    if #sites == 0 then
        ctx.lines[2] = '  ' .. empty_note
        ctx.marks[2] = { { 0, -1, 'CartographDim' } }
    end
end

-- Which class does a name belong to? 'BnwForce:trigger' -> 'BnwForce'
local function class_of(name)
    return name and name:match('^(.-)[.:][%w_]+$')
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
    local p1, p2 = (node.name or '') .. '.', (node.name or '') .. ':'
    for _, u in ipairs(store.var_usedby[id] or {}) do
        local fn = store.node(u.from)
        local member = fn and fn.name
            and (fn.name:sub(1, #p1) == p1 or fn.name:sub(1, #p2) == p2) or nil
        for _, r in ipairs(u.at) do
            sites[#sites + 1] = { fn = u.from, name = fn and fn.name or u.from,
                short = member and fn.name:sub(#(node.name or '') + 1) or nil,
                file = fn and fn.file, line = r.start.line, range = r,
                internal = member }
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
    local cls = class_of(node.name)
    local selfshort = class_of(node.name) and node.name
        and node.name:sub(#class_of(node.name) + 1) or nil
    for _, r in ipairs(store.occurrences(id, id) or {}) do -- recursion (self edge)
        sites[#sites + 1] = { fn = id, name = node.name or id, short = selfshort,
            file = node.file, line = r.start.line, range = r, rec = true, internal = true }
    end
    for _, from in ipairs(store.usedby[id] or {}) do
        local fn = store.node(from)
        local inf = store.edge_inferred[from .. '\31' .. id]
        local rec = from == id or nil
        local internal = rec or (cls ~= nil and class_of(fn and fn.name) == cls) or nil
        local short = internal and cls and fn and fn.name
            and fn.name:sub(1, #cls) == cls and fn.name:sub(#cls + 1) or nil
        for _, r in ipairs(store.occurrences(from, id) or {}) do
            sites[#sites + 1] = { fn = from, name = fn and fn.name or from,
                short = short,
                file = fn and fn.file, line = r.start.line, range = r, inferred = inf,
                rec = rec, internal = internal }
        end
    end
    render_sites(ctx, node, ICON[node.kind] or 'ƒ', 'callers', sites,
        '(no callers found — entry point, or dynamically dispatched)')
end

-- A REFUSAL as a place: an unresolved call kept the rule that refused
-- it and the candidates it refused between. The browser makes that a
-- fork in the road — the candidates as jumpable rows, the reasoning
-- named — instead of a dead end. `p` pins the candidate under the
-- cursor (a target-qualified pin: this ambiguous call, THIS def).
local REFUSAL_WHY = {
    ambiguous = 'more than one candidate fits — the tool will not pick',
    blocked   = 'candidates exist but none in scope (or another language)',
    samefile  = 'defined more than once in this file',
    vocab     = 'a stdlib / framework name — never linked to a project def',
}
local function render_refused(ctx, call)
    if not call then ctx.lines[1] = '(refusal gone — regenerate)'; return end
    local ref = call.refused or {}
    local pre = '⚠'
    ctx.lines[1] = ('%s %s — refused'):format(pre, call.callee or '?')
    ctx.marks[1] = { { 0, #pre, 'CartographFrontier' },
        { #pre, #pre + 1 + #(call.callee or '?'), 'CartographTitle' },
        { #pre + 1 + #(call.callee or '?'), -1, 'CartographDim' } }
    ctx.lines[2] = '  ' .. (REFUSAL_WHY[ref.rule] or 'not resolvable')
    ctx.marks[2] = { { 0, -1, 'CartographDim' } }
    local cands = ref.cands or {}
    if #cands == 0 then
        ctx.lines[3] = '  (no candidates recorded)'
        ctx.marks[3] = { { 0, -1, 'CartographDim' } }
        return
    end
    ctx.lines[3] = ('candidates (%d%s):'):format(ref.n or #cands,
        (ref.n and ref.n > #cands) and (', showing ' .. #cands) or '')
    ctx.marks[3] = { { 0, -1, 'CartographSection' } }
    for _, cid in ipairs(cands) do
        local n = store.node(cid)
        if n then
            local file = n.file or '?'
            ctx.lines[#ctx.lines + 1] = ('  %s'):format(n.name or cid)
            ctx.marks[#ctx.lines] = { { 0, -1, 'CartographTitle' } }
            ctx.line_node[#ctx.lines] = cid
            ctx.node_line[cid] = #ctx.lines
            -- the file, dim, right-aligned (the sites-view idiom)
            ctx.line_file[#ctx.lines] = file
        end
    end
    ctx.lines[#ctx.lines + 1] = ''
    ctx.lines[#ctx.lines + 1] = '  p pins the candidate under the cursor'
    ctx.marks[#ctx.lines] = { { 0, -1, 'CartographDim' } }
    ctx.line_sep[#ctx.lines] = true
end

-- The registrants of a function: who keeps it alive without calling it
-- (a dispatch table, a load-time callback list). Each row is the
-- registering module at the reference site — descend enters the file
-- there, gf opens it.
local function render_regfor(ctx, id)
    local node = store.node(id)
    if not node then ctx.lines[1] = '(gone)'; return end
    local regs = store.reg_by and store.reg_by[id] or {}
    local pre = ICON[node.kind] or 'ƒ'
    ctx.lines[1] = ('%s %s — registered by (%d)'):format(pre, node.name or '?', #regs)
    ctx.marks[1] = { { 0, #pre, 'CartographDim' },
        { #pre, #pre + 1 + #(node.name or '?'), 'CartographTitle' },
        { #pre + 1 + #(node.name or '?'), -1, 'CartographDim' } }
    for _, r in ipairs(regs) do
        local at = r.at and r.at[1]
        local line = at and at.start.line
        local label = line and ('%s:%d'):format(r.from, line + 1) or r.from
        ctx.lines[#ctx.lines + 1] = '  ' .. label
        ctx.marks[#ctx.lines] = { { 0, -1, 'CartographTitle' } }
        ctx.line_file[#ctx.lines] = r.from
        if line then
            ctx.line_site[#ctx.lines] = { fn = r.from, file = r.from,
                line = line, range = at }
        end
    end
    if #regs == 0 then
        ctx.lines[2] = '  (none)'
        ctx.marks[2] = { { 0, -1, 'CartographDim' } }
    end
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

-- Inside a LITERAL data table: entries as rows. Scalars show their value,
-- nested tables descend deeper, {ref='x'} follows to the referenced var.
-- key = var id \31 seg \31 seg … (the path into the data).
local function lit_walk(key)
    local parts = vim.split(key or '', '\31')
    local id = table.remove(parts, 1)
    local node = store.node(id)
    local val = node and node.data
    for _, seg in ipairs(parts) do
        if type(val) ~= 'table' then val = nil break end
        val = val[seg] ~= nil and val[seg] or val[tonumber(seg)]
    end
    return node, val, parts
end

local function render_lit(ctx, key)
    local node, val, path = lit_walk(key)
    if not (node and type(val) == 'table') then ctx.lines[1] = '(gone)'; return end
    local crumb = (node.name or '?')
        .. (#path > 0 and ('.' .. table.concat(path, '.')) or '')
    ctx.lines[1] = ('· %s'):format(crumb)
    ctx.marks[1] = { { 0, 1, 'CartographDim' }, { 1, -1, 'CartographTitle' } }
    if #path == 0 then -- usage sites one row away, as in the class-table view
        local nsites = 0
        for _, u in ipairs(store.var_usedby[node.id] or {}) do nsites = nsites + #u.at end
        ctx.lines[2] = ('↖ used by (%d)'):format(nsites)
        ctx.marks[2] = { { 0, -1, 'CartographSection' } }
        ctx.line_callers[2] = node.id
    end
    -- array part in order, then map keys sorted
    local keys = {}
    for i in ipairs(val) do keys[#keys + 1] = i end
    local arrn = #keys
    local mapk = {}
    for k in pairs(val) do
        if not (type(k) == 'number' and k % 1 == 0 and k >= 1 and k <= arrn) then
            mapk[#mapk + 1] = k
        end
    end
    table.sort(mapk, function (a, b) return tostring(a) < tostring(b) end)
    vim.list_extend(keys, mapk)
    local rows = {}
    for _, k in ipairs(keys) do
        local v = val[k]
        local row
        if type(v) == 'table' and v.ref then
            row = { label = ('%s → %s'):format(
                    type(k) == 'number' and ('[%d]'):format(k) or k, v.ref),
                entry = { kind = 'ref', ref = v.ref },
                needle = '%f[%w_]' .. pesc(v.ref) .. '%f[^%w_]' }
        elseif type(v) == 'table' and v.expr then
            -- a non-literal element the extractor couldn't take: honest text
            row = { label = type(k) == 'number' and v.expr
                    or ('%s = %s'):format(k, v.expr),
                entry = { kind = 'scalar' },
                needle = type(k) ~= 'number' and ('%f[%w_]' .. pesc(k) .. '%s*=')
                    or pesc(v.expr) }
        elseif type(v) == 'table' then
            -- name the entry when the data itself does (name= or a string
            -- element); a contained ref's tail disambiguates duplicates
            local tag = type(v.name) == 'string' and v.name or nil
            local reftail
            for _, el in ipairs(v) do
                if not tag and type(el) == 'string' then tag = el end
                if not reftail and type(el) == 'table' and el.ref then
                    reftail = el.ref:match('[^.]+$')
                end
            end
            local n = 0
            for _ in pairs(v) do n = n + 1 end
            row = { label = type(k) == 'number' and (tag or ('[%d]'):format(k))
                    or tostring(k),
                reftail = reftail, vnum = tostring(n),
                entry = { kind = 'tbl',
                    key = key .. '\31' .. (type(k) == 'number' and tostring(k) or k) },
                needle = tag and ('["\']' .. pesc(tag) .. '["\']')
                    or (type(k) ~= 'number' and ('%f[%w_]' .. pesc(k) .. '%s*=') or nil) }
        else
            local vt = type(v) == 'string' and ('%q'):format(v) or tostring(v)
            row = { label = type(k) == 'number' and vt or ('%s = %s'):format(k, vt),
                entry = { kind = 'scalar' },
                needle = type(v) == 'string' and ('["\']' .. pesc(v) .. '["\']')
                    or '%f[%w_]' .. pesc(v) .. '%f[^%w_]' }
        end
        rows[#rows + 1] = row
    end
    local dup = {}
    for _, row in ipairs(rows) do dup[row.label] = (dup[row.label] or 0) + 1 end
    for _, row in ipairs(rows) do
        row.entry.needle = row.needle
        local pref = '  · '
        local label, tail = row.label, ''
        if dup[label] > 1 and row.reftail then tail = ' · ' .. row.reftail end
        ctx.lines[#ctx.lines + 1] = pref .. label .. tail
        local marks = { { 2, #pref - 1, 'CartographDim' } }
        local eq = label:find(' = ', 1, true) or label:find(' → ', 1, true)
        if eq then marks[#marks + 1] = { #pref + eq - 1, #pref + #label, 'CartographLit' } end
        if tail ~= '' then marks[#marks + 1] = { #pref + #label, -1, 'CartographDim' } end
        ctx.marks[#ctx.lines] = marks
        if row.vnum then ctx.vnums[#ctx.lines] = row.vnum end
        ctx.line_lit[#ctx.lines] = row.entry
    end
end

-- One function's occurrences of the entity (the sites-view drill-down):
-- rows are real source lines. key = kind \31 entity id \31 using-fn id.
local function render_occs(ctx, key)
    local kind, entity, fnid = key:match('^(.-)\31(.-)\31(.*)$')
    local en, fn = store.node(entity), store.node(fnid)
    if not (en and fn) then ctx.lines[1] = '(gone)'; return end
    local ranges = {}
    if kind == 'var' then
        for _, u in ipairs(store.var_usedby[entity] or {}) do
            if u.from == fnid then
                for _, r in ipairs(u.at) do ranges[#ranges + 1] = r end
            end
        end
    else
        for _, r in ipairs(store.occurrences(fnid, entity) or {}) do
            ranges[#ranges + 1] = r
        end
    end
    table.sort(ranges, function (a, b) return a.start.line < b.start.line end)
    local fname = fn.name or '?'
    ctx.lines[1] = ('%s — sites of %s (%d)'):format(fname, en.name or '?', #ranges)
    ctx.marks[1] = { { 0, #fname, 'CartographTitle' }, { #fname, -1, 'CartographDim' } }
    -- each row shows the REFERENCE itself (sliced from its range), tail-
    -- stripped to the accessed field: `local bar = self.foo` reads `.foo`.
    -- The full statement is one hover away in the source pane.
    local cache = {}
    local function rawline(file, l0)
        if cache[file] == nil then
            local okr, all = pcall(vim.fn.readfile, store.data.root .. '/' .. file)
            cache[file] = okr and all or false
        end
        return (cache[file] and cache[file][l0 + 1]) or ''
    end
    for _, r in ipairs(ranges) do
        local line = rawline(fn.file, r.start.line)
        local t
        if r['end'].line == r.start.line then
            t = line:sub(r.start.char + 1, r['end'].char)
        else
            t = line:sub(r.start.char + 1)
        end
        if t == '' then t = line:gsub('^%s+', '') end
        -- follow the whole access CHAIN through the reference: `local x =
        -- self.bnw.home.surface` shows (and highlights) as `.bnw.home.surface`;
        -- a genuinely standalone ref (argument position) keeps the bare name
        if r['end'].line == r.start.line then
            local bs, be = line:find('^[%w_]+', r.start.char + 1)
            if bs then
                local i, parts = be + 1, {}
                while true do
                    local s2, e2, sep, name = line:find('^%s*([.:])%s*([%w_]+)', i)
                    if not s2 then break end
                    parts[#parts + 1] = sep .. name
                    i = e2 + 1
                end
                if #parts > 0 then
                    t = table.concat(parts)
                    r = { start = r.start, ['end'] = { line = r.start.line, char = i - 1 } }
                end
            end
        end
        ctx.lines[#ctx.lines + 1] = '  ' .. t
        ctx.vnums[#ctx.lines] = tostring(r.start.line + 1)
        ctx.line_site[#ctx.lines] = { fn = fnid, name = fname, file = fn.file,
            line = r.start.line, range = r }
    end
end

-- STATES level: the state machine's states, each with its reachability cone
-- size. Data + adapter via cartograph.fsm; nil model renders the reason.
local fsm = require 'cartograph.fsm'

local function fsm_model()
    if not M._fsm or M._fsm_data ~= store.data then
        local model, why = fsm.load(store)
        if not model then
            -- no configured spec: shape-detect one (any {name,from,to} list)
            local cfg = fsm.detect(store)
            if cfg then model, why = fsm.load(store, cfg) end
        end
        M._fsm, M._fsm_why, M._fsm_data = model or false, why, store.data
    end
    return M._fsm or nil, M._fsm_why
end

--- The states altitude is ANCHORED in the source: it hangs below the spec
--- var (the events table). Descending on that var enters 'states'; ascending
--- from 'states' lands back on it.
function M.fsm_anchor()
    local model = fsm_model()
    return model and model.events_var or nil
end

-- Hover anchor for DATA-borne rows (states, transitions, literal table
-- entries): they have no node of their own, so their "code" is the table
-- that declares them. The source pane shows the var with every line
-- matching the needle highlighted.
local function var_context(v, needle)
    local lines = vim.fn.readfile(store.abspath(v))
    local ranges = {}
    for l = v.range.start.line, math.min(v.range['end'].line, #lines - 1) do
        local s, e = (lines[l + 1] or ''):find(needle)
        if s then
            ranges[#ranges + 1] = { start = { line = l, char = s - 1 },
                ['end'] = { line = l, char = e } }
        end
    end
    store.set_context({ node = v.id, ranges = ranges })
end

local function spec_context(name)
    local model = fsm_model()
    local v = model and model.events_var
    if not v then return end
    var_context(v, '["\']' .. pesc(name) .. '["\']')
end

local function render_states(ctx)
    local model, why = fsm_model()
    ctx.lines[1] = 'states'
    ctx.marks[1] = { { 0, -1, 'CartographSection' } }
    if not model then
        ctx.lines[2] = '  (' .. (why or 'no state machine') .. ')'
        ctx.marks[2] = { { 0, -1, 'CartographDim' } }
        return
    end
    for _, st in ipairs(model.order) do
        local _, n = fsm.state_cone(store, model, st)
        local liveN = store.live and store.live.states and store.live.states[st]
        ctx.lines[#ctx.lines + 1] = '  ' .. st
            .. (liveN and ('   ◉ live' .. (liveN > 1 and ' ×' .. liveN or '')) or '')
        if liveN then
            ctx.marks[#ctx.lines] = { { 2 + #st, -1, 'CartographMarker' } }
        end
        ctx.vnums[#ctx.lines] = tostring(n)
        ctx.line_state[#ctx.lines] = st
    end
end

-- STATE level: what runs while the FSM is here — outgoing transitions
-- (descend = follow to the target state) and the active entry points
-- (descend = into the function; unresolved handlers are honest frontiers).
local function render_state(ctx, state)
    local model = fsm_model()
    if not model then ctx.lines[1] = '(no state machine)'; return end
    local _, ncone = fsm.state_cone(store, model, state)
    ctx.lines[1] = ('%s — reachable (%d)'):format(state, ncone)
    ctx.marks[1] = { { 0, #state, 'CartographTitle' }, { #state, -1, 'CartographDim' } }
    for _, t in ipairs(fsm.transitions_from(model, state)) do
        local text = ('  → %s ⇒ %s%s'):format(t.name, t.to,
            vim.tbl_contains(t.from, '*') and ' (from *)' or '')
        ctx.lines[#ctx.lines + 1] = text
        ctx.marks[#ctx.lines] = { { 0, 6 + #t.name, 'CartographDim' } }
        ctx.line_state[#ctx.lines] = t.to
        ctx.line_trans[#ctx.lines] = t.name
    end
    for _, e in ipairs(fsm.entrypoints(store, model, state)) do
        local icon = e.kind == 'listener' and '↯' or 'ƒ'
        local text = ('  %s %s%s'):format(icon, e.label, e.fn and '' or '  (unresolved)')
        ctx.lines[#ctx.lines + 1] = text
        ctx.marks[#ctx.lines] = e.fn and { { 2, 2 + #icon, 'CartographDim' } }
            or { { 0, -1, 'CartographDim' } }
        if e.fn then
            ctx.line_node[#ctx.lines] = e.fn
            ctx.node_line[e.fn] = #ctx.lines
            local n = store.node(e.fn)
            if n then ctx.vnums[#ctx.lines] = tostring(n.range.start.line + 1) end
        end
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
    ctx.lines[1] = ('%s %s%s'):format(pre, node.name or '?',
        node.access and '   (access point)' or '')
    ctx.marks[1] = { { 0, #pre, 'CartographDim' },
        { #pre, #pre + 1 + #(node.name or '?'), 'CartographTitle' } }
    if node.access then
        ctx.marks[1][#ctx.marks[1] + 1] =
            { #pre + 1 + #(node.name or '?'), -1, 'CartographDim' }
    end
    -- who calls this function — descend on the row to see the call sites
    local ncall = 0
    for _, from in ipairs(store.usedby[id] or {}) do
        ncall = ncall + #(store.occurrences(from, id) or {})
    end
    ctx.lines[2] = ('↖ callers (%d)'):format(ncall)
    ctx.marks[2] = { { 0, -1, 'CartographSection' } }
    ctx.line_callers[2] = id
    -- the other half of the alibi: registrations (kept alive by a
    -- dispatch table / load-time data, not a call). Descend to see them.
    local regs = store.reg_by and store.reg_by[id]
    if regs and #regs > 0 then
        ctx.lines[#ctx.lines + 1] = ('◆ registered by (%d)'):format(#regs)
        ctx.marks[#ctx.lines] = { { 0, -1, 'CartographSection' } }
        ctx.line_regfor[#ctx.lines] = id
    elseif node.cbarg then
        -- registered, but by an annotation/attribute/decorator ON the
        -- def itself — no site to descend into; state the alibi plainly
        ctx.lines[#ctx.lines + 1] = '◆ registered (annotation / dispatch field)'
        ctx.marks[#ctx.lines] = { { 0, -1, 'CartographDim' } }
    end
    -- the epistemic ladder for THIS fn's outgoing calls: how much of
    -- what it does is proven vs guessed vs unseeable, at a glance
    local lad = require('cartograph.ladder').tally(store, id)
    if lad.total > 0 then
        ctx.lines[#ctx.lines + 1] = 'ladder: '
            .. require('cartograph.ladder').summary(lad)
        ctx.marks[#ctx.lines] = { { 0, -1, 'CartographDim' } }
    end
    local df = node.df
    if not df then
        if node.unparsed then
            ctx.lines[3] = '  (unparsed source — landed by text search)'
            ctx.marks[3] = { { 0, -1, 'CartographDim' } }
        else
            -- no statement-level dataflow (e.g. scheme): descend into the
            -- body's nested forms, derived on demand from the source
            ctx.lines[3] = '▸ body (nested forms)'
            ctx.marks[3] = { { 0, -1, 'CartographSection' } }
            local r = node.range
            ctx.line_body[3] = ('%s\31%d\31%d\31%d\31%d'):format(id,
                r.start.line, r.start.char, r['end'].line, r['end'].char)
        end
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
                if not seen[c.callee] then
                    seen[c.callee] = true
                    -- a refused callee is a fork: mark it so, and descend
                    -- opens the candidates (see descend_fn_row)
                    local refused = not c.to and c.refused
                        and c.refused.cands and #c.refused.cands > 0
                    names[#names + 1] = (refused and '?' or '') .. c.callee
                end
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

-- Inside a compound statement / form: its immediate nested forms, one level
-- down (an if's branches, a nested scheme call's arguments). Derived ON DEMAND
-- from the source (treesitter.forms) — nothing is stored in the graph. A form
-- that has its OWN nested forms (▸) descends deeper; a leaf call descends into
-- the callee. key = fnid \31 sr \31 sc \31 er \31 ec (er<0 = position mode).
local function render_body(ctx, key)
    local fnid, srs, scs, ers, ecs =
        (key or ''):match('^(.-)\31(%-?%d+)\31(%-?%d+)\31(%-?%d+)\31(%-?%d+)$')
    local node = fnid and store.node(fnid)
    if not node then ctx.lines[1] = '(gone)'; return end
    local sr, sc, er, ec = tonumber(srs), tonumber(scs), tonumber(ers), tonumber(ecs)
    ctx.lines[1] = ('≡ %s'):format(node.name or '?')
    ctx.marks[1] = { { 0, #'≡', 'CartographDim' }, { #'≡', -1, 'CartographTitle' } }
    local ts = require 'cartograph.providers.treesitter'
    local file = store.abspath(node)
    local forms = (er and er >= 0) and ts.forms(file, sr, sc, er, ec)
        or ts.forms(file, sr, sc)
    if #forms == 0 then
        ctx.lines[2] = '  (no nested forms)'
        ctx.marks[2] = { { 0, -1, 'CartographDim' } }
        return
    end
    local calls = store.calls_by_fn[fnid] or {}
    -- the earliest call whose head token lies within a form = the form's call
    local function primary(f)
        local best
        for _, c in ipairs(calls) do
            local at = c.at and c.at.start
            if at and (at.line > f.sr or (at.line == f.sr and at.char >= f.sc))
                and (at.line < f.er or (at.line == f.er and at.char < f.ec)) then
                if not best or at.line < best.at.start.line
                    or (at.line == best.at.start.line and at.char < best.at.start.char) then
                    best = c
                end
            end
        end
        return best
    end
    for _, f in ipairs(forms) do
        ctx.lines[#ctx.lines + 1] = (f.branch and '  ▸ ' or '    ') .. f.text
        ctx.vnums[#ctx.lines] = tostring(f.sr + 1)
        ctx.line_stmt[#ctx.lines] = f.sr + 1 -- source preview/highlight anchor
        if f.branch then
            ctx.line_body[#ctx.lines] =
                ('%s\31%d\31%d\31%d\31%d'):format(fnid, f.sr, f.sc, f.er, f.ec)
            ctx.marks[#ctx.lines] = { { 0, 4, 'CartographSection' } }
        else
            local c = primary(f)
            if c then
                ctx.line_calls[#ctx.lines] = { c }
                ctx.marks[#ctx.lines] = { { 0, -1,
                    c.to and 'CartographTitle' or 'CartographDim' } }
            end
        end
    end
end

function M.render()
    if not (M.buf and vim.api.nvim_buf_is_valid(M.buf)) then return end
    local ctx = { lines = {}, marks = {}, vnums = {}, signs = {},
        line_node = {}, node_line = {}, line_file = {}, file_header = {}, line_stmt = {},
        line_stmtidx = {}, line_calls = {}, line_site = {}, line_callers = {}, line_vars = {},
        line_group = {}, line_sep = {}, line_state = {}, line_trans = {}, line_lit = {},
        line_regfor = {}, line_body = {} }
    local v = M.view
    if v.level == 'files' then
        if M.files_mode == 'tree' then
            if store.toc then render_files_load(ctx) else render_files_tree(ctx) end
        else
            render_files(ctx)
        end
    elseif v.level == 'file' then render_file(ctx, v.file)
    elseif v.level == 'block' then render_block(ctx, v.block)
    elseif v.level == 'var' then render_var(ctx, v.var)
    elseif v.level == 'tbl' then render_tbl(ctx, v.tbl)
    elseif v.level == 'callers' then render_callers(ctx, v.callers)
    elseif v.level == 'refused' then render_refused(ctx, M._refused_call)
    elseif v.level == 'regfor' then render_regfor(ctx, v.regfor)
    elseif v.level == 'occs' then render_occs(ctx, v.occs)
    elseif v.level == 'lit' then render_lit(ctx, v.lit)
    elseif v.level == 'states' then render_states(ctx)
    elseif v.level == 'state' then render_state(ctx, v.state)
    elseif v.level == 'body' then render_body(ctx, v.body)
    elseif v.level == 'ws' then render_ws(ctx)
    else render_fn(ctx, v.fn) end

    M.line_node, M.node_line = ctx.line_node, ctx.node_line
    M.line_file, M.file_header, M.line_stmt = ctx.line_file, ctx.file_header, ctx.line_stmt
    M.line_stmtidx, M.line_calls, M.line_site = ctx.line_stmtidx, ctx.line_calls, ctx.line_site
    M.line_callers, M.line_vars = ctx.line_callers, ctx.line_vars
    M.line_group, M.line_sep, M.line_state = ctx.line_group, ctx.line_sep, ctx.line_state
    M.line_trans, M.line_lit = ctx.line_trans, ctx.line_lit
    M.line_regfor, M.line_body = ctx.line_regfor, ctx.line_body

    -- names come from arbitrary source text; a row must stay one row
    for i, l in ipairs(ctx.lines) do
        if l:find('[\n\r]') then ctx.lines[i] = l:gsub('[\n\r]+', ' ¶ ') end
    end
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
        elseif level == 'callers' then M.view.callers = ctx_val
        elseif level == 'refused' then M.view.refused = ctx_val
        elseif level == 'regfor' then M.view.regfor = ctx_val
        elseif level == 'occs' then M.view.occs = ctx_val
        elseif level == 'lit' then M.view.lit = ctx_val
        elseif level == 'body' then M.view.body = ctx_val
        elseif level == 'state' then M.view.state = ctx_val end
    end
    M.render()
    if M.win and vim.api.nvim_win_is_valid(M.win) then
        local first = 1
        for row = 1, vim.api.nvim_buf_line_count(M.buf) do
            if M.line_node[row] or M.line_stmt[row] or M.line_site[row] or M.line_state[row]
                or M.line_lit[row] or M.line_body[row]
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
    -- orientation against the index: under the fn title, a ghost line
    -- says how to get back to (return path: <C-o> count) or reach
    -- (closest graph route: → descend, ↖ callers) the nearest member
    if next(store.workset.ids)
        and (M.view.level == 'fn' or M.view.level == nil) and M.view.fn then
        local id = M.view.fn
        local chunks
        if store.ws_has(id) then
            chunks = { { ' ● in the index', 'CartographDim' } }
        else
            local back = store.ws_back()
            local route = store.ws_route(id)
            if back then
                chunks = { { (' ↩ ● %s is %d×<C-o> back')
                    :format(back.name, back.steps), 'CartographDim' } }
            end
            if route and route.dist > 0 then
                local parts = {}
                for i, s in ipairs(route.path) do
                    if i > 4 then
                        parts[#parts + 1] = ('…(%d)'):format(route.dist)
                        break
                    end
                    parts[#parts + 1] = s.dir .. s.name
                end
                chunks = chunks or {}
                chunks[#chunks + 1] = { (' %s● %s'):format(
                    back and '   ' or '', table.concat(parts, ' ')),
                    'CartographDim' }
            end
        end
        if chunks then
            vim.api.nvim_buf_set_extmark(M.buf, ns_stage, 0, 0,
                { virt_lines = { chunks } })
        end
    end
    -- working-set membership: ● on member rows, and on files-level rows
    -- for files that contain members (staging's ✓ outranks it)
    if next(store.workset.ids) then
        local memberfiles = {}
        for id in pairs(store.workset.ids) do
            local r = M.node_line[id]
            if r then
                vim.api.nvim_buf_set_extmark(M.buf, ns_stage, r - 1, 0,
                    { sign_text = '● ', sign_hl_group = 'DiagnosticInfo',
                        priority = 50 })
            end
            local n = store.node(id)
            if n then memberfiles[n.file] = true end
        end
        for row, f in pairs(M.line_file) do
            if memberfiles[f] then
                vim.api.nvim_buf_set_extmark(M.buf, ns_stage, row - 1, 0,
                    { sign_text = '● ', sign_hl_group = 'DiagnosticInfo',
                        priority = 50 })
            end
        end
    end
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
    vim.wo[win].wrap = false         -- rows are rows; long ones clip, not fold
    vim.wo[win].cursorline = true
    local keys = config.keys
    local function row() return vim.api.nvim_win_get_cursor(win)[1] end
    -- forward-declared: the CursorMoved handler (below) fires the deferred
    -- ascend resync, but the helper itself is defined later in attach
    local sync_focus_to_view

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
                -- deferred ascent resync: while still on the landing row this
                -- is the ascent's own cursor placement (or no move yet) — keep
                -- the peeked source untouched. The first move OFF it commits
                -- the pane to the view we ascended to, then falls through to
                -- the normal per-row hover below.
                if M._resync then
                    if r == M._resync.row then return end
                    M._resync = nil
                    sync_focus_to_view()
                end
                if M.view.level == 'file' or M.view.level == 'block'
                    or M.view.level == 'tbl' or M.view.level == 'state' then
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
                    elseif M.view.level == 'state' and M.line_trans[r] then
                        -- a transition's "source" is its line in the spec
                        spec_context(M.line_trans[r])
                    end
                elseif M.view.level == 'states' then
                    -- a state's "source" is the spec lines that mention it
                    local st = M.line_state[r]
                    if st then spec_context(st) end
                elseif M.view.level == 'lit' then
                    -- an entry's "source" is its line in the declaring table
                    local e = M.line_lit[r]
                    local v = store.node((M.view.lit or ''):match('^[^\31]*'))
                    if e and e.needle and v then var_context(v, e.needle) end
                elseif M.view.level == 'fn' or M.view.level == 'body' then
                    local l = M.line_stmt[r]
                    local fnid = M.view.level == 'fn' and M.view.fn
                        or (M.view.body or ''):match('^(.-)\31')
                    local n = fnid and store.node(fnid)
                    if l and n then
                        store.set_highlight({ file = n.file, ranges = {
                            { start = { line = l - 1, char = 0 }, ['end'] = { line = l, char = 0 } } } })
                    end
                elseif M.view.level == 'var' or M.view.level == 'callers'
                    or M.view.level == 'occs' then
                    if M.line_sep[r] then return end -- chrome: keep the preview
                    -- hover a site -> preview it highlighted; a group row (a
                    -- function that uses the entity several times) -> preview
                    -- that function with EVERY occurrence highlighted at once
                    local s = M.line_site[r]
                    local g = M.line_group[r]
                    if s then store.set_context({ node = s.fn, ranges = { s.range } })
                    elseif g then
                        local ranges = {}
                        for _, st in ipairs(g.sites or {}) do
                            if st.range then ranges[#ranges + 1] = st.range end
                        end
                        store.set_context({ node = g.fn,
                            ranges = #ranges > 0 and ranges or nil })
                    else store.set_context(nil) end
                end
            end, 60)
        end,
    })

    -- location history: each pivot snapshots the browser's place, so <C-o>
    -- restores WHERE you were (level, file, cursor row), not just what was
    -- focused
    -- re-find the call a refused-level key names (the call object is
    -- transient; the key survives in location history)
    local function refused_call_of(key)
        local fnid, line, callee = (key or ''):match('^(.-)\31(%d+)\31(.*)$')
        if not fnid then return nil end
        line = tonumber(line)
        for _, c in ipairs(store.calls_by_fn[fnid] or {}) do
            if c.line == line and c.callee == callee and c.refused then return c end
        end
    end
    local function view_loc()
        return { level = M.view.level, file = M.view.file, fn = M.view.fn,
            block = M.view.block, var = M.view.var, callers = M.view.callers,
            body = M.view.body,
            tbl = M.view.tbl, occs = M.view.occs, state = M.view.state, lit = M.view.lit,
            refused = M.view.refused, regfor = M.view.regfor,
            files_mode = M.files_mode,
            row = (M.win and vim.api.nvim_win_is_valid(M.win))
                and vim.api.nvim_win_get_cursor(M.win)[1] or 1 }
    end
    -- the node a view is anchored on (whose def the source pane should show)
    local function view_anchor()
        return (M.view.level == 'fn' and M.view.fn)
            or (M.view.level == 'body' and (M.view.body or ''):match('^(.-)\31'))
            or (M.view.level == 'block' and M.view.block)
            or (M.view.level == 'tbl' and M.view.tbl)
            or (M.view.level == 'var' and M.view.var)
    end
    -- keep the source pane in step with the browser: after a move lands on a
    -- node-anchored view, focus that node so the def pane shows it instead of
    -- staying stranded on wherever a descent last focused. The _own_pivot
    -- guard stops the focus subscriber from clearing the h/l trails or
    -- re-showing the view we just set to it.
    function sync_focus_to_view()
        local id = view_anchor()
        if id and store.node(id) and id ~= store.focused then
            M._own_pivot = true
            store.set_focus(id)
            M._own_pivot = false
        end
    end
    -- called after an ASCENT lands (h). The peek (deferred sync) only earns its
    -- keep when the ascent swaps the def pane to a DIFFERENT location — backing
    -- out of a descended callee, where keeping the callee on screen helps.
    -- SAME location -> sync at once: a block/body ascent never leaves its own
    -- function, and landing already on the focused node changes nothing. So
    -- deferral is the exception, not the rule.
    local function arm_or_sync()
        local same_location = M.view.level == 'body'
            or view_anchor() == store.focused
        if config.sync_on_ascend or same_location then
            M._resync = nil
            sync_focus_to_view()
        else
            local row = (M.win and vim.api.nvim_win_is_valid(M.win))
                and vim.api.nvim_win_get_cursor(M.win)[1] or 1
            M._resync = { row = row }
        end
    end
    -- apply a saved location to the view + cursor. PURE: focus is the caller's
    -- to set (a descent already focused its target; an ascent defers).
    local function restore_loc(loc)
        M.files_mode = loc.files_mode or M.files_mode
        M.view.file, M.view.fn, M.view.block, M.view.var, M.view.callers =
            loc.file, loc.fn, loc.block, loc.var, loc.callers
        M.view.tbl, M.view.occs, M.view.state = loc.tbl, loc.occs, loc.state
        M.view.lit, M.view.refused = loc.lit, loc.refused
        M.view.regfor, M.view.body = loc.regfor, loc.body
        if loc.level == 'refused' then M._refused_call = refused_call_of(loc.refused) end
        M.show(loc.level)
        if loc.row then pcall(vim.api.nvim_win_set_cursor, M.win, { loc.row, 2 }) end
    end
    local function push_trail() M.trail[#M.trail + 1] = view_loc() end
    -- browser-initiated pivots must not clear the trail (see on_focus)
    local function browser_pivot(id)
        M._resync = nil -- a conscious descent/pivot cancels a pending peek
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
        local n = store.node(id)
        if n and type(n.data) == 'table' then return 'lit' end
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
    -- an unresolved name may live in an UNPARSED bundle (*.min.js): find
    -- it by text search, register a synthetic landing node, descend into it
    local function frontier_jump(name)
        local hits = store.frontier_find(name)
        if #hits == 0 then return false end
        local h = hits[1]
        local id = ('%s::%s@%d'):format(h.file, name, h.line)
        store.add_node({ id = id, name = name, kind = 'function',
            unparsed = true, file = h.file, order = h.line,
            range = { start = { line = h.line, char = h.char },
                ['end'] = { line = h.line, char = h.char + #name } } })
        if #hits > 1 then
            vim.notify(('cartograph: %q also found in %d more unparsed files')
                :format(name, #hits - 1), vim.log.levels.INFO)
        end
        enter('fn', id, id)
        return true
    end
    -- a var row descends into its members/sites — except the FSM spec var,
    -- which descends into the state machine it declares (the states anchor)
    local function descend_var(n)
        local anchor = M.fsm_anchor()
        if anchor and anchor.id == n.id then return enter('states', nil, n.id) end
        enter(enter_var(n.id), n.id, n.id)
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
            -- jumplist restore (<C-o>/<C-t>) lands you deliberately: the def
            -- pane follows at once, no peek/defer
            sync_focus_to_view()
        end,
    }

    store.on_focus(function (id)
        local n = store.node(id)
        -- an external focus jump cancels a pending ascend-peek: the def pane is
        -- moving to `id` regardless (our own deferred resync sets _own_pivot)
        if not M._own_pivot then M._resync = nil end
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

    -- a background splice (clangd resolving the focused fn's callers) changed
    -- the graph under the current view — re-render it in place
    store.on_redraw(function ()
        if M.win and vim.api.nvim_win_is_valid(M.win)
            and vim.api.nvim_win_get_buf(M.win) == M.buf then
            pcall(M.render)
        end
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
        -- 0. a COMPOUND statement (if/for/while/nested form) opens its BLOCK.
        -- Its row is a flattened def/use/callee summary where names aren't at
        -- their source positions, so a word under the cursor would descend
        -- into whatever callee it happens to spell (bnw: the first `if` landed
        -- in launch_platform_info). Reveal the structure instead.
        local sl = M.line_stmt[r]
        if sl and #require('cartograph.providers.treesitter')
            .forms(store.abspath(node), sl - 1) > 0 then
            return enter('body',
                ('%s\31%d\31%d\31%d\31%d'):format(node.id, sl - 1, 0, -1, -1))
        end
        local col  = vim.api.nvim_win_get_cursor(win)[2]
        local text = vim.api.nvim_buf_get_lines(M.buf, r - 1, r, false)[1] or ''
        local word = word_at(text, col)
        -- 1. a callee named under the cursor: follow the call — into an
        -- UNPARSED bundle by text search when the graph has no target
        for _, c in ipairs(M.line_calls[r] or {}) do
            if c.callee == word and c.to and store.node(c.to) then
                return enter('fn', c.to, c.to)
            end
        end
        for _, c in ipairs(M.line_calls[r] or {}) do
            -- a refused callee is a FORK, not a dead end: descend into the
            -- refusal — the candidates it refused between, and the rule
            if c.callee == word and not c.to and c.refused
                and c.refused.cands and #c.refused.cands > 0 then
                M._refused_call = c
                return enter('refused',
                    ('%s\31%d\31%s'):format(c.fn or '', c.line, c.callee))
            end
            if c.callee == word and not c.to and frontier_jump(word) then
                return
            end
            -- a DYNAMIC callee ($fn) that is a parameter: open the dispatch
            -- trace — the callers' literals are the candidate targets, and
            -- the pin key turns the chosen one into a real edge
            if c.dynamic and not c.to and c.callee == '$' .. word then
                for pi, pname in ipairs(node.params or {}) do
                    if pname == word then
                        return require('cartograph.panes.trace')
                            .open(node.id, pi, word, c)
                    end
                end
                -- a local: same trace, rooted at its defining statements
                return require('cartograph.panes.trace')
                    .open_local(node.id, word, c.line, c)
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
            if f then
                -- streaming open: a file still in the queue extracts NOW —
                -- the user's attention outranks the queue order
                if store.data and store.data.partial then
                    require('cartograph.parallel').demand(f)
                end
                enter('file', f)
            end
        elseif M.view.level == 'file' then
            local n = store.node(M.line_node[r])
            if n and STAGEABLE[n.kind] then
                enter('fn', n.id, n.id)
            elseif n and n.kind == 'block' then
                enter('block', n.id, n.id) -- source pane shows the block's span
            end
        elseif M.view.level == 'ws' then
            local n = store.node(M.line_node[r])
            if n then
                if n.kind == 'block' then enter('block', n.id, n.id)
                elseif n.kind == 'var' then descend_var(n)
                elseif STAGEABLE[n.kind] then enter('fn', n.id, n.id) end
            else
                local f = M.line_file[r]
                if f then enter('file', f) end
            end
        elseif M.view.level == 'block' then
            local n = store.node(M.line_node[r])
            if n and n.kind == 'var' then
                descend_var(n)
            end
        elseif M.view.level == 'var' or M.view.level == 'callers' then
            local g = M.line_group[r]
            if g then -- descend into this function's occurrences
                local kind = M.view.level == 'var' and 'var' or 'ref'
                local entity = M.view.level == 'var' and M.view.var or M.view.callers
                return enter('occs', ('%s\31%s\31%s'):format(kind, entity, g.fn), g.fn)
            end
            local s = M.line_site[r]
            if s and store.node(s.fn) then
                store.set_context(nil)
                enter('fn', s.fn, s.fn)
            end
        elseif M.view.level == 'occs' then
            local s = M.line_site[r]
            if s and store.node(s.fn) then
                store.set_context(nil)
                enter('fn', s.fn, s.fn)
            end
        elseif M.view.level == 'refused' then
            -- a candidate row: jump into that def (a real fork taken)
            local cid = M.line_node[r]
            if cid and store.node(cid) then
                store.set_context(nil)
                enter('fn', cid, cid)
            end
        elseif M.view.level == 'lit' then
            if M.line_callers[r] then
                return enter('var', M.line_callers[r])
            end
            local e = M.line_lit[r]
            if e and e.kind == 'tbl' then
                enter('lit', e.key)
            elseif e and e.kind == 'ref' then
                -- follow the indirection to the referenced var (its own
                -- literal when it has one, its usage sites otherwise);
                -- prefer the data-carrying var when names collide
                local best
                for _, n in pairs(store.by_id) do
                    if n.kind == 'var' and n.name == e.ref then
                        if n.data then best = n break end
                        best = best or n
                    end
                end
                if best then return descend_var(best) end
            end
        elseif M.view.level == 'states' then
            local st = M.line_state[r]
            if st then enter('state', st) end
        elseif M.view.level == 'state' then
            local st = M.line_state[r]
            if st then return enter('state', st) end
            local n = store.node(M.line_node[r])
            if n and STAGEABLE[n.kind] then
                enter('fn', n.id, n.id)
            end
        elseif M.view.level == 'tbl' then
            if M.line_callers[r] then
                return enter('var', M.line_callers[r])
            end
            local n = store.node(M.line_node[r])
            if n and STAGEABLE[n.kind] then
                enter('fn', n.id, n.id)
            elseif n and n.kind == 'var' then
                descend_var(n)
            end
        elseif M.view.level == 'fn' then
            if M.line_callers[r] then
                return enter('callers', M.line_callers[r])
            end
            if M.line_regfor[r] then
                return enter('regfor', M.line_regfor[r], nil)
            end
            if M.line_body[r] then return enter('body', M.line_body[r]) end
            descend_fn_row(r)
        elseif M.view.level == 'body' then
            -- a ▸ form opens its own nested forms; a leaf call enters its callee
            if M.line_body[r] then return enter('body', M.line_body[r]) end
            for _, c in ipairs(M.line_calls[r] or {}) do
                if c.to and store.node(c.to) then
                    store.set_context(nil); return enter('fn', c.to, c.to)
                end
            end
            for _, c in ipairs(M.line_calls[r] or {}) do
                if not c.to and c.refused and c.refused.cands
                    and #c.refused.cands > 0 then
                    M._refused_call = c
                    return enter('refused',
                        ('%s\31%d\31%s'):format(c.fn or '', c.line, c.callee))
                end
            end
        elseif M.view.level == 'regfor' then
            -- a registrant row: open its module at the reference site
            local f = M.line_file[r]
            if f then store.set_context(nil); enter('file', f) end
        end
    end
    -- the working set: mark what you're working on; M is the way back
    -- from a dive; ]w / [w cycle members as conscious pivots
    local function ws_goto(n)
        if not n then return end
        if n.kind == 'block' then enter('block', n.id, n.id)
        elseif n.kind == 'var' then
            browser_pivot(n.id)
            M.show(enter_var(n.id), n.id)
        else enter('fn', n.id, n.id) end
    end
    local function ws_cycle(dir)
        local list = store.ws_list()
        if #list == 0 then
            return vim.notify('cartograph: working set is empty',
                vim.log.levels.INFO)
        end
        local cur, idx = store.workset.last or store.focused, 0
        for i, n in ipairs(list) do
            if n.id == cur then idx = i break end
        end
        ws_goto(list[((idx - 1 + dir) % #list) + 1])
    end
    vim.keymap.set('n', keys.mark, function ()
        local id = M.line_node[row()]
        if id and store.node(id) then
            store.ws_toggle(id)
            local loc = view_loc()
            M.render()
            restore_loc(loc)
        end
    end, { buffer = M.buf, desc = 'cartograph: toggle working set' })
    vim.keymap.set('n', keys.set_view, function ()
        enter('ws')
        local r = store.workset.last and M.node_line[store.workset.last]
        if r then pcall(vim.api.nvim_win_set_cursor, win, { r, 2 }) end
    end, { buffer = M.buf, desc = 'cartograph: working set view' })
    vim.keymap.set('n', keys.set_next, function () ws_cycle(1) end,
        { buffer = M.buf, desc = 'cartograph: next working-set member' })
    vim.keymap.set('n', keys.set_prev, function () ws_cycle(-1) end,
        { buffer = M.buf, desc = 'cartograph: previous working-set member' })

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
            restore_loc(loc)
            return arm_or_sync() -- defer the def-pane resync to the next move
        end
        local function block_of(v)
            for _, n in ipairs(store.by_file[v.file] or {}) do
                if n.kind == 'block' and n.range.start.line <= v.range.start.line
                    and n.range['end'].line >= v.range['end'].line then
                    return n
                end
            end
        end
        local function surface_to_var(v)
            local blk = v and block_of(v)
            if blk then
                M.show('block', blk.id)
                local r = M.node_line[v.id]
                if r then pcall(vim.api.nvim_win_set_cursor, win, { r, 2 }) end
            elseif v then
                M.show('file', v.file)
            else
                M.show('files')
            end
        end
        if M.view.level == 'lit' then
            -- pop one path segment; at the root, surface onto the var itself
            store.set_context(nil)
            local parts = vim.split(M.view.lit or '', '\31')
            if #parts > 1 then
                local child = table.concat(parts, '\31')
                table.remove(parts)
                M.show('lit', table.concat(parts, '\31'))
                for r = 1, vim.api.nvim_buf_line_count(M.buf) do
                    local e = M.line_lit[r]
                    if e and e.key == child then
                        pcall(vim.api.nvim_win_set_cursor, win, { r, 2 })
                        break
                    end
                end
            else
                surface_to_var(store.node(parts[1]))
            end
        elseif M.view.level == 'state' then
            store.set_context(nil)
            local st = M.view.state
            M.show('states')
            for r = 1, vim.api.nvim_buf_line_count(M.buf) do
                if M.line_state[r] == st then
                    pcall(vim.api.nvim_win_set_cursor, win, { r, 2 })
                    break
                end
            end
        elseif M.view.level == 'states' then
            -- the states altitude hangs below the spec var: surface into its
            -- block with the cursor on it (files is the no-model fallback)
            store.set_context(nil)
            surface_to_var(M.fsm_anchor())
        elseif M.view.level == 'ws' then
            store.set_context(nil)
            M.show('files')
        elseif M.view.level == 'occs' then
            store.set_context(nil)
            local kind, entity = (M.view.occs or ''):match('^(.-)\31(.-)\31')
            if kind == 'var' then M.show('var', entity)
            else M.show('callers', entity) end
        elseif M.view.level == 'var' then
            store.set_context(nil)
            local id = M.view.var
            M.show('block', M.view.block)
            local r = M.node_line[id]
            if r then pcall(vim.api.nvim_win_set_cursor, win, { r, 2 }) end
        elseif M.view.level == 'callers' then
            store.set_context(nil)
            M.show('fn', M.view.callers)
            pcall(vim.api.nvim_win_set_cursor, win, { 2, 0 })
        elseif M.view.level == 'refused' then
            -- the refusal hangs below its enclosing fn: surface there
            store.set_context(nil)
            local fnid = (M.view.refused or ''):match('^(.-)\31')
            if fnid and store.node(fnid) then M.show('fn', fnid)
            else M.show('files') end
        elseif M.view.level == 'regfor' then
            -- registrations hang below the registered fn: surface there
            store.set_context(nil)
            if store.node(M.view.regfor) then M.show('fn', M.view.regfor)
            else M.show('files') end
        elseif M.view.level == 'body' then
            -- a body descent hangs below its function: surface back to it
            store.set_context(nil); store.set_highlight(nil)
            local fnid = (M.view.body or ''):match('^(.-)\31')
            if fnid and store.node(fnid) then M.show('fn', fnid)
            else M.show('files') end
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
        -- a structural ascent that landed on a node-anchored view (callers ->
        -- fn, var -> block, …) re-syncs the def pane to that node too — at
        -- once or on the next move, per config.sync_on_ascend
        arm_or_sync()
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
        -- in a refusal, `p` PINS the candidate under the cursor: this
        -- ambiguous call, resolved to THIS def, durably (a target-
        -- qualified pin — the name alone is ambiguous by definition)
        if M.view.level == 'refused' and M._refused_call then
            local cid = M.line_node[row()]
            local target = cid and store.node(cid)
            local c = M._refused_call
            if not target then return end
            c.to, c.inferred, c.refused = cid, nil, nil
            if c.fn then
                store.add_edge({ from = c.fn, to = cid, kind = 'ref',
                    at = { c.at or { start = { line = c.line, char = 0 },
                        ['end'] = { line = c.line, char = 0 } } } })
            end
            local cfg = require('cartograph.config')
            cfg.pins = cfg.pins or {}
            local encl = c.fn and store.node(c.fn)
            cfg.pins[#cfg.pins + 1] = { file = c.file, fn = encl and encl.name,
                callee = c.callee, to = target.name, to_file = target.file }
            local anchor = encl and ("fn = '%s', callee = '%s'")
                :format(encl.name, c.callee) or ("callee = '%s'"):format(c.callee)
            vim.notify(("cartograph: pinned %s -> %s (%s) — durable with:\n"
                .. "  setup{ pins = { { file = '%s', %s, to = '%s', to_file = '%s' } } }")
                :format(c.callee, target.name, target.file, c.file, anchor,
                    target.name, target.file), vim.log.levels.INFO)
            if c.fn and store.node(c.fn) then enter('fn', c.fn, c.fn) end
            return
        end
        local file = M.line_file[row()]
        if file then store.set_dest(file) end
    end, { buffer = M.buf, desc = 'cartograph: paste — set move destination / pin refusal candidate' })
    vim.keymap.set('n', keys.unstage, function ()
        store.unstage_last()
    end, { buffer = M.buf, desc = 'cartograph: unstage the last cut function' })
    vim.keymap.set('n', keys.open_file, function ()
        local r = row()
        local site = M.line_site[r]
        local n = store.node(M.line_node[r]) or (site and store.node(site.fn))
            or (M.line_group[r] and store.node(M.line_group[r].fn))
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
