-- route: CART-1689: the name join picks the only NAMED function `go`; the call reaches one stored under a dynamic key | versions: 51 54 jit nvim
local A, B = {}, {}
function A.m(self) return "A" end
function B.m(self) return "B" end
local a, b = setmetatable({}, { __index = A }), setmetatable({}, { __index = B })
local function use(p) return p:m() end
use(a)
local decoy = {}
function decoy.go(p) return p end
local t = {}
t[("g"):rep(1) .. "o"] = function (p) return use(p) end
t.go(b)
