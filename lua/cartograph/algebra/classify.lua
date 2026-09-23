-- A PART OF `cartograph.algebra.core`, which requires this file at its end and
-- passes its own module table in. ⚠ IT DOES NOT `require` CORE BACK: that is a
-- load cycle — Lua says "loop or previous error loading module".
-- ★ 8 shared file-local(s), each (a) a core module-level local, (b) used
-- here and (c) not defined here — the three conditions, not a guess.
return function (M, SHARED)
local at, cat, child, is_hole, key, occurrences, set_at, unpack =
    SHARED.at, SHARED.cat, SHARED.child, SHARED.is_hole, SHARED.key,
    SHARED.occurrences, SHARED.set_at, SHARED.unpack

-- ── classify an edit on one instance; propagate it by commitment ──────────────
-- USER (2026-09-12): "instantiate by editing, propagate by commitment". An edit lands on
-- one member's instance, turning I_i into I'. classify(T, V_i, I') says what it did to the
-- triplet, reading T, V_i and I' only. propagate computes previews and clusters for the
-- other members; WHICH members receive the change is the operator's decision, per cluster.
-- Scope: templates without repetition or context holes (paths in I and T then coincide
-- above the hole sites).
--   'none'      I' == I_i
--   'value'     I' still matches T: values changed, T did not. Member-local by the store
--               law; commitment scopes are member | value class | all.
--   'template'  the fixed part changed; T' keeps every hole (possibly RELOCATED, e.g. by
--               a wrapper) and V_i is unchanged. Propagates by commitment = migrate.
--   'mixed'     both; the template part propagates, the value part stays local.
--   'straddle'  the edit crossed a hole boundary. A non-linear hole changed at some sites
--               only carries a PROPOSAL (split those sites off; apply, migrate, classify
--               again: this converges). A vanished value, an ambiguous one, or a domain
--               refusing carries a HINT only: no edit makes re-classification succeed.
--- minimal positional edit regions between two terms: the paths where they first differ
--- (the lgg's hole sites at FIXED arity; exported so the re-derivation pass can replace it)
function M.diff_regions(a, b, path, out)
    if M.eq(a, b) then return end
    if a.kids and b.kids and a.k == b.k and #a.kids == #b.kids then
        for i = 1, #a.kids do M.diff_regions(a.kids[i], b.kids[i], child(path, i), out) end
        return
    end
    out[#out + 1] = path
end
local function is_prefix(p, q)
    if #p > #q then return false end
    for i = 1, #p do if p[i] ~= q[i] then return false end end
    return true
end

--- classify an edit made on ONE member's instance (PROPAGATE.md), over attributed hunks
--- (CLASSIFY.md): the regions of change are the LCS refinement between the member's
--- unfolding and the edited instance (SURGERY.md's hunks), and each is read through
--- `trace`'s origins: a hunk inside a hole's value is a value edit of that hole at that
--- site; a hunk in the fixed part is a template edit, a rewrite at the origin's template
--- path; a hunk over a hedge's elements is a value edit of the hedge, its new value the
--- new list's kids between the images of its old first and last element. The store law,
--- the wrapper relocation, the embed boundary, derived-domain widening and the rebuild
--- check are PROPAGATE.md's, unchanged. Repetition holes are no longer refused.
--- `M.classify_over(T, V, I2, hunks, origins, env)` is the core; `classify` feeds it the
--- LCS hunks and the derived `classify` (derive.lua) the join read at its sites.
local STRADDLE_HEDGE = 'the edit crossed the boundary of hedge %s at %s'
function M.classify_over(T, V, I2, hunks, r1, env)
    local H = M.sites(T)
    local O, I1 = r1.origins, r1.term
    local T2, V2 = T, {}
    for h, v in pairs(V) do V2[h] = v end
    local touched, fixed, relocated, widened = {}, {}, {}, {}
    local function straddle(rec) rec.kind = 'straddle'; return rec end
    local function prefix_of(p, n) local q = {}; for x = 1, n do q[x] = p[x] end; return q end
    local function parent_of(p) return prefix_of(p, #p - 1), p[#p] end
    -- ── a FIXED region rewritten (a node hunk in the fixed part): PROPAGATE.md's wrapper and
    -- occurrence rules, on template coordinates
    local function fixed_region(tp, old_region, sub)
        local below = {}
        for h, e in pairs(H) do
            for k, s in ipairs(e.sites) do if #tp < #s.path and is_prefix(tp, s.path) then below[#below + 1] = { h = h, k = k, s = s } end end
        end
        table.sort(below, function(x, y) return x.h < y.h or (x.h == y.h and x.k < y.k) end)
        local whole = {}
        occurrences(sub, old_region, {}, whole)
        for _, o in ipairs(whole) do
            sub = set_at(sub, o, M.copy(at(T.body, tp)))
            for _, b in ipairs(below) do
                local rel = { unpack(b.s.path, #tp + 1) }
                relocated[#relocated + 1] = { h = b.h, site = b.k, from = b.s.path, to = cat(tp, cat(o, rel)) }
            end
        end
        for _, b in ipairs(#whole > 0 and {} or below) do
            if b.s.through then
                return straddle { region = tp, hole = b.h, why = ('hole %s sits behind a grammar boundary and the old region is not intact'):format(b.h),
                    hint = 'relocation through a boundary needs the old region kept whole' }
            end
            local occ = {}
            occurrences(sub, V[b.h], {}, occ)
            if #occ ~= 1 then
                return straddle { region = tp, hole = b.h, occurrences = #occ,
                    why = ('hole %s: its value occurs %d times in the rewritten region at %s'):format(b.h, #occ, key(tp)),
                    hint = #occ == 0 and 'hole removed: not propagated (a discard); keep the edit local or pin by hand'
                        or 'ambiguous: the value coincides with fixed text; mark the intended occurrence by hand' }
            end
            sub = set_at(sub, occ[1], H[b.h].rep and M.hole(b.h, true) or M.hole(b.h))
            relocated[#relocated + 1] = { h = b.h, site = b.k, from = b.s.path, to = cat(tp, occ[1]) }
        end
        local T3, why = M.rewrite(T2, tp, sub)
        if not T3 then return straddle { region = tp, why = why } end
        T2 = T3
        fixed[#fixed + 1] = tp
        return nil
    end
    -- ── the embed boundary: the string changed, classify inside (PROPAGATE.md, EMBED.md)
    local function embed_region(tn, tp, new_s)
        local parsed = (new_s.k == 'lit' and type(new_s.v) == 'string') and M.grammars[tn.g].parse(new_s.v) or nil
        if not parsed then
            return straddle { region = tp, why = ('embed %s: the new string does not parse'):format(tn.g), hint = 'the edit left the inner grammar; keep it local or fix the string' }
        end
        local Ti = M.inner_template(T, tn)
        local Vi = {}
        for _, h in ipairs(M.hole_names(Ti)) do Vi[h] = V[h] end
        local Ci = M.classify(Ti, Vi, parsed, env)
        if Ci.kind == 'straddle' or Ci.kind == 'unsupported' then
            Ci.region = Ci.region and cat(tp, Ci.region) or tp
            return Ci
        end
        for _, c in ipairs(Ci.changed) do
            touched[c.h] = touched[c.h] or {}
            for k, st in ipairs(H[c.h].sites) do if is_prefix(tp, st.path) then touched[c.h][k] = c.to end end
        end
        for _, r in ipairs(Ci.relocated) do relocated[#relocated + 1] = r end
        if #Ci.regions > 0 then
            local T3, why = M.rewrite(T2, tp, { k = 'embed', g = tn.g, kids = { Ci.template.body } })
            if not T3 then return straddle { region = tp, why = why } end
            T2 = T3
            fixed[#fixed + 1] = tp
        end
        return nil
    end
    -- ── the lists with hunks: fixed kids become a rewrite of the parent, hedge elements a
    -- new slice, both read off the same list
    local lists, order = {}, {}
    local function list_of(P, P2)
        local k = key(P)
        if not lists[k] then lists[k] = { P = P, P2 = P2, hunks = {}, hedges = {} }; order[#order + 1] = k end
        return lists[k]
    end
    local function hedge_touched(h, site, P, P2) local L = list_of(P, P2); L.hedges[h .. '\1' .. site] = { h = h, site = site } end
    -- the value root of a hole position: the position minus the origin's relative path
    local function value_root(p2, o) return prefix_of(p2, #p2 - #o.at) end
    for _, hk in ipairs(hunks) do
        if hk.kids then
            local L = list_of(hk.at, hk.at2)
            L.hunks[#L.hunks + 1] = hk
        else
            local o = O[key(hk.at)]
            if not o then return straddle { region = hk.at, why = 'a position with no origin at ' .. key(hk.at) } end
            if o.src == 'embed' then
                local r = embed_region(at(T.body, o.at), o.at, at(I2, hk.at2))
                if r then return r end
            elseif o.src == 'hole' then
                if H[o.hole].rep then
                    -- inside an element of a hedge: the hedge's slice changes; the element's list
                    local depth = #o.at - 1 -- below the element
                    local ep, ep2 = prefix_of(hk.at, #hk.at - depth), prefix_of(hk.at2, #hk.at2 - depth)
                    local P = parent_of(ep); local P2 = parent_of(ep2)
                    hedge_touched(o.hole, o.site, P, P2)
                else
                    touched[o.hole] = touched[o.hole] or {}
                    touched[o.hole][o.site] = at(I2, value_root(hk.at2, o))
                end
            else
                local r = fixed_region(o.at, at(I1, hk.at), M.copy(at(I2, hk.at2)))
                if r then return r end
            end
        end
    end
    for _, k in ipairs(order) do
        local L = lists[k]
        local P, P2 = L.P, L.P2
        local op = O[key(P)] or { src = 'fixed', at = {} }
        local new_kids = at(I2, P2).kids
        if op.src == 'hole' then
            if H[op.hole].rep then
                local depth = #op.at - 1
                local ep, ep2 = prefix_of(P, #P - depth), prefix_of(P2, #P2 - depth)
                hedge_touched(op.hole, op.site, parent_of(ep), parent_of(ep2))
            else
                touched[op.hole] = touched[op.hole] or {}
                touched[op.hole][op.site] = at(I2, value_root(P2, op))
            end
        else
            local TP = op.at -- the template list
            local tnode = at(T.body, TP)
            -- the instance position of every template kid, and each hedge's element range
            local pos_of, range, tk_of = {}, {}, {}
            do
                local n = 0
                for ti, c in ipairs(tnode.kids) do
                    if is_hole(c) and c.rep then
                        local cnt = #(V[c.h] and V[c.h].kids or {})
                        local site = O[key(child(P, n + 1))] and O[key(child(P, n + 1))].hole == c.h and O[key(child(P, n + 1))].site or nil
                        range[ti] = { from = n + 1, to = n + cnt, h = c.h, site = site }
                        n = n + cnt
                    else
                        n = n + 1
                        pos_of[ti] = n
                        tk_of[n] = ti
                    end
                end
            end
            -- the site index of an empty hedge (no element carries it): its order among the hole's sites
            for ti, r in pairs(range) do
                if not r.site then
                    local c = 0
                    for k2, s in ipairs(H[r.h].sites) do if key(s.path) == key(child(TP, ti)) then c = k2 end end
                    r.site = c
                end
            end
            local function hedge_at(x) -- the hedge whose element range holds old position x
                for ti, r in pairs(range) do if x >= r.from and x <= r.to then return ti, r end end
            end
            local function empty_hedge_at(x) -- an empty hedge whose insertion point is before old position x
                for ti, r in pairs(range) do if r.to < r.from and r.from == x then return ti, r end end
            end
            -- decide each hunk of this list
            local tkids = {} -- the template's kid list under construction (indices shift as we go: apply from the right)
            for i, c in ipairs(tnode.kids) do tkids[i] = c end
            local fixed_hunks = {}
            table.sort(L.hunks, function(a, b) return a.kids[1] < b.kids[1] end)
            for _, hk in ipairs(L.hunks) do
                local i, j, i2, j2 = hk.kids[1], hk.kids[2], hk.kids2[1], hk.kids2[2]
                local hedges, fixed_here, termroots = {}, false, {}
                for x = i, j do
                    local ox = O[key(child(P, x))]
                    if ox and ox.src == 'embed' then -- a boundary broken apart: the holes behind it cannot be threaded
                        local inner
                        for h, e in pairs(H) do for _, s in ipairs(e.sites) do if is_prefix(ox.at, s.path) then inner = inner or h end end end
                        return straddle { region = TP, hole = inner, why = ('hole %s sits behind a grammar boundary and the old region is not intact'):format(tostring(inner)),
                            hint = 'relocation through a boundary needs the old region kept whole' }
                    end
                    if ox and ox.src == 'hole' then
                        if H[ox.hole].rep then hedges[ox.hole .. '\1' .. ox.site] = { h = ox.hole, site = ox.site }
                        elseif #ox.at == 0 then termroots[#termroots + 1] = { h = ox.hole, site = ox.site, x = x }
                        else hedges = hedges end -- deeper inside a term value: refine would have descended; a whole-kid change
                    else fixed_here = true end
                    if ox and ox.src == 'hole' and not H[ox.hole].rep and #ox.at > 0 then
                        touched[ox.hole] = touched[ox.hole] or {}
                        touched[ox.hole][ox.site] = at(I2, value_root(child(P2, x), ox))
                    end
                end
                if i > j then -- a pure insertion between old positions i-1 and i: a hedge beside it takes it
                    local _, rl = hedge_at(i - 1)
                    local _, rr = hedge_at(i)
                    local _, re = empty_hedge_at(i)
                    if rl and rr and (rl.h ~= rr.h or rl.site ~= rr.site) then
                        return straddle { region = TP, hole = rl.h, why = ('two hedges meet at %s: an insertion between %s and %s belongs to neither'):format(key(TP), rl.h, rr.h), hint = 'insert beside a fixed kid, or split the edit' }
                    end
                    local r = rl or rr or re
                    if r then hedges[r.h .. '\1' .. r.site] = { h = r.h, site = r.site } else fixed_here = true end
                end
                local nh = 0
                for _ in pairs(hedges) do nh = nh + 1 end
                if nh > 1 or (nh == 1 and (fixed_here or #termroots > 0)) then
                    local one; for _, r in pairs(hedges) do one = r end
                    return straddle { region = TP, hole = one.h, why = STRADDLE_HEDGE:format(one.h, key(TP)), hint = 'keep the edit inside the hedge, or move the fixed kids first' }
                end
                if nh == 1 then
                    local r; for _, x in pairs(hedges) do r = x end
                    hedge_touched(r.h, r.site, P, P2)
                    hk.hedge = r
                else
                    -- fixed kids (and term-hole roots in an unequal run): the parent is rewritten
                    fixed_hunks[#fixed_hunks + 1] = hk
                    hk.termroots = termroots
                end
            end
            if #fixed_hunks > 0 then
                -- the new template kids for the list: every fixed hunk applied from the right, its
                -- new kids copied from the instance, a term hole relocated by the one occurrence of
                -- its value among them (PROPAGATE.md's appended argument), refused when none or several
                for idx = #fixed_hunks, 1, -1 do
                    local hk = fixed_hunks[idx]
                    local i, j, i2, j2 = hk.kids[1], hk.kids[2], hk.kids2[1], hk.kids2[2]
                    local repl = {}
                    for x = i2, j2 do repl[#repl + 1] = M.copy(new_kids[x]) end
                    -- the value of a term hole sited in this list coinciding with new fixed text is ambiguous
                    for ti, c in ipairs(tnode.kids) do
                        if is_hole(c) and not c.rep and V[c.h] then
                            local inside = false
                            for _, tr in ipairs(hk.termroots) do if tr.h == c.h then inside = true end end
                            local occ = {}
                            for _, nk in ipairs(repl) do if M.eq(nk, V[c.h]) then occ[#occ + 1] = true end end
                            if not inside and #occ > 0 then
                                return straddle { region = TP, hole = c.h, occurrences = #occ + 1,
                                    why = ('hole %s: its value occurs %d times in the rewritten region at %s'):format(c.h, #occ + 1, key(TP)),
                                    hint = 'ambiguous: the value coincides with fixed text; mark the intended occurrence by hand' }
                            end
                        end
                    end
                    for _, tr in ipairs(hk.termroots) do
                        local occ = {}
                        for x, nk in ipairs(repl) do if M.eq(nk, V[tr.h]) then occ[#occ + 1] = x end end
                        if #occ ~= 1 then
                            return straddle { region = TP, hole = tr.h, occurrences = #occ,
                                why = ('hole %s: its value occurs %d times in the rewritten region at %s'):format(tr.h, #occ, key(TP)),
                                hint = #occ == 0 and 'hole removed: not propagated (a discard); keep the edit local or pin by hand'
                                    or 'ambiguous: the value coincides with fixed text; mark the intended occurrence by hand' }
                        end
                        repl[occ[1]] = M.hole(tr.h)
                    end
                    -- the template range: the fixed kids' template indices (a pure insertion goes
                    -- before the template kid at old position i)
                    local tfrom, tto
                    if i <= j then tfrom, tto = tk_of[i], tk_of[j]
                    else
                        tfrom = tk_of[i] or (#tkids + 1)
                        tto = tfrom - 1
                    end
                    local nk = {}
                    for x = 1, tfrom - 1 do nk[#nk + 1] = tkids[x] end
                    for _, x in ipairs(repl) do nk[#nk + 1] = x end
                    for x = tto + 1, #tkids do nk[#nk + 1] = tkids[x] end
                    tkids = nk
                end
                local before = {}
                for h, e in pairs(H) do for k2, s in ipairs(e.sites) do if #TP < #s.path and is_prefix(TP, s.path) then before[#before + 1] = { h = h, k = k2, from = s.path } end end end
                local T3, why = M.rewrite(T2, TP, M.rebuild(tnode, tkids))
                if not T3 then return straddle { region = TP, why = why } end
                T2 = T3
                fixed[#fixed + 1] = TP
                -- every hole site under the rewritten list is reported, from its old path to its new one
                local H2 = M.sites(T2)
                for _, b in ipairs(before) do
                    local to = H2[b.h] and H2[b.h].sites[b.k] and H2[b.h].sites[b.k].path or b.from
                    relocated[#relocated + 1] = { h = b.h, site = b.k, from = b.from, to = to }
                end
            end
            -- the new slice of every touched hedge: the new list's kids between the images of
            -- its old first and last element, the hunks assigned to it included
            for _, r in pairs(L.hedges) do
                local ti, rg
                for t, x in pairs(range) do if x.h == r.h and x.site == r.site then ti, rg = t, x end end
                if rg then
                    local function newpos(x) -- the image of an unchanged old position
                        local d = 0
                        for _, hk in ipairs(L.hunks) do
                            if hk.kids[2] < x or (hk.kids[1] > hk.kids[2] and hk.kids[1] <= x) then d = d + (hk.kids2[2] - hk.kids2[1]) - (hk.kids[2] - hk.kids[1]) end
                        end
                        return x + d
                    end
                    local lo, hi = math.huge, -math.huge
                    for x = rg.from, rg.to do
                        local inhunk = false
                        for _, hk in ipairs(L.hunks) do if x >= hk.kids[1] and x <= hk.kids[2] then inhunk = true end end
                        if not inhunk then local y = newpos(x); lo = math.min(lo, y); hi = math.max(hi, y) end
                    end
                    for _, hk in ipairs(L.hunks) do
                        if hk.hedge and hk.hedge.h == r.h and hk.hedge.site == r.site and hk.kids2[2] >= hk.kids2[1] then
                            lo = math.min(lo, hk.kids2[1]); hi = math.max(hi, hk.kids2[2])
                        end
                    end
                    local slice = {}
                    if lo <= hi then for x = lo, hi do slice[#slice + 1] = M.copy(new_kids[x]) end end
                    touched[r.h] = touched[r.h] or {}
                    touched[r.h][r.site] = M.seq(slice)
                end
            end
        end
    end
    -- values touched at sites: every site of the hole must carry the same new value
    local changed = {}
    for h, per in pairs(touched) do
        local sites, nv, ok = H[h].sites, nil, true
        for k = 1, #sites do
            local v = per[k]
            if v == nil then ok = false else
                if nv == nil then nv = v elseif not M.eq(nv, v) then ok = false end
            end
        end
        if not ok then
            local moved = {}
            for k = 1, #sites do if per[k] ~= nil then moved[#moved + 1] = k end end
            return straddle { hole = h, sites = moved,
                why = ('hole %s: changed at site(s) %s only; the store law binds all %d sites'):format(h, table.concat(moved, ','), #sites),
                proposal = { op = 'split', h = h, sites = moved, why = 'split these sites off into their own hole, then classify again' } }
        end
        V2[h] = nv
        changed[#changed + 1] = { h = h, from = V[h], to = nv }
    end
    table.sort(changed, function(x, y) return x.h < y.h end)
    -- the rebuilt triplet must reproduce the edited instance
    local r = M.instantiate(T2, V2, env)
    if not r.ok and #r.rejected > 0 then
        T2 = M.copy(T2)
        local supplied = {}
        for _, x in ipairs(r.rejected) do
            local h = x:match('^([^:]+):')
            if not T2.holes[h] or T2.holes[h].origin == 'supplied' then supplied[#supplied + 1] = x
            else
                local from = M.show_domain(T2.holes[h].domain)
                T2.holes[h].domain = M.widen(T2.holes[h].domain, V2[h])
                widened[#widened + 1] = { h = h, from = from, to = M.show_domain(T2.holes[h].domain) }
            end
        end
        if #supplied > 0 then
            return straddle { why = 'domain refuses the new value: ' .. table.concat(supplied, '; '), values = V2, hint = 'a supplied domain refuses: open the pin, split the hole, or keep the edit local' }
        end
        r = M.instantiate(T2, V2, env)
    end
    if not r.ok then
        local why = {}
        for _, x in ipairs(r.rejected) do why[#why + 1] = x end
        for _, x in ipairs(r.unfilled) do why[#why + 1] = 'no value for ' .. x end
        return straddle { why = 'domain refuses the new value: ' .. table.concat(why, '; '), values = V2 }
    end
    if not M.eq(r.term, I2) then return straddle { why = 'the rebuilt triplet does not reproduce the edit' } end
    local kind = (#fixed > 0 and #changed > 0) and 'mixed' or (#fixed > 0 and 'template' or 'value')
    return { kind = kind, template = T2, values = V2, changed = changed, regions = fixed, relocated = relocated, widened = widened }
end

function M.classify(T, V, I2, env)
    local H = M.sites(T)
    for h, e in pairs(H) do if e.ctx then return { kind = 'unsupported', why = 'hole ' .. h .. ' is a context hole' } end end
    if M.has_keyed(T.body) or M.has_keyed(I2) then return { kind = 'unsupported', why = 'keyed nodes: classify reads positional regions (KEYED.md)' } end
    local r1 = M.trace(T, V, env)
    if not r1.ok then return nil, 'V does not instantiate T' end
    local I1 = r1.term -- trace's unfolding is instantiate's (both nest a sequence held by a term hole)
    if M.eq(I1, I2) then return { kind = 'none', template = T, values = V } end
    local S1, X1 = M.spans(I1)
    local S2, X2 = M.spans(I2)
    local hunks = {}
    M.refine_hunks(I1, I2, {}, {}, S1, X1, S2, X2, hunks)
    return M.classify_over(T, V, I2, hunks, r1, env)
end

--- propagate a classified edit made by member `i` to the family Vs (V_i = Vs[i]).
--- Nothing is applied: the result carries clusters, previews and a `commit` closure.
---   value part: per changed hole, the VALUE CLASS (members sharing the old value) and the
---   other members grouped by their value; commit(scope, members?) sets the new value on
---   scope 'member' | 'class' | 'all' | an explicit member list.
---   template part: migrate(T, T', Vs): clean = kept (with previews), refused = dropped
---   grouped by reason; drifted = members whose instance (opts.instances) no longer matches
---   T. commit(members) gives two families: T' over the committed, T over the rest, and the
---   join of both bodies as the record that they were one family.
function M.propagate(T, C, Vs, i, env, opts)
    opts = opts or {}
    local Ps = opts.provenance
    local out = { kind = C.kind }
    if C.kind == 'none' or C.kind == 'straddle' or C.kind == 'unsupported' then return out end
    if #C.changed > 0 then
        local holes = {}
        for _, c in ipairs(C.changed) do
            local class, others, by = {}, {}, {}
            for j, V in ipairs(Vs) do
                if M.eq(V[c.h], c.from) then class[#class + 1] = j
                else
                    local k = M.show(V[c.h])
                    if not by[k] then by[k] = { value = V[c.h], members = {} }; others[#others + 1] = by[k] end
                    by[k].members[#by[k].members + 1] = j
                end
            end
            local function preview(j)
                local W = {}
                for h, v in pairs(Vs[j]) do W[h] = v end
                W[c.h] = c.to
                return M.instantiate(C.template, W, env).term, W -- C.template may carry widened domains
            end
            holes[#holes + 1] = { h = c.h, from = c.from, to = c.to, class = class, others = others, preview = preview }
        end
        out.values = {
            holes = holes,
            template = C.template, widened = C.widened, -- the family adopts the widened template with the values
            commit = function(scope)
                local members = {}
                if scope == 'member' then members = { i }
                elseif scope == 'class' then for _, hc in ipairs(holes) do for _, j in ipairs(hc.class) do members[#members + 1] = j end end
                elseif scope == 'all' then for j = 1, #Vs do members[j] = j end
                else members = scope end
                local new = {}
                for j, V in ipairs(Vs) do local W = {}; for h, v in pairs(V) do W[h] = v end; new[j] = W end
                local set = {}
                for _, j in ipairs(members) do set[j] = true end
                local prov = {}
                for j = 1, #Vs do prov[j] = (Ps and Ps[j]) and M.copy(Ps[j]) or {} end
                for _, hc in ipairs(holes) do
                    for j in pairs(set) do
                        new[j][hc.h] = hc.to
                        -- the source member's value was read off its edited instance; every
                        -- other member's is a premise the operator supplied, journaled here
                        prov[j][hc.h] = (j == i) and { src = 'observed', via = { 'edit' } }
                            or { src = 'supplied', via = { 'propagate' }, journal = { op = 'propagate', hole = hc.h, from = i, to = hc.to, scope = scope } }
                    end
                end
                return new, prov
            end,
        }
    end
    if #C.regions > 0 then
        local r = assert(M.migrate(T, C.template, Vs, env))
        local clean, refused, by = {}, {}, {}
        for _, j in ipairs(r.kept) do clean[#clean + 1] = j end
        for _, d in ipairs(r.dropped) do
            if not by[d.why] then by[d.why] = { why = d.why, members = {} }; refused[#refused + 1] = by[d.why] end
            by[d.why].members[#by[d.why].members + 1] = d.i
        end
        local drifted = {}
        if opts.instances then
            for j, I in ipairs(opts.instances) do if not M.match(T, I, env).ok then drifted[#drifted + 1] = j end end
        end
        out.template = {
            template = C.template, clean = clean, refused = refused, drifted = drifted,
            preview = function(j) return r.values[j] and M.instantiate(C.template, r.values[j], env).term end,
            commit = function(members)
                local set = {}
                for _, j in ipairs(members) do set[j] = true end
                local yes, no = { template = M.copy(C.template), values = {} }, { template = M.copy(T), values = {} }
                for j = 1, #Vs do
                    if set[j] and r.values[j] then yes.values[j] = (j == i) and C.values or r.values[j]
                    else no.values[j] = Vs[j] end
                end
                -- a commit is a membership change: each family's derived domains are recomputed
                -- from its own column (DOMAINS.md); the caller's T is copied, never mutated
                M.rederive_domains(yes.template, yes.values)
                M.rederive_domains(no.template, no.values)
                -- the least template above both, domains kept; under the 'none' rigidity so the link keeps
                -- the fixed-arity shape PROPAGATE.md was written for (a hedge hole in the link would make
                -- the next classify against it refuse; HEDGEJOIN.md)
                local link = M.join(T, C.template, { align = 'none' }).template
                return { families = { yes, no }, link = link }
            end,
        }
    end
    return out
end

-- ── classify an observation of ONE member of a KEYED family (CART-1041, CART-1040) ──
-- `classify` above refuses keyed nodes by name ("classify reads positional regions"), and
-- `kv_generalize` had no match or classify at all, so a keyed template (a locale file, a
-- manifest read as data) could be recovered but never compared against. This is the keyed
-- twin, with THE SAME KIND VOCABULARY so one consumer reads both:
--   'none'      the observation equals the member's unfolding
--   'value'     every hole the member reaches changed consistently at ALL its sites (the
--               store law), presence holes included: the family's shape still holds
--   'template'  a fixed part changed: a fixed scalar differs, a required key vanished, a key
--               the family never had appeared, a kind or an array length changed
--   'mixed'     both
--   'straddle'  a NON-LINEAR hole changed at some of its sites only: the member broke an
--               invariant the family keeps (two keys that always carry the same text); the
--               proposal is the positional one — split those sites into their own hole
-- Paths are KEY PATHS (`$.js.user_api_key.title`), native for keyed data. For a 'value'
-- result `rebuilds` says whether substituting the new values into the template reproduces
-- the observation exactly — the classification checked against the observation itself.
--- @param R table  a `kv_generalize` result
--- @param i integer the member observed
--- @param I2 any    the observed value (kv form)
function M.kv_classify(R, i, I2)
    local ABS, kind_of = M.KV_ABSENT, M.kv_kind
    local byid = {}
    for _, h in ipairs(R.holes) do byid[h.id] = h end
    local tchanges, seen, order = {}, {}, {}
    local function tchange(path, what, from, to, hole)
        tchanges[#tchanges + 1] = { path = path, what = what, from = from, to = to, hole = hole }
    end
    local function note(h, path, v)
        local s = seen[h.id]
        if not s then s = { h = h, sites = {} }; seen[h.id] = s; order[#order + 1] = h.id end
        s.sites[#s.sites + 1] = { path = path, new = v }
    end
    local walk
    walk = function(t, v, path)
        if type(t) ~= 'table' or t.null then -- a fixed scalar (or null)
            if v == ABS then tchange(path, 'removed', t, ABS)
            elseif not M.kv_eq(t, v) then tchange(path, 'changed', t, v) end
            return
        end
        if t.hole then
            local h = byid[t.hole]
            -- a REQUIRED position the member had, now gone: the family's shape broke here
            if v == ABS and h.values[i] ~= ABS then return tchange(path, 'removed', h.values[i], ABS, h.id) end
            return note(h, path, v)
        end
        if t.opt then
            note(byid[t.opt.hole], path, v ~= ABS)
            if v ~= ABS then walk(t.body, v, path) end
            return
        end
        if t.o then
            if kind_of(v) ~= 'obj' then return tchange(path, v == ABS and 'removed' or 'kind', 'object', v) end
            for _, k in ipairs(t.keys) do walk(t.o[k], v.o[k] == nil and ABS or v.o[k], path .. '.' .. k) end
            for _, k in ipairs(v.keys) do
                if t.o[k] == nil then tchange(path .. '.' .. k, 'added', ABS, v.o[k]) end
            end
            return
        end
        if t.ka then -- an array keyed by its merge field: compare as the object it aligned as
            if kind_of(v) ~= 'arr' then return tchange(path, 'kind', 'keyed array', v) end
            local o, keys = {}, {}
            for _, x in ipairs(v.a) do
                if kind_of(x) ~= 'obj' or x.o[t.keyfield] == nil then return tchange(path, 'kind', 'keyed array', v) end
                local kk = tostring(x.o[t.keyfield]); o[kk] = x; keys[#keys + 1] = kk
            end
            return walk(t.ka, { o = o, keys = keys }, path .. '[' .. t.keyfield .. ']')
        end
        if t.a then
            if kind_of(v) ~= 'arr' or #v.a ~= #t.a then
                return tchange(path, 'length', #t.a, kind_of(v) == 'arr' and #v.a or v)
            end
            for j, x in ipairs(t.a) do walk(x, v.a[j], path .. '[' .. j .. ']') end
            return
        end
    end
    walk(R.template, I2, '$')

    local vchanges, straddles = {}, {}
    table.sort(order)
    for _, id in ipairs(order) do
        local s = seen[id]
        local old, first, consistent, changed, to = s.h.values[i], nil, true, {}, nil
        -- ⚠ A PRESENCE THAT WAS NOT APPLICABLE (the parent absent: ABS) AND IS NOW `false` DID
        -- NOT CHANGE — both say "not there". Without this, a parent appearing with one child
        -- reported every sibling as vanished (Discourse, `be` and js.topic_entrance).
        local function same(new)
            if s.h.kind == 'presence' and old == ABS and new == false then return true end
            return M.kv_eq(new, old)
        end
        for _, st in ipairs(s.sites) do
            if not same(st.new) then changed[#changed + 1] = st.path; if to == nil then to = st.new end end
            if first == nil then first = st.new elseif not M.kv_eq(st.new, first) then consistent = false end
        end
        if #changed > 0 then
            if consistent and #changed == #s.sites then
                local paths = {}
                for _, st in ipairs(s.sites) do paths[#paths + 1] = st.path end
                vchanges[#vchanges + 1] = { hole = id, kind = s.h.kind, from = old, to = first, sites = paths }
            else
                straddles[#straddles + 1] = { hole = id, kind = s.h.kind, sites = changed, of = #s.sites, from = old, to = to }
            end
        end
    end

    local out = { changes = tchanges, values = vchanges, straddles = straddles }
    if #straddles > 0 then
        local st = straddles[1]
        out.kind = 'straddle'
        out.hole, out.sites = st.hole, st.sites
        out.why = ('hole %s: changed at %d of its %d site(s) only; the store law binds all of them')
            :format(st.hole, #st.sites, st.of)
        out.proposal = { op = 'split', h = st.hole, sites = st.sites,
            why = 'split these sites off into their own hole, then classify again' }
    elseif #tchanges > 0 and #vchanges > 0 then out.kind = 'mixed'
    elseif #tchanges > 0 then out.kind = 'template'
    elseif #vchanges > 0 then out.kind = 'value'
    else out.kind = 'none' end

    if out.kind == 'value' then
        -- ★ THE CLASSIFICATION, CHECKED AGAINST THE OBSERVATION: substitute and compare
        local nv = {}
        for _, c in ipairs(vchanges) do nv[c.hole] = c.to end
        local function inst(t)
            if type(t) ~= 'table' then return t end
            if t.hole then
                local v = nv[t.hole]; if v == nil then v = byid[t.hole].values[i] end
                return v
            end
            if t.opt then
                local p = nv[t.opt.hole]; if p == nil then p = byid[t.opt.hole].values[i] end
                if p ~= true then return ABS end
                return inst(t.body)
            end
            if t.ka then
                local ob = inst(t.ka)
                if ob == ABS then return ABS end
                local a = {}
                for _, key in ipairs(ob.keys) do a[#a + 1] = ob.o[key] end
                return { a = a }
            end
            if t.a then
                local a = {}
                for j, x in ipairs(t.a) do a[j] = inst(x) end
                return { a = a }
            end
            if t.o then
                local o, keys = {}, {}
                for _, key in ipairs(t.keys) do
                    local v = inst(t.o[key])
                    if v ~= ABS then o[key] = v; keys[#keys + 1] = key end
                end
                return { o = o, keys = keys }
            end
            return t
        end
        out.rebuilds = M.kv_eq(inst(R.template), I2)
    end
    return out
end
end
