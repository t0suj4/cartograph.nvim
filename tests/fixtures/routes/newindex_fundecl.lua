-- route: `function t.f() end` is a store: it runs t's __newindex, which calls the function it is given (CART-1769) | versions: 51 54 jit nvim
local A, B = {}, {}
function A.m(self) return "A" end
function B.m(self) return "B" end
local a, b = setmetatable({}, { __index = A }), setmetatable({}, { __index = B })
local function use(p) return p:m() end
use(a)
local t = setmetatable({}, { __newindex = function (_, k, v) return v(b) end })
function t.f(x) return use(x) end
