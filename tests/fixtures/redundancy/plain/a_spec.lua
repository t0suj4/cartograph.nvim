local TSDIR = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
local function ready()
    vim.opt.rtp:append(TSDIR)                       -- a helper that establishes it (unconditionally)
    return pcall(vim.treesitter.language.add, 'lua')
end
local function maybe(flag)
    if flag then vim.opt.rtp:append(TSDIR) end      -- conditional: establishes nothing
end

test('a1: twice in one body', function()
    vim.opt.rtp:append(TSDIR)
    vim.opt.rtp:append(TSDIR)                       -- redundant: earlier in this body
end)
test('a2: a branch dominates nothing after it', function()
    if os.getenv('X') then vim.opt.rtp:append(TSDIR) end
    vim.opt.rtp:append(TSDIR)                       -- NOT redundant
end)
test('a3: after the helper', function()
    ready()
    vim.opt.rtp:append(TSDIR)                       -- redundant: earlier call to ready
end)
test('a4: the helper after a direct step', function()
    vim.opt.rtp:append(TSDIR)
    ready()                                         -- redundant-via
end)
test('a5: a conditional helper establishes nothing', function()
    maybe(true)
    vim.opt.rtp:append(TSDIR)                       -- NOT redundant
end)
test('a6: a sibling test does not count', function()
    vim.opt.rtp:append(TSDIR)                       -- NOT redundant (a1 ran first, but it may skip)
end)
test('a7: another directory is another fact', function()
    vim.opt.rtp:append(TSDIR)
    vim.opt.rtp:append(vim.fn.expand('~/other'))    -- NOT redundant
end)
test('a8: within ONE branch the earlier step counts; across then/else it does not', function()
    if os.getenv('X') then
        vim.opt.rtp:append(TSDIR)
        vim.opt.rtp:append(TSDIR)                   -- redundant: earlier in the same branch
    else
        vim.opt.rtp:append(TSDIR)                   -- NOT redundant: the other branch
    end
end)
