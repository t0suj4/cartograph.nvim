-- THE PEER GENERATOR (lua/cartograph/peergen.lua, the protocol-free core; lua/cartograph/xmpppeer.lua, the XMPP IQ
-- adapter; CART-1138): an implementation's accepted requests become a generated client's operations.

local function sandboxed(src)
    local chunk = assert(loadstring(src, '=generated'))
    setfenv(chunk, { ipairs = ipairs, pairs = pairs, table = table, string = string, tostring = tostring,
        tonumber = tonumber, error = error, type = type, select = select, next = next })
    return chunk()
end

test('peergen: the core generates a client for a NON-XMPP model, and the client needs nothing but itself', function ()
    local PG = require 'cartograph.peergen'
    -- a key-value protocol: get(Key) -> {found, V} | missing
    local model = { name = 'kv', operations = { {
        name = 'get', params = { 'Key' },
        request = { k = 'tuple', kids = { { k = 'lit', v = 'get', lk = 'atom' }, { k = 'hole', h = 'Key' } } },
        replies = {
            { name = 'found', term = { k = 'tuple', kids = { { k = 'lit', v = 'found', lk = 'atom' }, { k = 'hole', h = 'o1' } } } },
            { name = 'missing', term = { k = 'lit', v = 'missing', lk = 'atom' } },
        } } } }
    local src = PG.generate(model)
    ok(not src:find('require', 1, true), 'the generated client requires nothing')
    local C = sandboxed(src)
    local store = { a = 'v1' }
    local client = C.new({ exchange = function (req)
        local key = req.kids[2].v
        if store[key] then return C.term.node('tuple', C.term.lit('found', 'atom'), C.term.lit(store[key], 'bin')) end
        return C.term.lit('missing', 'atom')
    end })
    local case, env = client.get({ Key = C.term.lit('a', 'bin') })
    eq('found', case)
    eq('v1', env.o1.v)
    eq('missing', (client.get({ Key = C.term.lit('b', 'bin') })))
    -- a reply no case describes is named, never forced into one
    local odd = C.new({ exchange = function () return C.term.lit('boom', 'atom') end })
    local c2, why = odd.get({ Key = C.term.lit('a', 'bin') })
    eq(nil, c2)
    eq('unrecognized reply', why)
    ok(not pcall(client.get, {}), 'a missing argument is an error')
    -- ★ the core knows no protocol
    local fd = io.open(debug.getinfo(PG.generate, 'S').source:sub(2)); local core = fd:read('a'); fd:close()
    for _, word in ipairs { 'xmpp', 'rec:iq', 'erlterms', 'ejabberd' } do
        local code = core:gsub('%-%-[^\n]*', '')
        ok(not code:find(word, 1, true), 'no ' .. word .. ' in the core\'s code')
    end
end)

test('peergen: the runtime matcher — a sequence hole binds the middle and fills back; literal kinds are kept', function ()
    local PG = require 'cartograph.peergen'
    local C = sandboxed(PG.generate({ name = 'empty', operations = {} }))
    local R = C.runtime
    local L = function (v, lk) return R.lit(v, lk) end
    local p = R.node('list', L('a'), { k = 'hole', h = 'R', rep = true }, L('z'))
    local t = R.node('list', L('a'), L('b'), L('c'), L('z'))
    local env = R.match(p, t, {})
    ok(env, 'matches')
    eq(2, #env.R.kids)
    ok(R.equal(R.fill(p, env), t), 'fill(match) gives the term back')
    eq(nil, R.match(p, R.node('list', L('a')), {}), 'too short for the fixed ends')
    -- the atom `get` is not the binary <<"get">>; a literal of unknown kind never clashes
    eq(nil, R.match(L('get', 'atom'), L('get', 'bin'), {}))
    ok(R.match(L('get'), L('get', 'bin'), {}))
    -- a repeated hole must bind equal values
    eq(nil, R.match(R.node('tuple', { k = 'hole', h = 'X' }, { k = 'hole', h = 'X' }), R.node('tuple', L('1'), L('2')), {}))
    -- and the verdicts agree with erlterms.match on the same pairs
    local ET = require 'cartograph.erlterms'
    local A = require('cartograph.algebra').load()
    eq('yes', (ET.match(A.node('list', A.lit('a'), A.hole('R', true), A.lit('z')), A.node('list', A.lit('a'), A.lit('b'), A.lit('c'), A.lit('z')))))
    eq('no', (ET.match(A.node('list', A.lit('a'), A.hole('R', true), A.lit('z')), A.node('list', A.lit('a')))))
end)

local function need() if not parser_available('erlang') then skip 'no erlang parser' end end

test('xmpppeer: a server\'s clauses become operations — envelope to the transport, a default that shadows retried as a parameter', function ()
    need()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root .. '/src', 'p')
    local fd = assert(io.open(root .. '/src/mod_t.erl', 'w'))
    fd:write(table.concat({
        '-module(mod_t).',
        '-record(iq, {id = <<>>, type, lang = <<>>, from, to, sub_els = [], meta = #{}}).',
        '-record(disco_info, {node = <<>>, identities = [], features = [], xdata = []}).',
        'start(Host) -> gen_iq_handler:add_iq_handler(ejabberd_local, Host, ?NS_DISCO_INFO, ?MODULE, process_iq),',
        '    gen_iq_handler:add_iq_handler(ejabberd_local, Host, ?NS_VERSION, ?MODULE, any_iq),',
        '    gen_iq_handler:add_iq_handler(ejabberd_local, Host, ?NS_PING, ?MODULE, ping_iq).',
        'any_iq(IQ) -> IQ#iq{type = result}.',
        -- two -ifdef variants of one handler: the second definition's clause is NOT shadowed by the first's
        '-ifdef(OLD).', 'ping_iq(#iq{type = get} = IQ) -> IQ#iq{type = result};', 'ping_iq(IQ) -> IQ.',
        '-else.', 'ping_iq(#iq{type = get} = IQ) -> IQ#iq{type = error}.', '-endif.',
        'process_iq(#iq{type = set} = IQ) -> IQ#iq{type = error};',
        'process_iq(#iq{type = get, sub_els = [#disco_info{node = <<"">>}]} = IQ) -> IQ#iq{type = result, sub_els = [top]};',
        'process_iq(#iq{type = get, sub_els = [#disco_info{}]} = IQ) -> IQ#iq{type = result, sub_els = [node]}.', '' }, '\n'))
    fd:close()
    local XP = require 'cartograph.xmpppeer'
    local PG = require 'cartograph.peergen'
    local model, st, index, P = XP.model(root, {})
    eq(7, st.clauses)
    -- the -else definition's get clause is reachable in ITS build (first match is within a definition)
    local ping_cands = 0
    for _, cands in pairs(index) do for _, c in ipairs(cands) do if c.fn == 'ping_iq' then ping_cands = ping_cands + 1 end end end
    eq(3, ping_cands, 'both definitions\' clauses are candidates')
    -- a head that takes ANY iq is the generic request: type, destination and payload the caller's
    eq(2, st.generic or 0)
    eq(0, st.shadowed, 'nothing unreachable left')
    eq(1, st.widened or 0, '#3 is reachable only with a node that is not ""')
    local by = {}
    for _, op in ipairs(model.operations) do by[op.name] = op end
    ok(by.disco_info_set and by.disco_info_get and by.disco_info_get_2, vim.inspect(vim.tbl_keys(by)))
    ok(by.version_any, vim.inspect(vim.tbl_keys(by)))
    eq({ 'SubEls', 'To', 'Type' }, by.version_any.params)
    -- the envelope is the transport's; the destination and the widened field are the caller's
    local widened
    for _, op in ipairs(model.operations) do if vim.tbl_contains(op.params, 'Node') then widened = op end end
    ok(widened, 'one op takes the node as a parameter')
    local shown = PG.serialize(widened.request)
    ok(shown:find('h="@id"', 1, true) and shown:find('h="@from"', 1, true), shown)
    eq({ 'Node', 'To' }, widened.params)
    -- the client, in process: the handler answers, the node picks the clause
    local C = sandboxed(PG.generate(model))
    eq(6, vim.tbl_count(C.operations))
    local ET = require 'cartograph.erlterms'
    local A = require('cartograph.algebra').load()
    local client = C.new({ exchange = function (req, op)
        local c = index[op.name][1]
        return (ET.call(P, c.mod, c.fn, { req }, ET.session()))
    end })
    local jid = A.node('rec:jid', A.lit('u'), A.lit('s'), A.lit('r'))
    local case, _, rep = client[widened.name]({ Node = A.lit('n', 'bin'), To = jid })
    eq('result', case)
    ok(A.show(rep):find('(list "node")', 1, true), 'the node picked clause #3: ' .. A.show(rep))
    local other
    for name, op in pairs(C.operations) do
        if name ~= widened.name and name:match('^disco_info_get') and op.request.kids[2].v == 'get' then other = name end
    end
    local _, _, rep2 = client[other]({ To = jid })
    ok(A.show(rep2):find('(list "top")', 1, true), 'the empty node is clause #2: ' .. A.show(rep2))
end)

test('peergen: the core refuses two operations under one name (one would silently overwrite the other)', function ()
    local PG = require 'cartograph.peergen'
    local op = { name = 'x', params = {}, request = { k = 'lit', v = 'a' }, replies = {} }
    ok(not pcall(PG.generate, { name = 'dup', operations = { op, op } }))
end)

test('grpcpeer: the SECOND instance — .proto rpcs become operations through the same core; copies merge, drift is kept', function ()
    local GP = require 'cartograph.grpcpeer'
    local PG = require 'cartograph.peergen'
    local root = vim.fn.tempname()
    local base = table.concat({
        'syntax = "proto3";', 'package shop;',
        'service Cart {', '  rpc Add(AddReq) returns (Empty) {}', '  rpc Watch(WatchReq) returns (stream Item) {}', '}',
        'message Item { string id = 1; int32 qty = 2; }',
        'message AddReq { string user = 1; Item item = 2; repeated string tags = 3; }',
        'message WatchReq { string user = 1; }', 'message Empty {}', '' }, '\n')
    for _, d in ipairs { 'a', 'b', 'c' } do vim.fn.mkdir(root .. '/' .. d, 'p') end
    local function write(path, text) local fd = assert(io.open(path, 'w')); fd:write(text); fd:close() end
    write(root .. '/a/shop.proto', base)
    write(root .. '/b/shop.proto', base)                                              -- an identical vendored copy
    write(root .. '/c/shop.proto', (base:gsub('repeated string tags = 3;', 'repeated string tags = 3; bool gift = 4;')))  -- drifted
    local model, st = GP.model(root)
    eq(3, st.files)
    eq(1, st.drift, 'the copy with an extra field is kept apart')
    local by = {}
    for _, op in ipairs(model.operations) do by[op.name] = op end
    ok(by.Cart_Add and by.Cart_Add_v2 and by.Cart_Watch, vim.inspect(vim.tbl_keys(by)))
    eq({ 'user', 'item', 'tags' }, by.Cart_Add.params)
    eq({ 'user', 'item', 'tags', 'gift' }, by.Cart_Add_v2.params)
    -- a server stream replies with a sequence
    eq('list', by.Cart_Watch.replies[1].term.k)
    -- the same core, standalone, at the simulated fidelity: a canned reply of the response shape is ok, a status error
    local src = PG.generate(model)
    ok(not src:find('require', 1, true))
    local chunk = assert(loadstring(src))
    setfenv(chunk, { ipairs = ipairs, pairs = pairs, table = table, string = string, tostring = tostring,
        tonumber = tonumber, error = error, type = type, select = select, next = next })
    local C = chunk()
    local canned = C.new({ exchange = function () return { k = 'rec:Empty', kids = {} } end })
    local args = { user = C.term.lit('u', 'bin'), item = C.term.lit('i', 'bin'), tags = C.term.node('list') }
    eq('ok', (canned.Cart_Add(args)))
    local failing = C.new({ exchange = function ()
        return C.term.node('tuple', C.term.lit('error', 'atom'), C.term.lit('5', 'int'), C.term.lit('not found', 'bin'))
    end })
    local case, env = failing.Cart_Add(args)
    eq('error', case)
    eq('not found', env.message.v)
end)
