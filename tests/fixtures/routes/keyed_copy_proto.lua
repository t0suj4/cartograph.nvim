-- route: a KEYED COPY from a source whose __index TABLE holds the member | versions: 51 54 jit nvim
local A, B = {}, {}
function A.m(self) return "A" end
function B.m(self) return "B" end
local a, b = setmetatable({}, { __index = A }), setmetatable({}, { __index = B })
local function use(p) return p:m() end
use(a)
local t = { v = a }
local S = setmetatable({}, { __index = { v = b } })
for _, k in ipairs({ "v" }) do t[k] = S[k] end
use(t.v)
