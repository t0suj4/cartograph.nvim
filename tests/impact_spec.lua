-- Unit tests for the ImpactEngine: given a graph, a move-set, and a destination,
-- does it describe the move's consequences correctly? Pure data-in/data-out.

local store  = require 'cartograph.store'
local impact = require 'cartograph.impact'

local R0 = { start = { line = 0, char = 0 }, ['end'] = { line = 0, char = 0 } }
local function mod(file, effects) return { id = file, name = file, kind = 'module', file = file, range = R0, order = 0, effects = effects } end
local function fn(file, name) return { id = file .. '::' .. name, name = name, kind = 'function', file = file, range = R0, order = 0 } end
local function ref(from, to, n)
    local at = {}
    for _ = 1, (n or 1) do at[#at + 1] = { start = R0.start, ['end'] = R0['end'] } end
    return { from = from, to = to, kind = 'ref', at = at }
end
local function import(from, to) return { from = from, to = to, kind = 'import', sideeffect = false } end
local function graph(nodes, edges) store.ingest({ schema = 1, root = '/x', nodes = nodes, edges = edges or {} }) end

test('impact: cross-file caller becomes a rewrite + a require to add', function ()
    -- match.lua calls src.lua::a twice; move a -> dest.lua
    graph(
        { mod('src.lua', false), fn('src.lua', 'a'),
          mod('match.lua', false), fn('match.lua', 'm'),
          mod('dest.lua', false) },
        { ref('match.lua::m', 'src.lua::a', 2) })
    local p = impact.compute(store, { 'src.lua::a' }, 'dest.lua')
    eq(1, #p.rewrites)
    eq('match.lua', p.rewrites[1].file)
    eq(2, p.rewrites[1].total)
    eq({ 'match.lua' }, p.requires_add)
end)

test('impact: a caller in the destination does NOT need a rewrite', function ()
    -- dest.lua::d calls src.lua::a; moving a into dest.lua makes it a local call
    graph(
        { mod('src.lua', false), fn('src.lua', 'a'),
          mod('dest.lua', false), fn('dest.lua', 'd') },
        { ref('dest.lua::d', 'src.lua::a', 1) })
    local p = impact.compute(store, { 'src.lua::a' }, 'dest.lua')
    eq(0, #p.rewrites)
    eq({}, p.requires_add)
end)

test('impact: a caller already requiring dest needs no new require', function ()
    graph(
        { mod('src.lua', false), fn('src.lua', 'a'),
          mod('match.lua', false), fn('match.lua', 'm'),
          mod('dest.lua', false) },
        { ref('match.lua::m', 'src.lua::a', 1), import('match.lua', 'dest.lua') })
    local p = impact.compute(store, { 'src.lua::a' }, 'dest.lua')
    eq(1, #p.rewrites)          -- still a call site to rewrite
    eq({}, p.requires_add)      -- but the require already exists
end)

test('impact: dest must require a stayed-behind dependency', function ()
    -- move a; a uses helper (staying in src) -> dest must require src
    graph(
        { mod('src.lua', false), fn('src.lua', 'a'), fn('src.lua', 'helper'),
          mod('dest.lua', false) },
        { ref('src.lua::a', 'src.lua::helper', 1) })
    local p = impact.compute(store, { 'src.lua::a' }, 'dest.lua')
    eq({ 'src.lua' }, p.dest_requires)
end)

test('impact: a dependency that moves with the symbol needs no require', function ()
    graph(
        { mod('src.lua', false), fn('src.lua', 'a'), fn('src.lua', 'helper'),
          mod('dest.lua', false) },
        { ref('src.lua::a', 'src.lua::helper', 1) })
    local p = impact.compute(store, { 'src.lua::a', 'src.lua::helper' }, 'dest.lua')
    eq({}, p.dest_requires)     -- helper travels too
end)

test('impact: moving into a side-effect module warns about load order', function ()
    graph(
        { mod('src.lua', false), fn('src.lua', 'a'), mod('dest.lua', true) },
        {})
    local p = impact.compute(store, { 'src.lua::a' }, 'dest.lua')
    local kinds = {}
    for _, h in ipairs(p.hazards) do kinds[h.kind] = h.level end
    eq('warn', kinds['load-order'])
end)

test('impact: cycle risk when dest must require a module that requires dest', function ()
    -- a (moving to dest) uses helper in src; src already requires dest -> cycle
    graph(
        { mod('src.lua', false), fn('src.lua', 'a'), fn('src.lua', 'helper'),
          mod('dest.lua', false) },
        { ref('src.lua::a', 'src.lua::helper', 1), import('src.lua', 'dest.lua') })
    local p = impact.compute(store, { 'src.lua::a' }, 'dest.lua')
    local has_cycle = false
    for _, h in ipairs(p.hazards) do if h.kind == 'cycle' then has_cycle = true end end
    ok(has_cycle, 'expected a cycle hazard')
end)

test('impact: scope-coupling limitation is always disclosed', function ()
    graph({ mod('src.lua', false), fn('src.lua', 'a'), mod('dest.lua', false) }, {})
    local p = impact.compute(store, { 'src.lua::a' }, 'dest.lua')
    local disclosed = false
    for _, h in ipairs(p.hazards) do if h.kind == 'scope' then disclosed = true end end
    ok(disclosed, 'expected the scope-coupling disclosure')
end)

test('impact: no destination yet -> just the staged list, no rewrites', function ()
    graph({ mod('src.lua', false), fn('src.lua', 'a') }, {})
    local p = impact.compute(store, { 'src.lua::a' }, nil)
    eq(1, #p.moves)
    eq(0, #p.rewrites)
    eq({}, p.requires_add)
end)
