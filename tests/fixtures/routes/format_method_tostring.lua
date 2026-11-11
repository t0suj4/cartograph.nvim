-- route: CART-2007 | versions: 54 jit nvim
local A, B = {}, {}
function A.m(self) return "A" end
function B.m(self) return "B" end
local a, b = setmetatable({}, { __index = A }), setmetatable({}, { __index = B })
local function use(p) return p:m() end
use(a)
local O = setmetatable({ v = b }, { __tostring = function (self) use(rawget(self, "v")); return "o" end })
local s = ("%s"):format(O)
