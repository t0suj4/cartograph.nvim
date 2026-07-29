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
local dfa    = require 'cartograph.df'
local atr = require 'cartograph.at'
local callrec = require 'cartograph.callrec'
local concerns = require 'cartograph.panes.concerns'

-- file level shows functions and BLOCKS (runs of top-level statements rolled
-- up under their first line); the individual vars live one level down
local SHOW_L2   = { ['function'] = true, method = true, region = true }
local STAGEABLE = { ['function'] = true, method = true }
local ICON      = { ['function'] = 'ƒ', method = ':', var = '·', region = '≡' }

-- lenses per altitude: <Tab>/<S-Tab> cycle these. `statements` is each
-- altitude's normal view; `detail` surfaces the code's fine-grained
-- descendable elements (arguments, conditions, var/field reads).
local LENS_SETS = {
    -- `lints` is the LENS PILOT ([[cartograph-interactive-reports]]): a per-fn
    -- REPORT (:CartographExpr) shown as rows in the browser instead of a
    -- dead-end scratch buffer. It cost nothing but a renderer because
    -- exprlint.lint() already returns RECORDS and report() is only a formatter
    -- over them — the conversion is free wherever that split already exists.
    fn     = { 'statements', 'detail', 'lints' },
    block  = { 'statements', 'detail' },
    region = { 'statements', 'detail' },
}

local ns       = vim.api.nvim_create_namespace('cartograph_symbols_dep')
local ns_class = vim.api.nvim_create_namespace('cartograph_symbols_class')
local ns_stage = vim.api.nvim_create_namespace('cartograph_symbols_stage')
local ns_heat  = vim.api.nvim_create_namespace('cartograph_symbols_heat')
local ns_ui    = vim.api.nvim_create_namespace('cartograph_symbols_ui')
local ns_cone  = vim.api.nvim_create_namespace('cartograph_symbols_cone')
local ns_terr  = vim.api.nvim_create_namespace('cartograph_symbols_territory')

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
    line_detail = {}, line_proto = {},
    -- what a row is ABOUT (a node id), which is NOT what `l` does here: a
    -- caller row is about the using function but descends into its
    -- occurrences. Keeping the two apart is the whole point — hover, descend,
    -- stage, heat and paint all read line_node, so anchoring these rows by
    -- setting IT would silently retarget `l`. See M.row_subject.
    line_about = {},
    -- a row's KIND, for overlays that must paint on what a row IS rather than
    -- on a field that merely mentions a file (see the working-set ● below)
    line_kind = {},
    trail = {},     -- descent trail: l pushes where you were, h pops (journey-back)
    fwd_trail = {}, -- ascent memory: h pushes where you left, l returns there exactly
}

-- Altitudes whose ROWS ARE NODES: hovering one previews that node's definition.
-- They share M.hover_node — the working set and the candidate list were left out
-- of the hover dispatch when they were added, so moving the cursor there changed
-- nothing in the source pane. That is worst exactly at the working set, whose
-- whole job is re-orientation after a code dive.
--
-- Public because MEMBERSHIP IS THE BUG SURFACE: hover_node's body was never
-- broken, the dispatch just never reached it, so a spec that calls hover_node
-- directly would pass against exactly that bug. The CursorMoved handler is a
-- closure inside attach() and unreachable from a test, so this table is the seam
-- a spec can hold to.
-- The non-concern half is listed here because those altitudes have no registry
-- entry (they are containment / data / the working set). The CONCERN half is
-- DERIVED, so adding an entry with hover='node' cannot be forgotten here — the
-- omission that left ws and refused previewing nothing.
M.NODE_HOVER = { file = true, region = true, tbl = true, state = true,
    ws = true }
for level in pairs(concerns.node_hover_levels()) do M.NODE_HOVER[level] = true end

-- the lenses offered at an altitude. The `file` altitude gains a `live` lens
-- ONLY under the self provider — the running instance can answer what a
-- module actually exports at runtime, which no on-disk graph can.
local function lens_set(level)
    if level == 'file' and store.data and store.data.provider == 'self' then
        return { 'members', 'live' }
    end
    return LENS_SETS[level]
end

-- the active lens at the current altitude (defaults to the first available)
local function cur_lens()
    local set = lens_set(M.view.level)
    return set and (M.view.lens or set[1])
end

-- a live key segment meaning "the upvalues of the function reached here"
local UPSENT = '\30ups'

-- the module node id for a file (the live lens's root); modules index by file
local function module_id(file)
    for _, n in ipairs(store.by_file[file] or {}) do
        if n.kind == 'module' then return n.id end
    end
    local n = store.node(file)
    return n and n.id
end

-- Relationship tints: dependencies (things the focus uses) in green, dependents
-- (things that use the focus) in amber; depth-1 saturated, depth-2 muted. Each
-- is a whole-line background blended over the real Normal bg so it tracks the
-- colorscheme rather than fighting it.
local function hl_setup()
    local hl = require 'cartograph.hl'
    local bg = hl.normal_bg()
    local GREEN, AMBER = 0x9ece6a, 0xff9e64
    vim.api.nvim_set_hl(0, 'CartographDep1',  { bg = hl.blend(GREEN, bg, 0.24) })
    vim.api.nvim_set_hl(0, 'CartographDep2',  { bg = hl.blend(GREEN, bg, 0.11) })
    vim.api.nvim_set_hl(0, 'CartographRdep1', { bg = hl.blend(AMBER, bg, 0.24) })
    vim.api.nvim_set_hl(0, 'CartographRdep2', { bg = hl.blend(AMBER, bg, 0.11) })
end

-- ── THE BUDGET LAW ([[cartograph-concern-layering]]) ─────────────────────────
-- The pane has `config.symbols_width` columns of text and no more: `wrap` is off,
-- so nvim clips a longer row with NO marker and the pane silently withholds what
-- it rendered. Measured before this existed: 28 of 35 file rows clipped at 30
-- columns, and the per-file symbol COUNT — the thing you scan the roster for —
-- was the first casualty, because it sits at the far right of the row.
--
-- So a row carries ONE IDENTITY that must fit, and anything that does not fit is
-- detail with a home elsewhere (hover, the source pane, a descend). For a file
-- row the identity is the shortest path SUFFIX that is UNIQUE among the displayed
-- files: the directory prefix is detail, but AMBIGUITY IS NOT ALLOWED — a bare
-- basename would render Von-Neumann's two railbot.lua files as the same row, and
-- 12 identical `init.lua` rows are worse than a clipped path. The full path stays
-- on the row via `line_file` (hover/gf/staging read it, never the label).

--- The shortest unique path suffix per file, rebuilt when the graph generation
--- moves (same cache discipline as var_idx).
local short_idx, short_gen
local function suffix(segs, n)
    return table.concat(segs, '/', math.max(1, #segs - n + 1))
end
function M.shortpath(file)
    if short_gen ~= store.generation or not short_idx then
        short_idx, short_gen = {}, store.generation
        local by_base = {}
        for _, f in ipairs(store.files or {}) do
            local base = f:match('([^/]+)$') or f
            by_base[base] = by_base[base] or {}
            table.insert(by_base[base], f)
        end
        for _, fs in pairs(by_base) do
            if #fs == 1 then
                short_idx[fs[1]] = fs[1]:match('([^/]+)$') or fs[1]
            else
                -- a shared basename grows parent segments until it separates
                for _, f in ipairs(fs) do
                    local segs = vim.split(f, '/')
                    local take, label = 2, nil
                    repeat
                        label = suffix(segs, take)
                        local clash = false
                        for _, g in ipairs(fs) do
                            if g ~= f and suffix(vim.split(g, '/'), take) == label then
                                clash = true
                                break
                            end
                        end
                        take = take + 1
                    until not clash or take > #segs
                    short_idx[f] = label
                end
            end
        end
    end
    return short_idx[file] or file
end

--- Fit an identity into what the budget leaves after `indent` and `tail`. Elides
--- the MIDDLE (both ends of a name carry signal — `crash-site-…-machine.lua`)
--- and MARKS it with …, because eliding identity is a real loss, unlike moving
--- the directory prefix to hover. Never squeezes below MIN_IDENTITY: a long prose
--- annotation must not mangle the name, so such a row overflows instead and
--- tests/width_spec.lua counts it against a declared ratchet.
local MIN_IDENTITY = 14
function M.fit_identity(label, indent, tail)
    local room = (require('cartograph.config').symbols_width or 30)
        - vim.fn.strdisplaywidth(indent or '') - vim.fn.strdisplaywidth(tail or '')
    room = math.max(room, MIN_IDENTITY)
    if vim.fn.strdisplaywidth(label) <= room then return label end
    local keep = room - 1                        -- 1 cell for the … marker
    local head = math.ceil(keep / 2)
    local back = keep - head
    return vim.fn.strcharpart(label, 0, head) .. '…'
        .. (back > 0 and vim.fn.strcharpart(label,
            vim.fn.strchars(label) - back, back) or '')
end

--- Fit free TEXT — a statement, a call, an expression — into the budget after
--- `indent`. Unlike an identity, a statement reads left to right and its FRONT
--- carries the signal (`local vonnCharacter = …` still says which local), so this
--- elides the TAIL, where fit_identity elides the middle. Both MARK: the … is the
--- whole difference between a fitted row and a silently clipped one. Measured, and
--- the reason this exists: the detail lens emitted rows up to 82 columns into a
--- 30-column pane — 7 of 15 rows on one function — and the overflow was invisible
--- because the window simply stops drawing. The dropped text is never lost: every
--- such row carries a line_stmt anchor, so the source pane holds it in full.
function M.fit_text(text, indent)
    local room = (require('cartograph.config').symbols_width or 30)
        - vim.fn.strdisplaywidth(indent or '')
    room = math.max(room, MIN_IDENTITY)
    if vim.fn.strdisplaywidth(text) <= room then return text end
    return vim.fn.strcharpart(text, 0, room - 1) .. '…'
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

-- var nodes by name, preferring the data-carrying one when names collide —
-- rebuilt when the graph's generation moves (ingest/splice/hotswap). The
-- lit-view ref follow used to scan ALL of by_id per keypress.
local var_idx, var_gen
local function var_by_name(name)
    if var_gen ~= store.generation then
        var_idx, var_gen = {}, store.generation
        for _, n in pairs(store.by_id or {}) do
            if n.kind == 'var' then
                local cur = var_idx[n.name]
                if not cur or (n.data and not cur.data) then var_idx[n.name] = n end
            end
        end
    end
    return var_idx[name]
end

local function file_row(ctx, file, depth, dim)
    local indent = string.rep('  ', depth or 0)
    local mod = store.by_id and store.by_id[file]
    -- identity fitted to what the budget leaves after this row's annotation
    local function ident(tail) return M.fit_identity(M.shortpath(file), indent, tail) end
    if mod and mod.lazy then
        local label = ident('  (lazy — l loads it)')
        ctx.lines[#ctx.lines + 1] = ('%s%s  (lazy — l loads it)'):format(indent, label)
        ctx.marks[#ctx.lines] = { { #indent, #indent + #label, 'CartographFrontier' },
            { #indent + #label, -1, 'CartographDim' } }
        ctx.line_file[#ctx.lines] = file
        ctx.line_kind[#ctx.lines] = 'file'
        return
    end
    if mod and mod.unparsed then
        ctx.lines[#ctx.lines + 1] = ('%s%s  (unparsed)'):format(indent,
            ident('  (unparsed)'))
        ctx.marks[#ctx.lines] = { { 0, -1, 'CartographDim' } }
        ctx.line_file[#ctx.lines] = file
        ctx.line_kind[#ctx.lines] = 'file'
        return
    end
    -- self graph: ⚡ marks a file that actually RAN this session (a required
    -- module or sourced script); the unmarked rest is present-but-never-loaded
    local ran = store.data and store.data.provider == 'self'
        and require('cartograph.self_oracle').loaded_files(store.data)[file]
    local ndefs = #shown_defs(file)
    local tail = ('  (%d)%s%s'):format(ndefs, dim and ' …' or '', ran and '  ⚡' or '')
    local label = ident(tail)
    ctx.lines[#ctx.lines + 1] = indent .. label .. tail
    ctx.marks[#ctx.lines] = dim and { { 0, -1, 'CartographDim' } }
        or { { #indent, #indent + #label, 'CartographSection' }, { #indent + #label, -1, 'CartographDim' } }
    if ran then
        local b = #indent + #label + #(('  (%d)%s'):format(ndefs, dim and ' …' or ''))
        table.insert(ctx.marks[#ctx.lines], { b, -1, 'DiagnosticOk' })
    end
    ctx.line_file[#ctx.lines] = file
    ctx.line_kind[#ctx.lines] = 'file'
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
            ctx.lines[#ctx.lines + 1] = M.fit_identity(M.shortpath(n.file), '', '')
            ctx.marks[#ctx.lines] = { { 0, -1, 'CartographDim' } }
            ctx.line_file[#ctx.lines] = n.file
            ctx.line_kind[#ctx.lines] = 'file'
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
        local extra = ''
        if store.data.provider == 'self' then
            local ran = require('cartograph.self_oracle').loaded_files(store.data)
            local n = 0; for _ in pairs(ran) do n = n + 1 end
            extra = (' — %d/%d files ran this session (⚡)'):format(n, #store.files)
        end
        ctx.lines[1] = ('%s — fetched %s%s'):format(
            store.data.provider or 'sample',
            os.date('%H:%M:%S', store.data.fetched_at), extra)
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
        for _, k in ipairs(store.topo():imports_out(file)) do kids[#kids + 1] = k end
        table.sort(kids)
        for _, k in ipairs(kids) do add(k, depth + 1) end
    end
    -- entry points first among the roots, then the accidental ones
    local roots = {}
    for _, f in ipairs(store.files) do
        if #store.topo():imports_in(f) == 0 then roots[#roots + 1] = f end
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
    -- THE DIRECTORY IS DISCLOSED HERE. Roster rows carry the shortest UNIQUE
    -- suffix because the prefix is detail (the budget law) — and this altitude is
    -- the place you descend INTO for that detail, so the dropped prefix appears as
    -- a dim breadcrumb, shown only when something was actually dropped. A dropped
    -- prefix that is never shown anywhere would be the absence-as-silence class;
    -- one keypress away is a HOME.
    local short = M.shortpath(file)
    local dropped = #short < #file and file:sub(1, #file - #short - 1) or nil
    if dropped then
        ctx.lines[#ctx.lines + 1] = M.fit_identity(dropped, '', '/') .. '/'
        ctx.marks[#ctx.lines] = { { 0, -1, 'CartographDim' } }
        ctx.line_sep[#ctx.lines] = true -- chrome: hover keeps the preview
    end
    local tail = ('  (%d)'):format(#shown_defs(file))
    local label = M.fit_identity(short, '', tail)
    local hrow = #ctx.lines + 1
    ctx.lines[hrow] = label .. tail
    ctx.marks[hrow] = { { 0, #label, 'CartographSection' }, { #label, -1, 'CartographDim' } }
    ctx.line_file[hrow] = file
    ctx.line_kind[hrow] = 'file'
    ctx.file_header[file] = hrow
    local sign = SIGN[store.classify(file)]
    if sign then ctx.signs[#ctx.signs + 1] = { row = hrow - 1, sign = sign } end
    for _, n in ipairs(shown_defs(file)) do
        local icon = ICON[n.kind] or '?'
        ctx.lines[#ctx.lines + 1] = ('  %s %s'):format(icon, n.name or '?')
        ctx.marks[#ctx.lines] = { { 2, 2 + #icon, 'CartographDim' } }
        ctx.vnums[#ctx.lines] = tostring(atr.sl(n.range) + 1)
        ctx.line_node[#ctx.lines] = n.id
        ctx.node_line[n.id]       = #ctx.lines
        ctx.line_file[#ctx.lines] = file
    end
end

-- Shared "usage sites" renderer: one row per occurrence, hover shows the site
-- in the bottom source view, descend enters the using function. Serves both
-- the var level (reads of a module var) and the callers level (calls of a fn).
-- `unavailable` (a reason string) means the sites were never COMPUTED, not that
-- there are none: the header must not print a count and the empty row states the
-- reason. Without it a fn with 4 callers read as "(no callers found — entry
-- point, or dynamically dispatched)" on the thin index. See cartograph.panes.
-- concerns, `empty`.
local function render_sites(ctx, node, icon, label, sites, empty_note, unavailable)
    -- defensive: one row per distinct (function, position)
    local seen, uniq = {}, {}
    for _, s in ipairs(sites) do
        local k = ('%s\31%d\31%d'):format(s.fn, s.line, s.range and atr.sc(s.range) or 0)
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
    -- `unavailable` WINS over a count even if rows somehow exist: a partial set
    -- shown as a total is the completeness lie the refusal exists to prevent,
    -- whereas "unavailable" beside visible rows is merely odd. Not reachable
    -- today (no edges means no sites), so this is the tie-break rule on record
    -- rather than a live case.
    local counts = unavailable and 'unavailable'
        or ((#sites - nint > 0 and nint > 0)
            and ('%d + %d self'):format(#sites - nint, nint))
        or (nint > 0 and ('%d self'):format(nint))
        or tostring(#sites)
    local name = node.name or '?'
    ctx.lines[1] = ('%s %s — %s (%s)'):format(icon, name, label, counts)
    ctx.marks[1] = { { 0, #icon, 'CartographDim' }, { #icon + 1, #icon + 1 + #name, 'CartographTitle' },
                     { #icon + 1 + #name, -1, 'CartographDim' } }
    -- the header names the entity these sites refer TO
    ctx.line_about[1] = node.id

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
            -- the row is ABOUT the using function (descend still opens the
            -- site, not the fn — that separation is line_about's whole reason)
            ctx.line_about[#ctx.lines] = g.fn
        else
            -- several sites: the row DESCENDS into the occurrences (no folds —
            -- the browser has altitude, l/h are the only vocabulary)
            local text = ('  %s (%d)%s%s'):format(
                disp, #g.sites, g.rec and ' ⟳' or '', g.inferred and ' ~' or '')
            ctx.lines[#ctx.lines + 1] = text
            ctx.marks[#ctx.lines] = { { 2 + #disp, -1, 'CartographDim' } }
            ctx.line_group[#ctx.lines] = g
            ctx.line_about[#ctx.lines] = g.fn
        end
    end
    if #sites == 0 then
        -- an UNAVAILABLE concern is a frontier, not a quiet nothing: it gets the
        -- frontier highlight so it never reads like a computed absence
        ctx.lines[2] = '  ' .. (unavailable and ('⚠ ' .. unavailable) or empty_note)
        ctx.marks[2] = { { 0, -1, unavailable and 'CartographFrontier' or 'CartographDim' } }
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
    local s, e = atr.sl(node.range), atr.el(node.range)
    local out = {}
    for _, n in ipairs(store.by_file[node.file] or {}) do
        if n.id ~= id and n.kind ~= 'region' and n.kind ~= 'module' then
            local named = n.name and (n.name:sub(1, #p1) == p1 or n.name:sub(1, #p2) == p2)
            local inside = n.kind ~= 'var'
                and atr.sl(n.range) >= s and atr.el(n.range) <= e
            if named or inside then out[#out + 1] = n end
        end
    end
    table.sort(out, function (a, b) return atr.sl(a.range) < atr.sl(b.range) end)
    return out
end

-- A var's usage sites: every function that reads it.
local function render_var(ctx, id)
    local node = store.node(id)
    if not node then ctx.lines[1] = '(gone)'; return end
    local sites = {}
    local p1, p2 = (node.name or '') .. '.', (node.name or '') .. ':'
    for _, u in ipairs(store.topo():var_used_by_detail(id)) do
        local fn = store.node(u.from)
        local member = fn and fn.name
            and (fn.name:sub(1, #p1) == p1 or fn.name:sub(1, #p2) == p2) or nil
        for _, r in ipairs(u.at) do
            sites[#sites + 1] = { fn = u.from, name = fn and fn.name or u.from,
                short = member and fn.name:sub(#(node.name or '') + 1) or nil,
                file = fn and fn.file, line = atr.sl(r), range = r,
                internal = member }
        end
    end
    -- the state atlas label rides the title: what KIND of state is this
    local atlas = require 'cartograph.atlas'
    local a = atlas.classify(store, id)
    -- `var` is not a concern entry (its subject and inverse are structural), but
    -- its rows come from the same use edges the thin index lacks, so it shares
    -- the fabrication fix rather than being the one altitude left lying
    render_sites(ctx, node, '·', 'used by · ' .. a.label, sites,
        '(no reads found — writes only, or dynamic access)', concerns.needs_edges(store))
    -- the FIELD decomposition (on demand, ~ms with warm parses): a
    -- multi-writer var often blurs per-field ownership — show it
    local fa = atlas.fields(store, id)
    if fa and next(fa.fields) then
        local names = {}
        for f in pairs(fa.fields) do names[#names + 1] = f end
        table.sort(names)
        ctx.lines[#ctx.lines + 1] = ''
        ctx.lines[#ctx.lines + 1] = fa.whole.nw > 0
            and 'fields (~ hedged: a whole-var write exists):'
            or 'fields:'
        ctx.marks[#ctx.lines] = { { 0, -1, 'CartographSection' } }
        for i = 1, math.min(#names, 16) do
            local f = names[i]
            local rec = fa.fields[f]
            ctx.lines[#ctx.lines + 1] = ('  .%s — %s%s'):format(
                f, rec.label, rec.hedged and ' ~' or '')
            ctx.marks[#ctx.lines] = { { 0, -1, 'CartographDim' } }
        end
        if #names > 16 then
            ctx.lines[#ctx.lines + 1] = ('  … %d more'):format(#names - 16)
            ctx.marks[#ctx.lines] = { { 0, -1, 'CartographDim' } }
        end
    end
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
            file = node.file, line = atr.sl(r), range = r, rec = true, internal = true }
    end
    for _, from in ipairs(store.topo():callers(id)) do
        local fn = store.node(from)
        local inf = store.edge_inferred[from .. '\31' .. id]
        local rec = from == id or nil
        local internal = rec or (cls ~= nil and class_of(fn and fn.name) == cls) or nil
        local short = internal and cls and fn and fn.name
            and fn.name:sub(1, #cls) == cls and fn.name:sub(#cls + 1) or nil
        for _, r in ipairs(store.occurrences(from, id) or {}) do
            sites[#sites + 1] = { fn = from, name = fn and fn.name or from,
                short = short,
                file = fn and fn.file, line = atr.sl(r), range = r, inferred = inf,
                rec = rec, internal = internal }
        end
    end
    local note, why = concerns.empty_of('callers', store)
    render_sites(ctx, node, ICON[node.kind] or 'ƒ', 'callers', sites, note, why)
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
        local note, why = concerns.empty_of('refused', store)
        ctx.lines[3] = '  ' .. (why and ('⚠ ' .. why) or note)
        ctx.marks[3] = { { 0, -1, why and 'CartographFrontier' or 'CartographDim' } }
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
    local regs = store.topo():registrants_detail(id)
    local note, why = concerns.empty_of('regfor', store)
    local pre = ICON[node.kind] or 'ƒ'
    ctx.lines[1] = ('%s %s — registered by (%s)'):format(pre, node.name or '?',
        why and 'unavailable' or tostring(#regs))
    ctx.marks[1] = { { 0, #pre, 'CartographDim' },
        { #pre, #pre + 1 + #(node.name or '?'), 'CartographTitle' },
        { #pre + 1 + #(node.name or '?'), -1, 'CartographDim' } }
    for _, r in ipairs(regs) do
        local at = r.at and r.at[1]
        local line = at and atr.sl(at)
        local label = line and ('%s:%d'):format(r.from, line + 1) or r.from
        ctx.lines[#ctx.lines + 1] = '  ' .. label
        ctx.marks[#ctx.lines] = { { 0, -1, 'CartographTitle' } }
        ctx.line_file[#ctx.lines] = r.from
        -- the row is ABOUT the registering module — and a module node's id IS
        -- its file path, so this is a node like any other row's. Recording it
        -- gives mark/cone a 'row' answer instead of the altitude fallback, and
        -- lets the row hover. (Banked as "the anchor is a MODULE not a fn, needs
        -- a decision"; measured 80/80 resolvable, so there was no decision.)
        ctx.line_about[#ctx.lines] = r.from
        if line then
            ctx.line_site[#ctx.lines] = { fn = r.from, file = r.from,
                line = line, range = at }
        end
    end
    if #regs == 0 then
        ctx.lines[2] = '  ' .. (why and ('⚠ ' .. why) or note)
        ctx.marks[2] = { { 0, -1, why and 'CartographFrontier' or 'CartographDim' } }
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
    for _, u in ipairs(store.topo():var_used_by_detail(id)) do nsites = nsites + #u.at end
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
        ctx.vnums[#ctx.lines] = tostring(atr.sl(n.range) + 1)
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

-- the live-value tree for a node id, snapshotted from the running process
-- (a SAMPLE — cached for this view, rebuilt on demand, never persisted).
local function live_tree(id)
    M._live = M._live or {}
    if M._live[id] == nil then
        local n = store.node(id)
        local tree = n and require('cartograph.self_oracle').live_value(n, store.data)
        M._live[id] = tree or false
    end
    return M._live[id] or nil
end

-- walk key = id \31 seg \31 seg … into the live tree (mirrors lit_walk)
local function live_walk(key)
    local parts = vim.split(key or '', '\31')
    local id = table.remove(parts, 1)
    local node = store.node(id)
    local function step(v, seg)
        if type(v) ~= 'table' then return nil end
        return v[seg] ~= nil and v[seg] or v[tonumber(seg)]
    end
    -- an UPSENT segment switches from walking the value tree to walking a
    -- function's upvalue tree, built on demand from the fn reached so far
    local upi
    for i, p in ipairs(parts) do if p == UPSENT then upi = i; break end end
    local val = live_tree(id)
    if not upi then
        for _, seg in ipairs(parts) do
            val = step(val, seg); if val == nil then break end
        end
        return node, val, parts, nil
    end
    for i = 1, upi - 1 do val = step(val, parts[i]); if val == nil then break end end
    local fnentry = (type(val) == 'table' and val.fn) and val or nil
    if not fnentry then return node, nil, parts, nil end
    local upt = require('cartograph.self_oracle').upvalues(fnentry.fn, store.data)
    for i = upi + 1, #parts do upt = step(upt, parts[i]); if upt == nil then break end end
    -- return the fn entry only at its upvalue ROOT, so render can offer its def
    return node, upt, parts, (upi == #parts) and fnentry or nil
end

-- Emit the rows for a data table `val` (litval or live-snapshot shape); shared
-- by the lit (static literal) and live (runtime) altitudes. `key` is the path
-- prefix for descendable sub-tables; `live` marks function refs navigable to
-- their resolved def node (v.id).
local function render_data(ctx, val, key, live)
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
            local lbl = ('%s → %s'):format(
                type(k) == 'number' and ('[%d]'):format(k) or k, v.ref)
            local entry = { kind = 'ref', ref = v.ref, id = v.id }
            -- a live closure with captured state: descending shows its upvalues
            if live and v.up then
                entry.upkey = key .. '\31'
                    .. (type(k) == 'number' and tostring(k) or k) .. '\31' .. UPSENT
                lbl = lbl .. ('  ⇡%d'):format(v.up)
            end
            row = { label = lbl, entry = entry,
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
        -- a live function ref resolves to its def node: wire hover + focus
        if live and row.entry.id then ctx.line_node[#ctx.lines] = row.entry.id end
    end
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
        for _, u in ipairs(store.topo():var_used_by_detail(node.id)) do nsites = nsites + #u.at end
        ctx.lines[2] = ('↖ used by (%d)'):format(nsites)
        ctx.marks[2] = { { 0, -1, 'CartographSection' } }
        ctx.line_callers[2] = node.id
    end
    render_data(ctx, val, key, false)
end

-- The self oracle's runtime value of a node, rendered like a literal table but
-- sourced from the live process — a module's concrete exports, a dispatch
-- table's actual contents, every function resolved to the def it dispatches to.
local function render_live(ctx, key)
    local node, val, path, fnentry = live_walk(key)
    if not node then ctx.lines[1] = '(gone)'; return end
    local upmode = (key or ''):find(UPSENT, 1, true) ~= nil
    -- drop the UPSENT sentinel from the displayed crumb
    local disp = {}
    for _, p in ipairs(path) do if p ~= UPSENT then disp[#disp + 1] = p end end
    local crumb = (node.name or '?')
        .. (#disp > 0 and ('.' .. table.concat(disp, '.')) or '')
    if val == nil then
        ctx.lines[1] = ('⚡ %s'):format(crumb)
        ctx.lines[2] = upmode and '   (this closure captured nothing / is gone)'
            or '   no runtime value — not loaded this session,'
        ctx.lines[3] = upmode and '' or
            '   or a value the process does not expose (a local)'
        for i = 1, 3 do ctx.marks[i] = { { 0, -1, 'CartographDim' } } end
        return
    end
    local tag = upmode and '↑ upvalues' or 'live @ now'
    ctx.lines[1] = ('⚡ %s   %s'):format(crumb, tag)
    ctx.marks[1] = { { 0, 4 + #crumb, 'CartographTitle' },
        { 4 + #crumb, -1, 'CartographDim' } }
    -- at a closure's upvalue root, offer its def (focus the concrete fn)
    if fnentry and fnentry.id and store.node(fnentry.id) then
        ctx.lines[#ctx.lines + 1] = ('→ %s'):format(fnentry.ref or 'definition')
        ctx.marks[#ctx.lines] = { { 0, -1, 'CartographSection' } }
        ctx.line_node[#ctx.lines] = fnentry.id
    end
    if type(val) ~= 'table' then
        ctx.lines[#ctx.lines + 1] = '  · '
            .. (type(val) == 'string' and ('%q'):format(val) or tostring(val))
        ctx.marks[#ctx.lines] = { { 4, -1, 'CartographLit' } }
        return
    end
    render_data(ctx, val, key, true)
end

-- One function's occurrences of the entity (the sites-view drill-down):
-- rows are real source lines. key = kind \31 entity id \31 using-fn id.
local function render_occs(ctx, key)
    local kind, entity, fnid = key:match('^(.-)\31(.-)\31(.*)$')
    local en, fn = store.node(entity), store.node(fnid)
    if not (en and fn) then ctx.lines[1] = '(gone)'; return end
    local ranges = {}
    if kind == 'var' then
        for _, u in ipairs(store.topo():var_used_by_detail(entity)) do
            if u.from == fnid then
                for _, r in ipairs(u.at) do ranges[#ranges + 1] = r end
            end
        end
    else
        for _, r in ipairs(store.occurrences(fnid, entity) or {}) do
            ranges[#ranges + 1] = r
        end
    end
    table.sort(ranges, function (a, b) return atr.sl(a) < atr.sl(b) end)
    local note, why = concerns.empty_of('occs', store)
    local fname = fn.name or '?'
    ctx.lines[1] = ('%s — sites of %s (%s)'):format(fname, en.name or '?',
        why and 'unavailable' or tostring(#ranges))
    ctx.marks[1] = { { 0, #fname, 'CartographTitle' }, { #fname, -1, 'CartographDim' } }
    -- the header names the USING function, whose body these occurrences are in
    ctx.line_about[1] = fnid
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
        local rsl, rsc = atr.sl(r), atr.sc(r)
        local line = rawline(fn.file, rsl)
        local t
        if atr.oneline(r) then
            t = line:sub(rsc + 1, atr.ec(r))
        else
            t = line:sub(rsc + 1)
        end
        if t == '' then t = line:gsub('^%s+', '') end
        -- follow the whole access CHAIN through the reference: `local x =
        -- self.bnw.home.surface` shows (and highlights) as `.bnw.home.surface`;
        -- a genuinely standalone ref (argument position) keeps the bare name
        if atr.oneline(r) then
            local bs, be = line:find('^[%w_]+', rsc + 1)
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
                    r = { start = { line = rsl, char = rsc },
                        ['end'] = { line = rsl, char = i - 1 } }
                end
            end
        end
        ctx.lines[#ctx.lines + 1] = '  ' .. t
        ctx.vnums[#ctx.lines] = tostring(rsl + 1)
        ctx.line_site[#ctx.lines] = { fn = fnid, name = fname, file = fn.file,
            line = rsl, range = r }
        -- every occurrence row is about the function whose body holds it
        ctx.line_about[#ctx.lines] = fnid
    end
    if #ranges == 0 then
        -- this altitude had NO empty note at all: zero ranges rendered a header
        -- counting (0) and not one row saying what that meant
        ctx.lines[2] = '  ' .. (why and ('⚠ ' .. why) or note)
        ctx.marks[2] = { { 0, -1, why and 'CartographFrontier' or 'CartographDim' } }
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
    for l = atr.sl(v.range), math.min(atr.el(v.range), #lines - 1) do
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
            if n then ctx.vnums[#ctx.lines] = tostring(atr.sl(n.range) + 1) end
        end
    end
end

-- Inside a block: its declarations (the var nodes within the block's range).
local function render_region(ctx, id)
    local node = store.node(id)
    if not node then ctx.lines[1] = '(gone)'; return end
    ctx.lines[1] = ('≡ %s'):format(node.name or '?')
    ctx.marks[1] = { { 0, #'≡', 'CartographDim' }, { #'≡', -1, 'CartographTitle' } }
    local s, e = atr.sl(node.range), atr.el(node.range)
    for _, n in ipairs(store.by_file[node.file] or {}) do
        if n.kind == 'var' and atr.sl(n.range) >= s and atr.sl(n.range) <= e then
            ctx.lines[#ctx.lines + 1] = ('  · %s'):format(n.name or '?')
            ctx.marks[#ctx.lines] = { { 2, 3, 'CartographDim' } }
            ctx.vnums[#ctx.lines] = tostring(atr.sl(n.range) + 1)
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
    -- the header names this function: the row IS about it, so mark/cone act on
    -- it here rather than falling back to the altitude
    ctx.line_about[1] = id
    if node.access then
        ctx.marks[1][#ctx.marks[1] + 1] =
            { #pre + 1 + #(node.name or '?'), -1, 'CartographDim' }
    end
    -- who calls this function — descend on the row to see the call sites
    local ncall = 0
    for _, from in ipairs(store.topo():callers(id)) do
        ncall = ncall + #(store.occurrences(from, id) or {})
    end
    ctx.lines[2] = ('↖ callers (%d)'):format(ncall)
    ctx.marks[2] = { { 0, -1, 'CartographSection' } }
    ctx.line_callers[2] = id
    -- the other half of the alibi: registrations (kept alive by a
    -- dispatch table / load-time data, not a call). Descend to see them.
    local regs = store.topo():registrants_detail(id)
    if #regs > 0 then
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
    local df = dfa.get(node)
    if not df then
        if node.unparsed then
            ctx.lines[3] = '  (unparsed source — landed by text search)'
            ctx.marks[3] = { { 0, -1, 'CartographDim' } }
        else
            -- no statement-level dataflow (e.g. scheme): descend into the
            -- body's forms (the block view), derived on demand from the source
            ctx.lines[3] = '▸ forms'
            ctx.marks[3] = { { 0, -1, 'CartographSection' } }
            local r = node.range
            ctx.line_block[3] = ('%s\31%d\31%d\31%d\31%d'):format(id,
                atr.sl(r), atr.sc(r), atr.el(r), atr.ec(r))
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
        local li, best, stmts = line0 + 1, nil, dfa.stmts(node)
        for i = 1, #stmts do
            if stmts[i].l <= li then best = i else break end
        end
        return best
    end
    local calls_at = {}
    for _, c in ipairs(store.topo():sites(id)) do
        local best = stmt_of(callrec.line(c))
        if best then
            calls_at[best] = calls_at[best] or {}
            table.insert(calls_at[best], c)
        end
    end
    local vars_at = {}
    for _, u in ipairs(store.topo():var_uses_detail(id)) do
        local vn = store.node(u.to)
        if vn then
            for _, r in ipairs(u.at) do
                local best = stmt_of(atr.sl(r))
                if best then
                    vars_at[best] = vars_at[best] or {}
                    table.insert(vars_at[best], { name = vn.name, id = u.to })
                end
            end
        end
    end
    for i, s in ipairs(dfa.stmts(node)) do
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
local function render_block(ctx, key)
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
    local calls = store.topo():sites(fnid)
    -- the earliest call whose head token lies within a form = the form's call
    local function primary(f)
        local best
        for _, c in ipairs(calls) do
            local a = c.at -- the range itself, not its interior: fold-ready
            if a and (atr.sl(a) > f.sr or (atr.sl(a) == f.sr and atr.sc(a) >= f.sc))
                and (atr.sl(a) < f.er or (atr.sl(a) == f.er and atr.sc(a) < f.ec)) then
                if not best or atr.sl(a) < atr.sl(best.at)
                    or (atr.sl(a) == atr.sl(best.at) and atr.sc(a) < atr.sc(best.at)) then
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
            ctx.line_block[#ctx.lines] =
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

-- The DETAIL lens (the fn/block/region altitudes' second lens): the code's
-- fine-grained descendable elements, indented under each statement — a call's
-- arguments and a conditional's condition (from treesitter.detail, `l` descends
-- into the element's forms), plus the module vars/fields the statement reads
-- (from the data flow; `l` opens the var's usage sites). Derived on demand.
local function detail_scope() -- -> node, sr, sc, er, ec, has_df, fnid
    local lvl = M.view.level
    if lvl == 'fn' then
        local n = store.node(M.view.fn); if not n then return end
        local r = n.range
        return n, atr.sl(r), atr.sc(r), atr.el(r), atr.ec(r),
            dfa.present(n) or nil, M.view.fn
    elseif lvl == 'block' then
        local fnid, sr, sc, er, ec =
            (M.view.block or ''):match('^(.-)\31(%-?%d+)\31(%-?%d+)\31(%-?%d+)\31(%-?%d+)$')
        local n = fnid and store.node(fnid); if not n then return end
        er, ec = tonumber(er), tonumber(ec)
        return n, tonumber(sr), tonumber(sc), (er and er >= 0 and er or nil),
            (ec and ec >= 0 and ec or nil), nil, fnid
    elseif lvl == 'region' then
        local n = store.node(M.view.region); if not n then return end
        local r = n.range
        return n, atr.sl(r), atr.sc(r), atr.el(r), atr.ec(r), nil, nil
    end
end
-- ── the LENS PILOT: a per-fn report as rows ──────────────────────────────────
-- Rows are FINDINGS, one per row, each anchored to its statement line so the
-- existing fn-level hover previews it with no new dispatch. The report's PROSE
-- (the rule glossary, the coverage footer) does not come along: under the budget
-- law it is not row material, and :CartographExpr still prints it in full. That
-- split — findings here, explanation there — is the lens/report division of
-- labour, not a loss.
local function render_lints(ctx, fn_id)
    local node = fn_id and store.node(fn_id)
    if not node then ctx.lines[1] = '(gone)'; return end
    local res = require('cartograph.exprlint').lint(store, fn_id)
    local head = ('⚑ %s'):format(node.name or '?')
    ctx.lines[1] = M.fit_identity(head, '', '')
    ctx.marks[1] = { { 0, -1, 'CartographTitle' } }
    ctx.line_node[1] = fn_id
    -- TYPED EMPTY, both halves: a language the harvest does not cover is
    -- UNAVAILABLE (a frontier), which is a different fact from a function the
    -- lints cleared. Rendering them the same is the defect this pane keeps paying
    -- for ([[cartograph-concern-layering]]).
    if res.unsupported then
        ctx.lines[2] = ('  ⚠ unread: no %s parser'):format(
            (node.file or ''):match('%.(%w+)$') or '?')
        ctx.marks[2] = { { 0, -1, 'CartographFrontier' } }
        ctx.line_sep[2] = true
        return
    end
    local c = res.census or { total = 0, unknown = 0 }
    if #res.findings == 0 then
        -- NEVER the word "clean". Measured: a python fn harvests 5 expression
        -- nodes and trips 0 rules because the rung-0 rules are Lua-authored, so
        -- "0 findings" can mean nothing-to-read, read-and-clean, or
        -- no-rule-applies. The row states WHAT WAS CHECKED and lets the reader
        -- draw the verdict — the alternative is a fabricated all-clear.
        if c.total == 0 then
            ctx.lines[2] = '  ⚠ no expressions read here'
            ctx.marks[2] = { { 0, -1, 'CartographFrontier' } }
        else
            ctx.lines[2] = ('  0 findings · %d/%d read')
                :format(c.total - c.unknown, c.total)
            ctx.marks[2] = { { 0, -1, 'CartographDim' } }
        end
        ctx.line_sep[2] = true
        return
    end
    for _, f in ipairs(res.findings) do
        -- identity = the RULE (what this row IS); the line rides the vnum lane
        -- and the message is the detail the source pane and the report carry
        local mark = f.hedged and '~' or ' '
        ctx.lines[#ctx.lines + 1] = ('%s %s'):format(mark,
            M.fit_identity(f.rule or '?', '  ', ''))
        ctx.marks[#ctx.lines] = f.hedged
            and { { 0, 1, 'CartographFrontier' } } or nil
        ctx.vnums[#ctx.lines] = tostring(f.line)
        ctx.line_stmt[#ctx.lines] = f.line -- the fn hover highlights this line
        ctx.line_kind[#ctx.lines] = 'lint'
    end
    if c.total > 0 and c.unknown > 0 then
        -- the findings are a LOWER BOUND when part of the tree is unread
        ctx.lines[#ctx.lines + 1] = ('  ~ %d/%d read'):format(c.total - c.unknown, c.total)
        ctx.marks[#ctx.lines] = { { 0, -1, 'CartographFrontier' } }
        ctx.line_sep[#ctx.lines] = true
    end
end

--- A prose NOTE as chrome: word-wrapped to the budget across as many dim rows as
--- it needs. Prose is not identity and cannot be elided, so the honest options are
--- "wrap it" or "move it elsewhere" — this is the cheap first answer to the
--- prose-overflow class tests/width_spec.lua currently ratchets.
local function note(ctx, text, hl)
    local budget = require('cartograph.config').symbols_width or 30
    local line = ''
    local function flush()
        if line == '' then return end
        ctx.lines[#ctx.lines + 1] = line
        ctx.marks[#ctx.lines] = { { 0, -1, hl or 'CartographDim' } }
        ctx.line_sep[#ctx.lines] = true -- chrome: hover keeps the preview
        line = ''
    end
    for word in tostring(text):gmatch('%S+') do
        local cand = line == '' and ('  ' .. word) or (line .. ' ' .. word)
        if vim.fn.strdisplaywidth(cand) > budget and line ~= '' then
            flush(); line = '  ' .. word
        else
            line = cand
        end
    end
    flush()
end

-- ── the COMPARTMENT PILOT: the prototype reading as two altitudes ────────────
-- `protos` is a ROOT (a concern index — the first door that is not the file tree,
-- [[cartograph-navigation-model]]); `proto` hangs below it, one prototype's
-- ORDERED overrides and hedges. Both read prototypes.all/at — the same records
-- :CartographPrototypes formats. A row's identity is the prototype's NAME (or the
-- override's PATH); its VALUE is deliberately absent, because the value lives in
-- the source one hover away and the report prints it in full. That is the budget
-- law choosing what a row is FOR.
local function render_protos(ctx)
    local pr = require 'cartograph.prototypes'
    local why = pr.unavailable(store)
    if why then
        ctx.lines[1] = 'prototypes  unavailable'
        ctx.marks[1] = { { 0, -1, 'CartographFrontier' } }
        ctx.line_sep[1] = true
        return note(ctx, '⚠ ' .. why, 'CartographFrontier')
    end
    local all = pr.all(store) or {}
    local total = 0
    for _, m in ipairs(all) do total = total + #m.protos end
    local tail = ('  (%d)'):format(total)
    ctx.lines[1] = M.fit_identity('prototypes', '', tail) .. tail
    ctx.marks[1] = { { 0, -1, 'CartographSection' } }
    ctx.line_sep[1] = true
    if total == 0 then
        return note(ctx, '(this project declares no prototypes — the data stage is'
            .. ' empty, not unreadable)')
    end
    for _, m in ipairs(all) do
        local ftail = ('  (%d)'):format(#m.protos)
        ctx.lines[#ctx.lines + 1] = M.fit_identity(M.shortpath(m.file), '', ftail) .. ftail
        ctx.marks[#ctx.lines] = { { 0, -1, 'CartographDim' } }
        ctx.line_file[#ctx.lines] = m.file
        ctx.line_kind[#ctx.lines] = 'file'
        for i, p in ipairs(m.protos) do
            local name = p.name or p.var
                or (p.patch and ('%s/%s'):format(p.patch.type, p.patch.name))
                or '(anonymous)'
            local mark = p.complete and '' or ' ~'
            ctx.lines[#ctx.lines + 1] = '  '
                .. M.fit_identity(name, '  ', mark) .. mark
            if not p.complete then
                ctx.marks[#ctx.lines] = { { -3, -1, 'CartographFrontier' } }
            end
            ctx.vnums[#ctx.lines] = tostring(p.line)
            ctx.line_proto[#ctx.lines] = pr.key(m.file, i)
            ctx.line_file[#ctx.lines] = m.file
            ctx.line_stmt[#ctx.lines] = p.line
            ctx.line_kind[#ctx.lines] = 'proto'
        end
    end
end

local function render_proto(ctx, key)
    local pr = require 'cartograph.prototypes'
    local rec, file = pr.at(store, key)
    if not rec then
        ctx.lines[1] = 'prototype  gone'
        ctx.marks[1] = { { 0, -1, 'CartographFrontier' } }
        ctx.line_sep[1] = true
        -- a DEAD ADDRESS says so: the alternative is an empty prototype, which
        -- reads as "this one overrides nothing" ([[cartograph-navigation-model]])
        return note(ctx, '⚠ the module changed — this prototype is no longer at'
            .. ' this position', 'CartographFrontier')
    end
    local name = rec.name or rec.var
        or (rec.patch and ('%s/%s'):format(rec.patch.type, rec.patch.name))
        or '(anonymous)'
    local btail = (' [%s]'):format(rec.basis or '?')
    ctx.lines[1] = M.fit_identity(name, '', btail) .. btail
    ctx.marks[1] = { { 0, -1, 'CartographTitle' } }
    ctx.line_file[1] = file
    ctx.line_stmt[1] = rec.line
    ctx.line_kind[1] = 'proto'
    if rec.base then
        local base = ('%s/%s'):format(rec.base.type, rec.base.name)
        ctx.lines[#ctx.lines + 1] = '  ← ' .. M.fit_identity(base, '  ← ', '')
        ctx.marks[#ctx.lines] = { { 0, -1, 'CartographDim' } }
        ctx.line_sep[#ctx.lines] = true
    elseif rec.from_path then
        ctx.lines[#ctx.lines + 1] = '  ← ' .. M.fit_identity(rec.from_path, '  ← ', ' ?')
            .. ' ?'
        ctx.marks[#ctx.lines] = { { 0, -1, 'CartographFrontier' } }
        ctx.line_sep[#ctx.lines] = true
    end
    -- overrides and frontiers INTERLEAVED BY LINE: the sequence is the fact (a
    -- later override wins), so a hedge must sit where it fired
    local fi = 1
    local function frontiers_upto(n)
        while fi <= #(rec.frontiers or {})
                and (n == nil or rec.frontiers[fi].line <= n) do
            local f = rec.frontiers[fi]
            ctx.lines[#ctx.lines + 1] = '  ~ '
                .. M.fit_identity(f.callee or f.kind or '?', '  ~ ', '')
            ctx.marks[#ctx.lines] = { { 0, -1, 'CartographFrontier' } }
            ctx.vnums[#ctx.lines] = tostring(f.line)
            ctx.line_file[#ctx.lines] = file
            ctx.line_stmt[#ctx.lines] = f.line
            ctx.line_kind[#ctx.lines] = 'frontier'
            fi = fi + 1
        end
    end
    for _, o in ipairs(rec.overrides or {}) do
        frontiers_upto(o.line)
        -- the marker carries what the VALUE could not: ∅ a delete (a fact), ? a
        -- value we could not read. The value itself is in the source, one hover
        -- away, and :CartographPrototypes prints it.
        local mark = (o.value == nil and ' ?')
            or (o.value == require('cartograph.expr').NIL and ' ∅') or ''
        ctx.lines[#ctx.lines + 1] = '  '
            .. M.fit_identity(o.path or '?', '  ', mark) .. mark
        ctx.vnums[#ctx.lines] = tostring(o.line)
        ctx.line_file[#ctx.lines] = file
        ctx.line_stmt[#ctx.lines] = o.line
        ctx.line_kind[#ctx.lines] = 'override'
    end
    frontiers_upto(nil)
    if #(rec.overrides or {}) == 0 and #(rec.frontiers or {}) == 0 then
        local text = concerns.empty_of('proto', store)
        note(ctx, text or '(no field overrides)')
    end
end

local function render_detail(ctx)
    local n, sr, sc, er, ec, df, fnid = detail_scope()
    if not n then ctx.lines[1] = '(gone)'; return end
    ctx.lines[1] = ('≡ %s'):format(n.name or '?')
    ctx.marks[1] = { { 0, #'≡', 'CartographDim' }, { #'≡', -1, 'CartographTitle' } }
    local ts = require 'cartograph.providers.treesitter'
    local stmts = ts.detail(store.abspath(n), sr, sc, er, ec)
    if #stmts == 0 then
        ctx.lines[2] = '  (no detail here)'; ctx.marks[2] = { { 0, -1, 'CartographDim' } }
        return
    end
    -- module vars a statement reads, by statement start line (descendable) —
    -- from the fn's use edges (fn altitude only). A name the function DEFINES
    -- (a param or a local) shadows any module var of that name: the read is
    -- the local, so a name-matched use edge to the module var is a false
    -- positive — skip it, or descending it would open a global's usages.
    local vars_by_line, locals = {}, {}
    if fnid then
        local fnode = store.node(fnid)
        for _, p in ipairs(fnode and fnode.params or {}) do locals[p] = true end
        if df then
            for _, s in ipairs(dfa.stmts(node)) do
                for _, d in ipairs(s.def or {}) do locals[d] = true end
            end
        end
        for _, u in ipairs(store.topo():var_uses_detail(fnid)) do
            local vn = store.node(u.to)
            if vn and not locals[vn.name] then
                for _, r in ipairs(u.at or {}) do
                    vars_by_line[atr.sl(r)] = vars_by_line[atr.sl(r)] or {}
                    vars_by_line[atr.sl(r)][u.to] = true
                end
            end
        end
    end
    for _, st in ipairs(stmts) do
        ctx.lines[#ctx.lines + 1] = '  ' .. M.fit_text(st.text, '  ')
        ctx.marks[#ctx.lines] = { { 0, -1, 'CartographDim' } }
        ctx.line_stmt[#ctx.lines] = st.sr + 1
        for _, it in ipairs(st.items) do
            local icon = it.kind == 'cond' and '? ' or '· '
            ctx.lines[#ctx.lines + 1] = '      ' .. icon
                .. M.fit_text(it.text, '      ' .. icon)
            ctx.line_stmt[#ctx.lines] = it.sr + 1
            ctx.line_detail[#ctx.lines] = { kind = it.kind,
                key = ('%s\31%d\31%d\31%d\31%d'):format(fnid or n.id, it.sr, it.sc, it.er, it.ec) }
        end
        -- module vars/fields this statement reads (fn altitude): descend -> uses
        local seen = {}
        for line, vs in pairs(vars_by_line) do
            if line >= st.sr and line <= st.er then
                for vid in pairs(vs) do
                    if not seen[vid] then
                        seen[vid] = true
                        local vn = store.node(vid)
                        if vn then
                            -- a var row is an IDENTITY, so it elides the middle
                            ctx.lines[#ctx.lines + 1] = '      → '
                                .. M.fit_identity(vn.name or vid, '      → ', '')
                            ctx.marks[#ctx.lines] = { { 0, 8, 'CartographDim' } }
                            ctx.line_stmt[#ctx.lines] = st.sr + 1 -- anchor to its statement
                            ctx.line_detail[#ctx.lines] = { kind = 'var', id = vid }
                        end
                    end
                end
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
        line_regfor = {}, line_block = {}, line_detail = {}, line_proto = {},
        line_about = {}, line_kind = {} }
    local v = M.view
    if LENS_SETS[v.level] and cur_lens() == 'detail' then
        render_detail(ctx)
    elseif v.level == 'fn' and cur_lens() == 'lints' then
        render_lints(ctx, v.fn)
    elseif v.level == 'files' then
        if M.files_mode == 'tree' then
            if store.toc then render_files_load(ctx) else render_files_tree(ctx) end
        else
            render_files(ctx)
        end
    elseif v.level == 'file' then
        if cur_lens() == 'live' then render_live(ctx, module_id(v.file))
        else render_file(ctx, v.file) end
    elseif v.level == 'live' then render_live(ctx, v.live)
    elseif v.level == 'region' then render_region(ctx, v.region)
    elseif v.level == 'var' then render_var(ctx, v.var)
    elseif v.level == 'tbl' then render_tbl(ctx, v.tbl)
    elseif v.level == 'callers' then render_callers(ctx, v.callers)
    elseif v.level == 'refused' then render_refused(ctx, M._refused_call)
    elseif v.level == 'regfor' then render_regfor(ctx, v.regfor)
    elseif v.level == 'occs' then render_occs(ctx, v.occs)
    elseif v.level == 'lit' then render_lit(ctx, v.lit)
    elseif v.level == 'states' then render_states(ctx)
    elseif v.level == 'state' then render_state(ctx, v.state)
    elseif v.level == 'block' then render_block(ctx, v.block)
    elseif v.level == 'ws' then render_ws(ctx)
    elseif v.level == 'protos' then render_protos(ctx)
    elseif v.level == 'proto' then render_proto(ctx, v.proto)
    else render_fn(ctx, v.fn) end

    M.line_node, M.node_line = ctx.line_node, ctx.node_line
    M.line_file, M.file_header, M.line_stmt = ctx.line_file, ctx.file_header, ctx.line_stmt
    M.line_stmtidx, M.line_calls, M.line_site = ctx.line_stmtidx, ctx.line_calls, ctx.line_site
    M.line_callers, M.line_vars = ctx.line_callers, ctx.line_vars
    M.line_group, M.line_sep, M.line_state = ctx.line_group, ctx.line_sep, ctx.line_state
    M.line_trans, M.line_lit = ctx.line_trans, ctx.line_lit
    M.line_regfor, M.line_block = ctx.line_regfor, ctx.line_block
    M.line_detail, M.line_proto = ctx.line_detail, ctx.line_proto
    M.line_about, M.line_kind = ctx.line_about, ctx.line_kind

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
    M.paint_cone() -- glow rows on the active reachability cone
    M.paint_territory() -- the territorial map, when toggled on
    M.emit_view() -- the visible list changed; surfaces track it (deduped)
end

M._territory_on = false

--- Toggle the territory overlay; returns the new on/off state.
function M.toggle_territory()
    M._territory_on = not M._territory_on
    M.paint_territory()
    return M._territory_on
end

--- Paint the territorial map: per-entry territories in the CONCERN hues, ●
--- commons / core in their own groups, ◆ on borders (the seams). eol dots,
--- like the cone — never line-bg. Node rows and, at files level, file rows.
function M.paint_territory()
    if not (M.buf and vim.api.nvim_buf_is_valid(M.buf)) then return end
    vim.api.nvim_buf_clear_namespace(M.buf, ns_terr, 0, -1)
    if not M._territory_on then return end
    local t = store.territory(); if not t then return end
    local hl = require 'cartograph.hl'
    local function dot(r, glyph, group)
        pcall(vim.api.nvim_buf_set_extmark, M.buf, ns_terr, r - 1, 0,
            { virt_text = { { glyph, group } }, virt_text_pos = 'eol' })
    end
    local function terr_hue(entry) return hl.concern((t.entry_index[entry] or 1) - 1) end
    for row, id in pairs(M.line_node or {}) do
        local info = t.node[id]
        if info then
            if info.border then dot(row, '◆', 'CartographBorder')
            elseif info.class == 'core' then dot(row, '●', 'CartographCore')
            elseif info.class == 'commons' then dot(row, '●', 'CartographCommons')
            else dot(row, '●', terr_hue(info.entry)) end
        end
    end
    local ft = store.territory_files()
    if ft then
        for row, file in pairs(M.line_file or {}) do
            local fi = ft[file]
            if fi then
                if fi.class == 'core' then dot(row, '●', 'CartographCore')
                elseif fi.class == 'commons' then dot(row, '●', 'CartographCommons')
                else dot(row, '●', terr_hue(fi.entry)) end
            end
        end
    end
end

--- Glow the rows on the active cone: ◆ on the anchor, ● on every reachable
--- node (and, at files level, on files that contain one). eol dots, NOT line
--- backgrounds — the cone must not fight the hover relationship tints.
function M.paint_cone()
    if not (M.buf and vim.api.nvim_buf_is_valid(M.buf)) then return end
    vim.api.nvim_buf_clear_namespace(M.buf, ns_cone, 0, -1)
    if not store.cone then return end
    local function dot(row, glyph, hl)
        pcall(vim.api.nvim_buf_set_extmark, M.buf, ns_cone, row - 1, 0,
            { virt_text = { { glyph, hl } }, virt_text_pos = 'eol' })
    end
    for row, id in pairs(M.line_node or {}) do
        if id == store.cone.id then
            dot(row, '◆', 'CartographConeAnchor')
        elseif store.in_cone(id) then
            dot(row, '●', 'CartographCone')
        end
    end
    local cf = store.cone_files()
    if cf then
        for row, file in pairs(M.line_file or {}) do
            if cf[file] then dot(row, '●', 'CartographCone') end
        end
    end
end

--- What the view SHOWS, for the projection surface ([[textplates]]): the node
--- names currently on screen in row order, plus which one the cursor is on.
--- The world renders exactly this list (so it tracks what the browser looks
--- at), with the selected row in a highlight material. Module/file names
--- project as their basename (STORE, not lua/cartograph/store.lua); `limit`
--- caps rows. Returns { labels = {...}, selected = index|nil }.
function M.projection(limit)
    local rows, labels, selected = {}, {}, nil
    for row in pairs(M.line_node or {}) do rows[#rows + 1] = row end
    table.sort(rows)
    local cursor = M.win and vim.api.nvim_win_is_valid(M.win)
        and vim.api.nvim_win_get_cursor(M.win)[1] or nil
    for _, row in ipairs(rows) do
        local n = store.node(M.line_node[row])
        if n and n.name then
            local label = n.name
            if n.kind == 'module' then label = label:match('[^/]+$') or label end
            labels[#labels + 1] = label
            if cursor and row == cursor then selected = #labels end
            if limit and #labels >= limit then break end
        end
    end
    return { labels = labels, selected = selected }
end

--- The row under the cursor in the browser window, or nil if it isn't open.
local function cursor_row()
    if not (M.win and vim.api.nvim_win_is_valid(M.win)) then return nil end
    return vim.api.nvim_win_get_cursor(M.win)[1]
end

-- ── THE SUBJECT OF AN ALTITUDE ──────────────────────────────────────────────
-- What is this view ABOUT? The recorded law ([[refactor-cockpit-design]], the
-- FSM anchor): "every altitude must hang somewhere in the structural tree or
-- h/l breaks symmetry — a synthetic altitude needs a source-code anchor node,
-- or it's a one-way door." The RELATION altitudes (callers / occs / regfor)
-- never got that treatment: their ROWS are other nodes referring to a subject
-- that is itself never a row, so a verb keyed on the cursor row found nothing
-- to act on and refused — while traversing references, exactly where you most
-- want to mark what you landed on.
--
-- Two flavours, deliberately kept distinct. Conflating them is how three
-- different "the node under the cursor" lookups accreted, each subtly wrong:
--   'def'   the node whose DEFINITION this altitude shows. Drives the SOURCE
--           PANE (sync_focus_to_view), so it stays narrow — widening it would
--           make an ascent onto a callers list swap the def pane out from under
--           you.
--   'about' (the default) that, plus the relation altitudes. Drives VERBS —
--           mark, cone, gf — which want the thing you are looking AT, not a
--           definition to display.
function M.subject(kind)
    local v = M.view
    local def = (v.level == 'fn' and v.fn)
        or (v.level == 'block' and (v.block or ''):match('^(.-)\31'))
        or (v.level == 'region' and v.region)
        or (v.level == 'tbl' and v.tbl)
        or (v.level == 'var' and v.var)
        or nil
    if kind == 'def' then return def end
    -- the RELATION altitudes declare their own subject (cartograph.panes.
    -- concerns) — three of them used to be spelled out here and `refused` was
    -- simply missing, so mark refused on every refusal row that was not a
    -- candidate while the ascend handler derived the same answer one line away.
    local e = concerns.of(v.level)
    return def
        or (e and concerns.subject_of(v.level, v[e.view_key]))
        or nil
end

--- The node a ROW is about: the row's own symbol, else its anchor (a reference
--- row is about the function that contains it), else the altitude's subject.
--- Returns (id, provenance) where provenance is 'row' or 'altitude' — the
--- caller must say which, since an altitude answer marks something that has no
--- row to show a sign on.
---
--- Nil-tolerant by design: an anchor is not always a node (a synthetic or
--- stale id), so the chain must SKIP a dead rung rather than name something that
--- is not there. Written as an `or` chain and NOT as ipairs over a candidate
--- list — ipairs stops at the first nil, which would silently drop every later
--- alternative (the bug that cost resolve_module_alias 845 fills).
--- (This note used to cite render_regfor's module anchor as the example. It was
--- the wrong example: a module node's id IS its file path, so those rows resolve
--- — measured 80/80. The nil-tolerance still matters; regfor never needed it.)
function M.row_subject(row)
    row = row or cursor_row()
    if not row then return nil end
    local function pick(id) return (id and store.node(id)) and id or nil end
    local id = pick(M.line_node[row]) or pick(M.line_about[row])
        or pick((M.line_site[row] or {}).fn)
        or pick((M.line_group[row] or {}).fn)
    if id then return id, 'row' end
    id = pick(M.subject())
    if id then return id, 'altitude' end
    return nil
end

--- The rendered rows of the browser, verbatim, plus the cursor's row index.
--- What cartograph SAID — the claim a feedback entry disputes, and the only
--- thing that makes such a report reproducible without asking the user to
--- paraphrase what was on their screen (cartograph.feedback).
function M.rows()
    if not (M.buf and vim.api.nvim_buf_is_valid(M.buf)) then return nil end
    local lines = vim.api.nvim_buf_get_lines(M.buf, 0, -1, false)
    local r = (M.win and vim.api.nvim_win_is_valid(M.win))
        and vim.api.nvim_win_get_cursor(M.win)[1] or nil
    return lines, r
end

--- Record the gesture about to fire, together with what is on screen AS it
--- fires. One slot, overwritten: feedback is filed about the last thing that
--- surprised you, and by the time you have typed the expectation the before-side
--- is gone. Recorded at the keymap seam so it is the keystroke actually pressed,
--- never a transition inferred afterwards from the trail — "l did nothing" and
--- "l went somewhere wrong" are different reports and the trail cannot tell them
--- apart. nil until the first gesture, which is itself honest: a report filed
--- without having navigated is not a transition report.
M.last_gesture = nil
function M.note_gesture(name)
    local rows, r = M.rows()
    M.last_gesture = { gesture = name, level = M.view.level, lens = M.view.lens,
        row = r, rows = rows }
end

--- Hover a NODE row: tint its relationships and PREVIEW its definition in the
--- source pane (a context takeover, restored on leave). Shared by every altitude
--- in NODE_HOVER. Hover never re-roots the cockpit — pivoting stays a conscious
--- <CR>/l, so the view follows the eye and focus follows intent. Returns the
--- previewed id, or nil when the row is not a node row.
function M.hover_node(r)
    -- the row's OWN node: `line_node` is what the row IS, `line_about` what it
    -- is about — a regfor row is about the registering module and carries only
    -- the latter, so reading line_node alone left the whole altitude previewing
    -- nothing. Deliberately NOT row_subject: that ladder ends at the ALTITUDE
    -- subject, which would preview the subject from a header or chrome row.
    local id = M.line_node[r] or M.line_about[r]
    if not id then return nil end
    M.paint(id)
    -- already focused: nothing to preview, drop the takeover so the def shows
    if id ~= store.focused then store.set_context({ node = id })
    else store.set_context(nil) end
    return id
end

--- Toggle the row's subject in the working set (:CartographMark; the `mark` key
--- calls this when the user binds one). Reports the name either way: at a
--- relation or fn altitude the mark lands on the altitude's subject, which has
--- no row of its own to carry the ● — a silent toggle there looks like a no-op.
function M.ws_toggle_cursor()
    local id, from = M.row_subject()
    if not id then
        return vim.notify('cartograph: nothing to mark here — mark works on a '
            .. 'symbol, a reference to one, or the function you are inside',
            vim.log.levels.INFO)
    end
    local now = store.ws_toggle(id)
    local n = store.node(id)
    vim.notify(('cartograph: %s %s%s'):format(now and 'marked' or 'unmarked',
        n and n.name or id, from == 'altitude' and ' (this altitude)' or ''),
        vim.log.levels.INFO)
    local loc = store.loc_provider and store.loc_provider.get()
    M.render()
    if loc and store.loc_provider then store.loc_provider.set(loc) end
end

--- Toggle a reachability cone on the row's subject (:CartographCone in|out).
function M.cone_cursor(dir)
    local id = M.row_subject()
    local n = id and store.node(id)
    if not n then
        return vim.notify('cartograph: nothing to cone here — cone works on a '
            .. 'symbol, a reference to one, or the function you are inside',
            vim.log.levels.INFO)
    end
    local count = store.set_cone(id, dir)
    M.paint_cone()
    if count == 0 and not store.cone then
        vim.notify('cartograph: cone cleared', vim.log.levels.INFO)
    else
        local go = require('cartograph.config').keys.descend or 'l'
        vim.notify(('cartograph: cone — %s %s (%d node%s) · follow the glow with %s')
            :format(dir == 'in' and 'what reaches' or 'what', n.name,
                count, count == 1 and '' or 's', go), vim.log.levels.INFO)
    end
end

-- ── the view observable ─────────────────────────────────────────────────────
-- THE seam a SURFACE subscribes to (the factorio projection, a web canvas, a
-- 2D map): the view is observable. Instead of a surface polling
-- store.on_redraw + store.on_context and recomputing every time, the pane
-- emits { labels, selected, level } whenever the view actually changes —
-- DEDUPED, so a redraw or cursor move that doesn't change the projection stays
-- quiet. Fired from render() (altitude/list changed) and the cursor handler
-- (selection changed). See [[cartograph-over-the-wire]] "the view is observable".
M._view_subs = {}
M._last_viewkey = nil

--- Subscribe to view changes. fn receives { labels, selected, level }.
--- Returns an unsubscribe function (like store.on_redraw / store.facts).
function M.on_view(fn)
    table.insert(M._view_subs, fn)
    return function ()
        for i, f in ipairs(M._view_subs) do
            if f == fn then table.remove(M._view_subs, i); return end
        end
    end
end

--- Emit the current view to subscribers iff it changed since the last emit.
--- Cheap no-op when nothing is subscribed. Capped so a huge list (a
--- thousand-file view) bounds the payload/key; surfaces cap further.
function M.emit_view()
    if #M._view_subs == 0 then return end
    local p = M.projection(256)
    p.level = M.view and M.view.level or nil
    local key = tostring(p.selected) .. '\0' .. table.concat(p.labels, '\n')
    if key == M._last_viewkey then return end
    M._last_viewkey = key
    for _, fn in ipairs(M._view_subs) do pcall(fn, p) end
end

--- Switch level (re-rendering) and land the cursor on the first useful row.
function M.show(level, ctx_val)
    M.view.level = level
    if ctx_val ~= nil then
        M.view.lens = nil  -- a fresh navigation starts at the altitude's default lens
        M._ghost = nil  -- fresh position: no ghosted lens node
        if level == 'file' then M.view.file = ctx_val
        elseif level == 'fn' then M.view.fn = ctx_val
        elseif level == 'region' then M.view.region = ctx_val
        elseif level == 'var' then M.view.var = ctx_val
        elseif level == 'tbl' then M.view.tbl = ctx_val
        elseif level == 'callers' then M.view.callers = ctx_val
        elseif level == 'refused' then M.view.refused = ctx_val
        elseif level == 'regfor' then M.view.regfor = ctx_val
        elseif level == 'occs' then M.view.occs = ctx_val
        elseif level == 'lit' then M.view.lit = ctx_val
        elseif level == 'live' then M.view.live = ctx_val
        elseif level == 'block' then M.view.block = ctx_val
        elseif level == 'state' then M.view.state = ctx_val
        elseif level == 'proto' then M.view.proto = ctx_val end
    end
    M.render()
    if M.win and vim.api.nvim_win_is_valid(M.win) then
        local first = 1
        for row = 1, vim.api.nvim_buf_line_count(M.buf) do
            if M.line_node[row] or M.line_stmt[row] or M.line_site[row] or M.line_state[row]
                or M.line_lit[row] or M.line_block[row]
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
        -- FILE rows only. line_file is set on every row that BELONGS to a file
        -- (member rows carry it so hover/gf/staging can find their source), so
        -- keying the file-level ● on it dotted every row of any file holding a
        -- mark — a true field, the wrong question. line_kind says what the row
        -- IS ([[cartograph-terminology]]: an overlay annotates rows, it must not
        -- restate them).
        for row, f in pairs(M.line_file) do
            if memberfiles[f] and M.line_kind[row] == 'file' then
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
    local band = store.topo()
    for _, t in ipairs(band:callees(id)) do uses1[t] = true end
    for _, f in ipairs(band:callers(id)) do rdep1[f] = true end
    for t in pairs(uses1) do
        for _, t2 in ipairs(band:callees(t)) do
            if t2 ~= id and not uses1[t2] then uses2[t2] = true end
        end
    end
    for f in pairs(rdep1) do
        for _, f2 in ipairs(band:callers(f)) do
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
    local band = store.topo()
    for id, row in pairs(M.node_line) do
        local n = store.node(id)
        if n and STAGEABLE[n.kind] then
            local fanin  = band:n_callers(id)
            local fanout = band:n_callees(id)
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
    -- forward-declared: the CursorMoved handler + the ascend key fire these,
    -- but the helpers themselves are defined later in attach
    local sync_focus_to_view
    local return_into_block -- undo a pending block step-out (h / the opposite key)

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
                M.emit_view() -- the selected row may have changed (deduped)
                if M.NODE_HOVER[M.view.level] then
                    if not M.hover_node(r)
                        and M.view.level == 'state' and M.line_trans[r] then
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
                elseif M.view.level == 'protos' or M.view.level == 'proto' then
                    -- a prototype is NOT a graph node: its anchor is a module +
                    -- a line, so hover previews the declaring line in that
                    -- module (the FSM-anchor law satisfied by the module, whose
                    -- id IS its file path)
                    local l, f = M.line_stmt[r], M.line_file[r]
                    local mid = f and module_id(f)
                    if l and mid and store.node(mid) then
                        store.set_context({ node = mid, ranges = {
                            { start = { line = l - 1, char = 0 },
                              ['end'] = { line = l, char = 0 } } } })
                    else
                        store.set_context(nil)
                    end
                elseif M.view.level == 'fn' or M.view.level == 'block' then
                    local l = M.line_stmt[r]
                    local fnid = M.view.level == 'fn' and M.view.fn
                        or (M.view.block or ''):match('^(.-)\31')
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
        for _, c in ipairs(store.topo():sites(fnid)) do
            if callrec.line(c) == line and callrec.callee(c) == callee and c.refused then return c end
        end
    end
    local function view_loc()
        return { level = M.view.level, file = M.view.file, fn = M.view.fn,
            region = M.view.region, var = M.view.var, callers = M.view.callers,
            block = M.view.block, lens = M.view.lens, -- lens rides the trail
            live = M.view.live,
            tbl = M.view.tbl, occs = M.view.occs, state = M.view.state, lit = M.view.lit,
            refused = M.view.refused, regfor = M.view.regfor,
            proto = M.view.proto,
            files_mode = M.files_mode,
            row = (M.win and vim.api.nvim_win_is_valid(M.win))
                and vim.api.nvim_win_get_cursor(M.win)[1] or 1 }
    end
    -- the node a view is anchored on (whose def the source pane should show).
    -- The NARROW flavour of the altitude's subject, on purpose: see M.subject.
    local function view_anchor() return M.subject('def') end
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
        local same_location = M.view.level == 'block'
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
        M.view.file, M.view.fn, M.view.region, M.view.var, M.view.callers =
            loc.file, loc.fn, loc.region, loc.var, loc.callers
        M.view.tbl, M.view.occs, M.view.state = loc.tbl, loc.occs, loc.state
        M.view.lit, M.view.refused = loc.lit, loc.refused
        M.view.regfor, M.view.block = loc.regfor, loc.block
        M.view.proto = loc.proto
        M.view.live = loc.live
        M.view.lens = loc.lens -- the lens rides the trail
        M._ghost = nil  -- fresh position: no ghosted lens node
        if loc.level == 'refused' then M._refused_call = refused_call_of(loc.refused) end
        M.show(loc.level)
        if loc.row then pcall(vim.api.nvim_win_set_cursor, M.win, { loc.row, 2 }) end
    end
    local function push_trail() M.trail[#M.trail + 1] = view_loc() end
    -- browser-initiated pivots must not clear the trail (see on_focus)
    local function browser_pivot(id)
        M._resync, M._stepout, M._ghost = nil, nil, nil -- a pivot cancels pending state
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
        M._stepout, M._ghost = nil, nil -- a descent abandons pending step-out / ghost
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
        local landed = store.add_node({ id = id, name = name, kind = 'function',
            unparsed = true, file = h.file, order = h.line,
            range = { start = { line = h.line, char = h.char },
                ['end'] = { line = h.line, char = h.char + #name } } })
        if not landed then return false end -- streaming: the store refused
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
            l.lens = nil -- the lens rides the trail only, not the jumplist
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
        if not M._own_pivot then M._resync, M._stepout = nil, nil end
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
            return enter('block',
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
        end
        -- (a parameter's origin / a dynamic callee's dispatch trace lived here
        -- via the retired trace pane; the sources axis will re-home them —
        -- see the cartograph-trace-axes design)
        -- a local: jump to its defining statement (latest before this row)
        local i, df = M.line_stmtidx[r], dfa.present(node)
        if word and i and df then
            local best, stmts = nil, dfa.stmts(node)
            for j = 1, #stmts do
                if j ~= i then
                    for _, d in ipairs(stmts[j].def) do
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
    -- a row in a live-value view: a sub-table descends deeper (the live
    -- altitude), a resolved function ref focuses the def it dispatches to.
    local function descend_live_row(r)
        local e = M.line_lit[r]
        if e and e.kind == 'tbl' then return enter('live', e.key) end
        if e and e.kind == 'ref' then
            -- a closure with captured state: descend into its upvalues;
            -- a plain fn ref focuses the def it dispatches to
            if e.upkey then return enter('live', e.upkey) end
            if e.id and store.node(e.id) then
                store.set_context(nil); return enter('fn', e.id, e.id)
            end
        end
        local n = store.node(M.line_node[r])
        if n and STAGEABLE[n.kind] then
            store.set_context(nil); enter('fn', n.id, n.id)
        end
    end
    -- descend the lazy $VIMRUNTIME node: extract + splice its tree, re-ingest
    local function load_runtime(node)
        vim.notify('cartograph: extracting $VIMRUNTIME…', vim.log.levels.INFO)
        local ok, data, added =
            pcall(require('cartograph.providers.self').load_runtime, store, node)
        if not ok then
            return vim.notify('cartograph: ' .. tostring(data), vim.log.levels.ERROR)
        end
        if not data then
            return vim.notify('cartograph: ' .. tostring(added), vim.log.levels.WARN)
        end
        store.ingest(data)
        M.show('files')
        vim.notify(('cartograph: $VIMRUNTIME loaded — %d nodes spliced in')
            :format(added), vim.log.levels.INFO)
    end
    local function descend()
        local r = row()
        -- detail lens: an arg/cond row descends into that element's forms (the
        -- block lens); a var row opens the var's usage sites
        local d = M.line_detail[r]
        if d then
            if d.kind == 'var' and store.node(d.id) then
                return enter('var', d.id, d.id)
            elseif d.key then
                return enter('block', d.key)
            end
            return
        end
        if M.view.level == 'protos' then
            local key = M.line_proto[r]
            if key then return enter('proto', key) end
            local f = M.line_file[r]
            if f then return enter('file', f) end
            return
        elseif M.view.level == 'proto' then
            -- an override is a leaf of THIS axis. A silent no-op is
            -- indistinguishable from a dropped keypress, so say it.
            return vim.notify('cartograph: an override is a leaf here — h returns'
                .. ' to the roster, <C-]> in the source pane goes to the value',
                vim.log.levels.INFO)
        elseif M.view.level == 'files' then
            local f = M.line_file[r]
            if f then
                -- the lazy $VIMRUNTIME node: descending it extracts the
                -- runtime tree NOW and splices it into the graph
                local mod = store.by_id and store.by_id[f]
                if mod and mod.lazy then return load_runtime(mod) end
                -- streaming open: a file still in the queue extracts NOW —
                -- the user's attention outranks the queue order
                if store.data and store.data.partial then
                    require('cartograph.parallel').demand(f)
                end
                enter('file', f)
            end
        elseif M.view.level == 'file' then
            if cur_lens() == 'live' then return descend_live_row(r) end
            local n = store.node(M.line_node[r])
            if n and STAGEABLE[n.kind] then
                enter('fn', n.id, n.id)
            elseif n and n.kind == 'region' then
                enter('region', n.id, n.id) -- source pane shows the block's span
            end
        elseif M.view.level == 'live' then
            return descend_live_row(r)
        elseif M.view.level == 'ws' then
            local n = store.node(M.line_node[r])
            if n then
                if n.kind == 'region' then enter('region', n.id, n.id)
                elseif n.kind == 'var' then descend_var(n)
                elseif STAGEABLE[n.kind] then enter('fn', n.id, n.id) end
            else
                local f = M.line_file[r]
                if f then enter('file', f) end
            end
        elseif M.view.level == 'region' then
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
                local best = var_by_name(e.ref)
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
            if M.line_block[r] then return enter('block', M.line_block[r]) end
            descend_fn_row(r)
        elseif M.view.level == 'block' then
            -- a ▸ form opens its own nested forms; a leaf call enters its callee
            if M.line_block[r] then return enter('block', M.line_block[r]) end
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
        if n.kind == 'region' then enter('region', n.id, n.id)
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
    -- node MARKS (vim-mark idiom, node-keyed): m{a-z} sets, `{a-z} jumps.
    if keys.set_mark then
        vim.keymap.set('n', keys.set_mark, function ()
            local ch = vim.fn.getcharstr()
            local id = M.line_node[row()]
            if id and ch:match('^%a$') then
                store.set_mark(ch, id)
                vim.notify('cartograph: mark ' .. ch .. ' → '
                    .. ((store.node(id) or {}).name or id), vim.log.levels.INFO)
            end
        end, { buffer = M.buf, desc = 'cartograph: set a node mark (m{a-z})' })
    end
    if keys.goto_mark then
        vim.keymap.set('n', keys.goto_mark, function ()
            local id = store.get_mark(vim.fn.getcharstr())
            if id then store.pivot(id) -- records the jumplist / focus history
            else vim.notify('cartograph: no such mark', vim.log.levels.WARN) end
        end, { buffer = M.buf, desc = 'cartograph: jump to a node mark (`{a-z})' })
    end
    -- working set + cones: graph-ops with no vim idiom — UNBOUND by default
    -- (commands + your own leader keys). See [[cartograph-terminology]].
    if keys.mark then
        vim.keymap.set('n', keys.mark, M.ws_toggle_cursor,
            { buffer = M.buf, desc = 'cartograph: toggle working set' })
    end
    if keys.set_view then
        vim.keymap.set('n', keys.set_view, function ()
            enter('ws')
            local r = store.workset.last and M.node_line[store.workset.last]
            if r then pcall(vim.api.nvim_win_set_cursor, win, { r, 2 }) end
        end, { buffer = M.buf, desc = 'cartograph: working set view' })
    end
    if keys.set_next then
        vim.keymap.set('n', keys.set_next, function () ws_cycle(1) end,
            { buffer = M.buf, desc = 'cartograph: next working-set member' })
    end
    if keys.set_prev then
        vim.keymap.set('n', keys.set_prev, function () ws_cycle(-1) end,
            { buffer = M.buf, desc = 'cartograph: previous working-set member' })
    end
    if keys.cone_in then
        vim.keymap.set('n', keys.cone_in, function () M.cone_cursor('in') end,
            { buffer = M.buf, desc = 'cartograph: cone — ancestors' })
    end
    if keys.cone_out then
        vim.keymap.set('n', keys.cone_out, function () M.cone_cursor('out') end,
            { buffer = M.buf, desc = 'cartograph: cone — descendants' })
    end

    -- Every FRAME/LENS gesture records itself before it runs (M.note_gesture):
    -- a feedback report about a transition needs the side you came FROM, and
    -- only the keymap knows which key was pressed. j/k are deliberately not
    -- wrapped — they move within one frame, so they change no address.
    local function gestured(name, fn)
        return function () M.note_gesture(name); return fn() end
    end

    vim.keymap.set('n', keys.descend, gestured('descend', descend),
        { buffer = M.buf, desc = 'cartograph: descend (into file / into function)' })
    vim.keymap.set('n', keys.pivot, gestured('pivot', function ()
        if M.view.level == 'file' or M.view.level == 'region' then
            local id = M.line_node[row()]
            if id then return store.pivot(id) end -- focus, stay at this altitude
        end
        descend()
    end), { buffer = M.buf, nowait = true, desc = 'cartograph: pivot here (focus without zooming)' })
    -- ascending lands the cursor ON what we came from (the file-manager rule),
    -- not on the first row of the wider view
    vim.keymap.set('n', keys.ascend, gestured('ascend', function ()
        -- a pending block step-out is provisional: h returns INTO the block
        if M._stepout then return return_into_block() end
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
        local function region_of(v)
            for _, n in ipairs(store.by_file[v.file] or {}) do
                if n.kind == 'region' and atr.sl(n.range) <= atr.sl(v.range)
                    and atr.el(n.range) >= atr.el(v.range) then
                    return n
                end
            end
        end
        local function surface_to_var(v)
            local blk = v and region_of(v)
            if blk then
                M.show('region', blk.id)
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
        elseif M.view.level == 'protos' then
            -- a concern INDEX is a root: there is nothing structurally above it,
            -- so h leaves for the one tree that is always there
            store.set_context(nil)
            M.show('files')
        elseif concerns.of(M.view.level) then
            -- THE INVERSE, declared: every relation altitude reconstructed its
            -- ascend target by parsing its own key (occs branched on the key's
            -- `kind` to choose var-vs-callers; refused/regfor matched the fn
            -- out). Four copies of one idea, now one lookup.
            store.set_context(nil)
            local e = concerns.of(M.view.level)
            local level, key = e.ascend(M.view[e.view_key])
            -- a key that no longer names a node means the thing we hung below
            -- is gone: surface to the file tree rather than an empty view
            if level and (not key or store.node(key)) then
                M.show(level, key)
                if e.ascend_row then
                    pcall(vim.api.nvim_win_set_cursor, win, { e.ascend_row, 0 })
                end
            else
                M.show('files')
            end
        elseif M.view.level == 'var' then
            store.set_context(nil)
            local id = M.view.var
            M.show('region', M.view.region)
            local r = M.node_line[id]
            if r then pcall(vim.api.nvim_win_set_cursor, win, { r, 2 }) end
        elseif M.view.level == 'block' then
            -- a body descent hangs below its function: surface back to it
            store.set_context(nil); store.set_highlight(nil)
            local fnid = (M.view.block or ''):match('^(.-)\31')
            if fnid and store.node(fnid) then M.show('fn', fnid)
            else M.show('files') end
        elseif M.view.level == 'fn' or M.view.level == 'region'
            or M.view.level == 'tbl' then
            store.set_highlight(nil)
            local id = (M.view.level == 'fn' and M.view.fn)
                or (M.view.level == 'region' and M.view.region) or M.view.tbl
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
    end), { buffer = M.buf, desc = 'cartograph: ascend (to file / to file tree)' })

    -- j/k as a depth-first walk of the form tree. Inside a block they move
    -- among its forms; at the FIRST/LAST form they STEP OUT to the parent —
    -- j lands on the node after the block, k on the node before it. If that
    -- parent has no such sibling, the step-out CHAINS further up automatically
    -- until it finds one, but NEVER leaves the function; if there is nowhere to
    -- go in that direction (a block at the very edge of the function), it is a
    -- no-op — you stay where you started. A landing is a sticky two-press: the
    -- ORIGINAL block is remembered and h ascends back INTO it, the opposite key
    -- returns there, and the same key again commits (drops it from the ascend
    -- history). Elsewhere j/k are plain motions.
    local function content_rows()
        local rows = {}
        for r = 1, vim.api.nvim_buf_line_count(M.buf) do
            if M.line_stmt[r] then rows[#rows + 1] = r end
        end
        return rows
    end
    -- the nearest content row in `dir` from `here` (first below / last above)
    local function sibling_in(rows, here, dir)
        local t
        for _, rr in ipairs(rows) do
            if dir == 1 then if rr > here then return rr end
            elseif rr < here then t = rr end
        end
        return t
    end
    local function step_out(dir)
        local start_loc = view_loc()
        local start_trail = vim.deepcopy(M.trail)
        local function noop()
            M.trail = start_trail
            restore_loc(start_loc) -- back where we started; nothing moved
        end
        store.set_context(nil); store.set_highlight(nil)
        local work = vim.deepcopy(M.trail)
        while true do
            local loc = table.remove(work)
            -- stay inside the function: never surface past the fn into the file
            if not loc or loc.level == 'file' or loc.level == 'files' then
                return noop()
            end
            M.trail = vim.deepcopy(work)
            restore_loc(loc) -- a parent view, cursor on the child's row
            local target = sibling_in(content_rows(), loc.row, dir)
            if target then
                pcall(vim.api.nvim_win_set_cursor, M.win, { target, 2 })
                local parent_trail = vim.deepcopy(work)
                -- provisional: h ascends back INTO the ORIGINAL block. Copy —
                -- pushing onto M.trail must NOT mutate the saved parent_trail
                M.trail = vim.deepcopy(parent_trail)
                M.trail[#M.trail + 1] = start_loc
                M._stepout = { dir = dir, block_loc = start_loc,
                    block_trail = start_trail, parent_trail = parent_trail }
                return sync_focus_to_view() -- same function -> def pane follows
            end
            if loc.level == 'fn' then return noop() end -- fn top, nowhere to go
            -- else: this parent has no sibling either — chain further up
        end
    end
    -- restore the remembered block at the spot we stepped out from, with its
    -- original ascend history (h and the opposite key both undo this way)
    function return_into_block()
        local so = M._stepout
        if not so then return end
        M._stepout = nil
        M.trail = vim.deepcopy(so.block_trail)
        store.set_context(nil); store.set_highlight(nil)
        restore_loc(so.block_loc)
        sync_focus_to_view()
    end
    local function step(dir)
        M._ghost = nil -- a manual move abandons a ghosted lens node
        if M.view.level ~= 'block' and not M._stepout then
            return vim.cmd('normal! ' .. vim.v.count1 .. (dir == 1 and 'j' or 'k'))
        end
        if M._stepout then
            if dir == -M._stepout.dir then
                return return_into_block() -- opposite key: back to the block
            end
            -- same key: commit — the ascend history is now the parent's depth
            M.trail = vim.deepcopy(M._stepout.parent_trail)
            M._stepout = nil
        end
        local rows, cur = content_rows(), row()
        if #rows == 0 then
            return vim.cmd('normal! ' .. (dir == 1 and 'j' or 'k'))
        end
        local idx
        for i, rr in ipairs(rows) do if rr == cur then idx = i end end
        if not idx then -- on a chrome row: snap into the list, don't step out
            return pcall(vim.api.nvim_win_set_cursor, M.win,
                { rows[dir == 1 and 1 or #rows], 2 })
        end
        local nxt = rows[idx + dir]
        if nxt then
            pcall(vim.api.nvim_win_set_cursor, M.win, { nxt, 2 })
        elseif M.view.level == 'block' then
            step_out(dir) -- at the block edge: cross out to the parent
        end
    end
    vim.keymap.set('n', keys.down, function () step(1) end,
        { buffer = M.buf, desc = 'cartograph: next row (steps out at a block edge)' })
    vim.keymap.set('n', keys.up, function () step(-1) end,
        { buffer = M.buf, desc = 'cartograph: previous row (steps out at a block edge)' })

    -- <Tab>/<S-Tab> cycle the current altitude's MODE: at the files level, flat
    -- list <-> include tree; at fn/block/region, the lens (statements <-> detail).
    -- (Shadows <C-i>-forward here — terminals conflate Tab/C-i.)
    -- what identifies a row across a lens switch: its source line + a stable tag
    local function row_tag(r)
        local d = M.line_detail[r]
        if d then return d.key or (d.id and 'var\31' .. d.id) or d.kind end
        return M.line_node[r]
    end
    local function row_desc(r)
        return { line = M.line_stmt[r], tag = row_tag(r) }
    end
    -- place the cursor for `desc` and report how well it matched:
    --   'exact' the node itself is a row here (a tagged item; or, for a bare
    --           statement, its row on the same line — the node lives in this lens)
    --   'ghost' the node is gone; land on its closest parent (the statement on
    --           its line) — a GHOST anchor
    --   'near'  not even the line is here; land on the nearest row above
    local function land_on(desc)
        if not desc then return nil end
        local exact, ghost, near
        for r = 1, vim.api.nvim_buf_line_count(M.buf) do
            local rl, rt = M.line_stmt[r], row_tag(r)
            if desc.tag then
                -- match tag AND line: the same var read in two statements shares
                -- a tag, so the line disambiguates which occurrence
                if rt == desc.tag and rl == desc.line then exact = r; break end
                if desc.line and rl == desc.line and not rt then ghost = ghost or r end
            elseif desc.line and rl == desc.line and not rt then
                exact = r; break -- a bare statement IS its same-line row
            end
            if desc.line and rl and rl <= desc.line
                and (not near or rl > (M.line_stmt[near] or -1)) then near = r end
        end
        local target = exact or ghost or near
        if target then pcall(vim.api.nvim_win_set_cursor, win, { target, 2 }) end
        return exact and 'exact' or (ghost and 'ghost') or (near and 'near') or nil
    end
    -- Cycling FOLLOWS the current position across lenses: the node under the
    -- cursor is carried to its row in the new lens. If it has no row there (an
    -- arg/cond/var vanishing in `statements`), it becomes a GHOST anchored to
    -- its enclosing statement and is remembered in M._ghost, so cycling back to
    -- the lens it lives in restores it exactly.
    local function cycle_lens(step)
        local set = lens_set(M.view.level)
        if not set then return end
        local from = cur_lens()
        -- carry the ghosted origin if we're mid-ghost, else the row we're on
        local anchor = M._ghost or { lens = from, desc = row_desc(row()) }
        local i = 1
        for k, name in ipairs(set) do if name == from then i = k end end
        M.view.lens = set[((i - 1 + step) % #set) + 1]
        M.render() -- re-render at the same altitude; keep our place, don't jump to row 1
        local kind = land_on(anchor.desc)
        -- exact => the node lives here, no ghost; ghost/near => still displaced,
        -- so remember the origin to restore it when we cycle back
        if kind == 'ghost' or kind == 'near' then M._ghost = anchor else M._ghost = nil end
        vim.api.nvim_exec_autocmds('CursorMoved', { buffer = M.buf })
    end
    local function cycle(step)
        if M.view.level == 'files' then
            local under = M.line_file[row()]
            M.files_mode = M.files_mode == 'tree' and 'flat' or 'tree'
            M.show('files')
            for r = 1, vim.api.nvim_buf_line_count(M.buf) do
                if M.line_file[r] == under then
                    pcall(vim.api.nvim_win_set_cursor, win, { r, 0 })
                    break
                end
            end
        else
            cycle_lens(step)
        end
    end
    vim.keymap.set('n', keys.cycle, gestured('cycle', function () cycle(1) end),
        { buffer = M.buf, desc = 'cartograph: cycle the altitude mode / lens' })
    vim.keymap.set('n', keys.cycle_back, gestured('cycle-back', function () cycle(-1) end),
        { buffer = M.buf, desc = 'cartograph: cycle the altitude mode / lens (reverse)' })

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
        -- the four-way probe this used to open-code IS row_subject — it was the
        -- only consumer that got the lookup right, so it now shares it. Extra
        -- parens: row_subject also returns a provenance, which would otherwise
        -- ride along as a second argument.
        local n = store.node((M.row_subject(r)))
        local file = (site and site.file) or (n and n.file) or M.line_file[r]
        if not file then return end
        local lnum = (site and site.line + 1) or (M.view.level == 'fn' and M.line_stmt[r])
            or (n and atr.sl(n.range) + 1) or 1
        vim.cmd('tab drop ' .. vim.fn.fnameescape(store.data.root .. '/' .. file))
        pcall(vim.api.nvim_win_set_cursor, 0, { lnum, 0 })
    end, { buffer = M.buf, desc = 'cartograph: open the real file here' })

    store.on_plan(function () M.restage() end)

    vim.api.nvim_buf_create_user_command(M.buf, 'CartographHeat', function () M.toggle_heat() end,
        { desc = 'cartograph: toggle the hub/heat overlay (fan-in/out + role)' })
end

return M
