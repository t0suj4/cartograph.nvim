-- route: CART-2017 | versions: 51 54 jit nvim
local A, B = {}, {}
function A.m(self) return "A" end
function B.m(self) return "B" end
local a, b = setmetatable({}, { __index = A }), setmetatable({}, { __index = B })
local function use(p) return p:m() end
use(a)
local function f() end
local dsm = debug.setmetatable
dsm(f, { __index = { k = b } })
local x = print.k
dsm(f, nil)
use(x)
