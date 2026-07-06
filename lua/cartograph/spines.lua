-- Spine detection: the tree structures hiding in a (cyclic) graph.
--   (1) per-root CALL-DOMINATOR tree — the honest call hierarchy, "what this
--       entry must-pass-through gates." Its SHAPE says whether it's a ride-able
--       spine (deep) or bushy (mostly shared, so nothing is uniquely gated).
--   (2) the REGION poset (entry-sets ordered by ⊆) — is it a forest (a clean
--       subsystem tree) or does a region have multiple parents (a layering seam)?
-- Pure: adjacency / sets in, no store or UI. See [[refactor-cockpit-design]]
-- and the axis/spine notes in [[cartograph-terminology]].

local M = {}

--- Immediate dominators over the subgraph reachable from `root` via `succ`
--- (id -> {callee ids}). Cooper–Harvey–Kennedy. Returns
---   idom      id -> immediate dominator (idom[root] = root)
---   rpo_list  reverse-postorder index -> id (root at 1)
---   n         reachable node count (incl. root)
--- Iterative throughout — safe on deep graphs.
function M.dominators(root, succ)
    -- iterative DFS, collecting postorder
    local seen, order = { [root] = true }, {}
    local stack = { { root, 1 } }
    while #stack > 0 do
        local top = stack[#stack]
        local u, ci = top[1], top[2]
        local kids = succ[u] or {}
        if ci <= #kids then
            top[2] = ci + 1
            local v = kids[ci]
            if not seen[v] then
                seen[v] = true
                stack[#stack + 1] = { v, 1 }
            end
        else
            order[#order + 1] = u -- postorder
            stack[#stack] = nil
        end
    end

    local n = #order
    local rpo, rpo_list = {}, {}
    for i = 1, n do
        local id = order[n - i + 1] -- reverse postorder; root -> 1
        rpo[id] = i; rpo_list[i] = id
    end

    -- predecessors within the reachable set
    local preds = {}
    for u in pairs(seen) do
        for _, v in ipairs(succ[u] or {}) do
            if seen[v] then preds[v] = preds[v] or {}; table.insert(preds[v], u) end
        end
    end

    local idom = { [root] = root }
    local function intersect(a, b)
        while a ~= b do
            while rpo[a] > rpo[b] do a = idom[a] end
            while rpo[b] > rpo[a] do b = idom[b] end
        end
        return a
    end

    local changed = true
    while changed do
        changed = false
        for r = 2, n do
            local b = rpo_list[r]
            local nd
            for _, p in ipairs(preds[b] or {}) do
                if idom[p] then nd = nd and intersect(p, nd) or p end
            end
            if nd and idom[b] ~= nd then idom[b] = nd; changed = true end
        end
    end
    return idom, rpo_list, n
end

--- Per-root dominator-tree shape. `roots` = entry ids, `succ` = uses.
--- Each entry: { root, size, depth, root_children, shape }, sorted big-first.
--- shape: trivial (≤2) / bushy (≥half hang off the root — shared, no spine) /
--- spine (depth ≥ 4) / shallow.
function M.dominator_analysis(roots, succ)
    local out = {}
    for _, root in ipairs(roots) do
        local idom, rpo_list, n = M.dominators(root, succ)
        local depth = { [root] = 0 }
        local maxdepth, rootkids = 0, 0
        for r = 2, n do
            local b = rpo_list[r]
            depth[b] = (depth[idom[b]] or 0) + 1
            if depth[b] > maxdepth then maxdepth = depth[b] end
            if idom[b] == root then rootkids = rootkids + 1 end
        end
        local ratio = n > 1 and rootkids / (n - 1) or 0
        local shape = (n <= 2 and 'trivial')
            or (ratio >= 0.5 and 'bushy')
            or (maxdepth >= 4 and 'spine')
            or 'shallow'
        out[#out + 1] = { root = root, size = n, depth = maxdepth,
            root_children = rootkids, shape = shape }
    end
    table.sort(out, function (a, b)
        if a.size ~= b.size then return a.size > b.size end
        return a.depth > b.depth
    end)
    return out
end

--- Is the region poset a forest? `regions` = list of { set = {id->true}, n }.
--- Returns { regions, forest, multiparent } — multiparent = regions with ≥2
--- immediate super-regions (the layering seams). Capped (skipped>threshold).
function M.region_forest(regions)
    local R = #regions
    if R == 0 then return { regions = 0, forest = true, multiparent = 0 } end
    if R > 300 then return { regions = R, skipped = true } end
    local function strict_sub(a, b)
        if a.n >= b.n then return false end
        for e in pairs(a.set) do if not b.set[e] then return false end end
        return true
    end
    local multiparent = 0
    for i = 1, R do
        local supers = {}
        for j = 1, R do
            if i ~= j and strict_sub(regions[i], regions[j]) then supers[#supers + 1] = j end
        end
        local imm = 0
        for _, j in ipairs(supers) do
            local minimal = true
            for _, k in ipairs(supers) do
                if k ~= j and strict_sub(regions[k], regions[j]) then minimal = false; break end
            end
            if minimal then imm = imm + 1 end
        end
        if imm >= 2 then multiparent = multiparent + 1 end
    end
    return { regions = R, forest = multiparent == 0, multiparent = multiparent }
end

return M
