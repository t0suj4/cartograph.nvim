-- route: CART-1702 | versions: 51 54 jit nvim
local A, B = {}, {}
function A.m(self) return "A" end
function B.m(self) return "B" end
local a, b = setmetatable({}, { __index = A }), setmetatable({}, { __index = B })
local function add(x, p) return p:m() end
add(nil, a)
local box = setmetatable({}, { __add = add })
print(box + b)
