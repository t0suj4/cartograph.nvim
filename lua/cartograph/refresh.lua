-- Live refresh: the graph follows saves. Changed files are re-extracted
-- (with the full project fileset, so their imports resolve), spliced into
-- the data, and the whole graph is relinked — calls INTO changed files
-- re-resolve through a refs-based remap, since node ids embed line numbers
-- and any edit shifts them. Navigation state survives: history, trails and
-- the browser location are carried across the re-ingest.
--
-- splice() is the PURE batch core, shared by the BufWritePost single-file
-- path and the incremental open cache (cartograph.cache): one mini-extract
-- covering every changed file, one remap, one relink.
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

--- PURE batch splice over `data`: re-extract `rels` (changed or new
--- files), drop `deleted`, remap what survives, relink once.
--- Landings in refreshed unparsed files are evicted (cache, not state);
--- sql:: entities are always dropped for the caller's re-attach.
--- Returns stats { removed, added, remapped, relinked, remap, removed_ids }.
function M.splice(data, rels, deleted)
    local ts = require 'cartograph.providers.treesitter'
    local relset, del = {}, {}
    for _, f in ipairs(rels or {}) do relset[f] = true end
    for _, f in ipairs(deleted or {}) do del[f] = true end

    -- fileset = surviving project files + the refreshed ones, so imports
    -- resolve project-wide inside the mini extraction
    local fileset, seenf = {}, {}
    local function addf(f)
        if f and not seenf[f] then seenf[f] = true; fileset[#fileset + 1] = f end
    end
    for _, n in ipairs(data.nodes) do
        if n.kind == 'module' and not del[n.file] then addf(n.file) end
    end
    for _, f in ipairs(rels or {}) do addf(f) end

    -- the id pass is SKIPPED in the mini extraction and re-run below
    -- against GLOBAL lookups: a mini's own index sees one file's names,
    -- and "unique across the workspace" decided against it would silently
    -- drop the refreshed file's reads of other files' globals
    local mini = (rels and #rels > 0)
        and ts.extract(data.root, { subdirs = rels, fileset = fileset,
            skip_idpass = true })
        or { nodes = {}, edges = {}, calls = {}, stamps = {} }

    -- removed = sql entities (re-derived by the caller) + every node of a
    -- refreshed or deleted file. Refreshed files drop their landings too:
    -- landings are content-keyed cache and this file's content changed.
    local removed, old_by_file = {}, {}
    for _, n in ipairs(data.nodes) do
        if n.id:sub(1, 5) == 'sql::' then
            removed[n.id] = true
        elseif relset[n.file] or del[n.file] then
            removed[n.id] = true
            if relset[n.file] and not n.unparsed then
                old_by_file[n.file] = old_by_file[n.file] or {}
                table.insert(old_by_file[n.file], n)
            end
        end
    end

    -- remap old ids -> new ids through the reference layer: witnesses
    -- disambiguate reordered same-named siblings; renames are NOT followed
    -- here (relink rebuilds those edges by the new name honestly)
    local old_callees = callee_ctx(data.calls)
    local mini_ctx = { callees = callee_ctx(mini.calls) }
    local remap = {}
    for _, olds in pairs(old_by_file) do
        for _, n in ipairs(olds) do
            local sibs = {}
            for _, x in ipairs(olds) do
                if x.kind == n.kind and x.name == n.name then sibs[#sibs + 1] = x end
            end
            local ref = refs.of(n, sibs, old_callees(n))
            local newid, note = refs.resolve(ref, mini.nodes, mini_ctx)
            -- same-id resolutions map to themselves: an inbound edge to a
            -- node whose id survived the edit must be KEPT, not dropped
            -- (relink rebuilds ref edges but not use edges)
            if newid and not (note and note:match('^renamed')) then
                remap[n.id] = newid
            end
        end
    end

    local stats = { removed = 0, added = #mini.nodes, remapped = 0,
        remap = remap, removed_ids = removed }

    -- nodes: drop the removed, append the fresh
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

    -- edges: refreshed files' outgoing come fresh (mini + relink); inbound
    -- edges remap by signature or drop (relink gives their calls another chance)
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

    -- calls: replace the refreshed files'; other files' resolved targets
    -- remap or reopen (to = nil -> relink retries against the new node set)
    local calls = {}
    for _, c in ipairs(data.calls or {}) do
        if not (relset[c.file] or del[c.file]) then
            if c.to and removed[c.to] then c.to = remap[c.to] end
            if c.fn and removed[c.fn] then c.fn = remap[c.fn] end
            calls[#calls + 1] = c
        end
    end
    for _, c in ipairs(mini.calls or {}) do calls[#calls + 1] = c end
    data.calls = calls

    -- stamps follow the content they key
    data.stamps = data.stamps or {}
    for f, s in pairs(mini.stamps or {}) do data.stamps[f] = s end
    for f in pairs(del) do data.stamps[f] = nil end

    -- the unparsed roster: survivors + the mini's, deleted gone
    local un, seenu = {}, {}
    for _, f in ipairs(data.unparsed or {}) do
        if not relset[f] and not del[f] and not seenu[f] then
            seenu[f] = true; un[#un + 1] = f
        end
    end
    for _, f in ipairs(mini.unparsed or {}) do
        if not seenu[f] then seenu[f] = true; un[#un + 1] = f end
    end
    table.sort(un)
    data.unparsed = #un > 0 and un or nil

    stats.relinked = ts.relink(data)

    -- the refreshed files' id pass, at GLOBAL scope: use edges into other
    -- files' vars, dispatch refs to unique fns anywhere, cbarg marks.
    -- (Inbound the other way — some OTHER file referencing a var this
    -- refresh just created — would need the id pass over every file;
    -- those edges appear on the next full extract. Known limit.)
    if rels and #rels > 0 and mini.fn_ranges then
        local live = {}
        for _, f in ipairs(rels) do
            if mini.fn_ranges[f] then live[#live + 1] = f end
        end
        if #live > 0 then
            local L = ts.lookups(data.nodes)
            L.fn_ranges = mini.fn_ranges
            ts.merge_idpass(data, ts.id_pass(data.root, live, L))
        end
    end
    return stats
end

--- Refresh one file (store-relative path). Returns stats or nil, reason.
function M.file(rel)
    local store = require 'cartograph.store'
    local data = store.data
    if not data or data.provider ~= 'treesitter' then
        return nil, 'not a live graph (dump-based — regenerate the dump instead)'
    end
    if data.partial then
        return nil, 'extraction in progress — refresh again when it completes'
            .. ' (the stale marker will say if this file needs it)'
    end
    if next(store.moveset or {}) then
        return nil, 'staged changes pending — refresh is frozen until applied or cleared'
    end

    local stats = M.splice(data, { rel }, nil)
    local removed, remap = stats.removed_ids, stats.remap

    -- post-passes (all idempotent over existing edges)
    local xl = require 'cartograph.xlang'
    xl.link(data, xl.effective_bindings(data))
    require('cartograph.sql').attach(data)

    -- carry navigation across the re-ingest: history entries remap like
    -- everything else; an entry whose node is gone and unmappable is
    -- pruned (back() also skips dead ids defensively, for paths that
    -- can't remap — refresh.all, provider swaps)
    local function carry_stack(stack)
        local out = {}
        for _, e in ipairs(stack or {}) do
            local id = e.id
            if id and removed[id] then id = remap[id] end
            if id or not e.id then
                e.id = id
                out[#out + 1] = e
            end
        end
        return out
    end
    if store.focused and removed[store.focused] then
        store.focused = remap[store.focused]
    end
    local focused = store.focused
    local back, fwd = carry_stack(store._nav_back), carry_stack(store._nav_fwd)
    local loc = store.loc_provider and store.loc_provider.get()
    store.ingest(data)
    store._nav_back, store._nav_fwd = back, fwd
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
    require('cartograph.cache').save(fresh)
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
