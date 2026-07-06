-- Territorial decomposition: entry-sets partition nodes into territory /
-- commons / core, and borders mark the seams. Pure over fake adjacency.

local territory = require 'cartograph.territory'

-- three entries; a/b/c are private; sh12 is shared by e1+e2; core by all.
--   e1->a, e2->b, e3->c ; a->{sh12,core} ; b->{sh12,core} ; c->{core}
local uses = {
    e1 = { 'a' }, e2 = { 'b' }, e3 = { 'c' },
    a = { 'sh12', 'core' }, b = { 'sh12', 'core' }, c = { 'core' },
    sh12 = {}, core = {},
}
local usedby = {
    a = { 'e1' }, b = { 'e2' }, c = { 'e3' },
    sh12 = { 'a', 'b' }, core = { 'a', 'b', 'c' },
}

test('territory: private code is one entry\'s territory', function ()
    local t = territory.compute({ 'e1', 'e2', 'e3' }, uses, usedby)
    eq('territory', t.node['a'].class)
    eq('e1', t.node['a'].entry)
    eq('territory', t.node['b'].class)
    eq('e2', t.node['b'].entry)
end)

test('territory: shared-by-some is commons, shared-by-all is core', function ()
    local t = territory.compute({ 'e1', 'e2', 'e3' }, uses, usedby)
    eq('commons', t.node['sh12'].class) -- e1 + e2, not e3
    eq(2, t.node['sh12'].n)
    eq('core', t.node['core'].class)    -- all three
    eq(3, t.node['core'].n)
end)

test('territory: borders are the seams into shared ground', function ()
    local t = territory.compute({ 'e1', 'e2', 'e3' }, uses, usedby)
    ok(t.node['sh12'].border, 'sh12 joins e1+e2 -> border')
    ok(t.node['core'].border, 'core joins all -> border')
    ok(not t.node['a'].border, 'private code entered only from its own entry is not a border')
end)

test('territory: unreached nodes are absent from the partition', function ()
    local t = territory.compute({ 'e1' }, { e1 = { 'a' }, a = {}, dead = {} },
        { a = { 'e1' } })
    ok(t.node['a'], 'a is reached')
    eq(nil, t.node['dead'], 'dead is unreached -> not in the map')
end)

test('territory: a single entry reads as one territory, not core', function ()
    local t = territory.compute({ 'e1' }, { e1 = { 'a' }, a = {} }, { a = { 'e1' } })
    eq('territory', t.node['a'].class)
    eq('territory', t.node['e1'].class)
end)

test('territory: summary tallies territories, commons, core, borders', function ()
    local s = territory.summary(territory.compute({ 'e1', 'e2', 'e3' }, uses, usedby))
    eq(1, s.commons)
    eq(1, s.core)
    eq(2, s.borders)
    local terr_n = 0; for _ in pairs(s.territories) do terr_n = terr_n + 1 end
    eq(3, terr_n) -- e1, e2, e3 each own private code
end)
