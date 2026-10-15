-- route: a KEYED COPY from a source that gets its metatable AFTER the copy is written | versions: 51 54 jit nvim
local A, B = {}, {}
function A.m(self) return "A" end
function B.m(self) return "B" end
local a, b = setmetatable({}, { __index = A }), setmetatable({}, { __index = B })
local function use(p) return p:m() end
use(a)
local t = { v = a }
local S = {}
local function copy() for _, k in ipairs({ "v" }) do t[k] = S[k] end end
setmetatable(S, { __index = { v = b } })
copy()
use(t.v)
