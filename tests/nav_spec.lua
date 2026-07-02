-- Navigation: focus history (vim-jumplist semantics over pivots) and the
-- source pane's <C-]> jump resolution.

local store  = require 'cartograph.store'
local source = require 'cartograph.panes.source'

local function node(id, name, file, l1, l2)
    return { id = id, name = name, kind = 'function', file = file or 'm.lua',
        range = { start = { line = l1 or 0, char = 0 }, ['end'] = { line = l2 or 0, char = 0 } },
        order = 0 }
end

local function graph(nodes, edges)
    store.ingest({ schema = 1, root = '/x', nodes = nodes, edges = edges or {} })
end

-- ── focus history ───────────────────────────────────────────────────────────

test('nav: pivot records, back returns, forward re-returns', function ()
    graph({ node('a', 'a'), node('b', 'b'), node('c', 'c') })
    store.set_focus('a')
    store.pivot('b')
    store.pivot('c')
    store.back();    eq('b', store.focused)
    store.back();    eq('a', store.focused)
    store.forward(); eq('b', store.focused)
end)

test('nav: back on empty history is a no-op', function ()
    graph({ node('a', 'a') })
    store.set_focus('a')
    store.back()
    eq('a', store.focused)
end)

test('nav: a pivot after going back clears the forward stack', function ()
    graph({ node('a', 'a'), node('b', 'b'), node('c', 'c') })
    store.set_focus('a')
    store.pivot('b')
    store.back()
    store.pivot('c')
    store.forward()
    eq('c', store.focused) -- nothing forward of c
end)

test('nav: scrolling (plain set_focus) between pivots does not record', function ()
    graph({ node('a', 'a'), node('b', 'b'), node('c', 'c'), node('d', 'd') })
    store.set_focus('a')
    store.pivot('b')
    store.set_focus('c')  -- scrolled here; no history entry
    store.pivot('d')
    store.back(); eq('c', store.focused) -- back = where the last pivot happened
    store.back(); eq('a', store.focused)
end)

test('nav: history restores the browser location, not just the focus', function ()
    graph({ node('a', 'a'), node('b', 'b') })
    local restored
    store.loc_provider = {
        get = function () return { level = 'fn', fn = store.focused } end,
        set = function (loc) restored = loc end,
    }
    store.set_focus('a')
    store.pivot('b')       -- snapshots {level='fn', fn='a'}
    store.back()
    eq('a', store.focused)
    eq('fn', restored.level)
    eq('a', restored.fn)
    store.loc_provider = nil
end)

test('nav: ingest resets the history', function ()
    graph({ node('a', 'a'), node('b', 'b') })
    store.set_focus('a')
    store.pivot('b')
    graph({ node('a', 'a'), node('b', 'b') })
    store.back()
    eq('b', store.focused) -- unchanged: nothing to go back to
end)

-- ── <C-]> jump resolution ───────────────────────────────────────────────────

local function occ(l, c1, c2)
    return { start = { line = l, char = c1 }, ['end'] = { line = l, char = c2 } }
end

test('jump: an occurrence range under the cursor wins', function ()
    graph({ node('f', 'f', 'm.lua', 10, 20), node('g', 'M.helper'), node('h', 'other') },
        { { from = 'f', to = 'g', kind = 'ref', at = { occ(12, 4, 10) } },
          { from = 'f', to = 'h', kind = 'ref', at = { occ(15, 0, 5) } } })
    eq('g', source.resolve_jump(store.node('f'), 12, 6, ''))
    eq(nil, source.resolve_jump(store.node('f'), 12, 10, '')) -- past the range end
end)

test('jump: falls back to the cursor word (last path segment)', function ()
    graph({ node('f', 'f', 'm.lua', 10, 20), node('g', 'M.helper') },
        { { from = 'f', to = 'g', kind = 'ref', at = { occ(12, 4, 10) } } })
    eq('g', source.resolve_jump(store.node('f'), 13, 0, 'helper'))
end)

test('jump: an ambiguous word resolves to nothing', function ()
    graph({ node('f', 'f', 'm.lua', 10, 20), node('g', 'M.helper'), node('g2', 'x.helper') },
        { { from = 'f', to = 'g',  kind = 'ref' },
          { from = 'f', to = 'g2', kind = 'ref' } })
    eq(nil, source.resolve_jump(store.node('f'), 13, 0, 'helper'))
end)

test('jump: no uses edges -> nil', function ()
    graph({ node('f', 'f') })
    eq(nil, source.resolve_jump(store.node('f'), 0, 0, 'anything'))
end)
