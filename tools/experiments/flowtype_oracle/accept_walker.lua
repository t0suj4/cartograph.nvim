-- a WALKER CHANGE's ACCEPTANCE as ONE PLAN over toolbelt steps (CART-1645): every corpus keeps 0 wrong answers against
-- its type checker AND at least the right answers it had (a floor — a change may not quietly answer less), and the
-- answers that move with the worklist order are flagged `partial`. The same steps were run by hand after every
-- flowtype_go / flowtype_js change on 2026-10-10.
--   nvim --headless -u NONE --cmd 'set rtp^=.' -l tools/experiments/flowtype_oracle/accept_walker.lua <manifest>
-- <manifest>: Lua returning { { root, oracle, scorer, floor, args?, schedule? = true }, ... } — the oracle TSVs are
-- machine-local (tools/experiments/flowtype_oracle/README.md says how to make them). `schedule` only where ports
-- SATURATE: on typescript-language-server (2 saturated ports) no order moves anything, and the check refuses — its
-- control did not move, so it could not have failed (measured 2026-10-10)
local TA = require 'cartograph.tactic'
local T = TA.T
local corpora = dofile(assert(arg[1], 'usage: accept_walker.lua <manifest>'))
local D = vim.fn.getcwd() .. '/tools/experiments/flowtype_oracle/'
local function src(f) return io.open(f):read('a') end
local plan = T.seq(
  T.each(corpora, function (c)                                            -- the oracle: 0 wrong, at least the floor
    return T.use('oracle', { scorer = c.scorer, root = c.root, oracle = c.oracle, floor = tostring(c.floor), args = c.args })
  end),
  T.each(corpora, function (c)                                            -- the schedule: what moves is flagged
    if not c.schedule then return T.seq() end
    return T.use('variants', { decl = src(D .. 'schedule.lua'), root = c.root })
  end)
)
local t0 = vim.uv.hrtime()
local res = TA.run(require 'cartograph.store', plan, {})
print(('status %s class %s (%.0f s)'):format(tostring(res.status), tostring(res.class), (vim.uv.hrtime() - t0) / 1e9))
print('where', tostring(res.where))
print('why', tostring(res.why):sub(1, 400))
for _, tr in ipairs(res.trace or {}) do print('  trace', tr.where, tr.verb, tr.ok, tostring(tr.why):sub(1, 160)) end
