-- CART-1042: a YAML document as DATA, in the keyed form the kv operations read.
-- ★ The acceptance oracle is PyYAML's CBaseLoader over the jenkins-infra org (266 of 266
-- parseable files agree per document); these pin the rules that oracle exercised.

local Y = require 'cartograph.yamlvalue'
local A = assert(require('cartograph.algebra').load())

local function ready()
    if not pcall(vim.treesitter.language.add, 'yaml') then skip('no yaml tree-sitter parser') end
end
local function one(src) return (Y.read_one(src)) end

test('yamlvalue: a mapping keeps key ORDER, and every scalar stays a STRING (no: stays "no")', function ()
    ready()
    local v = one('b: 1\na: no\nc: 1.10\n')
    eq('b,a,c', table.concat(v.keys, ','))
    eq('1', v.o.b); eq('no', v.o.a); eq('1.10', v.o.c)
end)

test('yamlvalue: nested mappings, block and flow sequences, flow mappings', function ()
    ready()
    local v = one('x:\n  y:\n  - 1\n  - two\n  z: [a, b]\n  w: {p: 1, q: 2}\n')
    eq(2, #v.o.x.o.y.a)
    eq('two', v.o.x.o.y.a[2])
    eq('b', v.o.x.o.z.a[2])
    eq('2', v.o.x.o.w.o.q)
end)

test('yamlvalue: quoting — double-quoted escapes, single-quoted doubled quote', function ()
    ready()
    local v = one('a: "x\\ty"\nb: \'it\'\'s\'\nc: "\\u00e9"\n')
    eq('x\ty', v.o.a)
    eq('\u{e9}', v.o.c) -- a \\u escape (LuaJIT has no utf8 library: encoded by hand)
    eq("it's", v.o.b)
end)

test('yamlvalue: block scalars — literal keeps lines, folded joins them, chomping decides the tail', function ()
    ready()
    local v = one('lit: |\n  one\n  two\nfold: >\n  one\n  two\nstrip: |-\n  x\n')
    eq('one\ntwo\n', v.o.lit)
    eq('one two\n', v.o.fold)
    eq('x', v.o.strip)
end)

test('yamlvalue: an alias resolves to its anchor\'s value; `<<` stays an ordinary key (BaseLoader)', function ()
    ready()
    local v = one('base: &b\n  k: 1\nuse: *b\nmerged:\n  <<: *b\n')
    ok(A.kv_eq(v.o.base, v.o.use), 'the alias is the anchored value')
    eq('<<', v.o.merged.keys[1])
end)

test('yamlvalue: several documents; a `{{` document is flagged TEMPLATED, not trusted as values', function ()
    ready()
    local docs = Y.read('a: 1\n---\nb: "{{ .Values.x }}"\n')
    eq(2, #docs)
    eq(false, docs[1].templated)
    eq(true, docs[2].templated)
end)

test('yamlvalue: an empty value is the empty string; a broken document is refused by name', function ()
    ready()
    eq('', one('a:\n').o.a)
    local d, why = Y.read('a: [1, 2\n')
    eq(nil, d)
    ok(why:find('does not parse', 1, true), tostring(why))
end)

-- ── CART-1053: ambiguity kept in `doc.raw`, implementations as PROFILES (measured 2026-09-24) ──

local function raw(src) local docs = assert(Y.read(src)); return docs[1] end

test('yamlvalue: ★ the raw tree keeps every ambiguity; `value` is still the BaseLoader decision', function ()
    ready()
    local d = raw('a: 1\na: 2\nbase: &b {k: 1}\nuse:\n  <<: *b\n  j: 2\nq: "no"\nn: no\n')
    local P = d.raw.pairs
    eq('a,a,base,use,q,n', table.concat(vim.tbl_map(function(p) return p.k end, P), ','))  -- both `a` pairs kept
    eq('<<', P[4].v.pairs[1].k); eq(true, P[4].v.pairs[1].plain)
    eq('scalar', P[6].v.amb); eq('no', P[6].v.text)
    eq('no', P[5].v)                                 -- a QUOTED scalar is a string everywhere: no ambiguity
    eq('2', d.value.o.a); eq('a,base,use,q,n', table.concat(d.value.keys, ','))   -- first place, last value
    eq('<<', d.value.o.use.keys[1])                  -- BaseLoader: a literal key
end)

test('yamlvalue: ★★ each implementation decides the SAME raw tree differently — as measured', function ()
    ready()
    local d = raw('a: 1\na: 2\nbase: &b {k: 1, j: 0}\nuse:\n  <<: *b\n  j: 2\n')
    local I = Y.IMPLEMENTATIONS
    eq(nil, (Y.decide(d.raw, I['ruamel-safe'])))     -- ruamel: DuplicateKeyError
    local py = assert(Y.decide(d.raw, I['pyyaml-safe']))
    eq('2', py.o.a); eq('k,j', table.concat(py.o.use.keys, ',')); eq('2', py.o.use.o.j)
    local xs = assert(Y.decide(d.raw, I['yaml-xs']))
    eq('<<', xs.o.use.keys[1])                       -- YAML::XS does not merge
    local yq = assert(Y.decide(d.raw, I.yq))
    eq(2, #yq.o.a.o.__dup.a)                         -- yq keeps both
end)

test('yamlvalue: ★★★ RESOLVERS — the measured table, cell by cell', function ()
    local cases = {
        -- text        pyyaml            ruamel          psych              goyaml (type)  libyaml-perl
        { 'no',       'bool:false',      'str:no',       'bool:false',      'str',         'str:no' },
        { 'on',       'bool:true',       'str:on',       'bool:true',       'str',         'str:on' },
        { 'yEs',      'str:yEs',         'str:yEs',      'bool:true',       'str',         'str:yEs' },
        { '010',      'int:8',           'int:10',       'int:8',           'int',         'str:010' },
        { '08',       'str:08',          'int:8',        'str:08',          'float',       'str:08' },
        { '0o10',     'str:0o10',        'int:8',        'str:0o10',        'int',         'str:0o10' },
        { '1_000',    'int:1000',        'int:1000',     'int:1000',        'int',         'str:1_000' },
        { '1,000',    'str:1,000',       'str:1,000',    'int:1000',        'str',         'str:1,000' },
        { '1:20',     'int:80',          'str:1:20',     'int:4800',        'str',         'str:1:20' },
        { '12:30:45', 'int:45045',       'str:12:30:45', 'int:45045',       'str',         'str:12:30:45' },
        { '1e5',      'str:1e5',         'float:100000', 'str:1e5',         'float',       'str:1e5' },
        { '1.5e+3',   'float:1500',      'float:1500',   'float:1500',      'float',       'str:1.5e+3' },
        { '0x1F',     'int:31',          'int:31',       'int:31',          'int',         'str:0x1F' },
        { '0b11',     'int:3',           'int:3',        'int:3',           'int',         'str:0b11' },
        { 'Null',     'null',            'null',         'null',            'null',        'str:Null' },
        { 'FALSE',    'bool:false',      'bool:false',   'bool:false',      'bool',        'str:FALSE' },
        { '~',        'null',            'null',         'null',            'null',        'null' },
        { '.inf',     'float:inf',       'float:inf',    'float:inf',       'float',       'str:.inf' },
        { '2001-12-14', 'timestamp',     'timestamp',    'timestamp',       'timestamp',   'str:2001-12-14' },
        { '-0',       'int:0',           'int:0',        'int:0',           'float',       'str:-0' },
        { 'y',        'str:y',           'str:y',        'str:y',           'str',         'str:y' },
    }
    local names = { 'pyyaml', 'ruamel', 'psych', 'goyaml', 'libyaml-perl' }
    for _, c in ipairs(cases) do
        for i, r in ipairs(names) do
            local t, v = Y.resolve(c[1], r)
            local got = (r == 'goyaml' or v == nil) and t or (t .. ':' .. v)
            eq(c[i + 1], got, c[1] .. ' under ' .. r)
        end
    end
end)

test('yamlvalue: ★★ DIVERGENCES — Norway, an `on:` key, a duplicate, a merge; quoted and agreed scalars are silent', function ()
    ready()
    local d = raw('on:\n  push: {}\nx: no\nq: "no"\ns: hello\na: 1\na: 2\n')
    local rows = Y.divergences(d.raw, { 'pyyaml-safe', 'ruamel-safe' })
    local by = {}
    for _, r in ipairs(rows) do by[r.path .. ' ' .. r.kind] = r end
    ok(by['$.on key'], 'the `on:` key is a boolean to YAML 1.1')
    eq('bool:true', by['$.on key'].outcomes['pyyaml-safe']); eq('str:on', by['$.on key'].outcomes['ruamel-safe'])
    ok(by['$.x scalar'], 'Norway'); eq(nil, by['$.q scalar']); eq(nil, by['$.s scalar'])
    ok(by['$ duplicate-key'], 'last vs rejected')      -- a duplicate belongs to its MAPPING
    eq('a=a rejected', by['$ duplicate-key'].outcomes['ruamel-safe'])
    eq('a=a the last', by['$ duplicate-key'].outcomes['pyyaml-safe'])
    -- a types-only implementation agrees with any value of its type
    local r2 = Y.divergences(raw('n: 12\n').raw, { 'pyyaml-safe', 'yq' })
    eq(0, #r2)
end)

test('yamlvalue: typed() is what an implementation LOADS — keys typed where it types them, sorted where it cannot order', function ()
    ready()
    local d = raw('b: 1\non: yes\n')
    local py = assert(Y.typed(d.raw, Y.IMPLEMENTATIONS['pyyaml-safe']))
    eq('str:b,bool:true', table.concat(py.keys, ','))
    eq('bool:true', py.o['bool:true'])
    local xs = assert(Y.typed(d.raw, Y.IMPLEMENTATIONS['yaml-xs']))
    eq('str:b,str:on', table.concat(xs.keys, ','))  -- a Perl hash: keys are strings, order is not kept
    eq('str:yes', xs.o['str:on'])
end)

test('yamlvalue: ★★★ TWO MERGE ALGORITHMS — explicit keys win (PyYAML/ruamel) vs `<<` overrides what came before (Psych/yq)', function ()
    ready()
    local I = Y.IMPLEMENTATIONS
    local one = raw('b: &b {k: 1, a: 0}\nm:\n  a: 1\n  <<: *b\n  z: 2\n')
    local py = assert(Y.decide(one.raw, I['pyyaml-safe'])).o.m
    eq('1', py.o.a); eq('k,a,z', table.concat(py.keys, ','))
    local ps = assert(Y.decide(one.raw, I['psych-safe'])).o.m
    eq('0', ps.o.a); eq('a,k,z', table.concat(ps.keys, ','))
    -- a LIST of sources: reversed, so the earlier source wins in both — measured on all four
    local seq = raw('x: &x {k: 1, a: 1}\ny: &y {k: 2, b: 2}\nm:\n  a: 9\n  <<: [*x, *y]\n')
    local py2 = assert(Y.decide(seq.raw, I['pyyaml-safe'])).o.m
    eq('k,b,a', table.concat(py2.keys, ',')); eq('1', py2.o.k); eq('9', py2.o.a)
    local ps2 = assert(Y.decide(seq.raw, I['psych-safe'])).o.m
    eq('a,k,b', table.concat(ps2.keys, ',')); eq('1', ps2.o.k); eq('1', ps2.o.a)
    -- and the divergence is reported only where the mappings really differ
    local agree = raw('b: &b {k: 1}\nm:\n  <<: *b\n  z: 2\n')
    local rows = Y.divergences(agree.raw, { 'pyyaml-safe', 'psych-safe' })
    for _, r in ipairs(rows) do ok(r.kind ~= 'merge-key', 'no overlap, same order: no merge divergence') end
    local rows2 = Y.divergences(one.raw, { 'pyyaml-safe', 'psych-safe' })
    local found = false
    for _, r in ipairs(rows2) do if r.kind == 'merge-key' then found = true end end
    ok(found, 'a = 1 vs a = 0 is a divergence')
end)

test('yamlvalue: a block scalar header COMMENT is not an indicator — `|  # command-instead` keeps its newline (SUSE15-CIS)', function ()
    ready()
    eq('a\nb\n', one('k: |  # noqa command-instead-of-module\n  a\n  b\nz: 1\n').o.k)
    eq('a', one('k: |- # keep-me\n  a\n').o.k)
end)

test('yamlvalue: yq TYPES ITS KEYS (measured: `200:` !!int, `on:` !!str) — keys are `type:text`, never a bare type', function ()
    ready()
    local t = assert(Y.typed(raw('200: ok\non: x\n"300": q\n').raw, Y.IMPLEMENTATIONS.yq))
    eq('int:200,str:on,str:300', table.concat(t.keys, ','))
end)

test('yamlvalue: ★★ EXPLICIT TAGS — an unknown one rejected (PyYAML, ruamel), ignored (Psych, XS), kept (yq); `!!bool` refused by XS', function ()
    ready()
    local I = Y.IMPLEMENTATIONS
    local d = raw('a: !Sub "x-${y}"\ne: !Ref plain\nm: !Custom {k: 1}\n')
    eq(nil, (Y.decide(d.raw, I['pyyaml-safe']))); eq(nil, (Y.decide(d.raw, I['ruamel-safe'])))
    local ps = assert(Y.typed(d.raw, I['psych-safe']))
    eq('str:x-${y}', ps.o['str:a']); eq('str:plain', ps.o['str:e']); eq('int:1', ps.o['str:m'].o['str:k'])
    local yq = assert(Y.typed(d.raw, I.yq))
    eq('tag:!Sub', yq.o['str:a']); eq('tag:!Ref', yq.o['str:e'])
    eq('x-${y}', d.value.o.a)                        -- BaseLoader value: the text, tag ignored
    local s = raw('b: !!str 010\nc: !!int "12"\ng: !!bool "yes"\n')
    local py = assert(Y.typed(s.raw, I['pyyaml-safe']))
    eq('str:010', py.o['str:b']); eq('int:12', py.o['str:c']); eq('bool:true', py.o['str:g'])
    local v, why = Y.decide(s.raw, I['yaml-xs'])
    eq(nil, v); ok(why:find('bad tag', 1, true), tostring(why))
    local rows = Y.divergences(d.raw, { 'pyyaml-safe', 'psych-safe', 'yq' })
    local tags = 0
    for _, r in ipairs(rows) do if r.kind == 'tag' then tags = tags + 1 end end
    eq(3, tags)
end)

test('yamlvalue: an ESCAPED LINE BREAK in double quotes drops the break and the indent (wildfly, quarkus `if:`)', function ()
    ready()
    eq('artifact via x', one('d: "artifact\\\n  \\ via x"\n').o.d)
    eq('a && ( b', one('d: "a && ( \\\n     b"\n').o.d)
    eq('a\\ b', one('d: "a\\\\\n  b"\n').o.d)               -- an EVEN run: a literal backslash, then a fold
end)

test('yamlvalue: a block scalar keeps its last line\'s trailing space, and has no final break at an unterminated EOF', function ()
    ready()
    eq('- a\n- \n', one('v: |\n  - a\n  - \nz: 1\n').o.v)
    eq('cd x\nmvn y', one('run: |\n  cd x\n  mvn y').o.run)
end)

test('yamlvalue: ★ PERL IS UNTYPED — a numeric string agrees with the number it numifies to, and only that', function ()
    ready()
    eq(0, #Y.divergences(raw('n: 12\nf: 1.5\n').raw, { 'pyyaml-safe', 'yaml-xs' }))
    eq(0, #Y.divergences(raw('n: 12\nf: 1.5\n').raw, { 'yaml-xs', 'pyyaml-safe' }))  -- either side may be the Perl one
    local rows = Y.divergences(raw('o: 010\nh: 0x1F\n').raw, { 'pyyaml-safe', 'yaml-xs' })
    eq(2, #rows)                                     -- Perl reads 10 and 0 where PyYAML reads 8 and 31
end)

test('yamlvalue: ★★★ DUPLICATES DEPEND ON THE KEY, NOT THE VALUE — each language\'s key equality, as measured', function ()
    ready()
    local I = Y.IMPLEMENTATIONS
    local function keys_of(src, impl)
        local t, why = Y.typed(raw(src).raw, I[impl])
        if t == nil then return 'REJECT' end
        local parts = {}
        for _, k in ipairs(t.keys) do parts[#parts + 1] = k .. '=' .. (type(t.o[k]) == 'table' and 'dup' or t.o[k]) end
        return table.concat(parts, ' ')
    end
    -- the VALUE's type changes nothing: a map/map duplicate is last-wins/reject/keep like scalar/scalar
    eq('str:a', keys_of('a: {x: 1}\na: {y: 2}\n', 'pyyaml-safe'):match('^[^=]+'))
    eq('REJECT', keys_of('a: {x: 1}\na: {y: 2}\n', 'ruamel-safe'))
    -- the KEY's identity does:           PyYAML              ruamel            Psych                        YAML::XS            yq
    local cases = {
        { 'true: a\nyes: b\n', 'bool:true=str:b', 'bool:true=str:a str:yes=str:b', 'bool:true=str:b', 'str:1=str:a str:yes=str:b', 'bool:true=str str:yes=str' },
        { '010: a\n8: b\n', 'int:8=str:b', 'int:10=str:a int:8=str:b', 'int:8=str:b', 'str:010=str:a str:8=str:b', 'int:010=str int:8=str' },
        { '1: a\n"1": b\n', 'int:1=str:a str:1=str:b', 'int:1=str:a str:1=str:b', 'int:1=str:a str:1=str:b', 'str:1=str:b', 'int:1=dup' },
        { '16: a\n0x10: b\n', 'int:16=str:b', 'REJECT', 'int:16=str:b', 'str:0x10=str:b str:16=str:a', 'int:16=str int:0x10=str' },
        { 'true: a\n1: b\n', 'bool:true=str:b', 'REJECT', 'bool:true=str:a int:1=str:b', 'str:1=str:b', 'bool:true=str int:1=str' },
        { 'null: a\n~: b\n"": c\n', 'null=str:b str:=str:c', 'REJECT', 'null=str:b str:=str:c', 'str:=str:c', 'null:null=str null:~=str str:=str' },
    }
    local names = { 'pyyaml-safe', 'ruamel-safe', 'psych-safe', 'yaml-xs', 'yq' }
    for _, c in ipairs(cases) do
        for i, n in ipairs(names) do eq(c[i + 1], keys_of(c[1], n), c[1]:gsub('\n', ' ') .. ' under ' .. n) end
    end
end)

test('yamlvalue: ★★ TWO `<<` KEYS — both merge, the LATER one wins an overlap (PyYAML, Psych); XS keeps the last literal', function ()
    ready()
    local d = raw('b: &b {k: 1, x: 1}\nc: &c {k: 2, y: 2}\nm:\n  <<: *b\n  <<: *c\n')
    local py = assert(Y.typed(d.raw, Y.IMPLEMENTATIONS['pyyaml-safe'])).o['str:m']
    eq('str:k,str:x,str:y', table.concat(py.keys, ',')); eq('int:2', py.o['str:k'])
    local ps = assert(Y.typed(d.raw, Y.IMPLEMENTATIONS['psych-safe'])).o['str:m']
    eq('int:2', ps.o['str:k'])
    eq(nil, (Y.typed(d.raw, Y.IMPLEMENTATIONS['ruamel-safe'])))
    local xs = assert(Y.typed(d.raw, Y.IMPLEMENTATIONS['yaml-xs'])).o['str:m']
    eq('str:<<', xs.keys[1]); eq('str:2', xs.o['str:<<'].o['str:k'])
    -- a key written AFTER a `<<` wins again under the in-place algorithm
    local split = raw('b: &b {k: 1}\nm:\n  <<: *b\n  z: 0\n  <<: {k: 3}\n')
    eq('int:3', assert(Y.typed(split.raw, Y.IMPLEMENTATIONS['psych-safe'])).o['str:m'].o['str:k'])
    eq('int:3', assert(Y.typed(split.raw, Y.IMPLEMENTATIONS['pyyaml-safe'])).o['str:m'].o['str:k'])
end)
