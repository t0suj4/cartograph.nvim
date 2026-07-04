-- Unit tests for the store: edge indexing and the file-usage classifier
-- (used / value / sideeffect / deadimport / orphan). Pure logic over an
-- in-memory graph via store.ingest — no files, no server.

local store = require 'cartograph.store'

local R0 = { start = { line = 0, char = 0 }, ['end'] = { line = 0, char = 0 } }

local function mod(file, effects)
    return { id = file, name = file, kind = 'module', file = file, range = R0, order = 0, effects = effects }
end
local function fn(file, name, order)
    return { id = file .. '::' .. name, name = name, kind = 'function', file = file, range = R0, order = order or 0 }
end
local function ref(from, to, at)
    return { from = from, to = to, kind = 'ref', at = at or {} }
end
local function import(from, to, sideeffect)
    return { from = from, to = to, kind = 'import', sideeffect = sideeffect }
end
local function graph(nodes, edges)
    store.ingest({ schema = 1, root = '/x', nodes = nodes, edges = edges or {} })
end

-- ── classify decision table ─────────────────────────────────────────────────

test('classify: orphan when nothing imports or references it', function ()
    graph({ mod('a.lua', false), fn('a.lua', 'f') })
    eq('orphan', store.classify('a.lua'))
end)

test('classify: entry when unimported but a configured entry point', function ()
    graph({ mod('control.lua', false), fn('control.lua', 'f'),
            mod('scen/control.lua', false), fn('scen/control.lua', 'g') })
    eq('entry', store.classify('control.lua'))
    eq('entry', store.classify('scen/control.lua')) -- pattern matches the basename
end)

test('classify: an imported entry point is just a normal module', function ()
    graph({ mod('control.lua', false), fn('control.lua', 'f'), mod('b.lua', false) },
          { import('b.lua', 'control.lua', false) })
    eq('value', store.classify('control.lua'))
end)

test('classify: used when a symbol is referenced', function ()
    graph({ mod('a.lua', false), fn('a.lua', 'f'), mod('b.lua', false), fn('b.lua', 'g') },
          { ref('b.lua::g', 'a.lua::f') })
    eq('used', store.classify('a.lua'))
end)

test('classify: value when imported and result is bound', function ()
    graph({ mod('a.lua', false), fn('a.lua', 'f') },
          { import('b.lua', 'a.lua', false) })
    eq('value', store.classify('a.lua'))
end)

test('classify: sideeffect for discarded require of an effectful module', function ()
    graph({ mod('a.lua', true), fn('a.lua', 'f') },
          { import('b.lua', 'a.lua', true) })
    eq('sideeffect', store.classify('a.lua'))
end)

test('classify: deadimport for discarded require of a pure module', function ()
    graph({ mod('a.lua', false), fn('a.lua', 'f') },
          { import('b.lua', 'a.lua', true) })
    eq('deadimport', store.classify('a.lua'))
end)

test('classify: a referenced symbol beats a side-effect import', function ()
    graph({ mod('a.lua', true), fn('a.lua', 'f'), mod('c.lua', false), fn('c.lua', 'h') },
          { import('b.lua', 'a.lua', true), ref('c.lua::h', 'a.lua::f') })
    eq('used', store.classify('a.lua'))
end)

test('classify: any value import wins over a side-effect import', function ()
    graph({ mod('a.lua', true), fn('a.lua', 'f') },
          { import('b.lua', 'a.lua', true), import('c.lua', 'a.lua', false) })
    eq('value', store.classify('a.lua'))
end)

test('classify: a nil effects flag is treated as pure (deadimport)', function ()
    graph({ mod('a.lua', nil), fn('a.lua', 'f') },
          { import('b.lua', 'a.lua', true) })
    eq('deadimport', store.classify('a.lua'))
end)

-- ── edge indexing ────────────────────────────────────────────────────────────

test('uses / usedby indexes are built from ref edges', function ()
    graph({ mod('a.lua', false), fn('a.lua', 'f'), fn('a.lua', 'g') },
          { ref('a.lua::f', 'a.lua::g') })
    eq({ 'a.lua::g' }, store.uses['a.lua::f'])
    eq({ 'a.lua::f' }, store.usedby['a.lua::g'])
end)

test('occurrences() returns the recorded reference sites', function ()
    local at = { { start = { line = 5, char = 2 }, ['end'] = { line = 5, char = 8 } } }
    graph({ mod('a.lua', false), fn('a.lua', 'f'), fn('a.lua', 'g') },
          { ref('a.lua::f', 'a.lua::g', at) })
    eq(at, store.occurrences('a.lua::f', 'a.lua::g'))
end)

test('by_file excludes module nodes and sorts by source order', function ()
    graph({ mod('a.lua', false), fn('a.lua', 'second', 2), fn('a.lua', 'first', 1) })
    local names = {}
    for _, n in ipairs(store.by_file['a.lua']) do names[#names + 1] = n.name end
    eq({ 'first', 'second' }, names)
end)

test('import edges without an explicit sideeffect flag default to value', function ()
    -- an import edge missing `sideeffect` (older dump) must not read as side-effect
    graph({ mod('a.lua', false), fn('a.lua', 'f') },
          { { from = 'b.lua', to = 'a.lua', kind = 'import' } })
    eq('value', store.classify('a.lua'))
end)

test('ingest invalidates the live sample and any stale move-set', function ()
    graph({ mod('a.lua', false), fn('a.lua', 'f') })
    store.live = { states = { inactive = 1 }, tick = 42 }
    store.stage('a.lua::f')
    local gen = store.generation
    graph({ mod('b.lua', false), fn('b.lua', 'g') })
    ok(store.live == nil, 'live sample cleared')
    eq(0, #store.staged_ids())
    -- the reentrancy contract's witness: every ingest bumps the generation
    eq(gen + 1, store.generation)
end)

test('back()/forward() skip history entries whose node is gone', function ()
    graph({ mod('a.lua', false), fn('a.lua', 'f'), fn('a.lua', 'g'), fn('a.lua', 'h') })
    store.set_focus('a.lua::f')
    store.pivot('a.lua::g')  -- pushes f
    store.pivot('a.lua::h')  -- pushes g
    -- g vanishes (as after a refresh that could not remap it)
    store.by_id['a.lua::g'] = nil
    store.back()
    eq('a.lua::f', store.focused) -- skipped the dead g entry
    -- and nothing left below f
    store.back()
    eq('a.lua::f', store.focused)
end)

test('working set: toggle, order, persistence, honest pending', function ()
    graph({ mod('a.lua', false), fn('a.lua', 'f', 5), fn('a.lua', 'g', 1),
            mod('b.lua', false), fn('b.lua', 'h', 3) })
    vim.fn.delete(store.ws_file('/x'))
    store.ws_load()
    eq(true, store.ws_toggle('a.lua::f'))
    eq(true, store.ws_toggle('b.lua::h'))
    ok(store.ws_has('a.lua::f') and store.ws_has('b.lua::h'))
    -- ordered by (file, source order)
    local names = {}
    for _, n in ipairs(store.ws_list()) do names[#names + 1] = n.id end
    eq({ 'a.lua::f', 'b.lua::h' }, names)
    -- toggle off removes the ref too
    eq(false, store.ws_toggle('b.lua::h') == true)
    eq(1, #store.workset.refs)

    -- persistence: a fresh graph re-resolves by REF, not id
    graph({ mod('a.lua', false), fn('a.lua', 'f', 5), fn('a.lua', 'g', 1) })
    store.ws_load()
    ok(store.ws_has('a.lua::f'), 'membership survived the reload')
    -- a member whose symbol vanished waits as pending, visibly
    graph({ mod('a.lua', false), fn('a.lua', 'g', 1) })
    local notes = store.ws_load()
    ok(not store.ws_has('a.lua::f'))
    eq(1, #store.workset.pending)
    ok(notes[1]:match('missing'), notes[1] or '?')
    -- and returns when the symbol does
    graph({ mod('a.lua', false), fn('a.lua', 'f', 5) })
    store.ws_resolve()
    ok(store.ws_has('a.lua::f'), 'pending member resolved on return')
    vim.fn.delete(store.ws_file('/x'))
    store.workset = { ids = {}, refs = {}, pending = {} }
end)
