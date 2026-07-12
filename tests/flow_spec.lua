-- flow.lua (df strangler, increment 1): the fine statement model — coarse
-- projection == df's top-level partition, plus nested rows with a control
-- parent (the region tree df collapses away).

local flow = require 'cartograph.flow'

local function ready(lang)
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    return pcall(vim.treesitter.language.add, lang or 'php')
end

local FN_TYPES = { function_definition = true, method_declaration = true,
    function_declaration = true, method_definition = true, function_item = true }

-- parse `code` and return the first function-like node. `lang` defaults to php
-- (with the <?php preamble); other langs take the code verbatim.
local function parse_fn(code, lang)
    lang = lang or 'php'
    local src = lang == 'php' and ('<?php\n' .. code) or code
    local root = vim.treesitter.get_string_parser(src, lang):parse()[1]:root()
    local fn
    local function rec(n)
        if fn then return end
        if FN_TYPES[n:type()] then fn = n; return end
        for c in n:iter_children() do if c:named() then rec(c) end end
    end
    rec(root)
    return fn, src
end

local function setof(t) local s = {} for _, v in ipairs(t) do s[v] = true end return s end

-- first row index matching (kind, line); line optional
local function row(fl, kind, ln)
    for i, s in ipairs(fl.stmts) do
        if s.kind == kind and (not ln or s.l == ln) then return i end
    end
end
local function has(succ, i, target) -- is `target` a successor of row i?
    for _, s in ipairs(succ[i] or {}) do if s == target then return true end end
    return false
end

-- the reaching edge for a use of `var` at source line `ln`
local function edge_at(fl, edges, var, ln)
    for _, e in ipairs(edges) do
        if e.var == var and fl.stmts[e.at].l == ln then return e end
    end
end

test('flow: fine nesting with control-parent; coarse == top-level partition', function ()
    if not ready() then skip 'no php parser' end
    local fn, src = parse_fn(table.concat({
        'function f($x) {',
        '  $a = 1;',            -- top-level
        '  if ($x > 0) {',      -- top-level control
        '    $b = $a + $x;',    -- nested under the if
        '    return $b;',       -- nested under the if
        '  }',
        '  $c = 2;',            -- top-level
        '}',
    }, '\n'))
    ok(fn, 'found the function node')
    local f = flow.build(fn, src)

    -- coarse projection = the 3 top-level statements ($a, if, $c)
    local co = flow.coarse(f)
    eq(3, #co, 'three top-level statements (df-coarse partition)')

    -- the fine model has MORE rows than df would (the nested $b/return)
    ok(#f.stmts >= 5, 'fine model emits the nested statements too')

    -- find the `if` row and a nested row; the nested row's parent IS the if
    local ifidx, nested
    for i, s in ipairs(f.stmts) do
        if s.kind == 'if_statement' then ifidx = i end
        if s.parent ~= 0 and s.kind == 'stmt' and not nested then nested = s end
    end
    ok(ifidx, 'the if is a control row')
    ok(nested and nested.parent == ifidx, 'a nested statement points at the if as its control parent')
    ok(nested.pol == 'body', 'nested statement is in the then/body region')

    -- def/use (increment 2): the `if` coarse row aggregates its body's dataflow
    -- (df's control-row semantics): defines b, uses x and a
    local ifco = co[2]
    ok(setof(ifco.def).b, 'coarse if-row defines b (aggregated from the body)')
    ok(setof(ifco.use).x and setof(ifco.use).a, 'coarse if-row uses x and a')
    ok(not setof(ifco.use).b, 'b is a def, not also a use (df shadow rule)')
end)

-- increment 2, def/use correctness fix: a control head's OWN row owns only its
-- condition — a sibling elseif/else/case condition belongs to that clause's
-- row, not the head (else it lands at the wrong DFS position and the coarse
-- order-sensitive shadow mis-fires).
test('flow: an elseif condition stays in the elseif clause, not the if head', function ()
    if not ready('php') then skip 'no php parser' end
    local fn, src = parse_fn(table.concat({
        'function f($x, $z) {',
        '  if ($x > 0) {',
        '    $y = 1;',
        '  } elseif ($z > 0) {',
        '    $y = 2;',
        '  }',
        '}',
    }, '\n'))
    ok(fn, 'found the function node')
    local f = flow.build(fn, src)
    local head, elif
    for _, s in ipairs(f.stmts) do
        if s.kind == 'if_statement' and s.pol ~= 'elseif' and not head then head = s end
        if s.pol == 'elseif' then elif = s end
    end
    ok(head, 'the if head is a control row')
    ok(setof(head.use).x, 'the if head uses its own condition var x')
    ok(not setof(head.use).z, 'the if head does NOT absorb the elseif condition var z')
    ok(elif and setof(elif.use).z, 'the elseif clause row owns z')
end)

-- increment 2: a catch clause binds its exception variable (a DEF) and
-- references the type (a use); the body regions under it. Without this the
-- caught var is unbound in the fine model.
test('flow: catch binds the exception var as a def, type as a use', function ()
    if not ready('php') then skip 'no php parser' end
    local fn, src = parse_fn(table.concat({
        'function f() {',
        '  try {',
        '    risky();',
        '  } catch (SomeError $e) {',
        '    handle($e);',
        '  }',
        '}',
    }, '\n'))
    ok(fn, 'found the function node')
    local co = flow.coarse(flow.build(fn, src))
    local tryco = co[1]
    ok(setof(tryco.def).e, 'the caught variable e is a DEF (binding)')
    ok(setof(tryco.use).SomeError, 'the exception type is a use')
    ok(not setof(tryco.use).e, 'e is a binding, not a free use (df shadow rule)')
end)

-- increment 2: JS/TS `{...}` blocks are `statement_block`; they must be treated
-- as region bodies (else control bodies are never regioned and their nested
-- statements — e.g. an else-if condition — are dropped).
test('flow: js statement_block bodies are regioned; else-if condition captured', function ()
    if not ready('javascript') then skip 'no javascript parser' end
    local fn, src = parse_fn(table.concat({
        'function f(err) {',
        '  if (err.code === "X") {',
        '    a();',
        '  } else if (err instanceof SyntaxError) {',
        '    b();',
        '  }',
        '}',
    }, '\n'), 'javascript')
    ok(fn, 'found the function node')
    local f = flow.build(fn, src)
    -- the block bodies are regioned into their own rows (a(), b())
    local bodyrows = 0
    for _, s in ipairs(f.stmts) do if s.kind == 'stmt' and s.pol == 'body' then bodyrows = bodyrows + 1 end end
    ok(bodyrows >= 2, 'both block bodies are regioned as statement rows')
    -- the else-if condition use is captured in the coarse projection
    local co = flow.coarse(f)
    ok(setof(co[1].use).SyntaxError, 'the else-if condition use (SyntaxError) is captured')
end)

-- increment 2: a statement that IS a bare name leaf — a rust/ml tail-expression
-- (implicit return) — must count as a use (du inspects children, so a root
-- name would otherwise be missed).
test('flow: a bare tail-expression name counts as a use (rust implicit return)', function ()
    if not ready('rust') then skip 'no rust parser' end
    local fn, src = parse_fn(table.concat({
        'fn f() -> String {',
        '    let mut out = String::new();',
        '    out = out.replace("a", "b");',
        '    out',                                -- bare tail expression
        '}',
    }, '\n'), 'rust')
    ok(fn, 'found the function node')
    local co = flow.coarse(flow.build(fn, src))
    local tail = co[#co]
    ok(setof(tail.use).out, 'the bare tail-expression `out` is counted as a use')
end)

-- step 2b: coarse dep = df's flat FIRST-def-wins reaching scan (params seed
-- defined=0); the parity projection. A later use depends on the FIRST stmt
-- that defined the var; an undefined name is a free input.
test('flow: coarse dep is df\'s flat first-def-wins scan; params seed inputs', function ()
    if not ready('php') then skip 'no php parser' end
    local fn, src = parse_fn(table.concat({
        'function f($p) {',
        '  $a = $p + 1;',   -- stmt 1: def a, use p (a param → not an input, not a dep)
        '  $b = $a + $q;',  -- stmt 2: def b, use a (dep on stmt 1), use q (free input)
        '  return $b;',     -- stmt 3: use b (dep on stmt 2)
        '}',
    }, '\n'))
    ok(fn, 'found the function node')
    local co, inputs = flow.coarse(flow.build(fn, src, { pfield = 'parameters' }))
    eq({ 'q' }, inputs, 'q is the only free input (p is a param, a/b are defined)')
    -- stmt 2 (index 2) depends on stmt 1 for a
    local function depvars(st) local o = {} for _, d in ipairs(st.dep) do o[d.var] = d.from end return o end
    eq(1, depvars(co[2]).a, 'stmt 2 use of a depends on stmt 1 (first def)')
    eq(nil, depvars(co[2]).q, 'q is a free input, not a dep')
    eq(2, depvars(co[3]).b, 'stmt 3 use of b depends on stmt 2')
end)

-- step 2b, scope-regime: the FINE reaching scan honors block vs function
-- scoping — a def in a now-closed block reaches a later use ONLY under a
-- function/hoisted regime. JS `let` (block) vs `var` (hoisted) is the case.
test('flow: scope-regime — JS let is block-scoped, var survives block exit', function ()
    if not ready('javascript') then skip 'no javascript parser' end
    local fn, src = parse_fn(table.concat({
        'function f(c) {',
        '  if (c) {',
        '    let x = 1;',
        '    a(x);',          -- line 4: x in scope here (lexical/enclosing)
        '  }',
        '  b(x);',            -- line 6: let x is dead after the block → free
        '  if (c) {',
        '    var y = 2;',
        '  }',
        '  d(y);',            -- line 10: var y survives the block → reaches
        '}',
    }, '\n'), 'javascript')
    ok(fn, 'found the function node')
    local fl = flow.build(fn, src, { regime = flow.REGIME.javascript })
    local edges = flow.reaching(fl)
    ok(edge_at(fl, edges, 'x', 4).kind == 'lexical', 'x reaches inside its own block')
    ok(edge_at(fl, edges, 'x', 6).kind == 'free', 'let x does NOT reach after the block (block-scoped)')
    ok(edge_at(fl, edges, 'y', 10).kind == 'function-scope', 'var y reaches after the block (hoisted/function-scoped)')
end)

test('flow: scope-regime — php variables are function-scoped (survive blocks)', function ()
    if not ready('php') then skip 'no php parser' end
    local fn, src = parse_fn(table.concat({
        'function h($c) {',
        '  if ($c) {',            -- (line 3 after the <?php preamble)
        '    $z = 1;',            -- line 4
        '  }',                    -- line 5
        '  use_it($z);',          -- line 6: php has no block scope → $z reaches
        '}',
    }, '\n'))
    ok(fn, 'found the function node')
    local fl = flow.build(fn, src, { pfield = 'parameters', regime = flow.REGIME.php })
    local e = edge_at(fl, flow.reaching(fl), 'z', 6)
    ok(e and e.kind == 'function-scope', 'php $z reaches after the block (function scope)')
end)

test('flow: scope-regime — lua locals are block-scoped (die at do..end)', function ()
    if not ready('lua') then skip 'no lua parser' end
    local fn, src = parse_fn(table.concat({
        'local function f()',
        '  do',
        '    local w = 1',
        '    g(w)',              -- line 4: in scope
        '  end',
        '  h(w)',                -- line 6: local w dead after the do-block → free
        'end',
    }, '\n'), 'lua')
    ok(fn, 'found the function node')
    local fl = flow.build(fn, src, { regime = flow.REGIME.lua })
    local edges = flow.reaching(fl)
    ok(edge_at(fl, edges, 'w', 4).kind == 'lexical', 'w reaches inside its block')
    ok(edge_at(fl, edges, 'w', 6).kind == 'free', 'local w does NOT reach after the do-block')
end)

-- per-language config step: rust control is EXPRESSIONS (if_expression, wrapped
-- in expression_statement) and `let` is let_declaration — flow now regions them
-- via cfg-independent node-type support, so rust `let` is block-scoped.
test('flow: scope-regime — rust let is block-scoped (fine structure)', function ()
    if not ready('rust') then skip 'no rust parser' end
    local fn, src = parse_fn(table.concat({
        'fn f(c: bool) {',
        '    if c {',
        '        let w = 1;',
        '        g(w);',           -- line 4: in scope
        '    }',
        '    h(w);',               -- line 6: let w dead after the if-block → free
        '}',
    }, '\n'), 'rust')
    ok(fn, 'found the function node')
    local fl = flow.build(fn, src, { regime = flow.REGIME.rust })
    local edges = flow.reaching(fl)
    ok(edge_at(fl, edges, 'w', 4).kind == 'lexical', 'w reaches inside its block')
    ok(edge_at(fl, edges, 'w', 6).kind == 'free', 'let w does NOT reach after the if-block')
end)

-- per-language config step: bash names are `variable_name` LEAVES (not
-- identifier/name), so du must count them via the language's df_ids extension
-- (cfg.df_ids); `local x=…` is a declaration_command def-position.
test('flow: per-language df_ids — bash variable_name leaves + local def', function ()
    if not ready('bash') then skip 'no bash parser' end
    local fn, src = parse_fn(table.concat({
        'f() {',
        '  local x=1',
        '  echo "$x"',
        '}',
    }, '\n'), 'bash')
    ok(fn, 'found the function node')
    local co = flow.coarse(flow.build(fn, src, { df_ids = { variable_name = true } }))
    ok(setof(co[1].def).x, 'bash `local x=1` defines x (declaration_command + df_ids)')
    ok(setof(co[2].use).x, 'bash `echo "$x"` uses x (variable_name leaf counted)')
    -- without df_ids, variable_name is invisible → x is neither def nor use
    local co0 = flow.coarse(flow.build(fn, src))
    ok(not setof(co0[1].def).x, 'without df_ids, bash variable_name is not counted')
end)

-- CFG phase 2: successor edges + liveness over the fine rows.
test('flow: liveness — used var lives to its use; defined-unused var is dead', function ()
    if not ready('lua') then skip 'no lua parser' end
    local fn, src = parse_fn(table.concat({
        'local function f()',
        '  local a = 1',   -- a is used → live out
        '  print(a)',
        '  local b = 2',   -- b never used → dead
        'end',
    }, '\n'), 'lua')
    local fl = flow.build(fn, src)
    local lv = flow.liveness(fl)
    ok(lv.live_out[row(fl, 'stmt', 2)].a, 'a is live after its definition (used next)')
    ok(next(lv.live_out[row(fl, 'stmt', 4)]) == nil, 'local b=2 is dead (never used) → empty live-out')
end)

test('flow: CFG if/else joins both branches; loop body has a back-edge to the head', function ()
    if not ready('lua') then skip 'no lua parser' end
    local fn, src = parse_fn(table.concat({
        'local function f(c)',
        '  if c then g() else h() end',   -- both branches → the join
        '  done()',
        'end',
    }, '\n'), 'lua')
    local fl = flow.build(fn, src)
    local cfg = flow.successors(fl)
    local ifr, join = row(fl, 'if_statement'), row(fl, 'stmt', 3)
    eq(2, #cfg.succ[ifr], 'the if branches two ways (then / else)')
    for _, br in ipairs(cfg.succ[ifr]) do
        ok(has(cfg.succ, br, join), 'each branch flows to the join (done())')
    end

    local fn2, src2 = parse_fn(table.concat({
        'local function g(n)',
        '  while n > 0 do n = n - 1 end',
        '  return n',
        'end',
    }, '\n'), 'lua')
    local fl2 = flow.build(fn2, src2)
    local cfg2 = flow.successors(fl2)
    local head = row(fl2, 'while_statement')
    local body = row(fl2, 'stmt', 2) -- `n = n - 1`
    ok(has(cfg2.succ, body, head), 'the loop body flows back to the head (back-edge)')
    ok(has(cfg2.succ, head, row(fl2, 'stmt', 3)), 'the head can exit the loop (zero-trip)')
end)

test('flow: an early return flows to exit; the fall-through use stays live', function ()
    if not ready('lua') then skip 'no lua parser' end
    local fn, src = parse_fn(table.concat({
        'local function f(c, x)',
        '  if c then return end',
        '  use(x)',
        'end',
    }, '\n'), 'lua')
    local fl = flow.build(fn, src)
    local cfg, lv = flow.successors(fl), flow.liveness(fl)
    ok(has(cfg.succ, row(fl, 'stmt', 2), cfg.EXIT), 'the return flows to the function exit')
    ok(lv.live_out[row(fl, 'if_statement')].x, 'x is live after the if (needed on the fall-through path)')
end)

-- CFG phase 2b: post-condition loops, plain blocks, feasibility, exception edges.
test('flow: POST-condition loop (repeat/until) — body runs before the test, no zero-trip', function ()
    if not ready('lua') then skip 'no lua parser' end
    local fn, src = parse_fn(table.concat({
        'local function f(n)',
        '  repeat',
        '    n = n - 1',
        '  until n <= 0',
        '  return n',
        'end',
    }, '\n'), 'lua')
    local fl = flow.build(fn, src)
    local cfg = flow.successors(fl)
    local head, body, cond = row(fl, 'repeat_statement'), row(fl, 'stmt', 3), row(fl, 'cond')
    local ret = row(fl, 'stmt', 5)
    eq(1, #cfg.succ[head], 'the head has ONE successor: it always enters the body (no zero-trip skip)')
    ok(has(cfg.succ, head, body), 'the head enters the body')
    ok(has(cfg.succ, body, cond), 'the body flows to the until-condition (tested AFTER the body)')
    ok(has(cfg.succ, cond, body), 'the condition loops back to the body (back-edge THROUGH the test)')
    ok(has(cfg.succ, cond, ret), 'the condition can exit the loop')
end)

test('flow: do{}while(0) — the const-false one-shot idiom has no back-edge', function ()
    if not ready('c') then skip 'no c parser' end
    local fn, src = parse_fn(table.concat({
        'void f(int n){',
        '  do { work(n); } while(0);',
        '  tail();',
        '}',
    }, '\n'), 'c')
    local fl = flow.build(fn, src)
    local cfg = flow.successors(fl)
    local cond, body, tail = row(fl, 'cond'), row(fl, 'stmt', 2), row(fl, 'stmt', 3)
    ok(not has(cfg.succ, cond, body), 'const-false condition drops the back-edge (runs exactly once)')
    ok(has(cfg.succ, cond, tail), 'the condition falls straight through to the tail')
end)

test('flow: while(true)+break — const-true loop has no zero-trip; break is the only exit', function ()
    if not ready('c') then skip 'no c parser' end
    local fn, src = parse_fn(table.concat({
        'void f(int n){',
        '  while(1){ if(n) break; step(); }',
        '  tail();',
        '}',
    }, '\n'), 'c')
    local fl = flow.build(fn, src)
    local cfg = flow.successors(fl)
    local head, tail, brk = row(fl, 'while_statement'), row(fl, 'stmt', 3), row(fl, 'stmt', 2)
    ok(not has(cfg.succ, head, tail), 'const-true head takes no zero-trip / condition-exit edge')
    ok(has(cfg.succ, brk, tail), 'break is the only way out of the infinite loop')
end)

test('flow: lua do...end is a plain block — no back-edge, no zero-trip', function ()
    if not ready('lua') then skip 'no lua parser' end
    local fn, src = parse_fn(table.concat({
        'local function f()',
        '  do',
        '    local x = 1',
        '  end',
        '  g()',
        'end',
    }, '\n'), 'lua')
    local fl = flow.build(fn, src)
    local cfg = flow.successors(fl)
    local head, body, tail = row(fl, 'do_statement'), row(fl, 'stmt', 3), row(fl, 'stmt', 5)
    ok(has(cfg.succ, head, body), 'the do-block enters its body')
    ok(has(cfg.succ, body, tail), 'the body flows straight to the next statement')
    ok(not has(cfg.succ, body, head), 'no spurious loop back-edge (it is NOT a loop)')
end)

test('flow: try/catch/finally — every try point reaches the handler; finally is on the normal path', function ()
    if not ready('php') then skip 'no php parser' end
    local fn, src = parse_fn(table.concat({
        'function f(){',
        '  try {',            -- line 2
        '    a();',           -- line 3
        '    risky();',       -- line 4
        '  } catch (E $e) {',  -- line 5
        '    handle($e);',    -- line 6
        '  } finally {',      -- line 7
        '    clean();',       -- line 8
        '  }',
        '  tail();',          -- line 10
        '}',
    }, '\n'), 'php')
    local fl = flow.build(fn, src)
    local cfg = flow.successors(fl)
    -- the <?php\n preamble shifts every source line by one
    local a, risky = row(fl, 'stmt', 4), row(fl, 'stmt', 5)
    local catch, fin, tail = row(fl, 'catch'), row(fl, 'stmt', 9), row(fl, 'stmt', 11)
    ok(has(cfg.succ, a, catch), 'a throw at try stmt 1 reaches the handler')
    ok(has(cfg.succ, risky, catch), 'a throw at try stmt 2 reaches the handler')
    ok(has(cfg.succ, risky, fin), 'normal try completion goes to finally')
    ok(has(cfg.succ, catch, row(fl, 'stmt', 7)), 'the catch binds then runs its body')
    ok(has(cfg.succ, fin, tail), 'finally completes to the statement after the try')
end)

test('flow: C/C++ pointer/reference/array declarators DEF the inner name', function ()
    if not ready('cpp') then skip 'no cpp parser' end
    local fn, src = parse_fn(table.concat({
        'void g(){',
        '  SMesh *mesh = make();',   -- pointer: mesh is a DEF (was miscounted as a use)
        '  int x = 5;',              -- plain: control
        '  Foo &r = getref();',      -- reference: r is a DEF
        '  char **pp = argv;',       -- double pointer: pp is a DEF
        '  int arr[4] = {0};',       -- array: arr is a DEF, size 4 is not
        '}',
    }, '\n'), 'cpp')
    local fl = flow.build(fn, src, { regime = flow.REGIME.cpp })
    local function defuse(ln)
        for _, s in ipairs(fl.stmts) do
            if s.l == ln then return setof(s.def), setof(s.use) end
        end
    end
    local d2 = defuse(2); ok(d2.mesh, 'SMesh *mesh is a def')
    local d4 = defuse(4); ok(d4.r, 'Foo &r is a def (reference_declarator)')
    local d5 = defuse(5); ok(d5.pp, 'char **pp is a def (nested pointer_declarator)')
    local d6, u6 = defuse(6); ok(d6.arr, 'int arr[4] is a def (array_declarator)')
    ok(not u6.arr, 'arr is not also a use')
end)

test('flow: C/C++ bare declarations (no initializer, multi) DEF their names', function ()
    if not ready('cpp') then skip 'no cpp parser' end
    local fn, src = parse_fn(table.concat({
        'void g(){',
        '  int x;',                     -- bare plain
        '  SMesh *p;',                  -- bare pointer
        '  int a, b;',                  -- multi-declarator (both defs)
        '  std::unique_ptr<T> arr[4];', -- bare array-of-smart-ptr
        '  int n = sz;',                -- init: n def, sz still a use (not eaten)
        '}',
    }, '\n'), 'cpp')
    local fl = flow.build(fn, src, { regime = flow.REGIME.cpp })
    local function du(ln) for _, s in ipairs(fl.stmts) do if s.l == ln then return setof(s.def), setof(s.use) end end end
    ok(du(2).x, 'bare `int x;` defs x')
    ok(du(3).p, 'bare `SMesh *p;` defs p')
    local d4 = du(4); ok(d4.a and d4.b, 'multi `int a, b;` defs both')
    ok(du(5).arr, 'bare `unique_ptr<T> arr[4];` defs arr')
    local d6, u6 = du(6); ok(d6.n and u6.sz and not u6.n, 'int n = sz: n def, sz use preserved')
end)

test('flow: python except_clause is recognised as an exception handler', function ()
    if not ready('python') then skip 'no python parser' end
    local fn, src = parse_fn(table.concat({
        'def f():',
        '  try:',
        '    x = risky()',
        '  except ValueError as e:',
        '    handle(e)',
        '  done()',
    }, '\n'), 'python')
    local fl = flow.build(fn, src)
    local cfg = flow.successors(fl)
    local try_body, catch = row(fl, 'stmt', 3), row(fl, 'catch')
    ok(catch ~= nil, 'except_clause produces a catch row (not a plain body statement)')
    ok(has(cfg.succ, try_body, catch), 'the try body reaches the except handler')
end)
