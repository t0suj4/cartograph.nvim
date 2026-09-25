-- CART-1042: an XML document as DATA, in the keyed form yamlvalue gives.
-- ★ The acceptance oracle is Python's ElementTree under the same convention, over 5,517 XML files
-- (wildfly, quarkus, hive, hadoop, jenkins-infra): 5,426 agree — every one of 2,413 pom.xml —
-- with one deliberate difference (DTD entities are not expanded) and every refusal named.

local X = require 'cartograph.xmlvalue'

local function ready()
    if not parser_available('xml') then skip('no xml tree-sitter parser') end
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
    eq('&lol;', d.value)              -- the READER's value keeps it literal; expanding is a policy
    eq(1, d.undefined_entities)
end)

test('xmlvalue: a forbidden control character is KEPT and listed — expat refuses it, Maven keeps it (measured)', function ()
    ready()
    local r = assert(X.read('<a>b\1c</a>'))
    eq(1, #r.forbidden); eq(1, r.forbidden[1].cp)
    eq('b\1c', r.value)
    local v, why = X.decide(r, X.IMPLEMENTATIONS.expat)
    eq(nil, v); ok(why:find('forbids', 1, true), tostring(why))
    eq('b\1c', X.decide(r, X.IMPLEMENTATIONS.maven))
end)

test('xmlvalue: ★★ a DUPLICATE ATTRIBUTE is KEPT, every value in order — the tiebreaker comes later', function ()
    ready()
    local r = assert(X.read('<a k="1" j="x" k="2"><b k="3"/></a>'))
    eq('1,2', table.concat(r.value.o['@k'].a, ','))
    eq('@k,@j,b', table.concat(r.value.keys, ','))
    eq(1, #r.duplicates); eq('@k', r.duplicates[1].attr); eq(2, r.duplicates[1].count)
    eq('3', r.value.o.b.o['@k'])                     -- a lone attribute stays a string
end)

test('xmlvalue: ★★ TIEBREAKERS are named policies — reject (XML 1.0, expat, Maven), first (HTML5), last (dict idiom)', function ()
    ready()
    local r = assert(X.read('<a k="1" k="2"/>'))
    local v, why = X.tiebreak(r.value, 'reject')
    eq(nil, v); ok(why:find('duplicate attribute @k', 1, true), tostring(why))
    eq('1', X.tiebreak(r.value, 'first').o['@k'])
    eq('2', X.tiebreak(r.value, 'last').o['@k'])
    eq(2, #X.tiebreak(r.value, 'keep').o['@k'].a)
    local clean = assert(X.read('<a k="1"/>'))
    eq('1', X.tiebreak(clean.value, 'reject').o['@k'])  -- nothing ambiguous: every policy agrees
end)

test('xmlvalue: ★★★ DIVERGENCES are where policies disagree — equal duplicates still split reject from the rest', function ()
    ready()
    local r = assert(X.read('<a><x k="1" k="2"/><y q="same" q="same"/><z ok="1"/></a>'))
    local d = X.divergences(r.value)
    eq(2, #d)
    eq('$.x', d[1].path); eq('rejected', d[1].outcomes.reject); eq('1', d[1].outcomes.first); eq('2', d[1].outcomes.last)
    eq('$.y', d[2].path); eq('same', d[2].outcomes.first); eq('same', d[2].outcomes.last)
    eq(1, #X.divergences(r.value, { 'first', 'last' })) -- between lenient readers only x diverges
end)

test('xmlvalue: ★ the grammar\'s CDATA bug (`]]]>` runs past the terminator) is REFUSED, not trusted (TSGAP-0009)', function ()
    ready()
    -- two same-named siblings keep the swallowed stretch BALANCED, so the tree has no error node
    local r, why = X.read('<a><d><![CDATA[p]]]></d><d><![CDATA[q]]></d></a>')
    eq(nil, r)
    ok(why:find('CDATA', 1, true), tostring(why))
end)

test('xmlvalue: ★★ a DTD ENTITY keeps both readings — expat/JAXP/REXML expand (nested too), Maven refuses, html.parser keeps it literal', function ()
    ready()
    local r = assert(X.read('<?xml version="1.0"?>\n<!DOCTYPE a [\n<!ENTITY e "x">\n<!ENTITY n "&e;&e;">\n]>\n<a><s>&e;</s><t>&n;</t><u k="&e;!"/></a>\n'))
    eq('entity', r.raw.o.s.amb)
    eq('x', X.decide(r, X.IMPLEMENTATIONS.expat).o.s)
    eq('xx', X.decide(r, X.IMPLEMENTATIONS.jaxp).o.t)
    eq('x!', X.decide(r, X.IMPLEMENTATIONS.rexml).o.u.o['@k'])
    eq('&n;', X.decide(r, X.IMPLEMENTATIONS['html.parser+dict']).o.t)
    local v, why = X.decide(r, X.IMPLEMENTATIONS.maven)
    eq(nil, v); ok(why:find('could not resolve entity', 1, true), tostring(why))
end)

test('xmlvalue: ★★ an EXTERNAL entity is NEVER fetched, and a billion-laughs expansion stops at its limit', function ()
    ready()
    -- (the internal subset starts on its own line: tree-sitter-xml refuses `[<!ENTITY` — TSGAP-0010)
    local r = assert(X.read('<!DOCTYPE a [\n<!ENTITY x SYSTEM "file:///etc/passwd">\n]>\n<a>&x;</a>'))
    local v, why = X.decide(r, X.IMPLEMENTATIONS.expat)
    eq(nil, v); ok(why:find('EXTERNAL', 1, true), tostring(why))
    local lol = { '<!DOCTYPE a [\n<!ENTITY l0 "lollollollollollollollollollol">\n' }
    for i = 1, 9 do lol[#lol + 1] = ('<!ENTITY l%d "%s">\n'):format(i, ('&l' .. (i - 1) .. ';'):rep(10)) end
    lol[#lol + 1] = ']>\n<a>&l9;</a>'
    local bomb = assert(X.read(table.concat(lol)))
    local v2, why2 = X.decide(bomb, X.IMPLEMENTATIONS.expat)
    eq(nil, v2); ok(why2:find('billion-laughs', 1, true), tostring(why2))
    eq('&l9;', bomb.value)                           -- the reader's own value never expands
end)

test('xmlvalue: ★★★ IMPLEMENTATION divergences — one document, the sites where named parsers part ways', function ()
    ready()
    local r = assert(X.read('<?xml version="1.0"?>\n<!DOCTYPE a [\n<!ENTITY e "x">\n]>\n<a k="1" k="2"><s>&e;</s>\1</a>'))
    local rows = X.implementation_divergences(r, { 'expat', 'maven', 'html.parser+dict' })
    local kinds = {}
    for _, row in ipairs(rows) do kinds[row.kind] = row end
    eq('rejected', kinds['control-char'].outcomes.expat); eq('kept', kinds['control-char'].outcomes.maven)
    eq('expanded x', kinds.entity.outcomes.expat); eq('rejected', kinds.entity.outcomes.maven)
    eq('literal &e;', kinds.entity.outcomes['html.parser+dict'])
    eq('the value 2', kinds['duplicate-attribute'].outcomes['html.parser+dict'])
    eq(0, #X.implementation_divergences(assert(X.read('<a k="1">t</a>'))))
end)
