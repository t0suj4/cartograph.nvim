-- TACTICS (CART-1152 step 2): verb invocations composed by tacticals, stopping ONLY on a decision, and recovering
-- FORWARD — a stopped run keeps what it completed, and resuming is re-running (USER: "atomicity is a strong guarantee
-- we cannot make once we leave the filesystem"). The matrix drives one step per stop class through the REAL write
-- path (txn.stage / txn.apply / the journal) on a temp root, with synthetic verbs whose outcome each case names; then
-- a REAL chain (moveset ; replace) accepted by an oracle that reads the written file, and an IDEMPOTENCE fence that is
-- total over compose.VERBS.

local tactic = require 'cartograph.tactic'
local store = require 'cartograph.store'
local ts = require 'cartograph.providers.treesitter'
local txn = require 'cartograph.txn'
local hazard = require 'cartograph.hazard'
local T = tactic.T

local function ready() return pcall(vim.treesitter.get_string_parser, '', 'lua') end

local ORIG = { ['a.lua'] = 'local a = 1\nreturn a\n', ['b.lua'] = 'local b = 2\nreturn b\n' }

local function mkroot(files)
    local root = vim.fn.tempname()
    for rel, text in pairs(files) do
        local dir = (root .. '/' .. rel):match('^(.*)/[^/]*$')
        vim.fn.mkdir(dir, 'p')
        local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(text); fd:close()
    end
    store.ingest(ts.extract(root))
    return root
end
local function read(root, rel)
    local fd = io.open(root .. '/' .. rel); if not fd then return nil end
    local s = fd:read('a'); fd:close(); return s
end

--- a protocol-complete plan appending `line` to `rel`, with optional hazards
local function write_plan(rel, line, hazards, guards)
    return txn.protocol({ verb = 't-write', guards = guards or {}, refspecs = {}, touched = { rel },
        generation = store.generation, stamps = { [rel] = txn.disk_stamp(store.data.root, rel) },
        desc = 't-write ' .. line, preserves = 'none', hazards = hazards or {}, rel = rel, line = line },
        function (p) return function (r, before) if r ~= p.rel then return before end return before .. p.line .. '\n' end end)
end

local calls, shipped = {}, 0
local VERBS = {
    -- GOAL-CHECKED: a file already holding the line is `empty`, so re-running it is safe
    write = { effect = 'journaled', rerun = 'empty', plan = function (_, a)
        local line = a.line or '-- x'
        if (read(store.data.root, a.file) or ''):find(line, 1, true) then return nil, 'already there', 'empty' end
        local hz = {}
        if a.decision then hz[1] = hazard.new(a.decision, 'a choice: ' .. a.decision, nil, nil, 'decision') end
        if a.residue then hz[#hz + 1] = hazard.new('left', 'left undone: ' .. a.residue, nil, nil, a.residue) end
        return write_plan(a.file, line, hz, a.guards)
    end },
    -- NOT goal-checked: every run appends again
    append = { effect = 'journaled', plan = function (_, a) return write_plan(a.file, '-- again') end },
    refuse = { effect = 'journaled', rerun = 'empty', plan = function (_, a) return nil, a.why or ('refused as ' .. tostring(a.class)), a.class end },
    -- stale the first time it is planned, a real write the second: the runner must RE-PLAN
    stale_once = { effect = 'journaled', rerun = 'empty', plan = function (_, a)
        calls[a.key] = (calls[a.key] or 0) + 1
        if calls[a.key] == 1 then return nil, 'the tree moved', 'stale' end
        if (read(store.data.root, a.file) or ''):find('replanned', 1, true) then return nil, 'done', 'empty' end
        return write_plan(a.file, '-- replanned')
    end },
    -- writes until the file holds `n` marker lines, then has nothing to do (empty)
    upto = { effect = 'journaled', rerun = 'empty', plan = function (_, a)
        local _, have = read(store.data.root, a.file):gsub('%-%- mark', '')
        if have >= a.n then return nil, 'already ' .. a.n, 'empty' end
        return write_plan(a.file, '-- mark')
    end },
    -- an EXTERNAL effect: staged like any plan, applied outside the journal (a deploy, a message)
    ship = { effect = 'irreversible', plan = function (_, a) return write_plan(a.file, '-- shipped') end,
        apply = function () shipped = shipped + 1; return { id = 'ext-' .. shipped } end },
}
local function W(file, extra) local a = { file = file }; for k, v in pairs(extra or {}) do a[k] = v end; return T.step('write', a) end
local function R(class, why) return T.step('refuse', { class = class, why = why }) end
local function run(term, opts) opts = opts or {}; opts.verbs = VERBS; if opts.apply == nil then opts.apply = true end; return tactic.run(store, term, opts) end
local function unchanged(root) for rel, text in pairs(ORIG) do eq(text, read(root, rel), rel .. ' is as the run found it') end end

test('tactic: `then` applies each step through the journal', function ()
    if not ready() then skip 'no lua parser' end
    local root = mkroot(ORIG)
    local r = run(T.seq(W('a.lua', { line = '-- one' }), W('b.lua', { line = '-- two' })))
    eq('done', r.status, tostring(r.why))
    eq(2, r.applied)
    ok(read(root, 'a.lua'):find('-- one', 1, true) and read(root, 'b.lua'):find('-- two', 1, true), 'both writes landed')
end)

test('tactic: a failure KEEPS the completed steps (forward recovery); re-running resumes, completed steps are empty', function ()
    if not ready() then skip 'no lua parser' end
    local root = mkroot(ORIG)
    local term = T.seq(W('a.lua'), W('b.lua'), R('unbuilt', 'this verb cannot yet'))
    local r = run(term)
    eq('failed', r.status); eq('unbuilt', r.class); eq('root.3', r.where)
    eq(2, #r.completed, 'both earlier writes stand'); eq(0, r.rolled_back)
    eq(true, r.resumable, 'every completed step is goal-checked')
    ok(read(root, 'a.lua') ~= ORIG['a.lua'] and read(root, 'b.lua') ~= ORIG['b.lua'])
    eq(1, #r.work_orders); ok(r.work_orders[1].why:find('cannot yet', 1, true), 'the work order names the gap')
    -- the gap is fixed: the same term minus the unbuilt step re-runs, and the completed steps come back EMPTY
    local again = run(T.seq(term[1], term[2]))
    eq('done', again.status); eq(0, again.applied, 'nothing written twice')
end)

test('tactic: on_stop = rollback undoes a stopped run — journaled writes only', function ()
    if not ready() then skip 'no lua parser' end
    local root = mkroot(ORIG)
    local r = run(T.seq(W('a.lua'), W('b.lua'), R('unbuilt')), { on_stop = 'rollback' })
    eq('failed', r.status); eq(2, r.rolled_back); eq(0, #r.completed); unchanged(root)
    -- an irreversible completed step: the policy REFUSES by name, and says what stands
    shipped = 0
    local x = run(T.seq(T.step('ship', { file = 'a.lua' }), R('unbuilt')), { on_stop = 'rollback' })
    eq('failed', x.status); eq(1, shipped)
    ok(x.rollback_refused and x.rollback_refused:find('irreversible', 1, true), tostring(x.rollback_refused))
    eq('irreversible', x.completed[1] and x.completed[1].effect)
    eq(false, x.resumable, 'an irreversible step that declares no goal check cannot be re-run safely')
end)

test('tactic: an unaccepted DECISION hazard STOPS the run with its options; answering it and re-running finishes', function ()
    if not ready() then skip 'no lua parser' end
    local root = mkroot(ORIG)
    local acc = {}
    local term = T.seq(W('a.lua'), T.step('write', { file = 'b.lua', decision = 'keep-surface' }, acc))
    local r = run(term)
    eq('stopped', r.status, 'a decision is a stop, not a failure'); eq('decision', r.class)
    eq('keep-surface', r.options and r.options[1] and r.options[1].kind, 'the options name the choice')
    eq(1, #r.completed, 'the step before the decision stands'); eq(ORIG['b.lua'], read(root, 'b.lua'))
    acc[1] = 'keep-surface'
    local done = run(term)
    eq('done', done.status, tostring(done.why)); eq(1, done.applied, 'only the answered step writes on the resume')
    local seen
    for _, h in ipairs(done.residue) do if h.kind == 'keep-surface' then seen = h end end
    ok(seen and seen.class == 'informational' and seen.accepted, 'an ANSWERED decision rides as informational residue')
end)

test('tactic: a decision REFUSAL stops too; non-decision residue does not', function ()
    if not ready() then skip 'no lua parser' end
    mkroot(ORIG)
    eq('stopped', run(T.seq(W('a.lua'), R('decision', 'which member form?'))).status)
    local r = run(T.seq(W('a.lua', { line = '-- r', residue = 'unbuilt' }), W('b.lua', { line = '-- r', residue = 'frontier' })))
    eq('done', r.status, 'unbuilt and frontier residue are open subgoals, not limits')
    eq(1, #r.work_orders, 'the unbuilt residue is a work order')
end)

test('tactic: `first` moves past a failed alternative, UNDOING its journaled writes; an irreversible step cannot be an attempt', function ()
    if not ready() then skip 'no lua parser' end
    local root = mkroot(ORIG)
    local r = run(T.first(T.seq(W('a.lua', { line = '-- alt1' }), R('frontier', 'no type for x')), W('b.lua', { line = '-- alt2' })))
    eq('done', r.status, tostring(r.why))
    eq(ORIG['a.lua'], read(root, 'a.lua'), 'the failed alternative left nothing behind')
    ok(read(root, 'b.lua'):find('-- alt2', 1, true), 'the second alternative landed')
    eq(1, r.rolled_back)
    local f = run(T.first(R('frontier'), R('ill-posed')))
    eq('failed', f.status); ok(f.why:find('every alternative failed', 1, true), f.why)
    eq('stopped', run(T.first(R('decision'), W('a.lua'))).status, 'a decision is not a failure to move past')
    shipped = 0
    local x = run(T.first(T.seq(T.step('ship', { file = 'a.lua' }), R('frontier')), W('b.lua', { line = '-- alt3' })))
    eq('failed', x.status); eq('ill-posed', x.class); eq(0, shipped, 'refused BEFORE it ran')
    ok(x.why:find('point of no return', 1, true), x.why)
    -- ⚠ an UNDECLARED effect is treated as irreversible: a verb that says nothing is not assumed undoable
    local vb = setmetatable({ mystery = { plan = VERBS.write.plan } }, { __index = VERBS })
    local y = tactic.run(store, T.try(T.step('mystery', { file = 'a.lua', line = '-- m' })), { apply = true, verbs = vb })
    eq('failed', y.status); ok(y.why:find('irreversible', 1, true), y.why)
end)

test('tactic: `try` turns a failure into no change; `repeat` runs until the work runs out', function ()
    if not ready() then skip 'no lua parser' end
    local root = mkroot(ORIG)
    local t = run(T.try(T.seq(W('a.lua'), R('ill-posed', 'no such dest'))))
    eq('done', t.status); unchanged(root)
    eq('try', t.residue[1] and t.residue[1].kind, 'the swallowed failure rides as residue')
    local r = run(T.rep(T.step('upto', { file = 'a.lua', n = 3 })))
    eq('done', r.status, tostring(r.why)); eq(3, r.applied)
    local _, marks = read(root, 'a.lua'):gsub('%-%- mark', '')
    eq(3, marks, 'three iterations, then EMPTY ended it')
    local nc = run(T.rep(T.step('append', { file = 'b.lua' }), 4))
    eq('failed', nc.status, 'a repeat that never runs out of work is refused by name')
    eq(false, nc.resumable, 'and a step with no goal check is not safe to re-run')
end)

test('tactic: a STALE step is re-planned once; an unknown class fails as `unclassified`, by name', function ()
    if not ready() then skip 'no lua parser' end
    local root = mkroot(ORIG)
    calls = {}
    local r = run(T.step('stale_once', { key = 's1', file = 'a.lua' }))
    eq('done', r.status, tostring(r.why)); eq(2, calls.s1, 'planned twice')
    ok(read(root, 'a.lua'):find('replanned', 1, true))
    local u = run(R(nil, 'an adapter that names no class'))
    eq('unclassified', u.class); ok(u.why:find('root', 1, true) and u.why:find('no known class', 1, true), u.why)
end)

test('tactic: a DRY run previews up to the first write and names what it cannot derive; a failing guard fails it', function ()
    if not ready() then skip 'no lua parser' end
    local root = mkroot(ORIG)
    local r = run(T.seq(W('a.lua'), W('b.lua')), { apply = false })
    eq('previewed', r.status); eq(0, r.applied); unchanged(root)
    eq(true, r.trace[2] and r.trace[2].underivable, 'step 2 waits on step 1')
    local g = run(W('a.lua', { line = 'local = (', guards = { 'parses' } }), { apply = false })
    eq('failed', g.status); eq('unbuilt', g.class, 'a verb breaking its own guard is a bug')
end)

test('tactic: the ORACLE is the kernel — a rejection fails the run (kept, or undone under the rollback policy)', function ()
    if not ready() then skip 'no lua parser' end
    mkroot(ORIG)
    local no = function () return false, 'the spec went red' end
    local r = run(W('a.lua'), { oracle = no })
    eq('failed', r.status); ok(r.why:find('spec went red', 1, true)); eq(1, #r.completed)
    local root2 = mkroot(ORIG)
    run(W('a.lua'), { oracle = no, on_stop = 'rollback' })
    unchanged(root2)
end)

test('tactic: rollback refuses to undo a write the run did not make', function ()
    if not ready() then skip 'no lua parser' end
    local root = mkroot(ORIG)
    local r = tactic.step(store, W('a.lua'), { verbs = VERBS, apply = true })
    ok(r.entry, 'applied')
    assert(txn.apply(store, write_plan('b.lua', '-- someone else')))
    local undone, why = tactic.rollback(store, { r.entry })
    eq(0, undone)
    ok(why and why:find('did not make', 1, true), tostring(why))
    ok(read(root, 'b.lua'):find('someone else', 1, true), 'the other write stands')
end)

test('tactic: `each` runs one body per item; a failing item leaves the completed ones', function ()
    if not ready() then skip 'no lua parser' end
    local root = mkroot(ORIG)
    local r = run(T.each({ 'a.lua', 'b.lua' }, function (rel) return W(rel, { line = '-- each' }) end))
    eq('done', r.status, tostring(r.why)); eq(2, r.applied)
    ok(read(root, 'a.lua'):find('-- each', 1, true) and read(root, 'b.lua'):find('-- each', 1, true))
    mkroot(ORIG)
    local f = run(T.each({ 'a.lua', 'b.lua', 'nope' }, function (rel)
        if rel == 'nope' then return R('ill-posed', 'no such file') end
        return W(rel)
    end))
    eq('failed', f.status); eq('root.3', f.where); eq(2, #f.completed)
end)

-- ── the REAL chain: move an exported function, then replace its body — two real verbs, a real decision each ──────
local R_LUA = 'local M = {}\nfunction M.dbl(x) return x * 2 end\nfunction M.keep(x) return x + 1 end\nreturn M\n'
local function fn_ref(name, file)
    for _, n in ipairs(store.data.nodes) do
        if n.name == name and (not file or n.file == file) and (n.kind == 'function' or n.kind == 'method') then return store.ref_of(n.id) end
    end
end
--- built ONCE per scenario and re-run as is: invocations are durable, and resuming is running the same term
local function chain(accept_move, accept_replace)
    return T.seq(
        T.step('moveset', { seed_refs = { fn_ref('M.dbl', 'r.lua') }, dest = 'lib/new.lua' }, accept_move),
        -- the ref to the symbol's NEW home: resolved when this step is PLANNED, after the move applied
        { op = 'step', verb = 'replace', accept = accept_replace, args = setmetatable({ text = 'function M.dbl(x) return x + x end' },
            { __index = function (_, k) if k == 'ref' then return fn_ref('M.dbl', 'lib/new.lua') end end }) })
end
local function oracle_for(root)
    return function ()
        -- the kernel reads the WRITTEN bytes, not the plan: load the new module and run it
        local chunk = loadstring(read(root, 'lib/new.lua') or '')
        local okm, mod = pcall(chunk or error)
        if not (okm and type(mod) == 'table' and mod.dbl) then return false, 'lib/new.lua does not load as a module' end
        return mod.dbl(21) == 42, 'dbl(21) = ' .. tostring(mod.dbl(21))
    end
end

test('tactic: the REAL chain STOPS at each decision, KEEPS the move, and RESUMES by re-running — an oracle accepts it', function ()
    if not ready() then skip 'no lua parser' end
    local root = mkroot { ['r.lua'] = R_LUA }
    local acc_move, acc_replace = {}, {}
    local term = chain(acc_move, acc_replace)
    -- the move's own decision is REAL: unanswered, the run stops at step 1 and writes nothing
    local m = tactic.run(store, term, { apply = true })
    eq('stopped', m.status); eq('root.1', m.where); eq('surface', m.options and m.options[1] and m.options[1].kind)
    eq(0, #m.completed); eq(R_LUA, read(root, 'r.lua'))
    acc_move[1] = 'surface'
    local r = tactic.run(store, term, { apply = true })
    eq('stopped', r.status, tostring(r.why)); eq('root.2', r.where, 'at the replace, after the move applied')
    eq('supplied-text', r.options and r.options[1] and r.options[1].kind)
    eq('moveset', r.completed[1] and r.completed[1].verb, 'the move STANDS'); eq(true, r.resumable)
    ok(read(root, 'lib/new.lua'), 'the moved module exists')
    acc_replace[1] = 'supplied-text'
    local done = tactic.run(store, term, { apply = true, oracle = oracle_for(root) })
    eq('done', done.status, tostring(done.why))
    eq(1, done.applied, 'the resume re-ran the move as EMPTY (goal met) and applied only the replace')
    eq('replace', done.completed[1] and done.completed[1].verb)
    ok(read(root, 'r.lua') ~= R_LUA, 'the move took M.dbl out of r.lua')
    ok((read(root, 'lib/new.lua') or ''):find('x + x', 1, true), 'and the replacement is in its new home')
end)

test('tactic: the REAL chain under on_stop = rollback leaves every file as it found it', function ()
    if not ready() then skip 'no lua parser' end
    local root = mkroot { ['r.lua'] = R_LUA }
    local r = tactic.run(store, chain({ 'surface' }, nil), { apply = true, on_stop = 'rollback' })
    eq('stopped', r.status); eq(1, r.rolled_back, 'the move is undone')
    eq(R_LUA, read(root, 'r.lua')); eq(nil, read(root, 'lib/new.lua'), 'the created module is gone')
end)

test('tactic: RE-RUNNING a move refuses on the caveated ref — it used to move the NEIGHBOUR (M.keep)', function ()
    -- MEASURED (CART-1152 idempotence probe): after the move the SAME ref to M.dbl resolved to M.keep with the caveat
    -- "renamed? now 'M.keep'", and compose's adapter took the id and moved M.keep. A caveat refuses on the write side;
    -- the goal check answers first when the seed already lives at dest, so this is a DIFFERENT dest.
    if not ready() then skip 'no lua parser' end
    local root = mkroot { ['r.lua'] = R_LUA }
    local ref = fn_ref('M.dbl', 'r.lua')
    ok(tactic.step(store, { verb = 'moveset', args = { seed_refs = { ref }, dest = 'lib/new.lua' } }, { apply = true }).entry)
    local again = tactic.step(store, { verb = 'moveset', args = { seed_refs = { ref }, dest = 'lib/other.lua' } }, { apply = true })
    eq(false, again.ok); eq('stale', again.class)
    ok(tostring(again.why):find('CAVEAT', 1, true), tostring(again.why))
    ok(read(root, 'r.lua'):find('M.keep', 1, true), 'M.keep stays where it was')
end)

-- ── THE IDEMPOTENCE FENCE: every compose.VERBS verb, applied twice with the SAME invocation, is `empty` the second
-- time and writes nothing — what `rerun = 'empty'` declares, and what forward recovery (resume = re-run) rests on.
-- ★ TOTAL BY CONSTRUCTION: the case table is keyed by verb and checked against compose.VERBS, so a verb added
-- without a case fails here rather than being assumed safe.
local SM = table.concat({ 'local M = {}', 'function M.norm(p, q)', '  local s = p * p + q * q', '  return s', 'end', 'return M', '' }, '\n')
local SN = table.concat({ 'local M = {}', 'function M.dist(p, q)', '  local s = p * p + q * q', '  return s', 'end',
    'function M.use(a, b) return M.dist(a, b) end', 'return M', '' }, '\n')
local IDEM = {
    moveset = { { ['r.lua'] = R_LUA }, function () return { seed_refs = { fn_ref('M.dbl', 'r.lua') }, dest = 'lib/new.lua' } end },
    replace = { { ['r.lua'] = R_LUA }, function () return { ref = fn_ref('M.dbl', 'r.lua'), text = 'function M.dbl(x) return x + x end' } end },
    annotate = { { ['r.lua'] = '-- style\n' .. R_LUA }, function () return { ref = fn_ref('M.dbl', 'r.lua'), text = 'doubles a number' } end },
    clonemerge = { { ['m.lua'] = SM, ['n.lua'] = SN }, function () return { ref = fn_ref('M.norm', 'm.lua') } end },
}
local function snap(root)
    local out = {}
    for _, p in ipairs(vim.fn.globpath(root, '**/*.lua', false, true)) do out[p:sub(#root + 2)] = read(root, p:sub(#root + 2)) end
    return vim.inspect(out)
end

test('tactic: IDEMPOTENCE — every compose verb re-run with the same invocation is empty and writes nothing', function ()
    if not ready() then skip 'no lua parser' end
    local VB = require('cartograph.compose').VERBS
    for verb, spec in pairs(VB) do
        local c = IDEM[verb]
        ok(c, verb .. ' has an idempotence case (a verb without one is not assumed safe)')
        eq('empty', spec.rerun, verb .. ' declares its re-run')
        eq('journaled', spec.effect, verb .. ' declares its effect')
        local root = mkroot(c[1])
        local st = { verb = verb, args = c[2]() }
        local s0 = snap(root)
        local r1 = tactic.step(store, st, { apply = true })
        local s1 = snap(root)
        ok(r1.entry and s1 ~= s0, verb .. ': the FIRST run writes (else the second proves nothing): ' .. tostring(r1.why))
        local r2 = tactic.step(store, st, { apply = true })
        eq(true, r2.ok and r2.empty, verb .. ': the second run is empty: ' .. tostring(r2.why))
        eq(s1, snap(root), verb .. ': and writes nothing')
    end
end)
