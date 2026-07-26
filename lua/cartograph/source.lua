-- The source capability layer: a graph's treatment is decided by what
-- its source CAN DO, not by its provider's name. Capabilities are mostly
-- derived from the data's shape (stamps present? names present?); the
-- registry supplies the behavioral half (can it diff? re-extract a
-- slice?). The rules downstream are theorems over this contract:
--
--   persistable   <=> stamps      (wire-free validity keys)
--   warm-openable <=> stamps and diff and refresh
--   reconcilable  <=> refresh and idpass and names
--   stale-markable<=> stamps and a filesystem root
--   dated display <=> sample (fetched_at, no stamps)
--
-- This is what makes "a Postgres introspector that stamps its tables"
-- cache like a source tree: table <=> shard, catalog check <=> diff,
-- and a warm open re-scans only tables whose definition changed.

local M = { providers = {} }
local transport = require 'cartograph.transport' -- single owner of the validity key (stamp)

function M.register(p)
    M.providers[p.name] = p
end

--- Registry entry for a graph (provider prefix before ':').
function M.provider(data)
    local name = data and data.provider or ''
    return M.providers[name:match('^([^:]+)') or name]
end

--- The capability view of a graph.
function M.caps(data)
    local p = M.provider(data)
    local stamps = data.stamps ~= nil
    return {
        stamps  = stamps,
        names   = data.names ~= nil,
        diff    = (p and p.diff) ~= nil,
        refresh = (p and p.refresh_slice) ~= nil,
        idpass  = (p and p.idpass) or false,
        fs      = not (data.root or ''):match('^%w+://'),
        sample  = data.fetched_at ~= nil and not stamps,
        -- per-site calls: a provider may AGGREGATE call sites into reference
        -- edges instead of recording them one by one — the token provider does,
        -- because a Forth word mention IS a reference and nothing more, and it
        -- declares `capabilities.calls = 'aggregated'`. A verb answering FROM
        -- call records must then say THAT, rather than present its empty result
        -- as "nothing calls this": attributing an absence to the wrong cause is
        -- precisely what the honesty vocabulary forbids.
        per_site_calls = (data.capabilities or {}).calls ~= 'aggregated',
    }
end

-- ── the tree-sitter source: filesystem substrate, full contract ──────────────
M.register {
    name = 'treesitter',
    idpass = true,
    -- diff by walking the tree with extraction's own rules and comparing
    -- stamps; new files are 'changed' (no stamp), bundles count only when
    -- they appear or vanish (content churn is the frontier machinery's)
    diff = function (meta)
        local ts = require 'cartograph.providers.treesitter'
        local files, minified = ts.list_files(meta.root)
        local changed, deleted, on_disk = {}, {}, {}
        for _, f in ipairs(files) do
            on_disk[f] = true
            -- the RECORD level asking the BYTE level for a validity key: the
            -- one call that lets a non-filesystem substrate be diffed and
            -- warm-opened at all (this used to fs_stat inline)
            local now = transport.stamp(meta.root .. '/' .. f)
            if meta.stamps[f] ~= now then changed[#changed + 1] = f end
        end
        local un = {}
        for _, f in ipairs(meta.unparsed or {}) do un[f] = true end
        for _, f in ipairs(minified) do
            on_disk[f] = true
            if not un[f] then changed[#changed + 1] = f end
        end
        for f in pairs(meta.stamps) do
            if not on_disk[f] then deleted[#deleted + 1] = f end
        end
        for f in pairs(un) do
            if not on_disk[f] then deleted[#deleted + 1] = f end
        end
        table.sort(changed)
        table.sort(deleted)
        return changed, deleted
    end,
    refresh_slice = function (data, rels, fileset)
        return require('cartograph.providers.treesitter').extract(data.root,
            { subdirs = rels, fileset = fileset, skip_idpass = true })
    end,
}

-- ── the MCP source: substrate iff the server stamps its keys ─────────────────
M.register {
    name = 'mcp',
    diff = function (meta)
        return require('cartograph.providers.mcp').diff(meta)
    end,
    refresh_slice = function (data, rels)
        local name = (data.provider or ''):match('^mcp:(.+)$')
        return require('cartograph.providers.mcp').extract(name, { only = rels })
    end,
}

return M
