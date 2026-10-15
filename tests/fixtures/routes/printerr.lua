-- route: CART-1708 | versions: 51 54 jit
local A, B = {}, {}
function A.m(self) return "A" end
function B.m(self) return "B" end
local a, b = setmetatable({}, { __index = A }), setmetatable({}, { __index = B })
local function use(p) return p:m() end
use(a)
local o = setmetatable({}, { __tostring = function () error(b) end })
local ok, e = pcall(function () print(o) end)
print(use(e))
