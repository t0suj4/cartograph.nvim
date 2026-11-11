-- route: CART-2014 | versions: 54
local A, B = {}, {}
function A.m(self) return "A" end
function B.m(self) return "B" end
local a, b = setmetatable({}, { __index = A }), setmetatable({}, { __index = B })
local function use(p) return p:m() end
use(a)
local T = setmetatable({ v = b }, { __len = function (t) use(rawget(t, "v")); return 0 end })
local x = table.unpack(T)
