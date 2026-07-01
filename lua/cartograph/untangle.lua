-- Untangle LENS (pure, read-only). Given a function's statement-level data-flow
-- (`df`), partition its statements into independent chains of computation
-- ("concerns") over the data-dependency edges, and measure how interleaved they
-- are in source order.
--
-- This REVEALS tangle; it does not fix it. Reordering code safely needs the full
-- PDG (control + anti/output deps + side-effect ordering) which `df` does not
-- carry — so this is a comprehension/diagnostic lens over local data flow, not a
-- transformation and not a safety claim.

local M = {}

--- @param df { inputs:string[], stmts: table[] } | nil
--- @return { n:integer, ncomp:integer, comp:integer[], sizes:table, switches:integer, tangle:integer, maxspan:integer }
function M.analyze(df)
    local stmts = df and df.stmts or {}
    local n = #stmts
    if n == 0 then return { n = 0, ncomp = 0, comp = {}, sizes = {}, switches = 0, tangle = 0, maxspan = 0 } end

    -- union-find over statement indices, joined by data-dependency edges
    local parent = {}
    for i = 1, n do parent[i] = i end
    local function find(x)
        while parent[x] ~= x do parent[x] = parent[parent[x]]; x = parent[x] end
        return x
    end
    local function union(a, b)
        local ra, rb = find(a), find(b)
        if ra ~= rb then parent[ra] = rb end
    end
    local maxspan = 0
    for i, s in ipairs(stmts) do
        for _, d in ipairs(s.dep or {}) do
            if d.from >= 1 and d.from <= n then
                union(i, d.from)
                if i - d.from > maxspan then maxspan = i - d.from end
            end
        end
    end

    -- label components by first appearance in source order (0-based: A, B, C…)
    local root2comp, comp, next_id = {}, {}, 0
    for i = 1, n do
        local r = find(i)
        if root2comp[r] == nil then root2comp[r] = next_id; next_id = next_id + 1 end
        comp[i] = root2comp[r]
    end
    local ncomp = next_id

    local sizes = {}
    for i = 1, n do sizes[comp[i]] = (sizes[comp[i]] or 0) + 1 end

    -- adjacent switches between concerns in source order; a perfectly grouped
    -- function switches exactly ncomp-1 times, so tangle = the excess.
    local switches = 0
    for i = 1, n - 1 do if comp[i] ~= comp[i + 1] then switches = switches + 1 end end
    local tangle = math.max(0, switches - math.max(0, ncomp - 1))

    return { n = n, ncomp = ncomp, comp = comp, sizes = sizes,
             switches = switches, tangle = tangle, maxspan = maxspan }
end

return M
