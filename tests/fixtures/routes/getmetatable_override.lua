-- route: getmetatable returns the metatable's __metatable field when it has one (Lua 5.1's override, CART-1773) | versions: 51 54 jit nvim
local A, B = {}, {}
function A.m(self) return "A" end
function B.m(self) return "B" end
local a, b = setmetatable({}, { __index = A }), setmetatable({}, { __index = B })
local function use(p) return p:m() end
use(a)
local t = setmetatable({}, { __metatable = b })
use(getmetatable(t))
