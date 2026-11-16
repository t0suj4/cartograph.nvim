-- CART-0696: a declared type was READ (receiver typing used it) and THROWN AWAY — no binding node carried it, so no
-- lint, report or agent could ask "what is x's declared type". Now one spec slot per language (spec.decl_type) reads
-- a binder's type AS WRITTEN, and the graph stores it: a module var's `ty`, a function's `ptypes` aligned with its
-- params ('' = none written). Typed only where a type is WRITTEN: `auto`, go `:=` / `var x = v`, an untyped rust `let`
-- record none. Resolves nothing by itself: calls identical on luanti, hugo, ripgrep, dav1d; cache +0.2-0.5%.

local ts    = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local agent = require 'cartograph.agent'

local function graph(files)
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    for f, t in pairs(files) do local fd = assert(io.open(root .. '/' .. f, 'w')); fd:write(t); fd:close() end
    local d = ts.extract(root); d.root = root
    local by = {}
    for _, n in ipairs(d.nodes) do if n.kind ~= 'module' then by[n.name] = n end end
    return d, by, root
end

test('decl type: c / cpp module vars and parameters carry their declared type as written; auto writes none (CART-0696)', function ()
    if not (parser_available('cpp') and parser_available('c')) then skip 'no c / cpp parser' end
    local _, by = graph({
        ['a.cpp'] = 'class Foo { public: int m(); };\nstatic Foo g_foo;\nconst Foo *g_ptr = nullptr;\nauto g_auto = 1;\ndecltype(g_foo) g_dt;\nint use(Foo *p, int n) { return 0; }\n',
        ['b.c'] = 'struct S { int x; };\nstruct S g_s;\nint f(struct S *s, unsigned long n) { return 0; }\n',
    })
    eq('Foo', by.g_foo.ty); eq('const Foo*', by.g_ptr.ty); eq(nil, by.g_auto.ty); eq(nil, by.g_dt.ty, 'decltype is inferred')
    eq({ { 'p', 'n' }, { 'Foo*', 'int' } }, { by.use.params, by.use.ptypes })
    eq('struct S', by.g_s.ty)
    eq({ 'struct S*', 'unsigned long' }, by.f.ptypes)
end)

test('decl type: go and rust — written types stored, inferred ones not (CART-0696)', function ()
    local files = {}
    if parser_available('go') then files['a.go'] = 'package a\n\ntype Foo struct{}\n\nvar gFoo Foo\nvar gInf = 1\n\nfunc use(p *Foo, n int) int { return 1 }\nfunc none() {}\n' end
    if parser_available('rust') then files['a.rs'] = 'struct Bar { }\nstatic G: Bar = Bar { };\nfn use_it(p: &Bar, mut q: i32) -> i32 { 1 }\n' end
    if not next(files) then skip 'no go / rust parser' end
    local _, by = graph(files)
    if files['a.go'] then
        eq('Foo', by.gFoo.ty); eq(nil, by.gInf.ty)
        eq({ '*Foo', 'int' }, by.use.ptypes); eq(nil, by.none.ptypes, 'no parameters: no list')
    end
    if files['a.rs'] then
        eq('Bar', by.G.ty); eq({ '&Bar', 'i32' }, by.use_it.ptypes)
    end
end)

test('decl type: the agent row names it — a var\'s `type`, a function\'s `param_types`; other rows unchanged (CART-0696)', function ()
    if not (parser_available('cpp') and parser_available('lua')) then skip 'no cpp / lua parser' end
    local d = graph({ ['a.cpp'] = 'class Foo { public: int m(); };\nconst Foo *g_foo;\nint use(Foo *p, int n) { return 0; }\n',
        ['x.lua'] = 'local M = {}\nfunction M.go(a, b) return a end\nreturn M\n' })
    store.ingest(d)
    local function row(q) return agent.answer(store, 'node_find', { query = q }).result[1] end
    eq('const Foo*', row('g_foo').type)
    eq({ { name = 'p', type = 'Foo*' }, { name = 'n', type = 'int' } }, row('use').param_types)
    local lr = row('M.go')
    eq({ nil, nil }, { lr.type, lr.param_types }, 'a language without the slot: no field')
end)
