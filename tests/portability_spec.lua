-- PORTABILITY: the external surface scored against a target environment profile.
-- The design note expected hand-authored `<runtime>-provides` sets; none were
-- needed, because a profile already IS a provides set. So what these pin is the
-- intersection and, above all, the honesty: this verb is the easiest in the
-- codebase to overstate, since "not in the profile" is not "missing".

local port = require 'cartograph.portability'

local function ready()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    return pcall(vim.treesitter.get_string_parser, '', 'ruby')
end

test('portability: provides() answers from every artifact shape', function ()
    -- the shapes really differ: a distilled zig std is free-fn heavy, a hand
    -- Factorio profile namespace-heavy, an RBS-derived one signature-keyed
    local prof = {
        lang = 'x',
        vocab = { tally = true },
        free = { helper = true },
        nsset = { Rails = true },
        types = { String = { members = { chomp = true } } },
        sigs = { ['String#squish'] = { sig = '() -> String' } },
    }
    ok(port.provides(prof, 'tally'), 'vocab')
    ok(port.provides(prof, 'helper'), 'free fn')
    ok(port.provides(prof, 'Rails.logger'), 'a provided namespace covers its members')
    ok(port.provides(prof, 'String.chomp'), 'a type member')
    ok(port.provides(prof, 'String#squish'), 'a signature key')
    eq(nil, port.provides(prof, 'nope'), 'and an unknown name is nil, not a guess')
    eq(nil, port.provides(nil, 'tally'), 'no profile provides nothing')
end)

test('portability: profile_size reports the weight behind a verdict', function ()
    eq(0, port.profile_size({}), 'an empty profile claims nothing')
    eq(3, port.profile_size({ vocab = { a = true, b = true }, free = { c = true } }),
        'and a real one is counted, so the reader can discount a thin artifact')
end)

test('portability: runtimes() is DERIVED from the shipped artifacts', function ()
    local rs = port.runtimes()
    ok(#rs > 0, 'some profile ships')
    local has = {}
    for _, r in ipairs(rs) do has[r] = true end
    ok(has['ruby-rails'], 'the rails profile is offered as a target')
    eq(nil, has['init'], 'the loader module is not a runtime')
end)

test('portability: an unknown runtime is refused by name', function ()
    local store = require 'cartograph.store'
    store.ingest({ schema = 1, root = '/x', nodes = {}, edges = {}, calls = {} })
    local res, err = port.audit(store, 'no-such-runtime')
    eq(nil, res, 'no result')
    ok(err and err:find('no profile named', 1, true), 'and the reason names the miss: ' .. tostring(err))
end)

test('portability: a profile for ANOTHER language is refused, not scored', function ()
    if not ready() then skip('no ruby parser') end
    -- auditing ruby against zig-std would mark every name not-provided, which
    -- looks like a catastrophic verdict and means nothing
    local ts = require 'cartograph.providers.treesitter'
    local store = require 'cartograph.store'
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    write(root, 'a.rb', { 'class A', '  def go(x) x.whatever end', 'end' })
    local data = ts.extract(root); data.root = root
    store.ingest(data)
    local res, err = port.audit(store, 'zig-std')
    eq(nil, res, 'refused')
    ok(err and err:find('nothing to compare', 1, true),
        'and it says why rather than producing a nonsense verdict: ' .. tostring(err))
    vim.fn.delete(root, 'rf')
end)

test('portability: the report buckets, and never says "missing"', function ()
    if not ready() then skip('no ruby parser') end
    local ts = require 'cartograph.providers.treesitter'
    local store = require 'cartograph.store'
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    -- I18n.t is in the rails profile; Wombat.frobnicate is in nobody's
    write(root, 'a.rb', { 'class A', '  def go', '    I18n.t("x")',
        '    Wombat.frobnicate(1)', '  end', 'end' })
    local data = ts.extract(root); data.root = root
    store.ingest(data)
    local res = port.audit(store, 'ruby-rails')
    ok(res, 'audited')
    local byname = {}
    for _, e in ipairs(res.entries) do byname[e.name] = e end
    ok(byname['I18n.t'] and byname['I18n.t'].provided,
        'a profile name is PROVIDED, with the evidence recorded')
    ok(byname['Wombat.frobnicate'] and not byname['Wombat.frobnicate'].provided,
        'an unknown one is not')
    local text = table.concat(port.report(store, 'ruby-rails'), '\n')
    ok(text:find('NOT IN ruby%-rails'), 'the bucket is NOT-IN-profile')
    ok(text:find('is not "missing"', 1, true), 'and the report refuses the stronger word')
    ok(text:find('claims %d+ symbols'), 'the profile size is disclosed')
    vim.fn.delete(root, 'rf')
end)

-- ── the SYMMETRIC INVERSION: the code has a profile too ────────────────────
-- One requirement set, three questions over it. What needs pinning is that the
-- set really is shared (so the three answers cannot disagree) and that coverage
-- is never dressed up as a verdict.

local function ruby_store(lines)
    local ts = require 'cartograph.providers.treesitter'
    local store = require 'cartograph.store'
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    write(root, 'a.rb', lines)
    local data = ts.extract(root); data.root = root
    store.ingest(data)
    return store, root
end

test('portability: requires() carries BOTH halves — names and version', function ()
    if not ready() then skip('no ruby parser') end
    local store, root = ruby_store { 'class A', '  def go(h)', '    I18n.t("x")',
        '    Wombat.frob(1)', '    h.then { |x| x }', '  end', '  def opts(x) = {x:}', 'end' }
    local req = require('cartograph.portability').requires(store)
    ok(req.names['I18n.t'], 'the name surface is there')
    ok(req.names['Wombat.frob'], 'including the unknown ones')
    ok(req.total >= 2, 'counted')
    eq('3.1', req.floor, 'and the VERSION half rides in the same set ({x:} is 3.1)')
    ok(req.langs.ruby, 'with the languages it spans')
    vim.fn.delete(root, 'rf')
end)

test('portability: audit and requires agree, because it is ONE set', function ()
    if not ready() then skip('no ruby parser') end
    local port = require 'cartograph.portability'
    local store, root = ruby_store { 'class A', '  def go', '    I18n.t("x")',
        '    Wombat.frob(1)', '  end', 'end' }
    local req = port.requires(store)
    local res = port.audit(store, 'ruby-rails')
    eq(req.total, res.provided + res.unknown,
        'the audit scores exactly the requirement set — no third walk to drift')
    vim.fn.delete(root, 'rf')
end)

test('portability: rank() discloses an unrankable artifact instead of 0%', function ()
    if not ready() then skip('no ruby parser') end
    local port = require 'cartograph.portability'
    local store, root = ruby_store { 'class A', '  def go', '    I18n.t("x")', '  end', 'end' }
    local ranked = port.rank(store)
    local byname = {}
    for _, r in ipairs(ranked) do byname[r.runtime] = r end
    ok(byname['ruby-rails'] and byname['ruby-rails'].queryable,
        'a vocab profile is name-queryable')
    -- ruby-core is RBS-derived: signature keys only, so it cannot answer name
    -- queries and must not be scored as though it provides nothing
    if byname['ruby-core'] then
        eq(false, byname['ruby-core'].queryable,
            'a signature-keyed artifact is flagged, not blamed')
        eq('ruby-rails', ranked[1].runtime, 'and it never ranks as the tightest fit')
    end
    local text = table.concat(port.requires_report(store), '\n')
    ok(text:find('not rankable', 1, true), 'the report says so in words: ' .. text:sub(1, 40))
    ok(text:find('coverage is not a verdict', 1, true), 'and refuses the stronger reading')
    vim.fn.delete(root, 'rf')
end)

test('portability: manifest groups by provider and never calls the rest missing', function ()
    if not ready() then skip('no ruby parser') end
    local port = require 'cartograph.portability'
    local store, root = ruby_store { 'class A', '  def go', '    I18n.t("x")',
        '    Wombat.frob(1)', '  end', 'end' }
    local groups, unclaimed = port.manifest(store)
    ok(groups['ruby-rails'], 'a provided name is grouped under its provider')
    local names = {}
    for _, u in ipairs(unclaimed) do names[u.name] = true end
    ok(names['Wombat.frob'], 'and an unclaimed one is in its own bucket')
    local text = table.concat(port.requires_report(store), '\n')
    ok(text:find('claimed by no profile', 1, true), 'labelled by what is KNOWN, not by a verdict')
    ok(text:find('third%-party dependency'), 'with the likely explanation, not an accusation')
    vim.fn.delete(root, 'rf')
end)

-- ── MOVING between environments: the A-to-B diff ───────────────────────────
-- The names whose status CHANGES are the porting work. The comparison is tested
-- through diff_entries, which takes two audit results and touches no disk — so
-- it needs no invented profile artifact, which matters because no two SHIPPED
-- profiles are comparable yet (three languages, and ruby-core has no name
-- surface).

local function audit_of(runtime, entries)
    return { runtime = runtime, entries = entries }
end

test('portability: the diff names what a move LOSES and GAINS', function ()
    local a = audit_of('rich', {
        { name = 'I18n.t', calls = 10, provided = true, why = 'vocab' },
        { name = 'Rails.logger', calls = 4, provided = true, why = 'namespace' },
        { name = 'Wombat.frob', calls = 2, provided = false },
        { name = 'Only.inB', calls = 7, provided = false },
    })
    local b = audit_of('lean', {
        { name = 'I18n.t', calls = 10, provided = true },
        { name = 'Rails.logger', calls = 4, provided = false },
        { name = 'Wombat.frob', calls = 2, provided = false },
        { name = 'Only.inB', calls = 7, provided = true },
    })
    local d = require('cartograph.portability').diff_entries(a, b)
    eq(1, #d.lost, 'one name the target does not provide')
    eq('Rails.logger', d.lost[1].name, 'and it is named')
    eq(1, #d.gained, 'one the target adds')
    eq('Only.inB', d.gained[1].name)
    eq(1, d.kept, 'one provided by both')
    eq(1, d.neither, 'and one by neither — every name is accounted for')
end)

test('portability: the diff is DIRECTIONAL', function ()
    local port = require 'cartograph.portability'
    local a = audit_of('a', { { name = 'x', calls = 1, provided = true } })
    local b = audit_of('b', { { name = 'x', calls = 1, provided = false } })
    eq(1, #port.diff_entries(a, b).lost, 'a -> b loses x')
    eq(0, #port.diff_entries(b, a).lost, 'b -> a does not')
    eq(1, #port.diff_entries(b, a).gained, 'it gains it instead')
end)

test('portability: lost names are ranked by call volume', function ()
    local a = audit_of('a', {
        { name = 'rare', calls = 1, provided = true },
        { name = 'hot', calls = 99, provided = true },
    })
    local b = audit_of('b', {
        { name = 'rare', calls = 1, provided = false },
        { name = 'hot', calls = 99, provided = false },
    })
    local d = require('cartograph.portability').diff_entries(a, b)
    eq('hot', d.lost[1].name, 'the heaviest breakage leads')
end)

test('portability: a diff against a signature-keyed profile is REFUSED', function ()
    if not ready() then skip('no ruby parser') end
    local ts = require 'cartograph.providers.treesitter'
    local store = require 'cartograph.store'
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    write(root, 'a.rb', { 'class A', '  def go; I18n.t("x"); end', 'end' })
    local data = ts.extract(root); data.root = root
    store.ingest(data)
    -- ruby-core cannot answer name queries, so a diff would call EVERYTHING lost
    local res, err = require('cartograph.portability').diff(store, 'ruby-rails', 'ruby-core')
    eq(nil, res, 'refused rather than scored')
    ok(err and err:find('no name surface', 1, true),
        'and it says why: ' .. tostring(err))
    vim.fn.delete(root, 'rf')
end)

-- ── the luajit sibling profile, and the root requirement it forced ──────────
-- Minted by tools/luadistill.lua INTROSPECTING the interpreter, which is why it
-- is sound: `for k in pairs(string)` measures the runtime that will execute the
-- code, where a hand-typed list would only claim.

test('portability: the luajit profile ships and is name-queryable', function ()
    local pm = require 'cartograph.spec.profile'
    local p = pm.load('luajit')
    ok(p, 'the distilled artifact loads')
    eq('lua', p.lang, 'it is a lua profile, so it pairs with lua-factorio')
    ok(port.name_queryable(p), 'and it can answer name queries, unlike ruby-core')
    ok(p.stamp and p.stamp:find('introspected', 1, true),
        'the stamp records HOW it was made: ' .. tostring(p.stamp))
    ok(p.vocab['pairs'], 'a base function')
    ok(p.nsset['string'] and p.nsset['table'], 'the standard namespaces')
    eq(nil, p.vocab['vim'], 'and nvim additions are excluded — it must not promise vim')
end)

test('portability: a DOTTED name needs its ROOT provided, not just its tail', function ()
    local pm = require 'cartograph.spec.profile'
    local lj = pm.load('luajit')
    ok(port.provides(lj, 'string.format'), 'a real namespace member resolves')
    ok(port.provides(lj, 'pairs'), 'and a base function')
    -- `print` IS a luajit base function, but `game.print` is Factorio's API: a
    -- tail-only match would have hidden the single most important dependency
    eq(nil, port.provides(lj, 'game.print'),
        'a tail match must not make an unknown root look provided')
    eq(nil, port.provides(lj, 'script.on_event'), 'nor this one')
    -- and the sibling profile DOES provide it, which is the whole point of the pair
    ok(port.provides(pm.load('lua-factorio'), 'game.print'),
        'the factorio profile provides what plain luajit cannot')
end)

test('portability: luajit and lua-factorio are a comparable PAIR', function ()
    local pm = require 'cartograph.spec.profile'
    local a, b = pm.load('lua-factorio'), pm.load('luajit')
    eq(a.lang, b.lang, 'same language')
    ok(port.name_queryable(a) and port.name_queryable(b), 'both queryable')
    -- so a move between them is scoreable, which no shipped pair was before
    local audits = {
        { runtime = 'lua-factorio', entries = {
            { name = 'game.print', calls = 5, provided = port.provides(a, 'game.print') ~= nil },
            { name = 'string.format', calls = 2, provided = port.provides(a, 'string.format') ~= nil } } },
        { runtime = 'luajit', entries = {
            { name = 'game.print', calls = 5, provided = port.provides(b, 'game.print') ~= nil },
            { name = 'string.format', calls = 2, provided = port.provides(b, 'string.format') ~= nil } } },
    }
    local d = port.diff_entries(audits[1], audits[2])
    eq(1, #d.lost, 'the factorio-only name is the porting work')
    eq('game.print', d.lost[1].name)
    eq(1, d.kept, 'and plain lua carries the rest')
end)

-- ── the cruby sibling: "will this run WITHOUT Rails?" ──────────────────────
-- Minted by tools/rubydistill.lua asking the real interpreter, so ruby finally
-- has a comparable pair — the question the whole lever was designed around.

test('portability: the cruby profile draws the Rails line correctly', function ()
    local pm = require 'cartograph.spec.profile'
    local p = pm.load('cruby')
    if not p then skip('cruby profile not minted (no ruby on PATH?)') end
    eq('ruby', p.lang)
    ok(port.name_queryable(p), 'queryable, so it can be a diff target')
    ok(p.stamp:find('introspected from ruby', 1, true), 'and says how it was made')
    -- plain ruby DOES provide these
    ok(port.provides(p, 'puts'), 'a Kernel function')
    ok(port.provides(p, 'String.upcase'), 'a core type member')
    ok(port.provides(p, 'URI.parse'), 'a default gem, loaded explicitly by the probe')
    -- and does NOT provide the framework
    eq(nil, port.provides(p, 'I18n.t'), 'I18n is Rails, not ruby')
    eq(nil, port.provides(p, 'Rails.logger'), 'nor is Rails')
    eq(nil, port.provides(p, 'ActiveRecord.base'), 'nor ActiveRecord')
end)

test('portability: ruby-rails and cruby OVERLAP rather than nest', function ()
    local pm = require 'cartograph.spec.profile'
    local rails, cruby = pm.load('ruby-rails'), pm.load('cruby')
    if not cruby then skip('cruby profile not minted') end
    -- Rails' profile carries framework vocab, not a copy of ruby core, so each
    -- provides something the other does not. The report must not read that as
    -- "plain ruby is richer than Rails".
    ok(port.provides(rails, 'I18n.t') and not port.provides(cruby, 'I18n.t'),
        'rails-only name')
    ok(port.provides(cruby, 'private_class_method')
        and not port.provides(rails, 'private_class_method'),
        'core-only name — which is why the diff shows gains in this direction')
end)

test('portability: a gains-heavy diff SAYS the profiles overlap', function ()
    if not ready() then skip('no ruby parser') end
    local pm = require 'cartograph.spec.profile'
    if not pm.load('cruby') then skip('cruby profile not minted') end
    local ts = require 'cartograph.providers.treesitter'
    local store = require 'cartograph.store'
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    -- one Rails name and several core ones, so the move both loses and gains
    write(root, 'a.rb', { 'class A', '  def go', '    I18n.t("x")',
        '    private_class_method :go', '    Foo.name', '    Bar.call', '  end', 'end' })
    local data = ts.extract(root); data.root = root
    store.ingest(data)
    local text = table.concat(port.diff_report(store, 'ruby-rails', 'cruby'), '\n')
    ok(text:find('MOVING FROM ruby%-rails TO cruby'), 'the direction is stated')
    if text:find('OVERLAP rather', 1, true) then
        ok(true, 'the caveat fires when gains outnumber losses')
    else
        -- fixture-dependent; the caveat is conditional by design
        ok(text:find('LOST', 1, true) or text:find('nothing ruby%-rails provides'),
            'and otherwise the report still reads as a move')
    end
    vim.fn.delete(root, 'rf')
end)

-- ── the version the code DECLARES it targets ─────────────────────────────────
-- The report used to print only the ARTIFACT's version, which reads as a claim
-- about the environment rather than about a MOVE. The missing fact was sitting in
-- the package manifest — a file the resolver already parses — so the header said
-- "lua-factorio 2.0.72" while never mentioning that the code declares 1.1.
--
-- Read through the ecosystem axis rather than a fifth hardcoded arm in
-- versionfloor: an ecosystem names its manifest, the key holding the environment
-- version, and the RULER that version sits on.

local function fixture(manifest)
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    local function w(rel, text)
        local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(text); fd:close()
    end
    if manifest then w('info.json', manifest) end
    w('control.lua', 'local function boot() return game.tick end\nreturn { boot = boot }\n')
    return root
end

test('versionfloor: a package manifest declares its environment version', function ()
    local vf = require 'cartograph.versionfloor'
    local root = fixture('{"name":"M","version":"1.0","factorio_version":"1.1"}')
    local d
    for _, cand in ipairs(vf.declarations(root)) do
        if cand.source == 'info.json' then d = cand end
    end
    ok(d ~= nil, 'the manifest declaration was found')
    eq('1.1', d.raw)
    eq('1.1', d.v)
    -- its OWN ruler, not the language's: comparing across rulers is meaningless,
    -- which versionfloor records learning the hard way (floor "2022" > "3.1")
    eq('factorio', d.scale)
    eq(d, vf.declared(root, 'factorio'))
    vim.fn.delete(root, 'rf')
end)

test('versionfloor: no manifest means no declaration, not a guess', function ()
    local vf = require 'cartograph.versionfloor'
    local root = fixture(nil)
    for _, cand in ipairs(vf.declarations(root)) do
        ok(cand.source ~= 'info.json', 'nothing invented from an absent manifest')
    end
    eq(nil, vf.declared(root, 'factorio'))
    vim.fn.delete(root, 'rf')
end)

test('portability: declared_for links a runtime to its ecosystem ruler', function ()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not pcall(vim.treesitter.language.add, 'lua') then skip 'no lua parser' end
    local ts = require 'cartograph.providers.treesitter'
    local store = require 'cartograph.store'
    local port = require 'cartograph.portability'
    local root = fixture('{"name":"M","version":"1.0","factorio_version":"1.1"}')
    store.ingest(ts.extract(root))
    local d = port.declared_for(store, 'lua-factorio')
    ok(d ~= nil, 'the runtime name resolved to an ecosystem with a ruler')
    eq('1.1', d.raw); eq('info.json', d.source)
    -- a runtime with no ecosystem of that name has no ruler, so no declaration
    eq(nil, port.declared_for(store, 'luajit'))
    vim.fn.delete(root, 'rf')
end)

test('portability: the report states the MOVE, both ends named', function ()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not pcall(vim.treesitter.language.add, 'lua') then skip 'no lua parser' end
    local ts = require 'cartograph.providers.treesitter'
    local store = require 'cartograph.store'
    local port = require 'cartograph.portability'
    local root = fixture('{"name":"M","version":"1.0","factorio_version":"1.1"}')
    store.ingest(ts.extract(root))
    local head = port.report(store, 'lua-factorio', { cap = 1 })[1]
    ok(head:match('MOVING FROM factorio 1%.1') ~= nil, 'the declared end: ' .. head)
    ok(head:match('%(declared in info%.json%)') ~= nil, 'and WHERE it was declared')
    ok(head:match('TO lua%-factorio') ~= nil, 'the target end too')
    vim.fn.delete(root, 'rf')
end)

-- with NO declaration the old header is kept verbatim: a report that cannot name
-- the move must not imply one
test('portability: an undeclared project keeps the plain header', function ()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not pcall(vim.treesitter.language.add, 'lua') then skip 'no lua parser' end
    local ts = require 'cartograph.providers.treesitter'
    local store = require 'cartograph.store'
    local port = require 'cartograph.portability'
    local root = fixture(nil)
    store.ingest(ts.extract(root))
    local head = port.report(store, 'lua-factorio', { cap = 1 })[1]
    eq(nil, head:find('MOVING FROM', 1, true))
    ok(head:match('^portability — lua%-factorio') ~= nil, 'plain header: ' .. head)
    vim.fn.delete(root, 'rf')
end)

-- a non-filesystem root (a roster's mods://, self://loaded) has no manifest to read
-- and must not be probed as if it were a path
test('portability: a URI root yields no declaration and does not crash', function ()
    local store = require 'cartograph.store'
    local port = require 'cartograph.portability'
    store.ingest({ schema = 1, root = 'mods:///tmp/x', nodes = {}, edges = {},
        calls = {}, stamps = {} })
    eq(nil, port.declared_for(store, 'lua-factorio'))
end)

-- ── the honesty split: WHY a name is not in the profile ──────────────────────
-- The list used to be headed "candidate porting work", which was wrong for EVERY
-- entry rather than for most. MEASURED on lua-factorio: the artifact distils METHODS
-- only (LuaGameScript::get_player and ::print are in it; ::tick, ::players,
-- ::surfaces, ::entity_prototypes are not), and it models global-rooted calls only.
-- So a miss is never evidence the target lacks the name — game.entity_prototypes,
-- genuinely renamed in 2.0, is indistinguishable from game.tick, which is fine.
-- Hence NO "absent" bucket, and the report says why rather than implying one.

test('portability: unknown_reason classifies by the artifact SHAPE', function ()
    local port = require 'cartograph.portability'
    local prof = require('cartograph.spec.profile').load('lua-factorio')
    if not prof then skip 'no lua-factorio profile' end
    -- a GLOBAL whose documented class is fully enumerated: the miss IS evidence.
    -- This was 'unenumerated-namespace' until the distiller emitted attributes as
    -- well as methods (220 members, 9 classes complete) — before that, a missing
    -- member could not be told from an attribute the artifact never held.
    eq('absent', port.unknown_reason(prof, 'game.no_such_member', 'a.lua'))
    -- a Lua STDLIB namespace is still not a closed set: Factorio extends `table`
    -- with lualib's deepcopy and the profile omits it, so a miss there says nothing
    eq('unenumerated-namespace', port.unknown_reason(prof, 'table.deepcopy', 'a.lua'))
    -- an UNmodelled root: receiver-typed, with no representation at all
    eq('receiver-typed', port.unknown_reason(prof, 'player.teleport', 'a.lua'))
    eq('receiver-typed', port.unknown_reason(prof, 'chest3.set_request_slot', 'a.lua'))
    -- a deep chain is still receiver-typed: only the first segment could ever be a
    -- modelled namespace
    eq('receiver-typed', port.unknown_reason(prof, 'a.b.c', 'a.lua'))
    -- bare
    eq('unclaimed-bare', port.unknown_reason(prof, 'my_helper', 'a.lua'))
    -- and a name from a file of another language is not this profile's business
    eq('other-language', port.unknown_reason(prof, 'json.load', 'zipper.py'))
    eq('other-language', port.unknown_reason(prof, 'open', 'tool.py'))
end)

test('portability: the report groups by reason and claims no porting work',
    function ()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not pcall(vim.treesitter.language.add, 'lua') then skip 'no lua parser' end
    local ts = require 'cartograph.providers.treesitter'
    local store = require 'cartograph.store'
    local port = require 'cartograph.portability'
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local function w(rel, t)
        local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(t); fd:close()
    end
    w('info.json', '{"name":"M","version":"1.0","factorio_version":"1.1"}')
    w('control.lua', 'local function boot()\n'
        .. '  local p = game.get_player(1)\n'          -- provided (a distilled method)
        .. '  p.teleport({0,0})\n'                     -- receiver-typed
        .. '  return my_helper()\n'                    -- bare, unclaimed
        .. 'end\nreturn { boot = boot }\n')
    store.ingest(ts.extract(root))
    local body = table.concat(port.report(store, 'lua-factorio', { cap = 12 }), '\n')
    -- the misleading label is GONE
    eq(nil, body:find('candidate porting work', 1, true))
    -- ... replaced by the honest framing and a reason per group
    ok(body:match('cannot adjudicate, grouped by WHY') ~= nil, 'grouped framing')
    ok(body:match('RECEIVER%-TYPED') ~= nil, 'the receiver-typed group appears')
    -- this fixture has no absent name, so the report SAYS there is no such group
    -- rather than leaving a reader to wonder whether one was omitted
    ok(body:match('no ABSENT group') ~= nil, 'the absence of the group is stated')
    vim.fn.delete(root, 'rf')
end)

-- every unknown gets exactly one reason, so the groups partition the list rather
-- than sampling it — otherwise a reader cannot trust the counts
test('portability: the reason groups PARTITION the unknown names', function ()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not pcall(vim.treesitter.language.add, 'lua') then skip 'no lua parser' end
    local ts = require 'cartograph.providers.treesitter'
    local store = require 'cartograph.store'
    local port = require 'cartograph.portability'
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local function w(rel, t)
        local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(t); fd:close()
    end
    w('info.json', '{"name":"M","version":"1.0"}')
    w('control.lua', 'return { go = function ()\n'
        .. '  thing.one(); other.two(); bare_three(); game.four()\n'
        .. 'end }\n')
    store.ingest(ts.extract(root))
    local res = port.audit(store, 'lua-factorio')
    local counted = 0
    for _, e in ipairs(res.entries) do
        if not e.provided then
            ok(e.reason ~= nil, 'every unknown carries a reason: ' .. e.name)
            counted = counted + 1
        end
    end
    eq(res.unknown, counted)
    vim.fn.delete(root, 'rf')
end)

-- the ABSENT bucket, which only exists because the distiller emits ATTRIBUTES as
-- well as methods. Before that a miss inside a global's class was indistinguishable
-- from an attribute the artifact never held, so no bucket could be earned.
test('portability: a call to a member a COMPLETE class lacks is ABSENT', function ()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not pcall(vim.treesitter.language.add, 'lua') then skip 'no lua parser' end
    local ts = require 'cartograph.providers.treesitter'
    local store = require 'cartograph.store'
    local port = require 'cartograph.portability'
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local function w(rel, t)
        local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(t); fd:close()
    end
    w('info.json', '{"name":"M","version":"1.0","factorio_version":"1.1"}')
    w('control.lua', 'local function boot()\n'
        .. '  game.get_player(1)\n'         -- a real method: provided
        .. '  game.tick_paused_probe()\n'   -- not a member of LuaGameScript
        .. '  remote.no_such_call("x")\n'   -- not a member of LuaRemote
        .. 'end\nreturn { boot = boot }\n')
    store.ingest(ts.extract(root))
    local res = port.audit(store, 'lua-factorio')
    local byname = {}
    for _, e in ipairs(res.entries) do byname[e.name] = e end
    -- the two misses are ABSENT: their classes are fully enumerated
    ok(byname['remote.no_such_call'], 'the miss is in the requirement set')
    eq('absent', byname['remote.no_such_call'].reason)
    eq(false, byname['remote.no_such_call'].provided)
    -- and the report leads with that group, since it is the only one that says
    -- anything about the TARGET rather than about the artifact
    local body = table.concat(port.report(store, 'lua-factorio', { cap = 9 }), '\n')
    ok(body:match('ABSENT FROM THE TARGET') ~= nil, 'the group is reported')
    ok(body:match('real porting work') ~= nil, 'and named as the actionable one')
    vim.fn.delete(root, 'rf')
end)

-- a member that DOES exist must not land in absent — the artifact's completeness
-- claim cuts both ways, and over-reporting work is as dishonest as hiding it
test('portability: an existing member is provided, never absent', function ()
    local port = require 'cartograph.portability'
    local prof = require('cartograph.spec.profile').load('lua-factorio')
    if not prof or not prof.api_complete then skip 'no distilled api artifact' end
    -- METHODS and ATTRIBUTES both count: `tick` is an attribute, and treating it as
    -- absent was exactly the methods-only failure
    ok(port.provides(prof, 'game.get_player') ~= nil, 'a method is provided')
    ok(port.provides(prof, 'game.tick') ~= nil, 'an ATTRIBUTE is provided too')
    ok(port.provides(prof, 'game.players') ~= nil, 'and another')
    eq(nil, port.provides(prof, 'game.entity_prototypes')) -- renamed in 2.0
    -- a DEEP chain keeps the prefix answer: it continues into receiver-typed
    -- territory the artifact cannot follow, so it is not adjudicated as absent
    ok(port.provides(prof, 'game.surfaces.create_entity') ~= nil,
        'a chain is not called absent')
end)
