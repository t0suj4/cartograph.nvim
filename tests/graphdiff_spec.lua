-- Structural graph diff: per-item comparison two count-parity totals can't
-- fake — attr flips and resolution changes surface as `changed`, and the
-- report never silently truncates.

local gd = require 'cartograph.graphdiff'

local function data(nodes, edges, calls)
    return { schema = 1, root = '/x', nodes = nodes or {}, edges = edges or {},
        calls = calls or {} }
end
local function n(id) return { id = id, name = id, kind = 'function', file = 'm.lua' } end

test('graphdiff: identical graphs are empty', function ()
    local a = data({ n 'f' }, { { from = 'f', to = 'g', kind = 'ref' } },
        { { file = 'm.lua', line = 3, callee = 'g', to = 'g' } })
    local d = gd.diff(a, a)
    ok(gd.empty(d), 'no differences')
    eq('graphs are identical (per-item)', gd.report(d)[1])
end)

test('graphdiff: count parity does NOT fool it', function ()
    -- same totals (1 edge each), different edges — the exact failure mode
    -- a total-count gate waves through
    local a = data({}, { { from = 'f', to = 'g', kind = 'ref' } })
    local b = data({}, { { from = 'f', to = 'h', kind = 'ref' } })
    local d = gd.diff(a, b)
    ok(not gd.empty(d), 'caught')
    eq(1, #d.edges.added)
    eq(1, #d.edges.removed)
    ok(d.edges.added[1]:find('f %-> h'), d.edges.added[1])
    ok(d.edges.removed[1]:find('f %-> g'), d.edges.removed[1])
end)

test('graphdiff: an attr flip is CHANGED, not add+remove', function ()
    local a = data({}, { { from = 'f', to = 'g', kind = 'ref', inferred = true } })
    local b = data({}, { { from = 'f', to = 'g', kind = 'ref', proven = true } })
    local d = gd.diff(a, b)
    eq(0, #d.edges.added)
    eq(0, #d.edges.removed)
    eq(1, #d.edges.changed)
    -- the two SIDES, not one exact substring: the signature grew a write-axis
    -- term (CART-0532), so `~ => proven` became `~ w- => proven w-`. What this
    -- test is about is that a trust flip lands in `changed` rather than
    -- add+remove, and that both tiers are named — matching the whole rendering
    -- would make every future signature term look like a regression here.
    local before, after = d.edges.changed[1]:match('(.*) => (.*)$')
    ok(before and before:find('~', 1, true), tostring(d.edges.changed[1]))
    ok(after and after:find('proven', 1, true), tostring(d.edges.changed[1]))
end)

test('graphdiff: duplicate pairs are counted, not set-membered', function ()
    local e = { from = 'f', to = 'g', kind = 'ref' }
    local a = data({}, { e, e }) -- two call sites, same pair
    local b = data({}, { e })
    local d = gd.diff(a, b)
    eq(1, #d.edges.changed) -- 2x matched -> 1x matched
    ok(d.edges.changed[1]:find('2x matched'), d.edges.changed[1])
end)

test('graphdiff: a call resolution change surfaces by site', function ()
    local a = data({}, {}, { { file = 'm.lua', line = 3, callee = 'g',
        refused = { rule = 'ambiguous' } } })
    local b = data({}, {}, { { file = 'm.lua', line = 3, callee = 'g', to = 'g' } })
    local d = gd.diff(a, b)
    eq(1, #d.calls.changed)
    ok(d.calls.changed[1]:find('m.lua:4 g'), d.calls.changed[1])
    ok(d.calls.changed[1]:find('refused %(ambiguous%) => to g'), d.calls.changed[1])
end)

test('graphdiff: node add/remove; report caps count what they cut', function ()
    local a = data({ n 'f' })
    local b = data({ n 'g', n 'h', n 'i' })
    local d = gd.diff(a, b)
    eq(3, #d.nodes.added)
    eq(1, #d.nodes.removed)
    local rep = gd.report(d, { limit = 2 })
    local joined = table.concat(rep, '\n')
    ok(joined:find('nodes added %(3%)'), joined)
    ok(joined:find('… 1 more'), 'the cut is counted')
end)

-- ── WITNESS ROWS (CART-0626) ────────────────────────────────────────────────
-- A gate that can say FAIL owes one row a reader can check. These test the four
-- things that make a row checkable rather than merely present: both sides are
-- named, a source location is offered, ABSENT never renders as a value, and the
-- structure is not paid for unless a caller asked for it.

test('witness: the memory guard — no samples unless opts.witness', function ()
    local a = data({}, { { from = 'm.lua', to = 'u.lua::abs@4', kind = 'ref', nat = 2 } })
    local b = data({}, { { from = 'm.lua', to = 'u.lua::abs@4', kind = 'ref', nat = 9 } })
    local plain = gd.diff(a, b)
    eq(nil, plain.witness, 'structure is NOT kept by default')
    eq(1, #plain.edges.changed, 'the ordinary diff is unaffected')
    -- and asking for a witness off a plain diff REFUSES with the reason rather
    -- than printing an empty section, which would read as "nothing to see"
    local said = gd.witness(plain)
    eq(1, #said)
    ok(said[1]:find('NO WITNESS ROWS'), said[1])
    ok(said[1]:find('refusal, not an empty result'), said[1])
    ok(gd.diff(a, b, { witness = true }).witness ~= nil, 'kept when asked')
end)

test('witness: an occurrence change names both sides and what to count', function ()
    local a = data({}, { { from = 'm.lua', to = 'u.lua::abs@4', kind = 'ref', nat = 14 } })
    local b = data({}, { { from = 'm.lua', to = 'u.lua::abs@4', kind = 'ref', nat = 1 } })
    local d = gd.diff(a, b, { witness = true })
    local rows = table.concat(gd.witness(d, { a = 'sequential', b = 'parallel' }), '\n')
    ok(rows:find('sequential:'), rows)
    ok(rows:find('parallel:'), rows)
    ok(rows:find('14 occurrence'), rows)
    ok(rows:find('1 occurrence'), rows)
    -- the location to open, and the ACTION -- a row that says only "these differ"
    -- is the delta row this replaces
    ok(rows:find('m%.lua'), rows)
    ok(rows:find('COUNT the places `abs` is called'), rows)
    -- a single-record pair gets no total line: the sampled numbers ARE the total
    ok(not rows:find('record%(s%) per side'), rows)
end)

test('witness: an ABSENT write class never renders as a value', function ()
    -- w- is "no classifier ran", which is NOT "not a write" -- nil-is-not-zero,
    -- the rule this file already lives by, carried into English
    local a = data({}, { { from = 'm.lua', to = 'u.lua::abs@4', kind = 'ref', nat = 1 } })
    local b = data({}, { { from = 'm.lua', to = 'u.lua::abs@4', kind = 'ref', nat = 1,
        rw = 'w' } })
    local d = gd.diff(a, b, { witness = true })
    local rows = table.concat(gd.witness(d), '\n')
    ok(rows:find('write%-class ABSENT'), rows)
    ok(rows:find('no classifier ran'), rows)
    ok(rows:find('write%-class w'), rows)
    ok(rows:find('CHECK %(write%-axis%)'), rows)
end)

test('witness: a call site is already a location, and says which side source settles', function ()
    local a = data({}, {}, { { file = 'm.lua', line = 6, callee = 'g', to = 'a.lua::g@1' } })
    local b = data({}, {}, { { file = 'm.lua', line = 6, callee = 'g',
        refused = { rule = 'ambiguous-name' } } })
    local d = gd.diff(a, b, { witness = true })
    local rows = table.concat(gd.witness(d, { a = 'baseline', b = 'current',
        decides = 'b' }), '\n')
    ok(rows:find('m%.lua:7 g'), rows)          -- ckey is 1-based on line+1
    ok(rows:find('to a%.lua::g@1'), rows)
    ok(rows:find('refused %(ambiguous%-name%)'), rows)
    ok(rows:find('open that line'), rows)
    -- a baseline describes a tree that is gone, so it cannot be re-checked
    ok(rows:find('settles current only'), rows)
end)

test('witness: the report half is untouched by all of it', function ()
    local a = data({}, { { from = 'f', to = 'g', kind = 'ref', inferred = true } })
    local b = data({}, { { from = 'f', to = 'g', kind = 'ref', proven = true } })
    eq(gd.report(gd.diff(a, b)), gd.report(gd.diff(a, b, { witness = true })))
end)

test('witness: what an occurrence IS depends on the edge kind', function ()
    -- a `reg` edge is a mention from DATA. Telling a reader to "count the
    -- references" makes them count calls too, and on grocy that reads as six
    -- against a correct two.
    local a = data({}, { { from = 'm.js', to = 'm.js::f@50', kind = 'reg', nat = 2 } })
    local b = data({}, { { from = 'm.js', to = 'm.js::f@50', kind = 'reg', nat = 1 } })
    local rows = table.concat(gd.witness(gd.diff(a, b, { witness = true })), '\n')
    ok(rows:find('AS A VALUE'), rows)
    ok(rows:find('NOT called'), rows)
    ok(not rows:find('called, or referenced from code'), rows)
end)

test('witness: a multi-record pair says which number the count answers', function ()
    -- two edge records for one (from,to,kind): the source count settles the
    -- sampled record, NOT the sum, and a row that printed only the sum would
    -- send the reader to compare against a number nothing in the file matches
    local a = data({}, {
        { from = 'm.js', to = 'm.js::f@50', kind = 'reg', nat = 2 },
        { from = 'm.js', to = 'm.js::f@50', kind = 'reg', nat = 2 } })
    local b = data({}, {
        { from = 'm.js', to = 'm.js::f@50', kind = 'reg', nat = 1 },
        { from = 'm.js', to = 'm.js::f@50', kind = 'reg', nat = 2 } })
    local rows = table.concat(gd.witness(gd.diff(a, b, { witness = true })), '\n')
    ok(rows:find('2 record%(s%) per side'), rows)
    ok(rows:find('totals A 4 · B 3'), rows)
    ok(rows:find('settles the SAMPLED RECORD'), rows)
end)

test('witness: an edge only one side has says which way the bug points', function ()
    -- the soundness-shaped half. A `changed` row can never be a minting bug; this
    -- one can only be, so the row must name BOTH readings and let the file decide
    local a = data({}, {})
    local b = data({}, { { from = 'm.js', to = 'u.js::f@9', kind = 'reg', nat = 1 } })
    local rows = table.concat(gd.witness(gd.diff(a, b, { witness = true }),
        { a = 'sequential', b = 'parallel' }), '\n')
    ok(rows:find('EDGE ADDED only in parallel'), rows)
    ok(rows:find('is `f` mentioned as a value %(not called%) there at all%?'), rows)
    ok(rows:find('yes → sequential dropped it%. no → parallel invented it%.'), rows)
end)

test('witness: a definition only one side has is checkable at its own line', function ()
    -- a node id already carries file, name and line, so this row needs no
    -- samples and no vocabulary: is it defined at that line, yes or no
    local a = data({ { id = 'm.lua::helper@42', name = 'helper', kind = 'function' } })
    local b = data({})
    local rows = table.concat(gd.witness(gd.diff(a, b, { witness = true }),
        { a = 'baseline', b = 'current' }), '\n')
    ok(rows:find('DEFINITION REMOVED only in baseline'), rows)
    -- 43, not 42: the id's line is 0-based and the reader's editor is not
    ok(rows:find('open m%.lua:43'), rows)
    ok(not rows:find('open m%.lua:42'), rows)
    ok(rows:find('definition of `helper` there'), rows)
    ok(rows:find('yes → current dropped it%. no → baseline invented it%.'), rows)
end)

test('witness: a target with no ::name still names something openable', function ()
    -- a module node, an import edge and a var edge all have ids with no `name`
    -- part. The first real diff rendered all three as "is `?` … there at all?",
    -- which is the one question a reader cannot answer.
    local a = data({ { id = 'nio/control.lua', name = 'control', kind = 'module' } },
        { { from = 'nio/control.lua', to = 'nio/tasks.lua', kind = 'import' } })
    local b = data({}, {})
    local rows = table.concat(gd.witness(gd.diff(a, b, { witness = true }),
        { a = 'full', b = 'trimmed' }), '\n')
    ok(rows:find('%(the module itself%)'), rows)
    ok(rows:find('does nio/control%.lua exist and parse%?'), rows)
    ok(rows:find('is `nio/tasks%.lua` imported there at all%?'), rows)
    ok(not rows:find('`%?`'), rows)
end)
