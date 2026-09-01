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
    -- annotation-mismatch joined 2026-08-03 (CART-0240). Justification: it is the one
    -- part of an annotation that is NOT a type claim — `---@param NAME` either names a
    -- parameter of the function it adheres to or it does not, which is a fact about
    -- names. Confirmed against an independent implementation: lua-language-server
    -- reports undefined-doc-param on every shape this rule reports, including a block
    -- separated from its def by a plain `--` comment (so its binding rule and our
    -- adhesion rule agree). MEASURED before promoting: 8 findings across 8 annotated
    -- roots, every one hand-read and real — 2 of them stranded docblocks in this repo,
    -- now fixed, so this fence stays green at 0.
    eq({ 'annotation-mismatch', 'dead-confined', 'load-order', 'seam-guard',
        'silent-drop', 'truncation' }, auth,
        'promoting a rule to authoritative is a DECISION — update this list with the'
        .. ' justification in the registry comment')
end)

test('annot: the type is ONE token, and the comment after it is not part of it', function ()
    local annot = require 'cartograph.annot'
    local P = '^%s*%-%-%-@([%a_]+)%s*(.*)$'
    local function parse(line)
        local tag, body = line:match(P)
        return annot.parse_body(annot.TAGS[tag or ''], body)
    end
    -- the two dialects spell the trailing comment differently and BOTH occur in the
    -- wild; "everything after the name" reads the type as `string @The input …`
    eq('string', parse('---@param char string @The input character.').type,
        'EmmyLua ends the type with @')
    eq('string', parse('---@param char string The input character.').type,
        'LuaLS ends it with nothing at all')
    -- whitespace INSIDE brackets belongs to the type
    eq('fun(key:string, value:V)', parse('---@param fn fun(key:string, value:V)').type)
    eq('table<integer, dap.bp>', parse('---@return table<integer, dap.bp>').type)
    -- …but an UNBALANCED bracket must not swallow the line
    eq('integer', parse('---@param n integer < 5').type, 'prose with a stray < ')
    -- `X|nil` is the other spelling of `X?`, and collapsing it is a spelling
    -- equivalence — NOT a licence to model unions
    local r = parse('---@return nio.lsp.types.ResponseError|nil')
    eq('nio.lsp.types.ResponseError', r.type)
    eq(true, r.opt, 'read as nullable')
    eq('A|B', parse('---@return A|B').type, 'a REAL union stays opaque')
    -- a multi-value tag keeps the first and says so, rather than inventing slots
    local m = parse('---@return function?, string? error_message')
    eq('function', m.type)
    eq(true, m.multi)
    eq(true, m.opt, 'the ? belongs to `function`, not to the comma')
    -- the visibility word precedes a field name
    eq('items', parse('---@field private items table').name)
    -- an unknown tag is ignored BY NAME: nvim's gen_vimdoc emits @brief/@toc/@text
    eq(nil, annot.TAGS['brief'])
    eq(nil, parse('---@brief a paragraph of prose'), 'prose tags carry no row')
end)

test('annotation-mismatch: a name check, with the three exclusions', function ()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not pcall(vim.treesitter.get_string_parser, '', 'lua') then skip 'no lua parser' end
    local ts = require 'cartograph.providers.treesitter'
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/a.lua', 'w'))
    fd:write(table.concat({
        '---@param a string',
        '---@param b string',
        'local function ok(a, b) return a, b end',       -- both named: silent
        '',
        '---@param a string',
        '-- a plain comment does NOT break the block, and lua-ls binds across it too',
        'local function stranded(x) return x end',       -- `a`: FINDING
        '',
        '---@param ... any',
        'local function varok(...) return ... end',      -- `...` is never a finding
        '',
        '---@param opts.field string',
        'local function dotted(opts) return opts end',   -- root `opts` exists: silent
        '',
        '---@param self Thing',
        '---@param n integer',
        'function Thing:m(n) return self, n end',        -- `self` IS a lua method param
        '',
        '---@param gone string',
        'local function stale(kept) return kept end',    -- `gone`: FINDING
        'return { ok, stranded, varok, dotted, stale }', '' }, '\n'))
    fd:close()
    local store2 = require 'cartograph.store'
    store2.ingest(ts.extract(root))
    local f = lint.run(store2, only('annotation-mismatch'))
    local got = {}
    for _, x in ipairs(f) do got[#got + 1] = x.message end
    table.sort(got)
    eq(2, #got, 'exactly the two real disagreements: ' .. table.concat(got, ' | '))
    ok(got[1]:match("@param 'a' names no parameter of 'stranded'"), got[1])
    ok(got[2]:match("@param 'gone' names no parameter of 'stale'"), got[2])
    ok(got[2]:match('parameters: kept'), 'the message says which names DO exist')
    vim.fn.delete(root, 'rf')
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

-- ── THE QUANTIFIER FENCE (CART-0513) ────────────────────────────────────────
-- The sibling of the disposition fence above, and it exists for a sharper reason:
-- disposition decides how much a finding is WORTH, quantifier decides whether the
-- rule may be SCOPED at all. A witness rule may be clipped to a subset and merely
-- under-report; a promise rule clipped to a subset FABRICATES, because absence
-- inside the scope reads as absence everywhere. So an undeclared rule is not a
-- documentation gap, it is a rule nobody can safely scope.
test('lint: every rule DECLARES which way its evidence runs', function ()
    local lint = require 'cartograph.lint'
    local missing, bad = {}, {}
    for _, r in ipairs(lint.rules) do
        if r.quantifier == nil then missing[#missing + 1] = r.name
        elseif not lint.QUANTIFIERS[r.quantifier] then
            bad[#bad + 1] = r.name .. '=' .. tostring(r.quantifier)
        end
    end
    eq({}, missing, 'a new rule must decide: witness (asserts existence) or'
        .. ' promise (asserts absence)')
    eq({}, bad, 'and it must be one of the declared quantifiers')
    ok(#lint.rules >= 25, 'sanity: the registry was actually read')
end)

test('lint: the boundary policy is DERIVED from the quantifier, not declared', function ()
    local lint = require 'cartograph.lint'
    -- the n+m collapse made executable: no rule declares its policies, and no
    -- (rule x policy) cell is authored anywhere
    eq({ clip = true, hedge = true, refuse = true }, lint.policies('witness'))
    eq({ clip = false, hedge = true, refuse = true }, lint.policies('promise'),
        'a promise rule may hedge or refuse — never clip')
    -- and it reads a rule table as happily as a bare string
    for _, r in ipairs(lint.rules) do
        eq(r.quantifier == 'witness', lint.policies(r).clip, r.name)
    end
    local clip = lint.clippable()
    ok(#clip > 0 and #clip < #lint.rules,
        ('the split is real: %d of %d rules are clip-legal'):format(#clip, #lint.rules))
end)

test('lint: quantifier and disposition are DIFFERENT axes', function ()
    local lint = require 'cartograph.lint'
    -- all four combinations are populated, so a reader cannot collapse the two
    -- fields into one. If this ever fails, the classification has drifted toward
    -- "authoritative means witness", which it does not.
    local seen = {}
    for _, r in ipairs(lint.rules) do
        seen[r.disposition .. '/' .. r.quantifier] = r.name
    end
    for _, k in ipairs({ 'authoritative/witness', 'authoritative/promise',
        'suggestive/witness', 'suggestive/promise' }) do
        ok(seen[k], 'no rule is ' .. k .. ' — the axes may have collapsed')
    end
end)

test('lint: every CALLER of lint.run declares the scope it supplies', function ()
    local lint = require 'cartograph.lint'
    -- ★ THE FENCE THAT MATTERS MORE THAN THE TABLE. Scope is part of the call
    -- convention, so a new entry point that ships without saying what it supplies
    -- is the defect — and today every row reads `corpus`, which is the omission
    -- made visible rather than a decision. The population is read from SOURCE, not
    -- from the table, so the table cannot go stale in the silent direction.
    local declared = {}
    for _, e in ipairs(lint.ENTRY_POINTS) do
        declared[e.at] = e
        ok(e.supplies, e.at .. ' must say what scope it supplies')
    end
    local root = vim.fn.getcwd()
    local found, undeclared = {}, {}
    local cmd = 'cd ' .. vim.fn.shellescape(root)
        .. " && grep -rlF -e \"lint').run(\" -e 'lint.run(' lua tools 2>/dev/null"
    for _, rel in ipairs(vim.fn.systemlist(cmd)) do
        if rel ~= '' and rel ~= 'lua/cartograph/lint.lua' then
            found[#found + 1] = rel
            if not declared[rel] then undeclared[#undeclared + 1] = rel end
        end
    end
    ok(#found >= 4, 'sanity: the call sites were actually found (' .. #found .. ')')
    eq({}, undeclared, 'a caller of lint.run that does not declare its scope')
end)

-- ── THE DENOMINATOR (CART-0512) ─────────────────────────────────────────────
test('lint: every PROMISE rule declares what it had to search', function ()
    local lint = require 'cartograph.lint'
    local missing, bad = {}, {}
    for _, r in ipairs(lint.rules) do
        if r.quantifier == 'promise' then
            if r.closed_over == nil then missing[#missing + 1] = r.name
            elseif not lint.CLOSED_OVER[r.closed_over] then
                bad[#bad + 1] = r.name .. '=' .. tostring(r.closed_over)
            end
        elseif r.closed_over ~= nil then
            -- a witness rule clips regardless, so declaring a denominator for one
            -- would be a field with no reader
            bad[#bad + 1] = r.name .. ' is a witness and declares closed_over'
        end
    end
    eq({}, missing, 'a promise rule must say whether its search space is a fn, a'
        .. ' file, or the corpus — that is what decides if a cut can hold it')
    eq({}, bad, 'and the value must be one of the declared spaces')
end)

test('lint: a promise clips when the CUT CONTAINS its denominator', function ()
    local lint = require 'cartograph.lint'
    -- the coarse rule stays the conservative default: asked without a grain, a
    -- promise never clips
    eq(false, lint.policies({ quantifier = 'promise', closed_over = 'fn' }).clip)
    -- a fn-cut holds a fn-denominator; a file-cut holds it too
    local fnrule = { quantifier = 'promise', closed_over = 'fn' }
    eq(true, lint.policies(fnrule, 'fn').clip)
    eq(true, lint.policies(fnrule, 'file').clip)
    -- but a REGION is finer than a function and does NOT contain one, which is why
    -- CLOSURE is a declared relation and not a numeric ladder
    eq(false, lint.policies(fnrule, 'region').clip)
    eq(false, lint.policies(fnrule, 'node').clip)
    -- a file-denominator needs a file-cut
    local frule = { quantifier = 'promise', closed_over = 'file' }
    eq(false, lint.policies(frule, 'fn').clip, 'a function does not hold its file')
    eq(true, lint.policies(frule, 'file').clip)
    -- and a corpus denominator is never held by a cut
    local crule = { quantifier = 'promise', closed_over = 'corpus' }
    for _, g in ipairs({ 'node', 'fn', 'region', 'file', 'set' }) do
        eq(false, lint.policies(crule, g).clip, 'corpus denominator at ' .. g)
    end
    -- a witness clips at every grain, denominator or not
    eq(true, lint.policies({ quantifier = 'witness' }, 'node').clip)
end)

test('lint: the refinement fixes the inversion it was filed for', function ()
    local lint = require 'cartograph.lint'
    -- ★ THE COST OF THE COARSE RULE, as a test. At a FUNCTION the scoped lint
    -- refused the four rules whose whole question is about that function while
    -- permitting corpus-shaped ones. Two of the four are fn-closed and become
    -- legal here; the other two turned out to be FILE-closed when their
    -- implementations were read, so they become legal at a file cut instead.
    local at_fn, at_file = {}, {}
    for _, n in ipairs(lint.clippable('fn')) do at_fn[n] = true end
    for _, n in ipairs(lint.clippable('file')) do at_file[n] = true end
    ok(at_fn['resource-leak'], 'resource-leak walks ONE function\'s rows')
    ok(at_fn['annotation-mismatch'], "and @param is checked against that fn's own list")
    ok(not at_fn['null-deref'], 'null-deref iterates MODULE nodes, so a fn is not enough')
    ok(at_file['null-deref'], 'but a file cut holds it')
    ok(at_file['member-leak'], 'same for member-leak, which says "anywhere" and means the file')
    ok(at_file['dead-confined'],
        'and dead-confined is file-closed BY ITS OWN PREMISES: exported==false,'
        .. ' escapes==false, the name occurs once in its file')
    ok(not at_file['dead-function'],
        'while dead-function asks band:n_callers — a corpus query, never clippable')
end)

test('tag-coverage: a walker that misses a tag its own module constructs is asked about',
    function ()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not pcall(vim.treesitter.language.add, 'lua') then skip 'no lua parser' end
    -- ★ CART-0662, built from the bug it would have caught — fixed in 5903841. expr.key
    -- had a case for 11 expression kinds and none for `assign`, whose `t` holds a TARGET
    -- where every other kind holds a type STRING, so an assign fell to a fallback that
    -- concatenated it; 267 of 395 bash functions threw.
    --
    -- ★★ THE REAL ACCEPTANCE TEST IS AGAINST 5903841^ AND IT CANNOT LIVE HERE: this
    -- fixture is a hand-built miniature, and a fixture proves the rule fires on what its
    -- author imagined. The tree the defect actually lived in is one command away —
    --     git show 5903841^:lua/cartograph/expr.lua
    -- — and running the rule over it reports "M.key … has no case for ?, assign". Do that
    -- before widening, narrowing or deleting this rule.
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    local function put(rel, text)
        local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(text); fd:close()
    end
    put('m.lua', table.concat({
        'local M = {}',
        'local function build(x)',
        '  if x == 1 then return { k = "lit", v = 1 } end',
        '  if x == 2 then return { k = "name", n = "a" } end',
        '  if x == 3 then return { k = "call", f = 1 } end',
        '  if x == 4 then return { k = "bin", l = 1, r = 2 } end',
        '  return { k = "assign", t = {}, v = {} }',   -- the tag the walker forgets
        'end',
        'function M.render(e)',
        '  local k = e.k',
        '  if k == "lit" then return "L" end',
        '  if k == "name" then return "N" end',
        '  if k == "call" then return "C" end',
        '  if k == "bin" then return "B" end',
        '  return "?" .. e.t',                          -- the fallback that assumes
        'end',
        'return { M = M, build = build }',
    }, '\n'))
    local lint = require 'cartograph.lint'
    local rule
    for _, r in ipairs(lint.rules) do if r.name == 'tag-coverage' then rule = r end end
    ok(rule ~= nil, 'the rule is registered')
    local store = { files = { 'm.lua' }, abs = function (f) return root .. '/' .. f end }
    local found = rule.run(store)
    eq(1, #found, 'the walker that covers 4 of 5 is asked about, got ' .. #found)
    ok(found[1].message:find('assign', 1, true), 'and the missing tag is named: '
        .. found[1].message)

    -- ⚠ A FAMILY TOO SMALL TO BE A DISPATCH IS NOT ONE. Two or three comparisons are not
    -- a walker, and reporting them would bury the shape this rule exists for.
    put('m.lua', table.concat({
        'local function build(x)',
        '  if x then return { k = "a" } end',
        '  return { k = "b" }',
        'end',
        'local function go(e) if e.k == "a" then return 1 end return 0 end',
        'return { build = build, go = go }',
    }, '\n'))
    eq(0, #rule.run(store), 'a two-tag family is not a dispatch')
    vim.fn.delete(root, 'rf')
end)

-- ── THE ELIDED TAIL (CART-0670) ─────────────────────────────────────────────
-- The fourth premise of a refusal shadow, and the one whose absence broke typed
-- absence at scale. `tsutil.refusal` keeps at most EIGHT candidate ids and
-- records the true count as `n`; the shadow matcher read the kept list and never
-- the count. So on any name with nine or more definitions the ninth onward cast
-- no shadow, every other premise held, and a LIVE function was handed `absent` —
-- the one absence value that licenses a deletion — with the choice of victim
-- decided by the candidate list's emission order. Measured on an 8k-file Java
-- monorepo: 25,559 truncated refusals, 525 names, 11 of 19 live implementations
-- of one interface method reported callerless.
--
-- The corpus below is the Lua shape of that: nine same-named methods, one
-- ambiguous call, so the refusal records n=9 and keeps p1..p8 — and p9 exists
-- ONLY in the tail that was never stored.
test('refusal shadow: a candidate in the ELIDED TAIL still blocks', function ()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not pcall(vim.treesitter.get_string_parser, '', 'lua') then skip 'no lua parser' end
    local ts = require 'cartograph.providers.treesitter'
    local lint = require 'cartograph.lint'
    local store = require 'cartograph.store'

    local function corpus(impls)
        local root = vim.fn.tempname()
        vim.fn.mkdir(root, 'p')
        local function put(p, s)
            local fd = assert(io.open(root .. '/' .. p, 'w')); fd:write(s); fd:close()
        end
        for i = 1, impls do
            put(('p%d.lua'):format(i), table.concat({
                ('local P%d = {}'):format(i),
                ('function P%d:appliesTo(d) return d == %d end'):format(i, i),
                ('return P%d'):format(i), '' }, '\n'))
        end
        put('runner.lua', table.concat({
            'local M = {}',
            'function M.run(list, doc)',
            '  for _, p in ipairs(list) do',
            '    if p:appliesTo(doc) then return p end',
            '  end',
            'end',
            'return M', '' }, '\n'))
        -- THE DISCRIMINATION CONTROL, and it is the point of the whole guard: a
        -- fix reading "some refusal in this graph was truncated, so stop saying
        -- absent" turns this row blocked too and destroys the dead-code surface.
        put('lonely.lua', table.concat({
            'local function reallyDeadHelper() return 1 end',
            'local M = {}',
            'function M.go() return 2 end',
            'return M', '' }, '\n'))
        store.ingest(ts.extract(root))
        return root, lint.alibi(store)
    end

    local function first_blocker(ali, name)
        for _, n in ipairs(store.data.nodes) do
            if n.name == name then return (ali(n).blockers or {})[1] end
        end
    end

    -- NINE: the refusal saw 9 and kept 8, so p9 is reachable by NOTHING but the count
    local root, ali = corpus(9)
    local trunc = nil
    for _, c in ipairs(store.data.calls or {}) do
        if c.refused and c.refused.cands then trunc = c.refused end
    end
    eq(9, trunc.n, 'the refusal recorded what it SAW')
    eq(8, #trunc.cands, 'and kept less than that')

    local b8 = first_blocker(ali, 'P8:appliesTo')
    eq('refused', b8.absence)
    eq(true, b8.evidence.by_candidate_list, 'p8 is inside the retained window')

    local b9 = first_blocker(ali, 'P9:appliesTo')
    eq('refused', b9.absence, 'the elided candidate is NOT absent')
    eq('refusal-shadow', b9.kind)
    eq(false, b9.evidence.by_candidate_list, 'and it got there by no other route')
    eq(true, b9.evidence.by_truncated_tail)
    eq('truncated-tail', b9.evidence.sites[1].matched)
    eq(9, b9.evidence.sites[1].candidates_total, 'the evidence names both counts')
    eq(8, b9.evidence.sites[1].candidates)
    ok(b9.why:find('8 of the 9'), 'and says so in words: ' .. b9.why)

    eq(nil, first_blocker(ali, 'reallyDeadHelper'),
        'a genuinely uncalled name with no truncated refusal spelling it stays claimable')
    vim.fn.delete(root, 'rf')

    -- EIGHT: nothing is elided, so the new route must be INERT. A widening that
    -- fires below the cap would be indistinguishable from one that never checks.
    local root8, ali8 = corpus(8)
    local b = first_blocker(ali8, 'P8:appliesTo')
    eq('refused', b.absence)
    eq(false, b.evidence.by_truncated_tail, 'no tail, no tail-route')
    eq(nil, first_blocker(ali8, 'reallyDeadHelper'))
    vim.fn.delete(root8, 'rf')
end)
