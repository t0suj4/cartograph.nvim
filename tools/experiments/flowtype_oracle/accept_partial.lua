-- CART-1643's ACCEPTANCE as ONE PLAN over toolbelt steps (CART-1645 step 2) — a tactical term, run by cartograph.tactic:
--   1 variants schedule.lua   flowtype under four worklist orders: what moves is flagged `partial`, the stack moves
--   2 variants cap.lua        the whole (non-partial) answers survive a bigger cap, the partial ones move
--   3 each taint rule: mutant  the rule removed alone, its corpus check must FAIL (the rule is needed)
-- The first run refused on step 3 by name (no tactic `mutant-variants`): the missing step, built as `mutant`. Then the
-- whole plan ran: done, 702 s, every rule caught (2026-10-10).
--   nvim --headless -u NONE --cmd 'set rtp^=.' -l tools/experiments/flowtype_oracle/accept_partial.lua <ts tree> <lua tree>
-- (<ts tree> e.g. ~/git/arktype; <lua tree> a copy of lua/ + plugin/ — the load-results rule is caught only there)
local TA = require 'cartograph.tactic'
local root = assert(arg[1], 'usage: accept_partial.lua <ts tree> <lua tree>')
local LROOT = assert(arg[2], 'usage: accept_partial.lua <ts tree> <lua tree>')
local D = vim.fn.getcwd() .. '/tools/experiments/flowtype_oracle/'
local plan = dofile(D .. 'plans.lua').partial(root, LROOT)
local t0 = vim.uv.hrtime()
local res = TA.run(require 'cartograph.store', plan, {})
print(('status %s class %s (%.0f s)'):format(tostring(res.status), tostring(res.class), (vim.uv.hrtime() - t0) / 1e9))
print('where', tostring(res.where))
print('why', tostring(res.why):sub(1, 400))
for _, tr in ipairs(res.trace or {}) do print('  trace', tr.where, tr.verb, tr.ok, tostring(tr.why):sub(1, 160)) end
