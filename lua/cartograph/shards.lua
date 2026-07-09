-- Workers produce CSR: turn resolved extract output into per-module CSR SHARDS
-- + a sparse cross-edge table + a directory (the name-index). This is the
-- "produce CSR before we ingest it" output shape (fed to the pre-merge
-- benchmark / virtual-vs-physical merge).
--
-- Sharded LEAN form (the one that measured size-neutral, not the global-id
-- trap): each shard interns its nodes into its OWN 0-based space and holds only
-- its INTRA-module ref-edges as a CSR; cross-module edges are kept as sparse
-- {from,to} node-key pairs (resolvable through the directory = a name-index
-- lookup, i.e. a "port"); `dir` maps node-key → module.
--
-- NB: this shards a fully-resolved (monolithic) extract — the on-ramp. True
-- per-worker LOCAL resolution (the map/reduce streaming split) is a later
-- refactor; this produces the shard artifacts from today's extract.

local csr = require 'cartograph.csr'

local M = {}

local function dirname(f) return (f and f:match('^(.*)/[^/]*$')) or '' end

-- from_extract(data, module_of) → { shards = {mod -> {csr, it, n}},
--   cross = {{from,to}...}, dir = {node_key -> mod}, dropped = <count> }.
-- module_of(file) → module key; default = the file's containing directory.
-- EVERY node is homed (a local id in its module's shard), not just ref-edge
-- endpoints — the shards are the graph, and isolated nodes are part of it.
-- `dropped` counts ref edges whose endpoint has no node entry: conservation
-- (edge_count) covers what was KEPT; dropped makes the difference honest.
function M.from_extract(data, module_of)
    module_of = module_of or dirname
    local nfile = {}
    for _, n in ipairs(data.nodes or {}) do nfile[n.id] = n.file end
    local function modof(id) local f = nfile[id]; return f and module_of(f) or '?' end

    local build = {} -- mod -> { it, from, to }
    local function shard(mod)
        local s = build[mod]
        if not s then s = { it = csr.interner(), from = {}, to = {} }; build[mod] = s end
        return s
    end

    local dir = {}
    for _, n in ipairs(data.nodes or {}) do -- home the full roster first
        local mod = modof(n.id)
        dir[n.id] = mod
        shard(mod).it.id(n.id)
    end

    local cross, dropped = {}, 0
    for _, e in ipairs(data.edges or {}) do
        if e.kind == 'ref' then
            if nfile[e.from] and nfile[e.to] then
                local ma, mb = dir[e.from], dir[e.to]
                if ma == mb then
                    local s = shard(ma)
                    s.from[#s.from + 1] = s.it.id(e.from)
                    s.to[#s.to + 1] = s.it.id(e.to)
                else
                    cross[#cross + 1] = { from = e.from, to = e.to }
                end
            else
                dropped = dropped + 1
            end
        end
    end

    local shards = {}
    for mod, s in pairs(build) do
        local n = s.it.count()
        shards[mod] = { csr = csr.build(s.from, s.to, n), it = s.it, n = n }
    end
    return { shards = shards, cross = cross, dir = dir, dropped = dropped }
end

-- locate a node key → module, local-id (read-only). nil if unknown.
function M.locate(sharded, key)
    local mod = sharded.dir[key]
    if not mod then return nil end
    return mod, sharded.shards[mod].it.get(key)
end

-- total ref-edges represented = Σ shard CSR edges + cross edges (conservation)
function M.edge_count(sharded)
    local m = #sharded.cross
    for _, s in pairs(sharded.shards) do m = m + s.csr.m end
    return m
end

return M
