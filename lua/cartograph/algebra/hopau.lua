-- A PART OF `cartograph.algebra.core`, which requires this file at its end and
-- passes its own module table in. ⚠ IT DOES NOT `require` CORE BACK: that is a
-- load cycle — Lua says "loop or previous error loading module".
return function (M, SHARED)
local _ = SHARED

-- ── HIGHER-ORDER PATTERN ANTI-UNIFICATION (Baumgartner, Kutsia, Levy, Villaret, JAR 2017) ──
-- Read in full (open access). Terms are simply typed λ-terms in η-long β-normal form:
-- λx1..xn.h(t1..tm) with h a constant or a variable. A HIGHER-ORDER PATTERN is a term whose
-- free variables are applied only to lists of DISTINCT BOUND variables. The lgg among
-- patterns exists, is unique modulo α and renaming (Cor. 1), and costs linear time (Thm 5).
--
-- Representation:  { k='lam', x='x', body }          λx.body
--                  { k='app', h='f', args={...} }     constant head
--                  { k='app', bv='x', args={...} }    bound-variable head
--                  { k='fv',  name='Y', args={...} }  free (generalization) variable
-- Binder names are made globally distinct on entry (Remark 1). Locals of a program are
-- exactly λ-bound variables here, and a hole Y(ȳ) carries the locals it depends on.
function M.lam(x, body) return { k = 'lam', x = x, body = body } end

function M.app(h, ...) return { k = 'app', h = h, args = { ... } } end

function M.bv(x, ...) return { k = 'app', bv = x, args = { ... } } end

function M.fv(name, ...) return { k = 'fv', name = name, args = { ... } } end

local function lams(t) -- peel leading abstractions
    local xs = {}
    while t.k == 'lam' do xs[#xs + 1] = t.x; t = t.body end
    return xs, t
end

function M.lams(xs, body)
    for i = #xs, 1, -1 do body = M.lam(xs[i], body) end
    return body
end

local function ho_map_names(t, ren) -- rename bound variables by table (binders and uses)
    if t.k == 'lam' then return { k = 'lam', x = ren[t.x] or t.x, body = ho_map_names(t.body, ren) } end
    local args = {}
    for i, a in ipairs(t.args) do args[i] = ho_map_names(a, ren) end
    if t.k == 'fv' then return { k = 'fv', name = t.name, args = args } end
    if t.bv then return { k = 'app', bv = ren[t.bv] or t.bv, args = args } end
    return { k = 'app', h = t.h, args = args }
end

--- every λ in the term binds a fresh, globally distinct name (Remark 1)
local ho_fresh_n = 0

function M.ho_distinct(t)
    local function go(u, env)
        if u.k == 'lam' then
            ho_fresh_n = ho_fresh_n + 1
            local nx = u.x .. '#' .. ho_fresh_n
            local env2 = setmetatable({ [u.x] = nx }, { __index = env })
            return { k = 'lam', x = nx, body = go(u.body, env2) }
        end
        local args = {}
        for i, a in ipairs(u.args) do args[i] = go(a, env) end
        if u.k == 'fv' then return { k = 'fv', name = u.name, args = args } end
        if u.bv then return { k = 'app', bv = env[u.bv] or u.bv, args = args } end
        return { k = 'app', h = u.h, args = args }
    end
    return go(t, {})
end

--- canonical string: de Bruijn indices for bound variables (a free-standing bound name
--- that is not under its binder is printed as '!name'), free variables numbered by first
--- occurrence unless opts.keep_free. Two α-equivalent terms print the same.
function M.ho_show(t, opts)
    opts = opts or {}
    local free, nf = {}, 0
    local function go(u, env, depth)
        if u.k == 'lam' then return 'λ.' .. go(u.body, setmetatable({ [u.x] = depth }, { __index = env }), depth + 1) end
        local as = {}
        for i, a in ipairs(u.args) do as[i] = go(a, env, depth) end
        local head
        if u.k == 'fv' then
            if opts.keep_free then head = u.name
            else
                if not free[u.name] then nf = nf + 1; free[u.name] = 'Y' .. nf end
                head = free[u.name]
            end
        elseif u.bv then
            head = env[u.bv] and ('#' .. (depth - 1 - env[u.bv])) or ('!' .. u.bv)
        else head = u.h end
        return head .. (#as > 0 and ('(' .. table.concat(as, ',') .. ')') or '')
    end
    return go(t, {}, 0)
end

function M.alpha_eq(t, s) return M.ho_show(t) == M.ho_show(s) end

--- Theorem 2(a): is t a higher-order pattern? Every free variable is applied to pairwise
--- distinct bound variables that are in scope. Returns ok, offending variable name.
function M.ho_is_pattern(t)
    local function go(u, env)
        if u.k == 'lam' then return go(u.body, setmetatable({ [u.x] = true }, { __index = env })) end
        if u.k == 'fv' then
            local seen = {}
            for _, a in ipairs(u.args) do
                if not (a.k == 'app' and a.bv and #a.args == 0 and env[a.bv]) or seen[a.bv] then return false, u.name end
                seen[a.bv] = true
            end
            return true
        end
        for _, a in ipairs(u.args) do
            local ok, why = go(a, env)
            if not ok then return false, why end
        end
        return true
    end
    return go(t, {})
end

--- canonical string MODULO ≃ (Theorem 4): free variables numbered by first occurrence, and
--- each free variable's parameters permuted so that its first occurrence lists its
--- bound-variable arguments in increasing de Bruijn order. Two results equivalent up to
--- renaming and per-variable argument permutation print the same.
function M.ho_canon(t)
    local free, perm, nf = {}, {}, 0
    local function go(u, env, depth)
        if u.k == 'lam' then return 'λ.' .. go(u.body, setmetatable({ [u.x] = depth }, { __index = env }), depth + 1) end
        if u.k == 'fv' then
            if not free[u.name] then
                nf = nf + 1; free[u.name] = 'Y' .. nf
                local idx, ok = {}, true
                for i, a in ipairs(u.args) do
                    if a.k == 'app' and a.bv and #a.args == 0 and env[a.bv] then idx[i] = { i = i, d = depth - 1 - env[a.bv] } else ok = false end
                end
                if ok then
                    table.sort(idx, function(p, q) return p.d < q.d end)
                    local pm = {}
                    for k, e in ipairs(idx) do pm[k] = e.i end
                    perm[u.name] = pm
                end
            end
            local pm = perm[u.name]
            if pm and #pm ~= #u.args then pm = nil end
            local as = {}
            for k = 1, #u.args do as[k] = go(u.args[pm and pm[k] or k], env, depth) end
            return free[u.name] .. (#as > 0 and ('(' .. table.concat(as, ',') .. ')') or '')
        end
        local as = {}
        for i, a in ipairs(u.args) do as[i] = go(a, env, depth) end
        local head = u.bv and (env[u.bv] and ('#' .. (depth - 1 - env[u.bv])) or ('!' .. u.bv)) or u.h
        return head .. (#as > 0 and ('(' .. table.concat(as, ',') .. ')') or '')
    end
    return go(t, {}, 0)
end

local function ho_free_bound(t, acc, order) -- bound-variable names occurring free in t, first-occurrence order
    acc, order = acc or {}, order or {}
    if t.k == 'lam' then ho_free_bound(t.body, acc, order); return acc, order end
    if t.bv and not acc[t.bv] then acc[t.bv] = true; order[#order + 1] = t.bv end
    for _, a in ipairs(t.args) do ho_free_bound(a, acc, order) end
    return acc, order
end

--- β-reduce a pattern application: Y(ā) with Y ↦ λȳ.t is t{ȳ ↦ ā}; since ā are variables
--- (or, when rebuilding, arbitrary terms in place of variables) this is a substitution
local function ho_subst_vars(t, map) -- replace bound-variable heads per map (var -> term)
    if t.k == 'lam' then return { k = 'lam', x = t.x, body = ho_subst_vars(t.body, map) } end
    local args = {}
    for i, a in ipairs(t.args) do args[i] = ho_subst_vars(a, map) end
    if t.k == 'fv' then return { k = 'fv', name = t.name, args = args } end
    if t.bv and map[t.bv] then
        local r = map[t.bv]
        if #args == 0 then return r end
        -- applying a variable-headed replacement to arguments (η-long form keeps this a renaming)
        assert(r.k == 'app' and r.bv and #r.args == 0, 'pattern application must be a renaming')
        return { k = 'app', bv = r.bv, args = args }
    end
    if t.bv then return { k = 'app', bv = t.bv, args = args } end
    return { k = 'app', h = t.h, args = args }
end

--- apply a substitution {Y = {xs = {...}, body = t}} to a term, β-reducing Y(ā)
function M.ho_apply(t, sigma)
    if t.k == 'lam' then return { k = 'lam', x = t.x, body = M.ho_apply(t.body, sigma) } end
    local args = {}
    for i, a in ipairs(t.args) do args[i] = M.ho_apply(a, sigma) end
    if t.k == 'fv' and sigma[t.name] then
        local b = sigma[t.name]
        assert(#b.xs == #args, 'arity of ' .. t.name)
        local map = {}
        for i, x in ipairs(b.xs) do map[x] = args[i] end
        return M.ho_apply(ho_subst_vars(b.body, map), sigma)
    end
    if t.k == 'fv' then return { k = 'fv', name = t.name, args = args } end
    if t.bv then return { k = 'app', bv = t.bv, args = args } end
    return { k = 'app', h = t.h, args = args }
end

--- The transformation set P (Def. 1): Dec, Abs, Sol, Mer, on states A; S; σ, plus the
--- untyped extension from the conclusion (lazy η-expansion, Sol on arity mismatch).
--- Mer is done by Lemma 4/5/6: each store entry's pair is closed over its argument
--- variables in first-occurrence order and keyed by de Bruijn form; equal keys merge, the
--- permuting matcher being the correspondence of the two orderings.
--- opts.queue processes A first-in-first-out (default: stack); opts.reverse_merge visits
--- merge classes in reverse; opts.no_merge / opts.identity_merge / opts.no_narrow /
--- opts.no_rename are mutation hooks. Returns { result, store, sigmaL, sigmaR, steps }.
function M.hoau(t0, s0, opts)
    opts = opts or {}
    local t, s = M.ho_distinct(t0), M.ho_distinct(s0)
    local n = { v = 0, steps = 0 }
    local function fresh() n.v = n.v + 1; return 'Y' .. n.v end
    local A, S, sigma = { { X = 'X0', xs = {}, t = t, s = s } }, {}, {}
    local function pop()
        if opts.queue then return table.remove(A, 1) end
        return table.remove(A)
    end
    local function set(X, xs, body) sigma[X] = { xs = xs, body = body } end
    local function eta(u, z) -- λz.h(args, z)
        local args = {}
        for i, a in ipairs(u.args) do args[i] = a end
        args[#args + 1] = { k = 'app', bv = z, args = {} }
        return { k = 'lam', x = z, body = u.k == 'fv' and { k = 'fv', name = u.name, args = args } or (u.bv and { k = 'app', bv = u.bv, args = args } or { k = 'app', h = u.h, args = args }) }
    end
    while #A > 0 do
        local p = pop()
        n.steps = n.steps + 1
        local pt, ps = p.t, p.s
        -- lazy η-expansion (untyped variant): a λ against a non-λ
        if pt.k == 'lam' and ps.k ~= 'lam' then ps = eta(ps, pt.x .. 'η') end
        if ps.k == 'lam' and pt.k ~= 'lam' then pt = eta(pt, ps.x .. 'η') end
        if pt.k == 'lam' then -- Abs: rename the right binder to the left name
            local body_s = opts.no_rename and ps.body or ho_map_names(ps.body, { [ps.x] = pt.x })
            local X2 = fresh()
            local xs2 = { unpack(p.xs) }
            xs2[#xs2 + 1] = pt.x
            set(p.X, p.xs, { k = 'lam', x = pt.x, body = { k = 'fv', name = X2, args = (function() local a = {} for i, x in ipairs(xs2) do a[i] = { k = 'app', bv = x, args = {} } end return a end)() } })
            A[#A + 1] = { X = X2, xs = xs2, t = pt.body, s = body_s }
        else
            local inscope = {}
            for _, x in ipairs(p.xs) do inscope[x] = true end
            local same_head = pt.k == ps.k and #pt.args == #ps.args and (
                (pt.k == 'app' and not pt.bv and not ps.bv and pt.h == ps.h)
                or (pt.k == 'app' and pt.bv and ps.bv and pt.bv == ps.bv and inscope[pt.bv]))
            if same_head then -- Dec (a constant head, or a bound variable in scope)
                local ys, args = {}, {}
                for i = 1, #pt.args do
                    local Yi = fresh()
                    ys[i] = Yi
                    local a = {}
                    for j, x in ipairs(p.xs) do a[j] = { k = 'app', bv = x, args = {} } end
                    args[i] = { k = 'fv', name = Yi, args = a }
                    A[#A + 1] = { X = Yi, xs = p.xs, t = pt.args[i], s = ps.args[i] }
                end
                set(p.X, p.xs, pt.bv and { k = 'app', bv = pt.bv, args = args } or { k = 'app', h = pt.h, args = args })
            else -- Sol: differing heads, a free head, or an arity mismatch
                local used = {}
                ho_free_bound(pt, used); ho_free_bound(ps, used)
                local ys = {}
                for _, x in ipairs(p.xs) do if opts.no_narrow or used[x] then ys[#ys + 1] = x end end
                local Y = fresh()
                local a = {}
                for i, x in ipairs(ys) do a[i] = { k = 'app', bv = x, args = {} } end
                set(p.X, p.xs, { k = 'fv', name = Y, args = a })
                S[#S + 1] = { Y = Y, ys = ys, t = pt, s = ps }
            end
        end
    end
    -- Mer by de Bruijn key (Lemmas 4–6): close pair(t, s) over ys ordered by first occurrence
    if not opts.no_merge then
        local classes, order = {}, {}
        for _, e in ipairs(S) do
            local ord
            if opts.identity_merge then ord = e.ys
            else
                local _, o = ho_free_bound({ k = 'app', h = 'pair', args = { e.t, e.s } })
                ord = {}
                local inys = {}
                for _, y in ipairs(e.ys) do inys[y] = true end
                for _, y in ipairs(o) do if inys[y] then ord[#ord + 1] = y end end
            end
            e.ord = ord
            local key = #e.ys .. ':' .. M.ho_show(M.lams(ord, { k = 'app', h = 'pair', args = { e.t, e.s } }), { keep_free = true })
            if not classes[key] then classes[key] = {}; order[#order + 1] = key end
            classes[key][#classes[key] + 1] = e
        end
        if opts.reverse_merge then
            local r = {}
            for i = #order, 1, -1 do r[#r + 1] = order[i] end
            order = r
        end
        local kept = {}
        for _, key in ipairs(order) do
            local cls = classes[key]
            local keep = cls[1]
            kept[#kept + 1] = keep
            for i = 2, #cls do
                local e = cls[i]
                -- π maps keep's ordered variables to e's: Y_e ↦ λ ys_e . Y_keep(keep.ys π)
                local pi = {}
                for j, x in ipairs(keep.ord) do pi[x] = e.ord[j] end
                local a = {}
                for j, x in ipairs(keep.ys) do a[j] = { k = 'app', bv = pi[x], args = {} } end
                set(e.Y, e.ys, { k = 'fv', name = keep.Y, args = a })
            end
        end
        S = kept
    end
    local result = M.ho_apply({ k = 'fv', name = 'X0', args = {} }, sigma)
    local sigmaL, sigmaR = {}, {}
    for _, e in ipairs(S) do
        sigmaL[e.Y] = { xs = e.ys, body = e.t }
        sigmaR[e.Y] = { xs = e.ys, body = e.s }
    end
    return { result = result, store = S, sigmaL = sigmaL, sigmaR = sigmaR, steps = n.steps, left = t, right = s }
end
end
