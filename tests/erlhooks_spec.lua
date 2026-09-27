-- cartograph.erlhooks (CART-1130 step 3): a keyed registry's dispatch, both sides derived. A miniature ejabberd:
-- `gen` interprets `{hook, Name, Function, Seq}` tuples into `hooks:add(Name, Host, Module, Function, Seq)`, `hooks`
-- runs handlers through apply/3, and xlang's add_iq_handler carrier marks `gen`'s interpreter as the generating one.

local ts = require 'cartograph.providers.treesitter'

local FILES = {
    ['gen.erl'] = table.concat({
        '-module(gen).',
        'start_module(Host, Module, Opts) ->',
        '    case Module:start(Host, Opts) of {ok, Regs} -> add_registrations(Host, Module, Regs); _ -> ok end.',
        'add_registrations(Host, Module, Regs) ->',
        '    lists:foreach(fun({hook, Hook, Function, Seq}) -> hooks:add(Hook, Host, Module, Function, Seq);',
        '                     ({iq_handler, C, NS, F}) -> gen_iq_handler:add_iq_handler(C, Host, NS, Module, F)',
        '                  end, Regs).',
        'del_registrations(Host, Module, Regs) ->',
        '    lists:foreach(fun({hook, Hook, Function, Seq}) -> hooks:delete(Hook, Host, Module, Function, Seq);',
        '                     ({iq_handler, C, NS, _F}) -> gen_iq_handler:remove_iq_handler(C, Host, NS)',
        '                  end, Regs).',
    }, '\n') .. '\n',
    ['hooks.erl'] = table.concat({
        '-module(hooks).',
        '-export([add/5, delete/5, run/3, handlers/1]).',
        'add(_H, _Host, _M, _F, _S) -> ok.',
        'delete(H, _Host, M, F, _S) -> apply(M, F, [H]).',  -- invokes, but it is the twin interpreter's EFFECT: not dispatch
        'run(Hook, _Host, Args) -> [call_one(M, F, Args) || {M, F} <- handlers(Hook)].',
        'call_one(M, F, Args) -> apply(M, F, Args).',
        'handlers(_Hook) -> [].',  -- takes the key, invokes nothing: NOT dispatch
    }, '\n') .. '\n',
    ['mod_a.erl'] = table.concat({
        '-module(mod_a).',
        '-export([start/2, on_send/1, on_login/1, never_run/1]).',
        'stop(Host) -> hooks:delete(user_send, Host, mod_a, on_send, 50).',
        'start(Host, _Opts) ->',
        '    hooks:add(user_login, Host, mod_a, on_login, 50),',               -- a DIRECT registration
        '    {ok, [{hook, user_send, on_send, 50}, {hook, orphan, never_run, 10}]}.',
        'on_send(P) -> P.', 'on_login(U) -> U.', 'never_run(X) -> X.',
    }, '\n') .. '\n',
    ['router.erl'] = table.concat({
        '-module(router).',
        'route(P) -> hooks:run(user_send, h, [P]), hooks:run(user_login, h, [P]), hooks:run(nobody_listens, h, [P]),',
        '            hooks:handlers(user_send).',
    }, '\n') .. '\n',
}

test('erlhooks: a run site reaches the handlers registered under its key, by tuple and by direct call', function ()
    if not parser_available('erlang') then skip 'no erlang parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    for f, s in pairs(FILES) do local fd = assert(io.open(root .. '/' .. f, 'w')); fd:write(s); fd:close() end
    local data = ts.extract(root)
    local s = require('cartograph.erlhooks').attach(data)
    vim.fn.delete(root, 'rf')
    local edges = {}
    for _, e in ipairs(data.edges) do
        if e.hook then edges[#edges + 1] = e.from:match('^(%w+)') .. '->' .. e.to:match('::([%w_]+)') .. ' [' .. e.hook .. ']' end
    end
    table.sort(edges)
    eq({ 'router->on_login [user_login]', 'router->on_send [user_send]' }, edges,
        'the tuple registration (on_send) and the direct call (on_login); handlers/1 shares the key and dispatches nothing')
    eq(3, s.registrations, 'two tuples and one direct call; the interpreter\'s own effect calls name no key')
    eq(2, s.unkeyed)
    eq(3, s.sites, 'run x3; handlers/1 is not a dispatch site')
    eq(1, s.unregistered.nobody_listens, 'a key run with no registration is reported')
    eq(true, s.unrun.orphan, 'a registration never run is reported')
end)
