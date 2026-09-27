-- cartograph.erlmsg (CART-1130 step 4): a gen_server call/cast site reaches the handle_call/handle_cast clause its
-- message unifies with, first match. The server is explicit (?MODULE, a module atom, or built from one through a
-- binding or a single-clause helper) or chosen by the message among SPECIFIC clauses (a catch-all is no evidence).

local ts = require 'cartograph.providers.treesitter'

local FILES = {
    ['srv.erl'] = table.concat({
        '-module(srv).',
        '-behaviour(gen_server).',
        'get(K) -> gen_server:call(?MODULE, {get, K}).',
        'odd() -> gen_server:call(?MODULE, nope).',                           -- falls to the catch-all
        'proc(H) -> gen_mod:get_module_proc(H, ?MODULE).',
        'reload(H) -> Proc = proc(H), gen_server:cast(Proc, {reload, 1}).',    -- built from ?MODULE via a helper
        'r2(H) -> P = srv2:name(H, ?MODULE), gen_server:cast(P, {reload, 2}).', -- srv2 is the CALLEE module, not the server
        'handle_call({get, K}, _From, S) -> {reply, K, S};',
        'handle_call(stop, _From, S) -> {stop, normal, S};',                  -- no site sends stop
        'handle_call(_Req, _From, S) -> {reply, error, S}.',
        'handle_cast({reload, X}, S) -> {noreply, X};',
        'handle_cast(unused_msg, S) -> {noreply, S}.',                         -- no site sends it
    }, '\n') .. '\n',
    ['srv2.erl'] = table.concat({
        '-module(srv2).',
        '-behaviour(gen_server).',
        'handle_call(get_state, _From, S) -> {reply, S, S};',
        'handle_call(_Req, _From, S) -> {reply, error, S}.',
        'handle_cast({reload, X}, S) -> {noreply, X}.',                       -- would make r2 ambiguous by message
        'name(H, M) -> {H, M}.',
    }, '\n') .. '\n',
    ['cli.erl'] = table.concat({
        '-module(cli).',
        'ask(Mod) -> gen_server:call(Mod, get_state).',                       -- by message: srv2 only
        'other(P) -> gen_server:call(P, {weird, 1}).',                          -- no specific clause anywhere
    }, '\n') .. '\n',
}

test('erlmsg: messages reach their clauses — explicit (?MODULE, via a helper, a catch-all) and by message', function ()
    if not parser_available('erlang') then skip 'no erlang parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    for f, s in pairs(FILES) do local fd = assert(io.open(root .. '/' .. f, 'w')); fd:write(s); fd:close() end
    local data = ts.extract(root)
    local s = require('cartograph.erlmsg').attach(data)
    vim.fn.delete(root, 'rf')
    local edges = {}
    for _, e in ipairs(data.edges) do
        if e.msg then
            edges[#edges + 1] = ('%s->%s %s@%s'):format(e.from:match('::([%w_]+)'), e.to:match('^(%w+)'), e.msg,
                table.concat(e.clauses, ','))
        end
    end
    table.sort(edges)
    eq({ 'ask->srv2 call@3', 'get->srv call@8', 'odd->srv call@10', 'r2->srv cast@11', 'reload->srv cast@11' }, edges)
    eq(4, s.explicit); eq(2, s.by_message); eq(1, s.unknown_target)
    local un = {}
    for _, u in ipairs(s.unreached) do un[#un + 1] = u.module .. ':' .. u.pattern end
    table.sort(un)
    eq({ 'srv2:{reload, X}', 'srv:stop', 'srv:unused_msg' }, un, 'the specific clauses no site in the tree sends to')
end)

test('erlmsg.unify: three-valued over the syntax', function ()
    if not parser_available('erlang') then skip 'no erlang parser' end
    local function node(src)
        local p = vim.treesitter.get_string_parser('f() -> ' .. src .. '.', 'erlang')
        local r = p:parse()[1]:root()
        local b = r:named_child(0):named_child(0):field('body')[1]
        return b:named_child(0), 'f() -> ' .. src .. '.'
    end
    local U = require('cartograph.erlmsg').unify
    local function u(p, v) local pn, ps = node(p); local vn, vs = node(v); return U(pn, ps, vn, vs) end
    eq('yes', u('{get, K}', '{get, 1}')); eq('no', u('{get, K}', '{put, 1}')); eq('no', u('{get, K}', '{get, 1, 2}'))
    eq('unknown', u('{get, K}', 'Msg'), 'a variable message could be anything')
    eq('no', u('stop', '{stop}')); eq('yes', u("'a'", 'a'))
end)

-- gen_statem: the callback mode decides the receiver. handle_event_function -> handle_event/4 (event type, content);
-- state_functions -> every state function (the current state is dynamic), gen_statem's own arity-3 callbacks
-- (terminate/3) excluded — read from the otp-api profile.
local STATEM = {
    ['hs.erl'] = table.concat({
        '-module(hs).',
        '-behaviour(gen_statem).',
        'callback_mode() -> handle_event_function.',
        'handle_event({call, From}, {get, K}, _S, D) -> {keep_state, D, [{reply, From, K}]};',
        'handle_event(cast, {put, K}, _S, D) -> {keep_state, K};',
        'handle_event(info, {tick}, _S, D) -> {keep_state, D};',           -- another event source: not "unreached"
        'handle_event(cast, never, _S, D) -> {keep_state, D}.',             -- no site casts it
    }, '\n') .. '\n',
    ['sf.erl'] = table.concat({
        '-module(sf).',
        '-behaviour(gen_statem).',
        'callback_mode() -> state_functions.',
        'halt() -> gen_statem:cast(?MODULE, stop).',
        'idle({call, From}, go, D) -> {next_state, busy, D, [{reply, From, ok}]};',
        'idle(cast, _Any, D) -> {keep_state, D}.',
        'busy(cast, stop, D) -> {stop, normal, D}.',
        'terminate(_R, _S, _D) -> ok.',                                     -- a callback, not a state
    }, '\n') .. '\n',
    ['user.erl'] = table.concat({
        '-module(user).',
        'a(P) -> gen_statem:call(P, {get, 1}).',
        'b(P) -> gen_statem:cast(P, {put, 2}).',
        'c(P) -> gen_statem:call(P, {put, 3}).',                             -- {put, _} is only a CAST clause
    }, '\n') .. '\n',
}

test('erlmsg/gen_statem: handle_event_function admits by event type; state_functions reach every handling state', function ()
    if not parser_available('erlang') then skip 'no erlang parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    for f, s in pairs(STATEM) do local fd = assert(io.open(root .. '/' .. f, 'w')); fd:write(s); fd:close() end
    local data = ts.extract(root)
    local s = require('cartograph.erlmsg').attach(data)
    vim.fn.delete(root, 'rf')
    local edges = {}
    for _, e in ipairs(data.edges) do
        if e.msg then edges[#edges + 1] = ('%s->%s %s@%s'):format(e.from:match('::([%w_]+)'), e.to:match('::([%w_]+)'), e.msg, table.concat(e.clauses, ',')) end
    end
    table.sort(edges)
    eq({ 'a->handle_event statem_call@4', 'b->handle_event statem_cast@5', 'halt->busy statem_cast@7', 'halt->idle statem_cast@6' }, edges,
        'the cast to ?MODULE reaches idle (its catch-all) and busy; terminate/3 is not a state; c reaches nothing')
    eq(1, s.unknown_target, '{put, 3} as a CALL: the only {put, _} clause admits cast')
    local un = {}
    for _, u in ipairs(s.unreached) do un[#un + 1] = u.module .. ':' .. u.pattern end
    table.sort(un)
    eq({ 'hs:never', 'sf:go' }, un, 'info {tick} is another event source; idle go is only CALLed and nothing calls it')
end)
