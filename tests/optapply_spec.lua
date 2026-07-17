-- Unit tests for the headless APPLY verb ([[cartograph-apply-for-agent]]): optapply
-- turns optimize's CSE-reuse finding into a verified source edit over the txn substrate.
-- Agent-drivable (no cockpit); the edit writes to a temp dir and re-ingests.

local optapply = require 'cartograph.optapply'
local optimize = require 'cartograph.optimize'
local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'

local function ready(lang)
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    return pcall(vim.treesitter.language.add, lang or 'lua')
end

-- write `lines` to a fresh temp dir, ingest, return (dir)
local function ingest(lines)
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/m.lua', 'w'))
    fd:write(table.concat(lines, '\n') .. '\n'); fd:close()
    store.ingest(ts.extract(root))
    return root
end
local function fn_id(name)
    for _, n in ipairs(store.data.nodes) do if n.name == name then return n.id end end
end

test('optapply: plan + preview a CSE-reuse rewrite (no write)', function ()
    if not ready('lua') then skip 'no lua parser' end
    ingest {
        'local function f(x, y)',
        '  local a = x + y',
        '  local b = x + y',
        '  return a, b',
        'end', 'return { f }',
    }
    local plan = optapply.plan_cse(store, fn_id('f'))
    ok(plan, 'a plan was produced')
    eq(1, #plan.reps)
    eq('a', plan.moves[1].reuse)
    local diff = table.concat(optapply.preview(store, plan), '\n')
    ok(diff:match('%-%s*local b = x %+ y'), 'the recompute line is removed')
    ok(diff:match('%+%s*local b = a'), 'and rewritten to reuse a')
end)

test('optapply: apply writes the verified edit, and the redundancy is then GONE', function ()
    if not ready('lua') then skip 'no lua parser' end
    local root = ingest {
        'local function f(x, y)',
        '  local a = x + y',
        '  local b = x + y',
        '  return a, b',
        'end', 'return { f }',
    }
    local res = optapply.run(store, fn_id('f'))
    ok(res.ok, 'apply succeeded: ' .. tostring(res.reason))
    eq(1, res.applied)
    -- the file on disk now reuses a
    local after = table.concat(vim.fn.readfile(root .. '/m.lua'), '\n')
    ok(after:match('local b = a'), 'disk file rewritten')
    -- re-ingest and confirm the CSE no longer fires (the transform removed it)
    store.ingest(ts.extract(root))
    eq(0, #optimize.cse(store, fn_id('f')).redundant)
end)

test('optapply: a HEDGED (table-read) redundancy is not applied', function ()
    if not ready('lua') then skip 'no lua parser' end
    ingest {
        'local function f(t)',
        '  local a = t.x + 1',   -- table read → CSE flags it HEDGED
        '  local b = t.x + 1',
        '  return a, b',
        'end', 'return { f }',
    }
    -- the pair is reported (hedged) by cse; the apply verb refuses it — WITH provenance
    local plan = optapply.plan_cse(store, fn_id('f'))
    eq(0, #plan.moves)
    eq(1, #plan.declined)
    ok(plan.declined[1].reason:match('hedged'), 'the decline names the reason: ' .. plan.declined[1].reason)
    -- run surfaces the ledger too
    local res = optapply.run(store, fn_id('f'))
    ok(not res.ok and #res.declined == 1, 'run refuses but carries the ledger')
end)

test('optapply: span drift is refused (CAS)', function ()
    if not ready('lua') then skip 'no lua parser' end
    ingest {
        'local function f(x, y)',
        '  local a = x + y',
        '  local b = x + y',
        '  return a, b',
        'end', 'return { f }',
    }
    local plan = optapply.plan_cse(store, fn_id('f'))
    plan.reps[1].old = 'x + z' -- pretend the captured text differs from disk
    local okp, reason = optapply.apply(store, plan)
    ok(not okp, 'apply refused')
    ok(tostring(reason):match('drift'), 'refusal names the drift: ' .. tostring(reason))
end)

-- ── targeted refactoring: per-finding + by-location ───────────────────────────
test('optapply: opts.line targets a single finding, leaving the rest', function ()
    if not ready('lua') then skip 'no lua parser' end
    ingest {
        'local function f(x, y)',
        '  local a = x + y',
        '  local b = x + y',  -- L3 finding
        '  local c = x - y',
        '  local d = x - y',  -- L5 finding
        '  return a, b, c, d',
        'end', 'return { f }',
    }
    eq(2, #optapply.plan_cse(store, fn_id('f')).reps)          -- both by default
    local p3 = optapply.plan_cse(store, fn_id('f'), { line = 3 })
    eq(1, #p3.reps); eq(3, p3.moves[1].line)                  -- only L3
    local p5 = optapply.plan_cse(store, fn_id('f'), { line = 5 })
    eq(1, #p5.reps); eq(5, p5.moves[1].line)                  -- only L5
    local p99 = optapply.plan_cse(store, fn_id('f'), { line = 99 })
    eq(0, #p99.reps); eq(0, #p99.declined)  -- no finding at L99 (others out of target, not declined)
end)

test('optapply: M.at resolves the INNERMOST enclosing function by location', function ()
    if not ready('lua') then skip 'no lua parser' end
    local root = ingest {
        'local function outer(x, y)',
        '  local a = x + y',       -- L2 (outer)
        '  local function inner(p, q)',
        '    local c = p + q',
        '    local d = p + q',     -- L5 (inner)
        '    return c, d',
        '  end',
        '  return a, inner',
        'end', 'return { outer }',
    }
    local function nm(id) local n = store.node(id); return n and n.name end
    eq('outer', nm(optapply.at(store, 'm.lua', 2)))
    eq('inner', nm(optapply.at(store, 'm.lua', 5)))   -- innermost, not outer
    -- run_at targets inner's finding; outer's body is untouched
    local res = optapply.run_at(store, 'm.lua', 5)
    ok(res.ok, 'applied at inner: ' .. tostring(res.reason))
    local after = table.concat(vim.fn.readfile(root .. '/m.lua'), '\n')
    ok(after:match('local d = c'), 'inner rewritten')
    ok(after:match('local a = x %+ y'), 'outer left intact')
end)

-- ── localize-upvalue apply ────────────────────────────────────────────────────
test('optapply: localize binds an in-loop stdlib call to a local + rewrites sites', function ()
    if not ready('lua') then skip 'no lua parser' end
    local root = ingest {
        'local function f(xs)',
        '  local s = 0',
        '  for _, x in ipairs(xs) do',
        '    s = s + math.floor(x) + math.floor(x)',  -- two sites, one line
        '  end',
        '  return s',
        'end', 'return { f }',
    }
    local res = optapply.run_localize(store, fn_id('f'))
    ok(res.ok, 'applied: ' .. tostring(res.reason))
    eq(2, res.moves[1].sites)
    local after = table.concat(vim.fn.readfile(root .. '/m.lua'), '\n')
    ok(after:match('local floor = math%.floor'), 'the local is inserted')
    ok(after:match('s %+ floor%(x%) %+ floor%(x%)'), 'BOTH same-line sites rewritten')
    -- idempotent: now `floor` is a local, localize no longer fires
    store.ingest(ts.extract(root))
    ok(not optapply.plan_localize(store, fn_id('f')), 'nothing left to localize')
end)

test('optapply: localize declines a non-stdlib global and a name collision', function ()
    if not ready('lua') then skip 'no lua parser' end
    ingest {
        'local function f(xs)',
        '  for _, x in ipairs(xs) do myglobal.step(x) end',  -- non-stdlib root → declined
        'end',
        'local function g(xs, insert)',                       -- `insert` param collides
        '  for _, x in ipairs(xs) do table.insert(xs, x) end',
        'end', 'return { f, g }',
    }
    local pf = optapply.plan_localize(store, fn_id('f'))
    eq(0, #pf.moves)
    ok(pf.declined[1] and pf.declined[1].reason:match('not a known always%-present global'),
        'non-stdlib decline named: ' .. (pf.declined[1] or {}).reason)
    local pg = optapply.plan_localize(store, fn_id('g'))
    eq(0, #pg.moves)
    ok(pg.declined[1] and pg.declined[1].reason:match('shadow'),
        'collision decline named: ' .. (pg.declined[1] or {}).reason)
end)

-- ── hoist (LICM) apply ────────────────────────────────────────────────────────
test('optapply: hoist lifts an invariant out of a run-once (repeat) loop', function ()
    if not ready('lua') then skip 'no lua parser' end
    local root = ingest {
        'local function f(base)',
        '  local n = 0',
        '  repeat',
        '    local k = base + 1',
        '    n = n + k',
        '  until n > 100',
        '  return n',
        'end', 'return { f }',
    }
    local res = optapply.run_hoist(store, fn_id('f'))
    ok(res.ok, 'applied: ' .. tostring(res.reason))
    local after = vim.fn.readfile(root .. '/m.lua')
    -- the declaration now precedes the `repeat`
    local kline, rline
    for i, l in ipairs(after) do
        if l:match('local k = base %+ 1') then kline = i end
        if l:match('^%s*repeat') then rline = i end
    end
    ok(kline and rline and kline < rline, 'k hoisted above the repeat')
end)

test('optapply: hoist declines a possibly zero-trip (for) loop', function ()
    if not ready('lua') then skip 'no lua parser' end
    ingest {
        'local function f(base, xs)',
        '  for _, x in ipairs(xs) do',
        '    local k = base + 1',   -- invariant, but the for-loop may run 0 times
        '    use(k, x)',
        '  end',
        'end', 'return { f }',
    }
    local plan = optapply.plan_hoist(store, fn_id('f'))
    eq(0, #plan.moves)
    ok(plan.declined[1] and plan.declined[1].reason:match('zero times'),
        'zero-trip decline named: ' .. (plan.declined[1] or {}).reason)
end)

-- ── hedge resolution: discharge a decline by supplying the premise ────────────
test('optapply: a decline carries its class + resolution menu', function ()
    if not ready('lua') then skip 'no lua parser' end
    ingest {
        'local function f(base, xs)',
        '  for _, x in ipairs(xs) do',   -- L2 loop header
        '    local k = base + 1',
        '    use(k, x)',
        '  end',
        'end', 'return { f }',
    }
    local plan = optapply.plan_hoist(store, fn_id('f'))
    eq('risk', plan.declined[1].class)
    eq('iterates', plan.declined[1].resolutions[1].id)
end)

test('optapply: assuming `iterates` discharges the zero-trip hoist and records it', function ()
    if not ready('lua') then skip 'no lua parser' end
    local root = ingest {
        'local function f(base, xs)',
        '  for _, x in ipairs(xs) do',   -- L2
        '    local k = base + 1',
        '    use(k, x)',
        '  end',
        'end', 'return { f }',
    }
    local res = optapply.run_hoist(store, fn_id('f'), { assume = { [2] = 'iterates' } })
    ok(res.ok, 'applied under assumption: ' .. tostring(res.reason))
    ok(res.moves[1].waived:match('iterates'), 'the waiver is recorded: ' .. tostring(res.moves[1].waived))
    local after = vim.fn.readfile(root .. '/m.lua')
    local kl, fl2
    for i, l in ipairs(after) do
        if l:match('local k = base') then kl = i end
        if l:match('for _, x') then fl2 = i end
    end
    ok(kl < fl2, 'k hoisted above the for')
end)

test('optapply: assuming `present` discharges the possibly-nil-global localize', function ()
    if not ready('lua') then skip 'no lua parser' end
    local root = ingest {
        'local function f(xs)',
        '  for _, x in ipairs(xs) do',   -- L2
        '    myglobal.step(x)',
        '  end',
        'end', 'return { f }',
    }
    local plan = optapply.plan_localize(store, fn_id('f'))
    eq('present', plan.declined[1].resolutions[1].id)
    local res = optapply.run_localize(store, fn_id('f'), { assume = { [2] = 'present' } })
    ok(res.ok, 'applied: ' .. tostring(res.reason))
    ok(res.moves[1].waived:match('present'), 'waiver recorded')
    ok(table.concat(vim.fn.readfile(root .. '/m.lua'), '\n'):match('local step = myglobal%.step'), 'localized')
end)

test('optapply: the `rename` resolution is MECHANICAL — rebinds fresh, no shadow, no waiver-risk', function ()
    if not ready('lua') then skip 'no lua parser' end
    local root = ingest {
        'local function f(xs, t, insert)',       -- `insert` param would be shadowed
        '  for _, x in ipairs(xs) do',           -- L2
        '    table.insert(t, x)',
        '  end',
        'end', 'return { f }',
    }
    local plan = optapply.plan_localize(store, fn_id('f'))
    eq('wrong', plan.declined[1].class)
    eq('rename', plan.declined[1].resolutions[1].id)
    local res = optapply.run_localize(store, fn_id('f'), { assume = { [2] = 'rename' } })
    ok(res.ok, 'applied: ' .. tostring(res.reason))
    local after = table.concat(vim.fn.readfile(root .. '/m.lua'), '\n')
    ok(after:match('local insert_ = table%.insert'), 'rebound under a fresh name')
    ok(after:match('insert_%(t, x%)'), 'the call site uses the fresh name')
end)

-- ── provenance on likely-bug declines + the informed override ─────────────────
test('optapply: a `wrong` decline carries evidence, and `stable` overrides it', function ()
    if not ready('lua') then skip 'no lua parser' end
    local root = ingest {
        'local function f(x, y)',
        '  local a = x + y',   -- L2 source
        '  local b = x + y',   -- L3 recompute (a reassigned below → declined)
        '  a = 0',             -- L4 the reassignment (AFTER the reuse — so `stable` holds)
        '  return a, b',
        'end', 'return { f }',
    }
    local plan = optapply.plan_cse(store, fn_id('f'))
    eq('wrong', plan.declined[1].class)
    ok(plan.declined[1].evidence:match('L4'), 'evidence points at the reassignment: ' .. plan.declined[1].evidence)
    eq('stable', plan.declined[1].resolutions[1].id)
    -- informed override: L4 is after the reuse at L3, so the premise is sound
    local res = optapply.run(store, fn_id('f'), { assume = { [3] = 'stable' } })
    ok(res.ok, 'applied under assertion: ' .. tostring(res.reason))
    ok(res.moves[1].waived:match('stable'), 'waiver recorded')
    ok(table.concat(vim.fn.readfile(root .. '/m.lua'), '\n'):match('local b = a'), 'reuse applied')
end)

test('optapply: a capture-unsafe hoist carries the collision site as evidence', function ()
    if not ready('lua') then skip 'no lua parser' end
    ingest {
        'local function f(base)',
        '  local k = 99',       -- k outside the loop → hoisting the inner k collides
        '  repeat',            -- POST loop → iterates, so it is the CAPTURE gate that fires
        '    local k = base + 1',
        '    use(k)',
        '  until base > 100',
        '  return k',
        'end', 'return { f }',
    }
    local plan = optapply.plan_hoist(store, fn_id('f'))
    local d = plan.declined[1]
    ok(d and d.class == 'wrong' and d.reason:match('capture'), 'capture-unsafe decline')
    ok(d.evidence and d.evidence:match('outside the loop'), 'evidence names the collision: ' .. tostring(d.evidence))
end)

-- ── PRE apply (the last verb) ─────────────────────────────────────────────────
test('optapply: PRE lifts a both-arm computation to a local above the branch', function ()
    if not ready('lua') then skip 'no lua parser' end
    local root = ingest {
        'local function f(x, y, c)',
        '  if c then',
        '    local a = x + y',
        '    return a + 1',
        '  else',
        '    local b = x + y',
        '    return b + 2',
        '  end',
        'end', 'return { f }',
    }
    local plan = optapply.plan_pre(store, fn_id('f'))
    eq(1, #plan.moves)
    local res = optapply.run_pre(store, fn_id('f'))
    ok(res.ok, 'applied: ' .. tostring(res.reason))
    local after = vim.fn.readfile(root .. '/m.lua')
    local tl, ifl
    for i, l in ipairs(after) do
        if l:match('local t = x %+ y') then tl = i end
        if l:match('if c then') then ifl = i end
    end
    ok(tl and ifl and tl < ifl, 'the computation is hoisted above the if')
    local joined = table.concat(after, '\n')
    ok(joined:match('local a = t') and joined:match('local b = t'), 'both arms reuse the hoisted local')
    -- idempotent: the arms are now copies, not computations
    store.ingest(ts.extract(root))
    ok(not optapply.plan_pre(store, fn_id('f')), 'nothing left to hoist')
end)
