-- cartograph.generators (CART-1125, first step): a generator is a site selector, the forms a site may take as
-- algebra templates, and what each form generates. Pinned BOTH WAYS for each declaration: a site that must
-- generate, a selected site that must refuse (with the right reason), and a non-site that must stay silent.

local G = require 'cartograph.generators'

local function tree(src, lang)
    local p = vim.treesitter.get_string_parser(src, lang)
    return p:parse()[1]:root()
end

local function names(facts)
    local out = {}
    for _, f in ipairs(facts) do out[#out + 1] = f.name end
    table.sort(out)
    return out
end

local function reasons(refusals)
    local out = {}
    for _, r in ipairs(refusals) do out[#out + 1] = r.reason end
    table.sort(out)
    return out
end

test('generators/erlreg: a registration tuple generates (registration key mod fn), from erlreg.CARRIERS', function ()
    if not parser_available('erlang') then skip 'no erlang parser' end
    local gen = G.from_erlreg(require('cartograph.erlreg').CARRIERS)[1]
    local src = table.concat({
        '-module(mod_x).',
        'start(_, _) -> [{iq_handler, ejabberd_local, ?NS_A, process_a},',          -- arity 4: mod is the file
        '                {iq_handler, ejabberd_sm, ?NS_B, other_mod, process_b},',  -- arity 5: mod is element 4
        '                {iq_handler, x, Ns, f},',                                  -- a PATTERN: a var key refuses
        '                {iq_handler, a, b, c, d, e},',                             -- no form of that arity
        '                {other_tag, ejabberd_local, ?NS_C, process_c},',           -- not a site at all
        '                {x, iq_handler}].',                                        -- the tag in 2nd place: not a site
    }, '\n') .. '\n'
    local facts, refusals, selected = G.read(gen, tree(src, 'erlang'), src, 'src/mod_x.erl')
    eq(4, selected, 'the other_tag tuple is not selected')
    local rows = {}
    for _, f in ipairs(facts) do rows[#rows + 1] = table.concat(f.parts, ' ') end
    table.sort(rows)
    eq({ 'NS_A mod_x process_a', 'NS_B other_mod process_b' }, rows)
    eq({ 'hole', 'shape' }, reasons(refusals), 'a var key is a hole refusal; a 6-tuple fits no form')
    eq(1, facts[1].site[1], 'a fact carries its site (0-based line)')
end)

test('generators/ruby.attr: readers and writers, singleton_class and a constant receiver, and the refusals', function ()
    if not parser_available('ruby') then skip 'no ruby parser' end
    local gen = require('cartograph.spec.ruby').generators[1]
    local src = table.concat({
        'class C',
        '  attr_accessor :a, "b"',
        '  attr_reader :r',
        '  attr_writer :c, # a comment between arguments is not an argument',
        '    :d',
        '  class << self',
        '    attr_reader :k',                 -- inside `class << self`: a singleton method, C.k
        '  end',
        '  singleton_class.attr_writer :s',
        '  Thread.attr_accessor :t',
        '  xs.each { |n| attr_accessor n }',  -- a computed name: refused by the element domain
        '  attr_reader "bad name"',           -- a string (in the domain) that is not an identifier: FILTERED, no refusal
        '  attr_reader :"quoted"',            -- a delimited symbol: outside the element domain, the site refuses
        '  puts :a',                          -- not a site
        'end',
        'attr_accessor :orphan',              -- no enclosing class: a context refusal
    }, '\n') .. '\n'
    local facts, refusals, selected = G.read(gen, tree(src, 'ruby'), src, 'c.rb')
    eq(10, selected)
    eq({ 'C#a', 'C#a=', 'C#b', 'C#b=', 'C#c=', 'C#d=', 'C#r', 'C.k', 'C.s=', 'Thread#t', 'Thread#t=' }, names(facts))
    eq({ 'context', 'hole', 'hole' }, reasons(refusals))
    local byname = {}
    for _, f in ipairs(facts) do byname[f.name] = f end
    eq(1, byname['C#a'].at[1], 'each generated def points at its own symbol')
end)

test('generatorjoin: the two-way diff names what each side has alone', function ()
    local J = dofile(vim.fn.getcwd() .. '/tools/generatorjoin.lua')
    local d = J.diff({ x = true, y = true }, { y = true, z = true })
    eq(1, d.both); eq({ 'x' }, d.only_a); eq({ 'z' }, d.only_b)
end)

test('generators/rails.dsl (the THIRD reader): an association names itself first; delegate generates per symbol', function ()
    if not parser_available('ruby') then skip 'no ruby parser' end
    local gen = require('cartograph.providers.treesitter').packs.rails.generators[1]
    local src = table.concat({
        'class Post',
        '  belongs_to :author, -> { where(active: true) }, optional: true', -- options after the name are not names
        '  has_many :comments',
        '  has_many :things?',                                             -- a symbol but not a method name: filtered
        '  delegate :name, :email, to: :author, prefix: true',             -- the pairs are options (`only`)
        '  has_one "legacy"',                                              -- a string name: the assoc hole refuses
        '  has_many :"bad name"',                                          -- delimited: refused
        '  def x; delegate.respond_to?(:y); end',                          -- `delegate` as a RECEIVER: not a site
        'end',
    }, '\n') .. '\n'
    local facts, refusals, selected = G.read(gen, tree(src, 'ruby'), src, 'post.rb')
    eq(6, selected)
    eq({ 'Post#author', 'Post#author=', 'Post#comments', 'Post#comments=', 'Post#email', 'Post#name' }, names(facts))
    eq({ 'hole', 'hole' }, reasons(refusals))
    -- `check`: a single-hole output is filtered by name too, and points at that hole's node
    local by = {}
    for _, f in ipairs(facts) do by[f.name] = f end
    eq(1, by['Post#author'].at[1])
end)

test("generators.snippet: a source snippet is a template in the grammar's own shape, placeholders as holes", function ()
    if not parser_available('erlang') then skip 'no erlang parser' end
    local A = require('cartograph.algebra').load()
    local T = G.snippet(A, 'erlang', '{tag, __a, __rest__}', { a = { 'atom' } }, 'f() -> %s.')
    eq('(tuple (atom "tag") ?a ?rest...)', A.show(T.body):gsub('%s+', ' '))
    -- a snippet the grammar only recovers from refuses: it does not template the error recovery
    eq(nil, (G.snippet(A, 'erlang', '{tag, __a', nil, nil)))
    -- no wrap needed where the top level admits the shape: the same template either way
    eq(A.show(T.body), A.show(G.snippet(A, 'erlang', '{tag, __a, __rest__}', { a = { 'atom' } }).body))
end)
