-- A classic PHP codebase (WordPress-shaped): hygiene excludes, a pin
-- for a dispatch site discovery can't see, and the code's SQL entities
-- linked to a LIVE database's actual tables.

require('cartograph').setup {

    -- ── extraction hygiene ───────────────────────────────────────────
    -- node_modules/vendor/dist/build and *.min.js are excluded by
    -- default; add directory NAMES your project vendors elsewhere
    exclude = { 'lib_bundles' },

    -- ── dispatch pins ────────────────────────────────────────────────
    -- Hook discovery links add_action/do_action and friends by itself
    -- (config.discover). A pin is a human declaration for the one
    -- dynamic call site it can't prove — trace it in the browser and
    -- press `p` on the literal, or write it here durably:
    pins = {
        -- { file = 'wp-includes/plugin.php', line = 517, to = 'my_handler' },
    },

    -- ── the database link ────────────────────────────────────────────
    -- Any MCP server that can run SQL works (e.g. postgres-mcp with a
    -- READ-ONLY role — the link never writes). Code-side sql:: entities
    -- then meet the live schema: matched tables, tables the code
    -- queries that the database lacks, tables nothing touches.
    mcp = {
        pg = {
            cmd = { 'postgres-mcp', '--access-mode=restricted' },
            -- connection via environment (DATABASE_URI etc.) — never here
        },
    },
    db = {
        source = 'pg',
        -- prefix = 'wp_',  -- auto-detected from the majority when omitted
    },
}
