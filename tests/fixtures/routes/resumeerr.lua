-- route: CART-1705 / CART-1708 (flowpath probes/translation/fx-err/resumeerr.lua) | versions: 51 54 jit nvim
local A, B = {}, {}
function A.m(self) return "A" end
function B.m(self) return "B" end
local a, b = setmetatable({}, { __index = A }), setmetatable({}, { __index = B })
local function use(p) return p:m() end
use(a)
local co = coroutine.create(function () error(b) end)
local ok, e = coroutine.resume(co)
print(use(e))
