-- CUTTING AN ANALYSIS TO A FRAME (CART-0514) — step 3 of the scope-boundary design.
--
-- The point of this cut is not a feature, it is an EXPERIMENT with three
-- assertions: that the browser's frame really is the scope (so constructing one is
-- a lookup, not a computation), that the illegal cell is unreachable rather than
-- discouraged, and that a finding can say which scope produced it. If any of the
-- three fails, the pipeline-stage boundary is not where the design claims.

local lint = require 'cartograph.lint'
local cut = require 'cartograph.cut'
local store = require 'cartograph.store'

local function has_parser(lang)
    return pcall(vim.treesitter.language.add, lang)
end

--- Two findings of a WITNESS rule (`truncation`: authoritative, purely syntactic,
--- so clip is legal) in two DIFFERENT functions -- which is what makes the cut
--- observable. `truncation` was chosen over `seam-guard` because seam-guard did
--- not fire on a synthetic fixture and a SKIPPED acceptance test proves nothing.
local function build()
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    write(root, 'm.lua', {
        'local function outer(x)',
        '    local a, b = compute(x) and fallback(x)',
        '    return a, b',
        'end',
        'local function other(y)',
        '    local c, d = compute(y) or fallback(y)',
        '    return c, d',
        'end',
        'return { outer = outer, other = other }',
    })
    local data = require('cartograph.providers.treesitter').extract(root)
    store.ingest(data)
    return root, data
end

local RULE = { truncation = true }

--- the fn node id for `outer` (line 0)
local function outer_id(data)
    for _, n in ipairs(data.nodes) do
        if n.kind == 'function' and n.name == 'outer' then return n.id end
    end
end

test('scope: a witness rule scoped to a frame returns the corpus answer, cut', function ()
    if not has_parser('lua') then skip 'no lua parser' end
    local root, data = build()
    local all = lint.run(store, { only = RULE })
    eq(2, #all, 'the corpus run sees BOTH truncations')
    -- cut at ONE of the two functions
    local sc = cut.of_node(store, outer_id(data))
    ok(sc, 'a frame at the fn altitude yields a scope')
    eq('fn', sc.grain, 'and it records the granularity it was cut at')
    local some = lint.run(store, { only = RULE, scope = sc })
    eq(1, #some, 'exactly the one inside the cut survives')
    eq(2, some[1].line, 'and it is the one in `outer`, not in `other`')
    -- EXACTLY the corpus answer filtered: no finding appears that a corpus run
    -- did not have, which is what "clip under-reports" means
    for _, f in ipairs(some) do
        local seen = false
        for _, g in ipairs(all) do
            if g.file == f.file and g.line == f.line and g.rule == f.rule then seen = true end
        end
        ok(seen, 'a scoped run invents nothing: ' .. tostring(f.message))
    end
    vim.fn.delete(root, 'rf')
end)

test('scope: a PROMISE rule is REFUSED for a scope, never clipped', function ()
    if not has_parser('lua') then skip 'no lua parser' end
    local root, data = build()
    local sc = cut.of_node(store, outer_id(data))
    -- dead-function asserts "no callers" — an absence, and the only caller could
    -- be outside the cut, so the scoped answer would be a lie the scope invented
    local f, refused = lint.run(store,
        { only = { ['dead-function'] = true }, scope = sc })
    eq(0, #f, 'a promise rule yields NO findings under a scope')
    eq(1, #refused, 'it is refused, and the refusal is reported')
    eq('dead-function', refused[1].rule)
    eq('promise', refused[1].quantifier)
    ok(refused[1].why:match('absence'), refused[1].why)
    -- and without a scope it is not refused at all
    local _, r2 = lint.run(store, { only = { ['dead-function'] = true } })
    eq(0, #r2, 'the corpus run refuses nothing')
    vim.fn.delete(root, 'rf')
end)

test('scope: a finding CARRIES the scope that produced it', function ()
    if not has_parser('lua') then skip 'no lua parser' end
    local root, data = build()
    local sc = cut.of_node(store, outer_id(data))
    local f = lint.run(store, { only = RULE, scope = sc })
    eq(1, #f)
    eq(sc.label, f[1].scope,
        'the INVERSION LAW: without this the same rule at two altitudes is'
        .. ' indistinguishable')
    local g = lint.run(store, { only = RULE })
    eq(nil, g[1].scope, 'and a corpus run claims no scope rather than a fake one')
    vim.fn.delete(root, 'rf')
end)

test('scope: of_frame reads the browser frame, and a ROOT altitude has no subject', function ()
    if not has_parser('lua') then skip 'no lua parser' end
    local root, data = build()
    -- the claim the whole design rests on: constructing a cut from where you are
    -- standing is a LOOKUP over the altitude registry, not a computation
    eq('file m.lua', cut.of_frame(store, 'file', 'm.lua').label)
    eq('fn', cut.of_frame(store, 'fn', outer_id(data)).grain)
    -- and a root altitude honestly has nothing to cut at: standing at the file
    -- tree, "here" IS everything
    eq(nil, cut.of_frame(store, 'files', 'anything'))
    eq(nil, cut.of_frame(store, 'ws', 'anything'))
    vim.fn.delete(root, 'rf')
end)

test('scope: contains normalises absolute and relative finding paths', function ()
    -- the rules are not consistent about it (dead-state calls store.abs, seam-guard
    -- does not), so normalising in ONE place beats asking 33 rules to agree
    store.ingest({ root = '/tmp/x', nodes = {}, edges = {}, calls = {} })
    local sc = { grain = 'fn', label = 'fn f', members = {},
        anchors = { { kind = 'text', doc = 'a.lua', sl = 4, el = 8 } } }
    ok(cut.contains(store, sc, 'a.lua', 6), 'relative, inside')
    ok(cut.contains(store, sc, '/tmp/x/a.lua', 6), 'absolute, inside')
    ok(not cut.contains(store, sc, 'a.lua', 4), 'above the span (1-based vs 0-based)')
    ok(not cut.contains(store, sc, 'b.lua', 6), 'another file')
    ok(cut.contains(store, nil, 'anything', 1), 'no scope contains everything')
end)

-- (the user, 2026-10-20: extents "too specific — won't survive outside files or buffers". A cut is its MEMBERS; a text
-- line range is one ANCHOR kind among those a provider may register, and membership is asked of a SUBJECT)
test('scope: a node with NO file is a member — kept, named unlocated, found by identity', function ()
    store.ingest({ root = '/tmp/x', nodes = {
        { id = 'bean:OrderService', kind = 'class', name = 'OrderService' },                    -- no file: a bean
        { id = 'a.lua::f@4', kind = 'function', name = 'f', file = 'a.lua', range = { start = { line = 4, char = 0 }, ['end'] = { line = 8, char = 3 } } },
    }, edges = {}, calls = {} })
    local sc = cut.of_nodes(store, { 'bean:OrderService', 'a.lua::f@4' })
    ok(sc, 'a set holding a file-less node is still a cut (it was nil, or the node was silently dropped)')
    eq(2, #sc.members, 'both members kept')
    eq('bean:OrderService', sc.unlocated[1], 'the file-less one is NAMED, not lost')
    ok(cut.has(store, sc, 'bean:OrderService'), 'and found by identity')
    ok(cut.contains(store, sc, 'a.lua', 6), 'the text member still locates a finding by file and line')
    eq('a.lua', cut.docs(sc)[1], 'the documents a pass may walk are the text anchors\' only')
    eq(1, #cut.docs(sc))
end)

test('scope: a node subject lies in a file cut through its anchor; another kind of anchor can be registered', function ()
    store.ingest({ root = '/tmp/x', nodes = {
        { id = 'a.lua::f@4', kind = 'function', name = 'f', file = 'a.lua', range = { start = { line = 4, char = 0 }, ['end'] = { line = 8, char = 3 } } },
        { id = 'svc:prod/api', kind = 'service', name = 'api', path = 'prod/api' },
        { id = 'svc:prod/api/db', kind = 'service', name = 'db', path = 'prod/api/db' },
    }, edges = {}, calls = {} })
    ok(cut.has(store, cut.of_file(store, 'a.lua'), 'a.lua::f@4'), 'a function inside a file cut: through its text anchor')
    ok(not cut.has(store, cut.of_file(store, 'b.lua'), 'a.lua::f@4'), 'not inside another file\'s')
    -- a provider's own anchor kind: a resource path, covered by its prefixes
    cut.ANCHORS.path = {
        of = function (_, n) return n.path and { { kind = 'path', path = n.path } } or {} end,
        covers = function (_, a, s) return s.path == a.path or s.path:sub(1, #a.path + 1) == a.path .. '/' end,
    }
    local sc = cut.of_node(store, 'svc:prod/api')
    eq(0, #sc.unlocated, 'the service is located by its own kind')
    ok(cut.has(store, sc, 'svc:prod/api/db'), 'a node under it is inside, by the path kind')
    ok(cut.has(store, sc, { kind = 'path', path = 'prod/api/db/conn' }), 'and so is an anchor subject')
    ok(not cut.has(store, sc, { kind = 'path', path = 'prod/web' }), 'a sibling path is not')
    cut.ANCHORS.path = nil
end)
