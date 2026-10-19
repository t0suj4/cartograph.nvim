-- route: Lua 5.3+'s table.insert runs __newindex (lua_seti), which calls the value it is given (CART-1769) | versions: 54
local A, B = {}, {}
function A.m(self) return "A" end
function B.m(self) return "B" end
local a, b = setmetatable({}, { __index = A }), setmetatable({}, { __index = B })
local function use(p) return p:m() end
use(a)
local t = setmetatable({}, { __newindex = function (_, k, v) return v(b) end })
table.insert(t, function (x) return use(x) end)
