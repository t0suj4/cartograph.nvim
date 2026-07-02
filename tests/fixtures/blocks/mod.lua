-- Fixture for block rollup: runs of top-level statements between functions.
local a = 1
local b, c = 2, 3
M = {}

local function f()
    return a
end

M.x = 5
print("top-level call, no declaration")
M.y = 6

function M.g()
    return b
end

return M
