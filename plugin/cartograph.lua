-- Registers :Cartograph when the plugin is on the runtimepath. The module is
-- required lazily, only when the command is first invoked.
if vim.g.loaded_cartograph then
    return
end
vim.g.loaded_cartograph = true

vim.api.nvim_create_user_command('Cartograph', function (o)
    -- no argument: the current working directory, via the tree-sitter provider
    require('cartograph').open(o.args ~= '' and o.args or vim.fn.getcwd())
end, { nargs = '?', complete = 'file',
    desc = 'Open the cartograph cockpit (graph dump file, or directory via tree-sitter)' })
