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
