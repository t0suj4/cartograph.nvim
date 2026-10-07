-- mixproj — mix's lowered program as FACTS, and the binding-time sets mix needs DERIVED from them by rules (CART-1524).
-- The PROJECTION reads plain facts off the IR (no mix rule consulted); the RULES below are data, run by the algebra's
-- rule engine (cartograph.saturate). Measured before promotion (CART-1525): over the 68 derivation programs the rules
-- give mix's own forced / fresh-root sets exactly (960/0/0, 2638/0/0), and dropping the mutate or the call facts makes
-- 216 / 146 differ — the comparison is live.
--
-- FACTS (every value a literal):
--   param(f, id, i)        id is f's i-th parameter (f: a function's name, or `λ<n>` for a lambda)
--   store(f, root, cap)    in f, a store into a table rooted in variable `root`; cap: root is a CAPTURED variable of f
--   mutate(root)           a primitive that MUTATES its first argument (mix's MUTATES), on a table rooted in `root`
--   assignvar(f, id, cap)  in f, an assignment to variable id; cap as above
--   alloc(f, id)           in f, `local id = { … }` — a table constructor
--   callarg(fn, i, a)      a call of the named function fn with variable a as its i-th argument
--   callvarg(x, i, a)      a call through the local x with variable a as its i-th argument
--   lamlocal(x, lam)       the local x is bound to the lambda `lam`
-- ⚠ The fact set is a SET, emitted in canonical order: no pairs() order reaches the rules (CART-1527's lesson).
local M = {}
local unpack = table.unpack or unpack

local function load_A() return require('cartograph.algebra').load() end

--- the facts of the lowered functions `funcs` ({ name -> { params, body } }) -> list of ground terms.
--- opts.mutates: the primitives that mutate their first argument (mix's MUTATES); opts.kinds: only these kinds
function M.facts(funcs, opts)
    local A = load_A()
    local kinds, mutates = opts and opts.kinds, opts and opts.mutates or {}
    local facts = {}
    -- (a fact's values are literals, one per value: terms are values, so sharing them is compression — and a fact of
    -- an unwanted kind builds nothing)
    local lits = {}
    local function fact(k, ...)
        if kinds and not kinds[k] then return end
        local kids = {}
        for i = 1, select('#', ...) do
            local v = select(i, ...)
            local l = lits[v]; if not l then l = A.lit(v); lits[v] = l end
            kids[i] = l
        end
        facts[#facts + 1] = A.node(k, unpack(kids))
    end
    local function root(t)
        for _ = 1, 10000 do
            if type(t) ~= 'table' then return nil end
            if t.op == 'var' then return t.id end
            if t.op ~= 'index' then return nil end
            t = t.obj
        end
    end
    local lamof = {}
    local function walk(x, owner, free, seen)
        if type(x) ~= 'table' or seen[x] then return end
        seen[x] = true
        if x.op == 'lambda' then
            local me, fr = 'λ' .. tostring(x.id), {}
            for _, id in ipairs(x.free or {}) do fr[id] = true end
            for i, id in ipairs(x.params or {}) do fact('param', me, id, i) end
            for _, c in pairs(x) do if type(c) == 'table' then walk(c, me, fr, seen) end end
            return
        end
        if x.op == 'local' and x.id then
            if x.e and x.e.op == 'table' then fact('alloc', owner, x.id) end
            if x.e and x.e.op == 'lambda' then lamof[x.id] = x.e end
        end
        if x.op == 'assign' or x.op == 'assignm' then
            for _, t in ipairs(x.op == 'assign' and { x.target } or x.targets or {}) do
                if t.op == 'var' then
                    fact('assignvar', owner, t.id, free[t.id] == true)
                    if x.op == 'assign' and x.e and x.e.op == 'lambda' then lamof[t.id] = x.e end
                else
                    local r = root(t)
                    if r then fact('store', owner, r, free[r] == true) end
                end
            end
        end
        if x.op == 'prim' and mutates[x.name] and x.args and root(x.args[1]) then fact('mutate', root(x.args[1])) end
        if x.op == 'call' and x.fn and x.args then
            for i, a in ipairs(x.args) do if type(a) == 'table' and a.op == 'var' then fact('callarg', x.fn, i, a.id) end end
        end
        if x.op == 'callv' and x.f and x.f.op == 'var' and x.args then
            for i, a in ipairs(x.args) do if type(a) == 'table' and a.op == 'var' then fact('callvarg', x.f.id, i, a.id) end end
        end
        -- (pairs order is harmless HERE: the IR is a tree, so a node has one owner whatever the order, and the engine
        -- sorts the facts by key before any rule reads them)
        for _, c in pairs(x) do if type(c) == 'table' then walk(c, owner, free, seen) end end
    end
    local names = {}
    for name, f in pairs(funcs) do if type(f) == 'table' then names[#names + 1] = name end end
    table.sort(names)
    for _, name in ipairs(names) do
        local f = funcs[name]
        for i, id in ipairs(f.params or {}) do fact('param', name, id, i) end
        walk(f.body, name, {}, {})
    end
    local ls = {}
    for v in pairs(lamof) do ls[#ls + 1] = v end
    table.sort(ls, function (a, b) return tostring(a) < tostring(b) end)
    for _, v in ipairs(ls) do fact('lamlocal', v, 'λ' .. tostring(lamof[v].id)) end
    return facts
end

-- ── the RULES, as data ─────────────────────────────────────────────────────────────────────────────────────────
local function rules()
    local A = load_A()
    local H, N, L = A.hole, A.node, A.lit
    return {
        -- FORCED: a variable whose table is written where mix cannot follow it — never computed early
        forced = {
            { stratum = 1, head = N('forced', H('r')), body = { N('store', H('f'), H('r'), L(true)) } }, -- a store into a captured table
            { stratum = 1, head = N('forced', H('r')), body = { N('param', H('f'), H('r'), H('i')), N('store', H('f'), H('r'), L(false)) } }, -- into f's own parameter
            { stratum = 1, head = N('forced', H('r')), body = { N('mutate', H('r')) } }, -- a mutating primitive's root
            { stratum = 1, head = N('calledge', H('fn'), H('i'), H('a')), body = { N('callarg', H('fn'), H('i'), H('a')) } },
            { stratum = 1, head = N('calledge', H('lam'), H('i'), H('a')), body = { N('lamlocal', H('x'), H('lam')), N('callvarg', H('x'), H('i'), H('a')) } },
            -- FORCED ACROSS CALLS: an argument variable passed where the callee's parameter is forced
            { stratum = 1, head = N('forced', H('a')), body = { N('calledge', H('fn'), H('i'), H('a')), N('param', H('fn'), H('p'), H('i')), N('forced', H('p')) } },
        },
        -- FRESH ROOTS: a local built by a table constructor, never assigned again, not a parameter / forced / boxed
        -- (forced and boxed are SEEDED: mix's sets, as facts)
        fresh = {
            { stratum = 1, head = N('reassigned', H('x')), body = { N('assignvar', H('f'), H('x'), H('c')) } },
            { stratum = 1, head = N('isparam', H('x')), body = { N('param', H('f'), H('x'), H('i')) } },
            { stratum = 2, head = N('fresh', H('x')), body = { N('alloc', H('f'), H('x')) },
              absent = { N('reassigned', H('x')), N('forced', H('x')), N('boxed', H('x')), N('isparam', H('x')) } },
        },
    }
end
local compiled = {}
local function rule_set(name)
    if not compiled[name] then compiled[name] = require('cartograph.saturate').compile(load_A(), rules()[name]) end
    return compiled[name]
end
M.rules = rules

local function ids(db, kind)
    local out = {}
    for _, f in ipairs(db.by[kind] or {}) do out[f.kids[1].v] = true end
    return out
end

--- the FRESH ROOTS of the lowered functions, given mix's forced and boxed sets -> { id -> true }
function M.fresh(funcs, forced, boxed)
    local A = load_A()
    local facts = M.facts(funcs, { kinds = { alloc = true, assignvar = true, param = true } })
    for _, s in ipairs({ { 'forced', forced }, { 'boxed', boxed } }) do
        for id in pairs(s[2] or {}) do facts[#facts + 1] = A.node(s[1], A.lit(id)) end
    end
    return ids(require('cartograph.saturate').run(rule_set('fresh'), facts, { list = false }), 'fresh')
end

--- the FORCED variables of the lowered functions -> { id -> true }. opts.mutates: mix's MUTATES
function M.forced(funcs, opts)
    local facts = M.facts(funcs, { mutates = opts and opts.mutates,
        kinds = { param = true, store = true, mutate = true, callarg = true, callvarg = true, lamlocal = true } })
    return ids(require('cartograph.saturate').run(rule_set('forced'), facts, { list = false }), 'forced')
end

return M
