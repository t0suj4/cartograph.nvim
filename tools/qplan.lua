-- qplan — CAN THE QUERY-PLAN OPTIMIZER REWRITE A COMPOSED ANALYSIS, AND IS THE REWRITE RIGHT AND FASTER? (CART-1142)
--
--   nvim --headless -u NONE -l tools/qplan.lua <corpus|dir> [--show N]
--
-- Territory is the first consumer (territory.qplan()). Over one extracted graph:
--   CHECKER  the NAIVE plan (one closure per seed, the composition as written) against territory.compute (the
--            hand-built implementation, its independent oracle), row by row
--   REWRITE  the laws under the graph's statistics (|V|, |E|, |S|): which fired, which declined and why, the cost
--            before and after
--   ACCEPT   the rewritten plan against the naive one, row by row, and both timed
local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
local bench = dofile(repo .. '/tools/bench.lua')
bench.bootstrap()

local target, show = nil, 5
local i = 1
while arg[i] do
    if arg[i] == '--show' then show = tonumber(arg[i + 1]); i = i + 1
    elseif not target then target = arg[i]
    else io.stderr:write('unknown argument ' .. arg[i] .. '\n'); os.exit(2) end
    i = i + 1
end
if not target then io.stderr:write('usage: tools/qplan.lua <corpus|dir> [--show N]\n'); os.exit(2) end
local c = bench.corpus(target)
local function print(line) io.write(line, '\n') end

local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local TR = require 'cartograph.territory'
local t0 = vim.uv.hrtime()
store.ingest(ts.extract(c.root, c.packs and { packs = c.packs } or nil))
local ms_extract = (vim.uv.hrtime() - t0) / 1e6

local ids, E = {}, 0
for _, n in ipairs(store.data.nodes) do ids[#ids + 1] = n.id end
for _, cs in pairs(store.uses) do E = E + #cs end
local lang_cache = {}
local seeds = TR.roots(store.data.nodes, store.usedby, function (f)
    local l = lang_cache[f]
    if l == nil then l = ts.parse_lang(f) or false; lang_cache[f] = l end
    return l or nil
end)
local graph = { nodes = ids, uses = store.uses, usedby = store.usedby }
local inputs = { seeds = seeds, graph = graph }
local stats = TR.qplan_stats(seeds, graph)
local P = TR.qplan()
local QP, A = P.QP, require('cartograph.algebra').load()

print(('qplan  %s  (extract %.0f ms)  |V| %d  |E| %d  |S| %d seeds  R ~%.0f (seed, node) pairs, from %d sampled seeds')
    :format(c.name, ms_extract, stats.V, stats.E, stats.S, stats.R, stats.sampled))
print('  plan   ' .. A.show(P.plan))

-- THE CHECKER: the composition as written against the hand-built implementation
local chk = QP.check(P.plan, function (inp) return TR.compute(inp.seeds, inp.graph.uses, inp.graph.usedby) end, inputs, TR.rows)
print(('  CHECK  naive plan vs territory.compute: same %d, differ %d, only-plan %d, only-compute %d   (%.0f ms vs %.0f ms)')
    :format(chk.same, #chk.differ, chk.only_a, chk.only_b, chk.ms_a, chk.ms_b))
for n = 1, math.min(show, #chk.differ) do print('     ' .. chk.differ[n].key .. '\n       plan    ' .. chk.differ[n].a .. '\n       compute ' .. chk.differ[n].b) end

-- THE REWRITE: every plan the laws reach, costed; the cheapest chosen
local formula_opt = QP.rewrite(P.plan, P.laws, stats)
local sampled, samples = QP.sampled_cost(inputs, TR.qplan_sample)
local opt, log = QP.rewrite(P.plan, P.laws, stats, { cost = sampled })
print('  FORMULA MODEL would choose ' .. A.show(formula_opt))
print(('  UNITS  hash insert %.1f ns, set iteration %.1f ns, bitset word %.2f ns, solver edge-word %.2f ns (measured here)')
    :format(stats.units.hash, stats.units.iter, stats.units.word, stats.units.edgeword))
print(('  REWRITE (sampled cost: every 4th and 2nd seed, extrapolated)  %d plan(s) explored'):format(#log.explored))
for _, e in ipairs(log.explored) do
    print(('     %s predicted %6.0f ms  formula %6.0f ms  via [%s]  %s'):format(e == log.best and '*' or ' ', e.cost / 1e6,
        QP.cost(e.plan, stats) / 1e6, table.concat(e.via, ', '), A.show(e.plan)))
end
for _, d in ipairs(log.declined) do print(('     declined %s at %s: %s'):format(d.law, table.concat(d.path, '.'), d.why)) end

-- ACCEPT: the rewrite against the oracle, both timed
local acc = QP.check(P.plan, opt, inputs, TR.rows)
print(('  ACCEPT  optimized vs naive: same %d, differ %d, only-naive %d, only-optimized %d   (naive %.0f ms, optimized %.0f ms, %.1fx)')
    :format(acc.same, #acc.differ, acc.only_a, acc.only_b, acc.ms_a, acc.ms_b, acc.ms_a / math.max(acc.ms_b, 0.001)))
for n = 1, math.min(show, #acc.differ) do print('     ' .. acc.differ[n].key .. '\n       naive     ' .. acc.differ[n].a .. '\n       optimized ' .. acc.differ[n].b) end
-- PREDICTED vs MEASURED, per form: the median of 5 runs (one run is noise; the max of several selects it)
local function median_ms(plan)
    local xs = {}
    for r = 1, 5 do
        collectgarbage('collect')
        local t1 = vim.uv.hrtime()
        QP.eval(plan, inputs)
        xs[r] = (vim.uv.hrtime() - t1) / 1e6
    end
    table.sort(xs)
    return xs[3]
end
local S_, G_ = QP.input('seeds'), QP.input('graph')
local forms = {
    { 'naive (per-seed closures)', P.plan },
    { 'L1 alone (worklist)', QP.op('classify', QP.op('seedsets', S_, G_, QP.const('worklist')), S_, G_) },
    { 'L1+L2 (scc)', QP.op('classify', QP.op('seedsets', S_, G_, QP.const('scc')), S_, G_) },
    { 'L1+L2+L3 (fused, scc)', QP.op('classify_bits', S_, G_, QP.const('scc')) },
}
local base_cost, base_ms
for _, f in ipairs(forms) do
    local r = QP.check(P.plan, f[2], inputs, TR.rows)
    local cst, ms = sampled(f[2]), median_ms(f[2])
    base_cost, base_ms = base_cost or cst, base_ms or ms
    print(('  FORM %-27s rows %-10s sampled-predicted %.0f ms (%.1fx)   median %.0f ms (measured %.1fx)'):format(f[1],
        r.ok and 'agree' or ('DIFFER ' .. #r.differ), cst / 1e6, base_cost / cst, ms, base_ms / ms))
end
-- THE SOLVER'S OWN COUNTS: visits per strategy (the cost model's `rounds` is a declared guess until this says)
do
    local solve = require 'cartograph.solve'
    local L = solve.lattice.bitset(#seeds)
    local index = {}
    for n, e in ipairs(seeds) do index[e] = n end
    for _, strat in ipairs { 'worklist', 'scc' } do
        local t1 = vim.uv.hrtime()
        local r = solve.solve { nodes = ids, succ = store.uses, direction = 'forward', lattice = L, strategy = strat,
            init = function (id) local n = index[id]; return n and L.single(n) or nil end }
        local ms = (vim.uv.hrtime() - t1) / 1e6
        local distinct, tables = 0, {}
        for _, v in pairs(r.value) do if not tables[v] then tables[v] = true; distinct = distinct + 1 end end
        print(('  SOLVE %-8s visits %d = %.2f x |V|, converged %s, %.0f ms, %d distinct value tables'):format(strat, r.visits,
            r.visits / #ids, tostring(r.converged), ms, distinct))
    end
end
-- S5b LOWERING: the solver's own kernel LIFTED from solve.lua, specialized under the facts this plan guarantees,
-- LOWERED back to Lua, loaded, checked and timed
do
    local QL = require 'cartograph.qlower'
    local solve = require 'cartograph.solve'
    local fd = assert(io.open(solve.source_path()))
    local src = fd:read('a'); fd:close()
    local t = assert(QL.lift(src))
    local _, fn = QL.find_function(t, 'run_worklist')
    local function kernel_of(term)
        local text = QL.lower(term) .. ' return run_worklist'
        local f, err = load(text, '=qlower:run_worklist')
        if not f then error('the lowered kernel does not load: ' .. tostring(err)) end
        return f(), #text
    end
    local L = solve.lattice.bitset(#seeds)
    local index = {}
    for n, e in ipairs(seeds) do index[e] = n end
    local function run(strat, kernel)
        collectgarbage('collect')
        local t1 = vim.uv.hrtime()
        local r = solve.solve { nodes = ids, succ = store.uses, direction = 'forward', lattice = L, strategy = strat, kernel = kernel,
            init = function (id) local n = index[id]; return n and L.single(n) or nil end }
        return r, (vim.uv.hrtime() - t1) / 1e6
    end
    local function same(a, b)
        for id, v in pairs(a.value) do if not (b.value[id] and L.eq(v, b.value[id])) then return false, id end end
        for id in pairs(b.value) do if not a.value[id] then return false, id end end
        return true
    end
    local plain = kernel_of(fn)
    for _, strat in ipairs { 'worklist', 'scc' } do
        -- the facts THIS call guarantees: no transfer, an in-place lattice; the worklist strategy has no component
        local facts = { transfer = 'nil', scratch = 'set' }
        if strat == 'worklist' then facts.member = 'nil' end
        local spec, log = QL.specialize(fn, QL.fold_laws(), facts)
        local kernel, bytes = kernel_of(spec)
        local fired = {}
        for _, l in ipairs(log) do fired[#fired + 1] = l.law end
        local ref, ms_ref = run(strat)
        local rt, ms_rt = run(strat, plain)
        local sp, ms_sp = run(strat, kernel)
        local ok_rt, ok_sp = same(ref, rt), same(ref, sp)
        -- medians of 5 for the timing
        local function med(k) local xs = {}; for r = 1, 5 do local _, ms = run(strat, k); xs[r] = ms end; table.sort(xs); return xs[3] end
        print(('  LOWER %-8s laws [%s]  %d bytes of Lua | round trip %s, specialized %s | median solve: source %.0f ms, round-tripped %.0f ms, specialized %.0f ms')
            :format(strat, table.concat(fired, ', '), bytes, ok_rt and 'agrees' or 'DIFFERS', ok_sp and 'agrees' or 'DIFFERS',
                med(nil), med(plain), med(kernel)))
    end
end
