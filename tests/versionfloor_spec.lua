-- The VERSION FLOOR (step one of the porting lever): the floor as an ATTRIBUTED
-- SET plus the downgrade ladder. What matters most here is not that it finds
-- features — it is that a wrong node type detects NOTHING silently, so every
-- table entry is asserted to fire on its own snippet, and that the floor never
-- overclaims.

local vf = require 'cartograph.versionfloor'

local function ready()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    return pcall(vim.treesitter.get_string_parser, '', 'ruby')
end

-- one snippet per table entry: the guard against a silently dead detector
local SNIPPETS = {
    ['safe-navigation']  = 'x&.y',
    ['squiggly-heredoc'] = 's = <<~TXT\n  hi\nTXT\n',
    ['numbered-param']   = 'a.map { _1 }',
    ['arg-forwarding']   = 'def f(...)\n  g(...)\nend',
    ['beginless-range']  = 'a[..5]',
    ['pattern-match']    = 'case x\nin [a]\n  a\nend',
    ['endless-method']   = 'def f = 1',
    ['rightward-assign'] = 'expr => y',
    ['hash-shorthand']   = 'h = {x:}',
    ['anon-block-param'] = 'def f(&)\n  g(&)\nend',
}

local function ids(facts)
    local s = {}
    for _, f in ipairs(facts or {}) do s[f.id] = true end
    return s
end

test('versionfloor: EVERY ruby table entry fires on its own snippet', function ()
    if not ready() then skip('no ruby parser') end
    local missing = {}
    for _, f in ipairs(vf.FEATURES.ruby) do
        local snip = SNIPPETS[f.id]
        if not snip then
            missing[#missing + 1] = f.id .. ' (no snippet in this spec)'
        elseif not ids(vf.scan('ruby', snip))[f.id] then
            missing[#missing + 1] = f.id .. ' (detector never fired)'
        end
    end
    eq({}, missing, 'a feature whose node type is wrong detects nothing SILENTLY')
end)

test('versionfloor: a lookalike in a string or comment is NOT a feature use', function ()
    if not ready() then skip('no ruby parser') end
    -- the reason detection is over the tree: a regex would claim all three
    local facts = vf.scan('ruby', 's = "x&.y"\n# x&.y and {x:} here\nt = \'def f = 1\'\n')
    eq(0, #facts, 'text that merely looks like syntax is not syntax')
end)

test('versionfloor: an uncovered language says so instead of reporting clean', function ()
    local facts, why = vf.scan('cobol', 'MOVE X TO Y')
    eq(nil, facts, 'no facts')
    ok(why and why:find('no version-floor table', 1, true),
        'and the reason is the missing table, not "nothing found": ' .. tostring(why))
end)

test('versionfloor: older() orders dotted versions numerically', function ()
    ok(vf.older('2.7', '3.0'), '2.7 < 3.0')
    ok(vf.older('3.0', '3.1'), '3.0 < 3.1')
    ok(vf.older('2.9', '2.10'), '2.9 < 2.10 — numeric, not lexicographic')
    ok(not vf.older('3.1', '3.1'), 'equal is not older')
    ok(not vf.older('3.1', '2.3'), 'and it is not symmetric')
end)

test('versionfloor: the report gives floor, attribution and a priced ladder', function ()
    if not ready() then skip('no ruby parser') end
    local ts = require 'cartograph.providers.treesitter'
    local store = require 'cartograph.store'
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    -- 3.1 held by ONE site; 3.0 by three; 2.7 by one; 2.3 by one
    write(root, 'a.rb', { 'class A', '  def opts(x) = {x:}', '  def name = @n',
        '  def old(a) a&.to_s end', 'end' })
    write(root, 'b.rb', { 'class B', '  def run(x)', '    case x',
        '    in [a] then a', '    end', '  end', '  def fwd(...) run(...) end', 'end' })
    local data = ts.extract(root); data.root = root
    store.ingest(data)
    local text = table.concat(vf.report(store), '\n')
    ok(text:find('version floor — ruby: 3.1', 1, true), 'the floor: ' .. text:sub(1, 60))
    ok(text:find('LOWER bound', 1, true), 'it states the bound is a lower one')
    ok(text:find('never "runs on"', 1, true), 'and refuses the stronger reading')
    ok(text:find('held up by 1 site', 1, true), 'attribution: the floor is held by one site')
    ok(text:find('{x:} hash value shorthand', 1, true), 'the responsible FEATURE is named')
    ok(text:find('a.rb:2', 1, true), 'with its site')
    -- the ladder prices each older target by everything NEWER than it
    ok(text:find('to 3.0   fix 1 site', 1, true), 'to 3.0 costs the single 3.1 site')
    ok(text:find('to 2.7   fix 4 site', 1, true), 'to 2.7 also costs the three 3.0 sites')
    ok(text:find('to 2.3   fix 5 site', 1, true), 'to 2.3 adds the 2.7 site')
    vim.fn.delete(root, 'rf')
end)

test('versionfloor: a file it cannot read counts as UNKNOWN, not as clean', function ()
    if not ready() then skip('no ruby parser') end
    local store = require 'cartograph.store'
    local R0 = { start = { line = 0, char = 0 }, ['end'] = { line = 0, char = 0 } }
    -- a graph naming a .rb file that does not exist on disk
    store.ingest({ schema = 1, root = '/nonexistent-root', nodes = {
        { id = 'ghost.rb', name = 'ghost.rb', kind = 'module', file = 'ghost.rb',
          range = R0, order = 0 } }, edges = {}, calls = {} })
    local text = table.concat(vf.report(store), '\n')
    ok(text:find('UNKNOWN, not clean', 1, true),
        'an unreadable file is disclosed, never folded into a clean result: ' .. text)
end)

-- ── the stdlib tier: weaker evidence, kept apart from the certain floor ────
-- A stdlib name match cannot see its receiver's type, so it is evidence to
-- CHECK rather than work to do. The gate that keeps it sound is the graph's own
-- disposition: if the PROJECT defines the name, the call resolves there and is
-- not a stdlib use at all.

local function ruby_graph(files)
    local ts = require 'cartograph.providers.treesitter'
    local store = require 'cartograph.store'
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    for name, lines in pairs(files) do write(root, name, lines) end
    local data = ts.extract(root); data.root = root
    store.ingest(data)
    return store, root
end

test('versionfloor stdlib: an unresolved gated call is a HEDGED fact', function ()
    if not ready() then skip('no ruby parser') end
    local store, root = ruby_graph { ['a.rb'] = { 'class A', '  def c(e) e.tally end', 'end' } }
    local facts = vf.call_facts(store)
    eq(1, #facts, 'one gated call found')
    eq('2.7', facts[1].v, 'Enumerable#tally is 2.7')
    eq('inferred', facts[1].tier, 'and it is INFERRED, not certain')
    ok(facts[1].desc:find('~', 1, true), 'the description carries the hedge mark')
    vim.fn.delete(root, 'rf')
end)

test('versionfloor stdlib: a name the PROJECT defines is not a stdlib use', function ()
    if not ready() then skip('no ruby parser') end
    -- `except` is Hash#except (3.0) — but here the project defines it, so the
    -- call resolves to the project method and must NOT raise the floor
    local store, root = ruby_graph {
        ['b.rb'] = { 'class B', '  def except(k) k end', '  def use(o) o.except(:z) end', 'end' },
    }
    local hits = {}
    for _, f in ipairs(vf.call_facts(store)) do hits[#hits + 1] = f.desc end
    eq({}, hits, 'a project-defined name is attributed to the project, never to the stdlib')
    vim.fn.delete(root, 'rf')
end)

test('versionfloor stdlib: the hedged tier never enters the floor or the ladder', function ()
    if not ready() then skip('no ruby parser') end
    -- syntax says 2.3 (safe-nav); a stdlib match says 3.0. The FLOOR must stay
    -- 2.3 — folding a ~ into a fact is the failure this separation prevents.
    local store, root = ruby_graph {
        ['c.rb'] = { 'class C', '  def a(x) x&.to_s end', '  def b(h) h.except(:k) end', 'end' },
    }
    local text = table.concat(vf.report(store), '\n')
    ok(text:find('version floor — ruby: 2.3', 1, true),
        'the certain floor is syntax-only: ' .. text:sub(1, 70))
    ok(text:find('WOULD RAISE the floor to 3.0', 1, true),
        'the stronger possibility is surfaced, separately and conditionally')
    ok(text:find('UNDER%-reports'), 'and the tier discloses that it under-reports')
    vim.fn.delete(root, 'rf')
end)
