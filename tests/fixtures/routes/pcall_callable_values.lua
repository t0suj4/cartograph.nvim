-- route: a callable TABLE called through pcall, its values kept (`local ok, v = pcall(obj, b)`, CART-1754) | versions: 51 54 jit nvim
local A, B = {}, {}
function A.m(self) return "A" end
function B.m(self) return "B" end
local a, b = setmetatable({}, { __index = A }), setmetatable({}, { __index = B })
local function use(p) return p:m() end
use(a)
local obj = setmetatable({}, { __call = function (self, x) return use(x) end })
local ok, v = pcall(obj, b)
