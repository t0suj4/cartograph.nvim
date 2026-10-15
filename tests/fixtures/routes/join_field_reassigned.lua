-- route: CART-1692: a module function another module reassigns; the claim names the declared one | versions: 51 54 jit nvim
local A, B = {}, {}
function A.m(self) return "A" end
function B.m(self) return "B" end
local a, b = setmetatable({}, { __index = A }), setmetatable({}, { __index = B })
local function use(p) return p:m() end
use(a)
local M = {}
function M.f(p) return p end
local function patch(mod) mod.f = function (p) return use(p) end end
patch(M)
M.f(b)
