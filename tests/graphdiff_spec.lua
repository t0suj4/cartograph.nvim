-- Structural graph diff: per-item comparison two count-parity totals can't
-- fake — attr flips and resolution changes surface as `changed`, and the
-- report never silently truncates.

local gd = require 'cartograph.graphdiff'

local function data(nodes, edges, calls)
    return { schema = 1, root = '/x', nodes = nodes or {}, edges = edges or {},
        calls = calls or {} }
end
local function n(id) return { id = id, name = id, kind = 'function', file = 'm.lua' } end

test('graphdiff: identical graphs are empty', function ()
    local a = data({ n 'f' }, { { from = 'f', to = 'g', kind = 'ref' } },
        { { file = 'm.lua', line = 3, callee = 'g', to = 'g' } })
    local d = gd.diff(a, a)
    ok(gd.empty(d), 'no differences')
    eq('graphs are identical (per-item)', gd.report(d)[1])
end)

test('graphdiff: count parity does NOT fool it', function ()
    -- same totals (1 edge each), different edges — the exact failure mode
    -- a total-count gate waves through
    local a = data({}, { { from = 'f', to = 'g', kind = 'ref' } })
    local b = data({}, { { from = 'f', to = 'h', kind = 'ref' } })
    local d = gd.diff(a, b)
    ok(not gd.empty(d), 'caught')
    eq(1, #d.edges.added)
    eq(1, #d.edges.removed)
    ok(d.edges.added[1]:find('f %-> h'), d.edges.added[1])
    ok(d.edges.removed[1]:find('f %-> g'), d.edges.removed[1])
end)

test('graphdiff: an attr flip is CHANGED, not add+remove', function ()
    local a = data({}, { { from = 'f', to = 'g', kind = 'ref', inferred = true } })
    local b = data({}, { { from = 'f', to = 'g', kind = 'ref', proven = true } })
    local d = gd.diff(a, b)
    eq(0, #d.edges.added)
    eq(0, #d.edges.removed)
    eq(1, #d.edges.changed)
    -- the two SIDES, not one exact substring: the signature grew a write-axis
    -- term (CART-0532), so `~ => proven` became `~ w- => proven w-`. What this
    -- test is about is that a trust flip lands in `changed` rather than
    -- add+remove, and that both tiers are named — matching the whole rendering
    -- would make every future signature term look like a regression here.
    local before, after = d.edges.changed[1]:match('(.*) => (.*)$')
    ok(before and before:find('~', 1, true), tostring(d.edges.changed[1]))
    ok(after and after:find('proven', 1, true), tostring(d.edges.changed[1]))
end)

test('graphdiff: duplicate pairs are counted, not set-membered', function ()
    local e = { from = 'f', to = 'g', kind = 'ref' }
    local a = data({}, { e, e }) -- two call sites, same pair
    local b = data({}, { e })
    local d = gd.diff(a, b)
    eq(1, #d.edges.changed) -- 2x matched -> 1x matched
    ok(d.edges.changed[1]:find('2x matched'), d.edges.changed[1])
end)

test('graphdiff: a call resolution change surfaces by site', function ()
    local a = data({}, {}, { { file = 'm.lua', line = 3, callee = 'g',
        refused = { rule = 'ambiguous' } } })
    local b = data({}, {}, { { file = 'm.lua', line = 3, callee = 'g', to = 'g' } })
    local d = gd.diff(a, b)
    eq(1, #d.calls.changed)
    ok(d.calls.changed[1]:find('m.lua:4 g'), d.calls.changed[1])
    ok(d.calls.changed[1]:find('refused %(ambiguous%) => to g'), d.calls.changed[1])
end)

test('graphdiff: node add/remove; report caps count what they cut', function ()
    local a = data({ n 'f' })
    local b = data({ n 'g', n 'h', n 'i' })
    local d = gd.diff(a, b)
    eq(3, #d.nodes.added)
    eq(1, #d.nodes.removed)
    local rep = gd.report(d, { limit = 2 })
    local joined = table.concat(rep, '\n')
    ok(joined:find('nodes added %(3%)'), joined)
    ok(joined:find('… 1 more'), 'the cut is counted')
end)
