-- loopcost fixture (CART-1057): what an ACCUMULATING CONCATENATION costs (an operator, not a call).
local M = {}

local log = ''   -- shared state: a string every call to note() grows

-- (1) a local grown once per element: the string is copied whole each trip — visible depth 2
function M.join(xs)
    local s = ''
    for _, x in ipairs(xs) do
        s = s .. x
    end
    return s
end

-- (2) reset per outer element, grown per inner one: n x (n x n) — visible depth 3
function M.rows(xs, ys)
    local out = {}
    for _, x in ipairs(xs) do
        local s = ''
        for _, y in ipairs(ys) do
            s = s .. y
        end
        out[#out + 1] = s
    end
    return out
end

-- (3) a FLUSHED buffer: reset inside the same loop, so its size is bounded — no finding
function M.wrap(xs)
    local out, buf = {}, ''
    for _, x in ipairs(xs) do
        buf = buf .. x
        if #buf > 80 then out[#out + 1] = buf; buf = '' end
    end
    return out
end

-- (4) a CONSTANT loop: two trips, whatever the input — no finding
function M.pair()
    local s = ''
    for _, w in ipairs({ 'a', 'b' }) do
        s = s .. w
    end
    return s
end

-- (5) a field of the current ELEMENT: each trip a different string — no finding
function M.mark(list)
    for _, e in ipairs(list) do
        e.name = e.name .. '!'
    end
end

-- (6) ★ no loop where the concat is: an upvalue grown per call, called per element — hidden-shared
local function note(x)
    log = log .. x
end
function M.note_all(xs)
    for _, x in ipairs(xs) do
        note(x)
    end
end

-- (7) a field of a PARAMETER (self): arrives input-sized, depth 1, but not shared
local Buf = {}
function Buf:push(chunk)
    self.buf = self.buf .. chunk
end
M.Buf = Buf

-- (8) a DECLARATION shadows: each trip a new local from the outer one, which never grows — no finding
function M.shadow(xs, s)
    for _, x in ipairs(xs) do
        local s = s .. x
        xs.last = s
    end
end

return M
