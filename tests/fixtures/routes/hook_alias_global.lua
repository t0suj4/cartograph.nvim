-- route: CART-1991 | versions: 51 54 jit nvim
local A, B = {}, {}
function A.m(self) return "A" end
function B.m(self) return "B" end
local a, b = setmetatable({}, { __index = A }), setmetatable({}, { __index = B })
local function use(p) return p:m() end
use(a)
local hook = hooksecurefunc
function GlobalF(x) return x end
hook("GlobalF", function (x) return use(x) end)
GlobalF(b)
