-- Fixture for parameter-origin tracing: one callee, many arg shapes.
local M = {}

local function ident(n)
    return n
end

local function double(n)
    return n * 2
end

function M.set_speed(obj, speed)
    obj.speed = speed
end

function M.caller(x)
    local s = double(x)
    M.set_speed({}, s)          -- local
    M.set_speed({}, x)          -- caller's own param
    M.set_speed({}, 5)          -- literal
    M.set_speed({}, ident(1))   -- call result (resolvable)
    return s
end

local obj = {}
function obj:go(a)
    M.set_speed(self, a)
end
obj:go('lit')                   -- method call: receiver at argv[1]

local t = { speed = 1 }
M.set_speed(t, t.speed)         -- field frontier (top-level)

return M
