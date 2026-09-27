-- qplan — QUERY PLANS: a composition of operators is an algebra TERM, and the optimizer is term rewriting (CART-1142).
--
--   a PLAN      A.node('<op>', kids…), its inputs HOLES (A.hole 'seeds'), its constants literals (A.lit 'scc')
--   an OPERATOR registered by the module that owns it:
--               { run = fn(args…) -> value, props = { … } (the DECLARED properties side conditions read),
--                 cost = fn(stats, args) -> number (symbolic in the inputs' statistics), doc }
--   a LAW       { name, lhs = template, rhs = template (sharing holes), when = fn(bindings) -> ok, why }
--               applied with the algebra's own verbs: A.match the lhs at a position, A.instantiate the rhs, A.put it
--               back. A law fires only when its side condition holds AND the plan gets cheaper under the statistics.
--
-- ★ THE UNOPTIMIZED PLAN STAYS THE ORACLE. M.check runs two plans (or a plan and a hand-built implementation) on the
-- same inputs and diffs their ROWS; a rewrite is accepted by a zero diff and a measured time, never by its cost.
--
-- "plan" alone means a txn_plan_* WRITE plan elsewhere; this module's are QUERY plans.
local M = {}

local function A() return require('cartograph.algebra').load() end

-- the values for the rhs's own holes: a law may DROP a hole the lhs bound (`if X then B end` -> nothing), and
-- instantiate refuses a value for a hole its template does not have
local function only_holes(T, values)
    local out = {}
    for h in pairs(T.holes or {}) do out[h] = values[h] end
    return out
end


M.OPS = {}

--- register an operator. def = { run, props, cost, doc }
function M.register(name, def)
    assert(type(def.run) == 'function', 'qplan.register: ' .. name .. ' has no run')
    if M.OPS[name] and M.OPS[name] ~= def then error('qplan.register: duplicate operator ' .. name) end
    M.OPS[name] = def
    return def
end

--- a plan node
function M.op(name, ...) return A().node(name, ...) end
function M.input(name) return A().hole(name) end
function M.const(v) return A().lit(v) end

--- EVALUATE a plan: holes read `inputs`, literals are their value, an operator runs on its evaluated kids
function M.eval(plan, inputs, trace)
    local function go(t)
        if t.k == 'hole' then
            local v = inputs[t.h]
            if v == nil then error('qplan.eval: no input ' .. tostring(t.h)) end
            return v
        end
        if t.k == 'lit' then return t.v end
        local op = M.OPS[t.k]
        if not op then error('qplan.eval: no operator ' .. tostring(t.k)) end
        local args = {}
        for i, c in ipairs(t.kids or {}) do args[i] = go(c) end
        local t0 = trace and vim.uv.hrtime()
        local v = op.run((table.unpack or unpack)(args, 1, #args))
        if trace then trace[#trace + 1] = { op = t.k, ms = (vim.uv.hrtime() - t0) / 1e6 } end
        return v
    end
    return go(plan)
end

--- THE UNIT WEIGHTS of the cost model, MEASURED on this machine once per process: a cost is a count of operations
--- of a kind, and the kinds differ by orders of magnitude (a hash-table insert allocates, a bitset word OR does
--- not). Uncalibrated, the model called the fused plan 2.6x slower when it measured 1.3x faster.
local UNITS
function M.units()
    if UNITS then return UNITS end
    local bit = require 'bit'
    local function per_op(n, f)
        local best = math.huge
        for _ = 1, 3 do
            local t0 = vim.uv.hrtime()
            f(n)
            best = math.min(best, (vim.uv.hrtime() - t0) / n)
        end
        return best
    end
    UNITS = {
        -- a set insert into a fresh table (the per-seed walks, invert, classify)
        hash = per_op(200000, function (n) local t = {}; for i = 1, n do if i % 64 == 1 then t = {} end; t[i] = true end end),
        -- a word of a bitset join (the solve)
        word = per_op(2000000, function (n) local a, b, c = {}, {}, {}; for i = 1, 64 do a[i] = i; b[i] = 2 * i end
            for i = 1, n do local w = i % 64 + 1; c[w] = bit.bor(a[w], b[w]) end end),
        -- one element of a pairs() walk over an existing set (classify's count). ⚠ NOT an insert: charging it as one
        -- made the deforestation law predict 26x for a saving that measured nothing
        iter = per_op(200000, function (n) local t = {}; for i = 1, 64 do t[i * 7] = true end
            local c = 0; for _ = 1, n / 64 do for _ in pairs(t) do c = c + 1 end end end),
    }
    -- ★ THE SOLVER'S OWN UNIT, measured by RUNNING it: ns per (visit x input edge x word) on a synthetic graph. Word ops
    -- alone priced the solve at 18 ms where it measured 554: its per-visit overhead is the cost.
    do
        local solve = require 'cartograph.solve'
        local V, S = 3000, 256
        local nodes, succ = {}, {}
        for i = 1, V do nodes[i] = i; succ[i] = { (i * 7) % V + 1, (i * 13) % V + 1 } end
        local L = solve.lattice.bitset(S)
        local best, visits = math.huge, 0
        for _ = 1, 3 do
            local t0 = vim.uv.hrtime()
            local r = solve.solve { nodes = nodes, succ = succ, lattice = L, strategy = 'scc',
                init = function (id) return id <= S and L.single(id) or nil end }
            best = math.min(best, (vim.uv.hrtime() - t0))
            visits = r.visits
        end
        UNITS.edgeword = best / (visits * 3 * L.words)
    end
    return UNITS
end

--- EVALUATE SEVERAL PLANS over the same inputs with their COMMON SUBPLANS computed once (CART-1142 L4; the plugin
--- payoff: many small plans, each written as its own specification, sharing what they have in common). A subterm is
--- one computation when it prints the same (A.show) — the inputs are one table, so equal terms are equal values.
--- ⚠ Operators must be pure for this: a run's result is SHARED, so a consumer that mutates it corrupts the others.
--- -> values (one per plan), stats = { runs = n, shared = n }
function M.eval_many(plans, inputs)
    local a = A()
    local memo, st = {}, { runs = 0, shared = 0 }
    local function go(t)
        if t.k == 'hole' then return inputs[t.h] end
        if t.k == 'lit' then return t.v end
        local key = a.show(t)
        if memo[key] ~= nil then st.shared = st.shared + 1; return memo[key] end
        local op = M.OPS[t.k]
        if not op then error('qplan.eval_many: no operator ' .. tostring(t.k)) end
        local args = {}
        for i, c in ipairs(t.kids or {}) do args[i] = go(c) end
        st.runs = st.runs + 1
        local v = op.run((table.unpack or unpack)(args, 1, #args))
        memo[key] = v
        return v
    end
    local out = {}
    for i, p in ipairs(plans) do out[i] = go(p) end
    return out, st
end

--- the plan's COST under `stats` (the inputs' statistics): the sum of its operators' costs
function M.cost(plan, stats)
    local total = 0
    local function go(t)
        if t.k == 'hole' or t.k == 'lit' then return end
        local op = M.OPS[t.k]
        local lits = {}
        for i, c in ipairs(t.kids or {}) do
            if c.k == 'lit' then lits[i] = c.v end
            go(c)
        end
        if op and op.cost then total = total + op.cost(stats, lits) end
    end
    go(plan)
    return total
end

--- a law: lhs and rhs are plan terms over the same holes; `when(bindings) -> ok, why` is its side condition
function M.law(name, lhs, rhs, when, why)
    local a = A()
    return { name = name, lhs = a.template(lhs), rhs = a.template(rhs), when = when, why = why }
end

--- REWRITE `plan` with `laws` under `stats` by SEARCH, not greedily: every plan the laws can reach (a law applies
--- where its lhs matches and its side condition holds, whatever the cost) is enumerated up to `opts.limit` plans, and
--- the CHEAPEST is chosen. ★ GREEDY WAS MEASURED WRONG: fusion alone is 5x slower than the per-seed closures and
--- fusion + condensation 1.3x faster, so a rewriter that takes only cheaper steps never reaches the fast plan. (An
--- e-graph is the scalable form of the same search; the plans here are a handful of nodes.)
--- -> best plan, log = { explored = { { plan, cost, via } }, declined = { { law, path, why } } }
function M.rewrite(plan, laws, stats, opts)
    local a = A()
    opts = opts or {}
    local limit = opts.limit or 64
    local seen, queue, explored, declined = {}, {}, {}, {}
    local costf = opts.cost or function (p) return M.cost(p, stats) end
    local function add(p, via)
        local key = a.show(p)
        if seen[key] then return end
        seen[key] = true
        local e = { plan = p, cost = costf(p), via = via }
        explored[#explored + 1] = e
        queue[#queue + 1] = e
    end
    add(plan, {})
    local head = 1
    while head <= #queue and #explored < limit do
        local cur = queue[head]; head = head + 1
        for _, pos in ipairs(a.positions(cur.plan)) do
            local path, sub = pos.path, pos.node
            if sub.k ~= 'hole' and sub.k ~= 'lit' then
                for _, L in ipairs(laws) do
                    local m = a.match(L.lhs, sub)
                    if m.ok then
                        local ok, why = true, nil
                        if L.when then ok, why = L.when(m.values) end
                        local inst = ok and a.instantiate(L.rhs, only_holes(L.rhs, m.values))
                        if ok and inst and inst.ok then
                            local via = {}
                            for n, x in ipairs(cur.via) do via[n] = x end
                            via[#via + 1] = L.name
                            add(a.put(cur.plan, path, inst.term), via)
                        elseif not ok then
                            declined[#declined + 1] = { law = L.name, path = path, why = why or 'side condition' }
                        end
                    end
                end
            end
        end
    end
    local best = explored[1]
    for _, e in ipairs(explored) do if e.cost < best.cost then best = e end end
    return best.plan, { explored = explored, declined = declined, best = best }
end

--- A SAMPLED COST: run `plan` on inputs shrunk to two sizes (sample(inputs, k) -> inputs at 1/k), fit a line in the
--- size, extrapolate to the full size. ★ WHY: the formula model's operators erred by different factors (the per-seed
--- walks 3x under, the solver's unit taken at 8 words and applied at 254), so their SUM mis-ranked the plans both
--- ways in turn; a measurement on the real input's shape does not. -> fn(plan) -> ns, and the samples taken
function M.sampled_cost(inputs, sample, opts)
    opts = opts or {}
    -- 1/4 and 1/2: extrapolating from 1/16 and 1/8 multiplied the timing noise ~15x (one plan read 136 ms and 269 ms
    -- in two calls); from here ~3x
    local k1, k2 = opts.k1 or 4, opts.k2 or 2
    local in1, in2 = sample(inputs, k1), sample(inputs, k2)
    local log = {}
    local function time(plan, inp)
        local best = math.huge
        for _ = 1, opts.reps or 3 do
            collectgarbage('collect')   -- a collection owed by the previous run is not this plan's cost
            local t0 = vim.uv.hrtime()
            M.eval(plan, inp)
            best = math.min(best, vim.uv.hrtime() - t0)
        end
        return best
    end
    return function (plan)
        local t1, t2 = time(plan, in1), time(plan, in2)
        -- the line through (1/k1, t1) and (1/k2, t2), read at 1
        local slope = (t2 - t1) / (1 / k2 - 1 / k1)
        local est = t1 + slope * (1 - 1 / k1)
        log[#log + 1] = { plan = plan, t1 = t1, t2 = t2, est = est }
        return math.max(est, t2)
    end, log
end

--- THE CHECKER: two computations over the same inputs, compared ROW BY ROW. `a`, `b` are plans or functions(inputs);
--- rows(value) -> { key -> row string }. -> { same, only_a, only_b, differ = { { key, a, b } }, ms_a, ms_b }
function M.check(a, b, inputs, rows)
    local function run(x)
        local t0 = vim.uv.hrtime()
        local v = type(x) == 'function' and x(inputs) or M.eval(x, inputs)
        return v, (vim.uv.hrtime() - t0) / 1e6
    end
    local va, ma = run(a)
    local vb, mb = run(b)
    local ra, rb = rows(va), rows(vb)
    local out = { same = 0, only_a = 0, only_b = 0, differ = {}, ms_a = ma, ms_b = mb }
    for k, x in pairs(ra) do
        local y = rb[k]
        if y == nil then out.only_a = out.only_a + 1
        elseif y == x then out.same = out.same + 1
        else out.differ[#out.differ + 1] = { key = k, a = x, b = y } end
    end
    for k in pairs(rb) do if ra[k] == nil then out.only_b = out.only_b + 1 end end
    table.sort(out.differ, function (x, y) return tostring(x.key) < tostring(y.key) end)
    out.ok = out.only_a == 0 and out.only_b == 0 and #out.differ == 0
    return out
end

return M
