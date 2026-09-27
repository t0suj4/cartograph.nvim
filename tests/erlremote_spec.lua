-- CART-1100: tree-sitter-erlang (nvim-treesitter main) nests a remote call INSIDE `remote` — (remote module: ...
-- fun: (call expr: (atom) ...)) — so read naively the call looks local and its module is dropped (9064 ejabberd calls
-- fell to no-def). A remote call must keep its module qualifier and resolve through the module-to-file bind.

local ts = require 'cartograph.providers.treesitter'

test('erlang: a remote call keeps its module (mod.f/arity) and resolves into mod.erl; a local call stays local', function ()
    if not parser_available('erlang') then skip 'no erlang parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local function put(f, s) local fd = assert(io.open(root .. '/' .. f, 'w')); fd:write(s); fd:close() end
    put('m.erl', '-module(m).\n-export([f/1]).\nf(X) ->\n    lists:map(fun g/1, X),\n    other:h(X),\n    g(X).\ng(Y) -> Y.\n')
    put('other.erl', '-module(other).\n-export([h/1]).\nh(Z) -> Z.\n')
    local data = ts.extract(root)
    vim.fn.delete(root, 'rf')
    local by = {}
    for _, c in ipairs(data.calls) do if c.file == 'm.erl' then by[c.callee] = c end end
    eq('lists.map/2', by.map and by.map.full, 'an OTP remote call is qualified by its module')
    eq('other.h/1', by.h and by.h.full)
    eq('other.erl::h@2', by.h and by.h.to, 'and a corpus remote call resolves into the module file')
    eq('m.erl::g@6', by.g and by.g.to, 'a local call still resolves locally')
end)

-- CART-1129: a remote call on a VARIABLE module is dynamic dispatch. It used to keep its bare name and go to the name
-- resolver, which matched 270 of 519 on ejabberd to a wrong same-named function — ejabberd_auth.erl:183
-- `M:start(Host)` resolved to ejabberd_auth:start/2, the function it sits in.
test('erlang: `Mod:f(...)` on a variable module is DYNAMIC, never name-matched (and a literal module still resolves)', function ()
    if not parser_available('erlang') then skip 'no erlang parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local function put(f, s) local fd = assert(io.open(root .. '/' .. f, 'w')); fd:write(s); fd:close() end
    put('auth.erl', '-module(auth).\n-export([start/2]).\nstart(Host, Modules) ->\n'
        .. '    lists:foreach(fun(M) -> M:start(Host) end, Modules),\n    backend:start(Host).\n')
    put('backend.erl', '-module(backend).\n-export([start/1]).\nstart(H) -> H.\n')
    local data = ts.extract(root)
    vim.fn.delete(root, 'rf')
    local dyn, lit
    for _, c in ipairs(data.calls) do
        if c.file == 'auth.erl' and c.callee == 'start' then
            if c.full == 'backend.start/1' then lit = c else dyn = c end
        end
    end
    ok(dyn, 'the variable-module call is recorded')
    eq(true, dyn.dynamic, 'as dynamic dispatch')
    eq(nil, dyn.to, 'and resolved to nothing: not auth:start/2, the function it sits in')
    eq('dynamic', (require('cartograph.census').disp(dyn)))
    eq('backend.erl::start@2', lit and lit.to, 'a literal module still resolves into its file')
end)

-- CART-1131: an erlang function's visibility is its module's -export list (or -compile(export_all)). Without it the
-- dead-function rule reported exported functions as dead: 1216 of 1770 findings on ejabberd, 472 more in export_all.
test('erlang: a function is exported by name AND arity from -export, quoted atoms unquoted, everything under export_all', function ()
    if not parser_available('erlang') then skip 'no erlang parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local function put(f, s) local fd = assert(io.open(root .. '/' .. f, 'w')); fd:write(s); fd:close() end
    -- `'g'/2` exported QUOTED, `g` defined bare: the same atom
    put('m.erl', "-module(m).\n-export([f/1, 'g'/2]).\nf(X) -> X.\nf(X, Y) -> {X, Y}.\ng(A, B) -> h(A, B).\nh(A, B) -> {A, B}.\n")
    put('t.erl', '-module(t).\n-compile([export_all, nowarn_export_all]).\nk() -> ok.\n')
    local data = ts.extract(root)
    vim.fn.delete(root, 'rf')
    local v = {}
    for _, n in ipairs(data.nodes) do if n.kind == 'function' then v[n.file .. ' ' .. n.altkeys[1]] = n.exported end end
    eq(true, v['m.erl f/1']); eq(false, v['m.erl f/2'], 'the same name at another arity is not exported')
    eq(true, v['m.erl g/2'], 'a quoted export names the bare atom'); eq(false, v['m.erl h/2'])
    eq(true, v['t.erl k/0'], 'export_all')
end)

-- CART-1132: `fun f/N` names a function of the same module as a VALUE. It minted nothing, so a function passed to
-- lists:map or kept in a handler list had no caller (47 of 76 dead-function findings on ejabberd after the export fix).
test('erlang: `fun f/N` is a hedged reference to f/N of the same module (by arity; a self-reference is not one)', function ()
    if not parser_available('erlang') then skip 'no erlang parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local function put(f, s) local fd = assert(io.open(root .. '/' .. f, 'w')); fd:write(s); fd:close() end
    put('m.erl', '-module(m).\n-export([h/0, loop/1]).\nh() -> lists:map(fun k/1, [1]), [fun j/2].\n'
        .. 'k(X) -> X.\nj(A, B) -> {A, B}.\nj(A) -> A.\nloop(X) -> F = fun loop/1, F(X).\n')
    local data = ts.extract(root)
    vim.fn.delete(root, 'rf')
    local refs = {}
    for _, e in ipairs(data.edges) do if e.kind == 'ref' then refs[#refs + 1] = e.from .. ' -> ' .. e.to .. (e.inferred and ' ~' or '') end end
    table.sort(refs)
    eq({ 'm.erl::h@2 -> m.erl::j@4 ~', 'm.erl::h@2 -> m.erl::k@3 ~' }, refs, 'j/2 (not j/1), k/1; loop names itself: no edge')
end)

-- CART-1133: a call inside a -define body happens wherever the macro is USED. The body is not code, so no call was
-- recorded, and functions only macros call read as dead (tr/2 behind ?INFO_IDENTITY, security_headers behind ?HTTP_OK).
test('erlang: each use of a macro references the same-file functions its body calls (transitively, by macro arity)', function ()
    if not parser_available('erlang') then skip 'no erlang parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local function put(f, s) local fd = assert(io.open(root .. '/' .. f, 'w')); fd:write(s); fd:close() end
    put('m.erl', '-module(m).\n-define(A(X), [tr(X)]).\n-define(B, ?A(1) ++ h()).\n-define(H(T), x:y(T)).\n'
        .. '-define(H(A, B), g(A) ++ B).\nf() -> ?B.\nk() -> ?H(1, 2).\ntr(X) -> X.\nh() -> [].\ng(A) -> A.\nu() -> ?H(1).\n'
        .. 'y(T) -> T.\n') -- a LOCAL y/1: the remote `x:y(T)` in ?H/1 must not reach it
    local data = ts.extract(root)
    vim.fn.delete(root, 'rf')
    local refs = {}
    for _, e in ipairs(data.edges) do
        if e.kind == 'ref' or e.kind == 'reg' then refs[#refs + 1] = e.kind .. ' ' .. (e.from:match('::(%w+)') or e.from) .. '->' .. e.to:match('::(%w+)') end
    end
    table.sort(refs)
    eq({ 'ref f->h', 'ref f->tr', 'ref k->g' }, refs,
        '?B reaches h and, through ?A, tr; ?H/2 reaches g; ?H/1 is a remote call; a use inside a -define is not a use site')
end)
