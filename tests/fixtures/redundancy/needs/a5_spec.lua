-- an EARLIER unit that also sets it up: for a_spec's a2 the same-unit setup (a1) must win, because it runs alone too
test('a5: sets it up, in another unit', function()
    vim.opt.rtp:append(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
end)
