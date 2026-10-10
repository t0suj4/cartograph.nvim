-- flowtype's acceptance PLANS as DATA (CART-1645): pure terms over toolbelt steps — no function anywhere (`each` bodies
-- are term templates, cartograph.tactic's T.hole), so a plan serializes, and two plans GENERALIZE as terms: their
-- holes are the decisions (which steps, which corpora, which checks). Run by accept_partial.lua / accept_walker.lua.
local T = require('cartograph.tactic').T
local M = {}
local D = vim.fn.getcwd() .. '/tools/experiments/flowtype_oracle/'
local function src(f) return io.open(D .. f):read('a') end

-- the four taint rules, each removed alone, each with the corpus check that caught it (CART-1643)
M.RULES = {
  { name = 'escaped fields', check = 'cap.lua', tree = 'ts',
    before = 'for _, o in ipairs(esc) do local m = ofield[o]; if m and m[f] then taint(m[f]) end end',
    after = 'for _, o in ipairs(esc) do local m = ofield[o]; if false and m and m[f] then taint(m[f]) end end' },
  { name = 'escaped params', check = 'cap.lua', tree = 'ts',
    before = 'for _, o in ipairs(esc) do local fpp = fnports[o]; if fpp then for _, pp in ipairs(fpp.params) do taint(pp) end end end',
    after = 'for _, o in ipairs(esc) do local fpp = fnports[o]; if false and fpp then for _, pp in ipairs(fpp.params) do taint(pp) end end end' },
  { name = 'field taint read by targets', check = 'schedule.lua', tree = 'ts',
    before = '        if p and tainted[p] then partial_hit = true end',
    after = '        if false and p and tainted[p] then partial_hit = true end' },
  { name = 'load results', check = 'cap.lua', tree = 'lua',
    before = '        for _, ld in ipairs(loads[p] or {}) do taint(ld[2]) end\n        for _, st in ipairs(stores[p] or {}) do',
    after = '        for _, ld in ipairs({}) do taint(ld[2]) end\n        for _, st in ipairs(stores[p] or {}) do' },
}

--- CART-1643: what moves with the order is flagged, whole answers survive a bigger cap, every taint rule is needed
function M.partial(ts_tree, lua_tree)
    local rules = {}
    for i, r in ipairs(M.RULES) do
        rules[i] = { before = r.before, after = r.after, check = D .. r.check, root = r.tree == 'lua' and lua_tree or ts_tree }
    end
    return T.seq(
        T.use('variants', { decl = src('schedule.lua'), root = ts_tree }),
        T.use('variants', { decl = src('cap.lua'), root = ts_tree }),
        T.each(rules, T.use('mutant', { file = 'lua/cartograph/flowtype.lua', before = T.hole('before'), after = T.hole('after'),
            use = 'variants', with = { T.hole('check', 'decl=@%s'), T.hole('root', 'root=%s') } })))
end

--- a walker change: every corpus 0 wrong at its floor; the order check where ports saturate
--- corpora = { { root, oracle, scorer, floor, args?, schedule? } }
function M.walker(corpora)
    local sched = {}
    for _, c in ipairs(corpora) do if c.schedule then sched[#sched + 1] = { root = c.root } end end
    return T.seq(
        T.each(corpora, T.use('oracle', { scorer = T.hole('scorer'), root = T.hole('root'), oracle = T.hole('oracle'),
            floor = T.hole('floor', '%s'), args = T.hole('args', nil, {}) })),
        T.each(sched, T.use('variants', { decl = src('schedule.lua'), root = T.hole('root') })))
end

return M
