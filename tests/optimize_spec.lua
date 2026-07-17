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
