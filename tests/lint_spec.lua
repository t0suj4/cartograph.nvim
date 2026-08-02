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
        'void throwing() {',
        '    Mesh *m = getMeshNoCreate();',  -- throwing variant, not nullable
        '    m->use();',
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

test('lint member-leak: a member new`d and never freed flags; delete/drop elsewhere excludes', function ()
    if not cpp_ready() then skip 'no cpp parser' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/c.cpp', 'w'))
    fd:write(table.concat({
        'void A::init() {',
        '    m_leaked = new Thing();',    -- never freed -> FLAG (line 2)
        '    m_deleted = new Thing();',   -- freed by delete below
        '    m_dropped = new Ref();',     -- freed by drop below
        '}',
        'A::~A() {',
        '    delete m_deleted;',
        '    m_dropped->drop();',
        '}',
    }, '\n'))
    fd:close()
    store.ingest(ts.extract(root))
    local f = lint.run(store, only('member-leak'))
    local msg = table.concat(messages(f), '\n')
    eq(1, #f)
    ok(msg:match("'m_leaked'") and f[1].line == 2, 'only the never-freed member flags')
    ok(not msg:match('m_deleted') and not msg:match('m_dropped'), 'delete/drop members excluded')
    vim.fn.delete(root, 'rf')
end)


-- ── DISPOSITION TOTALITY (CART-0192/0225) ───────────────────────────────────
-- A ratchet makes a count AUTHORITATIVE, so a rule that never declared what its
-- findings claim would be pinned by accident. The user's design point — greenspun is
-- suggestive, and a user-supplied TEMPLATE is what makes it authoritative — lived
-- nowhere in the registry, which is how the plan to pin all ten classes came to look
-- harmless. This fence is what stops the distinction going unrecorded again.
test('lint: every rule DECLARES what its findings claim', function ()
    local lint = require 'cartograph.lint'
    local missing, bad = {}, {}
    for _, r in ipairs(lint.rules) do
        if r.disposition == nil then missing[#missing + 1] = r.name
        elseif not lint.DISPOSITIONS[r.disposition] then
            bad[#bad + 1] = r.name .. '=' .. tostring(r.disposition)
        end
    end
    eq({}, missing, 'a new rule must decide: authoritative / suggestive / calibration'
        .. ' / annotation')
    eq({}, bad, 'and it must be one of the declared dispositions')
    ok(#lint.rules >= 25, 'sanity: the registry was actually read (' .. #lint.rules .. ')')
end)

test('lint: the AUTHORITATIVE set is small and positively justified', function ()
    -- The bar is positive justification, not absence of doubt. Mis-marking a proposal
    -- as authoritative fails builds for doing the right thing; mis-marking a defect
    -- rule as suggestive only loses a gate. Those costs are not symmetric, so this
    -- pins the set rather than letting it drift upward by habit.
    local lint = require 'cartograph.lint'
    local auth = {}
    for _, r in ipairs(lint.rules) do
        if r.disposition == 'authoritative' then auth[#auth + 1] = r.name end
    end
    table.sort(auth)
    -- dead-confined joined the set 2026-08-02 (CART-0249) and the justification is that its
    -- finding rests on three SOURCE facts, none of them a heuristic: the spec says the
    -- function is file-local (exported == false), the confinement walk says its name is never
    -- read in a value position in that file (escapes == false — which is precisely what a
    -- dispatch-table entry or a callback WOULD be), and no refused call in the file could name
    -- it. With those three, "no callers" is not a guess. MEASURED before promoting: 0 on lua/
    -- (so this fence stays green), 12 on the whole repo, 11 on factorio, 0 on desynced; and
    -- premise 3 is what makes it honest — without it the same-named nested `walk`/`visit`
    -- helper idiom produces 137 false positives out of 149.
    eq({ 'dead-confined', 'load-order', 'seam-guard', 'silent-drop', 'truncation' }, auth,
        'promoting a rule to authoritative is a DECISION — update this list with the'
        .. ' justification in the registry comment')
end)

test('dead-confined: provable only with all three premises', function ()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not pcall(vim.treesitter.get_string_parser, '', 'lua') then skip 'no lua parser' end
    local ts = require 'cartograph.providers.treesitter'
    local lint = require 'cartograph.lint'
    local store = require 'cartograph.store'
    -- CART-0249. Confinement turns "no callers" into a defect BY CONSTRUCTION for a
    -- file-local, because a dispatch-table entry or a callback IS a value position and that
    -- is what `escapes` records. Each file below isolates one premise.
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    local function put(p, s)
        local fd = assert(io.open(root .. '/' .. p, 'w')); fd:write(s); fd:close()
    end
    -- 1. DEAD: file-local, never a value, nothing calls it
    put('dead.lua', table.concat({
        'local M = {}',
        'local function unused_helper() return 1 end',
        'function M.work() return 2 end',
        'return M', '' }, '\n'))
    -- 2. NOT dead: never called BY NAME, but its value escapes into a table — the exact
    --    case that makes the plain no-callers test a proposal rather than a proof
    put('escapes.lua', table.concat({
        'local M = {}',
        'local function handler() return 1 end',
        'M.handlers = { onClick = handler }',
        'return M', '' }, '\n'))
    -- 3. NOT dead: two same-named nested helpers, so the call is refused as ambiguous and
    --    BOTH targets read as callerless. Without premise 3 this is a false positive — it
    --    was 137 of 149 on our own tree.
    put('ambig.lua', table.concat({
        'local M = {}',
        'function M.a()',
        '  local function walk(n) return n end',
        '  return walk(1)',
        'end',
        'function M.b()',
        '  local function walk(n) return n + 1 end',
        '  return walk(2)',
        'end',
        'return M', '' }, '\n'))
    -- 4. NOT dead: plainly called in its own file
    put('live.lua', table.concat({
        'local M = {}',
        'local function used() return 1 end',
        'function M.go() return used() end',
        'return M', '' }, '\n'))
    store.ingest(ts.extract(root))

    local hits = {}
    for _, f in ipairs(lint.run(store, { only = { ['dead-confined'] = true } })) do
        hits[f.file:gsub('^.*/', '')] = (hits[f.file:gsub('^.*/', '')] or 0) + 1
    end
    eq(1, hits['dead.lua'] or 0, 'the confined, uncalled local IS reported')
    eq(0, hits['escapes.lua'] or 0, 'a local whose value escapes into a table is NOT dead')
    eq(0, hits['ambig.lua'] or 0, 'a refusal-shadowed name is NOT claimed dead')
    eq(0, hits['live.lua'] or 0, 'a called local is not reported')

    -- and the suggestive rule must not double-report what the authoritative one proved
    local dsug = {}
    for _, f in ipairs(lint.run(store, { only = { ['dead-function'] = true } })) do
        dsug[f.file:gsub('^.*/', '')] = true
    end
    eq(nil, dsug['dead.lua'], 'one function, one disposition')
    vim.fn.delete(root, 'rf')
end)
