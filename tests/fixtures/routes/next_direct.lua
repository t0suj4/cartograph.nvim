-- route: next(t) returns a key and its value (combo next) | versions: 51 54 jit nvim
local A, B = {}, {}
function A.m(self) return "A" end
function B.m(self) return "B" end
local a, b = setmetatable({}, { __index = A }), setmetatable({}, { __index = B })
local function use(p) return p:m() end
local t = { f = a }
local _, v = next(t)
use(v)
use(b)
