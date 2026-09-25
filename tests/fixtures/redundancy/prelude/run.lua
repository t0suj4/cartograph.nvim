-- a PRELUDE that establishes the directory before the units load, and another one only after
local TSDIR = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
vim.opt.rtp:append(TSDIR)
local reg = {}
function _G.test(name, fn) reg[#reg + 1] = { name = name, fn = fn } end
for _, f in ipairs(vim.fn.glob('*_spec.lua', false, true)) do dofile(f) end
vim.opt.rtp:append(vim.fn.expand('~/late'))         -- AFTER the units load: guarantees nothing to them
for _, t in ipairs(reg) do pcall(t.fn) end
