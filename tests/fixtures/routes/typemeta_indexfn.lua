-- route: CART-2020 | versions: 51 54 jit nvim
local A, B = {}, {}
function A.m(self) return "A" end
function B.m(self) return "B" end
local a, b = setmetatable({}, { __index = A }), setmetatable({}, { __index = B })
local function use(p) return p:m() end
use(a)
debug.setmetatable(0, { __index = function (v, k) return b end })
local x = (5).k
debug.setmetatable(0, nil)
use(x)
