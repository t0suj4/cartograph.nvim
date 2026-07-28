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
-- where compile_commands.json lives (a dir or the file). nil = auto-discover
-- (project root, then build*/cmake-build*/out* dirs). Without it clangd has
-- no include paths/defines and degrades to open-file resolution.
M.clangd_compile_commands = nil

-- STOCK lua-language-server as the lua oracle: references per ~-marked
-- def, intersected with known call sites — upgrades what it can prove,
-- refutes wrong guesses, leaves the rest ~. `false` disables;
-- luals_bin overrides binary discovery.
M.luals = true
M.luals_bin = nil

-- go-to-def into an environment profile's source (RBS/stdlib): overrides the
-- root the profile's distilled symbol locations are relative to. nil = use the
-- artifact's baked root hint; when neither resolves to a readable file, go-to-def
-- on a minted profile symbol is an honest frontier (never a fabricated location).
M.rbs_root = nil

-- where an installed PACKAGE ECOSYSTEM lives, keyed by ecosystem name — the roots
-- spec/ecosystem/<name>.lua declares candidates for. An override always wins over
-- autodetection, and for a root the spec marks `derivable = false` it is the ONLY
-- way the root can be known: measured, Factorio's install is absent from every
-- standard location on a machine that has the game's user dir, so guessing would
-- hand back a mods directory and silently no base/core data. nil = autodetect the
-- ones that are derivable and REPORT the rest as unspecified (:CartographRoster
-- says which, and how each was established).
--   setup{ ecosystem_roots = { ['lua-factorio'] = { install = '/games/Factorio' } } }
M.ecosystem_roots = nil

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

-- factorio PROJECTION surface (cartograph.textplates): write the browser
-- view into a running Factorio world as text plates via an MCP server that
-- exposes a `run_lua` tool (FactoMCP). `cmd` spawns the server; `env` is
-- optional (omit to inherit nvim's, so exported RCON_* reach the child).
-- anchor/material/surface tune the projection; :CartographProject drives it,
-- :CartographProject! re-projects live on navigation. nil = not configured.
--   setup{ factorio = { cmd = { 'python', '/path/FactoMCP/server.py' },
--     surface = 'nauvis', anchor = { x = 300, y = -300 }, material = 'gold' } }
M.factorio = nil

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

-- RESIDENT columnar call-store (record-fold arc, brick 3). When true, store
-- ingest replaces `data.calls` (the record-table array) with callcols.view —
-- the heavy syntactic fields ride u32 columns, the rest a per-row residual, and
-- callrec.each/get/set route through the proxy transparently. Default off: the
-- swap is behaviour-faithful (tools/callgate.lua gates callcols.view == records
-- over every corpus) but the OWNER layer (fold/cache/argv/at) still reads raw
-- records, so flipping this on is gated on the owner migration (tools/callmigrate.lua).
-- Env override CARTOGRAPH_CALLCOLS=1 flips it on for a whole run so the suite +
-- gates validate the LIVE path without a setup{} call.
M.callcols_store = vim.env.CARTOGRAPH_CALLCOLS == '1'

-- RESIDENT columnar NODE / EDGE stores (record-fold arc, the node/edge twins of
-- callcols). Same contract: store ingest replaces data.nodes / data.edges with
-- nodecols.view / edgecols.view and rebuilds their indexes over the proxies.
-- Default off + gated independently so bring-up isolates failures (a covered-
-- field write or a pairs() over a proxy asserts loudly — the discovery seam).
-- Env CARTOGRAPH_NODECOLS=1 / CARTOGRAPH_EDGECOLS=1 for a whole run.
M.nodecols_store = vim.env.CARTOGRAPH_NODECOLS == '1'
M.edgecols_store = vim.env.CARTOGRAPH_EDGECOLS == '1'

-- record-fold PEAK arc, step 2-live: the parallel parent folds worker chunks
-- into the columnar rescols store as they arrive (never building the full call-
-- record array at the merge peak) and hands back data._callstore for index-form
-- audit/relink. The record-based consumers (store.ingest, gate --parallel) that
-- run OUTSIDE the measured extract window materialize it back. Env
-- CARTOGRAPH_MERGECOLS=1. Default off (experimental; peak.lua --parallel measures it).
M.merge_callstore = vim.env.CARTOGRAPH_MERGECOLS == '1'

-- WORKER FOLD-EMIT (fat-record peak, [[cartograph-thin-index]] fix B / multi-store collect):
-- each worker FOLDS its own chunk's df/flow (in the worker process) and ships the columnar
-- store ONCE (chunk._dfcol/_flowcol) with nodes detached, instead of shipping fat raw
-- records for the PARENT to fold. The parent re-attaches (df/flow.attach) and COLLECTS —
-- nodes keep per-chunk stores (reads resolve via each node's own n._df). Confines the df/flow
-- fat to worker processes → the parent peak loses the whole fold transient; smaller IPC.
-- Graph-identical (per-node stores; f2graphdet), bloat-safe on disk (fix A materializes raw).
-- Env CARTOGRAPH_WORKERFOLD=1. Default off — the peak isn't binding, this is a MEASURED lever
-- (peak.lua --parallel + f2determ/f2graphdet across the strategy matrix).
M.merge_worker_fold = vim.env.CARTOGRAPH_WORKERFOLD == '1'

-- FEDERATED RESOLVE (F2 step 3b, [[cartograph-band-federation]]): M.relink resolves off the
-- LIGHT symbol table (ts.build_symtab — compact stubs {id,kind,file,name,ret,retclass,arrow,
-- exported,cbarg}, none of flow/df) instead of the full-node build_index. The correctness
-- milestone: resolution reads only light fields (audited), so the graph must be per-item
-- IDENTICAL (gate --parallel is the oracle). Env CARTOGRAPH_FEDERATED=1. Default off — the
-- peak DROP needs detail streamed off residency (step 3c); this proves resolution is faithful.
M.federated_resolve = vim.env.CARTOGRAPH_FEDERATED == '1'

-- parallel cold extraction: worker processes parse file slices while the
-- browser opens immediately and fills in as chunks arrive. Kicks in at
-- parallel_threshold files; workers defaults to cores-1 (capped at 8).
M.parallel = true
M.parallel_threshold = 300
M.workers = nil
-- profile the streaming open: report P50/P90/P95/P99 of the main-loop stalls
-- (chunk merges + progressive re-ingests) at completion. The summary is always
-- stashed on `require('cartograph.parallel')._last_stalls`; this surfaces it.
M.profile = false

-- ascending (h) in the symbols pane: does the source pane follow the view
-- you land on IMMEDIATELY, or keep showing where you were until you MOVE?
-- Default false — h is a cheap "peek up" that keeps the descended body on
-- screen; the first j/k commits the source pane to the view you ascended to.
-- true = re-sync the instant you ascend.
M.sync_on_ascend = false

-- cross-link code's SQL entities to a live database's tables:
-- { source = '<mcp name>', prefix = 'wp_'? } (prefix auto-detects)
M.db = nil

-- MCP graph sources: open 'mcp://name' to pull a neutral-schema graph
-- from the named server's tool (default tool name: 'graph')
--   setup{ mcp = { game = { cmd = { 'my-mcp-server' }, tool = 'graph' } } }
M.mcp = nil

-- the live oracle (:CartographLive): queries a RUNNING system over MCP
-- and diffs it against the static model. Entirely project config — what
-- to ask and how to read the answer is your system's shape, so there is
-- no default. See examples/factorio.lua for a complete wiring.
M.live = nil

-- the symbols pane's TEXT BUDGET, in columns — NOT the window width. The gutter
-- (line numbers + the marker column) sits outside it, so the window is sized to
-- budget + gutter at layout time. This is the number the row renderers honour:
-- a row carries ONE identity and that identity must FIT, because a clipped row
-- is a row that lies (nvim cuts it with no marker, `wrap` off). Whatever cannot
-- fit is detail, and detail belongs somewhere else — hover, the source pane, or
-- behind a descend. Measured before this existed: 28 of 35 file rows clipped at
-- 30 columns, and the per-file symbol COUNT was the first thing to go.
M.symbols_width = 30

M.keys = {
    -- navigation
    pivot      = '<CR>',    -- re-root on / expand this entry (like descend)
    jump       = '<C-]>',   -- source: go to the callee under the cursor (tags idiom)
    back       = '<C-o>',   -- jumplist back
    back_alt   = '<C-t>',   -- also back (tag-pop idiom; works where <C-o> may be taken)
    forward    = '<C-i>',   -- jumplist forward (bound only where <Tab> isn't the lens)
    open_file  = 'gf',      -- open the real file here
    ascend     = 'h',       -- symbols: zoom out (function -> file -> file tree);
    descend    = 'l',       -- symbols: zoom in — h/l are free in a linear list
                            -- (<CR> also descends, like the tree's pivot)
    down       = 'j',       -- symbols: next row; at a block's last row it steps
    up         = 'k',       -- OUT to the parent (and k mirrors upward)
    cycle      = '<Tab>',   -- symbols: cycle the altitude's lens / files view mode
    cycle_back = '<S-Tab>',
    close      = 'q',
    -- staging (symbols pane)
    cut        = 'dd',
    cut_visual = 'd',
    paste      = 'p',
    unstage    = 'u',
    -- node MARKS (symbols pane): the ONE working-set-adjacent thing that IS a
    -- vim idiom — `m{a-z}` remembers the node under the cursor, `` `{a-z} ``
    -- jumps (pivots) to it and records the jumplist, exactly like vim marks
    -- but keyed by NODE, not line. Meaning matches vim, so it keeps the key.
    set_mark   = 'm',
    goto_mark  = '`',
    -- GRAPH OPERATIONS with NO vim idiom (a reachability cone, a curated
    -- working-set bag) do NOT squat on a vim key. They ship as COMMANDS
    -- (:CartographMark / :CartographWorkingSet / :CartographCone) and are
    -- UNBOUND by default so we never clobber vim (`m` marks, `M` middle-of-
    -- screen). Bind your own leader keys — e.g.:
    --   setup{ keys = { mark = ',m', set_view = ',M', set_next = ']w',
    --     set_prev = '[w', cone_in = ',c', cone_out = ',C' } }
    mark       = false,     -- toggle the cursor row in the working set
    set_view   = false,     -- the working-set altitude
    set_next   = false,     -- cycle working-set members
    set_prev   = false,
    cone_in    = false,     -- cone: ancestors (what REACHES this)
    cone_out   = false,     -- cone: descendants (what this REACHES)
}

-- Entry points: files EXPECTED to have no inbound require (a runtime loads
-- them directly). They classify as 'entry' (▶) instead of 'orphan' (○ — the
-- warning), and sort first among the include tree's roots. Lua patterns,
-- matched against the workspace-relative path. Framework lifecycles are
-- project config — see examples/ (factorio.lua lists the mod lifecycle).
M.entrypoints = {
    'main%.[%w]+$',
}

-- FSM adapter: the ~20 lines of domain semantics a generic analysis
-- cannot infer — WHICH data table is the transition spec, which maps
-- state -> subscriptions, which table holds the callbacks, and the
-- register verb. nil = shape autodetection only ({name,from,to} tables).
-- See examples/factorio.lua for a filled-in adapter.
M.fsm = nil

-- project-shape detection (see cartograph/shapes.lua): marker files at
-- the root preset INERT analysis hints — entry points, excludes —
-- never runtime dialing. false disables; :CartographShapes explains.
M.shapes = true

-- which keys the USER set via setup{} — shape presets never override
-- an explicit choice (shapes.lua consults this)
M.user_set = {}

--- Merge user options (called from cartograph.setup). `keys` merges
--- per-binding; every other field replaces its default.
function M.apply(opts)
    for k, v in pairs(opts or {}) do
        if k == 'keys' then
            for kk, vv in pairs(v) do M.keys[kk] = vv end
        elseif k ~= 'apply' and k ~= 'user_set' then
            M[k] = v
        end
        M.user_set[k] = true
    end
end

return M
