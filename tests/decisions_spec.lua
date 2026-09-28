-- REMEMBERED DECISIONS (CART-1160 step 6): a tactic's question answered ONCE, by the user, and consulted on later
-- runs — for THIS exact question, or for every question of one kind about files inside a VIEW. The oracles are the
-- runs themselves (stopped vs done, what the disk holds) and the provenance on the residue: a remembered answer is
-- never silent. The store is the user's state file; nothing is written inside the analysed tree, and no MCP verb
-- writes it.
local store = require 'cartograph.store'
local ts = require 'cartograph.providers.treesitter'
local txn = require 'cartograph.txn'
local tactic = require 'cartograph.tactic'
local hazard = require 'cartograph.hazard'
local D = require 'cartograph.decisions'
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

--- a write to `file` (and `also`, when given) that asks one decision (its evidence names the file, so two files ask
--- two questions); the prose changes on EVERY ask, so a key that hashed it would never match twice
local asked = 0
local VERBS = {
    ask = { effect = 'journaled', rerun = 'empty', plan = function (_, a)
        if (txn.read_file(store.data.root, a.file) or ''):find(a.line, 1, true) then return nil, 'already there', 'empty' end
        asked = asked + 1
        local touched, stamps = { a.file }, { [a.file] = txn.disk_stamp(store.data.root, a.file) }
        if a.also then touched[2] = a.also; stamps[a.also] = txn.disk_stamp(store.data.root, a.also) end
        return txn.protocol({ verb = 'ask', guards = {}, refspecs = {}, touched = touched, generation = store.generation,
            stamps = stamps, desc = 'ask', preserves = 'none',
            hazards = { hazard.new(a.kind or 'choose', ('a choice about %s (ask #%d)'):format(a.file, asked), nil, { file = a.file }, 'decision') } },
            function () return function (_, before) return before .. a.line .. '\n' end end)
    end },
}

local saved
local function fresh()
    saved = saved or D.path
    D.path = vim.fn.tempname() .. '-decisions.json'
end
local function restore() if saved then D.path = saved end end

local function run(term, o) o = o or {}; o.verbs = VERBS; if o.apply == nil then o.apply = true end; return tactic.run(store, term, o) end

test('decisions: an EXACT remembered answer lets the SAME term re-run to done — and says who answered', function ()
    if not ready() then skip 'no lua parser' end
    fresh()
    local ok_run, err = pcall(function ()
        local root = tree { ['a.lua'] = 'local a = 1\nreturn a\n', ['b.lua'] = 'local b = 1\nreturn b\n' }
        store.ingest(ts.extract(root))
        local term = T.step('ask', { file = 'a.lua', line = '-- one' })
        local r = run(term)
        eq('stopped', r.status); local opt = r.options[1]
        ok(opt.key and opt.key:match('^sha256:'), 'the stop names the question\'s identity')
        eq('local a = 1\nreturn a\n', disk(root, 'a.lua'))
        -- the prose carries a timestamp: the KEY must not (the same question asked later is the same question)
        eq(opt.key, run(term, { apply = false }).options[1].key)
        local e = assert(D.remember { key = opt.key, kind = opt.kind, why = 'I always want the line' })
        local done = run(term)
        eq('done', done.status, tostring(done.why)); eq(1, done.applied)
        local cited
        for _, h in ipairs(done.residue) do if h.decision_id == e.id then cited = h end end
        ok(cited and cited.remembered:find('exact', 1, true) and cited.text:find('answered:', 1, true), vim.inspect(done.residue))
        eq('informational', cited.class)
        -- a DIFFERENT question (another file) is not answered by it
        eq('stopped', run(T.step('ask', { file = 'b.lua', line = '-- one' })).status)
        -- remembered = false asks again; forget undoes the memory
        eq('stopped', run(T.step('ask', { file = 'a.lua', line = '-- two' }), { remembered = false }).status)
        ok(D.forget(e.id))
        eq('stopped', run(T.step('ask', { file = 'a.lua', line = '-- two' })).status)
        -- the record lives in the USER's state file, never inside the analysed tree
        local inside = vim.fs.find(function (n) return n:find('decision', 1, true) ~= nil end, { path = root, limit = math.huge })
        eq({}, inside)
    end)
    restore()
    if not ok_run then error(err, 0) end
end)

test('decisions: a VIEW answers every decision of its kind about files inside it — all touched files, most specific cited', function ()
    if not ready() then skip 'no lua parser' end
    fresh()
    local ok_run, err = pcall(function ()
        local root = tree { ['sub/a.lua'] = 'return 1\n', ['top.lua'] = 'return 2\n' }
        store.ingest(ts.extract(root))
        local outer = assert(D.remember { kind = 'choose', dir = root, why = 'the whole project' })
        local inner = assert(D.remember { kind = 'choose', dir = root .. '/sub', why = 'this subtree' })
        local r = run(T.step('ask', { file = 'sub/a.lua', line = '-- v' }))
        eq('done', r.status, tostring(r.why))
        local cited
        for _, h in ipairs(r.residue) do if h.decision_id then cited = h.decision_id end end
        eq(inner.id, cited, 'the most specific covering view is the one cited')
        eq('done', run(T.step('ask', { file = 'top.lua', line = '-- v' })).status, 'the outer view covers the top level')
        -- a plan is covered only when EVERY file it touches is inside a view: sub/a.lua is, top.lua is not (once the
        -- outer view is gone, below) — checked first with the outer view still there, then without it
        local both = run(T.step('ask', { file = 'sub/a.lua', also = 'top.lua', line = '-- both' }))
        eq('done', both.status, tostring(both.why))
        local why_both
        for _, h in ipairs(both.residue) do if h.decision_id then why_both = h end end
        eq(inner.id, why_both.decision_id, 'the most specific entry leads')
        ok(why_both.remembered:find(inner.id, 1, true) and why_both.remembered:find(outer.id, 1, true),
            'and BOTH views that answered are cited: ' .. why_both.remembered)
        -- a view answers only its KIND
        eq('stopped', run(T.step('ask', { file = 'top.lua', line = '-- w', kind = 'another' })).status)
        ok(D.forget(outer.id))
        eq('stopped', run(T.step('ask', { file = 'top.lua', line = '-- x' })).status, 'top.lua is outside the remaining view')
        eq('stopped', run(T.step('ask', { file = 'sub/a.lua', also = 'top.lua', line = '-- mixed' })).status,
            'one touched file outside every view: the plan is not covered')
    end)
    restore()
    if not ok_run then error(err, 0) end
end)

test('decisions: a remembered TARGET-WRITE is a grant — the cross-world write goes through; a view elsewhere is not', function ()
    if not ready() then skip 'no lua parser' end
    fresh()
    local ok_run, err = pcall(function ()
        local src, dst = tree { ['a.lua'] = 'return 1\n' }, tree { ['t.lua'] = 'return 2\n' }
        store.ingest(ts.extract(src))
        local V = { xw = { effect = 'journaled', rerun = 'empty', plan = function ()
            if (disk(dst, 't.lua') or ''):find('-- x', 1, true) then return nil, 'there', 'empty' end
            local plan = txn.protocol({ verb = 'xw', guards = {}, refspecs = {}, touched = { 't.lua' }, generation = store.generation,
                stamps = { ['t.lua'] = txn.disk_stamp(dst, 't.lua') }, desc = 'xw', preserves = 'none', hazards = {} },
                function () return function (_, before) return before .. '-- x\n' end end)
            return txn.target(plan, dst, 'test')
        end } }
        D.remember { kind = 'target-write', dir = src, why = 'the wrong world' }
        eq('stopped', tactic.run(store, T.step('xw', {}), { verbs = V, apply = true }).status, 'a view over the SOURCE does not cover the target')
        D.remember { kind = 'target-write', dir = dst, why = 'I allow writes there' }
        local r = tactic.run(store, T.step('xw', {}), { verbs = V, apply = true })
        eq('done', r.status, tostring(r.why)); eq('return 2\n-- x\n', disk(dst, 't.lua'))
    end)
    restore()
    if not ok_run then error(err, 0) end
end)

test('decisions: NO MCP verb can remember an answer — an agent must not grant itself standing permission', function ()
    local agent = require 'cartograph.agent'
    for _, v in ipairs(agent.ORDER) do
        ok(not v:find('remember', 1, true) and not v:find('decision', 1, true), v .. ' looks like a decision writer')
    end
    ok(#agent.ORDER > 30, 'the verb list is the real one')
end)
