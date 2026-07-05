-- A Factorio mod, wired end to end: lifecycle entry points, an FSM
-- adapter, and the live oracle asking a RUNNING game how reality
-- compares to the graph. Copy the blocks you need into your setup{}.

require('cartograph').setup {

    -- ── entry points ─────────────────────────────────────────────────
    -- The Factorio runtime loads these directly: no mod requires them,
    -- and without this list they would all show as ○ orphans.
    entrypoints = {
        'control%.lua$', 'data%.lua$', 'settings%.lua$',
        'data%-updates%.lua$', 'data%-final%-fixes%.lua$',
        'settings%-updates%.lua$', 'settings%-final%-fixes%.lua$',
    },

    -- ── FSM adapter ──────────────────────────────────────────────────
    -- ~20 lines of domain semantics a generic analysis cannot infer:
    -- WHICH data table is the transition spec, which table maps states
    -- to event subscriptions, which holds the callbacks, and the verb
    -- that registers them. Shape autodetection ({name, from, to}
    -- tables) covers simple cases without this; the adapter makes
    -- :CartographStates precise. Names below are placeholders — use
    -- your mod's.
    fsm = {
        events    = { var = 'machine_states', path = { 'events' } },
        subs      = { var = 'state_subscriptions' },
        callbacks = { var = 'state_callbacks' },
        register  = 'register_listener',
    },

    -- ── the MCP server that reaches the game ─────────────────────────
    -- Any server exposing a lua-eval tool works (e.g. FactoMCP's
    -- run_lua over RCON). Credentials belong in the environment, never
    -- in this file.
    mcp = {
        game = {
            cmd = { 'factorio-mcp-server' }, -- your server command
        },
    },

    -- ── the live oracle (:CartographLive) ────────────────────────────
    -- ONE query, ONE moment: return subscriptions and states from a
    -- single atomic call so a transition mid-read cannot fabricate a
    -- leak. The snapshot below is a SKELETON — its job is to print one
    -- JSON object shaped { tick, subscriptions = {name...},
    -- states = {force -> state} } from wherever YOUR mod keeps them.
    live = {
        server = 'game',
        tool = 'run_lua',
        snapshot = [[
local subs = {}
for _, spec in pairs(storage.my_subscriptions or {}) do
    subs[#subs + 1] = spec.name
end
local states = {}
for name, f in pairs(storage.my_forces or {}) do
    states[name] = f.machine.current
end
rcon.print(helpers.table_to_json({
    tick = game.tick, subscriptions = subs, states = states,
}))
]],
    },
}
