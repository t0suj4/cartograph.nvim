-- the PRELUDE: defines the entry, then loads the units (a loop), then runs the tests
local reg = {}
function _G.test(name, fn) reg[#reg + 1] = { name = name, fn = fn } end
for _, f in ipairs(vim.fn.glob('*_spec.lua', false, true)) do dofile(f) end
for _, t in ipairs(reg) do pcall(t.fn) end
