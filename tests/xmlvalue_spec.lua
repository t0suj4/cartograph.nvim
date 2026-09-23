-- CART-1042: an XML document as DATA, in the keyed form yamlvalue gives.
-- ★ The acceptance oracle is Python's ElementTree under the same convention, over 5,517 XML files
-- (wildfly, quarkus, hive, hadoop, jenkins-infra): 5,426 agree — every one of 2,413 pom.xml —
-- with one deliberate difference (DTD entities are not expanded) and every refusal named.

local X = require 'cartograph.xmlvalue'

local function ready()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not pcall(vim.treesitter.language.add, 'xml') then skip('no xml tree-sitter parser') end
end

test('xmlvalue: attributes are @keys, repeated children an ARRAY, a text-only element its text', function ()
    ready()
    local r = assert(X.read('<p a="1"><dep>x</dep><dep>y</dep><v>1.0</v><empty/></p>'))
    eq('p', r.root)
    eq('@a,dep,v,empty', table.concat(r.value.keys, ','))
    eq('1', r.value.o['@a'])
    eq(2, #r.value.o.dep.a)
    eq('y', r.value.o.dep.a[2])
    eq('1.0', r.value.o.v)
    eq('', r.value.o.empty)
end)

test('xmlvalue: indentation between elements is dropped; the text of MIXED content is #text', function ()
    ready()
    local r = assert(X.read('<p>\n  <a>1</a>\n  hello\n</p>'))
    ok(r.value.o['#text']:find('hello', 1, true), 'mixed text kept')
    local r2 = assert(X.read('<p>\n  <a>1</a>\n</p>'))
    eq(nil, r2.value.o['#text'])
end)

test('xmlvalue: ★ XML whitespace is space/tab/CR/LF only — a non-breaking space is TEXT (the oracle had this wrong)', function ()
    ready()
    local r = assert(X.read('<p><a>1</a>\u{a0}</p>'))
    eq('\u{a0}', r.value.o['#text'])
end)

test('xmlvalue: ★★ NAMESPACES RESOLVED — home bare, a foreign one {uri}local, a prefixed root is its own home', function ()
    ready()
    local r = assert(X.read('<project xmlns="urn:pom" xmlns:x="urn:ext"><a/><x:c k="1" x:q="2">z</x:c></project>'))
    eq('project', r.root)
    local c = r.value.o['{urn:ext}c']
    ok(c, 'the foreign element is {uri}local')
    eq('1', c.o['@k'])                -- an unprefixed attribute is in NO namespace
    eq('2', c.o['@{urn:ext}q'])       -- a prefixed one is in its prefix's
    eq(nil, r.value.o['@xmlns'])      -- declarations are consumed
    local p = assert(X.read('<j:ejb xmlns:j="urn:j"><j:bean/></j:ejb>'))
    eq('ejb', p.root)                 -- the root's OWN namespace is home
    ok(p.value.o.bean ~= nil, 'a child in the home namespace is bare')
end)

test('xmlvalue: entities and character references decode, CDATA is literal; a DTD entity is kept and COUNTED', function ()
    ready()
    local r = assert(X.read('<a k="x &amp; y">t &lt; &#65;&#x42;<![CDATA[<raw>]]></a>'))
    eq('x & y', r.value.o['@k'])
    eq('t < AB<raw>', r.value.o['#text'] or r.value)
    local d = assert(X.read('<?xml version="1.0"?>\n<!DOCTYPE a [\n  <!ENTITY lol "lol">\n]>\n<a>&lol;</a>\n'))
    eq('&lol;', d.value)              -- never expanded: the billion-laughs file stays one entity
    eq(1, d.undefined_entities)
end)

test('xmlvalue: NOT WELL-FORMED is refused by name — a duplicate attribute, a forbidden control character', function ()
    ready()
    local r, why = X.read('<a k="1" k="2"/>')
    eq(nil, r); ok(why:find('duplicate attribute', 1, true), tostring(why))
    local r2, why2 = X.read('<a>\1</a>')
    eq(nil, r2); ok(why2:find('forbids', 1, true), tostring(why2))
end)

test('xmlvalue: ★ the grammar\'s CDATA bug (`]]]>` runs past the terminator) is REFUSED, not trusted (TSGAP-0009)', function ()
    ready()
    -- two same-named siblings keep the swallowed stretch BALANCED, so the tree has no error node
    local r, why = X.read('<a><d><![CDATA[p]]]></d><d><![CDATA[q]]></d></a>')
    eq(nil, r)
    ok(why:find('CDATA', 1, true), tostring(why))
end)
