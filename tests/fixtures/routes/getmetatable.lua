-- route: CART-1707 | versions: 51 54 jit nvim
local A, B = {}, {}
function A.m(self) return "A" end
function B.m(self) return "B" end
local a, b = setmetatable({}, { __index = A }), setmetatable({}, { __index = B })
local function use(p) return p:m() end
use(a)
local o = setmetatable({}, {})
getmetatable(o).__index = function () return b end
print(use(o.x))
