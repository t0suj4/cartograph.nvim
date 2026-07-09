-- The honesty census: counts by trust tier + refusals grouped by rule (the
-- analyzer work-list). Pure over a data table.

local census = require 'cartograph.census'

local function data()
    return {
        schema = 1, root = '/x',
        nodes = {
            { id = 'm', name = 'm', kind = 'module', file = 'm.lua' },
            { id = 'f', name = 'f', kind = 'function', file = 'm.lua' },
            { id = 'g', name = 'g', kind = 'function', file = 'm.lua' },
            { id = 'x.js::lost@3', name = 'lost', kind = 'function',
                file = 'x.js', unparsed = true },
        },
        edges = {
            { from = 'f', to = 'g', kind = 'ref' },                    -- matched
            { from = 'g', to = 'f', kind = 'ref', inferred = true },   -- ~
            { from = 'f', to = 'g', kind = 'ref', proven = true },     -- proven
            { from = 'm', to = 'm2', kind = 'import' },
        },
        calls = {
            { fn = 'f', callee = 'g', to = 'g', file = 'm.lua', line = 1 },
            { fn = 'f', callee = 'h', file = 'm.lua', line = 2,
                refused = { rule = 'ambiguous-name', n = 2 } },
            { fn = 'g', callee = 'h', file = 'm.lua', line = 5,
                refused = { rule = 'ambiguous-name', n = 2 } },
            { fn = 'g', callee = 'k', file = 'm.lua', line = 6,
                refused = { rule = 'dynamic-key' } },
            { fn = 'g', callee = 'print', file = 'm.lua', line = 7 },
            { fn = 'g', callee = 'q', to = 'g', file = 'm.lua', line = 8,
                hedge = { rule = 'shadow-walkout' } },
        },
    }
end

test('census: counts by kind, tier, and rule', function ()
    local c = census.take(data())
    eq(4, c.nodes.total)
    eq(3, c.nodes.by_kind['function'])
    eq(1, c.nodes.unparsed)
    eq(4, c.edges.total)
    eq(3, c.edges.by_kind.ref)
    eq(1, c.edges.ref.proven)
    eq(1, c.edges.ref.inferred)
    eq(1, c.edges.ref.matched)
    eq(6, c.calls.total)
    eq(2, c.calls.resolved)
    eq(3, c.calls.refused)
    eq(1, c.calls.unresolved) -- print: outside the corpus, not refused
    eq(1, c.calls.hedged)
    eq(2, c.calls.rules['ambiguous-name'].n)
    eq(1, c.calls.rules['dynamic-key'].n)
end)

test('census: the report ranks refusal rules by count', function ()
    local lines = table.concat(census.report(data()), '\n')
    ok(lines:find('refusals by rule'), 'work-list section present')
    -- ambiguous-name (2) must come before dynamic-key (1)
    ok(lines:find('ambiguous%-name.*dynamic%-key'), 'ranked by count')
    ok(lines:find('m.lua:3 h'), 'sample site (1-based line)')
    ok(lines:find('frontier: 1 unparsed'), 'frontier counted')
end)
