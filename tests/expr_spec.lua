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

-- ── zig's FLAT DECLARATION: `names = value`, no declarator node (CART-0404) ──────────────
--
-- ★★ WHY THIS IS GATED AND WHAT WOULD MAKE IT RED. zig spells `const x: T = y;` as a
-- `variable_declaration` whose children are the bare identifier, an optional `type` FIELD,
-- the `=` token and the initialiser — no `init_declarator`, no `variable_declarator`. Every
-- earlier path in the LOCALDECL branch keys on one of those, so the row fell to the generic
-- `?` walk, which reads every identifier it meets INCLUDING THE DECLARED NAME: 14002 distinct
-- rows, 87% of zig's whole expression census and the largest single class in any corpus.
-- These assert `harvest_row` DIRECTLY (via `expr.reads`, which is exactly what the self-gate
-- compares against du's `use ∪ rmw`) rather than asserting a census agreed — a census can
-- agree because both sides are wrong, which is how this defect survived: see the last case.
local function zig_reads(line)
    local src = 'fn f(index: usize, raw: u32, it: It) void {\n    ' .. line .. '\n}'
    local root = vim.treesitter.get_string_parser(src, 'zig'):parse()[1]:root()
    local found
    local function rec(n)
        if found then return end
        if n:type() == 'variable_declaration' then found = n; return end
        for c in n:iter_children() do if c:named() then rec(c) end end
    end
    rec(root)
    if not found then return nil end
    return table.concat(expr.reads(expr.harvest_row(found, src, nil, 'zig')), ',')
end

test('expr: a zig declaration does NOT read the name it declares', function ()
    if not ready('zig') then skip 'no zig parser' end
    -- RED IF: the flat-declaration split stops firing and the row falls back to the `?`
    -- walk — every one of these grows the declared name, which IS the 14002-row defect.
    eq('raw', zig_reads('const x = @backingInt(raw);'), 'plain declaration reads only its value')
    eq('raw', zig_reads('const low: u31 = @truncate(raw);'), 'a builtin type contributes no name')
    eq('pair', zig_reads('const a, const b = pair();'),
        'BOTH binders of a destructuring declaration are targets, not reads')
    eq('raw', zig_reads('_ = raw;'), "zig's discard idiom: `_` is the target, `raw` the read")
end)

test('expr: a zig declared TYPE is a READ, because in zig a type is a value', function ()
    if not ready('zig') then skip 'no zig parser' end
    -- ★ THE OPPOSITE OF THE C RULE, and the difference is not taste: `int` is a KEYWORD and
    -- names nothing, while `Inst.Ref` is a real reference to the `Inst` binding — du reads
    -- both names, and dropping the type cost 5 `missing:{Inst,Ref}` rows on one file.
    -- RED IF: the type field is dropped again (or, worse, added to the LHS as a target).
    eq('Inst,Ref,extra,it', zig_reads('const items: []const Inst.Ref = @ptrCast(it.extra);'),
        'the type names are read, alongside the initialiser')
    eq('Type,fromInterned,raw', zig_reads('const ty: Type = .fromInterned(raw);'),
        'a bare type identifier is read too')
end)

test('expr: `var i: usize = index` reads index and NOT i — the row that exposed du', function ()
    if not ready('zig') then skip 'no zig parser' end
    -- ★★ THIS SPEC WAS WRITTEN TO STAY MEANINGFUL WHEN DU WAS LATER FIXED — AND DU WAS FIXED
    -- THE SAME DAY (CART-0431, cache v139). du USED TO record this row as `def={i,index}
    -- use={}`, treating a bare-identifier initialiser as a second BINDER, so a PARAMETER
    -- appeared to be redefined here; it now records `def={i} use={index}`. The assertion
    -- below did not change and must not be relaxed to match whatever du says today: it is
    -- about the IR alone, which is the whole reason it survived the other side moving.
    -- ★ Before either fix the two sides AGREED here, because the IR's `?` walk read both
    -- names too — two wrong sides agreeing is exactly what a two-implementation gate exists
    -- to break, and it took fixing this side to expose the other.
    -- RED IF: the IR starts reading `i` again (the `?` fallback returning), or stops reading
    -- `index` (a bare-identifier value mistaken for a second target).
    eq('index', zig_reads('var i: usize = index;'))
end)

-- ── a misparsed `qualified_identifier` must not FABRICATE a symbol (CART-0434) ───────────
--
-- ★★ THE GUARD IS `::`, AND THE NEGATIVE CONTROL IS THE IMPORTANT HALF. C++ spells
-- qualification with `::` in every form — a definition, a prototype, a nested namespace, a
-- template member — so a `qualified_identifier` whose text has none is the parser recovering
-- from something it could not read. An extern-C macro eats the type slot, the next two
-- identifiers read as `ns name`, and squeezing the whitespace out named a real zig header's
-- function `LLVMTargetMachineRefZigLLVMCreateTargetMachine`: a symbol that exists nowhere,
-- with the RETURN TYPE presented as a namespace, so every caller of the real function
-- resolved to nothing.
-- ★ RED IF the unglue starts firing on a REAL qualified name — `ns::f` truncated to `f`
-- would silently break C++ member resolution on every corpus, which is a far larger blast
-- radius than the bug being fixed. That is what the second test is for.
local function cpp_nodes(text)
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/u.cpp', 'w'))
    fd:write(text); fd:close()
    local data = ts.extract(root)
    local names = {}
    for _, n in ipairs(data.nodes or {}) do
        if n.kind == 'function' or n.kind == 'method' then names[n.name] = true end
    end
    vim.fn.delete(root, 'rf')
    return names
end

test('extract: a macro-typed C prototype keeps its OWN name, not the return type glued on',
    function ()
        if not ready('cpp') then skip 'no cpp parser' end
        local n = cpp_nodes('#define ZIG_EXTERN_C extern "C"\n'
            .. 'ZIG_EXTERN_C LLVMTargetMachineRef ZigLLVMCreateTargetMachine(int T);\n')
        ok(n['ZigLLVMCreateTargetMachine'], 'the prototype is named after the function')
        eq(nil, n['LLVMTargetMachineRefZigLLVMCreateTargetMachine'],
            'and NOT after the return type glued to it — that symbol exists nowhere')
    end)

test('extract: a glued-on QUALIFIED return type is dropped, the real qualifier kept',
    function ()
        if not ready('cpp') then skip 'no cpp parser' end
        -- ★★ THE CASE THE FIRST CUT MISSED, and v8 is where it lives: when the glued-on
        -- return type is itself qualified or templated, the node's TEXT contains `::` and a
        -- text-based guard passes it straight through. The signal is the MISSING (zero-width)
        -- `::` token, and the unglue must keep the REAL qualifier behind it.
        -- RED IF: the guard goes back to searching the text, or the unglue takes the trailing
        -- identifier instead of everything after the missing separator (which would yield
        -- `CompileFunction` and lose the class).
        local n = cpp_nodes('#define V8_WARN_UNUSED_RESULT __attribute__((warn_unused_result))\n'
            .. 'V8_WARN_UNUSED_RESULT MaybeLocal<Function> ScriptCompiler::CompileFunction(int a)'
            .. ' { return a; }\n')
        ok(n['ScriptCompiler::CompileFunction'], 'the real qualifier survives the unglue')
        eq(nil, n['MaybeLocal<Function>ScriptCompiler::CompileFunction'],
            'and the return type is not glued to the front of it')
        eq(nil, n['CompileFunction'], 'nor is the class stripped along with the return type')
    end)

test('extract: a QUALIFIED return type puts a real :: above the fabricated one', function ()
    if not ready('cpp') then skip 'no cpp parser' end
    -- ★★ THE SECOND v8 SHAPE, and the reason the unglue descends. When the return type is
    -- itself qualified (`i::MaybeHandle<i::String>`), the OUTER `::` is real and the MISSING
    -- one is nested inside it — so a check of the top node's own children finds nothing and
    -- the whole glued string survives. Everything above the deepest missing separator is
    -- return type; the name is what follows it.
    -- RED IF: the walk stops looking after the top level, which is where it stopped twice.
    local n = cpp_nodes('#define V8_WARN_UNUSED_RESULT __attribute__((warn_unused_result))\n'
        .. 'V8_WARN_UNUSED_RESULT\n'
        .. 'inline i::MaybeHandle<i::String> NewString(int factory) { return factory; }\n')
    ok(n['NewString'], 'the function is named after itself')
    eq(nil, n['i::MaybeHandle<i::String>NewString'], 'not after its qualified return type')
end)

test('extract: a return type on its OWN LINE parks the class in an ERROR node', function ()
    if not ready('cpp') then skip 'no cpp parser' end
    -- ★★ THE THIRD SHAPE, AND IT SHARES NO SIGNAL WITH THE FIRST TWO. When the return type
    -- sits on its own line — how v8 writes a long signature — there is NO missing `::`: the
    -- parser parks the CLASS in an ERROR node and keeps a real separator. The name therefore
    -- starts AT the ERROR; everything before it is return type.
    -- RED IF: the unglue only ever looks for a missing token, which is where it stopped for
    -- three cuts of this fix while six v8 names stayed fabricated.
    local n = cpp_nodes('#define V8_WARN_UNUSED_RESULT __attribute__((warn_unused_result))\n'
        .. 'V8_WARN_UNUSED_RESULT MaybeDirectHandle<Object>\n'
        .. 'Accessors::ReplaceAccessorWithDataProperty(int isolate) { return isolate; }\n')
    ok(n['Accessors::ReplaceAccessorWithDataProperty'], 'the class and method survive')
    eq(nil, n['MaybeDirectHandle<Object>Accessors::ReplaceAccessorWithDataProperty'],
        'and the return type is not glued to the front')
end)

test('extract: a QUALIFIED return type hides the ERROR one level down too', function ()
    if not ready('cpp') then skip 'no cpp parser' end
    -- ★★ THE SAME NESTING TRAP, NOW FOR THE ERROR SHAPE — and the fourth time on this fix
    -- that a rule was right at the top level and blind one level down. `std::optional<T>` is
    -- itself qualified, so the top node's `::` is real and its children hold no ERROR; the
    -- ERROR is inside the nested qualified_identifier.
    -- RED IF: either shape's detector stops descending. Both must, and for the same reason.
    local n = cpp_nodes('#include <optional>\nstruct H {};\n'
        .. 'std::optional<H>\nOS::CreateSharedMemoryHandleForTesting(int a) { return {}; }\n')
    ok(n['OS::CreateSharedMemoryHandleForTesting'], 'the class and method survive')
    eq(nil, n['std::optional<H>OS::CreateSharedMemoryHandleForTesting'],
        'and the qualified return type is not glued to the front')
end)

test('extract: BOTH misparse shapes in one node — the deepest signal wins', function ()
    if not ready('cpp') then skip 'no cpp parser' end
    -- ★★ TWO macros before a qualified template return type put an ERROR at the top AND a
    -- missing `::` one level down. Answering from the shallower one strips a single macro and
    -- glues the rest — measured: it made v8's residual go UP, 15 -> 17, because three fully
    -- glued names became half-glued and a detector counts both the same.
    -- RED IF: either local test runs before the descent. Everything above the DEEPEST signal
    -- is return type, so the descent must come first.
    local n = cpp_nodes('#define V8_NOINLINE __attribute__((noinline))\n'
        .. '#define V8_PRESERVE_MOST\n#include <utility>\n'
        .. 'V8_NOINLINE V8_PRESERVE_MOST std::pair<int, unsigned> read_leb_slowpath(int pc)'
        .. ' { return {pc, 0}; }\n')
    ok(n['read_leb_slowpath'], 'the function is named after itself')
    eq(nil, n['std::pair<int,unsigned>read_leb_slowpath'], 'not half-stripped')
    eq(nil, n['V8_PRESERVE_MOSTstd::pair<int,unsigned>read_leb_slowpath'], 'nor unstripped')
end)

test('extract: a REAL qualified name keeps its qualification — the negative control',
    function ()
        if not ready('cpp') then skip 'no cpp parser' end
        -- RED IF: the unglue drops its `::` guard and truncates every qualified definition
        -- to its trailing identifier. `ns::f` is the shape that must survive untouched.
        -- ★ the fixture holds ONLY the definition. My first cut also declared the prototype
        -- inside `namespace ns { int f(int a); }`, and the spec went red asserting no node
        -- named `f` — correctly: that prototype IS a node named `f`, captured by the header
        -- interface query. The spec was wrong, not the code, and it is worth the two lines
        -- to say so: a negative control that goes red on the FIXTURE has still done its job,
        -- because it proved the assertion was reachable at all.
        local n = cpp_nodes('int ns::f(int a) { return a; }\n')
        ok(n['ns::f'], 'a definition qualified with :: keeps the qualifier')
        eq(nil, n['f'], 'and is NOT truncated to its trailing identifier')
    end)

-- ── a C++20 requires-clause vs the constructor's name (CART-0435) ────────────
-- A CONSTRAINED CONSTRUCTOR nests one `function_declarator` inside another, and the cpp
-- spec's `declarator: (_) @name` captures the INNER one — so the stored name is the whole
-- signature: parameter list, `requires` clause and member-initializer list. Fourteen such
-- names in v8's handles.h / maybe-handles.h / tagged.h, and a constructor named
-- `Handle::Handle(Handle<S>handle)requires(…):HandleBase` can never be resolved to.
-- ★ THE GRAMMAR DOES PLACE `requires_clause` — this is not a pre-C++20 parser, and
-- CART-0434's qualified_identifier recovery cannot see it (the capture is a declarator, not
-- a qualified name). What it gets wrong is the member-init list: `: HandleBase` is eaten
-- into the requires_clause and its `(handle)` is left over as a second parameter_list, which
-- is what forces the second declarator level.
-- ★ THE MACRO IN THE TYPE SLOT IS LOAD-BEARING IN THE FIXTURE: without `V8_INLINE` the
-- parser reads a constructor, parks `: Base(x)` in a field_initializer_list and the bug does
-- not reproduce. Measured — my first fixture came back green on unfixed code.
test('extract: a C++20 requires-clause is not glued into the constructor NAME', function ()
    if not ready('cpp') then skip 'no cpp parser' end
    -- RED IF: the name capture stops descending through nested function_declarators — either
    -- spelling of the constraint, `requires(expr)` and the paren-less `requires expr`,
    -- produces the identical two-level shape and both must survive it.
    local n = cpp_nodes('#define V8_INLINE inline\n'
        .. 'template <typename T>\nclass Handle {\n public:\n'
        .. '  template <typename S>\n  V8_INLINE Handle(Handle<S> handle)\n'
        .. '    requires(is_subtype_v<S, T>)\n      : HandleBase(handle) {}\n};\n'
        .. 'class Tagged {\n public:\n  template <typename U>\n'
        .. '  V8_INLINE constexpr explicit Tagged(Address ptr)\n'
        .. '    requires std::is_same_v<This, MaybeObject>\n      : Base(ptr) {}\n};\n'
        .. 'class Widget {\n public:\n  V8_INLINE Widget(int a) : count_(a) {}\n'
        .. '  int count_;\n};\n'
        .. 'int ns::f(int a) { return a; }\n')
    ok(n['Handle::Handle'], 'the constrained constructor is named after itself')
    eq(nil, n['Handle::Handle(Handle<S>handle)requires(is_subtype_v<S,T>):HandleBase'],
        'and NOT after its entire signature — that symbol exists nowhere')
    ok(n['Tagged::Tagged'], 'the paren-less constraint spelling too')
    eq(nil, n['Tagged(Addressptr)requiresstd::is_same_v<This,MaybeObject>:Base'],
        'whose glued name also loses the class, because `std::` looks like qualification')
    -- NEGATIVE CONTROLS. An ordinary constructor with a member-initializer list does NOT
    -- nest its declarator, and an ordinary qualified definition is untouched by any of this.
    -- RED IF: the descent starts firing on the one-level shape and truncates real names.
    ok(n['Widget::Widget'], 'an ordinary constructor keeps the name it has today')
    ok(n['ns::f'], 'and a qualified definition keeps its qualifier')
end)

test('expr: key() handles an ASSIGN node, whose `t` is a TARGET and not a type string',
    function ()
    -- ★ FROM A USER'S FEEDBACK (2026-09-01): pressing Tab to the `lints` lens on a bash
    -- function threw "attempt to concatenate a table value". The builder writes
    -- `{ k = 'assign', t = TARGET, v = VALUE }` — `t` is an EXPRESSION there and a type
    -- STRING for every other kind — and clones.lua carries that warning twice, so the
    -- overload was known and M.key was simply never given the case. It fell to the
    -- generic branch and concatenated the target table.
    --
    -- ⚠ WHY BASH AND NOT LUA: Lua's assignments are statements the flow layer owns, so
    -- they never reach this builder. Bash puts them in EXPRESSION position constantly.
    -- Measured on ~/git/testssl.sh: 267 of 395 functions threw.
    local expr = require 'cartograph.expr'
    local assign = { k = 'assign',
        t = { k = 'name', n = 'x' },
        v = { k = 'lit', ty = 'num', v = 1 } }
    local ok, key = pcall(expr.key, assign)
    assert(ok, 'key() must not throw on an assign: ' .. tostring(key))
    assert(type(key) == 'string' and #key > 0, 'and it returns a key')
    -- the two halves are both in it, so two different assignments do not collide
    local other = { k = 'assign',
        t = { k = 'name', n = 'y' },
        v = { k = 'lit', ty = 'num', v = 1 } }
    assert(expr.key(assign) ~= expr.key(other),
        'assigning to a different target is a different expression')

    -- ⚠ AND THE FALLBACK MUST SURVIVE ANY non-string `t`, or the next kind that overloads
    -- it takes a pane down the same way
    local weird = { k = 'no-such-kind', t = { 1, 2 }, kids = {} }
    local ok2, key2 = pcall(expr.key, weird)
    assert(ok2, 'the generic branch must not assume `t` is a string: ' .. tostring(key2))
end)
