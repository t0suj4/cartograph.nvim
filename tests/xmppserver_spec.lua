-- THE SERVER LEG AS ROWS (lua/cartograph/xmppserver.lua): every registered IQ endpoint over both carriers, its
-- handler, and the handler's clause heads as read sets. Real namespace macros, because the URI comes from the
-- distilled vocabulary (erl-macros.mpack) and an invented ?NS_FIXTURE could never be valued (see erlreg_spec).

local function need() if not parser_available('erlang') then skip 'no erlang parser' end end

local function fixture()
    local ts = require 'cartograph.providers.treesitter'
    local store = require 'cartograph.store'
    local root = vim.fn.tempname(); vim.fn.mkdir(root .. '/src', 'p')
    local fd = assert(io.open(root .. '/src/mod_t.erl', 'w'))
    fd:write([[
-module(mod_t).
reg(Host) ->
    gen_iq_handler:add_iq_handler(ejabberd_local, Host, ?NS_TIME, ?MODULE, process_iq).
helper(Component, Host, NS, Module, Function) ->
    gen_iq_handler:add_iq_handler(Component, Host, NS, Module, Function).
start(_Host, _Opts) ->
    {ok, [{iq_handler, ejabberd_sm, ?NS_BLOCKING, process_sm_iq},
          {iq_handler, ejabberd_sm, ?NS_TIME, mod_nowhere, gone_iq}]}.
process_iq(#iq{type = get, sub_els = [#disco_info{node = Node}]} = IQ) -> {IQ, Node};
process_iq(#iq{type = set} = IQ) -> IQ.
process_sm_iq(IQ) -> IQ.
]])
    fd:close()
    local data = ts.extract(root)
    store.ingest(data)
    return data, store
end

test('xmppserver: endpoints over BOTH carriers, each with its URI and resolved handler; helpers and misses are named', function ()
    need()
    local X = require 'cartograph.xmppserver'
    local data = fixture()
    local rows, st = X.endpoints(data)
    eq(2, st.call, 'two add_iq_handler sites')
    eq(1, st.not_literal, 'one is a helper whose slots are its parameters')
    eq(2, st.tuple, 'two tuple registrations')
    eq(1, st.unresolved, 'mod_nowhere:gone_iq resolves to nothing, and says so')
    local got = {}
    for _, r in ipairs(rows) do
        if not r.why then got[#got + 1] = r.carrier .. ' ' .. r.uri .. ' ' .. r.fn end
    end
    table.sort(got)
    eq({ 'call urn:xmpp:time process_iq', 'tuple urn:xmpp:blocking process_sm_iq' }, got)
end)

test('xmppserver: a handler reads what its heads destructure — constants and bindings by path', function ()
    need()
    local X = require 'cartograph.xmppserver'
    local data, store = fixture()
    local rows = X.endpoints(data)
    local call
    for _, r in ipairs(rows) do if r.carrier == 'call' and r.handler then call = r end end
    local rd = X.reads(store, call.handler)
    eq(2, rd.clauses)
    eq('#iq.type=get  #iq.sub_els [1] #disco_info.node->Node', X.head_line(rd.heads[1]))
    eq('#iq.type=set', X.head_line(rd.heads[2]))
    eq(nil, (X.reads(store, nil)), 'no handler, no read set')
end)

test('xmppserver.sends: what a handler SENDS, as a term — a literal response, a routed parameter, a call', function ()
    need()
    local X = require 'cartograph.xmppserver'
    local ER = require 'cartograph.erlrecords'
    local root = vim.fn.tempname(); vim.fn.mkdir(root .. '/src', 'p')
    local fd = assert(io.open(root .. '/src/mod_s.erl', 'w'))
    fd:write([[
-module(mod_s).
-record(disco_info, {node = <<>>, identities = [], features = [], xdata = []}).
process_iq(IQ) -> xmpp:make_iq_result(IQ, #disco_info{features = [<<"urn:x">>]}).
forward(Pkt) -> ejabberd_router:route(Pkt).
later(IQ) -> xmpp:make_iq_result(IQ, build()).
]])
    fd:close()
    local rows = X.sends(root .. '/src', { E = ER.new {} })
    vim.fn.delete(root, 'rf')
    eq(3, #rows)
    local by = {}
    for _, r in ipairs(rows) do by[r.fn] = r end
    eq('complete', by['process_iq/1'].status)
    eq('disco_info', by['process_iq/1'].record)
    eq('(rec:disco_info "" (nil) (cons "urn:x" (nil)) (nil))', require('cartograph.algebra').load().show(by['process_iq/1'].term))
    eq('opaque', by['forward/1'].status, 'a routed parameter: step 4')
    eq('opaque', by['later/1'].status, 'a call result: step 3')
end)
