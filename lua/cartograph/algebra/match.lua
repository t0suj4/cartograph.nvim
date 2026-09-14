-- A PART OF `cartograph.algebra.core`, which requires this file at its end and
-- passes its own module table in. ⚠ IT DOES NOT `require` CORE BACK: that is a
-- load cycle — Lua says "loop or previous error loading module".
-- ★ 4 shared file-local(s), each (a) a core module-level local, (b) used
-- here and (c) not defined here — the three conditions, not a guess.
return function (M, SHARED)
local child, is_hole, key, unpack =
    SHARED.child, SHARED.is_hole, SHARED.key, SHARED.unpack

-- ── match ─────────────────────────────────────────────────────────────────────
--- Does I instantiate T? Returns { ok, values, sites } or { ok=false, refusal={at, why} }.
--- Reads T and I only. A hole bound at two sites must bind EQUAL values (non-linear
--- templates). Several hedge holes may share one child list: the matcher backtracks over
--- the split lengths. ⚠ Hedge matching is NP-complete (Kutsia, Levy, Villaret 2014), so
--- the search carries a step budget and refuses by name when it runs out.
function M.match(T, I, env)
    env = env or {}
    local cap = env.cap or 20000
    env = { defs = env.defs, self = env.self or T, hole_domains = env.hole_domains, cap = cap, collect = env.collect }
    local H = M.sites(T)
    local refusal, steps, nid = nil, 0, 0
    local function fail(path, why) refusal = { at = key(path), why = why }; return nil end
    -- every site carries an id (monotone in binding order) and `within`, the id of the
    -- context site whose applied hedge it was matched inside: the third leg needs the
    -- enclosure, since coinciding sites (X(Y(a)) against Y(X(a)) on (a)) have one geometry
    local function with(st, h, v, site)
        local V, S = {}, {}
        for k, x in pairs(st.V) do V[k] = x end
        for k, x in pairs(st.S) do S[k] = x end
        V[h] = v
        if not site.id then nid = nid + 1; site.id = nid end
        site.within = st.enc
        local list = { sites = {}, domain = H[h].domain, rep = H[h].rep, ctx = H[h].ctx or nil, origin = H[h].origin, was = H[h].was }
        for _, x in ipairs(S[h] and S[h].sites or {}) do list.sites[#list.sites + 1] = x end
        list.sites[#list.sites + 1] = site
        S[h] = list
        return { V = V, S = S, enc = st.enc }
    end
    local function bind(h, v, path, st, site)
        local ok, why
        if is_hole(v) and v.rep and not H[h].rep then
            return fail(path, 'hole ' .. h .. ': a hedge variable cannot fill a term hole')
        end
        if is_hole(v) and env.hole_domains then
            -- subsumption: a hole facing a hole is admitted iff its domain entails ours
            local d1 = env.hole_domains[v.h] and env.hole_domains[v.h].domain or M.open()
            ok = M.entails(d1, H[h].domain, env)
            why = not ok and ('?' .. v.h .. ' ' .. M.show_domain(d1) .. ' does not entail ' .. M.show_domain(H[h].domain)) or nil
        else
            ok, why = M.admits(H[h].domain, v, env)
        end
        if not ok then return fail(path, 'hole ' .. h .. ': ' .. why) end
        if st.V[h] ~= nil and not M.eq(st.V[h], v) then
            return fail(path, ('hole %s already bound to %s, here %s'):format(h, M.show(st.V[h]), M.show(v)))
        end
        return with(st, h, v, site or { path = path, n = v.k == 'seq' and #v.kids or nil })
    end
    local go, go_kids
    -- The matcher is in CONTINUATION-PASSING form: every alternative (a hedge width, a
    -- context placement) calls the success continuation `k` and moves on when it fails, so a
    -- choice made deep inside one child can be revised when a later sibling refuses it (a
    -- non-linear hole across subtrees). Before CTXMATCH.md the first success of a subtree was
    -- committed, which was incomplete for shared hedge holes; the all-matchers mode (`collect`)
    -- is the root continuation that records and refuses.
    -- ── CONTEXT VARIABLES (CART-0879 item 3). A context hole X(s̃) in a child list stands
    -- for a slice of the instance's children holding ONE cursor, with the applied hedge s̃
    -- instantiated where the cursor is (what `plug` does, read backwards). The search
    -- enumerates: the slice width n; a list L inside the slice reached by a path p (p empty:
    -- the slice itself, the cursor at top level); a sub-slice L[j1..j2] of it, the empty
    -- sub-slice at every insert point included (a context that wraps nothing), matched
    -- against s̃ by go_kids in place (hedge and context holes inside s̃ fall out). Kutsia's
    -- context (WWV'05 slides) is a TERM with one hole; BK's, which this prototype uses, is a
    -- HEDGE with one cursor, so the space is wider: what admits(context) plus plug accept.
    -- Context matching is NP-complete in general (stratified: Schmidt-Schauß & Stuber 2004,
    -- cited through Levy, Schmidt-Schauß, Villaret 2006; linear in P); the one step budget in
    -- go_kids prices it as it prices hedges (every placement re-enters go_kids).
    local with_cursor = M.with_cursor
    -- every list the cursor could sit in: f(L, p, lpath, first) with L the list, p the path
    -- inside the slice, lpath the instance path of L's parent, first the instance index of L[1]
    local function placements(slice, path, ii, f)
        local r = f(slice, {}, path, ii)
        if r then return r end
        local function walk(e, p, epath)
            -- term and hedge holes have no kids; a CONTEXT hole node on the instance side is
            -- descended into, since a context may contain context variables (BK §2: a context is
            -- a hedge over F ∪ {◦} ∪ V_H ∪ V_C), so X ↦ Y(◦) is a substitution (VMIN.md)
            if not e.kids or (is_hole(e) and not e.ctx) then return nil end
            local r2 = f(e.kids, p, epath, 1)
            if r2 then return r2 end
            for i, c in ipairs(e.kids) do
                local p2 = { unpack(p) }; p2[#p2 + 1] = i
                local r3 = walk(c, p2, child(epath, i))
                if r3 then return r3 end
            end
            return nil
        end
        for i, e in ipairs(slice) do
            local r4 = walk(e, { i }, child(path, ii + i - 1))
            if r4 then return r4 end
        end
        return nil
    end
    -- match template children tk[ti..] against instance children ik[ii..iend], then continue with k
    go_kids = function(tk, ik, ti, ii, path, st, iend, k)
        iend = iend or #ik
        steps = steps + 1
        if steps > cap then return fail(path, 'matching budget exceeded (hedge and context matching are NP-complete)') end
        if ti > #tk then
            if ii > iend then return k(st) end
            return fail(path, ('arity: %d unmatched children'):format(iend - ii + 1))
        end
        local t = tk[ti]
        if is_hole(t) and t.ctx then
            local fixed = 0 -- repetition and context holes after it are variable-width
            for j = ti + 1, #tk do if not (is_hole(tk[j]) and (tk[j].rep or tk[j].ctx)) then fixed = fixed + 1 end end
            local maxn = iend - ii + 1 - fixed
            for n = 0, maxn do
                local slice = {}
                for j = ii, ii + n - 1 do slice[#slice + 1] = ik[j] end
                local found = placements(slice, path, ii, function(L, p, lpath, first)
                    -- L[j] sits at child(lpath, first + j - 1); at the top level the list is ik itself
                    local list = (#p == 0) and ik or L
                    for j1 = 1, #L + 1 do
                        for j2 = j1 - 1, #L do
                            nid = nid + 1
                            local id = nid -- allocated before the applied hedge is matched: its sites are `within` this one
                            local inner = { V = st.V, S = st.S, enc = id }
                            local r = go_kids(t.kids or {}, list, 1, first + j1 - 1, lpath, inner, first + j2 - 1, function(st2)
                                local v = with_cursor(slice, p, j1, j2)
                                local site = { path = child(path, ii), n = n, cursor = { path = p, from = j1, n = j2 - j1 + 1 }, id = id }
                                local st3 = bind(t.h, v, child(path, ii), { V = st2.V, S = st2.S, enc = st.enc }, site)
                                if not st3 then return nil end
                                return go_kids(tk, ik, ti + 1, ii + n, path, st3, iend, k)
                            end)
                            if r then return r end
                            if steps > cap then return nil end
                        end
                    end
                    return nil
                end)
                if found then return found end
                if steps > cap then return nil end
            end
            return nil
        end
        if is_hole(t) and t.rep then
            local fixed = 0
            for j = ti + 1, #tk do if not (is_hole(tk[j]) and (tk[j].rep or tk[j].ctx)) then fixed = fixed + 1 end end
            local maxn = iend - ii + 1 - fixed
            for n = 0, maxn do
                local mid = {}
                for j = ii, ii + n - 1 do mid[#mid + 1] = ik[j] end
                local st2 = bind(t.h, M.seq(mid), child(path, ii), st)
                if st2 then
                    local r = go_kids(tk, ik, ti + 1, ii + n, path, st2, iend, k)
                    if r then return r end
                end
                if steps > cap then return nil end
            end
            return nil
        end
        if ii > iend then return fail(path, ('arity: template child %d has no counterpart'):format(ti)) end
        return go(t, ik[ii], child(path, ii), st, function(st2)
            return go_kids(tk, ik, ti + 1, ii + 1, path, st2, iend, k)
        end)
    end
    go = function(t, i, path, st, k)
        if is_hole(t) and t.ctx then
            -- a context hole as the whole body: its plugged value is a seq
            if type(i) ~= 'table' or i.k ~= 'seq' then return fail(path, 'hole ' .. t.h .. ': a context plugs into a seq, got ' .. tostring(type(i) == 'table' and i.k)) end
            return go_kids({ t }, i.kids, 1, 1, path, st, nil, k)
        end
        if is_hole(t) then
            local st2 = bind(t.h, i, path, st)
            if not st2 then return nil end
            return k(st2)
        end
        if t.k == 'embed' then
            if type(i) ~= 'table' or i.k ~= 'lit' or type(i.v) ~= 'string' then
                return fail(path, 'embed ' .. t.g .. ': not a string')
            end
            local parsed = M.grammars[t.g].parse(i.v)
            if not parsed then return fail(path, ('embed %s: %q does not parse'):format(t.g, i.v)) end
            return go(t.kids[1], parsed, child(path, 1), st, k)
        end
        if type(i) ~= 'table' or t.k ~= i.k then
            return fail(path, ('kind %s vs %s'):format(t.k, type(i) == 'table' and tostring(i.k) or 'nil'))
        end
        if t.k == 'lit' then
            if t.v == i.v then return k(st) end
            return fail(path, ('literal %s vs %s'):format(M.show(t), M.show(i)))
        end
        if t.k == 'name' then
            if t.n == i.n then return k(st) end
            return fail(path, ('name %s vs %s'):format(t.n, i.n))
        end
        return go_kids(t.kids or {}, i.kids or {}, 1, 1, path, st, nil, k)
    end
    if env.collect then
        -- every matcher: the root continuation records each success and refuses it, so the
        -- search backtracks through every alternative (finitary: a ground instance has finitely many)
        local all = {}
        go(T.body, I, {}, { V = {}, S = {} }, function(st) all[#all + 1] = { values = st.V, sites = st.S }; return nil end)
        return { ok = #all > 0, all = all, steps = steps, refusal = #all == 0 and refusal or nil }
    end
    local st = go(T.body, I, {}, { V = {}, S = {} }, function(st) return st end)
    if st then return { ok = true, values = st.V, sites = st.S, steps = steps, provenance = M.observed(st.V, st.S) } end
    return { ok = false, refusal = refusal, values = {}, sites = {}, steps = steps }
end

--- every matcher of T against I (a minimal complete set: with a ground instance every
--- matcher is ground, so the set is the distinct solutions). Returns { ok, all = {{values, sites}..}, steps }.
function M.match_all(T, I, env)
    env = env or {}
    return M.match(T, I, { defs = env.defs, self = env.self, hole_domains = env.hole_domains, cap = env.cap, collect = true })
end
end
