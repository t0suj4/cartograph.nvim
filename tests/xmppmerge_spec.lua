-- MERGE ACROSS THE WIRE (lua/cartograph/xmppmerge.lua): client IQ requests decoded through the codec spec, unified
-- with the handler clause heads, composed into client-function -> handler-clause edges. Fixtures only: a client
-- directory of stx templates, an erlang module registering a handler under a REAL namespace macro (the URI comes
-- from the distilled vocabulary), and a spec of forms copied VERBATIM from xmpp's xmpp_codec.spec.

local function need()
    if not (parser_available('erlang') and parser_available('javascript') and parser_available('xml')) then
        skip 'needs the erlang, javascript and xml parsers'
    end
end

local SPEC = [=[
-record(jid, {user = <<>>, server = <<>>, resource = <<>>, luser = <<>>, lserver = <<>>, lresource = <<>>}).

-record(iq, {id = <<>> :: binary(),
             type :: iq_type(),
             lang = <<>> :: binary(),
             from :: undefined | jid:jid(),
             to :: undefined | jid:jid(),
             sub_els = [] :: [xmpp_element() | fxml:xmlel()],
	     meta = #{} :: map()}).

-xml(iq,
     #elem{name = <<"iq">>,
           xmlns = [<<"jabber:client">>, <<"jabber:server">>,
		    <<"jabber:component:accept">>],
	   module = rfc6120,
           result = {iq, '$id', '$type', '$lang', '$from', '$to', '$_els', '$_'},
           attrs = [#attr{name = <<"id">>,
                          required = true},
                    #attr{name = <<"type">>,
                          required = true,
                          enc = {enc_enum, []},
                          dec = {dec_enum, [[get, set, result, error]]}},
                    #attr{name = <<"from">>,
                          dec = {jid, decode, []},
                          enc = {jid, encode, []}},
                    #attr{name = <<"to">>,
                          dec = {jid, decode, []},
                          enc = {jid, encode, []}},
                    #attr{name = <<"xml:lang">>,
			  dec = {xmpp_lang, check, []},
                          label = '$lang'}]}).

-xml(disco_info,
     #elem{name = <<"query">>,
           xmlns = <<"http://jabber.org/protocol/disco#info">>,
	   module = 'xep0030',
           result = {disco_info, '$node', '$identities', '$features', '$xdata'},
           attrs = [#attr{name = <<"node">>}],
           refs = [#ref{name = disco_identity,
                        label = '$identities'},
                   #ref{name = disco_feature,
                        label = '$features'},
                   #ref{name = xdata,
                        label = '$xdata'}]}).

-xml(disco_identity,
     #elem{name = <<"identity">>,
           xmlns = <<"http://jabber.org/protocol/disco#info">>,
	   module = 'xep0030',
           result = {identity, '$category', '$type', '$lang', '$name'},
           attrs = [#attr{name = <<"category">>,
                          required = true},
                    #attr{name = <<"type">>,
                          required = true},
                    #attr{name = <<"xml:lang">>,
			  dec = {xmpp_lang, check, []},
                          label = '$lang'},
                    #attr{name = <<"name">>}]}).

-xml(disco_feature,
     #elem{name = <<"feature">>,
           xmlns = <<"http://jabber.org/protocol/disco#info">>,
	   module = 'xep0030',
           result = '$var',
           attrs = [#attr{name = <<"var">>,
                          required = true}]}).
]=]

local CLIENT = [[
export function info(api, jid, node) {
    const stanza = stx`<iq xmlns="jabber:client" type="get" to="${jid}"><query xmlns="${Strophe.NS.DISCO_INFO}" node="${node}"/></iq>`;
    return api.sendIQ(stanza);
}
export function plain(api) {
    return api.sendIQ(stx`<iq xmlns="jabber:client" type="get"><query xmlns="${Strophe.NS.DISCO_INFO}"/></iq>`);
}
export function setter(api) {
    return api.sendIQ(stx`<iq xmlns="jabber:client" type="set"><query xmlns="${Strophe.NS.DISCO_INFO}"/></iq>`);
}
export function nobody(api) {
    return api.sendIQ(stx`<iq xmlns="jabber:client" type="get"><query xmlns="urn:nobody:0"/></iq>`);
}
export function withLocal(api, v2) {
    const inner = v2 ? stx`<identity category="${v2}" type="b"/>` : stx`<feature var="x"/>`;
    return api.sendIQ(stx`<iq xmlns="jabber:client" type="get"><query xmlns="${Strophe.NS.DISCO_INFO}">${inner}</query></iq>`);
}
function wrap(api, el) {
    return api.sendIQ(stx`<iq xmlns="jabber:client" type="get"><query xmlns="${Strophe.NS.DISCO_INFO}">${el}</query></iq>`);
}
export function caller(api) {
    const feat = stx`<feature var="y"/>`;
    return wrap(api, feat);
}
function mk() {
    return stx`<feature var="z"/>`;
}
export function oneLine(api) { return api.sendIQ(stx`<iq xmlns="jabber:client" type="set"><query xmlns="${Strophe.NS.DISCO_INFO}"/></iq>`); }
export function unread(api) {
    return api.sendIQ(stx`<iq type="get"><query xmlns="${Strophe.NS.DISCO_INFO}"/></iq>`);
}
export function viaCall(api) {
    return api.sendIQ(stx`<iq xmlns="jabber:client" type="get"><query xmlns="${Strophe.NS.DISCO_INFO}">${mk()}</query></iq>`);
}
]]

local SERVER = [[
-module(mod_t).
start(Host) ->
    gen_iq_handler:add_iq_handler(ejabberd_local, Host, ?NS_DISCO_INFO, ?MODULE, process_iq),
    gen_iq_handler:add_iq_handler(ejabberd_local, Host, ?NS_VERSION, ?MODULE, process_iq),
    gen_iq_handler:add_iq_handler(ejabberd_local, Host, ?NS_DISCO_ITEMS, ?MODULE, other_iq).
process_iq(#iq{type = set} = IQ) -> IQ;
process_iq(#iq{type = get, from = #jid{luser = _U}, sub_els = [#disco_info{node = <<"special">>}]} = IQ) -> IQ;
process_iq(#iq{type = get, sub_els = [#disco_info{node = Node}]} = IQ) -> {IQ, Node};
process_iq(#iq{type = get} = IQ) -> IQ;
process_iq(#iq{type = error} = IQ) -> IQ.
other_iq(#iq{type = get} = IQ) -> IQ.
]]

local function write(path, text)
    vim.fn.mkdir(vim.fn.fnamemodify(path, ':h'), 'p')
    local fd = assert(io.open(path, 'w')); fd:write(text); fd:close()
end

local cached
local function run()
    if cached then return cached end
    local root = vim.fn.tempname()
    write(root .. '/client/iq.js', CLIENT)
    write(root .. '/server/src/mod_t.erl', SERVER)
    write(root .. '/specs/xmpp_codec.spec', SPEC)
    cached = require('cartograph.xmppmerge').merge({ client = root .. '/client', server = root .. '/server',
        spec = root .. '/specs/xmpp_codec.spec' })
    return cached
end

local function row(R, owner_pat)
    for _, r in ipairs(R.rows) do if (r.owner or ''):match(owner_pat) then return r end end
end

test('xmppmerge: a request reaches the FIRST clause it unifies with, later ones are shadowed, a clash names its field', function ()
    need()
    local R = run()
    eq(9, R.stats.requests, 'nine IQ get/set templates')
    eq(9, R.stats.owned, 'every one owned by the function that builds it (a one-line function too)')
    local plain = row(R, '::plain@')
    local c = plain.candidates[1]
    eq('accepted', plain.verdict)
    eq(3, c.clause, 'no node attribute decodes to <<>>: clause #2 wants "special", #3 accepts')
    eq('""', c.binds.Node, 'and binds Node across the wire to the decoded default')
    local rej = {}
    for _, x in ipairs(c.rejected) do rej[x.clause] = x.at end
    eq('type', rej[1], '#1 rejects on the type')
    eq('sub_els.[].node', rej[2], '#2 rejects on the node, by field name — NOT on `from`: the server stamps it')
    local info = row(R, '::info@')
    eq(2, info.candidates[1].clause, 'a client HOLE may be "special": #2 is reachable, the join over-approximates')
    eq({ 3, 4 }, info.candidates[1].shadowed)
    eq(1, row(R, '::setter@').candidates[1].clause)
end)

test('xmppmerge: a request the spec cannot decode is UNREAD, never accepted by every clause', function ()
    need()
    local R = run()
    local r = row(R, '::unread@')
    eq('unread', r.verdict, 'an <iq> with no namespace matches no -xml: a hole would unify with anything')
    eq(1, R.stats.unread)
end)

test('xmppmerge: a namespace with no registered endpoint is a named frontier, never a rejection', function ()
    need()
    local R = run()
    local r = row(R, '::nobody@')
    eq('no endpoint', r.verdict)
    eq(1, R.stats.missing_uri['urn:nobody:0'])
    eq(0, R.stats.rejected)
end)

test('xmppmerge: a fragment reaches its hole through a local binding (with alternatives), a parameter, and a call', function ()
    need()
    local R = run()
    eq(2, row(R, '::withLocal@').alternatives, 'both arms of the conditional binding are decoded')
    eq('accepted', row(R, '::withLocal@').verdict)
    local by = R.stats.spliced_by or {}
    eq(2, by['local'], 'the two alternatives of `inner`')
    eq(1, by.parameter, '`el` in wrap(), from the caller binding `feat`')
    eq(1, by.call, '`mk()` returns a fragment')
    eq(0, #(R.stats.unknown_holes or {}), 'no content hole left unknown')
end)

test('xmppmerge: the absent-attribute rule matches the generated decoder shapes', function ()
    local M = require 'cartograph.xmppmerge'
    eq('', M.absent_value({}).v, 'no decoder, no default: <<>>')
    eq('undefined', M.absent_value({ dec = '{jid, decode, []}' }).v, 'a converting decoder: undefined')
    eq('', M.absent_value({ dec = '{xmpp_lang, check, []}' }).v, 'a checker keeps the binary')
    eq('absent', M.absent_value({ required = true }).k, 'a required attribute: a decode error')
    eq('available', M.absent_value({ default = 'available' }).v, 'an explicit default wins')
end)

test('xmppmerge: the SERVER view — handler -> namespaces, and per clause reached / shadowed / rejected / unasked', function ()
    need()
    local R = run()
    local h, other
    for _, rec in pairs(R.server) do
        if rec.fn == 'process_iq' then h = rec elseif rec.fn == 'other_iq' then other = rec end
    end
    table.sort(h.uris)
    eq({ 'http://jabber.org/protocol/disco#info', 'jabber:iq:version' }, h.uris, 'one handler, two namespaces')
    eq(5, h.nclauses)
    local st = {}
    for k = 1, 5 do st[k] = h.clauses[k].status end
    eq({ 'reached', 'reached', 'reached', 'shadowed', 'every request rejected' }, st)
    local who = {}
    for _, r in ipairs(h.clauses[3].reached) do who[#who + 1] = r.owner:match('::(%w+)@') end
    table.sort(who)
    -- `caller` only passes a fragment: the request is BUILT, and owned, by wrap()
    eq({ 'plain', 'viaCall', 'withLocal', 'wrap' }, who, 'clause #3 lists the client functions that reach it')
    eq('no request to its namespace', other.clauses[1].status, 'disco#items: registered, never asked')
end)
