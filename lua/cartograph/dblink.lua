-- Code ↔ database cross-linking: the SQL entities mined from query
-- strings (sql::table:*) meet the tables a live database actually has
-- (a recipe graph, e.g. postgres over MCP). The db's table entities and
-- FK edges are imported into the code graph (marked db = true) and each
-- code-side entity links to its table by name — PREFIX-AWARE, so
-- {$wpdb->posts} meets wp_posts; the prefix is auto-detected from the
-- schema when not configured; ambiguity refuses. What falls out is the
-- wiretap-shaped audit: tables the code queries that the database lacks
-- (typo or missing migration) and tables the database holds that no
-- code queries.
--
-- The attachment is a SESSION post-pass like clangd/xlang: re-derived
-- per open (through the db's own shard cache, so it costs one stamps
-- round-trip), never persisted into the code graph's shards.
--
--   setup{ db = { source = 'pg' } }   -- an entry under setup{ mcp = … }

local M = {}

local R0 = { start = { line = 0, char = 0 }, ['end'] = { line = 0, char = 0 } }

--- Auto-detect the installation prefix: the most common '<word>_'
--- prefix, when a majority of tables carry it.
function M.prefix_of(names)
    local count, total = {}, 0
    for _, n in ipairs(names) do
        total = total + 1
        local p = n:match('^(%w-_)')
        if p then count[p] = (count[p] or 0) + 1 end
    end
    local best, bn
    for p, c in pairs(count) do
        if not bn or c > bn or (c == bn and p < best) then best, bn = p, c end
    end
    return (best and bn * 2 > total) and best or nil
end

--- PURE: import `db`'s entities into `data` and link the code-side
--- sql:: entities to them. Idempotent: a previous attachment (db-marked
--- nodes/edges) is stripped first, so refresh can re-run it. Publishes
--- and returns the audit { matched, missing = { {name, why?} },
--- unused = {names}, prefix }.
function M.link(data, db, opts)
    -- strip a previous attachment
    local dbids, nodes = {}, {}
    for _, n in ipairs(data.nodes) do
        if n.db then dbids[n.id] = true else nodes[#nodes + 1] = n end
    end
    data.nodes = nodes
    local edges = {}
    for _, e in ipairs(data.edges) do
        if not (e.db or dbids[e.from] or dbids[e.to]) then
            edges[#edges + 1] = e
        end
    end
    data.edges = edges

    -- import the db's nodes and FK edges, collect tables by lowered name
    local tablenames, byname = {}, {}
    for _, n in ipairs(db.nodes) do
        local copy = {}
        for k, v in pairs(n) do copy[k] = v end
        copy.db = true
        data.nodes[#data.nodes + 1] = copy
        if n.kind == 'var' then
            tablenames[#tablenames + 1] = n.name
            local low = n.name:lower()
            byname[low] = byname[low] or {}
            table.insert(byname[low], copy)
        end
    end
    for _, e in ipairs(db.edges) do
        local copy = {}
        for k, v in pairs(e) do copy[k] = v end
        copy.db = true
        data.edges[#data.edges + 1] = copy
    end

    local prefix = (opts and opts.prefix) or M.prefix_of(tablenames)
    local out = { matched = 0, missing = {}, unused = {}, prefix = prefix }
    local used = {}
    for _, n in ipairs(data.nodes) do
        local key = not n.db and n.id:match('^sql::table:(.+)$')
        if key then
            local cands = byname[key]
                or (prefix and byname[prefix .. key]) or nil
            if cands and #cands == 1 then
                data.edges[#data.edges + 1] = { from = n.id,
                    to = cands[1].id, kind = 'use', at = { R0 }, db = true }
                out.matched = out.matched + 1
                used[cands[1].id] = true
            elseif cands then
                out.missing[#out.missing + 1] = { name = key,
                    why = ('%d same-named tables'):format(#cands) }
            else
                out.missing[#out.missing + 1] = { name = key }
            end
        end
    end
    for _, list in pairs(byname) do
        for _, n in ipairs(list) do
            if not used[n.id] then
                out.unused[#out.unused + 1] = n.name
            end
        end
    end
    table.sort(out.missing, function (a, b) return a.name < b.name end)
    table.sort(out.unused)
    data.dblink = out
    return out
end

--- Fetch the database graph (through its OWN shard cache — one stamps
--- round-trip when unchanged) and link it in. Session-cached per
--- source: refreshes reuse the fetched schema; the next open
--- re-verifies. Returns the audit or (nil, why).
M._db = {}
function M.attach(data)
    local cfg = require('cartograph.config').db
    if not (cfg and cfg.source) then return nil end
    local db = M._db[cfg.source]
    if not db then
        local cache = require 'cartograph.cache'
        db = cache.open('mcp://' .. cfg.source)
        if not db then
            local err
            db, err = require('cartograph.providers.mcp').extract(cfg.source)
            if not db then return nil, err end
            cache.save(db)
        end
        M._db[cfg.source] = db
    end
    return M.link(data, db, cfg)
end

return M
