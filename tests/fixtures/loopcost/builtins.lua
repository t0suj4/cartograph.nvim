-- loopcost fixture (CART-1057): what BUILTIN calls cost, and how an unknown aggregates.
local M = {}

local registry = {}   -- shared state: an upvalue every call below reads

-- (1) table.sort of a parameter, once per element of another: depth 2 (n x n log n)
function M.sort_each(calls, bucket)
    for _, c in ipairs(calls) do
        table.sort(bucket)
    end
end

-- (2) table.remove(q, 1) drains a queue: every removal shifts the rest (the position arity)
function M.drain(q)
    local out = {}
    while #q > 0 do
        out[#out + 1] = table.remove(q, 1)
    end
    return out
end

-- (3) table.insert(out, x) APPENDS: constant, cited — no finding
function M.collect(xs)
    local out = {}
    for _, x in ipairs(xs) do
        table.insert(out, x)
    end
    return out
end

-- (4) an UNKNOWN library call in a loop: a hole, reported as depth >= 1, never as 0
function M.scan_all(xs)
    for _, x in ipairs(xs) do
        unknown_lib.scan(xs)
    end
end

-- (5) vim.tbl_contains over SHARED state per element of an accumulator: the fn_at shape with no
-- user callee at all
function M.dedupe(items)
    local pending = {}
    for _, it in ipairs(items) do
        pending[#pending + 1] = it
    end
    for _, p in ipairs(pending) do
        if not vim.tbl_contains(registry, p) then registry[#registry + 1] = p end
    end
end

-- (6) pcall of a looping helper, per element: the invoked function's cost comes through
local function heavy(t)
    local s = 0
    for _, v in ipairs(t) do
        s = s + v
    end
    return s
end
function M.guarded(ts)
    for _, t in ipairs(ts) do
        pcall(heavy, t)
    end
end

-- (7) a string METHOD: on the loop binder (the element itself) it is bounded; on a parameter
-- scanned per element it is linear, believed by the method name
function M.words(lines, text)
    local n = 0
    for _, line in ipairs(lines) do
        if line:match('^%s*$') then n = n + 1 end
        if text:find(line, 1, true) then n = n + 1 end
    end
    return n
end

-- (8) a method with a LITERAL argument: `sep:rep(3)` is bounded (the receiver is not argument 1)
function M.pad(xs, sep)
    local out = {}
    for _, x in ipairs(xs) do
        out[#out + 1] = sep:rep(3) .. x
    end
    return out
end

-- (9) a caller looping over (4): the hole TIED at scan_all's certified depth travels up — >=2
function M.outer_scan(groups)
    for _, g in ipairs(groups) do
        M.scan_all(g)
    end
end

-- (10) MUTUAL RECURSION over a tree, called per element: the recursion is a HOLE (the lens cannot
-- size a walk), the kids loop is certified, and the answer is the same whichever is asked first
local walk_tree
local function walk_kids(n)
    for _, k in ipairs(n.kids) do
        walk_tree(k)
    end
end
function walk_tree(n)
    for _, a in ipairs(n.attrs) do
        n.seen = a
    end
    walk_kids(n)
end
function M.walk_forest(trees)
    for _, t in ipairs(trees) do
        walk_tree(t)
    end
end

-- (11) a THREE-member cycle A -> B -> C -> A, the loop in C, C defined FIRST: a re-entry guard
-- memoizes B as 0 when C is asked first; the component rule gives B's callers the loop every time
local cyc_a, cyc_b
local function cyc_c(xs)
    for _, x in ipairs(xs) do
        cyc_a(x)
    end
end
function cyc_b(xs) cyc_c(xs) end
function cyc_a(xs) cyc_b(xs) end
function M.cycle_each(groups)
    for _, g in ipairs(groups) do
        cyc_b(g)
    end
end

-- (12) a constructor of NON-literal elements is still BOUNDED in size (two patterns), and a
-- module call two levels deep in a head is not the collection (`vim.fn.globpath(root, ...)`)
function M.decl_like(lines, name)
    local esc = name:gsub('%W', '%%%0')
    local pats = { '^local%s+function%s+' .. esc, '^local%s+' .. esc }
    local n = 0
    for _, l in ipairs(lines) do
        for _, p in ipairs(pats) do
            if l:find(p) then n = n + 1 end
        end
    end
    for _, g in ipairs(vim.fn.globpath(name, '*.lua', false, true)) do
        n = n + #g
    end
    return n
end

-- (13) a MAYBE-LOOP: a loop over a call result nobody sized (`vim.api.nvim_list_bufs()`) is a hole,
-- not a level and not a zero; its caller's loop still certifies its own level and the helper's
function M.per_buf(words)
    local n = 0
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
        n = n + b + heavy(words)
    end
    return n
end
function M.per_buf_each(groups)
    for _, g in ipairs(groups) do
        M.per_buf(g)
    end
end

return M
