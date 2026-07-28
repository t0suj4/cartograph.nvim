-- ui.scratch is the ONE seam every cockpit report renders through, and
-- nvim_buf_set_lines fails the WHOLE call on a single embedded newline — so a
-- tenant rendering source-derived text (a Lua `[[…]]` literal, a docstring) could
-- take down an entire command, which is exactly how :CartographPrototypes died
-- on Von-Neumann's story text. The guard belongs at the seam, not in each
-- tenant: there is no way to enumerate the values a future report will render.

local ui = require 'cartograph.ui'

local function lines_of(buf)
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end
local function scratch(lines)
    local buf = ui.scratch(lines)
    local got = lines_of(buf)
    vim.cmd('close')
    return got
end

test('scratch: an embedded newline is FOLDED, never a failed render', function ()
    local got = scratch({ 'a', 'multi\nline\nvalue', 'b' })
    eq(3, #got)                       -- 1:1 line↔item, so <CR> keymaps still map
    eq('a', got[1])
    eq('multi↵line↵value', got[2])    -- folded, and the fold is VISIBLE
    eq('b', got[3])
end)

test('scratch: a CR (or CRLF) folds the same way', function ()
    eq({ 'x↵y' }, scratch({ 'x\r\ny' }))
end)

test('scratch: text with no breaks is passed through byte-identical', function ()
    local src = { 'PROTOTYPES — 54 in 31 module(s)', '  basis: copy 20 · literal 24' }
    eq(src, scratch(src))
end)

test('scratch: an empty report still renders (a window, and no crash)', function ()
    local wins = #vim.api.nvim_tabpage_list_wins(0)
    local buf = ui.scratch({})
    eq({ '' }, lines_of(buf))   -- a buffer is never zero lines in nvim
    eq(wins + 1, #vim.api.nvim_tabpage_list_wins(0))
    vim.cmd('close')
end)
