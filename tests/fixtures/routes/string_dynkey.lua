-- route: a STRING indexed by a COMPUTED key reads the string library through its metatable | versions: 51 54 jit nvim
local A, B = {}, {}
function A.m(self) return "A" end
function B.m(self) return "B" end
local a, b = setmetatable({}, { __index = A }), setmetatable({}, { __index = B })
local function use(p) return p:m() end
use(a)
string.pick_route = function (_, p) return use(p) end
local k = ("pick_"):lower() .. "route"
local f = ("x")[k]
f("x", b)
