-- QUERY PLANS (lua/cartograph/qplan.lua, CART-1142): a plan is a term, laws are template pairs with side conditions,
-- the rewrite SEARCHES every reachable plan for the cheapest, and the checker diffs rows. Territory is the consumer.

local function A() return require('cartograph.algebra').load() end

-- toy operators: `slow` and `fast` compute the same number; `mid` is a dearer step between them
local function toy()
    local QP = require 'cartograph.qplan'
    local ops = {
        t_slow = { run = function (x) return x * 2 end, cost = function () return 10 end, props = { ok = true } },
        t_mid = { run = function (x) return x + x end, cost = function () return 50 end },
        t_fast = { run = function (x) return 2 * x end, cost = function () return 1 end },
        t_wrong = { run = function (x) return x * 3 end, cost = function () return 0 end },
    }
    for name, def in pairs(ops) do if not QP.OPS[name] then QP.register(name, def) end end
    local X = QP.input('x')
    return QP, X
end

test('qplan: a plan is a term — eval runs it, holes read the inputs, literals are constants', function ()
    local QP, X = toy()
    eq(14, QP.eval(QP.op('t_slow', X), { x = 7 }))
    eq('(t_slow ?x)', A().show(QP.op('t_slow', X)))
end)

test('qplan.rewrite SEARCHES: it reaches the cheapest plan through a DEARER intermediate step, which greedy never takes', function ()
    local QP, X = toy()
    local laws = { QP.law('to mid', QP.op('t_slow', X), QP.op('t_mid', X)), QP.law('mid to fast', QP.op('t_mid', X), QP.op('t_fast', X)) }
    local best, log = QP.rewrite(QP.op('t_slow', X), laws, {})
    eq('(t_fast ?x)', A().show(best))
    eq({ 'to mid', 'mid to fast' }, log.best.via)
    eq(3, #log.explored)
end)

test('qplan.rewrite: a side condition that does not hold DECLINES the law by name, and the plan stays', function ()
    local QP, X = toy()
    local laws = { QP.law('to wrong', QP.op('t_slow', X), QP.op('t_wrong', X), function () return false, 't_wrong is not equal to t_slow' end) }
    local best, log = QP.rewrite(QP.op('t_slow', X), laws, {})
    eq('(t_slow ?x)', A().show(best))
    eq('t_wrong is not equal to t_slow', log.declined[1].why)
end)

test('qplan.check: rows that differ are named; equal computations agree', function ()
    local QP, X = toy()
    local rows = function (v) return { r = tostring(v) } end
    ok(QP.check(QP.op('t_slow', X), QP.op('t_fast', X), { x = 5 }, rows).ok)
    local bad = QP.check(QP.op('t_slow', X), QP.op('t_wrong', X), { x = 5 }, rows)
    eq(false, bad.ok)
    eq({ key = 'r', a = '10', b = '15' }, bad.differ[1])
end)

test('qplan territory: every form the laws reach agrees with territory.compute, row by row; the search ends fused', function ()
    local TR = require 'cartograph.territory'
    local P = TR.qplan()
    local QP = P.QP
    -- two entries sharing a cycle (c <-> d), a private tail each, one shared leaf, an unreached node
    local nodes = { 'e1', 'e2', 'a', 'b', 'c', 'd', 'leaf', 'z' }
    local uses = { e1 = { 'a', 'c' }, e2 = { 'b', 'd' }, a = { 'leaf' }, b = {}, c = { 'd' }, d = { 'c', 'leaf' }, leaf = {}, z = {} }
    local usedby = {}
    for from, cs in pairs(uses) do for _, to in ipairs(cs) do usedby[to] = usedby[to] or {}; table.insert(usedby[to], from) end end
    local inputs = { seeds = { 'e1', 'e2' }, graph = { nodes = nodes, uses = uses, usedby = usedby } }
    local want = TR.rows(TR.compute(inputs.seeds, uses, usedby))
    local S, G = QP.input('seeds'), QP.input('graph')
    for _, plan in ipairs {
        P.plan,
        QP.op('classify', QP.op('seedsets', S, G, QP.const('worklist')), S, G),
        QP.op('classify', QP.op('seedsets', S, G, QP.const('scc')), S, G),
        QP.op('classify_bits', S, G, QP.const('scc')),
        QP.op('classify_bits', S, G, QP.const('worklist')),
    } do
        eq(want, TR.rows(QP.eval(plan, inputs)), A().show(plan))
    end
    eq('core 2 nil B [e1,e2]', want.leaf)   -- both entries reach it: the core, entered at a border
    local stats = TR.qplan_stats(inputs.seeds, inputs.graph, 1)
    local best = QP.rewrite(P.plan, P.laws, stats)
    ok(A().show(best):find('seedsets', 1, true) or A().show(best):find('classify_bits', 1, true), A().show(best))
end)

test('qplan.eval_many: plans sharing a subplan compute it ONCE, and each still gets its own answer', function ()
    local QP, X = toy()
    local calls = 0
    if not QP.OPS.t_count then
        QP.register('t_count', { run = function (x) calls = calls + 1; return x + 1 end })
        QP.register('t_neg', { run = function (x) return -x end })
    end
    local shared = QP.op('t_count', X)
    local vals, st = QP.eval_many({ QP.op('t_slow', shared), QP.op('t_neg', QP.op('t_count', X)) }, { x = 4 })
    eq({ 10, -5 }, vals)
    eq(1, calls, 'the common subplan ran once')
    eq(1, st.shared)
end)
