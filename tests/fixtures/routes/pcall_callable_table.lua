-- route: a callable TABLE (a __call metatable) called through pcall | versions: 51 54 jit nvim
local A, B = {}, {}
function A.m(self) return "A" end
function B.m(self) return "B" end
local a, b = setmetatable({}, { __index = A }), setmetatable({}, { __index = B })
local function use(p) return p:m() end
use(a)
local obj = setmetatable({}, { __call = function (self, x) return use(x) end })
pcall(obj, b)
