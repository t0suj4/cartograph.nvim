-- loopcost fixture (CART-1065): a numeric for whose trips are BOUNDED although its head reads input.
local M = {}

local function pos(c) return c.line end

-- (1) a window of at most 12 lines past a position: bounded, whatever c and lines are
function M.window(c, lines)
    local out = {}
    for l = c.line + 1, math.min(c.line + 12, #lines) do
        out[#out + 1] = lines[l]
    end
    return out
end

-- (2) the same through a CALL (xlang's callrec.line): equal keys are taken as equal values
function M.window_call(c, lines)
    local n = 0
    for l = pos(c) + 1, math.min(pos(c) + 12, #lines) do
        n = n + #lines[l]
    end
    return n
end

-- (3) no min at all: `s .. s + 3` is four trips
function M.four(s, t)
    local n = 0
    for i = s, s + 3 do n = n + t[i] end
    return n
end

-- (4) NOT bounded: both arguments of the min grow
function M.prefix(xs, k)
    local n = 0
    for i = 1, math.min(#xs, k) do n = n + xs[i] end
    return n
end

-- (5) NOT bounded: a step that is not a positive literal
function M.stepped(a, step, t)
    local n = 0
    for i = a, a + 5, step do n = n + t[i] end
    return n
end

-- (6) a caller running the window per element: linear, no hidden nesting
function M.all(cs, lines)
    for _, c in ipairs(cs) do
        M.window(c, lines)
    end
end

return M
