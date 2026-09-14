-- algebra.lua — the (template, holes, values) triplet and its arrows, standalone.
--
-- Objects
--   term      ground tree:  {k='lit', v=..} | {k='name', n=..} | {k=<kind>, kids={..}}
--             a SEQUENCE value (what a repetition hole binds to) is {k='seq', kids={..}}
--   template  T = { body = term-with-hole-nodes, holes = { [name] = { domain = D } } }
--             a hole node is {k='hole', h=name} or {k='hole', h=name, rep=true}
--   holes     H = { [name] = { sites = { {path={i,j,..}, n=count|nil}, .. }, domain = D, rep = bool } }
--             H is DERIVABLE from T (M.sites) — it is the middle leg, positions + domains.
--   values    V = { [name] = term }          (a repetition hole binds a seq)
--   instance  I = ground term                (the product of the triplet)
--
-- Arrows
--   instantiate(T, V)  -> I         strict: an unfilled hole refuses
--   apply(T, sigma)    -> T'        partial: unfilled holes stay holes (substitution)
--   match(T, I)        -> V | refusal
--   abstract(I, H)     -> T         reads H and I only, never T or V
--   values_at(I, H)    -> V
--   unify(T1, T2)   -> U | refusal  the MEET: most general template below both (UNIFY.md)
--   transplant(a,b,c) -> c'          the edit a→b applied to c through the lgg context (TRANSPLANT.md)
--   join(T1, T2)    -> J            the least above both, hedges aligned (JOIN.md, HEDGEJOIN.md)
--   generalize({I..}) -> T, {V..}   n-ary anti-unification (the lgg), with repetition and
--                                   recursion proposed only when the evidence reaches 3
--   fill(T, h, T2)     -> T'        a hole filled with a template (nesting = substitution)
--   instance_of(T1,T2) -> bool      the generality order; ground at the bottom, ?open at top
--   gate(T, V, I)      -> verdict   leave-one-out: each leg re-derived from the other two
--   migrate(T0,T1,{V}) -> {V'}, dropped   the family follows T0's edits to T1; reads T and V only
--   classify(T,V,I')  -> kind, T', V'   what an edit on one instance did to the triplet
--   propagate(T,C,{V},i) -> clusters, previews, commit   the other members, by commitment
--   join(T1, T2|I)     -> J, left/right value maps   the least template above both (incremental)
--   adjoin(T,{V},I)    -> J, {V'}                     a newcomer joins a stored family
--   trace(T, V)        -> I, origins                  instantiate with attribution (a correspondence)
--   pipeline(stages)   -> I, origin(p), impact, uses  correspondences composed through taken holes
--   render(I)          -> text, spans                  the text stage, offsets ↔ paths
--   embed(g, T_inner)  -> fragment to fill a hole with  a grammar boundary; origin_in(origins, p, offset)
--   partition({I..})   -> families, dl                 which instances are one template: MDL, greedy vs partition_all
--   eau(t, s, theory)  -> minimal complete set        generalization modulo A, C, AC (Alpuente et al.); eau_naive the yardstick
--   materialize(T|I, {family}) -> nodes, edges, absences   the closed schema as a projection; hole-dependent facts are typed absences
--   emit(T, V, P)      -> I, verified                   provenance beside values (observed|derived|supplied); the reader verifies the writer
--   absence_of(neg)    -> absent|refused|frontier|unavailable   every negative answer classified on the reading axis
--   stamp/valid(T, V)  -> values keyed by the edit log   nothing persists across a boundary without a validity key
--   build(tasks, key, store) -> log      suspending scheduler + verifying/constructive traces (Mokhov et al.): rerun only on a changed demanded key
--   family_analyze(T, Vs, f) -> results  an analyzer reads members through the template; equal demanded projections share one run
--
-- Domains (what may fill a hole):  open | closed(v) | kinds{..} | ref(name) | alt(..) | rep(of) | both(a,b)
--   `ref 'self'` is the template being matched — a recursive hole. `meet` intersects.
local M = {}
local unpack = table.unpack or unpack

-- ── terms ─────────────────────────────────────────────────────────────────────
function M.lit(v) return { k = 'lit', v = v } end
function M.name(n) return { k = 'name', n = n } end
function M.node(k, ...) return { k = k, kids = { ... } } end
function M.seq(list) return { k = 'seq', kids = list } end
function M.hole(h, rep) return { k = 'hole', h = h, rep = rep or nil } end
--- a CONTEXT hole (Baumgartner & Kutsia 2014): a hole APPLIED to a hedge. Its value is a
--- hedge containing exactly one cursor; instantiation plugs the applied hedge there.
function M.ctx(h, kids) return { k = 'hole', h = h, ctx = true, kids = kids or {} } end
function M.cursor() return { k = 'cursor' } end
local function is_hole(t) return type(t) == 'table' and t.k == 'hole' end
M.is_hole = is_hole

function M.copy(t)
    if type(t) ~= 'table' then return t end
    local c = {}
    for k, v in pairs(t) do c[k] = M.copy(v) end
    return c
end

--- the one way to rebuild a node with new children: every field that is not the child list
--- (grammar of a boundary, anything a field adds later) is carried, so no arrow can lose it.
--- The grammar field was lost three times before this existed (EMBED.md).
function M.rebuild(t, kids)
    local n = {}
    for k, v in pairs(t) do if k ~= 'kids' then n[k] = v end end
    n.kids = kids
    return n
end

function M.eq(a, b)
    if a == b then return true end
    if type(a) ~= 'table' or type(b) ~= 'table' or a.k ~= b.k then return false end
    if a.k == 'lit' then return a.v == b.v end
    if a.k == 'name' then return a.n == b.n end
    if a.k == 'hole' and (a.h ~= b.h or (a.rep or false) ~= (b.rep or false) or (a.ctx or false) ~= (b.ctx or false)) then
        return false
    end
    local ka, kb = a.kids or {}, b.kids or {}
    if #ka ~= #kb then return false end
    for i = 1, #ka do if not M.eq(ka[i], kb[i]) then return false end end
    return true
end

function M.show(t)
    if t == nil then return 'nil' end
    if t.k == 'lit' then return type(t.v) == 'string' and ('%q'):format(t.v) or tostring(t.v) end
    if t.k == 'name' then return t.n end
    if t.k == 'cursor' then return '◦' end
    if t.k == 'hole' and not t.ctx then return '?' .. t.h .. (t.rep and '...' or '') end
    local parts = {}
    if t.k == 'hole' then
        for i, c in ipairs(t.kids or {}) do parts[i] = M.show(c) end
        return '?' .. t.h .. '(' .. table.concat(parts, ' ') .. ')'
    end
    for i, c in ipairs(t.kids or {}) do parts[i] = M.show(c) end
    return '(' .. t.k .. (#parts > 0 and ' ' or '') .. table.concat(parts, ' ') .. ')'
end

function M.size(t)
    local n = 1
    for _, c in ipairs(t.kids or {}) do n = n + M.size(c) end
    return n
end

function M.ground(t)
    if is_hole(t) then return false end
    for _, c in ipairs(t.kids or {}) do if not M.ground(c) then return false end end
    return true
end

-- ── paths and sites ───────────────────────────────────────────────────────────
local function key(path) return #path == 0 and 'root' or table.concat(path, '/') end
M.key = key
local function child(path, i) local p = { unpack(path) }; p[#p + 1] = i; return p end

local function at(t, path)
    for _, i in ipairs(path) do
        t = t and t.kids and t.kids[i]
    end
    return t
end
M.at = at

-- ── templates and their holes (H is derived from T) ───────────────────────────
--- A hole record is { domain, origin, was, was_origin, rep, ctx }. `origin` is 'supplied'
--- (a premise: a bare domain from the API, a pin, a dig with a domain) or 'derived' (a
--- summary of the value column, recomputed when membership changes; DOMAINS.md). Internal
--- callers pass whole records so the origin travels; a bare domain is a premise.
function M.template(body, domains)
    local holes = {}
    for h, D in pairs(domains or {}) do
        if type(D) == 'table' and D.kind == nil and D.domain then -- a hole RECORD (no `kind`; every domain has one)
            holes[h] = { domain = D.domain, origin = D.origin or 'derived', was = D.was, was_origin = D.was_origin }
        else
            holes[h] = { domain = D, origin = 'supplied' }
        end
    end
    local T = { body = body, holes = holes, edits = {} }
    -- every hole in the body has an entry; default domain is open, and derived (no evidence yet)
    for h, e in pairs(M.sites(T)) do
        if not holes[h] then holes[h] = { domain = e.ctx and M.context() or M.open(), origin = 'derived' } end
        holes[h].rep, holes[h].ctx = e.rep, e.ctx
    end
    return T
end

-- ── instantiate / apply ───────────────────────────────────────────────────────
-- Substitute V into T. Partial by default (`apply`): an unbound hole stays a hole.
--- plug a hedge into a context value (a seq with one cursor); returns a seq
function M.plug(ctxv, hedge)
    local c = M.copy(ctxv)
    local function go(t)
        if not t.kids then return false end
        for i, k in ipairs(t.kids) do
            if k.k == 'cursor' then
                local kids = {}
                for j = 1, i - 1 do kids[#kids + 1] = t.kids[j] end
                for _, e in ipairs(hedge) do kids[#kids + 1] = M.copy(e) end
                for j = i + 1, #t.kids do kids[#kids + 1] = t.kids[j] end
                t.kids = kids
                return true
            end
            if go(k) then return true end
        end
        return false
    end
    go(c)
    return c
end
--- the context value: the slice (a list of terms) with L[j1..j2] replaced by one cursor, L
--- the list reached inside the slice by the relative path p (p empty: the slice itself).
--- This is Huet's zipper path (1997) read off at a site: every level keeps its elder and
--- younger siblings, Top is the slice boundary, and `plug` is his go_up iterated; the focus
--- here is a hedge (j1..j2, possibly empty), not one tree, and Top may own siblings.
function M.with_cursor(slice, p, j1, j2)
    local c = M.seq({})
    for i, e in ipairs(slice) do c.kids[i] = M.copy(e) end
    local L = c
    for _, i in ipairs(p) do L = L.kids[i] end
    local kids = {}
    for j = 1, j1 - 1 do kids[#kids + 1] = L.kids[j] end
    kids[#kids + 1] = M.cursor()
    for j = j2 + 1, #L.kids do kids[#kids + 1] = L.kids[j] end
    L.kids = kids
    return c
end

local subst
local function subst_list(kids, V, unfilled)
    local out = {}
    for _, c in ipairs(kids) do
        if is_hole(c) and c.rep and V[c.h] ~= nil then
            local v = V[c.h]
            if v.k == 'seq' then for _, e in ipairs(v.kids) do out[#out + 1] = M.copy(e) end
            else out[#out + 1] = M.copy(v) end -- a hedge variable standing for a hedge variable (unify's X = Y)
        elseif is_hole(c) and c.ctx then
            local inner = subst_list(c.kids or {}, V, unfilled)
            if V[c.h] ~= nil then
                for _, e in ipairs(M.plug(V[c.h], inner).kids) do out[#out + 1] = e end
            else
                unfilled[c.h] = true
                out[#out + 1] = { k = 'hole', h = c.h, ctx = true, kids = inner }
            end
        else
            out[#out + 1] = subst(c, V, unfilled)
        end
    end
    return out
end
subst = function(t, V, unfilled)
    if t.k == 'embed' then
        local inner = subst(t.kids[1], V, unfilled)
        if not M.ground(inner) then return { k = 'embed', g = t.g, kids = { inner } } end
        local text = M.grammars[t.g].print(inner)
        if not text then error('embed: inner instance is not printable under ' .. t.g .. ': ' .. M.show(inner)) end
        return M.lit(text)
    end
    if is_hole(t) then
        if t.ctx then
            local inner = subst_list(t.kids or {}, V, unfilled)
            if V[t.h] ~= nil then return M.plug(V[t.h], inner) end
            unfilled[t.h] = true
            return { k = 'hole', h = t.h, ctx = true, kids = inner }
        end
        local v = V[t.h]
        if v == nil then unfilled[t.h] = true; return M.copy(t) end
        return M.copy(v)
    end
    if not t.kids then return M.copy(t) end
    return M.rebuild(t, subst_list(t.kids, V, unfilled))
end

--- partial substitution: returns a template; holes not in sigma remain (their domains kept)
function M.apply(T, sigma)
    local unfilled = {}
    local body = subst(T.body, sigma, unfilled)
    local domains = {}
    for h in pairs(unfilled) do domains[h] = T.holes[h] and M.copy(T.holes[h]) or { domain = M.open(), origin = 'derived' } end
    return M.template(body, domains)
end

--- strict instantiation: every hole bound and admitted, else refusal (an unfilled hole must fail)
function M.instantiate(T, V, env)
    local H = M.sites(T)
    local missing, rejected, extra = {}, {}, {}
    for h in pairs(V) do if not H[h] then extra[#extra + 1] = h end end
    for h, e in pairs(H) do
        if V[h] == nil then
            missing[#missing + 1] = h
        else
            local ok, why = M.admits(e.domain, V[h], env)
            if not ok then rejected[#rejected + 1] = h .. ': ' .. why end
        end
    end
    table.sort(missing); table.sort(rejected); table.sort(extra)
    -- a value with no hole has no site: it is unaddressable, so the triple is incoherent
    if #missing > 0 or #rejected > 0 or #extra > 0 then
        return { ok = false, unfilled = missing, rejected = rejected, extra = extra }
    end
    local unfilled = {}
    return { ok = true, term = subst(T.body, V, unfilled) }
end

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

-- ── abstract / values_at (read H and I; never T, never V) ─────────────────────
local function set_at(root, path, node)
    if #path == 0 then return node end
    local parent = at(root, { unpack(path, 1, #path - 1) })
    parent.kids[path[#path]] = node
    return root
end

-- ── generalize: n-ary anti-unification ────────────────────────────────────────
-- The lgg of n instances. The classical rule that makes templates NON-LINEAR: the same
-- tuple of divergent values gets the SAME hole. Repetition and recursion are proposed
-- only when the evidence reaches three distinct lengths / depths; at two they are
-- recorded as hypotheses and the hole stays a plain open one (CART-0730 in miniature).
local function distinct(list)
    local seen, n = {}, 0
    for _, x in ipairs(list) do if not seen[x] then seen[x] = true; n = n + 1 end end
    return n
end

-- ── composition ───────────────────────────────────────────────────────────────
--- fill hole h of T with template T2 (T2's holes are renamed h.<name> on clash)
function M.fill(T, h, T2)
    local rename = {}
    for _, g in ipairs(M.hole_names(T2)) do
        rename[g] = (T.holes[g] and g ~= h) and (h .. '.' .. g) or g
    end
    local function ren(t)
        if is_hole(t) then return M.hole(rename[t.h], t.rep) end
        if not t.kids then return M.copy(t) end
        local kids = {}
        for i, c in ipairs(t.kids) do kids[i] = ren(c) end
        return M.rebuild(t, kids)
    end
    local body = subst(T.body, { [h] = ren(T2.body) }, {})
    local domains = {}
    for g, e in pairs(T.holes) do if g ~= h then domains[g] = M.copy(e) end end
    for g, e in pairs(T2.holes) do domains[rename[g]] = M.copy(e) end
    return M.template(body, domains)
end

--- the generality order: T1 is an instance of T2 iff some substitution takes T2 to T1
function M.instance_of(T1, T2, env)
    return M.match(T2, T1.body, { defs = env and env.defs, hole_domains = T1.holes }).ok
end

-- ── edits: moves in the order ─────────────────────────────────────────────────
local function edited(T, op)
    local T2 = M.copy(T)
    T2.edits[#T2.edits + 1] = op
    return T2
end

--- pin: narrow a hole to one value (moves DOWN)
function M.pin(T, h, value)
    if not T.holes[h] then return nil, 'no hole ' .. h end
    local T2 = edited(T, { op = 'pin', h = h, value = M.copy(value) })
    if not T2.holes[h].was then T2.holes[h].was, T2.holes[h].was_origin = T2.holes[h].domain, T2.holes[h].origin end
    T2.holes[h].domain, T2.holes[h].origin = M.closed(value), 'supplied' -- a pin is a premise
    return T2
end

--- open: undo a pin (moves UP, bounded to holes that were pinned)
function M.open_hole(T, h)
    if not T.holes[h] then return nil, 'no hole ' .. h end
    if not T.holes[h].was then return nil, 'hole ' .. h .. ' was never pinned' end
    local T2 = edited(T, { op = 'open', h = h })
    T2.holes[h].domain, T2.holes[h].origin = T2.holes[h].was, T2.holes[h].was_origin or 'derived'
    T2.holes[h].was, T2.holes[h].was_origin = nil, nil
    return T2
end

--- dig: make a fixed subtree at `path` into a new hole (moves UP; needs a SITE)
function M.dig(T, path, h, domain)
    if is_hole(at(T.body, path)) then return nil, 'already a hole' end
    local T2 = edited(T, { op = 'dig', h = h, at = key(path), path = M.copy(path), domain = domain })
    T2.body = set_at(T2.body, path, M.hole(h))
    -- a dig with a domain is a premise; without one the domain is derived (migrate summarises it)
    T2.holes[h] = { domain = domain or M.open(), origin = domain and 'supplied' or 'derived' }
    -- holes swallowed by the dug subtree lose their last site and leave H (see migrate: dig)
    local H = M.sites(T2)
    for g in pairs(T2.holes) do if not H[g] then T2.holes[g] = nil end end
    return T2
end

--- merge: two holes become one (moves DOWN: the template turns non-linear)
function M.merge(T, h1, h2)
    if not (T.holes[h1] and T.holes[h2]) then return nil, 'no such holes' end
    local T2 = edited(T, { op = 'merge', h = h1, into = h2 })
    local function ren(t)
        if is_hole(t) and t.h == h2 then return M.hole(h1, t.rep) end
        for i, c in ipairs(t.kids or {}) do t.kids[i] = ren(c) end
        return t
    end
    T2.body = ren(T2.body)
    T2.holes[h1].domain = M.meet(T2.holes[h1].domain, T2.holes[h2].domain)
    T2.holes[h1].origin = (T2.holes[h1].origin == 'supplied' or T2.holes[h2].origin == 'supplied') and 'supplied' or 'derived'
    T2.holes[h2] = nil
    return T2
end

--- split: one site of a non-linear hole becomes its own hole (moves UP)
function M.split(T, h, site_index, h2)
    local H = M.sites(T)
    local s = H[h] and H[h].sites[site_index]
    if not s then return nil, 'no such site' end
    local T2 = edited(T, { op = 'split', h = h, site = site_index, new = h2 })
    T2.body = set_at(T2.body, s.path, M.hole(h2, H[h].rep))
    T2.holes[h2] = { domain = M.copy(T.holes[h].domain), origin = T.holes[h].origin }
    return T2
end

-- ── value migration: when an edit moves T, every stored V must follow ─────────
-- The five edits return T' and say nothing about the family (T, V_1..V_n). Each edit's
-- effect on a member is fixed by the edit alone and reads T and V only, never I:
--   pin h v       keep iff V[h] == v                               V unchanged
--   open h        keep                                              V unchanged
--   dig p h       keep; V[h] := the dug subtree RENDERED with V     (holes it swallowed
--                 leave V with it — dig is abstract's inverse, locally)
--   merge a b     keep iff V[a] == V[b];  V loses b
--   split h i g   keep; V[g] := V[h]
-- and then the moved template's domains must still admit the member (instantiate's check).
-- LAW (spec 'value migration'), per edit k taking T_{k-1} to T_k: a member kept has
-- instantiate(T_k, V') == I and match(T_k, I) succeeds; a member dropped at k has
-- match(T_k, I) refusing. Exception: `rewrite` (below) changes the fixed part on purpose,
-- so there the instance moves by the fixed delta and V is carried unchanged. Migration from V agrees with re-matching I at every step, so
-- a store never needs the instances to follow an edit. The law is per STEP, not per final
-- template: pin-then-open drops a member at the pin and the final T admits it again.
-- Edits that move UP (open, dig, split) can ADMIT instances outside the family; migration
-- carries the family it is given and never adopts — adoption is a match, not a migration.

-- ── rewrite: the sixth edit, a fixed region replaced by a subtree that may carry holes ──
--- The subtree may mention EXISTING holes only, relocating or duplicating them, never
--- discarding one. This is the edit `classify` records for a template change, and the one
--- edit that is not a move in the order: it changes what every member instantiates to.
function M.rewrite(T, path, sub)
    local names = {}
    for _, h in ipairs(M.hole_names(T)) do names[h] = true end
    local function check(t)
        if is_hole(t) then
            if not names[t.h] then return false, 'rewrite: unknown hole ' .. t.h end
            if t.rep or t.ctx then return false, 'rewrite: repetition/context holes not supported' end
        end
        for _, c in ipairs(t.kids or {}) do
            local ok, why = check(c)
            if not ok then return ok, why end
        end
        return true
    end
    local ok, why = check(sub)
    if not ok then return nil, why end
    local T2 = edited(T, { op = 'rewrite', h = key(path), path = M.copy(path), sub = M.copy(sub) })
    T2.body = set_at(T2.body, path, M.copy(sub))
    local H = M.sites(T2)
    -- a rewrite may relocate or duplicate a hole, never discard one: a discarded hole
    -- would change each member's instance by that member's own value. Filling is `pin`.
    for g in pairs(T2.holes) do
        if not H[g] then return nil, 'rewrite would discard hole ' .. g .. '; pin it instead' end
    end
    return T2
end

local function is_prefix(p, q)
    if #p > #q then return false end
    for i = 1, #p do if p[i] ~= q[i] then return false end end
    return true
end
local function occurrences(t, v, path, out)
    if is_hole(t) then return end
    if M.eq(t, v) then out[#out + 1] = path; return end
    for i, c in ipairs(t.kids or {}) do occurrences(c, v, child(path, i), out) end
end
local function cat(p, q) local r = { unpack(p) }; for _, x in ipairs(q) do r[#r + 1] = x end; return r end

-- ── join: the least template above a template and an instance, or above two templates ──
-- CART-0879 item 9. generalize({I..}) rebuilds a family from scratch; join(T, X) moves a
-- STORED template up by exactly what X needs, keeps hole names (so stored values follow by
-- name), keeps domains (widening only where X forces it), and keeps operator edits that X
-- does not contradict (a dug hole X agrees with stays a hole; batch generalize would not
-- have it). X may be a ground instance or another template (two families merging).
-- The lgg with a store keyed by the PAIR of fragments: an old hole facing the same partner
-- at every site keeps its name; facing different partners it SPLITS; a fixed fragment
-- facing a different fragment becomes a NEW hole; a fragment containing holes that is
-- swallowed renders per member (dig's rule). Value migration is one rule for every hole of
-- the result: V'[n] = the member's side fragment under n, rendered with V.
-- LAW (spec 'incremental join'): join(generalize(J1..Jn), I) ≅ generalize(J1..Jn, I) up to
-- hole renaming, and folding join from a single instance equals batch generalize; every
-- member rebuilds. Scope: no repetition or context holes.

--- THE ONE SUMMARY POLICY for derived domains (DOMAINS.md). 'kinds': kind agreement is
--- evidence (CART-0864), the summary of a column is the set of kinds seen, and the column
--- itself stays the record of the values. 'enumerate': closed values as `alt` up to `cap`,
--- then kinds. Both are fold-consistent: summarize(column) == fold of widen over it.
M.SUMMARY = 'kinds'
-- ── correspondences: attributed instantiation, and their composition through a pipeline ──
-- CART-0879 item 10; what CART-0870 (Helm sidecar), CART-0874 (two projections) and the
-- network mapping ("rendered from Y by Z") all need. A CORRESPONDENCE is the attribution of
-- every position of an output to where it came from: a FIXED position of the template that
-- produced it, or a position INSIDE the value of a hole. trace(T, V) is instantiate with
-- that attribution. A PIPELINE is a chain of stages where a stage's hole may be TAKEN from
-- a position of the previous stage's output (values.yaml → chart render → patch → text);
-- composing the correspondences is following an output position back through the taken
-- holes until it stops at a fixed part of some stage or at an external input of some stage.
-- origin(p) is that chain (the breadcrumb); impact(k, q) is the forward image (every final
-- position that came from position q of stage k's input — "where does this value go").
-- Point and repetition holes; context holes unsupported.
--   origin = { src = 'fixed'|'hole', stage = k, at = path, hole = h|nil, via = { {stage, at}.. } }

-- ── cross-grammar nesting: a hole whose value is text under another grammar ────────
-- CART-0879 item 11. A shell line inside a YAML string, a key=value list inside a shell
-- argument. Parsing is a derivation and printing is its inverse (serialization is
-- derivation), so the boundary is a NODE in the template body: {k='embed', g=<grammar>,
-- kids={inner body}}. The inner template's holes are holes of the outer template, with the
-- inner VALUES stored, never the string: instantiate prints the inner instance under g into
-- a lit, match parses the lit under g and continues inside, generalize parses differing
-- strings when a profile says which parent kinds carry which grammar (opts.grammars =
-- { [parent kind] = grammar }) and falls back to an opaque string hole when any instance
-- does not parse, trace keeps the inner spans and origins so an offset inside the string
-- resolves to an inner hole (origin_in), and classify recurses into the boundary so an edit
-- inside the string classifies and propagates like any other. A grammar is { parse(s) ->
-- term|nil, print(term) -> text, spans|nil }; two toy grammars ship for the tests.
M.grammars = {}
function M.grammar(name, g) M.grammars[name] = g; return g end

local function spanning_printer(f)
    return function(t)
        local buf, spans, off = {}, {}, 0
        local function emit(s) buf[#buf + 1] = s; off = off + #s end
        local ok = true
        local function go(x, path)
            local from = off
            if not f(x, path, emit, go) then ok = false end
            spans[#spans + 1] = { path = path, from = from, to = off }
        end
        go(t, {})
        if not ok then return nil end
        return table.concat(buf), spans
    end
end

-- 'sh': words separated by single spaces, commands separated by ' | '
M.grammar('sh', {
    parse = function(s)
        if type(s) ~= 'string' or s == '' then return nil end
        if s:match('^[ |]') or s:match('[ |]$') then return nil end
        local cmds = {}
        for part in (s .. ' | '):gmatch('(.-) | ') do
            if part == '' then return nil end
            local words = {}
            for w in (part .. ' '):gmatch('(.-) ') do
                if w == '' or w:find('|', 1, true) then return nil end
                words[#words + 1] = w
            end
            local kids = { M.name(words[1]) }
            for i = 2, #words do kids[#kids + 1] = M.lit(words[i]) end
            cmds[#cmds + 1] = { k = 'cmd', kids = kids }
        end
        if #cmds == 1 then return cmds[1] end
        return { k = 'pipe', kids = cmds }
    end,
    print = spanning_printer(function(x, path, emit, go)
        if x.k == 'pipe' then
            for i, c in ipairs(x.kids) do
                if i > 1 then emit(' | ') end
                go(c, child(path, i))
            end
            return true
        elseif x.k == 'cmd' then
            for i, c in ipairs(x.kids) do
                if i > 1 then emit(' ') end
                go(c, child(path, i))
            end
            return true
        elseif x.k == 'name' then emit(x.n); return true
        elseif x.k == 'lit' and type(x.v) == 'string' then emit(x.v); return true
        end
        return false
    end),
})

-- 'kv': KEY=value pairs separated by commas
M.grammar('kv', {
    parse = function(s)
        if type(s) ~= 'string' or s == '' then return nil end
        local pairs_ = {}
        for part in (s .. ','):gmatch('(.-),') do
            local k, v = part:match('^([%w_]+)=(.*)$')
            if not k or v:find(',', 1, true) then return nil end
            pairs_[#pairs_ + 1] = { k = 'pair', kids = { M.name(k), M.lit(v) } }
        end
        return { k = 'kv', kids = pairs_ }
    end,
    print = spanning_printer(function(x, path, emit, go)
        if x.k == 'kv' then
            for i, c in ipairs(x.kids) do
                if i > 1 then emit(',') end
                go(c, child(path, i))
            end
            return true
        elseif x.k == 'pair' then
            go(x.kids[1], child(path, 1)); emit('='); go(x.kids[2], child(path, 2)); return true
        elseif x.k == 'name' then emit(x.n); return true
        elseif x.k == 'lit' and type(x.v) == 'string' then emit(x.v); return true
        end
        return false
    end),
})

--- a template fragment to `fill` a hole with: the inner template behind a grammar boundary
function M.embed(g, T_inner)
    assert(M.grammars[g], 'unknown grammar ' .. tostring(g))
    return { body = { k = 'embed', g = g, kids = { M.copy(T_inner.body) } }, holes = M.copy(T_inner.holes) }
end

--- the inner template of an embed node, carrying the outer template's domains
function M.inner_template(T, node)
    local Ti = M.template(node.kids[1])
    for h in pairs(Ti.holes) do Ti.holes[h].domain, Ti.holes[h].origin, Ti.holes[h].was = T.holes[h].domain, T.holes[h].origin, T.holes[h].was end
    return Ti
end

--- resolve an origin INSIDE an embedded string: the innermost inner span containing
--- `offset` (0-based, relative to the string), through nested boundaries
function M.origin_in(origins, path, offset)
    local o = origins[key(path)]
    while o and o.src == 'embed' do
        local best
        for _, s in ipairs(o.spans) do
            if offset >= s.from and offset < s.to and (not best or (s.to - s.from) < (best.to - best.from)) then best = s end
        end
        if not best then return o end
        offset = offset - best.from
        o = o.origins[key(best.path)]
    end
    return o
end

-- ── MDL partitioning: which instances belong to one template? ─────────────────
-- CART-0879 item 12. The gate judges one fixed family; propagate's commit lets the operator
-- cut one; nothing said WHETHER a set of instances is one family or several. Minimum
-- description length says: the partition whose two-part code is shortest,
--   DL(partition) = Σ_families ( cost(T_f.body) + family_cost ) + Σ_members Σ_holes cost(V_i[h])
-- with cost(term) = number of nodes by default (a hole counts one, a sequence value counts
-- one plus its elements). One family over unrelated instances collapses to a root hole and
-- pays every instance in full plus one; singletons pay every instance in full plus one
-- family each; a shared skeleton is paid once. A non-linear hole is paid once per member,
-- not per site, which is the store law priced. The cost model is a knob (opts.cost,
-- opts.family_cost); domains are not priced.
-- partition() is greedy agglomerative from singletons, merging the pair whose re-generalized
-- family shortens the total most, strictly, until no merge helps. partition_all() is the
-- brute-force optimum over all set partitions for small n, the yardstick for greedy.

local function fixed_nodes(t)
    if is_hole(t) then return 0 end
    local n = 1
    for _, c in ipairs(t.kids or {}) do n = n + fixed_nodes(c) end
    return n
end

--- a family is ADMISSIBLE when its template shares something: at least `min_fixed` fixed
--- nodes (default 1). Without this, six unrelated one-node instances are "one family" under
--- a bare hole because that pays one family cost instead of six: MDL rewarding "anything".
--- Singletons are always admissible.
local function family_of(instances, members, opts)
    local Is = {}
    for _, i in ipairs(members) do Is[#Is + 1] = instances[i] end
    local T, values
    if #Is == 1 then T, values = M.template(M.copy(Is[1])), { {} }
    else
        local g = M.generalize(Is, opts.generalize)
        T, values = g.template, g.values
    end
    local Vs = {}
    for k, i in ipairs(members) do Vs[i] = values[k] end
    local dl, parts = M.family_dl(T, Vs, opts)
    local admissible = #Is == 1 or fixed_nodes(T.body) >= (opts.min_fixed or 1)
    return { members = members, template = T, values = Vs, dl = dl, parts = parts, admissible = admissible }
end

-- ── equational anti-unification: generalization modulo A, C, AC ──────────────
-- Alpuente, Escobar, Meseguer, Ojeda (LOPSTR 2008); Alpuente, Escobar, Espert, Meseguer
-- (I&C 2014); revisited with Sapiña (AMAI 2021, the rules used here: Figs 1, 5, 6, 7).
-- CART-0879 item 13: `x == nil` and `nil == x` are one template when == is declared
-- commutative; `a + b + c` and `c + a + b` are one when + is AC. A THEORY declares per
-- symbol which axioms hold: theory[k] = { A = true, C = true }. There is no unique lgg
-- modulo B; the result is the MINIMAL COMPLETE SET of B-lggs, finite for any combination
-- of A and C (I&C 2014; survey Table 3: type ω). Unit elements are NOT built: RecoverU
-- breaks termination without U-tolerance, two units make the type nullary (Cerna & Kutsia
-- 2020), and idempotency is infinitary — only A, C, AC are finitary and only those are here.
-- Terms are the prototype's: node kinds are the function symbols, lit/name leaves are
-- constants, holes are variables; holes in the INPUTS are treated as constants.
-- Configurations ⟨C | S | θ⟩ as in the paper; the search explores every branch of the
-- don't-know rules (DecomposeC, DecomposeA-left/right, DecomposeAC-left/right), then the
-- complete set is filtered by matching modulo B to the least general ones.
-- Stated departures: (1) a constraint whose sides are equal modulo B is bound at once to
-- the canonical side. This is DecomposeB's n = 0 case (equal constants) closed under =B, and
-- it is load-bearing, not an optimisation: without it an input variable facing itself is
-- Solved to a fresh hole (mutation Q7). (2) a free symbol with the same root and different
-- arity is Solved — the terms are unranked. (3) the empty theory reduces to Plotkin's lgg.

-- ── materialization: the neutral schema as a projection of terms (CHARTER.md) ──────────
-- cartograph's graph is six node kinds and four edge kinds (validate.lua). A node is
-- (kind, name, file, range): a term POSITION with a kind predicate, so on nodes the
-- projection is compositional. An edge is a resolution result with a tier: non-local, so
-- on edges it is not. A template's graph therefore needs a typed absence exactly where the
-- projection is non-compositional, which is every fact that depends on a hole's value.
-- Toy term language (mod/def/local/block/call/use); the output lands on the closed schema
-- BY NAME and the laws in the suite are what a port would have to keep.
M.NODE_KINDS = { module = true, ['function'] = true, method = true, var = true, region = true, external = true }
M.EDGE_KINDS = { ref = true, import = true, use = true, reg = true }
--- the READING axis of absence (tier.lua M.ABSENCE): why is the graph silent here. Five,
--- each with the most a consumer may do. The OBSERVATION axis (warrants) and the positive
--- ladder are different questions and are not modelled.
M.ABSENCE = {
    absent      = { licenses = 'act',     why = 'the reading was complete and found nothing' },
    refused     = { licenses = 'nothing', why = 'a rule declined to draw the edge; a navigable fork' },
    frontier    = { licenses = 'nothing', why = 'the region was never analysed' },
    unavailable = { licenses = 'nothing', why = 'the data class was never extracted' },
    unbuilt     = { licenses = 'nothing', why = 'something outside produces more artifacts; no counterpart in this algebra' },
}
--- the positive ladder's names in ladder.lua's display order, strongest first. Its rank
--- order is disputed between ladder.lua and tier.lua (CART-0545); this table is used only
--- to take the WEAKEST of several member tiers, and the toy resolver emits `linked` alone.
M.RUNGS = { 'confirmed', 'proven', 'linked', 'typed', 'inferred', 'dynamic', 'refused', 'frontier' }
local RUNG_RANK = {}
for i, r in ipairs(M.RUNGS) do RUNG_RANK[r] = i end
-- ── provenance beside values: observed | derived | supplied (CHARTER.md) ─────────────
--- P[h] = { src, via = {..}, journal = record | nil }. Kept BESIDE V, keyed by hole, never
--- inside the term (the side-channel decision). `observed` is read from an instance by
--- match; `derived` is computed by a total function (migrate, join, dig); `supplied` is a
--- premise a person or rule chose and needs a journal entry. A supplied value that passes
--- through migrate or join STAYS supplied: laundering it into observed is the charter's
--- fabrication failure.
function M.observed(V, sites)
    local P = {}
    for h in pairs(V) do P[h] = { src = 'observed', via = { sites and sites[h] and sites[h].sites and sites[h].sites[1] and key(sites[h].sites[1].path) or 'match' } } end
    return P
end
function M.supplied(h, journal, P)
    P = P or {}
    P[h] = { src = 'supplied', via = { 'operator' }, journal = journal }
    return P
end
function M.carry(p, via)
    if not p then return nil end
    local q = { src = p.src, via = {}, journal = p.journal }
    for _, v in ipairs(p.via or {}) do q.via[#q.via + 1] = v end
    q.via[#q.via + 1] = via
    return q
end
local function derived(via) return { src = 'derived', via = { via } } end
--- provenance for migrated values: a value equal to what the member had under the same
--- hole is carried; split's copy carries the source hole's; anything else was computed.
function M.migrate_provenance(op, V, W, P)
    local Q = {}
    for h, w in pairs(W) do
        if P and P[h] and V[h] ~= nil and M.eq(V[h], w) then Q[h] = M.carry(P[h], 'migrate:' .. op.op)
        elseif op.op == 'split' and h == op.new and P and P[op.h] then Q[h] = M.carry(P[op.h], 'migrate:split')
        else Q[h] = derived('migrate:' .. op.op) end
    end
    return Q
end
--- Emission is the line between verified span surgery and authoring: every value must
--- carry a provenance, a supplied value must carry its journal entry, and the reader
--- verifies the writer (match reads the emitted instance back).
function M.emit(T, V, P, env)
    for h in pairs(V) do
        local p = P and P[h]
        if not p then return { ok = false, absence = 'refused', why = 'hole ' .. h .. ': a value with no provenance is authoring' } end
        if p.src == 'supplied' and not p.journal then return { ok = false, absence = 'refused', why = 'hole ' .. h .. ': a supplied value without a journal entry' } end
        if p.src ~= 'observed' and p.src ~= 'derived' and p.src ~= 'supplied' then return { ok = false, absence = 'refused', why = 'hole ' .. h .. ': unknown provenance ' .. tostring(p.src) } end
    end
    local r = M.instantiate(T, V, env)
    if not r.ok then return { ok = false, absence = M.absence_of(r).absence, why = 'does not instantiate' } end
    local m = M.match(T, r.term, env)
    if not m.ok then return { ok = false, absence = 'refused', why = 'the reader does not verify the writer: ' .. m.refusal.why } end
    return { ok = true, term = r.term, verified = true }
end

-- ── the algebra's negatives, classified on the reading axis ──────────────────────────
local ABSENCE_RULES = {
    -- match refusals: the comparison is closed, so a mismatch is a complete reading
    { pat = '^arity',                              absence = 'absent' },
    { pat = '^kind ',                              absence = 'absent' },
    { pat = '^literal ',                           absence = 'absent' },
    { pat = '^name ',                              absence = 'absent' },
    { pat = 'already bound to',                    absence = 'absent' },  -- the store law is part of membership
    { pat = 'hedge variable cannot fill',          absence = 'absent' },
    { pat = 'budget exceeded',                     absence = 'frontier' }, -- the analysis did not finish
    { pat = 'context variables is not implemented', absence = 'unavailable' },
    { pat = 'does not parse',                      absence = 'absent' },
    { pat = 'not a string',                        absence = 'absent' },
    { pat = 'does not entail',                     absence = 'refused' },
    { pat = '^hole [^:]+: ',                       absence = 'refused' },  -- a domain declined; candidates = the domain
    -- migrate's dropped members
    { pat = 'value differs',                       absence = 'absent' },
    { pat = 'values differ',                       absence = 'absent' },
    { pat = 'lacks a value under',                 absence = 'absent' },
    { pat = 'domain refuses',                      absence = 'refused' },
    { pat = 'no value for',                        absence = 'frontier' },
    { pat = 'value without a site',                absence = 'refused' },
    { pat = '^join: ',                             absence = 'refused' },
    -- classify
    { pat = 'repetition/context hole',             absence = 'unavailable' },
    { pat = 'does not reproduce the edit',         absence = 'refused' },
    { pat = 'domain refuses the new value',        absence = 'refused' },
}
--- Classify a negative answer: a match result, an instantiate result, a classify result or
--- a migrate `dropped` record. Returns { absence, licenses, why, cands? }; errors on a
--- negative it cannot place, which is the point: a bare refusal is unrepresentable.
function M.absence_of(neg)
    local why
    if neg.refusal then why = neg.refusal.why
    elseif neg.unfilled or neg.rejected or neg.extra then
        if neg.rejected and #neg.rejected > 0 then why = 'domain refuses ' .. table.concat(neg.rejected, '; ')
        elseif neg.unfilled and #neg.unfilled > 0 then why = 'no value for ' .. table.concat(neg.unfilled, ', ')
        else why = 'value without a site ' .. table.concat(neg.extra or {}, ', ') end
    elseif neg.kind == 'unsupported' or neg.kind == 'straddle' then why = neg.why
    else why = neg.why end
    assert(type(why) == 'string', 'a negative answer with no reason cannot be classified')
    for _, r in ipairs(ABSENCE_RULES) do
        if why:find(r.pat) then
            local out = { absence = r.absence, licenses = M.ABSENCE[r.absence].licenses, why = why }
            if neg.proposal then out.cands = { neg.proposal } end
            return out
        end
    end
    error('undeclared negative: ' .. why)
end

-- ── validity key: values are valid for a template at a position in its edit log ────────
--- A stored V is a derivation from T as it was; the edit log index is the key the charter
--- demands ("nothing persists across a boundary without a validity key"). Scoped to the
--- template's own history; the source generation key is cartograph's validity.lua.
function M.edit_key(T)
    local parts = {}
    for i, op in ipairs(T.edits or {}) do
        local ks = {}
        for k in pairs(op) do ks[#ks + 1] = k end
        table.sort(ks)
        local fs = {}
        for _, k in ipairs(ks) do
            local v = op[k]
            if type(v) == 'table' and v.k then fs[#fs + 1] = k .. '=' .. M.show(v)
            elseif type(v) == 'table' and v.body then fs[#fs + 1] = k .. '=' .. M.show(v.body)
            elseif type(v) == 'table' then fs[#fs + 1] = k .. '=' .. table.concat(v, '.')
            else fs[#fs + 1] = k .. '=' .. tostring(v) end
        end
        parts[i] = table.concat(fs, ',')
    end
    return #parts .. ':' .. table.concat(parts, ';')
end
function M.stamp(T, V) return { values = V, at = #(T.edits or {}), key = M.edit_key(T) } end
function M.valid(T, S)
    if type(S) ~= 'table' or S.key == nil then return false, 'unstamped values are a guess wearing a cache\'s clothes' end
    if S.key ~= M.edit_key(T) then return false, ('stale: stamped at edit %d, template is at edit %d'):format(S.at or -1, #(T.edits or {})) end
    return true
end
--- instantiate from stamped values: a stale stamp is `unavailable` (the value class for
--- this generation was never extracted), never a silent fill.
function M.instantiate_stamped(T, S, env)
    local ok, why = M.valid(T, S)
    if not ok then return { ok = false, absence = 'unavailable', why = why } end
    return M.instantiate(T, S.values, env)
end

-- ── demand-keyed invalidation: build systems à la carte (Mokhov, Mitchell, Peyton Jones 2018) ──
-- A store maps keys to values; a task computes one key from the keys it FETCHES, and with
-- dynamic dependencies (a monadic task) the keys it fetches are known only by running it.
-- `track` records the (key, hash) pairs a run demanded; a VERIFYING TRACE keeps them so the
-- next build reruns a task only if a recorded dependency's post-build hash changed, which
-- gives minimality with dynamic dependencies and early cutoff (Shake = suspending scheduler
-- + verifying traces). A CONSTRUCTIVE trace also keeps the value, so a matching trace
-- restores it without a run. `M.show` stands in for the hash. Determinism is assumed
-- throughout; time is not measured, only reruns.
local function hash(v)
    if type(v) == 'table' and v.k then return 'T:' .. M.show(v) end
    if type(v) == 'table' then
        local es = {}
        for k, x in pairs(v) do es[#es + 1] = { k = tostring(k), h = hash(x) } end
        table.sort(es, function(a, b) return a.k < b.k end)
        local parts = {}
        for i, e in ipairs(es) do parts[i] = e.k .. '=' .. e.h end
        return '{' .. table.concat(parts, ',') .. '}'
    end
    return type(v) .. ':' .. tostring(v)
end
M.hash = hash

--- a store: values by key, plus the persistent build information (traces)
function M.new_store(inputs)
    local s = { values = {}, info = { vt = {}, ct = {} } }
    for k, v in pairs(inputs or {}) do s.values[k] = v end
    return s
end

--- §3.7 track: run a task, recording every dependency it demanded with the value's hash
function M.track(task, fetch)
    local deps = {}
    local v = task(function(k)
        local x = fetch(k)
        deps[#deps + 1] = { k = k, hash = hash(x) }
        return x
    end)
    return v, deps
end

--- §3.6 compute: the value of a key from the store as it is, updating nothing
function M.compute(task, store)
    return task(function(k) return store.values[k] end)
end

local REBUILDERS = {}
-- busy (§3.3): always rerun; the correctness oracle, not minimal
REBUILDERS.busy = function(store, key, value, task, fetch, log)
    local v, deps = M.track(task, fetch)
    log.executed[#log.executed + 1] = key
    return v
end
-- verifying traces (§4.2.2, Fig. 9): verify each recorded dependency THROUGH fetch, so the
-- dependency is brought up to date first and its post-build hash is what is compared. That
-- is where early cutoff comes from. Recorded order, stopping at the first change.
local function verify_deps(deps, fetch)
    for _, d in ipairs(deps) do
        if hash(fetch(d.k)) ~= d.hash then return false end
    end
    return true
end
REBUILDERS.vt = function(store, key, value, task, fetch, log)
    local t = store.info.vt[key]
    if t and value ~= nil and t.result == hash(value) and verify_deps(t.deps, fetch) then
        log.verified[#log.verified + 1] = key
        return value
    end
    local v, deps = M.track(task, fetch)
    store.info.vt[key] = { result = hash(v), deps = deps }
    log.executed[#log.executed + 1] = key
    return v
end
-- constructive traces (§4.2.3): several per key, each with its value; a trace whose
-- dependencies verify yields the value without a run (restored), a new one is recorded
REBUILDERS.ct = function(store, key, value, task, fetch, log)
    local list = store.info.ct[key] or {}
    store.info.ct[key] = list
    local hv = value ~= nil and hash(value) or nil
    local candidate
    for _, t in ipairs(list) do
        if verify_deps(t.deps, fetch) then
            if t.result == hv then log.verified[#log.verified + 1] = key; return value end
            candidate = candidate or t
        end
    end
    if candidate then log.restored[#log.restored + 1] = key; return candidate.value end
    local v, deps = M.track(task, fetch)
    list[#list + 1] = { result = hash(v), value = v, deps = deps }
    log.executed[#log.executed + 1] = key
    return v
end

--- §5.3 the suspending scheduler: build dependencies when they are demanded, each key at
--- most once per build (the done set). A dynamic cycle is refused by name (§3.6: correctness
--- is only defined for acyclic task descriptions). tasks: key -> function(fetch); a key with
--- no task is an input. Returns { store, executed, verified, restored }.
function M.build(tasks, target, store, opts)
    opts = opts or {}
    local rebuilder = REBUILDERS[opts.rebuilder or 'vt'] or error('no rebuilder ' .. tostring(opts.rebuilder))
    local log = { executed = {}, verified = {}, restored = {} }
    local done, visiting = {}, {}
    local fetch
    fetch = function(key)
        local task = tasks[key]
        if task and not done[key] then
            if visiting[key] then error('dynamic dependency cycle at ' .. tostring(key)) end
            visiting[key] = true
            local v = rebuilder(store, key, store.values[key], task, fetch, log)
            store.values[key] = v
            done[key], visiting[key] = true, nil
            return v
        end
        return store.values[key]
    end
    fetch(target)
    log.store = store
    return log
end

--- Def 3.1 correctness: inputs untouched, and every built non-input key equals its recompute
function M.build_correct(tasks, log, inputs_before)
    for k, v in pairs(inputs_before) do
        if not tasks[k] and hash(log.store.values[k]) ~= hash(v) then return false, 'input ' .. tostring(k) .. ' corrupted' end
    end
    -- Def 3.1 ranges over the keys REACHABLE from the target in this build: the ones the
    -- scheduler touched. A key built last time and no longer demanded may hold a stale value.
    local touched = {}
    for _, list in ipairs { log.executed, log.verified, log.restored } do for _, k in ipairs(list) do touched[k] = true end end
    for k in pairs(touched) do
        local task = tasks[k]
        if hash(M.compute(task, log.store)) ~= hash(log.store.values[k]) then return false, 'key ' .. tostring(k) .. ' not up to date' end
    end
    return true
end

--- the transitive dependents of a set of keys, over the VERIFYING traces of the previous
--- build (info.vt only; a build under the constructive rebuilder leaves it empty)
function M.dependents(store, changed)
    local out, frontier = {}, {}
    for k in pairs(changed) do frontier[k] = true end
    local grew = true
    while grew do
        grew = false
        for key, t in pairs(store.info.vt) do
            if not out[key] then
                for _, d in ipairs(t.deps) do
                    if frontier[d.k] or out[d.k] then out[key] = true; frontier[key] = true; grew = true; break end
                end
            end
        end
    end
    return out
end

-- ── demand over a family: an analyzer reads members THROUGH the template ────────────────
--- A read of a fixed site is keyed by the template's fixed subterm at that path (its
--- content, not its position), a read of a hole by the member's value for it. So a value
--- edit invalidates only readers of that hole, a rewrite only readers whose fixed subterm
--- changed, and the edit-log stamp (TENSIONS.md) is the coarse key this refines. The
--- analyzer receives `read(spec)` with spec = { path = {..} } or { hole = 'h' }.
--- Constructive traces, several per analyzer: a member whose demanded reads verify against
--- a recorded trace gets that result without a run. Members with equal demanded
--- projections therefore share one run: the store law priced a second time.
function M.family_analyze(T, Vs, analyzer, cache, env)
    cache = cache or { traces = {} }
    local results, runs, reused = {}, {}, {}
    local function reader(V)
        return function(spec)
            if spec.hole then
                local v = V[spec.hole]
                if v == nil then error('no value for hole ' .. spec.hole) end
                return v, 'hole:' .. spec.hole
            end
            local sub = at(T.body, spec.path)
            if sub == nil then error('no subterm at ' .. key(spec.path)) end
            if is_hole(sub) then return V[sub.h], 'hole:' .. sub.h end
            -- a fixed subterm may still contain holes below: render it for this member
            local unfilled = {}
            local rendered = subst(sub, V, unfilled)
            return rendered, 'fixed:' .. key(spec.path)
        end
    end
    for i, V in ipairs(Vs) do
        local read = reader(V)
        local hit
        for _, t in ipairs(cache.traces) do
            local ok = true
            for _, d in ipairs(t.deps) do
                local v = read(d.spec)
                if hash(v) ~= d.hash then ok = false; break end
            end
            if ok then hit = t; break end
        end
        if hit then
            results[i] = hit.result; reused[#reused + 1] = i
        else
            local deps = {}
            local r = analyzer(function(spec)
                local v, k = read(spec)
                deps[#deps + 1] = { spec = spec, k = k, hash = hash(v) }
                return v
            end)
            cache.traces[#cache.traces + 1] = { deps = deps, result = r }
            results[i] = r; runs[#runs + 1] = i
        end
    end
    return { results = results, runs = runs, reused = reused, cache = cache }
end


-- ── unification: the MEET of the generality order ─────────────────────────────
-- Martelli & Montanari 1982 §2 (read): the unification problem is a SET OF EQUATIONS, a
-- unifier is a substitution making every pair identical, and Algorithm 1 rewrites the set
-- into SOLVED FORM by four transformations: (a) swap t = x into x = t, (b) erase x = x,
-- (c) TERM REDUCTION (equal roots decompose into the argument equations, different roots
-- fail: Thm 2.1), (d) VARIABLE ELIMINATION (x = t with x elsewhere: substitute t for x in
-- every other equation; x inside t fails, the occurs check: Thm 2.2). Thm 2.3: it always
-- terminates (a well-founded triple: variables not yet solved, symbol occurrences, swaps),
-- with failure iff there is no unifier, and the solved form is the most general unifier,
-- unique up to renaming. The prototype's reading: two templates are two terms with holes;
-- the mgu instantiates both to the MOST GENERAL TEMPLATE BELOW BOTH, the meet the ticket
-- said the lattice lacked (CART-0879 item 1). Domains join the equations: a closed domain
-- IS an equation, kinds meet, and the rest is checked through the subsumption machinery
-- instance_of already uses (conservative where `entails` is partial). Hedges: one hedge
-- hole in a list on one side binds the forced slice (join's rule); one on each side leaves
-- a fresh hedge hole between the common ends; several in one list are refused by name
-- (sequence unification with repeated sequence variables is infinitary; recalled, not read
-- this pass). Context holes are refused.
--   solve(eqs, H)      -> { sigma, holes, fresh, free } | nil, why, at
--   unify(T1, T2)      -> { template, left, right, renamed, fresh } | nil, why, at
--   relax(D)           the kinds envelope of a summary (query mode over derived domains)


-- ── transplant: apply the edit a → b to c (CART-0879 item 2; CART-0863's REFLECT) ──────
-- Meng, Kim, McKinley, "Systematic Editing: Generating Program Transformations from an
-- Example" (PLDI 2011), §3 read: from one exemplar edit (mA_old, mA_new) SYDIT derives an
-- ABSTRACT, CONTEXT-AWARE edit script (AST edit operations positioned relative to the
-- unchanged statements they depend on; every variable, method and type name replaced by an
-- abstract one, v1 m1 T1, the SAME abstraction in old and new), matches the abstract context
-- in a target mB under a one-to-one identifier mapping, and applies the concretized script.
-- Here the three steps are three operators that exist:
--   context     = join(a, c): the lgg of exemplar and target IS the abstract context with the
--                 identifier abstraction (holes) and the one-to-one mapping (Plotkin's rule:
--                 one hole per value pair) in one step. SYDIT's context is dependence-based
--                 and partial (default k = 1, upstream); ours is total structural agreement.
--   edit        = classify(T_ac, V_a, b): the exemplar's edit in the context's frame; a value
--                 edit, a template edit (the shared part changed, holes relocated by position
--                 where the old region is intact), both, or a STRADDLE.
--   application = the template part through migrate (propagate on the two-member family);
--                 the value part per changed hole: b's new value with every occurrence of a's
--                 old value replaced by c's (SYDIT's concretization; a wrap (g x) over y is
--                 (g y), a replacement z stays z: the ticket's β-reduction in first-order form).
--                 When classify STRADDLES (a hole's value changed at some sites only, or occurs
--                 several times in a rewritten region), the positional frame is ambiguous and
--                 SYDIT's own route runs instead: abstract b by a's hole VALUES, every
--                 occurrence a site (Plotkin's rule), and instantiate with c's values. That
--                 route is refused by name when a hole's value also occurs in the shared part,
--                 because b's mentions of it could not be attributed (the one-to-one mapping
--                 SYDIT requires fails the same way).
-- Nothing is recorded on any edit log: transplant derives a term, it does not move a family.
--   transplant(a, b, c, {align, env, context}) -> { result, kind, route, context, template,
--            values, applied, lifted, replaced, dropped, classify } | nil, why, C
local function abstract_by_value(t, Vs) -- every occurrence of a hole's value becomes a site
    -- top-down, so an outer value (g x) is taken before the x inside it; a node equals at most one
    -- of the (distinct) values, so no ordering among them is needed
    local order = {}
    for h, v in pairs(Vs) do order[#order + 1] = { h = h, v = v } end
    table.sort(order, function(x, y) return x.h < y.h end)
    local function go(u)
        if is_hole(u) then return u end
        for _, o in ipairs(order) do if M.eq(u, o.v) then return M.hole(o.h) end end
        if not u.kids then return M.copy(u) end
        local kids = {}
        for i, c in ipairs(u.kids) do kids[i] = go(c) end
        return M.rebuild(u, kids)
    end
    return go(t)
end
function M.transplant(a, b, c, opts)
    opts = opts or {}
    local env = opts.env
    local T, Va, Vc
    if opts.context then
        -- REFLECT's shape: a supplied context (an idiom template) in place of the lgg
        T = opts.context
        local ma, mc = M.match(T, a, env), M.match(T, c, env)
        if not ma.ok then return nil, 'a does not match the supplied context: ' .. ma.refusal.why end
        if not mc.ok then return nil, 'c does not match the supplied context: ' .. mc.refusal.why end
        Va, Vc = ma.values, mc.values
    else
        -- the context: under the 'none' rigidity by default so the edit stays classifiable
        -- (classify refuses repetition holes; an arity divergence becomes a node hole)
        local r, why = M.join(M.template(M.copy(a)), c, { align = opts.align or 'none', prefix = opts.prefix or 't', env = env })
        if not r then return nil, 'context: ' .. why end
        T, Va, Vc = r.template, r.left({}), r.right({})
        T.edits = {}
    end
    local C, cwhy = M.classify(T, Va, b, env)
    if not C then return nil, 'the exemplar does not instantiate its own context: ' .. tostring(cwhy) end
    local out = { kind = C.kind, route = 'positional', context = T, classify = C, applied = {}, lifted = {}, replaced = {}, dropped = {} }
    if C.kind == 'none' then out.result, out.template, out.values = M.copy(c), T, Vc; return out end
    if C.kind == 'unsupported' then return nil, C.why, C end
    local template, W = T, {}
    local function concretize(h, from, to, vc) -- b's new value with a's old value replaced by c's, everywhere
        local occ = {}
        occurrences(to, from, {}, occ)
        if #occ == 0 then out.replaced[#out.replaced + 1] = { h = h, from = vc, to = to }; return M.copy(to) end
        local sites = {}
        for i, p in ipairs(occ) do sites[i] = { path = p } end
        local D = M.abstract(to, { v = { sites = sites, domain = M.open(), origin = 'derived' } })
        local I = M.instantiate(D, { v = vc }, env)
        out.lifted[#out.lifted + 1] = { h = h, wrap = D, at = #occ, from = vc, to = I.term }
        return I.term
    end
    if C.kind == 'straddle' then
        -- SYDIT's route: abstract b by a's hole values, every occurrence a site
        out.route, out.straddle = 'abstracted', { why = C.why, proposal = C.proposal }
        local seen = {}
        for h, v in pairs(Va) do
            local k = M.show(v)
            if seen[k] then return nil, ('ambiguous: holes %s and %s hold the same value %s in a, so b\'s mentions of it cannot be attributed (%s)'):format(seen[k], h, k, C.why), C end
            seen[k] = h
            local occ = {}
            occurrences(T.body, v, {}, occ)
            if #occ > 0 then
                return nil, ('ambiguous: the value %s of hole %s also occurs in the shared part at %s, so b\'s mentions of it cannot be attributed (%s)'):format(
                    M.show(v), h, key(occ[1]), C.why), C
            end
        end
        local body = abstract_by_value(b, Va)
        local domains = {}
        local present = M.hole_names(M.template(body))
        local set = {}
        for _, h in ipairs(present) do set[h] = true; domains[h] = { domain = M.open(), origin = 'derived' } end
        for h in pairs(Va) do
            if set[h] then W[h] = Vc[h]; out.applied[#out.applied + 1] = { h = h }
            else out.dropped[#out.dropped + 1] = { h = h, value = Vc[h], why = 'hole ' .. h .. ' has no site in b: c\'s value has nowhere to go' } end
        end
        template = M.template(body, domains)
    else
        for h, v in pairs(Vc) do W[h] = v end
        if #C.regions > 0 then
            local mig = assert(M.migrate(T, C.template, { Va, Vc }, env))
            if not mig.values[2] then
                local d = mig.dropped[1]
                return nil, 'the template edit does not carry to c: ' .. tostring(d and d.why), C
            end
            template, W = C.template, mig.values[2]
            for _, p in ipairs(C.regions) do out.applied[#out.applied + 1] = { region = key(p) } end
        end
        for _, ch in ipairs(C.changed) do
            local h, vc = ch.h, W[ch.h]
            if vc == nil then
                out.dropped[#out.dropped + 1] = { h = h, why = 'hole ' .. h .. ' has no value in c after the template edit' }
            else
                W[h] = concretize(h, ch.from, ch.to, vc) -- equal values are the trivial case of the same rule
            end
        end
    end
    -- the result family is {b, c'}: its derived domains are summaries of that column (DOMAINS.md)
    local Vb = M.match(template, b, env)
    template = M.rederive_domains(M.copy(template), { Vb.ok and Vb.values or {}, W })
    local I = M.instantiate(template, W, env)
    if not I.ok then
        local whys = {}
        for _, x in ipairs(I.rejected) do whys[#whys + 1] = x end
        for _, x in ipairs(I.unfilled) do whys[#whys + 1] = 'no value for ' .. x end
        return nil, 'the transplanted values do not instantiate the edited context: ' .. table.concat(whys, '; '), C
    end
    out.result, out.template, out.values = I.term, template, W
    return out
end

-- ── LINK BY VALUE: a family is a relation (Codd 1970) ─────────────────────────
-- A family (T, {V_i}) is a relation in Codd's sense: the holes are its domains, each V_i a
-- tuple, T the heading; what his model lacks, sites(T), says where each domain lives in the
-- text. A hole is a PRIMARY KEY when its column is unique (§1.3). A link A.from → B.to is
-- Codd's FOREIGN KEY when B.to is B's primary key ("its elements are values of the primary
-- key of some relation S"), and otherwise a join with POINTS OF AMBIGUITY (§2.1.3: an element
-- with several relatives under both). The link is the natural join R*S = {(a,b,c) : R(a,b) ∧
-- S(b,c)} of π(A.from) with π(B.to), returned as tuples of member indices. A fan-out is never
-- refused: the answer is a set, as locate's is (LINK.md).
local function family(F) -- accept a template carrying .values (generalize, vertical) or { template, values }
    if F.body then return { template = F, values = F.values or {} } end
    return F
end
--- read a member's key: a reader is nil (the value itself), a { template, hole } pair (the value
--- is matched against the template, an embed inside it parsing a string under another grammar,
--- and the key is the hole's value), or, as the escape hatch, a function(value) -> term | nil
local function read_key(v, reader, env)
    if v == nil then return nil end
    if reader == nil then return v end
    if type(reader) == 'function' then return reader(v) end
    local m = M.match(reader.template, v, env)
    if not m.ok then return nil end
    return m.values[reader.hole]
end
--- is `hole` a primary key of F? true, or false with the duplicated values and their members
function M.primary_key(F, hole, opts)
    F = family(F)
    local seen, dups = {}, {}
    for i, V in ipairs(F.values) do
        local k = read_key(V[hole], opts and opts.read, opts and opts.env)
        if k ~= nil then
            local found = false
            for _, e in ipairs(seen) do
                if M.eq(e.key, k) then
                    found = true
                    e.members[#e.members + 1] = i
                    if #e.members == 2 then dups[#dups + 1] = e end
                end
            end
            if not found then seen[#seen + 1] = { key = k, members = { i } } end
        end
    end
    return #dups == 0, dups
end
--- link(A, B, { from, to, read_from, read_to, complete, env }): the natural join of A.from with B.to
function M.link(A, B, spec)
    A, B = family(A), family(B)
    assert(spec and spec.from and spec.to, 'link: from and to hole names are required')
    local env = spec.env
    local out = { from = spec.from, to = spec.to, tuples = {}, pairs = {}, dangling = {},
        unreadable = { a = {}, b = {} }, ambiguity = {}, fan = 0,
        readers = { from = spec.read_from and (type(spec.read_from) == 'table' and spec.read_from.template) or nil,
                    to = spec.read_to and (type(spec.read_to) == 'table' and spec.read_to.template) or nil },
        complete = spec.complete }
    local bkeys = {}
    for j, V in ipairs(B.values) do
        local k = read_key(V[spec.to], spec.read_to, env)
        if k == nil then out.unreadable.b[#out.unreadable.b + 1] = j else bkeys[#bkeys + 1] = { j = j, key = k } end
    end
    out.is_function = M.primary_key({ template = B.template, values = B.values }, spec.to, { read = spec.read_to, env = env })
    local relatives = {} -- per key value: the a's and the b's, for Codd's points of ambiguity
    for i, V in ipairs(A.values) do
        local k = read_key(V[spec.from], spec.read_from, env)
        if k == nil then
            out.unreadable.a[#out.unreadable.a + 1] = i
        else
            local bs = {}
            for _, e in ipairs(bkeys) do
                if M.eq(e.key, k) then
                    bs[#bs + 1] = e.j
                    out.tuples[#out.tuples + 1] = { a = i, b = e.j, key = k, from = spec.from, to = spec.to }
                end
            end
            local rel
            for _, r in ipairs(relatives) do if M.eq(r.key, k) then rel = r end end
            if not rel then rel = { key = k, a = {}, b = bs }; relatives[#relatives + 1] = rel end
            rel.a[#rel.a + 1] = i
            if #bs == 0 then out.dangling[#out.dangling + 1] = i end
            if #bs > out.fan then out.fan = #bs end
            out.pairs[#out.pairs + 1] = { a = i, b = bs, key = k }
        end
    end
    for _, r in ipairs(relatives) do
        if #r.a > 1 and #r.b > 1 then out.ambiguity[#out.ambiguity + 1] = r end
    end
    return out
end
--- Codd §1.4 normalization, one nonsimple domain: the hedge hole's column of F is a relation of
--- its own. Each member's sequence is matched element by element against T_elem; the parent's
--- primary key is copied down under its own name (opts.key, a simple domain); the child family
--- carries parent and index per row. His two conditions: the key component must be simple, and
--- the nonsimple domains form a tree (each normalize call takes one node of it).
function M.normalize(F, hole, T_elem, opts)
    F = family(F)
    opts = opts or {}
    local key = opts.key -- one hole name or a list (a composite key: Codd's salaryhistory' is keyed by man#, jobdate)
    local keys = type(key) == 'table' and key or (key and { key } or {})
    local rows, unmatched, values = {}, {}, {}
    for i, V in ipairs(F.values) do
        local col = V[hole]
        if type(col) ~= 'table' or col.k ~= 'seq' then
            return nil, ('normalize: hole %s of member %d is not a sequence (a simple domain needs no normalization)'):format(hole, i)
        end
        for _, k in ipairs(keys) do
            local kv = V[k]
            if kv == nil then return nil, ('normalize: member %d has no value for the key %s'):format(i, k) end
            if type(kv) == 'table' and kv.k == 'seq' then
                return nil, ('normalize: the key %s is nonsimple (Codd 1970 §1.4, condition 2)'):format(k)
            end
        end
        for k2, e in ipairs(col.kids) do
            local m = M.match(T_elem, e, opts.env)
            if m.ok then
                local row = {}
                for h, v in pairs(m.values) do row[h] = v end
                for _, k in ipairs(keys) do
                    if row[k] ~= nil then return nil, ('normalize: the element template already has a hole named %s'):format(k) end
                    row[k] = M.copy(V[k])
                end
                values[#values + 1] = row
                rows[#rows + 1] = { parent = i, index = k2, sites = m.sites }
            else
                unmatched[#unmatched + 1] = { parent = i, index = k2, why = m.refusal and m.refusal.why }
            end
        end
    end
    return { template = T_elem, values = values, rows = rows, key = key, from = { hole = hole }, unmatched = unmatched }
end
--- follow links from one member: the set of members at every step, the join composed. A
--- member with no relative is a typed absence: `absent` only when the link's target family
--- was declared complete (spec.complete = true); `unavailable` when complete = 'unavailable';
--- `frontier` otherwise (TENSIONS.md: the reading axis; the link cannot decide completeness).
function M.chain(start, links)
    local members = type(start) == 'table' and start or { start }
    local steps, absences = { { members = members } }, {}
    for si, L in ipairs(links) do
        local nxt, seen = {}, {}
        for _, m in ipairs(members) do
            local found = false
            for _, pr in ipairs(L.pairs) do
                if pr.a == m then
                    for _, j in ipairs(pr.b) do
                        if not seen[j] then seen[j] = true; nxt[#nxt + 1] = j end
                        found = true
                    end
                end
            end
            if not found then
                local kind = L.complete == true and 'absent' or (L.complete == 'unavailable' and 'unavailable') or 'frontier'
                absences[#absences + 1] = { absence = kind, licenses = M.ABSENCE[kind].licenses, at = si, member = m,
                    why = ('member %d: no %s with %s equal to its %s (%s)'):format(m, L.to, L.to, L.from,
                        L.complete == true and 'the target family is complete' or 'the target family was not declared complete') }
            end
        end
        table.sort(nxt)
        members = nxt
        steps[#steps + 1] = { members = members, link = si, fan = L.fan }
    end
    return { steps = steps, members = members, absences = absences, ok = #members > 0 }
end

-- ── the gate: leave-one-out over (T, V, I) ────────────────────────────────────
-- Each leg is a separate function taking exactly the two legs it may read, so a spec can
-- poison the third and prove the derivation never consults it (vacuity guard).
M.derive = {
    instance = function(T, V, env) return M.instantiate(T, V, env) end,
    values   = function(T, I, env) return M.match(T, I, env) end,
    template = function(H, I) return M.abstract(I, H) end,
}

function M.values_eq(A, B)
    for h, v in pairs(A) do if not M.eq(v, B[h]) then return false end end
    for h in pairs(B) do if A[h] == nil then return false end end
    return true
end

function M.gate(T, V, I, env, H)
    H = H or M.sites(T)
    local r = {}
    local i2 = M.derive.instance(T, V, env)
    r.instance = { ok = i2.ok, agree = i2.ok and M.eq(i2.term, I) or false,
        why = not i2.ok and ('unfilled: ' .. table.concat(i2.unfilled, ',') .. ' rejected: '
            .. table.concat(i2.rejected, ',') .. ' extra: ' .. table.concat(i2.extra, ',')) or nil }
    local m = M.derive.values(T, I, env)
    r.values = { ok = m.ok, agree = m.ok and M.values_eq(m.values, V) or false,
        why = not m.ok and (m.refusal.at .. ': ' .. m.refusal.why) or nil }
    local okT, t2 = pcall(M.derive.template, H, I)
    if okT then r.template = { ok = true, agree = M.eq(t2.body, T.body) }
    else r.template = { ok = false, agree = false, why = tostring(t2):gsub('^.-: ', '') } end -- a context site without a cursor (H from sites(T)): abstract refuses by name
    local failed = {}
    for _, leg in ipairs { 'instance', 'values', 'template' } do
        if not r[leg].agree then failed[#failed + 1] = leg end
    end
    r.verdict = #failed == 0 and 'unrefuted' or 'refuted'
    r.failed = failed
    return r
end

--- the keyed-table fragment: every term a table whose kids are `pair` nodes with distinct
--- string-literal keys. Returns per-instance { map = key -> pair, order = {keys} } or nil.
function M.keyed_fields(ts)
    local out = {}
    for i, t in ipairs(ts) do
        if t.k ~= 'table' then return nil end
        local map, order = {}, {}
        for _, p in ipairs(t.kids or {}) do
            local kk = p.k == 'pair' and p.kids and p.kids[1]
            if not (kk and kk.k == 'lit' and type(kk.v) == 'string') or map[kk.v] then return nil end
            map[kk.v] = p; order[#order + 1] = kk.v
        end
        out[i] = { map = map, order = order }
    end
    return out
end

-- ── rigid unranked generalization of a PAIR (UFOG, Kutsia, Levy, Villaret 2014) ──
-- Terms are unranked: a child list is a HEDGE. Two variable sorts: an individual hole
-- (?x) stands for one term, a hedge hole (?X...) for a sequence. The problem is FINITARY:
-- several incomparable lggs. The RIGIDITY FUNCTION picks which top symbols align — here
-- every longest common subsequence — and the rigid variant forbids two hedge holes side
-- by side. Between aligned positions: equal-length gaps generalize element-wise with
-- individual holes; unequal gaps become one hedge hole. ⚠ That last rule is a
-- simplification of the published algorithm, which can split an unequal gap further;
-- it under-approximates the mcsg there.
-- ★ THE RIGIDITY FUNCTION IS A CHOICE, and the survey says so ("other, practically
-- interesting rigidity functions"). First cut aligned every `call` with every other
-- `call`, so log(..) aligned with close(..) and a three-row body had THREE incomparable
-- lggs. For code the head symbol of a call is its CALLEE; with that, one.
local function symbol(t)
    if t.k == 'lit' then return 'lit:' .. tostring(t.v) end
    if t.k == 'name' then return 'name:' .. t.n end
    if t.k == 'call' and t.kids and t.kids[1] and t.kids[1].k == 'name' then return 'call:' .. t.kids[1].n end
    if t.k == 'hole' then return '?' .. t.h .. (t.rep and '...' or '') end -- an input variable
    return t.k
end

-- every distinct longest-common-subsequence alignment of two symbol lists, as lists of {i, j}
local function lcs_alignments(A, B, cap)
    local n, m = #A, #B
    local L = {}
    for i = 0, n + 1 do L[i] = {}; for j = 0, m + 1 do L[i][j] = 0 end end
    for i = n, 1, -1 do
        for j = m, 1, -1 do
            if A[i] == B[j] then L[i][j] = L[i + 1][j + 1] + 1
            else L[i][j] = math.max(L[i + 1][j], L[i][j + 1]) end
        end
    end
    local out, truncated = {}, false
    -- an alignment is determined by its FIRST pair, then recursively; distinct first
    -- pairs give distinct alignments, so each is produced once
    local function rec(i, j)
        if L[i][j] == 0 then return { {} } end
        local res = {}
        for i2 = i, n do
            for j2 = j, m do
                if A[i2] == B[j2] and L[i2 + 1][j2 + 1] + 1 == L[i][j] then
                    for _, rest in ipairs(rec(i2 + 1, j2 + 1)) do
                        local al = { { i2, j2 } }
                        for _, p in ipairs(rest) do al[#al + 1] = p end
                        res[#res + 1] = al
                        if #res >= cap then truncated = true; return res end
                    end
                end
            end
        end
        return res
    end
    return rec(1, 1), truncated
end

-- ── RIGIDITY FUNCTIONS (Definition 4.1 / Example 4.2) ─────────────────────────
-- Each takes two symbol words and returns the set of alignments, as lists of {i, j}.
-- An empty set means "no structure to keep": the whole pair goes to the store.
M.rigidity = {}
M.rigidity.lcs = function(A, B, cap) return lcs_alignments(A, B, cap) end
--- all longest common subsequences of length at least k (cartograph's `min_rows`)
M.rigidity.lcs_min = function(k)
    return function(A, B, cap)
        local als, trunc = lcs_alignments(A, B, cap)
        if #als == 0 or #als[1] < k then return {}, trunc end
        return als, trunc
    end
end
--- all longest common SUBSTRINGS (contiguous)
M.rigidity.substring = function(A, B)
    local best, ends = 0, {}
    local prev = {}
    for i = 1, #A do
        local cur = {}
        for j = 1, #B do
            if A[i] == B[j] then
                cur[j] = (prev[j - 1] or 0) + 1
                if cur[j] > best then best, ends = cur[j], { { i, j } }
                elseif cur[j] == best and best > 0 then ends[#ends + 1] = { i, j } end
            end
        end
        prev = cur
    end
    if best == 0 then return {}, false end
    local out = {}
    for _, e in ipairs(ends) do
        local al = {}
        for k = best - 1, 0, -1 do al[#al + 1] = { e[1] - k, e[2] - k } end
        out[#out + 1] = al
    end
    return out, false
end
--- the same-position common subsequence: the paper's remark that this reproduces
--- standard (ranked, Plotkin) anti-unification
M.rigidity.positional = function(A, B)
    local al = {}
    for i = 1, math.min(#A, #B) do if A[i] == B[i] then al[#al + 1] = { i, i } end end
    return { al }, false
end

--- the minimal complete set: drop a template that is strictly more general than another
--- (some other is an instance of it and not the reverse), and every duplicate up to
--- renaming after the first. The order is BK §2's instance order, matching template against
--- template with the instance side's variables as constants (VMIN.md). Sound under the
--- budget, not complete: a drop needs a successful match, so a budget refusal can only keep
--- a dominated template; the refusals are counted and returned.
--- Returns kept, dropped ({ template, by = index into kept's source list }), budget refusals.
function M.minimize(templates, opts)
    opts = opts or {}
    local refusals = 0
    local function below(U, T) -- U is an instance of T
        local m = M.match(T, U.body, { defs = opts.defs, hole_domains = U.holes, cap = opts.cap })
        if not m.ok and m.refusal and m.refusal.why:find('budget', 1, true) then refusals = refusals + 1 end
        return m.ok
    end
    local kept, dropped = {}, {}
    for i, T in ipairs(templates) do
        local by
        for j, U in ipairs(templates) do
            if i ~= j and below(U, T) then
                if not below(T, U) or j < i then by = j; break end
            end
        end
        if by then dropped[#dropped + 1] = { template = T, by = by, index = i }
        else kept[#kept + 1] = T end
    end
    return kept, dropped, refusals
end

function M.rigid(a, b, opts)
    opts = opts or {}
    local cap = opts.cap or 32
    local R = opts.rigidity or M.rigidity.lcs
    if type(R) == 'string' then R = M.rigidity[R] end
    local ctx = { memo = {}, n = 0, v1 = {}, v2 = {}, domains = {}, truncated = false }
    local function fresh(x, y, hedge)
        local k = (hedge and 'H' or 'T') .. '\1' .. M.show(x) .. '\1' .. M.show(y)
        if ctx.memo[k] then return ctx.memo[k] end
        ctx.n = ctx.n + 1
        local h = (hedge and 'X' or 'x') .. ctx.n
        ctx.memo[k] = h
        ctx.v1[h], ctx.v2[h] = x, y
        ctx.domains[h] = hedge and M.rep(M.open()) or M.open()
        return h
    end
    local function product(segs)
        local acc = { {} }
        for _, alts in ipairs(segs) do
            local nxt = {}
            for _, prefix in ipairs(acc) do
                for _, alt in ipairs(alts) do
                    local row = { unpack(prefix) }
                    for _, kid in ipairs(alt) do row[#row + 1] = kid end
                    nxt[#nxt + 1] = row
                    if #nxt >= cap then ctx.truncated = true; break end
                end
                if #nxt >= cap then break end
            end
            acc = nxt
        end
        return acc
    end
    local gen_term, gen_hedge
    local function singles(alts)
        local w = {}
        for _, x in ipairs(alts) do w[#w + 1] = { x } end
        return w
    end
    gen_term = function(t1, t2)
        if symbol(t1) ~= symbol(t2) then return { M.hole(fresh(t1, t2, false)) } end
        if t1.k == 'lit' or t1.k == 'name' then return { M.copy(t1) } end
        local out = {}
        for _, kids in ipairs(gen_hedge(t1.kids or {}, t2.kids or {})) do
            out[#out + 1] = { k = t1.k, kids = kids }
        end
        return out
    end
    gen_hedge = function(h1, h2)
        local A, B = {}, {}
        for i, t in ipairs(h1) do A[i] = symbol(t) end
        for j, t in ipairs(h2) do B[j] = symbol(t) end
        local aligns, trunc = R(A, B, cap)
        if trunc then ctx.truncated = true end
        -- R = ∅ is the rule R-S-H: the whole pair is stored, which is the same as the
        -- empty alignment (the paper says so beside the rule)
        if #aligns == 0 then aligns = { {} } end
        local out = {}
        for _, al in ipairs(aligns) do
            local segs, pi, pj = {}, 0, 0
            local function gap(i1, i2, j1, j2)
                local g1, g2 = {}, {}
                for i = i1, i2 do g1[#g1 + 1] = h1[i] end
                for j = j1, j2 do g2[#g2 + 1] = h2[j] end
                if #g1 == 0 and #g2 == 0 then return end
                if #g1 == #g2 and opts.refine ~= false then
                    -- THE TERM-VARIABLE REFINEMENT (paper p.14): an equal-length stored pair
                    -- becomes a sequence of term variables instead of one hedge variable.
                    -- Definition 4.3 proper has NO term variables and would give one hedge
                    -- hole here. Stored pairs are OPAQUE: no decomposition below this point,
                    -- which is what makes Quiz 2 come out as g(x),h(x) and not g(a),h(a).
                    for e = 1, #g1 do segs[#segs + 1] = { { M.hole(fresh(g1[e], g2[e], false)) } } end
                else
                    segs[#segs + 1] = { { M.hole(fresh(M.seq(g1), M.seq(g2), true), true) } }
                end
            end
            for _, p in ipairs(al) do
                gap(pi + 1, p[1] - 1, pj + 1, p[2] - 1)
                segs[#segs + 1] = singles(gen_term(h1[p[1]], h2[p[2]]))
                pi, pj = p[1], p[2]
            end
            gap(pi + 1, #h1, pj + 1, #h2)
            for _, row in ipairs(product(segs)) do out[#out + 1] = row end
            if #out >= cap then ctx.truncated = true; break end
        end
        return out
    end
    local bodies = {}
    if a.k == 'seq' and b.k == 'seq' then
        for _, kids in ipairs(gen_hedge(a.kids, b.kids)) do bodies[#bodies + 1] = M.seq(kids) end
    else
        bodies = gen_term(a, b)
    end
    local templates = {}
    for _, body in ipairs(bodies) do
        local T = M.template(body, {})
        -- each candidate carries ITS OWN slice of the store: the substitutions that take
        -- it back to either input ("the store gives us the difference", paper §6)
        T.values = { {}, {} }
        for h in pairs(T.holes) do
            T.holes[h].domain = ctx.domains[h]
            T.values[1][h], T.values[2][h] = ctx.v1[h], ctx.v2[h]
        end
        templates[#templates + 1] = T
    end
    -- the mcsg: drop a template that is strictly more general than another, and every
    -- duplicate-up-to-renaming after the first (M.minimize, shared with vertical since VMIN.md)
    local keep, dropped, refusals = M.minimize(templates)
    return { templates = keep, candidates = #templates, values = { ctx.v1, ctx.v2 },
        truncated = ctx.truncated, dropped = dropped, budget_refusals = refusals }
end

-- ── VERTICAL DIFFERENCES: unranked second-order anti-unification ─────────────
-- Baumgartner & Kutsia, "Unranked Second-Order Anti-Unification" (WoLLIC 2014). A hedge
-- variable (?x...) absorbs a HORIZONTAL difference, a context variable (?X(...)) a
-- VERTICAL one: a wrapper of unknown shape around shared content, e.g. f(a,b) vs
-- g(h(a,b)) -> X(a,b). The SKELETON — which symbols of the two pre-order words are kept —
-- is the parameter: given as an admissible alignment, the rigid lgg is unique modulo
-- renaming (their Theorem 5), which is what licenses the fixed-order recursion below in
-- place of their rewrite rules. Positions are paths; symbols are plain kinds here (a
-- call's callee appears as a child symbol anyway, so the callee convention is not used
-- for vertical skeletons).

local function vsym(t)
    if t.k == 'lit' then return 'lit:' .. tostring(t.v) end
    if t.k == 'name' then return 'name:' .. t.n end
    if t.k == 'hole' then return '?' .. t.h end
    return t.k
end
local function slice(list, i, j)
    local out = {}
    for k = i, j do out[#out + 1] = list[k] end
    return out
end
local function cat_flat(...)
    local out = {}
    for _, l in ipairs { ... } do for _, x in ipairs(l) do out[#out + 1] = x end end
    return out
end
local function is_strict_prefix(p, q) -- p strict ancestor of q
    if #p >= #q then return false end
    for i = 1, #p do if p[i] ~= q[i] then return false end end
    return true
end
local function prefix_eq(p, q) -- p ⊑ q
    if #p > #q then return false end
    for i = 1, #p do if p[i] ~= q[i] then return false end end
    return true
end
local function lcp(p, q)
    local out = {}
    for i = 1, math.min(#p, #q) do
        if p[i] == q[i] then out[#out + 1] = p[i] else break end
    end
    return out
end
local function lexlt(p, q) -- strict lexicographic order on positions = preorder
    for i = 1, math.min(#p, #q) do if p[i] ~= q[i] then return p[i] < q[i] end end
    return #p < #q
end
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

-- ── KEYED (JSON-LIKE) n-ARY GENERALIZATION ────────────────────────────────────────────
-- Objects align BY KEY, never by position; arrays of objects carrying a merge key (k8s:
-- `name`) align by that key; other arrays positionally when lengths agree, else as one
-- hole. Scalars equal across all instances stay; otherwise a hole. The store is NON-LINEAR
-- across the whole document: two sites whose value vectors agree share one hole (the
-- service name used in six places is one parameter). A key present in some instances only
-- gets a PRESENCE hole (a boolean vector) and its body is generalized over the instances
-- that have it. Values: { o = {k = v}, keys = {ordered} } object, { a = {...} } array,
-- { null = true } null, Lua scalars otherwise. n-ary from the start: a directory is a cluster.
M.KV_ABSENT = setmetatable({}, { __tostring = function() return 'ABSENT' end })
local function kv_kind(v)
    if v == M.KV_ABSENT then return 'absent' end
    if type(v) == 'table' then
        if v.o then return 'obj' elseif v.a then return 'arr' elseif v.null then return 'null' end
    end
    return 'scalar'
end
local function kv_ser(v)
    local k = kv_kind(v)
    if k == 'absent' then return '⊥' elseif k == 'null' then return 'null' end
    if k == 'scalar' then return type(v) .. ':' .. tostring(v) end
    if k == 'arr' then
        local parts = {}
        for i, x in ipairs(v.a) do parts[i] = kv_ser(x) end
        return '[' .. table.concat(parts, ',') .. ']'
    end
    local keys = {}
    for key in pairs(v.o) do keys[#keys + 1] = key end
    table.sort(keys)
    local parts = {}
    for i, key in ipairs(keys) do parts[i] = key .. '=' .. kv_ser(v.o[key]) end
    return '{' .. table.concat(parts, ',') .. '}'
end
M.kv_ser = kv_ser
function M.kv_eq(x, y) return kv_ser(x) == kv_ser(y) end

function M.kv_generalize(instances, opts)
    opts = opts or {}
    local keyfield = opts.keyfield or 'name'
    local n = #instances
    local holes, byvec = {}, {}
    local function hole(kind, vals, path)
        local k = kind .. '|' .. (function() local p = {} for i = 1, n do p[i] = kv_ser(vals[i]) end return table.concat(p, '\1') end)()
        local h = byvec[k]
        if not h then
            h = { id = 'h' .. (#holes + 1), kind = kind, values = vals, sites = {} }
            holes[#holes + 1] = h; byvec[k] = h
        end
        h.sites[#h.sites + 1] = path
        return { hole = h.id }
    end
    local function present(vals)
        local out, any_absent = {}, false
        for i = 1, n do out[i] = vals[i] ~= M.KV_ABSENT; if not out[i] then any_absent = true end end
        return out, any_absent
    end
    local gen
    gen = function(vals, path)
        local kinds, first = {}, nil
        for i = 1, n do
            local k = kv_kind(vals[i])
            if k ~= 'absent' then kinds[k] = true; first = first or vals[i] end
        end
        local nk = 0
        for _ in pairs(kinds) do nk = nk + 1 end
        if nk ~= 1 then return hole('mixed', vals, path) end
        local k = kv_kind(first)
        if k == 'scalar' or k == 'null' then
            local same = true
            for i = 1, n do if vals[i] ~= M.KV_ABSENT and not M.kv_eq(vals[i], first) then same = false end end
            if same then return first end
            return hole('value', vals, path)
        end
        if k == 'obj' then
            local keys, seen = {}, {}
            for i = 1, n do
                if vals[i] ~= M.KV_ABSENT then
                    for _, key in ipairs(vals[i].keys) do if not seen[key] then seen[key] = true; keys[#keys + 1] = key end end
                end
            end
            local o = {}
            for _, key in ipairs(keys) do
                local sub = {}
                for i = 1, n do sub[i] = vals[i] == M.KV_ABSENT and M.KV_ABSENT or (vals[i].o[key] == nil and M.KV_ABSENT or vals[i].o[key]) end
                local _, some_absent = present(sub)
                -- absent because the whole parent is absent does not count as optional here
                local optional = false
                for i = 1, n do if vals[i] ~= M.KV_ABSENT and sub[i] == M.KV_ABSENT then optional = true end end
                local body = gen(sub, path .. '.' .. key)
                if optional then
                    local pres = {}
                    for i = 1, n do pres[i] = vals[i] == M.KV_ABSENT and M.KV_ABSENT or (sub[i] ~= M.KV_ABSENT) end
                    o[key] = { opt = hole('presence', pres, path .. '.' .. key .. '?'), body = body }
                else
                    o[key] = body
                end
                local _ = some_absent
            end
            return { o = o, keys = keys }
        end
        -- arrays: keyed if every element everywhere is an object carrying the merge key
        local keyed = true
        for i = 1, n do
            if vals[i] ~= M.KV_ABSENT then
                for _, x in ipairs(vals[i].a) do
                    if not (kv_kind(x) == 'obj' and x.o[keyfield] ~= nil and kv_kind(x.o[keyfield]) == 'scalar') then keyed = false end
                end
                if #vals[i].a == 0 then keyed = false end
            end
        end
        if keyed then
            local asobj = {}
            for i = 1, n do
                if vals[i] == M.KV_ABSENT then asobj[i] = M.KV_ABSENT
                else
                    local o, keys = {}, {}
                    for _, x in ipairs(vals[i].a) do local kk = tostring(x.o[keyfield]); o[kk] = x; keys[#keys + 1] = kk end
                    asobj[i] = { o = o, keys = keys }
                end
            end
            local body = gen(asobj, path .. '[' .. keyfield .. ']')
            return { ka = body, keyfield = keyfield }
        end
        local len
        for i = 1, n do
            if vals[i] ~= M.KV_ABSENT then
                if len and #vals[i].a ~= len then return hole('array', vals, path) end
                len = #vals[i].a
            end
        end
        local a = {}
        for j = 1, len do
            local sub = {}
            for i = 1, n do sub[i] = vals[i] == M.KV_ABSENT and M.KV_ABSENT or vals[i].a[j] end
            a[j] = gen(sub, path .. '[' .. j .. ']')
        end
        return { a = a }
    end
    local T = gen(instances, '$')
    local byid = {}
    for _, h in ipairs(holes) do byid[h.id] = h end
    local inst
    inst = function(t, i)
        if type(t) ~= 'table' then return t end
        if t.hole then return byid[t.hole].values[i] end
        if t.opt then
            local p = byid[t.opt.hole].values[i]
            if p ~= true then return M.KV_ABSENT end
            return inst(t.body, i)
        end
        if t.ka then
            local ob = inst(t.ka, i)
            if ob == M.KV_ABSENT then return M.KV_ABSENT end
            local a = {}
            for _, key in ipairs(ob.keys) do a[#a + 1] = ob.o[key] end
            return { a = a }
        end
        if t.a then
            local a = {}
            for j, x in ipairs(t.a) do a[j] = inst(x, i) end
            return { a = a }
        end
        if t.o then
            local o, keys = {}, {}
            for _, key in ipairs(t.keys) do
                local v = inst(t.o[key], i)
                if v ~= M.KV_ABSENT then o[key] = v; keys[#keys + 1] = key end
            end
            return { o = o, keys = keys }
        end
        return t
    end
    return { template = T, holes = holes, n = n, instantiate = function(i) return inst(T, i) end }
end

--- equality of JSON-like values where arrays of keyed objects compare as sets by key
function M.kv_eq_keyed(x, y, keyfield)
    keyfield = keyfield or 'name'
    local function norm(v)
        local k = kv_kind(v)
        if k == 'obj' then
            local o, keys = {}, {}
            for _, key in ipairs(v.keys) do o[key] = norm(v.o[key]); keys[#keys + 1] = key end
            return { o = o, keys = keys }
        elseif k == 'arr' then
            local keyed = #v.a > 0
            for _, e in ipairs(v.a) do if not (kv_kind(e) == 'obj' and e.o[keyfield] ~= nil) then keyed = false end end
            local a = {}
            for i, e in ipairs(v.a) do a[i] = norm(e) end
            if keyed then table.sort(a, function(p, q) return tostring(p.o[keyfield]) < tostring(q.o[keyfield]) end) end
            return { a = a }
        end
        return v
    end
    return kv_ser(norm(x)) == kv_ser(norm(y))
end

-- REDERIVE.md: with DERIVE=<op,op,..|all> in the environment, the named operators are
-- replaced by their re-derivations from the basis (derive.lua) so the suite can judge them
if os.getenv('DERIVE') then require('derive').apply_to(M, os.getenv('DERIVE')) end


-- ── PARTS ─────────────────────────────────────────────────────────────────
-- Sections extracted by cartograph's own move-set. Each part RECEIVES this
-- module table and writes onto it, so the surface does not depend on where a
-- definition lives. ⚠ NOT require + re-export: a part that reaches back (termgraph
-- calls M.show, vsym, lcs_alignments, slice) would need core at its top while
-- core needs it at its bottom — a load cycle.
-- ★ EVERY NAME HERE CAME FROM THE PLAN'S OWN CAPTURE HAZARDS, not from a crash.
local PARTS = { vsym = vsym, lcs_alignments = lcs_alignments, slice = slice,
    -- ⚠ BOTH VARIANTS, BY DISTINCT NAMES (CART-0924). `cat`/`is_prefix` are
    -- the definitions everything ABOVE the VERTICAL DIFFERENCES section was
    -- written against; `cat_flat`/`is_strict_prefix` are that section's own,
    -- which used to shadow them HERE — at the bottom of the file, where this
    -- table is built — and so were handed silently to every other part.
    cat = cat, cat_flat = cat_flat, is_prefix = is_prefix,
    is_strict_prefix = is_strict_prefix,
    is_hole = is_hole, child = child, key = key,
    lcp = lcp, lexlt = lexlt, prefix_eq = prefix_eq,
    RUNG_RANK = RUNG_RANK, family = family, family_of = family_of,
    derived = derived, subst = subst, unpack = unpack, at = at,
    set_at = set_at,
    distinct = distinct,
    occurrences = occurrences }
require('cartograph.algebra.hopau')(M, PARTS)
require('cartograph.algebra.termgraph')(M, PARTS)
require('cartograph.algebra.eau')(M, PARTS)
require('cartograph.algebra.materialize')(M, PARTS)
require('cartograph.algebra.tai')(M, PARTS)
require('cartograph.algebra.vertical')(M, PARTS)
require('cartograph.algebra.mdl')(M, PARTS)
require('cartograph.algebra.join')(M, PARTS)
require('cartograph.algebra.corr')(M, PARTS)
require('cartograph.algebra.domains')(M, PARTS)
require('cartograph.algebra.poslens')(M, PARTS)
require('cartograph.algebra.unify')(M, PARTS)
require('cartograph.algebra.abstract')(M, PARTS)
require('cartograph.algebra.summaries')(M, PARTS)
require('cartograph.algebra.migrate')(M, PARTS)
require('cartograph.algebra.classify')(M, PARTS)


return M
