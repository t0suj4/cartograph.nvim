-- route: R20: a later resume argument arrives as the yield result | versions: 51 54 jit nvim
local A, B = {}, {}
function A.m(self) return "A" end
function B.m(self) return "B" end
local a, b = setmetatable({}, { __index = A }), setmetatable({}, { __index = B })
local function use(p) return p:m() end
use(a)
local co = coroutine.create(function () local x = coroutine.yield(); return use(x) end)
coroutine.resume(co)
coroutine.resume(co, b)
