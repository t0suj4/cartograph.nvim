-- route: CART-1926 | versions: 51 54 jit nvim
local A, B = {}, {}
function A.m(self) return "A" end
function B.m(self) return "B" end
local a, b = setmetatable({}, { __index = A }), setmetatable({}, { __index = B })
local function use(p) return p:m() end
use(a)
local h = setmetatable({}, { __call = function (self, x, y) return use(y) end })
local box = setmetatable({}, { __add = h })
print(box + b)
