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

test('session: back crosses bands after the local history is exhausted (S2)', function ()
    session.reset()
    -- band A: focus a1, pivot to a2 (a within-band history entry)
    session.begin('/a'); store.ingest(graph('/a', 'a2'))
    store.data.nodes[#store.data.nodes + 1] = { id = '/a::a1', name = 'a1',
        kind = 'function', file = 'm.lua', range = R, order = 1 }
    store.by_id['/a::a1'] = store.data.nodes[#store.data.nodes]
    store.set_focus('/a::a1'); store.pivot('/a::a2')
    eq('/a::a2', store.focused)
    -- cross to band B (records the crossing at a2)
    store.record_crossing(); session.begin('/b'); store.ingest(graph('/b', 'b1'))
    store.set_focus('/b::b1')
    eq('b', session.active)
    -- back in B: B has no within-band history -> cross back to A at a2
    store.back()
    eq('a', session.active, 'crossed back into band A')
    eq('/a::a2', store.focused, 'restored to where we left A')
    -- back again: A's own history (a2 <- a1)
    store.back()
    eq('/a::a1', store.focused, 'then walks A\'s within-band history')
end)

test('nav: single-band back is unchanged — no crossings, empty is a no-op', function ()
    session.reset()
    store.ingest(graph('/solo', 'x'))
    store.set_focus('/solo::x')
    store.back() -- no history, no crossings
    eq('/solo::x', store.focused)
    eq(0, #session.crossings)
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
