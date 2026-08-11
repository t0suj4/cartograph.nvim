-- flow.lua (df strangler, increment 1): the fine statement model — coarse
-- projection == df's top-level partition, plus nested rows with a control
-- parent (the region tree df collapses away).

local flow = require 'cartograph.flow'
local tsspec = require('cartograph.providers.treesitter').spec -- per-language cfg (regime lives here now)

local function ready(lang)
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    return pcall(vim.treesitter.language.add, lang or 'php')
end

local FN_TYPES = { function_definition = true, method_declaration = true,
    function_declaration = true, method_definition = true, function_item = true,
    method = true } -- ruby (CART-0363)

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
-- reaching_cfg: the `from` set (as a set) for the use of `var` at source line `ln`
local function rc_at(rc, fl, var, ln)
    for _, e in ipairs(rc) do
        if e.var == var and fl.stmts[e.at].l == ln then return setof(e.from) end
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

-- reaching-on-CFG INC A: control-flow reaching definitions (set-valued).
test('flow: reaching_cfg — a branch join reaches BOTH arms defs', function ()
    if not ready('lua') then skip 'no lua parser' end
    local fn, src = parse_fn(table.concat({
        'local function f(c)',
        '  local x',        -- 2
        '  if c then',
        '    x = 1',         -- 4: arm A
        '  else',
        '    x = 2',         -- 6: arm B
        '  end',
        '  use(x)',          -- 8: reaches x@4 AND x@6 (join)
        'end',
    }, '\n'), 'lua')
    local fl = flow.build(fn, src, { pfield = 'parameters', regime = tsspec.lua.regime })
    local rc = flow.reaching_cfg(fl)
    local a4, b6, u8 = row(fl, 'stmt', 4), row(fl, 'stmt', 6), row(fl, 'stmt', 8)
    local from
    for _, e in ipairs(rc) do if e.var == 'x' and e.at == u8 then from = setof(e.from) end end
    ok(from, 'use(x) has a reaching set for x')
    ok(from[a4] and from[b6], 'both arm defs (x@4 and x@6) reach the join use — the multi-def the structural approx cannot express')
end)

test('flow: reaching_cfg — a loop back-edge reaches the pre-loop AND loop def', function ()
    if not ready('lua') then skip 'no lua parser' end
    local fn, src = parse_fn(table.concat({
        'local function f(n)',
        '  local x = 0',       -- 2: pre-loop def
        '  while n > 0 do',
        '    use(x)',          -- 4: reaches x@2 (first trip) AND x@5 (back-edge)
        '    x = x + 1',       -- 5: loop def
        '    n = n - 1',
        '  end',
        'end',
    }, '\n'), 'lua')
    local fl = flow.build(fn, src, { pfield = 'parameters', regime = tsspec.lua.regime })
    local rc = flow.reaching_cfg(fl)
    local pre, loopdef, usex = row(fl, 'stmt', 2), row(fl, 'stmt', 5), row(fl, 'stmt', 4)
    local from
    for _, e in ipairs(rc) do if e.var == 'x' and e.at == usex then from = setof(e.from) end end
    ok(from and from[pre], 'the pre-loop def x@2 reaches the loop-body use (first iteration)')
    ok(from and from[loopdef], 'the loop def x@5 reaches the use via the back-edge (later iterations)')
end)

test('flow: reaching_cfg — a block-local reassigned in a nested loop reaches a later in-block use', function ()
    if not ready('lua') then skip 'no lua parser' end
    -- flow-precision-gaps #2: `pos` is block-scoped (the do-block); the reassign
    -- `pos = f()` is function-scoped (assignments don't open a scope), so the
    -- nearest-scope preference used to drop it as "outer" — losing a real reaching
    -- def past the inner loop. Both the pre-loop decl AND the in-loop reassign must
    -- reach use(pos).
    local fn, src = parse_fn(table.concat({
        'local function f()',
        '  do',
        '    local pos = 1',      -- 3: block-scoped decl
        '    while cond() do',
        '      pos = f2()',        -- 5: reassignment inside the inner loop
        '    end',
        '    use(pos)',           -- 7: reaches BOTH pos@3 and pos@5
        '  end',
        'end',
    }, '\n'), 'lua')
    local fl = flow.build(fn, src, { pfield = 'parameters', regime = tsspec.lua.regime })
    local rc = flow.reaching_cfg(fl)
    local decl, reassign, usep = row(fl, 'stmt', 3), row(fl, 'stmt', 5), row(fl, 'stmt', 7)
    local from
    for _, e in ipairs(rc) do if e.var == 'pos' and e.at == usep then from = setof(e.from) end end
    ok(from and from[decl], 'the pre-loop block-local decl pos@3 reaches use(pos)')
    ok(from and from[reassign], 'the in-loop reassignment pos@5 reaches use(pos) (was dropped)')
end)

test('flow: reaching_cfg — a read-modify-write self-read reaches (rmw column)', function ()
    if not ready('lua') then skip 'no lua parser' end
    -- flow-precision-gaps #1: `total = total + x` — the df contract drops the RHS
    -- read of `total` from `use` (a def name is not also a use), so reaching used
    -- to miss the self-read entirely. The sparse `rmw` column keeps it; reaching_cfg
    -- must emit an edge for it (the accumulator reads its own prior value).
    local fn, src = parse_fn(table.concat({
        'local function f(xs)',
        '  local total = 0',      -- 2: pre-loop def
        '  for _, x in ipairs(xs) do',
        '    total = total + x',    -- 4: reads AND writes total (a read-modify-write)
        '  end',
        '  return total',
        'end',
    }, '\n'), 'lua')
    local fl = flow.build(fn, src, { pfield = 'parameters', regime = tsspec.lua.regime })
    local rmwrow = row(fl, 'stmt', 4)
    ok(fl.stmts[rmwrow].rmw and fl.stmts[rmwrow].rmw[1] == 'total',
        'the RHS self-read of total is recorded in the rmw column, not lost')
    local rc = flow.reaching_cfg(fl)
    local from
    for _, e in ipairs(rc) do if e.var == 'total' and e.at == rmwrow then from = setof(e.from) end end
    ok(from, 'reaching emits an edge for the self-read of total (was dropped entirely)')
    ok(from and from[row(fl, 'stmt', 2)], 'the self-read sees the pre-loop def total@2')
end)

test('flow: reaching_cfg — reassigning an inner shadow does not leak past its block', function ()
    if not ready('lua') then skip 'no lua parser' end
    -- comprehensive #2 (assignment scoping): `a = 3` writes the INNER block-local,
    -- so it must be scoped to the block and NOT reach the post-block `return a`
    -- (which sees the outer a@2). The filter-only surgical fix scoped the assignment
    -- to function scope, so it would have leaked here; correct assignment scoping
    -- confines it.
    local fn, src = parse_fn(table.concat({
        'local function f()',
        '  local a = 1',        -- 2: outer a
        '  do',
        '    local a = 2',       -- 4: inner shadow
        '    a = 3',             -- 5: reassign the INNER a (block-scoped)
        '  end',
        '  return a',           -- 7: reads OUTER a@2 only
        'end',
    }, '\n'), 'lua')
    local fl = flow.build(fn, src, { pfield = 'parameters', regime = tsspec.lua.regime })
    local rc = flow.reaching_cfg(fl)
    local outer, reassign, ret = row(fl, 'stmt', 2), row(fl, 'stmt', 5), row(fl, 'stmt', 7)
    local from
    for _, e in ipairs(rc) do if e.var == 'a' and e.at == ret then from = setof(e.from) end end
    ok(from and from[outer], 'the post-block return reads the outer a@2')
    ok(from and not from[reassign], 'the inner reassignment a@5 is confined to its block (not leaked)')
end)

test('flow: reaching_cfg — a genuine inner shadow is NOT resurrected by the reassign fix', function ()
    if not ready('lua') then skip 'no lua parser' end
    -- the control for the fix above: a real inner `local x` is a NEW binding that
    -- dies at block exit; the fix (which keeps a reassignment nested in the binding)
    -- must NOT keep this shadow. After the inner block, use(x) sees the OUTER x only.
    local fn, src = parse_fn(table.concat({
        'local function f()',
        '  local x = 1',          -- 2: outer decl
        '  do',
        '    local x = 2',         -- 4: inner shadow (a distinct binding)
        '    keep(x)',
        '  end',
        '  use(x)',               -- 7: sees x@2 only, NOT the dead shadow x@4
        'end',
    }, '\n'), 'lua')
    local fl = flow.build(fn, src, { pfield = 'parameters', regime = tsspec.lua.regime })
    local rc = flow.reaching_cfg(fl)
    local outer, shadow, usex = row(fl, 'stmt', 2), row(fl, 'stmt', 4), row(fl, 'stmt', 7)
    local from
    for _, e in ipairs(rc) do if e.var == 'x' and e.at == usex then from = setof(e.from) end end
    ok(from and from[outer], 'the outer x@2 reaches the post-block use')
    ok(from and not from[shadow], 'the dead inner shadow x@4 is NOT resurrected')
end)

test('flow: reaching_cfg INC B — a block-scoped def dies at block exit', function ()
    if not ready('lua') then skip 'no lua parser' end
    local fn, src = parse_fn(table.concat({
        'local function f(c)',
        '  local inner',       -- (unused decl; the real def is in the block)
        '  if c then',
        '    local x = 1',      -- 4: block-regime, in the if-body region
        '    use(x)',           -- 5: x IN scope → reaches x@4
        '  end',
        '  use(x)',             -- 7: x OUT of scope (if-body closed) → filtered → free
        'end',
    }, '\n'), 'lua')
    local fl = flow.build(fn, src, { pfield = 'parameters', regime = tsspec.lua.regime })
    local rc = flow.reaching_cfg(fl)
    local x4, u5, u7 = row(fl, 'stmt', 4), row(fl, 'stmt', 5), row(fl, 'stmt', 7)
    local inb, outb
    for _, e in ipairs(rc) do
        if e.var == 'x' and e.at == u5 then inb = setof(e.from) end
        if e.var == 'x' and e.at == u7 then outb = setof(e.from) end
    end
    ok(inb and inb[x4], 'inside the block, x@4 reaches the use')
    ok(outb and not outb[x4], 'after the block, the block-scoped x@4 is filtered (block-death)')
end)

test('flow: reaching_cfg — an unmodified param reaches from the entry sentinel 0', function ()
    if not ready('lua') then skip 'no lua parser' end
    local fn, src = parse_fn(table.concat({
        'local function f(p)',
        '  use(p)',   -- 2: p reaches from entry (0), no intervening def
        'end',
    }, '\n'), 'lua')
    local fl = flow.build(fn, src, { pfield = 'parameters', regime = tsspec.lua.regime })
    local rc = flow.reaching_cfg(fl)
    local from
    for _, e in ipairs(rc) do if e.var == 'p' and e.at == row(fl, 'stmt', 2) then from = setof(e.from) end end
    ok(from and from[0], 'the param p reaches from the entry sentinel 0 (always in scope)')
end)

test('flow: reaching_cfg INC C — reaching only via a may-throw edge is hedged (~)', function ()
    if not ready('php') then skip 'no php parser' end
    local fn, src = parse_fn(table.concat({
        'function f() {',
        '  try {',
        '    $x = risky();',   -- def x in the try body
        '  } catch (E $e) {',
        '    use($x);',         -- x reaches here ONLY via the conservative may-throw edge → ~
        '  }',
        '}',
    }, '\n'))
    local fl = flow.build(fn, src, { pfield = 'parameters' })
    local rc = flow.reaching_cfg(fl)
    local defx, usex
    for i, s in ipairs(fl.stmts) do
        for _, d in ipairs(s.def) do if d == 'x' then defx = i end end
    end
    for _, e in ipairs(rc) do if e.var == 'x' then usex = e end end
    ok(defx and usex, 'x has a def and a reaching use')
    ok(setof(usex.from)[defx], 'x@def reaches the catch use (control-wise)')
    ok(usex.hedged and usex.hedged[defx], 'the reaching is ~ — only via the conservative may-throw edge')
end)

-- reaching_cfg scope-regime coverage (ported from the retired structural
-- M.reaching tests): block-regime dies at block exit → empty reaching set;
-- function/hoisted-regime survives → non-empty.
test('flow: reaching_cfg scope-regime — JS let is block-scoped, var survives', function ()
    if not ready('javascript') then skip 'no javascript parser' end
    local fn, src = parse_fn(table.concat({
        'function f(c) {',
        '  if (c) {',
        '    let x = 1;',
        '    a(x);',          -- 4: x in scope
        '  }',
        '  b(x);',            -- 6: let x dead after the block → free (empty)
        '  if (c) {',
        '    var y = 2;',
        '  }',
        '  d(y);',            -- 10: var y survives → reaches
        '}',
    }, '\n'), 'javascript')
    local f2 = flow.build(fn, src, { regime = tsspec.javascript.regime })
    local rc = flow.reaching_cfg(f2)
    ok(next(rc_at(rc, f2, 'x', 4)), 'let x reaches inside its own block')
    ok(not next(rc_at(rc, f2, 'x', 6)), 'let x does NOT reach after the block (block-scoped → empty)')
    ok(next(rc_at(rc, f2, 'y', 10)), 'var y reaches after the block (hoisted/function-scoped)')
end)

test('flow: reaching_cfg scope-regime — php variables survive blocks (function scope)', function ()
    if not ready('php') then skip 'no php parser' end
    local fn, src = parse_fn(table.concat({
        'function h($c) {',
        '  if ($c) {',
        '    $z = 1;',        -- (line 4 after <?php)
        '  }',
        '  use_it($z);',      -- line 6: php has no block scope → $z reaches
        '}',
    }, '\n'))
    local f2 = flow.build(fn, src, { pfield = 'parameters', regime = tsspec.php.regime })
    ok(next(rc_at(flow.reaching_cfg(f2), f2, 'z', 6)), 'php $z reaches after the block (function scope)')
end)

test('flow: reaching_cfg scope-regime — rust let is block-scoped', function ()
    if not ready('rust') then skip 'no rust parser' end
    local fn, src = parse_fn(table.concat({
        'fn f(c: bool) {',
        '    if c {',
        '        let w = 1;',
        '        g(w);',        -- 4: in scope
        '    }',
        '    h(w);',            -- 6: let w dead after the if-block → free (empty)
        '}',
    }, '\n'), 'rust')
    local f2 = flow.build(fn, src, { regime = tsspec.rust.regime })
    local rc = flow.reaching_cfg(f2)
    ok(next(rc_at(rc, f2, 'w', 4)), 'let w reaches inside its block')
    ok(not next(rc_at(rc, f2, 'w', 6)), 'let w does NOT reach after the if-block (block-scoped → empty)')
end)

test('lens: branch-value — per-branch live values (what flows through each branch)', function ()
    if not ready('lua') then skip 'no lua parser' end
    local lens = require 'cartograph.lens'
    local fn, src = parse_fn(table.concat({
        'local function f(c, x, y)',
        '  if c then',
        '    use(x)',      -- then-branch: x flows in
        '  else',
        '    use(y)',      -- else-branch: y flows in
        '  end',
        'end',
    }, '\n'), 'lua')
    local fl = flow.build(fn, src, { pfield = 'parameters', regime = tsspec.lua.regime })
    local heads = lens.branches(fl)
    local ifh
    for _, h in ipairs(heads) do if h.kind == 'if_statement' then ifh = h end end
    ok(ifh, 'the if is a branch head')
    ok(#ifh.branches >= 2, 'the if has >=2 outgoing branches')
    local hasx, hasy = false, false
    for _, b in ipairs(ifh.branches) do
        local ls = setof(b.live)
        if ls.x then hasx = true end
        if ls.y then hasy = true end
    end
    ok(hasx and hasy, 'one branch flows x (then), another flows y (else) — per-branch live values')
end)

test('flow: predecessors transposes successors; exit is the backward root', function ()
    if not ready('lua') then skip 'no lua parser' end
    local fn, src = parse_fn(table.concat({
        'local function f(c, x)',
        '  if c then return end',
        '  use(x)',
        'end',
    }, '\n'), 'lua')
    local fl = flow.build(fn, src)
    local cfg, pred = flow.successors(fl), flow.predecessors(fl)
    for a, outs in pairs(cfg.succ) do
        for _, b in ipairs(outs) do
            ok(has(pred, b, a), ('succ edge %s->%s appears in pred[%s]'):format(tostring(a), tostring(b), tostring(b)))
        end
    end
    ok(has(pred, 'exit', row(fl, 'stmt', 2)), 'the return is a predecessor of exit (a backward root)')
end)

test('flow: yield/await are suspension points — suspend to exit + resume to next', function ()
    if not ready('python') then skip 'no python parser' end
    local fn, src = parse_fn(table.concat({
        'def g():',
        '  a()',
        '  x = yield v',   -- suspend (yield v out), resume (x = sent value) here
        '  b(x)',
    }, '\n'), 'python')
    local fl = flow.build(fn, src, { regime = tsspec.python.regime })
    local y = row(fl, 'stmt', 3)
    ok(fl.stmts[y].suspend, 'the yield row is flagged as a suspension point')
    local cfg = flow.successors(fl)
    ok(has(cfg.succ, y, cfg.EXIT), 'suspend edge: control may leave to the caller at yield')
    ok(has(cfg.succ, y, row(fl, 'stmt', 4)), 'resume edge: the continuation b(x) runs on resume')
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
    local fl = flow.build(fn, src, { regime = tsspec.cpp.regime })
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
    local fl = flow.build(fn, src, { regime = tsspec.cpp.regime })
    local function du(ln) for _, s in ipairs(fl.stmts) do if s.l == ln then return setof(s.def), setof(s.use) end end end
    ok(du(2).x, 'bare `int x;` defs x')
    ok(du(3).p, 'bare `SMesh *p;` defs p')
    local d4 = du(4); ok(d4.a and d4.b, 'multi `int a, b;` defs both')
    ok(du(5).arr, 'bare `unique_ptr<T> arr[4];` defs arr')
    local d6, u6 = du(6); ok(d6.n and u6.sz and not u6.n, 'int n = sz: n def, sz use preserved')
end)

test('flow: elseif body statements are regioned as rows, not folded', function ()
    if not ready('lua') then skip 'no lua parser' end
    local fn, src = parse_fn(table.concat({
        'local function f(x)',
        '  if x == 1 then',
        '    a()',
        '  elseif x == 2 then',
        '    b()',        -- the elseif BODY: its own row now (was folded away)
        '  end',
        'end',
    }, '\n'), 'lua')
    local fl = flow.build(fn, src)
    local ei = row(fl, 'elseif_statement')
    ok(ei, 'the elseif is a control row (its condition)')
    local bcall = row(fl, 'stmt', 5)
    ok(bcall, 'the elseif body b() is its own row')
    eq(ei, fl.stmts[bcall].parent, 'b() is parented to the elseif, not the if head')
end)

test('flow: switch case bodies unfold; break routes to the switch join', function ()
    if not ready('c') then skip 'no c parser' end
    local fn, src = parse_fn(table.concat({
        'void f(int x){',
        '  switch (x) {',
        '    case 1: a(); break;',
        '    default: b();',
        '  }',
        '  tail();',
        '}',
    }, '\n'), 'c')
    local fl = flow.build(fn, src, { regime = tsspec.c.regime })
    local brkrow, acall
    for i, s in ipairs(fl.stmts) do
        if s.t == 'break_statement' then brkrow = i end
        if s.t == 'expression_statement' and s.l == 3 then acall = i end
    end
    ok(row(fl, 'case'), 'the case is a row')
    ok(acall, 'the case body a() is its own row (was folded)')
    ok(brkrow, 'break inside the case is its own row (was folded)')
    local cfg = flow.successors(fl)
    ok(has(cfg.succ, brkrow, row(fl, 'stmt', 6)), 'break routes to the switch join (tail), not fn exit')
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

-- ── the columnar fold (df-strangler step 3) ────────────────────────────────
-- Fold a synthetic data.nodes of built flow records and assert the dual-mode
-- accessors round-trip to the raw rows BIT-FOR-BIT (vim.deep_equal), so
-- successors/coarse/liveness/reaching_cfg read folded storage identically.

test('flow.fold: round-trips rows + params bit-for-bit; accessors dual-mode', function ()
    if not (ready('lua') and ready('python') and ready('c')) then skip 'parsers' end
    -- three functions spanning the interesting row shapes: lua control + block
    -- regime, python yield (suspend) + try/except (catch, cond-less), C do-while
    -- (POST cond row + const) + declarators.
    local fn1, s1 = parse_fn(table.concat({
        'function f(a, b)',
        '  local x = a + b',
        '  if x > 0 then',
        '    do local y = x end',   -- block-regime def in a closed block
        '    return x',
        '  end',
        '  while x < 10 do x = x + 1 end',
        'end',
    }, '\n'), 'lua')
    local fn2, s2 = parse_fn(table.concat({
        'def g(n):',
        '  for i in range(n):',
        '    yield i * 2',          -- suspend row
        '  try:',
        '    risky()',
        '  except E as e:',         -- catch row (no regime/t on some rows)
        '    handle(e)',
    }, '\n'), 'python')
    local fn3, s3 = parse_fn(table.concat({
        'void h(int n) {',
        '  int *p = 0;',            -- pointer declarator def
        '  do { p = step(p); } while (0);',  -- POST cond row + const=false
        '}',
    }, '\n'), 'c')
    local r1 = flow.build(fn1, s1, { pfield = 'parameters', regime = tsspec.lua.regime })
    local r2 = flow.build(fn2, s2, { pfield = 'parameters', regime = tsspec.python.regime })
    local r3 = flow.build(fn3, s3, { pfield = 'parameters', regime = tsspec.c.regime })

    -- raw records, before folding (accessors read them dual-mode)
    local n1 = { flow = { stmts = r1.stmts, params = r1.params } }
    local n2 = { flow = { stmts = r2.stmts, params = r2.params } }
    local n3 = { flow = { stmts = r3.stmts, params = r3.params } }
    local empty = { flow = { stmts = {}, params = {} } }
    local none = {}
    local data = { nodes = { n1, n2, empty, n3, none } }

    -- pre-fold accessor behaviour (raw branch)
    ok(flow.has(n1) and not flow.has(empty), 'has: non-empty vs empty (raw)')
    ok(flow.present(empty) and not flow.present(none), 'present: 0-row vs absent (raw)')
    eq(#r2.stmts, flow.count(n2), 'count (raw)')

    -- capture raw rows/records, then fold
    local raw1, raw2, raw3 = flow.record(n1), flow.record(n2), flow.record(n3)
    local total = flow.fold(data)
    eq(#r1.stmts + #r2.stmts + #r3.stmts, total, 'fold returns total rows folded')
    eq(0, flow.fold(data), 'fold is idempotent')

    -- post-fold: records dropped, columnar slice present
    ok(n1.flow == nil and n1._flow ~= nil, 'raw record dropped, column slice set')

    -- round-trip identity through the folded accessors
    eq(raw1, flow.record(n1), 'fn1 record round-trips bit-for-bit')
    eq(raw2, flow.record(n2), 'fn2 record round-trips (suspend + catch rows)')
    eq(raw3, flow.record(n3), 'fn3 record round-trips (POST cond + const + declarator)')
    eq(r1.stmts, flow.rows(n1), 'fn1 rows round-trip')
    -- every fine row carries a 1-based start column (v32) — same-line entities
    -- are jump-locatable by (l,c); survives the fold like l.
    for _, s in ipairs(flow.rows(n1)) do ok(s.c and s.c >= 1, 'row has 1-based column') end

    -- accessors dual-mode consistent post-fold
    ok(flow.has(n1) and not flow.has(empty), 'has (folded)')
    ok(flow.present(empty) and not flow.present(none), 'present (folded)')
    eq(#r2.stmts, flow.count(n2), 'count (folded)')

    -- CFG analyses read folded storage identically to raw
    eq(flow.successors(raw2).succ, flow.successors(flow.record(n2)).succ,
        'successors identical folded vs raw')
    local cr, ci = flow.coarse(flow.record(n1))
    local cr0, ci0 = flow.coarse(raw1)
    eq(cr0, cr, 'coarse partition identical folded vs raw'); eq(ci0, ci, 'coarse inputs identical')
end)

-- ── control transfer (non-local-transfer): labeled break/continue + goto ────
-- find the first row with raw node type `tt`
local function rowt(fl, tt) for i, s in ipairs(fl.stmts) do if s.t == tt then return i end end end

test('flow: labeled break jumps to the OUTER loop exit, not the inner (go)', function ()
    if not ready('go') then skip 'no go parser' end
    local fn, src = parse_fn(table.concat({
        'func f() {',
        'Outer:',
        '  for i := 0; i < 3; i++ {',
        '    for j := 0; j < 3; j++ {',
        '      break Outer',
        '    }',
        '    work()',   -- inner-loop exit lands here (rest of OUTER body)
        '  }',
        '  done()',     -- OUTER-loop exit lands here
        '}',
    }, '\n'), 'go')
    local fl = flow.build(fn, src, { regime = tsspec.go.regime })
    local brk = rowt(fl, 'break_statement')
    local done = row(fl, 'stmt', 9)   -- done()
    local work = row(fl, 'stmt', 7)   -- work()
    ok(brk and done, 'found break + done rows')
    local cfg = flow.successors(fl)
    ok(has(cfg.succ, brk, done), 'break Outer → the OUTER loop exit (done)')
    ok(not has(cfg.succ, brk, work), 'break Outer does NOT fall to the inner-loop exit (work)')
end)

test('flow: labeled continue targets the OUTER loop head (js)', function ()
    if not ready('javascript') then skip 'no js parser' end
    local fn, src = parse_fn(table.concat({
        'function f() {',
        '  outer: for (let i = 0; i < 3; i++) {',
        '    for (let j = 0; j < 3; j++) {',
        '      continue outer;',
        '    }',
        '  }',
        '}',
    }, '\n'), 'javascript')
    local fl = flow.build(fn, src, { regime = tsspec.javascript.regime })
    local cont = rowt(fl, 'continue_statement')
    local outer = row(fl, 'for_statement', 2) -- the labeled outer loop head
    ok(cont and outer, 'found continue + outer-loop rows')
    local cfg = flow.successors(fl)
    ok(has(cfg.succ, cont, outer), 'continue outer → the OUTER loop head')
end)

test('flow: goto jumps to its label target row (c)', function ()
    if not ready('c') then skip 'no c parser' end
    local fn, src = parse_fn(table.concat({
        'void f() {',
        '  if (x) goto done;',
        '  work();',
        ' done:',
        '  cleanup();',
        '}',
    }, '\n'), 'c')
    local fl = flow.build(fn, src, { regime = tsspec.c.regime })
    local go = rowt(fl, 'goto_statement')
    local target = row(fl, 'stmt', 5) -- cleanup() — the labeled target
    ok(go and target, 'found goto + label-target rows')
    local cfg = flow.successors(fl)
    ok(has(cfg.succ, go, target), 'goto done → the cleanup() row under `done:`')
    ok(#cfg.succ[go] == 1, 'goto has ONLY the jump edge (no fall-through)')
end)

-- CART-0363. flow's CTRL set is `*_statement`-shaped, so a control node spelled otherwise is
-- emitted as a PLAIN ROW and du harvests its whole subtree — the BODY GETS NO ROWS AT ALL.
-- Measured before the fix: ruby opened ZERO control structures (2219 opaque on activerecord
-- alone), and js/ts lost `for…of`/`for…in`, cpp `for_range_loop`, java `enhanced_for`.
-- The set is now threaded PER LANGUAGE from the spec, the v120 precedent, rather than grown
-- as a hardcoded cross-language union.
test('flow: a JS for-of opens its body, like every other loop', function ()
    if not ready('javascript') then skip 'no javascript parser' end
    local fn, src = parse_fn([[
function f(xs) {
    for (const x of xs) {
        g(x);
        h(x);
    }
}
]], 'javascript')
    ok(fn, 'the fixture parses to a function')
    local fl = flow.build(fn, src, { ctrl = tsspec.javascript.ctrl,
        preloop = tsspec.javascript.preloop, regime = tsspec.javascript.regime })
    local head, body = nil, {}
    for i, s in ipairs(fl.stmts) do
        if (s.t or '') == 'for_in_statement' then head = i end
    end
    ok(head, 'the for-of is a row')
    for _, s in ipairs(fl.stmts) do
        if s.parent == head then body[#body + 1] = s.t end
    end
    ok(#body >= 2, 'its body statements are ROWS of their own, not folded into the head: got '
        .. #body .. ' (' .. table.concat(body, ', ') .. ')')
end)

-- CART-0363, ruby. Its control nodes are spelled `if` / `unless` / `while` / `until` /
-- `case` — no `_statement` suffix anywhere — and its region containers are `then` and `do`,
-- not `block`. So ruby opened ZERO control structures: 2219 opaque on rails/activerecord
-- alone, a shipped language with no intra-method control flow in the row model.
local function rb(code)
    local fn, src = parse_fn(code, 'ruby')
    ok(fn, 'the ruby fixture parses to a method')
    return flow.build(fn, src, { ctrl = tsspec.ruby.ctrl, preloop = tsspec.ruby.preloop,
        blocks = tsspec.ruby.blocks,
        body = tsspec.ruby.body, clause = tsspec.ruby.clause,
        body_of = tsspec.ruby.body_of, params_of = tsspec.ruby.params_of,
        pfield = tsspec.ruby.params_field, regime = tsspec.ruby.regime })
end
local function kids_of(fl, head)
    local out = {}
    for _, s in ipairs(fl.stmts) do if s.parent == head then out[#out + 1] = s.t end end
    return out
end
local function head_of(fl, t)
    for i, s in ipairs(fl.stmts) do if (s.t or '') == t then return i end end
end

test('flow: a ruby while opens its body', function ()
    if not ready('ruby') then skip 'no ruby parser' end
    local fl = rb('def f(a)\n  while a\n    g(1)\n    g(2)\n  end\nend')
    local h = head_of(fl, 'while')
    ok(h, 'the while is a row')
    ok(#kids_of(fl, h) >= 2, 'and its two body statements are rows: got '
        .. #kids_of(fl, h) .. ' (' .. table.concat(kids_of(fl, h), ', ') .. ')')
end)

test('flow: a ruby if regions its then-branch, and elsif/else are CLAUSES', function ()
    if not ready('ruby') then skip 'no ruby parser' end
    local fl = rb('def f(a, b)\n  if a\n    g(1)\n    g(2)\n  elsif b\n    g(3)\n'
        .. '  else\n    g(4)\n  end\nend')
    local h = head_of(fl, 'if')
    ok(h, 'the if is a row')
    local pols = {}
    for _, s in ipairs(fl.stmts) do
        if s.parent == h then pols[s.pol or '?'] = (pols[s.pol or '?'] or 0) + 1 end
    end
    ok((pols.body or 0) >= 2, 'the then-branch statements are body rows: ' .. (pols.body or 0))
    ok(head_of(fl, 'elsif'), 'the elsif is its own clause row, not folded into the if')
end)

test('flow: a ruby elsif CHAIN does not stop at the first link', function ()
    if not ready('ruby') then skip 'no ruby parser' end
    -- ★ RUBY NESTS ITS elsif; lua and python make theirs SIBLINGS of the `if`. So the loop
    -- that walks the if's children covers their whole chain and covered exactly one link of
    -- ruby's — everything past the first `elsif` had NO ROWS AT ALL. Measured before the
    -- fix: 4 rows here where python's identical chain produced 7. Found by sampling a
    -- df-parity delta, not by any gate: rows that were never emitted cannot be counted.
    local fl = rb('def f(a, b, c)\n  if a\n    g(1)\n  elsif b\n    g(2)\n'
        .. '  elsif c\n    g(3)\n  else\n    g(4)\n  end\nend')
    local h = head_of(fl, 'if')
    local n_elsif, n_else = 0, 0
    for _, s in ipairs(fl.stmts) do
        if s.t == 'elsif' then n_elsif = n_elsif + 1 end
        if s.pol == 'else' then n_else = n_else + 1 end
    end
    eq(2, n_elsif, 'BOTH elsif guards are rows')
    eq(1, n_else, 'and the else arm survives the chain')
    eq(7, #fl.stmts, 'seven rows, the same as python for the same chain')
    -- FLAT under the if head, which is the shape lua/python produce and successors reads
    for _, s in ipairs(fl.stmts) do
        if s.t == 'elsif' or s.pol == 'else' then
            eq(h, s.parent, 'the chain hangs flat under the if head')
        end
    end
end)

-- ── CART-0363 part B: ATTACHED BLOCKS, the form ruby is actually written in ──────────
-- Measured: activesupport 464 `do…end` + 403 brace blocks, 18% of statements inside one;
-- activerecord 1200 + 708, 20%. Before this a whole block was ONE row — `xs.each do |x|
-- g(x); h(x) end` came back as a single `call` row with use={xs,each,x,g,h} — so the
-- LARGEST single population of ruby statements had no rows at all. And `x` was a USE: the
-- third phantom free variable after the collection-loop variable and the exception variable.
-- ★ THE SUITE IS THE ONLY GATE HERE. There is no ruby generator (CART-0377 installment B),
-- so no synthetic corpus plants these forms and syngate cannot witness one.
local function rowsat(fl, parent)
    local out = {}
    for i, s in ipairs(fl.stmts) do if s.parent == parent then out[#out + 1] = i end end
    return out
end
local function joined(t) return table.concat(t or {}, ',') end

test('flow: a ruby do-block opens its body and BINDS its parameter', function ()
    if not ready('ruby') then skip 'no ruby parser' end
    local fl = rb('def f(xs)\n  xs.each do |x|\n    g(x)\n    h(x)\n  end\nend')
    local h = head_of(fl, 'do_block')
    ok(h, 'the block is a control row of its own')
    eq('x', joined(fl.stmts[h].def), 'and its parameter is a DEF, not a free use')
    eq(2, #rowsat(fl, h), 'its two body statements are rows: ' .. #rowsat(fl, h))
    -- the carrying statement keeps only what IT evaluates
    eq('xs,each', joined(fl.stmts[fl.stmts[h].parent].use),
        'and the call row no longer harvests the whole block')
end)

test('flow: a ruby BRACE block is the same shape as a do-block', function ()
    if not ready('ruby') then skip 'no ruby parser' end
    local fl = rb('def f(xs)\n  q = xs.map { |k, v| k + v }\n  q\nend')
    local h = head_of(fl, 'block')
    ok(h, 'the brace block is a control row')
    eq('k,v', joined(fl.stmts[h].def), 'both parameters bind')
    eq(1, #rowsat(fl, h), 'and its body is a row')
end)

test('flow: a ruby block with NO parameters binds nothing and still opens', function ()
    if not ready('ruby') then skip 'no ruby parser' end
    local fl = rb('def f(o)\n  o.tap { g(1) }\nend')
    local h = head_of(fl, 'block')
    ok(h, 'the block opens')
    eq('', joined(fl.stmts[h].def), 'and defs nothing')
    eq(1, #rowsat(fl, h), 'its body statement is a row')
end)

test('flow: a ruby DESTRUCTURING parameter binds EVERY name in it', function ()
    if not ready('ruby') then skip 'no ruby parser' end
    -- `b` used to be dropped (the wrapper rule takes the first identifier and stops), which
    -- left it a free use — the very defect class this ticket is about, one level down.
    local fl = rb('def f(xs)\n  xs.each_with_object({}) do |(a, b), memo|\n'
        .. '    memo[a] = b\n  end\nend')
    local h = head_of(fl, 'do_block')
    ok(h, 'the block opens')
    eq('a,b,memo', joined(fl.stmts[h].def), 'a, b AND memo all bind')
end)

test('flow: a ruby block parameter DEFAULT is read, while its name binds', function ()
    if not ready('ruby') then skip 'no ruby parser' end
    local fl = rb('def f(xs)\n  xs.each do |w = ff(zz)|\n    g(w)\n  end\nend')
    local h = head_of(fl, 'do_block')
    ok(h, 'the block opens')
    eq('w', joined(fl.stmts[h].def), 'the parameter binds')
    eq('ff,zz', joined(fl.stmts[h].use), 'and its default expression is genuinely READ')
end)

test('flow: a block on an ASSIGNMENT RHS is found — it is not a field of the row', function ()
    if not ready('ruby') then skip 'no ruby parser' end
    -- the block hangs off a `call` nested under the assignment, so nothing on the ROW's own
    -- node names it. du finds it on the walk it was already making.
    local fl = rb('def f(xs)\n  q = xs.map do |k|\n    k + 1\n  end\n  q\nend')
    local h = head_of(fl, 'do_block')
    ok(h, 'the nested block still opens')
    local p = fl.stmts[h].parent
    ok(p and p > 0 and joined(fl.stmts[p].def) == 'q',
        'and its parent is the assignment row: def=' .. joined(fl.stmts[p] and fl.stmts[p].def))
end)

test('flow: a block inside a CONDITION is emitted before the body it guards', function ()
    if not ready('ruby') then skip 'no ruby parser' end
    local fl = rb('def f(xs)\n  if xs.any? { |e| e > 1 }\n    r = 1\n  end\n  r\nend')
    local h = head_of(fl, 'if')
    local b = head_of(fl, 'block')
    ok(h and b, 'both the if and the block are rows')
    eq(h, fl.stmts[b].parent, 'the block hangs under the if head')
    local body
    for i, s in ipairs(fl.stmts) do
        if s.parent == h and s.pol == 'body' and s.t ~= 'block' then body = body or i end
    end
    ok(body and b < body, 'and precedes the consequence: a condition runs first')
end)

test('flow: rescue/ensure INSIDE a block still get clause rows', function ()
    if not ready('ruby') then skip 'no ruby parser' end
    local fl = rb('def f(xs)\n  xs.each do |v|\n    begin\n      t = 1\n'
        .. '    rescue E => er\n      u = 2\n    end\n  end\nend')
    local h = head_of(fl, 'do_block')
    ok(h, 'the block opens')
    local c
    for i, s in ipairs(fl.stmts) do if s.kind == 'catch' then c = i end end
    ok(c, 'the rescue is a catch row inside the block')
    eq('er', joined(fl.stmts[c].def), 'and still binds its exception variable')
end)

test('flow: NESTED blocks nest, and the inner one binds its own parameter', function ()
    if not ready('ruby') then skip 'no ruby parser' end
    local fl = rb('def f(as, bs)\n  as.each do |a1|\n    bs.each do |b1|\n'
        .. '      c1 = a1 + b1\n    end\n  end\nend')
    local heads = {}
    for i, s in ipairs(fl.stmts) do if s.t == 'do_block' then heads[#heads + 1] = i end end
    eq(2, #heads, 'two block rows')
    local inner = fl.stmts[heads[2]]
    ok(inner.parent > heads[1], 'the inner block hangs below the outer one')
    eq('b1', joined(inner.def), 'and binds its own parameter')
end)

test('flow: a ruby block is a PRE-condition loop — the back edge is present', function ()
    if not ready('ruby') then skip 'no ruby parser' end
    -- ★ THE MODELLING DECISION, fenced. A plain region would claim exactly-once, which is
    -- UNSOUND for `each` (0..n) exactly as a missing back edge was for js for-of. Pre-loop
    -- covers `each`, `tap` (once) and `lambda` (deferred) alike: the zero-trip skip admits
    -- "never ran", the back edge admits "ran many times".
    local fl = rb('def f(xs)\n  xs.each do |x|\n    g(x)\n  end\nend')
    local h = head_of(fl, 'do_block')
    ok(fl.preloop['do_block'], 'the record carries do_block as a PRE-condition loop')
    ok(flow.loops_of(fl)['do_block'], 'and loops_of — the one owner — agrees')
    local cfg = flow.successors(fl)
    local back, skip = false, false
    for i = h + 1, #fl.stmts do
        for _, s in ipairs(cfg.succ[i] or {}) do if s == h then back = true end end
    end
    for _, s in ipairs(cfg.succ[h] or {}) do
        if s ~= h + 1 then skip = true end -- past the body: the block may never run
    end
    ok(back, 'a body row wires back to the head (the loop may run again)')
    ok(skip, 'and the head can skip the body entirely (an empty collection)')
end)


-- CART-0363, cpp + java. The remaining `*_statement`-shaped blind spots, found by
-- tools/ctrlcensus.lua asking the tree STRUCTURALLY which region-containing nodes flow does
-- not classify. Unlike ruby these go in the BASE sets: the node names are unique to their
-- language among the ones we support, which is the criterion flow already documents for
-- rust — and a base entry reaches all three cfg constructions without a threading hazard.
local function jflow(code)
    local fn, src = parse_fn(code, 'java')
    ok(fn, 'the java fixture parses to a method')
    return flow.build(fn, src, { regime = tsspec.java.regime })
end

test('flow: a java enhanced-for opens its body and drops its header parts', function ()
    if not ready('java') then skip 'no java parser' end
    local fl = jflow('class C { void f(java.util.List<String> xs) {\n'
        .. '  for (String s : xs) { g(s); h(s); }\n} }')
    local h = head_of(fl, 'enhanced_for_statement')
    ok(h, 'the enhanced-for is a control row')
    local kids = kids_of(fl, h)
    ok(#kids == 2, 'exactly its two body statements are rows: got ' .. #kids
        .. ' (' .. table.concat(kids, ', ') .. ')')
    -- ★ AND NOT ITS HEADER. `type`/`name`/`value` are fielded children; the body fallback
    -- would emit them as rows that appear to execute each iteration.
    for _, t in ipairs(kids) do
        ok(t ~= 'identifier' and t ~= 'type_identifier',
            'a header part must not be a body row: ' .. t)
    end
end)

test('flow: a java SWITCH opens at all — it was 100% opaque', function ()
    if not ready('java') then skip 'no java parser' end
    -- ★ THE SPELLING IS `switch_expression` EVEN AS A STATEMENT, and its container is
    -- `switch_block`, not `block`. Both had to be found by probing the grammar: a census
    -- that asks "contains a recognised region" cannot see a node whose region spelling is
    -- ALSO unrecognised, which is the same blind spot that hid ruby's `then`/`do`.
    local fl = jflow('class C { void f(int x) {\n'
        .. '  switch (x) { case 1: g(); break; default: h(); }\n} }')
    local h = head_of(fl, 'switch_expression')
    ok(h, 'the switch is a control row')
    local ncase, nstmt = 0, 0
    for _, s in ipairs(fl.stmts) do
        if s.kind == 'case' then ncase = ncase + 1 end
        if (s.t or '') == 'expression_statement' then nstmt = nstmt + 1 end
    end
    eq(2, ncase, 'both arms are CASE rows (case 1 + default)')
    ok(nstmt >= 2, 'and the statements inside them are rows of their own: ' .. nstmt)
    -- the label is the case row's own use, NOT a statement row of its own
    for _, s in ipairs(fl.stmts) do
        ok((s.t or '') ~= 'switch_label', 'a switch_label does not execute, so it is no row')
    end
end)

test('flow: a java ARROW switch opens each rule, block-bodied or not', function ()
    if not ready('java') then skip 'no java parser' end
    -- 82 of 92 switch_rules in the elasticsearch sample are EXPRESSION-bodied, so the
    -- block-bodied form alone would not exercise the common case
    local fl = jflow('class C { void f(int x) {\n'
        .. '  switch (x) { case 1 -> g(); case 2 -> { h(); i(); } default -> j(); }\n} }')
    ok(head_of(fl, 'switch_expression'), 'the arrow switch is a control row')
    local ncase = 0
    for _, s in ipairs(fl.stmts) do if s.kind == 'case' then ncase = ncase + 1 end end
    eq(3, ncase, 'all three rules are CASE rows')
end)

test('flow: java try-with-resources acquires BEFORE the head, and keeps its catch', function ()
    if not ready('java') then skip 'no java parser' end
    local fl = jflow('class C { void f() {\n'
        .. '  try (Res r = open()) { use(r); } catch (E e) { log(e); }\n} }')
    local h = head_of(fl, 'try_with_resources_statement')
    ok(h, 'the try-with-resources is a control row')
    -- ★ THE RESOURCE IS NOT A HEADER PART TO DROP: it DEFINES `r`. It is emitted before the
    -- head, exactly like a three-part for's init, so the def survives and is ordered right.
    local res
    for i, s in ipairs(fl.stmts) do
        if (s.t or '') == 'resource_specification' then res = i end
    end
    ok(res and res < h, 'the resource acquisition is a row BEFORE the head (def of r kept)')
    -- a catch row is keyed by KIND ('catch'), not by its raw node type
    local ncatch = 0
    for _, s in ipairs(fl.stmts) do if s.kind == 'catch' then ncatch = ncatch + 1 end end
    eq(1, ncatch, 'and the catch is still its own clause row')
end)

test('flow: a java synchronized block opens its body', function ()
    if not ready('java') then skip 'no java parser' end
    local fl = jflow('class C { void f(Object lock) {\n'
        .. '  synchronized (lock) { crit(); more(); }\n} }')
    local h = head_of(fl, 'synchronized_statement')
    ok(h, 'the synchronized statement is a control row')
    eq(2, #kids_of(fl, h), 'its two body statements are rows, and the lock expression is not')
end)

test('flow: a cpp range-for opens its body', function ()
    if not ready('cpp') then skip 'no cpp parser' end
    local fn, src = parse_fn('void f(std::vector<int> &v) {\n'
        .. '  for (auto &x : v) { g(x); h(x); }\n}', 'cpp')
    ok(fn, 'the cpp fixture parses to a function')
    local fl = flow.build(fn, src, { regime = tsspec.cpp.regime })
    local h = head_of(fl, 'for_range_loop')
    ok(h, 'the range-for is a control row')
    eq(2, #kids_of(fl, h), 'its two body statements are rows, its header parts are not')
end)

-- ★ THE FENCE THAT KEEPS THIS HONEST. A pre-condition loop must be marked PRELOOP or the
-- CFG wires no zero-trip edge — the "opened but no better" failure ruby taught us, one
-- layer down. Asked through flow.classes(), the single owner, never a second copy.
test('flow: the new loop forms are PRE-condition (a zero-trip skip is feasible)', function ()
    local cls = flow.classes({})
    for _, t in ipairs { 'for_range_loop', 'enhanced_for_statement' } do
        ok(cls.ctrl[t], t .. ' is a control statement')
        ok(cls.preloop[t], t .. ' tests BEFORE the body — an empty collection skips it')
    end
    ok(cls.ctrl.synchronized_statement, 'synchronized is control')
    ok(not cls.preloop.synchronized_statement,
        'but NOT a loop — it runs once, unconditionally')
    ok(cls.body.switch_block, "java's switch container is a region, not a leaf")
end)

-- ★ CART-0363. A COLLECTION LOOP BINDS ITS LOOP VARIABLE. Found by probing the head row's
-- def/use rather than its shape — the structural tests above all passed while every one of
-- these forms reported `def={} use={s,xs}`, a READ of a variable nothing defines. js for-of
-- had SHIPPED that way in part A. The three-part `for` beside them was correct, which is
-- why it hid, and dfparity structurally cannot catch it: its per-statement def/use check
-- only runs when the coarse counts match, and they do not for these very functions.
test('flow: a collection loop DEFS its loop variable, in every language that has one', function ()
    local CASES = {
        { lang = 'java', t = 'enhanced_for_statement', var = 's', iter = 'xs',
          src = 'class C { void f(java.util.List<String> xs) { for (String s : xs) { g(s); } } }',
          cfg = function () return { regime = tsspec.java.regime } end },
        { lang = 'cpp', t = 'for_range_loop', var = 'x', iter = 'v',
          src = 'void f(std::vector<int> &v) { for (auto &x : v) { g(x); } }',
          cfg = function () return { regime = tsspec.cpp.regime } end },
        { lang = 'javascript', t = 'for_in_statement', var = 'x', iter = 'xs',
          src = 'function f(xs) { for (const x of xs) { g(x); } }',
          cfg = function () return { ctrl = tsspec.javascript.ctrl,
              preloop = tsspec.javascript.preloop, regime = tsspec.javascript.regime } end },
    }
    for _, c in ipairs(CASES) do
        if ready(c.lang) then
            local fn, src = parse_fn(c.src, c.lang)
            local fl = flow.build(fn, src, c.cfg())
            local head
            for i, s in ipairs(fl.stmts) do if (s.t or '') == c.t then head = i end end
            ok(head, c.lang .. ': the loop is a row')
            if head then
                local s = fl.stmts[head]
                local d, u = {}, {}
                for _, n in ipairs(s.def or {}) do d[n] = true end
                for _, n in ipairs(s.use or {}) do u[n] = true end
                ok(d[c.var], ('%s: `%s` is a DEF (the loop BINDS it) — got def={%s}')
                    :format(c.lang, c.var, table.concat(s.def or {}, ',')))
                ok(not u[c.var], c.lang .. ': and NOT also a free use of an outer name')
                ok(u[c.iter], ('%s: the iterated collection `%s` stays a use')
                    :format(c.lang, c.iter))
            end
        end
    end
end)

-- ★ CART-0363. A LOOP READ BACK FROM THE STORE MUST STILL BE A LOOP. Extraction persists
-- `flow = { stmts, params }` only, so the per-language sets M.build merged were LOST, and
-- PRELOOP_OF fell through to the base table — a js `for…of` off the store had NO BACK EDGE
-- from its body to its head, while a `while` beside it did. Missing a back edge is unsound,
-- not imprecise: reaching and liveness then believe a def in the body never reaches the next
-- iteration. flow.record now DERIVES the classes from the node's language.
test('flow: a stored record still classifies a SPEC-added pre-condition loop', function ()
    if not ready('javascript') then skip 'no javascript parser' end
    local tsp = require 'cartograph.providers.treesitter'
    local store = require 'cartograph.store'
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/a.js', 'w'))
    fd:write('function f(xs) {\n  before();\n  for (const x of xs) {\n    g(x);\n  }\n  after();\n}\n')
    fd:close()
    store.ingest(tsp.extract(root))
    local seen = false
    for _, n in ipairs(store.data.nodes) do
        if flow.present(n) and n.name == 'f' then
            seen = true
            local fl = flow.record(n)
            ok(fl.preloop, 'the record read back from the store carries its language classes')
            ok(fl.preloop and fl.preloop.for_in_statement,
                'including the SPEC-added for-of, which the base table does not have')
            local cfg = flow.successors(fl)
            local head
            for i, s in ipairs(fl.stmts) do if (s.t or '') == 'for_in_statement' then head = i end end
            local body
            for i, s in ipairs(fl.stmts) do if s.parent == head then body = body or i end end
            ok(head and body, 'the loop and its body are rows')
            local back = false
            for _, x in ipairs(cfg.succ[body] or {}) do if x == head then back = true end end
            ok(back, 'and the body has a BACK EDGE to the head — it is a loop in the CFG too')
        end
    end
    ok(seen, 'the fixture extracted a function with flow')
    vim.fn.delete(root, 'rf')
end)

-- ★ CART-0382. THE CFG PHASES READ BASE SETS THE SPEC SEAM NEVER REACHED. `M.successors` is
-- a SEPARATE function from `M.build`, and it matched IF-shaped control against a base
-- `IF_T = { if_statement, if_expression }`. Ruby's is spelled `if` / `unless`, so it never
-- matched and fell to the generic branch, which adds an edge to every child AND to the next
-- statement — claiming control could skip BOTH arms of an if/else. Sound (an
-- over-approximation) but false, and optapply's PRE rests on exactly that exhaustiveness.
-- The role now lives ON `ctrl` as a MAP value, so `ifs ⊆ ctrl` holds by construction.
local function rb_succ(code)
    local fn, src = parse_fn(code, 'ruby')
    ok(fn, 'the ruby fixture parses to a method')
    local fl = flow.build(fn, src, { ctrl = tsspec.ruby.ctrl, preloop = tsspec.ruby.preloop,
        blocks = tsspec.ruby.blocks,
        body = tsspec.ruby.body, clause = tsspec.ruby.clause,
        body_of = tsspec.ruby.body_of, params_of = tsspec.ruby.params_of,
        regime = tsspec.ruby.regime })
    return fl, flow.successors(fl)
end

test('flow: a ruby if/else is EXHAUSTIVE — no edge skipping both arms', function ()
    if not ready('ruby') then skip 'no ruby parser' end
    local fl, cfg = rb_succ('def f(a)\n  before\n  if a\n    g(1)\n  else\n    g(2)\n  end\n  after\nend')
    local h = head_of(fl, 'if')
    ok(h, 'the if is a control row')
    -- the row AFTER the if at top level: control must reach it only THROUGH an arm
    local after
    for i, s in ipairs(fl.stmts) do if i > h and s.parent == 0 then after = after or i end end
    ok(after, 'there is a statement after the if')
    local skips = false
    for _, x in ipairs(cfg.succ[h] or {}) do if x == after then skips = true end end
    ok(not skips, 'an if WITH an else cannot fall through: succ={'
        .. table.concat(cfg.succ[h] or {}, ',') .. '}')
    eq(2, #(cfg.succ[h] or {}), 'exactly the two arms')
end)

test('flow: a ruby if with NO else still falls through, and an elsif carries it', function ()
    if not ready('ruby') then skip 'no ruby parser' end
    -- ★ THE CASE THE FIX COULD SILENTLY BREAK. Withholding the skip edge is only correct
    -- when a false arm EXISTS; with none, the condition must still reach the next statement.
    local fl, cfg = rb_succ('def f(a)\n  before\n  if a\n    g(1)\n  end\n  after\nend')
    local h = head_of(fl, 'if')
    local after
    for i, s in ipairs(fl.stmts) do if i > h and s.parent == 0 then after = after or i end end
    local falls = false
    for _, x in ipairs(cfg.succ[h] or {}) do if x == after then falls = true end end
    ok(falls, 'no else → the condition may skip the body: succ={'
        .. table.concat(cfg.succ[h] or {}, ',') .. '}')

    -- and with an elsif but no else, the fall-through routes THROUGH the elsif guard
    local fl2, cfg2 = rb_succ('def f(a, b)\n  before\n  if a\n    g(1)\n  elsif b\n    g(2)\n  end\n  after\nend')
    local h2, e2 = head_of(fl2, 'if'), head_of(fl2, 'elsif')
    ok(h2 and e2, 'both the if and the elsif are rows')
    eq('elseif', fl2.stmts[e2].pol, 'the elsif is the if\'s FALSE arm, by pol')
    local reaches = false
    for _, x in ipairs(cfg2.succ[h2] or {}) do if x == e2 then reaches = true end end
    ok(reaches, 'the if reaches the elsif guard')
    ok(#(cfg2.succ[e2] or {}) >= 2, 'and the elsif itself carries the fall-through: succ={'
        .. table.concat(cfg2.succ[e2] or {}, ',') .. '}')
end)

test('flow: the ctrl ROLE map keeps ifs a subset of ctrl, by construction', function ()
    local cls = flow.classes({ ctrl = { myif = 'if', myplain = true } })
    ok(cls.ifs.myif, 'a role-tagged entry joins the IF class')
    ok(cls.ctrl.myif and cls.ctrl.myplain, 'and BOTH remain control statements')
    ok(not cls.ifs.myplain, 'a plain entry does not')
    for t in pairs(cls.ifs) do
        ok(cls.ctrl[t], t .. ' is in ifs, so it must also be in ctrl — no drift pair')
    end
    -- the base classes are untouched when a language declares nothing
    ok(flow.classes({}).ifs.if_statement, 'the base IF set survives an empty cfg')
end)

-- ★ CART-0386. RUBY begin/rescue/ensure WAS 100% OPAQUE: `kind=stmt`, the whole block one
-- row, body and handler with no rows at all — so no exception edge, no handler entry, and
-- nothing inside visible to reaching, liveness, taint or any lint. 187 sites in
-- activerecord/lib, 632 in discourse/app. And BOTH census modes were blind to it: --coverage
-- reports only forms flow already classifies, and the gap census needs a RECOGNISED REGION
-- child, which `begin`'s direct-statement children are not.
test('flow: a ruby begin/rescue opens, and its handler is reachable from the body', function ()
    if not ready('ruby') then skip 'no ruby parser' end
    local fl, cfg = rb_succ('def f(a)\n  begin\n    g(a)\n  rescue ArgumentError => e\n'
        .. '    h(e)\n  end\nend')
    local h = head_of(fl, 'begin')
    ok(h, 'the begin is a CONTROL row, not a folded statement')
    local body, catch
    for i, s in ipairs(fl.stmts) do
        if s.parent == h and s.pol == 'body' then body = body or i end
        if s.kind == 'catch' then catch = i end
    end
    ok(body, 'its body statements are rows of their own')
    ok(catch, 'and the rescue is a catch row')
    -- the exception edge: a raise may happen at any body point, so the handler is reachable
    local reaches = false
    for _, x in ipairs(cfg.succ[body] or {}) do if x == catch then reaches = true end end
    ok(reaches, 'the handler is reachable FROM the body: succ={'
        .. table.concat(cfg.succ[body] or {}, ',') .. '}')
end)

test('flow: `rescue E => e` BINDS e — it is a def, not a read of nothing', function ()
    if not ready('ruby') then skip 'no ruby parser' end
    -- the same defect class as the collection-loop variable (CART-0363): a binder the
    -- grammar spells its own way, which du classed as a use.
    local fl = rb_succ('def f(a)\n  begin\n    g(a)\n  rescue ArgumentError => e\n'
        .. '    h(e)\n  end\nend')
    local catch
    for i, s in ipairs(fl.stmts) do if s.kind == 'catch' then catch = i end end
    ok(catch, 'the rescue is a catch row')
    local d = {}
    for _, n in ipairs(fl.stmts[catch].def or {}) do d[n] = true end
    ok(d.e, 'the exception variable is a DEF — got def={'
        .. table.concat(fl.stmts[catch].def or {}, ',') .. '}')
    local u = {}
    for _, n in ipairs(fl.stmts[catch].use or {}) do u[n] = true end
    ok(not u.e, 'and not also a free use of an outer name')
end)

test('flow: a ruby `ensure` is the FINALLY pol, named by the clause map not by spelling',
function ()
    if not ready('ruby') then skip 'no ruby parser' end
    -- ★ `ensure` contains no substring the name-based pol fallback could match, so without a
    -- declared role it landed as a generic 'clause' and successors' TRY branch routed it as
    -- an ordinary sibling instead of the normal-completion path.
    local fl = rb_succ('def f(a)\n  begin\n    g(a)\n  rescue => e\n    h(e)\n  else\n'
        .. '    k(1)\n  ensure\n    z(1)\n  end\n  after\nend')
    local pols = {}
    for _, s in ipairs(fl.stmts) do if s.pol then pols[s.pol] = (pols[s.pol] or 0) + 1 end end
    ok((pols.finally or 0) >= 1, 'the ensure body is a `finally` row: pols = '
        .. vim.inspect(pols))
    ok((pols.catch or 0) >= 1, 'the rescue body is a `catch` row')
    ok((pols['else'] or 0) >= 1, 'and the else arm keeps its own pol')
end)

test('flow: a TRY head evaluates nothing — a container is not a computation', function ()
    if not ready('ruby') then skip 'no ruby parser' end
    -- ruby's `begin` hangs its body statements DIRECTLY (no block node), so du walked them
    -- and the head row claimed to def the exception variable and read every name inside.
    local fl = rb_succ('def f(a)\n  begin\n    g(a)\n  rescue => e\n    h(e)\n  end\nend')
    local h = head_of(fl, 'begin')
    eq(0, #(fl.stmts[h].def or {}), 'the begin head defs nothing')
    eq(0, #(fl.stmts[h].use or {}), 'and uses nothing: use={'
        .. table.concat(fl.stmts[h].use or {}, ',') .. '}')
end)

-- ★ CART-0383. ONE ANSWER TO "IS THIS A LOOP". Four modules each held a private LOOPISH
-- table — exprlint, optapply, optimize, untangle — and every PAIR of them disagreed
-- (loop_expression; for_numeric/for_generic_statement; foreach_statement). None knew the
-- forms flow had opened, so flow opened loops that LICM, CSE, the expression lints and
-- untangle could not see. And all four carried `loop_statement`, which NO grammar we support
-- spells — a phantom copied from set to set, which is the tell that they were duplicated
-- rather than derived.
test('flow: loops_of is language-aware, and the phantom is gone', function ()
    local base = flow.loops_of(nil)
    ok(base.while_statement and base.for_statement and base.repeat_statement,
        'the base answer covers the common spellings')
    ok(not base.loop_statement,
        'loop_statement is in NO grammar we support — it must not be in the answer')
    -- the forms this session opened are loops to every consumer, not just to flow
    for _, t in ipairs { 'enhanced_for_statement', 'for_range_loop', 'for_expression',
                         'while_expression' } do
        ok(base[t], t .. ' is a loop — it was in none of the four private tables')
    end
    -- ★ do_statement is EXCLUDED on purpose: C spells do-while that way and lua spells a
    -- plain `do…end` BLOCK that way, and only the presence of a condition tells them apart —
    -- a question about the NODE, not the type. A set keyed by type must not pretend to answer.
    ok(not base.do_statement, 'do_statement is ambiguous by TYPE, so it is not in the set')

    local ts_ = require 'cartograph.providers.treesitter'
    local js = flow.classes(ts_.spec.javascript or {}).loops
    ok(js.for_in_statement, 'js for-of/for-in is a loop, via the spec')
    ok(not base.for_in_statement, 'and it is NOT in the base answer — the set is per LANGUAGE')
    local rb = flow.classes(ts_.spec.ruby or {}).loops
    ok(rb['while'] and rb['until'] and rb['for'], 'ruby\'s own spellings are loops too')
end)

-- ★ CART-0387. A ruby `case`: its SUBJECT and its `when` PATTERNS do not execute, and a case
-- with an `else` is EXHAUSTIVE. Three defects in one construct, each a different mechanism.
test('flow: a ruby case does not emit its subject or its patterns as statements', function ()
    if not ready('ruby') then skip 'no ruby parser' end
    local fl = rb_succ('def f(a)\n  case a\n  when 1, 2\n    g(1)\n  else\n    g(2)\n  end\nend')
    for _, s in ipairs(fl.stmts) do
        ok((s.t or '') ~= 'pattern',
            'a `when` PATTERN does not execute, so it is not a row')
    end
    -- the subject `a` is the head's condition, so it is a USE of the case row and not an
    -- `identifier` body row of its own
    local h = head_of(fl, 'case')
    ok(h, 'the case is a control row')
    local kids = kids_of(fl, h)
    for _, t in ipairs(kids) do
        ok(t ~= 'identifier', 'the switched subject is not a body statement: got ' .. t)
    end
    local u = {}
    for _, n in ipairs(fl.stmts[h].use or {}) do u[n] = true end
    ok(u.a, 'it is a USE on the head instead: use={'
        .. table.concat(fl.stmts[h].use or {}, ',') .. '}')
end)

test('flow: a ruby case WITH an else is exhaustive; without one it falls through', function ()
    if not ready('ruby') then skip 'no ruby parser' end
    -- ★ ruby's `case` never reached the SWITCH branch of successors (base-set again), so it
    -- fell to the generic one -- which also passes `brk` THROUGH, meaning a `break` inside a
    -- ruby case escaped to the ENCLOSING LOOP rather than the switch join.
    local fl, cfg = rb_succ('def f(a)\n  before\n  case a\n  when 1\n    g(1)\n  else\n'
        .. '    g(2)\n  end\n  after\nend')
    local h = head_of(fl, 'case')
    local after
    for i, s in ipairs(fl.stmts) do if i > h and s.parent == 0 then after = after or i end end
    ok(h and after, 'the case and the statement after it are rows')
    local skips = false
    for _, x in ipairs(cfg.succ[h] or {}) do if x == after then skips = true end end
    ok(not skips, 'an else arm makes it exhaustive — no skip edge: succ={'
        .. table.concat(cfg.succ[h] or {}, ',') .. '}')

    local fl2, cfg2 = rb_succ('def f(a)\n  before\n  case a\n  when 1\n    g(1)\n  end\n'
        .. '  after\nend')
    local h2 = head_of(fl2, 'case')
    local after2
    for i, s in ipairs(fl2.stmts) do if i > h2 and s.parent == 0 then after2 = after2 or i end end
    local falls = false
    for _, x in ipairs(cfg2.succ[h2] or {}) do if x == after2 then falls = true end end
    ok(falls, 'with NO else, no arm need match, so it still falls through')
end)

test('flow: the switch class is language-aware, and `pattern` is NOT a base name', function ()
    local ts_ = require 'cartograph.providers.treesitter'
    local rb = flow.classes(ts_.spec.ruby or {})
    ok(rb.switch['case'], "ruby's `case` carries the switch role")
    ok(flow.classes({}).switch.switch_statement, 'and the base spellings survive')
    ok(not flow.classes({}).switch['case'], 'but `case` is NOT base — it is per language')
    -- ★ `pattern` is in SIX grammars (js/ts/tsx/python/java/haskell), so the case label is
    -- read from the FIELD, never from that type name. This asserts the intent, since a base
    -- set keyed on it would silently reach five languages that never asked.
    for _, cls in ipairs { flow.classes({}), rb } do
        ok(not cls.clause.pattern, '`pattern` must never be a clause type')
        ok(not cls.ctrl.pattern, '`pattern` must never be a control type')
    end
end)

-- ★ CART-0390. JS/TS SWITCH BODIES WERE 100% OPAQUE — java's situation before CART-0363, one
-- language over. js spells it `switch_statement > switch_body > switch_case / switch_default`
-- and flow classified none of the three, so the body was emitted by the generic fallback as
-- ONE plain row and every statement inside folded into it: a two-arm switch with four
-- statements produced exactly TWO rows.
test('flow: a js switch opens its arms, and their statements are rows', function ()
    if not ready('javascript') then skip 'no javascript parser' end
    local fn, src = parse_fn('function f(a) {\n  switch (a) {\n    case 1: g(1); h(1); break;\n'
        .. '    default: g(2);\n  }\n}', 'javascript')
    local fl = flow.build(fn, src, { ctrl = tsspec.javascript.ctrl,
        preloop = tsspec.javascript.preloop, body = tsspec.javascript.body,
        clause = tsspec.javascript.clause, regime = tsspec.javascript.regime })
    local h = head_of(fl, 'switch_statement')
    ok(h, 'the switch is a control row')
    local ncase, nstmt = 0, 0
    for _, s in ipairs(fl.stmts) do
        if s.kind == 'case' then ncase = ncase + 1 end
        if (s.t or '') == 'expression_statement' then nstmt = nstmt + 1 end
    end
    eq(2, ncase, 'both arms are case rows (the case and the default)')
    eq(3, nstmt, 'and all three statements inside them are rows of their own')
    for _, s in ipairs(fl.stmts) do
        ok((s.t or '') ~= 'switch_body',
            'the switch BODY is a region, not a statement row that swallows the arms')
    end
end)

test('flow: a DEFAULT arm is the one with no label, in every language', function ()
    if not ready('javascript') then skip 'no javascript parser' end
    -- ★ The CASE branch used to stamp pol='case' on EVERY arm, so a C/java/php `default:` was
    -- indistinguishable from a case arm and the exhaustiveness rule could not fire for those
    -- languages at all. A default arm is decidable without another name set: it carries no
    -- `value`, no `pattern` and no label child.
    local fn, src = parse_fn('function f(a) {\n before();\n switch (a) {\n  case 1: g(1); break;\n'
        .. '  default: g(2);\n }\n after();\n}', 'javascript')
    local cfg_ = { ctrl = tsspec.javascript.ctrl, preloop = tsspec.javascript.preloop,
        body = tsspec.javascript.body, clause = tsspec.javascript.clause,
        regime = tsspec.javascript.regime }
    local fl = flow.build(fn, src, cfg_)
    local pols = {}
    for _, s in ipairs(fl.stmts) do if s.kind == 'case' then pols[s.pol or '?'] = true end end
    ok(pols['case'] and pols['default'],
        'the labelled arm is `case` and the unlabelled one is `default`')

    -- and that is what makes the switch exhaustive: no edge past it
    local succ = flow.successors(fl).succ
    local h = head_of(fl, 'switch_statement')
    local after
    for i, s in ipairs(fl.stmts) do if i > h and s.parent == 0 then after = after or i end end
    local skips = false
    for _, x in ipairs(succ[h] or {}) do if x == after then skips = true end end
    ok(not skips, 'a switch WITH a default cannot be skipped: succ={'
        .. table.concat(succ[h] or {}, ',') .. '}')

    -- without a default it must still fall through
    local fn2, src2 = parse_fn('function f(a) {\n before();\n switch (a) {\n  case 1: g(1); break;\n }\n'
        .. ' after();\n}', 'javascript')
    local fl2 = flow.build(fn2, src2, cfg_)
    local succ2 = flow.successors(fl2).succ
    local h2 = head_of(fl2, 'switch_statement')
    local after2
    for i, s in ipairs(fl2.stmts) do if i > h2 and s.parent == 0 then after2 = after2 or i end end
    local falls = false
    for _, x in ipairs(succ2[h2] or {}) do if x == after2 then falls = true end end
    ok(falls, 'with no default, no arm need match, so it still falls through')
end)

test('flow: the js switch spelling stays in the SPEC — switch_case is zig and odin too', function ()
    local ts_ = require 'cartograph.providers.treesitter'
    ok(ts_.spec.javascript.body.switch_body, 'js declares its own body spelling')
    ok(ts_.spec.javascript.clause.switch_case, 'and its own arm spelling')
    -- ★ NOT a base entry: `switch_case` is ALSO zig and odin (checked across all 17 grammars),
    -- so a base set would have silently re-modelled two other languages' switches. Same
    -- lesson as `pattern`, which is in six.
    ok(not flow.classes({}).clause.switch_case, 'switch_case is NOT in the base clause set')
    ok(not flow.classes({}).body.switch_body, 'switch_body is NOT in the base body set')
    ok(flow.classes(ts_.spec.typescript or {}).clause.switch_case, 'typescript inherits it')
end)

-- ★ CART-0363. `du`'s stop_body read the BASE body/clause tables, not the merged per-language
-- ones, so it walked STRAIGHT THROUGH a region whose spelling the spec had supplied. Measured:
-- a ruby `if` head reported def={zz} use={a,q,w} — its ENTIRE BODY harvested onto the head row
-- — where js's correctly read use={a}. Every ruby control row's def/use was inflated with its
-- whole subtree, which is also why the `try` head needed zeroing by hand in CART-0386: that
-- was the symptom, this is the cause. The FIFTH consumer found holding a base set the spec
-- never reached, after PRELOOP, IF_T, TRY_T and CATCH.
test('flow: a control head evaluates its CONDITION, not its body — in every language', function ()
    if not (ready('ruby') and ready('javascript')) then skip 'no ruby/js parser' end
    local rbfl = rb_succ('def f(a)\n  if a\n    zz = q(1)\n    w(zz)\n  end\nend')
    local h = head_of(rbfl, 'if')
    ok(h, 'the ruby if is a control row')
    eq(0, #(rbfl.stmts[h].def or {}),
        'the head defs NOTHING — `zz` belongs to the body: def={'
        .. table.concat(rbfl.stmts[h].def or {}, ',') .. '}')
    local u = {}
    for _, n in ipairs(rbfl.stmts[h].use or {}) do u[n] = true end
    ok(u.a, 'it uses its condition')
    ok(not u.q and not u.w, 'and NOT the callees inside its body: use={'
        .. table.concat(rbfl.stmts[h].use or {}, ',') .. '}')

    -- the js twin, which was always correct because its region spelling is in the base set
    local fn, src = parse_fn('function f(a) {\n if (a) {\n  const zz = q(1);\n  w(zz);\n }\n}',
        'javascript')
    local jsfl = flow.build(fn, src, { ctrl = tsspec.javascript.ctrl,
        preloop = tsspec.javascript.preloop, body = tsspec.javascript.body,
        clause = tsspec.javascript.clause, regime = tsspec.javascript.regime })
    local jh = head_of(jsfl, 'if_statement')
    eq(#(jsfl.stmts[jh].use or {}), #(rbfl.stmts[h].use or {}),
        'ruby and js now agree on how much a control head evaluates')
end)

test('flow: an ASSIGNMENT IN THE CONDITION still defs on the head', function ()
    if not ready('ruby') then skip 'no ruby parser' end
    -- the case the fix could have broken: stopping at the BODY must not stop at the CONDITION
    local fl = rb_succ('def f(message)\n  if match = message.match(/x/)\n    match[1]\n  end\nend')
    local h = head_of(fl, 'if')
    local d, u = {}, {}
    for _, n in ipairs(fl.stmts[h].def or {}) do d[n] = true end
    for _, n in ipairs(fl.stmts[h].use or {}) do u[n] = true end
    ok(d.match, '`match` is bound BY THE CONDITION, so the head defs it')
    ok(u.message, 'and the condition\'s receiver is a use')
end)
