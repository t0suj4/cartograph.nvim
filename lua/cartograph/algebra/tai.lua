-- A PART OF `cartograph.algebra.core`, which requires this file at its end and
-- passes its own module table in. ⚠ IT DOES NOT `require` CORE BACK: that is a
-- load cycle — Lua says "loop or previous error loading module".
-- ★ SEVEN SHARED FILE-LOCALS, AND THE TWO INSTRUMENTS AGREED EXACTLY for the
-- first time: the plan's capture hazards named all seven, and the
-- free-identifier scan (zero on every part already adapted) found the same
-- seven. `is_prefix` is there only because of the TEXT rung — its call sites do
-- not resolve, so the resolved-edge rung could not see it (CART-0919).
-- ⚠ `is_strict_prefix`, NOT `is_prefix` (CART-0924). This section sits at 5006
-- in the original file and the second definition of that name is at 4614, so
-- THIS is the one it was written against — a fact about POSITION, which is how
-- Lua scoping works and how the PARTS table does not. The six donor tests that
-- failed when it was bound to the first definition are the whole argument for
-- taking the donor's tests along.
return function (M, SHARED)
local below, child, is_strict_prefix, key, lcp, lexlt, no_ancestors, prefix_eq, same, vsym =
    SHARED.below, SHARED.child, SHARED.is_strict_prefix, SHARED.key, SHARED.lcp,
    SHARED.lexlt, SHARED.no_ancestors, SHARED.prefix_eq, SHARED.same, SHARED.vsym

-- ── THE TAI MAPPING HIERARCHY (Lu, Su, Tang 2001, as corrected by Kuboyama 2007) ──────
-- Source: Kuboyama, "Matching and Learning in Trees", PhD thesis, U. Tokyo 2007, §2.8.6
-- and §§4.4–4.6. The LST01 paper is paywalled and was not read; the thesis quotes its
-- definition (Def. 2.70) and proves it collapses to Zhang's constraint (Prop. 4.7), then
-- gives the corrected definition (Def. 4.8) and proves it equals alignability (Thm 4.19).
-- CONVENTION: the thesis writes x < y for "x is a proper DESCENDANT of y" (the root is the
-- maximum) and x‘y for the lca. On position paths, lca = longest common prefix and
-- "x below y" = y is a strict prefix of x. The empty path is the hedge's virtual root.
local function lca(p, q) return lcp(p, q) end
local function triples(pairs, f)
    local n = #pairs
    for i = 1, n do
        for j = 1, n do
            for k = 1, n do
                if i ~= j and j ~= k and i ~= k then
                    local r = f(pairs[i], pairs[j], pairs[k])
                    if r ~= nil then return r end
                end
            end
        end
    end
end

--- LST01's PUBLISHED definition (thesis Def. 2.70), quoted for the record: for triples with
--- no ancestor among them, lca(s1,s2) ≤ lca(s1,s3) ∧ lca(s1,s3) = lca(s2,s3) iff the same
--- for t. Kuboyama Prop. 4.7: this is EQUIVALENT to the constrained condition.
function M.lst_original_ok(pairs)
    local ok, why = M.tai_ok(pairs)
    if not ok then return false, why end
    local bad = triples(pairs, function(a, b, c)
        if not (no_ancestors(a.I, b.I, c.I)) then return nil end
        local L = prefix_eq(lca(a.I, c.I), lca(a.I, b.I)) and same(lca(a.I, c.I), lca(b.I, c.I))
        local R = prefix_eq(lca(a.J, c.J), lca(a.J, b.J)) and same(lca(a.J, c.J), lca(b.J, c.J))
        if L ~= R then return true end
    end)
    if bad then return false, 'lst' end
    return true
end

--- Kuboyama's REVISED less-constrained mapping (Def. 4.8), over ALL triples:
---   lca(s1,s2) strictly below lca(s1,s3)  ⇒  lca(t2,t3) = lca(t1,t3).
--- Theorem 4.19: this is exactly the class of ALIGNABLE mappings (Jiang–Wang–Zhang).
function M.less_constrained_ok(pairs)
    local ok, why = M.tai_ok(pairs)
    if not ok then return false, why end
    local bad = triples(pairs, function(a, b, c)
        if below(lca(a.I, b.I), lca(a.I, c.I)) and not same(lca(b.J, c.J), lca(a.J, c.J)) then return true end
        if below(lca(a.J, b.J), lca(a.J, c.J)) and not same(lca(b.I, c.I), lca(a.I, c.I)) then return true end
    end)
    if bad then return false, 'less-constrained' end
    return true
end

--- Accordant mapping (thesis Def. 4.25): lca(s1,s2) = lca(s1,s3) iff lca(t1,t2) = lca(t1,t3),
--- over all triples. Strictly inside constrained.
function M.accordant_ok(pairs)
    local ok, why = M.tai_ok(pairs)
    if not ok then return false, why end
    local bad = triples(pairs, function(a, b, c)
        if same(lca(a.I, b.I), lca(a.I, c.I)) ~= same(lca(a.J, b.J), lca(a.J, c.J)) then return true end
    end)
    if bad then return false, 'accordant' end
    return true
end

--- the LEAVES of a mapping (thesis Def. 4.21): pairs with no other pair strictly below on the left
function M.mapping_leaves(pairs)
    local out = {}
    for _, p in ipairs(pairs) do
        local leaf = true
        for _, q in ipairs(pairs) do if q ~= p and is_strict_prefix(p.I, q.I) then leaf = false; break end end
        if leaf then out[#out + 1] = p end
    end
    return out
end

--- The LARGEST ALIGNABLE mapping with exact-label matches: Jiang, Wang, Zhang's alignment
--- recurrence (thesis Fig. 2.19 / eq. 2.5) in maximisation form. By Theorem 4.19 this is the
--- largest less-constrained mapping, and by the equivalence tested in the spec, the largest
--- BK-admissible skeleton — a common SUPERTREE with two embeddings, which is what a template
--- with hedge and context variables is. The D′ case (a suffix run of one forest placed under
--- the unmatched last root of the other) is "a wrapper over a run of siblings", the case
--- Zhang's constrained skeleton cannot express. Kuboyama's extra both-roots-gaps case is the
--- matched-root case with a zero score here, so it is present, not omitted. ⚠ Memoised over
--- child ranges; this does not reach JWZ's O(|S||Q|(d1+d2)²) bound.
function M.jwz(S, Q)
    local memoT, memoF = {}, {}
    local function children(item)
        local out = {}
        for i, c in ipairs(item.t.kids or {}) do out[i] = { t = c, path = child(item.path, i) } end
        out.pk = key(item.path)
        return out
    end
    local DT, DF
    DT = function(a, b)
        local k = key(a.path) .. '|' .. key(b.path)
        if memoT[k] then return memoT[k] end
        local FA, FB = children(a), children(b)
        local eqv = vsym(a.t) == vsym(b.t) and 1 or 0
        local r = DF(FA, 1, #FA, FB, 1, #FB)
        local best = { score = eqv + r.score, how = eqv == 1 and 'match' or 'gaps', sub = r, a = a, b = b }
        for _, T in ipairs(FB) do
            local q = DT(a, T)
            if q.score > best.score then best = { score = q.score, how = 'down', sub = q } end
        end
        for _, T in ipairs(FA) do
            local q = DT(T, b)
            if q.score > best.score then best = { score = q.score, how = 'down', sub = q } end
        end
        memoT[k] = best
        return best
    end
    DF = function(FA, i, j, FB, k, l)
        if i > j or k > l then return { score = 0, how = 'empty' } end
        local key_ = FA.pk .. ':' .. i .. '-' .. j .. '|' .. FB.pk .. ':' .. k .. '-' .. l
        if memoF[key_] then return memoF[key_] end
        local best
        local r = DF(FA, i, j - 1, FB, k, l)
        best = { score = r.score, how = 'dropL', sub = r }
        r = DF(FA, i, j, FB, k, l - 1)
        if r.score > best.score then best = { score = r.score, how = 'dropR', sub = r } end
        local pre = DF(FA, i, j - 1, FB, k, l - 1)
        local pair = DT(FA[j], FB[l])
        if pre.score + pair.score > best.score then
            best = { score = pre.score + pair.score, how = 'pair', sub = pre, pair = pair }
        end
        -- D′: the last right root is a gap and a suffix run FA[p..j] goes under it
        local CB = children(FB[l])
        for p = i, j do
            local left = DF(FA, i, p - 1, FB, k, l - 1)
            local under = DF(FA, p, j, CB, 1, #CB)
            if left.score + under.score > best.score then
                best = { score = left.score + under.score, how = 'run', sub = left, under = under }
            end
        end
        local CA = children(FA[j])
        for q = k, l do
            local left = DF(FA, i, j - 1, FB, k, q - 1)
            local under = DF(CA, 1, #CA, FB, q, l)
            if left.score + under.score > best.score then
                best = { score = left.score + under.score, how = 'run', sub = left, under = under }
            end
        end
        memoF[key_] = best
        return best
    end
    local out = {}
    local collectT, collectF
    collectT = function(r)
        if r.how == 'match' then out[#out + 1] = { sym = vsym(r.a.t), I = r.a.path, J = r.b.path }; collectF(r.sub)
        elseif r.how == 'gaps' then collectF(r.sub)
        elseif r.how == 'down' then collectT(r.sub) end
    end
    collectF = function(r)
        if r.how == 'empty' then return end
        if r.how == 'pair' then collectF(r.sub); collectT(r.pair)
        elseif r.how == 'run' then collectF(r.sub); collectF(r.under)
        else collectF(r.sub) end
    end
    local SA, QB = { pk = 'root' }, { pk = 'root' }
    for i, t in ipairs(S) do SA[i] = { t = t, path = { i } } end
    for j, t in ipairs(Q) do QB[j] = { t = t, path = { j } } end
    local top = DF(SA, 1, #SA, QB, 1, #QB)
    collectF(top)
    table.sort(out, function(x, y) return lexlt(x.I, y.I) end)
    return { size = top.score, alignment = out }
end
end
