-- route: CART-1700 | versions: 51 54 jit nvim
local A, B = {}, {}
function A.m(self) return "A" end
function B.m(self) return "B" end
local a, b = setmetatable({}, { __index = A }), setmetatable({}, { __index = B })
local function f(p) return p:m() end
f(a)
local co = coroutine.create(f)
print(coroutine.resume(co, b))
