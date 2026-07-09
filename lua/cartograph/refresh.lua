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

local function file_of(id)
    return id:match('^(.-)::') or id
end

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
    -- the SOURCE does the re-extraction: the filesystem provider parses
    -- files, an MCP substrate re-fetches the changed keys from its
    -- server. Everything after the mini is source-agnostic.
    local p = require('cartograph.source').provider(data)
    if rels and #rels > 0 and not (p and p.refresh_slice) then
        return nil, 'this source cannot re-extract slices — re-open cold'
    end
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
        and p.refresh_slice(data, rels, fileset)
        or { nodes = {}, edges = {}, calls = {}, stamps = {} }
    if not mini then
        return nil, 'source re-extraction failed'
    end

    -- removed = sql entities (re-derived by the caller) + every node of a
    -- refreshed or deleted file. Refreshed files drop their landings too:
    -- landings are content-keyed cache and this file's content changed.
    local removed, old_by_file = {}, {}
    -- name deltas: what this splice takes away / brings in, per class —
    -- the input to global-uniqueness reconciliation below
    local rm_fn, rm_var, ad_fn, ad_var = {}, {}, {}, {}
    for _, n in ipairs(data.nodes) do
        if n.id:sub(1, 5) == 'sql::' then
            removed[n.id] = true
        elseif relset[n.file] or del[n.file] then
            removed[n.id] = true
            if n.kind == 'function' or n.kind == 'method' then
                rm_fn[n.name] = (rm_fn[n.name] or 0) + 1
            elseif n.kind == 'var' then
                rm_var[n.name] = (rm_var[n.name] or 0) + 1
            end
            if relset[n.file] and not n.unparsed then
                old_by_file[n.file] = old_by_file[n.file] or {}
                table.insert(old_by_file[n.file], n)
            end
        end
    end
    for _, n in ipairs(mini.nodes) do
        if n.kind == 'function' or n.kind == 'method' then
            ad_fn[n.name] = (ad_fn[n.name] or 0) + 1
        elseif n.kind == 'var' then
            ad_var[n.name] = (ad_var[n.name] or 0) + 1
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
    -- dirty = every file whose PERSISTED contribution this splice
    -- changes: the refreshed files themselves, plus any file whose
    -- edges/calls get remapped, reopened, relinked or reconciled. The
    -- cache trusts this account for O(diff) saves — every mutation
    -- below must report here.
    local dirty = {}
    for _, f in ipairs(rels or {}) do dirty[f] = true end

    -- a reference is GONE when its node was removed — or when its id
    -- belongs to a refreshed/deleted file whose node never made it into
    -- this graph at all (a corrupted shard skipped at load): ids are
    -- file-prefixed, so the file tells us even when the node can't
    local function gone(id)
        if removed[id] then return true end
        local f = file_of(id)
        return relset[f] or del[f] or false
    end

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
        if gone(e.from) then
            -- fresh outgoing replaces it
        elseif gone(e.to) then
            dirty[file_of(e.from)] = true -- remapped or dropped: either way
            local to2 = remap[e.to]       -- this from-file's shard changed
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
            if c.to and gone(c.to) then
                c.to = remap[c.to]
                dirty[c.file] = true
            end
            if c.fn and gone(c.fn) then
                c.fn = remap[c.fn]
                dirty[c.file] = true
            end
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

    -- the mention index follows the files it describes (the id pass
    -- below re-records the refreshed files')
    data.names = data.names or {}
    for f in pairs(del) do data.names[f] = nil end
    for _, f in ipairs(rels or {}) do data.names[f] = nil end

    -- ── global-uniqueness reconciliation ─────────────────────────────
    -- A touched name is RECONCILE-WORTHY when this splice flipped its
    -- uniqueness (0↔1 or 1↔2, either class): a new global's inbound uses
    -- must APPEAR in unchanged files; a name made ambiguous must lose
    -- the inferred links only its former uniqueness justified. The
    -- mention index says which files can possibly care; only those get
    -- their id-pass artifacts re-derived. Sources without an id pass
    -- (non-parsed substrates: a DB introspector) have none of these
    -- artifacts to reconcile — skip to relink.
    local can_idpass = p and p.idpass
    local fn_after, var_after = {}, {}
    for _, n in ipairs(data.nodes) do
        if n.kind == 'function' or n.kind == 'method' then
            fn_after[n.name] = (fn_after[n.name] or 0) + 1
        elseif n.kind == 'var' and not n.sql then
            var_after[n.name] = (var_after[n.name] or 0) + 1
        end
    end
    local worthy = {}
    local function judge(after_counts, rm, ad)
        local names = {}
        for nme in pairs(rm) do names[nme] = true end
        for nme in pairs(ad) do names[nme] = true end
        for nme in pairs(names) do
            if #nme >= 3 then
                local after = after_counts[nme] or 0
                local before = after - (ad[nme] or 0) + (rm[nme] or 0)
                if (before == 1) ~= (after == 1) then worthy[nme] = true end
            end
        end
    end
    judge(fn_after, rm_fn, ad_fn)
    judge(var_after, rm_var, ad_var)
    local candidates = {}
    if can_idpass and next(worthy) then
        for f, s in pairs(data.names) do
            for nme in pairs(worthy) do
                if s:find('\31' .. nme .. '\31', 1, true) then
                    candidates[f] = true
                    break
                end
            end
        end
    end

    -- candidates' id-pass artifacts are re-derived wholesale: drop their
    -- use edges and inferred ref pairs, reopen calls sharing a killed
    -- pair (relink re-adds those at full fidelity via c.at)
    if next(candidates) then
        for f in pairs(candidates) do dirty[f] = true end
        local cand_fns = {}
        for _, n in ipairs(data.nodes) do
            if candidates[n.file]
                and (n.kind == 'function' or n.kind == 'method') then
                cand_fns[n.id] = true
            end
        end
        local killpair, edges2 = {}, {}
        for _, e in ipairs(data.edges) do
            local drop = false
            if cand_fns[e.from] then
                if e.kind == 'use' then
                    drop = true
                elseif e.kind == 'ref' and e.inferred then
                    drop = true
                    killpair[e.from .. '\31' .. e.to] = true
                end
            end
            if not drop then edges2[#edges2 + 1] = e end
        end
        data.edges = edges2
        for _, c in ipairs(data.calls or {}) do
            if c.to and c.fn and killpair[c.fn .. '\31' .. c.to] then
                c.to = nil
                c.inferred = nil
            end
        end
    end

    stats.relinked = ts.relink(data, dirty)

    -- the id pass at GLOBAL scope, over the refreshed files AND the
    -- reconciliation candidates (their fn extents come straight from the
    -- current nodes — no re-parse of anything but these files)
    local idfiles, franges = {}, {}
    for _, f in ipairs(rels or {}) do
        if mini.fn_ranges and mini.fn_ranges[f] then
            idfiles[#idfiles + 1] = f
            franges[f] = mini.fn_ranges[f]
        end
    end
    for f in pairs(candidates) do franges[f] = {} end
    for _, n in ipairs(data.nodes) do
        if candidates[n.file]
            and (n.kind == 'function' or n.kind == 'method') then
            table.insert(franges[n.file], { s = n.range.start.line,
                e = n.range['end'].line, id = n.id })
        end
    end
    for f in pairs(candidates) do
        if #franges[f] > 0 then -- fn-less files match sequential's skip
            idfiles[#idfiles + 1] = f
        else
            franges[f] = nil
        end
    end
    if can_idpass and #idfiles > 0 then
        local L = ts.lookups(data.nodes, data.root)
        L.fn_ranges = franges
        ts.merge_idpass(data, ts.id_pass(data.root, idfiles, L), dirty)
    end
    stats.reconciled = vim.tbl_count(candidates)
    stats.dirty = {}
    for f in pairs(dirty) do
        if not del[f] then stats.dirty[#stats.dirty + 1] = f end
    end
    table.sort(stats.dirty)
    return stats
end

--- Refresh one file (store-relative path). Returns stats or nil, reason.
function M.file(rel)
    return M.files({ rel })
end

--- Refresh a batch of files (one splice, one relink) — the post-apply
--- path for transactions, and the single-file save path with one rel.
function M.files(rels)
    local store = require 'cartograph.store'
    local data = store.data
    if not data or data.provider ~= 'treesitter' then
        return nil, 'not a live graph (dump-based — regenerate the dump instead)'
    end
    if data.partial then
        return nil, 'extraction in progress — refresh again when it completes'
            .. ' (the stale marker will say if this file needs it)'
    end
    if next(store.moveset or {}) or store.txn then
        return nil, 'staged changes pending — refresh is frozen until applied or cleared'
    end

    local stats, why = M.splice(data, rels, nil)
    if not stats then return nil, why end
    local removed, remap = stats.removed_ids, stats.remap

    -- post-passes (all idempotent over existing edges)
    local xl = require 'cartograph.xlang'
    xl.link(data, xl.effective_bindings(data))
    require('cartograph.sql').attach(data)
    require('cartograph.dblink').attach(data) -- session-cached db schema
    require('cartograph.django').attach(data)  -- routes/templates re-derive
    require('cartograph.symfony').attach(data)  -- yaml routes + twig re-derive
    require('cartograph.ansible').attach(data)  -- notify/handler + includes

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
    -- the working set re-resolves through its refs (renames followed,
    -- with notes; unresolved members wait as pending)
    local ws_notes = store.ws_resolve()
    if #ws_notes > 0 then
        vim.notify('cartograph: working set — ' .. table.concat(ws_notes, '; '),
            vim.log.levels.INFO)
    end
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
    if next(store.moveset or {}) or store.txn then
        return nil, 'staged changes pending — refresh is frozen'
    end
    local ts = require 'cartograph.providers.treesitter'
    local fresh = ts.extract(data.root)
    require('cartograph.cache').save_bg(fresh)
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

--- Hot-swap the CURRENT graph after an in-place EDGE mutation — a background
--- oracle (clangd/luals) upgrading ~ hypotheses to proven. Re-ingest the live
--- data carrying navigation, focus and the browser location, then redraw.
--- Nodes are unchanged (only edges), so every id stays valid. A no-op while a
--- transaction or move-set is staged (the graph must not shift underfoot).
function M.hotswap()
    local store = require 'cartograph.store'
    if not store.data or next(store.moveset or {}) or store.txn then return end
    local back, fwd = store._nav_back, store._nav_fwd
    local focused = store.focused
    local loc = store.loc_provider and store.loc_provider.get()
    store.ingest(store.data)
    store._nav_back, store._nav_fwd = back or {}, fwd or {}
    if focused and store.node(focused) then store.set_focus(focused) end
    require('cartograph.toc').attach(store)
    if loc and store.loc_provider then pcall(store.loc_provider.set, loc) end
    store.redraw() -- non-browser subscribers (live projections) see the upgrade too
end

return M
