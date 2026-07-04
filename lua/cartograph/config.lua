-- Plugin configuration. Keys are one flat table so any binding can be remapped
-- for a different layout (dvorak, colemak) without touching pane code:
--
--   require('cartograph').setup { keys = { jump = '<C-j>', back = '<C-h>' } }
--
-- Defaults assume qwerty and reuse standard vim idioms (tags, jumplist, gf).

local M = {}

-- clangd resolution for C/C++ directory opens: tree-sitter builds the
-- skeleton, a headless clangd session proves the call edges. `false`
-- disables; clangd_bin overrides binary discovery (PATH, ~/.local/bin).
M.clangd = true
M.clangd_bin = nil

-- cross-language bindings (string-key dispatch boundaries); nil = the
-- defaults in cartograph/xlang.lua (chromium WebUI, guile gsubr,
-- lua_register). Add your own: { export = { verb, name = argN },
-- import = { verb, name = argN } | { any_call = true } }.
M.bindings = nil

-- minified bundles (*.min.js): true = keep them as opaque frontier modules
-- (visible in the files view; descending an unresolved call reaches into
-- them by text search); false = invisible, as if they don't exist
M.unparsed = true

-- human dispatch declarations: pins name the target of a dynamic call
-- site the analysis can't resolve. 1-based lines, target by function name.
--   setup{ pins = { { file = 'src/hooks.php', line = 88, to = 'my_handler' } } }
M.pins = nil

M.keys = {
    -- navigation
    pivot      = '<CR>',    -- tree/trace: re-root on / expand this entry
    jump       = '<C-]>',   -- source: go to the callee under the cursor (tags idiom)
    back       = '<C-o>',   -- jumplist back
    back_alt   = '<C-t>',   -- also back (tag-pop idiom; works where <C-o> may be taken)
    forward    = '<C-i>',   -- jumplist forward (bound only where <Tab> isn't the lens)
    open_file  = 'gf',      -- open the real file here
    ascend     = 'h',       -- symbols: zoom out (function -> file -> file tree);
    descend    = 'l',       -- symbols: zoom in — h/l are free in a linear list
                            -- (<CR> also descends, like the tree's pivot)
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

-- Entry points: files EXPECTED to have no inbound require (a runtime loads
-- them directly). They classify as 'entry' (▶) instead of 'orphan' (○ — the
-- warning), and sort first among the include tree's roots. Lua patterns,
-- matched against the workspace-relative path; defaults cover the Factorio
-- lifecycle plus the common generic mains. Override the whole list via
-- setup{ entrypoints = {...} }.
M.entrypoints = {
    'control%.lua$', 'data%.lua$', 'settings%.lua$',
    'data%-updates%.lua$', 'data%-final%-fixes%.lua$',
    'settings%-updates%.lua$', 'settings%-final%-fixes%.lua$',
    'main%.lua$',
}

-- FSM adapter: the ~20 lines of domain semantics a generic Lua analysis
-- cannot infer — WHICH data table is the transition spec, which maps
-- state -> subscriptions, which table holds the callbacks, and the register
-- verb. Everything downstream (entry points, reachability, browsing) is
-- generic. Defaults fit the bnw scenario; override via setup{ fsm = {...} }.
M.fsm = {
    events    = { var = 'landing_states', path = { 'events' } },
    subs      = { var = 'state_subs' },
    callbacks = { var = 'launch_callbacks' },
    register  = 'register_listener',
}

--- Merge user options (called from cartograph.setup).
function M.apply(opts)
    for k, v in pairs((opts or {}).keys or {}) do M.keys[k] = v end
    if (opts or {}).entrypoints then M.entrypoints = opts.entrypoints end
    if (opts or {}).fsm then M.fsm = opts.fsm end
end

return M
