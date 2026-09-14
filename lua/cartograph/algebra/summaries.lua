-- A PART OF `cartograph.algebra.core`, which requires this file at its end and
-- passes its own module table in. ⚠ IT DOES NOT `require` CORE BACK: that is a
-- load cycle — Lua says "loop or previous error loading module".
-- ★ 3 shared file-local(s), each (a) a core module-level local, (b) used
-- here and (c) not defined here — the three conditions, not a guess.
return function (M, SHARED)
local distinct, is_hole, key =
    SHARED.distinct, SHARED.is_hole, SHARED.key

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
    local elem = #elems >= 2 and M.generalize(elems, { need = need, env = env, prefix = h .. '.', grammars = opts.grammars }) or nil
    -- homogeneous = the elements share SOME shape: a fixed node, or at least one kind
    local eb = elem and elem.template.body
    local homogeneous = eb and (not is_hole(eb) or one_kind(elem.template.holes[eb.h].domain))
    local note = { why = 'arity', lengths = lens, distinct = d, need = need,
        homogeneous = homogeneous or false,
        hypothesis = elem and { rep_of = elem.template } or nil }
    if d >= need and homogeneous then
        env.defs[h .. '.elem'] = elem.template
        note.claimed = 'rep'
        return { domain = M.rep(M.ref(h .. '.elem')), note = note }
    end
    note.claimed, note.under_determined = 'open', d < need
    -- no claim: the domain is still a derived summary, of the ELEMENTS (DOMAINS.md); it used
    -- to be rep(open), "a seq of anything", which threw the kind evidence away
    return { domain = M.rep(M.summarize(elems, opts)), note = note }
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

function M.generalize(instances, opts)
    opts = opts or {}
    local n = #instances
    local need = opts.need or 3 -- distinct lengths/depths required to claim rep/rec
    local env = opts.env or { defs = {} }
    env.defs = env.defs or {}
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
        for i = 1, n do values[i][h] = vals[i] end
        -- ★ KIND AGREEMENT IS EVIDENCE: the lgg of two literals is "a literal", not
        -- "anything". In an order-sorted signature the variable carries its sort, and
        -- that sort is the vocabulary rung (CART-0864) derived from the corpus side.
        -- the domain is DERIVED: the one summary function over the value column (DOMAINS.md)
        domains[h] = { domain = M.summarize(vals, opts), origin = 'derived' }
        notes[h] = { why = why }
        return h
    end

    local go
    -- a kids-list whose lengths differ: find fixed prefix/suffix columns (same kind in every
    -- instance), and treat the varying middle as a candidate repetition
    -- The fixed prefix/suffix are the columns IDENTICAL across every instance; the varying
    -- middle is the repetition candidate. Longer fixed parts give a LESS general template,
    -- which is what "least" in lgg asks for.
    local function arity_divergence(ts, lens)
        local minlen = math.huge
        for i = 1, n do minlen = math.min(minlen, lens[i]) end
        local function identical(col_of)
            local first = col_of(1)
            for i = 2, n do if not M.eq(col_of(i), first) then return false end end
            return true
        end
        local pre = 0
        while pre < minlen and identical(function(i) return ts[i].kids[pre + 1] end) do pre = pre + 1 end
        local suf = 0
        while suf < minlen - pre and identical(function(i) return ts[i].kids[lens[i] - suf] end) do suf = suf + 1 end
        -- middles
        local mids = {}
        for i = 1, n do
            local m = {}
            for j = pre + 1, lens[i] - suf do m[#m + 1] = ts[i].kids[j] end
            mids[i] = M.seq(m)
        end
        local h = fresh(mids, 'arity')
        -- the claim is the shared structural summary over the middles (one policy, `need`)
        local S = M.summarize_hedge(h, mids, { need = need, env = env, grammars = opts.grammars, summary = opts.summary, cap = opts.cap })
        notes[h] = S.note
        domains[h] = { domain = S.domain, origin = 'derived' }
        -- rebuild kids: fixed prefix, the rep hole, fixed suffix
        local kids = {}
        for j = 1, pre do
            local col = {}
            for i = 1, n do col[i] = ts[i].kids[j] end
            kids[#kids + 1] = go(col)
        end
        kids[#kids + 1] = M.hole(h, true)
        for j = suf - 1, 0, -1 do
            local col = {}
            for i = 1, n do col[i] = ts[i].kids[lens[i] - j] end
            kids[#kids + 1] = go(col)
        end
        return { k = ts[1].k, kids = kids }
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
            if type(ts[i].v) ~= 'string' then return nil end
            parsed[i] = M.grammars[g].parse(ts[i].v)
            if not parsed[i] then return nil end
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
    go = function(ts, parent)
        local k = ts[1].k
        for i = 2, n do if ts[i].k ~= k then return M.hole(fresh(ts, 'kind')) end end
        if k == 'lit' then
            local same = true
            for i = 2, n do if ts[i].v ~= ts[1].v then same = false end end
            if same then return M.copy(ts[1]) end
            local g = opts.grammars and parent and opts.grammars[parent]
            if g then
                local e = across_boundary(ts, g)
                if e then return e end -- otherwise: some instance did not parse, opaque hole
            end
            return M.hole(fresh(ts, 'literal'))
        end
        if k == 'name' then
            for i = 2, n do if ts[i].n ~= ts[1].n then return M.hole(fresh(ts, 'name')) end end
            return M.copy(ts[1])
        end
        if k == 'hole' then
            for i = 2, n do if ts[i].h ~= ts[1].h then return M.hole(fresh(ts, 'hole')) end end
            return M.copy(ts[1])
        end
        if k == 'table' and not opts.positional then
            local keyed = M.keyed_fields(ts)
            if keyed then return table_lgg(ts, keyed) end
        end
        local lens, same = {}, true
        for i = 1, n do
            lens[i] = #(ts[i].kids or {})
            if lens[i] ~= lens[1] then same = false end
        end
        if not same then return arity_divergence(ts, lens) end
        local kids = {}
        for j = 1, lens[1] do
            local col = {}
            for i = 1, n do col[i] = ts[i].kids[j] end
            kids[j] = go(col, k)
        end
        return M.rebuild(ts[1], kids)
    end

    local body = go(instances, nil)
    local T = M.template(body, domains)

    -- recursion pass: a hole whose values are themselves instances of T, to distinct depths
    for h, note in pairs(notes) do
        if not T.holes[h].rep and not is_hole(T.body) then
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
