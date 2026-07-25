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
