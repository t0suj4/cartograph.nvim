-- A PART OF `cartograph.algebra.core`, which requires this file at its end and
-- passes its own module table in. ⚠ IT DOES NOT `require` CORE BACK: that is a
-- load cycle — Lua says "loop or previous error loading module".
-- ★ 4 shared file-local(s), each (a) a core module-level local, (b) used
-- here and (c) not defined here — the three conditions, not a guess.
return function (M, SHARED)
local child, is_hole, key, occurs, subst =
    SHARED.child, SHARED.is_hole, SHARED.key, SHARED.occurs, SHARED.subst

--- the kinds envelope of a summary domain: what a family's derived domain says about SHAPE
function M.relax(D)
    if D.kind == 'closed' then return M.kinds { D.value.k } end
    if D.kind == 'alt' then
        local set, ok = {}, true
        for _, a in ipairs(D.alts) do
            local r = M.relax(a)
            if r.kind == 'kinds' then for k in pairs(r.set) do set[k] = true end else ok = false end
        end
        if ok then local l = {}; for k in pairs(set) do l[#l + 1] = k end; table.sort(l); return M.kinds(l) end
        return M.copy(D)
    end
    if D.kind == 'rep' then return M.rep(M.relax(D.of), D.min, D.max, D.period) end
    return M.copy(D) -- open, kinds, and the structural claims (ref, both) stay
end


--- the meet of two hole domains, closed domains excluded (they are equations). nil, why when disjoint.
local function meet_domains(A, B)
    if M.show_domain(A) == M.show_domain(B) then return M.copy(A) end
    if A.kind == 'open' then return M.copy(B) end
    if B.kind == 'open' then return M.copy(A) end
    if A.kind == 'closed' or B.kind == 'closed' then -- pins nested in a rep reach here: compare, never conjoin
        local P, O = A.kind == 'closed' and A or B, A.kind == 'closed' and B or A
        if O.kind == 'closed' then
            if M.eq(P.value, O.value) then return M.copy(P) end
            return nil, ('domains disjoint: %s and %s'):format(M.show_domain(A), M.show_domain(B))
        end
        if M.admits(O, P.value) then return M.copy(P) end
        return nil, ('domains disjoint: %s and %s'):format(M.show_domain(A), M.show_domain(B))
    end
    if A.kind == 'kinds' and B.kind == 'kinds' then
        local out = {}
        for k in pairs(A.set) do if B.set[k] then out[#out + 1] = k end end
        if #out == 0 then return nil, ('domains disjoint: %s and %s'):format(M.show_domain(A), M.show_domain(B)) end
        table.sort(out)
        return M.kinds(out)
    end
    if A.kind == 'rep' and B.kind == 'rep' then
        -- an open hedge takes the other side's claim, period included (an open side widens nothing)
        if A.of.kind == 'open' and not A.period then return M.rep(B.of, math.max(A.min, B.min), (A.max and B.max) and math.min(A.max, B.max) or A.max or B.max, B.period) end
        if B.of.kind == 'open' and not B.period then return M.rep(A.of, math.max(A.min, B.min), (A.max and B.max) and math.min(A.max, B.max) or A.max or B.max, A.period) end
        if (A.period or 1) ~= (B.period or 1) then return nil, ('periods differ: %d and %d'):format(A.period or 1, B.period or 1) end
        local of, why = meet_domains(A.of, B.of)
        if not of then return nil, why end
        local min, max = math.max(A.min, B.min), (A.max and B.max) and math.min(A.max, B.max) or A.max or B.max
        if max and min > max then return nil, ('repetition counts disjoint: {%d,%s} and {%d,%s}'):format(A.min, tostring(A.max or ''), B.min, tostring(B.max or '')) end
        return M.rep(of, min, max, A.period)
    end
    -- structural claims: a CONJUNCTION, kept canonical (flattened, deduplicated, kind sets merged,
    -- sorted) so the meet is symmetric and idempotent: (a & b) ∧ a = a & b
    local parts, kindset = {}, nil
    local function collect(D)
        if D.kind == 'both' then collect(D.a); collect(D.b)
        elseif D.kind == 'kinds' then
            if kindset then
                local out = {}
                for k in pairs(kindset.set) do if D.set[k] then out[#out + 1] = k end end
                if #out == 0 then return false, ('domains disjoint: %s and %s'):format(M.show_domain(kindset), M.show_domain(D)) end
                table.sort(out); kindset = M.kinds(out)
            else kindset = M.copy(D) end
        elseif D.kind ~= 'open' then parts[M.show_domain(D)] = M.copy(D) end
        return true
    end
    local ok, why = collect(A); if not ok then return nil, why end
    ok, why = collect(B); if not ok then return nil, why end
    if kindset then parts[M.show_domain(kindset)] = kindset end
    local keys = {}
    for k in pairs(parts) do keys[#keys + 1] = k end
    table.sort(keys)
    if #keys == 0 then return M.open() end
    local D = parts[keys[1]]
    for i = 2, #keys do D = M.both(D, parts[keys[i]]) end
    return D
end

--- solve a set of equations {{l, r, at}, ..} over terms with holes. H: hole name -> record
--- {domain, origin, rep}. Returns { sigma = {h -> term}, holes = {h -> record} (the free
--- holes with their meet domains), fresh = {W..}, free = {h..} } or nil, why, at.
function M.solve(eqs, H, opts)
    opts = opts or {}
    local env = opts.env or {}
    local dom, sigma, fresh, nfresh = {}, {}, {}, 0
    for h, e in pairs(H) do
        local D = e.domain or M.open()
        if opts.relax == 'derived' and e.origin ~= 'supplied' then D = M.relax(D) end
        dom[h] = { domain = D, origin = e.origin or 'derived', rep = e.rep or nil }
    end
    local pending = {}
    for i, e in ipairs(eqs) do pending[i] = { e[1], e[2], e[3] or {} } end
    local function push(l, r, at) pending[#pending + 1] = { l, r, at } end
    local function fail(why, at) return nil, why, key(at) end
    local function rep_at(kids)
        local at
        for i, c in ipairs(kids) do if is_hole(c) and c.rep then if at then return 'many' end; at = i end end
        return at or false
    end
    local function new_hedge(D)
        nfresh = nfresh + 1
        local w = (opts.prefix or 'w') .. nfresh
        while dom[w] or H[w] do w = w .. "'" end
        dom[w] = { domain = D, origin = 'derived', rep = true }
        fresh[#fresh + 1] = w
        return M.hole(w, true)
    end
    local function new_hole(D, base)
        local h = base
        while dom[h] or H[h] do h = h .. "'" end
        dom[h] = { domain = D, origin = 'derived' }
        return M.hole(h)
    end
    local function head_possible(D, t) -- could an instance of D have t's root symbol? (for alt)
        if D.kind == 'open' then return true end
        if D.kind == 'kinds' then return D.set[t.k] or false end
        if D.kind == 'closed' then return D.value.k == t.k end
        if D.kind == 'ref' then
            local T = D.name == 'self' and env.self or (env.defs or {})[D.name]
            return T ~= nil and (is_hole(T.body) or T.body.k == t.k)
        end
        if D.kind == 'alt' then for _, a in ipairs(D.alts) do if head_possible(a, t) then return true end end; return false end
        if D.kind == 'both' then return head_possible(D.a, t) and head_possible(D.b, t) end
        return true
    end
    -- CONSTRAIN: hole x (domain D) is being bound to the non-hole term t. A closed domain is
    -- an equation; kinds check the root; a @ref UNFOLDS: the def's body, holes renamed under
    -- x, is one more equation against t (unification with the grammar); alt takes the one
    -- alternative whose root can fit and refuses by name when several can; both is both.
    local constrain
    constrain = function(x, D, t, at)
        if D.kind == 'open' then return true end
        -- a hole meets the domain through a fresh carrier hole, written on the LEFT so the carrier is the
        -- one eliminated and the query keeps its own hole names
        if is_hole(t) then push(new_hole(D, x .. '.d'), t, at); return true end
        if M.ground(t) then return M.admits(D, t, { defs = env.defs, self = env.self }) end -- a ground term: membership decides
        if D.kind == 'closed' then push(M.copy(D.value), t, at); return true end
        if D.kind == 'kinds' then
            if D.set[t.k] then return true end
            return false, ('kind %s not in %s'):format(tostring(t.k), M.show_domain(D))
        end
        if D.kind == 'ref' then
            local T = D.name == 'self' and env.self or (env.defs or {})[D.name]
            if not T then return false, 'unresolved @' .. D.name end
            if M.ground(t) then return M.admits(D, t, { defs = env.defs, self = env.self }) end
            local ren = {}
            for _, g in ipairs(M.hole_names(T)) do
                local g2 = x .. '.' .. g
                while dom[g2] or H[g2] do g2 = g2 .. "'" end
                ren[g] = g2
                dom[g2] = { domain = T.holes[g].domain, origin = T.holes[g].origin or 'derived', rep = T.holes[g].rep }
            end
            local function rn(u)
                if is_hole(u) then local c = M.copy(u); c.h = ren[u.h]; return c end
                if not u.kids then return M.copy(u) end
                local kids = {}
                for i, c in ipairs(u.kids) do kids[i] = rn(c) end
                return M.rebuild(u, kids)
            end
            push(rn(T.body), t, at)
            return true
        end
        if D.kind == 'alt' then
            local fits = {}
            for _, a in ipairs(D.alts) do if head_possible(a, t) then fits[#fits + 1] = a end end
            if #fits == 0 then return false, ('no alternative of %s fits %s'):format(M.show_domain(D), M.show(t)) end
            if #fits > 1 then return false, ('several alternatives of %s fit %s: not unitary here, refused'):format(M.show_domain(D), M.show(t)) end
            return constrain(x, fits[1], t, at)
        end
        if D.kind == 'both' then
            local ok, why = constrain(x, D.a, t, at)
            if not ok then return false, why end
            return constrain(x, D.b, t, at)
        end
        if D.kind == 'rep' then
            if t.k ~= 'seq' then return false, 'a repetition binds a seq, got ' .. tostring(t.k) end
            local n = 0
            for _, e in ipairs(t.kids) do if not (is_hole(e) and e.rep) then n = n + 1 end end
            if n < D.min and not (function() for _, e in ipairs(t.kids) do if is_hole(e) and e.rep then return true end end end)() then
                return false, ('count %d below {%d,%s}'):format(n, D.min, tostring(D.max or ''))
            end
            if D.max and n > D.max then return false, ('count %d above {%d,%d}'):format(n, D.min, D.max) end
            if D.period then -- a unit of several kids: chunk the template's kids when no hedge hole cuts across them
                local hedged = false
                for _, e in ipairs(t.kids) do if is_hole(e) and e.rep then hedged = true end end
                if not hedged then
                    if #t.kids % D.period ~= 0 then return false, ('length %d is not a multiple of the period %d'):format(#t.kids, D.period) end
                    for c = 1, #t.kids / D.period do
                        local kids = {}
                        for j = 1, D.period do kids[j] = t.kids[(c - 1) * D.period + j] end
                        local ok, why = constrain(x, D.of, M.seq(kids), at)
                        if not ok then return false, ('chunk %d: %s'):format(c, why) end
                    end
                    return true
                end
            end
            for _, e in ipairs(t.kids) do
                if is_hole(e) and e.rep then
                    local de = dom[e.h]
                    local Dm, why = meet_domains(de.domain.kind == 'rep' and de.domain or M.rep(M.open()), M.rep(D.of))
                    if not Dm then return false, why end
                    dom[e.h].domain = Dm
                else
                    local ok, why = constrain(x, D.of, e, at)
                    if not ok then return false, why end
                end
            end
            return true
        end
        return false, 'unification does not handle domain ' .. tostring(D.kind)
    end
    -- VARIABLE ELIMINATION: x := t everywhere (pending equations and the solved bindings)
    local function eliminate(x, t)
        local one = { [x] = t }
        for _, e in ipairs(pending) do e[1] = subst(e[1], one, {}); e[2] = subst(e[2], one, {}) end
        for h, b in pairs(sigma) do sigma[h] = subst(b, one, {}) end
        sigma[x] = t
        dom[x] = nil
    end
    local steps, cap = 0, opts.cap or 100000
    while #pending > 0 do
        steps = steps + 1
        if steps > cap then return fail('unification budget exceeded', {}) end
        local e = table.remove(pending)
        local l, r, at = e[1], e[2], e[3]
        if is_hole(r) and not is_hole(l) then l, r = r, l end                          -- (a) swap
        if is_hole(l) and is_hole(r) and l.h == r.h then                                 -- (b) erase x = x
            -- nothing
        elseif is_hole(l) then
            local x = l.h
            if l.ctx or (is_hole(r) and r.ctx) then return fail('hole ' .. x .. ': unification with context variables is not implemented', at) end
            local dx = dom[x]
            if is_hole(r) then                                                           -- x = y
                local y = r.h
                if (l.rep or false) ~= (r.rep or false) then return fail(('hole %s: a hedge variable cannot fill a term hole'):format(l.rep and y or x), at) end
                local dy = dom[y]
                -- closed domains are equations: bind, then equate the value
                local pins = {}
                if dx.domain.kind == 'closed' then pins[#pins + 1] = dx.domain.value end
                if dy.domain.kind == 'closed' then pins[#pins + 1] = dy.domain.value end
                local Dx = dx.domain.kind == 'closed' and M.open() or dx.domain
                local Dy = dy.domain.kind == 'closed' and M.open() or dy.domain
                local D, why = meet_domains(Dx, Dy)
                if not D then return fail(('holes %s and %s: %s'):format(x, y, why), at) end
                dom[y] = { domain = D, origin = (dx.origin == 'supplied' or dy.origin == 'supplied') and 'supplied' or 'derived', rep = dy.rep }
                eliminate(x, M.hole(y, r.rep))
                for _, v in ipairs(pins) do push(M.hole(y, r.rep), v, at) end
            else                                                                          -- x = t
                if occurs(x, r) then return fail(('hole %s occurs in %s: no finite instance'):format(x, M.show(r)), at) end
                if l.rep and r.k ~= 'seq' then return fail(('hole %s: a repetition binds a seq, got %s'):format(x, tostring(r.k)), at) end
                local ok, why = constrain(x, dx.domain, r, at)
                if not ok then return fail(('hole %s: %s'):format(x, why), at) end
                eliminate(x, r)
            end
        else                                                                              -- (c) term reduction
            if l.k == 'embed' or r.k == 'embed' then
                local ge, other, swap = (l.k == 'embed') and l or r, (l.k == 'embed') and r or l, l.k ~= 'embed'
                if other.k == 'embed' then
                    if ge.g ~= other.g then return fail(('grammar %s vs %s'):format(ge.g, other.g), at) end
                    push(ge.kids[1], other.kids[1], child(at, 1))
                elseif other.k == 'lit' and type(other.v) == 'string' and M.grammars[ge.g] and M.grammars[ge.g].parse(other.v) then
                    local parsed = M.grammars[ge.g].parse(other.v)
                    if swap then push(parsed, ge.kids[1], child(at, 1)) else push(ge.kids[1], parsed, child(at, 1)) end
                else
                    return fail(('embed %s: %s is not a string of that grammar'):format(ge.g, M.show(other)), at)
                end
            elseif l.k ~= r.k then return fail(('kind %s vs %s'):format(tostring(l.k), tostring(r.k)), at)
            elseif l.k == 'lit' then
                if l.v ~= r.v then return fail(('literal %s vs %s'):format(M.show(l), M.show(r)), at) end
            elseif l.k == 'name' then
                if l.n ~= r.n then return fail(('name %s vs %s'):format(l.n, r.n), at) end
            elseif l.k == 'cursor' then
                -- equal
            else
                local ak, bk = l.kids or {}, r.kids or {}
                local ra, rb = rep_at(ak), rep_at(bk)
                if ra == 'many' or rb == 'many' then
                    return fail('several hedge holes in one list: sequence unification is not unitary there, refused', at)
                end
                if not ra and not rb then
                    if l.align or r.align then return fail('unification over keyed nodes is not implemented (KEYED.md)', at) end
                    if #ak ~= #bk then return fail(('arity: %d vs %d children'):format(#ak, #bk), at) end
                    for i = #ak, 1, -1 do push(ak[i], bk[i], child(at, i)) end
                elseif ra and rb then
                    -- one hedge hole on each side: common positional prefix and suffix, then either the
                    -- two holes are equal or a fresh hedge hole W sits between the extra fixed parts
                    local p1, s1, p2, s2 = ra - 1, #ak - ra, rb - 1, #bk - rb
                    local m, n = math.min(p1, p2), math.min(s1, s2)
                    for i = 1, m do push(ak[i], bk[i], child(at, i)) end
                    for i = 0, n - 1 do push(ak[#ak - i], bk[#bk - i], child(at, #ak - i)) end
                    local A, B, C, D = {}, {}, {}, {}
                    for i = m + 1, ra - 1 do A[#A + 1] = ak[i] end
                    for i = ra + 1, #ak - n do B[#B + 1] = ak[i] end
                    for i = m + 1, rb - 1 do C[#C + 1] = bk[i] end
                    for i = rb + 1, #bk - n do D[#D + 1] = bk[i] end
                    if #A + #B + #C + #D == 0 then
                        push(ak[ra], bk[rb], child(at, ra))
                    else
                        local Dx, Dy = dom[ak[ra].h].domain, dom[bk[rb].h].domain
                        local Dw, why = meet_domains(Dx.kind == 'rep' and Dx or M.rep(M.open()), Dy.kind == 'rep' and Dy or M.rep(M.open()))
                        if not Dw then return fail(('holes %s and %s: %s'):format(ak[ra].h, bk[rb].h, why), at) end
                        -- a repeated hedge variable makes the problem infinitary (x·a = a·x has the
                        -- unifiers x = aⁿ): every round writes one more fresh hedge hole, so the fresh
                        -- count is the budget that stops it by name (VMIN.md found it through DERIVE=instance_of)
                        if nfresh >= (opts.fresh_cap or 64) then
                            return fail('unification budget exceeded (a repeated hedge variable makes sequence unification infinitary)', at)
                        end
                        local W = new_hedge(M.rep(Dw.of))
                        -- X = C W D and Y = A W B; by construction one of A, C and one of B, D is empty
                        local xs, ys = {}, {}
                        for _, t in ipairs(C) do xs[#xs + 1] = t end; xs[#xs + 1] = W; for _, t in ipairs(D) do xs[#xs + 1] = t end
                        for _, t in ipairs(A) do ys[#ys + 1] = t end; ys[#ys + 1] = W; for _, t in ipairs(B) do ys[#ys + 1] = t end
                        push(ak[ra], M.seq(xs), child(at, ra))
                        push(bk[rb], M.seq(ys), child(at, rb))
                    end
                else
                    -- one hedge hole: the fixed parts before and after it align positionally (FORCED)
                    local hk, ok_, r_ = ra and ak or bk, ra and bk or ak, ra or rb
                    local p, sfx = r_ - 1, #hk - r_
                    if #ok_ < p + sfx then return fail(('arity: %d children for %d fixed parts around a hedge hole'):format(#ok_, p + sfx), at) end
                    for i = 1, p do push(hk[i], ok_[i], child(at, i)) end
                    for i = 0, sfx - 1 do push(hk[#hk - i], ok_[#ok_ - i], child(at, #hk - i)) end
                    local mid = {}
                    for i = p + 1, #ok_ - sfx do mid[#mid + 1] = ok_[i] end
                    push(hk[r_], M.seq(mid), child(at, r_))
                end
            end
        end
    end
    local free = {}
    for h in pairs(dom) do free[#free + 1] = h end
    table.sort(free)
    return { sigma = sigma, holes = dom, fresh = fresh, free = free }
end

--- the meet: the most general template that is an instance of both. T2's holes that clash
--- with T1's are renamed apart first. Returns { template = U, left = {h -> term over U's holes},
--- right = {h -> term}, renamed = {g -> g'}, fresh = {W..} } or nil, why, at.
--- U.edits is empty: the meet is a query over two families, not a move in either's log.
function M.unify(T1, T2, opts)
    opts = opts or {}
    if not T1.body then T1 = M.template(T1) end
    if not T2.body then T2 = M.template(T2) end
    local renamed, used = {}, {}
    for _, h in ipairs(M.hole_names(T1)) do used[h] = true end
    for _, g in ipairs(M.hole_names(T2)) do
        if used[g] then
            local g2 = g .. "'"
            while used[g2] or T2.holes[g2] do g2 = g2 .. "'" end
            renamed[g] = g2
        end
    end
    local function ren(t)
        if is_hole(t) then local c = M.copy(t); c.h = renamed[t.h] or t.h; return c end
        if not t.kids then return M.copy(t) end
        local kids = {}
        for i, c in ipairs(t.kids) do kids[i] = ren(c) end
        return M.rebuild(t, kids)
    end
    local H = {}
    for h, e in pairs(T1.holes) do H[h] = e end
    for g, e in pairs(T2.holes) do H[renamed[g] or g] = e end
    local body2 = ren(T2.body)
    local env = { defs = opts.env and opts.env.defs, self = (opts.env and opts.env.self) or T1 } -- @self is T1's family unless said
    local S, why, at = M.solve({ { M.copy(T1.body), body2, {} } }, H, { env = env, relax = opts.relax, prefix = opts.prefix, cap = opts.cap })
    if not S then return nil, why, at end
    local body = subst(M.copy(T1.body), S.sigma, {})
    local domains = {}
    for h, d in pairs(S.holes) do domains[h] = { domain = d.domain, origin = d.origin } end
    local U = M.template(body, domains)
    U.edits = {}
    local left, right = {}, {}
    for _, h in ipairs(M.hole_names(T1)) do left[h] = S.sigma[h] and M.copy(S.sigma[h]) or M.hole(h, T1.holes[h].rep) end
    for _, g in ipairs(M.hole_names(T2)) do
        local g2 = renamed[g] or g
        right[g] = S.sigma[g2] and M.copy(S.sigma[g2]) or M.hole(g2, T2.holes[g].rep)
    end
    return { template = U, left = left, right = right, renamed = renamed, fresh = S.fresh, free = S.free }
end
end
