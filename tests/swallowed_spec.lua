-- Unit tests for the swallowed-type lint: inferred calls betray a receiver
-- whose class was laundered to `unknown`; the fix targets the root cause.

local store = require 'cartograph.store'
local lint  = require 'cartograph.lint'

local GET, ZAP = 'm.lua::Thing.get@5', 'm.lua::Thing:zap@10'

local function fn(id, name, l)
    return { id = id, name = name, kind = 'function', file = 'm.lua',
        range = { start = { line = l, char = 0 }, ['end'] = { line = l + 3, char = 0 } }, order = 1 }
end

local function graph(calls)
    store.ingest({ schema = 1, root = '/x',
        nodes = { fn(GET, 'Thing.get', 5), fn(ZAP, 'Thing:zap', 10) },
        edges = {}, calls = calls })
end

local function only() return { only = { ['swallowed-type'] = true } } end

-- an inferred method call on local `t` (defined at line 20)
local function zap_call(line)
    return { callee = 'zap', to = ZAP, inferred = true, method = true,
        file = 'm.lua', line = line or 21, args = { '' },
        argv = { { k = 'local', name = 't', l = 20 } }, fn = 'x' }
end
-- the resolved getter call on the def line
local function get_call()
    return { callee = 'get', to = GET, file = 'm.lua', line = 20,
        args = {}, argv = {}, fn = 'x' }
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
    graph({ { callee = 'zap', to = ZAP, inferred = true, method = true,
        file = 'm.lua', line = 33, args = { '' },
        argv = { { k = 'field', path = 'state.thing' } }, fn = 'x' } })
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
