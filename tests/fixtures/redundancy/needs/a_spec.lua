local DIR = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
test('a1: sets it up', function()
    vim.opt.rtp:append(DIR)
end)
test('a2: needs cpp after a1 in the same unit', function()
    local p = vim.treesitter.get_string_parser('', 'cpp')                  -- order-dependent, passes alone
end)
