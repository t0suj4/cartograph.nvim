-- A PART OF `cartograph.algebra.core`, which requires this file at its end and
-- passes its own module table in. ⚠ IT DOES NOT `require` CORE BACK: that is a
-- load cycle — Lua says "loop or previous error loading module".
-- ★ `cat` and `is_hole` are the file-locals this section reaches back for. BOTH
-- came from the plan's own capture hazards; the free-identifier scan that
-- confirmed them reports ZERO for the two parts already adapted, which is what
-- makes a count of two believable rather than a coincidence.
return function (M, SHARED)
local ax, cat, isA, is_hole =
    SHARED.ax, SHARED.cat, SHARED.isA, SHARED.is_hole

local function isC(theory, t) local a = ax(theory, t); return a and a.C end

--- flatten nested associative symbols into variadic nodes; a group of one is the element
function M.flatten(t, theory)
    if not t.kids then return M.copy(t) end
    local kids = {}
    for _, c in ipairs(t.kids) do
        local fc = M.flatten(c, theory)
        if isA(theory, t) and fc.k == t.k and fc.kids then
            for _, g in ipairs(fc.kids) do kids[#kids + 1] = g end
        else
            kids[#kids + 1] = fc
        end
    end
    return M.rebuild(t, kids)
end

--- canonical representative modulo B: flattened, commutative children sorted
function M.canon(t, theory)
    local f = M.flatten(t, theory)
    local function go(x)
        if not x.kids then return x end
        local kids = {}
        for i, c in ipairs(x.kids) do kids[i] = go(c) end
        if isC(theory, x) and (isA(theory, x) or #kids == 2) then -- C alone is binary; AC groups sort at any width
            local keyed = {}
            for i, c in ipairs(kids) do keyed[i] = { s = M.show(c), c = c } end
            table.sort(keyed, function(p, q) return p.s < q.s end)
            for i, e in ipairs(keyed) do kids[i] = e.c end
        end
        return M.rebuild(x, kids)
    end
    return go(f)
end

function M.eq_mod(a, b, theory) return M.eq(M.canon(a, theory), M.canon(b, theory)) end

local function group(f, list, theory)
    if #list == 1 then return list[1] end
    return M.rebuild(f, list)
end
local function slice_l(list, i, j) local out = {}; for k = i, j do out[#out + 1] = list[k] end; return out end

--- matching modulo B: does pattern p (with holes) have an instance equal modulo B to t?
--- Holes of t are constants. Backtracking over the orders (C), consecutive groups (A) and
--- subsets (AC) of children; a step cap refuses by name.
function M.match_mod(p, t, theory, opts)
    opts = opts or {}
    local cap, steps = opts.cap or 20000, 0
    p, t = M.flatten(p, theory), M.flatten(t, theory)
    local function go(pp, tt, V)
        steps = steps + 1
        if steps > cap then return nil end
        if is_hole(pp) then
            local v = V[pp.h]
            if v == nil then
                local W = {}
                for k, x in pairs(V) do W[k] = x end
                W[pp.h] = tt
                return W
            end
            return M.eq_mod(v, tt, theory) and V or nil
        end
        if not pp.kids or not tt.kids then return M.eq(pp, tt) and V or nil end
        if pp.k ~= tt.k then return nil end
        local pk, tk = pp.kids, tt.kids
        local a, c = isA(theory, pp), isC(theory, pp)
        if not a and not c then
            if #pk ~= #tk then return nil end
            for i = 1, #pk do V = go(pk[i], tk[i], V); if not V then return nil end end
            return V
        end
        if c and not a then
            if #pk ~= 2 or #tk ~= 2 then return nil end
            local V1 = go(pk[1], tk[1], V); V1 = V1 and go(pk[2], tk[2], V1)
            if V1 then return V1 end
            local V2 = go(pk[1], tk[2], V); return V2 and go(pk[2], tk[1], V2)
        end
        if #tk < #pk then return nil end
        if a and not c then -- consecutive groups; a non-hole pattern child takes exactly one
            local function place(i, from, V0)
                if i > #pk then return from > #tk and V0 or nil end
                local left_needed = #pk - i
                local maxlen = #tk - from + 1 - left_needed
                if maxlen < 1 then return nil end
                local lens = is_hole(pk[i]) and maxlen or 1
                for len = (i == #pk and maxlen or 1), lens do
                    if i == #pk and len ~= maxlen then break end
                    local V1 = go(pk[i], group(tt, slice_l(tk, from, from + len - 1), theory), V0)
                    if V1 then
                        local V2 = place(i + 1, from + len, V1)
                        if V2 then return V2 end
                    end
                    if steps > cap then return nil end
                end
                return nil
            end
            return place(1, 1, V)
        end
        -- AC: each pattern child takes a nonempty subset of the term children; the last takes the rest
        local used = {}
        local function assign(i, V0)
            if i > #pk then
                for j = 1, #tk do if not used[j] then return nil end end
                return V0
            end
            local free = {}
            for j = 1, #tk do if not used[j] then free[#free + 1] = j end end
            if i == #pk then
                if #free == 0 then return nil end
                local list = {}
                for _, j in ipairs(free) do list[#list + 1] = tk[j] end
                if not is_hole(pk[i]) and #list > 1 then return nil end
                for _, j in ipairs(free) do used[j] = true end
                local V1 = go(pk[i], group(tt, list, theory), V0)
                for _, j in ipairs(free) do used[j] = nil end
                return V1
            end
            local maxsize = is_hole(pk[i]) and (#free - (#pk - i)) or 1
            local function subsets(start, chosen, size)
                if steps > cap then return nil end
                if #chosen > 0 and #chosen <= maxsize then
                    local list = {}
                    for _, j in ipairs(chosen) do list[#list + 1] = tk[j]; used[j] = true end
                    local V1 = go(pk[i], group(tt, list, theory), V0)
                    local V2 = V1 and assign(i + 1, V1)
                    for _, j in ipairs(chosen) do used[j] = nil end
                    if V2 then return V2 end
                end
                if #chosen >= maxsize then return nil end
                for s = start, #free do
                    chosen[#chosen + 1] = free[s]
                    local r = subsets(s + 1, chosen, size)
                    chosen[#chosen] = nil
                    if r then return r end
                end
                return nil
            end
            return subsets(1, {}, 0)
        end
        return assign(1, V)
    end
    local V = go(p, t, {})
    if steps > cap then return nil, 'matching budget exceeded' end
    return V
end

--- g is less general than or equal to g' modulo B (g' is an instance of g)
function M.leq_mod(g, g2, theory) return M.match_mod(g, g2, theory) ~= nil end

local function nonempty_proper_subsets(n)
    local out = {}
    for mask = 1, (2 ^ n) - 2 do
        local inn, outn = {}, {}
        for i = 1, n do
            if math.floor(mask / 2 ^ (i - 1)) % 2 == 1 then inn[#inn + 1] = i else outn[#outn + 1] = i end
        end
        out[#out + 1] = { inn, outn }
    end
    return out
end

--- the minimal complete set of generalizations of t and s modulo the theory
function M.eau(t, s, theory, opts)
    opts = opts or {}
    theory = theory or {}
    local cap = opts.cap or 50000
    local prefix = opts.prefix or 'e'
    local t0, s0 = M.flatten(t, theory), M.flatten(s, theory)
    local results, expansions, counter = {}, 0, 0
    local function fresh() counter = counter + 1; return prefix .. counter end
    local function copy_state(st)
        local C, S, th = {}, {}, {}
        for i, c in ipairs(st.C) do C[i] = c end
        for i, c in ipairs(st.S) do S[i] = c end
        for k, v in pairs(st.theta) do th[k] = v end
        return { C = C, S = S, theta = th }
    end
    local function bind(st, x, term) st.theta[x] = term end
    local function pick(l, r, x) return { l = l, r = r, x = x } end
    local function run(st)
        expansions = expansions + 1
        if expansions > cap then return end
        if #st.C == 0 then results[#results + 1] = st; return end
        local c = table.remove(st.C, 1)
        local l, r, x = c.l, c.r, c.x
        -- (1) equal modulo B: bound at once (DecomposeB with n = 0, closed under =B)
        if M.eq_mod(l, r, theory) then bind(st, x, M.canon(l, theory)); return run(st) end
        -- Recover: the same pair (modulo B) already solved
        for _, e in ipairs(st.S) do
            if M.eq_mod(e.l, l, theory) and M.eq_mod(e.r, r, theory) then bind(st, x, M.hole(e.y)); return run(st) end
        end
        local function solve()
            local z = fresh()
            st.S[#st.S + 1] = { l = l, r = r, y = z }
            bind(st, x, M.hole(z))
            return run(st)
        end
        if is_hole(l) or is_hole(r) or not l.kids or not r.kids or l.k ~= r.k then return solve() end
        local lk, rk = l.kids, r.kids
        local a, cc = isA(theory, l), isC(theory, l)
        if not a and not cc then
            if #lk ~= #rk then return solve() end -- (2) unranked: same root, different arity
            local xs = {}
            for i = #lk, 1, -1 do xs[i] = fresh(); table.insert(st.C, 1, pick(lk[i], rk[i], xs[i])) end
            local kids = {}
            for i = 1, #lk do kids[i] = M.hole(xs[i]) end
            bind(st, x, M.rebuild(l, kids))
            return run(st)
        end
        local function branch(pairs_)
            local st2 = copy_state(st)
            local xs = {}
            for i = #pairs_, 1, -1 do xs[i] = fresh(); table.insert(st2.C, 1, pick(pairs_[i][1], pairs_[i][2], xs[i])) end
            bind(st2, x, M.rebuild(l, { M.hole(xs[1]), M.hole(xs[2]) }))
            run(st2)
        end
        if cc and not a then -- DecomposeC (Fig 5): both pairings
            if #lk ~= 2 or #rk ~= 2 then return solve() end
            branch { { lk[1], rk[1] }, { lk[2], rk[2] } }
            branch { { lk[1], rk[2] }, { lk[2], rk[1] } }
            return
        end
        local n, m = #lk, #rk
        if a and not cc then -- DecomposeA left / right (AMAI Fig 6)
            for k = 1, n - 1 do
                branch { { group(l, slice_l(lk, 1, k), theory), rk[1] }, { group(l, slice_l(lk, k + 1, n), theory), group(r, slice_l(rk, 2, m), theory) } }
            end
            for k = 1, m - 1 do
                branch { { lk[1], group(r, slice_l(rk, 1, k), theory) }, { group(l, slice_l(lk, 2, n), theory), group(r, slice_l(rk, k + 1, m), theory) } }
            end
            return
        end
        -- DecomposeAC left / right (AMAI Fig 7): a subset of one side against one child of the other
        local seen = {}
        local function once(pairs_)
            local key = M.show(M.canon(pairs_[1][1], theory)) .. '\1' .. M.show(M.canon(pairs_[1][2], theory)) .. '\2'
                .. M.show(M.canon(pairs_[2][1], theory)) .. '\1' .. M.show(M.canon(pairs_[2][2], theory))
            if seen[key] then return end
            seen[key] = true
            branch(pairs_)
        end
        for _, sp in ipairs(nonempty_proper_subsets(n)) do
            for km = 1, m do
                local rest = {}
                for j = 1, m do if j ~= km then rest[#rest + 1] = rk[j] end end
                local inn, outn = {}, {}
                for _, i in ipairs(sp[1]) do inn[#inn + 1] = lk[i] end
                for _, i in ipairs(sp[2]) do outn[#outn + 1] = lk[i] end
                once { { group(l, inn, theory), rk[km] }, { group(l, outn, theory), group(r, rest, theory) } }
            end
        end
        for _, sp in ipairs(nonempty_proper_subsets(m)) do
            for kn = 1, n do
                local rest = {}
                for j = 1, n do if j ~= kn then rest[#rest + 1] = lk[j] end end
                local inn, outn = {}, {}
                for _, i in ipairs(sp[1]) do inn[#inn + 1] = rk[i] end
                for _, i in ipairs(sp[2]) do outn[#outn + 1] = rk[i] end
                once { { lk[kn], group(r, inn, theory) }, { group(l, rest, theory), group(r, outn, theory) } }
            end
        end
    end
    local x0 = fresh()
    run({ C = { pick(t0, s0, x0) }, S = {}, theta = {} })
    if expansions > cap then return nil, 'search budget exceeded' end
    -- resolve θ(x0), build templates and the two value tables
    local all = {}
    for _, st in ipairs(results) do
        local function resolve(term)
            if is_hole(term) and st.theta[term.h] then return resolve(st.theta[term.h]) end
            if not term.kids then return M.copy(term) end
            local kids = {}
            for i, c in ipairs(term.kids) do kids[i] = resolve(c) end
            return M.rebuild(term, kids)
        end
        local body = M.flatten(resolve(M.hole(x0)), theory)
        local domains, V1, V2 = {}, {}, {}
        for _, e in ipairs(st.S) do
            domains[e.y] = { domain = M.summarize({ e.l, e.r }, opts), origin = 'derived' }
            V1[e.y], V2[e.y] = M.copy(e.l), M.copy(e.r)
        end
        local T = M.template(body, domains)
        -- an INPUT variable that survived into the body is a constant of the problem: both
        -- value tables carry it as itself, so instantiate rebuilds the inputs as given
        for _, h in ipairs(M.hole_names(T)) do
            if V1[h] == nil then V1[h], V2[h] = M.hole(h), M.hole(h) end
        end
        all[#all + 1] = { template = T, values = { V1, V2 } }
    end
    -- filter: drop duplicates modulo B and renaming, then anything with a STRICT instance in the set
    local kept = {}
    for _, g in ipairs(all) do
        local dup = false
        for _, h in ipairs(kept) do
            if M.leq_mod(g.template.body, h.template.body, theory) and M.leq_mod(h.template.body, g.template.body, theory) then dup = true; break end
        end
        if not dup then kept[#kept + 1] = g end
    end
    local minimal = {}
    for i, g in ipairs(kept) do
        local dominated = false
        for j, h in ipairs(kept) do
            if i ~= j and M.leq_mod(g.template.body, h.template.body, theory) and not M.leq_mod(h.template.body, g.template.body, theory) then dominated = true; break end
        end
        if not dominated then minimal[#minimal + 1] = g end
    end
    return { set = minimal, complete = #all, distinct = #kept, expansions = expansions }
end

--- LOPSTR 2008 Definition 2, literally: enumerate the B-class of each input (bracketings
--- for A, child orders for C, both for AC), take Plotkin's lgg of every pair, keep the least
--- general modulo B. The yardstick for `eau` on tiny terms.
function M.eau_naive(t, s, theory, opts)
    local function bracketings(f, list)
        if #list == 1 then return { list[1] } end
        local out = {}
        for k = 1, #list - 1 do
            for _, L in ipairs(bracketings(f, slice_l(list, 1, k))) do
                for _, R in ipairs(bracketings(f, slice_l(list, k + 1, #list))) do out[#out + 1] = M.rebuild(f, { L, R }) end
            end
        end
        return out
    end
    local function perms(list)
        if #list <= 1 then return { list } end
        local out = {}
        for i = 1, #list do
            local rest = {}
            for j = 1, #list do if j ~= i then rest[#rest + 1] = list[j] end end
            for _, p in ipairs(perms(rest)) do out[#out + 1] = cat({ list[i] }, p) end
        end
        return out
    end
    local function class(x)
        if not x.kids then return { x } end
        local f = M.flatten(x, theory)
        local kid_classes = {}
        for i, c in ipairs(f.kids) do kid_classes[i] = class(c) end
        local combos = { {} }
        for i = 1, #f.kids do
            local nxt = {}
            for _, cmb in ipairs(combos) do for _, alt in ipairs(kid_classes[i]) do nxt[#nxt + 1] = cat(cmb, { alt }) end end
            combos = nxt
        end
        local out = {}
        for _, kids in ipairs(combos) do
            local orders = isC(theory, f) and perms(kids) or { kids }
            for _, o in ipairs(orders) do
                if isA(theory, f) then for _, b in ipairs(bracketings(f, o)) do out[#out + 1] = b end
                else out[#out + 1] = M.rebuild(f, o) end
            end
        end
        return out
    end
    local ct, cs = class(t), class(s)
    local gens = {}
    for _, u in ipairs(ct) do
        for _, v in ipairs(cs) do
            local g = M.generalize({ u, v }, { need = 100 })
            gens[#gens + 1] = M.flatten(g.template.body, theory)
        end
    end
    local kept = {}
    for _, g in ipairs(gens) do
        local dup = false
        for _, h in ipairs(kept) do if M.leq_mod(g, h, theory) and M.leq_mod(h, g, theory) then dup = true; break end end
        if not dup then kept[#kept + 1] = g end
    end
    local minimal = {}
    for i, g in ipairs(kept) do
        local dominated = false
        for j, h in ipairs(kept) do
            if i ~= j and M.leq_mod(g, h, theory) and not M.leq_mod(h, g, theory) then dominated = true; break end
        end
        if not dominated then minimal[#minimal + 1] = g end
    end
    return { set = minimal, pairs = #ct * #cs }
end

--- two sets of generalizers agree modulo B and renaming
function M.same_set_mod(A1, A2, theory)
    if #A1 ~= #A2 then return false end
    for _, g in ipairs(A1) do
        local found = false
        for _, h in ipairs(A2) do if M.leq_mod(g, h, theory) and M.leq_mod(h, g, theory) then found = true; break end end
        if not found then return false end
    end
    return true
end
end
