-- A PART OF `cartograph.algebra.core`, which requires this file at its end and
-- passes its own module table in. ⚠ IT DOES NOT `require` CORE BACK: that is a
-- load cycle — Lua says "loop or previous error loading module".
-- ★ 8 shared file-local(s), each (a) a core module-level local, (b) used
-- here and (c) not defined here — the three conditions, not a guess.
return function (M, SHARED)
local at, cat, child, is_prefix, key, occurrences, set_at, unpack =
    SHARED.at, SHARED.cat, SHARED.child, SHARED.is_prefix, SHARED.key, SHARED.occurrences, SHARED.set_at, SHARED.unpack

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

function M.classify(T, V, I2, env)
    local H = M.sites(T)
    for h, e in pairs(H) do
        if e.rep or e.ctx then return { kind = 'unsupported', why = 'hole ' .. h .. ' is a repetition/context hole' } end
    end
    local I1 = M.instantiate(T, V, env)
    if not I1.ok then return nil, 'V does not instantiate T' end
    if M.eq(I1.term, I2) then return { kind = 'none', template = T, values = V } end
    -- positional regions of change, each classified against the hole sites. (A first
    -- version tried match(T, I') first as a fast path for value edits; a mutation showed
    -- the region walk subsumes it, so it is gone.)
    local regions = {}
    M.diff_regions(I1.term, I2, {}, regions)
    local T2, V2 = T, {}
    for h, v in pairs(V) do V2[h] = v end
    local touched, fixed, relocated, changed = {}, {}, {}, {}
    for _, p in ipairs(regions) do
        local tn = at(T.body, p)
        if tn and tn.k == 'embed' then
            -- the string changed: parse both sides and classify against the inner template
            local new_s = at(I2, p)
            local parsed = (new_s.k == 'lit' and type(new_s.v) == 'string') and M.grammars[tn.g].parse(new_s.v) or nil
            if not parsed then
                return { kind = 'straddle', region = p, why = ('embed %s: the new string does not parse'):format(tn.g),
                    hint = 'the edit left the inner grammar; keep it local or fix the string' }
            end
            local Ti = M.inner_template(T, tn)
            local Vi = {}
            for _, h in ipairs(M.hole_names(Ti)) do Vi[h] = V[h] end
            local Ci = M.classify(Ti, Vi, parsed, env)
            if Ci.kind == 'straddle' or Ci.kind == 'unsupported' then
                Ci.region = Ci.region and cat(p, Ci.region) or p
                return Ci
            end
            -- inner value changes are registered per OUTER site under the boundary, so a hole
            -- shared across the boundary is held to the store law like any other
            for _, c in ipairs(Ci.changed) do
                touched[c.h] = touched[c.h] or {}
                for k, st in ipairs(H[c.h].sites) do if is_prefix(p, st.path) then touched[c.h][k] = c.to end end
            end
            for _, r in ipairs(Ci.relocated) do relocated[#relocated + 1] = r end
            if #Ci.regions > 0 then
                local T3, why = M.rewrite(T2, p, { k = 'embed', g = tn.g, kids = { Ci.template.body } })
                if not T3 then return { kind = 'straddle', region = p, why = why } end
                T2 = T3
                fixed[#fixed + 1] = p
            end
        else
        local inside, below = nil, {}
        for h, e in pairs(H) do
            for k, s in ipairs(e.sites) do
                if is_prefix(s.path, p) then inside = { h = h, k = k, s = s } end
                if #p < #s.path and is_prefix(p, s.path) then below[#below + 1] = { h = h, k = k, s = s } end
            end
        end
        if inside then
            touched[inside.h] = touched[inside.h] or {}
            touched[inside.h][inside.k] = at(I2, inside.s.path)
        else
            local sub = M.copy(at(I2, p))
            table.sort(below, function(x, y) return x.h < y.h or (x.h == y.h and x.k < y.k) end)
            -- a WRAPPER keeps the old region intact inside the new one: relocate every hole
            -- by the old region's occurrence(s), which needs no guess about values
            local whole = {}
            occurrences(sub, at(I1.term, p), {}, whole)
            for _, o in ipairs(whole) do
                -- the whole old TEMPLATE fragment goes where the old region reappears: holes,
                -- boundaries and all, so nothing has to be threaded through a string
                sub = set_at(sub, o, M.copy(at(T.body, p)))
                for _, b in ipairs(below) do
                    local rel = { unpack(b.s.path, #p + 1) }
                    relocated[#relocated + 1] = { h = b.h, site = b.k, from = b.s.path, to = cat(p, cat(o, rel)) }
                end
            end
            for _, b in ipairs(#whole > 0 and {} or below) do
                if b.s.through then
                    return { kind = 'straddle', region = p, hole = b.h,
                        why = ('hole %s sits behind a grammar boundary and the old region is not intact'):format(b.h),
                        hint = 'relocation through a boundary needs the old region kept whole' }
                end
                local occ = {}
                occurrences(sub, V[b.h], {}, occ)
                if #occ ~= 1 then
                    return { kind = 'straddle', region = p, hole = b.h, occurrences = #occ,
                        why = ('hole %s: its value occurs %d times in the rewritten region at %s'):format(b.h, #occ, key(p)),
                        -- a HINT, not a move: neither case converges by re-classifying after an edit.
                        -- 0: the edit removed the hole; propagating that would discard every member's
                        -- value, which rewrite refuses. >1: the operator must say which occurrence.
                        hint = #occ == 0 and 'hole removed: not propagated (a discard); keep the edit local or pin by hand'
                            or 'ambiguous: the value coincides with fixed text; mark the intended occurrence by hand' }
                end
                sub = set_at(sub, occ[1], M.hole(b.h))
                relocated[#relocated + 1] = { h = b.h, site = b.k, from = b.s.path, to = cat(p, occ[1]) }
            end
            local T3, why = M.rewrite(T2, p, sub)
            if not T3 then return { kind = 'straddle', region = p, why = why } end
            T2 = T3
            fixed[#fixed + 1] = p
        end
        end -- else: not an embed region
    end
    -- values touched at sites: every site of the hole must carry the same new value
    -- (`changed` may already hold changes classified inside a boundary)
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
            return { kind = 'straddle', hole = h, sites = moved,
                why = ('hole %s: changed at site(s) %s only; the store law binds all %d sites'):format(h, table.concat(moved, ','), #sites),
                proposal = { op = 'split', h = h, sites = moved, why = 'split these sites off into their own hole, then classify again' } }
        end
        V2[h] = nv
        changed[#changed + 1] = { h = h, from = V[h], to = nv }
    end
    table.sort(changed, function(x, y) return x.h < y.h end)
    -- the rebuilt triplet must reproduce the edited instance
    local r = M.instantiate(T2, V2, env)
    local widened = {}
    if not r.ok and #r.rejected > 0 then
        -- a DERIVED domain is a summary of what was seen: an observed value never refutes it,
        -- it widens it, and the widening is reported. A SUPPLIED domain (a pin, a dig with a
        -- domain) is a premise and refuses.
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
            return { kind = 'straddle', why = 'domain refuses the new value: ' .. table.concat(supplied, '; '), values = V2,
                hint = 'a supplied domain refuses: open the pin, split the hole, or keep the edit local' }
        end
        r = M.instantiate(T2, V2, env)
    end
    if not r.ok then
        local why = {}
        for _, x in ipairs(r.rejected) do why[#why + 1] = x end
        for _, x in ipairs(r.unfilled) do why[#why + 1] = 'no value for ' .. x end
        return { kind = 'straddle', why = 'domain refuses the new value: ' .. table.concat(why, '; '), values = V2 }
    end
    if not M.eq(r.term, I2) then
        -- a guard, not a rule: no test reaches it (mutation C3 survives). The store-law
        -- check above catches the shared-hole-across-a-rewrite case first.
        return { kind = 'straddle', why = 'the rebuilt triplet does not reproduce the edit' }
    end
    local kind = (#fixed > 0 and #changed > 0) and 'mixed' or (#fixed > 0 and 'template' or 'value')
    return { kind = kind, template = T2, values = V2, changed = changed, regions = fixed, relocated = relocated, widened = widened }
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
end
