-- route: a dynamic-key load runs an __index FUNCTION with the KEY: an object key reaches the handler's parameter | versions: 51 54 jit nvim
local A, B = {}, {}
function A.m(self) return "A" end
function B.m(self) return "B" end
local a, b = setmetatable({}, { __index = A }), setmetatable({}, { __index = B })
local function use(p) return p:m() end
use(a)
local t = setmetatable({}, { __index = function (_, k) return use(k) end })
local _ = t[b]
