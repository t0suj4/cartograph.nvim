-- Structural diff of two extracts (neutral-schema `data` tables). Count parity
-- ("66847 exact") is weaker than it looks — one spurious edge plus one missing
-- edge passes it. This compares per item: nodes by id, edges as multisets of
-- (from, to, kind) with their trust attributes, calls by site with their
-- resolution outcome — so a gate can assert "NOTHING moved" or "EXACTLY these
-- sites changed" instead of trusting a total. Pure data in, report out; the
-- verification half of extractor-change gates and refresh/splice testing.

local callrec = require 'cartograph.callrec'

local M = {}

-- trust signature of an edge for the structural diff: which honesty tier it
-- sits on (order-stable), the FULL canonical ladder ([[cartograph.tier]]).
-- The earlier coarsening (folding conf/tinf into 'matched') is GONE — the
-- diff now surfaces typed/confirmed trust like the rest of the tool (invariant
-- #3). Order mirrors tier.lua exactly; 'confirmed' never appears in a static
-- extract (runtime tier), but is listed so a session-live snapshot diffs true.
-- gd.diff applies this SYMMETRICALLY to both sides, so a current baseline
-- stays green; only a baseline PREDATING a corpus's tinf edges needs one
-- re-save (--save) — the deliberate re-baseline (roadmap P0.3).
-- ★ THE OCCURRENCE COUNT IS PART OF THE SIGNATURE (CART-0531). Until v147 the
-- signature carried only trust attributes, so an extraction change that altered
-- HOW MANY TIMES an edge was seen was invisible to every gate: all 37 printed
-- "graphs are identical". It had already hidden a large defect — v145 found that
-- every call site in the affected languages was recorded TWICE (mantisbt ref
-- occurrences 35793 -> 25216, pairs halving exactly against the call sites in the
-- source), and nothing on the roster moved for that half of the change. It was
-- found by a hand-written probe, looking for something else.
-- NIL IS NOT ZERO, the tri-state rule this file already lives by: an edge kind
-- that carries no occurrence list at all (`nil`) is a different fact from one
-- whose list is empty (`0`), and collapsing them would make an edge that LOST
-- its last occurrence indistinguishable from one that never had a list.
-- The count CHURNS with the corpus, which the pinned/unpinned split already
-- handles: an unpinned corpus that cannot certify it held still is advisory
-- anyway, and a pinned one has fixed source, so its counts are as stable as its
-- endpoints.
-- ★ STRUCTURED FIRST, RENDERED SECOND (CART-0626). The signature string is a
-- census KEY and must stay exactly the bytes it was; a WITNESS ROW needs the same
-- facts in English. Both are derived from ONE table so they cannot drift — a
-- decoder that re-parsed the signature back into fields would be a second grammar
-- for the same facts, and the second grammar is the one nobody updates.
local function eattrs(e)
    return {
        tier = e.conf and 'confirmed' or e.proven and 'proven' or e.xlang and 'xlang'
            or e.tinf and 'typed' or e.stdlib and 'stdlib' or e.inferred and '~' or 'matched',
        sideeffect = e.sideeffect or nil,
        -- READ EITHER SHAPE: see the note below on nat/atn/at.
        n = e.nat or e.atn or (e.at and #e.at) or nil,
        rw = e.rw, gw = e.gw, gp = e.gp, nflds = e.nflds,
    }
end

local function esig(e)
    local a = eattrs(e)
    return a.tier
        .. (a.sideeffect and '!' or '')
        -- READ EITHER SHAPE. gate/matrix diff slim-vs-slim (`nat`), and the
        -- faithfulness spec diffs the FAT table against a loaded slim one, where
        -- one side still carries the `at` list itself. Reading only `nat` would
        -- make that invariant fail for a snapshot that is perfectly faithful.
        .. (a.n and ('x' .. a.n) or '')
        -- THE WRITE AXIS, in the signature for the same reason the count is: a
        -- language declaring `spec.is_write` changes rw/gw/gp/flds on every use
        -- edge it has, and without this the whole axis lands invisibly (CART-0532).
        -- `w-` is the honest rendering of ABSENT: no classifier ran, which is a
        -- different fact from a measured read.
        .. (a.rw and (' w' .. a.rw) or ' w-')
        .. (a.gw and ('g' .. a.gw) or '')
        .. (a.gp ~= nil and ('p' .. tostring(a.gp)) or '')
        .. (a.nflds and ('f' .. a.nflds) or '')
end

-- edge identity = endpoints + kind; multiple call sites legitimately produce
-- the same pair, so identities are counted, not set-membered
local function ekey(e) return e.from .. ' -> ' .. e.to .. ' [' .. e.kind .. ']' end

-- call identity = site; outcome = where resolution landed
local function ckey(c)
    return (callrec.file(c) or '?') .. ':' .. tostring((callrec.line(c) or 0) + 1)
        .. ' ' .. (callrec.callee(c) or callrec.full(c) or '?')
end
local function coutcome(c)
    local hedge = c.hedge and (' hedged:' .. (c.hedge.rule or '?')) or ''
    if callrec.to(c) then return 'to ' .. callrec.to(c) .. hedge end
    if c.refused then return 'refused (' .. (c.refused.rule or '?') .. ')' .. hedge end
    return 'unresolved' .. hedge
end

-- key -> { outcome -> count } for one data table, plus — only when asked — one
-- REPRESENTATIVE item per (key, outcome).
-- ⚠ OPT-IN, AND THE DEFAULT-OFF IS THE POINT. gd.diff runs on the cache and tier
-- paths and over corpora where an extract is already the memory ceiling
-- ([[cartograph-sweep-memory]]: 290 MB graph, 2.5-4.5 GB sweep), so a second table
-- per distinct pair is not free at v8's 137k edges. Samples are REFERENCES to
-- edges the caller already holds, never copies, and nothing allocates them unless
-- a gate is about to render a witness.
local function edge_census(data, keep)
    local t, s = {}, keep and {} or nil
    for _, e in ipairs(data.edges or {}) do
        local k = ekey(e)
        local sig = esig(e)
        t[k] = t[k] or {}
        t[k][sig] = (t[k][sig] or 0) + 1
        if s then
            s[k] = s[k] or {}
            if s[k][sig] == nil then s[k][sig] = e end
        end
    end
    return t, s
end
local function call_census(data, keep)
    local t, s = {}, keep and {} or nil
    for _, c in callrec.each(data) do
        local k = ckey(c)
        local o = coutcome(c)
        t[k] = t[k] or {}
        t[k][o] = (t[k][o] or 0) + 1
        if s then
            s[k] = s[k] or {}
            if s[k][o] == nil then s[k][o] = c end
        end
    end
    return t, s
end

local function fmt_outcomes(o)
    local parts = {}
    for kk, n in pairs(o) do
        parts[#parts + 1] = (n > 1 and (n .. 'x ') or '') .. kk
    end
    table.sort(parts)
    return table.concat(parts, ' + ')
end

-- diff two censuses into added / removed / changed (same key, different
-- outcome distribution — an attr flip or resolution change, the gate's meat)
--- Diff two censuses. Returns the report-line table exactly as before, and —
--- when samples were kept — a parallel table of STRUCTURED rows. The strings are
--- what M.report has always printed and are not touched; the rows are what a
--- witness can be rendered from, and they exist because this function used to
--- destroy every fact it had at line-build time. That destruction is the whole
--- reason a gate could say FAIL in a vocabulary nobody could check.
local function census_diff(a, b, sa, sb)
    local added, removed, changed = {}, {}, {}
    local rows = (sa or sb) and { added = {}, removed = {}, changed = {} } or nil
    local function row(bucket, t)
        if rows then rows[bucket][#rows[bucket] + 1] = t end
    end
    for k, ob in pairs(b) do
        local oa = a[k]
        if not oa then
            added[#added + 1] = k .. ' (' .. fmt_outcomes(ob) .. ')'
            row('added', { key = k, b = ob, sb = sb and sb[k] })
        else
            local same = true
            for kk, n in pairs(ob) do if oa[kk] ~= n then same = false break end end
            if same then
                for kk, n in pairs(oa) do if ob[kk] ~= n then same = false break end end
            end
            if not same then
                changed[#changed + 1] = k .. ': '
                    .. fmt_outcomes(oa) .. ' => ' .. fmt_outcomes(ob)
                row('changed', { key = k, a = oa, b = ob,
                    sa = sa and sa[k], sb = sb and sb[k] })
            end
        end
    end
    for k, oa in pairs(a) do
        if not b[k] then
            removed[#removed + 1] = k .. ' (' .. fmt_outcomes(oa) .. ')'
            row('removed', { key = k, a = oa, sa = sa and sa[k] })
        end
    end
    table.sort(added); table.sort(removed); table.sort(changed)
    if rows then
        for _, t in pairs(rows) do
            table.sort(t, function (x, y) return x.key < y.key end)
        end
    end
    return { added = added, removed = removed, changed = changed }, rows
end

--- Diff two extracts a -> b. Returns { nodes = {added, removed}, edges =
--- {added, removed, changed}, calls = {added, removed, changed} }, every entry
--- a human-readable line (stable-sorted, so diffs of diffs work too).
function M.diff(a, b, opts)
    local w = opts and opts.witness or nil
    local na, nb = {}, {}
    for _, n in ipairs(a.nodes or {}) do na[n.id] = true end
    for _, n in ipairs(b.nodes or {}) do nb[n.id] = true end
    local nadded, nremoved = {}, {}
    for id in pairs(nb) do if not na[id] then nadded[#nadded + 1] = id end end
    for id in pairs(na) do if not nb[id] then nremoved[#nremoved + 1] = id end end
    table.sort(nadded); table.sort(nremoved)
    local ea, esa = edge_census(a, w)
    local eb, esb = edge_census(b, w)
    local ca, csa = call_census(a, w)
    local cb, csb = call_census(b, w)
    local ed, erows = census_diff(ea, eb, esa, esb)
    local cd, crows = census_diff(ca, cb, csa, csb)
    local d = {
        nodes = { added = nadded, removed = nremoved },
        edges = ed,
        calls = cd,
    }
    -- kept OFF the existing sub-tables on purpose: a caller iterating d.edges
    -- with pairs() sees exactly the three keys it always saw.
    -- ★ THE CONDITION IS `erows`, NOT `w`, AND THAT IS THE GUARD MADE TESTABLE.
    -- The memory guard's only real effect is that nothing is ALLOCATED when
    -- nobody asked, and allocation is invisible from outside — a spec asserting
    -- `d.witness == nil` passed just as happily with the guard removed, which is
    -- a test that cannot fail for the reason it claims. Keying the field on the
    -- rows themselves makes the two inseparable: samples built without a request
    -- now SHOW UP, and the spec bites.
    if erows or crows then d.witness = { edges = erows, calls = crows } end
    return d
end

--- No differences at all?
function M.empty(d)
    return #d.nodes.added == 0 and #d.nodes.removed == 0
        and #d.edges.added == 0 and #d.edges.removed == 0 and #d.edges.changed == 0
        and #d.calls.added == 0 and #d.calls.removed == 0 and #d.calls.changed == 0
end

--- Render a diff as report lines. opts.limit caps each section (default 20);
--- what got cut is COUNTED, never silently dropped.
function M.report(d, opts)
    local limit = (opts and opts.limit) or 20
    local lines = {}
    if M.empty(d) then return { 'graphs are identical (per-item)' } end
    local function section(title, list)
        if #list == 0 then return end
        lines[#lines + 1] = ('%s (%d)'):format(title, #list)
        for i = 1, math.min(#list, limit) do lines[#lines + 1] = '  ' .. list[i] end
        if #list > limit then
            lines[#lines + 1] = ('  … %d more'):format(#list - limit)
        end
    end
    section('nodes added', d.nodes.added)
    section('nodes removed', d.nodes.removed)
    section('edges added', d.edges.added)
    section('edges removed', d.edges.removed)
    section('edges changed', d.edges.changed)
    section('calls added', d.calls.added)
    section('calls removed', d.calls.removed)
    section('calls changed', d.calls.changed)
    return lines
end

-- ── WITNESS ROWS (CART-0626) ────────────────────────────────────────────────
-- A gate that can say FAIL owes ONE ROW A READER CAN CHECK. M.report prints a
-- DELTA ROW —
--     base/logging.h -> …::CompareChainNode::lhs@1646 [reg]: matchedx14 w- => matchedx1 w-
-- — which is a real instance and is verifiable only by someone who already knows
-- what `matchedx14 w-` means. A witness row states the claim, both sides in
-- words, ONE place to open, and what reading it would settle.
--
-- ⚠ WHAT A WITNESS ROW CAN HONESTLY PROMISE HERE IS NARROWER THAN IT LOOKS, and
-- the difference from a fabrication-census row is worth stating rather than
-- discovering:
--   * THE TWO SIDES ARE TWO PIPELINES (sequential vs parallel, baseline vs
--     current), not two places in the source. So the row NAMES the sides and
--     then offers ONE location — the source is the tie-breaker, not a third
--     opinion.
--   * WHICH SIDE THE SOURCE CAN SETTLE DEPENDS ON THE PAIRING, so the caller
--     declares it. Two pipelines over the SAME tree: source decides both. A
--     baseline against the current tree: source verifies only the current side,
--     because the baseline described a tree that is gone.
--   * THE OCCURRENCE SITES CANNOT BE LISTED. Matrix and gate diff SLIM extracts,
--     where `at` is stripped to a count (`nat`), so "14 occurrences" is a number
--     without addresses. The check is therefore "count them in the source", and
--     promising a list would promise what the slim form does not hold.

--- Split a node id into something openable. Ids are `file::name@line`; a bare
--- file is a legal id too (a module-level owner). Returning the file either way
--- is what lets every row name a place to look.
--- ⚠ THE LINE IN A NODE ID IS 0-BASED (tree-sitter's `sp.start.line`, see the
--- `%s::%s@%d` mints in providers/treesitter.lua) AND A READER'S EDITOR IS NOT.
--- Rendering it raw sent every check one line short: `clear` is defined at 67 and
--- its id says @66, `acquire` at 272 against @271. A witness row whose line is
--- wrong is worse than no row — it shows the reader something that is not what it
--- claims, and the natural conclusion is that the tool is confused rather than
--- that the row is off by one. ckey already adds the 1 for call sites; this is the
--- same correction at the other seam. Found by opening the file, not by a test.
local function loc(id)
    local f, n, l = id:match('^(.-)::(.-)@(%d+)$')
    if f then return f, n, tonumber(l) + 1 end
    f, n = id:match('^(.-)::(.+)$')
    if f then return f, n end
    return id
end

--- One representative per side, chosen by lowest signature so a row renders the
--- same on every run. A key with several signatures on one side still prints its
--- FULL outcome string, so picking one sample hides nothing.
local function pick(m)
    if not m then return nil end
    local best
    for k in pairs(m) do if not best or k < best then best = k end end
    return best and m[best] or nil
end

--- One side of an edge row, in words.
--- ★ `w-` MEANS NO CLASSIFIER RAN. This file's own header keeps nil apart from
--- zero; English is exactly where that distinction dies quietly, so the absent
--- case says so at length rather than rendering as a tidy "not a write".
local function edge_english(a)
    if not a then return '(no sample kept)' end
    local p = { 'tier ' .. a.tier }
    if a.sideeffect then p[#p + 1] = 'side-effecting' end
    p[#p + 1] = a.n and (('%d occurrence(s)'):format(a.n))
        or 'no occurrence list at all (ABSENT — not zero)'
    p[#p + 1] = a.rw and ('write-class ' .. tostring(a.rw))
        or 'write-class ABSENT (no classifier ran — NOT "not a write")'
    if a.gw then p[#p + 1] = 'global-write ' .. tostring(a.gw) end
    if a.gp ~= nil then p[#p + 1] = 'gp=' .. tostring(a.gp) end
    if a.nflds then p[#p + 1] = ('%d field(s)'):format(a.nflds) end
    return table.concat(p, ' · ')
end

--- Which axes disagree — this is what decides WHAT TO READ, so it drives the
--- check line rather than being printed for its own sake.
local function axes(x, y)
    local out = {}
    if not x or not y then return out end
    if x.tier ~= y.tier then out[#out + 1] = 'tier' end
    if x.n ~= y.n then out[#out + 1] = 'occurrences' end
    if (x.sideeffect and 1 or 0) ~= (y.sideeffect and 1 or 0) then
        out[#out + 1] = 'side-effect'
    end
    if x.rw ~= y.rw or x.gw ~= y.gw or x.gp ~= y.gp or x.nflds ~= y.nflds then
        out[#out + 1] = 'write-axis'
    end
    return out
end

-- ★★ WHAT AN OCCURRENCE IS DEPENDS ON THE EDGE KIND, and getting this wrong is
-- the difference between a check that settles the question and one that sends the
-- reader to count the wrong thing. The first cut said "count the references" for
-- every kind. On grocy that reads as SIX (CheckNightMode appears six times) while
-- the edge claims two — and two is CORRECT, because a `reg` edge is a mention from
-- DATA: `setInterval(CheckNightMode, 60000)` counts, `CheckNightMode()` does not.
-- Found by doing the ten-second check by hand instead of trusting that rows had
-- printed; the same three cases then confirmed the sequential side exactly.
local OCCURRENCE = {
    reg = 'mentioned AS A VALUE — passed to something, stored, assigned. NOT called: '
        .. '`f(x)` does not count, `setInterval(f, 60)` does',
    ref = 'called, or referenced from code',
    use = 'read or written',
    import = 'imported',
}

-- the same distinction in a SHORT form. OCCURRENCE reads as a clause inside
-- "count the places X is …"; a presence question needs "is X … there at all?",
-- and reusing the long one produced a sentence with two verbs and no punctuation.
local PRESENCE = {
    reg = 'mentioned as a value (not called)',
    ref = 'called or referenced',
    use = 'read or written',
    import = 'imported',
}

local CHECK = {
    occurrences = 'open %s and COUNT the places `%s` is %s. The two sides claim '
        .. 'different totals, and counting settles it.',
    tier = 'open %s at the reference to `%s` and decide whether it really resolves '
        .. 'to that target — the sides disagree about how it was resolved.',
    ['side-effect'] = 'open %s and decide whether this reference to `%s` runs for '
        .. 'effect at load time.',
    ['write-axis'] = 'open %s and read what is done to `%s` — assigned? passed to '
        .. 'something that writes it?',
}

--- Render a diff as WITNESS rows. Requires M.diff(a, b, { witness = true });
--- without it the structure was never kept and this REFUSES WITH THE REASON
--- rather than printing an empty section, which would read as "nothing to see".
---   opts.a / opts.b     what to call the two sides (default 'A' / 'B')
---   opts.decides        'both' (same tree) or 'b' (only the b side is current)
---   opts.limit          rows per section, default 10; what is cut is COUNTED
function M.witness(d, opts)
    opts = opts or {}
    local A, B = opts.a or 'A', opts.b or 'B'
    local limit = opts.limit or 10
    if not d.witness then
        return { 'NO WITNESS ROWS: this diff was run without opts.witness, so the '
            .. 'structure was discarded at census time. Re-run M.diff(a, b, '
            .. '{ witness = true }). This is a refusal, not an empty result.' }
    end
    local out = {}
    local function say(l) out[#out + 1] = l end

    local ew = d.witness.edges or { added = {}, removed = {}, changed = {} }
    local n = 0
    for _, r in ipairs(ew.changed) do
        n = n + 1
        if n > limit then break end
        local key = r.key:match('^(.*) %[') or r.key
        local kind = r.key:match('%[(.-)%]$') or '?'
        local from, to = key:match('^(.-) %-> (.*)$')
        local ffile = from and loc(from) or '?'
        -- ⚠ NOT `to and loc(to)`: an and/or expression is adjusted to ONE value,
        -- so the name and line silently vanished and every check line read
        -- "count the references to `?`". Found by the spec, which is the only
        -- reason it is not in the shipped output.
        local tfile, tname, tline
        if to then tfile, tname, tline = loc(to) end
        local xa, xb = pick(r.sa), pick(r.sb)
        local aa = xa and eattrs(xa) or nil
        local ab = xb and eattrs(xb) or nil
        say(('%s  →  %s%s  [%s]'):format(ffile, tname or tfile or '?',
            tline and (' @' .. tline) or '', kind))
        say(('    %-10s %s'):format(A .. ':', aa and edge_english(aa) or fmt_outcomes(r.a)))
        say(('    %-10s %s'):format(B .. ':', ab and edge_english(ab) or fmt_outcomes(r.b)))
        -- THE TOTAL, not just the sampled record: a pair can carry several edge
        -- records (different owners in one file), and the reader counting in the
        -- source counts ALL of them. Summing n x count per signature is exact.
        local function total(outc, samples)
            if not outc or not samples then return nil end
            local sum = 0
            for sig, c in pairs(outc) do
                local e = samples[sig]
                local a = e and eattrs(e)
                if not a or not a.n then return nil end
                sum = sum + a.n * c
            end
            return sum
        end
        local function nrec(o)
            local c = 0
            for _, k in pairs(o or {}) do c = c + k end
            return c
        end
        local ta, tb = total(r.a, r.sa), total(r.b, r.sb)
        local many = math.max(nrec(r.a), nrec(r.b)) > 1
        if ta and tb and ta ~= tb and many then
            -- ⚠ AND THE CAVEAT IS NOT OPTIONAL. On grocy this pair carries TWO
            -- records totalling 4 while the source holds 2 value-mentions, so a
            -- reader who counts 2 and compares it to 4 learns nothing. What the
            -- count settles is the SAMPLED RECORD (2 vs 1 — and 2 is what the
            -- source says). Printing a total without saying which number the
            -- count answers would turn a checkable row back into a puzzle.
            say(('    this pair has %d record(s) per side; totals %s %d · %s %d')
                :format(math.max(nrec(r.a), nrec(r.b)), A, ta, B, tb))
            say('    the count below settles the SAMPLED RECORD above, not the total —'
                .. ' several records can cover one name.')
        end
        local ax = axes(aa, ab)
        if #ax == 0 then
            -- the samples agree while the DISTRIBUTIONS differ: the key appears
            -- several times with different signatures and one side has a
            -- different mix. Say that, rather than a check that would not settle it.
            say('    CHECK: the sampled items agree; the two sides differ in HOW MANY '
                .. 'of each. Full outcomes — ' .. A .. ': ' .. fmt_outcomes(r.a)
                .. ' | ' .. B .. ': ' .. fmt_outcomes(r.b))
        else
            for _, k in ipairs(ax) do
                local t = CHECK[k] or 'open %s and read `%s`.'
                say('    CHECK (' .. k .. '): '
                    .. (k == 'occurrences'
                        and t:format(ffile, tname or tfile or '?',
                            OCCURRENCE[kind] or ('present as a `' .. kind .. '` edge'))
                        or t:format(ffile, tname or tfile or '?')))
            end
        end
        if opts.decides == 'b' then
            say(('    ⚠ the source settles %s only — %s described a tree that is gone.')
                :format(B, A))
        end
    end
    if #ew.changed > limit then
        say(('  … %d more changed edge(s)'):format(#ew.changed - limit))
    end

    -- CALLS ARE THE MOST CHECKABLE ROWS THIS FILE HAS: a call key already IS a
    -- source location, so the row needs no reconstruction and the reader needs no
    -- vocabulary at all.
    local cw = d.witness.calls or { added = {}, removed = {}, changed = {} }
    n = 0
    for _, r in ipairs(cw.changed) do
        n = n + 1
        if n > limit then break end
        say(r.key)
        say(('    %-10s %s'):format(A .. ':', fmt_outcomes(r.a)))
        say(('    %-10s %s'):format(B .. ':', fmt_outcomes(r.b)))
        say('    CHECK: open that line and read what the name refers to.')
        if opts.decides == 'b' then
            say(('    ⚠ the source settles %s only.'):format(B))
        end
    end
    if #cw.changed > limit then
        say(('  … %d more changed call site(s)'):format(#cw.changed - limit))
    end

    -- ── THE SOUNDNESS-SHAPED HALF ──────────────────────────────────────────
    -- An edge or a definition that ONE SIDE HAS AND THE OTHER DOES NOT is the
    -- shape a minting or dropping bug takes, and it is the shape a `changed` row
    -- can never be. The first cut rendered these as a COUNT pointing at
    -- M.report — so the checkable half was the multiplicity half, and the half
    -- that would actually be a soundness bug had no ten-second check at all.
    --
    -- These rows need no samples: an id already carries file, name and line, and
    -- the question is binary. That is what makes them the strongest rows here —
    -- "is this defined at that line, yes or no" needs no vocabulary whatsoever.
    local WHICH = { added = { B, A }, removed = { A, B } }
    for _, bucket in ipairs({ 'added', 'removed' }) do
        local has, hasnt = WHICH[bucket][1], WHICH[bucket][2]
        local nodes = d.nodes[bucket] or {}
        local n2 = 0
        for _, id in ipairs(nodes) do
            n2 = n2 + 1
            if n2 > limit then break end
            local f, nm, ln = loc(id)
            -- ⚠ A BARE-FILE ID IS A MODULE NODE, not a nameless definition. Asking
            -- "is there a definition of `?` there" is the question a reader cannot
            -- answer, and it is what this printed on the first real diff.
            say(('DEFINITION %s only in %s: %s%s'):format(bucket:upper(), has,
                nm or id, nm and '' or '  (the module itself)'))
            say(nm
                and (('    CHECK: open %s%s — is there a definition of `%s` there?')
                    :format(f or '?', ln and (':' .. ln) or '', nm))
                or (('    CHECK: does %s exist and parse?'):format(f or id)))
            say(('    yes → %s dropped it. no → %s invented it.'):format(hasnt, has))
        end
        if #nodes > limit then
            say(('  … %d more %s definition(s)'):format(#nodes - limit, bucket))
        end

        local n3 = 0
        for _, r in ipairs(ew[bucket]) do
            n3 = n3 + 1
            if n3 > limit then break end
            local key = r.key:match('^(.*) %[') or r.key
            local kind = r.key:match('%[(.-)%]$') or '?'
            local from, to = key:match('^(.-) %-> (.*)$')
            local ffile = from and loc(from) or '?'
            local tname, tfile
            if to then tfile, tname = loc(to) end
            local subject = tname or tfile or to or '?'
            say(('EDGE %s only in %s: %s → %s  [%s]')
                :format(bucket:upper(), has, ffile, subject, kind))
            say(('    CHECK: open %s — is `%s` %s there at all?'):format(
                ffile, subject,
                PRESENCE[kind] or ('present as a `' .. kind .. '` edge')))
            say(('    yes → %s dropped it. no → %s invented it.'):format(hasnt, has))
        end
        if #ew[bucket] > limit then
            say(('  … %d more %s edge(s)'):format(#ew[bucket] - limit, bucket))
        end

        local c = #cw[bucket]
        if c > 0 then
            -- a call key IS a location, so these need no reconstruction either
            local n4 = 0
            for _, r in ipairs(cw[bucket]) do
                n4 = n4 + 1
                if n4 > limit then break end
                say(('CALL SITE %s only in %s: %s'):format(bucket:upper(), has, r.key))
                say('    CHECK: open that line — is there a call there?')
            end
            if c > limit then say(('  … %d more %s call site(s)'):format(c - limit, bucket)) end
        end
    end
    if #out == 0 then say('no differences') end
    return out
end

--- What a gate should print when it FAILS: the witness rows first, because they
--- are the ones a reader can check, then the delta rows, because they are the
--- complete list. Returns (lines-or-nil, diff) — nil lines means no differences.
---
--- ⚠ IT DIFFS TWICE ON PURPOSE, and the second one only happens on failure. The
--- sample capture is opt-in precisely so the common path allocates nothing, and
--- passing `witness = true` up front to find out whether it is needed would give
--- that back on every green run of every corpus. A second census over an extract
--- already in memory is cheap next to the extraction that produced it (v8: 178s
--- to extract, well under a second to re-census), so failure pays and success
--- does not.
function M.detail(a, b, opts)
    local d = M.diff(a, b)
    if M.empty(d) then return nil, d end
    local lines = { 'WITNESS ROWS — open the file named and the claim settles:' }
    for _, l in ipairs(M.witness(M.diff(a, b, { witness = true }), opts)) do
        lines[#lines + 1] = '  ' .. l
    end
    -- the report gets its OWN cap: a witness row is ~5 lines and a delta row is
    -- one, so sharing a limit would trade 20 delta rows for 4 witnesses. Labelled
    -- "capped" rather than "complete" because it is — report() counts what it cut,
    -- but a section headed "complete list" ending in "… 163 more" reads as a lie.
    lines[#lines + 1] = 'DELTA ROWS (internal vocabulary, capped — report counts the rest):'
    for _, l in ipairs(M.report(d, { limit = (opts and opts.report_limit) or 25 })) do
        lines[#lines + 1] = '  ' .. l
    end
    return lines, d
end

return M
