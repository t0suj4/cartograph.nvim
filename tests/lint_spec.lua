-- Unit tests for the graph-aware lint rules.

local store = require 'cartograph.store'
local lint  = require 'cartograph.lint'

local R0 = { start = { line = 0, char = 0 }, ['end'] = { line = 0, char = 0 } }
local function mod(file, effects) return { id = file, name = file, kind = 'module', file = file, range = R0, order = 0, effects = effects } end
local function fn(file, name, kind) return { id = file .. '::' .. name, name = name, kind = kind or 'function', file = file, range = R0, order = 0 } end
local function ref(a, b) return { from = a, to = b, kind = 'ref', at = {} } end
local function import(from, to, se) return { from = from, to = to, kind = 'import', sideeffect = se } end
local function graph(nodes, edges) store.ingest({ schema = 1, root = '/x', nodes = nodes, edges = edges or {} }) end

local function only(name) return { only = { [name] = true } } end
local function messages(findings) local m = {} for _, f in ipairs(findings) do m[#m + 1] = f.message end return m end

test('lint: a local function with no callers is flagged dead', function ()
    -- M.run is an exported entry point (no static caller, but public); it calls
    -- `used`; `orphan` is a local nobody calls.
    graph({ mod('m.lua'), fn('m.lua', 'orphan'), fn('m.lua', 'M.run'), fn('m.lua', 'used') },
          { ref('m.lua::M.run', 'm.lua::used') })
    local f = lint.run(store, only('dead-function'))
    local names = table.concat(messages(f), '\n')
    ok(names:match("'orphan'"), 'orphan flagged')
    ok(not names:match("'used'"), 'used (has a caller) not flagged')
    ok(not names:match("M%.run"), 'exported entry point not flagged')
end)

test('lint: an exported no-caller function is NOT flagged (public surface)', function ()
    graph({ mod('m.lua'), fn('m.lua', 'M.api'), fn('m.lua', 'mt:method', 'method') }, {})
    local f = lint.run(store, only('dead-function'))
    eq(0, #f)
end)

test('lint: a metamethod is NOT flagged (dispatched via metatable, never by name)', function ()
    graph({ mod('m.lua'), fn('m.lua', '__index'), fn('m.lua', 'mt:__newindex', 'method') }, {})
    eq(0, #lint.run(store, only('dead-function')))
end)

test('lint: a redundant require (pure module, discarded) is flagged', function ()
    graph({ mod('pure.lua', false), fn('pure.lua', 'f') },
          { import('caller.lua', 'pure.lua', true) })  -- discarded require of a pure module
    local f = lint.run(store, only('redundant-require'))
    eq(1, #f)
    ok(f[1].message:match('redundant'), f[1].message)
end)

test('lint: a side-effecting module required for effect is NOT redundant', function ()
    graph({ mod('patch.lua', true), fn('patch.lua', 'f') },
          { import('caller.lua', 'patch.lua', true) })
    eq(0, #lint.run(store, only('redundant-require')))
end)

test('lint: mutual recursion is a call cycle; plain recursion is not', function ()
    graph({ mod('m.lua'), fn('m.lua', 'a'), fn('m.lua', 'b'), fn('m.lua', 'r') },
          { ref('m.lua::a', 'm.lua::b'), ref('m.lua::b', 'm.lua::a'),
            ref('m.lua::r', 'm.lua::r') })  -- r calls itself
    local f = lint.run(store, only('call-cycle'))
    eq(1, #f)                                   -- only the a<->b cycle
    ok(f[1].message:match('a <%-> b'), f[1].message)
end)

test('lint: silent-drop flags a bare call to a local callable, neither resolved nor refused', function ()
    -- run(handler): `handler` is a param (a local callable). Three call sites:
    --  1. handler()     — unresolved + NOT refused → the silent honesty gap
    --  2. external_fn() — a FREE name (not a local) resolving to nil → honest external, NOT flagged
    --  3. handler()     — but honestly REFUSED → not silent, NOT flagged
    local caller = fn('m.lua', 'run'); caller.params = { 'handler' }
    store.ingest({ schema = 1, root = '/x', nodes = { mod('m.lua'), caller }, edges = {},
        calls = {
            { callee = 'handler', fn = 'm.lua::run', file = 'm.lua', at = R0 },
            { callee = 'external_fn', fn = 'm.lua::run', file = 'm.lua', at = R0 },
            { callee = 'handler', fn = 'm.lua::run', file = 'm.lua', at = R0, refused = { rule = 'ambiguous' } },
        } })
    local f = lint.run(store, only('silent-drop'))
    eq(1, #f) -- only the silent handler() (deduped per (fn,local); external + refused excluded)
    ok(f[1].message:match("'handler'"), f[1].message)
    ok(f[1].message:match('silent honesty gap'), f[1].message)
end)

test('lint: silent-drop ignores resolved, dynamic, and qualified calls', function ()
    local caller = fn('m.lua', 'run'); caller.params = { 'handler', 'obj' }
    store.ingest({ schema = 1, root = '/x', nodes = { mod('m.lua'), caller }, edges = {},
        calls = {
            { callee = 'handler', fn = 'm.lua::run', file = 'm.lua', at = R0, to = 'm.lua::run' }, -- resolved
            { callee = 'handler', fn = 'm.lua::run', file = 'm.lua', at = R0, dynamic = true },    -- dynamic frontier
            { callee = 'method', full = 'obj.method', fn = 'm.lua::run', file = 'm.lua', at = R0 }, -- qualified (receiver-typing, not this rule)
        } })
    eq(0, #lint.run(store, only('silent-drop')))
end)

test('lint: silent-drop gates on unbound-ness, not length — a SHORT bound name is flagged', function ()
    -- `go` is a 2-char PARAM (a local callable); a silent bare call to it is a
    -- gap the same as any longer name. The old `#callee >= 3` guard hid this —
    -- the resolver's honesty pass now resolves/refuses these regardless of
    -- length, so a residual short silent drop is a real regression.
    local caller = fn('m.lua', 'run'); caller.params = { 'go' }
    store.ingest({ schema = 1, root = '/x', nodes = { mod('m.lua'), caller }, edges = {},
        calls = {
            { callee = 'go', fn = 'm.lua::run', file = 'm.lua', at = R0 }, -- short + bound + silent = a gap
        } })
    local f = lint.run(store, only('silent-drop'))
    eq(1, #f)
    ok(f[1].message:match("'go'"), f[1].message)
end)

test('ladder: narrowable-refusal classifies receivers and ranks the work-list', function ()
    local ladder = require 'cartograph.ladder'
    local caller = fn('u.lua', 'run'); caller.params = { 'obj' }
    local amb = { rule = 'ambiguous', n = 2, cands = { 'a.lua::M.x', 'b.lua::M.x' } }
    store.ingest({ schema = 1, root = '/x',
        nodes = { mod('u.lua'), caller, fn('a.lua', 'M.x'), fn('b.lua', 'M.x') },
        edges = { { from = 'u.lua', to = 'mod.lua', kind = 'import', bind = 'm' } },
        calls = {
            { callee = 'get',  full = 'm.get',    fn = 'u.lua::run', file = 'u.lua', at = R0, refused = amb }, -- alias
            { callee = 'load', full = 'm.load',   fn = 'u.lua::run', file = 'u.lua', at = R0, refused = amb }, -- alias (2nd member)
            { callee = 'bar',  full = 'self.bar', fn = 'u.lua::run', file = 'u.lua', at = R0, refused = amb }, -- self
            { callee = 'baz',  full = 'obj.baz',  fn = 'u.lua::run', file = 'u.lua', at = R0, refused = amb }, -- local (obj = param)
            { callee = 'qux',  full = 'x.qux',    fn = 'u.lua::run', file = 'u.lua', at = R0, refused = amb }, -- unknown
        } })
    local nb = ladder.narrowable(store)
    local by = {}; for _, a in ipairs(nb) do by[a.class] = a end
    ok(by.alias and by.alias.recv == 'm' and by.alias.calls == 2 and by.alias.nmembers == 2,
        'require-alias receiver: 2 calls, 2 members')
    ok(by.self and by.self.recv == 'self', 'self receiver classed self')
    ok(by['local'] and by['local'].recv == 'obj', 'param receiver classed local')
    ok(by.unknown and by.unknown.recv == 'x', 'free receiver classed unknown')
    -- ranked by payoff = calls × narrowability (alias 2×4 > self 1×3 > local 1×2 > unknown 1×1)
    eq('alias', nb[1].class)
    ok(nb[1].score >= nb[#nb].score, 'sorted by descending score')
end)

-- resource-leak (manual-pair regime, [[cartograph-resource-pairing]]): a raw
-- `p = new T()` reassigned with no release leaks; a released/RAII one does not.
-- Integration test — real cpp extraction (flow def-positions + source scan).
local ts = require 'cartograph.providers.treesitter'
local function cpp_ready()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    return pcall(vim.treesitter.language.add, 'cpp')
end

test('lint resource-leak: a reassigned raw `new` with no drop leaks; released/RAII do not', function ()
    if not cpp_ready() then skip 'no cpp parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/leak.cpp', 'w'))
    fd:write(table.concat({
        'void bug() {',                       -- L1
        '    Mesh *m = new Mesh();',           -- L2 acquire
        '    m = transform(m);',               -- L3 reassign, NO release -> LEAK
        '    use(m);',                         -- L4
        '}',
        'void released() {',                   -- L6
        '    Mesh *m = new Mesh();',           -- L7 acquire
        '    m->drop();',                      -- L8 released
        '    m = transform(m);',               -- L9 reassign after release -> no leak
        '}',
        'void raii() {',                       -- L11
        '    std::unique_ptr<Mesh> p = make();', -- L12 no raw new
        '    p = transform(p);',               -- L13 reassign -> no leak (RAII)
        '}',
    }, '\n'))
    fd:close()
    store.ingest(ts.extract(root))
    local f = lint.run(store, only('resource-leak'))
    local msg = table.concat(messages(f), '\n')
    eq(1, #f)
    ok(msg:match("'m'") and msg:match('line 2'), 'the bug()-fn leak is flagged (acquired L2)')
    ok(not msg:match('line 7'), 'the released `new` (L7, drop before reassign) is NOT flagged')
    ok(not msg:match("'p'"), 'the RAII unique_ptr reassign is NOT flagged')
    vim.fn.delete(root, 'rf')
end)

test('lint null-deref: an unguarded nullable deref flags; guards/param/new do not', function ()
    if not cpp_ready() then skip 'no cpp parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/nd.cpp', 'w'))
    fd:write(table.concat({
        'void bug() {',
        '    Mesh *m = getThingNoEx();',   -- nullable, unguarded -> FLAG (line 3)
        '    m->use();',
        '}',
        'void guarded_if() {',
        '    Mesh *m = getThingNoEx();',
        '    if (m) m->use();',            -- guarded
        '}',
        'void guarded_early() {',
        '    Mesh *m = getThingNoEx();',
        '    if (!m) return;',             -- early-exit (braceless)
        '    m->use();',
        '}',
        'void guarded_assert() {',
        '    Mesh *m = getThingNoEx();',
        '    assert(m != NULL);',          -- assert-narrowed
        '    m->use();',
        '}',
        'void param(Mesh *m) {',
        '    m->use();',                   -- param: no nullable-return def
        '}',
        'void newed() {',
        '    Mesh *m = new Mesh();',       -- non-nullable source
        '    m->use();',
        '}',
    }, '\n'))
    fd:close()
    store.ingest(ts.extract(root))
    local f = lint.run(store, only('null-deref'))
    eq(1, #f)
    ok(f[1].message:match("'m'") and f[1].line == 3, 'only the unguarded nullable deref in bug() flags')
    vim.fn.delete(root, 'rf')
end)
