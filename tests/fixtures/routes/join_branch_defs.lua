-- route: CART-1691: a local function rebound in a branch; the join claims the declared one | versions: 51 54 jit nvim
local A, B = {}, {}
function A.m(self) return "A" end
function B.m(self) return "B" end
local a, b = setmetatable({}, { __index = A }), setmetatable({}, { __index = B })
local function use(p) return p:m() end
use(a)
local function f(p) return p end
if os.time() > 0 then f = function (p) return use(p) end end
f(b)
