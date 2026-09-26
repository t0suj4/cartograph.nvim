-- The PARSE VIEW (lua/cartograph/parseview.lua): a length-preserving rewrite a grammar parses correctly, with every
-- consumer reading text from the original bytes. Lua has its dialect view (luadialect_spec); scheme masks a
-- symbol-initial `@`, which the nvim 0.12 tree-sitter-scheme rejects (one turned guile's tree-il.scm into ONE error).

local pv = require 'cartograph.parseview'

test('parseview: scheme masks a symbol-initial @ and nothing else, keeping every offset', function ()
    local src = "(define (f) (@@ (m) g) (@prompt a b) `(x ,@ys) #`(p #,@qs) 'ok user@host)"
    local v = pv.view(src, 'scheme')
    eq(#src, #v, 'length preserved')
    eq("(define (f) (__ (m) g) (_prompt a b) `(x ,@ys) #`(p #,@qs) 'ok user@host)", v)
    eq(src, pv.view(src, 'racket'), 'a language without a view is untouched')
    eq({ 'cpp', 'lua', 'scheme' }, pv.languages())
end)

test('parseview: a multi-line guile extended symbol #{...}# is masked except its newlines', function ()
    local src = "(f '#{\nAC [x] \"q\"\n}# y)"
    local v = pv.view(src, 'scheme')
    eq(#src, #v)
    eq("(f '__\n__________\n__ y)", v, 'line positions hold')
end)

test('parseview: a guile file using @ forms still yields its definitions, and names read from the original bytes', function ()
    if not parser_available('scheme') then skip 'no scheme parser' end
    local ts = require 'cartograph.providers.treesitter'
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/m.scm', 'w'))
    fd:write('(define (early) (@@ (ice-9 boot-9) module-name))\n(define (later x) (early) (@prompt x))\n(define (last) (later 1))\n')
    fd:close()
    local data = ts.extract(root)
    vim.fn.delete(root, 'rf')
    local defs, calls = {}, {}
    for _, n in ipairs(data.nodes) do if n.kind == 'function' then defs[n.name] = n end end
    for _, c in ipairs(data.calls) do calls[c.callee] = c end
    ok(defs.later and defs.last, 'definitions after an @ form are extracted')
    eq(defs.later and defs.later.id, calls.later and calls.later.to, 'and resolve')
    -- `@@` is the witness that text comes from the ORIGINAL bytes: read through the view it would be `__`. (A callee
    -- is normalized to its last word segment, so `@prompt` reads `prompt`, the same rule that gives `ice-9` -> `9`.)
    ok(calls['@@'], 'the @@ name is read from the original bytes')
    eq(nil, calls['__'], 'never the masked spelling')
    eq(nil, calls['_prompt'])
end)

test('scheme: a parse error tears only the definition it sits in (node-local), not the rest of the file', function ()
    if not parser_available('scheme') then skip 'no scheme parser' end
    local ts = require 'cartograph.providers.treesitter'
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/t.scm', 'w'))
    -- an error the view does NOT fix: an unbalanced paren inside the first definition
    fd:write('(define (bad) (car x))) )\n(define (good) 1)\n(define (user) (good))\n')
    fd:close()
    local data = ts.extract(root)
    vim.fn.delete(root, 'rf')
    local good, call
    for _, n in ipairs(data.nodes) do if n.name == 'good' then good = n end end
    for _, c in ipairs(data.calls) do if c.callee == 'good' then call = c end end
    ok(good and not good.torn, 'the def after the error is not torn')
    eq(good and good.id, call and call.to, 'and a call to it resolves')
end)

test('parseview: cpp masks a namespace-scope `= default` / `= delete` to a same-length body, and nothing in a class', function ()
    if not parser_available('cpp') then skip 'no cpp parser' end
    local src = 'struct A {};\nA::A() = default;\nvoid f(int) =\n  delete ;\nstruct B { B& operator=(const B&) = delete; B() = default; virtual int g() = 0; };\nbool h = a == default_v;\n'
    local v = pv.view(src, 'cpp')
    eq(#src, #v, 'length preserved')
    eq('struct A {};\nA::A() { ;}     ;\nvoid f(int) {\n  ;}     ;\nstruct B { B& operator=(const B&) = delete; B() = default; virtual int g() = 0; };\nbool h = a == default_v;\n', v)
end)

test('cpp: a namespace-scope defaulted ctor is a definition, and a deleted one does not swallow the next', function ()
    if not parser_available('cpp') then skip 'no cpp parser' end
    local ts = require 'cartograph.providers.treesitter'
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/a.cpp', 'w'))
    fd:write('struct A { A(); ~A(); void run(); A& operator=(const A&) = delete; bool operator==(const A&) const; };\nvoid f(int) = delete;\nA::A() = default;\nA::~A() = default;\nbool A::operator==(const A&) const = default;\nstruct C { C& operator=(const C&); };\nC& C::operator=(const C&) = default;\nvoid A::run() {}\nvoid user() { A a; a.run(); }\n')
    fd:close()
    local data = ts.extract(root)
    vim.fn.delete(root, 'rf')
    local got = {}
    for _, n in ipairs(data.nodes) do if n.kind == 'method' then got[#got + 1] = n.name end end
    table.sort(got)
    eq({ 'A::A', 'A::operator=', 'A::operator==', 'A::run', 'A::~A', 'C::operator=' }, got, 'both defaulted members are definitions, and run after them survives')
end)
