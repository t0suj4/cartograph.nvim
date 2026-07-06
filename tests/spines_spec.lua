-- Spine detection: Cooper-Harvey-Kennedy dominators, dominator-tree shape,
-- and the region-poset forest test. Pure over fake adjacency/sets.

local spines = require 'cartograph.spines'

-- ── dominators ──────────────────────────────────────────────────────────────

test('dominators: a diamond is dominated by its head', function ()
    -- a -> b -> d ; a -> c -> d ; d -> e   (d reachable two ways -> idom a)
    local succ = { a = { 'b', 'c' }, b = { 'd' }, c = { 'd' }, d = { 'e' }, e = {} }
    local idom = spines.dominators('a', succ)
    eq('a', idom['b'])
    eq('a', idom['c'])
    eq('a', idom['d']) -- two paths reach d, so only a dominates it
    eq('d', idom['e'])
    eq('a', idom['a']) -- root dominates itself
end)

test('dominators: a chain dominates linearly', function ()
    local succ = { a = { 'b' }, b = { 'c' }, c = { 'd' }, d = {} }
    local idom = spines.dominators('a', succ)
    eq('a', idom['b'])
    eq('b', idom['c'])
    eq('c', idom['d'])
end)

test('dominators: cycle-safe (a back edge does not loop)', function ()
    local succ = { a = { 'b' }, b = { 'c' }, c = { 'b' } } -- b<->c cycle
    local idom = spines.dominators('a', succ)
    eq('a', idom['b'])
    eq('b', idom['c'])
end)

-- ── dominator-tree shape ─────────────────────────────────────────────────────

test('shape: a deep chain reads as a spine', function ()
    local succ = { a = { 'b' }, b = { 'c' }, c = { 'd' }, d = { 'e' }, e = { 'f' }, f = {} }
    local d = spines.dominator_analysis({ 'a' }, succ)[1]
    eq(6, d.size)
    eq(5, d.depth)
    eq('spine', d.shape)
end)

test('shape: a star (all callees off the root) reads as bushy', function ()
    local succ = { a = { 'b', 'c', 'd', 'e' }, b = {}, c = {}, d = {}, e = {} }
    local d = spines.dominator_analysis({ 'a' }, succ)[1]
    eq(4, d.root_children)
    eq('bushy', d.shape)
end)

-- ── region forest ────────────────────────────────────────────────────────────

local function region(...) local s, n = {}, 0; for _, e in ipairs({ ... }) do s[e] = true; n = n + 1 end return { set = s, n = n } end

test('region_forest: nested regions form a tree', function ()
    -- {e1} and {e2} both under {e1,e2}: each has one parent -> a forest
    local rf = spines.region_forest({ region('e1'), region('e2'), region('e1', 'e2') })
    eq(true, rf.forest)
    eq(0, rf.multiparent)
end)

test('region_forest: a region under two incomparable supers is NOT a forest', function ()
    -- {e1} sits under both {e1,e2} and {e1,e3} -> multi-parent (a layering seam)
    local rf = spines.region_forest({
        region('e1'), region('e2'), region('e3'),
        region('e1', 'e2'), region('e1', 'e3'),
    })
    eq(false, rf.forest)
    ok(rf.multiparent >= 1, 'e1 has two immediate super-regions')
end)
