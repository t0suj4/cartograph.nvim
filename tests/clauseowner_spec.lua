-- CART-2115: a multi-clause function (erlang clauses, haskell equations — spec.merge_equations) is ONE node whose range
-- grows clause by clause; the merge moved the range's END LINE but kept the first clause's END COLUMN, so on the last
-- clause's last line every call past that column was owned by no function: no caller edge. ejabberd 156 calls, ghc's
-- compiler/GHC/Core 135; after the fix 0, and nothing resolves differently.

local ts = require 'cartograph.providers.treesitter'

test('clause owner: a call on the LAST clause\'s last line, past the first clause\'s end column, is the function\'s (CART-2115)', function ()
    if not parser_available('erlang') then skip 'no erlang parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/m.erl', 'w'))
    fd:write(table.concat({
        '-module(m).',
        '-export([fmt/1]).',
        'fmt([]) ->',
        '    "(empty)";',
        'fmt(L) ->',
        '    string:join(lists:sort(L), ", ").', -- line 5: lists:sort sits past col 13
        '' }, '\n'))
    fd:close()
    local data = ts.extract(root)
    local owners = {}
    for _, c in ipairs(data.calls) do if c.line == 5 then owners[c.callee] = c.fn end end
    eq('m.erl::fmt@2', owners.join)
    eq('m.erl::fmt@2', owners.sort, 'the inner call is the function\'s too: ' .. vim.inspect(owners))
    vim.fn.delete(root, 'rf')
end)
