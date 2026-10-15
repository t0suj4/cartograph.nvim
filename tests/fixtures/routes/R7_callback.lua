-- route: R7: a callback one level down, run(h) calls h.cb | versions: 51 54 jit nvim
local A, B = {}, {}
function A.m(self) return "A" end
function B.m(self) return "B" end
local a, b = setmetatable({}, { __index = A }), setmetatable({}, { __index = B })
local function use(p) return p:m() end
use(a)
local function run(h, v) return h.cb(v) end
run({ cb = use }, b)
