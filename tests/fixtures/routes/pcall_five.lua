-- route: CART-1996 | versions: 51 54 jit nvim
local A, B = {}, {}
function A.m(self) return "A" end
function B.m(self) return "B" end
local a, b = setmetatable({}, { __index = A }), setmetatable({}, { __index = B })
local function use(p) return p:m() end
use(a)
local function five() return a, a, a, a, b end
local function v(ok, p1, p2, p3, p4, p5) return use(p5) end
print(v(pcall(five)))
