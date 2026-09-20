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
    'txn_plan_annotate', 'txn_plan_extract_family', 'txn_preview', 'journal_list',
    'journal_get', 'txn_apply', 'txn_undo' }

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

-- ⚠ THE DOMINANT REPLY, so it is fenced like an answer. 70.6% of containers with
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

-- ── txn_plan_annotate: the whole loop, over the agent surface ────────────────
-- The arc's own metric asked for this verb: comment prose is 50.2% of added
-- lines against the table-entry case's 4.5%. A verb that exists only as a
-- library function is not IN the loop, which is what this surface is for.

test('agentwrite: txn_plan_annotate plans, previews and applies prose', function ()
    if not ready() then return skip('no lua parser') end
    local root = mkroot({ ['m.lua'] = {
        '-- a module',
        'local function helper(x)',
        '    return x + 1',
        'end',
        'return { helper = helper }',
    } })
    ingest(root)
    permit(true)
    local id = idof('helper')
    if not id then return skip('no node') end

    local d = call('txn_plan_annotate', { node = id, text = 'what it does\nand why' })
    ok(d.subject and d.subject.plan, 'planned: ' .. vim.inspect(d.refusal or d.error))
    -- ★ THE ANSWER SAYS WHERE THE STYLE CAME FROM, because "we borrowed it from
    -- another file" is a thing a caller must be able to see.
    local donor, guards
    for _, n in ipairs(d.notes or {}) do
        if n.kind == 'style-donor' then donor = n end
        if n.kind == 'guards' then guards = n end
    end
    ok(donor and donor.evidence.prefix == '--', 'the sliced prefix is disclosed')
    eq('comment-inert', guards.evidence.guards[2])

    ok(not read(root, 'm.lua'):find('what it does', 1, true), 'planning wrote nothing')
    local p = call('txn_preview', { plan = d.subject.plan })
    ok(p.result and #p.result > 0, 'previewed: ' .. vim.inspect(p.refusal or p.error))
    ok(not read(root, 'm.lua'):find('what it does', 1, true), 'preview wrote nothing')

    local a = call('txn_apply', { plan = d.subject.plan })
    ok(type(a.subject) == 'table' and a.subject.journal,
        'applied: ' .. vim.inspect(a.refusal or a.error))
    local after = read(root, 'm.lua')
    ok(after:find('-- what it does\n-- and why\nlocal function helper', 1, true),
        'both lines, prefixed, directly above the definition: ' .. after)
end)

-- ★ TWO DISPOSITIONS, NOT ONE, and the difference is the surface's own contract.
-- `text` is declared `required`, so OMITTING it is a USAGE error decided before
-- the verb runs — more precise than any refusal the verb could give. The verb's
-- own `no-prose` rule therefore covers the case the surface cannot see:
-- whitespace that is present and empty. A first version asserted `refusal` for
-- the missing arg and was testing the wrong layer.
test('agentwrite: txn_plan_annotate distinguishes a MISSING arg from EMPTY prose', function ()
    if not ready() then return skip('no lua parser') end
    local root = mkroot({ ['m.lua'] = { '-- m', 'local function f() return 1 end', 'return f' } })
    ingest(root); permit(true)
    local id = idof('f')
    if not id then return skip('no node') end
    local _, missing = agent.answer(store, 'txn_plan_annotate', { node = id })
    eq('usage', missing, 'a required arg left out is the SURFACE\'s answer')
    local d, status = agent.answer(store, 'txn_plan_annotate', { node = id, text = '   ' })
    eq('refusal', status, 'prose that is present and blank is the VERB\'s answer')
    eq('cannot-annotate', d.refusal.rule)
    ok(d.refusal.reason:find('no prose'), d.refusal.reason)
end)

-- ── THE THIRD CAPABILITY AXIS: LANGUAGE SCOPE (CART-0304) ───────────────────
-- `needs_calls` is about the GRAPH, `mutates` about the HOST, `langs` about the
-- SUBJECT. It is fenced here beside the other two because it fails the same way
-- if it is only documented: a lua-only planner aimed at a ruby function does not
-- error, it DECLINES every candidate, and every decline it writes is phrased as a
-- fact about the user's code.
--
-- PINNED ON BOTH SIDES, or a `langs` list that refused EVERYTHING would pass:
-- the ruby subject must refuse AND the lua one must still plan.
test('agentwrite: a lua-only planner REFUSES a subject in another language', function ()
    if not ready() then skip('no treesitter') end
    if not pcall(vim.treesitter.language.add, 'ruby') then skip('no ruby parser') end
    permit(true)
    local root = mkroot { ['m.lua'] = CSE_LUA, ['thing.rb'] = {
        'class Thing',
        '  def f(x, y)',
        '    a = x + y',
        '    b = x + y',
        '    return a, b',
        '  end',
        'end',
    } }
    ingest(root)

    local rid
    for _, n in ipairs(store.data.nodes) do
        if n.file and n.file:match('%.rb$')
            and (n.kind == 'function' or n.kind == 'method') then rid = n.id break end
    end
    ok(rid, 'the ruby fixture yielded a function node to aim at')

    local r = call('txn_plan_optimize', { kind = 'cse', node = rid })
    eq(false, r.ok, 'a ruby subject does not get a lua rewrite planned')
    eq('lang-scope', r.refusal.rule, 'and the rule NAMES the axis it failed')
    ok(r.refusal.reason:find('ruby', 1, true),
        'the reason says which language the subject is in: ' .. r.refusal.reason)
    ok(r.refusal.remedy:find('graph_info', 1, true),
        'and the remedy points at the column that answers "which verb then": '
        .. r.refusal.remedy)

    -- THE OTHER SIDE: the same verb, the same graph, a lua subject — still plans.
    local good = call('txn_plan_optimize', { kind = 'cse', node = idof('M.f') })
    eq(true, good.ok, 'the declared language is unaffected')
end)

test('agentwrite: the language column is on graph_info, and it is DERIVED', function ()
    if not ready() then skip('no treesitter') end
    permit(true)
    ingest(mkroot { ['m.lua'] = CSE_LUA })
    local info = call('graph_info')
    local by = {}
    for _, row in ipairs(info.result) do by[row.verb] = row end

    eq('lua', by.txn_plan_optimize.langs, 'the lua-only planner says so')
    eq('lua javascript', by.txn_plan_extract_family.langs,
        'the two-language planner names both')
    -- A NULL IS A CLAIM OF GENERALITY, the same reading `needs_calls = false`
    -- gets — moveapply was BUILT general (it moves text and discloses the wiring
    -- it will not guess), so its planner declares nothing.
    eq(vim.NIL, by.txn_plan_moveset.langs, 'a general verb carries null, not a roster')
    eq(vim.NIL, by.node_find.langs, 'and so does every read verb')

    -- DERIVED, NOT RETYPED: whatever the verb table declares is what the column
    -- shows, so the two cannot drift.
    for verb, row in pairs(by) do
        local v = agent.VERBS[verb]
        eq(v.langs and table.concat(v.langs, ' ') or vim.NIL, row.langs,
            'the column for ' .. verb .. ' is the declaration')
    end
end)

-- ── A REMEDY THE CALLER COULD NOT FOLLOW (CART-0973) ────────────────────────
-- CART-0580 says a refusal a caller cannot REACH is not a contract. This is the
-- mirror. `cloneextract.plan_family` has always taken `opts.dest` and refused a
-- cross-file family with "pass a destination module path" — but this verb had no
-- `dest` argument, and the underlying refusal named a `:Cartograph*` command an MCP
-- client cannot run. The capability was present, wired, and unaskable: measured, 2 of
-- 25 near-pair findings on cartograph's own tree ended there.
--
-- ★ AND CROSS-FILE IS THE INTERESTING CASE. One helper wanted by two modules is what
-- "extract a shared abstraction" means; the same-file families this verb could already
-- reach are the ones a human spots unaided.
local XFILE_A = {
    'local M = {}',
    'function M.pick_a(items)',
    '  local out = {}',
    '  for _, it in ipairs(items) do',
    "    if type(it) == 'string' then out[#out + 1] = it end",
    '  end',
    '  table.sort(out)',
    '  return out',
    'end',
    'return M',
}
local XFILE_B = {
    'local M = {}',
    'function M.pick_b(items)',
    '  local out = {}',
    '  for _, it in ipairs(items) do',
    "    if type(it) == 'number' then out[#out + 1] = it end",
    '  end',
    '  table.sort(out)',
    '  return out',
    'end',
    'return M',
}

-- ⚠ vim.NIL IS TRUTHY. Every optional envelope field is TYPE-checked, never
-- truth-checked — `doc.refusal` is NUL on success and indexing it raises. This cost a
-- probe its numbers earlier in the same arc (CART-0973's own measurement) and then
-- cost these two tests their first run.
-- ⚠ AND THE SENTINEL HAS TO BE IN SCOPE TO BE COMPARED AGAINST. `NUL` was used in
-- this file before it was defined, so every `x ~= NUL` was `x ~= nil` and every
-- `eq(NUL, …)` expected nil — assertions that read as envelope checks and were not.
-- Third time in one arc that vim.NIL has cost a measurement its meaning.
local NUL = vim.NIL
local function refusal_of(doc) return type(doc.refusal) == 'table' and doc.refusal or nil end

test('agentwrite: a CROSS-FILE family is plannable once `dest` can be given', function ()
    if not ready() then skip('no treesitter') end
    permit(true)
    ingest(mkroot { ['one.lua'] = XFILE_A, ['two.lua'] = XFILE_B })
    local id = idof('M.pick_a')
    ok(id, 'the fixture yielded a function to aim at')

    -- WITHOUT it: the verb refuses, and the refusal now names the ARGUMENT rather
    -- than an interactive command no client can run.
    local no = call('txn_plan_extract_family', { node = id })
    local nr = refusal_of(no)
    ok(nr, 'a cross-file family cannot be planned without a destination')
    eq('cannot-plan', nr.rule)
    ok(nr.reason:find('spans', 1, true),
        'the reason says the family spans more than one file: ' .. nr.reason)
    ok(nr.remedy:find('`dest`', 1, true),
        'and the REMEDY names the argument, which is the whole point: ' .. nr.remedy)

    -- WITH it: the same family plans.
    local yes = call('txn_plan_extract_family', { node = id, dest = 'shared/pick.lua' })
    eq(true, yes.ok, 'and with a destination it plans: '
        .. ((refusal_of(yes) or {}).reason or ''))
    ok(yes.subject and yes.subject.plan and yes.subject.plan ~= NUL,
        'returning a plan handle for txn_preview')
end)

test('agentwrite: `dest` is OPTIONAL — a same-file family neither needs nor takes one', function ()
    if not ready() then skip('no treesitter') end
    permit(true)
    -- ⚠ THE TRIPWIRE. Making the argument required, or passing it through when the
    -- family is same-file, would break every extraction the verb could already do.
    ingest(mkroot { ['m.lua'] = CSE_LUA })
    local id = idof('M.f')
    local r = call('txn_plan_extract_family', { node = id })
    local rr = refusal_of(r)
    ok(not rr or not (rr.reason or ''):find('destination', 1, true),
        'a same-file subject is never refused FOR WANT OF A DESTINATION: '
        .. ((rr and rr.reason) or 'planned'))
    local schema = agent.schema('txn_plan_extract_family')
    local req = (schema or {}).required or {}
    for _, name in ipairs(req) do
        ok(name ~= 'dest', '`dest` is not in the verb\'s required list')
    end
end)

-- ── A FINDING THAT NAMES NO NODE CAN ADDRESS NOTHING (CART-0976 / CART-0972) ─
-- Measured before the fix: every other finding surface carries `id` and gets a durable
-- `ref` from attach_refs for free; lint rows carried file+line and stopped there, so
-- the tool's LARGEST finding source (11 rules, 2554 rows on its own tree) could hand
-- its subject to no planner at all. `store.defs_at` resolves the innermost DEFINITION
-- containing the line; attach_refs does the rest, in the one place it is done.
--
-- ★ AND THIS ALONE CLOSED THE FILL. CART-0972's measurement expected to also widen
-- txn_plan_declare / txn_plan_annotate to accept file+line, since they were the only
-- planners that refused it. Once a lint row carries a REF they need no widening —
-- both take `ref` already.
local LINTABLE = {
    'local M = {}',
    '-- a comment on its own line, inside no definition',
    'local function unreferenced_helper(x)',
    '  return x + 1',
    'end',
    'function M.go(v) return v end',
    'return M',
}

test('agentwrite: a lint finding names the definition it sits in and carries its ref', function ()
    if not ready() then skip('no treesitter') end
    permit(false)
    ingest(mkroot { ['lf.lua'] = LINTABLE })
    local doc = call('lint_run', {})
    ok(type(doc.result) == 'table', 'lint_run answered with rows')
    local named = 0
    for _, r in ipairs(doc.result) do
        if r.id ~= nil and r.id ~= NUL then
            named = named + 1
            ok(r.ref ~= nil and r.ref ~= NUL,
                'a row naming a node also carries its durable ref')
            ok(r.ref.file and r.ref.name, 'and the ref resolves: ' .. vim.inspect(r.ref))
        else
            -- ⚠ NIL IS A REAL ANSWER, not a gap: a finding on a comment, an import or
            -- a top-level statement is in no definition — sayable only because the
            -- module is excluded from the containment chain.
            ok(r.ref == nil or r.ref == NUL,
                'a row naming no definition carries no ref either')
        end
    end
    ok(named > 0, 'at least one finding sits inside a definition')
end)

test('agentwrite: a lint finding\'s ref ADDRESSES a planner, which is the whole point', function ()
    if not ready() then skip('no treesitter') end
    permit(false)   -- planning needs no write permission
    ingest(mkroot { ['lf.lua'] = LINTABLE })
    local doc = call('lint_run', {})
    local sample
    for _, r in ipairs(doc.result or {}) do
        if r.ref ~= nil and r.ref ~= NUL then sample = r break end
    end
    ok(sample, 'a lint finding carrying a ref')
    -- txn_plan_annotate takes {ref, text} and the finding supplies BOTH
    local plan = call('txn_plan_annotate', { ref = sample.ref, text = sample.message })
    eq(true, plan.ok, 'the finding plans an annotation on the definition it sits in: '
        .. ((type(plan.refusal) == 'table' and plan.refusal.reason) or ''))
    ok(plan.subject and plan.subject.plan and plan.subject.plan ~= NUL,
        'returning a plan handle')
end)

-- ── THE FOURTH AXIS: WHAT A VERB IS ADDRESSED AT (CART-0972) ────────────────
-- CART-0972 was opened to design a finding -> planner table and warned against it in
-- the same breath. Measured instead: what a finding row HOLDS and what a planner NEEDS
-- are the SAME FOUR FIELDS (node, ref, file, line). There was no relation to invent —
-- one accessor was missing (CART-0976) and one fact was unstated, which is this column.
--
-- ⚠ DECLARED, NOT INFERRED — and this test is the half that inference CAN decide. A
-- deriver with special cases would make the answer agree with whatever the args say
-- rather than with what the verb means, so the query-shaped verbs are declared and
-- only the ADDRESSABLE shapes are checked against their own arg lists. Same split as
-- `@langs`: declare everything, fence what is fenceable.
test('agentwrite: every verb declares what it is ADDRESSED AT', function ()
    local SHAPES = { node = true, ['node-handle'] = true, set = true, position = true,
        plan = true, journal = true, path = true, query = true, graph = true }
    for _, name in ipairs(agent.ORDER) do
        local v = agent.VERBS[name]
        ok(v.subject, name .. ' declares a subject shape')
        ok(SHAPES[v.subject], name .. ' declares a KNOWN shape, not ' .. tostring(v.subject))
    end
end)

test('agentwrite: the declared subject shape MATCHES the arguments it accepts', function ()
    for _, name in ipairs(agent.ORDER) do
        local v = agent.VERBS[name]
        local a = {}
        for _, x in ipairs(v.args or {}) do a[x.name] = true end
        if v.subject == 'node' then
            ok(a.node and a.ref and a.file and a.line,
                name .. ' declares `node` so it must take the FULL address')
        elseif v.subject == 'node-handle' then
            ok(a.node and a.ref, name .. ' declares `node-handle` so it takes node and ref')
            ok(not (a.file and a.line),
                name .. ' declares `node-handle`, so it must NOT also take a position —'
                .. ' that would be `node`')
        elseif v.subject == 'set' then
            ok(a.seed or a.seed_refs, name .. ' declares `set` so it takes seed/seed_refs')
        elseif v.subject == 'plan' then
            ok(a.plan, name .. ' declares `plan` so it takes a plan handle')
        elseif v.subject == 'position' then
            ok(a.file and a.line, name .. ' declares `position` so it takes file and line')
            ok(not a.ref, name .. ' declares `position`, not a node handle')
        elseif v.subject == 'graph' then
            ok(not (a.node or a.ref or a.seed or a.plan),
                name .. ' declares `graph`, so it accepts no subject handle at all')
        end
    end
end)

test('agentwrite: graph_info CARRIES the column, derived from the declaration', function ()
    if not ready() then skip('no treesitter') end
    permit(true)
    ingest(mkroot { ['m.lua'] = CSE_LUA })
    local by = {}
    for _, row in ipairs(call('graph_info').result) do by[row.verb] = row end
    eq('node', by.txn_plan_extract_family.subject)
    eq('node-handle', by.txn_plan_annotate.subject, 'the two that take no position')
    eq('set', by.txn_plan_moveset.subject)
    eq('graph', by.lint_run.subject, 'a finding surface is addressed at nothing')
    -- DERIVED, NOT RETYPED: whatever the verb table declares is what the column shows.
    for verb, row in pairs(by) do
        eq(agent.VERBS[verb].subject, row.subject, 'the column for ' .. verb)
    end
end)

-- ── THE THIRD APPLY FAMILY (CART-0978) ──────────────────────────────────────
-- CART-0972 drove every finding surface against every planner's declared arguments.
-- After the position accessor landed, every finding shape reached something except one:
-- `clones_find` EXACT groups carried members with refs and no verb took them. The module
-- has had an apply path since the first transaction and no plan verb on this surface —
-- agent.lua's own skipped list said so, and was caught STALE once already (CART-0964).
local MERGE_A = {
    'local M = {}',
    'function M.norm(x, y)',
    '  local s = x * x + y * y',
    '  return s',
    'end',
    'return M',
}
local MERGE_B = {
    'local M = {}',
    'function M.dist(x, y)',
    '  local s = x * x + y * y',
    '  return s',
    'end',
    'function M.use(p, q) return M.dist(p, q) end',
    'return M',
}
-- ⚠ THE SAME DATA-FLOW WITNESS, DIFFERENT CONTROL FLOW (CART-0892). An `if` and a
-- `while` over the same body are indistinguishable to the witness and must NOT merge.
local KIND_A = {
    'local M = {}',
    'function M.loopy(t)',
    '  local n = 0',
    '  if t then n = n + 1 end',
    '  return n',
    'end',
    'return M',
}
local KIND_B = {
    'local M = {}',
    'function M.whiley(t)',
    '  local n = 0',
    '  while t do n = n + 1 end',
    '  return n',
    'end',
    'function M.use(z) return M.whiley(z) end',
    'return M',
}

test('agentwrite: an EXACT clone group finally has a planner', function ()
    if not ready() then skip('no treesitter') end
    permit(false)   -- planning needs no write permission
    ingest(mkroot { ['a.lua'] = MERGE_A, ['b.lua'] = MERGE_B })
    local r = call('txn_plan_clonemerge', { node = idof('M.norm') })
    eq(true, r.ok, 'the twin is mergeable: '
        .. ((type(r.refusal) == 'table' and r.refusal.reason) or ''))
    ok(r.subject.plan and r.subject.plan ~= NUL, 'returning a plan handle for txn_preview')
    eq(1, r.subject.removed, 'one copy is deleted')
    ok(r.subject.survivor, 'and the survivor is named: ' .. tostring(r.subject.survivor))
end)

test('agentwrite: a twin the KIND gate throws out REFUSES — it is not an absence', function ()
    if not ready() then skip('no treesitter') end
    permit(false)
    ingest(mkroot { ['c.lua'] = KIND_A, ['d.lua'] = KIND_B })
    local r = call('txn_plan_clonemerge', { node = idof('M.loopy') })
    eq(false, r.ok, 'a twin that differs in control flow is not merged')
    local rf = type(r.refusal) == 'table' and r.refusal or nil
    ok(rf, 'and it REFUSES rather than reporting an absence')
    eq(NUL, r.absence, 'a refusal is not an absence — the two must never render alike')
    ok(rf.reason:find('STATEMENT KINDS', 1, true),
        'naming the gate that declined it: ' .. rf.reason)
    -- ★ THIS IS THE ONLY EVIDENCE THAT THE WITNESS IS COARSE. Pooling it with "no
    -- clones found" would hide the finding worth having.
end)

test('agentwrite: no twin at all is ABSENT, a fact about the code', function ()
    if not ready() then skip('no treesitter') end
    permit(false)
    ingest(mkroot { ['m.lua'] = CSE_LUA })
    local r = call('txn_plan_clonemerge', { node = idof('M.g') })
    eq(NUL, r.refusal, 'no gate declined anything')
    eq('absent', r.absence, 'the witness simply found no twin')
    ok(r.absence_why and r.absence_why.premise == 'no-twin',
        'and the premise says which: ' .. vim.inspect(r.absence_why))
end)

test('agentwrite: the merge planner takes NO `partial` — the law is the opposite one', function ()
    -- ⚠ THE TRIPWIRE. Extraction is sound when incomplete: the helper exists, a skipped
    -- member keeps its own body, nothing dangles. A merge DELETES the copies and points
    -- their callers at the survivor, so leaving one twin behind rewrites the callers of
    -- a function that still exists. Copying `partial` across would copy the wrong law
    -- with the right spelling.
    for _, a in ipairs(agent.VERBS.txn_plan_clonemerge.args or {}) do
        ok(a.name ~= 'partial', 'clonemerge declares no `partial` argument')
    end
    local has = false
    for _, a in ipairs(agent.VERBS.txn_plan_extract_family.args or {}) do
        if a.name == 'partial' then has = true end
    end
    ok(has, 'while extract_family does — the asymmetry is the point, not an oversight')
end)

-- ── THE DESTINATION FOR A RENDERED EDIT (CART-0977) ─────────────────────────
-- CART-0972 matched every finding surface against every planner's arguments, and one
-- producer fit on no axis: `transplant` derives new SOURCE TEXT and the planners take a
-- node, a node SET, or a container plus a member. None took bytes.
--
-- ⚠⚠ ITS GUARANTEE IS THE WEAKEST IN THE CATALOGUE, AND THE TESTS BELOW PIN THAT RATHER
-- THAN HIDING IT. Every other write verb can re-check what it is about to write because
-- it BUILT it. This one is handed bytes and verifies two things: the result parses, and
-- the file has not moved since planning.
local REPL = {
    'local M = {}',
    '',
    '-- doubles a number',
    'function M.dbl(x)',
    '  return x * 2',
    'end',
    '',
    'function M.keep(x) return x + 1 end',
    'return M',
}

test('agentwrite: a rendered edit finally has a destination', function ()
    if not ready() then skip('no treesitter') end
    permit(false)   -- planning needs no write permission
    local root = mkroot { ['r.lua'] = REPL }
    ingest(root)
    local r = call('txn_plan_replace', { node = idof('M.dbl'),
        text = 'function M.dbl(x)\n  return x + x\nend' })
    eq(true, r.ok, 'the replacement plans: '
        .. ((type(r.refusal) == 'table' and r.refusal.reason) or ''))
    ok(r.subject.plan and r.subject.plan ~= NUL, 'returning a plan handle for txn_preview')
    eq(3, r.subject.replaced_lines, 'the definition was three lines')
    eq(3, r.subject.new_lines)
    -- PLANNING WRITES NOTHING, asserted off the disk like every other planner
    eq(table.concat(REPL, '\n'), read(root, 'r.lua'),
        'and the file is untouched until apply')
end)

test('agentwrite: the plan DECLARES what it did not verify, on every answer', function ()
    if not ready() then skip('no treesitter') end
    permit(false)
    ingest(mkroot { ['r.lua'] = REPL })
    -- ★ VALID LUA THAT MEANS SOMETHING ELSE ENTIRELY. The verb accepts it — that is the
    -- property, not a bug — and the envelope says so without the caller opening the plan.
    local r = call('txn_plan_replace', { node = idof('M.dbl'),
        text = 'function M.unrelated() return nil end' })
    eq(true, r.ok, 'a replacement that redefines a DIFFERENT name still plans')
    local said
    for _, n in ipairs(r.notes or {}) do
        if n.kind == 'unverified-payload' then said = n end
    end
    ok(said, 'and the envelope carries the standing declaration as a NOTE')
    ok(said.why:find('NOTHING about whether', 1, true),
        'which states what was not checked: ' .. said.why)
    ok(said.why:find('M.dbl', 1, true), 'naming the definition it will overwrite')
end)

test('agentwrite: replace declares `parses` and nothing it cannot honour', function ()
    -- ⚠ THE TRIPWIRE. `comment-inert` belongs to prose and `shape-preserved` to a
    -- container whose shape was DERIVED; neither has a counterpart here, because
    -- nothing about the payload was derived. A verb that declared one would be
    -- claiming a check it cannot run — and txn refuses a plan declaring no guards at
    -- all, so the empty list is not an option either.
    if not ready() then skip('no treesitter') end
    permit(false)
    ingest(mkroot { ['r.lua'] = REPL })
    local rp = require 'cartograph.replace'
    local plan = assert(rp.plan(store, { node = idof('M.dbl'), text = 'function M.dbl() end' }))
    eq(1, #plan.guards, 'exactly one guard')
    eq('parses', plan.guards[1])
    ok(#plan.hazards >= 1, 'and the standing hazard rides on the plan itself')
    ok(plan.hazards[1]:find('supplied, not derived', 1, true),
        'saying the payload was not derived: ' .. plan.hazards[1])
end)

test('agentwrite: empty text and a missing subject REFUSE, by name', function ()
    if not ready() then skip('no treesitter') end
    permit(false)
    ingest(mkroot { ['r.lua'] = REPL })
    local blank = call('txn_plan_replace', { node = idof('M.dbl'), text = '   \n  ' })
    eq(false, blank.ok, 'whitespace is not a replacement')
    ok((type(blank.refusal) == 'table' and blank.refusal.reason or ''):find('replacement text'),
        'and it says so: ' .. vim.inspect(blank.refusal))
    local gone = call('txn_plan_replace', { node = 'no::such@1', text = 'x = 1' })
    eq(false, gone.ok, 'an unknown node refuses')
end)

test('agentwrite: the splice REPLACES — it does not swallow the blank line after', function ()
    -- ⚠ FOUND BY A NEUTRALISATION, NOT BY READING, AND THE FIRST TEST I WROTE FOR IT
    -- DID NOT DISCRIMINATE EITHER. `txn.edit_file`'s deletion path swallows one
    -- trailing blank line so removals do not leave double blanks behind — correct for
    -- a REMOVAL and wrong for a REPLACEMENT, which puts content back where the old
    -- content was. replace.lua splices directly for that reason, the same way
    -- cloneextract does.
    -- ★ THE PREVIEW'S OWN COUNTS ARE THE DISCRIMINATOR. A three-line definition whose
    -- body line changes is removed=1/added=1; swallow the blank after it and the
    -- removal becomes 2. Asked of the accessor rather than guessed — the first version
    -- of this test pattern-matched `vim.inspect(preview)` and passed either way.
    if not ready() then skip('no treesitter') end
    permit(false)
    ingest(mkroot { ['r.lua'] = REPL })
    local p = call('txn_plan_replace', { node = idof('M.dbl'),
        text = 'function M.dbl(x)\n  return x + x\nend' })
    eq(true, p.ok, 'planned')
    local pv = call('txn_preview', { plan = p.subject.plan })
    eq(true, pv.ok, 'previewed: ' .. vim.inspect(pv.refusal))
    local row
    for _, r in ipairs(pv.result or {}) do if r.file == 'r.lua' then row = r end end
    ok(row, 'the preview reports the edited file')
    eq(1, row.removed, 'exactly the changed body line is removed — not it AND the blank')
    eq(1, row.added, 'and exactly one line replaces it')
end)
