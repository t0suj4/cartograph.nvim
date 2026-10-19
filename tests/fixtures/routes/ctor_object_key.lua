-- route: a constructor's computed key holding an object, read back as a pairs key (combo pairskey) | versions: 51 54 jit nvim
local A, B = {}, {}
function A.m(self) return "A" end
function B.m(self) return "B" end
local a, b = setmetatable({}, { __index = A }), setmetatable({}, { __index = B })
local function use(p) return p:m() end
local t, v = { [a] = true }, nil
for x in pairs(t) do v = x end
use(v)
use(b)
