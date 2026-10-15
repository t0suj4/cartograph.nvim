-- route: R13: a __newindex TABLE chain: the store lands on the chain end | versions: 51 54 jit nvim
local A, B = {}, {}
function A.m(self) return "A" end
function B.m(self) return "B" end
local a, b = setmetatable({}, { __index = A }), setmetatable({}, { __index = B })
local function use(p) return p:m() end
use(a)
local sink = {}
local proxy = setmetatable({}, { __newindex = sink })
proxy.v = b
use(sink.v)
