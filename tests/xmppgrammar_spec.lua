-- THE XMPP WIRE AS AN ALGEBRA GRAMMAR (lua/cartograph/xmppgrammar.lua, CART-1138): the printer's observed rules, the
-- reader's canonical term, the laws, and the grammar registered with the algebra.

local function need()
    if not (parser_available('xml') and parser_available('erlang')) then skip 'needs the xml and erlang parsers' end
end

test('xmppgrammar: the printer — fxml\'s observed escaping, self-closing, attribute order', function ()
    need()
    local XG = require 'cartograph.xmppgrammar'
    -- text escapes all five, drops \r and control characters; an attribute keeps > and escapes \n \t \r
    local el = XG.el('a', { { 'z', '1' }, { 'b', '<"\'>&\n\t\r' } }, { XG.cdata('x&y>"\'\r\1ok'), XG.el('c', {}, {}) })
    eq("<a z='1' b='&lt;&quot;&apos;>&amp;&#xA;&#x9;&#xD;'>x&amp;y&gt;&quot;&apos;ok<c/></a>", XG.print_el(el))
    -- an element with an EMPTY text child is not self-closing
    eq('<a></a>', XG.print_el(XG.el('a', {}, { XG.cdata('') })))
end)

test('xmppgrammar: the reader — one cdata for adjacent text, entities and CDATA; namespace declarations first', function ()
    need()
    local XG = require 'cartograph.xmppgrammar'
    local A = require('cartograph.algebra').load()
    local el = XG.read('<a b="1" xmlns="urn:x" xmlns:p="urn:p">x&amp;<![CDATA[<y]]>&#65;&#x42;<c/>\n</a>')
    eq('(tuple "xmlel" "a" (list (tuple "xmlns" "urn:x") (tuple "xmlns:p" "urn:p") (tuple "b" "1")) '
        .. '(list (tuple "xmlcdata" "x&<yAB") (tuple "xmlel" "c" (list) (list)) (tuple "xmlcdata" "\\\n")))', A.show(el))
    eq(nil, (XG.read('<a><b></a>')), 'text that does not parse is refused')
    -- LAW 1, modulo attribute order
    local t = XG.el('q', { { 'k', "v'<" }, { 'xmlns', 'urn:q' } }, { XG.cdata('t&') })
    ok(A.equality('term').eq(XG.canon(t), XG.canon(XG.read(XG.print_el(t)))), 'the round trip is the same element, attributes as a set')
end)

test('xmppgrammar: the record grammar round-trips and registers as the algebra\'s xmpp grammar', function ()
    need()
    -- a fixture checkout: a spec (forms copied from xmpp's) and a codec module whose decode/1 the grammar evaluates
    local root = vim.fn.tempname()
    for _, d in ipairs { 'specs', 'src' } do vim.fn.mkdir(root .. '/' .. d, 'p') end
    local function write(path, text) local fd = assert(io.open(path, 'w')); fd:write(text); fd:close() end
    write(root .. '/specs/xmpp_codec.spec', table.concat({
        '-record(disco_info, {node = <<>> :: binary(), identities = [], features = [], xdata = []}).',
        '-xml(disco_info, #elem{name = <<"query">>, xmlns = <<"http://jabber.org/protocol/disco#info">>, module = xep0030,',
        '    result = {disco_info, \'$node\', \'$identities\', \'$features\', \'$xdata\'},',
        '    attrs = [#attr{name = <<"node">>}],',
        '    refs = [#ref{name = disco_feature, label = \'$features\'}]}).',
        '-xml(disco_feature, #elem{name = <<"feature">>, xmlns = <<"http://jabber.org/protocol/disco#info">>, module = xep0030,',
        '    result = \'$var\', attrs = [#attr{name = <<"var">>, required = true}]}).', '' }, '\n'))
    write(root .. '/src/xmpp_codec.erl', table.concat({
        '-module(xmpp_codec).',
        'decode({xmlel, <<"query">>, Attrs, Els}) ->',
        '    {disco_info, node(Attrs), [], [V || {xmlel, <<"feature">>, [{<<"var">>, V}], _} <- Els], []}.',
        'node([{<<"node">>, N} | _]) -> N;', 'node([_ | T]) -> node(T);', 'node([]) -> <<>>.', '' }, '\n'))
    local XG = require 'cartograph.xmppgrammar'
    local A = require('cartograph.algebra').load()
    local G = XG.register(XG.new { spec = root .. '/specs/xmpp_codec.spec' })
    local function lit(v, lk) local l = A.lit(v); l.lk = lk; return l end
    local rec = A.node('rec:disco_info', lit('n', 'bin'), A.node('list'), A.node('list', lit('urn:a', 'bin')), A.node('list'))
    local text = G.print(rec)
    eq("<query node='n' xmlns='http://jabber.org/protocol/disco#info'><feature var='urn:a'/></query>", text)
    eq(A.show(rec), A.show(G.parse(text)), 'the decoder is the codec module, evaluated')
    -- through the algebra: an embed prints under the grammar, and matching parses it back
    local T = A.embed('xmpp', A.template(A.node('rec:disco_info', A.hole('N'), A.node('list'), A.node('list', lit('urn:a', 'bin')), A.node('list'))))
    local inst = A.instantiate(T, { N = lit('n', 'bin') })
    ok(inst.ok, vim.inspect(inst))
    eq(text, inst.term.v)
    local m = A.match(T, A.lit(text))
    ok(m.ok, vim.inspect(m.refusal))
    eq('n', m.values.N.v)
end)
