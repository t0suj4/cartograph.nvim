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

-- STOCK lua-language-server as the lua oracle: references per ~-marked
-- def, intersected with known call sites — upgrades what it can prove,
-- refutes wrong guesses, leaves the rest ~. `false` disables;
-- luals_bin overrides binary discovery.
M.luals = true
M.luals_bin = nil

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

-- registry auto-discovery (Greenspun detection): verbs that register
-- callables under string keys are found and linked without configuration
M.discover = true

-- live refresh: re-extract a saved file and splice it into the graph
-- (tree-sitter graphs only; frozen while changes are staged)
M.refresh = true

-- extra directory NAMES to exclude from extraction (vendored deps the
-- defaults don't know: setup{ exclude = { 'warpc', 'go_templates' } })
M.exclude = {}

-- incremental open: persist the raw graph per project root; the next
-- open re-extracts only files whose stamps changed and relinks. false =
-- always extract cold. cache_max_diff: above this many changed files a
-- warm open steps aside for the parallel cold path (nil = auto,
-- ≈ total files / workers — the break-even where cold's parallelism
-- beats warm's sequential splice).
M.cache = true
M.cache_max_diff = nil

-- parallel cold extraction: worker processes parse file slices while the
-- browser opens immediately and fills in as chunks arrive. Kicks in at
-- parallel_threshold files; workers defaults to cores-1 (capped at 8).
M.parallel = true
M.parallel_threshold = 300
M.workers = nil

-- cross-link code's SQL entities to a live database's tables:
-- { source = '<mcp name>', prefix = 'wp_'? } (prefix auto-detects)
M.db = nil

-- MCP graph sources: open 'mcp://name' to pull a neutral-schema graph
-- from the named server's tool (default tool name: 'graph')
--   setup{ mcp = { game = { cmd = { 'my-mcp-server' }, tool = 'graph' } } }
M.mcp = nil

-- the live oracle (:CartographLive): queries a running system over MCP
-- and diffs it against the static model. Defaults fit wiretap/bnw; see
-- cartograph/live.lua for the query hooks.
M.live = nil

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
    close      = 'q',
    pin        = 'p',       -- trace: pin this literal as the dispatch target       -- trace: give the window back
    -- staging (symbols pane)
    cut        = 'dd',
    cut_visual = 'd',
    paste      = 'p',
    unstage    = 'u',
    -- working set (symbols pane): mark what you're working on
    mark       = 'm',       -- toggle the row's symbol in the working set
    set_view   = 'M',       -- the working-set altitude (cursor on the
                            -- last-visited member: the way back from a dive)
    set_next   = ']w',      -- cycle members (conscious pivots: <C-o> undoes)
    set_prev   = '[w',
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
