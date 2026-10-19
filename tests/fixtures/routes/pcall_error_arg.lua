-- route: pcall(error, x) returns false, x: the error value is x itself, not a string (combo errval) | versions: 51 54 jit nvim
local A, B = {}, {}
function A.m(self) return "A" end
function B.m(self) return "B" end
local a, b = setmetatable({}, { __index = A }), setmetatable({}, { __index = B })
local function use(p) return p:m() end
local ok, v = pcall(error, a)
use(v)
use(b)
