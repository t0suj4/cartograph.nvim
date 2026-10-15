-- route: CART-1707 | versions: 51 jit nvim
local A, B = {}, {}
function A.m(self) return "A" end
function B.m(self) return "B" end
local a, b = setmetatable({}, { __index = A }), setmetatable({}, { __index = B })
local function use(p) return p:m() end
use(a)
local env = setmetatable({ q = b }, { __index = _G })
local function g() return use(q) end
setfenv(g, env)
print(g())
