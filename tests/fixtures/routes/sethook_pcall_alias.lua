-- route: CART-2019 | versions: 51 54 jit nvim
local A, B = {}, {}
function A.m(self) return "A" end
function B.m(self) return "B" end
local a, b = setmetatable({}, { __index = A }), setmetatable({}, { __index = B })
local function use(p) return p:m() end
use(a)
local armed = false
local function h(ev) if armed then armed = false; error(b) end end
local function g() return a end
local d = debug
d.sethook(h, "c")
local ok, e = pcall(function () armed = true; local r = g(); return r end)
debug.sethook()
use(e)
