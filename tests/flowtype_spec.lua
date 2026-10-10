-- cartograph.flowtype — WHAT VALUE REACHES A RECEIVER, BY FLOW (CART-1621). An inclusion points-to analysis: the
-- functions / tables / types that flow to an AMBIGUOUS call's receiver decide it — one function (exact, possibly one
-- the name join never listed), a type (string), or nothing claimed when an unknown value may arrive.

local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local flowtype = require 'cartograph.flowtype'

local function tree(files)
    local root = vim.fn.tempname()
    for rel, src in pairs(files) do
        vim.fn.mkdir((root .. '/' .. rel):match('^(.*)/[^/]+$'), 'p')
        local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(src); fd:close()
    end
    return root
end

local FILES = {
    -- (two modules each defining `get` and `lower`: every `x.get()` / `s:lower()` below is AMBIGUOUS by name)
    ['a.lua'] = 'local A = {}\nfunction A.get(t) t.n = 1; return t end\nfunction A.lower(s) return s end\nreturn A\n',
    ['b.lua'] = 'local B = {}\nfunction B.get(t) t.m = 2; return t end\nfunction B.lower(s) return s end\nreturn B\n',
    ['main.lua'] = table.concat({
        -- a record of closures returned by a constructor: `r.get` is the closure, not A.get / B.get
        'local function reader(src)',
        '  return { get = function (i) return src:sub(i, i) end }',
        'end',
        'local function first(src)',
        '  local r = reader(src)',
        '  return r.get(1)',
        'end',
        -- a receiver only ever a string BY FLOW (the parameter of a local function its callers hand literals):
        -- name:lower() is string.lower, neither A.lower nor B.lower
        'local function shout(name)',
        '  return name:lower()',
        'end',
        'local function greet() return shout("ada"), shout("bob") end',
        -- a dispatch table called through pcall: the handler reached is the table's
        'local VERBS = { get = function (t) return t end }',
        'local function run(verb, t)',
        '  local h = VERBS[verb]',
        '  local ok, v = pcall(h, t)',
        '  return v',
        'end',
        'return { first = first, greet = greet, run = run }',
    }, '\n'),
}

test('flowtype: a returned record\'s closure, a string-only receiver — decided by what FLOWS there, not by the name', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree(FILES)
    store.ingest(ts.extract(root))
    local R = flowtype.of(store, { open = false })
    vim.fn.delete(root, 'rf')
    local callrec = require 'cartograph.callrec'
    local by = {}
    for _, c in ipairs(store.data.calls) do
        if callrec.file(c) == 'main.lua' then by[tostring(callrec.full(c) or callrec.callee(c))] = R.verdict(c) end
    end
    local g = by['r.get']
    eq('exact', g and g.kind, 'the record\'s closure: ' .. vim.inspect(g))
    ok(g and g.targets[1] and g.targets[1]:match('^main%.lua::'), 'a main.lua function — neither A.get nor B.get: ' .. vim.inspect(g))
    local s = by['name:lower']
    eq('string', s and s.kind, 'only a string reaches s: ' .. vim.inspect(s))
end)

test('flowtype: an EXPORTED function\'s parameter may hold anything (open) — no claim through it', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({
        ['a.lua'] = 'local A = {}\nfunction A.get(t) t.n = 1 end\nreturn A\n',
        ['b.lua'] = 'local B = {}\nfunction B.get(t) t.m = 2 end\nreturn B\n',
        ['m.lua'] = 'local M = {}\nlocal function g() return 1 end\nfunction M.use(x) return x.get() end\nfunction M.inside() return M.use({ get = g }) end\nreturn M\n',
    })
    store.ingest(ts.extract(root))
    local callrec = require 'cartograph.callrec'
    local call
    for _, c in ipairs(store.data.calls) do if callrec.full(c) == 'x.get' then call = c end end
    ok(call, 'the ambiguous call is recorded')
    local closed = flowtype.of(store, { open = false }).verdict(call)
    eq('exact', closed and closed.kind, 'closed world: the one table that flows in decides it')
    eq(nil, flowtype.of(store).verdict(call), 'open (the default): M.use is exported — an outside caller may pass anything')
    vim.fn.delete(root, 'rf') -- (after: the analysis reads the sources)
end)

test('effects by flow: a joined call flow decides takes ITS target — not every same-named candidate\'s writes', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local effects = require 'cartograph.effects'
    local root = tree({
        ['a.lua'] = 'local A = {}\nlocal hits = 0\nfunction A.get() hits = hits + 1 end\nreturn A\n',
        ['b.lua'] = 'local B = {}\nlocal seen = 0\nfunction B.get() seen = seen + 1 end\nreturn B\n',
        ['main.lua'] = 'local function reader(src)\n  return { get = function (i) return i end }\nend\nlocal function first(src)\n  local r = reader(src)\n  return r.get(1)\nend\nreturn first\n',
    })
    store.ingest(ts.extract(root))
    local first
    for _, n in ipairs(store.data.nodes) do if n.name == 'first' then first = n end end
    store._fx = nil
    local by_name = effects.purity(store, first.id)
    store._fx = nil
    effects.FLOW = true
    local ok_, by_flow = pcall(effects.purity, store, first.id)
    effects.FLOW = nil
    store._fx = nil
    vim.fn.delete(root, 'rf')
    ok(ok_, tostring(by_flow))
    eq('writes~', by_name, 'the name join takes A.get and B.get: their writes')
    eq('pure~', by_flow, 'by flow, r.get is the record\'s closure: no write (a premise: ~)')
end)

-- ★ THE GO WALKER, the language the type checker can SCORE (tools/experiments/flowtype_oracle: on helm, 709 exact,
-- 0 wrong): declared types are ignored — an allocation names its type (`&T{…}` carries T's methods), embedding
-- promotes, the rest flows. Two types both declare `Get` / `Base` / `Run`: every call below is decided by what reaches it
test('flowtype (go): a method reached through a constructor, an embedded type, a map range, a struct field', function ()
    if not parser_available('go') then skip 'no go parser' end
    local root = tree({
        ['go.mod'] = 'module example.com/m\n\ngo 1.22\n',
        ['p/p.go'] = table.concat({
            'package p',
            'type S struct{ n int }',
            'func (s S) Base() int { return s.n }',
            'type T struct {',
            '\tS',
            '\tname string',
            '}',
            'func (t *T) Get(i int) (int, error) { return i, nil }',
            'type U struct{ S }',
            'func (u *U) Get(i int) (int, error) { return -i, nil }',
            'func (u *U) Base() int { return 0 }',
            'type Runner interface{ Run() }',
            'type R1 struct{}',
            'func (R1) Run() {}',
            'type R2 struct{}',
            'func (R2) Run() {}',
            'type Holder struct{ r Runner }',
            'func New(name string) *T { return &T{name: name} }',
            'func use() {',
            '\tt := New("x")',
            '\tv, err := t.Get(1)',
            '\t_, _ = v, err',
            '\tm := map[string]*T{"a": t}',
            '\tfor _, x := range m {',
            '\t\tx.Base()',
            '\t}',
            '\th := Holder{r: R1{}}',
            '\th.r.Run()',
            '}',
        }, '\n'),
    })
    store.ingest(ts.extract(root))
    local R = flowtype.of(store, { open = false })
    vim.fn.delete(root, 'rf')
    local by = {}
    for _, p in ipairs(R.probes) do by[p.member .. '@' .. p.line] = p end
    local function one(key, pat, why)
        local p = by[key]
        eq('exact', p and p.kind, why .. ': ' .. vim.inspect(p))
        ok(p and p.targets[1] and p.targets[1]:match(pat), why .. ': ' .. vim.inspect(p and p.targets))
    end
    one('Get@20', 'T%.Get', 't := New(...): *T\'s Get, not U\'s')
    one('Base@24', 'S%.Base', 'a *T from the map, Base promoted from the embedded S — not U.Base')
    one('Run@27', 'R1%.Run', 'the field holds an R1: R1.Run, not R2.Run (the declared type is only the interface)')
end)

-- ★ THE ALLOCATIONS A GO PROGRAM MAKES WITHOUT A LITERAL (scored on helm: exact-right 709 -> 1063, still 0 wrong): a
-- zero value `var x T`, a typed const (and its iota successors), a conversion `T(x)`, and a method's RECEIVER (a T,
-- always: Go has no struct subtyping). Two types each declare every method named below
test('flowtype (go): zero values, typed consts, conversions and the receiver are allocations of their type', function ()
    if not parser_available('go') then skip 'no go parser' end
    local root = tree({
        ['go.mod'] = 'module example.com/m\n\ngo 1.22\n',
        ['p/p.go'] = table.concat({
            'package p',
            'type labels map[string]string',
            'func (l *labels) init() { *l = labels{} }',
            'type other map[string]int',
            'func (o *other) init() {}',
            'type Status string',
            'func (s Status) String() string { return string(s) }',
            'type Kind string',
            'func (k Kind) String() string { return string(k) }',
            'const (',
            '\tDeployed Status = "deployed"',
            '\tFailed',
            ')',
            'type T struct{}',
            'func (t *T) Get() int { return 1 }',
            'func (t *T) Twice() int { return t.Get() }',
            'type U struct{}',
            'func (u *U) Get() int { return 2 }',
            'func use() {',
            '\tvar lb labels',
            '\tlb.init()',
            '\t_ = Failed.String()',
            '\t_ = Status("x").String()',
            '}',
        }, '\n'),
    })
    store.ingest(ts.extract(root))
    local R = flowtype.of(store, { open = false })
    vim.fn.delete(root, 'rf')
    local by = {}
    for _, p in ipairs(R.probes) do by[p.member .. '@' .. p.line] = p end
    local function one(key, pat, why)
        local p = by[key]
        eq('exact', p and p.kind, why .. ': ' .. vim.inspect(p))
        ok(p and p.targets[1] and p.targets[1]:match(pat), why .. ': ' .. vim.inspect(p and p.targets))
    end
    one('init@20', 'labels%.init', 'var lb labels: a zero labels value')
    one('String@21', 'Status%.String', 'Failed repeats the iota block\'s type: a Status')
    one('String@22', 'Status%.String', 'a conversion Status("x") is a Status')
    one('Get@15', 'T%.Get', 'inside T\'s method the receiver is a T')
end)

-- ★ A TYPE ASSERTION IS A RUNTIME TYPE CHECK, so it FILTERS: through an `any` both T and U arrive, and `x.(*T)` /
-- `case *T:` pass only the T (on helm, tests included: the one wrong exact — v2's Validate for a v3 call — gone)
test('flowtype (go): x.(*T) and a one-type `case *T:` keep only the T that flows through an `any`', function ()
    if not parser_available('go') then skip 'no go parser' end
    local root = tree({
        ['go.mod'] = 'module example.com/m\n\ngo 1.22\n',
        ['p/p.go'] = table.concat({
            'package p',
            'type T struct{}',
            'func (t *T) Get() int { return 1 }',
            'type U struct{}',
            'func (u *U) Get() int { return 2 }',
            'func pass(x any) any { return x }',
            'func use() {',
            '\ta := pass(&T{})',
            '\t_ = pass(&U{})',
            '\tt := a.(*T)',
            '\t_ = t.Get()',
            '\tswitch v := a.(type) {',
            '\tcase *U:',
            '\t\t_ = v.Get()',
            '\t}',
            '}',
        }, '\n'),
    })
    store.ingest(ts.extract(root))
    local R = flowtype.of(store, { open = false })
    vim.fn.delete(root, 'rf')
    local by = {}
    for _, p in ipairs(R.probes) do by[p.member .. '@' .. p.line] = p end
    local t, u = by['Get@10'], by['Get@13']
    eq('exact', t and t.kind, 'the assertion passes only the T: ' .. vim.inspect(t))
    ok(t and t.targets[1]:match('T%.Get'), vim.inspect(t and t.targets))
    eq('exact', u and u.kind, 'the case clause passes only the U: ' .. vim.inspect(u))
    ok(u and u.targets[1]:match('U%.Get'), vim.inspect(u and u.targets))
end)

-- ★ THE JS / TS WALKER (scored by the TypeScript checker, tools/experiments/flowtype_oracle/ts: on
-- typescript-language-server 661 of 759 class-method calls exact-right, 0 wrong; turborepo 213, 0 wrong). Types are
-- ignored: `new C()` takes C's prototype, `this` inside C's method is a C, a static is the class's own, an imported
-- name is the module's export. Two classes declare `get`: every call below is decided by flow
test('flowtype (ts): new, this, statics, imports and object literals decide a member call', function ()
    if not parser_available('typescript') then skip 'no typescript parser' end
    local root = tree({
        ['src/a.ts'] = table.concat({
            'export class A {',
            '  get(): number { return 1; }',
            '  run(): number { return this.get(); }',
            '  static make(): A { return new A(); }',
            '}',
            'export class B {',
            '  get(): number { return 2; }',
            '}',
        }, '\n'),
        ['src/b.ts'] = table.concat({
            "import { A } from './a';",
            'const a = A.make();',
            'a.get();',
            'const o = { get: () => 3 };',
            'o.get();',
        }, '\n'),
    })
    store.ingest(ts.extract(root))
    local R = flowtype.of(store, { open = false })
    vim.fn.delete(root, 'rf')
    local by = {}
    for _, p in ipairs(R.probes) do by[p.file .. ':' .. p.member .. '@' .. p.line] = p end
    local function one(key, pat, why)
        local p = by[key]
        eq('exact', p and p.kind, why .. ': ' .. vim.inspect(p))
        ok(p and p.targets[1] and p.targets[1]:match(pat), why .. ': ' .. vim.inspect(p and p.targets))
    end
    one('src/a.ts:get@2', 'A%.get', 'this inside A.run is an A')
    one('src/b.ts:make@1', 'make', 'A.make: the imported class\'s static')
    one('src/b.ts:get@2', 'A%.get', 'a = A.make() = new A(): A.get, not B.get')
    one('src/b.ts:get@4', 'b%.ts::', 'the object literal\'s own arrow function')
end)

-- ★ `x instanceof C` NARROWS THE FLOW, not only the verdict (arktype, scored: `if (out instanceof ArkErrors)
-- out.transform(e => e.transform(...))` had handed the callback to BaseNode.transform too, so `e` held BaseNodes and
-- `e.transform` read wrong). Inside the branch x is a port of C's instances among x's — solved to a fixpoint
test('flowtype (ts): inside `if (x instanceof B)` and `x instanceof B ? …` x holds only the B instances', function ()
    if not parser_available('typescript') then skip 'no typescript parser' end
    local root = tree({
        ['src/m.ts'] = table.concat({
            'class Leaf { visit(f: (x: Leaf) => void): void { f(this); } name(): string { return "leaf"; } }',
            'class Node2 { visit(f: (x: Node2) => void): void { f(this); } name(): string { return "node"; } }',
            'function pick(k: number) { return k > 0 ? new Leaf() : new Node2(); }',
            'const v = pick(1);',
            'if (v instanceof Leaf) {',
            '  v.visit(x => x.name());',
            '}',
            'const w = v instanceof Node2 ? v.name() : "";',
            'const u = v instanceof Node2 ? v.visit(y => y.name()) : 0;',
        }, '\n'),
    })
    store.ingest(ts.extract(root))
    local R = flowtype.of(store, { open = false })
    vim.fn.delete(root, 'rf')
    local by = {}
    for _, p in ipairs(R.probes) do by[p.member .. '@' .. p.line .. ':' .. p.col] = p end
    local function one(key, pat, why)
        local p = by[key]
        eq('exact', p and p.kind, why .. ': ' .. vim.inspect(p))
        ok(p and p.targets[1] and p.targets[1]:match(pat), why .. ': ' .. vim.inspect(p and p.targets))
    end
    one('visit@5:2', 'Leaf%.visit', 'the branch sees only the Leaf')
    one('name@5:15', 'Leaf%.name', 'and so does the callback it hands Leaf.visit: x is a Leaf, never a Node2')
    one('name@7:31', 'Node2%.name', 'the ternary consequence sees only the Node2')
    one('name@8:44', 'Node2%.name', 'and the callback it hands Node2.visit holds only Node2s')
end)

-- ★ a TS NAMESPACE is an object of its exports, a barrel's `export * from` / `export { a as b } from` re-exports,
-- and a bare specifier resolves through tsconfig `paths` (typebox-codegen, scored: `Formatter.Format(…)` from
-- `export namespace Formatter`, reached via `export * from './formatter'` and `@sinclair/typebox-codegen` → src/index.ts:
-- 12 → 183 of 183 exact-right). A call inside a template string's `${…}` is a probe too
test('flowtype (ts): namespaces, re-exports, tsconfig paths and template substitutions reach the function', function ()
    if not parser_available('typescript') then skip 'no typescript parser' end
    local root = tree({
        ['tsconfig.json'] = table.concat({
            '{ "compilerOptions": {',
            '  // JSONC: a comment and a trailing comma',
            '  "paths": { "@pkg": ["src/index.ts"], "@lib/*": ["src/lib/*"], },',
            '} }',
        }, '\n'),
        ['src/lib/fmt.ts'] = 'export namespace Fmt { export function format(s: string) { return s; } }',
        ['src/lib/enc.ts'] = 'export namespace Enc { export function encode(s: string) { return s; } }',
        ['src/index.ts'] = "export * from './lib/fmt'\nexport { Enc as E } from '@lib/enc'",
        ['example/use.ts'] = table.concat({
            "import * as P from '@pkg'",
            'const a = P.Fmt.format("x")',
            'const b = `<${P.E.encode("y")}>`',
        }, '\n'),
    })
    store.ingest(ts.extract(root))
    local R = flowtype.of(store, { open = false })
    vim.fn.delete(root, 'rf')
    local by = {}
    for _, p in ipairs(R.probes) do if p.file == 'example/use.ts' then by[p.member] = p end end
    local function one(m, pat, why)
        local p = by[m]
        eq('exact', p and p.kind, why .. ': ' .. vim.inspect(p))
        ok(p and p.targets[1] and p.targets[1]:match(pat), why .. ': ' .. vim.inspect(p and p.targets))
    end
    one('format', '^src/lib/fmt%.ts::.*format', 'P.Fmt.format: paths → the barrel → export * → the namespace')
    one('encode', '^src/lib/enc%.ts::.*encode', 'P.E.encode: an aliased re-export through `@lib/*`, inside `${…}`')
end)

-- ★ OCCLUDING THE TYPES is an instrument: flowtype on a tree with every type blanked (positions kept) must answer as
-- on the typed tree — it reads no type. Its first run found two places where TYPES STILL CHANGED THE ANSWER:
-- tree-sitter-typescript parses `await c.m<T>(…)` as `(await c.m)<T>(…)`, so the typed call had no probe at all
-- (typescript-language-server: withProgress, getWorkspaceConfiguration); and a 17th parameter indexed past the fixed
-- 16 parameter ports and crashed the walk (arktype's tests)
test('flowtype (ts): a generic call under await is a probe, and a function may take more than 16 parameters', function ()
    if not parser_available('typescript') then skip 'no typescript parser' end
    local ps = {}
    for k = 1, 18 do ps[#ps + 1] = 'p' .. k end
    local root = tree({
        ['src/m.ts'] = table.concat({
            'class C { async w<T>(x: T): Promise<T> { return x; } }',
            'const c = new C();',
            'async function f() { return await c.w<number>(1); }',
            'function many(' .. table.concat(ps, ', ') .. ') { return p18; }',
            'const r = many(' .. table.concat(ps, ', '):gsub('p%d+', '0') .. ');',
        }, '\n'),
    })
    store.ingest(ts.extract(root))
    local R = flowtype.of(store, { open = false })
    vim.fn.delete(root, 'rf')
    local p
    for _, x in ipairs(R.probes) do if x.member == 'w' then p = x end end
    eq('exact', p and p.kind, 'the awaited generic call is a probe: ' .. vim.inspect(p))
    ok(p and p.targets[1]:match('C%.w'), vim.inspect(p and p.targets))
end)
