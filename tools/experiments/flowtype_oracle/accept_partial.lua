-- CART-1643's ACCEPTANCE as ONE PLAN over toolbelt steps (CART-1645 step 2) — a tactical term, run by cartograph.tactic:
--   1 variants schedule.lua   flowtype under four worklist orders: what moves is flagged `partial`, the stack moves
--   2 variants cap.lua        the whole (non-partial) answers survive a bigger cap, the partial ones move
--   3 each taint rule: mutant  the rule removed alone, its corpus check must FAIL (the rule is needed)
-- The first run refused on step 3 by name (no tactic `mutant-variants`): the missing step, built as `mutant`. Then the
-- whole plan ran: done, 702 s, every rule caught (2026-10-10).
--   nvim --headless -u NONE --cmd 'set rtp^=.' -l tools/experiments/flowtype_oracle/accept_partial.lua <ts tree> <lua tree>
-- (<ts tree> e.g. ~/git/arktype; <lua tree> a copy of lua/ + plugin/ — the load-results rule is caught only there)
local TA = require 'cartograph.tactic'
local T = TA.T
local root = assert(arg[1], 'usage: accept_partial.lua <ts tree> <lua tree>')
local repo = vim.fn.getcwd()
local D = repo .. '/tools/experiments/flowtype_oracle/'
local function src(f) return io.open(f):read('a') end
-- the four taint rules, each removed alone (the mutants that survived the unit fixture)
local LROOT = assert(arg[2], 'usage: accept_partial.lua <ts tree> <lua tree>')
-- the four taint rules, each removed alone, each with the corpus check that caught it (CART-1643's measurement)
local RULES = {
  { name = 'escaped fields', check = 'cap.lua', root = root,
    before = 'for _, o in ipairs(esc) do local m = ofield[o]; if m and m[f] then taint(m[f]) end end',
    after = 'for _, o in ipairs(esc) do local m = ofield[o]; if false and m and m[f] then taint(m[f]) end end' },
  { name = 'escaped params', check = 'cap.lua', root = root,
    before = 'for _, o in ipairs(esc) do local fpp = fnports[o]; if fpp then for _, pp in ipairs(fpp.params) do taint(pp) end end end',
    after = 'for _, o in ipairs(esc) do local fpp = fnports[o]; if false and fpp then for _, pp in ipairs(fpp.params) do taint(pp) end end end' },
  { name = 'field taint read by targets', check = 'schedule.lua', root = root,
    before = '        if p and tainted[p] then partial_hit = true end',
    after = '        if false and p and tainted[p] then partial_hit = true end' },
  { name = 'load results', check = 'cap.lua', root = LROOT,
    before = '        for _, ld in ipairs(loads[p] or {}) do taint(ld[2]) end\n        for _, st in ipairs(stores[p] or {}) do',
    after = '        for _, ld in ipairs({}) do taint(ld[2]) end\n        for _, st in ipairs(stores[p] or {}) do' },
}
local plan = T.seq(
  T.use('variants', { decl = src(D .. 'schedule.lua'), root = root }),   -- order: what moves is flagged
  T.use('variants', { decl = src(D .. 'cap.lua'), root = root }),        -- completeness: whole answers survive a bigger cap
  T.each(RULES, function (r)                                              -- each rule is NEEDED: its mutant breaks a check
    return T.use('mutant', { file = 'lua/cartograph/flowtype.lua', before = r.before, after = r.after, use = 'variants',
      with = { 'decl=@' .. D .. r.check, 'root=' .. r.root } })
  end)
)
local t0 = vim.uv.hrtime()
local res = TA.run(require 'cartograph.store', plan, {})
print(('status %s class %s (%.0f s)'):format(tostring(res.status), tostring(res.class), (vim.uv.hrtime() - t0) / 1e9))
print('where', tostring(res.where))
print('why', tostring(res.why):sub(1, 400))
for _, tr in ipairs(res.trace or {}) do print('  trace', tr.where, tr.verb, tr.ok, tostring(tr.why):sub(1, 160)) end
