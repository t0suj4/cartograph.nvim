-- STROPHE `stx` TAGGED TEMPLATES AS XML ELEMENT TREES WITH HOLES (CART-1097): the client leg of the
-- XMPP triple. Every fixture is a JS source; the reader must place each `${...}` at exactly one site.

local stx = require 'cartograph.stx'
local xv = require 'cartograph.xmlvalue'

local function ready()
    return parser_available('javascript') and parser_available('xml')
end

local function one(src)
    local recs = assert(stx.templates(src))
    return recs[1], recs
end

local function child(el, name)
    for _, c in ipairs(el.children) do if c.name == name then return c end end
    return nil
end

local function holes_of(el)
    local out = {}
    for _, c in ipairs(el.children) do if c.hole then out[#out + 1] = c.hole end end
    return out
end

test('stx: a static stanza is a tree: top element, type, and every namespace (declared and inherited)', function()
    if not ready() then skip 'no javascript/xml parser' end
    local r = one([[const s = stx`<iq type="get" xmlns="jabber:client"><query xmlns="jabber:iq:roster"><item jid="a@b"/></query></iq>`;]])
    ok(r.ok, r.why)
    eq(1, r.line)
    eq(11, r.col)
    eq('iq', r.tree.name)
    eq('get', r.tree.attr.type.value)
    eq('jabber:client', r.tree.ns.uri)
    eq('literal', r.tree.ns.via)
    local q = child(r.tree, 'query')
    eq('jabber:iq:roster', q.ns.uri)
    eq(true, q.ns.declared)
    local item = child(q, 'item')
    eq('jabber:iq:roster', item.ns.uri)
    eq(false, item.ns.declared) -- inherited, and said so
    eq('iq/query/item', item.path)
    eq(0, #r.holes)
end)

test('stx: attribute holes carry their expression; a mixed value keeps its literal parts', function()
    if not ready() then skip 'no javascript/xml parser' end
    local r = one([[const s = stx`<message to="${jid}" id='m-${n}-x' type="chat" xmlns="jabber:client"/>`;]])
    ok(r.ok, r.why)
    local to = r.tree.attr.to
    eq(1, to.hole)
    eq('jid', r.holes[1].expr)
    eq('attr', r.holes[1].site)
    eq('to', r.holes[1].attr)
    eq('message', r.holes[1].element)
    eq(nil, r.holes[1].fill) -- an attribute value is always escaped text: no fill claim
    local id = r.tree.attr.id -- single-quoted
    eq(3, #id.parts)
    eq('m-', id.parts[1])
    eq(2, id.parts[2].hole)
    eq('-x', id.parts[3])
    eq('m-${n}-x', stx.attr_shown(id, r.holes))
end)

test('stx: a text hole is a content hole; a literal fill is text, an unknown value is said to be unknown', function()
    if not ready() then skip 'no javascript/xml parser' end
    local r = one([[const s = stx`<message xmlns="jabber:client"><body>${text}</body><subject>${'hi'} &amp; ${n}</subject></message>`;]])
    ok(r.ok, r.why)
    local body = child(r.tree, 'body')
    eq({ 1 }, holes_of(body))
    eq('content', r.holes[1].site)
    eq('unknown', r.holes[1].fill)
    eq('message/body', r.holes[1].element)
    local subj = child(r.tree, 'subject')
    eq('text', r.holes[2].fill)
    -- literal text between holes is decoded and kept in order
    eq({ 2 }, { subj.children[1].hole })
    eq(' & ', subj.children[2].text)
    eq(3, subj.children[3].hole)
end)

test('stx: a whole child element from a const-bound stx (candidate bind), spliced into the parent namespace', function()
    if not ready() then skip 'no javascript/xml parser' end
    local recs = assert(stx.templates([[
const el = stx`<item jid="${jid}"/>`;
const s = stx`<iq type="set" xmlns="jabber:client"><query xmlns="jabber:iq:roster">${el}</query></iq>`;
]]))
    eq(2, #recs)
    local frag, top = recs[1], recs[2]
    eq('none', frag.tree.ns.via) -- the fragment alone has no namespace ...
    local h = top.holes[1]
    eq('content', h.site)
    eq(frag.id, h.bind)
    eq('element', h.fill)
    eq(top.id, frag.bound_by[1].id)
    local inv = stx.inventory(recs)
    eq(1, #inv) -- the bound fragment is not a stanza of its own
    eq('iq', inv[1].top)
    eq('set', inv[1].type)
    local item = inv[1].elements[3]
    eq('item', item.name)
    eq('jabber:iq:roster', item.uri) -- ... and takes the namespace where it is spliced
    eq('spliced', item.via)
    eq('bound', item.from)
end)

test('stx: a list of elements (.map over a nested stx) is a nested template, not a stanza', function()
    if not ready() then skip 'no javascript/xml parser' end
    local recs = assert(stx.templates(
        [[const s = stx`<iq type="set" xmlns="jabber:client"><block xmlns="urn:xmpp:blocking">${jids.map((j) => stx`<item jid="${j}"/>`)}</block></iq>`;]]))
    eq(2, #recs)
    local top, inner = recs[1], recs[2]
    eq(top.id, inner.parent)
    eq(1, inner.parent_hole)
    eq('elements', top.holes[1].fill)
    eq({ inner.id }, top.holes[1].nested)
    local inv = stx.inventory(recs)
    eq(1, #inv)
    local names = {}
    for _, e in ipairs(inv[1].elements) do names[#names + 1] = e.name .. '{' .. tostring(e.uri) .. '}' .. e.via end
    eq({ 'iq{jabber:client}literal', 'block{urn:xmpp:blocking}literal', 'item{urn:xmpp:blocking}spliced' }, names)
end)

test('stx: nested xmlns inheritance, prefixes, and namespaces from Strophe.NS / addNamespace / consts / composition', function()
    if not ready() then skip 'no javascript/xml parser' end
    local recs = assert(stx.templates([[
Strophe.addNamespace('MUC_ADMIN', Strophe.NS.MUC + '#admin');
const NS_THREAD = 'http://purl.org/syndication/thread/1.0';
const s = stx`<iq xmlns="jabber:client" type="set">
    <query xmlns="${Strophe.NS.MUC_ADMIN}"><item><reason/></item></query>
    <pubsub xmlns="${Strophe.NS.PUBSUB}#owner" xmlns:thr="${NS_THREAD}"><thr:in-reply-to/></pubsub>
    <x xmlns="${Strophe.NS.DISCO_INFO}"/><y xmlns="${Strophe.NS.NOPE}"/>
</iq>`;]]))
    local r = recs[1]
    ok(r.ok, r.why)
    local q = child(r.tree, 'query')
    eq('http://jabber.org/protocol/muc#admin', q.ns.uri)
    eq('addNamespace', q.ns.via)
    local reason = child(child(q, 'item'), 'reason')
    eq('http://jabber.org/protocol/muc#admin', reason.ns.uri) -- two levels down
    eq(false, reason.ns.declared)
    local ps = child(r.tree, 'pubsub')
    eq(nil, ps.ns.uri) -- PUBSUB is not registered in this source: composed but unresolved
    eq('unresolved', ps.ns.via)
    eq('${Strophe.NS.PUBSUB}#owner', ps.ns.expr)
    local irt = child(ps, 'thr:in-reply-to')
    eq('http://purl.org/syndication/thread/1.0', irt.ns.uri)
    eq('const', irt.ns.via)
    eq('in-reply-to', irt.localname)
    eq('http://jabber.org/protocol/disco#info', child(r.tree, 'x').ns.uri)
    eq('strophe', child(r.tree, 'x').ns.via)
    eq('unresolved', child(r.tree, 'y').ns.via)
    -- a corpus table resolves the composed one
    local res = stx.resolver({ ns = { PUBSUB = 'http://jabber.org/protocol/pubsub' } })
    local r2 = assert(stx.templates([[const s = stx`<pubsub xmlns="${Strophe.NS.PUBSUB}#owner"/>`;]], { resolve = res }))[1]
    eq('http://jabber.org/protocol/pubsub#owner', r2.tree.ns.uri)
    eq('composed', r2.tree.ns.via)
end)

test('stx: a malformed template is reported unparsed, never half-read', function()
    if not ready() then skip 'no javascript/xml parser' end
    local r = one([[const s = stx`<iq type="${t}" xmlns="jabber:client"><query></iq>`;]])
    eq(false, r.ok)
    ok(r.why and r.why:find('does not parse', 1, true), r.why)
    eq(nil, r.tree)
    eq(nil, r.roots)
    eq(nil, r.holes[1].site) -- no hole keeps a site from a failed read
    local inv = stx.inventory({ r })
    eq(false, inv[1].ok)
    eq(0, #inv[1].elements)
end)

test('stx: a hole the tree cannot place is refused by the placement check (an unquoted attribute value)', function()
    if not ready() then skip 'no javascript/xml parser' end
    -- the placeholder `"xx"` parses as a value, but the hole spans its quotes: placed at 0 sites
    local r = one([[const s = stx`<iq to="${a}" type=${t} xmlns="jabber:client"/>`;]])
    eq(false, r.ok)
    ok(r.why and r.why:find('placed at 0 sites', 1, true), r.why)
    -- hole 1 WAS placed before the refusal; a failed read must not leave it a site
    eq(nil, r.holes[1].site)
    eq(nil, r.holes[1].element)
end)

test('stx: attribute-list holes (unsafeXML, glued to the tag name) and the escaped-text bug shape', function()
    if not ready() then skip 'no javascript/xml parser' end
    local r = one([[const s = stx`<iq xmlns="jabber:client" type="get">
  <query xmlns="q" ${node ? Stanza.unsafeXML(`node="${node}"`) : ''}/>
  <subscriptions${node ? ` node="${node}"` : ''}/>
</iq>`;]])
    ok(r.ok, r.why)
    local q = child(r.tree, 'query')
    eq({ 1 }, q.attr_holes)
    eq('attrs', r.holes[1].site)
    eq('raw', r.holes[1].fill)
    eq(true, r.holes[1].cond)
    local sub = child(r.tree, 'subscriptions')
    ok(sub, 'the glued hole must not become part of the element name')
    eq({ 2 }, sub.attr_holes)
    eq('attrs', r.holes[2].site)
    eq('text', r.holes[2].fill) -- Strophe escapes it: malformed when node is set
end)

test('stx: a multi-line hole expression maps back by byte: line/col are the file\'s', function()
    if not ready() then skip 'no javascript/xml parser' end
    local recs = assert(stx.templates([[
// lead
const s = stx`<message xmlns="jabber:client" to="${
    a ? b
      : c}"><body>${text}</body></message>`;
]]))
    local r = recs[1]
    ok(r.ok, r.why)
    eq(2, r.line)
    eq(2, r.holes[1].line)
    eq(4, r.holes[2].line)
    eq(19, r.holes[2].col) -- `      : c}"><body>` is 18 bytes
    eq('text', r.holes[2].expr)
    eq('message/body', r.holes[2].element)
end)

test('stx: only the `stx` tag is read; other tagged templates and plain templates are not stanzas', function()
    if not ready() then skip 'no javascript/xml parser' end
    local recs = assert(stx.templates([[
const a = html`<div>${x}</div>`;
const b = `<iq xmlns="jabber:client"/>`;
const c = stx`<presence xmlns="jabber:client"/>`;
]]))
    eq(1, #recs)
    eq('presence', recs[1].tree.name)
end)

test('stx: a fragment with several roots is legal when spliced, and flagged', function()
    if not ready() then skip 'no javascript/xml parser' end
    local r = one([[const f = stx`<content type="text">${b}</content>${Stanza.unsafeXML(x)}`;]])
    ok(r.ok, r.why)
    eq(true, r.fragment)
    eq(nil, r.tree)
    eq('content', r.roots[1].name)
    eq(2, r.roots[2].hole)
    eq('raw', r.holes[2].fill)
end)

test('stx: a hole in a comment before the root is a comment site (the comment parses inside the prolog)', function()
    if not ready() then skip 'no javascript/xml parser' end
    local r = one([[const s = stx`<!-- ${why} --><iq xmlns="jabber:client"><!-- ${n} --></iq>`;]])
    ok(r.ok, r.why)
    eq('comment', r.holes[1].site)
    eq('comment', r.holes[2].site)
    eq('iq', r.tree.name)
end)

test('xmlvalue.decode: one pass (a decoded ampersand is not decoded again)', function()
    eq('&lt; < " A &unknown;', xv.decode('&#38;lt; &lt; &quot; &#x41; &unknown;'))
end)
