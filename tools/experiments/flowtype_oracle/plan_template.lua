-- A PLAN TEMPLATE from executed plans, and a plan nobody wrote (CART-1645 step 3). Two walker acceptances of ONE kind
-- (plans.lua's walker over all the manifest's corpora, and over its first and last) are DATA (cartograph.tactic terms
-- with term-template `each` bodies); read as kv terms (A.lua_kv) and generalized, the steps stay fixed and the corpus
-- list holds the holes — the DECISION is which corpora. Binding a new corpus into the open hole and instantiating gives
-- a plan of that kind for corpora no plan named; it runs like any other. A hole whose evidence held one value only is
-- PINNED to it: binding something else there is refused by A.instantiate (the template is as general as its donors).
-- MEASURED 2026-10-10: effect bound in -> done, 161 s, 3314 right, 0 wrong.
--   nvim --headless -u NONE --cmd 'set rtp^=.' -l tools/experiments/flowtype_oracle/plan_template.lua <manifest> <new item>
-- <manifest> as accept_walker.lua's; <new item>: Lua returning { root, oracle, scorer, floor, args? }
local A = require('cartograph.algebra').load()
local TA = require 'cartograph.tactic'
local D = vim.fn.getcwd() .. '/tools/experiments/flowtype_oracle/'
local P = dofile(D .. 'plans.lua')
local all = dofile(assert(arg[1], 'usage: plan_template.lua <manifest> <new item>'))
local new = dofile(assert(arg[2], 'usage: plan_template.lua <manifest> <new item>'))
local fam = { A.lua_kv(P.walker(all)), A.lua_kv(P.walker({ all[1], all[#all] })) }
local g = A.generalize(A.kv_terms(fam, {}))
-- every hole as the SMALLER plan has it; the decision goes into the corpus list — the SEQUENCE hole whose instances
-- disagree (the corpora between the first and the last). Another hole may differ too (the schedule's items: only some
-- corpora saturate) — it keeps the smaller plan's value
local V, open = {}, nil
for h, v in pairs(g.values[2]) do
    V[h] = v
    if v.k == 'seq' and not A.eq(v, g.values[1][h]) then open = h end
end
assert(open, 'no sequence hole tells the two plans apart: ' .. A.show(g.template.body))
V[open] = A.seq({ A.kv_term(A.lua_kv(new)) })
local inst = A.instantiate(g.template, V)
if not inst.ok then error('the template refuses the decision: ' .. vim.inspect(inst.rejected)) end
local plan = A.kv_lua(A.term_kv(inst.term))
local names = {}
for _, it in ipairs(plan[1].items) do names[#names + 1] = it.root end
print('GENERATED: oracle over ' .. table.concat(names, ', '))
local t0 = vim.uv.hrtime()
local res = TA.run(require 'cartograph.store', plan, {})
print(('status %s class %s (%.0f s)'):format(tostring(res.status), tostring(res.class), (vim.uv.hrtime() - t0) / 1e9))
for _, tr in ipairs(res.trace or {}) do print('  trace', tr.where, tr.verb, tr.ok, tostring(tr.why):sub(1, 140)) end
