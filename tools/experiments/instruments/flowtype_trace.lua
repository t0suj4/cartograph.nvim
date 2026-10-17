-- the SOLVE as a bounded graph (flowtype experiment `trace`, CART-1697): ports folded onto the function the walk made
-- them in (a field cell: `cell <owner's function>.<field>`), deliveries of new objects counted per (source, destination,
-- kind), fan-in, saturation order, prototype replays. A function node's id is its code-graph id (`file::name@line`).
-- params: root (default: the cwd), mode = closed | open (default closed), out = <file.json> (the graph), top = K (20)
-- Output: the report (MERGE / EDGE / SAT / REPLAY lines), and the graph { nodes = [{id, fanin, maxset, sat, nsat,
-- replay}], edges = [{from, to, kind, n}] } in `out`. Other experiments come from CARTOGRAPH_FLOWTYPE_EXP.
return { measure = function (_, params)
    params = params or {}
    local root = params.root or vim.fn.getcwd()
    local K = tonumber(params.top or 20)
    local store = require 'cartograph.store'
    store.ingest(require('cartograph.providers.treesitter').extract(root))
    local t0 = vim.uv.hrtime()
    local R = require('cartograph.flowtype').solve(store, { open = params.mode == 'open', ctx = false, exp = 'trace' })
    local secs = (vim.uv.hrtime() - t0) / 1e9
    local T = R.trace
    local nodes, edges = {}, {}
    local function node(id) local n = nodes[id]; if not n then n = { id = id }; nodes[id] = n end; return n end
    for k, n in pairs(T.edges) do
        local a, b, kind = k:match('^(.-)\t(.-)\t(.*)$')
        edges[#edges + 1] = { from = a, to = b, kind = kind, n = n }
        node(a); node(b)
    end
    for id, f in pairs(T.fanin) do node(id).fanin = f end
    for id, m in pairs(T.maxset) do node(id).maxset = m end
    for id, s in pairs(T.sat) do node(id).sat = s; node(id).nsat = T.nsat[id] end
    for id, r in pairs(T.replay) do node(id).replay = r end
    local nl = {}
    for _, n in pairs(nodes) do nl[#nl + 1] = n end
    table.sort(nl, function (a, b) return a.id < b.id end)
    table.sort(edges, function (a, b) if a.n ~= b.n then return a.n > b.n end return a.from .. a.to .. a.kind < b.from .. b.to .. b.kind end)
    -- ★ IN THE EXISTING SCHEMA (user: "can't it be translated into the existing schema?"): a graph of its own, root
    -- `trace://<root>`, that cartograph.validate accepts and store.ingest loads — a function keeps its code-graph node, a
    -- file chunk is its MODULE node (module ids are file paths), a field cell a `var` node in its owner's file, an owner the
    -- tree has no node for (_G, the string library, a type) the synthetic module `solver`; a delivery is a `use` edge (the
    -- destination uses values from the source) with origin `derived`, via `solve:<kind>` and atn = the deliveries. The node
    -- statistics ride in `data`. Its own graph, so no analysis that reads the code graph's `use` edges sees these
    local function schema()
        local Z = { line = 0, char = 0 }
        local out, map = { root = 'trace://' .. root, nodes = {}, edges = {} }, {}
        local function add(n) if not map[n.id] then map[n.id] = n; n.order = #out.nodes + 1; out.nodes[#out.nodes + 1] = n end; return n.id end
        local solver = add({ id = 'solver', name = 'solver', kind = 'module', file = 'solver', range = { start = Z, ['end'] = Z } })
        local function code(id)
            local n = store.node(id)
            if not n then return nil end
            return add({ id = n.id, name = n.name, kind = n.kind == 'method' and 'method' or (n.kind == 'module' and 'module' or 'function'), file = n.file,
                range = n.range and { start = { line = require('cartograph.at').sl(n.range), char = 0 }, ['end'] = { line = require('cartograph.at').el(n.range), char = 0 } } or { start = Z, ['end'] = Z } })
        end
        local function of(tid)
            local cell, f = tid:match('^cell (.*)%.([^.]*)$')
            if cell then
                local owner = of(cell)
                local on = map[owner]
                return add({ id = 'cell:' .. tid:sub(6), name = (on and on.name or owner) .. '.' .. f, kind = 'var', file = on and on.file or 'solver',
                    range = on and on.range or { start = Z, ['end'] = Z } })
            end
            local file = tid:match('^chunk:(.*)$')
            return (file and code(file)) or code(tid) or solver
        end
        for _, n in ipairs(nl) do
            local id = of(n.id)
            local z = map[id]
            z.data = z.data or {}
            for _, k in ipairs({ 'fanin', 'maxset', 'sat', 'nsat', 'replay' }) do
                if n[k] then z.data[k] = math.max(z.data[k] or 0, n[k]) end
            end
        end
        local agg = {}
        for _, e in ipairs(edges) do
            local a, b = of(e.from), of(e.to)
            if a ~= b then
                local k = a .. '\t' .. b .. '\t' .. e.kind
                local x = agg[k]
                if not x then x = { from = a, to = b, kind = 'use', origin = 'derived', via = 'solve:' .. e.kind, at = {}, atn = 0 }; agg[k] = x; out.edges[#out.edges + 1] = x end
                x.atn = x.atn + e.n
            end
        end
        return out
    end
    if params.out then
        local data = schema()
        local V = require 'cartograph.validate'
        io.write('SCHEMA ', (V.report(V.check(data)):gsub('\n', ' | ')), '\n')
        local fd = assert(io.open(params.out, 'w'))
        fd:write(vim.json.encode(data))
        fd:close()
    end
    -- the report: where sets MERGE (fan-in x the largest set held), the heaviest deliveries, the first saturations, replays
    local merge = {}
    for _, n in ipairs(nl) do if (n.fanin or 0) >= 3 then merge[#merge + 1] = n end end
    table.sort(merge, function (a, b) local x, y = (a.fanin or 0) * (a.maxset or 64), (b.fanin or 0) * (b.maxset or 64); if x ~= y then return x > y end return a.id < b.id end)
    for i = 1, math.min(K, #merge) do local n = merge[i]; io.write(('MERGE\tfanin %d\tmaxset %s\tsat %s\t%s\n'):format(n.fanin, n.maxset and tostring(n.maxset) or 'TOP', tostring(n.nsat or 0), n.id)) end
    for i = 1, math.min(K, #edges) do local e = edges[i]; io.write(('EDGE\t%d\t%s\t%s -> %s\n'):format(e.n, e.kind, e.from, e.to)) end
    local sat = {}
    for _, n in ipairs(nl) do if n.sat then sat[#sat + 1] = n end end
    table.sort(sat, function (a, b) return a.sat < b.sat end)
    for i = 1, math.min(K, #sat) do local n = sat[i]; io.write(('SAT\t#%d\tx%d\t%s\n'):format(n.sat, n.nsat or 1, n.id)) end
    local rep = {}
    for _, n in ipairs(nl) do if n.replay then rep[#rep + 1] = n end end
    table.sort(rep, function (a, b) return a.replay > b.replay end)
    for i = 1, math.min(K, #rep) do local n = rep[i]; io.write(('REPLAY\t%d\t%s\n'):format(n.replay, n.id)) end
    io.write(('TRACE nodes %d edges %d saturations %d solve %.1f s\n'):format(#nl, #edges, T.seq, secs))
    return { holds = true, why = ('%d nodes, %d edges'):format(#nl, #edges) }
end }
