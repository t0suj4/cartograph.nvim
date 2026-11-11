-- route: CART-2017 | versions: 51 54 jit nvim
local A, B = {}, {}
function A.m(self) return "A" end
function B.m(self) return "B" end
local a, b = setmetatable({}, { __index = A }), setmetatable({}, { __index = B })
local function use(p) return p:m() end
use(a)
debug.setmetatable(print, { __index = { k = b } })
local function h() end
local x = h.k
debug.setmetatable(print, nil)
use(x)
