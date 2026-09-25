-- idxrewrite fixture (CART-1057): equality-filter scans, repeated and not, and near misses.
local M = {}

local registry = {}   -- shared state, appended to only

function M.register(r) registry[#registry + 1] = r end

-- (1) a SHARED list filtered per call, first match: repeated by M.first_each
local function first_by_name(name)
    for _, r in ipairs(registry) do
        if r.name == name then return r end
    end
    return nil
end
function M.first_each(names)
    local out = {}
    for _, n in ipairs(names) do out[#out + 1] = first_by_name(n) or false end
    return out
end

-- (2) the whole PARAMETER list, collecting every match: repeated by M.count_each
local function count_kind(list, kind)
    local n = 0
    for _, r in ipairs(list) do
        if kind == r.kind then n = n + 1 end
    end
    return n
end
function M.count_each(list, kinds)
    local out = {}
    for _, k in ipairs(kinds) do out[#out + 1] = count_kind(list, k) end
    return out
end

-- (3) a FIELD of a parameter: a fresh list per call — declined
local function kids_of(node, k)
    for _, c in ipairs(node.kids) do
        if c.k == k then return c end
    end
end
function M.kids_each(nodes, k)
    local out = {}
    for _, n in ipairs(nodes) do out[#out + 1] = kids_of(n, k) or false end
    return out
end

-- (4) not repeated: nothing loops over it — declined
function M.once(list, name)
    for _, r in ipairs(list) do
        if r.name == name then return r end
    end
end

-- near misses: an else branch, a key reading the element
function M.with_else(list, name)
    local a, b = 0, 0
    for _, r in ipairs(list) do
        if r.name == name then a = a + 1 else b = b + 1 end
    end
    return a, b
end
function M.self_key(list)
    local n = 0
    for _, r in ipairs(list) do
        if r.name == r.alias then n = n + 1 end
    end
    return n
end

-- (5) the key field is REASSIGNED elsewhere in the file — declined (a bucket could miss a renamed element)
local tagged = {}
local function by_tag(t)
    for _, r in ipairs(tagged) do
        if r.tag == t then return r end
    end
end
function M.tag_each(ts) local out = {}; for _, t in ipairs(ts) do out[#out + 1] = by_tag(t) or false end; return out end
function M.retag(r, t) r.tag = t end

-- (6) an element of the list is REPLACED in place — declined (same length, different contents)
local slots = {}
local function by_slot(s)
    for _, r in ipairs(slots) do
        if r.slot == s then return r end
    end
end
function M.slot_each(ss) local out = {}; for _, s in ipairs(ss) do out[#out + 1] = by_slot(s) or false end; return out end
function M.replace(i, r) slots[i] = r end

return M
