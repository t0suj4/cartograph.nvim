-- Feedback about CARTOGRAPH, anchored to a node. The rules under test are the
-- ones that make a filed report usable weeks later by someone who is not you:
-- the entry FREEZES its evidence instead of re-anchoring, a field the capture
-- could not determine says UNAVAILABLE instead of vanishing (a missing key reads
-- as an answer), and a subject that is a HOLE is still filed — an empty
-- compartment is the most useful complaint there is, and a capture that demands
-- a node would reject exactly those.

local fb = require 'cartograph.feedback'

local SCRATCH = '/tmp/claude-1000/-home-t0suj4-tools-nvim/feedback-spec'
local ROOT = SCRATCH .. '/root'

local function cleanup()
    vim.fn.delete(fb.dir(ROOT), 'rf')
end

local function stub_store(over)
    local s = {
        data = { root = ROOT, profile = 'lua-factorio', packs = { rails = true } },
        is_index_only = function () return false end,
        node = function () return nil end,
    }
    for k, v in pairs(over or {}) do s[k] = v end
    return s
end

-- ── the entry: the honesty rules ─────────────────────────────────────────────

test('entry: an empty expectation is REFUSED — a bookmark is not a report', function ()
    eq(nil, (fb.entry {}))
    local _, why = fb.entry { expected = '   \n  ' }
    eq('no expectation given', why)
end)

test('entry: every schema field is PRESENT, UNAVAILABLE where undetermined', function ()
    local e = fb.entry { expected = 'I expected the callers here' }
    for _, f in ipairs(fb.FIELDS) do
        -- the point: never absent. An omitted key reads as "no hedge"/"no empty"
        assert(e[f] ~= nil, 'field vanished from the entry: ' .. f)
    end
    eq('I expected the callers here', e.expected)
    eq(fb.UNAVAILABLE, e.gesture)
    eq(fb.UNAVAILABLE, e.subject)
    eq(fb.UNAVAILABLE, e.why)
end)

test('entry: an EMPTY table is UNAVAILABLE, not "empty"', function ()
    -- a browser buffer is never zero lines (a blank pane is `{ "" }`), so
    -- nothing to read means the read failed, which is a different fact
    local e = fb.entry { expected = 'x', after = {}, before = {} }
    eq(fb.UNAVAILABLE, e.after)
    eq(fb.UNAVAILABLE, e.before)
end)

test('entry: the expectation is trimmed but its internal newlines survive', function ()
    local e = fb.entry { expected = '\n  line one\nline two  \n\n' }
    eq('line one\nline two', e.expected)
end)

test('classify: DERIVED, and an absence outranks a transition', function ()
    eq('content', fb.classify { subject = { kind = 'node' } })
    eq('transition', fb.classify { subject = { kind = 'node' }, gesture = 'descend' })
    -- descended INTO an empty pane: diagnosed from the empty's declared reason,
    -- not from the hop, so 'absence' wins
    eq('absence', fb.classify { subject = { kind = 'node' }, gesture = 'descend',
        empty = { rendered = 'x', uncomputed = true } })
    eq('absence', fb.classify { subject = { kind = 'none' } })
end)

-- ── env: what can flip a verdict ─────────────────────────────────────────────

test('env: every key present; a nil store yields UNAVAILABLE, not a gap', function ()
    local e = fb.env(nil)
    for _, k in ipairs({ 'nvim', 'cartograph', 'parsers', 'cache_version',
        'root', 'index_only', 'profile', 'packs' }) do
        assert(e[k] ~= nil, 'env key vanished: ' .. k)
    end
    eq(fb.UNAVAILABLE, e.root)
    eq(fb.UNAVAILABLE, e.index_only)
    eq('number', type(e.cache_version)) -- ours, always knowable
end)

test('env: a store supplies the facts that decide verdicts', function ()
    local e = fb.env(stub_store())
    eq(ROOT, e.root)
    eq(false, e.index_only)
    eq('lua-factorio', e.profile)
    eq({ 'rails' }, e.packs)
end)

-- ── sight: the capture, and how it degrades ──────────────────────────────────

test('sight: with NO store and NO pane the expectation still becomes an entry', function ()
    -- the rule: the capture degrades, the message never does
    local s = fb.sight(nil, nil)
    s.expected = 'the cockpit would not open at all'
    local e = fb.entry(s)
    assert(e, 'a report was refused for lack of context')
    eq('the cockpit would not open at all', e.expected)
    eq('content', e.kind)
end)

test('sight: a gesture captures the side you came FROM', function ()
    local pane = {
        view = { level = 'proto', lens = false },
        rows = function () return { 'after-1', 'after-2' }, 1 end,
        last_gesture = { gesture = 'descend', level = 'protos', lens = false,
            row = 7, rows = { 'before-1' } },
        row_subject = function () return nil end,
    }
    local s = fb.sight(stub_store(), pane)
    eq('descend', s.gesture)
    eq({ 'before-1' }, s.before)
    eq({ 'after-1', 'after-2' }, s.after)
    eq('protos', s.from.altitude) -- where the key was PRESSED, not where we are
    eq('proto', s.altitude)
end)

test('sight: a row about NO node files a HOLE carrying the row text', function ()
    local pane = {
        view = { level = 'callers' },
        rows = function () return { 'ƒ update', '  (no callers)' }, 2 end,
        row_subject = function () return nil end,
    }
    local s = fb.sight(stub_store(), pane)
    eq('none', s.subject.kind)
    eq('  (no callers)', s.subject.row) -- the row you were actually pointing at
    assert(s.subject.why:match('no node'), 'the hole must say WHY it is a hole')
    s.expected = 'update is called from railbot.lua'
    eq('absence', fb.entry(s).kind)
end)

test('sight: with no cursor row the ALTITUDE still names the subject', function ()
    -- found live: row_subject bails when the browser window is not the current
    -- one, which is exactly when you file a complaint from somewhere else. Losing
    -- the subject there silently downgraded a content report to an absence.
    local node = { id = 'n9', name = 'compactLog', kind = 'function', file = 'log.lua' }
    local store = stub_store { node = function () return node end }
    local pane = {
        view = { level = 'fn' },
        rows = function () return { '⚑ compactLog', '  concat-in-loop' }, nil end,
        row_subject = function () return nil end, -- no cursor row -> no answer
        subject = function () return 'n9' end,    -- but the altitude knows
    }
    local s = fb.sight(store, pane)
    eq('node', s.subject.kind)
    eq('compactLog', s.subject.name)
    eq('altitude', s.subject.whence) -- and it says HOW it was anchored
    s.expected = 'the footer should name the unread expressions'
    eq('content', fb.entry(s).kind) -- not 'absence'
end)

test('sight: an unreadable row does NOT claim it was filed on the row', function ()
    -- saying "filed on the ROW" when no row could be read is a false statement
    -- about our own evidence — the exact defect class this module guards
    local pane = { view = { level = 'files' },
        rows = function () return { 'a', 'b' }, nil end,
        row_subject = function () return nil end }
    local s = fb.sight(stub_store(), pane)
    eq('none', s.subject.kind)
    eq(fb.UNAVAILABLE, s.subject.row)
    assert(not s.subject.why:match('filed on the ROW'),
        'claimed a row it never read: ' .. s.subject.why)
    assert(s.subject.why:match('no cursor row'), s.subject.why)
end)

test('sight: the typed EMPTY is captured with its uncomputed flag', function ()
    -- 'callers' is a registered concern, so the pane's blankness has a declared
    -- reason; capturing it separates "honest but unhelpful" from "lied"
    local pane = { view = { level = 'callers' },
        rows = function () return { 'x' }, 1 end,
        row_subject = function () return nil end }
    local s = fb.sight(stub_store(), pane)
    eq('table', type(s.empty))
    eq('string', type(s.empty.rendered))
    eq('boolean', type(s.empty.uncomputed))
end)

test('sight: a node subject FREEZES its source bytes', function ()
    vim.fn.mkdir(SCRATCH, 'p')
    local src = SCRATCH .. '/frozen.lua'
    local fd = assert(io.open(src, 'w'))
    fd:write('local function keep()\n  return 1\nend\n')
    fd:close()
    local node = { id = 'n1', name = 'keep', kind = 'function', file = 'frozen.lua',
        range = { start = { line = 0, char = 0 }, ['end'] = { line = 2, char = 3 } } }
    local store = stub_store {
        node = function (id) return id == 'n1' and node or nil end,
        abs = function () return src end,
        -- the call list arrives through Band:sites, the sanctioned seam for the
        -- wide indexes (store.calls_by_fn is band.lua's to read, not ours)
        topo = function ()
            return { sites = function (_, id)
                return id == 'n1'
                    and { { callee = 'x', prov = 'name-index', file = 'f', line = 1 } }
                    or {}
            end }
        end,
    }
    local pane = { view = { level = 'fn', lens = 'statements' },
        rows = function () return { 'ƒ keep' }, 1 end,
        row_subject = function () return 'n1', 'row' end }
    local s = fb.sight(store, pane)
    eq('node', s.subject.kind)
    eq('keep', s.subject.name)
    eq('row', s.subject.whence)
    -- the evidence, verbatim: an id may still resolve after an edit and resolve
    -- to something ELSE, so the bytes are what survive
    eq({ 'local function keep()', '  return 1', 'end' }, s.subject.source.text)
    eq(false, s.subject.source.truncated)
    -- and WHY it believed what it said: a histogram, not a verdict
    eq(1, s.why.calls)
    eq({ 'name-index 1' }, s.why.by_prov)
    vim.fn.delete(src)
end)

test('freeze: a FOLDED range (a column index, not a table) never crashes', function ()
    -- found live, and no fixture could have caught it: my spec invented the raw
    -- {start={line}} shape, but a live store folds every range to a number and
    -- indexing that raises. Read through cartograph.at or not at all.
    local node = { id = 'n1', name = 'x', kind = 'function', file = 'f.lua', range = 4241 }
    local store = stub_store { node = function () return node end,
        abs = function () return SCRATCH .. '/nothing.lua' end }
    local got = fb.freeze(store, node)
    -- either it read the columns or it says UNAVAILABLE; it does not raise
    assert(got == fb.UNAVAILABLE or type(got) == 'table', tostring(got))
    local pane = { view = { level = 'fn' }, rows = function () return { 'r' }, 1 end,
        row_subject = function () return 'n1', 'row' end }
    local s = fb.sight(store, pane) -- the path that actually crashed
    eq('node', s.subject.kind)
end)

test('sight: an unreadable subject file is UNAVAILABLE, never a crash', function ()
    local node = { id = 'n1', name = 'gone', kind = 'function', file = 'nope.lua',
        range = { start = { line = 0 }, ['end'] = { line = 1 } } }
    local store = stub_store {
        node = function () return node end,
        abs = function () return SCRATCH .. '/definitely-absent.lua' end,
    }
    local pane = { view = { level = 'fn' }, rows = function () return { 'r' }, 1 end,
        row_subject = function () return 'n1', 'row' end }
    local s = fb.sight(store, pane)
    eq(fb.UNAVAILABLE, s.subject.source)
    eq(fb.UNAVAILABLE, s.why) -- no calls indexed for it
end)

-- ── the store on disk ────────────────────────────────────────────────────────

test('write/list: a round trip through JSON, newest first', function ()
    cleanup()
    local a = fb.entry { expected = 'first complaint', ts = 1000,
        after = { 'row-a' }, subject = { kind = 'none', row = 'r', why = 'w' } }
    local b = fb.entry { expected = 'second complaint', ts = 2000 }
    assert(fb.write(ROOT, a))
    assert(fb.write(ROOT, b))
    local got = fb.list(ROOT)
    eq(2, #got)
    eq('second complaint', got[1].expected) -- newest first
    eq('first complaint', got[2].expected)
    eq({ 'row-a' }, got[2].after)          -- rows survive the round trip
    eq(fb.UNAVAILABLE, got[2].gesture)     -- so does the honest absence
    cleanup()
end)

test('dir: entries live in the STATE dir — a user record, never a cache', function ()
    local d = fb.dir(ROOT)
    assert(d:find(vim.fn.stdpath('state'), 1, true) == 1, 'not under stdpath(state): ' .. d)
    assert(not d:find(vim.fn.stdpath('cache'), 1, true), 'a cache is deletable; this is not')
    assert(d:match('%.feedback$'), 'feedback entries must not share the journal dir')
end)

-- ── the dump: the read path that has to reach a fixer ─────────────────────────

local function dump_of(entries) return fb.markdown(entries, ROOT) end
local function joined(entries) return table.concat(dump_of(entries), '\n') end

test('markdown: no entries still tells you how to file one', function ()
    local out = joined({})
    assert(out:match('0 entries'), out)
    assert(out:match('CartographFeedback'), 'an empty log must not be a dead end')
end)

test('markdown: carries the expectation, the observed rows and the environment', function ()
    local e = fb.entry {
        expected = 'descending should list the overrides',
        gesture = 'descend', altitude = 'proto', lens = false,
        from = { altitude = 'protos', lens = false },
        after = { 'vn-chest [copy]', '  name' }, before = { 'prototypes  (54)' },
        subject = { kind = 'node', id = 'n1', name = 'chests', node_kind = 'module',
            file = 'chests.lua', whence = 'row',
            source = { first_line = 1, last_line = 2, truncated = false,
                text = { 'local a = 1', 'return a' } } },
        why = { calls = 3, refused = 1, by_prov = { 'name-index 2', 'pack 1' } },
        env = fb.env(stub_store()),
    }
    local out = joined({ e })
    assert(out:match('descending should list the overrides'), 'the expectation is missing')
    assert(out:match('vn%-chest %[copy%]'), 'the OBSERVED rows are missing')
    assert(out:match('prototypes  %(54%)'), 'the BEFORE rows are missing')
    assert(out:match('local a = 1'), 'the frozen source is missing')
    assert(out:match('name%-index 2'), 'the call provenance is missing')
    assert(out:match('lua%-factorio'), 'the profile is missing')
    assert(out:match('came from altitude `protos`'), 'the side you came FROM is missing')
    assert(out:match('transition'), 'the derived kind is missing')
end)

test('markdown: a HOLE report says what the row was, not just that it failed', function ()
    local e = fb.entry { expected = 'there should be callers',
        subject = { kind = 'none', row = '  (no callers)',
            why = 'the cursor row is about no node — filed on the ROW' },
        empty = { rendered = '(no callers)', uncomputed = true },
        env = fb.env(nil) }
    local out = joined({ e })
    assert(out:match('a row with no node'), out)
    assert(out:match('%(no callers%)'), 'the row text is the only anchor a hole has')
    assert(out:match('nothing was COMPUTED'),
        'an uncomputed empty must be spelled out, not left as a flag')
end)

test('markdown: never renders a bare nil — the silence defect, fenced', function ()
    -- an unrendered nil in a report reads as an answer; UNAVAILABLE reads as one
    -- too, but as the RIGHT one. The NESTED nils are the ones that got through
    -- live: entry() normalizes top-level fields only, so `from.lens = nil`
    -- printed "nil" one line below a sibling printing UNAVAILABLE.
    local out = joined({ fb.entry {
        expected = 'minimal',
        from = { altitude = 'protos' },              -- .lens is nil
        subject = { kind = 'node', name = 'f' },     -- .file/.whence are nil
        why = { calls = 1 },                         -- .refused/.by_prov are nil
        env = { root = '/x' },                       -- most keys are nil
    } })
    for _, l in ipairs(vim.split(out, '\n', { plain = true })) do
        assert(not l:match('%f[%w]nil%f[%W]'), 'a nested nil reached the dump: ' .. l)
    end
    out = joined({ fb.entry { expected = 'minimal' } })
    for _, l in ipairs(vim.split(out, '\n', { plain = true })) do
        assert(not l:match('%f[%w]nil%f[%W]'), 'a nil reached the dump: ' .. l)
    end
    assert(out:match('UNAVAILABLE'), 'the honest absence should be visible')
end)

-- ── the pane seam ────────────────────────────────────────────────────────────

test('pane: the gesture recorder works with no browser open', function ()
    local symbols = require 'cartograph.panes.symbols'
    eq(nil, symbols.rows())          -- no buffer: nil, not an error
    symbols.note_gesture('descend')  -- must not depend on a live pane
    eq('descend', symbols.last_gesture.gesture)
    eq(nil, symbols.last_gesture.rows)
    symbols.last_gesture = nil
end)
