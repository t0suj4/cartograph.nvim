-- Unit tests for the optimize lens (LICM INC 1): loop-invariant code motion.
-- Pure; operates over a store + a focused fn id.

local optimize = require 'cartograph.optimize'
local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'

local function ready(lang)
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    return pcall(vim.treesitter.language.add, lang or 'lua')
end

local function ingest(lines)
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/m.lua', 'w'))
    fd:write(table.concat(lines, '\n')); fd:close()
    store.ingest(ts.extract(root))
end

local function fn_id(name)
    for _, n in ipairs(store.data.nodes) do
        if n.name == name then return n.id end
    end
end

-- the licm result for the sole loop; asserts there is exactly one loop
local function sole_loop(name)
    local res = optimize.licm(store, fn_id(name))
    eq(1, #res.heads)
    return res, res.loops[res.heads[1]]
end

-- the def name(s) of an invariant/hoistable row, as a set
-- the redundant pairs of a fn as { second_line -> {first_line, expr, hedged} }
local function redundant(name)
    local res = optimize.cse(store, fn_id(name))
    local out = {}
    for _, p in ipairs(res.redundant) do
        out[res.rows[p.second].l] = { first = res.rows[p.first].l, expr = p.expr, hedged = p.hedged }
    end
    return out
end

local function names(res, rowset)
    local out = {}
    for r in pairs(rowset) do
        for _, v in ipairs(res.rows[r].def or {}) do out[v] = true end
    end
    return out
end

test('licm: a pure computation of pre-loop inputs is invariant + hoistable', function ()
    if not ready('lua') then skip 'no lua parser' end
    ingest {
        'local function f(xs, base)',
        '  for _, x in ipairs(xs) do',
        '    local k = base + 1',   -- base is a param (pre-loop) -> invariant, clean
        '    use(k, x)',
        '  end',
        'end',
        'return { f }',
    }
    local res, lp = sole_loop('f')
    ok(names(res, lp.invariant).k, 'k = base + 1 is loop-invariant')
    ok(names(res, lp.hoistable).k, 'k is unconditionally hoistable (*)')
end)

test('licm: an accumulator (read-modify-write) is NOT invariant', function ()
    if not ready('lua') then skip 'no lua parser' end
    -- the reaching rmw fix is what makes this correct: total reads its own prior
    -- value (defined IN the loop) so it is loop-carried, not invariant.
    ingest {
        'local function f(xs)',
        '  local total = 0',
        '  for _, x in ipairs(xs) do',
        '    total = total + x',
        '  end',
        '  return total',
        'end',
        'return { f }',
    }
    local res, lp = sole_loop('f')
    ok(not names(res, lp.invariant).total, 'the accumulator total is loop-carried, not invariant')
end)

test('licm: a computation of the loop variable is NOT invariant', function ()
    if not ready('lua') then skip 'no lua parser' end
    ingest {
        'local function f(xs)',
        '  for _, x in ipairs(xs) do',
        '    local y = x * 2',   -- x is the induction var -> varying
        '    use(y)',
        '  end',
        'end',
        'return { f }',
    }
    local res, lp = sole_loop('f')
    ok(not names(res, lp.invariant).y, 'y depends on the loop variable x -> not invariant')
end)

test('licm: an impure call is not hoisted (side-effect-free gate)', function ()
    if not ready('lua') then skip 'no lua parser' end
    ingest {
        'local function f(xs, cfg)',
        '  for _, x in ipairs(xs) do',
        '    local w = io.read(cfg)',   -- io.read is impure -> not invariant
        '    use(w, x)',
        '  end',
        'end',
        'return { f }',
    }
    local res, lp = sole_loop('f')
    ok(not names(res, lp.invariant).w, 'an impure computation is not hoistable')
end)

test('licm: a field read of an invariant table is invariant but HEDGED (~)', function ()
    if not ready('lua') then skip 'no lua parser' end
    ingest {
        'local function f(xs, cfg)',
        '  for _, x in ipairs(xs) do',
        '    local limit = cfg.max',   -- cfg invariant, but cfg.max field read = aliasing ~
        '    use(limit, x)',
        '  end',
        'end',
        'return { f }',
    }
    local res, lp = sole_loop('f')
    ok(names(res, lp.invariant).limit, 'reading a field of an invariant table is invariant')
    ok(not names(res, lp.hoistable).limit, 'but it is HEDGED (aliasing) — not a clean hoist')
end)

test('licm: a var reassigned twice in the loop is not invariant (single-def gate)', function ()
    if not ready('lua') then skip 'no lua parser' end
    ingest {
        'local function f(xs, base)',
        '  for _, x in ipairs(xs) do',
        '    local m = base',
        '    m = base + 1',   -- m defined twice in the loop -> loop-carried
        '    use(m, x)',
        '  end',
        'end',
        'return { f }',
    }
    local res, lp = sole_loop('f')
    ok(not names(res, lp.invariant).m, 'a var with two defs in the loop is not invariant')
end)

test('licm: a numeric-for induction variable is not invariant', function ()
    if not ready('lua') then skip 'no lua parser' end
    ingest {
        'local function f(nn)',
        '  for i = 1, nn do',
        '    local b = i * 5',   -- i is the numeric induction var -> varying
        '    use(b)',
        '  end',
        'end',
        'return { f }',
    }
    local res, lp = sole_loop('f')
    ok(not names(res, lp.invariant).b, 'b = i * 5 depends on the numeric loop var -> not invariant')
end)

test('licm: a single-variable for-in induction var is not invariant', function ()
    if not ready('lua') then skip 'no lua parser' end
    ingest {
        'local function f(parent)',
        '  for i in pairs(parent) do',
        '    local r = find(i)',   -- i is the for-in var -> varying
        '    use(r)',
        '  end',
        'end',
        'return { f }',
    }
    local res, lp = sole_loop('f')
    ok(not names(res, lp.invariant).r, 'r = find(i) depends on the for-in var -> not invariant')
end)

test('licm: an allocation (fresh table each iteration) is not hoisted', function ()
    if not ready('lua') then skip 'no lua parser' end
    -- `{}` is loop-independent as an expression but hoisting it shares one table
    -- across iterations (identity change) — must NOT be an invariant/hoist candidate.
    ingest {
        'local function f(xs)',
        '  for _, x in ipairs(xs) do',
        '    local acc = {}',
        '    acc[1] = x',
        '  end',
        'end',
        'return { f }',
    }
    local res, lp = sole_loop('f')
    ok(not names(res, lp.invariant).acc, 'a fresh {} per iteration is not hoistable')
end)

test('licm: a table-index read is invariant but HEDGED (aliasing), not clean', function ()
    if not ready('lua') then skip 'no lua parser' end
    ingest {
        'local function f(xs, t)',
        '  for _, x in ipairs(xs) do',
        '    local first = t[1]',   -- t invariant, but t[1] reads contents (aliasing)
        '    use(first, x)',
        '  end',
        'end',
        'return { f }',
    }
    local res, lp = sole_loop('f')
    ok(names(res, lp.invariant).first, 'reading t[1] of an invariant table is invariant')
    ok(not names(res, lp.hoistable).first, 'but a table-index read is aliasing-hedged, not clean')
end)

test('licm: a reassignment (read-before-def flag) is not a hoist candidate', function ()
    if not ready('lua') then skip 'no lua parser' end
    -- `first = false` has an invariant value but is a REASSIGNMENT; hoisting it out
    -- would change iteration-1 behavior when first is read earlier. Excluded.
    ingest {
        'local function f(xs)',
        '  local first = true',
        '  for _, x in ipairs(xs) do',
        '    use(first, x)',
        '    first = false',
        '  end',
        'end',
        'return { f }',
    }
    local res, lp = sole_loop('f')
    ok(not names(res, lp.invariant).first, 'a reassignment is not a LICM hoist candidate')
end)

-- ── refinements: pure-module-call un-hedge + allocating-call detection ───────

test('licm: a pure stdlib module call of invariant scalars is CLEAN (un-hedged)', function ()
    if not ready('lua') then skip 'no lua parser' end
    -- string.format is pure and returns an immutable value; base is a param. The
    -- `.` in string.format is a benign call receiver, not a mutable-table field read.
    ingest {
        'local function f(xs, base)',
        '  for _, x in ipairs(xs) do',
        '    local s = string.format("%d", base)',
        '    use(s, x)',
        '  end',
        'end',
        'return { f }',
    }
    local res, lp = sole_loop('f')
    ok(names(res, lp.hoistable).s, 'a pure module call of an invariant scalar is cleanly hoistable')
end)

test('licm: an allocating call (deepcopy) is not hoistable (fresh identity)', function ()
    if not ready('lua') then skip 'no lua parser' end
    -- vim.deepcopy returns a FRESH table each call; hoisting shares one -> excluded.
    ingest {
        'local function f(xs, base)',
        '  for _, x in ipairs(xs) do',
        '    local c = vim.deepcopy(base)',
        '    use(c, x)',
        '  end',
        'end',
        'return { f }',
    }
    local res, lp = sole_loop('f')
    ok(not names(res, lp.invariant).c, 'an allocating call is not a hoist candidate')
end)

test('cse: an allocating call is not a redundant candidate (identity)', function ()
    if not ready('lua') then skip 'no lua parser' end
    ingest {
        'local function f(base)',
        '  local a = vim.deepcopy(base)',
        '  local b = vim.deepcopy(base)',   -- same text, but each is a distinct object
        '  return a, b',
        'end',
        'return { f }',
    }
    ok(not redundant('f')[3], 'two deepcopy calls are NOT a CSE pair — reuse would share identity')
end)

-- ── LICM INC 2: the hoist plan ───────────────────────────────────────────────

-- the sole loop's hoist plan
local function sole_plan(name)
    local hp = optimize.hoist_plan(store, fn_id(name))
    eq(1, #hp.plans)
    return hp, hp.plans[1]
end

test('hoist_plan: a clean-hoistable row plans a safe lift above the header', function ()
    if not ready('lua') then skip 'no lua parser' end
    ingest {
        'local function add(a, b) return a + b end',
        'local function f(xs, base)',
        '  for _, x in ipairs(xs) do',
        '    local k = add(base, 1)',   -- clean-hoistable
        '    use(k, x)',
        '  end',
        'end',
        'return { f, add }',
    }
    local _, p = sole_plan('f')
    ok(p.safe, 'no capture -> the plan is safe')
    eq(1, #p.moves)
    ok(p.moves[1].text:find('local k = add%(base, 1%)'), 'the exact statement is the move')
    ok(p.insert_before == p.line, 'it inserts just before the loop header')
end)

test('hoist_plan: a hoisted local colliding with an outer name is flagged ⚠', function ()
    if not ready('lua') then skip 'no lua parser' end
    -- the disagreement oracle: INC 1 says `k` is invariant/hoistable, but INC 2's
    -- independent capture check sees the outer `k` — the MOVE is not mechanically safe.
    ingest {
        'local function add(a, b) return a + b end',
        'local function f(xs)',
        '  local k = 7',
        '  use(k)',
        '  for _, x in ipairs(xs) do',
        '    local k = add(1, 2)',   -- hoistable value, but name collides with the outer k
        '    use(k, x)',
        '  end',
        'end',
        'return { f, add }',
    }
    local _, p = sole_plan('f')
    ok(not p.safe, 'the collision makes the hoist unsafe')
    ok(#p.hazards >= 1 and p.hazards[1].var == 'k', 'the hazard names the colliding var')
end)

test('hoist_plan: report renders the hoist plan + validation', function ()
    if not ready('lua') then skip 'no lua parser' end
    ingest {
        'local function add(a, b) return a + b end',
        'local function f(xs, base)',
        '  for _, x in ipairs(xs) do',
        '    local k = add(base, 1)',
        '    use(k, x)',
        '  end',
        'end',
        'return { f, add }',
    }
    local joined = table.concat(optimize.report(store, fn_id('f')), '\n')
    ok(joined:match('hoist plan'), 'the report shows a hoist plan')
    ok(joined:match('no capture'), 'and its validation verdict')
end)

-- ── CSE INC 1: redundant computations ───────────────────────────────────────

test('cse: two identical pure computations in a block -> the later is redundant', function ()
    if not ready('lua') then skip 'no lua parser' end
    ingest {
        'local function add(a, b) return a + b end',
        'local function f(x, y)',
        '  local p = add(x, y)',
        '  local q = add(x, y)',   -- redundant: same expr, same x,y -> reuse p
        '  return p, q',
        'end',
        'return { f, add }',
    }
    local red = redundant('f')
    ok(red[4], 'the second add(x,y) is flagged redundant')
    eq(3, red[4].first)
    ok(not red[4].hedged, 'a scalar pure recompute is not hedged')
end)

test('cse: a redefinition of an operand between the two breaks the match', function ()
    if not ready('lua') then skip 'no lua parser' end
    ingest {
        'local function f(x, y)',
        '  local p = x + y',
        '  x = 99',            -- x redefined
        '  local q = x + y',   -- NOT redundant with p: x changed
        '  return p, q',
        'end',
        'return { f }',
    }
    ok(not redundant('f')[4], 'the recompute after a redefinition is not matched')
end)

test('cse: a table-index recompute is flagged but HEDGED (aliasing)', function ()
    if not ready('lua') then skip 'no lua parser' end
    ingest {
        'local function f(t)',
        '  local a = t[1] + 1',
        '  local b = t[1] + 1',   -- redundant text, but t[1] contents may change
        '  return a, b',
        'end',
        'return { f }',
    }
    local red = redundant('f')
    ok(red[3], 'the recompute is flagged')
    ok(red[3].hedged, 'a table-index read makes it aliasing-hedged (~)')
end)

test('cse: different expressions are not matched', function ()
    if not ready('lua') then skip 'no lua parser' end
    ingest {
        'local function f(x, y)',
        '  local p = x + y',
        '  local q = x - y',   -- different op -> not redundant
        '  return p, q',
        'end',
        'return { f }',
    }
    eq(nil, next(redundant('f')))
end)

test('cse: two statements on one line do not produce a garbage match', function ()
    if not ready('lua') then skip 'no lua parser' end
    -- exercises the precise (line,col) statement extraction: `a = ...; b = ...`
    -- must not over-capture across the `;` into a bogus shared expression.
    ingest {
        'local function f(x)',
        '  local a = x + 1; local b = x + 2',
        '  local c = x + 1; local d = x + 2',
        '  return a, b, c, d',
        'end',
        'return { f }',
    }
    -- a/c both `x + 1` and b/d both `x + 2` ARE genuine redundant pairs, cleanly
    -- extracted; the point is the expressions are the real ones, never `x + 1; local b`.
    for _, p in ipairs(optimize.cse(store, fn_id('f')).redundant) do
        ok(not p.expr:find(';'), 'no expr spans the statement separator: ' .. p.expr)
        ok(not p.expr:find('local'), 'no expr captures the next statement: ' .. p.expr)
    end
end)

test('licm: report renders per-loop invariants + verdict; no-loop fn is inert', function ()
    if not ready('lua') then skip 'no lua parser' end
    ingest {
        'local function loopy(xs, base)',
        '  for _, x in ipairs(xs) do local k = base + 1 use(k, x) end',
        'end',
        'local function flat(a) return a + 1 end',
        'return { loopy, flat }',
    }
    local joined = table.concat(optimize.report(store, fn_id('loopy')), '\n')
    ok(joined:match('loop%-invariant computation'), 'the loop report names invariants')
    ok(joined:match('%*'), 'a clean hoist is marked *')
    ok(table.concat(optimize.report(store, fn_id('flat')), '\n'):match('no loops'),
        'a fn with no loops is inert')
end)

-- ── INC 2: expression-IR migration (structural predicates replace text scans) ──
test('optimize: `{` inside a STRING is not mistaken for an allocation (structural)', function ()
    if not ready('lua') then skip 'no lua parser' end
    -- the old `{`-text scan flagged this string as allocating → excluded it from CSE;
    -- expr.allocates is structural, so the two identical pure computations CSE cleanly.
    ingest {
        'local function g(a, b)',
        '  local p = tostring(a) .. "{"',
        '  local q = tostring(a) .. "{"',
        '  return p, q',
        'end', 'return { g }',
    }
    local red = redundant('g')
    ok(red[3], 'the identical string-concat is recognized as redundant, not blocked by the brace')
end)

test('optimize: localize-upvalue suggests globals-in-loops, never locals', function ()
    if not ready('lua') then skip 'no lua parser' end
    ingest {
        'local function hot(xs, helper, m)',
        '  for _, x in ipairs(xs) do',
        '    use(math.floor(x), math.floor(x + 1))', -- math.floor x2
        '    helper(x)',   -- a param callee (bare name) — never suggested
        '    m.step(x)',   -- rooted at a LOCAL (param) — must NOT suggest
        '  end',
        'end',
        'local function cold(x) return math.floor(x) end', -- no loop — must NOT suggest
        'return { hot, cold }',
    }
    local loc = optimize.localize(store, fn_id('hot'))
    eq(1, #loc.loops)
    local by = {}
    for _, c in ipairs(loc.loops[1].cands) do by[c.full] = c.count end
    eq(2, by['math.floor'])
    ok(by['m.fn'] == nil and by['m.step'] == nil, 'a local-rooted callee is not localized')
    eq(0, #optimize.localize(store, fn_id('cold')).loops)
end)
