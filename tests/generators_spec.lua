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

-- ── DERIVED from the interpreter (CART-1125, erlderive) ─────────────────────────────────────────────────────────
local GEN_MOD = table.concat({
    '-module(gen).',
    '-type reg() :: {iq_handler, atom(), binary(), atom()} | {hook, atom(), atom(), integer()}.',  -- a TYPE: non-site
    'start_module(Host, Module, Opts) ->',
    '    case Module:start(Host, Opts) of',
    '        {ok, Registrations} -> add_registrations(Host, Module, Registrations);',
    '        _ -> ok',
    '    end.',
    'add_registrations(Host, Module, Registrations) ->',
    '    lists:foreach(',
    '      fun({hook, Hook, Function, Seq}) -> hooks:add(Hook, Host, Module, Function, Seq);',
    '         ({hook, Hook, Function, Seq, Host1}) when is_integer(Seq) -> hooks:add(Hook, Host1, Module, Function, Seq);',
    '         ({hook, Hook, Module1, Function, Seq}) when is_integer(Seq) -> hooks:add(Hook, Host, Module1, Function, Seq);',
    '         ({iq_handler, Component, NS, Function}) -> gen_iq_handler:add_iq_handler(Component, Host, NS, Module, Function)',
    '      end, Registrations).',
}, '\n') .. '\n'
local MOD_A = table.concat({
    '-module(mod_a).',
    'start(_Host, _Opts) ->',
    '    {ok, [{iq_handler, ejabberd_local, ?NS_A, process_iq},',
    '          {hook, h1, f1, 50},',
    '          {hook, h2, f2, 60, global},',          -- 5-tuple, an integer in position 4: the Host1 clause
    '          {hook, h3, mod_b, f3, 70},',           -- 5-tuple, an integer in position 5: the Module1 clause
    '          {hook, h4, f4, ?PRIO, global}]}.',     -- the guard cannot be decided on a macro: REFUSED, no fall-through
    'helper() -> {hook, not_a, registration, 1}.',     -- a value, but not inside the callback: a non-site
}, '\n') .. '\n'

local function derive(files_src)
    local D = require 'cartograph.erlderive'
    local files = {}
    for rel, src in pairs(files_src) do files[#files + 1] = { rel = rel, src = src } end
    table.sort(files, function (a, b) return a.rel < b.rel end)
    local it
    for _, f in ipairs(files) do for _, x in ipairs(D.find(f.src, f.rel)) do it = it or x end end
    local chain = D.context_chain(it, files)
    return D.generator(it, chain, require('cartograph.providers.treesitter').spec.erlang), it, chain, files
end

test('erlderive: the interpreter IS the declaration — heads, guards, effects and the callback module, derived', function ()
    if not parser_available('erlang') then skip 'no erlang parser' end
    local gen, it, chain = derive({ ['src/gen.erl'] = GEN_MOD, ['src/mod_a.erl'] = MOD_A })
    eq('add_registrations', it.fn.name); eq(4, #it.clauses)
    ok(chain[2] and chain[2].callback.fn == 'start' and chain[2].callback.arity == 2, 'Module is bound through Module:start/2')
    local facts, refusals, selected = G.read(gen, tree(MOD_A, 'erlang'), MOD_A, 'src/mod_a.erl')
    local rows = {}
    for _, f in ipairs(facts) do rows[#rows + 1] = table.concat(f.parts, ' ') end
    table.sort(rows)
    eq({ 'gen_iq_handler.add_iq_handler ejabberd_local ?Host NS_A mod_a process_iq',
         'hooks.add h1 ?Host mod_a f1 50',
         'hooks.add h2 global mod_a f2 60',      -- Host1 = global
         'hooks.add h3 ?Host mod_b f3 70' }, rows) -- Module1 = mod_b
    eq(5, selected)
    eq(1, #refusals); eq('guard', refusals[1].reason)
end)

test('erlderive: types, the interpreter heads and a value outside the callback are NON-SITES, silent', function ()
    if not parser_available('erlang') then skip 'no erlang parser' end
    local gen = derive({ ['src/gen.erl'] = GEN_MOD, ['src/mod_a.erl'] = MOD_A })
    local _, r1, s1, non1 = G.read(gen, tree(GEN_MOD, 'erlang'), GEN_MOD, 'src/gen.erl')
    eq(0, s1); eq(0, #r1)
    eq(6, #non1, 'the two tuples of the -type and the four interpreter heads')
    local _, _, _, non2 = G.read(gen, tree(MOD_A, 'erlang'), MOD_A, 'src/mod_a.erl')
    eq(1, #non2, 'helper/0 builds a hook tuple outside start/2')
end)

test('erlderive: with no caller binding the list, the module stays an explicit unresolved marker', function ()
    if not parser_available('erlang') then skip 'no erlang parser' end
    local no_chain = GEN_MOD:gsub('start_module%(.-end%.\n', '')
    local gen, _, chain = derive({ ['src/gen.erl'] = no_chain, ['src/mod_a.erl'] = MOD_A })
    eq(nil, next(chain))
    local facts = G.read(gen, tree(MOD_A, 'erlang'), MOD_A, 'src/mod_a.erl')
    local iq
    for _, f in ipairs(facts) do if f.parts[1]:match('add_iq_handler') then iq = f end end
    eq('?Module', iq.parts[5], 'not the file name: the hand rule does not come back')
    -- and with no callback to restrict the population, the POSITION rules alone keep types and heads out
    local _, _, s1, non1 = G.read(gen, tree(no_chain, 'erlang'), no_chain, 'src/gen.erl')
    eq(0, s1); eq(6, #non1, 'the -type tuples (a type context) and the interpreter heads (patterns)')
end)
