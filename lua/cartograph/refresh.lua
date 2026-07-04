-- Live refresh: the graph follows saves. One file is re-extracted (with
-- the full project fileset, so its imports resolve), spliced into the
-- store's data, and the whole graph is relinked — calls INTO the changed
-- file re-resolve through a (kind, name) remap, since node ids embed line
-- numbers and any edit shifts them. Navigation state survives: history,
-- trails and the browser location are carried across the re-ingest.
--
-- Freeze-while-staged: a pending moveset pins the graph — refreshing under
-- a staged transaction would invalidate what the user is about to apply.

local M = {}

local refs = require 'cartograph.refs'

-- callee-name lookup over a raw calls list (pre-ingest, no store indexes)
local function callee_ctx(calls)
    local by_fn = {}
    for _, c in ipairs(calls or {}) do
        if c.fn then
            by_fn[c.fn] = by_fn[c.fn] or {}
            table.insert(by_fn[c.fn], c.callee)
        end
    end
    return function (n) return by_fn[n.id] end
end

--- Refresh one file (store-relative path). Returns stats or nil, reason.
function M.file(rel)
    local store = require 'cartograph.store'
    local data = store.data
    if not data or data.provider ~= 'treesitter' then
        return nil, 'not a live graph (dump-based — regenerate the dump instead)'
    end
    if next(store.moveset or {}) then
        return nil, 'staged changes pending — refresh is frozen until applied or cleared'
    end
    local ts = require 'cartograph.providers.treesitter'

    -- re-extract just this file, resolving imports against the whole project
    local fileset = {}
    for _, f in ipairs(store.files) do fileset[#fileset + 1] = f end
    if not vim.tbl_contains(fileset, rel) then fileset[#fileset + 1] = rel end
    local mini = ts.extract(data.root, { subdirs = { rel }, fileset = fileset })

    -- old nodes of this file (synthetic sql:: entities are re-derived below)
    local removed, old_nodes = {}, {}
    for _, n in ipairs(data.nodes) do
        if n.id:sub(1, 5) == 'sql::' then
            removed[n.id] = true
        elseif n.file == rel and not n.unparsed then
            removed[n.id] = true
            old_nodes[#old_nodes + 1] = n
        end
    end
    -- remap old ids -> new ids through the reference layer: witnesses
    -- disambiguate reordered same-named siblings; renames are NOT followed
    -- here (relink rebuilds those edges by the new name honestly)
    local old_callees = callee_ctx(data.calls)
    local mini_ctx = { callees = callee_ctx(mini.calls) }
    local remap = {}
    for _, n in ipairs(old_nodes) do
        local sibs = {}
        for _, x in ipairs(old_nodes) do
            if x.kind == n.kind and x.name == n.name then sibs[#sibs + 1] = x end
        end
        local ref = refs.of(n, sibs, old_callees(n))
        local newid, note = refs.resolve(ref, mini.nodes, mini_ctx)
        if newid and newid ~= n.id
            and not (note and note:match('^renamed')) then
            remap[n.id] = newid
        end
    end

    local stats = { removed = 0, added = #mini.nodes, remapped = 0 }

    -- nodes: drop this file's (and sql entities), append the fresh ones
    local nodes = {}
    for _, n in ipairs(data.nodes) do
        if removed[n.id] then
            stats.removed = stats.removed + 1
        else
            nodes[#nodes + 1] = n
        end
    end
    for _, n in ipairs(mini.nodes) do nodes[#nodes + 1] = n end
    data.nodes = nodes

    -- edges: this file's outgoing come fresh (mini + relink); inbound edges
    -- remap by signature or drop (relink gives their calls another chance)
    local edges = {}
    for _, e in ipairs(data.edges) do
        if removed[e.from] then
            -- fresh outgoing replaces it
        elseif removed[e.to] then
            local to2 = remap[e.to]
            if to2 then
                e.to = to2
                stats.remapped = stats.remapped + 1
                edges[#edges + 1] = e
            end
        else
            edges[#edges + 1] = e
        end
    end
    for _, e in ipairs(mini.edges) do edges[#edges + 1] = e end
    data.edges = edges

    -- calls: replace this file's; other files' resolved targets remap or
    -- reopen (to = nil -> relink retries against the new node set)
    local calls = {}
    for _, c in ipairs(data.calls or {}) do
        if c.file ~= rel then
            if c.to and removed[c.to] then c.to = remap[c.to] end
            if c.fn and removed[c.fn] then c.fn = remap[c.fn] end
            calls[#calls + 1] = c
        end
    end
    for _, c in ipairs(mini.calls or {}) do calls[#calls + 1] = c end
    data.calls = calls

    -- global relink + the post-passes (all idempotent over existing edges)
    stats.relinked = ts.relink(data)
    local xl = require 'cartograph.xlang'
    xl.link(data, xl.effective_bindings(data))
    require('cartograph.sql').attach(data)

    -- carry navigation across the re-ingest
    if store.focused and removed[store.focused] then
        store.focused = remap[store.focused]
    end
    local focused = store.focused
    local back, fwd = store._nav_back, store._nav_fwd
    local loc = store.loc_provider and store.loc_provider.get()
    store.ingest(data)
    store._nav_back, store._nav_fwd = back or {}, fwd or {}
    require('cartograph.toc').attach(store)
    if focused and store.node(focused) then store.set_focus(focused) end
    if loc and store.loc_provider then
        pcall(store.loc_provider.set, loc)
    end
    return stats
end

--- Full refresh: re-extract the whole root (small projects; the manual
--- escape hatch for big ones).
function M.all()
    local store = require 'cartograph.store'
    local data = store.data
    if not data or data.provider ~= 'treesitter' then
        return nil, 'not a live graph'
    end
    if next(store.moveset or {}) then
        return nil, 'staged changes pending — refresh is frozen'
    end
    local ts = require 'cartograph.providers.treesitter'
    local fresh = ts.extract(data.root)
    local xl = require 'cartograph.xlang'
    xl.link(fresh, xl.effective_bindings(fresh))
    require('cartograph.sql').attach(fresh)
    local back, fwd = store._nav_back, store._nav_fwd
    local loc = store.loc_provider and store.loc_provider.get()
    store.ingest(fresh)
    store._nav_back, store._nav_fwd = back or {}, fwd or {}
    require('cartograph.toc').attach(store)
    if loc and store.loc_provider then pcall(store.loc_provider.set, loc) end
    return { nodes = #fresh.nodes }
end

return M
