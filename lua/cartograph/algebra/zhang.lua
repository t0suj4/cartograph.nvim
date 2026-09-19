-- A PART OF `cartograph.algebra.core`, which requires this file at its end and
-- passes its own module table in. ⚠ IT DOES NOT `require` CORE BACK: that is a
-- load cycle — Lua says "loop or previous error loading module".
-- ★ 6 shared file-local(s), each (a) a core module-level local, (b) used
-- here and (c) not defined here — the three conditions, not a guess.
return function (M, SHARED)
-- ⚠ `is_strict_prefix` IS BOUND, NOT DEFINED HERE (CART-0925). It travelled
-- into this part when the section was extracted, because `vertical` reaches it
-- through `SHARED` and THE GRAPH CANNOT SEE THAT — so the move-set judged it
-- private to this section and took it. PARTS then handed `vertical` a nil.
-- ⇒ EACH SPLIT MAKES THE NEXT ONE LESS SAFE while a part's dependencies are
--   invisible to the analysis that decides what travels.
local child, is_strict_prefix, key, lcp, lexlt, prefix_eq, vsym =
    SHARED.child, SHARED.is_strict_prefix, SHARED.key, SHARED.lcp, SHARED.lexlt,
    SHARED.prefix_eq, SHARED.vsym

-- ── CONSTRAINED MAPPINGS (Zhang 1995, as presented in Bille 2005 §3.4) ─────────
-- ⚠ Zhang's paper was not read (paywalled). The definition below is Bille's statement
-- of it; the algorithm is RE-DERIVED from that definition and validated in the spec
-- against a brute-force oracle over the same definition.
local function leftof(p, q) return lexlt(p, q) and not prefix_eq(p, q) end

--- Tai's three mapping conditions on a set of pairs {I=, J=}: one-to-one, ancestor iff
--- ancestor, left-of iff left-of.
function M.tai_ok(pairs)
    for i = 1, #pairs do
        for j = 1, #pairs do
            if i ~= j then
                local a, b = pairs[i], pairs[j]
                if key(a.I) == key(b.I) or key(a.J) == key(b.J) then return false, 'one-to-one' end
                if is_strict_prefix(a.I, b.I) ~= is_strict_prefix(a.J, b.J) then return false, 'ancestor' end
                if leftof(a.I, b.I) ~= leftof(a.J, b.J) then return false, 'sibling' end
            end
        end
    end
    return true
end

--- Zhang's constrained mapping (Bille §3.4): a Tai mapping such that for every triple,
--- nca(v1,v2) is a proper ancestor of v3  iff  nca(w1,w2) is a proper ancestor of w3.
--- (nca of two positions is their longest common prefix; the empty path is the hedge's
--- virtual root and is above everything.)
function M.constrained_ok(pairs)
    local ok, why = M.tai_ok(pairs)
    if not ok then return false, why end
    local n = #pairs
    for i = 1, n do
        for j = 1, n do
            for k = 1, n do
                if i ~= j and j ~= k and i ~= k then
                    local nI, nJ = lcp(pairs[i].I, pairs[j].I), lcp(pairs[i].J, pairs[j].J)
                    if is_strict_prefix(nI, pairs[k].I) ~= is_strict_prefix(nJ, pairs[k].J) then return false, 'nca' end
                end
            end
        end
    end
    return true
end

--- The LARGEST constrained common subforest with exact-label matches — what BK cite as
--- "constrained LCS" — by the recursion Zhang's constraint forces:
---   tree/tree:     roots matched + forest/forest, or either root unmatched (descend);
---   forest/forest: whole left forest under ONE right child, symmetric, or the
---                  child-sequence layer: a weighted LCS over children with subtree
---                  scores as pair weights (the reduction to string edit distance).
--- O(|S|·|Q|) subproblems; the per-pair degree products sum to O(|S|·|Q|) as well.
--- Returns { size, alignment } with the alignment in BK format and preorder.
function M.zhang(S, Q)
    local memoT, memoF = {}, {}
    local function children(item)
        local out = {}
        for i, c in ipairs(item.t.kids or {}) do out[i] = { t = c, path = child(item.path, i) } end
        return out
    end
    local CT, CF
    CT = function(a, b)
        local k = key(a.path) .. '|' .. key(b.path)
        if memoT[k] then return memoT[k] end
        local FA, FB = children(a), children(b)
        local best = { score = 0, how = 'none' }
        if vsym(a.t) == vsym(b.t) then
            local r = CF(FA, FB, a.path, b.path)
            best = { score = 1 + r.score, how = 'match', sub = r, a = a, b = b, FA = FA, FB = FB }
        end
        for _, ca in ipairs(FA) do
            local r = CT(ca, b)
            if r.score > best.score then best = { score = r.score, how = 'down', sub = r } end
        end
        for _, cb in ipairs(FB) do
            local r = CT(a, cb)
            if r.score > best.score then best = { score = r.score, how = 'down', sub = r } end
        end
        local r = CF(FA, FB, a.path, b.path)
        if r.score > best.score then best = { score = r.score, how = 'forests', sub = r, FA = FA, FB = FB } end
        memoT[k] = best
        return best
    end
    CF = function(FA, FB, pa, pb)
        local k = 'F' .. key(pa) .. '|F' .. key(pb)
        if memoF[k] then return memoF[k] end
        local best = { score = 0, how = 'empty' }
        if #FA == 0 or #FB == 0 then memoF[k] = best; return best end
        for _, cb in ipairs(FB) do -- the whole left forest under one right child
            local r = CF(FA, children(cb), pa, cb.path)
            if r.score > best.score then best = { score = r.score, how = 'into', sub = r } end
        end
        for _, ca in ipairs(FA) do
            local r = CF(children(ca), FB, ca.path, pb)
            if r.score > best.score then best = { score = r.score, how = 'into', sub = r } end
        end
        local m, n = #FA, #FB
        local E = {}
        for i = 0, m do E[i] = {}; for j = 0, n do E[i][j] = 0 end end
        for i = 1, m do
            for j = 1, n do
                E[i][j] = math.max(E[i - 1][j], E[i][j - 1], E[i - 1][j - 1] + CT(FA[i], FB[j]).score)
            end
        end
        if E[m][n] > best.score then best = { score = E[m][n], how = 'seq', E = E, FA = FA, FB = FB } end
        memoF[k] = best
        return best
    end
    local out = {}
    local collectT, collectF
    collectT = function(r)
        if r.how == 'match' then
            out[#out + 1] = { sym = vsym(r.a.t), I = r.a.path, J = r.b.path }
            collectF(r.sub)
        elseif r.how == 'down' then collectT(r.sub)
        elseif r.how == 'forests' then collectF(r.sub) end
    end
    collectF = function(r)
        if r.how == 'into' then collectF(r.sub)
        elseif r.how == 'seq' then
            local i, j, E = #r.FA, #r.FB, r.E
            while i > 0 and j > 0 do
                local pair = CT(r.FA[i], r.FB[j])
                if pair.score > 0 and E[i][j] == E[i - 1][j - 1] + pair.score then
                    collectT(pair); i, j = i - 1, j - 1
                elseif E[i][j] == E[i - 1][j] then i = i - 1
                else j = j - 1 end
            end
        end
    end
    local SA, QB = {}, {}
    for i, t in ipairs(S) do SA[i] = { t = t, path = { i } } end
    for j, t in ipairs(Q) do QB[j] = { t = t, path = { j } } end
    local top = CF(SA, QB, {}, {})
    collectF(top)
    table.sort(out, function(x, y) return lexlt(x.I, y.I) end)
    return { size = top.score, alignment = out }
end
end
