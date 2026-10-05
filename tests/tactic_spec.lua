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
        -- the goal check reads THROUGH the graph's transport (txn.read_file), as a planner does: in a dry run's
        -- overlay world it sees what the previewed steps would have written
        if (txn.read_file(store.data.root, a.file) or ''):find(line, 1, true) then return nil, 'already there', 'empty' end
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
        local _, have = txn.read_file(store.data.root, a.file):gsub('%-%- mark', '')
        if have >= a.n then return nil, 'already ' .. a.n, 'empty' end
        return write_plan(a.file, '-- mark')
    end },
    -- a COMPENSABLE external effect: applied outside the journal, undoable only by its world's own inverse
    comp = { effect = 'compensable', plan = function (_, a) return write_plan(a.file, '-- compensable') end,
        apply = function () shipped = shipped + 1; return { id = 'comp-' .. shipped } end },
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
    -- a COMPENSABLE completed step: the journal cannot undo it, so the policy REFUSES by name and says what stands
    -- (compensation itself is CART-1186)
    shipped = 0
    local x = run(T.seq(T.step('comp', { file = 'a.lua' }), R('unbuilt')), { on_stop = 'rollback' })
    eq('failed', x.status); eq(1, shipped)
    ok(x.rollback_refused and x.rollback_refused:find('compensable', 1, true), tostring(x.rollback_refused))
    eq('compensable', x.completed[1] and x.completed[1].effect)
    -- ★ an IRREVERSIBLE step before something that can still stop the run is refused BEFORE ANYTHING RUNS (CART-1187):
    -- the case the rollback policy could only ever refuse after the fact
    shipped = 0
    local y = run(T.seq(T.step('ship', { file = 'a.lua' }), R('unbuilt')), { on_stop = 'rollback' })
    eq('failed', y.status); eq('ill-posed', y.class); eq(0, shipped, 'nothing ran'); unchanged(root)
    ok(y.why:find('point of no return', 1, true) and y.why:find('root.1', 1, true) and y.why:find('root.2', 1, true), y.why)
    -- the accepted reorderings: the check BEFORE the irreversible step, or what follows wrapped in `try`
    eq('done', run(T.seq(W('b.lua'), T.step('ship', { file = 'a.lua' }))).status)
    eq('done', run(T.seq(T.step('ship', { file = 'a.lua' }), T.try(R('unbuilt')))).status)
    -- and the tactic's ORACLE is a gate too: an irreversible step with an oracle after it is refused
    local z = run(T.step('ship', { file = 'a.lua' }), { oracle = function () return true end })
    eq('ill-posed', z.class); ok(z.why:find('the oracle', 1, true), z.why)
    -- ★ a term BUILT AT RUN TIME (a bind body, a used write's build) gets the same walk before it runs (CART-1444)
    local d = vim.fn.tempname(); vim.fn.mkdir(d, 'p')
    local fd = assert(io.open(d .. '/always.lua', 'w'))
    fd:write("return { name = 'always', kind = 'discovery', summary = 's', params = {}, examples = { { name = 'x' } }, "
        .. "measure = function () return 1 end, claim = function () return true, 'yes' end }\n"); fd:close()
    shipped = 0
    local b = run(T.bind('always', {}, function () return T.seq(T.step('ship', { file = 'a.lua' }), R('unbuilt')) end), { toolbelt_dir = d })
    eq('failed', b.status); eq('ill-posed', b.class); eq(0, shipped, 'the built irreversible step never ran')
    ok(b.why:find('point of no return', 1, true), b.why)
    fd = assert(io.open(d .. '/shipper.lua', 'w'))
    fd:write("local T = require('cartograph.tactic').T\nreturn { name = 'shipper', kind = 'write', summary = 's', params = {}, examples = { { name = 'x' } }, "
        .. "build = function () return T.seq(T.step('ship', { file = 'a.lua' }), T.step('refuse', { class = 'unbuilt' })) end }\n"); fd:close()
    local u = run(T.use('shipper'), { toolbelt_dir = d })
    eq('failed', u.status); eq('ill-posed', u.class); eq(0, shipped, 'the used write\'s irreversible step never ran')
    ok(u.why:find('point of no return', 1, true), u.why)
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

test('tactic: a DRY run CHAINS overlay worlds — step 2 plans against what step 1 would write; a failing guard fails it', function ()
    if not ready() then skip 'no lua parser' end
    local root = mkroot(ORIG)
    local caller = store.data
    local term = T.seq(W('a.lua', { line = '-- one' }), W('a.lua', { line = '-- two' }), W('b.lua'))
    local r = run(term, { apply = false })
    eq('previewed', r.status, tostring(r.why)); eq(0, r.applied); unchanged(root)
    eq(3, r.worlds, 'one overlay world per previewed step')
    for i = 1, 3 do ok(r.trace[i] and r.trace[i].previewed and not r.trace[i].underivable, 'step ' .. i .. ' previewed') end
    eq(ORIG['a.lua'] .. '-- one\n-- two\n', r.preview and r.preview['a.lua'], 'the same file edited twice: both edits, in order')
    eq(ORIG['b.lua'] .. '-- x\n', r.preview['b.lua'])
    eq(caller, store.data, 'and the caller\'s graph is the lens again')
    -- ★ THE ORACLE: the preview EQUALS what the apply writes
    local done = run(term)
    eq('done', done.status, tostring(done.why))
    for rel, text in pairs(r.preview) do eq(text, read(root, rel), rel .. ': the preview is the apply') end
    local g = run(W('a.lua', { line = 'local = (', guards = { 'parses' } }), { apply = false })
    eq('failed', g.status); eq('unbuilt', g.class, 'a verb breaking its own guard is a bug')
end)

test('tactic: a DRY repeat sees its own effect and converges; a failed dry alternative leaves no world behind', function ()
    if not ready() then skip 'no lua parser' end
    local root = mkroot(ORIG)
    local r = run(T.rep(T.step('upto', { file = 'a.lua', n = 3 })), { apply = false })
    eq('previewed', r.status, tostring(r.why)); eq(3, r.worlds, 'three marks, then the fourth iteration is empty')
    local _, marks = r.preview['a.lua']:gsub('%-%- mark', '')
    eq(3, marks); unchanged(root)
    -- first: alternative 1 previews a.lua and then fails; alternative 2 must plan against the world BEFORE it
    local f = run(T.first(T.seq(W('a.lua', { line = '-- abandoned' }), R('ill-posed', 'no')), W('b.lua')), { apply = false })
    eq('previewed', f.status, tostring(f.why)); eq(1, f.worlds)
    eq(nil, f.preview['a.lua'], 'the failed alternative\'s edit is not in the preview'); ok(f.preview['b.lua'])
end)

test('tactic: a NON-JOURNALED previewed step does not chain — its effect is more than the staged text', function ()
    if not ready() then skip 'no lua parser' end
    local root = mkroot(ORIG)
    shipped = 0
    local r = run(T.seq(T.step('comp', { file = 'a.lua' }), W('b.lua')), { apply = false })
    eq('previewed', r.status, tostring(r.why)); eq(0, shipped, 'a dry run ships nothing'); eq(0, r.worlds); unchanged(root)
    ok(tostring(r.trace[1].why):find('compensable', 1, true), tostring(r.trace[1].why))
    eq(true, r.trace[2] and r.trace[2].underivable, 'so the next step waits on it')
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
    ['learn-tactic'] = { { ['m.lua'] = 'local M = {}\nreturn M\n' },
        function () return { name = 'nil-check', before = 'if x == nil then return 0 end', after = 'if not x then return 0 end' } end },
    ['promote-tactic'] = { { ['.cartograph/tactics/count-functions.lua'] = 'return { name = \'count-functions\', kind = \'discovery\', summary = \'s\', params = {}, measure = function (store) local n = 0; for _, x in ipairs(store.data.nodes or {}) do if x.kind == \'function\' then n = n + 1 end end; return n end, claim = function (n) return n > 0, n .. \' function(s)\' end, examples = { { name = \'one\', files = { [\'a.lua\'] = \'local function f() end\\nreturn f\\n\' }, expect = { holds = true } } } }\n' },
        function () return { name = 'count-functions', from = store.data.root, into = store.data.root .. '/builtin' } end },
    edit = { { ['e.lua'] = 'local E = {}\nE.v = 1\nreturn E\n' }, function () return { file = 'e.lua', before = 'E.v = 1\n', after = 'E.v = 1\nE.w = 2\n' } end },
    release = { { ['app/x.txt'] = 'x\n' }, function () return { from = 'app', target = vim.fn.tempname() .. '-dw' } end,
        { 'target-write' }, function (a) vim.fn.mkdir(a.target, 'p'); return a.target end },
    switch = { { ['a.lua'] = 'return 1\n' }, function ()
            local t = vim.fn.tempname() .. '-dw'; vim.fn.mkdir(t .. '/releases/r1', 'p')
            return { target = t, release = 'r1' }
        end, { 'target-write', 'approve-deploy' }, function (a) return a.target end },
    undeploy = { { ['a.lua'] = 'return 1\n' }, function ()
            local t = vim.fn.tempname() .. '-dw'; vim.fn.mkdir(t, 'p')
            local fd = io.open(t .. '/CURRENT', 'w'); fd:write('r1\n'); fd:close()
            return { target = t }
        end, { 'target-write' }, function (a) return a.target end },
    ['rename-field'] = { { ['s.lua'] = 'return { scopes = 1 }\n', ['r.lua'] = 'local M = {}\nfunction M.f(spec) return spec.scopes end\nreturn M\n' },
        function () return { base = 'spec', field = 'scopes', to = 'lexical', define = { 's.lua' } } end },
    ['rewrite-by-example'] = { { ['q.lua'] = 'local Q = {}\nfunction Q.h(q)\n  if q == nil then return 3 end\n  return q\nend\nreturn Q\n' },
        function () return { before = 'if x == nil then return 0 end', after = 'if not x then return 0 end', scope = 'all' } end },
    propagate = { { ['fe.lua'] = (function ()
            local function b(n, mul) return ('function M.g%d(t)\n    local acc = 0\n    local seen = {}\n    for i = 1, #t do acc = acc + t[i] * %d end\n    local s = tostring(acc)\n    local u = string.upper(s)\n    seen[u] = true\n    local pad = string.rep("-", #u)\n    local out = pad .. u\n    return out .. "%d"\nend\n'):format(n, mul, n) end
            return 'local M = {}\n' .. b(1, 1) .. b(2, 2) .. b(3, 3) .. 'return M\n'
        end)() }, function ()
            return { ref = fn_ref('M.g1', 'fe.lua'), scope = 'all', text = 'function M.g1(t)\n    local acc = 0\n    local seen = {}\n    for i = 1, #t do acc = acc + t[i] * 9 end\n    local s = tostring(acc)\n    local u = string.upper(s)\n    seen[u] = true\n    local pad = string.rep("-", #u)\n    local out = pad .. u\n    return out .. "1"\nend' }
        end },
}
-- ⚠ EVERY file, hidden directories included: globpath's `**` skips them, and a verb that creates
-- `.cartograph/tactics/x.lua` would have read as "wrote nothing" (it did: learn-tactic's first run)
local function snap(root)
    local out = {}
    for name, ty in vim.fs.dir(root, { depth = 20 }) do
        if ty == 'file' then out[name] = read(root, name) end
    end
    return vim.inspect(out)
end

test('tactic: IDEMPOTENCE — every compose verb re-run with the same invocation is empty and writes nothing', function ()
    if not ready() then skip 'no lua parser' end
    local VB = require('cartograph.compose').VERBS
    for verb, spec in pairs(VB) do
        local c = IDEM[verb]
        ok(c, verb .. ' has an idempotence case (a verb without one is not assumed safe)')
        eq('empty', spec.rerun, verb .. ' declares its re-run')
        -- a DECLARED, known effect: journaled, or compensable with its inverse (CART-1186) — never undeclared (= irreversible)
        ok(spec.effect == 'journaled' or (spec.effect == 'compensable'), verb .. ' declares its effect: ' .. tostring(spec.effect))
        local root = mkroot(c[1])
        -- c[3] = the accept list (a cross-world verb's grant, a gate), c[4] = the OTHER world it writes (snapshotted too)
        local args = c[2]()
        local st = { verb = verb, args = args, accept = c[3] }
        local other = c[4] and c[4](args)
        local function snapall() return snap(root) .. (other and snap(other) or '') end
        local s0 = snapall()
        local r1 = tactic.step(store, st, { apply = true })
        local s1 = snapall()
        ok(r1.entry and s1 ~= s0, verb .. ': the FIRST run writes (else the second proves nothing): ' .. tostring(r1.why))
        local r2 = tactic.step(store, st, { apply = true })
        eq(true, r2.ok and r2.empty, verb .. ': the second run is empty: ' .. tostring(r2.why))
        eq(s1, snapall(), verb .. ': and writes nothing')
    end
end)

-- ── DID YOU MEAN (CART-1152): a refused step's arguments corrected, when the VERB accepts the correction ─────────
local function replace_step(ref, text) return T.step('replace', { ref = ref, text = text or 'function M.dbl(x) return x + x end' }, { 'supplied-text' }) end
local function corrected_of(r) for _, h in ipairs(r.residue or {}) do if h.kind == 'corrected' then return h end end end

test('near: every candidate within the slip budget, a transposition is one slip, and a tie is kept', function ()
    local near = require 'cartograph.near'
    eq(1, near.dist('on_tikc', 'on_tick', 2), 'a transposition is ONE slip')
    local w = near.within('M.dbb', { 'M.dba', 'M.dbc', 'M.keep', 'M.dbb' })
    eq({ 'M.dba', 'M.dbc' }, vim.tbl_map(function (c) return c.value end, w), 'both, nearest first — the key itself excluded')
end)

test('did-you-mean: an INFERRED correction (a slipped name) is a DECISION with the candidate — never applied behind the caller', function ()
    -- USER: "I wonder if the corrections can be surprising" — MEASURED yes: a hand-typed M.get was applied to M.set
    if not ready() then skip 'no lua parser' end
    local SRC = 'local M = {}\nfunction M.set(k, v) M[k] = v end\nreturn M\n'
    local root = mkroot { ['a.lua'] = SRC }
    local r = tactic.run(store, replace_step({ file = 'a.lua', name = 'M.get', kind = 'function' }, 'function M.get(k) return M[k] end'), { apply = true })
    eq('stopped', r.status); eq('decision', r.class)
    ok(r.options and r.options[1] and r.options[1].args and r.options[1].text:find('M.set', 1, true), vim.inspect(r.options))
    eq(SRC, read(root, 'a.lua'), 'M.set untouched: the accepted supplied-text decision was for M.get, not for it')
    eq(0, #r.corrections)
end)

test('did-you-mean: a stale ref to a symbol THIS RUN moved is corrected by PROVENANCE — also on the resume, where the move is empty', function ()
    if not ready() then skip 'no lua parser' end
    local root = mkroot { ['r.lua'] = R_LUA }
    local old = fn_ref('M.dbl', 'r.lua')
    local acc = {}
    -- the replace holds the OLD address, captured before the move: only the run's own move can vouch for the new one
    local term = T.seq(T.step('moveset', { seed_refs = { old }, dest = 'lib/new.lua' }, { 'surface' }),
        T.step('replace', { ref = old, text = 'function M.dbl(x) return x + x end' }, acc))
    local r = tactic.run(store, term, { apply = true })
    eq('stopped', r.status, 'corrected, then stopped at replace\'s own decision: ' .. tostring(r.why))
    eq('supplied-text', r.options and r.options[1] and r.options[1].kind)
    acc[1] = 'supplied-text'
    local done = tactic.run(store, term, { apply = true })
    eq('done', done.status, tostring(done.why))
    eq(1, #done.corrections, 'the correction is surfaced at the top of the result')
    ok(done.corrections[1].text:find('this run moved it there', 1, true), done.corrections[1].text)
    ok(read(root, 'lib/new.lua'):find('x + x', 1, true), 'the replacement landed at the new home')
    ok(not read(root, 'r.lua'):find('x + x', 1, true), 'and NOT on the neighbour')
end)

test('did-you-mean: a move nobody in this run made is INFERRED — a decision, even with the same name and shape', function ()
    -- MEASURED: a deleted a.lua::M.setup was "moved" onto an unrelated b.lua::M.setup of the same trivial shape
    if not ready() then skip 'no lua parser' end
    local root = mkroot { ['r.lua'] = R_LUA }
    local old = fn_ref('M.dbl', 'r.lua')
    ok(tactic.step(store, { verb = 'moveset', args = { seed_refs = { old }, dest = 'lib/new.lua' } }, { apply = true }).entry)
    local before = read(root, 'lib/new.lua')
    local r = tactic.run(store, replace_step(old), { apply = true })
    eq('stopped', r.status); eq('moved', r.options and r.options[1] and r.options[1].source)
    eq(before, read(root, 'lib/new.lua'), 'nothing applied on inference')
end)

test('did-you-mean: a WITNESSED ref whose symbol is GONE says so — near names are information, not the answer', function ()
    if not ready() then skip 'no lua parser' end
    local root = mkroot { ['a.lua'] = 'local M = {}\nfunction M.get(k) return M[k] end\nfunction M.set(k, v) M[k] = v end\nreturn M\n' }
    local old = fn_ref('M.get', 'a.lua')
    local AFTER = 'local M = {}\nfunction M.set(k, v) M[k] = v end\nreturn M\n'
    local fd = assert(io.open(root .. '/a.lua', 'w')); fd:write(AFTER); fd:close()
    store.ingest(ts.extract(root))
    local r = tactic.run(store, replace_step(old, 'function M.get(k) return nil end'), { apply = true })
    eq('failed', r.status); eq('stale', r.class)
    ok(r.why:find('GONE', 1, true) and r.why:find('for information', 1, true), r.why)
    eq(AFTER, read(root, 'a.lua'))
end)

test('did-you-mean: two equally near names are a DECISION with both as options; nothing is written', function ()
    if not ready() then skip 'no lua parser' end
    local src = 'local M = {}\nfunction M.dba(x) return x end\nfunction M.dbc(x) return x end\nreturn M\n'
    local root = mkroot { ['r.lua'] = src }
    local r = tactic.run(store, replace_step({ file = 'r.lua', name = 'M.dbb', kind = 'function' }, 'function M.dba(x) return 1 end'), { apply = true })
    eq('stopped', r.status); eq('decision', r.class)
    eq(2, r.options and #r.options, vim.inspect(r.options))
    ok(r.options[1].args and r.options[1].args.ref, 'each option carries the corrected invocation')
    eq(src, read(root, 'r.lua'))
end)

test('did-you-mean: a contradicting witness is flagged on its option', function ()
    if not ready() then skip 'no lua parser' end
    local SRC = 'local M = {}\nfunction M.two(x)\n  local y = x + 1\n  return y\nend\nfunction M.keep(x) return x + 1 end\nreturn M\n'
    local root = mkroot { ['r.lua'] = SRC }
    local wrong = fn_ref('M.two', 'r.lua')
    ok(wrong.witness and wrong.witness ~= fn_ref('M.keep', 'r.lua').witness, 'the premise: two DIFFERENT shapes')
    wrong.name = 'M.kep'
    local r = tactic.run(store, replace_step(wrong, 'function M.keep(x) return 0 end'), { apply = true })
    eq('stopped', r.status)
    local keep, renamed
    for _, o in ipairs(r.options or {}) do
        if o.text:find('M.keep', 1, true) and o.text:find('CONTRADICTS', 1, true) then keep = o end
        if o.source == 'renamed' and o.text:find('M.two', 1, true) then renamed = o end
    end
    ok(keep, 'the near name is offered, flagged as contradicting the witness: ' .. vim.inspect(r.options))
    ok(renamed, 'and the function that still has the ref\'s shape is offered as a possible RENAME')
    eq(SRC, read(root, 'r.lua'))
end)

test('did-you-mean: a candidate the VERB refuses does not survive; no candidate at all is the original refusal', function ()
    if not ready() then skip 'no lua parser' end
    mkroot { ['r.lua'] = R_LUA }
    -- M.keep has no clone: clonemerge answers `empty` for it, so the correction is dropped
    local r = tactic.run(store, T.step('clonemerge', { ref = { file = 'r.lua', name = 'M.kep', kind = 'function' } }), { apply = true })
    eq('failed', r.status); ok(r.why:find('no correction survived: 1 candidate', 1, true), r.why)
    local n = tactic.run(store, replace_step({ file = 'r.lua', name = 'M.zzzzzz', kind = 'function' }), { apply = true })
    eq('failed', n.status); ok(n.why:find('does not resolve', 1, true) and not n.why:find('survived', 1, true), n.why)
end)

test('did-you-mean: correct = ask makes even a PROVENANCE correction a decision; off disables it', function ()
    if not ready() then skip 'no lua parser' end
    local function scenario()
        mkroot { ['r.lua'] = R_LUA }
        local old = fn_ref('M.dbl', 'r.lua')
        return T.seq(T.step('moveset', { seed_refs = { old }, dest = 'lib/new.lua' }, { 'surface' }),
            T.step('replace', { ref = old, text = 'function M.dbl(x) return x + x end' }, { 'supplied-text' }))
    end
    local a = tactic.run(store, scenario(), { apply = true, correct = 'ask' })
    eq('stopped', a.status); eq(true, a.options and a.options[1] and a.options[1].proven, vim.inspect(a.options))
    eq('failed', tactic.run(store, scenario(), { apply = true, correct = 'off' }).status)
end)

test('spec-fails (the mutation oracle): the SUMMARY LINE decides; a spec that HANGS is a FAILURE named as a timeout, and its whole process group dies with it', function ()
    local SF = require 'cartograph.tactics.spec-fails'
    local function root(script)
        local r = vim.fn.tempname()
        vim.fn.mkdir(r .. '/tests', 'p')
        local fd = assert(io.open(r .. '/tests/run.sh', 'w')); fd:write(script); fd:close()
        return r
    end
    local v = assert(SF.run(root('echo "3 passed, 1 failed, 0 skipped"\n'), 'x_spec', 20000))
    eq({ 3, 1, false }, { v.passed, v.failed, v.timed_out == true })
    -- a hang (measured: a mutation that made a transliterated loop infinite): bounded, a failure, its child killed
    local mark = vim.fn.tempname()
    local t0 = vim.uv.hrtime()
    local h = assert(SF.run(root(('sleep 300 & echo $! > %s\nwait\n'):format(mark)), 'x_spec', 1500))
    ok(h.timed_out and h.failed == 1 and h.summary:find('TIMED OUT', 1, true), vim.inspect(h))
    ok((vim.uv.hrtime() - t0) / 1e9 < 30, 'the timeout bounds the run')
    local fd = assert(io.open(mark)); local pid = vim.trim(fd:read('a')); fd:close()
    local gone = vim.wait(3000, function () return vim.system({ 'kill', '-0', pid }):wait().code ~= 0 end, 50)
    ok(gone, 'the hung child ' .. pid .. ' was killed with its process group')
end)
