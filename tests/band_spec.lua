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
    eq({ 'v' }, b:var_uses('a'))
    eq({ 'a' }, b:var_used_by('v'))
    eq({ 'b' }, b:registered('m.lua'))
    eq({ 'm.lua' }, b:registrants('b'))
    eq({ 'other.lua' }, b:imports_out('m.lua'))
    eq({}, b:callers('iso'), 'isolated node: empty, not nil')
end)
