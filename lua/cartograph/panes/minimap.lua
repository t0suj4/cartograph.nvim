-- MINIMAP pane: a compact overview of the focused function's neighborhood. It
-- lives in a horizontal split under the tree. Three variants are provided so we
-- can judge which earns its screen space (this is the "most expendable" pane in
-- the design); cycle them live with <Tab> / <S-Tab>.
--
--   1 'file'   — a compressed strip of the focus's file: its span shaded, and
--                its outgoing call sites marked. Spatial companion to source.
--   2 'spread' — one line per file the 1-hop neighborhood touches, with
--                uses / used-by counts. The "which files does a move touch" view.
--   3 'graph'  — a tiny node sketch: used-by above, focus, uses below.
--   4 'flow'   — statement-level local def-use, with the untangle lens: each
--                statement tagged/coloured by independent concern + a tangle score.

local store    = require 'cartograph.store'
local untangle = require 'cartograph.untangle'

local VARIANTS = { 'file', 'spread', 'graph', 'flow' }

local M = { variant = 1, win = nil }

-- ── shared helpers ────────────────────────────────────────────────────────
local function set_lines(buf, lines)
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
end

-- outgoing call sites of the focus, as { {line=0based, target=name}, ... }
local function outgoing_sites(id)
    local sites = {}
    for _, to in ipairs(store.uses[id] or {}) do
        local tn = store.node(to)
        for _, r in ipairs(store.occurrences(id, to) or {}) do
            sites[#sites + 1] = { line = r.start.line, target = tn and tn.name or to }
        end
    end
    return sites
end

-- ── variant 1: file-position strip ─────────────────────────────────────────
local function render_file(node, rows)
    local ok, all = pcall(vim.fn.readfile, store.abspath(node))
    if not ok or #all == 0 then return { '(file unreadable)' } end
    local L = #all
    local H = math.max(8, math.min(rows, L))
    local function to_row(line1) return math.floor((line1 - 1) / L * H) end

    local s = node.range.start.line + 1   -- 1-based
    local e = node.range['end'].line + 1
    local glyph, ann = {}, {}
    for r = 0, H - 1 do glyph[r] = '░' end
    for r = to_row(s), to_row(e) do glyph[r] = '▓' end
    ann[to_row(s)] = ('%s  L%d-%d'):format(node.name or '?', s, e)
    for _, site in ipairs(outgoing_sites(node.id)) do
        local r = to_row(site.line + 1)
        ann[r] = ann[r] and (ann[r] .. ', ' .. site.target) or ('· → ' .. site.target)
    end

    local out = { ('%s   %d ln'):format(node.file, L), '' }
    for r = 0, H - 1 do
        out[#out + 1] = (' %s  %s'):format(glyph[r], ann[r] or '')
    end
    return out
end

-- ── variant 2: neighborhood file-spread ─────────────────────────────────────
local function render_spread(node)
    local home = node.file
    local tally = {}   -- file -> {uses=, usedby=}
    local order = {}
    local function bump(file, key)
        if not tally[file] then tally[file] = { uses = 0, usedby = 0 }; order[#order + 1] = file end
        tally[file][key] = tally[file][key] + 1
    end
    for _, to in ipairs(store.uses[node.id] or {}) do
        local n = store.node(to); if n then bump(n.file, 'uses') end
    end
    for _, from in ipairs(store.usedby[node.id] or {}) do
        local n = store.node(from); if n then bump(n.file, 'usedby') end
    end
    -- home first, then alphabetical
    table.sort(order, function (a, b)
        if a == home ~= (b == home) then return a == home end
        return a < b
    end)

    local out = { ('neighborhood of  %s'):format(node.name or '?'),
                  '─────────────────────────────' }
    if #order == 0 then out[#out + 1] = '  (no dependencies)'; return out end
    for _, f in ipairs(order) do
        local t = tally[f]
        local u = t.uses   > 0 and (t.uses   .. (t.uses   == 1 and ' use'  or ' uses')) or '—'
        local b = t.usedby > 0 and (t.usedby .. ' by') or '—'
        out[#out + 1] = ('%s %-22s %-7s %s'):format(f == home and '●' or ' ', f, u, b)
    end
    out[#out + 1] = ''
    out[#out + 1] = '● = home file'
    return out
end

-- ── variant 3: 1-hop graph sketch ───────────────────────────────────────────
local function names(ids, home)
    local list = {}
    for _, id in ipairs(ids or {}) do
        local n = store.node(id)
        local label = n and n.name or id
        if n and n.file ~= home then label = label .. '   [' .. n.file .. ']' end
        list[#list + 1] = label
    end
    table.sort(list)
    return list
end

local function render_graph(node)
    local home = node.file
    local ups  = names(store.usedby[node.id], home)   -- callers reach IN
    local dns  = names(store.uses[node.id],   home)   -- focus calls OUT
    local out  = { ('◀ used by (%d)'):format(#ups) }
    for _, n in ipairs(ups) do out[#out + 1] = '    ' .. n end
    if #ups > 0 then out[#out + 1] = '        │' end
    out[#out + 1] = ('   %s %s'):format(node.kind == 'method' and ':' or 'ƒ', node.name or '?')
    if #dns > 0 then out[#out + 1] = '        │' end
    out[#out + 1] = ('▶ uses (%d)'):format(#dns)
    for _, n in ipairs(dns) do out[#out + 1] = '    ' .. n end
    return out
end

-- ── variant 4: statement-level data flow ───────────────────────────────────
-- Zooms below the function: local def-use within the body, from the provider's
-- `df`. COMPREHENSION ONLY — locals, no control/anti/aliasing, so it explains
-- flow but is not a reorder-safety claim (see the ledger/PDG notes).
-- statement-level def-use with the untangle lens: each statement is tagged with
-- its concern (A, B, C…) and the header shows the tangle metrics. The concern
-- *colours* land in the source pane (via the 'concerns' lens), where they line
-- up with the real code; here the letters carry the grouping.
local function render_flow(node)
    local df = node.df
    if not df then return { '(no data-flow info for this node)' } end
    local a = untangle.analyze(df)
    local function tag(c) return string.char(65 + (c % 26)) end -- A, B, C…
    local out = {
        ('inputs: %s'):format(#df.inputs > 0 and table.concat(df.inputs, ', ') or '(none)'),
        ('concerns: %d   tangle: %d   maxspan: %d      locals only'):format(a.ncomp, a.tangle, a.maxspan),
        '─────────────────────────',
    }
    for i, s in ipairs(df.stmts) do
        local parts = {}
        if #s.def > 0 then parts[#parts + 1] = 'def ' .. table.concat(s.def, ',') end
        if #s.use > 0 then parts[#parts + 1] = 'use ' .. table.concat(s.use, ',') end
        local deps = {}
        for _, d in ipairs(s.dep) do
            local from = df.stmts[d.from]
            deps[#deps + 1] = ('L%s·%s'):format(from and from.l or ('#' .. d.from), d.var)
        end
        out[#out + 1] = ('%s L%-4d %-26s%s'):format(tag(a.comp[i]), s.l, table.concat(parts, '  '),
            #deps > 0 and ('  <- ' .. table.concat(deps, ' ')) or '')
    end
    return out
end

-- ── pane machinery ──────────────────────────────────────────────────────────
function M.render(id)
    if not M.buf or not vim.api.nvim_buf_is_valid(M.buf) then return end
    local node = store.node(id)
    local variant = VARIANTS[M.variant]
    local header = ('── minimap · %s   (<Tab> switch)'):format(variant)
    local body
    if not node then
        body = { '(no selection)' }
    elseif variant == 'file' then
        local rows = (M.win and vim.api.nvim_win_is_valid(M.win))
            and (vim.api.nvim_win_get_height(M.win) - 3) or 15
        body = render_file(node, rows)
    elseif variant == 'spread' then
        body = render_spread(node)
    elseif variant == 'flow' then
        body = render_flow(node)
    else
        body = render_graph(node)
    end
    local lines = { header, '' }
    for _, l in ipairs(body) do lines[#lines + 1] = l end
    set_lines(M.buf, lines)
end

function M.cycle(delta)
    M.variant = (M.variant - 1 + delta) % #VARIANTS + 1
    -- the flow variant turns on the concern lens (the source pane colours by it)
    store.set_lens(VARIANTS[M.variant] == 'flow' and 'concerns' or nil)
    M.render(store.focused)
end

function M.create()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = 'wipe'
    vim.bo[buf].filetype  = 'cartograph-minimap'
    M.buf = buf
    store.on_focus(function (id) M.render(id) end)
    vim.keymap.set('n', '<Tab>',   function () M.cycle(1)  end, { buffer = buf, desc = 'cartograph: next minimap variant' })
    vim.keymap.set('n', '<S-Tab>', function () M.cycle(-1) end, { buffer = buf, desc = 'cartograph: prev minimap variant' })
    return buf
end

-- Split the tree window horizontally; put the minimap in the bottom.
function M.attach(win)
    local h = vim.api.nvim_win_get_height(win)
    vim.api.nvim_set_current_win(win)
    vim.cmd('belowright split')
    M.win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(M.win, M.create())
    vim.api.nvim_win_set_height(M.win, math.max(8, math.floor(h * 0.45)))
    vim.api.nvim_set_current_win(win)
end

return M
