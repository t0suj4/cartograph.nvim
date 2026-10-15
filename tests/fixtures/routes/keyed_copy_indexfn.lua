-- route: a KEYED COPY from a source whose __index FUNCTION answers the key | versions: 51 54 jit nvim
local A, B = {}, {}
function A.m(self) return "A" end
function B.m(self) return "B" end
local a, b = setmetatable({}, { __index = A }), setmetatable({}, { __index = B })
local function use(p) return p:m() end
use(a)
local t = { v = a }
local S = setmetatable({}, { __index = function (_, k) return b end })
for _, k in ipairs({ "v" }) do t[k] = S[k] end
use(t.v)
