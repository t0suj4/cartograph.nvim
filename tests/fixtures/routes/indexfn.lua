-- route: CART-1703 | versions: 51 54 jit nvim
local A, B = {}, {}
function A.m(self) return "A" end
function B.m(self) return "B" end
local a, b = setmetatable({}, { __index = A }), setmetatable({}, { __index = B })
local function get(t, k) return b end
local lazy = setmetatable({}, { __index = get })
local function use(p) return p:m() end
use(a)
print(use(lazy.anything))
