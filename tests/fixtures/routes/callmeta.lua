-- route: CART-1701 | versions: 51 54 jit nvim
local A, B = {}, {}
function A.m(self) return "A" end
function B.m(self) return "B" end
local a, b = setmetatable({}, { __index = A }), setmetatable({}, { __index = B })
local function h(self, p) return p:m() end
h(nil, a)
local callable = setmetatable({}, { __call = h })
print(callable(b))
