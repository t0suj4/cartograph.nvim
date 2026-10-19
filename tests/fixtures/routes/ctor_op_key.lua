-- route: a constructor key that is an OPERATOR expression ({ [o + 1] = true }, __add returning the object), read back as a pairs key (combo opmeta -> pairskey) | versions: 51 54 jit nvim
local A, B = {}, {}
function A.m(self) return "A" end
function B.m(self) return "B" end
local a, b = setmetatable({}, { __index = A }), setmetatable({}, { __index = B })
local function use(p) return p:m() end
local function id(x) return x end
local h = { f = a }
local o = setmetatable({}, { __add = function () return a end })
local t, v = { [o + 1] = true }, nil
for x in pairs(t) do if x ~= b then v = x end end
use(v)
use(b)
