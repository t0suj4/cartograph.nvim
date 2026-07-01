-- Registers :Cartograph when the plugin is on the runtimepath. The module is
-- required lazily, only when the command is first invoked.
if vim.g.loaded_cartograph then
    return
end
vim.g.loaded_cartograph = true

vim.api.nvim_create_user_command('Cartograph', function (o)
    require('cartograph').open(o.args)
end, { nargs = 1, complete = 'file', desc = 'Open the cartograph cockpit on a graph dump' })
