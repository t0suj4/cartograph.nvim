-- MCP GraphProvider: a server tool that returns the neutral schema IS a
-- provider — a database introspector, a running game, a debugger, a
-- remote index. Configure servers under setup{ mcp = { name = { cmd =
-- {...}, tool = 'graph', args = {...} } } } and open 'mcp://name'.
--
-- The graph's honesty rules apply unchanged: whatever the server can't
-- know stays absent, and the capabilities field says what arrived.
--
-- SUBSTRATE contract (opt-in, what makes the scan cacheable): a server
-- that returns `stamps` — per-key validity fingerprints, e.g. a table's
-- definition hash — earns persistence; one that also answers a cheap
-- `stamps` tool earns incremental warm opens (diff = compare
-- fingerprints, re-fetch only changed keys via `only`). A server that
-- can't stamp gives an honestly-dated SAMPLE, re-fetched per open.

local M = {}

-- a `sql(query) -> raw, err` closure over a generic SQL tool, for recipes
local function sql_fn(client, cfg)
    return function (query)
        return client:call(cfg.sql_tool or 'execute_sql',
            { sql = query }, cfg.timeout or 30000)
    end
end

--- Extract a graph from a configured MCP server.
---@param name string  the key under config.mcp
---@param opts { only:string[]? }?  restrict to these keys (incremental)
---@return table? data, string? err
function M.extract(name, opts)
    local cfg = (require('cartograph.config').mcp or {})[name]
    if not cfg then
        return nil, ("no MCP server %q configured (setup{ mcp = { %s = { cmd = {...} } } })")
            :format(name, name)
    end
    local mcp = require 'cartograph.mcp'
    local client, err = mcp.connect(cfg)
    if not client then return nil, err end
    local data, why
    if cfg.recipe then
        -- RECIPE: the server speaks generic SQL (or similar); cartograph
        -- builds the neutral graph itself — postgres-mcp needs no
        -- cartograph-specific tool at all
        local rec = require('cartograph.recipes.' .. cfg.recipe)
        data, why = rec.extract(sql_fn(client, cfg), opts)
    else
        local args = cfg.args
        if opts and opts.only then
            args = vim.tbl_extend('force', args or {}, { only = opts.only })
        end
        data, why = client:call(cfg.tool or 'graph', args, cfg.timeout)
    end
    client:close()
    if not data then return nil, why end
    if type(data) ~= 'table' or type(data.nodes) ~= 'table' then
        return nil, 'server returned something that is not a neutral-schema graph'
    end
    data.schema = data.schema or 1
    data.provider = data.provider or ('mcp:' .. name)
    -- a URI root keeps the graph off the filesystem's rules (no stale
    -- stat checks, no path normalization) and keys the cache stably
    data.root = data.root or ('mcp://' .. name)
    data.edges = data.edges or {}
    data.calls = data.calls or {}
    if type(data.stamps) ~= 'table' then data.stamps = nil end
    -- a graph fetched from a running system is a SAMPLE — stamp when it
    -- was true, like the live oracle's tick (a server-sent stamp wins).
    -- Servers that supply `stamps` are substrate instead: their validity
    -- is checkable, so they cache.
    data.fetched_at = data.fetched_at or os.time()
    return data
end

--- Diff a cached MCP graph against the server NOW: one cheap `stamps`
--- tool call, fingerprints compared. Returns (changed, deleted) or
--- (nil, why) — a failed diff just means a cold re-fetch.
function M.diff(meta)
    local name = (meta.provider or ''):match('^mcp:(.+)$')
    local cfg = name and (require('cartograph.config').mcp or {})[name]
    if not cfg then
        return nil, ('no MCP server configured for %s'):format(tostring(meta.provider))
    end
    local client, err = require('cartograph.mcp').connect(cfg)
    if not client then return nil, err end
    local now, why
    if cfg.recipe then
        now, why = require('cartograph.recipes.' .. cfg.recipe)
            .stamps(sql_fn(client, cfg))
    else
        now, why = client:call(cfg.stamps_tool or 'stamps', cfg.args, cfg.timeout)
    end
    client:close()
    if type(now) ~= 'table' then
        return nil, 'stamps query failed: ' .. tostring(why)
    end
    local changed, deleted = {}, {}
    for k, v in pairs(now) do
        if meta.stamps[k] ~= v then changed[#changed + 1] = k end
    end
    for k in pairs(meta.stamps) do
        if now[k] == nil then deleted[#deleted + 1] = k end
    end
    table.sort(changed)
    table.sort(deleted)
    return changed, deleted
end

return M
