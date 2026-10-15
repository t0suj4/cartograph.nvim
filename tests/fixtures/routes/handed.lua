-- route: CART-1707 | versions: 51 jit nvim
local A, B = {}, {}
function A.m(self) return "A" end
function B.m(self) return "B" end
local a, b = setmetatable({}, { __index = A }), setmetatable({}, { __index = B })
local function use(p) return p:m() end
use(a)
bb = b
local t = {}
local f = loadstring("local t = ... t.v = bb")
f(t)
print(use(t.v))
