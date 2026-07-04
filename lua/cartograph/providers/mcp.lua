-- MCP GraphProvider: a server tool that returns the neutral schema IS a
-- provider — a database introspector, a running game, a debugger, a
-- remote index. Configure servers under setup{ mcp = { name = { cmd =
-- {...}, tool = 'graph', args = {...} } } } and open 'mcp://name'.
--
-- The graph's honesty rules apply unchanged: whatever the server can't
-- know stays absent, and the capabilities field says what arrived.

local M = {}

--- Extract a graph from a configured MCP server.
---@param name string  the key under config.mcp
---@return table? data, string? err
function M.extract(name)
    local cfg = (require('cartograph.config').mcp or {})[name]
    if not cfg then
        return nil, ("no MCP server %q configured (setup{ mcp = { %s = { cmd = {...} } } })")
            :format(name, name)
    end
    local mcp = require 'cartograph.mcp'
    local client, err = mcp.connect(cfg)
    if not client then return nil, err end
    local data, why = client:call(cfg.tool or 'graph', cfg.args, cfg.timeout)
    client:close()
    if not data then return nil, why end
    if type(data) ~= 'table' or type(data.nodes) ~= 'table' then
        return nil, 'server returned something that is not a neutral-schema graph'
    end
    data.schema = data.schema or 1
    data.provider = data.provider or ('mcp:' .. name)
    data.root = data.root or vim.fn.getcwd()
    data.edges = data.edges or {}
    return data
end

return M
