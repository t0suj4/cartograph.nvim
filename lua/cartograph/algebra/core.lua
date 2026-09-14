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
local function derived(via) return { src = 'derived', via = { via } } end
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


-- restored from the CONSTRAINED MAPPINGS part, which took it while `vertical`
-- reached it through SHARED (CART-0925)
local function is_strict_prefix(p, q) -- p strict ancestor of q
    if #p >= #q then return false end
    for i = 1, #p do if p[i] ~= q[i] then return false end end
    return true
end

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
    occurrences = occurrences,
    hash = hash }
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
require('cartograph.algebra.validity')(M, PARTS)
require('cartograph.algebra.linkvalue')(M, PARTS)
require('cartograph.algebra.provenance')(M, PARTS)
require('cartograph.algebra.transplant')(M, PARTS)
require('cartograph.algebra.zhang')(M, PARTS)
require('cartograph.algebra.composition')(M, PARTS)
require('cartograph.algebra.match')(M, PARTS)
require('cartograph.algebra.negatives')(M, PARTS)
require('cartograph.algebra.demandfam')(M, PARTS)


return M
