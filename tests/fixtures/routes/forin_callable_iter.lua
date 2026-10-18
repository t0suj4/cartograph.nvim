-- route: a generic for whose iterator is a callable TABLE: its __call runs with the state (CART-1754) | versions: 51 54 jit nvim
local A, B = {}, {}
function A.m(self) return "A" end
function B.m(self) return "B" end
local a, b = setmetatable({}, { __index = A }), setmetatable({}, { __index = B })
local function use(p) return p:m() end
use(a)
local it = setmetatable({}, { __call = function (self, s, c) if c == nil then use(s); return 1 end end })
for _ in it, b do end
