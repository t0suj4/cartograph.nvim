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

-- ── domains ───────────────────────────────────────────────────────────────────
function M.open() return { kind = 'open' } end
function M.closed(v) return { kind = 'closed', value = v } end
function M.kinds(list)
    local set = {}
    for _, k in ipairs(list) do set[k] = true end
    return { kind = 'kinds', set = set }
end
function M.ref(name) return { kind = 'ref', name = name } end
function M.alt(...) return { kind = 'alt', alts = { ... } } end
function M.rep(of, min, max) return { kind = 'rep', of = of, min = min or 0, max = max } end
function M.both(a, b) return { kind = 'both', a = a, b = b } end
function M.context() return { kind = 'context' } end

function M.show_domain(D)
    if D.kind == 'open' then return '*' end
    if D.kind == 'closed' then return '=' .. M.show(D.value) end
    if D.kind == 'kinds' then
        local ks = {}
        for k in pairs(D.set) do ks[#ks + 1] = k end
        table.sort(ks)
        return '{' .. table.concat(ks, '|') .. '}'
    end
    if D.kind == 'ref' then return '@' .. D.name end
    if D.kind == 'alt' then
        local ps = {}
        for i, a in ipairs(D.alts) do ps[i] = M.show_domain(a) end
        return '(' .. table.concat(ps, ' | ') .. ')'
    end
    if D.kind == 'rep' then return M.show_domain(D.of) .. '{' .. D.min .. ',' .. (D.max or '') .. '}' end
    if D.kind == 'both' then return M.show_domain(D.a) .. ' & ' .. M.show_domain(D.b) end
    if D.kind == 'context' then return '◦-context' end
    return '?'
end

--- does value v satisfy domain D?  env = { defs = {name -> template}, self = template }
function M.admits(D, v, env)
    env = env or {}
    if D.kind == 'open' then return true end
    if D.kind == 'closed' then
        if M.eq(D.value, v) then return true end
        return false, 'pinned to ' .. M.show(D.value) .. ', got ' .. M.show(v)
    end
    if D.kind == 'kinds' then
        if D.set[v.k] then return true end
        return false, 'kind ' .. tostring(v.k) .. ' not in ' .. M.show_domain(D)
    end
    if D.kind == 'ref' then
        local T = D.name == 'self' and env.self or (env.defs or {})[D.name]
        if not T then return false, 'unresolved @' .. D.name end
        local m = M.match(T, v, { defs = env.defs, self = D.name == 'self' and env.self or T })
        if m.ok then return true end
        return false, '@' .. D.name .. ' refused: ' .. m.refusal.why
    end
    if D.kind == 'alt' then
        local whys = {}
        for _, a in ipairs(D.alts) do
            local ok, why = M.admits(a, v, env)
            if ok then return true end
            whys[#whys + 1] = why
        end
        return false, 'no alternative: ' .. table.concat(whys, '; ')
    end
    if D.kind == 'rep' then
        if v.k ~= 'seq' then return false, 'a repetition binds a seq, got ' .. tostring(v.k) end
        local n = #v.kids
        if n < D.min or (D.max and n > D.max) then
            return false, ('count %d outside {%d,%s}'):format(n, D.min, tostring(D.max or ''))
        end
        for i, e in ipairs(v.kids) do
            local ok, why = M.admits(D.of, e, env)
            if not ok then return false, ('element %d: %s'):format(i, why) end
        end
        return true
    end
    if D.kind == 'both' then
        local ok, why = M.admits(D.a, v, env)
        if not ok then return false, why end
        return M.admits(D.b, v, env)
    end
    if D.kind == 'context' then
        local n = 0
        local function count(t)
            if t.k == 'cursor' then n = n + 1 end
            for _, c in ipairs(t.kids or {}) do count(c) end
        end
        if v.k ~= 'seq' then return false, 'a context is a seq with one cursor, got ' .. tostring(v.k) end
        count(v)
        if n == 1 then return true end
        return false, ('a context has exactly one cursor, this has %d'):format(n)
    end
    return false, 'unknown domain ' .. tostring(D.kind)
end

--- intersection of two domains, simplified where the answer is syntactic
function M.meet(A, B, env)
    if A.kind == 'open' then return B end
    if B.kind == 'open' then return A end
    -- a pin is a point: it survives only if the other side admits it; otherwise the conjunction,
    -- which admits nothing (UNIFY.md found the old "return the pin" unsound in merge)
    if A.kind == 'closed' or B.kind == 'closed' then
        local P, O = A.kind == 'closed' and A or B, A.kind == 'closed' and B or A
        if O.kind == 'closed' then return M.eq(P.value, O.value) and P or M.both(A, B) end
        if M.admits(O, P.value, env) then return P end
        return M.both(A, B)
    end
    if A.kind == 'kinds' and B.kind == 'kinds' then
        local out = {}
        for k in pairs(A.set) do if B.set[k] then out[#out + 1] = k end end
        return M.kinds(out)
    end
    return M.both(A, B)
end

--- A entails B (every value of A is a value of B) — syntactic, partial
function M.entails(A, B, env)
    if B.kind == 'open' then return true end
    if A.kind == 'open' then return false end
    if A.kind == 'closed' then return (M.admits(B, A.value, env)) end
    if A.kind == 'kinds' and B.kind == 'kinds' then
        for k in pairs(A.set) do if not B.set[k] then return false end end
        return true
    end
    if A.kind == 'alt' then
        for _, a in ipairs(A.alts) do if not M.entails(a, B, env) then return false end end
        return true
    end
    if B.kind == 'alt' then
        for _, b in ipairs(B.alts) do if M.entails(A, b, env) then return true end end
    end
    if A.kind == B.kind and A.kind == 'ref' then return A.name == B.name end
    -- the meet's domains (UNIFY.md): every value of a&b is a value of a and of b
    if B.kind == 'both' then return M.entails(A, B.a, env) and M.entails(A, B.b, env) end
    if A.kind == 'both' then return M.entails(A.a, B, env) or M.entails(A.b, B, env) end
    return false
end

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

-- ── the position lens: the basis operators the re-derivation pass (REDERIVE.md) builds on ──
--- read the subterm at a path (nil when the path leaves the term)
function M.locate_at(t, path) return at(t, path) end
--- a PURE put: the term with `sub` at `path`, rebuilt along the way (set_at mutates)
function M.put(t, path, sub, i)
    i = i or 1
    if i > #path then return sub end
    local kids = {}
    for j, c in ipairs(t.kids or {}) do kids[j] = (j == path[i]) and M.put(c, path, sub, i + 1) or c end
    return M.rebuild(t, kids)
end
--- every position of a term in preorder, with its subterm: { {path, node}, .. }
function M.positions(t)
    local out = {}
    local function walk(x, path)
        out[#out + 1] = { path = path, node = x }
        for i, c in ipairs(x.kids or {}) do walk(c, child(path, i)) end
    end
    walk(t, {})
    return out
end

--- H: every hole's sites and domain, read off the body
function M.sites(T)
    local H = {}
    local through = {} -- grammar boundaries on the way down: { {path, g}, .. }
    local function walk(t, path)
        if is_hole(t) then
            local e = H[t.h]
            if not e then
                e = { sites = {}, domain = (T.holes and T.holes[t.h] and T.holes[t.h].domain) or M.open(),
                    origin = (T.holes and T.holes[t.h] and T.holes[t.h].origin) or 'derived',
                    was = T.holes and T.holes[t.h] and T.holes[t.h].was or nil,
                    rep = t.rep or false }
                H[t.h] = e
            end
            local site = { path = path }
            if #through > 0 then site.through = M.copy(through) end -- H carries the boundaries, so the third leg can cross them
            e.sites[#e.sites + 1] = site
            e.ctx = t.ctx or false
            if t.ctx then for i, c in ipairs(t.kids or {}) do walk(c, child(path, i)) end end
            return
        end
        if t.k == 'embed' then
            through[#through + 1] = { path = path, g = t.g }
            walk(t.kids[1], child(path, 1))
            through[#through] = nil
            return
        end
        for i, c in ipairs(t.kids or {}) do walk(c, child(path, i)) end
    end
    walk(T.body, {})
    return H
end

function M.hole_names(T)
    local names = {}
    for h in pairs(M.sites(T)) do names[#names + 1] = h end
    table.sort(names)
    return names
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

--- the subterm of I at a site path, parsing each grammar boundary the path crosses;
--- returns the term reached and, for the last segment, its parent and index
local function at_through(I, path, through)
    local cur, consumed = I, 0
    for _, b in ipairs(through or {}) do
        local sub = at(cur, { unpack(path, consumed + 1, #b.path) })
        if sub == nil then return nil end
        if sub.k == 'embed' then cur = sub.kids[1] -- already a boundary node (abstract in progress)
        else
            if sub.k ~= 'lit' or type(sub.v) ~= 'string' then return nil end
            cur = M.grammars[b.g].parse(sub.v)
            if not cur then return nil end
        end
        consumed = #b.path + 1 -- past the embed node and its single kid index
    end
    local rest = { unpack(path, consumed + 1) }
    return at(cur, rest), cur, rest
end

--- read each hole's value off I at its sites (first site; the others must agree)
function M.values_at(I, H)
    local V, conflicts = {}, {}
    for h, e in pairs(H) do
        for _, s in ipairs(e.sites) do
            local v
            if e.ctx then
                -- cut the context out: the slice with the sub-slice at the cursor replaced by ◦ (CTXCUT.md)
                if not s.cursor then error('values_at: a context site (hole ' .. h .. ') needs a cursor record; H from sites(T) has none, H from match does') end
                local parent = at(I, { unpack(s.path, 1, #s.path - 1) })
                local start, n = s.path[#s.path], s.n or 0
                local slice = {}
                for j = start, start + n - 1 do slice[#slice + 1] = parent.kids[j] end
                v = M.with_cursor(slice, s.cursor.path, s.cursor.from, s.cursor.from + s.cursor.n - 1)
            elseif e.rep then
                local _, root, rest = at_through(I, s.path, s.through)
                local parent = at(root, { unpack(rest, 1, #rest - 1) })
                local start, n = rest[#rest], s.n or 0
                local kids = {}
                for j = start, start + n - 1 do kids[#kids + 1] = M.copy(parent.kids[j]) end
                v = M.seq(kids)
            else
                v = M.copy(at_through(I, s.path, s.through))
            end
            if V[h] == nil then V[h] = v
            elseif not M.eq(V[h], v) then conflicts[#conflicts + 1] = h end
        end
    end
    return V, conflicts
end

--- the template whose holes sit at H's sites in I
local function later_first(a, b)
    -- deeper / later sites first, so indices of untouched siblings stay valid; at one path,
    -- the later-bound site first (ids from match), else the positive-width one
    if #a.path ~= #b.path then return #a.path > #b.path end
    for i = 1, #a.path do
        if a.path[i] ~= b.path[i] then return a.path[i] > b.path[i] end
    end
    if a.id and b.id then return a.id > b.id end
    return (a.n or 1) > (b.n or 1)
end
function M.abstract(I, H)
    local entries = {}
    for h, e in pairs(H) do
        for _, s in ipairs(e.sites) do
            if e.ctx and not s.cursor then error('abstract: a context site (hole ' .. h .. ') needs a cursor record; H from sites(T) has none, H from match does') end
            entries[#entries + 1] = { h = h, path = s.path, n = s.n, rep = e.rep, ctx = e.ctx or nil, cursor = s.cursor,
                through = s.through, id = s.id, within = s.within }
        end
    end
    -- the sites matched inside a context site's applied hedge, transitively (nested contexts)
    local function inside(e, pool)
        if not e.id then return {} end -- a hand-built site: nothing was matched inside it
        local ids, out, grew = { [e.id] = true }, {}, true
        while grew do
            grew = false
            for _, x in ipairs(pool) do if x.within and ids[x.within] and not ids[x.id] then ids[x.id] = true; grew = true end end
        end
        for _, x in ipairs(pool) do if x.id ~= e.id and ids[x.id] then out[#out + 1] = x end end
        return out
    end
    -- CONTEXT SITES (CTXCUT.md): cut the sub-slice at the cursor out of the ORIGINAL level, rebase
    -- the sites inside it onto that hedge, abstract the hedge recursively, and put one context hole
    -- node holding the result where the slice was. Recursing on original coordinates means a
    -- repetition hole or a nested context inside the applied hedge never shifts the cut.
    local build
    local function cut(orig, e, pool)
        local P = { unpack(e.path, 1, #e.path - 1) }
        local ii, p, from, cn = e.path[#e.path], e.cursor.path, e.cursor.from, e.cursor.n
        -- the cursor list: at the top level it is the slice itself (cursor.from counts from the
        -- slice's first element), deeper it is the kids of the node reached by p inside the slice
        local Lparent, fstart = P, ii + from - 1
        if #p > 0 then
            Lparent = { unpack(P) }
            Lparent[#Lparent + 1] = ii + p[1] - 1
            for i = 2, #p do Lparent[#Lparent + 1] = p[i] end
            fstart = from
        end
        local L = at(orig, Lparent)
        local kids = {}
        for j = fstart, fstart + cn - 1 do kids[#kids + 1] = M.copy(L.kids[j]) end
        local sub = M.seq(kids)
        local rebased = {}
        for _, x in ipairs(inside(e, pool)) do
            local q = { unpack(x.path, #Lparent + 1) }
            q[1] = q[1] - fstart + 1
            local y = {}
            for k2, v in pairs(x) do y[k2] = v end
            y.path = q
            rebased[#rebased + 1] = y
        end
        local hedge = build(sub, e.id, rebased)
        return { k = 'hole', h = e.h, ctx = true, kids = hedge.kids }
    end
    build = function(orig, enc, pool)
        local body = M.copy(orig)
        local plan = {}
        for _, x in ipairs(pool) do if x.within == enc then plan[#plan + 1] = x end end
        table.sort(plan, later_first)
        for _, p in ipairs(plan) do
            if p.ctx then
                local node = cut(orig, p, pool)
                local parent = at(body, { unpack(p.path, 1, #p.path - 1) })
                local start, n = p.path[#p.path], p.n or 0
                local kids = {}
                for j = 1, start - 1 do kids[#kids + 1] = parent.kids[j] end
                kids[#kids + 1] = node
                for j = start + n, #parent.kids do kids[#kids + 1] = parent.kids[j] end
                parent.kids = kids
            elseif p.through then
                -- a site behind grammar boundaries: parse each string into an embed node first (once),
                -- then place the hole inside the parsed term
                local root, rest = body, p.path
                local consumed = 0
                for _, b in ipairs(p.through) do
                    local epath = { unpack(p.path, consumed + 1, #b.path) }
                    local sub = at(root, epath)
                    if sub.k ~= 'embed' then
                        local parsed = M.grammars[b.g].parse(sub.v)
                        local e = { k = 'embed', g = b.g, kids = { parsed } }
                        root = set_at(root, epath, e)
                        sub = e
                    end
                    root = sub.kids[1] -- descend into the parsed term; edits below mutate it in place
                    consumed = #b.path + 1
                    rest = { unpack(p.path, consumed + 1) }
                    if #rest == 0 then error('abstract: a hole cannot replace a whole boundary') end
                end
                if p.rep then
                    local parent = at(root, { unpack(rest, 1, #rest - 1) })
                    local start, n = rest[#rest], p.n or 0
                    local kids = {}
                    for j = 1, start - 1 do kids[#kids + 1] = parent.kids[j] end
                    kids[#kids + 1] = M.hole(p.h, true)
                    for j = start + n, #parent.kids do kids[#kids + 1] = parent.kids[j] end
                    parent.kids = kids
                else
                    set_at(root, rest, M.hole(p.h))
                end
            elseif p.rep then
                local parent = at(body, { unpack(p.path, 1, #p.path - 1) })
                local start, n = p.path[#p.path], p.n or 0
                local kids = {}
                for j = 1, start - 1 do kids[#kids + 1] = parent.kids[j] end
                kids[#kids + 1] = M.hole(p.h, true)
                for j = start + n, #parent.kids do kids[#kids + 1] = parent.kids[j] end
                parent.kids = kids
            else
                body = set_at(body, p.path, M.hole(p.h))
            end
        end
        return body
    end
    local body = build(I, nil, entries)
    local domains = {}
    for h, e in pairs(H) do domains[h] = { domain = e.domain, origin = e.origin or 'derived', was = e.was } end
    return M.template(body, domains)
end

--- where in I could V's values sit? The answer is a SET per hole — sites are not derivable
--- from (I, V) when a value occurs more than once or two holes carry equal values.
function M.locate(I, V)
    local cands, ambiguous = {}, false
    for h, v in pairs(V) do
        cands[h] = {}
        local function walk(t, path)
            if M.eq(t, v) then cands[h][#cands[h] + 1] = key(path) end
            for i, c in ipairs(t.kids or {}) do walk(c, child(path, i)) end
        end
        walk(I, {})
        if #cands[h] ~= 1 then ambiguous = true end
    end
    return cands, ambiguous
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

--- replay one recorded edit on the template it was recorded against
function M.replay_edit(T, op)
    if op.op == 'pin' then return M.pin(T, op.h, op.value)
    elseif op.op == 'open' then return M.open_hole(T, op.h)
    elseif op.op == 'dig' then return M.dig(T, op.path, op.h, op.domain)
    elseif op.op == 'merge' then return M.merge(T, op.h, op.into)
    elseif op.op == 'split' then return M.split(T, op.h, op.site, op.new)
    elseif op.op == 'rewrite' then return M.rewrite(T, op.path, op.sub)
    elseif op.op == 'join' then
        local r, why = M.join(T, op.with)
        return r and r.template, why
    end
    return nil, 'unknown edit ' .. tostring(op.op)
end

--- one member across one edit. T is the template BEFORE `op`, T2 the one after.
--- Returns V' or nil, why.
function M.migrate_one(T, T2, op, V, env)
    local W = {}
    for k, v in pairs(V) do W[k] = v end
    if op.op == 'pin' then
        if not M.eq(V[op.h], op.value) then return nil, 'pin ' .. op.h .. ': value differs' end
    elseif op.op == 'dig' then
        local unfilled = {}
        W[op.h] = subst(at(T.body, op.path), V, unfilled)
        if next(unfilled) then return nil, 'dig ' .. op.h .. ': member lacks a value under the dug subtree' end
    elseif op.op == 'merge' then
        if not M.eq(V[op.h], V[op.into]) then
            return nil, 'merge ' .. op.h .. '/' .. op.into .. ': values differ'
        end
        W[op.into] = nil
    elseif op.op == 'split' then
        W[op.new] = M.copy(V[op.h])
    elseif op.op == 'rewrite' then
        -- the fixed part changed and the hole set did not (rewrite refuses to discard):
        -- values are carried unchanged and every member's instance moves by the same
        -- fixed delta. This is the one edit whose purpose is to change the instances.
    elseif op.op == 'join' then
        -- the template moved up to admit a newcomer; this member's values follow by the
        -- join's own left map (kept by name, split copied, swallowed fragments rendered)
        local r, why = M.join(T, op.with)
        if not r then return nil, 'join: ' .. why end
        local W2, err = r.left(V)
        if not W2 then return nil, 'join: ' .. err end
        W = W2
    end
    local H = M.sites(T2)
    for h in pairs(W) do if not H[h] then W[h] = nil end end -- swallowed by a dig
    local r = M.instantiate(T2, W, env)
    if not r.ok then
        local why = {}
        if #r.rejected > 0 then why[#why + 1] = 'domain refuses ' .. table.concat(r.rejected, '; ') end
        if #r.unfilled > 0 then why[#why + 1] = 'no value for ' .. table.concat(r.unfilled, ', ') end
        if #r.extra > 0 then why[#why + 1] = 'value without a site ' .. table.concat(r.extra, ', ') end
        return nil, op.op .. ' ' .. op.h .. ': ' .. table.concat(why, '; ')
    end
    return W
end

--- the family follows T0 to T1 along the edits T1 recorded beyond T0's.
--- Returns { template, values = {[i]=V'}, kept = {i..}, dropped = {{i, edit, op, why}..} }.
function M.migrate(T0, T1, Vs, env, Ps)
    local T = T0
    local cur, alive, dropped, prov = {}, {}, {}, {}
    for i, V in ipairs(Vs) do cur[i], alive[i] = V, true end
    for k = #T0.edits + 1, #T1.edits do
        local op = T1.edits[k]
        local T2, err = M.replay_edit(T, op)
        if not T2 then return nil, 'edit ' .. k .. ': ' .. err end
        for i = 1, #Vs do
            if alive[i] then
                local W, why = M.migrate_one(T, T2, op, cur[i], env)
                if W then
                    if Ps and Ps[i] then prov[i] = M.migrate_provenance(op, cur[i], W, prov[i] or Ps[i]) end
                    cur[i] = W
                else
                    alive[i] = false
                    dropped[#dropped + 1] = { i = i, edit = k, op = op.op, why = why }
                end
            end
        end
        T = T2
    end
    if not M.eq(T.body, T1.body) then return nil, 'T1 is not T0 plus its recorded edits' end
    local kept, values, stamped, provenance = {}, {}, {}, {}
    for i = 1, #Vs do
        if alive[i] then
            kept[#kept + 1] = i; values[i] = cur[i]
            if Ps and Ps[i] then provenance[i] = prov[i] or Ps[i] end
        end
    end
    -- derived domains follow the column: a dig without a domain gets its summary here, and a
    -- pin-then-open returns to the column's sort rather than to the old record
    T = M.rederive_domains(M.copy(T), values)
    for i = 1, #Vs do if alive[i] then stamped[i] = M.stamp(T, cur[i]) end end -- valid for T1 at its edit position
    return { template = T, values = values, kept = kept, dropped = dropped, stamped = stamped, provenance = provenance }
end

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
local function occurrences(t, v, path, out)
    if is_hole(t) then return end
    if M.eq(t, v) then out[#out + 1] = path; return end
    for i, c in ipairs(t.kids or {}) do occurrences(c, v, child(path, i), out) end
end
local function cat(p, q) local r = { unpack(p) }; for _, x in ipairs(q) do r[#r + 1] = x end; return r end

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
    local used, leftcount, memo, frags, order, counter, absorbed = {}, {}, {}, {}, {}, 0, {}
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
    local function rep_at(kids) -- the index of the one hedge hole; false when none; 'many' when several
        local at
        for i, c in ipairs(kids) do if is_hole(c) and c.rep then if at then return 'many' end; at = i end end
        return at or false
    end
    -- ── hedge alignment (HEDGEJOIN.md). Two cases, both unitary:
    -- FORCED: a list holding exactly one hedge hole fixes p positions before it and s after;
    --   they align positionally, the hole absorbs the other side's middle (what match does).
    -- ENDS: no hedge hole and unequal lengths: the identical prefix and suffix (generalize's
    --   rule, M.eq per position), the middle becomes one hedge hole.
    -- Several hedge holes in one list are not aligned by guessing: the node becomes a hole.
    local function lgg_hedge(ak, bk, parent)
        local ra, rb = rep_at(ak), rep_at(bk)
        if ra == 'many' or rb == 'many' then return nil end
        if opts.align == 'none' and #ak ~= #bk then return nil end -- the fixed-arity lgg: no hedge holes
        local function elementwise(pa, pb, n, out)
            for i = 1, n do out[#out + 1] = lgg(ak[pa + i], bk[pb + i], parent) end
        end
        local p, sa, sb
        if ra and rb then
            if ra ~= rb or #ak - ra ~= #bk - rb then ra, rb = false, false end -- shapes disagree: ENDS
        end
        if ra or rb then
            p = (ra or rb) - 1
            local s = ra and (#ak - ra) or (#bk - rb)
            local other = ra and #bk or #ak
            if other < p + s then ra, rb = false, false -- no room for the fixed parts: ENDS
            else
                local out = {}
                elementwise(0, 0, p, out)
                local la = ra and ak[ra] or slice(ak, p + 1, #ak - s)
                local lb = rb and bk[rb] or slice(bk, p + 1, #bk - s)
                out[#out + 1] = fresh(la, lb, true)
                elementwise(#ak - s, #bk - s, s, out)
                return out
            end
        end
        if #ak == #bk then local out = {}; elementwise(0, 0, #ak, out); return out end
        local minlen = math.min(#ak, #bk)
        local pre = 0
        while pre < minlen and M.eq(ak[pre + 1], bk[pre + 1]) do pre = pre + 1 end
        local suf = 0
        while suf < minlen - pre and M.eq(ak[#ak - suf], bk[#bk - suf]) do suf = suf + 1 end
        local out = {}
        elementwise(0, 0, pre, out)
        out[#out + 1] = fresh(slice(ak, pre + 1, #ak - suf), slice(bk, pre + 1, #bk - suf), true)
        elementwise(#ak - suf, #bk - suf, suf, out)
        return out
    end
    -- the keyed-table fragment (survey §3.2): fields align by key, the rest is one hedge hole
    local function table_join(a, b, keyed)
        local kids, common, extra = {}, {}, false
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
    lgg = function(a, b, parent)
        if is_hole(a) or is_hole(b) then return fresh(a, b) end
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
            for _, n in ipairs(order) do W[n] = subst(frags[n][side], V, unfilled) end
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
        kept = kept, split = split, widened = widened, overrode = overrode, new = new, absorbed = absorbed, frags = frags }
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

local function all_paths(t, path, f) -- every position under t, with its subterm
    f(path, t)
    for i, c in ipairs(t.kids or {}) do all_paths(c, child(path, i), f) end
end

--- instantiate with attribution. Returns { ok, term, origins = { [key(p)] = origin } }.
function M.trace(T, V, env, stage)
    stage = stage or 1
    local r = M.instantiate(T, V, env)
    if not r.ok then return r end
    for h, e in pairs(M.sites(T)) do if e.ctx then return { ok = false, why = 'context hole ' .. h .. ' unsupported' } end end
    local origins = {}
    local function attribute_value(out_path, h, v, base)
        all_paths(v, {}, function(q, _)
            origins[key(cat(out_path, q))] = { src = 'hole', stage = stage, hole = h, at = cat(base, q) }
        end)
    end
    local function build(t, tpath, out_path)
        if is_hole(t) then -- a point hole: the whole value lands here
            attribute_value(out_path, t.h, V[t.h], {})
            return M.copy(V[t.h])
        end
        if t.k == 'embed' then -- the string is one output position; its inside is a nested correspondence
            local Ti, Vi = M.inner_template(T, t), {}
            for h in pairs(Ti.holes) do Vi[h] = V[h] end
            local inner = M.trace(Ti, Vi, env, stage)
            local text, spans = M.grammars[t.g].print(inner.term)
            origins[key(out_path)] = { src = 'embed', stage = stage, g = t.g, at = tpath,
                text = text, spans = spans, origins = inner.origins }
            return M.lit(text)
        end
        origins[key(out_path)] = { src = 'fixed', stage = stage, at = tpath }
        if not t.kids then return M.copy(t) end
        local kids, n = {}, 0
        for i, c in ipairs(t.kids) do
            if is_hole(c) and c.rep then -- a repetition hole splices its sequence in
                for j, e in ipairs(V[c.h].kids or {}) do
                    n = n + 1
                    attribute_value(child(out_path, n), c.h, e, { j })
                    kids[n] = M.copy(e)
                end
            else
                n = n + 1
                kids[n] = build(c, child(tpath, i), child(out_path, n))
            end
        end
        return M.rebuild(t, kids)
    end
    local term = build(T.body, {}, {})
    return { ok = true, term = term, origins = origins }
end

--- compose: c2's output positions traced through c2 into the previous output where a hole
--- was TAKEN (taken[h] = path in the previous output the hole's value was read from), then
--- through c1. Origins that stop earlier keep their stage. `via` records the path the
--- position had in each intermediate output, newest first.
function M.corr_compose(c2, c1, taken)
    local out = {}
    for k, o in pairs(c2) do
        if o.src == 'hole' and taken[o.hole] then
            local pos = cat(taken[o.hole], o.at)
            local o1 = c1[key(pos)]
            if o1 then
                -- newest first: hops already recorded on o, then this hop, then c1's
                local via = {}
                for _, v in ipairs(o.via or {}) do via[#via + 1] = v end
                via[#via + 1] = { stage = o.stage, at = pos }
                for _, v in ipairs(o1.via or {}) do via[#via + 1] = v end
                out[k] = { src = o1.src, stage = o1.stage, hole = o1.hole, at = o1.at, via = via }
            else
                out[k] = o
            end
        else
            out[k] = o
        end
    end
    return out
end

--- a pipeline: stages { {template, values, taken = { [h] = path in previous output }}, .. }.
--- Every taken hole's value is READ off the previous output, so stage k+1 needs only its
--- external values. Returns { ok, term, outputs, origins, origin(p), impact(k, q) }.
function M.pipeline(stages, env)
    local outputs, corrs, prev = {}, {}, nil
    for k, st in ipairs(stages) do
        local V = {}
        for h, v in pairs(st.values or {}) do V[h] = v end
        for h, q in pairs(st.taken or {}) do
            if not prev then return { ok = false, why = 'stage 1 cannot take' } end
            local v = at(prev, q)
            if v == nil then return { ok = false, why = ('stage %d: nothing at %s to take for %s'):format(k, key(q), h) } end
            V[h] = v
        end
        local r = M.trace(st.template, V, env, k)
        if not r.ok then return { ok = false, why = 'stage ' .. k .. ' refused', detail = r } end
        outputs[k], corrs[k], prev = r.term, r.origins, r.term
    end
    local composed = corrs[#stages]
    for k = #stages - 1, 1, -1 do composed = M.corr_compose(composed, corrs[k], stages[k + 1].taken or {}) end
    local P = { ok = true, term = prev, outputs = outputs, corrs = corrs, origins = composed }
    function P.origin(p) return composed[key(p)] end
    --- every final position whose chain passes through position q of stage k's OUTPUT
    --- (for external inputs of a stage see `uses`; at the final stage it is q itself)
    function P.impact(k, q)
        local qk, hits = key(q), {}
        for pk, o in pairs(composed) do
            local pass = false
            for _, v in ipairs(o.via or {}) do if v.stage == k + 1 and key(v.at) == qk then pass = true end end
            if not pass and k == #stages and pk == qk then pass = true end
            if pass then hits[#hits + 1] = pk end
        end
        table.sort(hits)
        return hits
    end
    --- every final position that came from external input `hole` of stage k
    function P.uses(k, hole)
        local hits = {}
        for pk, o in pairs(composed) do
            if o.src == 'hole' and o.stage == k and o.hole == hole then hits[#hits + 1] = pk end
        end
        table.sort(hits)
        return hits
    end
    return P
end

--- the text stage: show() with a span per position, so a cursor offset maps to a path and
--- from there through the pipeline. Serialization is a derivation with a correspondence.
function M.render(t)
    local buf, spans = {}, {}
    local off = 0
    local function emit(s) buf[#buf + 1] = s; off = off + #s end
    local function go(x, path)
        local from = off
        if x.k == 'lit' or x.k == 'name' or is_hole(x) then
            emit(M.show(x))
        else
            emit('(' .. x.k)
            for i, c in ipairs(x.kids or {}) do emit(' '); go(c, child(path, i)) end
            emit(')')
        end
        spans[#spans + 1] = { path = path, from = from, to = off }
    end
    go(t, {})
    return { text = table.concat(buf), spans = spans }
end

--- the innermost span containing a 0-based offset, or nil
function M.at_offset(R, off)
    local best
    for _, s in ipairs(R.spans) do
        if off >= s.from and off < s.to and (not best or (s.to - s.from) < (best.to - best.from)) then best = s end
    end
    return best and best.path
end

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

function M.dl(t, cost) return (cost or M.size)(t) end

--- description length of one family: its template once, its values per member
function M.family_dl(T, Vs, opts)
    opts = opts or {}
    local cost, fam = opts.cost or M.size, opts.family_cost or 1
    local tdl, vdl = cost(T.body), 0
    for _, V in pairs(Vs) do for _, v in pairs(V) do vdl = vdl + cost(v) end end
    return tdl + fam + vdl, { template = tdl, values = vdl, family = fam }
end

function M.partition_dl(families, opts)
    local total = 0
    for _, f in ipairs(families) do total = total + M.family_dl(f.template, f.values, opts) end
    return total
end

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

--- greedy agglomerative partition by description length
function M.partition(instances, opts)
    opts = opts or {}
    local fams, steps = {}, {}
    for i = 1, #instances do fams[i] = family_of(instances, { i }, opts) end
    local singletons_dl = M.partition_dl(fams, opts)
    local all = {}
    for i = 1, #instances do all[i] = i end
    local one = family_of(instances, all, opts)
    while #fams > 1 do
        local best
        for a = 1, #fams do
            for b = a + 1, #fams do
                local members = {}
                for _, i in ipairs(fams[a].members) do members[#members + 1] = i end
                for _, i in ipairs(fams[b].members) do members[#members + 1] = i end
                table.sort(members)
                local merged = family_of(instances, members, opts)
                local gain = fams[a].dl + fams[b].dl - merged.dl
                if merged.admissible and gain > 0 and (not best or gain > best.gain) then
                    best = { a = a, b = b, merged = merged, gain = gain }
                end
            end
        end
        if not best then break end
        steps[#steps + 1] = { merged = best.merged.members, gain = best.gain }
        local nf = {}
        for k, f in ipairs(fams) do if k ~= best.a and k ~= best.b then nf[#nf + 1] = f end end
        nf[#nf + 1] = best.merged
        fams = nf
    end
    -- greedy can stop at a local optimum above the one-family partition (seed 26 of the
    -- spec's law did, before admissibility); the trivial candidate is always compared
    local dl = M.partition_dl(fams, opts)
    if one.admissible and one.dl < dl then
        steps[#steps + 1] = { merged = all, gain = dl - one.dl, why = 'one family beats the greedy result' }
        fams, dl = { one }, one.dl
    end
    table.sort(fams, function(x, y) return x.members[1] < y.members[1] end)
    return { families = fams, dl = dl, steps = steps,
        singletons_dl = singletons_dl, one_family_dl = one.dl, one_family_admissible = one.admissible }
end

--- the optimum over every set partition (n ≤ 8), for measuring greedy
function M.partition_all(instances, opts)
    opts = opts or {}
    local n = #instances
    assert(n <= 8, 'partition_all: too many instances')
    local memo = {}
    local function block(members)
        local k = table.concat(members, ',')
        if not memo[k] then memo[k] = family_of(instances, members, opts) end
        return memo[k]
    end
    local best, count = nil, 0
    local rgs = {}
    local function rec(i, m) -- restricted growth strings enumerate set partitions once each
        if i > n then
            count = count + 1
            local blocks = {}
            for j = 1, n do blocks[rgs[j]] = blocks[rgs[j]] or {}; table.insert(blocks[rgs[j]], j) end
            local fams, dl, ok = {}, 0, true
            for _, b in ipairs(blocks) do local f = block(b); fams[#fams + 1] = f; dl = dl + f.dl; ok = ok and f.admissible end
            if ok and (not best or dl < best.dl) then best = { families = fams, dl = dl } end
            return
        end
        for v = 1, m + 1 do rgs[i] = v; rec(i + 1, math.max(m, v)) end
    end
    rec(1, 0)
    best.partitions = count
    return best
end

--- price an operator's split (propagate.commit): one family versus the two it produces
function M.dl_delta(T, Vs, T2, committed, opts)
    local set, yes, no = {}, {}, {}
    for _, i in ipairs(committed) do set[i] = true end
    local r = assert(M.migrate(T, T2, Vs))
    for i, V in pairs(Vs) do if set[i] then yes[i] = r.values[i] or V else no[i] = V end end
    local one = M.family_dl(T, Vs, opts)
    local two = M.family_dl(T2, yes, opts) + (next(no) and M.family_dl(T, no, opts) or 0)
    return { one = one, two = two, delta = two - one }
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
    if D.kind == 'rep' then return M.rep(M.relax(D.of), D.min, D.max) end
    return M.copy(D) -- open, kinds, and the structural claims (ref, both) stay
end

local function occurs(h, t)
    if is_hole(t) then return t.h == h end
    for _, c in ipairs(t.kids or {}) do if occurs(h, c) then return true end end
    return false
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
        local of, why = meet_domains(A.of, B.of)
        if not of then return nil, why end
        local min, max = math.max(A.min, B.min), (A.max and B.max) and math.min(A.max, B.max) or A.max or B.max
        if max and min > max then return nil, ('repetition counts disjoint: {%d,%s} and {%d,%s}'):format(A.min, tostring(A.max or ''), B.min, tostring(B.max or '')) end
        return M.rep(of, min, max)
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
local function cat(...)
    local out = {}
    for _, l in ipairs { ... } do for _, x in ipairs(l) do out[#out + 1] = x end end
    return out
end
local function is_prefix(p, q) -- p strict ancestor of q
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
                if is_prefix(a.I, b.I) ~= is_prefix(a.J, b.J) then return false, 'ancestor' end
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
                    if is_prefix(nI, pairs[k].I) ~= is_prefix(nJ, pairs[k].J) then return false, 'nca' end
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

-- ── THE TAI MAPPING HIERARCHY (Lu, Su, Tang 2001, as corrected by Kuboyama 2007) ──────
-- Source: Kuboyama, "Matching and Learning in Trees", PhD thesis, U. Tokyo 2007, §2.8.6
-- and §§4.4–4.6. The LST01 paper is paywalled and was not read; the thesis quotes its
-- definition (Def. 2.70) and proves it collapses to Zhang's constraint (Prop. 4.7), then
-- gives the corrected definition (Def. 4.8) and proves it equals alignability (Thm 4.19).
-- CONVENTION: the thesis writes x < y for "x is a proper DESCENDANT of y" (the root is the
-- maximum) and x‘y for the lca. On position paths, lca = longest common prefix and
-- "x below y" = y is a strict prefix of x. The empty path is the hedge's virtual root.
local function lca(p, q) return lcp(p, q) end
local function below(x, y) return is_prefix(y, x) end -- x proper descendant of y
local function same(p, q) return key(p) == key(q) end
local function no_ancestors(a, b, c)
    return not (prefix_eq(a, b) or prefix_eq(b, a) or prefix_eq(a, c) or prefix_eq(c, a)
        or prefix_eq(b, c) or prefix_eq(c, b))
end
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
        for _, q in ipairs(pairs) do if q ~= p and is_prefix(p.I, q.I) then leaf = false; break end end
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
    cat = cat, is_hole = is_hole, child = child, key = key }
require('cartograph.algebra.hopau')(M, PARTS)
require('cartograph.algebra.termgraph')(M, PARTS)
require('cartograph.algebra.eau')(M, PARTS)
require('cartograph.algebra.materialize')(M, PARTS)


return M
