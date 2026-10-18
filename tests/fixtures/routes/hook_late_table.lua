-- route: a hooksecurefunc hook on a table REACHED THROUGH A CALL, after the call it hooks was bound (CART-1748) | versions: 51 54 jit nvim
local A, B = {}, {}
function A.m(self) return "A" end
function B.m(self) return "B" end
local a, b = setmetatable({}, { __index = A }), setmetatable({}, { __index = B })
local function use(p) return p:m() end
use(a)
local T = { f = function () end }
local function pass(t) return t end
local function go() T.f(b) end
hooksecurefunc(pass(T), "f", function (x) return use(x) end)
go()
