-- Reachability cones — the "mark a node, follow the glow toward it" navigation
-- idiom (user's flamegraph-search seedling). Pure: a BFS over a plain
-- adjacency map, so it works either direction (the caller passes store.uses
-- for the DESCENDANT cone — what a node reaches — or store.usedby for the
-- ANCESTOR cone — what reaches it) and needs no store/UI to test.

local M = {}

--- The set of ids reachable from `anchor` through `adj` (id -> {ids}),
--- transitively, cycle-safe, ANCHOR EXCLUDED. Returns { id = true }.
function M.reachable(anchor, adj)
    local seen, queue, out = { [anchor] = true }, { anchor }, {}
    local i = 1
    while i <= #queue do
        local id = queue[i]; i = i + 1
        for _, nb in ipairs(adj[id] or {}) do
            if not seen[nb] then
                seen[nb] = true
                queue[#queue + 1] = nb
                out[nb] = true
            end
        end
    end
    return out
end

return M
