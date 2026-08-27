-- SHAPE MATCHING against a profile's declared CLASS TABLE (CART-0590) — a
-- QUERY, not a resolution. externals.surface already computes the shape of every
-- unresolved base (the members observed on it); a profile artifact that carries
-- the environment's full class table can be asked which classes declare all of
-- them. Exactly one → the shape DETERMINES the class. Several → an honest
-- candidate set. None → the base is not an API object at all.
--
-- ★ THIS IS NOT RECEIVER TYPING, and the distinction is the whole reason it
-- exists. Nothing here infers a type from flow — it is a SUBSET LOOKUP in a
-- declared table ([[cartograph-anonymous-types]]: you need the partition, not the
-- name). factoriodistill's header discarded 139 of 148 classes because
-- "receiver-typed methods need receiver typing (measured-negative for dynamic
-- langs)"; that verdict is a WRONG-MECHANISM death for a profile that ships a
-- declared API export ([[cartograph-revisit-killed-optimizations]]). ⚠ It says
-- NOTHING about a dynamic language with no such export, and must not be
-- generalised into one.
--
-- ── WHAT IS MEASURED, AND IT IS THE SPEC ────────────────────────────────────
-- Four Factorio 2.0 mods, 21082 calls, against the 2.0.72 export (api v6), bases
-- matching at least one class:
--     n>=1  58.2%   n>=2  88.1%   n>=3  94.9% (99.1% call-weighted)
--     n>=5  95.5% (99.6% call-weighted)
-- So AMBIGUITY IS RARE (2 of 39 at n>=3) and the interesting failure is the other
-- one: ZERO-match. 74 of 256 candidate bases (n>=1, recognized builtins excluded)
-- match nothing, and 66 of those are UNRELATED — no class comes within one member
-- of the shape while sharing anything with it. They are mod-local tables (`util`
-- 529 calls, `data` 327). Zero-match is therefore a cheap "not an API object"
-- DISCRIMINATOR and is rendered as its own outcome, never as a failure to answer.
-- Reproduced by tools/classmatch.lua on 2026-08-27, all four thresholds and all
-- three population counts identical to the recorded run — see M.unrelated for the
-- one definition that had to be pinned down to make the last of them agree.
--
-- ★ PARENT CLOSURE IS REQUIRED, verified not assumed: v6 declares `parent` on 79
-- of 148 classes and `insert` is NOT on LuaPlayer — it is on LuaControl. Without
-- the transitive closure the single most observed receiver in the corpus
-- FALSE-ZEROES. A premise that dies for the wrong reason looks exactly like one
-- that dies, so tests/classmatch_spec.lua fences this.
--
-- ── THE RUNG IS `inferred`, DELIBERATELY NOT `stdlib` ───────────────────────
-- `stdlib` means an active profile NAMES the symbol — authoritative. A shape
-- match is a UNIQUE-MATCH HYPOTHESIS, measured wrong 2/39 at n>=3 with known
-- wrongs at n=1 (`name.find` → LuaEquipmentGrid, which is really string.find;
-- `Zone.get_surface` → LuaGameScript). That is precisely tier.lua's `inferred`
-- rung ("~ unique-name hypothesis"), so every determined answer carries it plus
-- its evidence.
--
-- ★ NO THRESHOLD IS HARDCODED HERE. `n` (the observed member count) and the full
-- candidate list ride in the evidence, so a consumer thresholds for itself — the
-- two known wrongs are BOTH n=1, and a matcher that silently dropped n=1 would
-- also drop the 27-of-29 high-call n=1 answers that are right
-- (find_entities_filtered → LuaSurface). M.report shows `n` on every line and
-- marks a one-member answer as a hypothesis — a rendering a reader may disagree
-- with; the query itself does not judge.
--
-- SCOPE: read-only. Nothing here touches ref resolution, so no graph moves and no
-- cache VERSION bumps. Wiring a match into resolution is a separate and much
-- heavier decision (it would re-save every corpus).

local M = {}

--- The tier rung a determined match rides, CHECKED against the canonical ladder
--- rather than re-typed as a loose string: if `inferred` ever leaves tier.lua
--- this must fail loudly instead of labelling evidence with a rung nothing knows.
--- Reading the ladder is all this does — the ladder itself is FULL (3 packed
--- bits, 7 rungs) and adding a rung is a separate, heavier decision.
M.TIER = 'inferred'
assert(require('cartograph.tier').RANK[M.TIER],
    'classmatch: tier.lua no longer has an `' .. M.TIER .. '` rung')

--- Artifacts to consult for a class table, ACTIVE-FIRST. The unsuffixed name is
--- what spec/profile/lua-factorio.lua (the live 2.0 profile) loads, so as soon as
--- it is re-distilled it wins; today only the `-20` build carries `classes`, and
--- the meta says which one answered.
M.ARTIFACTS = { 'lua-factorio-api', 'lua-factorio-api-20', 'lua-factorio-api-11' }

-- closure cache, keyed by the artifact TABLE identity (weak, so a reloaded
-- profile does not pin the old one). The profile loader is itself stamp-keyed, so
-- an edited artifact arrives here as a different table.
local cache = setmetatable({}, { __mode = 'k' })

-- The first segment of an observed member chain. externals.split hands back the
-- WHOLE remainder of a call chain (`player.character.insert` → base `player`,
-- member `character.insert`), and what the base's own class declares is the FIRST
-- segment (`character`, an attribute). Matching the whole chain would make every
-- deep call miss, which is also why the class table carries attributes.
local function head(m) return (m:match('^([%w_]+)')) end

--- Normalize an observed shape to a SET of first-segment member names.
--- Accepts externals' `{ member -> count }` map or a plain array of names.
function M.shape(members)
    local set = {}
    if type(members) ~= 'table' then return set end
    if #members > 0 and type(members[1]) == 'string' then
        for _, m in ipairs(members) do
            local h = head(m); if h then set[h] = true end
        end
    else
        for m in pairs(members) do
            local h = head(m); if h then set[h] = true end
        end
    end
    return set
end

--- Build the CLOSED class table from an artifact/profile table.
--- Returns { classes = { [name] = { parent, own = set, all = set, depth } },
---           order = sorted names, n, n_parent, meta } or nil + reason.
--- The closure is computed HERE rather than at distill time so the artifact keeps
--- saying which class actually declares a name (an honest export), and so a
--- missing `parent` edge is visible as a bug rather than baked in.
local function build(art, artname)
    if type(art) ~= 'table' then return nil, 'no profile artifact' end
    local decl = art.classes
    if type(decl) ~= 'table' or next(decl) == nil then
        return nil, ('artifact %s carries no class table (re-run tools/factoriodistill.lua)')
            :format(artname or art.runtime or '?')
    end
    local classes, order, n_parent = {}, {}, 0
    for name, c in pairs(decl) do
        classes[name] = { parent = c.parent, own = c.members or {}, abstract = c.abstract }
        order[#order + 1] = name
        if c.parent then n_parent = n_parent + 1 end
    end
    table.sort(order)
    -- transitive closure over `parent`, with a visited guard: a cyclic or
    -- self-referential parent chain in a future export must not hang the query.
    for _, name in ipairs(order) do
        local e = classes[name]
        local all, seen, cur, depth = {}, {}, name, 0
        while cur and classes[cur] and not seen[cur] do
            seen[cur] = true
            for m in pairs(classes[cur].own) do all[m] = true end
            cur = classes[cur].parent
            depth = depth + 1
        end
        e.all, e.depth = all, depth - 1
    end
    return { classes = classes, order = order, n = #order, n_parent = n_parent,
        meta = { artifact = artname or art.runtime, version = art.version,
            api_version = art.api_version } }
end

--- The class table for a source: a loaded profile/artifact TABLE, an artifact
--- NAME, or nil = try M.ARTIFACTS in order and use the first that carries one.
--- Returns (ct) or (nil, reason). Memoized per artifact table.
function M.table(source)
    if type(source) == 'table' and source.classes then
        local hit = cache[source]
        if hit == nil then
            local ct, why = build(source, source.runtime)
            hit = ct or { err = why }
            cache[source] = hit
        end
        if hit.err then return nil, hit.err end
        return hit
    end
    local prof = require 'cartograph.spec.profile'
    local names = type(source) == 'string' and { source } or M.ARTIFACTS
    local tried = {}
    for _, name in ipairs(names) do
        local art = prof.load(name)
        if art then
            local hit = cache[art]
            if hit == nil then
                local ct, why = build(art, name)
                hit = ct or { err = why }
                cache[art] = hit
            end
            if not hit.err then return hit end
            tried[#tried + 1] = name .. ' (no class table)'
        else
            tried[#tried + 1] = name .. ' (absent)'
        end
    end
    return nil, 'no artifact carries a class table: ' .. table.concat(tried, ', ')
end

-- how many of `shape` a class DECLARES and does not, plus (up to `cap`) the names
-- it lacks
local function overlap(shape, all, cap)
    local hit, miss, names = 0, 0, {}
    for m in pairs(shape) do
        if all[m] then hit = hit + 1
        else
            miss = miss + 1
            if #names < (cap or 3) then names[#names + 1] = m end
        end
    end
    table.sort(names)
    return hit, miss, names
end

--- Is a zero-match base UNRELATED to the API — "not an API object at all" rather
--- than a near miss? THE DEFINITION IS LOAD-BEARING and it is the recorded one:
--- distance is measured only against classes that share AT LEAST ONE member, and
--- a shape that overlaps NO class is unrelated by definition.
---
--- ★ THE NAIVE DEFINITION IS WRONG AND SILENTLY SO (found reproducing the premise
--- run, 2026-08-27). Minimum-miss over ALL 148 classes calls every single-member
--- base "1 member away", because a class that shares nothing with the shape still
--- misses only that one member — so `Log{debug}` reads as a near miss of
--- LuaAISettings, which has nothing to do with it. That definition put 38 of 74
--- zero-match bases in this bucket where the recorded run had 66; the
--- overlap-restricted one reproduces 66 exactly. Same data, same matcher, a
--- metric that quietly meant something else.
function M.unrelated(ev)
    if ev.outcome ~= 'zero' then return false end
    return (not ev.overlap) or (ev.distance or 0) > 1
end

--- MATCH an observed shape against the class table.
--- `members` is externals' member map (or an array of names); `ct` is M.table().
--- Returns the EVIDENCE, always a table, never nil:
---   { outcome = 'determined' | 'ambiguous' | 'zero' | 'no-shape',
---     n          = distinct observed members (the discriminating quantity),
---     members    = sorted observed member names,
---     candidates = sorted class names that declare EVERY observed member,
---     ncand      = #candidates,
---     class      = the single candidate, when determined,
---     tier/hedge = the rung a determined answer rides, and why it is hedged,
---     nearest    = for `zero`, the closest OVERLAPPING classes and how many
---                  members away; `overlap`/`distance` say whether any class
---                  shares a member at all. "One member away" and "nothing like an
---                  API object" are different facts and the tail depends on
---                  telling them apart — M.unrelated is the predicate }
--- NO THRESHOLD: n and candidates are reported so the caller can judge.
function M.match(members, ct)
    local shape = M.shape(members)
    local names = {}
    for m in pairs(shape) do names[#names + 1] = m end
    table.sort(names)
    local ev = { n = #names, members = names, candidates = {}, ncand = 0 }
    if not ct then ev.outcome = 'no-shape'; ev.why = 'no class table available'; return ev end
    if ev.n == 0 then
        -- a base called BARE only (`foo()`), so there is no shape to match. This
        -- must not fall through to the subset test: the empty set is a subset of
        -- every class, which would "match" all 148 and read as evidence.
        ev.outcome = 'no-shape'
        ev.why = 'bare calls only'
        return ev
    end
    local best, best_names = math.huge, {}
    for _, cname in ipairs(ct.order) do
        local c = ct.classes[cname]
        local hit, miss, which = overlap(shape, c.all)
        if miss == 0 then
            ev.candidates[#ev.candidates + 1] = cname
        elseif hit > 0 then
            -- NEAREST IS MEASURED AMONG CLASSES THAT SHARE SOMETHING. A class with
            -- zero overlap is not "n members away" in any useful sense — see
            -- M.unrelated for what counting it costs.
            if miss < best then
                best, best_names = miss, { { class = cname, missing = miss,
                    names = which, shared = hit } }
            elseif miss == best and #best_names < 3 then
                best_names[#best_names + 1] = { class = cname, missing = miss,
                    names = which, shared = hit }
            end
        end
    end
    ev.ncand = #ev.candidates
    if ev.ncand == 1 then
        ev.outcome, ev.class = 'determined', ev.candidates[1]
        ev.tier = M.TIER
        ev.hedge = ('shape-unique hypothesis: %d observed member%s, exactly 1 of %d declared classes declares them all')
            :format(ev.n, ev.n == 1 and '' or 's', ct.n)
    elseif ev.ncand > 1 then
        ev.outcome = 'ambiguous'
        ev.why = ('%d classes declare this shape'):format(ev.ncand)
    else
        ev.outcome = 'zero'
        ev.nearest = best_names
        ev.overlap = best < math.huge
        ev.distance = ev.overlap and best or nil
        ev.why = ev.overlap and 'no class declares this shape'
            or 'no class shares even one member of this shape'
    end
    return ev
end

-- ── the SURFACE-wide query ──────────────────────────────────────────────────

--- Match every base of an external surface. `surf` is externals.surface(store).
--- Returns (rows, summary) or (nil, reason) when no class table is available.
--- rows are sorted by call volume (the order a reader triages in), each
---   { base, calls, bare, known, files, ev }
--- summary carries the OUTCOME census and the DISCRIMINATION table — the
--- measured numbers this feature's premise rests on, recomputed rather than
--- quoted, so a divergence from the recorded run is visible as a finding.
function M.of_surface(surf, ct, opts)
    opts = opts or {}
    local why
    if not ct then ct, why = M.table(opts.source) end
    if not ct then return nil, why end
    local rows = {}
    for base, e in pairs((surf or {}).bases or {}) do
        -- KNOWN bases (lua builtins: `table`, `string`, …) are matched too, but
        -- flagged: they are the population where a match is EXPECTED to be wrong
        -- (`name.find` is string.find), and a summary that silently mixed them
        -- would report a discrimination rate for a different population.
        local nf = 0; for _ in pairs(e.files or {}) do nf = nf + 1 end
        rows[#rows + 1] = { base = base, calls = e.calls, bare = e.bare,
            known = e.known or false, files = nf, ev = M.match(e.members, ct) }
    end
    table.sort(rows, function (x, y)
        if x.calls ~= y.calls then return x.calls > y.calls end
        return x.base < y.base
    end)
    local sum = { classes = ct.n, meta = ct.meta, bases = #rows,
        determined = 0, ambiguous = 0, zero = 0, no_shape = 0,
        calls = { determined = 0, ambiguous = 0, zero = 0, no_shape = 0 },
        zero_far = 0, known_determined = 0, buckets = {} }
    for _, r in ipairs(rows) do
        local o = r.ev.outcome:gsub('%-', '_')
        sum[o] = sum[o] + 1
        sum.calls[o] = sum.calls[o] + r.calls
        if M.unrelated(r.ev) then sum.zero_far = sum.zero_far + 1 end
        if r.ev.outcome == 'determined' and r.known then
            sum.known_determined = sum.known_determined + 1
        end
    end
    -- DISCRIMINATION at each n, over the bases that match AT LEAST ONE class —
    -- the denominator the recorded measurement used. Zero-match bases are a
    -- different question (are they API objects at all?) and are counted above.
    for _, k in ipairs(opts.thresholds or { 1, 2, 3, 5 }) do
        local matched, uniq, mcalls, ucalls = 0, 0, 0, 0
        for _, r in ipairs(rows) do
            local ev = r.ev
            if ev.n >= k and ev.ncand > 0 then
                matched, mcalls = matched + 1, mcalls + r.calls
                if ev.ncand == 1 then uniq, ucalls = uniq + 1, ucalls + r.calls end
            end
        end
        sum.buckets[#sum.buckets + 1] = { n = k, matched = matched, unique = uniq,
            pct = matched > 0 and (uniq / matched * 100) or 0,
            calls = mcalls, unique_calls = ucalls,
            call_pct = mcalls > 0 and (ucalls / mcalls * 100) or 0 }
    end
    return rows, sum
end

--- The same query straight off a store.
function M.of_store(store, opts)
    local surf = require('cartograph.externals').surface(store)
    return M.of_surface(surf, nil, opts)
end

-- ── THE FREE ANSWER KEY ─────────────────────────────────────────────────────
--- `global2class` gives 9 (base → class) pairs the export itself declares, so the
--- matcher can be scored against ground truth instead of only reporting a
--- distribution. Two modes, and both are checks a broken matcher fails:
---   observed  `shapes[base]` from a corpus — does the shape a real mod uses on
---             `game` still contain LuaGameScript?
---   declared  (no shapes) the class's OWN member set as the shape — can each
---             documented class identify itself? Needs no corpus, so it fences
---             the parent closure and the subset test in the suite.
--- Returns (rows, summary) or (nil, reason). CONTAINS is the soundness question
--- (the true class must never be dropped); UNIQUE is the precision one.
function M.answer_key(ct, g2c, shapes)
    local why
    if not ct then ct, why = M.table(nil) end
    if not ct then return nil, why end
    if not g2c then
        local art = require('cartograph.spec.profile').load(
            (ct.meta or {}).artifact or M.ARTIFACTS[1])
        g2c = art and art.global2class
    end
    if not g2c or next(g2c) == nil then return nil, 'no global2class in the artifact' end
    local bases = {}
    for b in pairs(g2c) do bases[#bases + 1] = b end
    table.sort(bases)
    local rows = { }
    local sum = { n = 0, contains = 0, unique = 0, missing_shape = 0,
        mode = shapes and 'observed' or 'declared' }
    for _, b in ipairs(bases) do
        local cls = g2c[b]
        local members = shapes and shapes[b]
        if not members and not shapes then
            members = (ct.classes[cls] or {}).own
        end
        if members then
            local ev = M.match(members, ct)
            local contains = false
            for _, c in ipairs(ev.candidates) do if c == cls then contains = true end end
            sum.n = sum.n + 1
            if contains then sum.contains = sum.contains + 1 end
            if contains and ev.ncand == 1 then sum.unique = sum.unique + 1 end
            rows[#rows + 1] = { base = b, class = cls, ev = ev, contains = contains,
                unique = contains and ev.ncand == 1 }
        else
            sum.missing_shape = sum.missing_shape + 1
            rows[#rows + 1] = { base = b, class = cls, absent = true }
        end
    end
    return rows, sum
end

-- ── rendering ───────────────────────────────────────────────────────────────

--- One line of evidence, rendered so the THREE outcomes cannot be confused.
--- `~` marks the hedged tier, exactly as the rest of the project renders it.
function M.line(ev, cap)
    cap = cap or 4
    if ev.outcome == 'determined' then
        return ('~%-24s  n=%d  %s'):format(ev.class, ev.n,
            ev.n == 1 and '(single-member hypothesis)' or '')
    elseif ev.outcome == 'ambiguous' then
        local shown = {}
        for i = 1, math.min(cap, ev.ncand) do shown[i] = ev.candidates[i] end
        return ('AMBIGUOUS %d classes  n=%d  [%s%s]'):format(ev.ncand, ev.n,
            table.concat(shown, ', '),
            ev.ncand > cap and (', +' .. (ev.ncand - cap)) or '')
    elseif ev.outcome == 'zero' then
        local near = (ev.nearest or {})[1]
        return ('NO CLASS declares this shape  n=%d  %s'):format(ev.n,
            near and ('nearest %s shares %d, is %d member%s away (%s)'):format(near.class,
                near.shared, near.missing, near.missing == 1 and '' or 's',
                table.concat(near.names, ',')) or 'NO class shares even one member')
    end
    return ('no member evidence — %s'):format(ev.why or 'nothing observed')
end

--- Display lines: the shape match over a store's external surface.
--- GROUPING BY n IS A RENDERING CHOICE, not a rule in the query: the two known
--- wrong answers are both n=1, so a reader must be able to see that column
--- without the matcher having decided a cutoff for them.
function M.report(store, opts)
    opts = opts or {}
    local rows, sum = M.of_store(store, opts)
    if not rows then
        return { 'shape match — UNAVAILABLE: ' .. tostring(sum) }
    end
    local m = sum.meta or {}
    local lines = {
        ('shape match — %d external bases against %d declared classes (%s %s, api v%s)')
            :format(sum.bases, sum.classes, tostring(m.artifact), tostring(m.version),
                tostring(m.api_version)),
        ('  %d determined (%d calls) · %d ambiguous (%d) · %d no-class (%d) · %d no-shape (%d)')
            :format(sum.determined, sum.calls.determined, sum.ambiguous,
                sum.calls.ambiguous, sum.zero, sum.calls.zero, sum.no_shape,
                sum.calls.no_shape),
        ('  a determined match is a HYPOTHESIS on the `%s` rung (~), not a resolution:'):format(M.TIER),
        '  the observed member set is unique to one class — no receiver typing, a subset lookup.',
        ('  %d of %d no-class bases are UNRELATED (no overlapping class within one member)')
            :format(sum.zero_far, sum.zero),
        '  = not an API object at all — a mod-local table. The rest are near misses.',
        '',
        '  discrimination (bases matching >=1 class) — unique / matched:',
    }
    for _, b in ipairs(sum.buckets) do
        lines[#lines + 1] = ('    n>=%d  %3d/%-3d = %5.1f%%   call-weighted %5.1f%% (%d calls)')
            :format(b.n, b.unique, b.matched, b.pct, b.call_pct, b.calls)
    end
    lines[#lines + 1] = ''
    local cap = opts.limit or 40
    local shown = 0
    for _, r in ipairs(rows) do
        if not (opts.only and r.ev.outcome ~= opts.only) then
            if shown >= cap then
                lines[#lines + 1] = ('  … %d more bases'):format(#rows - shown)
                break
            end
            shown = shown + 1
            lines[#lines + 1] = ('  %-20s ×%-5d %-7s %s'):format(r.base, r.calls,
                r.known and 'stdlib' or '', M.line(r.ev))
        end
    end
    return lines
end

--- Display lines for the answer key (the self-check a broken matcher fails).
function M.answer_key_report(opts)
    opts = opts or {}
    local rows, sum = M.answer_key(nil, nil, opts.shapes)
    if not rows then return { 'answer key — UNAVAILABLE: ' .. tostring(sum) } end
    local lines = { ('answer key (%s shapes) — %d pairs: %d contain the declared class, %d unique')
        :format(sum.mode, sum.n, sum.contains, sum.unique) }
    for _, r in ipairs(rows) do
        if r.absent then
            lines[#lines + 1] = ('  %-12s -> %-24s NOT OBSERVED in this corpus'):format(r.base, r.class)
        else
            lines[#lines + 1] = ('  %-12s -> %-24s %s  %s'):format(r.base, r.class,
                r.contains and (r.unique and 'UNIQUE' or 'contained') or 'MISSING!',
                M.line(r.ev))
        end
    end
    return lines
end

return M
