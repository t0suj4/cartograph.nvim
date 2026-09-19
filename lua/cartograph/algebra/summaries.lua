-- A PART OF `cartograph.algebra.core`, which requires this file at its end and
-- passes its own module table in. ⚠ IT DOES NOT `require` CORE BACK: that is a
-- load cycle — Lua says "loop or previous error loading module".
-- ★ 3 shared file-local(s), each (a) a core module-level local, (b) used
-- here and (c) not defined here — the three conditions, not a guess.
return function (M, SHARED)
local anchor_fit, distinct, hedged_run, is_hole, same_key =
    SHARED.anchor_fit, SHARED.distinct, SHARED.hedged_run, SHARED.is_hole,
    SHARED.same_key

-- ── the two STRUCTURAL summaries: repetition and recursion claims over a column ───────
-- Like the value summaries (DOMAINS.md), these are policies over the column, not choices
-- of the builder: `need` distinct lengths (depths) and a homogeneous element shape claim a
-- repetition (recursion); fewer record the hypothesis and leave the domain open. Both
-- generalize and rederive_domains call these, so a family built by n-ary generalize and one
-- built by a fold of join carry the same claim (HEDGEJOIN.md).
local function one_kind(D) -- the summary spans a single kind (the column is homogeneous)
    if D.kind == 'closed' then return true end
    if D.kind == 'kinds' then local n = 0; for _ in pairs(D.set) do n = n + 1 end; return n == 1 end
    if D.kind == 'alt' then
        local k
        for _, a in ipairs(D.alts) do
            if a.kind ~= 'closed' then return false end
            if k and a.value.k ~= k then return false end
            k = a.value.k
        end
        return true
    end
    return false
end
--- the repetition claim for hole h over a column of sequences. Returns { domain, note }.
--- The element template is the generalization of every element of every member and is
--- named h.elem in env.defs when the claim is made.
-- ── REPETITION: the period is the unit (Kolpakov & Kucherov 1999, REPETITION.md) ──────
-- KK, page 1: the period of a word w = a1..an is the smallest positive p with a_i = a_{i+p}
-- for all 1 <= i, i+p <= n; n/p is the exponent; a word of exponent >= 2 (period at most half
-- the length) is a REPETITION; an integer exponent k makes it an integer power u^k; a maximal
-- repetition is one whose extension by one letter to the left or right has a bigger period.
-- Here letters are terms compared by eq; the run's unit under GENERALIZATION is the lgg of
-- the chunks of one period (equality modulo the unit's holes), so `1 a 2 a 3` has period 2
-- with unit (a ?v) although no two letters repeat.
--- the period of a sequence of terms (KK: smallest p with w[i] eq w[i+p]); #w for a
--- primitive word, 0 for the empty one
function M.period(w)
    local n = #w
    for p = 1, n - 1 do
        local ok = true
        for i = 1, n - p do if not M.eq(w[i], w[i + p]) then ok = false; break end end
        if ok then return p end
    end
    return n
end
--- n/p; 0 for the empty sequence
function M.exponent(w) local p = M.period(w); return p > 0 and #w / p or 0 end
--- every maximal repetition of w: { from, to, period, exponent }, in position order. Naive
--- (each subword's period recomputed); KK's linear algorithm is not reproduced.
function M.maximal_repetitions(w)
    local n, out = #w, {}
    local function period_of(i, j)
        local sub = {}
        for x = i, j do sub[#sub + 1] = w[x] end
        return M.period(sub)
    end
    for i = 1, n do
        for j = i + 1, n do
            local p = period_of(i, j)
            if j - i + 1 >= 2 * p then
                local left = i > 1 and period_of(i - 1, j) or math.huge
                local right = j < n and period_of(i, j + 1) or math.huge
                if left > p and right > p then out[#out + 1] = { from = i, to = j, period = p, exponent = (j - i + 1) / p } end
            end
        end
    end
    return out
end

--- the repetition analysis over a column of sequences (the varying middles of an arity
--- divergence, one per member). Inside the middle an aligned HEAD and TAIL (columns present
--- in every member: identical, a node, or a hole of one kind) may precede and follow the RUN,
--- whose length varies; the run has a PERIOD p when every member's run is an integer power of
--- p kids and the lgg of all the chunks (the UNIT) has every column fixed or of one kind.
--- Search order: the longest run first (smallest head+tail: KK's maximal repetition, within
--- the middle), then the smallest period whose unit is NON-TRIVIAL (some column fixed); when
--- no split has one, the element rule as before: period 1 at head = tail = 0 with a unit of
--- one kind, `trivial = true`. Returns nil when nothing qualifies. The claim policy is the
--- caller's (`need` distinct run lengths, HEDGEJOIN.md).
function M.repetition(col, opts)
    opts = opts or {}
    local need, n = opts.need or 3, #col
    if n == 0 then return nil end
    -- the analysis is a function of the column: memoized through the env, which the nested
    -- generalizes share (READER.md: a fold over two files ran it 23,802 times, most repeats)
    local memo = opts.env and opts.env.repmemo
    local mkey
    if memo then
        local sig = {}
        for i, v in ipairs(col) do sig[i] = M.show(v) end
        mkey = table.concat(sig, '\1')
        if memo[mkey] ~= nil then return memo[mkey] or nil end
    end
    local function done(R) if memo and not (R and R.truncated) then memo[mkey] = R or false end return R end -- a truncated answer is not kept: a later call may have a larger budget
    local lens, minlen = {}, math.huge
    for i, v in ipairs(col) do lens[i] = #(v.kids or {}); minlen = math.min(minlen, lens[i]) end
    local genopts = { need = need, prefix = opts.prefix or 'u.', grammars = opts.grammars, cap = opts.cap }
    -- the split search (spans x heads x periods) prices each candidate with a generalize over
    -- its chunks; on long lists (a file's statements) it is the cost READER.md measured, so it
    -- is budgeted like match: `opts.split_cap` generalize calls (default 2000), after which the
    -- search stops with what it has and says `truncated`
    local spent, split_cap, truncated = 0, opts.split_cap or 2000, false
    local function lgg(vals)
        spent = spent + 1
        if spent > split_cap then truncated = true; return nil end
        local o = {}
        for k, v in pairs(genopts) do o[k] = v end
        o.env = { defs = {}, repmemo = memo }
        return M.generalize(vals, o)
    end
    local function column_ok(vals) -- aligned: identical, or an lgg that is a node or a hole of one kind
        local leaves = true
        for _, v in ipairs(vals) do if not (v.k == 'lit' or v.k == 'name') then leaves = false end end
        if leaves then return true end -- a column of leaves is one kind: no generalize needed
        for i = 2, #vals do
            if not M.eq(vals[i], vals[1]) then
                local g = lgg(vals)
                if not g then return false end
                local b = g.template.body
                if is_hole(b) then return one_kind(g.template.holes[b.h].domain) end
                return true
            end
        end
        return true
    end
    local function chunks_of(head, runs, p)
        local out = {}
        for i = 1, n do
            for c = 0, runs[i] / p - 1 do
                local kids = {}
                for j = 1, p do kids[j] = col[i].kids[head + c * p + j] end
                out[#out + 1] = M.seq(kids)
            end
        end
        return out
    end
    local function try(head, tail)
        local runs, maxr, total = {}, 0, 0
        for i = 1, n do runs[i] = lens[i] - head - tail; maxr = math.max(maxr, runs[i]); total = total + runs[i] end
        if total < 2 then return nil end
        local trivial
        for p = 1, maxr do
            local divides = true
            for i = 1, n do if runs[i] % p ~= 0 then divides = false; break end end
            -- KK: a repetition has exponent >= 2 (some member holds two chunks); the element
            -- rule (p = 1) stands on the column as before
            if divides and (p == 1 or maxr >= 2 * p) then
                local ch = chunks_of(head, runs, p)
                local U = lgg(p == 1 and (function() local es = {}; for _, c in ipairs(ch) do es[#es + 1] = c.kids[1] end; return es end)() or ch)
                if not U then return nil, trivial end
                local body = U.template.body
                local cols = (p == 1 or is_hole(body)) and { body } or body.kids
                local ok, nontrivial = true, false
                for _, c in ipairs(cols) do
                    if is_hole(c) then
                        if not (U.template.holes[c.h] and one_kind(U.template.holes[c.h].domain)) then ok = false; break end
                    else nontrivial = true end
                end
                if ok then
                    local R = { head = head, tail = tail, period = p, unit = U, runs = runs, chunks = #ch, trivial = not nontrivial }
                    if nontrivial then return R end
                    if p == 1 then trivial = R end
                end
            end
        end
        return nil, trivial
    end
    local function holes_in(U) local c = 0; for _ in pairs(U.template.holes) do c = c + 1 end; return c end
    local fallback
    for span = 0, minlen do
        if truncated then break end
        -- every split of this span is a rotation of the same run (KK: a repetition has as
        -- many starting points as its period); keep the unit with the fewest holes, the
        -- least general reading, and the smallest head on a tie
        local best
        for head = 0, span do
            local tail = span - head
            local aligned = true
            for j = 1, head do
                local vals = {}
                for i = 1, n do vals[i] = col[i].kids[j] end
                if not column_ok(vals) then aligned = false; break end
            end
            for j = 1, tail do
                if not aligned then break end
                local vals = {}
                for i = 1, n do vals[i] = col[i].kids[lens[i] - tail + j] end
                if not column_ok(vals) then aligned = false; break end
            end
            if aligned then
                local R, trivial = try(head, tail)
                if R and (not best or holes_in(R.unit) < holes_in(best.unit)) then best = R end
                if span == 0 and trivial then fallback = trivial end
            end
            if truncated then break end
        end
        if best then best.truncated = truncated or nil; return done(best) end
    end
    if fallback then fallback.truncated = truncated or nil end
    return done(fallback)
end

--- the SHAPE of a middle whose run sits behind an aligned head or tail: a seq template
--- (head columns, the run hole with its repetition claim, tail columns). A caller that keeps
--- the hedge whole (rederive over a fold of join) claims @h.shape; generalize restructures
--- the list instead and the two describe the same sequences.
function M.hedge_shape(h, col, R, env, opts)
    local n, kids, domains = #col, {}, {}
    local lens = {}
    for i, v in ipairs(col) do lens[i] = #(v.kids or {}) end
    local function column(vals, label)
        local g = M.generalize(vals, { need = opts.need, prefix = h .. '.' .. label .. '.', env = env, grammars = opts.grammars })
        for name, e in pairs(g.template.holes) do domains[name] = { domain = e.domain, origin = 'derived' } end
        return g.template.body
    end
    for j = 1, R.head do
        local vals = {}
        for i = 1, n do vals[i] = col[i].kids[j] end
        kids[#kids + 1] = column(vals, 'head' .. j)
    end
    local run = h .. '.run'
    kids[#kids + 1] = M.hole(run, true)
    domains[run] = { domain = M.rep(M.ref(h .. (R.period == 1 and '.elem' or '.unit')), 0, nil, R.period), origin = 'derived' }
    for j = 1, R.tail do
        local vals = {}
        for i = 1, n do vals[i] = col[i].kids[lens[i] - R.tail + j] end
        kids[#kids + 1] = column(vals, 'tail' .. j)
    end
    return M.template(M.seq(kids), domains)
end

--- the summary of a hedge column (HEDGEJOIN.md, now through `repetition`): the claim is
--- rep(@h.elem) for a period of 1, rep(@h.unit) with the period for a longer unit, @h.shape
--- when an aligned head or tail lies inside the column; below `need` distinct run lengths
--- the analysis is recorded as the hypothesis and the domain is the element summary.
function M.summarize_hedge(h, col, opts)
    opts = opts or {}
    local need, env = opts.need or 3, opts.env or { defs = {} }
    env.defs = env.defs or {}
    local lens, elems = {}, {}
    for i, v in ipairs(col) do
        lens[i] = #(v.kids or {})
        for _, e in ipairs(v.kids or {}) do elems[#elems + 1] = e end
    end
    local d = distinct(lens)
    env.repmemo = env.repmemo or {}
    local R = M.repetition(col, { need = need, prefix = h .. '.', grammars = opts.grammars, cap = opts.cap, split_cap = opts.split_cap, env = env })
    local note = { why = 'arity', lengths = lens, distinct = d, need = need,
        homogeneous = R ~= nil, period = R and R.period or nil, head = R and R.head or nil, tail = R and R.tail or nil,
        trivial = R and R.trivial or nil, truncated = R and R.truncated or nil,
        hypothesis = R and { rep_of = R.unit.template, period = R.period, head = R.head, tail = R.tail }
            or (#elems >= 2 and { rep_of = M.generalize(elems, { need = need, env = { defs = {} }, prefix = h .. '.', grammars = opts.grammars }).template } or nil) }
    if R and d >= need then
        note.claimed = 'rep'
        local unit = h .. (R.period == 1 and '.elem' or '.unit')
        env.defs[unit] = R.unit.template
        if R.head == 0 and R.tail == 0 then
            return { domain = M.rep(M.ref(unit), 0, nil, R.period), note = note, split = R }
        end
        env.defs[h .. '.shape'] = M.hedge_shape(h, col, R, env, opts)
        return { domain = M.ref(h .. '.shape'), note = note, split = R }
    end
    note.claimed, note.under_determined = 'open', d < need
    -- no claim: the domain is still a derived summary, of the ELEMENTS (DOMAINS.md); it used
    -- to be rep(open), "a seq of anything", which threw the kind evidence away
    return { domain = M.rep(M.summarize(elems, opts)), note = note }
end

--- the per-chunk bindings of a repetition hole: the claimed unit matched against each chunk
--- of the hedge's value. Derived from match; the stored value stays the flat sequence.
function M.unit_values(T, h, V, env)
    local e = T.holes[h]
    if not e or not e.rep then return nil, 'not a repetition hole: ' .. tostring(h) end
    local D, v = e.domain, V[h]
    if not v or v.k ~= 'seq' then return nil, 'no sequence bound to ' .. h end
    if D.kind ~= 'rep' or D.of.kind ~= 'ref' then return nil, 'no claimed unit on ' .. h end
    local U = (env and env.defs or {})[D.of.name]
    if not U then return nil, 'unresolved @' .. D.of.name end
    local p, out = D.period or 1, {}
    if #v.kids % p ~= 0 then return nil, ('length %d is not a multiple of the period %d'):format(#v.kids, p) end
    for c = 1, #v.kids / p do
        local kids = {}
        for j = 1, p do kids[j] = v.kids[(c - 1) * p + j] end
        local m = M.match(U, p == 1 and kids[1] or M.seq(kids), { defs = env.defs })
        if not m.ok then return nil, ('chunk %d: %s'):format(c, m.refusal.why) end
        out[c] = m.values
    end
    return out
end
--- the recursion claim for term hole h of T over its column: values that are themselves
--- instances of T, to distinct depths. Returns { domain|nil, note }; domain is nil when
--- there is nothing to say (depths do not vary).
function M.summarize_recursion(T, h, col, opts)
    opts = opts or {}
    local need, env = opts.need or 3, opts.env or { defs = {} }
    env.defs = env.defs or {}
    if T.holes[h].rep or is_hole(T.body) then return { note = {} } end
    -- depths are read with this hole OPEN, so re-summarizing a claimed hole is idempotent
    local T0 = M.copy(T)
    T0.holes[h].domain = M.open()
    local menv = { defs = env.defs, self = T0 }
    local function depth(v)
        local m = M.match(T0, v, menv)
        if not m.ok or not m.values[h] then return 0 end
        return 1 + depth(m.values[h])
    end
    local depths, bases = {}, {}
    for i, v in ipairs(col) do
        local d = depth(v)
        depths[i] = d
        local b = v
        for _ = 1, d do b = M.match(T0, b, menv).values[h] end
        bases[#bases + 1] = b
    end
    local dd = distinct(depths)
    if dd < 2 then return { note = {} } end
    local base = M.generalize(bases, { need = need, env = env, prefix = h .. '.', grammars = opts.grammars })
    local note = { depths = depths, distinct_depths = dd, hypothesis = { rec_base = base.template } }
    if dd >= need then
        env.defs[h .. '.base'] = base.template
        note.claimed = 'rec'
        return { domain = M.alt(M.ref(h .. '.base'), M.ref('self')), note = note }
    end
    note.claimed, note.under_determined = 'open', true
    return { note = note }
end

-- a column entry for a member that lacks the optional pair this column sits under: never a
-- value (a presence hole's `absent` IS a value), never shown to a summary
local GONE = { k = 'gone' }
local function is_gone(v) return v == GONE end
-- ── generalize: n-ary anti-unification, the operator (its helpers sit under the header of the same
-- name above; the repetition analysis between them is what it calls) ───────────────────────
function M.generalize(instances, opts)
    opts = opts or {}
    local n = #instances
    local need = opts.need or 3 -- distinct lengths/depths required to claim rep/rec
    local env = opts.env or { defs = {} }
    env.defs = env.defs or {}
    env.repmemo = env.repmemo or {}
    local prefix = opts.prefix or 'h'
    local values, domains, notes = opts.values or {}, {}, {}
    if not opts.values then for i = 1, n do values[i] = {} end end
    local memo, counter = opts.memo or {}, 0 -- shared with an inner generalize across a boundary

    local function fresh(vals, why)
        local sig = {}
        for i = 1, n do sig[i] = M.show(vals[i]) end
        local k = table.concat(sig, '\1')
        -- LINEAR VARIANT (survey §2): no hole occurs twice. cartograph's element_template
        -- keys holes per donor span and is this variant; analyze_pair groups by the value
        -- tuple (Plotkin's rule) and is the non-linear one.
        if memo[k] and not opts.linear then return memo[k] end
        counter = counter + 1
        local h = prefix .. counter
        memo[k] = h
        -- an instance lacking the optional pair this column sits under (KEYED.md) owes no
        -- value here and does not enter the summary; the memo signature keeps its mark, so
        -- two columns absent in the same members share a hole exactly as kv_generalize's do
        local live = {}
        for i = 1, n do if not is_gone(vals[i]) then values[i][h] = vals[i]; live[#live + 1] = vals[i] end end
        -- ★ KIND AGREEMENT IS EVIDENCE: the lgg of two literals is "a literal", not
        -- "anything". In an order-sorted signature the variable carries its sort, and
        -- that sort is the vocabulary rung (CART-0864) derived from the corpus side.
        -- the domain is DERIVED: the one summary function over the value column (DOMAINS.md)
        domains[h] = { domain = M.summarize(live, opts), origin = 'derived' }
        notes[h] = { why = why }
        return h
    end
    -- the instances that carry a value in this column (the others are under an absent pair)
    local function live_of(ts)
        local live = {}
        for i = 1, n do if not is_gone(ts[i]) then live[#live + 1] = i end end
        return live
    end

    local go
    -- a kids-list whose lengths differ (LCSJOIN.md; Myers 1986): the ANCHORS are a common
    -- subsequence of every live member's kids, the LCS of the first two intersected with each
    -- next member in turn (a common subsequence, not the longest, and it depends on member
    -- order). Between two anchors, runs of one length are columns aligned kid by kid; runs of
    -- differing lengths are one hedge hole, a candidate repetition, with REPETITION.md's
    -- aligned head and tail moved out of it. The identical prefix and suffix are the anchors'
    -- first and last stretch, so the old ends rule is the case with no anchor inside.
    local function arity_divergence(ts, lens)
        local live = live_of(ts)
        local first = live[1]
        local minlen = math.huge
        for _, i in ipairs(live) do minlen = math.min(minlen, lens[i]) end
        local function identical(col_of)
            local f = col_of(live[1])
            for x = 2, #live do if not M.eq(col_of(live[x]), f) then return false end end
            return true
        end
        -- the identical prefix and suffix first (the old ends rule)
        local pre = 0
        while pre < minlen and identical(function(i) return ts[i].kids[pre + 1] end) do pre = pre + 1 end
        local suf = 0
        while suf < minlen - pre and identical(function(i) return ts[i].kids[lens[i] - suf] end) do suf = suf + 1 end
        local function slice(i, from, to)
            local m = {}
            for j = from, to do m[#m + 1] = ts[i].kids[j] end
            return M.seq(m)
        end
        -- the anchors inside the middle: the LCS of the first two members' middles, intersected
        -- with each next member in turn
        local anch, seqk = {}, {}
        for j = pre + 1, lens[first] - suf do anch[#anch + 1] = { [first] = j }; seqk[#seqk + 1] = ts[first].kids[j] end
        for x = 2, #live do
            local m = live[x]
            local mk = {}
            for j = pre + 1, lens[m] - suf do mk[#mk + 1] = ts[m].kids[j] end
            local na, nk = {}, {}
            for _, pr in ipairs(M.lcs(seqk, mk, anchor_fit)) do
                local a = anch[pr[1]]; a[m] = pre + pr[2]
                na[#na + 1] = a; nk[#nk + 1] = seqk[pr[1]]
            end
            anch, seqk = na, nk
        end
        local kids = {}
        local function column_at(offset_of)
            local col = {}
            for i = 1, n do col[i] = is_gone(ts[i]) and ts[i] or ts[i].kids[offset_of(i)] end
            return go(col)
        end
        for j = 1, pre do kids[#kids + 1] = column_at(function() return j end) end
        local prev, final = {}, {}
        for _, i in ipairs(live) do prev[i] = pre; final[i] = lens[i] - suf + 1 end
        anch[#anch + 1] = final
        for _, a in ipairs(anch) do
            local runlen, equal
            for _, i in ipairs(live) do
                local l = a[i] - prev[i] - 1
                if runlen == nil then runlen, equal = l, true elseif l ~= runlen then equal = false end
                if hedged_run(ts[i].kids, prev[i] + 1, a[i] - 1) then equal = false end -- a hedge kid inside a run: the run is a hedge (as join)
            end
            if equal then
                for d = 1, runlen do kids[#kids + 1] = column_at(function(i) return prev[i] + d end) end
            else
                local livemids = {}
                for _, i in ipairs(live) do livemids[#livemids + 1] = slice(i, prev[i] + 1, a[i] - 1) end
                -- REPETITION.md: an aligned head or tail inside the run (columns every member has)
                -- becomes term columns beside it, once the run's lengths reach the claim policy
                local R = M.repetition(livemids, { need = need, grammars = opts.grammars, cap = opts.cap, split_cap = opts.split_cap, env = env })
                local head, tail = 0, 0
                if R and (R.head > 0 or R.tail > 0) and distinct(R.runs) >= need then head, tail = R.head, R.tail end
                local mids, liveruns = {}, {}
                for i = 1, n do
                    if is_gone(ts[i]) then mids[i] = ts[i]
                    else
                        mids[i] = slice(i, prev[i] + head + 1, a[i] - 1 - tail)
                        liveruns[#liveruns + 1] = mids[i]
                    end
                end
                local h = fresh(mids, 'arity')
                -- the claim is the shared structural summary over the runs (one policy, `need`)
                local S = M.summarize_hedge(h, liveruns, { need = need, env = env, grammars = opts.grammars, summary = opts.summary, cap = opts.cap, split_cap = opts.split_cap })
                S.note.head, S.note.tail = head, tail -- the columns moved out of the run beside the hole
                notes[h] = S.note
                domains[h] = { domain = S.domain, origin = 'derived' }
                for d = 1, head do kids[#kids + 1] = column_at(function(i) return prev[i] + d end) end
                kids[#kids + 1] = M.hole(h, true)
                for d = tail - 1, 0, -1 do kids[#kids + 1] = column_at(function(i) return a[i] - 1 - d end) end
            end
            if a ~= final then kids[#kids + 1] = column_at(function(i) return a[i] end) end
            for _, i in ipairs(live) do prev[i] = a[i] end
        end
        for j = suf - 1, 0, -1 do kids[#kids + 1] = column_at(function(i) return lens[i] - j end) end
        return { k = ts[live[1]].k, kids = kids }
    end

    -- ── the KEYED-TABLE FRAGMENT of commutative generalization ────────────────
    -- Full C-generalization is FINITARY (Alpuente et al. 2014): several incomparable
    -- lggs. Tables whose fields all carry distinct literal keys are a fragment where the
    -- alignment is forced by the key, so the answer is unique again. Fields present in
    -- every instance align by key; the rest become one hedge hole.
    local function table_lgg(ts, keyed)
        local kids, common = {}, {}
        for _, key in ipairs(keyed[1].order) do
            local col, all = {}, true
            for i = 1, n do
                local p = keyed[i].map[key]
                if not p then all = false; break end
                col[i] = p.kids[2]
            end
            if all then
                common[key] = true
                kids[#kids + 1] = { k = 'pair', kids = { M.copy(keyed[1].map[key].kids[1]), go(col, 'pair') } }
            end
        end
        local rests, extra = {}, false
        for i = 1, n do
            local r = {}
            for _, key in ipairs(keyed[i].order) do
                if not common[key] then r[#r + 1] = keyed[i].map[key] end
            end
            if #r > 0 then extra = true end
            rests[i] = M.seq(r)
        end
        if extra then
            local h = fresh(rests, 'fields')
            domains[h] = { domain = M.rep(M.open()), origin = 'derived' }
            kids[#kids + 1] = M.hole(h, true)
        end
        return { k = 'table', kids = kids }
    end

    local function across_boundary(ts, g)
        local parsed = {}
        for i = 1, n do
            if is_gone(ts[i]) then parsed[i] = ts[i]
            else
                if type(ts[i].v) ~= 'string' then return nil end
                parsed[i] = M.grammars[g].parse(ts[i].v)
                if not parsed[i] then return nil end
            end
        end
        counter = counter + 1
        -- the store (memo, values) is SHARED: a value tuple seen outside the string and again
        -- inside it is one hole, Plotkin's rule across the boundary
        local inner = M.generalize(parsed, { need = need, env = env, prefix = prefix .. counter .. '.',
            grammars = opts.grammars, linear = opts.linear, positional = opts.positional,
            memo = memo, values = values })
        for h, e in pairs(inner.template.holes) do if domains[h] == nil then domains[h] = M.copy(e) end end
        for h, nt in pairs(inner.notes) do notes[h] = nt end
        return { k = 'embed', g = g, kids = { inner.template.body } }
    end
    -- ── the KEYED arm (KEYED.md): kids meet by key. A key every live member carries
    -- generalizes its kids as one column; a key some carry gets a PRESENCE hole (its
    -- value vector is present/absent) and its kid is generalized over the members that
    -- have it, the others threaded through as absent. The keys come in first-occurrence
    -- order over the members; whether that order is the same in every member is recorded
    -- on the node (`order`), a claim when `need` distinct members agree.
    local function keyed_lgg(ts, live)
        local first = ts[live[1]]
        for _, i in ipairs(live) do
            if ts[i].align ~= first.align or not same_key(ts[i].key, first.key) then return M.hole(fresh(ts, 'alignment')) end
        end
        local order, seen, maps, seqs = {}, {}, {}, {}
        for _, i in ipairs(live) do
            local ok, ks = pcall(M.keys, ts[i])
            if not ok then return M.hole(fresh(ts, 'unkeyable')) end
            maps[i] = {}
            for _, e in ipairs(ks) do
                maps[i][e.key] = e.kid
                if not seen[e.key] then seen[e.key] = true; order[#order + 1] = e.key end
            end
            -- the order NOTE reads the kids as the member wrote them, not the canonical order
            local seqi = {}
            for _, kid in ipairs(ts[i].kids) do seqi[#seqi + 1] = M.key_of(ts[i], kid) end
            seqs[i] = table.concat(seqi, '\1')
        end
        -- a merge-keyed list's elements under one key must agree in kind and discipline: the
        -- key cannot survive a divergence there, and a bare hole may not be a kid of a keyed
        -- node, so the WHOLE list becomes the hole. Checked over every key BEFORE any column is
        -- generalized, so no hole is registered for a list that then escalates.
        if first.key then
            for _, key in ipairs(order) do
                local ref
                for _, i in ipairs(live) do
                    local kid = maps[i][key]
                    if kid then
                        if ref and (kid.k ~= ref.k or kid.align ~= ref.align or not same_key(kid.key, ref.key)) then return M.hole(fresh(ts, 'alignment')) end
                        ref = ref or kid
                    end
                end
            end
        end
        local kids = {}
        for _, key in ipairs(order) do
            local col, pres, optional = {}, {}, false
            for i = 1, n do
                if is_gone(ts[i]) then col[i], pres[i] = GONE, GONE
                elseif maps[i][key] then col[i], pres[i] = maps[i][key], M.present()
                else col[i], pres[i] = GONE, M.absent(); optional = true end
            end
            local kid = go(col, first.k)
            assert(not (is_hole(kid) and not kid.opt), 'keyed: a bare hole as a kid of a keyed node (the pre-check should have escalated)')
            if optional then kid = M.copy(kid); kid.opt = fresh(pres, 'presence') end
            kids[#kids + 1] = kid
        end
        local stable = true
        for x = 2, #live do if seqs[live[x]] ~= seqs[live[1]] then stable = false end end
        local node = { k = first.k, align = first.align, key = first.key, kids = kids,
            order = { stable = stable, support = #live, claimed = stable and #live >= need } }
        return node
    end
    go = function(ts, parent)
        local live = live_of(ts)
        if #live == 0 then return GONE end
        local k = ts[live[1]].k
        for _, i in ipairs(live) do if ts[i].k ~= k then return M.hole(fresh(ts, 'kind')) end end
        if ts[live[1]].align then return keyed_lgg(ts, live) end
        for _, i in ipairs(live) do if ts[i].align then return M.hole(fresh(ts, 'alignment')) end end
        if k == 'lit' then
            local same = true
            for _, i in ipairs(live) do if ts[i].v ~= ts[live[1]].v then same = false end end
            if same then return M.copy(ts[live[1]]) end
            local g = opts.grammars and parent and opts.grammars[parent]
            if g then
                local e = across_boundary(ts, g)
                if e then return e end -- otherwise: some instance did not parse, opaque hole
            end
            return M.hole(fresh(ts, 'literal'))
        end
        if k == 'name' then
            for _, i in ipairs(live) do if ts[i].n ~= ts[live[1]].n then return M.hole(fresh(ts, 'name')) end end
            return M.copy(ts[live[1]])
        end
        if k == 'hole' then
            for _, i in ipairs(live) do if ts[i].h ~= ts[live[1]].h then return M.hole(fresh(ts, 'hole')) end end
            return M.copy(ts[live[1]])
        end
        if k == 'table' and not opts.positional and #live == n then
            local keyed = M.keyed_fields(ts)
            if keyed then return table_lgg(ts, keyed) end
        end
        local lens, same = {}, true
        for _, i in ipairs(live) do
            lens[i] = #(ts[i].kids or {})
            if lens[i] ~= lens[live[1]] then same = false end
        end
        if not same then return arity_divergence(ts, lens) end
        local kids = {}
        for j = 1, lens[live[1]] do
            local col = {}
            for i = 1, n do col[i] = is_gone(ts[i]) and ts[i] or ts[i].kids[j] end
            kids[j] = go(col, k)
        end
        return M.rebuild(ts[live[1]], kids)
    end

    local body = go(instances, nil)
    local T = M.template(body, domains)

    -- recursion pass: a hole whose values are themselves instances of T, to distinct depths
    for h, note in pairs(notes) do
        local partial = false
        for i = 1, n do if values[i][h] == nil then partial = true end end
        if partial then note.under_optional = true end
        if not T.holes[h].rep and not is_hole(T.body) and not partial and not T.holes[h].presence then
            local col = {}
            for i = 1, n do col[i] = values[i][h] end
            local S = M.summarize_recursion(T, h, col, { need = need, env = env, grammars = opts.grammars, summary = opts.summary, cap = opts.cap })
            for k, v in pairs(S.note) do note[k] = v end
            if S.domain then T.holes[h].domain = S.domain end
        end
    end
    return { template = T, values = values, notes = notes, env = env }
end
end
