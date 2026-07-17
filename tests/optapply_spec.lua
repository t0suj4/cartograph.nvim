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
    -- the pair is reported (hedged) by cse, but the apply verb refuses to touch it
    local plan, why = optapply.plan_cse(store, fn_id('f'))
    ok(not plan, 'no clean plan: ' .. tostring(why))
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
    ok(not (optapply.plan_cse(store, fn_id('f'), { line = 99 })), 'no finding at L99')
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
