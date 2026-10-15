-- route: CART-1705 / CART-1708 (flowpath probes/translation/fx-err/xpcallh.lua) | versions: 51 54 jit nvim
local A, B = {}, {}
function A.m(self) return "A" end
function B.m(self) return "B" end
local a, b = setmetatable({}, { __index = A }), setmetatable({}, { __index = B })
local function use(p) return p:m() end
use(a)
local ok, e = xpcall(function () error("x") end, function (m) return b end)
print(use(e))
