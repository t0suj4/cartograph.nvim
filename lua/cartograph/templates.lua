-- templates.lua — A RECOVERED TEMPLATE, AS A THING YOU CAN HOLD (CART-0698).
--
-- USER (2026-09-02): "I like the part that we can also produce the template,
-- because then that can be a thing we modify."
--
-- It was already produced, as data, and then thrown away. `clones.analyze_pair`
-- computes one parameter per distinct varying leaf, each carrying every
-- occurrence's range; `clones.element_template` computes a donor plus the
-- positions its members already vary at. Both were then formatted into strings
-- (`extract_proposal`) or consumed once and dropped. No identity, no storage,
-- nothing to modify, nothing to apply twice.
--
-- ★★ WHY THIS IS NOT A CACHE, AND THE DISTINCTION IS THE WHOLE MODULE.
-- Persisting a derivation to avoid recomputing it is a cache; `validity.lua`
-- already owns that discipline. What a STORED template buys is different: a
-- template you cannot point at cannot be CORRECTED. If the mining
-- over-generalises — a hole wider than it should be, two holes that are really
-- one — there is nothing to narrow. Storing it turns the template into A CLAIM,
-- which is the only form that can be WRONG IN A USEFUL WAY. So this module's
-- centre of gravity is `M.reverify` and the edit verbs, not `M.record`.
--
-- ── FOUR DECISIONS, EACH WITH ITS ALTERNATIVE ───────────────────────────────
--
-- 1. A HANDLE, NOT A CONTENT HASH. A content-derived id changes on every edit,
--    which breaks every reference the moment the user does the thing this
--    ticket exists to enable. Same reasoning as a plan handle.
--
-- 2. ★★★ A TEMPLATE OUTLIVES ITS SOURCE, AND PROVENANCE IS THE MOST WE MAY SAY.
--    USER (2026-09-09): "I expected that creating a template needs to outlive
--    its source, unless it's temporary, the best we can do is probably recording
--    provenance."
--    `findings.lua` and plan handles die with the generation they were computed
--    against, and that rule is right for a pure derivation. ⚠ IT IS WRONG HERE
--    TWICE OVER: an EDITED template is authored, not derived, so dropping it on
--    the next graph change deletes the user's work — and even an unedited one is
--    a claim ABOUT a shape, not a view OF a file.
--    ⚠⚠ MY FIRST CUT REFUSED `apply` ON A STALE ORIGIN, AND THAT WAS WRONG ON
--    THE FACTS rather than merely strict: `clones.match` compares IR to IR and
--    touches NO FILE AND NO STORE (checked across its whole body). Matching does
--    not depend on the source still existing, so refusing made the template die
--    with its source — exactly what it must not do. It was an assumed dependency
--    I never checked: "ask the accessor, not the container", in its usual
--    disguise.
--    ⇒ SO PROVENANCE IS RECORDED, NOT ENFORCED. `M.provenance` reports what
--    moved; `M.license` grades it `act` or `flag` — NEVER `nothing`, because no
--    state of the source can invalidate the template. That mirrors
--    `tier.licenses`: an UPPER BOUND a consumer may only weaken.
--    ★ WHERE THE SOURCE GENUINELY MATTERS IS RENDERING, and `clones.render`
--    already takes `donor_src` as an ARGUMENT — the caller supplies the text, so
--    the honest guard is a stamp it can CHECK against, which is why one is
--    recorded here. A gate in this module would have been in the wrong place.
--
-- 2b. AND A STAMP OUTRANKS THE GENERATION. `store.generation` bumps on any
--    ingest anywhere in the session; a file stamp is about THIS file. So a
--    template whose source is byte-identical reads LIVE even after a re-ingest —
--    `validity.lua`'s own doctrine: use a stamp "whenever a stamp is available:
--    it is precise, and it survives across epochs". The generation is the
--    FALLBACK, for a template that recorded no file.
--
-- 3. NOT BAND_TRANSIENT, DELIBERATELY, AND THIS IS THE OPPOSITE DEFAULT FROM
--    CART-0822. Ten caches were re-homed into `store.BAND_TRANSIENT` because a
--    cache must not survive a band swap — it rebuilds. A template must: it is a
--    claim about ONE band's tree, and losing an edited one on a swap is data
--    loss, not staleness. `store.capture()` copies every field that is neither
--    SESSION_GLOBAL nor BAND_TRANSIENT, so leaving `_templates` unregistered is
--    the CORRECT registration — recorded here because "unregistered" and
--    "nobody decided" render identically in a diff.
--
-- 4. TWO PRODUCERS, TWO SHAPES, AND ONLY ONE IS MATCHABLE — which storage is
--    what exposed. `element_template` returns `{n, alignable, donor, holes,
--    varying, unkeyed}` and `clones.match` accepts exactly that.
--    `analyze_pair` returns `{kind, holes, insdel, drift}` and HAS NO DONOR, so
--    `match` cannot take it and `render` cannot substitute into it. This module
--    records both, declares `matchable` per shape, and REFUSES `apply` on the
--    pair shape with that reason. ⚠ It does NOT synthesise a donor from
--    `pair.a` — that would be inventing a choice the producer never made, and
--    the caller would have no way to tell it apart from a donor the miner
--    picked. Unifying the two shapes is CART-0698's follow-on, not a silent fix
--    here.
--
--    ⚠⚠ CORRECTED 2026-09-12 — THE REASONING ABOVE IS WRONG FOR HALF ITS SCOPE,
--    AND THE BEHAVIOUR IS LEFT UNCHANGED ONLY BECAUSE THE FIX IS A BUILD.
--    The external algebra corpus (`~/tools/templates`, 243 passing tests)
--    settles it BY LAW rather than by opinion: `abstract(I_a, sites(T)) = T`,
--    i.e. holes-with-sites plus EITHER instance IS the body. A donor is
--    DERIVED, never chosen — so "inventing a choice" is answered by LABELLING
--    which side it came from, and both valuations are already stored.
--    ★ I CHECKED THE SCOPE RATHER THAN ACCEPTING THE CLAIM, and it is half:
--      · kind == 'value'      — `analyze_pair`'s params carry `at_a`/`at_b` and
--        `sites_a`/`sites_b`, so the holes leg is COMPLETE and `abstract`
--        reproduces the body. THE REFUSAL HERE IS WRONG.
--      · kind == 'structural' — `anti_unify_row` emits `{kind='struct'}` for
--        differing-length lists and the loop DROPS those from params, so the
--        holes leg is INCOMPLETE and `abstract` does NOT reproduce the body.
--        THE REFUSAL HERE IS RIGHT — for a reason this decision never stated.
--        A hedge hole built from `insdel` is what would close it.
--    ⇒ SO `matchable` IS NOT A PROPERTY OF THE SHAPE, IT IS A PROPERTY OF THE
--      RESULT. Flipping it needs the value/structural split plus a labelled
--      donor side; that is CART-0856, not an edit to this comment.
--    ★ THIS IS THE SECOND TIME IN THIS MODULE that a refusal rested on AN
--      ASSUMED DEPENDENCY NOBODY CHECKED. Decision 2's was about the CONSUMER
--      (`match` needing the source to exist); this one is about the PRODUCER
--      (its return value already carrying what I said it lacked). Different
--      halves, one habit: "ask the accessor, not the container" — twice, in
--      one file, within one ticket.
--
-- ── WHAT AN EDIT MAY DO, AND WHY `open` IS BOUNDED ──────────────────────────
--
--   pin(key)   a varying position becomes FIXED — a payload differing there now
--              MISMATCHES instead of binding. Narrowing an over-general hole is
--              the correction the ticket names first.
--   open(key)  a pinned position varies again. ⚠ BOUNDED TO PREVIOUSLY-PINNED
--              KEYS: opening a position that was never a hole would need a
--              SOURCE SPAN, and a hole with no span is precisely what
--              `element_template` counts as `unkeyed` and `match` refuses on
--              ("a position cannot be told from a mismatch"). So you can undo a
--              narrowing; you cannot invent a hole where anti-unification saw
--              none. The data model refuses it, not a policy.
--
-- Both are recorded in `edits`, in order, so the current body is derivable from
-- the base and the reader can see what a human changed.
--
-- ── 5. LIVING TEMPLATES, AND SNAPSHOTTING IS THE ACT OF AUTHORING ──────────
--
-- USER (2026-09-09): "I think living templates could be a thing and the act of
-- snapshotting would be authoring it."
--
-- ⚠ MY FIRST CUT SNAPSHOTTED ON EVERY `record`, which made the frozen copy an
-- accident of when you happened to recover the template. A template that FOLLOWS
-- its source is the cheaper and more useful default; freezing it is a DECISION.
--
-- ★★★ AND IT IS [[cartograph-declared-properties]] ARRIVING AT TEMPLATES —
-- second application of a banked mechanism, not a new one. That design is
-- already "a snapshot is a tiered, stamp-keyed CLAIM ... a human ratified an
-- inferred property at time T against source stamp S", and it insists that
-- "SELECTIVELY is doing real work in the user's sentence". Snapshotting a
-- template is that, one subject over.
--
--   LIVING     no frozen copy. Re-derives through `origin.redo`, KEYED ON THE
--              SOURCE STAMP (falling back to the generation when no file was
--              recorded), so a read is cached until the source actually moves.
--              Requires `redo` — a template that cannot re-derive cannot follow
--              anything, and `record` refuses the combination rather than
--              storing an incoherent one.
--   SNAPSHOT   frozen at a named moment, with `authored_at` recording the key it
--              was frozen against and whether the freeze was DELIBERATE or
--              IMPLIED BY AN EDIT.
--
-- ★ EVERY READ SAYS WHICH STATE OF THE SOURCE IT REFLECTS (`derived_at`).
-- Without that, two reads straddling an edit return different bodies under one
-- handle and nothing says which — the same accessor-with-two-answers shape that
-- CART-0822's band collision was.
--
-- ★★ AN EDIT IMPLIES A SNAPSHOT, because editing a view is incoherent: the next
-- re-derive would overwrite it. `pin`/`open` therefore freeze first and record
-- `{ op = 'snapshot', implied = true }` as the first edit, so the authoring
-- moment is visible rather than a side effect.
--
-- ★★ AND IT INVERTS WHICH STATE CARRIES THE STALENESS WORRY, which is worth
-- saying because it is the opposite of what my first cut assumed: LIVING + apply
-- is the FRESH path (the bindings' spans point into the current source), and
-- SNAPSHOT + apply is the one that can be stale. Per declared-properties a stale
-- snapshot DEGRADES rather than refusing — "stale = noisy but sound, never
-- silently believed" — which is exactly what `M.license` already does (`flag`,
-- never `nothing`), so nothing there needed changing.
--
-- ── 6. THE CAP, AND WHY IT EVICTS BY RE-DERIVABILITY ────────────────────────
--
-- USER (2026-09-09): "Recording state might be interesting, but I feel like we
-- might hit the prometheus cardinality thing if we do it indiscriminately."
--
-- Right, and the first cut of this module was the failure: `seq` grew without
-- bound and `by_id` kept everything, so a session that recovers templates while
-- the tree churns accumulates them forever.
--
-- ★★ HIGH CARDINALITY IS A KEY THAT CANNOT REFUSE, which is a defect this
-- codebase already knows under another name: `clones.lua` records that "a
-- predicate that fires on every shape has stopped being a predicate", and
-- [[cartograph-relation-descriptions]] states the law as THE KEY MUST BE ABLE TO
-- REFUSE. A per-instant key partitions everything into singletons and
-- discriminates nothing — the same failure, on the storage axis.
--
-- The house answer is CAP WHAT YOU KEEP, COUNT WHAT YOU SAW, DISCLOSE THE CAP
-- WHERE THE READER IS — shipped in three places already:
--   providers/tokens.lua  MAX_AT = 8 occurrences per edge; `e.atn` is the TRUTH
--   agent.lua             refusals publish `candidates` (saw) AND
--                         `candidates_kept` (kept) — CART-0682 cost a session to
--                         one refusal having two published widths
--   agent.lua             PLAN_CAP = 16, and the unknown-handle refusal SAYS
--                         "only the %d most recent are kept"
--
-- ⚠ BUT A PLAIN LRU IS WRONG HERE, and for the same reason decision 3 refused
-- BAND_TRANSIENT: evicting a SNAPSHOT is DATA LOSS, not staleness. So eviction
-- follows decision 5's split exactly:
--   · a SNAPSHOT is authored — never evicted by the cap
--   · a LIVING template is evictable, because `redo` recovers it exactly
-- ★ THE THIRD CATEGORY IS GONE. The first cut also counted a `lossy` eviction —
-- a template with neither edits nor `redo`. Under decision 5 that state cannot
-- exist: no `redo` means it cannot be living, so `record` snapshots it, so it is
-- never an eviction candidate. `lossy` could therefore never move, and a counter
-- that cannot move is a fence that never fires
-- ([[cartograph-spec-audit]]'s fifth form) — so it was removed rather than kept
-- as decoration.
-- `M.pressure` publishes (kept, snapshots, living, evicted) so the cap is never
-- silent — a dropped handle must not read like one that never existed.

local validity = require 'cartograph.validity'

local M = {}

--- The declared producer roster. A shape absent from here cannot be recorded —
--- the same rule findings.CENSUSES states, for the same reason: `matchable` is
--- computed against THIS, so an unlisted shape would be stored with no answer
--- to "can this be applied?".
M.SHAPES = {
    element = {
        matchable = true,
        producer = 'clones.element_template',
        why = 'a donor plus the positions its members already vary at',
    },
    -- ★★★ THE HIGHER-ORDER SHAPE (CART-0698 / hoau absorption). Its holes carry
    -- the LOCALS THEY DEPEND ON, so it is the only recorded shape that names a
    -- helper SIGNATURE rather than a hole count.
    higher_order = {
        matchable = false,
        producer = 'hotemplate.of_pair',
        -- ⚠ NOT MATCHABLE FOR THE SAME REASON AS `pair`, AND ONE MORE. It names
        -- no donor; and even given one, `clones.match` binds VALUES, while a
        -- dependent hole binds a FUNCTION of the instance's own locals — which
        -- the first-order matcher has no representation for. Recording that
        -- distinction is the point: `matchable = false` here is a statement
        -- about the MATCHER's vocabulary, not about this template's quality.
        why = 'holes over the function\'s own locals — match() binds values, and a '
            .. 'dependent hole is a function of bindings the payload has not made yet',
    },
    pair = {
        matchable = false,
        producer = 'clones.analyze_pair',
        -- ⚠ THE REASON IS THE POINT, not a TODO: the shape carries located holes
        -- but names no donor, and `match`/`render` both require one. Reported so
        -- a caller learns WHY it cannot apply, rather than that it failed.
        why = 'located holes but no donor — match() and render() both need one',
    },
}

-- ── the store ───────────────────────────────────────────────────────────────

--- How many templates one band keeps. Deliberately small: a template is
--- something a human is working with, not a log. The cap exists so a churning
--- tree cannot grow this without bound — see decision 5.
M.CAP = 32

local function bag(store)
    store._templates = store._templates or { seq = 0, by_id = {}, evicted = 0 }
    return store._templates
end

--- The key a LIVING template's derivation is cached under: the source's current
--- stamp when a file was recorded, else the graph generation. ⚠ THE STAMP IS
--- PREFERRED FOR THE SAME REASON AS IN `M.provenance` (decision 2b) — the
--- generation churns on any ingest, the stamp is about this file.
local function live_key(store, rec)
    local o = rec.origin
    if o.file then return 'stamp:' .. tostring(M.stamp(o.file) or 'gone') end
    return 'gen:' .. tostring(store.generation or 0)
end

--- What the cap has cost, so it is never silent. A handle dropped by the cap
--- must not read like one that never existed, which is why `evicted` is counted
--- and `M.get`'s refusal mentions it.
---@return table { kept, snapshots, living, evicted, cap }
function M.pressure(store)
    local b = bag(store)
    local kept, snaps, living = 0, 0, 0
    for _, rec in pairs(b.by_id) do
        kept = kept + 1
        if rec.living then living = living + 1 else snaps = snaps + 1 end
    end
    return { kept = kept, snapshots = snaps, living = living,
        evicted = b.evicted or 0, cap = M.CAP }
end

--- Enforce the cap. ⚠ EVICTS LIVING TEMPLATES ONLY (decision 6): a SNAPSHOT is
--- authored and never dropped; a living one is recovered exactly by `redo`.
--- ⚠⚠ `keep` IS THE HANDLE JUST CREATED, AND EXEMPTING IT IS AN INVARIANT, NOT
--- A TUNING CHOICE: `record` MUST NEVER RETURN A DEAD HANDLE. Without this the
--- cap ate the row it was called about — once the store filled with SNAPSHOTS
--- (which are never evictable) the only candidate left was the brand-new living
--- one, so `record` returned an id that `get` could not find. Caught by the
--- all-snapshots spec, which is why that case is a test and not a footnote.
local function enforce_cap(b, keep)
    local live = {}
    for _, rec in pairs(b.by_id) do live[#live + 1] = rec end
    if #live <= M.CAP then return end
    local cand = {}
    for _, rec in ipairs(live) do
        if rec.living and rec.id ~= keep then cand[#cand + 1] = rec end
    end
    table.sort(cand, function (x, y) return x.seq < y.seq end)   -- oldest first
    local over = #live - M.CAP
    for i = 1, math.min(over, #cand) do
        b.by_id[cand[i].id] = nil
        b.evicted = (b.evicted or 0) + 1
    end
    -- ⚠ IF EVERY TEMPLATE IS A SNAPSHOT THE CAP IS EXCEEDED ON PURPOSE. Dropping
    -- a human's authored template to satisfy a number would be the data loss
    -- this policy exists to prevent; `M.pressure` reports it instead.
end

--- Deep-copy the parts of a template we own. The donor and hole `at` spans are
--- shared by reference on purpose: they are immutable expr-IR nodes, and copying
--- an IR subtree would make the stored donor a DIFFERENT node from the one the
--- producer located, which is the bug `varying`'s span keys exist to avoid.
local function copy_body(t)
    local out = { n = t.n, alignable = t.alignable, unkeyed = t.unkeyed,
        donor = t.donor, kind = t.kind, insdel = t.insdel }
    -- ★★★ THE HIGHER-ORDER SHAPE'S OWN FIELDS. ⚠ THIS FUNCTION IS A WHITELIST,
    -- so a shape whose fields are absent from it is stored HOLLOW and SILENTLY:
    -- `record` succeeds, the handle resolves, and every read returns a body with
    -- nothing in it. A third shape had to either extend this list or be a
    -- uniform zero, and a uniform zero reads as a clean answer
    -- ([[ask-the-accessor-not-the-container]]).
    out.result = t.result
    out.signature = t.signature
    out.subject = t.subject
    out.renaming = t.renaming
    out.rows = t.rows
    out.pattern = t.pattern
    out.rebuild = t.rebuild
    out.holes = t.holes
    out.drift = t.drift
    out.varying = {}
    for k, v in pairs(t.varying or {}) do out.varying[k] = v end
    out.pinned = {}
    for k, v in pairs(t.pinned or {}) do out.pinned[k] = v end
    return out
end

--- Record a recovered template and return a handle.
---@param store table
---@param shape string   a key of M.SHAPES
---@param tmpl table     the producer's result
---@param origin table   { subject = <what it was recovered from>, why = string,
---                        redo = function(store) -> tmpl|nil, string  (optional) }
---@return string|nil id, string|nil err
function M.record(store, shape, tmpl, origin)
    local sh = M.SHAPES[shape]
    if not sh then
        return nil, ('unknown template shape %q — add it to templates.SHAPES in the '
            .. 'same change that produces it, or `matchable` has no answer')
            :format(tostring(shape))
    end
    if type(tmpl) ~= 'table' then return nil, 'a template must be a table' end
    if shape == 'element' and not tmpl.donor then
        -- the element shape's own contract; a donorless element result is the
        -- `alignable = false` answer, which is a first-class ANSWER and not a
        -- template. Storing it would put a non-template behind a handle.
        return nil, 'this element result has no donor (' ..
            tostring(tmpl.why or 'not alignable') .. ') — that is an answer, not a template'
    end
    if type(origin) ~= 'table' or type(origin.why) ~= 'string' then
        -- ⚠ PROVENANCE IS MANDATORY. A template with no recorded origin cannot
        -- go stale, cannot be reverified, and reads as authored when it was
        -- mined. The whole body/warrant split above depends on this field.
        return nil, 'origin.why is required — a template with no provenance cannot go stale'
    end
    -- ★★ LIVING IS THE DEFAULT WHEN IT IS POSSIBLE (decision 5): a template that
    -- can re-derive should FOLLOW its source, and freezing is a decision. A
    -- caller may force a snapshot with `origin.snapshot = true`.
    local living = origin.redo ~= nil and not origin.snapshot
    if origin.living and not origin.redo then
        -- ⚠ ENFORCED AT THE BOUNDARY, not assumed: a template that cannot
        -- re-derive cannot follow anything, and storing one as "living" would
        -- create a record whose body nothing can produce.
        return nil, 'a living template needs origin.redo — without it there is '
            .. 'nothing to follow the source with'
    end
    local b = bag(store)
    b.seq = b.seq + 1
    local id = ('t%d'):format(b.seq)
    b.by_id[id] = {
        id = id,
        seq = b.seq,                 -- insertion order, for the cap's tie-break
        shape = shape,
        living = living,
        -- a SNAPSHOT freezes both now; a LIVING one holds neither and derives
        -- through `cache`, so there is no frozen copy to go quietly stale.
        base = not living and copy_body(tmpl) or nil,
        body = not living and copy_body(tmpl) or nil,
        -- ★ SEEDED UNDER THE CURRENT KEY. `record` already holds the
        -- derivation, so leaving the key nil made every living template
        -- re-derive once on its first read — measured by the cache spec, which
        -- counts redo calls rather than trusting the field.
        cache = living and { key = nil, body = copy_body(tmpl) } or nil,
        authored_at = not living
            and { key = origin.stamp or ('gen:' .. tostring(store.generation or 0)),
                  deliberate = true } or nil,
        edits = {},
        origin = {
            subject = origin.subject,
            why = origin.why,
            redo = origin.redo,
            -- ★ THE DURABLE HALF. `file` + `stamp` are supplied by the caller
            -- (see M.stamp) rather than computed here, so this module stays
            -- plain Lua — the same discipline clones.lua keeps, for the same
            -- reason: the headless fold and sharded-index flows load it.
            file = origin.file,
            stamp = origin.stamp,
            generation = store.generation or 0,
            epoch = validity.epoch('extract'),
        },
    }
    if living then b.by_id[id].cache.key = live_key(store, b.by_id[id]) end
    enforce_cap(b, id)
    return id
end

--- The current stamp of a path, or nil. Lazily requires transport so the rest of
--- this module needs no cartograph module and no `vim.*`.
function M.stamp(path)
    if not path then return nil end
    local ok, transport = pcall(require, 'cartograph.transport')
    if not ok then return nil end
    return (transport.stamp(path))
end

--- What has moved under this template. Reports; never gates — see decision 2.
---@return table|nil prov  { source, generation, license, why }, or nil + err
---@return string|nil err
--- ⚠ A DROPPED HANDLE MUST NOT READ LIKE ONE THAT NEVER EXISTED — the same
--- distinction findings.lua draws between a RESULT and UNAVAILABLE. If the cap
--- has evicted anything this session, say so, because the caller's next move
--- differs: re-record versus you-asked-for-the-wrong-thing.
local function no_such(store, id)
    local b = bag(store)
    if (b.evicted or 0) > 0 then
        return ('no template %s — %d handle(s) have been evicted by the cap of %d '
            .. 'this session (re-record it; authored templates are never evicted)')
            :format(tostring(id), b.evicted, M.CAP)
    end
    return ('no template %s'):format(tostring(id))
end

--- The body to read, and WHICH STATE OF THE SOURCE IT REFLECTS.
--- ★ A snapshot returns its frozen body. A LIVING template re-derives when the
--- key has moved and caches otherwise — the `validity.memo` shape, inline
--- because the cache lives on the record rather than in a module upvalue
--- (decision 3: a module upvalue is invisible to store.capture()).
--- ⚠ EVERY CALLER GETS `derived_at` BACK. Two reads straddling an edit return
--- different bodies under one handle, and nothing saying which state each
--- reflects is the accessor-with-two-answers shape CART-0822 was.
---@return table|nil body
---@return string derived_at
---@return string|nil why   set when a living re-derivation failed
local function current_body(store, rec)
    if not rec.living then
        return rec.body, (rec.authored_at and rec.authored_at.key) or 'frozen'
    end
    local key = live_key(store, rec)
    local c = rec.cache
    if c and c.key == key and c.body then return c.body, key end
    local fresh, why = rec.origin.redo(store)
    if type(fresh) ~= 'table' then
        -- ⚠ KEEP THE LAST GOOD BODY AND SAY THE SOURCE STOPPED YIELDING ONE.
        -- Dropping to nil would make a living template vanish the moment its
        -- container is edited into a non-template, which is the "die with its
        -- source" failure decision 2 exists to prevent.
        return (c and c.body or nil), key,
            ('the source no longer yields a template: %s'):format(tostring(why or 'no result'))
    end
    rec.cache = { key = key, body = copy_body(fresh) }
    return rec.cache.body, key
end

--- Freeze a living template: THE ACT OF AUTHORING IT (decision 5).
--- `implied` marks a freeze forced by an edit rather than asked for.
---@return table|nil rec, string|nil err
function M.snapshot(store, id, implied)
    local rec = bag(store).by_id[id]
    if not rec then return nil, no_such(store, id) end
    if not rec.living then
        return rec, nil   -- already authored; snapshotting twice is a no-op
    end
    local body, key, why = current_body(store, rec)
    if not body then
        return nil, ('nothing to snapshot: %s'):format(tostring(why or 'no body'))
    end
    rec.living = false
    rec.base = copy_body(body)     -- what the source said at the frozen moment
    rec.body = copy_body(body)     -- base + edits from here on
    rec.cache = nil
    rec.authored_at = { key = key, deliberate = not implied }
    -- ★ THE AUTHORING MOMENT IS AN EDIT ROW, not a side effect, so the record
    -- shows when it happened and whether a human asked for it.
    rec.edits[#rec.edits + 1] = { op = 'snapshot', implied = implied or nil }
    return rec
end

function M.provenance(store, id)
    local rec = bag(store).by_id[id]
    if not rec then return nil, no_such(store, id) end
    local o = rec.origin
    -- SOURCE: the precise axis, when a stamp was recorded.
    local source, now = 'unstamped', nil
    if o.stamp and o.file then
        now = M.stamp(o.file)
        if now == nil then source = 'gone'
        elseif now == o.stamp then source = 'same'
        else source = 'moved' end
    end
    local generation = (o.generation == (store.generation or 0)) and 'same' or 'moved'
    -- ★★ A STAMP OUTRANKS THE GENERATION (decision 2b): the generation bumps on
    -- any ingest in the session, the stamp is about THIS file. Only when no
    -- stamp was recorded does the coarse counter get a vote.
    local live
    if source == 'unstamped' then live = generation == 'same'
    else live = source == 'same' end
    return {
        source = source,
        generation = generation,
        -- ⚠ NEVER 'nothing'. No state of the source can invalidate a template,
        -- so the strongest this may say is "act on it, but say what moved".
        license = live and 'act' or 'flag',
        why = live and 'the template\'s origin is intact'
            or ('recorded from %s (source %s, generation %s)')
                :format(tostring(o.file or 'no file'), source, generation),
    }
end

--- Read a template back with the state of its WARRANT.
--- ⚠ `state` is a SUMMARY for display. It licenses nothing — `M.provenance`
--- carries the axes and `M.license` the bound.
---@return table|nil rec
---@return string|nil state  'live' | 'stale-origin'
---@return string|nil err
--- ⚠ A LIVING TEMPLATE IS ALWAYS 'live': it follows the source, so there is no
--- frozen copy to have gone stale. `state` is meaningful for a SNAPSHOT, which
--- is the inversion decision 5 records.
---@return table|nil rec
---@return string|nil state  'living' | 'live' | 'stale-origin'
---@return string|nil err
function M.get(store, id)
    local rec = bag(store).by_id[id]
    if not rec then return nil, nil, no_such(store, id) end
    if rec.living then return rec, 'living' end
    local prov = M.provenance(store, id)
    return rec, prov.license == 'act' and 'live' or 'stale-origin'
end

--- The body to read plus which state of the source it reflects. The read verb a
--- caller should use — `rec.body` is nil on a living template by construction.
---@return table|nil body, string|nil derived_at, string|nil why
function M.body(store, id)
    local rec = bag(store).by_id[id]
    if not rec then return nil, nil, no_such(store, id) end
    return current_body(store, rec)
end

--- The bound a consumer may only WEAKEN: 'act' | 'flag'. Never 'nothing'.
function M.license(store, id)
    local prov, err = M.provenance(store, id)
    if not prov then return nil, err end
    return prov.license, prov.why
end

--- How many positions this template currently varies at. ⚠ NO `vim.*` in this
--- module — it is plain Lua for the same reason clones.lua is (the sharded-index
--- and fold flows load it headless), and `vim.tbl_count` was the one reference.
local function nvarying(body)
    local n = 0
    for _ in pairs(body.varying or {}) do n = n + 1 end
    -- ★ THE HIGHER-ORDER SHAPE HAS NO `varying` MAP — its holes are a LIST, and
    -- they have no source span to key one by (a hole is a λ-abstraction over the
    -- function's binders, not a position in a donor). Without this a recorded
    -- higher-order template reports `holes = 0` in `M.list`, which is the
    -- degenerate answer this codebase keeps mistaking for a real one.
    -- ⚠ GATED ON `signature`, WHICH ONLY THIS SHAPE CARRIES, so the `pair`
    -- shape's count is left exactly as it was rather than changed in passing.
    if n == 0 and body.signature then return #(body.holes or {}) end
    return n
end

--- Every handle, newest last, with each one's warrant state.
--- ⚠ ITERATES `by_id`, NOT 1..seq. `seq` keeps counting after the cap starts
--- evicting, so walking it would cost the SESSION's total recoveries rather than
--- the ones still held — the cap would bound memory and not the walk.
function M.list(store)
    local b, out = bag(store), {}
    for _, rec in pairs(b.by_id) do
        local _, state = M.get(store, rec.id)
        local body = current_body(store, rec)
        out[#out + 1] = { id = rec.id, seq = rec.seq, shape = rec.shape,
            state = state, living = rec.living or false, why = rec.origin.why,
            edits = #rec.edits, holes = body and nvarying(body) or 0 }
    end
    table.sort(out, function (x, y) return x.seq < y.seq end)
    return out
end

--- Drop one. Returns whether anything was there — a forget of nothing is not an
--- error, but the caller may want to know it was already gone.
function M.forget(store, id)
    local b = bag(store)
    local had = b.by_id[id] ~= nil
    b.by_id[id] = nil
    return had
end

-- ── edits: the template as a claim you can correct ──────────────────────────

--- Narrow: a varying position becomes fixed.
function M.pin(store, id, key)
    local rec, _, err = M.get(store, id)
    if not rec then return nil, err end
    -- ★★ AN EDIT IMPLIES A SNAPSHOT (decision 5): editing a view is incoherent
    -- because the next re-derive would overwrite it. Recorded as an edit row so
    -- the authoring moment is visible.
    if rec.living then
        local ok, swhy = M.snapshot(store, id, true)
        if not ok then return nil, swhy end
    end
    local v = rec.body.varying and rec.body.varying[key]
    if not v then
        return nil, ('%s is not a varying position in this template'):format(tostring(key))
    end
    rec.body.varying[key] = nil
    rec.body.pinned[key] = v
    rec.edits[#rec.edits + 1] = { op = 'pin', key = key }
    return rec
end

--- Widen: a PREVIOUSLY PINNED position varies again.
--- ⚠ Bounded by construction — see the header. A key that was never a hole has
--- no span, and a spanless hole is what `match` refuses on.
function M.open(store, id, key)
    local rec, _, err = M.get(store, id)
    if not rec then return nil, err end
    if rec.living then
        local ok, swhy = M.snapshot(store, id, true)
        if not ok then return nil, swhy end
    end
    local v = rec.body.pinned and rec.body.pinned[key]
    if not v then
        local had = rec.body.varying and rec.body.varying[key]
        if had then return nil, ('%s already varies'):format(tostring(key)) end
        return nil, ('%s was never a hole in this template, so it has no source span '
            .. '— a hole with no span is a position match() cannot tell from a '
            .. 'mismatch, so it cannot be opened'):format(tostring(key))
    end
    rec.body.pinned[key] = nil
    rec.body.varying[key] = v
    rec.edits[#rec.edits + 1] = { op = 'open', key = key }
    return rec
end

-- ── reverification: what makes a stored template falsifiable ────────────────

--- Re-derive from the same inputs and compare against the AS-RECOVERED base.
--- This is CART-0728's round-trip law at the template layer: a stored template
--- that cannot be re-derived is either a bad template or the tree drifted under
--- it, and those are different findings.
---
--- ⚠ COMPARES AGAINST `base`, NOT `body`. An edited body is SUPPOSED to differ
--- from a fresh derivation — that is what editing means — so comparing the body
--- would report every correction as drift. `edited` is returned beside the
--- verdict so a caller never reads "matches" as "the current template is what
--- the code says".
---@return table|nil result  { ok, agree, edited, why }
---@return string|nil err
function M.reverify(store, id)
    local rec, state, err = M.get(store, id)
    if not rec then return nil, err end
    if rec.living then
        -- ⚠ NOT A PASS, AND NOT A FAILURE. A living template follows its source,
        -- so "does it still re-derive" is answered by construction and carries
        -- no information. Drift is a finding only against a SNAPSHOT, which is
        -- the moment someone froze. Reporting `agree = true` here would
        -- manufacture a check nobody ran.
        return { ok = false, agree = nil, edited = false, state = state,
            why = 'a living template follows its source — nothing is frozen to '
                .. 'compare; snapshot it first if you want drift reported' }
    end
    if type(rec.origin.redo) ~= 'function' then
        -- an honest UNAVAILABLE, not a pass. Nothing was checked.
        return { ok = false, agree = nil, edited = #rec.edits > 0,
            why = 'this template recorded no `redo`, so nothing can re-derive it' }
    end
    local fresh, rwhy = rec.origin.redo(store)
    if type(fresh) ~= 'table' then
        return { ok = false, agree = false, edited = #rec.edits > 0,
            why = ('the inputs no longer yield a template: %s'):format(tostring(rwhy or 'no result')) }
    end
    local a, b = rec.base, fresh
    local diffs = {}
    if (a.alignable or false) ~= (b.alignable or false) then diffs[#diffs + 1] = 'alignable' end
    if (a.n or 0) ~= (b.n or 0) then diffs[#diffs + 1] = 'n' end
    if (a.unkeyed or 0) ~= (b.unkeyed or 0) then diffs[#diffs + 1] = 'unkeyed' end
    -- the varying SET is the template's discriminating content (M.match asks only
    -- whether a key is present), so key equality is the right comparison here.
    local akeys, bkeys = {}, {}
    for k in pairs(a.varying or {}) do akeys[k] = true end
    for k in pairs(b.varying or {}) do bkeys[k] = true end
    local missing, added = 0, 0
    for k in pairs(akeys) do if not bkeys[k] then missing = missing + 1 end end
    for k in pairs(bkeys) do if not akeys[k] then added = added + 1 end end
    if missing > 0 then diffs[#diffs + 1] = ('%d hole(s) gone'):format(missing) end
    if added > 0 then diffs[#diffs + 1] = ('%d new hole(s)'):format(added) end
    local agree = #diffs == 0
    return { ok = true, agree = agree, edited = #rec.edits > 0, state = state,
        why = agree and 'the same template re-derives from the same inputs'
            or ('re-derivation disagrees: ' .. table.concat(diffs, ', ')) }
end

-- ── application: run a held template against a candidate ────────────────────

--- Match a payload against a stored template. Refuses only on a NON-MATCHABLE
--- SHAPE (no donor); a moved or missing source does not refuse — the answer
--- carries `provenance` so the caller can flag it. See decision 2.
---@return table|nil match  the clones.match result + `provenance` and `state`
---@return string|nil why
function M.apply(store, id, payload, opts)
    local rec, state, err = M.get(store, id)
    if not rec then return nil, err end
    local sh = M.SHAPES[rec.shape]
    if not sh.matchable then
        return nil, ('a %s template cannot be applied: %s'):format(rec.shape, sh.why)
    end
    -- ⚠⚠ NO STALENESS GATE HERE, AND ITS ABSENCE IS THE DESIGN (decision 2).
    -- `clones.match` compares IR to IR — no file, no store — so a moved source
    -- cannot make a match wrong. Gating here made a template die with its
    -- source. The provenance rides ALONG with the answer instead, so a caller
    -- can flag what moved without being denied the match.
    -- ★★ THE FRESH PATH IS THE LIVING ONE, which is the opposite of what my
    -- first cut assumed: a living template re-derives, so its bindings' spans
    -- point into the CURRENT source. A SNAPSHOT is the state that can be stale —
    -- and per declared-properties a stale snapshot DEGRADES rather than
    -- refusing, which is what `M.license` already does.
    local body, derived_at, bwhy = current_body(store, rec)
    if not body then
        return nil, ('no body to match against: %s'):format(tostring(bwhy or 'unknown'))
    end
    local clones = require 'cartograph.clones'
    local m = clones.match(body, payload, opts)
    if type(m) == 'table' then
        m.provenance = M.provenance(store, id)
        m.state = state
        m.derived_at = derived_at
        m.stale_source = bwhy      -- set only when a living re-derive failed
    end
    return m
end

return M
