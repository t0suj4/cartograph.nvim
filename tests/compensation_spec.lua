-- COMPENSATION (CART-1186): a compensable step records its inverse as an INVOCATION, derived by its verb from the args
-- and the entry; rollback runs it through the same step executor, newest first, interleaved with journal undos. The
-- oracle is both worlds after the rollback: the journaled file byte-identical to before, the "remote" sink back to
-- its prior value — and a compensation that fails says which step it could not undo.
local store = require 'cartograph.store'
local ts = require 'cartograph.providers.treesitter'
local txn = require 'cartograph.txn'
local tactic = require 'cartograph.tactic'
local T = tactic.T

local function ready() return pcall(vim.treesitter.get_string_parser, '', 'lua') end

local root, unpush_fails
local function file(rel) local fd = io.open(root .. '/' .. rel); if not fd then return nil end; local s = fd:read('a'); fd:close(); return s end
local function put(rel, s) local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(s); fd:close() end
local function plan_on(rel, desc)
    return txn.protocol({ verb = desc, guards = {}, refspecs = {}, touched = { rel }, generation = store.generation,
        stamps = { [rel] = txn.disk_stamp(root, rel) }, desc = desc, preserves = 'none' },
        function () return function (_, b) return b .. '-- ' .. desc .. '\n' end end)
end
local VERBS = {
    jw = { effect = 'journaled', rerun = 'empty', plan = function (_, a)
        if (file('a.lua') or ''):find('-- jw' .. (a.n or ''), 1, true) then return nil, 'there', 'empty' end
        return plan_on('a.lua', 'jw' .. (a.n or ''))
    end },
    -- a REMOTE-like effect: the "remote" is a sink file outside the journal; its inverse removes the id it pushed
    push = { effect = 'compensable', plan = function (_, a) return plan_on('a.lua', 'push-staged') end,
        apply = function (_, _) put('remote.txt', (file('remote.txt') or '') .. 'pushed\n'); return { id = 'push-1' } end,
        compensate = function (args, entry) return { verb = 'unpush', args = { id = entry.id } } end },
    unpush = { effect = 'compensable', plan = function () return plan_on('a.lua', 'unpush-staged') end,
        apply = function (_, _)
            if unpush_fails then error('the remote refused the undo') end
            put('remote.txt', ((file('remote.txt') or ''):gsub('pushed\n', '', 1))); return { id = 'unpush-1' }
        end },
    refuse = { effect = 'journaled', plan = function () return nil, 'this verb cannot yet', 'unbuilt' end },
}
local function fresh()
    root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    put('a.lua', 'return 1\n'); put('remote.txt', '')
    store.ingest(ts.extract(root))
    unpush_fails = false
end
local function run(term, o) o = o or {}; o.verbs = VERBS; o.apply = true; return tactic.run(store, term, o) end

test('compensation: on_stop = rollback undoes a JOURNALED and a COMPENSABLE step, newest first — both worlds back', function ()
    if not ready() then skip 'no lua parser' end
    fresh()
    local r = run(T.seq(T.step('jw', {}), T.step('push', {}), T.step('refuse', {})), { on_stop = 'rollback' })
    eq('failed', r.status); eq(2, r.rolled_back, tostring(r.rollback_refused or r.rollback_failed))
    eq('return 1\n', file('a.lua'), 'the journaled write is undone')
    eq('', file('remote.txt'), 'the compensable effect is COMPENSATED — the remote is back to its prior value')
    eq(0, #r.completed)
end)

test('compensation: a compensation that FAILS leaves the run rollback_failed, naming the step and its inverse', function ()
    if not ready() then skip 'no lua parser' end
    fresh()
    unpush_fails = true
    local r = run(T.seq(T.step('jw', {}), T.step('push', {}), T.step('refuse', {})), { on_stop = 'rollback' })
    eq('failed', r.status)
    ok(r.rollback_failed and r.rollback_failed:find('push', 1, true) and r.rollback_failed:find('unpush', 1, true), tostring(r.rollback_failed))
    eq('pushed\n', file('remote.txt'), 'nothing pretended to undo it')
end)

test('compensation: a failed `first` alternative is COMPENSATED before the next one runs', function ()
    if not ready() then skip 'no lua parser' end
    fresh()
    local r = run(T.first(T.seq(T.step('push', {}), T.step('refuse', {})), T.step('jw', { n = 2 })))
    eq('done', r.status, tostring(r.why))
    eq('', file('remote.txt'), 'the abandoned alternative\'s remote effect was compensated')
    ok(file('a.lua'):find('-- jw2', 1, true), 'and the second alternative ran')
end)
