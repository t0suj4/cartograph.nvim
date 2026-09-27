-- solve — THE SHARED MONOTONE-FRAMEWORK SOLVER (CART-1037; the query-plan optimizer's first operator, CART-1142).
--
-- Every hand-rolled fixpoint in the tree has one body: for each node, new = transfer(join(inputs)); if new ~= old,
-- go again. This is that body once, over a DECLARED lattice:
--
--   solve{ nodes = { id… }, succ = id -> { id… }, direction = 'forward' | 'backward',
--          lattice = { bottom = fn() -> v, join = fn(a, b) -> v, eq = fn(a, b) -> bool, props = { … } },
--          init = fn(id) -> v | nil,       a node's own contribution (joined with its inputs)
--          transfer = fn(id, v) -> v | nil  (nil = the identity: the value passes through unchanged)
--          strategy = 'worklist' | 'scc', limit = max node visits,
--          kernel = a replacement for the inner worklist loop — a SPECIALIZED copy of run_worklist that qlower lifted,
--                   folded under facts the caller guarantees, and lowered back (CART-1142 S5b) }
--   -> { value = { id -> v }, converged = bool, visits = n, strategy }
--
-- FORWARD: a node's input is the join of its predecessors' values (values flow along succ, caller to callee).
-- BACKWARD: the join of its successors' (callee to caller). `converged` is a RETURN FIELD: a bounded run can no longer
-- discard its non-convergence (CART-0748).
--
-- Two STRATEGIES, the physical plans the optimizer chooses between (CART-1142 law L2):
--   worklist  FIFO over every node until nothing changes — the reference.
--   scc       the strongly connected components (scc.condense) in topological order for the direction, a local
--             worklist inside each: a component's inputs are final before it starts, so one pass over the DAG.
--             Valid for any monotone transfer; it only changes the order of the same equations.
local M = {}

-- ── lattices: declared, with the properties the optimizer's side conditions read ─────────────────────────────────
M.lattice = {}

--- the powerset of a universe of `n` indexed members as a BITSET (LuaJIT `bit`, 32 members a word).
--- props: join is commutative, associative, idempotent (a semilattice); `union` is the join.
function M.lattice.bitset(n)
    local bit = require 'bit'
    -- ★ PRESIZED: a join builds a fresh W-word array, and grown one slot at a time it reallocates ~log2(W) times; that,
    -- not the ORs, was the solve's cost (measured: 26 µs a visit where the word ops predict 0.3)
    local okn, tnew = pcall(require, 'table.new')
    local function fresh(w) return okn and tnew(w, 0) or {} end
    local words = math.floor((n + 31) / 32)
    local L = { n = n, words = words,
        props = { join = { commutative = true, associative = true, idempotent = true }, kind = 'powerset' } }
    local EMPTY = {}
    for w = 1, words do EMPTY[w] = 0 end
    function L.bottom() return EMPTY end   -- shared and never written: join always allocates
    function L.single(i)
        local s = fresh(words)
        for w = 1, words do s[w] = 0 end
        local w = bit.rshift(i - 1, 5) + 1
        s[w] = bit.bor(s[w], bit.lshift(1, bit.band(i - 1, 31)))
        return s
    end
    function L.join(a, b)
        if a == b or b == EMPTY then return a end
        if a == EMPTY then return b end
        local s, same_a, same_b = fresh(words), true, true
        for w = 1, words do
            local x = bit.bor(a[w], b[w])
            s[w] = x
            if x ~= a[w] then same_a = false end
            if x ~= b[w] then same_b = false end
        end
        -- ★ INTERNING BY IDENTITY: a join that adds nothing returns its operand, so equal values stay one table and the
        -- next eq is a pointer compare
        if same_a then return a end
        if same_b then return b end
        return s
    end
    -- ★ THE IN-PLACE FORM the solver prefers when a lattice has it: one scratch accumulator per solve, a value
    -- allocated only when a node's value really changes (the join above allocates per call, intermediate joins
    -- included)
    function L.leq(a, b)
        if a == b or a == EMPTY then return true end
        for w = 1, words do if bit.band(a[w], bit.bnot(b[w])) ~= 0 then return false end end
        return true
    end
    function L.scratch() return fresh(words) end
    function L.copy_into(dst, src) for w = 1, words do dst[w] = src[w] end; return dst end
    function L.join_into(acc, b) for w = 1, words do acc[w] = bit.bor(acc[w], b[w]) end end
    function L.copy(src) return L.copy_into(fresh(words), src) end
    function L.eq(a, b)
        if a == b then return true end
        for w = 1, words do if a[w] ~= b[w] then return false end end
        return true
    end
    function L.members(s)
        local out = {}
        for w = 1, words do
            local x = s[w]
            if x ~= 0 then
                for b = 0, 31 do
                    if bit.band(x, bit.lshift(1, b)) ~= 0 then out[#out + 1] = (w - 1) * 32 + b + 1 end
                end
            end
        end
        return out
    end
    function L.count(s)
        local c = 0
        for w = 1, words do
            local x = s[w]
            while x ~= 0 do x = bit.band(x, x - 1); c = c + 1 end
        end
        return c
    end
    return L
end

-- predecessors of every node, for the direction's inputs
local function inputs_of(nodes, succ, direction)
    if direction == 'backward' then return succ end
    local pred = {}
    for _, id in ipairs(nodes) do
        for _, s in ipairs(succ[id] or {}) do
            local p = pred[s]
            if not p then p = {}; pred[s] = p end
            p[#p + 1] = id
        end
    end
    return pred
end
-- the nodes a change at `id` must revisit
local function outputs_of(nodes, succ, direction)
    if direction == 'backward' then return inputs_of(nodes, succ, 'forward') end
    return succ
end

local function run_worklist(o, order, inp, outp, value, st)
    local L, init, transfer = o.lattice, o.init, o.transfer
    local queue, queued, head = {}, {}, 1
    for _, id in ipairs(order) do queue[#queue + 1] = id; queued[id] = true end
    local member = o.member   -- restrict the revisits to one component (scc strategy)
    local scratch = L.join_into and L.scratch() or nil
    while head <= #queue do
        if st.visits >= st.limit then return false end
        local id = queue[head]; head = head + 1
        queued[id] = nil
        st.visits = st.visits + 1
        local old = value[id]
        local v
        if scratch then
            -- in place: the result is an EXISTING value table (an input that covers the rest, or `old`) unless the
            -- inputs really add up to something new — equal values then stay one table, which interns them
            local acc
            v = init and init(id) or nil
            for _, p in ipairs(inp[id] or {}) do
                local pv = value[p]
                if pv and pv ~= v then
                    if v == nil then v = pv
                    elseif not L.leq(pv, v) then
                        if not acc then acc = L.copy_into(scratch, v); v = acc end
                        L.join_into(acc, pv)
                    end
                end
            end
            if v == nil then v = L.bottom() end
            if v == acc then v = (old and L.eq(old, acc)) and old or L.copy(acc) end
        else
            v = (init and init(id)) or L.bottom()
            for _, p in ipairs(inp[id] or {}) do
                local pv = value[p]
                if pv then v = L.join(v, pv) end
            end
        end
        if transfer then v = transfer(id, v) end
        if not old or not L.eq(old, v) then
            value[id] = v
            for _, s in ipairs(outp[id] or {}) do
                if not queued[s] and (not member or member[s]) then queue[#queue + 1] = s; queued[s] = true end
            end
        end
    end
    return true
end

function M.solve(o)
    local nodes, direction = o.nodes, o.direction or 'forward'
    local inp = inputs_of(nodes, o.succ, direction)
    local outp = outputs_of(nodes, o.succ, direction)
    local value = {}
    local st = { visits = 0, limit = o.limit or math.huge }
    local strategy = o.strategy or 'worklist'
    local converged = true
    if strategy == 'worklist' then
        converged = (o.kernel or run_worklist)(o, nodes, inp, outp, value, st)
    elseif strategy == 'scc' then
        local ids = {}
        for i, id in ipairs(nodes) do ids[i] = id end
        table.sort(ids, function (a, b) return tostring(a) < tostring(b) end)
        local con = require('cartograph.scc').condense(o.succ, ids)
        -- Tarjan emits a component after everything it reaches: emission order is callees first, which is the order a
        -- BACKWARD problem needs; a FORWARD one runs the reverse
        local first, last, step = con.n, 1, -1
        if direction == 'backward' then first, last, step = 1, con.n, 1 end
        for ci = first, last, step do
            local ms = con.members[ci]
            local member = nil
            if #ms > 1 then member = {}; for _, id in ipairs(ms) do member[id] = true end end
            local sub = { lattice = o.lattice, init = o.init, transfer = o.transfer, member = member or {} }
            if not member then sub.member[ms[1]] = true end
            if not (o.kernel or run_worklist)(sub, ms, inp, outp, value, st) then converged = false; break end
        end
    else
        error('solve: no strategy ' .. tostring(strategy))
    end
    return { value = value, converged = converged, visits = st.visits, strategy = strategy }
end

--- the file this module was loaded from, for qlower to lift its kernel
function M.source_path() return (debug.getinfo(1, 'S').source:gsub('^@', '')) end

return M
