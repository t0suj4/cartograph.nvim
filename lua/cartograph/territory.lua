-- Territorial decomposition: partition the graph by WHICH ENTRY POINTS reach
-- each node (its entry-set), so the architecture falls out of reachability
-- with no clustering heuristic. Pure — entries + adjacency in, no store/UI.
--
--   territory  reached by exactly one entry  -> that feature's private code
--   commons    reached by several (not all)  -> a shared subsystem
--   core       reached by every entry        -> the universal core
--   (absent)   reached by none               -> unreached from the entries
--
-- BORDERS are the seams: a node whose entry-set is strictly larger than a live
-- caller's — the join where a feature's path first meets shared code, i.e. the
-- natural API of a shared subsystem. See [[cartograph-terminology]] (territory
-- / commons / core / border) and [[refactor-cockpit-design]].

local M = {}

--- Partition over `uses` (id -> callees) with border detection via `usedby`.
--- `entries` = the root ids. Returns:
---   node        id -> { entries=set, n=count, class, entry?, border? }
---              (only reached nodes appear)
---   k, entries, entry_index (id -> 1-based order, for stable per-entry colour)
function M.compute(entries, uses, usedby)
    local cone = require 'cartograph.cone'
    local reach, entry_index = {}, {}
    for i, e in ipairs(entries) do
        entry_index[e] = i
        local set = cone.reachable(e, uses)
        set[e] = true -- an entry reaches itself (its own territory's root)
        for id in pairs(set) do
            local r = reach[id]; if not r then r = {}; reach[id] = r end
            r[e] = true
        end
    end

    local k = #entries
    local node = {}
    for id, set in pairs(reach) do
        local n, only = 0, nil
        for e in pairs(set) do n = n + 1; only = e end
        -- territory checked before core so a single-entry graph reads as one
        -- territory, not a degenerate "core"
        local class = (n == 1 and 'territory') or (n == k and 'core') or 'commons'
        node[id] = { entries = set, n = n, class = class,
            entry = class == 'territory' and only or nil }
    end

    -- a border = some LIVE caller (itself reached) has a strictly smaller
    -- entry-set: stepping into this node crosses into more-shared ground
    for id, info in pairs(node) do
        for _, c in ipairs(usedby[id] or {}) do
            local ci = node[c]
            if ci and ci.n >= 1 and ci.n < info.n then info.border = true; break end
        end
    end

    return { node = node, k = k, entries = entries, entry_index = entry_index }
end

--- Counts for a one-line report: per-entry territory sizes + commons/core/borders.
function M.summary(t)
    local territories, commons, core, borders = {}, 0, 0, 0
    for _, info in pairs(t.node) do
        if info.class == 'territory' then
            territories[info.entry] = (territories[info.entry] or 0) + 1
        elseif info.class == 'commons' then
            commons = commons + 1
        elseif info.class == 'core' then
            core = core + 1
        end
        if info.border then borders = borders + 1 end
    end
    return { territories = territories, commons = commons, core = core, borders = borders }
end

return M
