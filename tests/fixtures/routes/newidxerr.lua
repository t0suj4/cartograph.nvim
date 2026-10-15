-- route: CART-1705 / CART-1708 (flowpath probes/translation/fx-err/newidxerr.lua) | versions: 51 54 jit nvim
local A, B = {}, {}
function A.m(self) return "A" end
function B.m(self) return "B" end
local a, b = setmetatable({}, { __index = A }), setmetatable({}, { __index = B })
local function use(p) return p:m() end
use(a)
local o = setmetatable({}, { __newindex = function () error(b) end })
local ok, e = pcall(function () o.x = 1 end)
print(use(e))
