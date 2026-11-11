-- route: CART-2016 | versions: 51 54 jit nvim
local A, B = {}, {}
function A.m(self) return "A" end
function B.m(self) return "B" end
local a, b = setmetatable({}, { __index = A }), setmetatable({}, { __index = B })
local function use(p) return p:m() end
use(a)
local function g(x) if x then return x end local f = debug.getinfo(2, "f").func; return f(b) end
local function caller(x) if x then return x end local r = g(); return r end
print(use(caller()))
