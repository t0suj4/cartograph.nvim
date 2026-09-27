-- WHICH CLAUSE A CALL REACHES (lua/cartograph/erlclauses.lua, CART-1110): a call site is its callee's peer.

local function need() if not parser_available('erlang') then skip 'no erlang parser' end end

test('erlclauses: exact / possible / none per call site; unreached clauses only where every caller is in the module', function ()
    need()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    local fd = assert(io.open(dir .. '/m.erl', 'w'))
    fd:write(table.concat({
        '-module(m).',
        '-export([pub/1]).',
        'f(a) -> 1;', 'f(b) -> 2.',
        'g(x) -> 1;', 'g(_) -> 2.',
        'p(<<"!", R/binary>>) -> R;', 'p(B) -> B.',
        'h(1) -> one;', 'h(_) -> other.',
        'pub(1) -> one;', 'pub(_) -> other.',
        '-ifdef(X).', 'v() -> 1.', '-else.', 'v() -> 2.', '-endif.',
        'run(U) -> f(a), f(c), g(x), p(U), lists:map(fun h/1, [1]), pub(1), v().', '' }, '\n'))
    fd:close()
    local EC = require 'cartograph.erlclauses'
    local rows, st, un = EC.census(dir)
    local by = {}
    for _, r in ipairs(rows) do by[r.callee .. '@' .. (r.args[1] and require('cartograph.algebra').load().show(r.args[1]) or '')] = r end
    eq('exact', by['m:f/1@"a"'].kind)
    eq(1, by['m:f/1@"a"'].clause)
    -- no clause takes f(c): a function_clause crash waiting
    eq('none', by['m:f/1@"c"'].kind)
    eq(1, st.none)
    -- an unreadable pattern (a binary with a tail) is constrained: both clauses of p only may take an unknown
    local pkind
    for _, r in ipairs(rows) do if r.callee == 'm:p/1' then pkind = r.kind end end
    eq('possible', pkind)
    -- unreached: g's catch-all (its only caller passes x); NOT h (a fun value), NOT pub (exported), NOT v (variants),
    -- NOT p's second clause (an unknown argument may take it)
    local names = {}
    for _, u in ipairs(un) do names[#names + 1] = u.callee .. '#' .. u.clause end
    table.sort(names)
    eq({ 'm:f/1#2', 'm:g/1#2' }, names)
    eq(1, st.fun_values)
    eq(1, st.exported_skipped)
    eq(1, st.variants)
end)
