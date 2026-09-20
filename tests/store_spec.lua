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
    -- entry points are project config (defaults are generic mains only)
    local cfg = require 'cartograph.config'
    local saved = cfg.entrypoints
    cfg.entrypoints = { 'control%.lua$' }
    graph({ mod('control.lua', false), fn('control.lua', 'f'),
            mod('scen/control.lua', false), fn('scen/control.lua', 'g') })
    eq('entry', store.classify('control.lua'))
    eq('entry', store.classify('scen/control.lua')) -- pattern matches the basename
    cfg.entrypoints = saved
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

test('index orientation: closest route and return path', function ()
    graph({ mod('m.lua', false), fn('m.lua', 'a'), fn('m.lua', 'b'),
            fn('m.lua', 'c') },
          { ref('m.lua::a', 'm.lua::b'), ref('m.lua::b', 'm.lua::c') })
    vim.fn.delete(store.ws_file('/x'))
    store.ws_load()
    -- mark c: from a the route descends a -> b -> c
    store.ws_toggle('m.lua::c')
    local r = store.ws_route('m.lua::a')
    eq(2, r.dist)
    eq({ '→b', '→c' }, { r.path[1].dir .. r.path[1].name,
        r.path[2].dir .. r.path[2].name })
    -- mark a instead: from c the route climbs the callers
    store.ws_toggle('m.lua::c')
    store.ws_toggle('m.lua::a')
    r = store.ws_route('m.lua::c')
    eq(2, r.dist)
    eq('↖b', r.path[1].dir .. r.path[1].name)
    eq('↖a', r.path[2].dir .. r.path[2].name)
    -- the member itself: dist 0
    eq(0, store.ws_route('m.lua::a').dist)
    -- return path: dive a -> b -> c, then ask the way back
    store.set_focus('m.lua::a')
    store.pivot('m.lua::b')
    store.pivot('m.lua::c')
    local back = store.ws_back()
    eq('a', back.name)
    eq(2, back.steps)
    vim.fn.delete(store.ws_file('/x'))
    store.workset = { ids = {}, refs = {}, pending = {} }
end)

-- ── store.enclosing: the lexical parent, position-aware (CART-0975) ─────────
-- Three analyses gave the right answer for a blind reason because nothing could ask
-- "whose scope is this in?" after extraction. `clones.local_deps` reads ONE function's
-- locals, scope.lua dies with the parse tree, store.scopes() is a namespace axis, and
-- agent.v_node_at computes a containment chain and keeps it nowhere.
local function rng(sl, sc, el, ec)
    return { start = { line = sl, char = sc }, ['end'] = { line = el, char = ec } }
end
local function fnr(file, name, r)
    return { id = file .. '::' .. name, name = name, kind = 'function',
        file = file, range = r, order = 0 }
end

test('store.enclosing: the innermost containing definition, nil at file scope', function ()
    graph({ mod('a.lua', false),
        fnr('a.lua', 'outer', rng(0, 0, 20, 3)),
        fnr('a.lua', 'middle', rng(4, 4, 14, 7)),
        fnr('a.lua', 'inner', rng(6, 8, 9, 11)),
        fnr('a.lua', 'sibling', rng(24, 0, 30, 3)) })
    eq('a.lua::middle', store.enclosing('a.lua::inner').id)
    eq('a.lua::outer', store.enclosing('a.lua::middle').id)
    eq(nil, store.enclosing('a.lua::outer'), 'a file-scope definition has no parent')
    eq(nil, store.enclosing('a.lua::sibling'), 'and neither does one beside it')
end)

test('store.enclosing: never returns the MODULE, so nil means file scope', function ()
    -- the module spans the whole file; if it were eligible, every node would be
    -- enclosed and "top level" would be unsayable. `by_file` excludes it by
    -- construction and this pins that.
    graph({ mod('b.lua', false), fnr('b.lua', 'top', rng(0, 0, 9, 3)) })
    eq(nil, store.enclosing('b.lua::top'))
end)

-- ⚠ POSITION-AWARE, NOT LINE-GRANULAR — the bug CART-0813 fixed on the owner query.
-- A callback that OPENS on its parent's line is contained by that line range, so a
-- line-only test cannot order the two and may pick either.
test('store.enclosing: a callback opening on its parent\'s LINE is still inside it', function ()
    graph({ mod('c.lua', false),
        -- `function outer() cb(function () ... end) end` — both start on line 0
        fnr('c.lua', 'outer', rng(0, 0, 5, 3)),
        fnr('c.lua', 'cb', rng(0, 24, 3, 7)) })
    eq('c.lua::outer', store.enclosing('c.lua::cb').id,
        'the callback resolves to the function it opens inside')
    eq(nil, store.enclosing('c.lua::outer'),
        'and the parent is NOT swallowed by its own child')
end)

test('store.enclosing: a definition ENDING on its parent\'s line is still inside it', function ()
    -- the symmetric half. fn_at compares the start side only and says its end side has
    -- never been observed to need a column; a CONTAINMENT query has no reason to pick.
    graph({ mod('d.lua', false),
        fnr('d.lua', 'outer', rng(0, 0, 4, 40)),
        fnr('d.lua', 'tail', rng(2, 2, 4, 12)) })
    eq('d.lua::outer', store.enclosing('d.lua::tail').id)
end)

test('store.enclosing: ONE-LINE parent and child — line-only would swallow the parent', function ()
    -- ⚠ THE DISCRIMINATING CASE, and the earlier two are not it: both of those give the
    -- same answer with or without columns, which revert-and-rerun proved by neutralising
    -- the column test and costing ZERO failures. The shape that separates them is two
    -- definitions on the SAME line — `function outer() cb(function () return 1 end) end`.
    -- Compared by line alone each one contains the other, so `enclosing` may return the
    -- CHILD as the parent's parent. With columns, only one containment holds.
    graph({ mod('e.lua', false),
        fnr('e.lua', 'one_outer', rng(0, 0, 0, 52)),
        fnr('e.lua', 'one_cb', rng(0, 20, 0, 44)) })
    eq('e.lua::one_outer', store.enclosing('e.lua::one_cb').id,
        'the callback is inside the function it sits in')
    eq(nil, store.enclosing('e.lua::one_outer'),
        'and the function is NOT reported as living inside its own callback')
end)
