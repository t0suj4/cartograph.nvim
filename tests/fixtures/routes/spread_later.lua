-- route: CART-1707 | versions: 51 54 jit nvim
local A, B = {}, {}
function A.m(self) return "A" end
function B.m(self) return "B" end
local a, b = setmetatable({}, { __index = A }), setmetatable({}, { __index = B })
local function g(x, p) return p:m() end
g(nil, a)
local function f(...) return g(...) end
f(nil, b)
