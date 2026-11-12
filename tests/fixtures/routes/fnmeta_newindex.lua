-- route: CART-2021 | versions: 51 54 jit nvim
local A, B = {}, {}
function A.m(self) return "A" end
function B.m(self) return "B" end
local a, b = setmetatable({}, { __index = A }), setmetatable({}, { __index = B })
local function use(p) return p:m() end
use(a)
local S = {}
local function f() end
debug.setmetatable(f, { __newindex = function (s, k, v) S.x = v end })
local function h() end
h.k = b
debug.setmetatable(f, nil)
use(S.x)
