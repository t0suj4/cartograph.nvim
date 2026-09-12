-- CART-0698. A recovered template becomes a thing you can hold, correct, and
-- re-apply. The point is not persistence — `validity.lua` already owns caching —
-- it is that a template you can point at is A CLAIM, and a claim is the only
-- form that can be WRONG IN A USEFUL WAY. So these specs weigh toward the edit
-- verbs and `reverify`, not toward record/get round-tripping.

local T = require 'cartograph.templates'
local clones = require 'cartograph.clones'
local expr = require 'cartograph.expr'
local store = require 'cartograph.store'

local function ready()
    return pcall(vim.treesitter.language.add, 'lua')
end

local function container_of(src)
    local root = vim.treesitter.get_string_parser(src, 'lua'):parse()[1]:root()
    local function find(n)
        if n:type() == 'table_constructor' then return n end
        for c in n:iter_children() do
            if c:named() then local r = find(c); if r then return r end end
        end
    end
    return expr.build(find(root), src, 'lua')
end

-- a bare store stand-in: these specs exercise the template store, not extraction
local function fresh(gen)
    return { generation = gen or 1 }
end

local function tmpl3()
    return clones.element_template(container_of("local T = { 'x', 'y', 'z' }"))
end

local function some_key(body)
    local keys = {}
    for k in pairs(body.varying or {}) do keys[#keys + 1] = k end
    table.sort(keys)
    return keys[1], #keys
end

-- ⚠ READ THROUGH T.body, NOT rec.body. A LIVING template holds no frozen body by
-- construction — it derives through `redo` — so reaching for rec.body is exactly
-- the mistake the living/snapshot split is meant to make impossible to miss.
local function key_of(st, id)
    return (some_key((T.body(st, id))))
end

-- most of these specs want a definite body to edit, which is what a SNAPSHOT is
local function snap3(st, why)
    local id = assert(T.record(st, 'element', tmpl3(),
        { why = why or 'literals', snapshot = true }))
    return id
end

test('templates: a recovered template gets a handle and keeps its provenance', function ()
    if not ready() then return skip 'no lua parser' end
    local st = fresh()
    local id = assert(T.record(st, 'element', tmpl3(),
        { why = 'three string literals in one container' }))
    local rec, state = T.get(st, id)
    ok(rec, 'the handle reads back')
    eq('live', state, 'recorded against this generation')
    eq('element', rec.shape)
    ok(rec.origin.why:find 'three string', 'and carries WHY it exists')
end)

-- ⚠ PROVENANCE IS MANDATORY, and this is the guard that makes the whole
-- body/warrant split possible: a template with no origin cannot go stale and
-- cannot be reverified, so it would read as authored when it was mined.
test('templates: a template with no provenance is refused, not stored', function ()
    if not ready() then return skip 'no lua parser' end
    local st = fresh()
    local id, err = T.record(st, 'element', tmpl3(), {})
    eq(nil, id)
    ok(err and err:find 'provenance', 'and says why: ' .. tostring(err))
    eq(0, #T.list(st), 'nothing was stored')
end)

-- ★ Decision 4: two producers, two shapes, and only one is matchable. Storage is
-- what exposed it. The `pair` shape is recorded rather than rejected — it is a
-- real template — but it must never claim it can be applied.
test('templates: a pair-shaped template records, and REFUSES apply with the reason', function ()
    if not ready() then return skip 'no lua parser' end
    local st = fresh()
    local id = assert(T.record(st, 'pair',
        { kind = 'value', holes = {}, insdel = 0 },
        { why = 'an analyze_pair result' }))
    local m, why = T.apply(st, id, { k = 'lit' })
    eq(nil, m)
    ok(why and why:find 'donor', 'the refusal names the missing donor: ' .. tostring(why))
end)

test('templates: an unlisted shape cannot be recorded', function ()
    local st = fresh()
    local id, err = T.record(st, 'protocol', {}, { why = 'x' })
    eq(nil, id)
    ok(err and err:find 'templates.SHAPES', 'points at the roster: ' .. tostring(err))
end)

-- ★ `alignable = false` is an ANSWER, not a template. Storing it would put a
-- non-template behind a handle that later code would try to apply.
test('templates: a donorless element result is an answer, not a template', function ()
    if not ready() then return skip 'no lua parser' end
    local st = fresh()
    local bad = { n = 0, alignable = false, why = 'no members' }
    local id, err = T.record(st, 'element', bad, { why = 'empty container' })
    eq(nil, id)
    ok(err and err:find 'answer, not a template', tostring(err))
end)

-- ── the edits: a template you can correct ───────────────────────────────────

-- THE MECHANISM, not the outcome: pinning must change what MATCH DOES. `match`
-- classifies a divergence at a varying position as a BINDING and the same
-- divergence anywhere else as a MISMATCH, so removing a key from `varying` has
-- to flip that verdict. Asserting only that the key moved would pass against a
-- version where nothing consumes `varying`.
test('templates: pinning a hole turns a binding into a mismatch', function ()
    if not ready() then return skip 'no lua parser' end
    local st = fresh()
    local id = assert(T.record(st, 'element', tmpl3(), { why = 'literals' }))
    local key, n = some_key((T.body(st, id)))
    ok(key and n > 0, 'the template varies somewhere')

    local payload = container_of("local U = { 'q' }").kids[1]
    local before = T.apply(st, id, payload)
    ok(before and before.ok, 'a differing literal binds while the position varies')

    assert(T.pin(st, id, key))
    local after = T.apply(st, id, payload)
    ok(after and not after.ok, 'and MISMATCHES once that position is pinned')
    ok(#(after.refusal and after.refusal.mismatches or {}) > 0 or after.distance > 0,
        'with the divergence reported as a mismatch')
end)

test('templates: pinning is recorded as an edit, in order', function ()
    if not ready() then return skip 'no lua parser' end
    local st = fresh()
    local id = assert(T.record(st, 'element', tmpl3(), { why = 'literals' }))
    local key = key_of(st, id)
    assert(T.pin(st, id, key))
    assert(T.open(st, id, key))
    local rec = select(1, T.get(st, id))
    eq(2, #rec.edits)
    eq('pin', rec.edits[1].op)
    eq('open', rec.edits[2].op)
end)

-- ⚠ THE BOUND ON `open`, and it falls out of the data model rather than a
-- policy: opening a position that was never a hole would need a SOURCE SPAN, and
-- a spanless hole is exactly what `element_template` counts as `unkeyed` and
-- `match` refuses on ("a position cannot be told from a mismatch").
test('templates: a position that was never a hole cannot be opened', function ()
    if not ready() then return skip 'no lua parser' end
    local st = fresh()
    local id = assert(T.record(st, 'element', tmpl3(), { why = 'literals' }))
    local rec, err = T.open(st, id, 'never-a-hole:0:0')
    eq(nil, rec)
    ok(err and err:find 'no source span', 'and the refusal explains: ' .. tostring(err))
end)

-- ── the warrant: the claim outlives it, and only the warrant licenses acting ──

-- ★★ Decision 2. Generation-keying the whole record — the rule findings.lua and
-- plan handles use — would DELETE an edited template on the next graph change.
-- So the body survives and the ORIGIN goes stale, separately and by name.
test('templates: a graph change stales the ORIGIN and keeps the body', function ()
    if not ready() then return skip 'no lua parser' end
    local st = fresh(1)
    local id = assert(T.record(st, 'element', tmpl3(), { why = 'literals' }))
    local key = key_of(st, id)
    assert(T.pin(st, id, key), 'an edit the user made')

    st.generation = 2                       -- the tree moved under it
    local rec, state = T.get(st, id)
    eq('stale-origin', state)
    ok(rec, 'the body is still there')
    eq(1, #rec.edits, 'and so is the correction the user made')
end)

-- ★★★ AND THE OTHER HALF, WHICH THE FIRST CUT GOT BACKWARDS. A stale origin
-- must NOT refuse: `clones.match` compares IR to IR and touches no file, so a
-- moved source cannot make a match wrong, and gating it made the template die
-- with its source. USER: "creating a template needs to outlive its source ...
-- the best we can do is probably recording provenance."
test('templates: a template OUTLIVES its source — apply still answers, flagged', function ()
    if not ready() then return skip 'no lua parser' end
    local st = fresh(1)
    local id = assert(T.record(st, 'element', tmpl3(), { why = 'literals' }))
    st.generation = 7
    local m = T.apply(st, id, container_of("local U = { 'q' }").kids[1])
    ok(m and m.ok, 'the match is still answered')
    eq('stale-origin', m.state, 'and it says the origin moved')
    eq('flag', m.provenance.license, 'flag, not refuse')
end)

-- ⚠ THE BOUND MAY NEVER REACH 'nothing'. No state of the source can invalidate
-- a template, so the strongest this may say is "act, but report what moved" —
-- tier.licenses' rule, that a license is an upper bound a consumer may weaken.
test('templates: the license is act or flag, never nothing', function ()
    if not ready() then return skip 'no lua parser' end
    local st = fresh(1)
    local id = assert(T.record(st, 'element', tmpl3(),
        { why = 'literals', file = '/definitely/not/here.lua', stamp = 'x:y:z' }))
    local lic, why = T.license(st, id)
    eq('flag', lic, 'the source is GONE and it still only flags: ' .. tostring(why))
    local prov = T.provenance(st, id)
    eq('gone', prov.source)
end)

-- ★★ A STAMP OUTRANKS THE GENERATION (decision 2b): the generation bumps on any
-- ingest in the session, a stamp is about THIS file. So an intact source reads
-- LIVE even after a re-ingest, and a template that recorded no file falls back
-- to the coarse counter.
test('templates: an intact stamp reads live even after the generation moves', function ()
    if not ready() then return skip 'no lua parser' end
    local st = fresh(1)
    local self_path = vim.fn.getcwd() .. '/lua/cartograph/templates.lua'
    local stamp = T.stamp(self_path)
    ok(stamp, 'this file is stampable')
    local id = assert(T.record(st, 'element', tmpl3(),
        { why = 'literals', file = self_path, stamp = stamp }))
    st.generation = 99
    local prov = T.provenance(st, id)
    eq('same', prov.source, 'the file has not moved')
    eq('moved', prov.generation, 'the graph has')
    eq('act', prov.license, 'and the STAMP decides, not the counter')
end)

test('templates: with no stamp recorded, the generation is the fallback', function ()
    if not ready() then return skip 'no lua parser' end
    local st = fresh(1)
    local id = assert(T.record(st, 'element', tmpl3(), { why = 'no file recorded' }))
    eq('unstamped', T.provenance(st, id).source)
    eq('act', (T.license(st, id)))
    st.generation = 2
    eq('flag', (T.license(st, id)), 'the coarse counter gets a vote only here')
end)

-- ── reverification: what makes a stored template falsifiable ────────────────

-- ★★ LIVING IS THE DEFAULT WHEN A `redo` EXISTS (decision 5), and reverify on a
-- living template is an honest UNCHECKED: it follows the source, so "does it
-- still re-derive" is true by construction and carries no information.
-- Reporting agreement here would manufacture a check nobody ran.
test('templates: reverify on a LIVING template is unchecked, not agreement', function ()
    if not ready() then return skip 'no lua parser' end
    local st = fresh()
    local id = assert(T.record(st, 'element', tmpl3(),
        { why = 'literals', redo = function () return tmpl3() end }))
    eq('living', select(2, T.get(st, id)))
    local r = assert(T.reverify(st, id))
    eq(false, r.ok)
    eq(nil, r.agree, 'not true — nothing is frozen to compare')
    ok(r.why:find 'snapshot it first', tostring(r.why))
end)

-- and once frozen, drift IS a finding — that is what snapshotting buys
test('templates: a SNAPSHOT re-derives from the same inputs', function ()
    if not ready() then return skip 'no lua parser' end
    local st = fresh()
    local id = assert(T.record(st, 'element', tmpl3(),
        { why = 'literals', snapshot = true, redo = function () return tmpl3() end }))
    local r = assert(T.reverify(st, id))
    eq(true, r.ok)
    eq(true, r.agree)
    eq(false, r.edited)
end)

-- ★ REVERIFY COMPARES AGAINST `base`, NOT `body`. An edited body is SUPPOSED to
-- differ from a fresh derivation — that is what editing means — so comparing the
-- body would report every correction as drift.
test('templates: an edited template still re-derives, and reports that it was edited', function ()
    if not ready() then return skip 'no lua parser' end
    local st = fresh()
    local id = assert(T.record(st, 'element', tmpl3(),
        { why = 'literals', redo = function () return tmpl3() end }))
    assert(T.pin(st, id, (key_of(st, id))))
    local r = assert(T.reverify(st, id))
    eq(true, r.agree, 'the BASE is unchanged, so re-derivation still agrees')
    eq(true, r.edited, 'and the caller is told the current body is not the derived one')
end)

test('templates: a template whose inputs now yield a different shape DISAGREES', function ()
    if not ready() then return skip 'no lua parser' end
    local st = fresh()
    local id = assert(T.record(st, 'element', tmpl3(), {
        why = 'literals',
        snapshot = true,     -- drift is a finding only against a frozen moment
        -- the "code changed" case: two members instead of three
        redo = function ()
            return clones.element_template(container_of("local T = { 'x' }"))
        end,
    }))
    local r = assert(T.reverify(st, id))
    eq(true, r.ok)
    eq(false, r.agree)
    ok(r.why:find 'disagrees', tostring(r.why))
end)

-- ⚠ AN HONEST UNAVAILABLE, NOT A PASS. `ok = false` with `agree = nil` says
-- nothing was checked — the same distinction findings.lua draws between "every
-- census looked and said nothing" and "no census ran".
test('templates: a template with no redo reports UNCHECKED, never agreement', function ()
    if not ready() then return skip 'no lua parser' end
    local st = fresh()
    local id = assert(T.record(st, 'element', tmpl3(), { why = 'literals' }))
    local r = assert(T.reverify(st, id))
    eq(false, r.ok)
    eq(nil, r.agree, 'not `false` — nothing was compared')
    ok(r.why:find 'redo', tostring(r.why))
end)

-- ── band placement (decision 3) ─────────────────────────────────────────────

-- ★★ THE OPPOSITE DEFAULT FROM CART-0822, and it needs a test because
-- "unregistered" and "nobody decided" look identical in a diff. Ten caches were
-- re-homed INTO BAND_TRANSIENT because a cache must not survive a band swap. A
-- template must: losing an edited one is data loss, not staleness.
test('templates: _templates is NOT band-transient — a swap must not lose an edit', function ()
    eq(nil, store.BAND_TRANSIENT._templates,
        'a template store in BAND_TRANSIENT would be dropped on every band swap')
end)

test('templates: capture() carries the template store, so a band keeps its own', function ()
    if not ready() then return skip 'no lua parser' end
    local saved = store._templates
    store._templates = nil
    local id = assert(T.record(store, 'element', tmpl3(), { why = 'literals' }))
    local rec = store.capture()
    ok(rec._templates, 'the snapshot carries it')
    ok(rec._templates.by_id[id], 'including the handle')
    store._templates = saved
end)

test('templates: forget removes one and says whether it was there', function ()
    if not ready() then return skip 'no lua parser' end
    local st = fresh()
    local id = assert(T.record(st, 'element', tmpl3(), { why = 'literals' }))
    eq(true, T.forget(st, id))
    eq(false, T.forget(st, id))
    eq(nil, (T.get(st, id)))
end)

test('templates: list reports each handle with its warrant state and hole count', function ()
    if not ready() then return skip 'no lua parser' end
    local st = fresh(3)
    local a = assert(T.record(st, 'element', tmpl3(), { why = 'first' }))
    st.generation = 4
    local b = assert(T.record(st, 'element', tmpl3(), { why = 'second' }))
    local rows = T.list(st)
    eq(2, #rows)
    eq(a, rows[1].id); eq('stale-origin', rows[1].state)
    eq(b, rows[2].id); eq('live', rows[2].state)
    ok(rows[2].holes > 0, 'and how many positions it varies at')
end)

-- ── the cap (decision 5): recording state without unbounded cardinality ─────

-- USER: "Recording state might be interesting, but I feel like we might hit the
-- prometheus cardinality thing if we do it indiscriminately." The first cut had
-- no cap at all — `seq` grew and `by_id` kept everything.
test('templates: the store is capped, so churn cannot grow it without bound', function ()
    if not ready() then return skip 'no lua parser' end
    local st = fresh()
    for _ = 1, T.CAP + 20 do
        assert(T.record(st, 'element', tmpl3(),
            { why = 'derived', redo = function () return tmpl3() end }))
    end
    local p = T.pressure(st)
    eq(T.CAP, p.kept, 'held down to the cap')
    eq(20, p.evicted, 'and the overflow is COUNTED, not silent')
    eq(T.CAP, p.living, 'they are all LIVING, so every eviction is recoverable')
end)

-- ★★ EVICTION IS BY RE-DERIVABILITY, NOT AGE. A plain LRU would drop an EDITED
-- template, which is the data loss decision 3 already refused for band swaps.
test('templates: a SNAPSHOT is never evicted by the cap', function ()
    if not ready() then return skip 'no lua parser' end
    local st = fresh()
    local mine = assert(T.record(st, 'element', tmpl3(),
        { why = 'the one I edited', redo = function () return tmpl3() end }))
    assert(T.pin(st, mine, (key_of(st, mine))))   -- implies the snapshot
    -- now flood it with fresh derivations, all newer than `mine`
    for _ = 1, T.CAP + 10 do
        assert(T.record(st, 'element', tmpl3(),
            { why = 'derived', redo = function () return tmpl3() end }))
    end
    local rec = select(1, T.get(st, mine))
    ok(rec, 'the oldest template survived because it was frozen')
    eq(false, rec.living)
    eq(2, #rec.edits, 'the implied snapshot and the pin, both recorded')
    eq('snapshot', rec.edits[1].op)
    eq(true, rec.edits[1].implied, 'and it says the freeze was edit-implied')
    ok(T.pressure(st).snapshots >= 1)
end)

-- ★ THE THIRD EVICTION CATEGORY IS GONE, and this is the test that would have
-- caught it coming back. The first cut also had a LOSSY tier — neither edited
-- nor re-derivable. Under decision 5 that state cannot exist: no `redo` means it
-- cannot be living, so `record` freezes it, so it is never a candidate. A
-- template recorded WITHOUT a redo must therefore survive any amount of churn.
test('templates: a template with no redo is frozen at record, so it survives churn', function ()
    if not ready() then return skip 'no lua parser' end
    local st = fresh()
    local norehydrate = assert(T.record(st, 'element', tmpl3(), { why = 'no redo recorded' }))
    eq(false, (select(1, T.get(st, norehydrate))).living, 'frozen, because it cannot follow')
    for _ = 1, T.CAP + 5 do
        assert(T.record(st, 'element', tmpl3(),
            { why = 'derived', redo = function () return tmpl3() end }))
    end
    ok(select(1, T.get(st, norehydrate)), 'and the un-recoverable one is still held')
end)

-- ⚠ ENFORCED AT THE BOUNDARY, not assumed: asking for a living template with no
-- way to re-derive it would store a record whose body nothing can produce.
test('templates: a living template without a redo is refused', function ()
    if not ready() then return skip 'no lua parser' end
    local st = fresh()
    local id, err = T.record(st, 'element', tmpl3(), { why = 'x', living = true })
    eq(nil, id)
    ok(err and err:find 'origin.redo', tostring(err))
end)

-- ⚠ IF EVERYTHING IS AUTHORED THE CAP IS EXCEEDED ON PURPOSE. Dropping a human's
-- edited template to satisfy a number is the loss this policy exists to prevent.
test('templates: an all-SNAPSHOT store exceeds the cap rather than lose work', function ()
    if not ready() then return skip 'no lua parser' end
    local st = fresh()
    for _ = 1, T.CAP + 5 do
        assert(T.record(st, 'element', tmpl3(), { why = 'authored', snapshot = true }))
    end
    local p = T.pressure(st)
    eq(T.CAP + 5, p.kept, 'over the cap, deliberately')
    eq(0, p.evicted, 'because every candidate was a snapshot')
    eq(T.CAP + 5, p.snapshots, 'and pressure REPORTS it instead of acting')
end)

-- ★ A DROPPED HANDLE MUST NOT READ LIKE ONE THAT NEVER EXISTED — the caller's
-- next move differs: re-record, versus you asked for the wrong thing.
test('templates: after an eviction, an unknown handle says the cap dropped some', function ()
    if not ready() then return skip 'no lua parser' end
    local st = fresh()
    for _ = 1, T.CAP + 3 do
        assert(T.record(st, 'element', tmpl3(),
            { why = 'derived', redo = function () return tmpl3() end }))
    end
    local rec, state, err = T.get(st, 't1')
    eq(nil, rec); eq(nil, state)
    ok(err and err:find 'evicted', 'the refusal discloses the cap: ' .. tostring(err))
    ok(err and err:find 'never evicted', 'and says authored ones are safe')
end)

-- ⚠ `seq` KEEPS COUNTING PAST THE CAP, so a 1..seq walk would cost the session's
-- total recoveries rather than what is held — the cap would bound memory but not
-- the walk.
test('templates: list walks what is HELD, not the session total', function ()
    if not ready() then return skip 'no lua parser' end
    local st = fresh()
    for _ = 1, T.CAP + 40 do
        assert(T.record(st, 'element', tmpl3(),
            { why = 'derived', redo = function () return tmpl3() end }))
    end
    eq(T.CAP, #T.list(st))
    ok(st._templates.seq > T.CAP, 'while seq has counted every recovery')
end)

-- ⚠⚠ THE INVARIANT THE ALL-AUTHORED CASE EXPOSED: `record` MUST NEVER RETURN A
-- DEAD HANDLE. Before the fix the cap ate the row it was called about — with the
-- store full of authored (never-evictable) templates, the only candidate left
-- was the brand-new unedited one, so `record` handed back an id `get` could not
-- find. A cap that can eat its own return value is worse than no cap.
test('templates: record never returns a handle the cap immediately ate', function ()
    if not ready() then return skip 'no lua parser' end
    local st = fresh()
    for _ = 1, T.CAP do
        assert(T.record(st, 'element', tmpl3(), { why = 'authored', snapshot = true }))
    end
    -- the store is now full of un-evictable templates; the next record is the
    -- only candidate the cap could pick
    local fresh_id = assert(T.record(st, 'element', tmpl3(), { why = 'the newest' }))
    ok(select(1, T.get(st, fresh_id)), 'and it is still there: ' .. tostring(fresh_id))
end)

-- ── living templates: the template FOLLOWS its source (decision 5) ──────────

-- ★★★ USER: "I think living templates could be a thing and the act of
-- snapshotting would be authoring it." The mechanism, not the label: a living
-- template must actually RE-DERIVE when the source moves, and every read must
-- say which state it reflects.
test('templates: a living template re-derives when its key moves', function ()
    if not ready() then return skip 'no lua parser' end
    local st = fresh()
    local members = 3
    local id = assert(T.record(st, 'element', tmpl3(), {
        why = 'follows the container',
        redo = function ()
            local src = members == 3 and "local T = { 'x', 'y', 'z' }" or "local T = { 'x', 'y' }"
            return clones.element_template(container_of(src))
        end,
    }))
    local b1, at1 = T.body(st, id)
    eq(3, b1.n)

    members = 2                 -- the code changed
    st.generation = 2           -- and the graph noticed (no file => generation is the key)
    local b2, at2 = T.body(st, id)
    eq(2, b2.n, 'the living template followed the source')
    ok(at1 ~= at2, 'and each read says which state it reflects: ' .. at1 .. ' -> ' .. at2)
end)

-- ⚠ CACHED WHILE THE KEY IS STABLE, or a living template re-parses on every
-- read. This is validity.memo's shape, and the counter proves the cache is real.
test('templates: a living read is cached until the key actually moves', function ()
    if not ready() then return skip 'no lua parser' end
    local st = fresh()
    local calls = 0
    local id = assert(T.record(st, 'element', tmpl3(), {
        why = 'counts its own derivations',
        redo = function () calls = calls + 1; return tmpl3() end,
    }))
    local before = calls
    T.body(st, id); T.body(st, id); T.body(st, id)
    eq(before, calls, 'three reads, no re-derivation')
    st.generation = 5
    T.body(st, id)
    eq(before + 1, calls, 'and exactly one when the key moved')
end)

-- ★★ SNAPSHOTTING IS THE ACT OF AUTHORING IT, and the record says whether a
-- human asked or an edit forced it.
test('templates: snapshot freezes a living template and records the moment', function ()
    if not ready() then return skip 'no lua parser' end
    local st = fresh()
    local id = assert(T.record(st, 'element', tmpl3(),
        { why = 'living', redo = function () return tmpl3() end }))
    eq('living', select(2, T.get(st, id)))
    assert(T.snapshot(st, id))
    local rec, state = T.get(st, id)
    eq(false, rec.living)
    ok(state ~= 'living', 'it now has a warrant that can go stale: ' .. tostring(state))
    eq('snapshot', rec.edits[1].op)
    eq(true, rec.authored_at.deliberate, 'a human asked for this one')
    ok(rec.authored_at.key, 'and it names the key it was frozen against')
end)

test('templates: snapshotting twice is a no-op, not a second authoring', function ()
    if not ready() then return skip 'no lua parser' end
    local st = fresh()
    local id = assert(T.record(st, 'element', tmpl3(),
        { why = 'living', redo = function () return tmpl3() end }))
    assert(T.snapshot(st, id))
    assert(T.snapshot(st, id))
    eq(1, #(select(1, T.get(st, id))).edits)
end)

-- ⚠ A LIVING TEMPLATE WHOSE SOURCE STOPS YIELDING ONE KEEPS ITS LAST GOOD BODY
-- AND SAYS SO. Dropping to nil would make it vanish the moment its container is
-- edited into a non-template — the "die with its source" failure decision 2
-- exists to prevent.
test('templates: a living template survives its source ceasing to yield', function ()
    if not ready() then return skip 'no lua parser' end
    local st = fresh()
    local broken = false
    local id = assert(T.record(st, 'element', tmpl3(), {
        why = 'living',
        redo = function ()
            if broken then return nil, 'the container is no longer a template' end
            return tmpl3()
        end,
    }))
    eq(3, (T.body(st, id)).n)
    broken = true
    st.generation = 3
    local body, _, why = T.body(st, id)
    ok(body, 'the last good body is still there')
    eq(3, body.n)
    ok(why and why:find 'no longer yields', 'and the read says what happened: ' .. tostring(why))
end)

-- ★ AND APPLY STILL ANSWERS on that last-good body, flagged — the same
-- outlives-its-source rule, one layer up.
test('templates: apply on a living template reports which state it matched', function ()
    if not ready() then return skip 'no lua parser' end
    local st = fresh()
    local id = assert(T.record(st, 'element', tmpl3(),
        { why = 'living', redo = function () return tmpl3() end }))
    local m = T.apply(st, id, container_of("local U = { 'q' }").kids[1])
    ok(m and m.ok, 'the match is answered')
    ok(m.derived_at, 'and says which state of the source it used: ' .. tostring(m.derived_at))
end)
