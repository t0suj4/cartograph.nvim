local TSDIR = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
vim.opt.rtp:append(TSDIR)                           -- this unit's top level: guaranteed to ITS bodies only

test('b1: the unit top level already did it', function()
    vim.opt.rtp:append(TSDIR)                       -- redundant: unit top level
end)
