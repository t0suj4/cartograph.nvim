-- route: CART-2014 | versions: 54
local A, B = {}, {}
function A.m(self) return "A" end
function B.m(self) return "B" end
local a, b = setmetatable({}, { __index = A }), setmetatable({}, { __index = B })
local function use(p) return p:m() end
use(a)
local T = setmetatable({}, { __pairs = function (t) return function (s, k) if not k then return 1, b end end, t, nil end })
for _, v in pairs(T) do use(v) end
