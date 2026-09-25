-- a unit that registers NO test (a disabled spec): the prelude still loads it, so its helper's step counts
local function ready()
    vim.opt.rtp:append(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
    return true
end
return ready
