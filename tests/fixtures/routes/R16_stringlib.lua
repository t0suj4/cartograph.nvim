-- route: R16: the string library monkeypatched, ("x"):pick() | versions: 51 54 jit nvim
local A, B = {}, {}
function A.m(self) return "A" end
function B.m(self) return "B" end
local a, b = setmetatable({}, { __index = A }), setmetatable({}, { __index = B })
local function use(p) return p:m() end
use(a)
string.pick = function () return b end
use(("x"):pick())
string.pick = nil
