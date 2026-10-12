-- THE GRAPH an extraction produces, as rows a `join` instrument compares across two trees: one row per store.data
-- table, `ROW\tdata:<name>\tn=<entries> sha=<digest>` — the digest a MERKLE hash (each table hashes its sorted keys
-- and its children's digests, so a table shared by many parents costs its hash, not its text; a cycle prints
-- `<cycle>`; functions and userdata are skipped, so `_atcol` — accessor functions only — prints the empty digest; the
-- packed columns are strings and hashed whole). The gate for a change that must not move the graph — a cache, a
-- memo, a walk that reads less (CART-1659: 2392 rows with lintrows equal on the 428-file corpus). Pair it with
-- lintrows.lua for the findings. Checked sensitive: dropping one parameter from param_map moves calls and edges.
--   nvim --headless -u NONE -l tools/toolbelt.lua run @tools/experiments/instruments/graphrows.lua - dir=<abs dir>
return { measure = function (_, params)
    local dir = params and params.dir or (vim.fn.getcwd() .. '/lua')
    local store = require 'cartograph.store'
    store.ingest(require('cartograph.providers.treesitter').extract(dir))
    local memo, onpath = {}, {}
    local function digest(v)
        local t = type(v)
        if t ~= 'table' then return (t == 'userdata' or t == 'function') and '?' or tostring(v) end
        if memo[v] then return memo[v] end
        if onpath[v] then return '<cycle>' end
        onpath[v] = true
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = k end
        table.sort(keys, function (a, b) return tostring(a) < tostring(b) end)
        local parts = {}
        for _, k in ipairs(keys) do
            local x = v[k]
            if type(x) ~= 'userdata' and type(x) ~= 'function' then parts[#parts + 1] = tostring(k) .. '=' .. digest(x) end
        end
        onpath[v] = nil
        local r = '#' .. vim.fn.sha256(table.concat(parts, ',')):sub(1, 20)
        memo[v] = r
        return r
    end
    local names = {}
    for k, v in pairs(store.data) do if type(v) == 'table' then names[#names + 1] = k end end
    table.sort(names)
    for _, k in ipairs(names) do
        local n = 0
        for _ in pairs(store.data[k]) do n = n + 1 end
        io.write(('ROW\tdata:%s\tn=%d sha=%s\n'):format(k, n, digest(store.data[k])))
    end
    io.write(('GRAPH %d tables\n'):format(#names))
    return {}
end }
