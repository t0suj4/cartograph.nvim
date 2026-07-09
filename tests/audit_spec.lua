-- store.audit: re-derive every index from data through the same builders and
-- diff against the live tables — the Log/View rule ("Views are only ever
-- derived") as an executable check. The money test: the post-ingest mutators
-- (add_edge/add_node/set_callers) must leave the store indistinguishable from
-- a fresh derive.

local store = require 'cartograph.store'

local R0 = { start = { line = 0, char = 0 }, ['end'] = { line = 0, char = 0 } }
local function node(id, file)
    return { id = id, name = id, kind = 'function', file = file or 'm.lua',
        range = R0, order = 0 }
end
local function ref(from, to, attrs)
    local e = { from = from, to = to, kind = 'ref', at = {} }
    for k, v in pairs(attrs or {}) do e[k] = v end
    return e
end
local function graph(nodes, edges, calls)
    return store.ingest({ schema = 1, root = '/x', nodes = nodes,
        edges = edges or {}, calls = calls or {} })
end

test('audit: a fresh ingest is clean', function ()
    graph({ node 'a', node 'b', node 'c' },
        { ref('a', 'b'), ref('b', 'c', { inferred = true }),
            { from = 'a', to = 'c', kind = 'use', at = {} } },
        { { fn = 'a', to = 'b', callee = 'b', file = 'm.lua', line = 1 } })
    eq({}, store.audit())
end)

test('audit: the post-ingest mutators keep the store derivable', function ()
    graph({ node 'a', node 'b', node 'c' },
        { ref('b', 'a', { inferred = true }) })
    -- the pin path
    store.add_edge(ref('c', 'a'))
    -- the frontier-landing path
    store.add_node({ id = 'x.js::lost@3', name = 'lost', kind = 'function',
        unparsed = true, file = 'x.js', order = 3, range = R0 })
    -- the demand-oracle path: replaces b->a with a proven c->a
    store.set_callers('a', { { from = 'c', at = R0 } })
    eq({}, store.audit())
end)

test('audit: manual index drift is caught and named', function ()
    graph({ node 'a', node 'b' }, { ref('a', 'b') })
    table.insert(store.usedby['b'], 'ghost') -- an in-place writer bug
    local out = store.audit()
    eq(1, #out)
    ok(out[1]:find('usedby%[b%]'), out[1])
    ok(out[1]:find('ghost'), out[1])
end)

test('audit: refuses while streaming', function ()
    local data = graph({ node 'a' }, {})
    data.partial = true
    local out, why = store.audit()
    eq(nil, out)
    ok(why:find('stream'), why)
    data.partial = nil
end)
