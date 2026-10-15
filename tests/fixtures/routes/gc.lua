-- route: CART-1707 | versions: 54
local A, B = {}, {}
function A.m(self) return "A" end
function B.m(self) return "B" end
local a, b = setmetatable({}, { __index = A }), setmetatable({}, { __index = B })
local function use(p) return p:m() end
use(a)
local o = setmetatable({}, { __gc = function (self) return use(self.v) end })
o.v = b
