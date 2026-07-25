-- THE PERSISTED SELF-TYPE MAP (cache.save_selft / load_selft) — the carry-forward
-- artifact the calls half of index-and-reduce needs
-- ([[cartograph-merging-strategies]]).
--
-- The map is derived from RESOLVED CALLS, so a cold thin index cannot compute one —
-- persistence is the only way a demand open can have it, which makes these properties
-- load-bearing rather than conveniences:
--   · a STALE map must be refused. It names method ids and classes from one corpus
--     state; if a file moved, seeding it types against classes that may be gone, which
--     yields confident wrong receivers instead of an honest refusal — worse than none.
--   · a THIN save must not clobber it. A partial graph's own map is exactly the unsound
--     answer this artifact displaces, so it must never overwrite a whole-graph one.
--   · the GC must not sweep it. It is deliberately manifest-independent, so
--     "unreferenced" cannot mean "garbage" here.

local cache = require 'cartograph.cache'
local config = require 'cartograph.config'

local R = { start = { line = 1, char = 0 }, ['end'] = { line = 1, char = 3 } }

local function graph(root, extra)
    local g = {
        schema = 1, root = root, provider = 'test',
        stamps = { ['a.rb'] = 'sA' },
        nodes = {
            { id = 'a.rb', name = 'a.rb', kind = 'module', file = 'a.rb', order = -1, range = R },
        },
        edges = {}, calls = {}, names = {},
    }
    for k, v in pairs(extra or {}) do g[k] = v end
    return g
end

-- a map with BOTH shapes: a poisoned id (false) and a typed one (a class set)
local function map()
    return { ['a.rb::C#m@1'] = false, ['a.rb::C#n@2'] = { C = true },
        ['a.rb::D#p@3'] = { D = true, E = true } }
end

test('selft cache: round-trips poisoned and typed entries', function ()
    if config.cache == false then skip 'cache disabled' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local stamps = { ['a.rb'] = 'sA' }
    ok(cache.save_selft(root, map(), stamps), 'saved')
    local got = cache.load_selft(root, stamps)
    ok(got, 'loaded')
    eq(false, got['a.rb::C#m@1'])                 -- poisoned stays FALSE, not nil:
    ok(got['a.rb::C#m@1'] ~= nil, 'poisoned is present, distinct from absent')
    eq(true, got['a.rb::C#n@2'].C)
    ok(got['a.rb::D#p@3'].D and got['a.rb::D#p@3'].E, 'multi-class set restored')
    cache.wipe(root); vim.fn.delete(root, 'rf')
end)

test('selft cache: a map from a DIFFERENT corpus state is refused', function ()
    if config.cache == false then skip 'cache disabled' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    cache.save_selft(root, map(), { ['a.rb'] = 'sA' })
    -- same file, changed stamp = the content moved under the map
    eq(nil, cache.load_selft(root, { ['a.rb'] = 'sB' }))
    -- a file appearing also invalidates: new defs can poison what was clean
    eq(nil, cache.load_selft(root, { ['a.rb'] = 'sA', ['b.rb'] = 'sB' }))
    -- and a file disappearing
    eq(nil, cache.load_selft(root, {}))
    -- the unchanged set still loads, so the digest is not simply always-mismatching
    ok(cache.load_selft(root, { ['a.rb'] = 'sA' }), 'unchanged stamps still load')
    cache.wipe(root); vim.fn.delete(root, 'rf')
end)

test('selft cache: absent map reads as nil, never as an empty map', function ()
    if config.cache == false then skip 'cache disabled' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    -- nil is what makes the demand path take the WITHDRAWAL branch; an empty table
    -- would look like "nothing is poisoned anywhere", i.e. licence to self-type
    eq(nil, cache.load_selft(root, { ['a.rb'] = 'sA' }))
    vim.fn.delete(root, 'rf')
end)

test('selft cache: a THIN save leaves an existing whole-graph map intact', function ()
    if config.cache == false then skip 'cache disabled' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local stamps = { ['a.rb'] = 'sA' }
    cache.save_selft(root, map(), stamps)
    -- an index_only save must not overwrite it with its own (unsound) answer
    cache.save(graph(root, { index_only = true }), nil)
    local got = cache.load_selft(root, stamps)
    ok(got, 'the map survived a thin save')
    eq(false, got['a.rb::C#m@1'])
    cache.wipe(root); vim.fn.delete(root, 'rf')
end)

test('selft cache: the GC does not sweep it', function ()
    if config.cache == false then skip 'cache disabled' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local stamps = { ['a.rb'] = 'sA' }
    cache.save(graph(root), nil)              -- a manifest must exist for gc to run
    cache.save_selft(root, map(), stamps)
    cache.gc(root, { sync = true })           -- the map is manifest-UNREFERENCED
    ok(cache.load_selft(root, stamps), 'still there after a sync sweep')
    cache.wipe(root); vim.fn.delete(root, 'rf')
end)

test('selft cache: save is a no-op without a map or without stamps', function ()
    if config.cache == false then skip 'cache disabled' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    ok(not cache.save_selft(root, nil, { ['a.rb'] = 'sA' }), 'no map')
    ok(not cache.save_selft(root, {}, { ['a.rb'] = 'sA' }), 'empty map')
    ok(not cache.save_selft(root, map(), nil), 'no stamps')
    ok(not cache.save_selft(root, map(), {}), 'empty stamps')
    vim.fn.delete(root, 'rf')
end)
