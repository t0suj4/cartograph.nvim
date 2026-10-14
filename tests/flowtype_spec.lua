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

test('flowtype: a store into a SCALAR writes no field — the shared string object never holds `.body`; explain names a saturation (CART-1683)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local L3 = 'local function main() put("s"); put({}) end'
    local sinks = {}
    for i = 1, 70 do sinks[i] = 'sink({})' end -- (70 tables through one parameter: past CAP)
    local root = tree({
        ['m.lua'] = table.concat({
            'local function f() return 1 end',
            'local function put(x) x.body = f end', -- x is a string at one call, a table at the other
            L3,
            'local function sink(x) return x end',
            table.concat(sinks, '\n'),
            'return main' }, '\n') .. '\n',
    })
    store.ingest(ts.extract(root))
    local R = flowtype.of(store, { open = false, explain = true, keepsat = true })
    local so = R.object('type:string')
    ok(so, 'the string type object exists')
    eq(nil, R.field_port(so, 'body'), 'a string has no field to write: `x.body = f` raises on one')
    local tb = R.object('tbl:m.lua:2:' .. (L3:find('{', 1, true) - 1)) -- (an object's key: file, 0-based line and column)
    ok(tb and R.field_port(tb, 'body'), 'the table handed to put does get .body')
    -- (explain: the first sink table escaped through sink's saturated parameter, and that port saturated past CAP)
    local path = R.escape_of(R.object('tbl:m.lua:4:5'))
    ok(path[#path]:find('[saturated]', 1, true), 'escape_of ends at a saturated port: ' .. table.concat(path, ' | '))
    local late = R.escape_of(R.object('tbl:m.lua:73:5')) -- (the last: it reached the port AFTER it saturated)
    ok(late[#late]:find('[saturated]', 1, true), 'a late arrival is recorded too: ' .. table.concat(late, ' | '))
    local why = R.taint_path(R._escport)
    eq('<- saturated (past CAP)', why[#why], 'taint_path names the seed')
    vim.fn.delete(root, 'rf')
end)

test('flowtype: a load over many objects sharing one deep prototype chain walks the chain ONCE, not once per object (CART-1686)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    -- (50 objects, each its own allocation site, all with __index = P1, the head of a 30-link prototype chain linked
    -- AFTER the loads: each object's load `o.x` is replayed onto P1 once P1 is its prototype, and P1 already holds
    -- that load — the old code re-walked the whole chain every time: 1760 load_obj calls here, 290 with the return)
    local src = { 'local ' .. table.concat(vim.tbl_map(function (k) return 'P' .. k end, vim.fn.range(1, 30)), ', '),
        'local P31 = { x = 1 }', 'local get' }
    for k = 0, 49 do src[#src + 1] = ('local o%d = setmetatable({}, { __index = P1 })'):format(k) end
    src[#src + 1] = 'get = function (o) return o.x end'
    for k = 0, 49 do src[#src + 1] = ('get(o%d)'):format(k) end
    for k = 30, 1, -1 do src[#src + 1] = ('P%d = setmetatable({}, { __index = P%d })'):format(k, k + 1) end
    src[#src + 1] = 'return get'
    local root = tree({ ['m.lua'] = table.concat(src, '\n') .. '\n' })
    store.ingest(ts.extract(root))
    local R = flowtype.of(store, { open = false, ctx = false })
    ok(R.stats.loadvisits > 0, 'the counter counts')
    ok(R.stats.loadvisits < 500, 'linear in objects + chain, not their product: ' .. R.stats.loadvisits)
    vim.fn.delete(root, 'rf')
end)

test('flowtype: a store through a SATURATED base may write any escaped object\'s field — a load through that object\'s own port is partial (CART-1643 rule 1, CART-1696)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    -- (o holds A.run; o and 70 other tables reach g's parameter, which saturates: o ESCAPES. g writes `t.run = B.run`
    -- through it, which the solve no longer follows into o. A load o.run through o's own, untainted port must not
    -- answer a whole exact A.run — at run time it may be B.run)
    local sinks = {}
    for k = 1, 70 do sinks[k] = 'g({})' end
    local root = tree({
        ['a.lua'] = 'local A = {}\nfunction A.run(self) return 1 end\nreturn A\n',
        ['b.lua'] = 'local B = {}\nfunction B.run(self) return 2 end\nreturn B\n',
        ['m.lua'] = table.concat({
            'local A, B = require("a"), require("b")',
            'local o = { run = A.run }',
            'local function g(t) t.run = B.run end',
            'g(o)',
            table.concat(sinks, '\n'),
            'return o:run()' }, '\n') .. '\n' })
    store.ingest(ts.extract(root))
    local callrec = require 'cartograph.callrec'
    local call
    for _, c in ipairs(store.data.calls) do if callrec.full(c) == 'o:run' then call = c end end
    ok(call and call.refused, 'the call is ambiguous: ' .. vim.inspect(call and call.refused and call.refused.rule))
    local v = flowtype.of(store, { open = false }).verdict(call)
    ok(not (v and v.kind == 'exact' and not v.partial), 'no WHOLE exact through the escaped object: ' .. vim.inspect(v))
    vim.fn.delete(root, 'rf')
end)

test('flowtype: a loop\'s per-site instance of its iterator is walked AT ITS OWN POSITIONS — the original call\'s answer is the union (CART-1688)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    -- (the loop hands `node` to an instance of `it`; a direct call hands `other` to the original. The call n:kid inside
    -- `it` reaches BOTH — an answer naming other.kid alone was an unsound exact)
    local root = tree({ ['m.lua'] = table.concat({
        'local A, B = {}, {}',
        'function A.kid(self, i) return nil end',
        'function B.kid(self, i) return nil end',
        'local node = { kid = function (self, i) if i < 2 then return i end end }',
        'local other = { kid = function (self, i) return nil end }',
        'local function it(n, i)',
        '    local c = n:kid(i + 1)',
        '    if c then return i + 1, c end',
        'end',
        'it(other, 0)',
        'for _, c in it, node, -1 do print(c) end',
        'return A' }, '\n') .. '\n' })
    store.ingest(ts.extract(root))
    local callrec = require 'cartograph.callrec'
    local call
    for _, c in ipairs(store.data.calls) do if callrec.full(c) == 'n:kid' then call = c end end
    ok(call, 'the ambiguous call is recorded')
    for _, open in ipairs { false, true } do
        local v = flowtype.of(store, { open = open }).verdict(call)
        ok(not (v and v.kind == 'exact'), (open and 'open' or 'closed') .. ': no exact through the loop\'s instance: ' .. vim.inspect(v))
    end
    vim.fn.delete(root, 'rf')
end)

test('flowtype: a loop site minted INSIDE an instance takes no instance of its own — a chain of iterators instantiates once per original site (CART-1687)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    -- (three small closed iterators, each looping over the next; global, so each is closed. Without the bound every
    -- instance's own loop instantiated the next again — 6 instances here, a cycle of them never stopped on WoW)
    local root = tree({ ['m.lua'] = table.concat({
        'function it3(s, i) return nil end',
        'function it2(s, i) for _ in it3, s, i do end return nil end',
        'function it1(s, i) for _ in it2, s, i do end return nil end',
        'for _ in it1, {}, 0 do end',
        'return it1' }, '\n') .. '\n' })
    store.ingest(ts.extract(root))
    local R = flowtype.of(store, { open = false, ctx = false })
    eq(3, R.stats.instances, 'one instance per loop site of the original code')
    vim.fn.delete(root, 'rf')
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

-- ★ `setmetatable(t, { __index = idx })` links t's objects to idx's whichever side arrives LAST (CART-1621): the link
-- was made only when t gained an object, so an __index table whose value flowed in later was never a prototype — a
-- missed flow, and an ORDER-dependent one (here: lost under the ascending and FIFO schedules, kept under the others).
-- And `require` reaches its module at all: the import edge's range is an index once ingest FOLDS it, and a table-only
-- guard had left every require unresolved since flowtype shipped
test('flowtype: an __index table that receives its value after the object becomes its prototype, in every order', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({
        ['a.lua'] = 'local A = {}\nfunction A.hello(self) return 1 end\nreturn A\n',
        ['b.lua'] = 'local B = {}\nfunction B.hello(self) return 2 end\nreturn B\n',
        ['main.lua'] = table.concat({
            'local holder = { k = 1 }',
            'local t = setmetatable({ n = 0 }, { __index = holder.base })',
            'holder.base = require "a"',
            'return t:hello()',
        }, '\n'),
    })
    store.ingest(ts.extract(root))
    local callrec = require 'cartograph.callrec'
    local got = {}
    for _, order in ipairs({ 'desc', 'asc', 'lifo', 'fifo' }) do
        local R = flowtype.solve(store, { open = false, order = order })
        for _, c in ipairs(store.data.calls) do if callrec.file(c) == 'main.lua' and c.refused then got[order] = R.verdict(c) end end
    end
    vim.fn.delete(root, 'rf')
    for _, order in ipairs({ 'desc', 'asc', 'lifo', 'fifo' }) do
        local v = got[order]
        eq('exact', v and v.kind, order .. ': t:hello() through the late __index: ' .. vim.inspect(v))
        ok(v and tostring(v.targets[1]):match('A%.hello'), order .. ': ' .. vim.inspect(v and v.targets))
    end
end)

-- ★ AN UNRELATED FILE MOVES NO ANSWER (CART-1621). A port that saturates mid-solve has handed downstream whatever it
-- held when it was processed, so the schedule decides the answer. A stack's order followed port numbers (through
-- `pairs` over integer-keyed sets), and adding ANY file shifts every number — arktype: 127 of 7917 answers in untouched
-- files moved when one 3-line file was added, and the per-process string hash moved them run to run (456 / 413 / 422
-- exact). The worklist is now a heap over a stable order. Fixture: tests/fixtures/flowsched, delta-debugged from
-- arktype to the 151 lines where a comment-only file still moved an answer under the stack
test('flowtype: adding an unrelated file moves no answer — and under the old stack order it did', function ()
    if not parser_available('typescript') then skip 'no typescript parser' end
    local FIX = vim.fn.getcwd() .. '/tests/fixtures/flowsched/ark/schema/shared/'
    local files = {}
    for _, f in ipairs({ 'errors.ts', 'traversal.ts' }) do
        files['ark/schema/shared/' .. f] = assert(io.open(FIX .. f)):read('a')
    end
    local function answers(extra, order)
        local fs = vim.deepcopy(files)
        if extra then fs['aaa_unrelated.ts'] = '// nothing\n' end
        local root = tree(fs)
        store.ingest(ts.extract(root))
        local R = flowtype.solve(store, { open = false, order = order })
        vim.fn.delete(root, 'rf')
        local out, n = {}, 0
        for _, p in ipairs(R.probes) do
            if p.file:match('^ark/') then
                out[p.file .. ':' .. p.line .. ':' .. p.col] = p.kind .. ' ' .. table.concat(p.targets, ','); n = n + 1
            end
        end
        return out, n
    end
    local function moved(a, b) local m = 0 for k, v in pairs(a) do if b[k] ~= v then m = m + 1 end end return m end
    local a, n = answers(false)
    ok(n >= 5, 'the fixture has answers: ' .. n)
    eq(0, moved(a, (answers(true))), 'the default schedule: nothing moves')
    ok(moved((answers(false, 'lifo')), (answers(true, 'lifo'))) > 0, 'the old stack order still moves an answer — the fixture is live')
end)

-- ★ PARTIAL (CART-1643): the stable schedule made a saturated port's leak REPRODUCIBLE, not whole — what it held went
-- downstream, what came after was lost. An answer read through a port the cap may have left incomplete is `partial`;
-- one that is not is a function of the graph: the same under every schedule, and the same with a bigger cap. Measured
-- on arktype / lua/cartograph: every answer that varied by schedule was flagged (268 / 13), no unflagged answer changed
-- at CAP 256 (283 / 445), while 192 / 150 flagged ones did
test('flowtype: a non-partial answer is the same under every schedule and a bigger cap; what varies is flagged', function ()
    if not parser_available('typescript') then skip 'no typescript parser' end
    local FIX = vim.fn.getcwd() .. '/tests/fixtures/flowsched/ark/schema/shared/'
    local files = {}
    for _, f in ipairs({ 'errors.ts', 'traversal.ts' }) do files['ark/schema/shared/' .. f] = assert(io.open(FIX .. f)):read('a') end
    local root = tree(files)
    store.ingest(ts.extract(root))
    local function rows(order)
        local out = {}
        for _, p in ipairs(flowtype.solve(store, { open = false, order = order }).probes) do
            out[p.file .. ':' .. p.line .. ':' .. p.col] = { a = p.kind .. ' ' .. table.concat(p.targets, ','), partial = p.partial }
        end
        return out
    end
    local cap = flowtype.CAP
    flowtype.CAP = 3 -- (a small cap: this fixture saturates at once)
    local runs = {}
    for _, o in ipairs({ 'desc', 'asc', 'lifo', 'fifo' }) do runs[o] = rows(o) end
    flowtype.CAP = 64
    local big = rows()
    flowtype.CAP = cap
    vim.fn.delete(root, 'rf')
    local npartial, nwhole = 0, 0
    for k, x in pairs(runs.desc) do
        if x.partial then npartial = npartial + 1 else nwhole = nwhole + 1 end
        local varies = false
        for _, o in ipairs({ 'asc', 'lifo', 'fifo' }) do
            local y = runs[o][k]
            if y and y.a ~= x.a then varies = true end
            if y and not x.partial and not y.partial then eq(x.a, y.a, k .. ': non-partial under desc and ' .. o) end
        end
        if varies then ok(x.partial, k .. ' varies by schedule, so it is partial') end
        if not x.partial and not x.a:match('^none') then eq(x.a, big[k] and big[k].a, k .. ': non-partial at CAP 3 holds at CAP 64') end
    end
    ok(npartial > 0 and nwhole > 0, ('both kinds occur: %d partial, %d whole'):format(npartial, nwhole))
end)

-- ★ THE ARRAY PART `#` (CART-1643): what a NUMBER key stores (t[i] in a numeric for, t[#t + 1], table.insert, a
-- positional constructor field) is no field NAME, so `t.handler` does not read it — while a key we cannot type (`t[k]`)
-- may be any name, and still reaches every named load. On lua/cartograph `[]` had been the commonest saturated hub
test('flowtype: a list built into a table does not reach its named fields; an untyped key still does', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({
        ['a.lua'] = 'local A = {}\nfunction A.run(self) return 1 end\nreturn A\n',
        ['b.lua'] = 'local B = {}\nfunction B.run(self) return 2 end\nreturn B\n',
        ['main.lua'] = table.concat({
            'local A, B = require "a", require "b"',
            'local reg = { handler = A, B }',
            'for i = 1, 3 do reg[i] = B end',
            'reg[#reg + 1] = B; reg[#reg] = B',
            'table.insert(reg, B)',
            'local one = reg.handler:run()',
            'local dyn = { handler = A }',
            'local function put(k) dyn[k] = B end',
            'put("handler")',
            'local two = dyn.handler:run()',
        }, '\n'),
    })
    store.ingest(ts.extract(root))
    local R = flowtype.of(store, { open = false })
    local callrec, atr = require 'cartograph.callrec', require 'cartograph.at'
    local v = {}
    for _, c in ipairs(store.data.calls) do
        if callrec.file(c) == 'main.lua' and c.refused and c.at then v[atr.sl(c.at)] = R.verdict(c) end
    end
    vim.fn.delete(root, 'rf')
    eq('exact', v[5] and v[5].kind, 'reg.handler:run() — the list of Bs is not the field: ' .. vim.inspect(v[5]))
    ok(v[5] and tostring(v[5].targets[1]):match('A%.run'), vim.inspect(v[5] and v[5].targets))
    ok(not (v[9] and v[9].kind == 'exact'), 'dyn[k] = B may write `handler`: no exact claim — ' .. vim.inspect(v[9]))
end)

-- ★ A LOAD THROUGH A TAINTED FIELD IS PARTIAL (CART-1643): field reads are implicit — an object keeps the loads that
-- read it (96% of all edges were object x load, 339 MB on lua/cartograph) — so taint reaches a load through the same
-- readers. Here `put` saturates (CAP 2), box escapes into it, and box.handler may have been written there unseen
test('flowtype: a load of a field the cap may have left incomplete is partial', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({
        ['a.lua'] = 'local A = {}\nfunction A.run(self) return 1 end\nreturn A\n',
        ['b.lua'] = 'local B = {}\nfunction B.run(self) return 2 end\nreturn B\n',
        ['main.lua'] = table.concat({
            'local A, B = require "a", require "b"',
            'local box = { handler = A }',
            'local function put(t, v) t.handler = v end',
            'put(box, A); put({ n = 1 }, B); put({ n = 2 }, B)',
            'local x = box.handler',
            'return x:run()',
        }, '\n'),
    })
    store.ingest(ts.extract(root))
    local cap = flowtype.CAP
    flowtype.CAP = 2
    local R = flowtype.solve(store, { open = false })
    flowtype.CAP = cap
    local callrec, atr = require 'cartograph.callrec', require 'cartograph.at'
    local v
    for _, c in ipairs(store.data.calls) do
        if callrec.file(c) == 'main.lua' and c.refused and c.at and atr.sl(c.at) == 5 then v = R.verdict(c) end
    end
    vim.fn.delete(root, 'rf')
    ok(v ~= nil, 'x:run() is answered')
    eq(true, v and v.partial, 'box.handler may hold what put wrote unseen: ' .. vim.inspect(v))
end)

-- ★ A STRING METHOD ON AN EMPTY RECEIVER (CART-1643): nothing reaches `name`, but a program past `name:lower()` had a
-- string there — the result is a string, hedged (partial). A receiver the solve DID fill keeps its own answer
test('flowtype: a string method on an empty receiver returns the string library\'s type, partial', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({
        ['a.lua'] = 'local A = {}\nfunction A.find(self) return 1 end\nreturn A\n',
        ['b.lua'] = 'local B = {}\nfunction B.find(self) return 2 end\nreturn B\n',
        ['main.lua'] = 'local function f(name)\n  local l = name:lower()\n  return l:find("x")\nend\nreturn f\n',
    })
    store.ingest(ts.extract(root))
    local R = flowtype.solve(store, { open = false })
    vim.fn.delete(root, 'rf')
    local callrec = require 'cartograph.callrec'
    local v
    for _, c in ipairs(store.data.calls) do if callrec.file(c) == 'main.lua' and tostring(callrec.full(c)) == 'l:find' then v = R.verdict(c) end end
    eq('string', v and v.kind, 'what :lower() returns: ' .. vim.inspect(v))
    eq(true, v and v.partial, 'the evidence is the call, not a flow: hedged')
end)

-- ★ A GENERIC RETURN IS ITS ARGUMENT (CART-1653): `assert(v: T, …): T` returns v. Read as an object of a type named T
-- the algebra table never reached `A().node(…)` — 48 empty receivers on lua/cartograph
test('flowtype: a profile function returning its generic parameter (assert) returns the argument, not a type named T', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({
        ['a.lua'] = 'local A = {}\nfunction A.run(self) return 1 end\nreturn A\n',
        ['b.lua'] = 'local B = {}\nfunction B.run(self) return 2 end\nreturn B\n',
        ['main.lua'] = 'local A = require "a"\nlocal x = assert(A, "no a")\nreturn x:run()\n',
    })
    store.ingest(ts.extract(root))
    local R = flowtype.solve(store, { open = false })
    vim.fn.delete(root, 'rf')
    local callrec = require 'cartograph.callrec'
    local v
    for _, c in ipairs(store.data.calls) do if callrec.file(c) == 'main.lua' and tostring(callrec.full(c)) == 'x:run' then v = R.verdict(c) end end
    eq('exact', v and v.kind, 'assert hands A through: ' .. vim.inspect(v))
    ok(v and v.targets[1] == 'a.lua::A.run@1', vim.inspect(v))
end)

-- ★ SELECTIVE CONTEXT SENSITIVITY (CART-1653): a function whose parameter SATURATES upstream of an unknown answer gets
-- an instance per resolved call site, walked inside the scopes it was defined in (a closure: `use` reads `count`), and
-- a call in it is answered over its instances. At CAP 2 the merged `x` holds A and two plain tables: saturated, no
-- claim; each instance holds one, and of the three only A has `run`
test('flowtype: a closure whose parameter saturates gets an instance per call site — its call is answered over them (CART-1653)', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({
        ['a.lua'] = 'local A = {}\nfunction A.run(self) return 1 end\nreturn A\n',
        ['b.lua'] = 'local B = {}\nfunction B.run(self) return 2 end\nreturn B\n',
        ['main.lua'] = table.concat({
            'local A = require "a"',
            'local count = 0',
            'local function use(x)',
            '  count = count + 1',
            '  x:run()',
            '  return A',
            'end',
            'use(A); use({ n = 1 })',
            'local r = use({ n = 2 })',
            'return r:run()',
        }, '\n'),
    })
    store.ingest(ts.extract(root))
    local cap = flowtype.CAP
    flowtype.CAP = 2
    local merged = flowtype.solve(store, { open = false, ctx = false })
    local split = flowtype.solve(store, { open = false })
    flowtype.CAP = cap
    vim.fn.delete(root, 'rf')
    local callrec = require 'cartograph.callrec'
    local c, rc
    for _, x in ipairs(store.data.calls) do
        if callrec.file(x) == 'main.lua' and tostring(callrec.full(x)) == 'x:run' then c = x end
        if callrec.file(x) == 'main.lua' and tostring(callrec.full(x)) == 'r:run' then rc = x end
    end
    ok(c ~= nil, 'the call x:run() is in the graph')
    eq(nil, merged.verdict(c), 'one walk: x saturates, no claim')
    local v = split.verdict(c)
    eq('exact', v and v.kind, 'instances: ' .. vim.inspect(v))
    ok(v and v.targets[1] == 'a.lua::A.run@1', 'A.run, the only receiver with run: ' .. vim.inspect(v))
    ok((split.stats.ctxfns or 0) >= 1, 'use was selected: ' .. tostring(split.stats.ctxfns))
    -- (the instance sees the scopes `use` was defined in: its upvalue A is the module, not a global)
    local rv = split.verdict(rc)
    eq('exact', rv and rv.kind, 'what an instance returns from its upvalue: ' .. vim.inspect(rv))
end)

-- ★ WHAT AN ESCAPED OBJECT HOLDS ESCAPES WITH IT (CART-1643): a call through a tainted callee taints the parameters of
-- every escaped function — but the function is often not what escaped: here a P instance reaches `keep`'s saturated
-- parameter, and `r.go(q)` would read P's method `go` through it, binding q to its o. The instance escaped, its metatable
-- and the metatable's methods did not, so `o:hit()` read exact P:hit (uncapped: P:hit and Q:hit) — and under another
-- schedule it was not (lua/cartograph's ir.lua P:skip_group: exact under desc, saturated under asc)
test('flowtype: a method reached only through an escaped object has partial parameters', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({
        ['main.lua'] = table.concat({
            'local P = {}; P.__index = P',
            'function P:hit() return 1 end',
            'function P.go(o) return o:hit() end',
            'local Q = {}; Q.__index = Q',
            'function Q:hit() return 2 end',
            'function Q.go(o) return 0 end',
            'local function keep(x) return x end',
            'keep(setmetatable({}, P)); keep({}); keep({})',
            'local q = setmetatable({}, Q)',
            'local r = keep(setmetatable({}, P))',
            'r.go(q)',
            'P.go(setmetatable({}, P))',
        }, '\n'),
    })
    store.ingest(ts.extract(root))
    local cap = flowtype.CAP
    flowtype.CAP = 2
    local R = flowtype.solve(store, { open = false })
    flowtype.CAP = cap
    local callrec, atr = require 'cartograph.callrec', require 'cartograph.at'
    local v
    for _, c in ipairs(store.data.calls) do
        if callrec.file(c) == 'main.lua' and c.refused and c.at and atr.sl(c.at) == 2 then v = R.verdict(c) end
    end
    vim.fn.delete(root, 'rf')
    ok(v ~= nil, 'o:hit() is answered')
    eq(true, v and v.partial, 'go may get q, unseen: ' .. vim.inspect(v))
end)

-- ★ DENSE SETS ARE THE SAME SETS (CART-1643): past M.BIG objects a set and its delta become bitsets, moved word by word
-- — the complete solve of arktype went 707 s -> ~186 s with every answer unchanged. Under the default cap no set gets
-- that big, so this solves uncapped with BIG forced down (dense almost everywhere) and up (never), and every answer —
-- probes and Lua verdicts — must be the same
test('flowtype: dense (bitset) sets give exactly the answers hash sets give', function ()
    if not parser_available('typescript') or not parser_available('lua') then skip 'no parsers' end
    local FIX = vim.fn.getcwd() .. '/tests/fixtures/flowsched/ark/schema/shared/'
    local files = {}
    for _, f in ipairs({ 'errors.ts', 'traversal.ts' }) do files['ark/schema/shared/' .. f] = assert(io.open(FIX .. f)):read('a') end
    -- (and a Lua part with fan-in: many tables through one helper)
    local L = { 'local M = {}', 'local function keep(x) return x end', 'local out = {}' }
    for i = 1, 40 do L[#L + 1] = ('out[%d] = keep({ id = %d, run = function () return %d end })'):format(i, i, i) end
    L[#L + 1] = 'for _, x in ipairs(out) do local r = x.run() end'
    L[#L + 1] = 'return M'
    files['lib/many.lua'] = table.concat(L, '\n')
    local root = tree(files)
    store.ingest(ts.extract(root))
    local callrec, atr = require 'cartograph.callrec', require 'cartograph.at'
    local function rows()
        local R = flowtype.solve(store, { open = false })
        local out = {}
        for _, p in ipairs(R.probes) do out[#out + 1] = p.file .. ':' .. p.line .. ':' .. p.col .. ' ' .. p.kind .. ' ' .. table.concat(p.targets, ',') end
        for _, c in ipairs(store.data.calls) do
            local v = R.verdict(c)
            if v and c.at then out[#out + 1] = callrec.file(c) .. ':' .. atr.sl(c.at) .. ' ' .. v.kind .. ' ' .. table.concat(v.targets or {}, ',') end
        end
        table.sort(out)
        return out, R.stats.ports
    end
    local cap, big = flowtype.CAP, flowtype.BIG
    flowtype.CAP = 1e9
    flowtype.BIG = 1e9
    local hashed = rows()
    flowtype.BIG = 2
    local dense = rows()
    flowtype.CAP, flowtype.BIG = cap, big
    vim.fn.delete(root, 'rf')
    ok(#hashed > 10, 'the fixture answers: ' .. #hashed)
    eq(hashed, dense, 'the same answers, dense or not')
end)

-- ★ VALUES FROM OUTSIDE THE TREE (CART-1643): on lua/cartograph most ambiguous calls with nothing at the receiver held
-- values from nvim's API — tree-sitter nodes, strings. The environment profile types them (`vim.split` -> string[]),
-- and a value read out of a container type is its ELEMENT type: `parts[1]` is a string, so `parts[1]:upper()` is the
-- string method, neither in-tree `upper`
test('flowtype: an element read out of a profile-typed container has the element type', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({
        -- (laid out as an nvim plugin: that SHAPE is what composes the nvim profile in)
        ['lua/fx/a.lua'] = 'local A = {}\nfunction A.upper(s) return s end\nreturn A\n',
        ['lua/fx/b.lua'] = 'local B = {}\nfunction B.upper(s) return s end\nreturn B\n',
        ['lua/fx/main.lua'] = 'local parts = vim.split("a,b", ",")\nlocal p = parts[1]\nreturn p:upper()\n',
        ['plugin/fx.lua'] = 'require("fx.main")\n',
    })
    store.ingest(ts.extract(root))
    local R = flowtype.solve(store, { open = false })
    local callrec, atr = require 'cartograph.callrec', require 'cartograph.at'
    local v, refused
    for _, c in ipairs(store.data.calls) do
        if callrec.file(c) == 'lua/fx/main.lua' and c.at and atr.sl(c.at) == 2 then v = R.verdict(c); refused = c.refused end
    end
    vim.fn.delete(root, 'rf')
    if not refused then skip('the extractor already decides p:upper() (profile ' .. tostring(store.data.profile) .. ')') end
    eq('string', v and v.kind, 'parts[1] is a string: ' .. vim.inspect(v) .. ' profile ' .. tostring(store.data.profile))
end)

-- ★ MULTIPLE VALUES (CART-1643): Lua's walker gave every call ONE value and bound a generic for's variables to nothing
-- unless it was pairs / ipairs — so `local ok, parser = pcall(get_string_parser, …)` left parser empty, `return i, c`
-- lost c, and `for _, c in tsutil.inext, node, -1` / `for c in node:iter_children()` (the profile's `fun(): TSNode,
-- string`) left c empty. On lua/cartograph the generic for alone took the empty receivers 1441 -> 975 and the typed
-- verdicts 14 -> 381
test('flowtype: multiple values — pcall, a second return, an iterator in the tree and a typed one', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({
        ['lua/fx/a.lua'] = table.concat({
            'local A = {}; A.__index = A',
            'function A:run() return 1 end',
            'function A:type() return 1 end',
            'local B = {}; B.__index = B',
            'function B:run() return 2 end',
            'function B:type() return 2 end',
            'local function two() return 1, setmetatable({}, A) end',
            'local function inext(t, i) i = i + 1; local v = t[i]; if v then return i, v end end',
            'local function scan(src)',
            '    local ok, x = pcall(function () return setmetatable({}, A) end)',
            '    local r1 = x:run()',
            '    local _, y = two()',
            '    local r2 = y:run()',
            '    for _, z in inext, { setmetatable({}, B) }, 0 do local r3 = z:run() end',
            '    local p = vim.treesitter.get_string_parser(src, "lua")',
            '    local t = p:parse()',
            '    local root = t[1]:root()',
            '    for c in root:iter_children() do local k = c:type() end',
            '    return r1, r2',
            'end',
            'return scan',
        }, '\n'),
        ['plugin/fx.lua'] = 'require("fx.a")\n',
    })
    store.ingest(ts.extract(root))
    local R = flowtype.solve(store, { open = false })
    local callrec, atr = require 'cartograph.callrec', require 'cartograph.at'
    local v = {}
    for _, c in ipairs(store.data.calls) do
        if callrec.file(c) == 'lua/fx/a.lua' and c.refused and c.at then v[atr.sl(c.at) + 1] = R.verdict(c) or false end
    end
    vim.fn.delete(root, 'rf')
    local function one(line, want, what)
        local x = v[line]
        ok(x, what .. ': answered — ' .. vim.inspect(x))
        if want == 'TSNode' then eq('typed', x and x.kind, what); eq('TSNode', x and x.type, what)
        else eq('exact', x and x.kind, what); ok(x and tostring(x.targets[1]):match(want), what .. ': ' .. vim.inspect(x)) end
    end
    one(11, 'A:run', "pcall's second value is the function's first")
    one(13, 'A:run', 'the second return')
    one(14, 'B:run', "an iterator in the tree: inext's second value")
    one(18, 'TSNode', "a typed iterator: iter_children's first value")
end)

-- ★ A REQUIRE THE GRAPH HAS NO IMPORT EDGE FOR (CART-1643): `pcall(require, 'cartograph.algebra.core')` passes require
-- as a VALUE, and cartograph.algebra's whole API comes out of that one call (M.load()). A literal module name now
-- resolves by Lua's path convention (lua/a/b.lua, lua/a/b/init.lua) to a file in the tree: on lua/cartograph exact
-- verdicts 279 -> 387, and the runtime oracle saw 57 more executed exact answers right, 0 wrong
test('flowtype: pcall(require, "m") reaches module m', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({
        ['lua/fx/core.lua'] = 'local M = {}\nfunction M.run() return 1 end\nreturn M\n',
        ['lua/fx/other.lua'] = 'local O = {}\nfunction O.run() return 2 end\nreturn O\n',
        ['lua/fx/main.lua'] = table.concat({
            'local ok, A = pcall(require, "fx.core")',
            'local function load() return A end',
            'return load().run()',
        }, '\n'),
        ['plugin/fx.lua'] = 'require("fx.main"); require("fx.other")\n',
    })
    store.ingest(ts.extract(root))
    local R = flowtype.solve(store, { open = false })
    local callrec, atr = require 'cartograph.callrec', require 'cartograph.at'
    local v, refused
    for _, c in ipairs(store.data.calls) do
        if callrec.file(c) == 'lua/fx/main.lua' and c.at and atr.sl(c.at) == 2 and (callrec.callee(c) == 'run') then v = R.verdict(c); refused = c.refused end
    end
    vim.fn.delete(root, 'rf')
    if not refused then skip 'the extractor already decides load().run()' end
    eq('exact', v and v.kind, vim.inspect(v))
    ok(v and tostring(v.targets[1]):match('core%.lua::M%.run'), vim.inspect(v and v.targets))
end)

-- ★ AN OBJECT WITHOUT THE MEMBER IS NOT THE RECEIVER (CART-1643): `x:upper()` on a table that has no `upper` raises,
-- so a program past the call held the string there. The exact answer always read a call that way; a string beside
-- such a table read `none` (275 of lua/cartograph's non-empty `none` receivers). A table that holds functions under a
-- key the walk could not name (`t[k] = f`) may have the member: no claim
test('flowtype: a receiver object lacking the member is excluded; one with unnamed function keys is not', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({
        ['lua/fx/a.lua'] = 'local A = {}\nfunction A.upper(s) return s end\nreturn A\n',
        ['lua/fx/b.lua'] = 'local B = {}\nfunction B.upper(s) return s end\nreturn B\n',
        ['lua/fx/main.lua'] = table.concat({
            'local M = {}',
            'function M.pick(c) if c then return "text" end return { n = 1 } end',
            'local x = M.pick(true)',
            'local r1 = x:upper()',
            'local dyn = { n = 2 }',
            'function M.put(k) dyn[k] = function () return 1 end end',
            'function M.pick2(c) if c then return "text" end return dyn end',
            'local y = M.pick2(true)',
            'local r2 = y:upper()',
            'return M',
        }, '\n'),
        ['plugin/fx.lua'] = 'require("fx.main"); require("fx.a"); require("fx.b")\n',
    })
    store.ingest(ts.extract(root))
    local R = flowtype.solve(store, { open = false })
    local callrec, atr = require 'cartograph.callrec', require 'cartograph.at'
    local v, refused = {}, {}
    for _, c in ipairs(store.data.calls) do
        if callrec.file(c) == 'lua/fx/main.lua' and c.at and callrec.callee(c) == 'upper' then
            v[atr.sl(c.at) + 1] = R.verdict(c) or false; refused[atr.sl(c.at) + 1] = c.refused
        end
    end
    vim.fn.delete(root, 'rf')
    if not refused[4] or not refused[9] then skip 'the extractor already decides the upper() calls' end
    eq('string', v[4] and v[4].kind, 'the table has no upper: ' .. vim.inspect(v[4]))
    eq(false, v[9], 'dyn may hold upper under a key the walk cannot name: ' .. vim.inspect(v[9]))
end)

-- (…and an ESCAPED object without the member may have gained it where the solve no longer follows it: the answer
-- that excludes it is partial)
test('flowtype: excluding an escaped receiver object that lacks the member makes the answer partial', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({
        ['lua/fx/a.lua'] = 'local A = {}\nfunction A.upper(s) return s end\nreturn A\n',
        ['lua/fx/b.lua'] = 'local B = {}\nfunction B.upper(s) return s end\nreturn B\n',
        ['lua/fx/main.lua'] = table.concat({
            'local M = {}',
            'local t = { n = 1 }',
            'local function keep(v) return v end',
            'keep(t); keep({ n = 2 }); keep({ n = 3 })',
            'function M.pick(c) if c then return "text" end return t end',
            'local x = M.pick(true)',
            'local r1 = x:upper()',
            'return M',
        }, '\n'),
        ['plugin/fx.lua'] = 'require("fx.main"); require("fx.a"); require("fx.b")\n',
    })
    store.ingest(ts.extract(root))
    local cap = flowtype.CAP
    flowtype.CAP = 2
    local R = flowtype.solve(store, { open = false })
    flowtype.CAP = cap
    local callrec, atr = require 'cartograph.callrec', require 'cartograph.at'
    local v, refused
    for _, c in ipairs(store.data.calls) do
        if callrec.file(c) == 'lua/fx/main.lua' and c.at and atr.sl(c.at) == 6 then v = R.verdict(c); refused = c.refused end
    end
    vim.fn.delete(root, 'rf')
    if not refused then skip 'the extractor already decides x:upper()' end
    eq('string', v and v.kind, vim.inspect(v))
    eq(true, v and v.partial, 't escaped into keep: it may have gained upper unseen — ' .. vim.inspect(v))
end)

-- ★ OPEN REACHES PAST THE EXPORTS (CART-1652): an outside caller can call a method on what an exported function
-- RETURNS — `M.b():go()` runs A:go with a B instance, though the tree itself only ever calls `M.a():go()`. Open, the
-- answer inside A:go is partial; closed (only the tree's own callers), it stays whole
test('flowtype: open — a method reached through an exported return has partial parameters', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({
        ['lua/fx/a.lua'] = table.concat({
            'local M = {}',
            'local A = {}; A.__index = A',
            'function A:hit() return 1 end',
            'function A:go() return self:hit() end',
            'local B = setmetatable({}, { __index = A }); B.__index = B',
            'function B:hit() return 2 end',
            'function M.a() return setmetatable({}, A) end',
            'function M.b() return setmetatable({}, B) end',
            'M.a():go()',
            'return M',
        }, '\n'),
        ['plugin/fx.lua'] = 'require("fx.a")\n',
    })
    store.ingest(ts.extract(root))
    local callrec, atr = require 'cartograph.callrec', require 'cartograph.at'
    local function at3(R)
        for _, c in ipairs(store.data.calls) do
            if callrec.file(c) == 'lua/fx/a.lua' and c.at and atr.sl(c.at) == 3 and c.refused then return R.verdict(c), true end
        end
    end
    local vo, ro = at3(flowtype.solve(store, {}))
    local vc = at3(flowtype.solve(store, { open = false }))
    vim.fn.delete(root, 'rf')
    if not ro then skip 'the extractor already decides self:hit()' end
    eq('exact', vc and vc.kind, 'closed: ' .. vim.inspect(vc))
    eq(nil, vc and vc.partial, 'closed: whole')
    eq(true, vo and vo.partial, 'open: an outside caller may run go with a B — ' .. vim.inspect(vo))
end)

-- ★ A PROFILE FUNCTION AS A VALUE (CART-1643): `pcall(vim.treesitter.get_string_parser, src, lang)` — 65 of
-- lua/cartograph's tree-sitter entry points — passes the function, and a load off the global `vim` held nothing, so no
-- parser, tree or node existed downstream. A dotted reference rooted at a GLOBAL that names a profile signature holds its
-- function type; a local of the root's name is not the profile's
test('flowtype: a profile function passed as a value returns its declared type; a shadowing local does not', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({
        ['lua/fx/a.lua'] = 'local A = {}\nfunction A:root() return self end\nfunction A:parse() return self end\nreturn A\n',
        ['lua/fx/b.lua'] = 'local B = {}\nfunction B:root() return self end\nfunction B:parse() return self end\nreturn B\n',
        ['lua/fx/main.lua'] = table.concat({
            'local M = {}',
            'function M.scan(src)',
            '    local ok, parser = pcall(vim.treesitter.get_string_parser, src, "lua")',
            '    local t = M.first(parser:parse())',
            '    local tree = M.first(t[1])',
            '    return tree:root()',
            'end',
            'function M.first(x) return x end',
            'function M.shadow(src)',
            '    local vim = { treesitter = { get_string_parser = function () return nil end } }',
            '    local ok, parser = pcall(vim.treesitter.get_string_parser, src, "lua")',
            '    return parser:parse()',
            'end',
            'return M',
        }, '\n'),
        ['plugin/fx.lua'] = 'require("fx.main"); require("fx.a"); require("fx.b")\n',
    })
    store.ingest(ts.extract(root))
    local R = flowtype.solve(store, { open = false })
    local callrec, atr = require 'cartograph.callrec', require 'cartograph.at'
    local v, refused = {}, {}
    for _, c in ipairs(store.data.calls) do
        if callrec.file(c) == 'lua/fx/main.lua' and c.at and (callrec.callee(c) == 'root' or atr.sl(c.at) + 1 == 12) then
            v[atr.sl(c.at) + 1] = R.verdict(c) or false; refused[atr.sl(c.at) + 1] = c.refused
        end
    end
    vim.fn.delete(root, 'rf')
    if not refused[6] then skip 'the extractor already decides tree:root()' end
    eq('typed', v[6] and v[6].kind, 'tree holds what parse() returned: ' .. vim.inspect(v[6]))
    if not refused[12] then skip 'the extractor already decides parser:parse()' end
    ok(not (v[12] and v[12].kind == 'typed'), 'the local vim is not the profile: ' .. vim.inspect(v[12]))
end)

-- ★ PER-LOOP INSTANCES OF A SMALL CLOSED ITERATOR (CART-1643): a generic for binds its iterator to an instance of its
-- own when the function is small and CLOSED (every name it reads is its own or a global, nothing nested) — so one loop's
-- values do not pour into another's. tsutil.inext took every loop's node and saturated; with instances, lua/cartograph's
-- executed WHOLE typed answers went 47 -> 126 right (runtime oracle). An iterator that reads an UPVALUE is shared
test('flowtype: a closed iterator is instantiated per loop; one reading an upvalue is shared', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({
        ['lua/fx/a.lua'] = table.concat({
            'local A = {}; A.__index = A',
            'function A:run() return 1 end',
            'local B = {}; B.__index = B',
            'function B:run() return 2 end',
            'local function inext(t, i) i = i + 1; local v = t[i]; if v then return i, v end end',
            'local shift = 1',
            'local function onext(t, i) i = i + shift; local v = t[i]; if v then return i, v end end',
            'local function vals(s) s.i = s.i + 1; return s.list[s.i] end',
            'local function nnext(t, i) local function step(j) return j + 1 end; i = step(i); local v = t[i]; if v then return i, v end end',
            'local M = {}',
            'function M.more()',
            '    for a in vals, { list = { setmetatable({}, A) }, i = 0 } do a:run() end',
            '    for b in vals, { list = { setmetatable({}, B) }, i = 0 } do b:run() end',
            '    for _, c in nnext, { setmetatable({}, A) }, 0 do c:run() end',
            '    for _, d in nnext, { setmetatable({}, B) }, 0 do d:run() end',
            'end',
            'function M.go()',
            '    for _, x in inext, { setmetatable({}, A) }, 0 do x:run() end',
            '    for _, y in inext, { setmetatable({}, B) }, 0 do y:run() end',
            '    for _, z in onext, { setmetatable({}, A) }, 0 do z:run() end',
            '    for _, w in onext, { setmetatable({}, B) }, 0 do w:run() end',
            'end',
            'return M',
        }, '\n'),
        ['plugin/fx.lua'] = 'require("fx.a")\n',
    })
    store.ingest(ts.extract(root))
    local R = flowtype.solve(store, { open = false })
    local callrec, atr = require 'cartograph.callrec', require 'cartograph.at'
    local v = {}
    for _, c in ipairs(store.data.calls) do
        if callrec.file(c) == 'lua/fx/a.lua' and c.refused and c.at then v[atr.sl(c.at) + 1] = R.verdict(c) or false end
    end
    vim.fn.delete(root, 'rf')
    ok(v[18] and v[18].kind == 'exact' and tostring(v[18].targets[1]):match('A:run'), 'inext loop 1: A only — ' .. vim.inspect(v[18]))
    ok(v[19] and v[19].kind == 'exact' and tostring(v[19].targets[1]):match('B:run'), 'inext loop 2: B only — ' .. vim.inspect(v[19]))
    ok(not (v[20] and v[20].kind == 'exact'), 'onext reads `shift`: shared, both loops hold A and B — ' .. vim.inspect(v[20]))
    ok(v[12] and v[12].kind == 'exact' and tostring(v[12].targets[1]):match('A:run'), 'vals, its FIRST value: A only — ' .. vim.inspect(v[12]))
    ok(v[13] and v[13].kind == 'exact' and tostring(v[13].targets[1]):match('B:run'), 'vals loop 2: B only — ' .. vim.inspect(v[13]))
    ok(not (v[14] and v[14].kind == 'exact'), 'nnext holds a function of its own: shared — ' .. vim.inspect(v[14]))
end)

-- the walker looks its tree up by the PARSE VIEW, the key the extractor stored it under: keyed by the raw text, a file
-- that mentions `global` (the view renames it, TSGAP-0012) missed the shared tree and was parsed a second time
test('flowtype: a file that mentions `global` reuses the extractor\'s tree — no second parse', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({ ['g.lua'] = 'local global = { a = 1 }\nlocal function get() return global.a end\nreturn get\n' })
    store.ingest(ts.extract(root))
    local pcache = require 'cartograph.parsecache'
    local m0 = pcache.stats.misses
    flowtype.solve(store, {})
    vim.fn.delete(root, 'rf')
    eq(0, pcache.stats.misses - m0, 'the walker parsed nothing of its own')
end)

-- an ABSENT child list — a bare `return`, `local x` with no value — is walked through EMPTY_NODE, the stand-in for
-- "no node": it must answer every iterator the walker uses (inamed asks named_child; its absence crashed the solve
-- on the 428-file corpus while the suite passed)
test('flowtype: a bare return and a valueless local walk an absent child list without crashing', function ()
    if not parser_available('lua') then skip 'no lua parser' end
    local root = tree({ ['e.lua'] = 'local function f() local x; return end\nlocal function g() return f() end\nreturn g\n' })
    store.ingest(ts.extract(root))
    local ok_, err = pcall(flowtype.solve, store, {})
    vim.fn.delete(root, 'rf')
    ok(ok_, tostring(err))
end)
