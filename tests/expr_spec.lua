-- Unit tests for the expression layer ([[cartograph-expression-layer]] INC 1): the
-- closed IR harvested co-emitted in flow.build, the names≡use∪rmw self-gate, the
-- derived predicates, and the Rung-0 lints (exprlint).

local flow = require 'cartograph.flow'
local expr = require 'cartograph.expr'
local exprlint = require 'cartograph.exprlint'
local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'

local function ready(lang)
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    return pcall(vim.treesitter.language.add, lang or 'lua')
end

-- build a fn's flow with the expr harvest wired (mirrors expr.of, no store needed)
local function build_expr_flow(lines)
    local src = table.concat(lines, '\n')
    local root = vim.treesitter.get_string_parser(src, 'lua'):parse()[1]:root()
    local fn
    local function rec(n)
        if fn then return end
        if n:type() == 'function_declaration' or n:type() == 'function_definition' then fn = n; return end
        for c in n:iter_children() do if c:named() then rec(c) end end
    end
    rec(root)
    local cfg = { pfield = 'parameters', expr = function (nd, s, hint) return expr.harvest_row(nd, s, hint) end }
    return flow.build(fn, src, cfg)
end

-- the first row whose source line is `ln`
local function row_at(fl, ln)
    for _, r in ipairs(fl.stmts) do if r.l == ln and r.expr then return r end end
end

local function ingest(lines)
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/m.lua', 'w'))
    fd:write(table.concat(lines, '\n')); fd:close()
    store.ingest(ts.extract(root))
end
local function fn_id(name)
    for _, n in ipairs(store.data.nodes) do if n.name == name then return n.id end end
end
-- the set of (rule) findings at source line `ln` for fn `name`
local function findings_at(name, ln)
    local out = {}
    for _, f in ipairs(exprlint.lint(store, fn_id(name)).findings) do
        if f.line == ln then out[f.rule] = f end
    end
    return out
end

-- ── the harvest schema ───────────────────────────────────────────────────────
test('expr: harvest builds bin / call / field / index / table / literals', function ()
    if not ready('lua') then skip 'no lua parser' end
    local fl = build_expr_flow {
        'local function f(a, b, t, o)',
        '  local x = a + b',   -- L2 bin(+)
        '  local u = { z = a }', -- L3 table (alloc) reading a
        '  local y = t.k[b]',   -- L4 index(field)
        '  o:m(1, "s")',        -- L5 method call w/ literals
        '  return #t, not a',   -- L6 unary
        'end',
    }
    local e2 = row_at(fl, 2).expr.rhs[1]
    eq('bin', e2.k); eq('+', e2.op); eq('name', e2.l.k); eq('a', e2.l.n)

    local e3 = row_at(fl, 3).expr.rhs[1]
    eq('table', e3.k); ok(expr.allocates(e3), 'table constructor allocates')
    ok(not expr.is_pure(e3), 'an allocation is not pure')

    local e4 = row_at(fl, 4).expr.rhs[1]
    eq('index', e4.k); eq('field', e4.b.k); eq('k', e4.b.n)

    local e5 = row_at(fl, 5).expr.rhs[1]
    eq('call', e5.k); ok(e5.method, 'o:m is a method call'); eq('lit', e5.a[1].k)
end)

test('expr: every node carries a source range (.at) that spans its own text', function ()
    if not ready('lua') then skip 'no lua parser' end
    local at = require 'cartograph.at'
    local lines = {
        'local function f(a, b)',
        '  local y = trim(a) + 1',
        '  return y',
        'end',
    }
    local fl = build_expr_flow(lines)
    local function span(e)
        local sl, sc, el, ec = at.sl(e.at), at.sc(e.at), at.el(e.at), at.ec(e.at)
        if sl == el then return (lines[sl + 1] or ''):sub(sc + 1, ec) end
        return '<multiline>'
    end
    local rhs = row_at(fl, 2).expr.rhs[1] -- trim(a) + 1
    ok(rhs.at, 'the bin node has a range')
    eq('trim(a) + 1', span(rhs), 'the bin node spans the whole rhs')
    eq('call', rhs.l.k)
    eq('trim(a)', span(rhs.l), 'the call sub-node spans just the call')
    eq('trim', span(rhs.l.f), 'the callee name leaf spans exactly the token')
    eq('a', span(rhs.l.a[1]), 'the argument name leaf spans exactly the token')
    eq('1', span(rhs.r), 'the literal leaf spans exactly the token')
end)

test('expr: an unmapped construct becomes `?` but still exposes its names', function ()
    if not ready('lua') then skip 'no lua parser' end
    -- a numeric for header clause is not modeled → `?`, but its names survive
    local fl = build_expr_flow {
        'local function f(xs)',
        '  for i = 1, #xs do use(i) end',
        'end',
    }
    -- the self-gate proves no name is hidden by the `?`
    eq({}, expr.gate(fl))
end)

-- ── the self-gate: reads ≡ use ∪ rmw ─────────────────────────────────────────
test('expr: self-gate is clean over tricky rows (field target, method, swap, rmw)', function ()
    if not ready('lua') then skip 'no lua parser' end
    local fl = build_expr_flow {
        'local function f(a, b, t, o, s, xs)',
        '  t.k = b',            -- field target reads t, selector k, b
        '  x, b = b, x',        -- multi-assign / swap
        '  s = s .. a',         -- rmw + concat',
        '  o:m(a)',             -- method call
        '  for _, e in ipairs(xs) do use(e) end',
        '  return t.k[b]',
        'end',
    }
    eq({}, expr.gate(fl))
end)

test('expr: self-gate survives a comment interspersed in a multi-line expression', function ()
    if not ready('lua') then skip 'no lua parser' end
    -- the comment-shift bug the self-gate caught on the real codebase
    local fl = build_expr_flow {
        'local function f(a, b, c)',
        '  local x = a',
        '    -- a mid-expression comment',
        '    + b * c',
        '  return x',
        'end',
    }
    eq({}, expr.gate(fl))
    -- and the operands were not corrupted by the comment
    local e = row_at(fl, 2).expr.rhs[1]
    eq('bin', e.k); eq('+', e.op)
end)

-- ── predicates ────────────────────────────────────────────────────────────────
test('expr: key is structural (identical exprs share a key; different differ)', function ()
    if not ready('lua') then skip 'no lua parser' end
    local fl = build_expr_flow {
        'local function f(a, b)',
        '  local p = a + b',
        '  local q = a + b',
        '  local r = a - b',
        'end',
    }
    local kp = expr.key(row_at(fl, 2).expr.rhs[1])
    local kq = expr.key(row_at(fl, 3).expr.rhs[1])
    local kr = expr.key(row_at(fl, 4).expr.rhs[1])
    eq(kp, kq); ok(kp ~= kr, 'a-b differs from a+b')
end)

test('expr: eval folds literals and honest ⊤ otherwise', function ()
    if not ready('lua') then skip 'no lua parser' end
    local fl = build_expr_flow {
        'local function f(a)',
        '  local p = 1 + 2 * 3',
        '  local q = "a" .. "b"',
        '  local r = a + 1',
        'end',
    }
    local ok1, v1 = expr.eval(row_at(fl, 2).expr.rhs[1]); eq(true, ok1); eq(7, v1)
    local ok2, v2 = expr.eval(row_at(fl, 3).expr.rhs[1]); eq(true, ok2); eq('ab', v2)
    eq(false, (expr.eval(row_at(fl, 4).expr.rhs[1]))) -- a is unknown
end)

-- ── the Rung-0 lints ─────────────────────────────────────────────────────────
test('exprlint: self-compare, and its NaN hedge on ==', function ()
    if not ready('lua') then skip 'no lua parser' end
    ingest {
        'local function g(a)',
        '  if a == a then return 1 end', -- L2 == hedged (NaN)
        '  if a < a then return 2 end',  -- L3 < definite
        '  if a == other then return 3 end', -- L4 clean
        'end', 'return { g }',
    }
    ok(findings_at('g', 2)['self-compare'], 'a==a flagged')
    ok(findings_at('g', 2)['self-compare'].hedged, '== is NaN-hedged')
    ok(findings_at('g', 3)['self-compare'], 'a<a flagged')
    ok(not findings_at('g', 3)['self-compare'].hedged, '< is definite')
    ok(not findings_at('g', 4)['self-compare'], 'a==other not flagged')
end)

test('exprlint: self-assignment flags a reassignment but not a `local` capture', function ()
    if not ready('lua') then skip 'no lua parser' end
    ingest {
        'local function g(a)',
        '  a = a',        -- L2 flagged
        '  local a2 = a', -- L3 NOT flagged (capture)
        '  return a2',
        'end', 'return { g }',
    }
    ok(findings_at('g', 2)['self-assignment'], 'a=a flagged')
    ok(not findings_at('g', 3)['self-assignment'], 'local a2=a not flagged')
end)

test('exprlint: pure-gate stops self-compare on side-effecting operands', function ()
    if not ready('lua') then skip 'no lua parser' end
    ingest {
        'local function g()',
        '  if f() == f() then return 1 end', -- L2 impure — must NOT flag
        'end', 'return { g }',
    }
    ok(not findings_at('g', 2)['self-compare'], 'f()==f() not flagged (impure)')
end)

test('exprlint: string concat in a loop (but not outside one)', function ()
    if not ready('lua') then skip 'no lua parser' end
    ingest {
        'local function g(xs, a, b)',
        '  local s = ""',
        '  for _, x in ipairs(xs) do',
        '    s = s .. x',  -- L4 flagged
        '  end',
        '  local t = a .. b', -- L6 NOT flagged (no loop)
        '  return s, t',
        'end', 'return { g }',
    }
    ok(findings_at('g', 4)['concat-in-loop'], 's=s..x in loop flagged')
    ok(not findings_at('g', 6)['concat-in-loop'], 'concat outside a loop not flagged')
end)

test('exprlint: constant condition and duplicated branch condition', function ()
    if not ready('lua') then skip 'no lua parser' end
    ingest {
        'local function g(a, b)',
        '  if 1 > 2 then return 0 end', -- L2 constant
        '  if a then',
        '    return 1',
        '  elseif a then',              -- L5 duplicated
        '    return 2',
        '  end',
        '  if a > b then return 3 end',  -- L8 clean
        'end', 'return { g }',
    }
    ok(findings_at('g', 2)['constant-condition'], '1>2 constant')
    ok(findings_at('g', 5)['duplicated-condition'], 'duplicated elseif')
    ok(not findings_at('g', 8)['constant-condition'], 'a>b is not constant')
end)
