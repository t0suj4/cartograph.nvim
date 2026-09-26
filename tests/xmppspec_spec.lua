-- XMPP_CODEC.SPEC AS THE INTERPRETATION OF ERLANG RECORDS (CART-1096).
--
-- ★★★ WHAT THESE SPECS FENCE are the things a plausible-looking spec reader gets wrong:
--   1. DEFAULTS ARE THE GENERATOR'S: an element with no `cdata = …` still has #cdata{label = '$cdata'} (86 labels in
--      the real spec resolve only through it), a #ref with no min/max is 0..infinity (a LIST), an #attr/#ref with no
--      label is '$' .. lowercase(name).
--   2. SEVERAL -xml PRODUCE ONE RECORD (ps_error 23, chatstate 5, …): every variant is returned; a CONSTANT in the
--      head narrows them and says which it excluded and why; a BINDING narrows nothing.
--   3. RESULT SHAPES: a record tuple (possibly with constant slots), an ANONYMOUS tuple ({'$name', '$cdata'}), a
--      single label (a scalar child), a constant (presence is the value).
--   4. NOTHING IS DROPPED: unknown records / fields / labels, descent into a decoded attribute, a field not on the
--      wire, and a malformed -xml form all come back NAMED.
--
-- ⚠ NOT the real xmpp library: the suite reads only the running tree (isolation_spec forbids a home-dir path in a
-- spec, so the task's "skip when the checkout is missing" guard is replaced by this fixture). The census
-- (tools/xmppspeccensus.lua) reads the real xmpp_codec.spec. The -xml / -record forms below are VERBATIM from it
-- (xmpp specs/xmpp_codec.spec), except pubsub_error_unsupported whose dec enum list is abridged, and three synthetic
-- forms at the end, each marked.

local X = require 'cartograph.xmppspec'

local function have_erlang() return parser_available('erlang') end

local FIXTURE = [==[
-record(text, {lang = <<>> :: binary(),
               data = <<>> :: binary()}).
-type text() :: #text{}.

-xml(last,
     #elem{name = <<"query">>,
           xmlns = <<"jabber:iq:last">>,
	   module = 'xep0012',
           result = {last, '$seconds', '$status'},
           attrs = [#attr{name = <<"seconds">>,
                          enc = {enc_int, []},
                          dec = {dec_int, [0, infinity]}}],
           cdata = #cdata{default = <<"">>, label = '$status'}}).

-xml(version_name,
     #elem{name = <<"name">>,
           xmlns = <<"jabber:iq:version">>,
	   module = 'xep0092',
           result = '$cdata',
           cdata = #cdata{label = '$cdata', required = true}}).

-xml(version,
     #elem{name = <<"query">>,
           xmlns = <<"jabber:iq:version">>,
	   module = 'xep0092',
           result = {version, '$name', '$ver', '$os'},
           refs = [#ref{name = version_name,
                        label = '$name',
                        min = 0, max = 1}]}).

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

-record(iq, {id = <<>> :: binary(),
             type :: iq_type(),
             lang = <<>> :: binary(),
             from :: undefined | jid:jid(),
             to :: undefined | jid:jid(),
             sub_els = [] :: [xmpp_element() | fxml:xmlel()],
	     meta = #{} :: map()}).
-type iq() :: #iq{}.

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

-record(ps_error, {type :: ps_error_type(), feature :: ps_feature()}).
-type ps_error() :: #ps_error{}.

-xml(pubsub_error_closed_node,
     #elem{name = <<"closed-node">>,
           xmlns = <<"http://jabber.org/protocol/pubsub#errors">>,
	   module = 'xep0060',
           result = {ps_error, 'closed-node', '$_'}}).

-xml(pubsub_error_unsupported,
     #elem{name = <<"unsupported">>,
           xmlns = <<"http://jabber.org/protocol/pubsub#errors">>,
	   module = 'xep0060',
           result = {ps_error, 'unsupported', '$feature'},
	   attrs = [#attr{name = <<"feature">>, required = true,
			  dec = {dec_enum, [['access-authorize', 'access-open']]},
			  enc = {enc_enum, []}}]}).

-xml(shim_header,
     #elem{name = <<"header">>,
           xmlns = <<"http://jabber.org/protocol/shim">>,
	   module = 'xep0131',
           result = {'$name', '$cdata'},
           attrs = [#attr{name = <<"name">>,
                          required = true}]}).

-xml(shim_headers,
     #elem{name = <<"headers">>,
           xmlns = <<"http://jabber.org/protocol/shim">>,
	   module = 'xep0131',
           result = {shim, '$headers'},
           refs = [#ref{name = shim_header, label = '$headers'}]}).

-record(chatstate, {type :: active | composing | gone | inactive | paused}).
-type chatstate() :: #chatstate{}.

-xml(chatstate_active,
     #elem{name = <<"active">>,
           xmlns = <<"http://jabber.org/protocol/chatstates">>,
	   module = 'xep0085',
           result = {chatstate, active}}).

-xml(chatstate_composing,
     #elem{name = <<"composing">>,
           xmlns = <<"http://jabber.org/protocol/chatstates">>,
	   module = 'xep0085',
           result = {chatstate, composing}}).

%% SYNTHETIC: three refs sharing one label (a list field collecting scalar AND record child kinds), an unlabelled ref
-xml(synth_pair,
     #elem{name = <<"pair">>,
           xmlns = <<"urn:synth">>,
	   module = synth,
           result = {synth_pair, '$items', '$version_name'},
           refs = [#ref{name = disco_feature, label = '$items'},
                   #ref{name = version_name, label = '$items'},
                   #ref{name = disco_identity, label = '$items'},
                   #ref{name = version_name, min = 1, max = 1}]}).

%% SYNTHETIC: an element name that is a variable, not a literal
-xml(synth_bad,
     #elem{name = Name, module = synth, result = {synth_bad}}).

%% SYNTHETIC: a one-argument -xml (malformed: no name)
-xml(#elem{name = <<"nameless">>, module = synth, result = true}).

%% SYNTHETIC: a result label nothing declares
-xml(synth_orphan,
     #elem{name = <<"orphan">>,
           xmlns = <<"urn:synth">>,
	   module = synth,
           result = {synth_orphan, '$ghost'}}).
]==]

local function spec()
    return X.parse_source(FIXTURE, 'fixture.spec')
end

local function count_xml_lines(src)
    local n = 0
    for line in (src .. '\n'):gmatch('([^\n]*)\n') do if line:find('^%-xml%(') then n = n + 1 end end
    return n
end

test('xmppspec: every -xml form is an entry or a NAMED refusal (parsed + refused = the line scan)', function ()
    if not have_erlang() then skip('no erlang parser') end
    local S = spec()
    eq(17, count_xml_lines(FIXTURE))
    eq(17, S.forms)
    eq(15, #S.order)
    local why = {}
    for _, r in ipairs(S.refused) do why[#why + 1] = (r.name or '?') .. ': ' .. r.why end
    -- a variable where a literal belongs is refused BY NAME, never guessed at
    eq({ 'synth_bad: #elem has no literal name', '?: no `Name,` before the element (a one-argument -xml)' }, why)
    eq(#S.order + #S.refused, S.forms)
end)

test('xmppspec: the entry shape, with fxml_gen defaults applied (label from name, ref 0..infinity)', function ()
    if not have_erlang() then skip('no erlang parser') end
    local S = spec()
    local d = S.entries.disco_info
    eq('query', d.element)
    eq('http://jabber.org/protocol/disco#info', d.xmlns)
    eq('xep0030', d.module)
    eq({ kind = 'record', record = 'disco_info', fields = { '$node', '$identities', '$features', '$xdata' } }, d.result)
    eq(1, #d.attrs)
    eq({ 'node', '$node', false, false }, { d.attrs[1].name, d.attrs[1].label, d.attrs[1].declared_label,
        d.attrs[1].required })
    eq({ 'disco_identity', '$identities', 0, 'infinity' }, { d.refs[1].name, d.refs[1].label, d.refs[1].min,
        d.refs[1].max })
    eq(nil, d.cdata)
    -- 1-based line of the -xml attribute, and the line it ends on
    local n, first, last = 0, nil, nil
    for line in (FIXTURE .. '\n'):gmatch('([^\n]*)\n') do
        n = n + 1
        if line:find('^%-xml%(disco_info,') then first = n end
        if first and not last and line:find('%}%)%.$') then last = n end
    end
    eq({ first, last }, { d.line, d.last })
    -- xmlns list, an explicit label on a name the default rule cannot produce ('xml:lang' -> '$lang')
    local iq = S.entries.iq
    eq({ 'jabber:client', 'jabber:server', 'jabber:component:accept' }, iq.xmlns)
    eq({ 'xml:lang', '$lang', true }, { iq.attrs[5].name, iq.attrs[5].label, iq.attrs[5].declared_label })
    eq('{dec_enum, [[get, set, result, error]]}', iq.attrs[2].dec)
    eq(true, iq.attrs[2].required)
    -- a declared cdata with its own label and a default, verbatim text
    eq({ '$status', '<<"">>' }, { S.entries.last.cdata.label, S.entries.last.cdata.default })
    -- the four result shapes
    eq({ kind = 'label', label = '$cdata' }, S.entries.version_name.result)
    eq({ kind = 'tuple', fields = { '$name', '$cdata' } }, S.entries.shim_header.result)
    eq({ kind = 'record', record = 'chatstate', fields = { { const = 'active' } } }, S.entries.chatstate_active.result)
    eq({ kind = 'record', record = 'ps_error', fields = { { const = 'closed-node' }, '$_' } },
        S.entries.pubsub_error_closed_node.result)
    -- an unlabelled ref gets '$' .. name; ref min/max literals are read
    local p = S.entries.synth_pair.refs[4]
    eq({ '$version_name', false, 1, 1 }, { p.label, p.declared_label, p.min, p.max })
    -- by_record: every producer, spec order; an anonymous tuple produces no record
    eq({ 'chatstate_active', 'chatstate_composing' }, S.by_record.chatstate)
    eq({ 'pubsub_error_closed_node', 'pubsub_error_unsupported' }, S.by_record.ps_error)
    eq(nil, S.by_record['$name'])
    -- the spec's own -record forms come from erlrecords
    eq({ 'id', 'type', 'lang', 'from', 'to', 'sub_els', 'meta' }, X.record_fields(S, 'iq'))
    eq(select(2, X.record_fields(S, 'iq')), 'spec')
    eq({ 'node', 'identities', 'features', 'xdata' }, X.record_fields(S, 'disco_info'))
    eq(select(2, X.record_fields(S, 'disco_info')), 'derived')
end)

test('xmppspec: label sources follow get_spec_by_label (cdata first, the #cdata{} DEFAULT, shared refs)', function ()
    if not have_erlang() then skip('no erlang parser') end
    local S = spec()
    local function kinds(e, l)
        local t = {}
        for i, s in ipairs(X.label_sources(S.entries[e], l)) do t[i] = s.kind .. (s.name and (':' .. s.name) or '') end
        return t
    end
    -- disco_feature declares no cdata; its result '$var' is an attr, and '$cdata' would still be the DEFAULT cdata
    eq({ 'attr:var' }, kinds('disco_feature', '$var'))
    eq({ 'cdata' }, kinds('disco_feature', '$cdata'))
    eq(false, X.label_sources(S.entries.disco_feature, '$cdata')[1].declared)
    eq(true, X.label_sources(S.entries.version_name, '$cdata')[1].declared)
    eq({ 'cdata' }, kinds('last', '$status'))
    eq({ 'attr:seconds' }, kinds('last', '$seconds'))
    eq({ 'els' }, kinds('iq', '$_els'))
    eq({ 'ignored' }, kinds('iq', '$_'))
    eq({ 'ref:disco_feature', 'ref:version_name', 'ref:disco_identity' }, kinds('synth_pair', '$items'))
    eq({ 'ref:version_name' }, kinds('synth_pair', '$version_name'))
    eq({ 'unknown' }, kinds('synth_orphan', '$ghost'))
    -- prepare_label lowercases the NAME ('$' .. lowercase), and an explicit label wins untouched
    eq({ '$feature', '$lang' }, { X.prepare_label(nil, 'Feature'), X.prepare_label('$lang', 'xml:lang') })
    ok(X.is_label('$_els') and X.is_label('$_') and X.is_label('$node'), 'labels')
    ok(not X.is_label('$_x') and not X.is_label('$-x') and not X.is_label('closed-node'), 'constants')
end)

test('xmppspec: the interpretation of a record field returns EVERY producing -xml, never one', function ()
    if not have_erlang() then skip('no erlang parser') end
    local S = spec()
    local rows = X.field(S, 'disco_info', 'node')
    eq(1, #rows)
    eq({ 'disco_info', 'query', 1, '$node', 'attr', 'node' }, { rows[1].xml, rows[1].element, rows[1].index,
        rows[1].label, rows[1].sources[1].kind, rows[1].sources[1].name })
    eq('@node on <query xmlns="http://jabber.org/protocol/disco#info">',
        X.describe(S, S.entries.disco_info, rows[1].sources[1]))
    -- ps_error.feature: one variant does not carry it ('$_'), the other reads it from @feature
    local pe = X.field(S, 'ps_error', 'feature')
    eq(2, #pe)
    eq({ 'pubsub_error_closed_node', 'ignored' }, { pe[1].xml, pe[1].sources[1].kind })
    eq({ 'pubsub_error_unsupported', 'attr', 'feature' }, { pe[2].xml, pe[2].sources[1].kind, pe[2].sources[1].name })
    -- chatstate.type: both variants, each a CONSTANT slot
    local cs = X.field(S, 'chatstate', 'type')
    eq({ 'active', 'composing' }, { cs[1].const, cs[2].const })
    -- a ref field
    local fe = X.field(S, 'disco_info', 'features')
    eq({ 'ref', 'disco_feature', 0, 'infinity' }, { fe[1].sources[1].kind, fe[1].sources[1].name,
        fe[1].sources[1].min, fe[1].sources[1].max })
    eq('<feature xmlns="http://jabber.org/protocol/disco#info"> children of <query xmlns="http://jabber.org/protocol/'
        .. 'disco#info"> (0..infinity)', X.describe(S, S.entries.disco_info, fe[1].sources[1]))
    local r, why = X.field(S, 'nosuch', 'x')
    eq(nil, r); ok(why:find('^unknown_record'), why)
    r, why = X.field(S, 'disco_info', 'nosuch')
    eq(nil, r); ok(why:find('^unknown_field'), why)
end)

test('xmppspec: the arity / name cross-check against attached declarations fires both ways', function ()
    if not have_erlang() then skip('no erlang parser') end
    local S = spec()
    local function decl(name, fields)
        local d = { name = name, fields = {}, by = {} }
        for i, f in ipairs(fields) do d.fields[i] = { name = f, index = i }; d.by[f] = d.fields[i] end
        return d
    end
    X.attach_records(S, { disco_info = decl('disco_info', { 'node', 'identities', 'features', 'xdata' }) })
    local C = X.check_fields(S)
    eq({}, C.arity)
    eq({}, C.names)
    eq('hrl', select(2, X.record_fields(S, 'disco_info')))
    -- a header with one field fewer, and one renamed: both named
    X.attach_records(S, { disco_info = decl('disco_info', { 'node', 'identities', 'feats' }) })
    C = X.check_fields(S)
    eq(1, #C.arity)
    eq({ 'disco_info', 4, 3 }, { C.arity[1].record, C.arity[1].result, C.arity[1].declared })
    eq(1, #C.names)
    eq({ 3, '$features', 'feats' }, { C.names[1].index, C.names[1].label, C.names[1].declared })
    -- '$_' slots name no field: counted, never compared (iq's meta, ps_error's feature)
    ok(C.ignored >= 2, 'ignored ' .. C.ignored)
end)

-- the CART-0957 fact shape, hand-built: process_local_iq(#iq{type = get, sub_els = [#disco_info{node = Node}]} = IQ)
local DISCO = {
    { value = 'get', ty = 'atom', path = { { rec = 'iq', field = 'type' } }, arg = 1 },
    { name = 'Node', path = { { rec = 'iq', field = 'sub_els' }, { elem = 1 }, { rec = 'disco_info', field = 'node' } },
        arg = 1 },
    { name = 'IQ', path = {}, arg = 1 },
}

test('xmppspec: lift — the disco#info handler head READS <iq type="get"><query … node="?Node"/></iq>', function ()
    if not have_erlang() then skip('no erlang parser') end
    local S = spec()
    local L = X.lift(DISCO, S)
    eq({}, L.frontier)
    eq('IQ=<iq xmlns="jabber:client|jabber:server|jabber:component:accept" type="get"><query xmlns="http://jabber.org/'
        .. 'protocol/disco#info" node="?Node"/></iq>', X.render(L.args[1]))
    local V = L.args[1]
    eq({ 'IQ' }, V.binds)
    eq('iq', V.record)
    eq(1, #V.alts)
    local E = V.alts[1]
    eq({ 'type', 'type', '$type' }, { E.attrs[1].name, E.attrs[1].field, E.attrs[1].label })
    eq({ { value = 'get', ty = 'atom' } }, E.attrs[1].consts)
    eq({ 'sub_els', '$_els', 'els', 'many' }, { E.kids[1].field, E.kids[1].label, E.kids[1].via, E.kids[1].value.card })
    local child = E.kids[1].value.items[1]
    eq('1', child.pos)
    eq({ 'disco_info', 'query', 'http://jabber.org/protocol/disco#info' }, { child.value.alts[1].xml,
        child.value.alts[1].element, child.value.alts[1].xmlns })
    eq({ 'Node' }, child.value.alts[1].attrs[1].binds)
end)

test('xmppspec: lift — a record two -xml produce: a binding keeps both, a constant excludes by name', function ()
    if not have_erlang() then skip('no erlang parser') end
    local S = spec()
    local L = X.lift({ { name = 'T', path = { { rec = 'chatstate', field = 'type' } }, arg = 1 } }, S)
    eq({}, L.frontier)
    eq(2, #L.args[1].alts)
    eq('(<active xmlns="http://jabber.org/protocol/chatstates"/> | <composing xmlns="http://jabber.org/protocol/'
        .. 'chatstates"/>)', X.render(L.args[1]))
    L = X.lift({ { value = 'composing', ty = 'atom', path = { { rec = 'chatstate', field = 'type' } }, arg = 1 } }, S)
    eq({}, L.frontier)
    local A = L.args[1].alts
    eq('chatstate_active decodes #chatstate.type as the constant active; the head requires composing', A[1].excluded)
    eq(nil, A[2].excluded)
    eq('<composing xmlns="http://jabber.org/protocol/chatstates"/>', X.render(L.args[1]))
    -- a constant no variant carries: every variant excluded, and that is a NAMED frontier
    L = X.lift({ { value = 'paused', ty = 'atom', path = { { rec = 'chatstate', field = 'type' } }, arg = 1 } }, S)
    eq(1, #L.frontier)
    eq('no_variant', L.frontier[1].reason)
    -- nested, the no_variant row names WHERE the value sits, not the whole argument
    L = X.lift({ { value = 'paused', ty = 'atom', path = { { rec = 'iq', field = 'sub_els' }, { elem = 2 },
        { rec = 'chatstate', field = 'type' } }, arg = 3 } }, S)
    eq({ 'no_variant', 3, '#iq.sub_els [2]' }, { L.frontier[1].reason, L.frontier[1].arg, L.frontier[1].path })
    -- ps_error.feature: the variant that does not carry it reports not_on_wire, the other binds @feature
    L = X.lift({ { name = 'F', path = { { rec = 'ps_error', field = 'feature' } }, arg = 1 } }, S)
    eq({ 'not_on_wire' }, vim.tbl_map(function (r) return r.reason end, L.frontier))
    eq('(<closed-node xmlns="http://jabber.org/protocol/pubsub#errors"/> | <unsupported xmlns="http://jabber.org/'
        .. 'protocol/pubsub#errors" feature="?F"/>)', X.render(L.args[1]))
end)

test('xmppspec: lift — scalar children, anonymous tuples, and every frontier NAMED', function ()
    if not have_erlang() then skip('no erlang parser') end
    local S = spec()
    -- a single scalar child (ref max 1 to an element whose result is '$cdata'): the binding lands on its TEXT
    local L = X.lift({ { name = 'N', path = { { rec = 'version', field = 'name' } }, arg = 1 } }, S)
    eq({}, L.frontier)
    eq('<query xmlns="jabber:iq:version"><name xmlns="jabber:iq:version">?N</name></query>', X.render(L.args[1]))
    -- an anonymous tuple result reached by a { tuple } step
    L = X.lift({
        { name = 'K', path = { { rec = 'shim', field = 'headers' }, { head = true }, { tuple = 1, arity = 2 } }, arg = 1 },
        { name = 'V', path = { { rec = 'shim', field = 'headers' }, { head = true }, { tuple = 2, arity = 2 } }, arg = 1 },
    }, S)
    eq({}, L.frontier)
    eq('<headers xmlns="http://jabber.org/protocol/shim"><header xmlns="http://jabber.org/protocol/shim" name="?K">?V'
        .. '</header></headers>', X.render(L.args[1]))
    -- the frontier, one reason each
    local function reasons(facts)
        local t = {}
        for i, r in ipairs(X.lift(facts, S).frontier) do t[i] = r.reason end
        return t
    end
    eq({ 'unknown_record' }, reasons({ { name = 'A', path = { { rec = 'nosuch', field = 'x' } }, arg = 1 } }))
    eq({ 'unknown_field' }, reasons({ { name = 'A', path = { { rec = 'iq', field = 'nosuch' } }, arg = 1 } }))
    eq({ 'unknown_label' }, reasons({ { name = 'A', path = { { rec = 'synth_orphan', field = 'ghost' } }, arg = 1 } }))
    eq({ 'not_on_wire' }, reasons({ { name = 'M', path = { { rec = 'iq', field = 'meta' } }, arg = 1 } }))
    eq({ 'scalar_descent' }, reasons({ { name = 'U', path = { { rec = 'iq', field = 'from' },
        { rec = 'jid', field = 'luser' } }, arg = 1 } }))
    -- version.name decodes to a scalar child, not a record
    eq({ 'record_mismatch' }, reasons({ { name = 'A', path = { { rec = 'version', field = 'name' },
        { rec = 'disco_info', field = 'node' } }, arg = 1 } }))
    -- disco_info refs `xdata`, which is no -xml in this fixture
    eq({ 'unknown_ref' }, reasons({ { name = 'A', path = { { rec = 'disco_info', field = 'xdata' } }, arg = 1 } }))
    eq({ 'step_kind' }, reasons({ { name = 'A', path = { { rec = 'iq', field = 'sub_els' }, { map = 'k' } }, arg = 1 } }))
    eq({ 'step_kind' }, reasons({ { name = 'A', path = { { elem = 1 } }, arg = 1 } }))
    -- a frontier row names its argument, its path and its fact
    local fr = X.lift({ { name = 'A', path = { { rec = 'nosuch', field = 'x' } }, arg = 2 } }, S).frontier[1]
    eq({ 2, '#nosuch.x', 'A' }, { fr.arg, fr.path, fr.fact.name })
end)

test('xmppspec: lift is ORDER-INDEPENDENT over a list collecting scalar and record kinds; tail and bare-rec steps', function ()
    if not have_erlang() then skip('no erlang parser') end
    local S = spec()
    local item = { { rec = 'synth_pair', field = 'items' }, { elem = 1 } }
    local whole = { name = 'X', path = item, arg = 1 }
    local deep = { name = 'C', path = { item[1], item[2], { rec = 'identity', field = 'category' } }, arg = 1 }
    local a, b = X.lift({ whole, deep }, S), X.lift({ deep, whole }, S)
    eq({}, a.frontier)
    eq({}, b.frontier)
    local want = '<pair xmlns="urn:synth">X=<identity xmlns="http://jabber.org/protocol/disco#info" category="?C"/>'
        .. '</pair>'
    eq(want, X.render(a.args[1]))
    eq(want, X.render(b.args[1]))
    -- the scalar kinds the early binding had opened are EXCLUDED by the later { rec }, with the reason
    local ex = {}
    for _, E in ipairs(a.args[1].alts[1].kids[1].value.items[1].value.alts) do
        if E.excluded then ex[#ex + 1] = E.xml end
    end
    table.sort(ex)
    eq({ 'disco_feature', 'version_name' }, ex)
    -- [_ | [H | _]]: the tail is a list again, its head the second child
    local L = X.lift({ { name = 'F', path = { { rec = 'disco_info', field = 'features' }, { tail = true }, { head = true } },
        arg = 1 } }, S)
    eq({}, L.frontier)
    eq('<query xmlns="http://jabber.org/protocol/disco#info"><feature xmlns="http://jabber.org/protocol/disco#info" '
        .. 'var="?F"/></query>', X.render(L.args[1]))
    eq({ 'tail', 'head' }, { L.args[1].alts[1].kids[1].value.items[1].pos,
        L.args[1].alts[1].kids[1].value.items[1].value.items[1].pos })
    -- a { rec } step with no field narrows (the element is named) and reads nothing
    L = X.lift({ { name = 'I', path = { { rec = 'iq', field = 'sub_els' }, { elem = 1 }, { rec = 'disco_info' } },
        arg = 1 } }, S)
    eq({}, L.frontier)
    eq('<iq xmlns="jabber:client|jabber:server|jabber:component:accept"><query xmlns="http://jabber.org/protocol/'
        .. 'disco#info"/></iq>', X.render(L.args[1]))
end)
