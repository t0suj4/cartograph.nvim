-- Shared highlight groups. Concern colours (for the untangle lens) are defined
-- once here and reused by any pane that paints by concern, so every view
-- agrees on the palette.

local M = {}

M.CONCERN = {
    'CartographConcern0', 'CartographConcern1', 'CartographConcern2',
    'CartographConcern3', 'CartographConcern4', 'CartographConcern5',
}

local HUES = { 0x9ece6a, 0x7dcfff, 0xff9e64, 0xbb9af7, 0x2ac3de, 0xf7768e }

--- Blend a 0xRRGGBB `hue` over a 0xRRGGBB `bg` at `alpha`, as a '#rrggbb' string.
--- Pure — the colour math shared by every concern / relationship tint (callers
--- resolve the real Normal bg once, then pass it in). See M.normal_bg.
function M.blend(hue, bg, alpha)
    local function ch(c, n) return math.floor(c / n) % 256 end
    local r = math.floor(ch(hue, 65536) * alpha + ch(bg, 65536) * (1 - alpha) + 0.5)
    local g = math.floor(ch(hue, 256) * alpha + ch(bg, 256) * (1 - alpha) + 0.5)
    local b = math.floor((hue % 256) * alpha + (bg % 256) * (1 - alpha) + 0.5)
    return string.format('#%02x%02x%02x', r, g, b)
end

--- The real Normal background as a 0xRRGGBB number (a tokyonight-ish default
--- when the colorscheme leaves it unset), so tints track the colorscheme.
function M.normal_bg()
    return vim.api.nvim_get_hl(0, { name = 'Normal', link = false }).bg or 0x222436
end

--- Define the concern groups by blending each hue over the real Normal bg, so
--- the bands track the colorscheme. Idempotent; safe to call on ColorScheme.
function M.setup()
    local bg = M.normal_bg()
    for i, hue in ipairs(HUES) do
        vim.api.nvim_set_hl(0, M.CONCERN[i], { bg = M.blend(hue, bg, 0.16) })
    end
end

--- Group name for a 0-based concern id (cycles through the palette).
function M.concern(id) return M.CONCERN[(id % #M.CONCERN) + 1] end

--- UI groups for the browser + source panes. `default = true` links so a colorscheme
--- (or the user) can override without fighting us. Idempotent.
function M.ui()
    local link = function (name, to) vim.api.nvim_set_hl(0, name, { link = to, default = true }) end
    link('CartographTitle',    'Function')   -- the rooted node / trace subject
    link('CartographSection',  'Title')      -- 'uses' / 'used by' headers
    link('CartographDim',      'Comment')    -- locations, counts, frontier reasons
    link('CartographLit',      'String')     -- literal values (trace answers)
    link('CartographMarker',   'Special')    -- expand/collapse markers
    link('CartographPick',     'IncSearch')  -- a row-local name pick's labels
    link('CartographFrontier', 'WarningMsg') -- the ⊘ frontier marker
    link('CartographCone',       'Special')  -- ● a node inside the active cone
    link('CartographConeAnchor', 'Todo')     -- ◆ the cone's anchor node
    -- territory overlay: per-entry territories reuse the CONCERN hues; these
    -- three name the shared regions and the seams between them.
    link('CartographCommons', 'WarningMsg')  -- ● reached by several entries
    link('CartographCore',    'Comment')     -- ● reached by every entry (dim: it's everywhere)
    link('CartographBorder',  'Todo')        -- ◆ a seam: feature meets shared code
end

return M
