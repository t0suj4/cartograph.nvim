-- A PART OF `cartograph.algebra.core`, which requires this file at its end and
-- passes its own module table in. ⚠ IT DOES NOT `require` CORE BACK: that is a
-- load cycle — Lua says "loop or previous error loading module".
-- ★ TWO SHARED FILE-LOCALS, AND THE UNION WAS PRUNED TWICE OVER. The capture
-- hazards named four (`family`, `family_of`, `template`, `values`); the
-- free-identifier scan named one (`family_of`). `template` and `values` are not
-- core locals at all — the part reaches them as `M.template` / `M.values` — and
-- binding them would have made core's PARTS table hand round two names it does
-- not define, which the parts fence rejects.
-- ⇒ UNION, THEN PRUNE: the hazards over-report, the scan under-reports, and the
--   fence is what settles it.
return function (M, SHARED)
local family_of, is_hole =
    SHARED.family_of, SHARED.is_hole

function M.dl(t, cost) return (cost or M.size)(t) end

--- description length of one family: its template once, its values per member
function M.family_dl(T, Vs, opts)
    opts = opts or {}
    local cost, fam = opts.cost or M.size, opts.family_cost or 1
    local tdl, vdl = cost(T.body), 0
    for _, V in pairs(Vs) do for _, v in pairs(V) do vdl = vdl + cost(v) end end
    return tdl + fam + vdl, { template = tdl, values = vdl, family = fam }
end

--- a term's cost in BYTES: the length of every leaf's text, a hole counting one (the unit the
--- reader's terms make natural beside `size`, which counts nodes)
function M.text_size(t)
    if type(t) ~= 'table' then return 0 end
    if t.k == 'lit' then return #tostring(t.v) end
    if t.k == 'name' then return #tostring(t.n) end
    if is_hole(t) then return 1 end
    local n = 0
    for _, c in ipairs(t.kids or {}) do n = n + M.text_size(c) end
    return n
end

-- ── THE RECURSIVE FOLD (FOLD.md; Nevill-Manning and Witten 1997, the two constraints) ──────
--- generalize, then every term hole's value column is a candidate family of its own, folded
--- the same way. A nested family is kept when it has at least two members and its description
--- (template once, inner values per member) is shorter than the column's values as they stand:
--- SEQUITUR's rule utility, priced by MDL. The value maps do not change (a member's value at a
--- nested hole is still the term; `nested_values` reads its inner bindings); what changes is
--- the hole's domain, `@h.of` naming the nested template in the env, and the description
--- length, which is hierarchical. Depth-bounded. Returns { template, values, env, families =
--- { [h] = { template, values, members, families, dl, flat } }, dl, flat }.
function M.fold(instances, opts)
    opts = opts or {}
    local depth = opts.depth == nil and 3 or opts.depth
    local env = opts.env or { defs = {} }
    env.defs = env.defs or {}
    local cost, fam = opts.cost or M.size, opts.family_cost or 1
    local prefix = opts.prefix or 'h'
    local g = M.generalize(instances, { need = opts.need, env = env, prefix = prefix, grammars = opts.grammars, split_cap = opts.split_cap })
    local T, Vs = g.template, g.values
    local families = {}
    local names = M.hole_names(T)
    table.sort(names)
    local function nest(col, members, h, label) -- fold a column; keep it when it pays
        local sub = M.fold(col, { depth = depth - 1, need = opts.need, prefix = h .. (label and ('.' .. label) or '') .. '.', env = env, grammars = opts.grammars, split_cap = opts.split_cap, cost = cost, family_cost = fam })
        local before = 0
        for _, v in ipairs(col) do before = before + cost(v) end
        -- rule utility, priced: the nested family (template once, inner values) PLUS one reference
        -- per use must be shorter than the values as they stand
        if sub.dl + #col < before then
            local name = h .. (label and ('.' .. label) or '') .. '.of'
            env.defs[name] = sub.template
            return { template = sub.template, values = sub.values, members = members, families = sub.families, dl = sub.dl, flat = before, name = name }
        end
    end
    local function nodes_of_one_kind(col)
        for _, v in ipairs(col) do
            if type(v) ~= 'table' or v.k == 'lit' or v.k == 'name' or v.k == 'seq' or is_hole(v) or v.k ~= col[1].k then return false end
        end
        return #col >= 2 -- rule utility: a family of one is no family
    end
    for _, h in ipairs(names) do
        local e = T.holes[h]
        if depth > 0 and not e.ctx and not e.presence then
            if not e.rep then
                -- a term hole: its column is the candidate family (every value a node of one kind;
                -- a leaf or a sequence is already a value)
                local col, members = {}, {}
                for i = 1, #instances do
                    local v = Vs[i][h]
                    if v ~= nil then col[#col + 1] = v; members[#members + 1] = i end
                end
                if nodes_of_one_kind(col) then
                    local f = nest(col, members, h)
                    if f then
                        T.holes[h].domain, T.holes[h].origin = M.ref(f.name), 'derived'
                        families[h] = f
                    end
                end
            else
                -- a hedge hole: its ELEMENTS, across the members, bucketed by node kind (a
                -- statement list holds statements of several kinds; each kind is its own
                -- candidate family); leaves (gaps, tokens) stay values
                local buckets, order = {}, {}
                for i = 1, #instances do
                    local v = Vs[i][h]
                    for _, x in ipairs(v and v.kids or {}) do
                        if type(x) == 'table' and x.k ~= 'lit' and x.k ~= 'name' and x.k ~= 'seq' and not is_hole(x) then
                            if not buckets[x.k] then buckets[x.k] = { col = {}, members = {} }; order[#order + 1] = x.k end
                            local b = buckets[x.k]
                            b.col[#b.col + 1] = x; b.members[#b.members + 1] = i
                        end
                    end
                end
                table.sort(order)
                local kinds = {}
                for _, k in ipairs(order) do
                    local b = buckets[k]
                    if #b.col >= 2 then
                        local f = nest(b.col, b.members, h, k)
                        if f then kinds[k] = f end
                    end
                end
                if next(kinds) then families[h] = { kinds = kinds, members = nil, dl = nil } end
            end
        end
    end
    -- the description length is hierarchical: the template once, then per hole either its
    -- values or its nested families (template once, inner values per member) plus what stayed
    -- a member pays one for each REFERENCE to a nested family (Sequitur's symbol for a rule,
    -- MDL.md's one per hole), the sequence former per member as `family_dl` does, and the
    -- elements that did not fold in full; the nested family itself is paid once, inside its dl
    local dl = cost(T.body) + fam
    local former = cost(M.seq {})
    for _, h in ipairs(names) do
        local f = families[h]
        if f and f.template then dl = dl + f.dl + #f.members
        elseif f and f.kinds then
            local sum = 0
            for i = 1, #instances do
                local v = Vs[i][h]
                if v ~= nil then
                    sum = sum + former
                    for _, x in ipairs(v.kids or {}) do
                        if type(x) == 'table' and f.kinds[x.k] then sum = sum + 1 -- a reference to the nested family
                        else sum = sum + cost(x) end
                    end
                end
            end
            for _, kf in pairs(f.kinds) do sum = sum + kf.dl end
            f.dl = sum
            dl = dl + sum
        else
            for i = 1, #instances do local v = Vs[i][h]; if v ~= nil then dl = dl + cost(v) end end
        end
    end
    local flat = M.family_dl(T, Vs, { cost = cost, family_cost = fam })
    return { template = T, values = Vs, env = env, families = families, dl = dl, flat = flat, notes = g.notes }
end
--- the inner bindings of member i at a nested hole (the nested family's own value map)
function M.nested_values(F, h, i)
    local f = F.families[h]
    if not f then return nil, 'no nested family at ' .. tostring(h) end
    for k, m in ipairs(f.members) do if m == i then return f.values[k] end end
    return nil, ('member %d has no value at %s'):format(i, tostring(h))
end

-- ── MDL partitioning, continued: the price of a partition and the greedy agglomeration (MDL.md) ─────
-- (after the recursive fold's section, whose `family_of` these share)
function M.partition_dl(families, opts)
    local total = 0
    for _, f in ipairs(families) do total = total + M.family_dl(f.template, f.values, opts) end
    return total
end

--- greedy agglomerative partition by description length
function M.partition(instances, opts)
    opts = opts or {}
    local fams, steps = {}, {}
    for i = 1, #instances do fams[i] = family_of(instances, { i }, opts) end
    local singletons_dl = M.partition_dl(fams, opts)
    local all = {}
    for i = 1, #instances do all[i] = i end
    local one = family_of(instances, all, opts)
    while #fams > 1 do
        local best
        for a = 1, #fams do
            for b = a + 1, #fams do
                local members = {}
                for _, i in ipairs(fams[a].members) do members[#members + 1] = i end
                for _, i in ipairs(fams[b].members) do members[#members + 1] = i end
                table.sort(members)
                local merged = family_of(instances, members, opts)
                local gain = fams[a].dl + fams[b].dl - merged.dl
                if merged.admissible and gain > 0 and (not best or gain > best.gain) then
                    best = { a = a, b = b, merged = merged, gain = gain }
                end
            end
        end
        if not best then break end
        steps[#steps + 1] = { merged = best.merged.members, gain = best.gain }
        local nf = {}
        for k, f in ipairs(fams) do if k ~= best.a and k ~= best.b then nf[#nf + 1] = f end end
        nf[#nf + 1] = best.merged
        fams = nf
    end
    -- greedy can stop at a local optimum above the one-family partition (seed 26 of the
    -- spec's law did, before admissibility); the trivial candidate is always compared
    local dl = M.partition_dl(fams, opts)
    if one.admissible and one.dl < dl then
        steps[#steps + 1] = { merged = all, gain = dl - one.dl, why = 'one family beats the greedy result' }
        fams, dl = { one }, one.dl
    end
    table.sort(fams, function(x, y) return x.members[1] < y.members[1] end)
    return { families = fams, dl = dl, steps = steps,
        singletons_dl = singletons_dl, one_family_dl = one.dl, one_family_admissible = one.admissible }
end

--- the optimum over every set partition (n ≤ 8), for measuring greedy
function M.partition_all(instances, opts)
    opts = opts or {}
    local n = #instances
    assert(n <= 8, 'partition_all: too many instances')
    local memo = {}
    local function block(members)
        local k = table.concat(members, ',')
        if not memo[k] then memo[k] = family_of(instances, members, opts) end
        return memo[k]
    end
    local best, count = nil, 0
    local rgs = {}
    local function rec(i, m) -- restricted growth strings enumerate set partitions once each
        if i > n then
            count = count + 1
            local blocks = {}
            for j = 1, n do blocks[rgs[j]] = blocks[rgs[j]] or {}; table.insert(blocks[rgs[j]], j) end
            local fams, dl, ok = {}, 0, true
            for _, b in ipairs(blocks) do local f = block(b); fams[#fams + 1] = f; dl = dl + f.dl; ok = ok and f.admissible end
            if ok and (not best or dl < best.dl) then best = { families = fams, dl = dl } end
            return
        end
        for v = 1, m + 1 do rgs[i] = v; rec(i + 1, math.max(m, v)) end
    end
    rec(1, 0)
    best.partitions = count
    return best
end

--- price an operator's split (propagate.commit): one family versus the two it produces
function M.dl_delta(T, Vs, T2, committed, opts)
    local set, yes, no = {}, {}, {}
    for _, i in ipairs(committed) do set[i] = true end
    local r = assert(M.migrate(T, T2, Vs))
    for i, V in pairs(Vs) do if set[i] then yes[i] = r.values[i] or V else no[i] = V end end
    local one = M.family_dl(T, Vs, opts)
    local two = M.family_dl(T2, yes, opts) + (next(no) and M.family_dl(T, no, opts) or 0)
    return { one = one, two = two, delta = two - one }
end
end
