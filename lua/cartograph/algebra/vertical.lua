-- A PART OF `cartograph.algebra.core`, which requires this file at its end and
-- passes its own module table in. ⚠ IT DOES NOT `require` CORE BACK: that is a
-- load cycle — Lua says "loop or previous error loading module".
-- ★ NINE SHARED FILE-LOCALS. ⚠ THE UNION OVER-INCLUDES AND THE PARTS FENCE
-- PRUNED IT: the capture hazards also named `template` and `values`, which are
-- reached here as `M.template(…)` — MODULE functions needing nothing passed.
-- Binding them made PARTS hand round two names core does not define, and the
-- fence caught it on its first run. ⇒ UNION, THEN PRUNE BY THE FENCE, the most of any part — and the count is a UNION:
-- the free-identifier scan found 8 and the plan's capture hazards found 4, and
-- NEITHER SET CONTAINED THE OTHER. `key` is in the hazards and not the scan
-- (the scan reads CALL targets and `key` is passed as a VALUE); `slice` and
-- `vsym` are in the scan and not the hazards (their call sites do not resolve).
-- ⚠ USE THE UNION. Trusting the scan alone cost a runtime `attempt to call
-- global 'key'` here; trusting the hazards alone cost the same thing on
-- `slice` two sections ago.
-- This section is the alignment machinery and every other part borrows from it — this section is the
-- alignment machinery and every other part borrows from it. ⚠ THEY STAY IN CORE
-- DELIBERATELY: `slice` and `lcs_alignments` are read by `termgraph` and by
-- `M.rigidity.lcs`, and core's PARTS table is what hands them round. A local
-- that left with this section would take those with it.
-- ⚠ THIS PART BINDS `cat_flat` AND `is_strict_prefix`, NOT `cat`/`is_prefix`
-- (CART-0924). Core declared each of those names TWICE, and the SECOND
-- definition of both lived INSIDE this section — so this is the code that
-- meant them. `local PARTS = {...}` is built at the BOTTOM of core, where a
-- duplicated name resolves to the LAST definition, so every OTHER part was
-- silently handed these instead of the ones it was written against. Lua
-- scoping is positional; the PARTS protocol is not, so the names are unique
-- now and the ambiguity cannot come back (the parts fence checks it).
return function (M, SHARED)
local cat, is_prefix, key, lcp, lcs_alignments, lexlt, prefix_eq, slice, vsym =
    SHARED.cat_flat, SHARED.is_strict_prefix, SHARED.key, SHARED.lcp, SHARED.lcs_alignments, SHARED.lexlt, SHARED.prefix_eq, SHARED.slice, SHARED.vsym

-- I1 ⋈_{I3} I2: I1 and I2 share a proper ancestor that is not an ancestor of I3,
-- and none of the three is an ancestor of another
local function bowtie(I1, I3, I2)
    if prefix_eq(I1, I2) or prefix_eq(I2, I1) or prefix_eq(I1, I3) or prefix_eq(I3, I1)
        or prefix_eq(I2, I3) or prefix_eq(I3, I2) then return false end
    local L = lcp(I1, I2)
    if #L == 0 then return false end
    return not prefix_eq(L, I3)
end

--- the pre-order word of a hedge, each symbol with its position
function M.word(H)
    local out = {}
    local function walk(hedge, prefix)
        for i, t in ipairs(hedge) do
            local pos = cat(prefix, { i })
            out[#out + 1] = { sym = vsym(t), pos = pos }
            if t.kids then walk(t.kids, pos) end
        end
    end
    walk(H, {})
    return out
end

--- Section 3: an alignment is admissible iff it has no collision. Two-element collision:
--- ancestor on one side, not on the other. Three-element: Ik ⋈_{In} Il and Jl ⋈_{Jk} Jn,
--- over every assignment of the three roles.
function M.admissible(a)
    -- an ALIGNMENT first (BK §3): I1 < ... < Im and J1 < ... < Jm in preorder, one-to-one
    local order = {}
    for i = 1, #a do order[i] = a[i] end
    table.sort(order, function(x, y) return lexlt(x.I, y.I) end)
    for i = 2, #order do
        if key(order[i - 1].I) == key(order[i].I) or not lexlt(order[i - 1].J, order[i].J) then
            return false, { kind = 'not-an-alignment', i - 1, i }
        end
    end
    for k = 1, #a do
        for l = 1, #a do
            if k ~= l then
                local Ik, Il, Jk, Jl = a[k].I, a[l].I, a[k].J, a[l].J
                if is_prefix(Ik, Il) ~= is_prefix(Jk, Jl) then
                    return false, { kind = 'two', k, l }
                end
            end
        end
    end
    for k = 1, #a do
        for l = 1, #a do
            for n = 1, #a do
                if k ~= l and l ~= n and k ~= n then
                    if bowtie(a[k].I, a[n].I, a[l].I) and bowtie(a[l].J, a[k].J, a[n].J) then
                        return false, { kind = 'three', k, l, n }
                    end
                end
            end
        end
    end
    return true
end

--- Every longest common subsequence of the two pre-order words, kept if admissible. ⚠ This
--- is a FILTER over word alignments, not the paper's skeleton: they name constrained LCS on
--- trees (Zhang 1995) and agreement subtrees, which are admissible by construction. Most
--- word alignments collide; `candidates` vs `#admissible` says how many.
function M.skeletons(S, Q, opts)
    opts = opts or {}
    local cap = opts.cap or 64
    local wS, wQ = M.word(S), M.word(Q)
    local A, B = {}, {}
    for i, e in ipairs(wS) do A[i] = e.sym end
    for j, e in ipairs(wQ) do B[j] = e.sym end
    local als, trunc = lcs_alignments(A, B, cap)
    local out = { admissible = {}, candidates = #als, truncated = trunc }
    for _, al in ipairs(als) do
        local a = {}
        for _, p in ipairs(al) do a[#a + 1] = { sym = A[p[1]], I = wS[p[1]].pos, J = wQ[p[2]].pos } end
        if M.admissible(a) then out.admissible[#out.admissible + 1] = a end
    end
    return out
end

-- the rigid lgg of hedges S, Q with respect to an admissible alignment `a`
local function rigid_lgg(S, Q, a)
    local ctx = { memo = {}, nh = 0, nc = 0, L = {}, R = {} }
    -- a context value from frames (outer to inner); a frame is {left, node?, right}
    local function build(fr)
        if #fr == 0 then return M.seq({ M.cursor() }) end
        local f = fr[1]
        local innerk = build(slice(fr, 2, #fr)).kids
        if f.node then
            return M.seq(cat(M.copy(f.left), { M.rebuild(f.node, innerk) }, M.copy(f.right)))
        end
        return M.seq(cat(M.copy(f.left), innerk, M.copy(f.right)))
    end
    -- the store: one variable per distinct pair (Mer-S); empties vanish (Clr-S)
    local function hedgevar(S1, Q1)
        if #S1 == 0 and #Q1 == 0 then return {} end
        local key = 'H\1' .. M.show(M.seq(S1)) .. '\1' .. M.show(M.seq(Q1))
        local h = ctx.memo[key]
        if not h then
            ctx.nh = ctx.nh + 1
            h = 'x' .. ctx.nh
            ctx.memo[key] = h
            ctx.L[h], ctx.R[h] = M.seq(M.copy(S1)), M.seq(M.copy(Q1))
        end
        return { M.hole(h, true) }
    end
    local function ctxvar(cs, ds, inner)
        if #cs == 0 and #ds == 0 then return inner end
        local vl, vr = build(cs), build(ds)
        local key = 'C\1' .. M.show(vl) .. '\1' .. M.show(vr)
        local h = ctx.memo[key]
        if not h then
            ctx.nc = ctx.nc + 1
            h = 'X' .. ctx.nc
            ctx.memo[key] = h
            ctx.L[h], ctx.R[h] = vl, vr
        end
        return { M.ctx(h, inner) }
    end
    -- Res-C: split the TOP level of each context into left siblings, singleton context,
    -- right siblings; deeper siblings stay inside the context value
    local function wrap(c, d, inner)
        if #c == 0 and #d == 0 then return inner end
        local function top(fr)
            if #fr == 0 then return {}, {}, {} end
            local f, rest = fr[1], slice(fr, 2, #fr)
            if f.node then return f.left, cat({ { node = f.node, left = {}, right = {} } }, rest), f.right end
            return f.left, rest, f.right
        end
        local cl, cs, cr = top(c)
        local dl, ds, dr = top(d)
        return cat(hedgevar(cl, dl), ctxvar(cs, ds, inner), hedgevar(cr, dr))
    end
    local function rebase(e, di, dj, drop_i, drop_j)
        local I, J = {}, {}
        for i = drop_i and 2 or 1, #e.I do I[#I + 1] = e.I[i] end
        for j = drop_j and 2 or 1, #e.J do J[#J + 1] = e.J[j] end
        if di then I[1] = I[1] - di end
        if dj then J[1] = J[1] - dj end
        return { sym = e.sym, I = I, J = J }
    end
    local process
    process = function(S1, Q1, al, c, d)
        if #al == 0 then return hedgevar(S1, Q1) end -- Sol-H
        local i1, j1 = al[1].I[1], al[1].J[1]
        local im, jm = al[#al].I[1], al[#al].J[1]
        if i1 ~= im and j1 ~= jm then -- Spl-H
            local k = 1
            while k < #al and (al[k + 1].I[1] == i1 or al[k + 1].J[1] == j1) do k = k + 1 end
            local ik, jk = al[k].I[1], al[k].J[1]
            local a1, a2 = {}, {}
            for e = 1, k do a1[#a1 + 1] = rebase(al[e], i1 - 1, j1 - 1) end
            for e = k + 1, #al do a2[#a2 + 1] = rebase(al[e], ik, jk) end
            local inner = cat(process(slice(S1, i1, ik), slice(Q1, j1, jk), a1, {}, {}),
                process(slice(S1, ik + 1, im), slice(Q1, jk + 1, jm), a2, {}, {}))
            return wrap(cat(c, { { left = slice(S1, 1, i1 - 1), right = slice(S1, im + 1, #S1) } }),
                cat(d, { { left = slice(Q1, 1, j1 - 1), right = slice(Q1, jm + 1, #Q1) } }), inner)
        end
        if i1 == im and #al[1].I > 1 then -- Abs-L: all inside S1[i1], whose root is not aligned
            local t = S1[i1]
            local a2 = {}
            for e = 1, #al do a2[e] = rebase(al[e], nil, nil, true, false) end
            return process(t.kids or {}, Q1, a2,
                cat(c, { { left = slice(S1, 1, i1 - 1), node = t, right = slice(S1, i1 + 1, #S1) } }), d)
        end
        if j1 == jm and #al[1].J > 1 then -- Abs-R
            local t = Q1[j1]
            local a2 = {}
            for e = 1, #al do a2[e] = rebase(al[e], nil, nil, false, true) end
            return process(S1, t.kids or {}, a2, c,
                cat(d, { { left = slice(Q1, 1, j1 - 1), node = t, right = slice(Q1, j1 + 1, #Q1) } }))
        end
        -- App-A: the first element is the root of S1[i1] and of Q1[j1]
        local s, q = S1[i1], Q1[j1]
        assert(vsym(s) == vsym(q), 'not an alignment: ' .. vsym(s) .. ' vs ' .. vsym(q))
        local rest = {}
        for e = 2, #al do rest[#rest + 1] = rebase(al[e], nil, nil, true, true) end
        local kids = process(s.kids or {}, q.kids or {}, rest, {}, {})
        local nd = s.kids and M.rebuild(s, kids) or M.copy(s)
        return wrap(cat(c, { { left = slice(S1, 1, i1 - 1), right = slice(S1, i1 + 1, #S1) } }),
            cat(d, { { left = slice(Q1, 1, j1 - 1), right = slice(Q1, j1 + 1, #Q1) } }), { nd })
    end
    local body = M.seq(process(S, Q, a, {}, {}))
    local T = M.template(body, {})
    T.values = { {}, {} }
    for h in pairs(T.holes) do T.values[1][h], T.values[2][h] = ctx.L[h], ctx.R[h] end
    T.alignment = a
    return T
end

--- Rigid lggs of two terms or hedges with context and hedge variables. Pass
--- opts.alignment (an admissible alignment) or let `skeletons` enumerate admissible LCS
--- alignments. Since VMIN.md the set is MINIMIZED across alignments (BK's "generalizations
--- computed for each alignment should be compared to each other", the step their paper and
--- tool leave out): a rigid lgg that is strictly more general than another is dropped and
--- reported in `dropped`; `opts.minimize = false` returns every candidate. Minimal only
--- relative to the alignments enumerated (`skeletons.truncated` under the cap).
function M.vertical(s, q, opts)
    opts = opts or {}
    local S = s.k == 'seq' and s.kids or { s }
    local Q = q.k == 'seq' and q.kids or { q }
    local aligns, info
    if opts.alignment then
        assert(M.admissible(opts.alignment), 'alignment is not admissible')
        aligns = { opts.alignment }
    elseif opts.skeleton == 'zhang' or opts.skeleton == 'jwz' then
        local z = (opts.skeleton == 'zhang' and M.zhang or M.jwz)(S, Q)
        info = { candidates = 1, admissible = { z.alignment }, size = z.size }
        aligns = info.admissible
    else
        info = M.skeletons(S, Q, opts)
        aligns = info.admissible
    end
    local out, seen = { templates = {}, skeletons = info }, {}
    for _, a in ipairs(aligns) do
        local T = rigid_lgg(S, Q, a)
        local key = M.show(T.body)
        if not seen[key] then
            seen[key] = true
            out.templates[#out.templates + 1] = T
        end
    end
    out.candidates = #out.templates
    out.truncated = info and info.truncated or false
    if opts.minimize ~= false then
        -- opts.cap bounds the alignment enumeration (skeletons); the matching budget of each comparison is opts.match_cap
        local kept, dropped, refusals = M.minimize(out.templates, { defs = opts.env and opts.env.defs, cap = opts.match_cap })
        out.templates, out.dropped, out.budget_refusals = kept, dropped, refusals
    end
    return out
end
end
