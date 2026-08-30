-- CART-0582: TWO APPLIES INSIDE ONE SECOND MUST NOT EAT EACH OTHER'S UNDO.
--
-- The id was `os.time() .. '-' .. verb` and write_entry opens with 'w' (a plain
-- truncate), so two applies of one verb to one root in the same second wrote the
-- same filename and the second OVERWROTE the first. The entry holds the
-- BEFORE-CONTENT, so what was destroyed was the first apply's UNDO.
--
-- Nothing in the code ever guaranteed uniqueness — THE GUARANTEE WAS HUMAN
-- TYPING SPEED. Making the write verbs agent-drivable (CART-0146) removed what
-- was hiding it. That is why these tests do the two applies back to back with
-- nothing in between: the fence has to reproduce machine speed, because a test
-- that pauses between them passes against the bug.

local journal = require 'cartograph.journal'

-- a root nobody else owns: dir_of() derives the journal directory from the root
-- path, so a unique root gives a unique directory under stdpath('state') that
-- this spec creates and wipes. It must not touch the developer's real journals.
local function fresh_root()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    return root
end

local function put(root, rel, text)
    local fd = assert(io.open(root .. '/' .. rel, 'w'))
    fd:write(text); fd:close()
end

local function get(root, rel)
    local fd = io.open(root .. '/' .. rel, 'r')
    if not fd then return nil end
    local t = fd:read('a'); fd:close()
    return t
end

--- one full apply: journal it, write the new bytes, commit.
local function apply(root, verb, rel, from, to)
    local e, why = journal.begin(root, verb, 'test', { [rel] = from })
    if not e then return nil, why end
    put(root, rel, to)
    journal.commit(root, e, { [rel] = to })
    return e
end

test('CART-0582: two applies in the same second keep BOTH undos', function ()
    local root = fresh_root()
    put(root, 'm.lua', 'v0')

    -- back to back, no sleep: this is the machine-speed case
    local e1 = assert(apply(root, 'move', 'm.lua', 'v0', 'v1'))
    local e2 = assert(apply(root, 'move', 'm.lua', 'v1', 'v2'))

    ok(e1.id ~= e2.id, 'ids must differ: ' .. e1.id .. ' vs ' .. e2.id)
    eq(2, #journal.list(root), 'both entries survive on disk')
    eq('v2', get(root, 'm.lua'))

    -- LIFO, and each restores ITS OWN before-content. Under the bug the first
    -- entry's file was gone, so this second rollback had nothing to restore.
    local r1 = assert(journal.rollback(root))
    eq(e2.id, r1.id, 'the newest entry is the undo target')
    eq('v1', get(root, 'm.lua'), 'first undo restores the second apply\'s before')

    local r2 = assert(journal.rollback(root))
    eq(e1.id, r2.id, 'then the older one')
    eq('v0', get(root, 'm.lua'), 'second undo restores the FIRST apply\'s before')

    journal.wipe(root)
    vim.fn.delete(root, 'rf')
end)

test('CART-0582: ids stay ordered — newest first, across many in one second', function ()
    local root = fresh_root()
    put(root, 'm.lua', 'x0')
    local made = {}
    for i = 1, 8 do
        made[i] = assert(apply(root, 'move', 'm.lua', 'x' .. (i - 1), 'x' .. i))
    end
    local seen = {}
    for _, e in ipairs(made) do
        ok(not seen[e.id], 'id reused: ' .. e.id)
        seen[e.id] = true
    end
    local listed = journal.list(root)
    eq(8, #listed)
    -- M.list sorts by `a.id > b.id` and M.last takes the first applied entry,
    -- so ordering is not cosmetic: it picks the undo target.
    for i = 1, 8 do
        eq(made[9 - i].id, listed[i].id, ('position %d is newest-first'):format(i))
    end
    journal.wipe(root)
    vim.fn.delete(root, 'rf')
end)

test('CART-0582: a NEW id sorts after an OLD-format one from the same second', function ()
    -- Journals already on disk hold `<epoch>-<verb>` ids and M.list compares
    -- them as STRINGS, so the new format has to interleave correctly with them
    -- or an existing journal's undo order silently changes. `.` is 0x2E and `-`
    -- is 0x2D, which is what makes this hold.
    local old = '1787782381-move'
    local new = ('%d.%06d-%s'):format(1787782381, 0, 'move')
    ok(new > old, 'a new entry from the same second is treated as LATER')
    ok(('%d.%06d-move'):format(1787782382, 0) > new, 'the next second is later still')
    -- zero-padding is load-bearing: unpadded, '.9' would beat '.10'
    ok(('%d.%06d-move'):format(1, 10) > ('%d.%06d-move'):format(1, 9),
        'usec must be fixed-width or ordering inverts above 9')
end)

-- ⚠ THE BUMP PATH IS NOT FENCED, AND SAYING SO BEATS FAKING IT.
-- alloc_id retries on EEXIST by advancing the microsecond. Reaching that branch
-- needs two allocations inside the SAME microsecond, which cannot be forced
-- deterministically without controlling the clock — and a test that pre-creates a
-- band of ids and hopes the allocator lands in it is a flaky test, not a fence.
--
-- This file previously ended with a test asserting that an exclusive create fails
-- on an existing path. It passed against the bug, because it exercised libuv's
-- O_EXCL rather than alloc_id: the entry file exists either way. That is the same
-- defect as CART-0579's `#ev.sites >= 2`, which passes trivially on a duplicated
-- list — an assertion that cannot fail for the reason it names. Removed rather
-- than kept as coverage it never provided.
--
-- What IS fenced: distinct ids under machine speed, both undos surviving, order
-- across eight applies in one second, and the string-ordering contract against
-- the on-disk format. What is not: the EEXIST retry itself.

-- ── RETENTION (CART-0644) ───────────────────────────────────────────────────

test('journal retention: a journal whose ROOT IS GONE is unreachable, and pruned',
    function ()
    local j = require 'cartograph.journal'
    -- ★★ THE PREDICATE IS SOUNDNESS, NOT AGE. `rollback` verifies the CURRENT content
    -- of each file against after_hash before restoring; with the root gone there is
    -- no current content, so the entry can never do its job again — today or in a
    -- year. Nothing reachable is destroyed. Measured when this shipped: 27798 journal
    -- directories, 27794 of them for `vim.fn.tempname()` roots from ~1949 test runs.
    local live_root = vim.fn.tempname(); vim.fn.mkdir(live_root, 'p')
    local dead_root = vim.fn.tempname(); vim.fn.mkdir(dead_root, 'p')
    local e1 = j.begin(live_root, 'trial', {}, { ['a.lua'] = 'before' })
    local e2 = j.begin(dead_root, 'trial', {}, { ['a.lua'] = 'before' })
    ok(e1 and e2, 'both journals written')
    vim.fn.delete(dead_root, 'rf')          -- the root goes; the journal remains

    local seen = {}
    for _, r in ipairs(j.survey()) do seen[tostring(r.root)] = r end
    eq(true, seen[live_root] and seen[live_root].keep, 'a live root is KEPT')
    eq(false, seen[dead_root] and seen[dead_root].keep, 'a dead root is unreachable')
    eq('root-gone', seen[dead_root].why)

    -- ⚠ DRY BY DEFAULT. Deleting a USER RECORD must not happen as a side effect of
    -- asking about it, which is why `apply` is opt-in and the command needs a bang.
    local dry = j.prune({})
    eq(false, dry.applied)
    ok(#j.list(dead_root) > 0, 'a dry run touched nothing')

    local st = j.prune({ apply = true })
    eq(true, st.applied)
    ok(st.removed >= 1, 'at least the dead one went')
    eq(0, #j.list(dead_root), 'the unreachable journal is gone')
    ok(#j.list(live_root) > 0, 'and the reachable one is UNTOUCHED — the whole point')
    j.wipe(live_root)
    vim.fn.delete(live_root, 'rf')
end)

test('journal retention: the root is read from an ENTRY, not from the directory name',
    function ()
    -- ⚠ `dir_of` maps `/`, `\` and `:` all to `%`, so the directory name is a LOSSY
    -- escape and un-escaping it would guess. Every entry records `root` verbatim.
    local j = require 'cartograph.journal'
    local root = vim.fn.tempname() .. '/a:b'   -- a colon: escaped like a separator
    vim.fn.mkdir(root, 'p')
    ok(j.begin(root, 'trial', {}, { ['x.lua'] = 'before' }) ~= nil, 'journal written')
    local found
    for _, r in ipairs(j.survey()) do if r.root == root then found = r end end
    ok(found ~= nil, 'the survey recovered the exact root, colon and all')
    eq(true, found.keep, 'and it still exists, so it is kept')
    j.wipe(root); vim.fn.delete(root, 'rf')
end)
