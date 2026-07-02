-- Unit tests for ledger reconstruction: diffing two graph snapshots into a
-- structural delta and classifying the operation.

local ledger = require 'cartograph.history.ledger'

local R0 = { start = { line = 0, char = 0 }, ['end'] = { line = 0, char = 0 } }
-- id embeds a line to mimic real dumps (proves matching is by file/name/kind)
local function fn(file, name, line) return { id = file .. '::' .. name .. '@' .. (line or 0), name = name, kind = 'function', file = file, range = R0, order = line or 0 } end
local function mod(file) return { id = file, name = file, kind = 'module', file = file, range = R0, order = 0 } end
local function ref(a, b) return { from = a.id, to = b.id, kind = 'ref', at = {} } end
local function g(nodes, edges) return { schema = 1, root = '/x', nodes = nodes, edges = edges or {} } end

test('ledger: an added function is detected as an extract', function ()
    local before = g({ mod('m.lua'), fn('m.lua', 'big', 1) })
    local after  = g({ mod('m.lua'), fn('m.lua', 'big', 1), fn('m.lua', 'helper', 20) })
    local d = ledger.delta(before, after)
    eq({ 'm.lua::helper/function' }, d.added)
    eq({}, d.removed)
    eq('extract', ledger.classify(d))
end)

test('ledger: node identity ignores line/id churn', function ()
    -- same function, moved down the file (new line, new id) -> NOT a change
    local before = g({ mod('m.lua'), fn('m.lua', 'f', 5) })
    local after  = g({ mod('m.lua'), fn('m.lua', 'f', 99) })
    local d = ledger.delta(before, after)
    eq({}, d.added)
    eq({}, d.removed)
    eq('internal', ledger.classify(d))
end)

test('ledger: a lone remove+add in one file is a rename', function ()
    local before = g({ mod('m.lua'), fn('m.lua', 'oldName', 1) })
    local after  = g({ mod('m.lua'), fn('m.lua', 'newName', 1) })
    local d = ledger.delta(before, after)
    eq(1, #d.renamed)
    eq('m.lua::oldName/function', d.renamed[1].from)
    eq('m.lua::newName/function', d.renamed[1].to)
    eq({}, d.added)
    eq({}, d.removed)
    eq('rename', ledger.classify(d))
end)

test('ledger: a removed function is an inline/removal', function ()
    local before = g({ mod('m.lua'), fn('m.lua', 'a', 1), fn('m.lua', 'b', 2) })
    local after  = g({ mod('m.lua'), fn('m.lua', 'a', 1) })
    local d = ledger.delta(before, after)
    eq({ 'm.lua::b/function' }, d.removed)
    eq('inline', ledger.classify(d))
end)

test('ledger: new reference edge with no node change is a rewire', function ()
    local a1, b1 = fn('m.lua', 'a', 1), fn('m.lua', 'b', 2)
    local before = g({ mod('m.lua'), a1, b1 })
    local after  = g({ mod('m.lua'), a1, b1 }, { ref(a1, b1) })
    local d = ledger.delta(before, after)
    eq(1, d.edges_added)
    eq('rewire', ledger.classify(d))
end)

test('ledger: edges are matched by endpoint name, not id', function ()
    -- same a->b edge, but ids differ across snapshots (lines moved) => no delta
    local before = g({ mod('m.lua'), fn('m.lua', 'a', 1), fn('m.lua', 'b', 2) },
                      { { from = 'm.lua::a@1', to = 'm.lua::b@2', kind = 'ref', at = {} } })
    local after  = g({ mod('m.lua'), fn('m.lua', 'a', 5), fn('m.lua', 'b', 9) },
                      { { from = 'm.lua::a@5', to = 'm.lua::b@9', kind = 'ref', at = {} } })
    local d = ledger.delta(before, after)
    eq(0, d.edges_added)
    eq(0, d.edges_removed)
end)

test('ledger: reconstruct produces one step per transition', function ()
    local s1 = g({ mod('m.lua'), fn('m.lua', 'a', 1) })
    local s2 = g({ mod('m.lua'), fn('m.lua', 'a', 1), fn('m.lua', 'b', 2) })
    local s3 = g({ mod('m.lua'), fn('m.lua', 'a', 1) })
    local steps = ledger.reconstruct({ s1, s2, s3 }, { 'base', 'extract b', 'inline b' })
    eq(2, #steps)
    eq('extract', steps[1].op)
    eq('extract b', steps[1].label)
    eq('inline', steps[2].op)
end)
