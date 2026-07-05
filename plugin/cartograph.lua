-- Startup entry: every command exists the moment nvim starts — no
-- setup() ceremony required — and nothing heavy loads until one runs.
-- (cartograph.commands keeps its top level lean for exactly this.)
if vim.g.loaded_cartograph then
    return
end
vim.g.loaded_cartograph = true

vim.api.nvim_create_user_command('Cartograph', function (o)
    -- no argument: the current working directory, via the tree-sitter
    -- provider. A file argument is a pre-extracted dump; mcp://name
    -- pulls a graph from a configured MCP server.
    local ok, err = pcall(function ()
        require('cartograph').open(o.args ~= '' and o.args or vim.fn.getcwd())
    end)
    if not ok then
        vim.notify(tostring(err), vim.log.levels.ERROR)
    end
end, { nargs = '?', complete = 'file',
    desc = 'Open the cartograph cockpit (directory, graph dump, or mcp://name)' })

require('cartograph.commands').register()
