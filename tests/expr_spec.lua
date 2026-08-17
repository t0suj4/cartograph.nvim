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

test('lua 5.4 attribute: a binding modifier is neither a field nor a read (CART-0234)', function ()
    if not ready('lua') then skip 'no lua parser' end
    -- `attribute` is python's name for `a.b` AND lua 5.4's `<const>`/`<close>`. The shared
    -- node-type map turned the second into a field access with an EMPTY name, i.e. a read of
    -- a variable called `const` that does not exist. Both expr AND du fabricated it
    -- identically, so the self-gate reported agreement on a fabrication.
    local lines = {
        'local function g(n)',
        '  local t <const> = { n }',
        '  return t',
        'end', 'return { g }' }
    local src = table.concat(lines, '\n')
    local root = vim.treesitter.get_string_parser(src, 'lua'):parse()[1]:root()
    local fn
    local function rec(nd)
        if fn then return end
        if nd:type() == 'function_declaration' then fn = nd; return end
        for c in nd:iter_children() do if c:named() then rec(c) end end
    end
    rec(root)
    -- WIRED exactly as expr.of wires it: the language is declared, so the spec's
    -- `binding_modifiers` reach both consumers (harvest via lang, du via cfg.mods)
    local mods = ts.spec.lua.binding_modifiers
    ok(mods and mods.attribute, 'the lua spec declares the modifier')
    local fl = flow.build(fn, src, { pfield = 'parameters', mods = mods,
        expr = function (nd, s, hint) return expr.harvest_row(nd, s, hint, 'lua') end })

    local row = row_at(fl, 2)
    ok(row, 'the declaration row was harvested')
    -- the DEF side is untouched: `t` is still declared here
    ok(vim.tbl_contains(row.def, 't'), 'the binding still defs its name')
    -- and NEITHER side invents a read of the attribute keyword
    for _, nm in ipairs(expr.reads(row)) do
        ok(nm ~= 'const', 'expr must not read `const`, got ' .. nm)
    end
    for _, nm in ipairs(row.use or {}) do
        ok(nm ~= 'const', 'du must not read `const`, got ' .. nm)
    end
    eq(0, #expr.gate(fl), 'and the two sides agree, without agreeing on a fabrication')
    -- the lhs holds the target only — no field node with an empty name
    for _, e in ipairs(row.expr.lhs or {}) do
        ok(not (e.k == 'field' and (e.n == nil or e.n == '')),
            'no phantom field on the target list')
    end

    -- THE VETO MUST NOT OVER-FIRE: `attribute` in PYTHON is a real field access
    if pcall(vim.treesitter.language.add, 'python') then
        local psrc = 'x = a.b\n'
        local proot = vim.treesitter.get_string_parser(psrc, 'python'):parse()[1]:root()
        -- python wraps the assignment in an expression_statement; harvest_row wants the
        -- `assignment` itself (the row node the provider would hand it)
        local stmt = proot:named_child(0)
        local asg = stmt:type() == 'assignment' and stmt or stmt:named_child(0)
        local prow = expr.harvest_row(asg, psrc, nil, 'python')
        local rhs = prow and prow.rhs and prow.rhs[1]
        eq('field', rhs and rhs.k, 'python a.b is still a field')
        eq('b', rhs and rhs.n, 'with its selector intact')
    end
end)

-- ── the parse cache (CART-0423) ──────────────────────────────────────────────
-- ★ WHY THESE ARE GATES AND NOT A BENCHMARK. `expr.of` re-parses the enclosing file per
-- subject; a sweeping consumer pays that once per FUNCTION, which made four corpora
-- unrunnable (21–53 bytes of RSS per source byte, per parse). The cache fixes it, and a
-- refactor that silently breaks reuse would restore the old cost with IDENTICAL RESULTS —
-- invisible to every other spec in this file and to the census's own pins. The only thing
-- that can catch it is a counter, so the counter is asserted.
test('expr: a second subject in the same file reuses the parsed tree', function ()
    if not ready('lua') then skip 'no lua parser' end
    ingest {
        'local function one(a) return a + 1 end',
        'local function two(b) return b + 2 end',
        'local function three(c) return c + 3 end',
    }
    expr.parse_release()
    local p0 = expr.parse_stats()
    for _, name in ipairs { 'one', 'two', 'three' } do
        local id = fn_id(name)
        ok(id and expr.of(store, id), 'expr.of resolved ' .. name)
    end
    local p1 = expr.parse_stats()
    -- THREE subjects, ONE file: exactly one parse, and the concat is paid once too
    eq(1, p1.miss - p0.miss, 'one parse for three subjects in one file')
    eq(2, p1.hit - p0.hit, 'the other two reused the tree')
    eq(1, p1.concat - p0.concat, 'and the source string is built once, not per subject')
end)

test('expr: released, and re-parsed — the cache holds exactly one file', function ()
    if not ready('lua') then skip 'no lua parser' end
    ingest { 'local function only(a) return a end' }
    local id = fn_id('only')
    expr.parse_release()

    local p0 = expr.parse_stats()
    ok(expr.of(store, id), 'first call parses')
    eq(1, expr.parse_stats().miss - p0.miss, 'a cold cache is a miss')

    -- release returns the BYTES dropped, which is what lets a sweeping consumer trigger a
    -- collect on released source rather than on a per-item reflex (that reflex, measured,
    -- cost 4.7x on go)
    local freed = expr.parse_release()
    ok(freed > 0, 'release reports the source bytes it dropped')
    eq(0, expr.parse_release(), 'releasing twice drops nothing the second time')

    local p1 = expr.parse_stats()
    ok(expr.of(store, id), 'after release it parses again')
    eq(1, expr.parse_stats().miss - p1.miss, 'a released cache is cold again')
end)


-- ── scoped extraction (CART-0429) ────────────────────────────────────────────
-- ★★ WHAT `--file` CLAIMS, AND WHAT THIS ACTUALLY TESTS. Scoping the census filters
-- EXTRACTION (the provider's `opts.files`) — the only place the loop really collapses, 135s
-- to 3.1s on zig. The hazard that buys is INCOMPLETE CROSS-FILE RESOLUTION: a name defined
-- in an excluded file does not resolve, and a node's KIND can depend on that (a function
-- attached to a class declared elsewhere becomes a `method` only if the class is seen).
-- So the invariant is narrower than "same answer": A FILE'S OWN SUBJECTS MUST BE IDENTICAL
-- WHETHER OR NOT ITS NEIGHBOURS WERE EXTRACTED.
--
-- ★ THE FIRST VERSION OF THIS SPEC ASSERTED NOTHING. It compared census ROWS, and clean
-- lua produces ZERO disagreements (ten probed constructs, all 0 — lua is the language the
-- IR was built against, CART-0224). Both sides were empty, every loop body was skipped, and
-- it passed green. Hence the explicit non-vacuity assertions below: the fixture must
-- produce subjects in BOTH files, and the scope must be shown to have excluded one.
test('exprcensus: a scoped extraction gives a file the same subjects as the full corpus', function ()
    if not ready('lua') then skip 'no lua parser' end
    local ts_ = require 'cartograph.providers.treesitter'
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    local a = assert(io.open(root .. '/a.lua', 'w'))
    a:write('local M = {}\n'
        .. 'function M.f(t)\n  local x = t.k\n  for i, v in ipairs(t) do x = x + v end\n'
        .. '  return x\nend\n'
        .. 'function M.g(o)\n  o.n = o.n + 1\n  return o\nend\nreturn M\n')
    a:close()
    -- b.lua holds NAMED functions so it contributes subjects of its own — otherwise
    -- "the scope excluded the neighbour" is true for the wrong reason
    local b = assert(io.open(root .. '/b.lua', 'w'))
    b:write('local A = require "a"\n'
        .. 'local B = {}\nfunction B.h(z)\n  return A.f(z) + A.g(z).n\nend\n'
        .. 'function B.i(z)\n  return B.h(z) * 2\nend\nreturn B\n')
    b:close()

    -- subjects, keyed the way the census picks them: kind + file + name
    local function subjects(opts)
        local out, byfile = {}, {}
        for _, n in ipairs(ts_.extract(root, opts).nodes or {}) do
            if n.kind == 'function' or n.kind == 'method' then
                local k = ('%s|%s|%s'):format(n.kind, n.file or '?', n.name or '?')
                out[k] = true
                byfile[n.file or '?'] = (byfile[n.file or '?'] or 0) + 1
            end
        end
        return out, byfile
    end

    local full, fcount = subjects(nil)
    local scoped, scount = subjects { files = { 'a.lua' } }

    -- NON-VACUITY, both directions — this spec is worthless without them
    ok((fcount['a.lua'] or 0) > 0, 'the fixture puts subjects in a.lua')
    ok((fcount['b.lua'] or 0) > 0, 'and subjects in b.lua, so exclusion means something')
    eq(nil, scount['b.lua'], 'the scoped extraction really excluded b.lua')
    eq(fcount['a.lua'], scount['a.lua'], 'a.lua keeps every subject when scoped')

    -- THE INVARIANT: identical subject IDENTITY for the scoped file, kind included
    for k in pairs(full) do
        if k:find('|a%.lua|') then ok(scoped[k], 'scoped run kept subject ' .. k) end
    end
    for k in pairs(scoped) do ok(full[k], 'scoped run invented no subject: ' .. k) end
end)
