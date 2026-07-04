-- Unit tests for the FSM reachability engine over a synthetic graph:
-- spec data tables + listener registrations + a small call graph.

local store = require 'cartograph.store'
local fsm   = require 'cartograph.fsm'

local CFG = {
    events    = { var = 'spec', path = { 'events' } },
    subs      = { var = 'subs' },
    callbacks = { var = 'cbs' },
    register  = 'register_listener',
}

local function node(id, name, kind, l1, l2, data)
    return { id = id, name = name, kind = kind, file = 'm.lua',
        range = { start = { line = l1, char = 0 }, ['end'] = { line = l2 or l1, char = 0 } },
        order = l1, data = data }
end

local function graph()
    store.ingest({ schema = 1, root = '/x',
        nodes = {
            node('v1', 'spec', 'var', 1, 1, { initial = 'boot', events = {
                { name = 'go',    from = 'ready', to = 'run' },
                { name = 'stop',  from = '*',     to = 'ready' },
                -- lua-state-machine allows an ARRAY of source states
                { name = 'start', from = { 'boot', 'idle' }, to = 'ready' },
            } }),
            node('v2', 'subs', 'var', 2, 2, {
                -- one bare {ref} entry (the shared spec idiom) + one direct
                run = { { ref = 'tick' }, { { ref = 'defines.events.x' }, 'on_run' } },
            }),
            node('v3', 'tick', 'var', 3, 3, { 'nth_tick', 'on_tick', 33 }),
            node('cbv', 'cbs', 'var', 10, 30, {}),
            node('cb1', 'onenterrun', 'function', 12, 14),
            node('cb2', 'onstatechange', 'function', 16, 18),
            node('h1', 'handle_run', 'function', 40, 45),
            node('h2', 'handle_tick', 'function', 50, 55),
            node('g1', 'deep', 'function', 60, 65),
        },
        edges = {
            { from = 'h1', to = 'g1', kind = 'ref', at = {} },
            { from = 'cb1', to = 'g1', kind = 'ref', at = {} },
        },
        calls = {
            { callee = 'register_listener', method = true, file = 'm.lua', line = 70,
              args = { '', 'on_run' },
              argv = { { k = 'local' }, { k = 'lit', v = 'on_run' }, { k = 'local', name = 'handle_run', l = 40 } },
              top = true },
            { callee = 'register_listener', method = true, file = 'm.lua', line = 71,
              args = { '', 'on_tick' },
              argv = { { k = 'local' }, { k = 'lit', v = 'on_tick' }, { k = 'local', name = 'handle_tick', l = 50 } },
              top = true },
        } })
end

test('fsm: model loads states and transitions from the data', function ()
    graph()
    local model = assert(fsm.load(store, CFG))
    -- `boot` comes from initial= and the array from; `idle` only from the array
    eq('boot,ready,run,idle', table.concat(model.order, ','))
    eq('boot', model.initial)
    eq(3, #model.transitions)
end)

test('fsm: array froms match in transitions_from', function ()
    graph()
    local model = assert(fsm.load(store, CFG))
    local names = {}
    for _, t in ipairs(fsm.transitions_from(model, 'boot')) do names[#names + 1] = t.name end
    table.sort(names)
    eq('start,stop', table.concat(names, ',')) -- start (array) + stop (from *)
end)

test('fsm: subscriptions resolve through {ref} indirection', function ()
    graph()
    local model = assert(fsm.load(store, CFG))
    eq(2, #model.subs.run) -- the ticking ref + the direct entry
    -- ref entry picks the registered name out of the spec array
    local names = {}
    for _, sub in ipairs(model.subs.run) do names[#names + 1] = sub.listener end
    table.sort(names)
    eq('on_run,on_tick', table.concat(names, ','))
end)

test('fsm: bindings resolve named handlers, entrypoints include callbacks', function ()
    graph()
    local model = assert(fsm.load(store, CFG))
    ok(model.bindings.on_run.fn == 'h1', 'handler resolved to node id')
    local eps = fsm.entrypoints(store, model, 'run')
    local labels = {}
    for _, e in ipairs(eps) do labels[#labels + 1] = e.label end
    table.sort(labels)
    -- listeners on_run/on_tick + onstatechange (stop from *) ; onenterready
    -- doesn't exist as a cb; onenterrun is NOT active in 'run' (it fires
    -- entering, not leaving) unless a transition re-enters run — none does
    ok(table.concat(labels, ','):match('on_run'), 'listener present')
    ok(table.concat(labels, ','):match('onstatechange'), 'callback present')
end)

test('fsm: the cone follows the call graph from resolved entries', function ()
    graph()
    local model = assert(fsm.load(store, CFG))
    local set, n = fsm.state_cone(store, model, 'run')
    ok(set['h1'] and set['g1'] and set['h2'], 'entries and transitive callee reached')
    ok(set['cb2'], 'active callback in the cone')
    eq(4, n) -- h1, h2, cb2, g1
end)

test('fsm: missing spec is an honest nil+reason', function ()
    store.ingest({ schema = 1, root = '/x', nodes = {}, edges = {} })
    local model, why = fsm.load(store, CFG)
    eq(nil, model)
    ok(why and why:match('spec'), 'reason names the missing table')
end)
