-- String-embedded SQL (pure post-pass over the neutral schema). Query
-- strings in call arguments carry real structure: the TABLES they touch.
-- Each table becomes a first-class entity — a synthetic var node anchored
-- at its first query — with `use` edges from every function that queries
-- it, so the existing var machinery answers "who touches wp_posts" as an
-- ordinary sites view. Reads and writes are distinguished; interpolated
-- table names ({$wpdb->posts}) stay honest misses.

local M = {}

local KIND = {
    select = 'read', insert = 'write', update = 'write', delete = 'write',
    replace = 'write', create = 'ddl', alter = 'ddl', drop = 'ddl',
    truncate = 'write',
}

-- Table patterns per query kind, matched against the ORIGINAL string:
-- code SQL capitalizes its keywords, and matching case is what keeps an
-- email template's <table cellspacing=...> from corroborating anything.
-- The interpolation variants capture php's {$wpdb->posts} style, where
-- the property name IS the table.
local function pats_for(keyword)
    return {
        keyword .. '%s+`?([%w_%.]+)`?',
        keyword .. '%s+{?%$[%w_]+%->([%w_]+)',
        -- {$this->getTable('sales/order')}: the ARGUMENT is the table
        keyword .. [=[%s+{?%$[%w_]+%->[%w_]+%(%s*['"]([%w_/%.]+)['"]]=],
    }
end
local KIND_PATS = {
    read   = { pats_for('FROM'), pats_for('JOIN') },
    update = { pats_for('UPDATE'), pats_for('FROM'), pats_for('JOIN') },
    insert = { pats_for('INTO') },
    delete = { pats_for('FROM') },
    ddl    = { { 'TABLE%s+IF%s+EXISTS%s+`?([%w_%.]+)`?' }, pats_for('TABLE') },
}
local VERB_PATS = {
    select = 'read', insert = 'insert', replace = 'insert',
    update = 'update', delete = 'delete', truncate = 'ddl',
    create = 'ddl', alter = 'ddl', drop = 'ddl',
}

-- SQL's own vocabulary and prose debris are never table names
local NOT_TABLES = { ['if'] = true, exists = true, cascade = true, set = true,
    where = true, select = true, dual = true, ['not'] = true, null = true,
    key = true, index = true, values = true, into = true, table = true,
    on = true, the = true, to = true, ['and'] = true, a = true, an = true,
    this = true, your = true, all = true, new = true, convert = true,
    character = true, duplicate = true }

--- Parse one string: nil unless it starts with an UPPERCASE SQL verb and
--- names at least one table. Returns { kind, tables }.
function M.parse(str)
    if type(str) ~= 'string' or #str < 8 then return nil end
    local verb = str:match('^%s*(%u+)%f[%W]')
    local pk = verb and VERB_PATS[verb:lower()]
    if not pk then return nil end
    local kind = KIND[verb:lower()]
    local tables, seen = {}, {}
    for _, group in ipairs(KIND_PATS[pk]) do
        for _, pat in ipairs(group) do
            local init = 1
            while true do
                local s2, e2, name = str:find(pat, init)
                if not s2 then break end
                init = e2 + 1
                -- a captured name followed by '(' is a CALL, not a table
                if str:sub(e2 + 1, e2 + 1) == '(' then name = '' end
                local low = name:lower()
                if not seen[low] and not low:match('^%d') and #name >= 2
                    and not NOT_TABLES[low] then
                    seen[low] = true
                    tables[#tables + 1] = name
                end
            end
        end
    end
    if #tables == 0 then return nil end
    return { kind = kind, tables = tables }
end

--- Scan the call inventory for SQL strings. Returns
--- { tables = { [name] = { reads = n, writes = n, ddl = n,
---   sites = { {call, kind}, ... } } }, queries = n }.
function M.scan(data)
    local tables, nq = {}, 0
    for _, c in ipairs(data.calls or {}) do
        for _, a in ipairs(c.args or {}) do
            local q = a ~= '' and M.parse(a)
            if q then
                nq = nq + 1
                for _, t in ipairs(q.tables) do
                    local e = tables[t]
                    if not e then
                        e = { reads = 0, writes = 0, ddl = 0, sites = {} }
                        tables[t] = e
                    end
                    e[q.kind == 'read' and 'reads'
                        or q.kind == 'ddl' and 'ddl' or 'writes'] =
                        e[q.kind == 'read' and 'reads'
                            or q.kind == 'ddl' and 'ddl' or 'writes'] + 1
                    table.insert(e.sites, { call = c, kind = q.kind })
                end
                break -- one SQL string per call is the signal
            end
        end
    end
    return { tables = tables, queries = nq }
end

--- Attach tables as entities: synthetic var nodes + use edges from each
--- touching function, anchored at the first query. Pure over `data`
--- (pre-ingest, like xlang.link). Returns stats.
function M.attach(data)
    local scanned = M.scan(data)
    local stats = { tables = 0, edges = 0, queries = scanned.queries }
    local line_cache = {}
    local function key_range(c, key)
        if line_cache[c.file] == nil then
            local fd = io.open(data.root .. '/' .. c.file, 'r')
            line_cache[c.file] = fd
                and vim.split(fd:read('a'), '\n', { plain = true }) or false
            if fd then fd:close() end
        end
        local lines = line_cache[c.file]
        for l = c.line, math.min(c.line + 4, lines and #lines - 1 or c.line) do
            local text = lines and lines[l + 1] or ''
            local s, e = text:find(key, 1, true)
            if s then
                return { start = { line = l, char = s - 1 },
                    ['end'] = { line = l, char = e } }
            end
        end
        return { start = { line = c.line, char = 0 },
            ['end'] = { line = c.line, char = 0 } }
    end

    local names = {}
    for t in pairs(scanned.tables) do names[#names + 1] = t end
    table.sort(names)
    for _, t in ipairs(names) do
        local e = scanned.tables[t]
        local first = e.sites[1].call
        local id = 'sql::table:' .. t:lower()
        data.nodes[#data.nodes + 1] = { id = id, name = 'table ' .. t,
            kind = 'var', sql = true, file = first.file,
            order = first.line,
            range = key_range(first, t) }
        stats.tables = stats.tables + 1
        local per_fn = {}
        for _, site in ipairs(e.sites) do
            local fn = site.call.fn
            if fn then
                local edge = per_fn[fn]
                if not edge then
                    edge = { from = fn, to = id, kind = 'use', at = {} }
                    per_fn[fn] = edge
                    data.edges[#data.edges + 1] = edge
                    stats.edges = stats.edges + 1
                end
                table.insert(edge.at, key_range(site.call, t))
            end
        end
    end
    data.sql = { tables = stats.tables, queries = stats.queries }
    return stats
end

return M
