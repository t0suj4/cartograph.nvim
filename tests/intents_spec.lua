-- INDETERMINATE OUTCOMES (CART-1185): an effect the journal cannot hold records its INTENT before it applies. When the
-- apply cannot say whether it took effect, the step is INDETERMINATE — a frontier, never "failed", never "done" — the
-- intent stays open, and re-running the SAME invocation reconciles it through the verb's own goal check. The oracle is
-- the sink: after the reconciling re-run it holds the effect EXACTLY ONCE, whichever side of the commit the fault hit.
local store = require 'cartograph.store'
local ts = require 'cartograph.providers.treesitter'
local txn = require 'cartograph.txn'
local tactic = require 'cartograph.tactic'
local I = require 'cartograph.intents'
local T = tactic.T

local function ready() return pcall(vim.treesitter.get_string_parser, '', 'lua') end

local root, fault, shipped
local function marks()
    local fd = io.open(root .. '/sink.txt'); if not fd then return 0 end
    local s = fd:read('a'); fd:close()
    local _, n = s:gsub('X\n', ''); return n
end
local function sink() local fd = assert(io.open(root .. '/sink.txt', 'a')); fd:write('X\n'); fd:close() end

-- a REMOTE-like effect: compensable, outside the journal, goal-checked by reading the sink. `fault` is the network,
-- not part of the invocation: the retry is the SAME invocation, the same edit identity.
local VERBS = {
    remote = { effect = 'compensable', rerun = 'empty', plan = function (_, a)
        if marks() >= 1 then return nil, 'the effect is already there', 'empty' end
        return txn.protocol({ verb = 'remote', guards = {}, refspecs = {}, touched = { 'a.lua' }, generation = store.generation,
            stamps = { ['a.lua'] = txn.disk_stamp(root, 'a.lua') }, desc = 'remote ' .. tostring(a.what), preserves = 'none' },
            function () return function (_, before) return before .. '-- staged\n' end end)
    end, apply = function ()
        if fault == 'before' then error('timeout: the host never answered (the commit did not land)') end
        sink(); shipped = shipped + 1
        if fault == 'after' then error('timeout: the host never answered (the commit DID land)') end
        return { id = 'remote-' .. shipped }
    end },
    local_w = { effect = 'journaled', rerun = 'empty', plan = function ()
        return txn.protocol({ verb = 'lw', guards = {}, refspecs = {}, touched = { 'a.lua' }, generation = store.generation,
            stamps = { ['a.lua'] = txn.disk_stamp(root, 'a.lua') }, desc = 'lw', preserves = 'none' },
            function () return function (_, b) return b .. '-- local\n' end end)
    end },
}
local function fresh()
    root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/a.lua', 'w')); fd:write('return 1\n'); fd:close()
    store.ingest(ts.extract(root))
    fault, shipped = nil, 0
end
local function run(term) return tactic.run(store, term, { verbs = VERBS, apply = true }) end
local STEP = T.step('remote', { what = 'deploy' })

test('indeterminate: the fault hit BEFORE the commit landed — the step is a frontier, the intent open; the re-run APPLIES once', function ()
    if not ready() then skip 'no lua parser' end
    fresh()
    fault = 'before'
    local r = run(STEP)
    eq('failed', r.status); eq('frontier', r.class); ok(r.why:find('UNKNOWN', 1, true), r.why)
    eq(1, #r.indeterminate); eq(1, #r.open_intents); eq('indeterminate', r.open_intents[1].state)
    eq(0, marks())
    fault = nil
    local again = run(STEP)
    eq('done', again.status, tostring(again.why)); eq(1, again.applied)
    eq(1, marks(), 'applied exactly once'); eq(0, #again.open_intents, 'the intent is closed')
end)

test('indeterminate: the fault hit AFTER the commit landed — the re-run finds it there, is EMPTY, and closes the intent: no duplicate', function ()
    if not ready() then skip 'no lua parser' end
    fresh()
    fault = 'after'
    local r = run(STEP)
    eq('frontier', r.class); eq(1, marks(), 'it DID land'); eq(1, #r.open_intents)
    fault = nil
    local again = run(STEP)
    eq('done', again.status); eq(0, again.applied, 'reconciled as done — not applied again')
    eq(1, marks(), 'zero duplicate effects'); eq(0, #again.open_intents)
end)

test('indeterminate: a RESTARTED runner sees the open intent; `first` never moves on over an effect that may have happened', function ()
    if not ready() then skip 'no lua parser' end
    fresh()
    fault = 'after'
    run(STEP)
    -- a different run, later (the crashed runner's successor): the open intent is reported
    fault = nil
    local other = run(T.step('local_w', {}))
    eq(1, #other.open_intents, 'the in-flight intent from the earlier run is visible'); eq('remote', other.open_intents[1].verb)
    -- inside `first`: an indeterminate alternative is UNRECOVERABLE — the next alternative must not run
    fresh()
    fault = 'after'
    local f = run(T.first(T.step('remote', { what = 'x' }), T.step('local_w', {})))
    eq('failed', f.status); eq('frontier', f.class)
    ok(not io.open(root .. '/a.lua'):read('a'):find('-- local', 1, true), 'the second alternative did not run over it')
    -- a JOURNALED step records no intent: the journal is its own recovery
    fresh()
    eq(0, #run(T.step('local_w', {})).open_intents)
end)
