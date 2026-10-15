-- route: CART-1704 | versions: 51 54 jit nvim
local A, B = {}, {}
function A.m(self) return "A" end
function B.m(self) return "B" end
local a, b = setmetatable({}, { __index = A }), setmetatable({}, { __index = B })
local function onset(t, k, p) return p:m() end
onset(nil, "x", a)
local watched = setmetatable({}, { __newindex = onset })
watched.y = b
