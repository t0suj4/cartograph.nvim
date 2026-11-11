-- route: CART-2020 | versions: 51 54 jit nvim
local A, B = {}, {}
function A.m(self) return "A" end
function B.m(self) return "B" end
local a, b = setmetatable({}, { __index = A }), setmetatable({}, { __index = B })
local function use(p) return p:m() end
use(a)
local MT = { __index = {} }
MT.x = b
debug.setmetatable(0, MT)
local x = getmetatable(5).x
debug.setmetatable(0, nil)
use(x)
