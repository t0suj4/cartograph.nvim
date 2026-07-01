-- Unit tests for hub/heat role classification.

local heat = require 'cartograph.heat'

test('heat: high fan-in, low fan-out is a hub', function ()
    eq('hub', heat.role(12, 3, false).tag)
end)

test('heat: high fan-out, low fan-in is a coordinator', function ()
    eq('coordinator', heat.role(1, 9, false).tag)
end)

test('heat: a low-traffic function with no callees is a leaf', function ()
    eq('leaf', heat.role(2, 0, false).tag)
end)

test('heat: many callers still reads as hub even with no callees', function ()
    -- hub (load-bearing) takes precedence over leaf (terminal) — more informative
    eq('hub', heat.role(5, 0, false).tag)
end)

test('heat: no callers + local is a suspicious unused', function ()
    eq('unused?', heat.role(0, 2, false).tag)
end)

test('heat: no callers + exported is an api entry (not dead)', function ()
    -- the entry-point trap: exported/no-caller is public surface, not dead
    eq('api', heat.role(0, 2, true).tag)
end)

test('heat: no callers and no callees is isolated', function ()
    eq('isolated', heat.role(0, 0, false).tag)
end)

test('heat: balanced fan-in/out has no special role', function ()
    eq('', heat.role(3, 3, false).tag)
end)
