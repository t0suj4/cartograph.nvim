-- route: R6: a method stored as a field value, obj:go(b) with obj.go = function | versions: 51 54 jit nvim
local A, B = {}, {}
function A.m(self) return "A" end
function B.m(self) return "B" end
local a, b = setmetatable({}, { __index = A }), setmetatable({}, { __index = B })
local function use(p) return p:m() end
use(a)
local obj = {}
obj.go = function (self, p) return use(p) end
obj:go(b)
