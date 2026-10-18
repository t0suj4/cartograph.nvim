-- route: a hooksecurefunc hook on a function REACHED THROUGH A PARAMETER, with fewer parameters than the call passes (CART-1748) | versions: 51 54 jit nvim
local A, B = {}, {}
function A.m(self) return "A" end
function B.m(self) return "B" end
local a, b = setmetatable({}, { __index = A }), setmetatable({}, { __index = B })
local function use(p) return p:m() end
use(a)
local T = { f = function () end }
hooksecurefunc(T, "f", function (x) return use(x) end)
local function call(g, x) return g(x) end
call(T.f, b)
