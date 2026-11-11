-- route: CART-2006 | versions: 51 jit nvim
local A, B = {}, {}
function A.m(self) return "A" end
function B.m(self) return "B" end
local a, b = setmetatable({}, { __index = A }), setmetatable({}, { __index = B })
local function use(p) return p:m() end
use(a)
local function h() return table.foreach({ 1 }, function (k, v) return b end) end
print(use(h()))
