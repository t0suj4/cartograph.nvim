-- The Band: one topology interface, two interchangeable backends (wide
-- store, folded triple table). The API-first contract: the two backends
-- return IDENTICAL slices, so a consumer migrated onto the Band works on
-- either representation — proven here on the same graph, then relied on
-- when the representation swaps.

local band = require 'cartograph.band'
local fold = require 'cartograph.fold'
local store = require 'cartograph.store'

local R = { start = { line = 0, char = 0 }, ['end'] = { line = 0, char = 0 } }
local function node(id, kind)
    return { id = id, name = id, kind = kind or 'function',
        file = 'm.lua', range = R, order = 0 }
end

local DATA = {
    root = '/x',
    nodes = {
        node('m.lua', 'module'), node('a'), node('b'), node('c'),
        node('v', 'var'), node('iso'),
    },
    edges = {
        { from = 'a', to = 'b', kind = 'ref', at = { R } },
        { from = 'a', to = 'c', kind = 'ref', at = { R } },
        { from = 'b', to = 'c', kind = 'ref', at = { R } },
        { from = 'c', to = 'c', kind = 'ref', at = { R } },  -- self (recursion)
        { from = 'a', to = 'v', kind = 'use', at = { R } },
        { from = 'm.lua', to = 'b', kind = 'reg', at = { R } },
        { from = 'm.lua', to = 'other.lua', kind = 'import' },
    },
    calls = {},
}

local function sorted(t) local u = {} for i, x in ipairs(t) do u[i] = x end
    table.sort(u); return u end

test('band: store and fold backends return identical slices', function ()
    store.ingest(DATA)
    local bs = band.from_store(store)
    local bf = band.from_fold(fold.build(DATA))
    local methods = { 'callees', 'callers', 'var_uses', 'var_used_by',
        'registered', 'registrants', 'imports_out', 'imports_in' }
    for _, n in ipairs(DATA.nodes) do
        for _, m in ipairs(methods) do
            eq(sorted(bs[m](bs, n.id)), sorted(bf[m](bf, n.id)),
                m .. ' on ' .. n.id)
        end
    end
end)

test('band: certainty tier survives, identical on both backends', function ()
    local D = {
        root = '/x',
        nodes = { node('a'), node('b'), node('c') },
        edges = {
            { from = 'a', to = 'b', kind = 'ref', at = { R } },
            { from = 'a', to = 'c', kind = 'ref', inferred = true, at = { R } },
        },
        calls = {},
    }
    store.ingest(D)
    local bs = band.from_store(store)
    local bf = band.from_fold(fold.build(D))
    eq('confident', bs:tier('a', 'b')); eq('confident', bf:tier('a', 'b'))
    eq('inferred', bs:tier('a', 'c')); eq('inferred', bf:tier('a', 'c'))
    eq(nil, bs:tier('b', 'c')); eq(nil, bf:tier('b', 'c')) -- no such edge
end)

test('band: the ref view excludes self-loops (both backends)', function ()
    store.ingest(DATA)
    local bs = band.from_store(store)
    local bf = band.from_fold(fold.build(DATA))
    eq({ 'a', 'b' }, sorted(bs:callers('c')), 'store: c self excluded')
    eq({ 'a', 'b' }, sorted(bf:callers('c')), 'fold: c self excluded')
    eq(2, bs:n_callers('c'))
    eq(2, bf:n_callers('c'))
end)

test('band: sugar maps to the right predicate+direction', function ()
    store.ingest(DATA)
    local b = band.from_store(store)
    eq({ 'b', 'c' }, sorted(b:callees('a')))
    eq(2, b:n_callees('a')); eq(0, b:n_callees('c'), 'leaf: no callees')
    eq({ 'v' }, b:var_uses('a'))
    eq({ 'a' }, b:var_used_by('v'))
    eq({ 'b' }, b:registered('m.lua'))
    eq({ 'm.lua' }, b:registrants('b'))
    eq({ 'other.lua' }, b:imports_out('m.lua'))
    eq({}, b:callers('iso'), 'isolated node: empty, not nil')
end)

-- identity/detail axes: node-identity by name/file and call outcomes by fn
local IDATA = {
    root = '/x',
    nodes = {
        node('f.lua', 'module'),
        { id = 'f.lua::foo:1', name = 'foo', kind = 'function',
            file = 'f.lua', range = R, order = 0 },
        { id = 'g.lua::foo:1', name = 'foo', kind = 'function',
            file = 'g.lua', range = R, order = 0 }, -- same NAME, other file
        { id = 'f.lua::bar:2', name = 'bar', kind = 'function',
            file = 'f.lua', range = R, order = 1 },
    },
    edges = {},
    calls = {
        { fn = 'f.lua::foo:1', callee = 'bar', file = 'f.lua', line = 3,
            to = 'f.lua::bar:2' },
        { fn = 'f.lua::foo:1', callee = 'mystery', file = 'f.lua', line = 4,
            refused = { rule = 'ambiguous' } },
    },
}

test('band: NAME axis — named(name) returns every node with that name', function ()
    store.ingest(IDATA)
    local bs = band.from_store(store)
    local bf = band.from_fold(fold.build(IDATA), store) -- resident-shaped
    eq({ 'f.lua::foo:1', 'g.lua::foo:1' }, sorted(bs:named('foo')))
    eq({ 'f.lua::foo:1', 'g.lua::foo:1' }, sorted(bf:named('foo')),
        'identity axis identical on both backends')
    eq({ 'f.lua::bar:2' }, bs:named('bar'))
    eq({}, bs:named('nope'), 'unknown name: empty, not nil')
end)

test('band: FILE axis — nodes_of(file) returns the file\'s non-module nodes', function ()
    store.ingest(IDATA)
    local bs = band.from_store(store)
    local bf = band.from_fold(fold.build(IDATA), store)
    eq({ 'f.lua::bar:2', 'f.lua::foo:1' }, sorted(bs:nodes_of('f.lua')))
    eq({ 'f.lua::bar:2', 'f.lua::foo:1' }, sorted(bf:nodes_of('f.lua')))
    eq({ 'g.lua::foo:1' }, bs:nodes_of('g.lua'))
end)

test('band: SITE axis — sites(fn) returns the fn\'s call rows as outcomes', function ()
    store.ingest(IDATA)
    local bs = band.from_store(store)
    local rows = bs:sites('f.lua::foo:1')
    eq(2, #rows)
    -- one resolved, one refused — the outcome rides each row
    local resolved, refused = 0, 0
    for _, c in ipairs(rows) do
        if c.to then resolved = resolved + 1 end
        if c.refused then refused = refused + 1 end
    end
    eq(1, resolved); eq(1, refused)
    eq({}, bs:sites('nobody'), 'no calls: empty, not nil')
end)

test('band: USE/REG detail slices return the full records (both backends)', function ()
    local D = {
        root = '/x',
        nodes = { node('f'), node('g'), node('v', 'var'), node('h') },
        edges = {
            -- g writes v (rw=2), guarded (gw=2); f reads v (rw=1)
            { from = 'g', to = 'v', kind = 'use', at = { R }, rw = 2, gw = 2 },
            { from = 'f', to = 'v', kind = 'use', at = { R, R }, rw = 1 },
            { from = 'h', to = 'g', kind = 'reg', at = { R } }, -- h registers g
        },
        calls = {},
    }
    store.ingest(D)
    local bs = band.from_store(store)
    local bf = band.from_fold(fold.build(D), store)
    -- backward use records: who touches v, with the write axis + spans
    for _, b in ipairs({ bs, bf }) do
        local recs = b:var_used_by_detail('v')
        eq(2, #recs)
        local byfrom = {}
        for _, u in ipairs(recs) do byfrom[u.from] = u end
        eq(2, byfrom.g.rw); eq(2, byfrom.g.gw)          -- write, guarded
        eq(1, byfrom.f.rw); eq(2, #byfrom.f.at)         -- read, two sites
    end
    -- forward use records: what g touches
    eq('v', bs:var_uses_detail('g')[1].to)
    -- reg records: who registers g, with the site span
    eq('h', bs:registrants_detail('g')[1].from)
    eq(1, #bf:registrants_detail('g')[1].at)
    eq({}, bs:var_used_by_detail('nobody'), 'no edges: empty, not nil')
    eq({}, bs:registrants_detail('nobody'))
end)

test('band: a pure-topology fold (no idx) yields empty identity axes', function ()
    store.ingest(IDATA)
    local bare = band.from_fold(fold.build(IDATA)) -- no store handle
    eq({}, bare:named('foo'))
    eq({}, bare:nodes_of('f.lua'))
    eq({}, bare:sites('f.lua::foo:1'))
    eq({}, bare:var_used_by_detail('f.lua::foo:1'))
    eq({}, bare:registrants_detail('f.lua::foo:1'))
end)
