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
local family, family_of = SHARED.family, SHARED.family_of

function M.dl(t, cost) return (cost or M.size)(t) end

--- description length of one family: its template once, its values per member
function M.family_dl(T, Vs, opts)
    opts = opts or {}
    local cost, fam = opts.cost or M.size, opts.family_cost or 1
    local tdl, vdl = cost(T.body), 0
    for _, V in pairs(Vs) do for _, v in pairs(V) do vdl = vdl + cost(v) end end
    return tdl + fam + vdl, { template = tdl, values = vdl, family = fam }
end

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
