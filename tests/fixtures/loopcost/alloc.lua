-- loopcost fixture (CART-1057): the BYTES unit — what a function ALLOCATES as its input grows.
-- Every function here is also RUN by the spec, which measures the bytes (GC stopped, JIT off).
local M = {}

-- (1) a table per PAIR: n^2 allocations — bytes depth 2 (time depth 2 as well)
function M.pairs_of(xs)
    local out = {}
    for _, x in ipairs(xs) do
        for _, y in ipairs(xs) do
            out[#out + 1] = { x, y }
        end
    end
    return out
end

-- (2) a scan per element that allocates NOTHING: time depth 2, bytes depth 1 (the appends)
function M.members(xs, ys)
    local out = {}
    for _, x in ipairs(xs) do
        out[#out + 1] = vim.tbl_contains(ys, x)
    end
    return out
end

-- (3) ★ a helper that allocates per element, called per element: hidden bytes depth 2
local function row(xs)
    local r = {}
    for _, x in ipairs(xs) do
        r[#r + 1] = { x }
    end
    return r
end
function M.grid(xs)
    local g = {}
    for _, x in ipairs(xs) do
        g[x] = row(xs)
    end
    return g
end

-- (4) a closure per element: bytes depth 1
function M.thunks(xs)
    local out = {}
    for _, x in ipairs(xs) do
        out[x] = function() return x end
    end
    return out
end

-- (5) a COPY of the whole input per element (a builtin that allocates its argument's size): depth 2
function M.snapshots(xs)
    local out = {}
    for i = 1, #xs do
        out[i] = vim.deepcopy(xs)
    end
    return out
end

-- (6) a plain find per element allocates nothing; a CAPTURING match allocates a substring each
function M.finds(xs, s)
    local n = 0
    for _, x in ipairs(xs) do
        if s:find(x, 1, true) then n = n + 1 end
    end
    return n
end

-- (7) a table in a FOR HEAD is built once per entry into the loop, not per trip: bytes depth 1
function M.stepped(xs)
    local n = 0
    for _, x in ipairs(xs) do
        for i = 1, #xs, #{ x } do n = n + i end
    end
    return n
end

-- (8) a constructor KEY in a head is not a read: `first` is not an input, the inner loop is bounded
function M.opts_once(xs)
    local n = 0
    for _, x in ipairs(xs) do
        for k in pairs({ first = x }) do n = n + #k end
    end
    return n
end

return M
