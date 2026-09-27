-- cartograph.erldispatch (CART-1130 step 2): a dynamic `Mod:f(...)` reaches the implementers of the behaviour that
-- obliges f. Pinned both ways per rule: own / single / several (the union, marked ambiguous) / none (no edge), an
-- implementer that skipped an optional callback gets none, and the caller is never its own target.

local ts = require 'cartograph.providers.treesitter'

local function tree_of(files)
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    for f, s in pairs(files) do local fd = assert(io.open(root .. '/' .. f, 'w')); fd:write(s); fd:close() end
    local data = ts.extract(root)
    local stats = require('cartograph.erldispatch').attach(data)
    vim.fn.delete(root, 'rf')
    return data, stats
end

local function dyn_targets(data, from_pat)
    local out = {}
    for _, e in ipairs(data.edges) do
        if e.dyn and e.from:match(from_pat) then out[#out + 1] = e.to:match('^([%w_]+)%.erl') .. (e.pop_ambiguous and '?' or '') end
    end
    table.sort(out)
    return out
end

test('erldispatch: a behaviour calling its OWN callback reaches exactly its implementers (not itself)', function ()
    if not parser_available('erlang') then skip 'no erlang parser' end
    local data, s = tree_of({
        ['auth.erl'] = '-module(auth).\n-callback start(term()) -> ok.\n-callback reload(term()) -> ok.\n'
            .. '-optional_callbacks([reload/1]).\n'
            .. 'start(H, Ms) -> lists:foreach(fun(M) -> M:start(H) end, Ms).\n'
            .. 'reload(H, Ms) -> lists:foreach(fun(M) -> M:reload(H) end, Ms).\n',
        ['auth_sql.erl'] = '-module(auth_sql).\n-behaviour(auth).\nstart(H) -> H.\nreload(H) -> H.\n',
        ['auth_ldap.erl'] = '-module(auth_ldap).\n-behaviour(auth).\nstart(H) -> H.\n', -- no reload/1: optional
        ['other.erl'] = '-module(other).\nstart(H) -> H.\n',                             -- same name, not an implementer
    })
    eq({ 'auth_ldap', 'auth_sql' }, dyn_targets(data, '^auth%.erl::start'), 'start/1 -> both implementers')
    eq({ 'auth_sql' }, dyn_targets(data, '^auth%.erl::reload'), 'reload/1 -> only the one that defines the optional callback')
    eq(2, s.own); eq(0, s.none)
    for _, c in ipairs(data.calls) do if c.dynamic then eq(nil, c.to, 'the call itself stays dynamic') end end
end)

test('erldispatch: one declaring behaviour elsewhere is precise; several give the union, marked ambiguous; none gives nothing', function ()
    if not parser_available('erlang') then skip 'no erlang parser' end
    local data, s = tree_of({
        ['store.erl'] = '-module(store).\n-callback put(term()) -> ok.\n-callback init(term()) -> ok.\n',
        ['cache.erl'] = '-module(cache).\n-callback init(term()) -> ok.\n',
        ['store_a.erl'] = '-module(store_a).\n-behaviour(store).\nput(X) -> X.\ninit(X) -> X.\n',
        ['cache_a.erl'] = '-module(cache_a).\n-behaviour(cache).\ninit(X) -> X.\n',
        ['user.erl'] = '-module(user).\nf(M, X) -> M:put(X), M:init(X), M:frob(X), M:put(X, X).\n', -- put/2: no such callback
    })
    eq({ 'cache_a?', 'store_a', 'store_a?' }, dyn_targets(data, '^user%.erl'))
    eq(1, s.single); eq(1, s.several); eq(2, s.none, 'frob/1, and put/2 (the callback is put/1: arity is part of the key)')
end)
