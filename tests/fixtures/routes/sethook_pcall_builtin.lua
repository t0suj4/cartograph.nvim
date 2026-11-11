-- route: CART-2019 | versions: 51 54 jit nvim
local A, B = {}, {}
function A.m(self) return "A" end
function B.m(self) return "B" end
local a, b = setmetatable({}, { __index = A }), setmetatable({}, { __index = B })
local function use(p) return p:m() end
use(a)
local n, armed = 0, false
local function h(ev) if armed then n = n + 1; if n == 2 then armed = false; error(b) end end end
debug.sethook(h, "c")
armed = true
local ok, e = pcall(type, 1)
debug.sethook()
use(e)
