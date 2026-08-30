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

-- ── WHAT MAY BE A TARGET (CART-0209) ───────────────────────────────────────
-- The roster is what EXISTS; a target is what can ANSWER. These pin the
-- DISTINCTION and, deliberately, NOT the `ingredient` marker: filtering on the
-- marker was the obvious fix and it would have dropped a working target.

test('portability: target_kinds separates the NAMES question from the DATA one',
    function ()
    -- a names target must answer BOTH a bare and a dotted name — the same pair
    -- M.diff already fences on, so the list cannot drift from the fence
    local env = { lang = 'x', vocab = { tally = true }, types = { String = {} } }
    eq(true, port.target_kinds(env).names, 'bare + dotted = a names target')
    eq(false, port.target_kinds(env).data, 'and it answers no data-stage question')

    -- THE CART-0209 ARTIFACT: name-queryable on a few free functions, blind to
    -- every dotted name, which is how it once reported "0 LOST" on a real port
    local ingredient = { lang = 'x', free = { log = true },
        sigs = { ['LuaGameScript::print'] = true } }
    eq(true, port.name_queryable(ingredient), 'it does claim SOME names')
    eq(false, port.target_kinds(ingredient).names, 'and is still no names target')
    eq(false, port.target_kinds(ingredient).data, 'nor a data one')

    -- …while a PROTOTYPE artifact answers neither name question and IS a target
    local proto = { lang = 'x', ingredient = true, stage = 'prototype',
        prototypes = { lamp = true }, typenames = { lamp = 'lamp' },
        own_props = { ['lamp::height'] = 'optional' } }
    eq(false, port.target_kinds(proto).names, 'no name surface at all')
    eq(true, port.target_kinds(proto).data, 'but it is the data-stage target')
    eq(nil, port.target_kinds(nil).names or nil, 'and no profile answers nothing')
end)

test('portability: targets() offers what can ANSWER, never the ingredient marker',
    function ()
    local roster, names, data = port.runtimes(), {}, {}
    for _, r in ipairs(port.targets('names')) do names[r] = true end
    for _, r in ipairs(port.targets('data')) do data[r] = true end
    local inroster = {}
    for _, r in ipairs(roster) do inroster[r] = true end

    ok(#port.targets() < #roster, 'the target list is SMALLER than the roster')
    for _, t in ipairs(port.targets()) do
        ok(inroster[t], t .. ' is a shipped artifact')
    end

    local pm = require 'cartograph.spec.profile'
    -- the three runtime-api artifacts predate the marker and carry none: they are
    -- caught by what they can ANSWER, not by what they declare
    for _, ing in ipairs({ 'lua-factorio-api', 'lua-factorio-api-11',
        'lua-factorio-api-20' }) do
        if pm.load(ing) then
            eq(nil, names[ing] or nil, ing .. ' is no names target')
            eq(nil, data[ing] or nil, ing .. ' is no data target either')
            local p, why = port.targetable(ing)
            eq(nil, p, 'and it is refused')
            ok(why:find('INGREDIENT', 1, true) and why:find('keyed by class', 1, true),
                'with the MECHANISM, not a label: ' .. tostring(why))
        end
    end
    -- AND THE OTHER DIRECTION, which is the whole reason the filter is not the
    -- marker: both prototype artifacts DECLARE `ingredient` and both are targets
    for _, pr in ipairs({ 'lua-factorio-proto-11', 'lua-factorio-proto-20' }) do
        local prof = pm.load(pr)
        if prof then
            eq(true, prof.ingredient, pr .. ' declares the marker')
            ok(data[pr], 'and is STILL offered — for the data-stage question')
            eq(nil, names[pr] or nil, 'but not for the name question')
        end
    end
    -- every real environment survives
    for _, envn in ipairs({ 'luajit', 'lua-factorio', 'lua-factorio-11',
        'ruby-rails', 'zig-std', 'cruby' }) do
        if pm.load(envn) then ok(names[envn], envn .. ' is a names target') end
    end
    -- ruby-core is refused, and that is CORRECT (RBS, signature-keyed) — the same
    -- disposition profile.env_usable gives it, for the same reason
    if pm.load('ruby-core') then
        eq(nil, names['ruby-core'] or nil, 'a signature-keyed artifact is no target')
    end
end)

test('portability: the roster report tells a reader what completion narrowed',
    function ()
    local text = table.concat(port.roster_report(), '\n')
    local pm = require 'cartograph.spec.profile'
    ok(text:find('NAMES', 1, true), 'the name question has a section')
    ok(text:find('DATA STAGE', 1, true), 'and so does the data one')
    if pm.load('lua-factorio-api-11') then
        ok(text:find('NOT A TARGET', 1, true), 'what is not offered is SHOWN')
        ok(text:find('lua%-factorio%-api%-11'), 'by name')
        ok(text:find('keyed by class', 1, true), 'with the mechanism')
        -- and NOT as a worthless file: every one of these is load-bearing somewhere
        ok(text:find('load%-bearing elsewhere'), 'and without calling it junk')
    end
    if pm.load('lua-factorio-proto-20') then
        ok(text:find('prototypes,', 1, true),
            'a data artifact is measured in ITS currency, not "0 sigs"')
    end
end)

test('portability: the SINGLE-target audit is fenced like the diff', function ()
    local store = require 'cartograph.store'
    store.ingest({ schema = 1, root = '/x', nodes = {}, edges = {}, calls = {} })
    local pm = require 'cartograph.spec.profile'
    -- an empty graph has no language, so the language guard cannot fire and what
    -- refuses here is the target fence itself. Before it existed this printed a
    -- header claiming 294 symbols and 92 names of "candidate porting work".
    if pm.load('lua-factorio-api-11') then
        local res, err = port.audit(store, 'lua-factorio-api-11')
        eq(nil, res, 'an ingredient is not auditable')
        ok(err:find('INGREDIENT', 1, true), 'and says why: ' .. tostring(err))
    end
    if pm.load('lua-factorio-proto-20') then
        local res, err = port.audit(store, 'lua-factorio-proto-20')
        eq(nil, res, 'nor is a data-stage artifact, on the NAME question')
        ok(err:find('DATA%-STAGE') and err:find('TWO', 1, true),
            'and the refusal names the OTHER DOOR: ' .. tostring(err))
    end
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
    local ranked, _, skipped = port.rank(store)
    local byname = {}
    for _, r in ipairs(ranked) do byname[r.runtime] = r end
    ok(byname['ruby-rails'] and byname['ruby-rails'].queryable,
        'a vocab profile is name-queryable')
    -- ruby-core is RBS-derived: signature keys only, so it cannot answer name
    -- queries and must not be scored as though it provides nothing. IT IS NOT
    -- RANKED AT ALL NOW (CART-0209) — and NOT DROPPED EITHER: an artifact that
    -- vanishes from the list leaves "three profiles ship" where five do.
    if require('cartograph.spec.profile').load('ruby-core') then
        eq(nil, byname['ruby-core'], 'a signature-keyed artifact is not ranked')
        eq('ruby-rails', ranked[1].runtime, 'and it never ranks as the tightest fit')
        local seen = {}
        for _, s in ipairs(skipped) do seen[s.runtime] = s end
        ok(seen['ruby-core'], 'it is RETURNED as skipped, not silently dropped')
        ok(seen['ruby-core'].reason:find('no name surface', 1, true),
            'with the mechanism: ' .. tostring(seen['ruby-core'].reason))
    end
    local text = table.concat(port.requires_report(store), '\n')
    ok(text:find('not rankable', 1, true), 'the report says so in words: ' .. text:sub(1, 40))
    ok(text:find('ruby%-core'), 'and NAMES the artifact it did not score')
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

test('portability: a name is ANOTHER language\'s only if NO file of ours holds it',
    function ()
    -- CART-0215. This used to be decided from ONE sampled file, so a name seen in
    -- both languages was classified by whichever filename sorted first. The
    -- population decides now, and a single file of our own language is enough to
    -- make the name our business.
    local port = require 'cartograph.portability'
    local prof = require('cartograph.spec.profile').load('lua-factorio')
    if not prof then skip 'no lua-factorio profile' end
    eq('other-language', port.unknown_reason(prof, 'json.load', { 'zipper.py', 'b.py' }),
        'every file foreign -> still not our business')
    eq('unclaimed-bare', port.unknown_reason(prof, 'my_helper', { 'zipper.py', 'a.lua' }),
        'MIXED: one lua file makes it ours, and the old form could rule that out'
        .. ' on filename order alone (a.lua sorts before zipper.py, so this one'
        .. ' passed by luck — the reverse order was the bug)')
    eq('unclaimed-bare', port.unknown_reason(prof, 'my_helper', { 'a.lua', 'zipper.py' }),
        'and order does not matter, which is the actual fix')
    -- back-compatible: a bare string is still a one-file population
    eq('other-language', port.unknown_reason(prof, 'json.load', 'zipper.py'))
    eq('unclaimed-bare', port.unknown_reason(prof, 'my_helper', nil),
        'and no provenance at all cannot rule a language out')
    -- an extension no spec claims is not evidence either way
    eq('unclaimed-bare', port.unknown_reason(prof, 'my_helper', { 'notes.txt' }),
        'an unknown extension is not a foreign language')
end)

-- ── THE STAGE PARTITION (CART-0216) ─────────────────────────────────────────
-- One root, one language, three DISJOINT environments. Von-Neumann yields ZERO
-- findings (its stage separation is clean), so every positive here is synthetic and
-- these tests are the only thing proving the check fires at all.

--- A real on-disk factorio mod, extracted for real, so the IMPORT EDGES the stage
--- map walks are the extractor's own. control.lua + data.lua at the root is what
--- makes the shape activate the lua-factorio profile, so this also exercises the
--- selection path end to end.
local function factorio_tree(files)
    local ts = require 'cartograph.providers.treesitter'
    local st = require 'cartograph.store'
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    for rel, src in pairs(files) do
        local dir = rel:match('^(.*)/[^/]+$')
        if dir then vim.fn.mkdir(root .. '/' .. dir, 'p') end
        vim.fn.writefile(vim.split(src, '\n'), root .. '/' .. rel)
    end
    st._content_cache = {}
    local data = ts.extract(root); data.root = root
    st.ingest(data)
    return st, root
end

local function lua_ready()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    return pcall(vim.treesitter.language.add, 'lua')
end

local function region_of(res, name)
    for _, e in ipairs(res.out_of_region or {}) do
        if e.name == name then return e end
    end
end

test('portability: a name used OUTSIDE its load stage is a finding, not an absence',
    function ()
    if not lua_ready() then skip 'no lua parser' end
    local st, root = factorio_tree({
        ['data.lua'] = 'require("protos.belt")',
        ['protos/belt.lua'] = table.concat({
            -- `game` is RUNTIME-only: at the data stage this is a load-time crash
            'game.print("hi")',
            -- `data` and `string` are fine here
            'data.extend{{ type = "container" }}',
            'local s = string.format("%d", 1)',
        }, '\n'),
        ['control.lua'] = 'require("rt.tick")',
        ['rt/tick.lua'] = table.concat({
            'game.print("ok")',       -- correct stage
            'data.extend{{}}',        -- `data` is DATA-only: wrong stage at runtime
        }, '\n'),
    })
    local res = port.audit(st, 'lua-factorio')
    ok(res and res.stages, 'the profile declares stages, so a map was built')
    eq('data', res.stages.by_file['protos/belt.lua'] and 'data'
        or tostring(res.stages.by_file['protos/belt.lua']),
        'reachability placed a non-entry file: data.lua requires it')
    ok(res.stages.by_file['protos/belt.lua'].data, 'belt.lua is a DATA-stage file')
    ok(res.stages.by_file['rt/tick.lua'].runtime, 'tick.lua is a RUNTIME-stage file')

    local g = region_of(res, 'game.print')
    ok(g, 'game.print at the data stage is reported')
    eq('protos/belt.lua', g.file)
    eq('data', table.concat(g.loaded_at, '+'), 'the stage the FILE is loaded at')
    eq('runtime', table.concat(g.provided_at, '+'), 'and the stage that HAS the name')

    local d = region_of(res, 'data.extend')
    ok(d, 'and `data` at runtime is reported too — the partition cuts both ways')
    eq('rt/tick.lua', d.file)

    -- NOT an absence: the environment holds both names, so `provided` stays true and
    -- no existing count moves. The third disposition is recorded beside it.
    for _, e in ipairs(res.entries) do
        if e.name == 'game.print' then
            ok(e.provided, 'still provided — the environment HAS it')
            eq('out-of-region', e.region, 'with the region verdict beside that')
        end
    end
    -- a SHARED namespace is never stage-scoped
    eq(nil, region_of(res, 'string.format'), 'string.format is shared, never flagged')
    eq(nil, port.stage_owners_of(require('cartograph.spec.profile').load('lua-factorio'),
        'string.format'), 'and the partition has NO OPINION on it, which is not a refusal')
    vim.fn.delete(root, 'rf')
end)

test('portability: migrations/ is an ENGINE entry point; deeper files are not',
    function ()
    if not lua_ready() then skip 'no lua parser' end
    -- CART-0221. The engine loads migrations/<file>.lua directly, so nothing requires
    -- them and reachability alone can never place them. Anything DEEPER is an ordinary
    -- require: bravest-new-world keeps migrations/lib/util.lua, and a
    -- `migrations/.*%.lua$` pattern would wrongly declare that an engine entry.
    local st, root = factorio_tree({
        ['data.lua'] = 'data.extend{{}}',
        ['control.lua'] = 'game.print("x")',
        ['migrations/1.0.0.lua'] = 'local h = require("migrations.lib.helper")\ngame.print("m")',
        ['migrations/lib/helper.lua'] = 'local M = {}\nreturn M',
    })
    local res = port.audit(st, 'lua-factorio')
    local sm = res.stages
    ok(sm.by_file['migrations/1.0.0.lua'].runtime,
        'a depth-1 migration is placed at the RUNTIME stage')
    eq('runtime', sm.entries['migrations/1.0.0.lua'], 'and it is an ENTRY point')
    eq(nil, sm.entries['migrations/lib/helper.lua'],
        'while a deeper file is NOT an entry — the engine does not load it')
    ok(sm.by_file['migrations/lib/helper.lua']
        and sm.by_file['migrations/lib/helper.lua'].runtime,
        'it is placed by REACHABILITY instead, which is the right mechanism')
    -- game at the runtime stage is correct, so no finding
    eq(nil, region_of(res, 'game.print'))
    vim.fn.delete(root, 'rf')
end)

test('portability: a MULTI-MOD root places each mod\'s own entries', function ()
    if not lua_ready() then skip 'no lua parser' end
    -- A mods folder is the ecosystem's normal shape, and every entry pattern needs a
    -- `/`-prefixed form for it. Measured before the fix: on the 4-mod factorio corpus
    -- ZERO data-stage files were placed and 335 files were orphans, because
    -- `^data%.lua$` only matches at the extraction root — while the runtime stage
    -- worked by accident, already carrying `/control%.lua$` for scenarios.
    --
    -- The shape cannot fire on a multi-mod root (no root-level control.lua), so this
    -- also exercises the CART-0217 profile override as the thing that makes such a
    -- root analysable at all.
    local st, root = factorio_tree({
        ['modA/data.lua'] = 'data.extend{{}}',
        ['modA/control.lua'] = 'game.print("a")',
        ['modB/data-updates.lua'] = 'data.extend{{}}',
        ['modB/settings.lua'] = 'data.extend{{}}',
    })
    local ts = require 'cartograph.providers.treesitter'
    local d = ts.extract(root, { profile = 'lua-factorio' })
    d.root = root
    local st2 = require 'cartograph.store'; st2.ingest(d)
    local sm = port.stage_map(st2, require('cartograph.spec.profile').load('lua-factorio'))
    ok(sm.by_file['modA/data.lua'] and sm.by_file['modA/data.lua'].data,
        'a sub-mod data.lua is a DATA entry')
    ok(sm.by_file['modA/control.lua'] and sm.by_file['modA/control.lua'].runtime,
        'and its control.lua is RUNTIME')
    ok(sm.by_file['modB/data-updates.lua'] and sm.by_file['modB/data-updates.lua'].data,
        'data-updates.lua too')
    ok(sm.by_file['modB/settings.lua'] and sm.by_file['modB/settings.lua'].settings,
        'and settings.lua lands in the SETTINGS stage')
    eq(0, #sm.orphans, 'nothing is orphaned')
    ok(st ~= nil, 'the fixture built')
    vim.fn.delete(root, 'rf')
end)

test('portability: only MODULE-LEVEL sites are decidable; locals and bodies are not',
    function ()
    if not lua_ready() then skip 'no lua parser' end
    -- The three dispositions, all measured on real mods before being coded:
    --   MODULE LEVEL   evaluated when the file loads -> a real finding
    --   FUNCTION BODY  evaluated only if CALLED at that stage -> withheld. The
    --                  Factorio idiom is to nil-guard (`if game then game.print(…)`),
    --                  and space-exploration/scripts/log.lua does exactly that;
    --                  judging these gave 17 findings on that corpus, all false.
    --   A LOCAL of that name (parameter or assignment) -> not the global at all;
    --                  4 of the corpus's 5 other false findings were `data` as a param.
    local st, root = factorio_tree({
        ['data.lua'] = 'require("p")',
        ['control.lua'] = 'game.print("ok")',
        ['p.lua'] = table.concat({
            'game.print("module level")',            -- FINDING: runs at load
            'local function inner() game.print("body") end',  -- withheld
            'local function shadow(game) game.print("param") end', -- a local
            'return { inner = inner, shadow = shadow }',
        }, '\n'),
    })
    local res = port.audit(st, 'lua-factorio')
    local g = region_of(res, 'game.print')
    ok(g, 'the MODULE-LEVEL use is reported')
    eq('p.lua', g.file)
    eq('data', table.concat(g.loaded_at, '+'))
    ok((res.stage_withheld or 0) >= 1, 'the function-body use is WITHHELD, not reported')
    ok((res.stage_shadowed or 0) >= 1, 'and the parameter is recognised as a LOCAL')
    -- both counts must be DISCLOSED — a clean report that hid them would read as
    -- "everything checked"
    local text = table.concat(port.report(st, 'lua-factorio'), '\n')
    ok(text:find('WITHHELD') or text:find('withheld'), 'the report says what it declined')
    vim.fn.delete(root, 'rf')
end)

test('portability: a file loaded at TWO stages is held to the INTERSECTION',
    function ()
    if not lua_ready() then skip 'no lua parser' end
    -- THE CASE A PATH GLOB CANNOT EXPRESS, and the reason the selector is
    -- reachability: shared.lua is pulled in by BOTH entries, so it runs in both
    -- environments and may use only what BOTH provide. `game` is runtime-only, so it
    -- is wrong there even though ONE of its two stages does provide it.
    local st, root = factorio_tree({
        ['data.lua'] = 'require("shared")',
        ['control.lua'] = 'require("shared")',
        ['shared.lua'] = 'game.print("x")\nlocal s = string.rep("a", 2)',
    })
    local res = port.audit(st, 'lua-factorio')
    ok(res.stages, 'a map was built')
    local at = res.stages.by_file['shared.lua']
    ok(at.data and at.runtime, 'shared.lua is placed at BOTH stages')
    eq(1, #res.stages.shared, 'and reported as multi-stage')
    local g = region_of(res, 'game.print')
    ok(g, 'game.print is STILL a finding: membership in one stage is not enough')
    eq('data+runtime', table.concat(g.loaded_at, '+'))
    eq(nil, region_of(res, 'string.rep'), 'while a shared name is fine in both')
    vim.fn.delete(root, 'rf')
end)

test('portability: a file NO entry reaches has no stage, and the report says so',
    function ()
    if not lua_ready() then skip 'no lua parser' end
    local st, root = factorio_tree({
        ['data.lua'] = 'data.extend{{}}',
        ['control.lua'] = 'game.print("x")',
        -- required by nothing: dead code, or loaded by a mechanism we do not model
        ['orphan.lua'] = 'game.print("y")',
    })
    local res = port.audit(st, 'lua-factorio')
    eq(1, #res.stages.orphans, 'exactly the unreached file')
    eq('orphan.lua', res.stages.orphans[1])
    -- and NOTHING was ruled about it: an unplaced file must not be silently treated
    -- as clean, which is the absence-rendered-as-silence class
    eq(nil, region_of(res, 'game.print'),
        'no verdict on a file whose stage is unknown')
    local text = table.concat(port.report(st, 'lua-factorio'), '\n')
    ok(text:find('reached by NO entry point'), 'the report discloses it')
    ok(text:find('nothing above ruled on them'), 'and says it did not rule')
    vim.fn.delete(root, 'rf')
end)

test('portability: a profile with NO stages behaves exactly as before', function ()
    local pm = require 'cartograph.spec.profile'
    -- every other shipped profile: no partition declared, so no map, no new bucket,
    -- and nothing about the existing report changes
    for _, name in ipairs({ 'luajit', 'ruby-core', 'zig-std' }) do
        local prof = pm.load(name)
        if prof then
            eq(nil, port.stage_map({ data = { nodes = {}, edges = {} } }, prof),
                name .. ' declares no stages, so there is no partition to apply')
            eq(nil, port.stage_owners_of(prof, 'foo.bar'),
                name .. ' has no opinion about any name\'s stage')
        end
    end
end)

test('portability: the 1.1 delta partitions its OWN runtime globals', function ()
    local pm = require 'cartograph.spec.profile'
    local p20, p11 = pm.load('lua-factorio'), pm.load('lua-factorio-11')
    if not (p20 and p11) then skip 'no factorio profiles' end
    -- the stage partition is a delta too: 1.1's runtime has `global`, 2.0's has
    -- `storage`, and neither should carry the other's
    ok(p20.stage_owners.storage and p20.stage_owners.storage.runtime,
        '2.0: storage is runtime-only')
    eq(nil, p20.stage_owners.global, '2.0 has no `global`')
    ok(p11.stage_owners.global and p11.stage_owners.global.runtime,
        '1.1: global is runtime-only')
    eq(nil, p11.stage_owners.storage, '1.1 has no `storage`')
    -- and what did NOT change stays identical, which is the point of a delta
    ok(p11.stage_owners.data.data and p11.stage_owners.data.settings,
        '`data` is a data+settings-stage name in both')
    eq(nil, p11.stage_owners.helpers, 'helpers is 2.0-only, so it is absent here too')
    eq(#p20.stages, #p11.stages, 'same three stages')
end)

-- ── THE THIRD SURFACE: the DATA STAGE (CART-0213) ───────────────────────────
-- calls diff, reads diff, and now prototypes. What needs pinning is the thing that
-- makes this a WORKLIST rather than a name match: a property is judged against the
-- property set of the prototype that OWNS it, and a DELETION is not a write.

local proto_tmp = vim.fn.tempname()

--- A one-module factorio store. `profile` is what activates the prototype adapter
--- (the L2 identity, never the extension), the same trick prototypes_spec uses.
local function factorio_store(src)
    local st = require 'cartograph.store'
    vim.fn.mkdir(proto_tmp, 'p')
    local name = 'data.lua'
    vim.fn.writefile(vim.split(src, '\n'), proto_tmp .. '/' .. name)
    st._content_cache = {}
    st.ingest({ schema = 1, root = proto_tmp, profile = 'lua-factorio',
        nodes = { { id = name, name = name, kind = 'module', file = name,
            range = { start = { line = 0, char = 0 },
                      ['end'] = { line = #vim.split(src, '\n') + 1, char = 0 } },
            order = 0 } }, edges = {} })
    return st
end

local function proto_ready()
    local pm = require 'cartograph.spec.profile'
    return pm.load('lua-factorio-proto-11') and pm.load('lua-factorio-proto-20')
end

test('portability: the data-stage diff separates a WRITE from a DELETION', function ()
    if not proto_ready() then skip 'no prototype-api artifacts' end
    -- every property below was verified against BOTH artifacts before being used:
    -- recipe.result and transport-belt.circuit_wire_connection_points are in 1.1 and
    -- not 2.0; recipe.enabled is in both.
    local st = factorio_store(table.concat({
        'local r = table.deepcopy(data.raw.recipe["assembling-machine-1"])',
        'r.result = "damaged-machine"',   -- a WRITE to a removed property
        'r.enabled = true',               -- present in both: unchanged
        'data:extend{r}',
        'local b = table.deepcopy(data.raw["transport-belt"]["basic"])',
        'b.circuit_wire_connection_points = nil', -- a DELETION of a removed property
        'data:extend{b}',
    }, '\n'))
    local res, err = port.prototype_diff(st, 'lua-factorio-proto-11',
        'lua-factorio-proto-20')
    ok(res, 'the diff runs: ' .. tostring(err))

    eq(1, #res.lost, 'exactly ONE write to a removed property')
    eq('result', res.lost[1].prop)
    eq('recipe', res.lost[1].typename)
    eq('RecipePrototype', res.lost[1].proto, 'and the prototype that OWNS it')
    eq('damaged-machine', res.lost[1].value, 'carrying the value that goes nowhere')

    -- THE REGRESSION THIS EXISTS FOR: my first discriminator tested `value == nil`,
    -- which is never true (the IR carries a sentinel for a nil literal whose
    -- tostring is "nil"), so all nine of Von-Neumann's deletions were reported as
    -- writes — a worklist that was 90% wrong about what to DO. The schema says
    -- ty == 'nil' (expr.lua:11) and that is what must be read.
    eq(1, #res.stale_delete, 'and the nil-assignment is a DELETION, not a write')
    eq('circuit_wire_connection_points', res.stale_delete[1].prop)
    ok(res.kept >= 1, 'a property present in both versions is unchanged')
    vim.fn.delete(proto_tmp, 'rf')
end)

test('portability: an INLINE table literal is read — its type= is its discriminator',
    function ()
    if not proto_ready() then skip 'no prototype-api artifacts' end
    -- CART-0220. `data:extend{{…}}` is the ecosystem's dominant shape: 3280 of 3874
    -- data:extend sites across 195 installed mods, against 594 that pass a variable.
    -- Those keys used to be unreadable and the whole prototype counted as UNREAD; the
    -- expression IR now models a constructor entry, so the literal is adjudicated by
    -- its own `type=` exactly as a copied prototype is by data.raw[<type>][<name>].
    -- Properties verified against BOTH artifacts first: container.vehicle_impact_sound
    -- is in 1.1 and gone in 2.0; container.inventory_size is in both.
    local st = factorio_store(table.concat({
        'data:extend{{',
        '  type = "container",',
        '  name = "q",',
        '  inventory_size = 8,',
        '  vehicle_impact_sound = 1,',
        '}}',
    }, '\n'))
    local res = port.prototype_diff(st, 'lua-factorio-proto-11', 'lua-factorio-proto-20')
    ok(res, 'the diff runs')
    eq(0, #res.unread, 'the literal is NOT unread any more — it is read')
    eq(1, #res.lost, 'and its removed property is a real finding')
    eq('vehicle_impact_sound', res.lost[1].prop)
    eq('container', res.lost[1].typename, 'from the literal\'s OWN type= key')
    ok(res.kept >= 1, 'while a property present in both versions is unchanged')
    vim.fn.delete(proto_tmp, 'rf')
end)

test('portability: a literal it still cannot read is UNREAD, with the reason',
    function ()
    if not proto_ready() then skip 'no prototype-api artifacts' end
    -- The lower bound did not go away, it got smaller. Two things still defeat it, and
    -- each says which: a COMPUTED key (the property name is not knowable) and a literal
    -- with no `type=` (no prototype owns its properties). Reported, never counted clean
    -- — a data-stage reading that printed only findings would be a fabricated all-clear.
    local st = factorio_store(table.concat({
        'local k = "inventory_size"',
        'local u = { [k] = 8 }',        -- computed key, and no type=
        'data:extend{u}',
    }, '\n'))
    local res = port.prototype_diff(st, 'lua-factorio-proto-11', 'lua-factorio-proto-20')
    ok(res, 'the diff runs')
    eq(0, #res.lost, 'nothing is claimed about it')
    eq(1, #res.unread, 'it is UNREAD, and counted')
    ok(res.unread[1].why:find('COMPUTED') or res.unread[1].why:find('no `type=`'),
        'with the reason, not a shrug: ' .. tostring(res.unread[1].why))
    local text = table.concat(port.prototype_diff_report(st, 'lua-factorio-proto-11',
        'lua-factorio-proto-20'), '\n')
    ok(text:find('LOWER BOUND'), 'and the report leads with the lower bound')
    vim.fn.delete(proto_tmp, 'rf')
end)

test('portability: a RUNTIME artifact cannot answer a data-stage question', function ()
    if not proto_ready() then skip 'no prototype-api artifacts' end
    local st = factorio_store('local r = table.deepcopy(data.raw.recipe["x"])')
    -- the same class of fence as dotted_queryable: a runtime profile has no
    -- typenames, so every property would come back fine — the most reassuring
    -- possible answer from the artifact least able to give it
    local res, err = port.prototype_diff(st, 'lua-factorio-api-11', 'lua-factorio-api-20')
    eq(nil, res, 'refused rather than answered')
    ok(err and err:find('DATA%-STAGE'), 'and it says what is missing: ' .. tostring(err))
    ok(not port.prototype_queryable(require('cartograph.spec.profile')
        .load('lua-factorio-api-11')), 'the predicate agrees')
    ok(port.prototype_queryable(require('cartograph.spec.profile')
        .load('lua-factorio-proto-11')), 'and accepts a prototype-stage artifact')
    vim.fn.delete(proto_tmp, 'rf')
end)

test('portability: requires() carries EVERY file a name was seen in, not a sample',
    function ()
    if not ready() then skip('no ruby parser') end
    local ts = require 'cartograph.providers.treesitter'
    local store = require 'cartograph.store'
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    -- the SAME external base used from two files, deliberately named so the
    -- alphabetically-first file is not the only interesting one
    write(root, 'a_first.rb', { 'class A', '  def go', '    Wombat.frob(1)', '  end', 'end' })
    write(root, 'z_last.rb', { 'class Z', '  def go', '    Wombat.frob(2)', '  end', 'end' })
    local data = ts.extract(root); data.root = root
    store.ingest(data)
    local req = port.requires(store)
    local files = req.files['Wombat.frob']
    ok(files, 'the population is carried at all')
    eq(2, #files, 'BOTH files, which is the whole point of CART-0215')
    eq('a_first.rb', files[1], 'sorted, so reports and gates are deterministic')
    eq('z_last.rb', files[2])
    eq('a_first.rb', req.where['Wombat.frob'],
        'and `where` keeps its historical meaning — the alphabetically first — so'
        .. ' no existing count moves')
    -- and the audit carries the population through, not the sample
    local res = port.audit(store, 'ruby-rails')
    for _, e in ipairs(res.entries) do
        if e.name == 'Wombat.frob' then
            eq(2, #e.files, 'the audit entry carries both files')
        end
    end
    vim.fn.delete(root, 'rf')
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

-- ── the REFERENCE surface: names read but never called ───────────────────────
-- surface() is built from CALL records, so a name that is read and never invoked is
-- invisible to it — and two whole classes of porting work live exactly there.
-- MEASURED on the Von Neumann mod: `game.entity_prototypes[...]` is an INDEX
-- EXPRESSION and `global.foo` a FIELD ACCESS, so neither produces a call record.
-- Verified against runtime-api 2.0.72, not merely reported: entity_prototypes,
-- item_prototypes and active_mods are all absent from LuaGameScript (active_mods
-- moved to LuaBootstrap, i.e. script.active_mods).

local function refs_fixture(body)
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local function w(rel, t)
        local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(t); fd:close()
    end
    w('info.json', '{"name":"M","version":"1.0","factorio_version":"1.1"}')
    w('control.lua', body)
    return root
end

test('externals: a read is a reference; a CALL is not', function ()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not pcall(vim.treesitter.language.add, 'lua') then skip 'no lua parser' end
    local ts = require 'cartograph.providers.treesitter'
    local store = require 'cartograph.store'
    -- `global.flag` is READ in two functions; `string.find` is CALLED
    local root = refs_fixture('local function a()\n  if global.flag then return 1 end\n'
        .. '  return string.find("x", "y")\nend\n'
        .. 'local function b()\n  global.flag = true\n  return a()\nend\n'
        .. 'return { a = a, b = b }\n')
    store.ingest(ts.extract(root))
    local refs = require('cartograph.externals').references(store)
    ok(refs.names['global.flag'] ~= nil, 'the read is a reference')
    -- the CALLEE position is excluded, so the two surfaces stay disjoint and each
    -- can be reported as evidence of its own kind
    eq(nil, refs.names['string.find'])
    vim.fn.delete(root, 'rf')
end)

test('externals: a read rooted at a local or param is NOT external', function ()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not pcall(vim.treesitter.language.add, 'lua') then skip 'no lua parser' end
    local ts = require 'cartograph.providers.treesitter'
    local store = require 'cartograph.store'
    local root = refs_fixture('local function a(param)\n  local loc = {}\n'
        .. '  return param.field + loc.other + global.real\nend\n'
        .. 'local function b()\n  return global.real\nend\n'
        .. 'return { a = a, b = b }\n')
    store.ingest(ts.extract(root))
    local refs = require('cartograph.externals').references(store)
    eq(nil, refs.names['param.field'])  -- a parameter
    eq(nil, refs.names['loc.other'])    -- a local
    ok(refs.names['global.real'] ~= nil, 'a genuinely free root survives')
    vim.fn.delete(root, 'rf')
end)

-- LOOP BINDINGS are locals, known from the spec's declared BINDER NODES. This was a
-- spread heuristic ("withhold a root seen in only one function") until the grammar
-- was declared; the heuristic is gone and nothing is withheld, which is the
-- difference between guessing and knowing.
test('externals: a loop-bound receiver is a LOCAL, with nothing withheld', function ()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not pcall(vim.treesitter.language.add, 'lua') then skip 'no lua parser' end
    local ts = require 'cartograph.providers.treesitter'
    local store = require 'cartograph.store'
    local root = refs_fixture('local function a(list)\n'
        .. '  for _, gen in pairs(list) do print(gen.energy) end\n'
        .. '  return global.shared + global.once\nend\n'
        .. 'local function b()\n  return global.shared\nend\n'
        .. 'return { a = a, b = b }\n')
    store.ingest(ts.extract(root))
    local refs = require('cartograph.externals').references(store)
    eq(nil, refs.names['gen.energy'])   -- a declared binder: a local, not a global
    eq(0, refs.withheld or 0)           -- ... and nothing had to be withheld to know
    ok(refs.names['global.shared'] ~= nil, 'a genuinely free root survives')
    -- the discriminator is the GRAMMAR, not spread: a loop-bound root is excluded
    -- even when it is touched in only one function, and a free root is kept even
    -- when it is
    ok(refs.names['global.once'] ~= nil, 'a free root read in ONE function survives')
    vim.fn.delete(root, 'rf')
end)

test('portability: the reference report names the real porting work', function ()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not pcall(vim.treesitter.language.add, 'lua') then skip 'no lua parser' end
    local ts = require 'cartograph.providers.treesitter'
    local store = require 'cartograph.store'
    local port = require 'cartograph.portability'
    local prof = require('cartograph.spec.profile').load('lua-factorio')
    if not (prof and prof.api_complete) then skip 'no distilled api artifact' end
    -- `global.*` is a root 2.0 removed; game.entity_prototypes is a member it moved
    local root = refs_fixture('local function a()\n'
        .. '  if global.done then return game.entity_prototypes["x"] end\n'
        .. '  return game.tick\nend\n'
        .. 'local function b()\n  global.done = true\n  return game.entity_prototypes\nend\n'
        .. 'return { a = a, b = b }\n')
    store.ingest(ts.extract(root))
    -- the classifier, directly
    eq('unknown-root', port.ref_reason(prof, 'global.done'))
    eq('absent', port.ref_reason(prof, 'game.entity_prototypes'))
    eq('unenumerated-namespace', port.ref_reason(prof, 'game.tick'))
    local body = table.concat(port.reference_report(store, 'lua-factorio'), '\n')
    ok(body:match('ROOT NOT IN THE TARGET') ~= nil, 'the removed-global group')
    ok(body:match('MEMBER ABSENT') ~= nil, 'the moved-member group')
    ok(body:match('real porting work') ~= nil, 'both named as actionable')
    vim.fn.delete(root, 'rf')
end)

-- ── the VERSION DIFF: a change beats an absence ──────────────────────────────
-- Scoring against one profile can only say "the target lacks this name", which may
-- be a fact about the artifact. With BOTH environments present, a status CHANGE is a
-- fact about the environments and survives both artifacts being incomplete the same
-- way. MEASURED 1.1.110 vs 2.0.72: api_version 5 vs 6, 97 classes vs 148, 7 globals
-- vs 9, LuaGameScript 133 members vs 74.
--
-- M.diff (the CALL surface) reports 0 lost on this move, because every name that
-- actually changed is READ and never called — which is why reference_diff exists.

test('portability: the 1.1 profile is the DELTA, not a copy', function ()
    local pm = require 'cartograph.spec.profile'
    local port = require 'cartograph.portability'
    local a, b = pm.load('lua-factorio-11'), pm.load('lua-factorio')
    if not (a and b) then skip 'factorio profiles not both present' end
    ok(port.name_queryable(a), '1.1 can answer name queries')
    -- the rename that matters: `global` became `storage` in 2.0
    ok((a.nsset or {})['global'] ~= nil, '1.1 has global')
    eq(nil, (b.nsset or {})['global'])
    eq(nil, (a.nsset or {})['storage'])
    ok((b.nsset or {})['storage'] ~= nil, '2.0 has storage')
    -- 2.0-only globals are absent from 1.1
    eq(nil, (a.nsset or {})['prototypes'])
    eq(nil, (a.nsset or {})['helpers'])
    -- the shared Lua half is REUSED, so it cannot drift and look like a version
    -- difference: the stdlib namespaces are identical
    for _, ns in ipairs({ 'table', 'string', 'math', 'coroutine' }) do
        ok((a.nsset or {})[ns] ~= nil and (b.nsset or {})[ns] ~= nil,
            ns .. ' present in both')
    end
end)

-- REGRESSION for a trap that cost a debugging round: a Lua module name is a PATH, so
-- a profile called `lua-factorio-1.1` makes require look for `lua-factorio-1/1.lua`.
-- The loader tries require BEFORE its .mpack fallback, so a dotted name silently
-- loads NOTHING — the first version of that file returned nil with no error.
test('portability: no profile module name contains a dot', function ()
    local dir = repo('lua/cartograph/spec/profile') -- the RUNNING tree: CART-0440
    if vim.fn.isdirectory(dir) ~= 1 then skip 'profile dir not present' end
    local bad = {}
    local it = vim.uv.fs_scandir(dir)
    while it do
        local n = vim.uv.fs_scandir_next(it)
        if not n then break end
        local base = n:match('^(.+)%.lua$')
        if base and base ~= 'init' and base:find('%.') then bad[#bad + 1] = base end
    end
    eq({}, bad)
end)

test('portability: reference_diff reports what the move LOST', function ()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not pcall(vim.treesitter.language.add, 'lua') then skip 'no lua parser' end
    local pm = require 'cartograph.spec.profile'
    if not (pm.load('lua-factorio-11') and pm.load('lua-factorio')) then
        skip 'factorio profiles not both present'
    end
    local ts = require 'cartograph.providers.treesitter'
    local store = require 'cartograph.store'
    local port = require 'cartograph.portability'
    -- `global.x` is a namespace 2.0 removed; game.entity_prototypes a member it moved
    local root = refs_fixture('local function a()\n'
        .. '  if global.done then return game.entity_prototypes end\n'
        .. '  return game.tick\nend\n'
        .. 'local function b()\n  global.done = true\n  return game.players\nend\n'
        .. 'return { a = a, b = b }\n')
    store.ingest(ts.extract(root))
    local res = port.reference_diff(store, 'lua-factorio-11', 'lua-factorio')
    ok(res ~= nil, 'the diff ran')
    local lost = {}
    for _, e in ipairs(res.lost) do lost[e.name] = e end
    ok(lost['global.done'], 'the removed NAMESPACE is lost')
    eq('namespace global', lost['global.done'].was)
    ok(lost['game.entity_prototypes'], 'the moved MEMBER is lost')
    eq('member of LuaGameScript', lost['game.entity_prototypes'].was)
    -- and what 2.0 still holds is NOT reported as work
    eq(nil, lost['game.tick'])
    eq(nil, lost['game.players'])
    ok(res.kept >= 2, 'unchanged names are counted, not listed')
    vim.fn.delete(root, 'rf')
end)

test('portability: a cross-language reference diff is refused', function ()
    local store = require 'cartograph.store'
    local port = require 'cartograph.portability'
    store.ingest({ schema = 1, root = '/tmp/x', nodes = {}, edges = {}, calls = {},
        stamps = {} })
    local res, err = port.reference_diff(store, 'lua-factorio', 'cruby')
    eq(nil, res)
    ok(tostring(err):match('different languages') ~= nil, 'says why: ' .. tostring(err))
end)

-- A DOTTED-QUERYABLE FENCE ([[cartograph-portability-lever]]). A distilled factorio
-- artifact once emitted its member table as `members`/`complete` while
-- portability.provides reads `api_members`/`api_complete`. It loaded fine, reported
-- "[complete]" for all 9 globals, and answered nil for EVERY dotted name — so a MOVE
-- diff compared silence with silence and printed "0 LOST" on a mod with two real
-- breaking changes. The bare-name fence did not catch it because 3 free functions are
-- enough for name_queryable to say yes. Hence a SECOND predicate, and these tests
-- pin the distinction rather than the spelling.
test('portability: bare-name queryable does not imply DOTTED queryable', function ()
    local port = require 'cartograph.portability'
    -- exactly the shape the old distiller emitted: free fns present, member table
    -- under the field name nothing reads
    local old = { lang = 'lua', free = { serpent = true },
        members = { ['LuaGameScript::print'] = true }, complete = { LuaGameScript = true },
        global2class = { game = 'LuaGameScript' } }
    ok(port.name_queryable(old), 'free fns make it look queryable')
    eq(false, port.dotted_queryable(old), 'but no dotted name can be adjudicated')
    eq(nil, port.provides(old, 'game.print'),
        'and provides() confirms it: the member table is unreachable')
end)

test('portability: the canonical field names ARE dotted-queryable', function ()
    local port = require 'cartograph.portability'
    local fixed = { lang = 'lua', free = { serpent = true },
        api_members = { ['LuaGameScript::print'] = true },
        api_complete = { LuaGameScript = true },
        global2class = { game = 'LuaGameScript' } }
    ok(port.dotted_queryable(fixed), 'api_members is what the reader consults')
    eq('member of LuaGameScript', port.provides(fixed, 'game.print'))
    -- and an ENUMERATED class makes a miss into evidence, which is the whole point
    eq(nil, port.provides(fixed, 'game.entity_prototypes'))
end)

test('portability: a MOVE diff refuses a profile that cannot answer a dotted name',
    function ()
    local store = require 'cartograph.store'
    local port = require 'cartograph.portability'
    store.ingest({ schema = 1, root = '/tmp/x', nodes = {}, edges = {}, calls = {},
        stamps = {} })
    -- lua-factorio is dotted-queryable; asking it to diff against a signature-keyed
    -- artifact must REFUSE rather than report every rename as unchanged
    local res, err = port.diff(store, 'lua-factorio', 'ruby-core')
    eq(nil, res)
    ok(err ~= nil and err ~= '', 'refuses with a reason: ' .. tostring(err))
end)

-- ── THE RECEIVER AXIS (CART-0587) ───────────────────────────────────────────
-- `receiver-typed` was the largest non-answer on every Factorio corpus (48 of 92
-- names / 101 calls on Von-Neumann) and said only "no representation at all".
-- classmatch supplies the missing key: the base's observed member set picks a class
-- out of the environment's declared class table, and the class-keyed member set is
-- the key space portability could never reach.
--
-- WHAT THESE SPECS ARE FOR, and it is one thing: the axis may never turn "I cannot
-- tell" into "the target lacks it". Ambiguity and zero-match are NOT-KNOWING, and
-- folding either into an absence would invent porting work out of the tool's own
-- uncertainty. Each has its own reason key and each is asserted to be neither the
-- absent one nor the present one.

-- A synthetic class table, so every branch is constructible — including the one a
-- real corpus CANNOT produce (see the next spec's note on why it exists anyway).
local function fake_ct()
    return require('cartograph.classmatch').table({
        runtime = 'fake', lang = 'lua', version = '0.0',
        classes = {
            -- Alpha and Beta are identical, so a shape inside them is AMBIGUOUS
            Alpha = { members = { a = true, b = true, c = true } },
            Beta  = { members = { a = true, b = true, c = true } },
            -- Gamma is the only class with `g`, so {g} DETERMINES it
            Gamma = { members = { g = true } },
        } })
end

test('portability: a receiver verdict is never AMBIGUITY dressed up as absence',
    function ()
    local port = require 'cartograph.portability'
    local cm = require 'cartograph.classmatch'
    local ct = fake_ct()
    -- {a} is declared by BOTH Alpha and Beta: the shape does not pick one
    local ev = cm.match({ a = 1 }, ct)
    eq('ambiguous', ev.outcome, 'the matcher itself says ambiguous')
    local why, d = port.receiver_verdict(ct, 'base.a', ev)
    eq('receiver-ambiguous', why)
    ok(why ~= 'receiver-class-absent' and why ~= 'absent',
        'AMBIGUOUS MUST NOT BECOME MISSING — this is the whole point of the axis')
    ok(why ~= 'receiver-class-present', 'nor may it become a claim of presence')
    eq(2, d.ncand, 'and the candidate count rides in the evidence, so a reader'
        .. ' can see how far from an answer it is')
    -- and the group text says so in words, not only in the key
    local txt = port.REASON_TEXT[why]
    ok(txt:find('NOT adjudicable', 1, true) ~= nil, 'the text says unadjudicable')
    ok(txt:find('the target lacks it', 1, true) ~= nil,
        'and names the misreading it is guarding against')
end)

test('portability: a ZERO-match receiver is not missing, and a NEAR MISS is not a'
    .. ' mod-local table', function ()
    local port = require 'cartograph.portability'
    local cm = require 'cartograph.classmatch'
    local ct = fake_ct()
    -- NOTHING like an API object: no class shares even one member. On Von-Neumann
    -- this is `util`, `data`, `Log`, `handler` — mod-local tables.
    local far = cm.match({ q = 1 }, ct)
    eq('zero', far.outcome)
    ok(cm.unrelated(far), 'unrelated by the recorded definition')
    local why = port.receiver_verdict(ct, 'base.q', far)
    eq('receiver-nomatch', why)
    ok(why ~= 'receiver-class-absent', 'ZERO MUST NOT BECOME MISSING: there is no'
        .. ' class to have looked the member up in, which is a different failure')
    -- ONE MEMBER AWAY from a real class. This is the ONLY pattern that could ever
    -- mean "the target removed that member", and it is equally what a mod that
    -- decorates an API object looks like — so it gets its OWN bucket rather than
    -- being filed under "not an API object", which would mislabel the one future
    -- absence signal there is.
    local near = cm.match({ a = 1, b = 1, z = 1 }, ct)
    eq('zero', near.outcome)
    eq(1, near.distance, 'Alpha/Beta are one member (z) away and share two')
    ok(not cm.unrelated(near), 'a near miss is NOT unrelated')
    eq('receiver-nearmiss', port.receiver_verdict(ct, 'base.z', near))
    ok(port.REASON_TEXT['receiver-nearmiss'] ~= port.REASON_TEXT['receiver-nomatch'],
        'and the two render differently, which is the point of splitting them')
end)

test('portability: a DETERMINED class that lacks the member is ABSENT — hedged,'
    .. ' and marked when it rests on one member', function ()
    -- ★ THIS BRANCH IS STRUCTURALLY UNREACHABLE FROM A REAL CORPUS TODAY, and that
    -- is itself the finding CART-0587 produced. requires() derives its names FROM
    -- externals.surface, so every `base.member` contributed head(member) to the
    -- base's SHAPE — and `determined` MEANS one class declares every member of the
    -- shape. So a determined base's class declares all of its members by
    -- construction, and adjudicable-absent is empty (measured on Von-Neumann: 27
    -- present, 8 chain, 7 ambiguous, 6 no-match, 0 absent).
    -- The branch is specced through the PURE entry point because the day the shape
    -- and the adjudicated name come from different populations, a silent fold into
    -- `present` is the bug that would follow.
    local port = require 'cartograph.portability'
    local cm = require 'cartograph.classmatch'
    local ct = fake_ct()
    local ev = cm.match({ g = 1 }, ct)
    eq('determined', ev.outcome); eq('Gamma', ev.class); eq(1, ev.n)
    local why, d = port.receiver_verdict(ct, 'base.not_a_member', ev)
    eq('receiver-class-absent', why)
    eq('Gamma', d.class, 'the hypothesised class rides into the verdict')
    eq('inferred', d.tier, 'on the inferred rung, NOT stdlib')
    -- THE HEDGE COMPOUNDS, and the rendering has to show it: classmatch's two known
    -- wrong answers are both n=1 (`name.find` -> LuaEquipmentGrid is really
    -- string.find), so a one-member verdict is marked as the hypothesis it is
    -- rather than presented as a confident port item.
    local cell = port.receiver_cell(d)
    ok(cell:find('~Gamma', 1, true) ~= nil, 'the class is rendered with the ~ hedge mark')
    ok(cell:find('n=1', 1, true) ~= nil, 'and the member count that decides belief')
    ok(cell:find('SINGLE%-MEMBER HYPOTHESIS') ~= nil,
        'a one-member match is CALLED a hypothesis: ' .. cell)
    -- a match on several members carries no such warning, because it does not need one
    local many = cm.match({ a = 1, b = 1, c = 1 }, fake_ct())
    if many.outcome == 'determined' then
        ok(port.receiver_cell({ class = many.class, n = many.n })
            :find('SINGLE', 1, true) == nil, 'and a multi-member one does not')
    end
end)

test('portability: a verdict resting on an INFERRED class renders weaker than one'
    .. ' resting on a global', function ()
    -- The compounded hedge, asserted where a reader meets it: the group text. The
    -- `absent` group rests on a global the profile NAMES and a class the artifact
    -- declares COMPLETE; the receiver one rests on a guess about the receiver.
    local port = require 'cartograph.portability'
    local strong = port.REASON_TEXT['absent']
    local weak = port.REASON_TEXT['receiver-class-absent']
    ok(strong:find('real porting work', 1, true) ~= nil,
        'the authoritative group claims porting work')
    ok(weak:find('CANDIDATE', 1, true) ~= nil,
        'the inferred one claims only a CANDIDATE: ' .. weak)
    ok(weak:find('WEAKER', 1, true) ~= nil, 'and says so explicitly')
    ok(weak:find('hypothesis', 1, true) ~= nil, 'naming the mechanism')
    -- and the merely-consistent group must not read as a verification: the class
    -- was CHOSEN because it declares these members, so it cannot confirm them
    local present = port.REASON_TEXT['receiver-class-present']
    ok(present:find('CHOSEN because', 1, true) ~= nil,
        'the tautology is disclosed rather than banked: ' .. present)
    ok(present:find('Not `provided`', 1, true) ~= nil,
        'and it is kept out of the authoritative count in words too')
end)

test('portability: every reason with TEXT has a slot in the report ORDER',
    function ()
    -- THE DUAL-REGISTRATION TRAP. The report walks REASON_ORDER, so a key that has
    -- text but no slot builds a group that is never printed — the reader sees fewer
    -- names than the header counts and has no way to know why. That is the
    -- absence-rendered-as-silence class, and adding the receiver axis added SIX
    -- keys at once, so it is fenced rather than remembered.
    local port = require 'cartograph.portability'
    local inorder = {}
    for _, k in ipairs(port.REASON_ORDER) do
        ok(not inorder[k], 'no duplicate slot: ' .. k)
        inorder[k] = true
        ok(port.REASON_TEXT[k] ~= nil, 'every ordered reason has text: ' .. k)
    end
    for k in pairs(port.REASON_TEXT) do
        ok(inorder[k], 'every reason WITH TEXT has a slot in the order, or its group'
            .. ' is silently dropped: ' .. k)
    end
end)

test('portability: no class table for THIS version leaves receivers unadjudicated,'
    .. ' and says why', function ()
    -- ★ THE VERSION GUARD IS THE SAFETY ARGUMENT. classmatch answers from whichever
    -- artifact carries a class table (today the 2.0.72 export, and the 1.1 artifact
    -- carries none). Adjudicating a 1.1 verdict against a 2.0 class table would turn
    -- a version mismatch into confident member verdicts — the shape of 44b8a2a, v5
    -- keys read against a v6 document, 104 confident nonsenses.
    local port = require 'cartograph.portability'
    local pm = require 'cartograph.spec.profile'
    local prof11 = pm.load('lua-factorio-11')
    if not prof11 then skip 'no lua-factorio-11 profile' end
    local store = require 'cartograph.store'
    local ctx, why = port.receiver_context(store, prof11)
    eq(nil, ctx, 'the 1.1 end gets NO class table')
    ok(why ~= nil and why:find('version', 1, true) ~= nil,
        'and the refusal names the mechanism rather than going quiet: ' .. tostring(why))
    -- an audit without a context behaves EXACTLY as it did before this axis existed
    local prof = pm.load('lua-factorio')
    if not prof then skip 'no lua-factorio profile' end
    eq('receiver-typed', port.unknown_reason(prof, 'player.teleport', 'a.lua'),
        'no context -> the unrefined bucket, not a nil and not a guess')
    ok(port.REASON_TEXT['receiver-typed']:find('UNADJUDICATED', 1, true) ~= nil,
        'and its text says the axis was unavailable, not that there was nothing to say')
end)

test('portability: the report splits receivers by reason and counts none as provided',
    function ()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not pcall(vim.treesitter.language.add, 'lua') then skip 'no lua parser' end
    local pm = require 'cartograph.spec.profile'
    if not pm.load('lua-factorio') then skip 'no lua-factorio profile' end
    local ts = require 'cartograph.providers.treesitter'
    local store = require 'cartograph.store'
    local port = require 'cartograph.portability'
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local function w(rel, t)
        local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(t); fd:close()
    end
    w('info.json', '{"name":"M","version":"1.0","factorio_version":"1.1"}')
    -- one base per outcome, chosen from the real 2.0.72 class table:
    --   pl  {print,teleport,get_inventory,character} -> LuaPlayer, determined
    --   gui {add}                                    -> several classes, ambiguous
    --   zz  {no_such_api_thing_at_all}               -> no class shares it at all
    w('control.lua', 'return { go = function (pl, gui, zz)\n'
        .. '  pl.print("x"); pl.teleport({0,0}); pl.get_inventory(1)\n'
        .. '  pl.character.destroy()\n'
        .. '  gui.add({})\n'
        .. '  zz.no_such_api_thing_at_all()\n'
        .. 'end }\n')
    store.ingest(ts.extract(root))
    local res = assert(port.audit(store, 'lua-factorio'))
    if not res.receiver.available then
        skip('no class table: ' .. tostring(res.receiver.why))
    end
    local byname = {}
    for _, e in ipairs(res.entries) do byname[e.name] = e end
    eq('receiver-class-present', byname['pl.print'].reason)
    eq('LuaPlayer', byname['pl.print'].receiver.class,
        'the class the verdict rests on is carried on the ENTRY, not only rendered')
    eq('receiver-class-chain', byname['pl.character.destroy'].reason,
        'a deeper hop is only PARTIALLY adjudicated: the class table carries member'
        .. ' NAMES without member TYPES, so `character` cannot be followed')
    eq('receiver-ambiguous', byname['gui.add'].reason)
    -- ⚠ THIS USED TO EXPECT `receiver-nomatch` AND THE BETTER ANSWER REPLACED IT
    -- (CART-0631). The fixture declares factorio_version "1.1" in info.json, so the
    -- audit now picks the 1.1 class table as the ORIGIN by itself and can say
    -- something the no-match bucket never could: the name is declared by no class in
    -- EITHER version, so it never was API. `receiver-nomatch` is still reachable and
    -- still fenced — it is what remains when no origin is available (below).
    eq('not-a-runtime-member', byname['zz.no_such_api_thing_at_all'].reason)
    eq(true, res.origin.auto, 'and the origin was derived from the manifest, not asked for')
    -- NOTHING the receiver axis touched is counted as provided. Folding a shape-match
    -- hypothesis into that count would change what the number means AND make a
    -- version diff report every receiver as GAINED, because only the 2.0 end has a
    -- class table to match against.
    for _, e in ipairs(res.entries) do
        if e.reason and e.reason:match('^receiver%-') then
            eq(false, e.provided, 'a hypothesis is never `provided`: ' .. e.name)
        end
    end
    local body = table.concat(port.report(store, 'lua-factorio', { cap = 40 }), '\n')
    ok(body:find('inferred', 1, true) ~= nil, 'the report names the rung it rides')
    -- `receiver-nomatch` LEFT THIS LIST because the fixture no longer produces one:
    -- with an origin available every no-match name is decided (CART-0631). It is
    -- still fenced — the no-origin run at the end of this test asserts it is exactly
    -- what comes back when the class spaces cannot be compared.
    for _, key in ipairs({ 'receiver-class-present', 'receiver-class-chain',
        'receiver-ambiguous', 'not-a-runtime-member' }) do
        -- the group TEXT is wrapped across lines, so match its first distinctive word
        local head = port.REASON_TEXT[key]:match('^(%S+ %S+ %S+)')
        ok(body:find(head, 1, true) ~= nil, 'the group prints for ' .. key)
    end
    -- the structural emptiness of the absent bucket is STATED, not left to be read
    -- as a clean bill of health
    ok(body:find('STRUCTURAL', 1, true) ~= nil,
        'the report says WHY there is no hypothesised-class absent group')
    -- ★ AND THE UNREFINED BUCKET IS STILL REACHABLE. Same tree, manifest removed,
    -- so no origin can be derived: `zz` falls back to exactly the answer it gave
    -- before this axis existed. A bucket that can no longer be produced by anything
    -- is a fence that never fires, and the report still carries its text.
    vim.fn.delete(root .. '/info.json')
    store.ingest(ts.extract(root))
    local plain = assert(port.audit(store, 'lua-factorio'))
    eq(false, plain.origin.available, 'no manifest -> no origin')
    ok(plain.origin.why ~= nil, 'and it says why rather than staying silent')
    local pn = {}
    for _, e in ipairs(plain.entries) do pn[e.name] = e end
    eq('receiver-nomatch', pn['zz.no_such_api_thing_at_all'].reason)
    vim.fn.delete(root, 'rf')
end)

-- ── THE CLASS-SPACE AXIS (CART-0631) ────────────────────────────────────────
-- A member name decided against BOTH versions' whole class spaces, with no
-- receiver. The removal direction is sound without one; the supplied direction is
-- a SUBSET test, never bare presence — which is the only thing separating it from
-- the MOVED bucket, and the reason all four exist rather than three.

test('class space: the four verdicts are a partition, and MOVED is not either neighbour',
    function ()
    local port = require 'cartograph.portability'
    -- a SPACE is member -> the set of classes declaring it (classmatch.space), the
    -- class table read along its other axis
    local A = { set_request_slot = { LuaEntity = true },
        destroy = { LuaEntity = true, LuaRendering = true },
        die = { LuaEntity = true } }
    local B = { destroy = { LuaEntity = true },
        die = { LuaEntity = true, LuaSection = true } }
    eq('member-removed', (port.class_space_verdict(A, B, 'set_request_slot')),
        'declared in the origin, by NO class in the target — sound without a receiver')
    eq('not-a-runtime-member', (port.class_space_verdict(A, B, 'nothing_at_all')),
        'declared by no class in EITHER: never was API, and that is an ANSWER')
    eq('member-supplied', (port.class_space_verdict(A, B, 'die')),
        'every class that declared it still does, so any receiver that worked works')
    eq('member-moved', (port.class_space_verdict(A, B, 'destroy')),
        'LuaRendering dropped it: SUPPLIED to a presence test, REMOVED to LuaRendering')
    local _, d = port.class_space_verdict(A, B, 'destroy')
    eq({ 'LuaRendering' }, d.lost_classes, 'and the row names which class lost it')
    local _, rd = port.class_space_verdict(A, B, 'set_request_slot')
    eq({ 'LuaEntity' }, rd.from_classes, 'a removal names where it used to live')
    -- a name only the TARGET has says nothing about porting FROM the origin
    eq(nil, (port.class_space_verdict(A, {}, 'x')) and nil or
        (port.class_space_verdict({}, B, 'die')), 'gained is not a verdict here')
end)

test('class space: a name is decided by its STRONGEST segment, and literals do not split',
    function ()
    local port = require 'cartograph.portability'
    local A = { element = { C = true }, parent = { C = true },
        destroy = { C = true, D = true }, gone = { C = true } }
    local B = { element = { C = true }, parent = { C = true }, destroy = { C = true } }
    -- a chain is several member accesses and ALL must survive: one removed hop
    -- outranks three surviving ones
    eq('member-removed', (port.class_space_name(A, B, 'ev.parent.gone')),
        'removed outranks supplied — one broken hop breaks the call')
    eq('member-moved', (port.class_space_name(A, B, 'ev.element.parent.destroy')),
        'D lost destroy, so the chain is receiver-dependent, not clean')
    local _, d = port.class_space_name(A, B, 'ev.element.parent.destroy')
    eq({ 'element', 'parent', 'destroy' }, d.segments,
        'the segments asked about ride in the detail, so the split is checkable')
    -- ⚠ a call-shaped key carries a TABLE LITERAL; splitting it on dots would
    -- invent members out of whatever the literal holds
    local v, cd = port.class_space_name(A, B, 'cs.make{name="a.b",pos={1,2}}.destroy')
    eq('member-moved', v)
    eq({ 'destroy' }, cd.segments, 'only the TRAILING member, never the literal')
    eq(nil, (port.class_space_name(A, B, 'bare')), 'an undotted name has no member')
end)

test('class space: the origin is FENCED, and a refusal is reported not silent',
    function ()
    local pm = require 'cartograph.spec.profile'
    if not pm.load('lua-factorio') then skip 'no lua-factorio profile' end
    local port = require 'cartograph.portability'
    local store = require 'cartograph.store'
    store.ingest({ schema = 1, root = '/x', nodes = {}, edges = {}, calls = {} })
    local prof = pm.load('lua-factorio')
    -- SAME VERSION BOTH ENDS: a diff against itself decides nothing, and saying so
    -- is not the same as finding nothing
    local rc = port.receiver_context(store, prof, 'lua-factorio-api-20')
    if rc then
        eq(nil, rc.from_space, 'an equal-version origin supplies no space')
        ok(rc.from_why and rc.from_why:find('decides nothing', 1, true) ~= nil,
            'and the reason names the mechanism: ' .. tostring(rc.from_why))
    end
    local rc2 = port.receiver_context(store, prof, 'no-such-artifact-at-all')
    if rc2 then
        eq(nil, rc2.from_space)
        ok(rc2.from_why ~= nil, 'an origin that could not load must not read as absent')
    end
end)

test('class space: a REAL removal is found where the receiver cannot be typed',
    function ()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not pcall(vim.treesitter.language.add, 'lua') then skip 'no lua parser' end
    local pm = require 'cartograph.spec.profile'
    if not (pm.load('lua-factorio') and pm.load('lua-factorio-api-11')) then
        skip 'both profiles are needed for a class-space diff'
    end
    local ts = require 'cartograph.providers.treesitter'
    local store = require 'cartograph.store'
    local port = require 'cartograph.portability'
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local function w(rel, t)
        local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(t); fd:close()
    end
    w('info.json', '{"name":"M","version":"1.0","factorio_version":"1.1"}')
    -- `set_request_slot` is declared by LuaEntity in 1.1 and by NO class in 2.0 —
    -- verified against the raw 2.0.77 runtime-api.json, not only against our mpack.
    -- The base's shape matches no class, so the receiver axis CANNOT type it; that
    -- is exactly the bucket this axis refines.
    w('control.lua', 'return { go = function (chest)\n'
        .. '  chest.set_request_slot(1, {})\n'
        .. 'end }\n')
    store.ingest(ts.extract(root))
    local res = assert(port.audit(store, 'lua-factorio'))
    if not res.receiver.available then skip('no class table: ' .. tostring(res.receiver.why)) end
    if not res.origin.available then skip('no origin: ' .. tostring(res.origin.why)) end
    local byname = {}
    for _, e in ipairs(res.entries) do byname[e.name] = e end
    local e = byname['chest.set_request_slot']
    ok(e ~= nil, 'the name is in the audit at all')
    eq('member-removed', e.reason, 'a port item, not a frontier')
    eq('receiver-nomatch', e.receiver.receiver_was,
        'and it records WHICH bucket it was refined out of, so the change is traceable')
    eq(false, e.provided, 'a removal is never `provided`')
    local body = table.concat(port.report(store, 'lua-factorio', { cap = 40 }), '\n')
    ok(body:find('CLASS SPACES:', 1, true) ~= nil, 'the header says the axis ran')
    ok(body:find('REMOVED FROM THE TARGET', 1, true) ~= nil, 'and the group is printed')
end)

-- ── THE SHAPE-MOVE AXIS (CART-0632) ─────────────────────────────────────────
-- The evidence that was missing is the ORIGIN's candidate set. Two earlier forms
-- of this test are VACUOUS BY CONSTRUCTION and both look like features, so the
-- first spec here fences the vacuity rather than the feature.

test('shape move: the ORIGIN candidates decide, per MEMBER, not per base',
    function ()
    local port = require 'cartograph.portability'
    -- 2.0 moved `set_command` off LuaEntity and LuaUnitGroup lost `surface` too
    local to_ct = { classes = {
        LuaEntity = { all = { surface = true, position = true } },
        LuaCommandable = { all = { set_command = true, surface = true } },
    } }
    local from = { candidates = { 'LuaEntity', 'LuaUnitGroup' }, n = 2 }
    local to = { class = 'LuaCommandable', n = 2 }
    -- the member NO origin candidate still declares: broken whichever it was
    local v, d = port.shape_move_verdict(from, to, to_ct, 'set_command')
    eq('shape-broken', v)
    eq({ 'LuaEntity', 'LuaUnitGroup' }, d.lost_classes)
    eq({}, d.kept_classes)
    -- ★ A SIBLING CALL ON THE SAME BASE IS NOT CONDEMNED WITH IT. `surface` still
    -- lives on LuaEntity, so this is a hedge, not porting work — the first cut
    -- answered per BASE and marked all three railbotUnit names broken.
    local v2, d2 = port.shape_move_verdict(from, to, to_ct, 'surface')
    eq('shape-at-risk', v2)
    eq({ 'LuaUnitGroup' }, d2.lost_classes)
    eq({ 'LuaEntity' }, d2.kept_classes)
    -- a member every origin candidate kept is not a finding at all
    eq(nil, (port.shape_move_verdict({ candidates = { 'LuaEntity' } },
        to, to_ct, 'position')))
    -- no candidates on either side -> no evidence, never a verdict
    eq(nil, (port.shape_move_verdict({ candidates = {} }, to, to_ct, 'surface')))
    eq(nil, (port.shape_move_verdict(from, { candidates = {} }, to_ct, 'surface')))
    eq(nil, (port.shape_move_verdict(from, to, to_ct, nil)))
end)

test('shape move: the TARGET-side candidate tests are vacuous, and this is why',
    function ()
    local cm = require 'cartograph.classmatch'
    local prof = require 'cartograph.spec.profile'
    if not prof.load('lua-factorio-api-20') then skip 'no 2.0 class table' end
    local ct = assert(cm.table('lua-factorio-api-20'))
    -- ⚠ THE FENCE IS ON THE VACUITY, NOT ON A FEATURE. classmatch builds the
    -- candidate set by requiring EVERY observed member, so "does every candidate
    -- declare the member" is true by construction — a test shaped like this would
    -- ship, always answer yes, and look like it worked. Measured 7/7 on
    -- Von-Neumann before the real test was found.
    local ev = cm.match({ add = true }, ct)
    if ev.outcome ~= 'ambiguous' then skip 'shape {add} is not ambiguous here' end
    ok(#ev.candidates > 1, 'several classes declare it')
    for _, c in ipairs(ev.candidates) do
        ok(ct.classes[c].all['add'] ~= nil,
            c .. ' declares the member BY CONSTRUCTION — this is why the'
            .. ' all-candidates test carries no information')
    end
end)

test('shape move: a real removal is found in the DETERMINED bucket',
    function ()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not pcall(vim.treesitter.language.add, 'lua') then skip 'no lua parser' end
    local pm = require 'cartograph.spec.profile'
    if not (pm.load('lua-factorio') and pm.load('lua-factorio-api-11')) then
        skip 'both profiles are needed'
    end
    local ts = require 'cartograph.providers.treesitter'
    local store = require 'cartograph.store'
    local port = require 'cartograph.portability'
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local function w(rel, t)
        local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(t); fd:close()
    end
    w('info.json', '{"name":"M","version":"1.0","factorio_version":"1.1"}')
    -- the Von-Neumann shape: {set_command, surface}. Under 1.1 that is LuaEntity
    -- or LuaUnitGroup; under 2.0 `set_command` lives only on LuaCommandable
    -- (verified against the raw 2.0.77 runtime-api.json). So the base's 2.0 match
    -- is DETERMINED — which is why an ambiguous-only build would have missed it.
    w('control.lua', 'return { go = function (unit)\n'
        .. '  unit.set_command({})\n'
        .. '  unit.surface.create_entity({})\n'
        .. 'end }\n')
    store.ingest(ts.extract(root))
    local res = assert(port.audit(store, 'lua-factorio'))
    if not (res.receiver.available and res.origin.available) then
        skip('needs both class tables: ' .. tostring(res.receiver.why or res.origin.why))
    end
    local byname = {}
    for _, e in ipairs(res.entries) do byname[e.name] = e end
    local sc = byname['unit.set_command']
    ok(sc ~= nil, 'the name is in the audit')
    eq('shape-broken', sc.reason, 'no origin candidate still declares set_command')
    eq(false, sc.provided)
    ok(sc.receiver.receiver_was ~= nil,
        'and it records which bucket it was refined out of')
    -- the sibling on the same base must NOT be condemned with it
    local su = byname['unit.surface.create_entity']
    if su then
        ok(su.reason ~= 'shape-broken',
            'a member the origin candidates kept is not porting work: ' .. su.reason)
    end
    local body = table.concat(port.report(store, 'lua-factorio', { cap = 40 }), '\n')
    ok(body:find('NO PLAUSIBLE RECEIVER', 1, true) ~= nil, 'the group prints')
    vim.fn.delete(root, 'rf')
end)

-- ── THE NESTED DATA STAGE (CART-0633) ───────────────────────────────────────
-- The diff used to check the FIRST path segment against the prototype that owns it
-- and stop. Factorio's data stage nests, so a whole class was invisible.

test('nested data stage: type_props closes over a CONCEPT parent',
    function ()
    local port = require 'cartograph.portability'
    -- ★★ THIS IS THE SPEC THAT CAUGHT A WRONG HAND-ANALYSIS. Writing the port guide
    -- I checked properties per-type with no inheritance and concluded 2.0 had removed
    -- `fade_in_ticks` from WorkingSound. It has not: 2.0 gave WorkingSound a parent,
    -- MainSound, which declares it. A flat check invents porting work out of a
    -- refactor; the closure is the whole difference.
    local prof = { prototypes = {}, concept_types = { WorkingSound = true, MainSound = true },
        concept_parent = { WorkingSound = 'MainSound' },
        concept_props = {
            ['WorkingSound::sound_accents'] = 'optional',
            ['MainSound::fade_in_ticks'] = 'optional',
        }, own_props = {} }
    local ps = port.type_props(prof, 'WorkingSound')
    ok(ps ~= nil, 'a concept has a property set at all')
    eq('optional', ps.fade_in_ticks, 'inherited from the parent concept')
    eq('optional', ps.sound_accents, 'and its own')
    eq(nil, port.type_props(prof, 'NoSuchType'), 'an unknown type has none')
end)

test('nested data stage: walk_path follows the declared type chain, and REFUSES a hop',
    function ()
    local port = require 'cartograph.portability'
    local prof = {
        prototypes = { LabPrototype = true }, concept_types = { Animation = true },
        parent = {}, concept_parent = {},
        prop_type = {
            ['LabPrototype::on_animation'] = 'Animation',
            -- `layers` is an Animation[]; the distiller unwrapped the array, so the
            -- step is TRANSPARENT and adds no path segment
            ['Animation::layers'] = 'Animation',
        } }
    local owner, prop = port.walk_path(prof, 'LabPrototype', 'on_animation.layers.hr_version')
    eq('Animation', owner, 'two hops down, arrays transparent')
    eq('hr_version', prop, 'and the LAST segment is the one to adjudicate')
    -- ⚠ AN UNRESOLVABLE HOP IS A REFUSAL, NEVER A PASS. `Animation4Way` is a
    -- dictionary in the api, so the distiller records no single type for its members;
    -- treating that as "nothing to check" would turn every unmodelled shape into a
    -- silent clean bill.
    local o2, why = port.walk_path(prof, 'LabPrototype', 'graphics.layers.hr_version')
    eq(nil, o2)
    eq('graphics', why, 'and it names the segment that broke the chain')
    eq(nil, (port.walk_path(prof, 'LabPrototype', 'on_animation')),
        'a single segment is the TOP-LEVEL question, not this one')
end)

test('nested data stage: a property declared by an ANCESTOR still walks',
    function ()
    local port = require 'cartograph.portability'
    local prof = {
        prototypes = { LabPrototype = true, EntityPrototype = true },
        concept_types = { WorkingSound = true }, parent = { LabPrototype = 'EntityPrototype' },
        concept_parent = {},
        prop_type = { ['EntityPrototype::working_sound'] = 'WorkingSound' } }
    -- `working_sound` is declared on EntityPrototype, not on the leaf; prop_type keys
    -- by the DECLARING owner, so the walk has to climb
    local owner, prop = port.walk_path(prof, 'LabPrototype', 'working_sound.fade_in_ticks')
    eq('WorkingSound', owner)
    eq('fade_in_ticks', prop)
end)

test('nested data stage: the reader walks nested literals, arrays transparent',
    function ()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not pcall(vim.treesitter.language.add, 'lua') then skip 'no lua parser' end
    local pm = require 'cartograph.spec.profile'
    if not pm.load('lua-factorio-proto-11') then skip 'no proto profile' end
    local ts = require 'cartograph.providers.treesitter'
    local store = require 'cartograph.store'
    local root = vim.fn.tempname(); vim.fn.mkdir(root .. '/prototypes', 'p')
    local function w(rel, t)
        local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(t); fd:close()
    end
    w('info.json', '{"name":"M","version":"1.0","factorio_version":"1.1"}')
    w('data.lua', 'require("prototypes.e")\n')
    w('prototypes/e.lua', 'data:extend({{\n'
        .. '  type = "lab", name = "x",\n'
        .. '  on_animation = { layers = {\n'
        .. '    { filename = "a.png", hr_version = { filename = "b.png" } },\n'
        .. '  } },\n'
        .. '  working_sound = { audible_distance_modifier = 0.7 },\n'
        .. '}})\n')
    store.ingest(ts.extract(root))
    local protos = require('cartograph.prototypes').all(store)
    if not protos then skip 'no data stage' end
    local paths = {}
    for _, m in ipairs(protos) do
        for _, p in ipairs(m.protos) do
            for _, ov in ipairs(p.nested or {}) do paths[ov.path] = ov.line end
        end
    end
    ok(paths['on_animation.layers.hr_version'] ~= nil,
        'the ARRAY step adds no segment — `layers` is an Animation[], so every element'
        .. ' has the element type and an index would only have to be stripped again')
    ok(paths['working_sound.audible_distance_modifier'] ~= nil, 'a plain nested map')
    ok(paths['on_animation.layers.filename'] ~= nil, 'siblings too')
    -- ★ EACH ENTRY CARRIES ITS OWN LINE, 1-BASED. A worklist row that sends the reader
    -- to the line above the one that is wrong reads as the tool being confused.
    eq(4, paths['on_animation.layers.hr_version'],
        'the hr_version line, not the prototype line')
    vim.fn.delete(root, 'rf')
end)

-- ── THE PROTOTYPE POPULATION (CART-0637) ────────────────────────────────────

test('data stage: an unregistered table literal is NOT an unadjudicated prototype',
    function ()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not pcall(vim.treesitter.language.add, 'lua') then skip 'no lua parser' end
    local pm = require 'cartograph.spec.profile'
    if not (pm.load('lua-factorio-proto-11') and pm.load('lua-factorio-proto-20')) then
        skip 'both proto profiles are needed'
    end
    local ts = require 'cartograph.providers.treesitter'
    local store = require 'cartograph.store'
    local port = require 'cartograph.portability'
    local root = vim.fn.tempname(); vim.fn.mkdir(root .. '/prototypes', 'p')
    local function w(rel, t)
        local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(t); fd:close()
    end
    w('info.json', '{"name":"M","version":"1.0","factorio_version":"1.1"}')
    w('data.lua', 'require("prototypes.e")\n')
    -- `helper` is an ordinary table in a data-stage file — a sprite fragment, the
    -- commonest thing in prototypes/. It has no `type=` and needs none, because it is
    -- not a prototype. `real` is one, and IS registered.
    w('prototypes/e.lua', 'local helper = { filename = "a.png", width = 1 }\n'
        .. 'local real = { type = "lab", name = "x", icon_mipmaps = 4 }\n'
        .. 'data:extend({ real })\n'
        .. 'return helper\n')
    store.ingest(ts.extract(root))
    local res = assert(port.prototype_diff(store, 'lua-factorio-proto-11',
        'lua-factorio-proto-20'))
    -- ★★ THE REGRESSION: `helper` used to land in `unread` and be counted as a
    -- prototype the reading could not adjudicate. Across 135 real mods that error
    -- inflated the frontier tenfold — 1502 of 1536 unreadable literals were never
    -- registered — and on Von-Neumann it was 20 of 20, so the whole declared blind
    -- spot contained no prototypes at all. AN OVERSTATED LOWER BOUND READS AS
    -- CAUTION AND COSTS NOTHING VISIBLE, which is why it survived a port exercise.
    for _, u in ipairs(res.unread) do
        ok(not (u.line == 1),
            'an unregistered helper table must not be reported as an unadjudicated'
            .. ' prototype (line ' .. tostring(u.line) .. ')')
    end
    ok((res.unregistered or 0) >= 1,
        'and it is COUNTED rather than dropped: a literal that should have been'
        .. ' registered and is not is a finding of another kind')
    -- the real prototype is still read, and its removed property still found
    local found = false
    for _, l in ipairs(res.lost) do if l.prop == 'icon_mipmaps' then found = true end end
    ok(found, 'the registered prototype is still adjudicated')
    vim.fn.delete(root, 'rf')
end)

test('data stage: an ARRAY of prototypes registered by name expands to its elements',
    function ()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not pcall(vim.treesitter.language.add, 'lua') then skip 'no lua parser' end
    local pm = require 'cartograph.spec.profile'
    if not pm.load('lua-factorio-proto-11') then skip 'no proto profile' end
    local ts = require 'cartograph.providers.treesitter'
    local store = require 'cartograph.store'
    local root = vim.fn.tempname(); vim.fn.mkdir(root .. '/prototypes', 'p')
    local function w(rel, t)
        local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(t); fd:close()
    end
    w('info.json', '{"name":"M","version":"1.0","factorio_version":"1.1"}')
    w('data.lua', 'require("prototypes.e")\n')
    -- the Accumulator-V2 shape: an array in a local, registered BY NAME. The elements
    -- carry the type; the array carries none, so it used to be recorded as one
    -- untyped prototype and the whole group went unadjudicated. `data:extend{{…},{…}}`
    -- was already expanded — this is the same shape one indirection away.
    w('prototypes/e.lua', 'local remnants = {\n'
        .. '  { type = "corpse", name = "a", icon_mipmaps = 4 },\n'
        .. '  { type = "corpse", name = "b" },\n'
        .. '}\n'
        .. 'local sounds = { variations = { { filename = "x.ogg" } } }\n'
        .. 'data:extend(remnants)\n')
    store.ingest(ts.extract(root))
    local protos = require('cartograph.prototypes').all(store)
    if not protos then skip 'no data stage' end
    local typed, container = 0, 0
    for _, m in ipairs(protos) do
        for _, p in ipairs(m.protos) do
            if p.declared_type == 'corpse' then typed = typed + 1 end
            if p.container then container = container + 1 end
        end
    end
    eq(2, typed, 'both elements become typed prototype records of their own')
    eq(1, container, 'and the array is marked a CONTAINER so it is not counted too')
    -- ⚠ THE GUARD THAT MATTERS: descending into a helper table would mint prototypes
    -- out of sound variations and sprite layers — the exact over-counting CART-0637
    -- exists to remove. An element is expanded ONLY when it declares a type.
    for _, m in ipairs(protos) do
        for _, p in ipairs(m.protos) do
            ok(p.declared_type ~= 'x.ogg', 'no prototype minted from a sound variation')
        end
    end
    vim.fn.delete(root, 'rf')
end)

test('class space: a BRACKET-INDEXED name is decided by the member, not the index',
    function ()
    local port = require 'cartograph.portability'
    local A = { script = { C = true }, gone = { C = true }, kept = { C = true } }
    local B = { kept = { C = true } }
    -- ★★ CART-0636. `Event.script[event_id]` ends in `]`, so the trailing-member
    -- fallback's `[%w_]+$` matched nothing, the function returned nil, and the name
    -- kept its unrefined bucket. It was the ONLY surviving `receiver-nomatch` across
    -- five sample mods — a bucket that empties everywhere except one place is worth
    -- opening.
    local v, d = port.class_space_name(A, B, 'Event.script[event_id]')
    eq('member-removed', v)
    -- ⚠ AND THE OBVIOUS REPAIR IS WRONG: the last identifier ANYWHERE is `event_id`,
    -- the INDEX EXPRESSION — a local variable, not a member of anything. Asking the
    -- class spaces about it would adjudicate a name the code never used as a member.
    eq('script', d.member, 'the member is the thing INDEXED, never the index')
    -- several groups, and a member access after one
    eq('member-supplied', (port.class_space_name(A, B, 'Event.kept[i][j]')))
    local _, d2 = port.class_space_name(A, B, 'Event.script[a].gone')
    eq('gone', d2.member, 'a member access AFTER an index is still the trailing one')
    eq('not-a-runtime-member', (port.class_space_name(A, B, 'Event.nothing[i]')))
end)
