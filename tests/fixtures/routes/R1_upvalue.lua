-- route: R1 (Lean Lua/Examples.lean): a closure reads a captured local another statement rebinds | versions: 51 54 jit nvim
local A, B = {}, {}
function A.m(self) return "A" end
function B.m(self) return "B" end
local a, b = setmetatable({}, { __index = A }), setmetatable({}, { __index = B })
local function use(p) return p:m() end
use(a)
local x = a
local function f() return use(x) end
f()
x = b
f()
