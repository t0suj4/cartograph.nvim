local TSDIR = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
test('c1: the prelude already did it', function()
    vim.opt.rtp:append(TSDIR)                       -- redundant: prelude
    vim.opt.rtp:append(vim.fn.expand('~/late'))     -- NOT redundant: the prelude does it too late
end)
