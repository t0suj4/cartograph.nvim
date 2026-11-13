-- The VERSION FLOOR (step one of the porting lever): the floor as an ATTRIBUTED
-- SET plus the downgrade ladder. What matters most here is not that it finds
-- features — it is that a wrong node type detects NOTHING silently, so every
-- table entry is asserted to fire on its own snippet, and that the floor never
-- overclaims.

local vf = require 'cartograph.versionfloor'

local function ready()
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

test('versionfloor: a plain except is NOT except* (CART-1089)', function ()
    if not py_ready() then skip('no python parser') end
    -- both are `except_clause` under the newer grammar; only the anonymous `*` tells them
    -- apart. RED IF: the detector keys on the node type alone and every except fires 3.11.
    eq(false, ids(vf.scan('python', 'try:\n    pass\nexcept TypeError:\n    pass\n'))
        ['except-star'] or false, 'a plain except clause must not raise the floor to 3.11')
    eq(false, ids(vf.scan('python', 'try:\n    pass\nexcept:\n    pass\n'))
        ['except-star'] or false, 'nor a bare except')
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

-- ── constant- and import-shaped removals (tree-detected) ───────────────────
-- The call gate cannot see these: Fixnum is a constant, $SAFE a global,
-- `import distutils` a statement. Node type + exact text, with the project's own
-- definitions excluded.

test('versionfloor: ruby constants and globals removed later are found', function ()
    if not ready() then skip('no ruby parser') end
    local store, root = rb_store(
        'class A\n  def go\n    x = Fixnum\n    r = Random::DEFAULT\n    $SAFE = 1\n  end\nend')
    local byid = {}
    for _, f in ipairs(vf.removed_syntax_facts(store)) do byid[f.id] = f end
    ok(byid['gone:Fixnum'], 'a constant')
    eq('3.2', byid['gone:Fixnum'].v, 'gone in 3.2')
    ok(byid['gone:Random::DEFAULT'], 'a scope resolution')
    ok(byid['gone:$SAFE'], 'a special global')
    eq('3.0', byid['gone:$SAFE'].v, '$SAFE stopped being special in 3.0')
    vim.fn.delete(root, 'rf')
end)

test('versionfloor: the project\'s OWN Fixnum is not the removed one', function ()
    if not ready() then skip('no ruby parser') end
    -- a class the project defines shows up as `Fixnum#method` in the graph, so
    -- the class head has to be recovered for this check to work at all
    local store, root = rb_store(
        'class Fixnum\n  def go; end\nend\nclass B\n  def use; Fixnum; end\nend')
    eq(0, #vf.removed_syntax_facts(store),
        'a project-defined constant is its own, never the removed builtin')
    vim.fn.delete(root, 'rf')
end)

test('versionfloor: python removed imports and ABC aliases', function ()
    local py = pcall(vim.treesitter.get_string_parser, '', 'python')
    if not py then skip('no python parser') end
    local ts = require 'cartograph.providers.treesitter'
    local store = require 'cartograph.store'
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    write(root, 'c.py', { 'import distutils', 'from distutils.core import setup',
        'import imp', 'def f(x):', '    return isinstance(x, collections.Mapping)' })
    local data = ts.extract(root); data.root = root
    store.ingest(data)
    local vs = {}
    for _, f in ipairs(vf.removed_syntax_facts(store)) do vs[f.id] = f.v end
    eq('3.12', vs['gone:distutils'], 'a removed module, via import AND from-import')
    eq('3.12', vs['gone:imp'], 'and another')
    eq('3.10', vs['gone:collections.Mapping'], 'an ABC alias moved to collections.abc')
    vim.fn.delete(root, 'rf')
end)

test('versionfloor: a module path matches at a DOT boundary only', function ()
    local py = pcall(vim.treesitter.get_string_parser, '', 'python')
    if not py then skip('no python parser') end
    local ts = require 'cartograph.providers.treesitter'
    local store = require 'cartograph.store'
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    -- distutils_helpers merely STARTS with the removed module's name
    write(root, 'd.py', { 'import distutils_helpers' })
    local data = ts.extract(root); data.root = root
    store.ingest(data)
    eq(0, #vf.removed_syntax_facts(store),
        'a longer identifier sharing the prefix is a different module')
    vim.fn.delete(root, 'rf')
end)

test('versionfloor: a tree-detected removal reaches the CEILING in the report', function ()
    if not ready() then skip('no ruby parser') end
    local store, root = rb_store('class A\n  def go(x) x&.to_s end\n  def c; Fixnum; end\nend')
    local text = table.concat(vf.report(store), '\n')
    ok(text:find('CEILING 3.2', 1, true), 'the constant sets the ceiling')
    ok(text:find('supported range: [2.3, 3.2)', 1, true), 'and closes the range')
    vim.fn.delete(root, 'rf')
end)

-- ── BEHAVIOUR CHANGES: a boundary INSIDE the range ─────────────────────────
-- A removal bounds the range; a change SPLITS it. So the fact is CONDITIONAL: it
-- only matters when the supported range straddles the boundary. Reporting these
-- unconditionally would be noise, and that conditionality is what these pin.

test('versionfloor: a change the range STRADDLES is a hazard', function ()
    if not ready() then skip('no ruby parser') end
    -- floor 2.3 (safe-nav), ceiling 3.2 (taint), change at 3.0 (&:sym)
    local store, root = rb_store('class A\n  def a(x) x&.to_s end\n'
        .. '  def b(l) l.map(&:upcase) end\n  def c(o) o.taint end\nend')
    local text = table.concat(vf.report(store), '\n')
    ok(text:find('BEHAVIOUR SPLITS INSIDE THE RANGE [2.3, 3.2)', 1, true),
        'the split is reported with the range it sits in')
    ok(text:find('Symbol#to_proc returns a lambda', 1, true), 'and the responsible construct')
    ok(text:find('either side of that', 1, true),
        'explaining that it is a split, not a bound')
    vim.fn.delete(root, 'rf')
end)

test('versionfloor: the SAME change behind the floor is NOT a hazard', function ()
    if not ready() then skip('no ruby parser') end
    -- identical &:sym use, but floor 3.1 means always on the new behaviour
    local store, root = rb_store('class A\n  def o(x) = {x:}\n'
        .. '  def b(l) l.map(&:upcase) end\nend')
    local text = table.concat(vf.report(store), '\n')
    eq(nil, text:find('BEHAVIOUR SPLITS', 1, true),
        'no hazard: the range never reaches the old behaviour')
    ok(text:find('OUTSIDE the range', 1, true),
        'but the evidence is still disclosed rather than dropped')
    vim.fn.delete(root, 'rf')
end)

test('versionfloor: change_facts finds both call- and tree-shaped changes', function ()
    if not ready() then skip('no ruby parser') end
    local store, root = rb_store('class A\n  def g; Dir.glob("*.rb"); end\n'
        .. '  def b(l) l.map(&:upcase) end\n  def d(**o) foo(**o) end\nend')
    local ids = {}
    for _, f in ipairs(vf.change_facts(store)) do ids[f.id] = f end
    ok(ids['changed:Dir.glob'], 'a call-shaped change (Dir.glob ordering)')
    ok(ids['changed:symbol-to-proc'], 'a tree-shaped one via a test predicate')
    ok(ids['changed:kwargs-split'], 'and one matched on the node type alone')
    eq('3.0', ids['changed:kwargs-split'].v, 'the 2.7/3.0 keyword split')
    vim.fn.delete(root, 'rf')
end)

test('versionfloor: syntax_facts supports all four entry shapes', function ()
    if not ready() then skip('no ruby parser') end
    -- text / mod / test / bare-node — one scanner, or a new table shape silently
    -- matches nothing (which is how the change table first came up empty)
    local shapes = { text = false, mod = false, test = false, bare = false }
    for _, e in ipairs(vf.REMOVED_SYNTAX.ruby) do
        if e.text then shapes.text = true end
    end
    for _, e in ipairs(vf.REMOVED_SYNTAX.python) do
        if e.mod then shapes.mod = true end
    end
    for _, e in ipairs(vf.CHANGED_SYNTAX.ruby) do
        if e.test then shapes.test = true end
        if not (e.text or e.mod or e.test) then shapes.bare = true end
    end
    eq({ text = true, mod = true, test = true, bare = true }, shapes,
        'every shape is actually in use, so the scanner cannot regress unnoticed')
end)

-- ── LUA (CART-0782): detectors authored, versions ASKED of the interpreters ───
-- The version of every Lua entry comes from spec/luafloor.lua, which tools/luafloor.lua distils by handing each
-- detector's snippets to lua5.1 / lua5.2 / lua5.4 / luajit. So the spec pins three things: each detector fires on its
-- own snippets, the near-misses do not (and the interpreters agree they are 5.1-clean), and the artifact is current.

local function lua_ready() return pcall(vim.treesitter.get_string_parser, '', 'lua') end

-- scan with EVERY detector live (an entry the artifact gives no version is not in FEATURES.lua, so its detector
-- would otherwise go untested)
local function scan_all(src)
    local saved = vf.FEATURES.lua
    local all = {}
    for _, f in ipairs(vf.LUA_SYNTAX) do
        all[#all + 1] = { id = f.id, v = '0', desc = f.desc, node = f.node, test = f.test }
    end
    vf.FEATURES.lua = all
    local got, why = vf.scan('lua', src)
    vf.FEATURES.lua = saved
    return got, why
end

test('versionfloor lua: EVERY detector fires on each of its own snippets (CART-0782)', function ()
    if not lua_ready() then skip('no lua parser') end
    local dead = {}
    for _, f in ipairs(vf.LUA_SYNTAX) do
        for _, s in ipairs(f.snippets) do
            if not ids(scan_all(s))[f.id] then dead[#dead + 1] = f.id .. ' on ' .. s end
        end
    end
    eq({}, dead, 'a detector whose node type or test is wrong detects nothing SILENTLY')
end)

-- each must stay silent; each is also asked of lua5.1, so "not a floor feature" is the interpreter's word too
local LUA_NEAR = {
    { 'local x = a ~= b', '~= is not bitwise xor' },
    { 'local x = -a', 'unary minus is not bitwise not' },
    { 'while true do break end', 'break as the last statement' },
    { 'while true do local x = 1 break; end', 'break; with its optional semicolon, last' },
    -- (a comment AFTER the last statement attaches outside the block; between break and its `;` it stays inside)
    { 'while true do break -- done\n; end', 'break, a comment, then its optional ;' },
    { '-' .. '-[[ a plain block comment ]]\nlocal x = 1', 'a long comment with no [[ inside' },
    { 'local x = 1; local y = 2;', 'a ; terminating a statement' },
    { 'local x = 1 -- set\n;', 'a ; terminating the statement before a comment' },
    { 'local s = [[ a ]]', 'a long string with no [[ inside' },
    { 'local s = "a // b & c"', 'operators inside a string' },
    { '-- a // b, local x <const>\nlocal y = 1', 'operators inside a comment' },
    { 'local s = [=[ [[ ]=]', '[[ inside a LEVEL-1 long string' },
    { '--[==[ [[ ]==]\nlocal x = 1', '[[ inside a level-2 long comment' },
    { 'local x = 0x1p4 + 0xFF', 'an unsigned hex exponent (5.1 reads it through strtod) and a plain hex' },
    { 'local x = 0xab + 0xbb', 'a hex numeral holding the digit b is no 0b binary literal (CART-2039)' },
    { 'local f = g(\n  1)', 'a ( on the callee\'s own line' },
    { 'local t = f\n{ 1 }', 'a table argument on the next line (only ( is ambiguous)' },
}

test('versionfloor lua: the near-misses do not fire (CART-0782)', function ()
    if not lua_ready() then skip('no lua parser') end
    for _, c in ipairs(LUA_NEAR) do
        local got, why = scan_all(c[1])
        ok(got, c[2] .. ': the snippet parses (' .. tostring(why) .. ')')
        eq(0, #got, c[2] .. ': ' .. c[1])
    end
end)

test('versionfloor lua: the near-misses ARE 5.1-clean, by lua5.1 itself (CART-0782)', function ()
    if vim.fn.executable('lua5.1') ~= 1 then skip('lua5.1 is not installed') end
    local COMPILE = 'local f, e = loadfile() if not f then io.stderr:write(tostring(e)) os.exit(1) end'
    for _, c in ipairs(LUA_NEAR) do
        local r = vim.system({ 'lua5.1', '-e', COMPILE }, { stdin = c[1] .. '\n', text = true }):wait()
        eq(0, r.code, c[2] .. ' — lua5.1 refused it: ' .. tostring(r.stderr))
    end
end)

test('versionfloor lua: the versions are the interpreters\' answers, LuaJIT kept apart (CART-0782)', function ()
    local D = require 'cartograph.spec.luafloor'
    local F = D.features
    for _, id in ipairs { 'goto', 'label', 'break-not-last', 'empty-statement', 'escape-z', 'hex-float',
        'nested-long-string', 'nested-long-comment', 'call-across-lines' } do
        eq('5.2', F[id] and F[id].v, id .. ': 5.1 refuses, 5.2 accepts')
        eq(true, F[id].exact, id .. ': and 5.2 was asked')
    end
    for _, id in ipairs { 'int-div', 'bit-and', 'bit-or', 'bit-xor', 'shift-left', 'shift-right', 'bit-not',
        'attrib-const', 'attrib-close' } do
        eq('5.3', F[id] and F[id].v, id .. ': the LOWEST it can need — 5.2 refuses, 5.4 accepts')
        eq(false, F[id].exact, id .. ': no 5.3 interpreter was asked, and the artifact says so')
    end
    -- LuaJIT is a sibling dialect: 5.2 syntax it takes, 5.2 syntax it refuses
    eq(true, F['goto'].luajit, 'LuaJIT accepts goto')
    eq(false, F['break-not-last'].luajit, 'LuaJIT refuses a mid-block break, as 5.1 does')
    eq(false, F['int-div'].luajit, 'LuaJIT refuses //')
    -- the one entry with no version, and why: loading is not its question, meaning is
    local feats, dropped, jitonly = vf.lua_features(D)
    eq({ ['escape-u'] = F['escape-u'].why }, dropped, 'only \\u{} goes without a version')
    ok(F['escape-u'].why:find('removal', 1, true), '5.1 accepts it, 5.2 refuses it: ' .. F['escape-u'].why)
    -- (LuaJIT's own numerals: every PUC interpreter refuses them, LuaJIT accepts — LuaJIT-only, CART-2039)
    local jo = {}
    for _, f in ipairs(jitonly) do jo[#jo + 1] = f.id end
    table.sort(jo)
    eq({ 'binary-literal', 'imaginary-literal', 'int64-literal' }, jo, 'the LuaJIT-only syntax, by the interpreters\' answers')
    eq(#vf.LUA_SYNTAX - 1 - #jitonly, #feats, 'every other detector is in the floor table')
    eq(#vf.LUA_SYNTAX, D.detectors, 'the artifact was distilled from this detector set')
end)

test('versionfloor lua: re-distilling reproduces the artifact (CART-0782)', function ()
    for _, b in ipairs { 'lua5.1', 'lua5.2', 'lua5.4', 'luajit' } do
        if vim.fn.executable(b) ~= 1 then skip(b .. ' is not installed: the artifact cannot be re-derived here') end
    end
    local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
    local r = vim.system({ vim.v.progpath, '--headless', '-u', 'NONE', '-l', root .. '/tools/luafloor.lua', '--check' },
        { text = true, cwd = root }):wait()
    eq(0, r.code, (r.stdout or '') .. (r.stderr or ''))
end)

test('versionfloor: a tree with an ERROR is UNKNOWN, its facts never read (CART-0782)', function ()
    if not lua_ready() then skip('no lua parser') end
    -- wow_addons' Carbonite.lua: an escape 5.2+ refuses turns the rest of the file into ERROR, and detectors fired
    -- on the debris. The same file without the error is read normally.
    local got, why = vf.scan('lua', 'local s = "a\\Hb"\nlocal t = {\nlocal x = 7 // 2')
    eq(nil, got, 'no facts from a misparse')
    ok(why and why:find('parse error', 1, true), 'and the reason says so: ' .. tostring(why))
    ok(ids(vf.scan('lua', 'local x = 7 // 2'))['int-div'], 'the clean file is read')
end)

test('versionfloor: a TypeScript ERROR is LOCAL, so the rest of the tree still counts (CART-0782)', function ()
    if not js_ready('typescript') then skip('no typescript parser') end
    -- arktype's `out T` variance annotation: the grammar errs on that one token, and 299 real facts (2021 among
    -- them) sit in 26 files like it — refusing the file, as Lua's tearing grammar needs, would lower a true floor
    local src = 'interface I<out T> { x: T }\nconst y = a ?? b\n'
    local okp, parser = pcall(vim.treesitter.get_string_parser, src, 'typescript')
    ok(okp and parser:parse()[1]:root():has_error(), 'the fixture really has an ERROR')
    ok(ids(vf.scan('typescript', src))['nullish'], 'and its ?? is still a 2020 fact')
    eq(nil, vf.ERROR_TEARS.typescript, 'typescript is not a tearing grammar')
end)

test('versionfloor lua: the report names the PUC ruler, the guessed version and LuaJIT (CART-0782)', function ()
    if not lua_ready() then skip('no lua parser') end
    local ts = require 'cartograph.providers.treesitter'
    local store = require 'cartograph.store'
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    write(root, 'a.lua', { 'local M = {}', 'function M.f(a) return a // 2 end', 'return M' })
    write(root, 'b.lua', { 'local M = {}', 'function M.g() goto done ::done:: end', 'return M' })
    local data = ts.extract(root); data.root = root
    store.ingest(data)
    local text = table.concat(vf.report(store), '\n')
    ok(text:find('version floor — lua: PUC-Lua 5.3', 1, true), 'the floor on the PUC ruler: ' .. text:sub(1, 80))
    ok(text:find('5.3 is the LOWEST version these can need: no 5.3 interpreter was asked', 1, true),
        'the inexact version is disclosed: ' .. text)
    ok(text:find('LuaJIT (a sibling dialect, not on this ruler) REFUSES 1 site(s) above, first // floor division at a.lua:2',
        1, true), 'LuaJIT is answered beside the ruler, not on it: ' .. text)
    ok(text:find('removals are not modelled', 1, true), 'no ceiling table, said plainly')
    ok(not text:find('ECMAScript does not remove', 1, true), 'and not ECMAScript\'s sentence')
    vim.fn.delete(root, 'rf')
end)

-- ★ THE LuaJIT COLUMN AND THE DECLARED SIDE (CART-2039): LuaJIT's own numerals (1LL, 1ULL, 1i, 0b101) no PUC version
-- accepts were reported nowhere; and the project's declared dialect (luadialect.resolve: .luarc, .luacheckrc, a Neovim
-- plugin's layout) was never the answer key. LuaJIT-only syntax is listed BESIDE the PUC floor, never on it; a LuaJIT
-- declaration is checked against the LuaJIT column, a PUC one against the floor and against LuaJIT-only syntax
test('versionfloor lua: LuaJIT-only syntax is reported beside the floor, and the declared dialect is checked (CART-2039)', function ()
    if not lua_ready() then skip('no lua parser') end
    local ts = require 'cartograph.providers.treesitter'
    local store = require 'cartograph.store'
    local function report(files)
        local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
        for name, lines in pairs(files) do vim.fn.mkdir(vim.fn.fnamemodify(root .. '/' .. name, ':h'), 'p'); write(root, name, lines) end
        local data = ts.extract(root); data.root = root
        store.ingest(data)
        local facts, stats = vf.facts(store)
        local text = table.concat(vf.report(store), '\n')
        vim.fn.delete(root, 'rf')
        return text, facts, stats
    end
    local JIT = { 'local M = {}', 'function M.f() return 1LL + 0b101 end', 'return M' }
    -- no declaration: LuaJIT-only listed, kept off the floor and off the facts portability reads
    local t, facts, stats = report({ ['a.lua'] = JIT })
    eq(0, #facts, 'no PUC fact: LuaJIT-only syntax has no PUC version')
    eq(2, #stats.jitonly, 'both numerals found')
    ok(t:find('LuaJIT-ONLY syntax — no PUC Lua version accepts it, 2 site(s):', 1, true), t)
    ok(t:find('1LL / 1ULL 64-bit integer literal', 1, true) and t:find('0b101 binary literal', 1, true), t)
    -- a PUC declaration (.luarc.json: Lua 5.4) with LuaJIT-only syntax: a broken promise
    t = report({ ['a.lua'] = JIT, ['.luarc.json'] = { '{ "runtime.version": "Lua 5.4" }' } })
    ok(t:find('BROKEN PROMISE — .luarc.json declares Lua 5.4, but the code uses LuaJIT-only syntax, which Lua 5.4 refuses', 1, true), t)
    -- a LuaJIT declaration: checked against the LuaJIT column — // refused, goto accepted
    local LJ = { ['.luarc.json'] = { '{ "runtime.version": "LuaJIT" }' } }
    LJ['a.lua'] = { 'local M = {}', 'function M.f(a) return a // 2 end', 'return M' }
    t = report(LJ)
    ok(t:find('BROKEN PROMISE — .luarc.json declares LuaJIT, but LuaJIT refuses 1 site(s), first // floor division at a.lua:2', 1, true), t)
    ok(not t:find('open-ended', 1, true), 'a LuaJIT declaration is not "open-ended": ' .. t)
    LJ['a.lua'] = { 'local M = {}', 'function M.f() goto done ::done:: end', 'return M' }
    t = report(LJ)
    ok(t:find('✓ .luarc.json declares LuaJIT, and LuaJIT accepts every site found', 1, true), t)
    -- a PUC declaration the floor satisfies: the generic invariant, on the PUC ruler
    t = report({ ['a.lua'] = { 'local M = {}', 'function M.f() goto done ::done:: end', 'return M' },
        ['.luarc.json'] = { '{ "runtime.version": "Lua 5.4" }' } })
    ok(t:find('.luarc.json declares Lua 5.4; no detected feature needs past 5.2', 1, true), t)
end)
