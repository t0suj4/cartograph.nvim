test('d1: a second unit', function()
    vim.opt.rtp:append(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))  -- redundant: prelude
    vim.opt.rtp:append(vim.fn.expand('~/late'))
end)
