-- Territorial decomposition: partition the graph by WHICH ENTRY POINTS reach
-- each node (its entry-set), so the architecture falls out of reachability
-- with no clustering heuristic. Pure — entries + adjacency in, no store/UI.
--
--   territory  reached by exactly one entry  -> that feature's private code
--   commons    reached by several (not all)  -> a shared subsystem
--   core       reached by every entry        -> the universal core
--   (absent)   reached by none               -> unreached from the entries
--
-- BORDERS are the seams: a node whose entry-set is strictly larger than a live
-- caller's — the join where a feature's path first meets shared code, i.e. the
-- natural API of a shared subsystem. See [[cartograph-terminology]] (territory
-- / commons / core / border) and [[refactor-cockpit-design]].

local M = {}

--- Partition over `uses` (id -> callees) with border detection via `usedby`.
--- `entries` = the root ids. Returns:
---   node        id -> { entries=set, n=count, class, entry?, border? }
---              (only reached nodes appear)
---   k, entries, entry_index (id -> 1-based order, for stable per-entry colour)
function M.compute(entries, uses, usedby)
    local cone = require 'cartograph.cone'
    local reach, entry_index = {}, {}
    for i, e in ipairs(entries) do
        entry_index[e] = i
        local set = cone.reachable(e, uses)
        set[e] = true -- an entry reaches itself (its own territory's root)
        for id in pairs(set) do
            local r = reach[id]; if not r then r = {}; reach[id] = r end
            r[e] = true
        end
    end

    local k = #entries
    local node = {}
    for id, set in pairs(reach) do
        local n, only = 0, nil
        for e in pairs(set) do n = n + 1; only = e end
        -- territory checked before core so a single-entry graph reads as one
        -- territory, not a degenerate "core"
        local class = (n == 1 and 'territory') or (n == k and 'core') or 'commons'
        node[id] = { entries = set, n = n, class = class,
            entry = class == 'territory' and only or nil }
    end

    -- a border = some LIVE caller (itself reached) has a strictly smaller
    -- entry-set: stepping into this node crosses into more-shared ground
    for id, info in pairs(node) do
        for _, c in ipairs(usedby[id] or {}) do
            local ci = node[c]
            if ci and ci.n >= 1 and ci.n < info.n then info.border = true; break end
        end
    end

    return { node = node, k = k, entries = entries, entry_index = entry_index }
end

--- THE ROOTS, decided PER LANGUAGE (CART-1141). A language that has a DECLARED entry in this graph (its spec's
--- entry_names: c/go/erlang `main` …) is rooted in its declared entries; every other language in its APPARENT
--- sources — each function, method or top-level REGION (a script's top-level code, the v107 module-level owner of
--- its calls) that nothing calls. The switch used to be graph-wide: on the self graph six fixture `main`s turned the
--- fallback off for every Lua script, and the partition covered 19 of 20,802 nodes.
--- nodes = list; usedby = id -> callers; lang_of(file) -> lang | nil.
--- -> roots (node order), basis = { [lang] = { declared = bool, n = count } }
function M.roots(nodes, usedby, lang_of)
    local declared_in, chosen = {}, {}
    local function lang(n) return (n.file and lang_of(n.file)) or '?' end
    for _, n in ipairs(nodes) do
        if (n.kind == 'function' or n.kind == 'method') and n.entry then declared_in[lang(n)] = true end
    end
    local roots, basis = {}, {}
    for _, n in ipairs(nodes) do
        local k = n.kind
        if k == 'function' or k == 'method' or k == 'region' then
            local l = lang(n)
            local take
            if declared_in[l] then take = k ~= 'region' and n.entry
            else take = not (usedby[n.id] and #usedby[n.id] > 0) end
            if take and not chosen[n.id] then
                chosen[n.id] = true
                roots[#roots + 1] = n.id
                local b = basis[l] or { declared = declared_in[l] == true, n = 0 }
                b.n = b.n + 1
                basis[l] = b
            end
        end
    end
    return roots, basis
end

--- Counts for a one-line report: per-entry territory sizes + commons/core/borders.
function M.summary(t)
    local territories, commons, core, borders = {}, 0, 0, 0
    for _, info in pairs(t.node) do
        if info.class == 'territory' then
            territories[info.entry] = (territories[info.entry] or 0) + 1
        elseif info.class == 'commons' then
            commons = commons + 1
        elseif info.class == 'core' then
            core = core + 1
        end
        if info.border then borders = borders + 1 end
    end
    return { territories = territories, commons = commons, core = core, borders = borders }
end

-- ── TERRITORY AS A QUERY PLAN (CART-1142 S3): the composition, its operators, its laws ───────────────────────────
-- graph = { nodes = { id… }, uses = id -> callees, usedby = id -> callers }
--
--   NAIVE   (classify (invert (close_each ?seeds ?graph)) ?seeds ?graph)      one closure PER SEED: |S| x (|V| + |E|)
--   L1      (invert (close_each ?S ?G))  =>  (seedsets ?S ?G "worklist")        ONE closure over the lattice of seed
--           sets. Side condition: close_each is REACHABILITY (identity transfer, which distributes over union) and
--           the lattice's join is a semilattice (commutative, associative, idempotent) — both DECLARED, both read.
--   L2      (seedsets ?S ?G "worklist")  =>  (seedsets ?S ?G "scc")            the strongly connected components in
--           topological order: one pass over the DAG. Valid for any monotone solve.
local QP_READY
function M.qplan()
    local QP = require 'cartograph.qplan'
    if QP_READY then return QP_READY end
    local cone = require 'cartograph.cone'
    local solve = require 'cartograph.solve'
    local function W(st) return math.ceil(st.S / 32) end
    -- node -> bitset of the seeds reaching it: ONE forward solve
    local function seed_solve(seeds, g, strategy)
        local L = solve.lattice.bitset(#seeds)
        local index = {}
        for i, e in ipairs(seeds) do index[e] = i end
        local r = solve.solve { nodes = g.nodes, succ = g.uses, direction = 'forward', lattice = L, strategy = strategy,
            init = function (id) local i = index[id]; return i and L.single(i) or nil end }
        return L, r
    end
    -- the classes and the borders over node -> { entries, n, only }, shared by classify and classify_bits
    local function finish(info_of, seeds, g)
        local k, entry_index, node = #seeds, {}, {}
        for i, e in ipairs(seeds) do entry_index[e] = i end
        for id, x in pairs(info_of) do
            local class = (x.n == 1 and 'territory') or (x.n == k and 'core') or 'commons'
            node[id] = { entries = x.entries, n = x.n, class = class, entry = class == 'territory' and x.only or nil }
        end
        for id, info in pairs(node) do
            for _, c in ipairs(g.usedby[id] or {}) do
                local ci = node[c]
                if ci and ci.n >= 1 and ci.n < info.n then info.border = true; break end
            end
        end
        return { node = node, k = k, entries = seeds, entry_index = entry_index }
    end
    QP.register('close_each', {
        doc = 'per seed, the set of nodes it reaches (itself included)',
        props = { closure = 'reachability', transfer = 'identity', monotone = true },
        -- the per-seed walks visit only what each seed reaches: R (seed, node) pairs, each with its out-edges
        cost = function (st) return st.R * (1 + st.E / st.V) * st.units.hash end,
        run = function (seeds, g)
            local out = {}
            for _, e in ipairs(seeds) do
                local set = cone.reachable(e, g.uses)
                set[e] = true
                out[e] = set
            end
            return out
        end,
    })
    QP.register('invert', {
        doc = 'seed -> nodes, as node -> the set of seeds reaching it',
        cost = function (st) return st.R * st.units.hash end,
        run = function (m)
            local out = {}
            for e, set in pairs(m) do
                for id in pairs(set) do
                    local r = out[id]; if not r then r = {}; out[id] = r end
                    r[e] = true
                end
            end
            return out
        end,
    })
    QP.register('seedsets', {
        doc = 'node -> the set of seeds reaching it, as ONE monotone solve over a bitset lattice',
        props = { monotone = true, lattice = 'bitset' },
        -- every visit joins W-word bitsets over the node's in-edges; the worklist revisits (measured ~3x on the self
        -- graph), the component order visits once. Materializing the interned sets back is R.
        -- the solve: visits (measured 2.4-2.9 x |V| for the worklist, 1.1-1.2 x for components) x (1 + in-degree) x W
        -- at the solver's own measured unit; then R members materialized
        cost = function (st, lits)
            local visits = lits[3] == 'scc' and 1.2 or 2.6
            return visits * (st.V + st.E) * W(st) * st.units.edgeword + st.R * st.units.hash
        end,
        run = function (seeds, g, strategy)
            local L, r = seed_solve(seeds, g, strategy)
            local out, cache = {}, {}
            for id, v in pairs(r.value) do
                if v ~= L.bottom() then
                    -- equal values are one table (the join interns), so one materialized set serves them all
                    local set = cache[v]
                    if not set then
                        set = {}
                        for _, i in ipairs(L.members(v)) do set[seeds[i]] = true end
                        cache[v] = set
                    end
                    out[id] = set
                end
            end
            return out
        end,
    })
    QP.register('classify', {
        doc = 'territory / commons / core per node, and the borders',
        cost = function (st) return st.R * st.units.iter + (st.V + st.E) * st.units.hash end,
        run = function (reach, seeds, g)
            local info_of = {}
            for id, set in pairs(reach) do
                local n, only = 0, nil
                for e in pairs(set) do n = n + 1; only = e end
                info_of[id] = { entries = set, n = n, only = only }
            end
            return finish(info_of, seeds, g)
        end,
    })
    QP.register('classify_bits', {
        doc = 'classify straight off the solve\'s bitsets: each DISTINCT value counted (popcount) and materialized once',
        props = { equals = 'classify . seedsets' },
        -- the solve, then per distinct value W words and its members; V + E for the classes and borders
        cost = function (st, lits)
            local visits = lits[3] == 'scc' and 1.2 or 2.6
            return visits * (st.V + st.E) * W(st) * st.units.edgeword + st.R * st.units.hash
                + st.V * W(st) * st.units.word + (st.V + st.E) * st.units.hash
        end,
        run = function (seeds, g, strategy)
            local L, r = seed_solve(seeds, g, strategy)
            local info_of, cache = {}, {}
            for id, v in pairs(r.value) do
                if v ~= L.bottom() then
                    local x = cache[v]
                    if not x then
                        local set, only = {}, nil
                        for _, i in ipairs(L.members(v)) do set[seeds[i]] = true; only = seeds[i] end
                        x = { entries = set, n = L.count(v), only = only }
                        cache[v] = x
                    end
                    info_of[id] = x
                end
            end
            return finish(info_of, seeds, g)
        end,
    })
    local S, G = QP.input('seeds'), QP.input('graph')
    local A_hole = QP.input
    local plan = QP.op('classify', QP.op('invert', QP.op('close_each', S, G)), S, G)
    local laws = {
        QP.law('L1 multi-seed fusion', QP.op('invert', QP.op('close_each', S, G)),
            QP.op('seedsets', S, G, QP.const('worklist')),
            function ()
                local ce, lat = QP.OPS.close_each.props, require('cartograph.solve').lattice.bitset(1).props.join
                if ce.transfer ~= 'identity' then return false, 'close_each is not an identity-transfer closure' end
                if not (lat.commutative and lat.associative and lat.idempotent) then return false, 'the join is not a semilattice' end
                return true
            end),
        QP.law('L2 condensation', QP.op('seedsets', S, G, QP.const('worklist')), QP.op('seedsets', S, G, QP.const('scc')),
            function ()
                if not QP.OPS.seedsets.props.monotone then return false, 'seedsets is not monotone' end
                return true
            end),
    }
    -- L3 DEFORESTATION: the node -> set map between the solve and the classes is never built; each distinct value is
    -- counted and materialized once. Side condition: classify reads only each set's members and size
    laws[#laws + 1] = QP.law('L3 deforestation', QP.op('classify', QP.op('seedsets', S, G, A_hole('st')), S, G),
        QP.op('classify_bits', S, G, A_hole('st')),
        function ()
            if QP.OPS.classify_bits.props.equals ~= 'classify . seedsets' then return false, 'no declared equality' end
            return true
        end)
    QP_READY = { QP = QP, plan = plan, laws = laws }
    return QP_READY
end

--- the plan's STATISTICS: |V|, |E|, |S| counted, and R = the (seed, node) pairs the closures produce ESTIMATED by
--- walking every `step`-th seed (deterministic). The first cost model charged each seed the whole graph and
--- predicted a 31x gain that measured 1.1x: most seeds reach a handful of nodes, and R is what the walks cost.
function M.qplan_stats(seeds, g, step)
    local cone = require 'cartograph.cone'
    local E = 0
    for _, cs in pairs(g.uses) do E = E + #cs end
    step = step or math.max(1, math.floor(#seeds / 64))
    local walked, reached = 0, 0
    for i = 1, #seeds, step do
        walked = walked + 1
        local n = 1
        for _ in pairs(cone.reachable(seeds[i], g.uses)) do n = n + 1 end
        reached = reached + n
    end
    local R = walked > 0 and (reached / walked) * #seeds or 0
    return { V = #g.nodes, E = E, S = #seeds, R = R, sampled = walked, units = require('cartograph.qplan').units() }
end

--- the SAMPLER for qplan.sampled_cost: every k-th seed, the graph unchanged (both the per-seed walks and the bitset
--- width grow with the seeds, so the cost is a line in their number)
function M.qplan_sample(inputs, k)
    local s = {}
    for i = 1, #inputs.seeds, k do s[#s + 1] = inputs.seeds[i] end
    return { seeds = s, graph = inputs.graph }
end

--- a territory's ROWS for the checker: one per reached node — class, count, owning entry, border, and the entry set
function M.rows(t)
    local out = {}
    for id, info in pairs(t.node) do
        local es = {}
        for e in pairs(info.entries) do es[#es + 1] = tostring(e) end
        table.sort(es)
        out[id] = ('%s %d %s %s [%s]'):format(info.class, info.n, tostring(info.entry), info.border and 'B' or '-',
            table.concat(es, ','))
    end
    return out
end

return M
