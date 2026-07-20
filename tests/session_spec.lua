-- The multi-band session: open ADDS a band, switching swaps the store lens
-- between bands with NO bleed, single-band stays byte-identical. The store
-- capture/restore round-trip is the load-bearing invariant.

local store = require 'cartograph.store'
local session = require 'cartograph.session'

local R = { start = { line = 0, char = 0 }, ['end'] = { line = 0, char = 0 } }
local function graph(root, fn)
    return {
        root = root,
        nodes = {
            { id = root .. '::m', name = 'm', kind = 'module', file = 'm.lua', range = R, order = 0 },
            { id = root .. '::' .. fn, name = fn, kind = 'function', file = 'm.lua', range = R, order = 0 },
        },
        edges = {}, calls = {},
    }
end

test('store: capture/restore round-trips per-band state, no bleed', function ()
    store.ingest(graph('/a', 'aaa'))
    local gen_a = store.generation
    local snap = store.capture()
    -- mutate the lens as if another band loaded
    store.ingest(graph('/b', 'bbb'))
    ok(store.node('/b::bbb'), 'lens now shows B')
    eq(nil, store.node('/a::aaa'), 'A is not visible while B is loaded')
    -- restore A
    store.restore(snap)
    ok(store.node('/a::aaa'), 'A restored')
    eq(nil, store.node('/b::bbb'), 'no B bleed after restoring A')
    eq(gen_a, store.generation, 'A\'s generation restored')
    eq('/a', store.data.root)
end)

test('session: open ADDS bands; switch swaps the lens without clobbering', function ()
    session.reset()
    -- open A
    session.begin('/a'); store.ingest(graph('/a', 'aaa'))
    eq('a', session.active)
    -- open B (begin freezes A first)
    session.begin('/b'); store.ingest(graph('/b', 'bbb'))
    eq('b', session.active)
    ok(store.node('/b::bbb') and not store.node('/a::aaa'), 'B active, A frozen')
    -- switch back to A — restored intact
    session.switch('a')
    ok(store.node('/a::aaa') and not store.node('/b::bbb'), 'A restored, no B bleed')
    eq('/a', store.data.root)
    -- and forward to B
    session.switch('b')
    ok(store.node('/b::bbb') and not store.node('/a::aaa'))
    -- the registry lists both, active flagged
    local names = {}
    for _, r in ipairs(session.list()) do names[r.name] = r.active end
    eq(false, names.a); eq(true, names.b)
end)

test('session: re-opening a root switches; owning routes by root containment', function ()
    session.reset()
    session.begin('/proj/a'); store.ingest(graph('/proj/a', 'aaa'))
    session.begin('/proj/b'); store.ingest(graph('/proj/b', 'bbb'))
    eq('a', session.by_root('/proj/a'))
    eq('a', session.owning('/proj/a/deep/file.lua'), 'file routes to its owning band')
    eq('b', session.owning('/proj/b/x.lua'))
    ok(session.switch_to_root('/proj/a'), 're-open of a registered root is a switch')
    eq('a', session.active)
    eq(nil, session.switch_to_root('/proj/never'), 'an unregistered root is not a switch')
end)

test('session: close drops a band and re-activates a survivor', function ()
    session.reset()
    session.begin('/a'); store.ingest(graph('/a', 'aaa'))
    session.begin('/b'); store.ingest(graph('/b', 'bbb'))
    local now = session.close('b') -- closing the active band
    eq('a', now, 'a survivor becomes active')
    ok(store.node('/a::aaa'), 'the survivor is live in the lens')
    eq(nil, session.bands.b, 'closed band is gone')
end)
