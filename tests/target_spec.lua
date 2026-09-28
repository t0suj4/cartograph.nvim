-- TARGET ON PLANS (CART-1160 step 5): a plan derived from one world may WRITE another — promotion writes the built-in
-- toolbelt while the graph is the project. A cross-world write needs the target MOUNTED WRITABLE in the namespace the
-- caller runs with, and only an ACCEPTED decision naming the target grants that mount. The oracles are the two disks
-- and the two journals: the target holds the write, the source world is byte-identical, and the entry lives in the
-- target's journal.
local store = require 'cartograph.store'
local ts = require 'cartograph.providers.treesitter'
local txn = require 'cartograph.txn'
local journal = require 'cartograph.journal'
local namespace = require 'cartograph.namespace'
local tactic = require 'cartograph.tactic'
local hazard = require 'cartograph.hazard'
local T = tactic.T

local function ready() return pcall(vim.treesitter.get_string_parser, '', 'lua') end

local function tree(files)
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    for rel, t in pairs(files) do
        local d = (root .. '/' .. rel):match('^(.*)/[^/]*$'); vim.fn.mkdir(d, 'p')
        local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(t); fd:close()
    end
    return root
end
local function disk(root, rel) local fd = io.open(root .. '/' .. rel); if not fd then return nil end; local s = fd:read('a'); fd:close(); return s end

local SRC = { ['a.lua'] = 'local a = 1\nreturn a\n' }
local DST = { ['t.lua'] = 'local t = 1\nreturn t\n' }

--- a plan made against the ACTIVE graph that appends a line to `rel` in the world at `target`
local function cross_plan(target, rel, line, hazards)
    local plan = txn.protocol({ verb = 'x-write', guards = { 'parses' }, refspecs = {}, touched = { rel },
        generation = store.generation, stamps = { [rel] = txn.disk_stamp(target, rel) }, hazards = hazards or {},
        desc = 'x-write ' .. line, preserves = 'none', rel = rel, line = line },
        function (p) return function (r, before) if r ~= p.rel then return before end return before .. p.line .. '\n' end end)
    return txn.target(plan, target, 'the test writes the other world')
end

test('target: a cross-world plan REFUSES as a decision unless its target is mounted writable; then it writes THERE only', function ()
    if not ready() then skip 'no lua parser' end
    local src, dst = tree(SRC), tree(DST)
    store.ingest(ts.extract(src))
    local gen = store.generation
    local plan = cross_plan(dst, 't.lua', '-- written')
    local kinds = {}
    for _, h in ipairs(hazard.plain(plan.hazards)) do kinds[#kinds + 1] = h.kind .. ':' .. h.class end
    eq({ 'target-write:decision' }, kinds, 'txn.target adds the generic decision when the builder has none')
    local r, why, class = txn.apply(store, plan)
    eq(nil, r); eq('decision', class); ok(why:find('ANOTHER world', 1, true) and why:find('target-write', 1, true), why)
    -- a READ-ONLY mount is no grant
    local ro = namespace.mount(namespace.empty(), dst, 'ro-view', {})
    local r2, _, c2 = txn.apply(store, plan, { ns = ro })
    eq(nil, r2); eq('decision', c2)
    eq(DST['t.lua'], disk(dst, 't.lua'), 'nothing written while refused')
    -- the grant is an ACCEPTED decision naming the target, and nothing else
    eq(nil, txn.grant(nil, plan, {}), 'nothing accepted, nothing granted')
    eq(nil, txn.grant(nil, plan, { ['some-other'] = true }))
    ok(txn.writable(txn.grant(nil, plan, { ['target-write'] = true }), dst), 'accepted: a writable mount of the target')
    -- mounted rw: it writes the TARGET, journals it THERE, and leaves the source world and its graph alone
    local rw = namespace.mount(namespace.empty(), dst, 'granted', { rw = true })
    local entry, ewhy = txn.apply(store, plan, { ns = rw })
    ok(entry, tostring(ewhy))
    eq(DST['t.lua'] .. '-- written\n', disk(dst, 't.lua'))
    eq(SRC['a.lua'], disk(src, 'a.lua')); eq(nil, disk(src, 't.lua'), 'the source world got no t.lua')
    eq(dst, entry.root); eq(entry.id, journal.last(dst).id, 'the entry is in the TARGET world\'s journal')
    ok(not journal.last(src) or journal.last(src).id ~= entry.id)
    eq(gen, store.generation, 'the graph was not refreshed: the files written are not its files')
    -- containment is checked against the target root
    local esc = cross_plan(dst, '../escape.lua', '-- no')
    local r3, why3 = txn.apply(store, esc, { ns = rw })
    eq(nil, r3); ok(tostring(why3):find('outside', 1, true), tostring(why3))
end)

--- a verb for the runner: its plan targets the world named in args
local VERBS = {
    xw = { effect = 'journaled', rerun = 'empty', plan = function (_, a)
        if (disk(a.target, 't.lua') or ''):find(a.line, 1, true) then return nil, 'already there', 'empty' end
        return cross_plan(a.target, 't.lua', a.line)
    end },
    refuse = { effect = 'journaled', plan = function () return nil, 'this verb cannot yet', 'unbuilt' end },
    local_write = { effect = 'journaled', rerun = 'empty', plan = function (_, a)
        return txn.protocol({ verb = 'lw', guards = {}, refspecs = {}, touched = { 'a.lua' }, generation = store.generation,
            stamps = { ['a.lua'] = txn.disk_stamp(store.data.root, 'a.lua') }, desc = 'lw', preserves = 'none' },
            function () return function (_, before) return before .. a.line .. '\n' end end)
    end },
}

test('target: in a TACTIC the grant is the ACCEPTED decision; rollback undoes it in the target\'s journal; a dry run does not chain it', function ()
    if not ready() then skip 'no lua parser' end
    local src, dst = tree(SRC), tree(DST)
    store.ingest(ts.extract(src))
    local run = function (term, o) o = o or {}; o.verbs = VERBS; if o.apply == nil then o.apply = true end; return tactic.run(store, term, o) end
    local r = run(T.step('xw', { target = dst, line = '-- one' }))
    eq('stopped', r.status); eq('target-write', r.options and r.options[1] and r.options[1].kind)
    eq(DST['t.lua'], disk(dst, 't.lua'), 'stopped BEFORE anything was written')
    local done = run(T.step('xw', { target = dst, line = '-- one' }, { 'target-write' }))
    eq('done', done.status, tostring(done.why)); eq(1, done.applied)
    eq(DST['t.lua'] .. '-- one\n', disk(dst, 't.lua'))
    -- on_stop = rollback: the cross-world write is undone from ITS journal, identity-checked
    local rb = run(T.seq(T.step('xw', { target = dst, line = '-- two' }, { 'target-write' }), T.step('refuse', {})), { on_stop = 'rollback' })
    eq('failed', rb.status); eq(1, rb.rolled_back, tostring(rb.rollback_refused or rb.rollback_failed))
    eq(DST['t.lua'] .. '-- one\n', disk(dst, 't.lua'), 'the second write is gone, the first stands')
    -- dry: the cross-world step previews, but the preview world is THIS one, so the next step waits on it
    local dry = run(T.seq(T.step('xw', { target = dst, line = '-- three' }, { 'target-write' }), T.step('local_write', { line = '-- l' })), { apply = false })
    eq('previewed', dry.status, tostring(dry.why)); eq(0, dry.worlds)
    ok(tostring(dry.trace[1].why):find('ANOTHER world', 1, true), tostring(dry.trace[1].why))
    eq(true, dry.trace[2] and dry.trace[2].underivable)
    eq(SRC['a.lua'], disk(src, 'a.lua')); eq(DST['t.lua'] .. '-- one\n', disk(dst, 't.lua'))
end)

test('target: PROMOTION writes the toolbelt\'s own world — `promote` is the one question, and it is the grant', function ()
    if not ready() then skip 'no lua parser' end
    local tb = require 'cartograph.toolbelt'
    local SMALL = table.concat({
        'return {',
        "    name = 'count-fns', kind = 'discovery', summary = 'functions in the graph', params = {},",
        "    measure = function (store) local n = 0; for _, x in ipairs(store.data.nodes or {}) do if x.kind == 'function' then n = n + 1 end end; return n end,",
        "    claim = function (n) return n > 0, n .. ' function(s)' end,",
        "    examples = { { name = 'one', files = { ['a.lua'] = 'local function f() end\\nreturn f\\n' }, expect = { holds = true } } },",
        '}', '' }, '\n')
    local project = tree { ['m.lua'] = 'local M = {}\nreturn M\n', ['.cartograph/tactics/count-fns.lua'] = SMALL }
    local builtin = vim.fn.tempname(); vim.fn.mkdir(builtin, 'p')
    store.ingest(ts.extract(project))
    local plan = assert(tb.plan_promote(store, { name = 'count-fns', from = project, into = builtin }))
    eq(builtin, plan.target and plan.target.root)
    local decisions = {}
    for _, h in ipairs(hazard.plain(plan.hazards)) do if h.class == 'decision' then decisions[#decisions + 1] = h.kind end end
    eq({ 'promote' }, decisions, 'no second question: the promote decision names the target')
    local stop = tb.run(store, 'promote-tactic', { name = 'count-fns', from = project, into = builtin }, { apply = true })
    eq('stopped', stop.status); eq(0, vim.fn.filereadable(builtin .. '/count-fns.lua'))
    local done = tb.run(store, 'promote-tactic', { name = 'count-fns', from = project, into = builtin, confirm = 'yes' }, { apply = true })
    eq('done', done.status, tostring(done.why))
    eq(SMALL, disk(builtin, 'count-fns.lua'), 'promoted byte for byte into the other world')
    eq(nil, disk(project, 'count-fns.lua')); eq(SMALL, disk(project, '.cartograph/tactics/count-fns.lua'), 'the project is as it was')
    eq(0, tb.run(store, 'promote-tactic', { name = 'count-fns', from = project, into = builtin, confirm = 'yes' }, { apply = true }).applied,
        're-run: already promoted is empty')
end)
