-- LEFT pane: the movable definitions (functions/methods) grouped by file, in
-- source order. Not a flat alphabetical dump — the ordering is the file's, and
-- moving the cursor writes focus to the store (which drives the source pane).

local store = require 'cartograph.store'

-- The cockpit's unit is the function. documentSymbol emits every local/field/
-- constant too; we show only the movable units here (richer nodes stay in the
-- dump for later panes).
local SHOWN = { ['function'] = true, method = true }

local M = { line_node = {}, node_line = {} }

local ns = vim.api.nvim_create_namespace('cartograph_symbols_dep')
local ns_class = vim.api.nvim_create_namespace('cartograph_symbols_class')

-- File-usage markers, shown in the gutter on each file header (keeps the narrow
-- header text clean). Separates truly-unused from loaded-for-side-effects, so a
-- side-effect-only module never reads as dead code.
--   ○ orphan (no inbound)   ⚠ unused import (pure module)   ↻ side-effect
local SIGN = {
    orphan     = { text = '○ ', hl = 'DiagnosticWarn' },
    deadimport = { text = '⚠ ', hl = 'DiagnosticWarn' },
    sideeffect = { text = '↻ ', hl = 'Comment' },
    -- 'value' and 'used' are genuinely used → no marker (keeps the list quiet)
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

function M.create()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = 'wipe'
    vim.bo[buf].filetype  = 'cartograph-symbols'

    local lines, line_node, node_line = {}, {}, {}
    local signs = {} -- { {row0, sign}, ... } applied after the lines land
    for _, file in ipairs(store.files) do
        local defs = {}
        for _, n in ipairs(store.by_file[file] or {}) do
            if SHOWN[n.kind] then defs[#defs + 1] = n end
        end
        if #defs > 0 then
            lines[#lines + 1] = ('▸ %s  (%d)'):format(file, #defs)
            line_node[#lines] = false -- header row
            local sign = SIGN[store.classify(file)]
            if sign then signs[#signs + 1] = { row = #lines - 1, sign = sign } end
            for _, n in ipairs(defs) do
                local icon = n.kind == 'method' and ':' or 'ƒ'
                lines[#lines + 1] = ('  %s %-24s L%d'):format(icon, n.name or '?', n.range.start.line + 1)
                line_node[#lines] = n.id
                node_line[n.id]   = #lines
            end
        end
    end

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    for _, s in ipairs(signs) do
        vim.api.nvim_buf_set_extmark(buf, ns_class, s.row, 0, {
            sign_text = s.sign.text, sign_hl_group = s.sign.hl,
        })
    end
    vim.bo[buf].modifiable = false
    M.buf       = buf
    M.line_node = line_node
    M.node_line = node_line

    hl_setup()
    vim.api.nvim_create_autocmd('ColorScheme', { callback = hl_setup })
    return buf
end

-- Tint the list by each row's relationship to `id`: dependencies (uses) and
-- dependents (used-by), out to 2 levels, with depth-1 stronger than depth-2.
-- Priority (high wins): uses¹ > used-by¹ > uses² > used-by². The focus row is
-- left to the cursorline.
function M.paint(id)
    if not M.buf or not vim.api.nvim_buf_is_valid(M.buf) then return end
    vim.api.nvim_buf_clear_namespace(M.buf, ns, 0, -1)
    if not id then return end

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

--- Wire cursor movement in `win` to focus (so source/tree follow), and keep the
--- list cursor synced to the focused node (so a pivot elsewhere shows here too).
function M.attach(win)
    M.win = win
    vim.wo[win].signcolumn = 'yes:1' -- stable-width gutter for the class markers
    vim.api.nvim_create_autocmd('CursorMoved', {
        buffer = M.buf,
        callback = function ()
            local row = vim.api.nvim_win_get_cursor(win)[1]
            local id  = M.line_node[row]
            if id then store.set_focus(id) end
        end,
    })
    store.on_focus(function (id)
        local ln = M.node_line[id]
        if ln and M.win and vim.api.nvim_win_is_valid(M.win)
            and vim.api.nvim_win_get_buf(M.win) == M.buf then
            -- set_focus is idempotent, so the CursorMoved this triggers no-ops
            vim.api.nvim_win_set_cursor(M.win, { ln, 2 })
        end
        M.paint(id)
    end)
end

return M
