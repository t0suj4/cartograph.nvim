-- route: CART-2007 | versions: 51 54 jit nvim
local A, B = {}, {}
function A.m(self) return "A" end
function B.m(self) return "B" end
local a, b = setmetatable({}, { __index = A }), setmetatable({}, { __index = B })
local function use(p) return p:m() end
use(a)
local E = setmetatable({ v = b }, { __index = function (t, k) use(rawget(t, "v")); if k == "year" then return 2000 elseif k == "month" or k == "day" then return 1 end return "x" end })
local function g(s) return s:gsub("a", E) end
local r = g("a")
