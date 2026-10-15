-- flowtype's acceptance PLANS as DATA (CART-1645): pure terms over toolbelt steps — no function anywhere (`each` bodies
-- are term templates, cartograph.tactic's T.hole), so a plan serializes, and two plans GENERALIZE as terms: their
-- holes are the decisions (which steps, which corpora, which checks). Run by accept_partial.lua / accept_walker.lua.
local T = require('cartograph.tactic').T
local M = {}
local D = vim.fn.getcwd() .. '/tools/experiments/flowtype_oracle/'
local function src(f) return io.open(D .. f):read('a') end

-- the taint rules, each removed alone, each with the corpus check that caught it (CART-1643; CART-1696 added the fifth).
-- ★ THE TEXTS ARE THE CODE'S: an edit of a rule's line must move its entry here in the same commit — they had drifted
-- (escf, NOTHING, `partial_hit or p`) and the mutant step failed "did not APPLY" for days unseen
-- ('escaped fields' — a store through a tainted base reaches that field of every escaped object — and 'field taint read
-- by targets' have NO corpus witness since 2203ed7: their mutants survive cap and schedule on arktype and the lua tree.
-- Both are pinned by one synthetic spec instead, tests/flowtype_spec.lua "a store through a SATURATED base…", each
-- mutant-CAUGHT, CART-1696. 'functions under a tainted field load' (CART-1696's own) lost its arktype witness when a
-- call the cut lost began handing its ARGUMENTS on — they escape, and the escape closure reaches what it protected
-- (CART-1715 work): its mutant survives the cap check. Kept in the code, out of this list; whether it is now SUBSUMED
-- in closed mode is CART-1727)
M.RULES = {
  { name = 'escaped params', check = 'cap.lua', tree = 'ts',
    before = 'for _, o in ipairs(esc) do local fpp = fnports[o]; if fpp then for _, pp in ipairs(fpp.params) do taint(pp) end end end',
    after = 'for _, o in ipairs(esc) do local fpp = fnports[o]; if false and fpp then for _, pp in ipairs(fpp.params) do taint(pp) end end end' },
  { name = 'load results', check = 'cap.lua', tree = 'lua',
    before = '        for _, ld in ipairs(loads[p] or NOTHING) do taint(ld[2]) end',
    after = '        for _, ld in ipairs(NOTHING) do taint(ld[2]) end' },
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
