-- Postgres over a GENERIC SQL-speaking MCP server (postgres-mcp's
-- execute_sql): the recipe turns catalog introspection into the neutral
-- schema. Tables become entities — a module per table, a var node whose
-- litdata is the column list (l descends into it) — foreign keys become
-- use edges between tables, and every table is STAMPED with a definition
-- fingerprint, so the scan is SUBSTRATE: it caches, and a warm open
-- re-introspects only tables whose definition changed. Every query is a
-- catalog read: read-only credentials are sufficient by construction.
--
--   setup{ mcp = { pg = {
--     cmd = { 'postgres-mcp', '--access-mode=restricted', '<database-url>' },
--     recipe = 'postgres',
--   } } }        then :Cartograph mcp://pg

local M = {}

-- postgres-mcp wraps rows in a Python repr: [{'j': '<json>'}] — every
-- recipe query emits exactly one row with one json-text column `j`, so
-- the repr layer never has to be parsed beyond this envelope
local function unwrap(raw, why)
    if type(raw) ~= 'string' then
        return nil, 'query failed: ' .. tostring(why or raw)
    end
    local j = raw:match("^%[%{'j': '(.*)'%}%]%s*$")
    if not j then
        return nil, 'unrecognized response shape: ' .. raw:sub(1, 120)
    end
    local ok, v = pcall(vim.json.decode, (j:gsub("\\'", "'")))
    if not ok then return nil, 'undecodable json in response' end
    return v
end

local NOT_SCHEMAS = "('pg_catalog','information_schema')"

-- restrict a query to specific table keys (incremental re-fetch)
local function keyfilter(only, expr)
    if not only then return '' end
    local quoted = {}
    for _, k in ipairs(only) do
        quoted[#quoted + 1] = "'" .. tostring(k):gsub("'", "''") .. "'"
    end
    return (' AND %s IN (%s)'):format(expr, table.concat(quoted, ','))
end

local function q_stamps(only)
    return [[SELECT coalesce(json_object_agg(key, stamp), '{}'::json)::text AS j FROM (
SELECT 'tables/' || table_schema || '.' || table_name AS key,
       md5(string_agg(column_name || ':' || data_type || ':'
           || coalesce(character_maximum_length::text, ''), ','
           ORDER BY ordinal_position)) AS stamp
FROM information_schema.columns
WHERE table_schema NOT IN ]] .. NOT_SCHEMAS
        .. keyfilter(only, "'tables/' || table_schema || '.' || table_name")
        .. ' GROUP BY 1) t'
end

local function q_columns(only)
    return [[SELECT coalesce(json_agg(row_to_json(t)), '[]'::json)::text AS j FROM (
SELECT table_schema AS s, table_name AS n,
       json_agg(json_build_object('c', column_name, 't', data_type)
           ORDER BY ordinal_position) AS cols
FROM information_schema.columns
WHERE table_schema NOT IN ]] .. NOT_SCHEMAS
        .. keyfilter(only, "'tables/' || table_schema || '.' || table_name")
        .. ' GROUP BY 1, 2 ORDER BY 1, 2) t'
end

local function q_fks(only)
    return [[SELECT coalesce(json_agg(row_to_json(t)), '[]'::json)::text AS j FROM (
SELECT tc.table_schema AS s, tc.table_name AS n,
       ccu.table_schema AS fs, ccu.table_name AS fn
FROM information_schema.table_constraints tc
JOIN information_schema.constraint_column_usage ccu
  ON ccu.constraint_name = tc.constraint_name
 AND ccu.constraint_schema = tc.constraint_schema
WHERE tc.constraint_type = 'FOREIGN KEY'
  AND tc.table_schema NOT IN ]] .. NOT_SCHEMAS
        .. keyfilter(only, "'tables/' || tc.table_schema || '.' || tc.table_name")
        .. ' ORDER BY 1, 2) t'
end

local R0 = { start = { line = 0, char = 0 }, ['end'] = { line = 0, char = 0 } }

local function table_key(s, n) return ('tables/%s.%s'):format(s, n) end
local function var_id(s, n)
    return ('%s::table:%s@0'):format(table_key(s, n), n)
end

--- Build the neutral graph through `sql(query) -> raw, err`.
--- opts.only limits to those table keys (the incremental slice).
function M.extract(sql, opts)
    local only = opts and opts.only
    local stamps, e1 = unwrap(sql(q_stamps(only)))
    if not stamps then return nil, e1 end
    local tabs, e2 = unwrap(sql(q_columns(only)))
    if not tabs then return nil, e2 end
    local fks, e3 = unwrap(sql(q_fks(only)))
    if not fks then return nil, e3 end

    local data = { schema = 1, nodes = {}, edges = {}, calls = {},
        stamps = {} }
    for k, v in pairs(stamps) do data.stamps[k] = v end
    for _, t in ipairs(tabs) do
        local file = table_key(t.s, t.n)
        data.nodes[#data.nodes + 1] = { id = file, name = file,
            kind = 'module', file = file, order = -1, range = R0 }
        local cols = {}
        for _, c in ipairs(t.cols or {}) do
            cols[#cols + 1] = { k = 'lit', v = ('%s %s'):format(c.c, c.t) }
        end
        data.nodes[#data.nodes + 1] = { id = var_id(t.s, t.n),
            name = t.s == 'public' and t.n or (t.s .. '.' .. t.n),
            kind = 'var', file = file, order = 0, range = R0, data = cols }
    end
    -- foreign keys: the database's own dependency graph. Ids are
    -- deterministic, so an edge into an UNCHANGED table (absent from an
    -- incremental slice) still lands on its cached node.
    for _, k in ipairs(fks) do
        data.edges[#data.edges + 1] = { from = var_id(k.s, k.n),
            to = var_id(k.fs, k.fn), kind = 'use', at = { R0 } }
    end
    return data
end

--- Current fingerprints, for the warm-open diff (one catalog query).
function M.stamps(sql)
    return unwrap(sql(q_stamps()))
end

return M
