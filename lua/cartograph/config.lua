-- Plugin configuration. Keys are one flat table so any binding can be remapped
-- for a different layout (dvorak, colemak) without touching pane code:
--
--   require('cartograph').setup { keys = { jump = '<C-j>', back = '<C-h>' } }
--
-- Defaults assume qwerty and reuse standard vim idioms (tags, jumplist, gf).

local M = {}

M.keys = {
    -- navigation
    pivot      = '<CR>',    -- tree/trace: re-root on / expand this entry
    jump       = '<C-]>',   -- source: go to the callee under the cursor (tags idiom)
    back       = '<C-o>',   -- jumplist back
    back_alt   = '<C-t>',   -- also back (tag-pop idiom; works where <C-o> may be taken)
    forward    = '<C-i>',   -- jumplist forward (bound only where <Tab> isn't the lens)
    open_file  = 'gf',      -- open the real file here
    ascend     = '-',       -- symbols: zoom out (function -> file -> file tree)
    trace      = 'gr',      -- source: trace where the parameter under the cursor comes from
    cycle      = '<Tab>',   -- source: toggle the flow (concern) lens
    cycle_back = '<S-Tab>',
    close      = 'q',       -- trace: give the window back
    -- staging (symbols pane)
    cut        = 'dd',
    cut_visual = 'd',
    paste      = 'p',
    unstage    = 'u',
}

--- Merge user options (called from cartograph.setup).
function M.apply(opts)
    for k, v in pairs((opts or {}).keys or {}) do M.keys[k] = v end
end

return M
