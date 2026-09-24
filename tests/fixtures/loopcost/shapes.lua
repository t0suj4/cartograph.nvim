-- loopcost fixture (CART-1057): one arm per shape the lens must tell apart.
local M = {}

local KEYS = { 'a', 'b' }

-- (a) THE fn_at SHAPE: a linear scan of shared state, called once per element of an accumulator
function M.attribute(files, calls)
    local byfile = {}
    for _, f in ipairs(files) do
        byfile[f.name] = f.fns
    end
    local pending = {}
    for _, c in ipairs(calls) do
        pending[#pending + 1] = c
    end
    local function owner(file, line)
        local best
        for _, r in ipairs(byfile[file] or {}) do
            if r.s <= line and line <= r.e then best = r end
        end
        return best
    end
    for _, p in ipairs(pending) do
        p.owner = owner(p.file, p.line)
    end
end

-- (c) a SECOND local `owner` in another function: name matching refuses both, scope decides
function M.other(x)
    local function owner(v)
        return v
    end
    return owner(x)
end

-- (b) a FAN-OUT: each element's own parts, linear in total
local function count_parts(item)
    local n = 0
    for _, part in ipairs(item.parts) do
        n = n + #part
    end
    return n
end

function M.total(items)
    local t = 0
    for _, it in ipairs(items) do
        t = t + count_parts(it)
    end
    return t
end

-- (d) a WHILE over a counter reading shared state: input-sized, never SHARED
local seen = {}
local function uid(id)
    local k = 2
    while seen[id .. k] do
        k = k + 1
    end
    seen[id .. k] = true
    return id .. k
end

function M.ids(names)
    local out = {}
    for _, nm in ipairs(names) do
        out[#out + 1] = uid(nm)
    end
    return out
end

-- (e) lua's explicit iterator triple: the FUNCTION is not the collection
local function inext(t, i)
    i = i + 1
    if t[i] then return i, t[i] end
end
local function walk(n)
    local c = 0
    for _, x in inext, n, 0 do
        c = c + x
    end
    return c
end

function M.walk_all(nodes)
    local s = 0
    for _, n in ipairs(nodes) do
        s = s + walk(n)
    end
    return s
end

-- (f) a constant list, inline and as a local, and (g) an ALL-CAPS constant: bounded, no finding
local function flags(x)
    local hit = 0
    for _, k in ipairs({ 'x', 'y' }) do
        if x[k] then hit = hit + 1 end
    end
    for _, k in ipairs(KEYS) do
        if x[k] then hit = hit + 1 end
    end
    local modes = { 'r', 'w' }
    for _, m in ipairs(modes) do
        if x[m] then hit = hit + 1 end
    end
    return hit
end

function M.flag_all(xs)
    local n = 0
    for _, x in ipairs(xs) do
        n = n + flags(x)
    end
    return n
end

-- (h) a looping helper reached THROUGH A WRAPPER that has no loop of its own: the wrapper
-- loops as deep as its callee, so the outer loop still sees depth 2
local function sum_all(xs)
    local s = 0
    for _, x in ipairs(xs) do
        s = s + x
    end
    return s
end
local function wrapped(xs)
    return sum_all(xs)
end

function M.grand(groups)
    local g = 0
    for _, grp in ipairs(groups) do
        g = g + wrapped(grp)
    end
    return g
end

return M
