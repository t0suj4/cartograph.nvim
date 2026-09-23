-- CART-1042: a YAML document as DATA, in the keyed form the kv operations read.
-- ★ The acceptance oracle is PyYAML's CBaseLoader over the jenkins-infra org (266 of 266
-- parseable files agree per document); these pin the rules that oracle exercised.

local Y = require 'cartograph.yamlvalue'
local A = assert(require('cartograph.algebra').load())

local function ready()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
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
    local v = one('a: "x\\ty"\nb: \'it\'\'s\'\n')
    eq('x\ty', v.o.a)
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
