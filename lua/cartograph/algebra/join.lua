-- A PART OF `cartograph.algebra.core`, which requires this file at its end and
-- passes its own module table in. ⚠ IT DOES NOT `require` CORE BACK: that is a
-- load cycle — Lua says "loop or previous error loading module".
-- ★ THE UNION WAS TWELVE AND THE TRUTH IS SIX. The capture hazards named 12 and
-- the free-identifier scan 4; the six below are the names that are (a) a core
-- file-local, (b) used here, and (c) NOT defined here. `lgg`, `at`, `slice` and
-- `values` came WITH the section — they were private to it — and `instance`,
-- `parse`, `template` are not core locals at all.
-- ⚠ `unpack` IS IN THE LIST AND LOOKS LIKE A LUA GLOBAL: core binds the
-- `table.unpack or unpack` idiom once as a file-local, so a part that lost it
-- would get 5.1's global on LuaJIT and nil elsewhere.
return function (M, SHARED)
local anchor_fit, derived, fits, hedged_run, is_hole, same_key, subst, unpack =
    SHARED.anchor_fit, SHARED.derived, SHARED.fits, SHARED.hedged_run, SHARED.is_hole,
    SHARED.same_key, SHARED.subst, SHARED.unpack

local function policy_of(opts)
    if type(opts) == 'number' then return { cap = opts, summary = M.SUMMARY } end
    opts = opts or {}
    return { cap = opts.cap or 3, summary = opts.summary or M.SUMMARY }
end
local function summarizable(v) return type(v) == 'table' and not is_hole(v) and v.k ~= 'seq' and v.k ~= 'cursor' end
--- a derived domain from a value column: the fold of `widen`; empty or unsummarizable → open
function M.summarize(values, opts)
    local D
    for _, v in ipairs(values) do -- list order, so the fold law holds by construction under 'enumerate'
        if not summarizable(v) then return M.open() end
        D = D and M.join_domain(D, M.closed(v), opts) or M.closed(v)
    end
    return D or M.open()
end
--- the incremental step: a derived domain meets one more observed value
function M.widen(D, v, opts)
    if not summarizable(v) then return M.open() end
    return M.join_domain(D, M.closed(v), opts)
end
--- is this domain a value summary (as against a structural claim: rep, ref, context)?
function M.summary_shaped(D)
    if D.kind == 'open' or D.kind == 'closed' or D.kind == 'kinds' then return true end
    if D.kind == 'alt' then
        for _, a in ipairs(D.alts) do if not M.summary_shaped(a) then return false end end
        return true
    end
    return false
end
--- derived domains are summaries: recompute them from the family's value column.
--- Three arms: value summaries (always); the repetition claim of a hedge hole and the
--- recursion claim of a term hole (only when `opts.env` is passed: the element and base
--- templates live in env.defs, and without an env a claim is left as it stands rather than
--- demoted). Returns T and the notes of the structural claims, keyed by hole.
function M.rederive_domains(T, Vs, opts)
    opts = opts or {}
    local notes = {}
    local idx = {} -- member order (the column may be sparse: propagate's split families)
    for j in pairs(Vs) do idx[#idx + 1] = j end
    table.sort(idx)
    local function column(h)
        local col = {}
        for _, j in ipairs(idx) do if Vs[j][h] ~= nil then col[#col + 1] = Vs[j][h] end end
        return col
    end
    for h, e in pairs(T.holes) do
        if e.origin ~= 'supplied' and not e.ctx then
            if e.rep then
                if opts.env then
                    local col = column(h)
                    if #col > 0 then
                        local S = M.summarize_hedge(h, col, opts)
                        e.domain, notes[h] = S.domain, S.note
                    end
                end
            elseif M.summary_shaped(e.domain) then
                local col = column(h)
                if #col > 0 then e.domain = M.summarize(col, opts) end
            end
        end
    end
    if opts.env then -- the recursion claim reads the whole template, so it comes last
        for h, e in pairs(T.holes) do
            if e.origin ~= 'supplied' and not e.rep and not e.ctx then
                local col = column(h)
                if #col > 0 then
                    local S = M.summarize_recursion(T, h, col, opts)
                    notes[h] = notes[h] or {}
                    for k, v in pairs(S.note) do notes[h][k] = v end
                    if S.domain then e.domain = S.domain end
                end
            end
        end
    end
    return T, notes
end

--- the least domain above two, under the summary policy: `kinds` union; under 'enumerate'
--- closed values stay exact as `alt` up to `cap`; anything not representable collapses to open
function M.join_domain(D1, D2, opts)
    local P = policy_of(opts)
    local cap = P.cap
    if M.show_domain(D1) == M.show_domain(D2) then return M.copy(D1) end
    -- an instance of a domain widens nothing: a closed value the other side admits leaves it
    -- as it stands (with `opts.env` for @refs; this is what keeps a matching newcomer out of
    -- `widened` for claims such as (@h.base | @self))
    local env = opts and opts.env or {}
    if D2.kind == 'closed' and D1.kind ~= 'closed' and M.admits(D1, D2.value, env) then return M.copy(D1) end
    if D1.kind == 'closed' and D2.kind ~= 'closed' and M.admits(D2, D1.value, env) then return M.copy(D2) end
    -- ── the hedge arm: a repetition domain, or a closed sequence, on either side ──
    local function seq_of(D) return D.kind == 'closed' and D.value.k == 'seq' and D.value or nil end
    local function elem_summary(E, seqs) -- widen E by every element of every sequence
        for _, q in ipairs(seqs) do for _, e in ipairs(q.kids) do E = E and M.widen(E, e, opts) or M.closed(e) end end
        return E or M.open()
    end
    if D1.kind == 'rep' and D2.kind == 'rep' then
        if M.summary_shaped(D1.of) and M.summary_shaped(D2.of) then return M.rep(M.join_domain(D1.of, D2.of, opts)) end
        return M.rep(M.open()) -- two claims (element templates) do not join here: rederive with an env does
    end
    if D1.kind == 'rep' or D2.kind == 'rep' then
        local R, C = D1.kind == 'rep' and D1 or D2, D1.kind == 'rep' and D2 or D1
        local q = seq_of(C)
        if not q then return M.open() end -- a hedge facing a term: no domain we can write
        -- an instance of the claim widens nothing (this is what keeps an admitted newcomer out of `widened`)
        if not M.summary_shaped(R.of) then return M.rep(M.open()) end
        return M.rep(elem_summary(R.of, { q }))
    end
    if seq_of(D1) and seq_of(D2) then return M.rep(elem_summary(nil, { seq_of(D1), seq_of(D2) })) end
    if D1.kind == 'open' or D2.kind == 'open' then return M.open() end
    local function atoms(D) -- closed values and kind sets, or nil if not representable
        if D.kind == 'closed' then return { D.value }, {} end
        if D.kind == 'kinds' then return {}, D.set end
        if D.kind == 'alt' then
            local vs, ks = {}, {}
            for _, a in ipairs(D.alts) do
                local v2, k2 = atoms(a)
                if not v2 then return nil end
                for _, v in ipairs(v2) do vs[#vs + 1] = v end
                for k in pairs(k2) do ks[k] = true end
            end
            return vs, ks
        end
        return nil
    end
    local v1, k1 = atoms(D1)
    local v2, k2 = atoms(D2)
    if not (v1 and v2) then return M.open() end
    local vals, seen, kinds, nk = {}, {}, {}, 0
    for _, list in ipairs { v1, v2 } do
        for _, v in ipairs(list) do
            local s = M.show(v)
            if not seen[s] then seen[s] = true; vals[#vals + 1] = v end
        end
    end
    for _, set in ipairs { k1, k2 } do for k in pairs(set) do if not kinds[k] then kinds[k] = true; nk = nk + 1 end end end
    if nk == 0 and #vals == 1 then return M.closed(vals[1]) end
    if P.summary == 'enumerate' and nk == 0 and #vals <= cap then
        local alts = {}
        for i, v in ipairs(vals) do alts[i] = M.closed(v) end
        return M.alt(unpack(alts))
    end
    local list = {}
    for k in pairs(kinds) do list[#list + 1] = k end
    for _, v in ipairs(vals) do if not kinds[v.k] then kinds[v.k] = true; list[#list + 1] = v.k end end
    table.sort(list)
    return M.kinds(list)
end

--- bodies equal modulo a bijection of hole names (and equal domains when opts.domains)
function M.iso(T1, T2, opts)
    opts = opts or {}
    local f, g = {}, {}
    local function go(a, b)
        if is_hole(a) or is_hole(b) then
            if not (is_hole(a) and is_hole(b)) then return false end
            if (a.rep or false) ~= (b.rep or false) then return false end
            if f[a.h] == nil and g[b.h] == nil then f[a.h], g[b.h] = b.h, a.h
            elseif f[a.h] ~= b.h or g[b.h] ~= a.h then return false end
            if opts.domains and M.show_domain(T1.holes[a.h].domain) ~= M.show_domain(T2.holes[b.h].domain) then return false end
            return true
        end
        if a.k ~= b.k then return false end
        if not a.kids then return M.eq(a, b) end
        if #a.kids ~= #b.kids then return false end
        for i = 1, #a.kids do if not go(a.kids[i], b.kids[i]) then return false end end
        return true
    end
    return go(T1.body, T2.body)
end

function M.join(T1, T2, opts)
    opts = opts or {}
    if not T1.body then T1 = M.template(T1) end -- a ground instance is a template with no holes
    if not T2.body then T2 = M.template(T2) end
    for _, T in ipairs { T1, T2 } do
        for h, e in pairs(M.sites(T)) do
            if e.ctx then return nil, 'unsupported: hole ' .. h .. ' is a context hole (joining with context variables is not implemented)' end
        end
    end
    local used, leftcount, memo, frags, order, counter, absorbed, relaxed = {}, {}, {}, {}, {}, 0, {}, {}
    -- a fragment side with NO value: the hole sits under an optional pair the other side
    -- lacks, so that side's mapper owes nothing for it (KEYED.md)
    local NOVAL = { k = 'noval' }
    -- the domain joins read `opts.env` for @refs; `@self` is the family's template, T1
    local dopts = setmetatable({ env = { defs = (opts.env or {}).defs, self = (opts.env or {}).self or T1 } }, { __index = opts })
    local boundary = nil -- inside a boundary crossed by THIS join, new holes are named <boundary>.<n>
    for _, h in ipairs(M.hole_names(T1)) do used[h] = true end
    local function dom_of(T, t)
        if is_hole(t) then return T.holes[t.h].domain end
        if M.ground(t) then return M.closed(t) end
        if t.k == 'seq' then return M.rep(M.open()) end -- a hedge with holes inside
        return M.open() -- a fragment with holes inside: its instances are not a domain we can write
    end
    local function holes_in(t, out) -- T1's holes swallowed by a fragment
        if is_hole(t) then out[#out + 1] = t.h end
        for _, c in ipairs(t.kids or {}) do holes_in(c, out) end
        return out
    end
    local function fresh(a, b, hedge)
        local k = (hedge and 'H' or 'T') .. '\1' .. M.show(a) .. '\1' .. M.show(b)
        -- LINEAR VARIANT (survey §2): no hole twice
        if memo[k] and not opts.linear then return M.hole(memo[k], hedge) end
        local name
        if is_hole(a) then
            leftcount[a.h] = (leftcount[a.h] or 0) + 1
            name = leftcount[a.h] == 1 and a.h or (a.h .. '_' .. leftcount[a.h])
            while used[name] and name ~= a.h do name = name .. "'" end
        elseif is_hole(b) and not used[b.h] then
            name = b.h
        elseif boundary then
            repeat boundary.n = boundary.n + 1; name = boundary.prefix .. boundary.n until not used[name]
        else
            repeat counter = counter + 1; name = (opts.prefix or 'j') .. counter until not used[name]
        end
        used[name], memo[k] = true, name
        frags[name] = { left = a, right = b, hedge = hedge or nil, domain = M.join_domain(dom_of(T1, a), dom_of(T2, b), dopts) }
        order[#order + 1] = name
        if not is_hole(a) then for _, h in ipairs(holes_in(a, {})) do absorbed[#absorbed + 1] = { from = h, to = name } end end
        return M.hole(name, hedge)
    end
    local lgg
    local function slice(kids, i, j) local out = {}; for x = i, j do out[#out + 1] = kids[x] end; return M.seq(out) end
    -- ── hedge alignment (HEDGEJOIN.md, LCSJOIN.md). Unitary, in this order:
    -- BOTH HEDGED, same shape: hedge against hedge, the rest positional.
    -- FORCED by k hedges on one side: the p kids before the first and the s after the last
    --   align positionally; each interior fixed segment is placed at its leftmost fit in what
    --   remains and the hedge before it takes what precedes (Kutsia's order as the hand-built
    --   matcher takes it: leftmost hedge, shortest first). No fit: fall through.
    -- EQUAL LENGTHS: positional.
    -- LCS (Myers 1986): the kids common to both lists anchor; between two anchors a run of
    --   equal length aligns kid by kid and an unequal run is one fresh hedge. The identical
    --   prefix and suffix are the anchors' first and last stretch, so the old ends rule is the
    --   case with no anchor inside.
    local function hedges_at(kids) local out = {}; for i, c in ipairs(kids) do if is_hole(c) and c.rep then out[#out + 1] = i end end; return out end
    local function lgg_hedge(ak, bk, parent)
        local ha, hb = hedges_at(ak), hedges_at(bk)
        if opts.align == 'none' and #ak ~= #bk then return nil end -- the fixed-arity lgg: no hedge holes
        local out = {}
        local function elementwise(pa, pb, n) for i = 1, n do out[#out + 1] = lgg(ak[pa + i], bk[pb + i], parent) end end
        if #ha > 0 and #hb > 0 and #ha == #hb and #ak == #bk then
            local same = true
            for i = 1, #ha do if ha[i] ~= hb[i] then same = false end end
            if same then
                local at = {}
                for _, i in ipairs(ha) do at[i] = true end
                for i = 1, #ak do out[#out + 1] = at[i] and fresh(ak[i], bk[i], true) or lgg(ak[i], bk[i], parent) end
                return out
            end
        end
        local function forced(tk, ik, tside) -- tk holds the hedges, ik does not
            local hs = hedges_at(tk)
            local p, s = hs[1] - 1, #tk - hs[#hs]
            if #ik < p + s then return nil end
            local plan = {}
            for i = 1, p do plan[#plan + 1] = { 'pair', i, i } end
            local pos, limit = p + 1, #ik - s
            for x = 1, #hs do
                if x < #hs then
                    local seg_from, seg_to = hs[x] + 1, hs[x + 1] - 1
                    local len = seg_to - seg_from + 1
                    local q
                    for cand = pos, limit - len + 1 do
                        local okf = true
                        for d = 0, len - 1 do if not fits(tk[seg_from + d], ik[cand + d]) then okf = false; break end end
                        if okf then q = cand; break end
                    end
                    if not q then return nil end
                    plan[#plan + 1] = { 'hedge', hs[x], pos, q - 1 }
                    for d = 0, len - 1 do plan[#plan + 1] = { 'pair', seg_from + d, q + d } end
                    pos = q + len
                else
                    plan[#plan + 1] = { 'hedge', hs[x], pos, limit }
                    pos = limit + 1
                end
            end
            for i = 1, s do plan[#plan + 1] = { 'pair', #tk - s + i, #ik - s + i } end
            local res = {}
            for _, st in ipairs(plan) do
                if st[1] == 'pair' then
                    local t, i = tk[st[2]], ik[st[3]]
                    res[#res + 1] = tside == 'a' and lgg(t, i, parent) or lgg(i, t, parent)
                else
                    local sl = slice(ik, st[3], st[4])
                    res[#res + 1] = tside == 'a' and fresh(tk[st[2]], sl, true) or fresh(sl, tk[st[2]], true)
                end
            end
            return res
        end
        if #ha > 0 and #hb == 0 then local r = forced(ak, bk, 'a'); if r then return r end end
        if #hb > 0 and #ha == 0 then local r = forced(bk, ak, 'b'); if r then return r end end
        if #ak == #bk and #ha == 0 and #hb == 0 then elementwise(0, 0, #ak); return out end
        -- a hedge that found no placement above is swallowed by the run it lies in (`absorbed`)
        -- the identical prefix and suffix first (M.eq per position, the old ends rule), then the
        -- LCS inside the middle. An anchor there: equal kids, or a kid with holes inside that fits
        -- the other (the same test the forced rule places segments by), so a statement the family
        -- already abstracted still anchors.
        local minlen = math.min(#ak, #bk)
        local pre = 0
        while pre < minlen and M.eq(ak[pre + 1], bk[pre + 1]) do pre = pre + 1 end
        local suf = 0
        while suf < minlen - pre and M.eq(ak[#ak - suf], bk[#bk - suf]) do suf = suf + 1 end
        elementwise(0, 0, pre)
        local ma, mb = {}, {}
        for x = pre + 1, #ak - suf do ma[#ma + 1] = ak[x] end
        for x = pre + 1, #bk - suf do mb[#mb + 1] = bk[x] end
        local anchors = M.lcs(ma, mb, anchor_fit)
        anchors[#anchors + 1] = { #ma + 1, #mb + 1 }
        local i, j = 1, 1
        for _, an in ipairs(anchors) do
            local ra, rb = an[1] - i, an[2] - j
            local ai, bj = pre + i, pre + j -- the run's first positions in the full lists
            if ra == rb and not hedged_run(ak, ai, ai + ra - 1) and not hedged_run(bk, bj, bj + rb - 1) then elementwise(ai - 1, bj - 1, ra)
            elseif ra > 0 or rb > 0 then out[#out + 1] = fresh(slice(ak, ai, ai + ra - 1), slice(bk, bj, bj + rb - 1), true) end
            if an[1] <= #ma then out[#out + 1] = lgg(ak[pre + an[1]], bk[pre + an[2]], parent) end
            i, j = an[1] + 1, an[2] + 1
        end
        elementwise(#ak - suf, #bk - suf, suf)
        return out
    end
    -- the keyed-table fragment (survey §3.2): fields align by key, the rest is one hedge hole
    local function table_join(a, b, keyed)
        local kids, common = {}, {}
        for _, kk in ipairs(keyed[1].order) do
            local pb = keyed[2].map[kk]
            if pb then
                common[kk] = true
                kids[#kids + 1] = { k = 'pair', kids = { M.copy(keyed[1].map[kk].kids[1]), lgg(keyed[1].map[kk].kids[2], pb.kids[2], 'pair') } }
            end
        end
        local ra, rb = {}, {}
        for _, kk in ipairs(keyed[1].order) do if not common[kk] then ra[#ra + 1] = keyed[1].map[kk] end end
        for _, kk in ipairs(keyed[2].order) do if not common[kk] then rb[#rb + 1] = keyed[2].map[kk] end end
        if #ra > 0 or #rb > 0 then kids[#kids + 1] = fresh(M.seq(ra), M.seq(rb), true) end
        return { k = 'table', kids = kids }
    end
    -- ── KEYED nodes (KEYED.md): kids meet by key. A key on both sides joins its kids; a
    -- key on one side is CARRIED from that side, made optional under a presence hole whose
    -- fragments are present/absent (or the side's own presence hole), and the holes inside
    -- the carried kid get fragments with NOVAL on the other side. The kid order is T1's,
    -- then T2's new keys.
    local function carry(kid, side)
        local c = M.copy(kid)
        local T = side == 'left' and T1 or T2
        local function register(h, node_setter)
            local name = h
            if side == 'right' and used[name] then
                repeat counter = counter + 1; name = (opts.prefix or 'j') .. counter until not used[name]
            end
            if not frags[name] then
                used[name] = true
                local src = T.holes[h] or { domain = M.open(), origin = 'derived' }
                frags[name] = { left = side == 'left' and M.hole(h) or NOVAL, right = side == 'right' and M.hole(h) or NOVAL,
                    domain = M.copy(src.domain), carried = side }
                order[#order + 1] = name
            end
            if node_setter then node_setter(name) end
        end
        local function walk(t, top)
            if type(t) ~= 'table' then return end
            -- the carried kid's OWN presence is decided by the caller (`presence`); a nested
            -- optional pair keeps the presence hole it had, registered here
            if t.opt and not top then register(t.opt, function(name) t.opt = name end) end
            if is_hole(t) then
                register(t.h, function(name) t.h = name end)
                for _, x in ipairs(t.kids or {}) do walk(x) end
                return
            end
            for _, x in ipairs(t.kids or {}) do walk(x) end
        end
        walk(c, true)
        return c
    end
    local function keyed_join(a, b)
        local oka, ka = pcall(M.keys, a)
        local okb, kb = pcall(M.keys, b)
        if not (oka and okb) then return fresh(a, b) end
        local amap, bmap = {}, {}
        for _, e in ipairs(ka) do amap[e.key] = e end
        for _, e in ipairs(kb) do bmap[e.key] = e end
        local function presence(pa, pb)
            local l = pa and (pa.opt and M.hole(pa.opt) or M.present()) or M.absent()
            local r = pb and (pb.opt and M.hole(pb.opt) or M.present()) or M.absent()
            return fresh(l, r).h
        end
        -- two keyed-ordered nodes whose shared keys come in different orders: no keyed-ordered
        -- template admits both, so the least one above them RELAXES the discipline to keyed
        -- (order is no longer identity). Recorded: a relaxation is a widening of the node.
        local align = a.align
        if a.align == 'keyed-ordered' then
            local pos = {}
            for i, kid in ipairs(b.kids) do pos[M.key_of(b, kid)] = i end
            local last = 0
            for _, kid in ipairs(a.kids) do
                local k = M.key_of(a, kid)
                if pos[k] then
                    if pos[k] < last then align = 'keyed'; relaxed[#relaxed + 1] = { k = a.k, from = 'keyed-ordered', to = 'keyed' }; break end
                    last = pos[k]
                end
            end
        end
        -- a merge-keyed element diverging in kind or discipline on the two sides: the whole
        -- list is the hole, decided before any fragment is registered for its elements
        if a.key then
            for _, e in ipairs(ka) do
                local other = bmap[e.key]
                if other and (e.kid.k ~= other.kid.k or e.kid.align ~= other.kid.align or not same_key(e.kid.key, other.kid.key)) then return fresh(a, b) end
            end
        end
        local kids = {}
        for _, e in ipairs(ka) do
            local other = bmap[e.key]
            local kid
            if other then
                kid = lgg(e.kid, other.kid, a.k)
                assert(not is_hole(kid), 'keyed join: a bare hole as a kid of a keyed node (the pre-check should have escalated)')
                if e.kid.opt or other.kid.opt then kid = M.copy(kid); kid.opt = presence(e.kid, other.kid) end
            else
                kid = carry(e.kid, 'left')
                kid.opt = presence(e.kid, nil)
            end
            kids[#kids + 1] = kid
        end
        for _, e in ipairs(kb) do
            if not amap[e.key] then
                local kid = carry(e.kid, 'right')
                kid.opt = presence(nil, e.kid)
                kids[#kids + 1] = kid
            end
        end
        return { k = a.k, align = align, key = a.key, kids = kids }
    end
    lgg = function(a, b, parent)
        if is_hole(a) or is_hole(b) then return fresh(a, b) end
        if a.align or b.align then
            if a.k ~= b.k or a.align ~= b.align or not same_key(a.key, b.key) then return fresh(a, b) end
            local kid = keyed_join(a, b)
            -- a joined pair keeps a presence mark it had on either side (both carried it: no new one)
            return kid
        end
        if a.k == 'embed' or b.k == 'embed' then -- a boundary: parse the other side, or match grammars
            local ga, gb = a.k == 'embed' and a, b.k == 'embed' and b
            if ga and gb then
                if ga.g ~= gb.g then return fresh(a, b) end
                return { k = 'embed', g = ga.g, kids = { lgg(a.kids[1], b.kids[1]) } }
            end
            local e, other = ga or gb, ga and b or a
            local parsed = (other.k == 'lit' and type(other.v) == 'string') and M.grammars[e.g].parse(other.v) or nil
            if not parsed then return fresh(a, b) end
            return { k = 'embed', g = e.g, kids = { ga and lgg(a.kids[1], parsed) or lgg(parsed, b.kids[1]) } }
        end
        if a.k ~= b.k then return fresh(a, b) end
        if not a.kids then
            if M.eq(a, b) then return M.copy(a) end
            -- two strings under a grammar-bearing parent: cross the boundary (EMBED.md)
            local g = a.k == 'lit' and opts.grammars and parent and opts.grammars[parent]
            if g and type(a.v) == 'string' and type(b.v) == 'string' then
                local pa, pb = M.grammars[g].parse(a.v), M.grammars[g].parse(b.v)
                if pa and pb then
                    -- the boundary takes a name of its own and the inner holes are named under it
                    -- (generalize's convention: h2.1 is the first hole inside boundary h2)
                    local outer = boundary
                    if outer then
                        repeat outer.n = outer.n + 1 until not used[outer.prefix .. outer.n]
                        boundary = { prefix = outer.prefix .. outer.n .. '.', n = 0 }
                    else
                        repeat counter = counter + 1 until not used[(opts.prefix or 'j') .. counter]
                        boundary = { prefix = (opts.prefix or 'j') .. counter .. '.', n = 0 }
                    end
                    local inner = lgg(pa, pb, 'embed')
                    boundary = outer
                    return { k = 'embed', g = g, kids = { inner } }
                end
            end
            return fresh(a, b)
        end
        -- two leaves (a literal or a name on both sides) join by value; a stray `kids` table on a
        -- leaf (a rebuilt name) used to send them to the hedge alignment, which crashed on nil kids
        if type(a) == 'table' and type(b) == 'table' and (a.k == 'lit' or a.k == 'name') and (b.k == 'lit' or b.k == 'name') then
            if M.eq(a, b) then return M.copy(a) end
            return fresh(a, b)
        end
        if a.k == 'table' and not opts.positional then
            local keyed = M.keyed_fields { a, b }
            if keyed then return table_join(a, b, keyed) end
        end
        local kids = lgg_hedge(a.kids, b.kids, a.k)
        if not kids then return fresh(a, b) end
        return M.rebuild(a, kids)
    end
    local body = lgg(T1.body, T2.body, nil)
    local domains = {}
    for n, f in pairs(frags) do
        local src = is_hole(f.left) and T1.holes[f.left.h] or (is_hole(f.right) and T2.holes[f.right.h]) or nil
        domains[n] = { domain = f.domain, origin = src and src.origin or 'derived', was = src and src.was, was_origin = src and src.was_origin }
    end
    local J = M.template(body, domains)
    -- the join is the SEVENTH recorded edit: the log continues, pins stay undoable, and
    -- migrate can replay across it (adjoin's values are that migration)
    J.edits = M.copy(T1.edits)
    J.edits[#J.edits + 1] = { op = 'join', h = '*', with = M.copy(T2) }
    local kept, split, widened, new, overrode = {}, {}, {}, {}, {}
    for _, n in ipairs(order) do
        local f = frags[n]
        if is_hole(f.left) then
            if n == f.left.h then kept[#kept + 1] = n else split[#split + 1] = { from = f.left.h, to = n } end
            local before = M.show_domain(T1.holes[f.left.h].domain)
            if M.show_domain(f.domain) ~= before then
                widened[#widened + 1] = { h = n, from = before, to = M.show_domain(f.domain) }
                -- join stays total (it is above both inputs), but widening a SUPPLIED domain
                -- overrides a premise: recorded, and adjoin refuses it unless forced
                if T1.holes[f.left.h].origin == 'supplied' then overrode[#overrode + 1] = { h = n, from = before, to = M.show_domain(f.domain) } end
            end
        else
            new[#new + 1] = n
        end
    end
    local function mapper(side)
        return function(V, P)
            local W, unfilled = {}, {}
            for _, n in ipairs(order) do
                local f = frags[n][side]
                -- a bare hole with no value on this side sits under an optional pair this
                -- member lacks (KEYED.md): nothing is owed, and instantiate is where a hole
                -- that IS owed and missing is refused. A fragment WITH holes inside still
                -- needs every value to be built.
                if f == NOVAL or (is_hole(f) and V[f.h] == nil) then W[n] = nil
                else W[n] = subst(f, V, unfilled) end
            end
            if next(unfilled) then
                local miss = {}
                for h in pairs(unfilled) do miss[#miss + 1] = h end
                table.sort(miss)
                return nil, 'no value for ' .. table.concat(miss, ', ')
            end
            if P then return W, M.join_provenance(frags, side, P) end
            return W
        end
    end
    return { template = J, left = mapper('left'), right = mapper('right'),
        kept = kept, split = split, widened = widened, overrode = overrode, new = new, absorbed = absorbed, frags = frags, relaxed = relaxed }
end

--- a new instance joins a stored family; the family's values follow, the newcomer's are read
--- off. When I already fits T this is ADOPTION: the template is unchanged.
function M.adjoin(T, Vs, I, opts)
    opts = opts or {}
    local r, why = M.join(T, I, opts)
    if not r then return nil, why end
    if #r.overrode > 0 and not opts.force then
        -- a newcomer is an observation; it widens derived domains and may not override a premise
        local o = r.overrode[1]
        return nil, ('newcomer violates the supplied domain of hole %s (%s): open the pin, or adjoin with force'):format(o.h, o.from), r
    end
    local values = {}
    for j, V in ipairs(Vs) do
        local W, err = r.left(V)
        if not W then return nil, 'member ' .. j .. ': ' .. err end
        values[j] = W
    end
    values[#Vs + 1] = r.right({})
    M.rederive_domains(r.template, values, opts) -- exact summaries from the new column
    return { template = r.template, values = values, join = r }
end

--- provenance through a join's value map: a fragment that is a bare input hole carries
--- that hole's provenance; a rendered fragment is derived.
function M.join_provenance(frags, side, P)
    local Q = {}
    for n, f in pairs(frags) do
        local x = f[side]
        if is_hole(x) and P and P[x.h] then Q[n] = M.carry(P[x.h], 'join') else Q[n] = derived('join') end
    end
    return Q
end
end
