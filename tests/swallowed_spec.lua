-- Unit tests for the swallowed-type lint: inferred calls betray a receiver
-- whose class was laundered to `unknown`; the fix targets the root cause.

local store = require 'cartograph.store'
local lint  = require 'cartograph.lint'

local GET, ZAP = 'm.lua::Thing.get@5', 'm.lua::Thing:zap@10'
-- THE ENCLOSING FN, and it is not decoration (CART-0241). These fixtures used to hand a
-- `argv = { { k = 'local', name = 't', l = 20 } }` to the lint, and the lint believed it —
-- but the extractor NEVER produces that: slot 1 of a method call is a positional
-- placeholder (`{ k = 'expr' }`) that every other argv consumer skips. So the repair branch
-- was unreachable on real input for 1987 findings while these tests stayed green, because a
-- hand-built input supplied the one shape reality lacks. The lint now reads the receiver
-- name from `full` and its binding line from the enclosing fn's FINE flow rows, so the
-- fixture has to carry both — which is exactly what makes the test worth having.
local CALLER = 'm.lua::use@18'

local function fn(id, name, l)
    return { id = id, name = name, kind = 'function', file = 'm.lua',
        range = { start = { line = l, char = 0 }, ['end'] = { line = l + 3, char = 0 } }, order = 1 }
end

local function graph(calls)
    local caller = fn(CALLER, 'use', 18)
    -- fine flow rows: `t` is bound on 0-based line 20, and rows are 1-BASED
    -- c/parent are not decoration: flow.fold reads both on every fine row
    caller.flow = { stmts = { { l = 21, c = 0, parent = 0,
        def = { 't' }, use = { 'get' } } }, params = {} }
    store.ingest({ schema = 1, root = '/x',
        nodes = { fn(GET, 'Thing.get', 5), fn(ZAP, 'Thing:zap', 10), caller },
        edges = {}, calls = calls })
end

local function only() return { only = { ['swallowed-type'] = true } } end

-- an inferred method call on local `t` (defined at line 20)
local function zap_call(line)
    -- `full` carries the receiver, as the extractor writes it; argv slot 1 stays the
    -- placeholder the extractor actually emits
    return { callee = 'zap', full = 't:zap', to = ZAP, inferred = true, method = true,
        file = 'm.lua', line = line or 21, args = { '' },
        argv = { { k = 'expr' } }, fn = CALLER }
end
-- the resolved getter call on the def line
local function get_call()
    return { callee = 'get', to = GET, file = 'm.lua', line = 20,
        args = {}, argv = {}, fn = CALLER }
end

test('swallowed: root cause found -> one finding, ---@return on the getter', function ()
    graph({ get_call(), zap_call(21), zap_call(30), zap_call(40) })
    local f = lint.run(store, only())
    eq(1, #f) -- three call sites, ONE finding at the getter
    eq(6, f[1].line) -- Thing.get's def line (1-based)
    eq('---@return Thing', f[1].fix.text)
    ok(f[1].message:match('3 call'), 'counts the call sites')
end)

test('swallowed: no getter on the def line -> ---@type on the local', function ()
    graph({ zap_call(21) })
    local f = lint.run(store, only())
    eq(1, #f)
    eq(21, f[1].line) -- the local's def line (1-based)
    eq('---@type Thing', f[1].fix.text)
end)

test('swallowed: non-local receiver -> finding at the call, no fix', function ()
    -- a CHAIN receiver (`state.thing:zap()`): not a simple local, so no repair
    graph({ { callee = 'zap', full = 'state.thing:zap', to = ZAP, inferred = true,
        method = true, file = 'm.lua', line = 33, args = { '' },
        argv = { { k = 'expr' } }, fn = CALLER } })
    local f = lint.run(store, only())
    eq(1, #f)
    eq(34, f[1].line)
    eq(nil, f[1].fix)
end)

test('swallowed: vm-resolved calls raise nothing', function ()
    graph({ get_call(), { callee = 'zap', to = ZAP, method = true,
        file = 'm.lua', line = 21, args = { '' },
        argv = { { k = 'local', name = 't', l = 20 } }, fn = 'x' } })
    eq(0, #lint.run(store, only()))
end)
