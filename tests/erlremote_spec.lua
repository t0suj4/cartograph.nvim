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
