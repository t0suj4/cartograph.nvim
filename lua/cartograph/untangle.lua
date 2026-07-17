-- Untangle LENS (pure, read-only). Given a function's statement-level data-flow
-- (`df`), partition its statements into independent chains of computation
-- ("concerns") over the data-dependency edges, and measure how interleaved they
-- are in source order.
--
-- This REVEALS tangle; it does not fix it. Reordering code safely needs the full
-- PDG (control + anti/output deps + side-effect ordering) which `df` does not
-- carry — so `analyze(df)` is a comprehension/diagnostic lens over local data
-- flow, not a transformation and not a safety claim.
--
-- INC 1 of the PDG upgrade ([[cartograph-untangle-pdg]]): `analyze_flow(flow)` is
-- the FINE, data-precise sibling — same partition/metrics, but over flow's fine
-- rows (all nesting levels, so control bodies stop folding into one blob) with
-- data-dependency edges from `flow.reaching_cfg` (scope-aware, branch-join/loop
-- precise) instead of df's coarse first-def-wins `dep`. STILL data-deps only
-- (comprehension, not yet a safety claim — control + anti/output + side-effect
-- ordering are INC 2/3). It sits BESIDE analyze until the arc completes.

local flowmod = require 'cartograph.flow'

local M = {}

-- union-find over 1..n joined by the (a,b) edges `add_edges(union, span)` emits
-- (span reports each def→use distance for maxspan), then component labelling +
-- interleaving metrics. Shared by analyze/analyze_flow so the two dep sources
-- (df.dep vs reaching_cfg) differ ONLY in which edges they feed. Concerns are
-- labelled by first appearance in ROW order (0-based: A, B, C…); a perfectly
-- grouped function switches exactly ncomp-1 times, so tangle = the excess.
local function partition(n, add_edges)
    if n == 0 then return { n = 0, ncomp = 0, comp = {}, sizes = {}, switches = 0, tangle = 0, maxspan = 0 } end
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
    local function span(d) if d > maxspan then maxspan = d end end
    add_edges(union, span)

    local root2comp, comp, next_id = {}, {}, 0
    for i = 1, n do
        local r = find(i)
        if root2comp[r] == nil then root2comp[r] = next_id; next_id = next_id + 1 end
        comp[i] = root2comp[r]
    end
    local ncomp = next_id
    local sizes = {}
    for i = 1, n do sizes[comp[i]] = (sizes[comp[i]] or 0) + 1 end
    local switches = 0
    for i = 1, n - 1 do if comp[i] ~= comp[i + 1] then switches = switches + 1 end end
    local tangle = math.max(0, switches - math.max(0, ncomp - 1))
    return { n = n, ncomp = ncomp, comp = comp, sizes = sizes,
             switches = switches, tangle = tangle, maxspan = maxspan }
end

--- COARSE lens (the shipped comprehension view): union-find over df's data-dep
--- edges. Locals-only, top-level statements only, not a safety claim.
--- @param df { inputs:string[], stmts: table[] } | nil
--- @return { n:integer, ncomp:integer, comp:integer[], sizes:table, switches:integer, tangle:integer, maxspan:integer }
function M.analyze(df)
    local stmts = df and df.stmts or {}
    return partition(#stmts, function (union, span)
        for i, s in ipairs(stmts) do
            for _, d in ipairs(s.dep or {}) do
                if d.from >= 1 and d.from <= #stmts then
                    union(i, d.from); span(i - d.from)
                end
            end
        end
    end)
end

--- FINE lens (INC 1): union-find over flow's reaching-definition edges across the
--- fine rows. `from` sets include 0 for a param/entry reach — skipped (no row to
--- join). More correct than analyze() where a var is redefined (reaching picks
--- the nearest def, not df's first-def-wins) and where control bodies would fold.
--- @param flow { stmts: table[], params: string[] } | nil  (flow.record(n) shape)
--- @return { n:integer, ncomp:integer, comp:integer[], sizes:table, switches:integer, tangle:integer, maxspan:integer }
function M.analyze_flow(flow)
    local stmts = flow and flow.stmts or {}
    local n = #stmts
    if n == 0 then return { n = 0, ncomp = 0, comp = {}, sizes = {}, switches = 0, tangle = 0, maxspan = 0 } end
    local reaching = flowmod.reaching_cfg(flow)
    return partition(n, function (union, span)
        for _, e in ipairs(reaching) do
            local at = e.at
            for _, from in ipairs(e.from) do
                if from ~= 0 and from >= 1 and from <= n then
                    union(at, from); span(at - from)
                end
            end
        end
    end)
end

return M
