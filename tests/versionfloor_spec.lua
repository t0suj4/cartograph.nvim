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
    -- whitespace-tolerant: the version column widened for 4-digit ES years, and
    -- pinning the exact padding made this fail on a pure formatting change
    ok(text:find('to 3%.0%s+fix 1 site'), 'to 3.0 costs the single 3.1 site')
    ok(text:find('to 2%.7%s+fix 4 site'), 'to 2.7 also costs the three 3.0 sites')
    ok(text:find('to 2%.3%s+fix 5 site'), 'to 2.3 adds the 2.7 site')
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

-- ── PYTHON: the second language table ──────────────────────────────────────
-- The mechanism generalised for free (tables keyed by language, extensions read
-- off the spec), so what needs asserting is the same thing as for ruby: that no
-- entry is silently dead, and that a lookalike is not counted.

local PY_SNIPPETS = {
    ['yield-from']      = 'def g():\n    yield from h()',
    ['await']           = 'async def f():\n    await g()',
    ['literal-unpack']  = 'a = [*b, *c]',
    ['fstring']         = 'x = f"hi {name}"',
    ['var-annotation']  = 'x: int = 1',
    ['walrus']          = 'if (n := f()):\n    pass',
    ['positional-only'] = 'def f(a, /, b):\n    pass',
    ['match-statement'] = 'match x:\n    case 1:\n        pass',
    ['union-type']      = 'def f(a: int | str):\n    pass',
    ['except-star']     = 'try:\n    pass\nexcept* TypeError:\n    pass',
    ['type-parameter']  = 'def f[T](x: T) -> T:\n    return x',
}

local function py_ready()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    return pcall(vim.treesitter.get_string_parser, '', 'python')
end

test('versionfloor: EVERY python table entry fires on its own snippet', function ()
    if not py_ready() then skip('no python parser') end
    local missing = {}
    for _, f in ipairs(vf.FEATURES.python) do
        local snip = PY_SNIPPETS[f.id]
        if not snip then
            missing[#missing + 1] = f.id .. ' (no snippet in this spec)'
        elseif not ids(vf.scan('python', snip))[f.id] then
            missing[#missing + 1] = f.id .. ' (detector never fired)'
        end
    end
    eq({}, missing, 'a python detector with a wrong node type fires never, silently')
end)

test('versionfloor: f(*args) is NOT literal unpacking (the 3.5 false positive)', function ()
    if not py_ready() then skip('no python parser') end
    -- both are `list_splat`; only the one inside a LITERAL is PEP 448
    eq(false, ids(vf.scan('python', 'f(*args)\n'))['literal-unpack'] or false,
        'call unpacking is ancient and must not raise the floor to 3.5')
    eq(true, ids(vf.scan('python', 'a = [*b]\n'))['literal-unpack'] or false,
        'literal unpacking still counts')
end)

test('versionfloor: a plain string is not an f-string', function ()
    if not py_ready() then skip('no python parser') end
    eq(0, #vf.scan('python', 'x = "hi {name}"\n'), 'braces in a plain string are just braces')
end)

-- ── the stdlib tables must stay REACHABLE ──────────────────────────────────
test('versionfloor: every STDLIB and REMOVED key is reachable through gate_for', function ()
    local dead = {}
    local tables = { STDLIB = vf.STDLIB, REMOVED = vf.REMOVED }
    for which, byLang in pairs(tables) do
    for lang, tbl in pairs(byLang) do
        for key in pairs(tbl) do
            -- a dotted key is only ever reachable via the QUALIFIED form, which
            -- the extractor puts in `full` — proven by measurement, since every
            -- dotted key was silently dead while only `callee` was consulted
            local probe = key:find('%.') and key or ('recv.' .. key)
            local hit, matched = vf.gate_for(lang, probe, byLang)
            if not hit or matched ~= key then
                dead[#dead + 1] = which .. ' ' .. lang .. ':' .. key
            end
        end
    end
    end
    eq({}, dead, 'a key no call form can ever match would sit in the table dead')
end)

test('versionfloor: gate_for does not match a bare tail against a dotted key', function ()
    -- `Data.define` must NOT fire for every project `define` call
    eq(nil, vf.gate_for('ruby', 'thing.define'), 'a dotted gate needs its full callee')
    ok(vf.gate_for('ruby', 'Data.define'), 'and fires on it')
    ok(vf.gate_for('ruby', 'h.except'), 'a bare gate matches on the tail')
end)

-- ── the JS family: ONE table, two grammars, the ECMAScript scale ───────────
-- The interesting risk here is not the features, it is that javascript and
-- typescript are DIFFERENT grammars sharing one table: a private class member is
-- `field_definition` in one and `public_field_definition` in the other, so a
-- detector keyed on the field node would silently cover only half the family.

local JS_SNIPPETS = {
    ['arrow-function']    = 'const f = (x) => x',
    ['class']             = 'class A {}',
    ['template-string']   = 'const s = `hi ${n}`',
    ['exponent']          = 'const y = 2 ** 8',
    ['await']             = 'async function f() { await g() }',
    ['object-spread']     = 'const o = { ...a, b: 1 }',
    ['optional-catch']    = 'try { f() } catch { g() }',
    ['optional-chain']    = 'const v = a?.b',
    ['nullish']           = 'const v = a ?? b',
    ['logical-assign']    = 'a ??= 1',
    ['numeric-separator'] = 'const n = 1_000_000',
    ['private-field']     = 'class A { #x = 1 }',
    ['static-block']      = 'class A { static { this.x = 1 } }',
}

local function js_ready(lang)
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    return pcall(vim.treesitter.get_string_parser, '', lang)
end

test('versionfloor: the ES table fires under BOTH the js and ts grammars', function ()
    for _, lang in ipairs({ 'javascript', 'typescript' }) do
        if not js_ready(lang) then skip('no ' .. lang .. ' parser') end
        local missing = {}
        for _, f in ipairs(vf.FEATURES[lang]) do
            local snip = JS_SNIPPETS[f.id]
            if not snip then
                missing[#missing + 1] = f.id .. ' (no snippet)'
            elseif not ids(vf.scan(lang, snip))[f.id] then
                missing[#missing + 1] = f.id .. ' (never fired under ' .. lang .. ')'
            end
        end
        eq({}, missing, 'every ES entry must fire under ' .. lang)
    end
end)

test('versionfloor: the js family shares one table object', function ()
    ok(vf.FEATURES.javascript == vf.FEATURES.typescript
        and vf.FEATURES.typescript == vf.FEATURES.tsx,
        'one table serves .js/.mjs/.cjs/.jsx/.ts/.tsx — no drift between them')
    eq('ECMAScript', vf.SCALE.javascript, 'and the scale is named, so 2021 is not read as a version')
end)

test('versionfloor: ES detectors reject the near-misses', function ()
    if not js_ready('javascript') then skip('no javascript parser') end
    eq(false, ids(vf.scan('javascript', 'try { f() } catch (e) { g() }'))['optional-catch'] or false,
        'catch WITH a binding is not the 2019 feature')
    eq(false, ids(vf.scan('javascript', 'const n = 1000'))['numeric-separator'] or false,
        'a plain number has no separator')
    eq(0, #vf.scan('javascript', 'const s = "a?.b ?? c"'),
        'operators inside a string are text, not syntax')
end)

test('versionfloor: the ECMAScript scale is named in the report header', function ()
    if not js_ready('javascript') then skip('no javascript parser') end
    local ts = require 'cartograph.providers.treesitter'
    local store = require 'cartograph.store'
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    write(root, 'a.js', { 'export const f = (a) => a?.b ?? 0' })
    local data = ts.extract(root); data.root = root
    store.ingest(data)
    local text = table.concat(vf.report(store), '\n')
    ok(text:find('ECMAScript 2020', 1, true),
        'the header names the scale: ' .. text:sub(1, 70))
    vim.fn.delete(root, 'rf')
end)

-- ── DECLARED vs COMPUTED: the project's own artifact as an answer key ───────
-- The two directions are NOT symmetric and that is the design: computed-newer is
-- a defect backed by positive evidence, computed-older is only an absence of
-- evidence. Formats below are copied from real files on disk, not invented.

local function decl_root(files)
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    for name, lines in pairs(files) do write(root, name, lines) end
    return root
end

test('versionfloor: declarations() reads each ecosystem\'s real format', function ()
    local root = decl_root {
        ['x.gemspec'] = { 'Gem::Specification.new do |s|',
            '  s.required_ruby_version = ">= 3.0"', 'end' },
        ['pyproject.toml'] = { '[project]', 'requires-python = ">=3.8"' },
        ['tsconfig.json'] = { '{ "compilerOptions": { "target": "ES2022" } }' },
    }
    local ds = {}
    for _, d in ipairs(vf.declarations(root)) do ds[d.scale] = d end
    eq('3.0', ds.ruby.v, 'gemspec required_ruby_version')
    eq('3.8', ds.python.v, 'pyproject requires-python')
    eq('2022', ds.ECMAScript.v, 'a tsconfig target IS the ECMAScript scale')
    eq('ruby', ds.ruby.scale, 'each declaration knows which ruler it speaks')
    vim.fn.delete(root, 'rf')
end)

test('versionfloor: a Gemfile ruby directive is the fallback declaration', function ()
    local root = decl_root { ['Gemfile'] = { 'source "https://rubygems.org"', 'ruby "~> 3.4"' } }
    local d = vf.declared(root, 'ruby')
    eq('3.4', d.v, 'the pessimistic operator still pins a floor')
    eq('Gemfile', d.source)
    vim.fn.delete(root, 'rf')
end)

test('versionfloor: an open-ended target is known-but-unusable, not absent', function ()
    local root = decl_root { ['tsconfig.json'] = { '{ "compilerOptions": { "target": "ESNext" } }' } }
    local d = vf.declared(root, 'ECMAScript')
    ok(d, 'the declaration is FOUND')
    eq(nil, d.v, 'but carries no comparable version')
    vim.fn.delete(root, 'rf')
end)

test('versionfloor: computed NEWER than declared is a broken promise', function ()
    if not ready() then skip('no ruby parser') end
    local ts = require 'cartograph.providers.treesitter'
    local store = require 'cartograph.store'
    local root = decl_root {
        ['x.gemspec'] = { 'Gem::Specification.new do |s|',
            '  s.required_ruby_version = ">= 2.6"', 'end' },
        ['lib.rb'] = { 'class A', '  def opts(x) = {x:}', 'end' },
    }
    local data = ts.extract(root); data.root = root
    store.ingest(data)
    local inv = vf.invariant(store, '3.1', { '{x:} at lib.rb:2' }, 'ruby')
    eq('broken', inv.verdict, 'declared 2.6, needs 3.1')
    local text = table.concat(vf.report(store), '\n')
    ok(text:find('BROKEN PROMISE', 1, true), 'and the report leads with it')
    ok(text:find('because of', 1, true), 'naming the responsible feature and site')
    vim.fn.delete(root, 'rf')
end)

test('versionfloor: computed OLDER than declared is NOT asserted as needless', function ()
    if not ready() then skip('no ruby parser') end
    local ts = require 'cartograph.providers.treesitter'
    local store = require 'cartograph.store'
    local root = decl_root {
        ['x.gemspec'] = { 'Gem::Specification.new do |s|',
            '  s.required_ruby_version = ">= 3.2"', 'end' },
        ['lib.rb'] = { 'class A', '  def old(a) a&.to_s end', 'end' },
    }
    local data = ts.extract(root); data.root = root
    store.ingest(data)
    local inv = vf.invariant(store, '2.3', {}, 'ruby')
    eq('no-evidence', inv.verdict, 'the verdict names the absence, not a defect')
    local text = table.concat(vf.report(store), '\n')
    ok(text:find('NOT a finding', 1, true),
        'because our floor is a lower bound, an undetected gate may justify it')
    vim.fn.delete(root, 'rf')
end)

test('versionfloor: scales are reported SEPARATELY, never maxed together', function ()
    if not ready() then skip('no ruby parser') end
    local ok_ts = pcall(vim.treesitter.get_string_parser, '', 'typescript')
    if not ok_ts then skip('no typescript parser') end
    local ts = require 'cartograph.providers.treesitter'
    local store = require 'cartograph.store'
    -- ruby 3.1 syntax and ES2020 syntax in one repo: 2020 > 3.1 numerically, so
    -- a single max() would report "floor 2020" for the ruby code too
    local root = decl_root {
        ['a.rb'] = { 'class A', '  def opts(x) = {x:}', 'end' },
        ['b.ts'] = { 'export const f = (a: any) => a?.b' },
    }
    local data = ts.extract(root); data.root = root
    store.ingest(data)
    local text = table.concat(vf.report(store), '\n')
    ok(text:find('2 version scales', 1, true), 'the split is announced: ' .. text:sub(1, 60))
    ok(text:find('version floor — ruby: 3%.1'), 'ruby keeps its own ruler')
    ok(text:find('ECMAScript 2020', 1, true), 'and the JS family keeps its own')
    vim.fn.delete(root, 'rf')
end)

-- ── the CEILING: what a NEWER version takes away ───────────────────────────
-- Floor answers "how old can I go"; this answers "how new breaks me", so the
-- version dimension is a RANGE. The hedges point opposite ways and both NARROW
-- the interval, which is the property worth pinning.

local function rb_store(src)
    local ts = require 'cartograph.providers.treesitter'
    local store = require 'cartograph.store'
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    write(root, 'a.rb', { src })
    local data = ts.extract(root); data.root = root
    store.ingest(data)
    return store, root
end

test('versionfloor: a removed name gives a ceiling and a supported range', function ()
    if not ready() then skip('no ruby parser') end
    local store, root = rb_store(
        'class A\n  def go(x) x&.to_s end\n  def t(o) o.taint end\nend')
    local facts = vf.removal_facts(store)
    eq(1, #facts, 'one removal found')
    eq('3.2', facts[1].v, 'Object#taint is gone in 3.2')
    eq('inferred', facts[1].tier, 'hedged, like every name match')
    local text = table.concat(vf.report(store), '\n')
    ok(text:find('CEILING 3.2', 1, true), 'the ceiling is named')
    ok(text:find('supported range: [2.3, 3.2)', 1, true),
        'and the floor plus ceiling make a RANGE: ' .. text:sub(1, 40))
    vim.fn.delete(root, 'rf')
end)

test('versionfloor: floor at or above ceiling means NO version works', function ()
    if not ready() then skip('no ruby parser') end
    -- 3.1 syntax and a name removed in 3.0 cannot both be satisfied
    local store, root = rb_store(
        'class A\n  def opts(x) = {x:}\n  def u(s) URI.escape(s) end\nend')
    local text = table.concat(vf.report(store), '\n')
    ok(text:find('NO VERSION WORKS', 1, true),
        'the contradiction is stated, not left for the reader to compute')
    ok(text:find('One of the two sites has to change', 1, true), 'with the way out')
    vim.fn.delete(root, 'rf')
end)

test('versionfloor: a dotted key matches the QUALIFIED form, not a bare tail', function ()
    if not ready() then skip('no ruby parser') end
    -- the extractor records callee as the TAIL and the qualified name in `full`,
    -- so URI.escape can only match via full — and CGI.escape must NOT match the
    -- entry written for URI.escape, though both have the tail `escape`
    local store, root = rb_store(
        'class A\n  def u(s) URI.escape(s) end\n  def ok(s) CGI.escape(s) end\nend')
    local descs = {}
    for _, f in ipairs(vf.removal_facts(store)) do descs[#descs + 1] = f.desc end
    eq(1, #descs, 'exactly one of the two escapes is a removal')
    ok(descs[1]:find('URI.escape', 1, true), 'and it is the URI one: ' .. descs[1])
    vim.fn.delete(root, 'rf')
end)

test('versionfloor: a scale with no ceiling table says so, and claims no bound', function ()
    local js = pcall(vim.treesitter.get_string_parser, '', 'javascript')
    if not js then skip('no javascript parser') end
    local ts = require 'cartograph.providers.treesitter'
    local store = require 'cartograph.store'
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    write(root, 'a.js', { 'export const f = (a) => a?.b' })
    local data = ts.extract(root); data.root = root
    store.ingest(data)
    local text = table.concat(vf.report(store), '\n')
    ok(text:find('no ceiling table for this scale', 1, true),
        'ECMAScript does not remove features, so no bound is computed')
    ok(text:find('not the same claim as "unbounded"', 1, true),
        'and the absence is not dressed up as an upper bound')
    vim.fn.delete(root, 'rf')
end)
