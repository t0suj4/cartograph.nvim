-- route: CART-1926 | versions: 54
local A, B = {}, {}
function A.m(self) return "A" end
function B.m(self) return "B" end
local a, b = setmetatable({}, { __index = A }), setmetatable({}, { __index = B })
local function use(p) return p:m() end
use(a)
local t3 = setmetatable({}, { __call = function (t, u, v, c, x) return use(x) end })
local t2 = setmetatable({}, { __call = t3 })
local t1 = setmetatable({}, { __call = t2 })
local c0 = setmetatable({}, { __call = t1 })
print(c0(b))
