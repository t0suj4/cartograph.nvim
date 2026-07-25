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
