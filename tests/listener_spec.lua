-- Unit tests for the wiretap-style listener audit (paired register/subscribe/
-- unsubscribe keyed by a call argument). Drives lint via a synthetic call
-- inventory in the dump; method calls put self at args[1], so names sit one over.

local store = require 'cartograph.store'
local lint  = require 'cartograph.lint'

-- method call: self placeholder at args[1], logical arg 1 at args[2], etc.
local function call(callee, names, opts)
    opts = opts or {}
    local args = { '' } -- self
    for _, n in ipairs(names) do args[#args + 1] = n end
    return { callee = callee, args = args, method = true, top = opts.top ~= false,
        file = 'm.lua', line = opts.line or 1 }
end
local function reg(name, opts) return call('register_listener', { name }, opts) end
-- subscribe(type, name): type at logical 1, name at logical 2
local function sub(name) return call('subscribe', { 'evt', name }) end
local function unsub(name) return call('unsubscribe', { 'evt', name }) end
local function dyn(verb) return call(verb, { 'evt', '' }) end -- non-literal name

local function graph(calls) store.ingest({ schema = 1, root = '/x',
    nodes = { { id = 'm.lua', name = 'm.lua', kind = 'module', file = 'm.lua',
        range = { start = { line = 0, char = 0 }, ['end'] = { line = 0, char = 0 } }, order = 0 } },
    edges = {}, calls = calls }) end

local function only() return { only = { ['listener-audit'] = true } } end
local function msgs(f) local m = {} for _, x in ipairs(f) do m[#m + 1] = x.message end return table.concat(m, '\n') end

test('listener: clean register+subscribe+unsubscribe -> no findings', function ()
    graph({ reg('a'), sub('a'), unsub('a') })
    eq(0, #lint.run(store, only()))
end)

test('listener: subscribe to an unregistered name is flagged (runtime error)', function ()
    graph({ reg('a'), sub('ghost') })
    ok(msgs(lint.run(store, only())):match("subscribe to 'ghost'"), 'ghost flagged')
end)

test('listener: registered-but-never-subscribed is flagged', function ()
    graph({ reg('a'), reg('b'), sub('a'), unsub('a') })
    ok(msgs(lint.run(store, only())):match("'b' is registered but never subscribed"), 'b flagged')
end)

test('listener: a dynamic subscribe suppresses the dead-registration check', function ()
    graph({ reg('a'), reg('b'), dyn('subscribe') }) -- b could be subscribed dynamically
    ok(not msgs(lint.run(store, only())):match('never subscribed'), 'suppressed')
end)

test('listener: subscribed-but-never-unsubscribed is flagged (leak)', function ()
    graph({ reg('a'), sub('a') })
    ok(msgs(lint.run(store, only())):match("'a' is subscribed but never unsubscribed"), 'leak flagged')
end)

test('listener: a dynamic unsubscribe suppresses the leak check', function ()
    graph({ reg('a'), sub('a'), dyn('unsubscribe') })
    ok(not msgs(lint.run(store, only())):match('never unsubscribed'), 'suppressed')
end)

test('listener: registering inside a function (not at load) is flagged', function ()
    graph({ reg('a', { top = false }), sub('a'), unsub('a') })
    ok(msgs(lint.run(store, only())):match("registered inside a function"), 'lazy flagged')
end)

test('listener: no register_listener anywhere -> rule is inert', function ()
    graph({ sub('x'), unsub('x') })
    eq(0, #lint.run(store, only()))
end)
