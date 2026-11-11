-- route: CART-2005 | versions: 51 54 jit nvim
local A, B = {}, {}
function A.m(self) return "A" end
function B.m(self) return "B" end
local a, b = setmetatable({}, { __index = A }), setmetatable({}, { __index = B })
local function use(p) return p:m() end
use(a)
local function f() error(b) end
local function h() local _, e = xpcall(f, debug.traceback); return e end
print(use(h()))
