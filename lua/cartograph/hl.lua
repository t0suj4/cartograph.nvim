-- Shared highlight groups. Concern colours (for the untangle lens) are defined
-- once here and reused by any pane that paints by concern, so every view
-- agrees on the palette.

local M = {}

M.CONCERN = {
    'CartographConcern0', 'CartographConcern1', 'CartographConcern2',
    'CartographConcern3', 'CartographConcern4', 'CartographConcern5',
}

local HUES = { 0x9ece6a, 0x7dcfff, 0xff9e64, 0xbb9af7, 0x2ac3de, 0xf7768e }

--- Define the concern groups by blending each hue over the real Normal bg, so
--- the bands track the colorscheme. Idempotent; safe to call on ColorScheme.
function M.setup()
    local normal = vim.api.nvim_get_hl(0, { name = 'Normal', link = false })
    local bg = normal.bg or 0x222436
    local function blend(hue, alpha)
        local function ch(c, n) return math.floor(c / n) % 256 end
        local r = math.floor(ch(hue, 65536) * alpha + ch(bg, 65536) * (1 - alpha) + 0.5)
        local g = math.floor(ch(hue, 256) * alpha + ch(bg, 256) * (1 - alpha) + 0.5)
        local b = math.floor((hue % 256) * alpha + (bg % 256) * (1 - alpha) + 0.5)
        return string.format('#%02x%02x%02x', r, g, b)
    end
    for i, hue in ipairs(HUES) do
        vim.api.nvim_set_hl(0, M.CONCERN[i], { bg = blend(hue, 0.16) })
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
    link('CartographFrontier', 'WarningMsg') -- the ⊘ frontier marker
end

return M
