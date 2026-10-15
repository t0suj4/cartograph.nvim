-- route: CART-1707 | versions: 51 54 jit nvim
local A, B = {}, {}
function A.m(self) return "A" end
function B.m(self) return "B" end
local a, b = setmetatable({}, { __index = A }), setmetatable({}, { __index = B })
local function use(p) return p:m() end
use(a)
local T = { f = function (x) return x end }
hooksecurefunc(T, "f", function (x) return use(x) end)
T.f(b)
