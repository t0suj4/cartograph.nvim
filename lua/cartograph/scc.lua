-- SCC condensation over the call graph (iterative Tarjan — 60k-node
-- graphs would blow a recursive stack). Two properties the effects
-- fixpoint rides:
--   * Tarjan EMITS components callees-first (a component finishes only
--     after everything it reaches has finished), so processing in
--     emission order IS the reverse-topological pass — effects are a
--     join-semilattice, and one pass suffices, no iteration.
--   * comp[a] == comp[b] answers "are these mutually recursive" — the
--     "can this call recurse" fact, free.
-- Deterministic: adjacency lists keep extraction order, roots iterate a
-- caller-sorted id list (worker == inline discipline).

local M = {}

--- Condense. `adj` maps id -> list of successor ids (store.uses); `ids`
--- lists every node that must appear (sorted for determinism). Returns
--- { comp = {id -> component index}, members = {ci -> {ids}}, n } with
--- component indexes in EMISSION (= reverse topological) order.
function M.condense(adj, ids)
    local index, low, onstk = {}, {}, {}
    local stk, comp, members = {}, {}, {}
    local idx = 0
    for _, root in ipairs(ids) do
        if not index[root] then
            local frames = { { v = root, i = 0 } }
            while #frames > 0 do
                local fr = frames[#frames]
                local v = fr.v
                if fr.i == 0 then
                    idx = idx + 1
                    index[v], low[v] = idx, idx
                    stk[#stk + 1] = v
                    onstk[v] = true
                end
                local nbrs = adj[v]
                local nn = nbrs and #nbrs or 0
                local descended = false
                while fr.i < nn do
                    fr.i = fr.i + 1
                    local w = nbrs[fr.i]
                    if index[w] == nil then
                        frames[#frames + 1] = { v = w, i = 0 }
                        descended = true
                        break
                    elseif onstk[w] and index[w] < low[v] then
                        low[v] = index[w]
                    end
                end
                if not descended and fr.i >= nn then
                    frames[#frames] = nil
                    if low[v] == index[v] then
                        local ci = #members + 1
                        local ms = {}
                        while true do
                            local w = stk[#stk]
                            stk[#stk] = nil
                            onstk[w] = nil
                            comp[w] = ci
                            ms[#ms + 1] = w
                            if w == v then break end
                        end
                        members[ci] = ms
                    end
                    local up = frames[#frames]
                    if up and low[v] < low[up.v] then low[up.v] = low[v] end
                end
            end
        end
    end
    return { comp = comp, members = members, n = #members }
end

--- LONGEST-PATH LEVEL per component — the only depth an import/call graph
--- actually has. Depth measured by WALKING is not a property of a node: it
--- records which path the walk took to reach it (measured on mantis, 37% of
--- files were drawn at more than one depth and config_api.php at 23 of them;
--- on our own lua/, 50%). Condense the cycles first and it becomes single-
--- valued, and much smaller: mantis's drawn 26 is really 3.
---
--- One forward pass, no recursion: condense() emits components in reverse
--- topological order, so every successor of `ci` already has a level.
--- Level 0 is a component that reaches nothing — for imports, a file that
--- requires nobody, which makes ascending level READ AS LOAD ORDER.
--- Returns { level = {ci -> n}, max = n }.
function M.levels(con, adj)
    local level, max = {}, 0
    for ci = 1, con.n do
        local m = 0
        for _, id in ipairs(con.members[ci]) do
            for _, w in ipairs(adj[id] or {}) do
                local cw = con.comp[w]
                -- a successor OUTSIDE the id set has no component: not ours to level
                if cw and cw ~= ci then
                    local l = (level[cw] or 0) + 1
                    if l > m then m = l end
                end
            end
        end
        level[ci] = m
        if m > max then max = m end
    end
    return { level = level, max = max }
end

return M
