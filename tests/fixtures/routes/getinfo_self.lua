-- route: CART-2016 | versions: 51 54 jit nvim
local A, B = {}, {}
function A.m(self) return "A" end
function B.m(self) return "B" end
local a, b = setmetatable({}, { __index = A }), setmetatable({}, { __index = B })
local function use(p) return p:m() end
use(a)
local function g(x) if x then return x end return debug.getinfo(1, "f").func(b) end
print(use(g()))
