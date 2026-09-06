-- THE WRITE AXIS OF THE AGENT SURFACE (CART-0146) — plan → preview → journal →
-- apply → undo, in lua/cartograph/agent.lua and over tools/mcpserve.lua.
--
-- WHAT THESE SPECS FENCE, and it is not "the verbs work":
--
--   1 PLANNING AND PREVIEWING WRITE NOTHING. That is the whole reason the ticket
--     put them first, and it is a property of a PROCESS (bytes on disk, entries
--     in a journal), so it is asserted by reading the disk back, never by
--     trusting a return value.
--   2 THE LATE-BOUND LADDER REFUSES, AND IS SEEN REFUSING. A write verb that has
--     only ever been watched succeeding is not tested — the four rungs
--     (generation match, refs witness-clean, stamp CAS, no dirty buffers) are
--     what lets apply be exposed to a machine at all, so one of them is BROKEN
--     ON PURPOSE below and the refusal is driven over the wire.
--   3 A REF CAVEAT IS AN ANSWER ON THE READ SIDE AND A REFUSAL ON THIS ONE. The
--     same ref, the same graph, two verbs, two dispositions — asserted together
--     in one test so the asymmetry cannot be "fixed" by accident.
--   4 THE PERMISSION IS REACHABLE. --write is a documented host mode exactly as
--     --index-only is, so `read-only` is a refusal a caller can actually
--     provoke rather than a branch nobody can reach (CART-0580).
--
-- TWO LAYERS, the split mcpserve_spec established: the verb table IN PROCESS
-- (fast, and where the envelope invariant lives), the host END TO END (because
-- "a plan handle survives between two JSON-RPC calls" is a property of the
-- server's process and cannot be asserted any other way).
--
-- EVERY BYTE THIS FILE WRITES GOES TO A TEMP DIR IT CREATED. No spec here opens
-- the running checkout: repo() is used only to find tools/mcpserve.lua.

local agent = require 'cartograph.agent'
local journal = require 'cartograph.journal'
local mcp = require 'cartograph.mcp'
local store = require 'cartograph.store'
local ts = require 'cartograph.providers.treesitter'

local function ready()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    return pcall(vim.treesitter.language.add, 'lua')
end

-- ── fixtures ────────────────────────────────────────────────────────────────

-- a redundant computation optapply's CSE verb will plan a reuse for, plus a
-- caller so the moved/edited function is not an island
local CSE_LUA = {
    'local M = {}',
    'function M.f(x, y)',
    '  local a = x + y',
    '  local b = x + y',
    '  return a, b',
    'end',
    'function M.g(x) return M.f(x, 1) end',
    'return M',
}

-- a module with one function worth extracting and one caller in another file,
-- so a move plan touches three files (dest, source, caller)
local SRC_LUA = {
    'local M = {}',
    '',
    '-- doubles a number',
    'function M.dbl(x) return x * 2 end',
    '',
    'function M.keep(x) return x + 1 end',
    '',
    'return M',
}
local USE_LUA = {
    "local src = require 'src'",
    'local U = {}',
    'function U.go(x) return src.dbl(x) end',
    'return U',
}

local ROOTS = {}

local function mkroot(files)
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    for name, lines in pairs(files) do
        write(root, name, lines)
    end
    ROOTS[#ROOTS + 1] = root
    return root
end

local function ingest(root)
    local data = ts.extract(root)
    data.root = data.root or root
    store.ingest(data)
    return store
end

local function idof(name)
    for _, n in ipairs(store.data.nodes) do
        if n.name == name and (n.kind == 'function' or n.kind == 'method') then return n.id end
    end
end

local function read(root, rel)
    return table.concat(vim.fn.readfile(root .. '/' .. rel), '\n')
end

--- every test sets the permission explicitly rather than restoring it, so a
--- failure in one cannot silently change what the next one is testing
local function permit(on) agent.set_writable(on) end

local function call(verb, args) return (agent.answer(store, verb, args or {})) end

local WRITE_VERBS = { 'txn_plan_moveset', 'txn_plan_optimize', 'txn_plan_declare',
    'txn_preview', 'journal_list', 'journal_get', 'txn_apply', 'txn_undo' }

-- ── layer 1: the verb table, in process ─────────────────────────────────────

test('agentwrite: PLANNING AND PREVIEWING WRITE NOTHING — asserted off the disk', function ()
    if not ready() then skip('no treesitter') end
    permit(true) -- even with permission granted, these two must not write
    local root = mkroot { ['m.lua'] = CSE_LUA }
    ingest(root)
    local before = read(root, 'm.lua')

    local p = call('txn_plan_optimize', { kind = 'cse', node = idof('M.f') })
    eq(true, p.ok, 'the plan answered')
    eq(1, #p.result, 'one rewrite proposed')
    local pid = p.subject.plan
    ok(type(pid) == 'string', 'and handed back a plan handle: ' .. vim.inspect(p.subject))

    local d = call('txn_preview', { plan = pid })
    eq(true, d.ok)
    eq(1, #d.result, 'one file would change')
    ok(table.concat(d.result[1].diff, '\n'):match('%+%s*local b = a'),
        'and the diff shows the rewrite')

    eq(before, read(root, 'm.lua'), 'THE FILE IS BYTE-IDENTICAL after plan + preview')
    eq(0, #journal.list(root), 'and no journal entry was opened')
end)

test('agentwrite: a preview declares its own COVERAGE — the four rungs it does not assert', function ()
    if not ready() then skip('no treesitter') end
    permit(false) -- previewing needs no permission, which is the point
    local root = mkroot { ['m.lua'] = CSE_LUA }
    ingest(root)
    local pid = call('txn_plan_optimize', { kind = 'cse', node = idof('M.f') }).subject.plan
    local d = call('txn_preview', { plan = pid })
    eq(true, d.ok, 'a READ-ONLY host still proposes and diffs — the ticket\'s stop-here value')
    local cov
    for _, n in ipairs(d.notes) do if n.kind == 'preview-coverage' then cov = n end end
    ok(cov, 'the preview names what it does not assert: ' .. vim.inspect(d.notes))
    eq(4, #cov.evidence.late_bound_rungs, 'and lists the rungs still ahead of it')
    ok(cov.why:find('plan.edit_of', 1, true),
        'and says the diff came from the SAME callback the apply runs, not a second simulation')
end)

test('agentwrite: no candidate is ABSENT, no instrument is REFUSED — and they never merge', function ()
    if not ready() then skip('no treesitter') end
    permit(false)
    local root = mkroot { ['m.lua'] = CSE_LUA }
    ingest(root)
    -- M.g has no redundant computation: the analysis RAN and found nothing
    local none = call('txn_plan_optimize', { kind = 'cse', node = idof('M.g') })
    eq(true, none.ok, 'an absence is an ANSWER')
    eq(0, #none.result)
    eq('absent', none.absence)
    eq('no-candidates', none.absence_why.premise)

    -- an id that is not in this graph: the instrument could not look at all
    local bad = call('txn_plan_optimize', { kind = 'cse', node = 'no::such@1' })
    eq(false, bad.ok, 'a missing subject is a REFUSAL, never "nothing to optimize"')
    eq('unknown-node', bad.refusal.rule)
    ok(bad.absence == vim.NIL, 'and a refusal carries no absence')
end)

test('agentwrite: every plan answer carries the `declined` ledger, present even when empty', function ()
    if not ready() then skip('no treesitter') end
    permit(false)
    local root = mkroot { ['m.lua'] = CSE_LUA }
    ingest(root)
    local cases = {
        call('txn_plan_optimize', { kind = 'cse', node = idof('M.f') }), -- a plan
        call('txn_plan_optimize', { kind = 'cse', node = idof('M.g') }), -- an absence
    }
    for i, doc in ipairs(cases) do
        local led
        for _, n in ipairs(doc.notes) do if n.kind == 'declined' then led = n end end
        ok(led, ('case %d carries the ledger'):format(i))
        ok(type(led.evidence.declined) == 'table',
            'and the field is PRESENT even when empty — a caller never has to tell'
            .. ' "nothing was declined" from "the ledger was not filled in"')
    end
end)

test('agentwrite: a ref CAVEAT answers on the read side and REFUSES on the write side', function ()
    if not ready() then skip('no treesitter') end
    permit(true)
    local root = mkroot { ['m.lua'] = CSE_LUA }
    ingest(root)
    local ref = store.ref_of(idof('M.f'))
    ok(ref and ref.witness, 'the ref was minted with a witness: ' .. vim.inspect(ref))

    -- edit the BODY: the witness drifts, so the ref still resolves but only with
    -- a caveat. This is the shape phase 2 chose to answer on.
    write(root, 'm.lua', {
        'local M = {}',
        'function M.f(x, y)',
        '  local a = x + y',
        '  local b = x + y',
        '  local c = a * b',
        '  return a, b, c',
        'end',
        'function M.g(x) return M.f(x, 1) end',
        'return M',
    })
    ingest(root)
    local _, note = store.resolve_ref(ref)
    ok(note, 'the ref now resolves WITH a caveat: ' .. tostring(note))

    local rd = call('edges_callers', { ref = ref })
    eq(true, rd.ok, 'the READ side answers — a wrong answer there is recoverable')
    local caveat
    for _, n in ipairs(rd.notes) do if n.kind == 'ref-caveat' then caveat = n end end
    ok(caveat, 'and rides the caveat as a note: ' .. vim.inspect(rd.notes))

    local wr = call('txn_plan_optimize', { kind = 'cse', ref = ref })
    eq(false, wr.ok, 'the WRITE side REFUSES the same handle')
    eq('ref-caveat', wr.refusal.rule)
    eq(note, wr.refusal.why, 'carrying refs.lua\'s own reason verbatim, not a paraphrase')

    -- and a seed ARRAY is held to the same rule, element-wise
    local mv = call('txn_plan_moveset', { seed_refs = { ref }, dest = 'lib/new.lua' })
    eq(false, mv.ok, 'including inside a move-set seed, where a wrong pick is worst')
    eq('ref-caveat', mv.refusal.rule)
end)

test('agentwrite: a plan handle dies with its generation rather than diffing stale offsets', function ()
    if not ready() then skip('no treesitter') end
    permit(true)
    local root = mkroot { ['m.lua'] = CSE_LUA }
    ingest(root)
    local pid = call('txn_plan_optimize', { kind = 'cse', node = idof('M.f') }).subject.plan
    ingest(root) -- a fresh ingest bumps the generation, as any edit would

    local d = call('txn_preview', { plan = pid })
    eq(false, d.ok, 'PREVIEW refuses too, not only apply: txn.dryrun does not check the'
        .. ' generation, so a stale preview would print a confident wrong patch')
    eq('stale-plan', d.refusal.rule)

    local a = call('txn_apply', { plan = pid })
    eq(false, a.ok)
    eq('stale-plan', a.refusal.rule)

    local u = call('txn_preview', { plan = 'plan-does-not-exist' })
    eq(false, u.ok)
    eq('unknown-plan', u.refusal.rule, 'and an unknown handle refuses by its own name')
end)

test('agentwrite: apply refuses a plan nobody has looked at', function ()
    if not ready() then skip('no treesitter') end
    permit(true)
    local root = mkroot { ['m.lua'] = CSE_LUA }
    ingest(root)
    local before = read(root, 'm.lua')
    local pid = call('txn_plan_optimize', { kind = 'cse', node = idof('M.f') }).subject.plan
    local a = call('txn_apply', { plan = pid })
    eq(false, a.ok, 'the preview step is a PRECONDITION on a machine transport,'
        .. ' not a human convention')
    eq('unpreviewed', a.refusal.rule)
    eq(before, read(root, 'm.lua'), 'and nothing was written')
end)

test('agentwrite: THE LATE-BOUND LADDER REFUSES on stamp drift, after a green preview', function ()
    if not ready() then skip('no treesitter') end
    permit(true)
    local root = mkroot { ['m.lua'] = CSE_LUA }
    ingest(root)
    local pid = call('txn_plan_optimize', { kind = 'cse', node = idof('M.f') }).subject.plan
    eq(true, call('txn_preview', { plan = pid }).ok, 'the preview is green')

    -- someone else edits the file between the diff and the apply. This is the
    -- exact window the CAS rung exists for, and a green preview does not close it.
    local fd = assert(io.open(root .. '/m.lua', 'a'))
    fd:write('-- a third party got here first\n')
    fd:close()
    local drifted = read(root, 'm.lua')

    local a = call('txn_apply', { plan = pid })
    eq(false, a.ok, 'apply REFUSES: a green preview asserts nothing about the'
        .. ' late-bound rungs, and this spec exists to keep it that way')
    eq('apply-refused', a.refusal.rule)
    ok(a.refusal.reason:find('changed on disk', 1, true),
        'carrying txn.verify\'s own reason: ' .. a.refusal.reason)
    eq(drifted, read(root, 'm.lua'), 'and the third party\'s edit is untouched')
    eq(0, #journal.list(root), 'the journal never opened — the refusal precedes it')
end)

test('agentwrite: apply → journal_get → undo, and the tree comes back byte-exact', function ()
    if not ready() then skip('no treesitter') end
    permit(true)
    local root = mkroot { ['src.lua'] = SRC_LUA, ['use.lua'] = USE_LUA }
    ingest(root)
    local before = { src = read(root, 'src.lua'), use = read(root, 'use.lua') }

    -- extract-module: the richer family — it CREATES a file, cuts from a second
    -- and requalifies a call site in a third
    local p = call('txn_plan_moveset', { seed = { idof('M.dbl') }, dest = 'lib/math.lua' })
    eq(true, p.ok, 'the move-set planned: ' .. vim.inspect(p.refusal))
    eq('extract-module', p.subject.verb, 'a dest that does not exist yet is an EXTRACT')
    local pid = p.subject.plan
    eq(true, call('txn_preview', { plan = pid }).ok)

    local a = call('txn_apply', { plan = pid })
    eq(true, a.ok, 'the apply wrote: ' .. vim.inspect(a.refusal))
    eq(3, #a.result, 'three files: the created module, the source, the caller')
    ok(read(root, 'lib/math.lua'):find('function M.dbl', 1, true), 'the new module has the function')
    ok(not read(root, 'src.lua'):find('function M.dbl', 1, true), 'and the source no longer does')

    local jid = a.subject.journal
    local entries = call('journal_list', {})
    eq(true, entries.ok)
    eq(jid, entries.result[1].id, 'the journal lists it, newest first')
    eq(true, entries.result[1].undoable, 'marked as the entry undo would target')
    for _, row in ipairs(entries.result) do
        eq(nil, row.before, 'a list row carries NO file content')
        eq(nil, row.after, 'in either direction — journal_get serves the bytes')
    end

    local g = call('journal_get', { id = jid })
    eq(true, g.ok)
    eq(3, #g.result)
    ok(table.concat(g.result[1].diff, '\n'):find('@@', 1, true), 'with a real diff')

    -- a plan applied is a plan consumed: the handle must not be reusable
    local again = call('txn_apply', { plan = pid })
    eq(false, again.ok)
    ok(again.refusal.rule == 'unknown-plan' or again.refusal.rule == 'stale-plan',
        'an applied plan describes a tree that no longer exists, got ' .. again.refusal.rule)

    local u = call('txn_undo', {})
    eq(true, u.ok, 'undo: ' .. vim.inspect(u.refusal))
    eq(before.src, read(root, 'src.lua'), 'src.lua restored BYTE-EXACT')
    eq(before.use, read(root, 'use.lua'), 'use.lua too')
    eq(0, vim.fn.filereadable(root .. '/lib/math.lua'),
        'and a file the apply CREATED undoes to its deletion, never to an empty husk')

    local none = call('txn_undo', {})
    eq(false, none.ok, 'a second undo has nothing to roll back')
    eq('undo-refused', none.refusal.rule)
end)

test('agentwrite: a read-only host refuses every mutating verb, and graph_info says so', function ()
    if not ready() then skip('no treesitter') end
    permit(false)
    local root = mkroot { ['m.lua'] = CSE_LUA }
    ingest(root)
    local cat = {}
    for _, r in ipairs(call('graph_info', {}).result) do cat[r.verb] = r end
    for _, name in ipairs(WRITE_VERBS) do
        ok(cat[name], name .. ' is in the catalogue')
    end
    eq(false, cat.txn_plan_optimize.mutates, 'planning does not write')
    eq(true, cat.txn_plan_optimize.available, 'so it is available on a read-only host')
    eq(true, cat.txn_apply.mutates)
    eq(false, cat.txn_apply.available, 'and apply is not')
    ok(#cat.txn_apply.unavailable_why > 20, 'with the reason stated, not implied by silence')

    for _, case in ipairs({ { 'txn_apply', { plan = 'plan-1' } }, { 'txn_undo', {} } }) do
        local doc = call(case[1], case[2])
        eq(false, doc.ok, case[1] .. ' refuses')
        -- and it refuses BEFORE looking at the plan handle: a caller must not be
        -- able to probe which handles exist on a host that will not write for them
        eq('read-only', doc.refusal.rule)
        ok(doc.refusal.remedy:find('--write', 1, true), 'and says how to grant it')
    end
    permit(false)
end)

test('agentwrite: the declared absences are the ones the verbs can actually emit', function ()
    if not ready() then skip('no treesitter') end
    -- CART-0580 in its general form: a value listed in `absences` that no branch
    -- reaches is a contract a caller cannot verify. This is the weaker half that
    -- CAN be checked mechanically — every absence a verb emits must be declared.
    permit(false)
    local root = mkroot { ['m.lua'] = CSE_LUA }
    ingest(root)
    local seen = {
        txn_plan_optimize = call('txn_plan_optimize', { kind = 'cse', node = idof('M.g') }),
        journal_list = call('journal_list', {}),
    }
    for verb, doc in pairs(seen) do
        if doc.absence ~= vim.NIL then
            ok(vim.tbl_contains(agent.VERBS[verb].absences, doc.absence),
                ('%s emitted absence %q, which it does not declare'):format(verb, doc.absence))
        end
    end
end)

-- ── layer 2: the host, over stdio ───────────────────────────────────────────

local SERVERS = {}

--- a live client against a server on its OWN fixture root. Write specs mutate
--- the tree, so they never share a root with anything else — a fixture one test
--- edits is a fixture no other test can make assertions about.
local function server(key, files, writable)
    if SERVERS[key] then return SERVERS[key].c, SERVERS[key].root end
    local root = mkroot(files)
    local cmd = { vim.v.progpath, '--headless', '-u', 'NONE', '-l',
        repo('tools/mcpserve.lua'), root }
    if writable then cmd[#cmd + 1] = '--write' end
    local c, err = mcp.connect { cmd = cmd, timeout = 60000 }
    ok(c ~= nil, 'mcpserve did not come up: ' .. tostring(err))
    SERVERS[key] = { c = c, root = root }
    return c, root
end

test('mcpserve: the write verbs are ADVERTISED on a read-only host, not hidden', function ()
    if not ready() then skip('no treesitter') end
    local c = server('ro', { ['m.lua'] = CSE_LUA }, false)
    local res = c:request('tools/list', vim.empty_dict())
    ok(res ~= nil, 'tools/list answered')
    local by = {}
    for _, t in ipairs(res.tools) do by[t.name] = t end
    for _, name in ipairs(WRITE_VERBS) do
        ok(by[name], 'advertised: ' .. name)
        ok(by[name].name:match('^[%w_-]+$'), 'with a portable name')
    end
    -- hiding a gated verb would render the permission as SILENCE: the client
    -- would conclude the capability does not exist rather than is not granted
    ok(by.txn_apply.description:find('READ%-ONLY'),
        'and txn_apply says it is gated: ' .. by.txn_apply.description)
    -- the seed array publishes the REF SHAPE, so a schema-driven client can hand
    -- back the refs it was given instead of reducing them to strings
    local seed = by.txn_plan_moveset.inputSchema.properties.seed_refs
    eq('array', seed.type)
    eq('object', seed.items.type)
    ok(vim.tbl_contains(seed.items.required, 'witness') == false
        and vim.tbl_contains(seed.items.required, 'name'), 'items are refs, name required')
end)

test('mcpserve: a read-only host PROPOSES and DIFFS, and refuses only the write', function ()
    if not ready() then skip('no treesitter') end
    local c, root = server('ro', { ['m.lua'] = CSE_LUA }, false)
    local before = read(root, 'm.lua')
    local found = c:call('node_find', { query = 'M.f' })
    ok(found and found.ok, 'found the function: ' .. vim.inspect(found))
    local id = found.result[1].id

    local p = c:call('txn_plan_optimize', { kind = 'cse', node = id })
    eq(true, p.ok, 'planning needs no permission: ' .. vim.inspect(p.refusal))
    local pid = p.subject.plan
    local d = c:call('txn_preview', { plan = pid })
    eq(true, d.ok, 'and neither does diffing')
    ok(table.concat(d.result[1].diff, '\n'):match('%+%s*local b = a'),
        'the human sees the exact patch BEFORE any apply capability exists')

    local a, _, raw = c:call('txn_apply', { plan = pid })
    eq(false, raw.isError, 'a refusal is an ANSWER on this wire, not a fault')
    eq(false, a.ok)
    eq('read-only', a.refusal.rule)
    eq(before, read(root, 'm.lua'), 'and the tree is untouched')
end)

test('mcpserve: a write host applies over the wire — and refuses when a rung breaks', function ()
    if not ready() then skip('no treesitter') end
    local c, root = server('rw', { ['m.lua'] = CSE_LUA }, true)
    local id = c:call('node_find', { query = 'M.f' }).result[1].id

    -- FIRST: break a precondition and watch the ladder refuse. A write verb seen
    -- only succeeding is not tested.
    local p1 = c:call('txn_plan_optimize', { kind = 'cse', node = id })
    eq(true, p1.ok, 'planned: ' .. vim.inspect(p1.refusal))
    eq(true, c:call('txn_preview', { plan = p1.subject.plan }).ok, 'previewed green')
    local fd = assert(io.open(root .. '/m.lua', 'a'))
    fd:write('-- a third party got here first\n')
    fd:close()
    local drifted = read(root, 'm.lua')
    local refused = c:call('txn_apply', { plan = p1.subject.plan })
    eq(false, refused.ok, 'the stamp CAS refused the write')
    eq('apply-refused', refused.refusal.rule)
    ok(refused.refusal.reason:find('changed on disk', 1, true), refused.refusal.reason)
    eq(drifted, read(root, 'm.lua'), 'nothing was written over the third party')

    -- THEN: a fresh plan re-stamps, and the same call succeeds
    local p2 = c:call('txn_plan_optimize', { kind = 'cse', node = id })
    eq(true, p2.ok, 're-planned against the current disk: ' .. vim.inspect(p2.refusal))
    eq(true, c:call('txn_preview', { plan = p2.subject.plan }).ok)
    local a = c:call('txn_apply', { plan = p2.subject.plan })
    eq(true, a.ok, 'applied over the wire: ' .. vim.inspect(a.refusal))
    ok(read(root, 'm.lua'):find('local b = a', 1, true), 'the rewrite is on disk')
    ok(read(root, 'm.lua'):find('third party', 1, true), 'and the other edit survived it')

    local jl = c:call('journal_list', {})
    eq(true, jl.ok)
    eq(a.subject.journal, jl.result[1].id, 'the journal, read over the same wire')

    local u = c:call('txn_undo', {})
    eq(true, u.ok, 'undo: ' .. vim.inspect(u.refusal))
    eq(drifted, read(root, 'm.lua'), 'restored byte-exact to the pre-apply bytes')
end)

test('agentwrite: the servers shut down and the fixtures are removed', function ()
    if not ready() then skip('no treesitter') end
    for _, s in pairs(SERVERS) do s.c:close() end
    SERVERS = {}
    for _, root in ipairs(ROOTS) do
        journal.wipe(root)
        vim.fn.delete(root, 'rf')
    end
    ROOTS = {}
    permit(false) -- leave the module as the host finds it
    ok(true)
end)

-- ── CART-0583: a read-only host must not reach into session state ───────────

test('agentwrite: a READ-ONLY host plans WITHOUT arming, and says so', function ()
    if not ready() then skip('no treesitter') end
    permit(false) -- the operator started this host read-only
    local root = mkroot { ['m.lua'] = SRC_LUA }
    ingest(root)
    local seed = idof('M.dbl')
    ok(seed, 'fixture has a function to move')

    -- a cockpit user on this session already had something staged
    store.clear_stage()
    store.stage(seed)
    store.set_dest('m.lua')
    local staged_before = #store.staged_ids()

    local p = call('txn_plan_moveset', { seed = { seed }, dest = 'sub/new.lua' })
    eq(true, p.ok, 'planning is still ALLOWED read-only — it writes nothing')

    -- ★ the whole point: their move-set is untouched. Staging is ARMING, and this
    -- host can never fire, so arming would only cost them their state.
    eq(staged_before, #store.staged_ids(), 'the live move-set was not re-staged')
    eq(seed, store.staged_ids()[1], 'and it is still THEIR symbol')
    eq('m.lua', store.dest, 'nor was the destination moved')

    -- and the disclosure differs from the armed case rather than being dropped:
    -- `staged` and `unarmed` are opposite claims and must not render alike
    local kinds = {}
    for _, n in ipairs(p.notes or {}) do kinds[n.kind] = n end
    ok(kinds.unarmed, 'a read-only plan discloses that it did NOT stage')
    ok(not kinds.staged, 'and does not claim it did')
    ok(kinds.unarmed.why:find('previewed'), 'it says what the plan is still good for')
    store.clear_stage()
end)

test('agentwrite: a WRITABLE host still arms, and still says so', function ()
    if not ready() then skip('no treesitter') end
    permit(true)
    local root = mkroot { ['m.lua'] = SRC_LUA }
    ingest(root)
    local seed = idof('M.dbl')
    ok(seed, 'fixture has a function to move')
    store.clear_stage()

    local p = call('txn_plan_moveset', { seed = { seed }, dest = 'sub/new.lua' })
    eq(true, p.ok)
    -- arming is what makes the plan applyable; the note is the disclosure that
    -- session state moved. Both halves stay true on a writable host.
    ok(#store.staged_ids() > 0, 'the plan IS armed here')
    local kinds = {}
    for _, n in ipairs(p.notes or {}) do kinds[n.kind] = n end
    ok(kinds.staged, 'and the staging side effect is disclosed')
    ok(not kinds.unarmed, 'not the read-only note')
    store.clear_stage()
end)

-- ── txn_plan_declare: the whole loop, over the agent surface ─────────────────
-- CART-0763 measured the gap this verb closes: a day of real work was 15
-- commits, ZERO file moves, diffs `+158/-0` and `+130/-1`. The work is
-- INSERTION, and no shipped verb modelled it — so none of that day could have
-- gone through the ladder however reliable the ladder became.

local function declare_root()
    local root = mkroot({ ['m.lua'] = {
        'local SOLE_WRAP = { argument = true, condition_clause = true }',
        'local function use() return SOLE_WRAP end',
        'return { use = use, SOLE_WRAP = SOLE_WRAP }',
    } })
    ingest(root)
    return root
end

local function var_id(name)
    for _, n in ipairs(store.data.nodes) do
        if n.name == name and n.kind == 'var' then return n.id end
    end
end

test('agentwrite: txn_plan_declare plans, previews and applies a table entry', function ()
    if not ready() then return skip('no lua parser') end
    local root = declare_root()
    permit(true)
    local id = var_id('SOLE_WRAP')
    if not id then return skip('no var node') end

    local d = call('txn_plan_declare', { node = id, member = 'subscript_list = true' })
    ok(d.subject and d.subject.plan, 'planned: ' .. vim.inspect(d.refusal or d.error))
    -- ★ THE PLAN SAYS WHAT IT WILL BE CHECKED AGAINST, as a note rather than a
    -- promise: both guards REFUSE rather than warn, and neither claims the
    -- change is correct.
    local guards
    for _, n in ipairs(d.notes or {}) do if n.kind == 'guards' then guards = n end end
    ok(guards, 'the answer declares its guards')
    eq('parses', guards.evidence.guards[1])
    eq('shape-preserved', guards.evidence.guards[2])

    -- PLANNING WROTE NOTHING
    ok(not read(root, 'm.lua'):find('subscript_list', 1, true), 'the file is untouched')

    local p = call('txn_preview', { plan = d.subject.plan })
    ok(p.result and #p.result > 0, 'previewed: ' .. vim.inspect(p.refusal or p.error))
    ok(not read(root, 'm.lua'):find('subscript_list', 1, true), 'preview wrote nothing either')

    local a = call('txn_apply', { plan = d.subject.plan })
    ok(a.subject ~= nil and type(a.subject) == 'table' and a.subject.journal,
        'applied: ' .. vim.inspect(a.refusal or a.error))
    local after = read(root, 'm.lua')
    ok(after:find('condition_clause = true, subscript_list = true', 1, true),
        'placed after the last member, with the separator taken from the source: ' .. after)
end)

-- ⚠ THE DOMINANT REPLY, so it is fenced like an answer. 54.9% of container literals with
-- two or more members share NO shape, and the refusal must describe the
-- CONTAINER rather than the caller's syntax.
test('agentwrite: txn_plan_declare REFUSES a payload of the wrong shape, naming the divergence', function ()
    if not ready() then return skip('no lua parser') end
    declare_root()
    permit(true)
    local id = var_id('SOLE_WRAP')
    if not id then return skip('no var node') end
    local d, status = agent.answer(store, 'txn_plan_declare',
        { node = id, member = "'a bare string'" })
    eq('refusal', status)
    ok(d.refusal.reason:find('does not fit the ones already there'), d.refusal.reason)
    ok(d.refusal.reason:find('leaf%-vs%-tree') or d.refusal.reason:find('size%-skew')
        or d.refusal.reason:find('drift'),
        'and carries a ranked feature, not just a verdict: ' .. d.refusal.reason)
end)

test('agentwrite: txn_plan_declare with no payload refuses by name', function ()
    if not ready() then return skip('no lua parser') end
    declare_root()
    permit(true)
    local id = var_id('SOLE_WRAP')
    if not id then return skip('no var node') end
    local d, status = agent.answer(store, 'txn_plan_declare', { node = id })
    eq('refusal', status)
    eq('no-payload', d.refusal.rule)
end)
