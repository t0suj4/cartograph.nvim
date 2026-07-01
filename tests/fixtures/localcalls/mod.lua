-- fixture: helpers wired together with `local function` and called via getlocal.
-- The intra-module call graph here was invisible before the getlocal fix
-- (only getglobal/getfield/getmethod were resolved).
local function helper(x)
    return x + 1
end

local function middle(y)
    return helper(y) * 2   -- middle -> helper
end

local function caller(z)
    return middle(z) + helper(z)   -- caller -> middle, caller -> helper
end

return { run = caller }
