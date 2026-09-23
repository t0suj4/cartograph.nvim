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
--                                   recursion proposed only when the evidence reaches 3;
--                                   a repetition's unit is the lgg of one period's chunks (REPETITION.md)
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

-- ── keyed alignment (KEYED.md) ────────────────────────────────────────────────
-- A node may DECLARE how its children align: `align = 'keyed'` (the key is the identity,
-- order is how the source printed it), `align = 'keyed-ordered'` (key and order both), or
-- nothing (positional, every node before this pass). A keyed node's kids are `pair`s
-- carrying a string key, or, for a merge-keyed LIST (`key = 'name'`, Kubernetes'
-- patchMergeKey), nodes whose key is the value under that field. Two rules keep the
-- position lens sound: a keyed step is the KEY STRING and never the last element of a
-- repetition or context site (no hedge or context hole is a direct kid of a keyed node;
-- the "rest" is a presence hole per key), and every kid of a keyed node yields a key.
function M.pair(key, value) return { k = 'pair', kids = { M.lit(key), value } } end
-- ── COMPOSITE KEYS (KEYED.md, "Composite keys"). A merge key may be a TUPLE of components:
-- Kubernetes' `x-kubernetes-list-map-keys` ("a list of field names whose values uniquely
-- identify entries ... the key fields must be scalars"), Erlang's `mod:f/N` (name and arity),
-- Java's method signature (JLS §8.4.2: name and the formal parameter types, never the
-- parameter names). A component is a field name (its literal value) or a DERIVED measure
-- `{ field = 'params', by = 'arity' | 'types' }`. The tuple is compared componentwise: the
-- key string call sites index by is an injective serialization (`port=80,protocol=TCP`, with
-- `\`, `=`, `,` and `|` escaped inside values), so ("a,b","c") and ("a","b,c") never collide.
-- A single plain field stays the bare value, so every path before this section is unchanged.
local function esc(v) return (tostring(v):gsub('[\\=,|]', function(c) return '\\' .. c end)) end
local function field_of(kid, name)
    for _, p in ipairs(kid.kids or {}) do
        if p.k == 'pair' and p.kids and p.kids[1] and p.kids[1].k == 'lit' and tostring(p.kids[1].v) == name then return p.kids[2] end
    end
    return nil
end
local function key_components(t)
    if type(t.key) == 'table' then return t.key end
    return { t.key }
end
local function component_of(kid, c)
    if type(c) == 'string' then
        local v = field_of(kid, c)
        if v == nil then return nil, 'no field ' .. c end
        if is_hole(v) then return nil, 'the key field ' .. c .. ' is a hole; a key is an identity, not a variable' end
        if v.k ~= 'lit' then return nil, 'the key field ' .. c .. ' is not a scalar' end -- Kubernetes: key fields must be scalars
        return tostring(v.v)
    end
    local v = field_of(kid, c.field)
    if v == nil then return nil, 'no field ' .. tostring(c.field) end
    if is_hole(v) then return nil, 'the key field ' .. tostring(c.field) .. ' is a hole; a key is an identity, not a variable' end
    if c.by == 'arity' then return tostring(#(v.kids or {})) end -- Erlang: the number of arguments
    if c.by == 'types' then -- JLS §8.4.2: the formal parameter TYPES, the names do not enter
        local ts = {}
        for i, prm in ipairs(v.kids or {}) do
            local ty = (prm.k == 'name' and prm.n) or (prm.k == 'lit' and tostring(prm.v)) or nil
            if ty == nil then
                local tp = field_of(prm, 'type')
                ty = tp and (tp.k == 'lit' and tostring(tp.v) or (tp.k == 'name' and tp.n)) or nil
            end
            if ty == nil then return nil, ('parameter %d of %s has no type'):format(i, c.field) end
            ts[#ts + 1] = esc(ty)
        end
        return table.concat(ts, '|')
    end
    return nil, 'unknown key measure ' .. tostring(c.by)
end
--- how a key spec prints in the mark: `port+protocol`, `name+params/types`; two nodes carry the
--- SAME key when their specs agree (a composite spec is a table, never compared by identity)
local function same_key(a, b)
    if a == b then return true end
    if a == nil or b == nil or a == true or b == true then return false end
    return M.key_spec({ key = a }) == M.key_spec({ key = b })
end
M.same_key = same_key
function M.key_spec(t)
    if t.key == true then return 'true' end
    local parts = {}
    for _, c in ipairs(key_components(t)) do parts[#parts + 1] = type(c) == 'string' and c or (tostring(c.field) .. '/' .. tostring(c.by)) end
    return table.concat(parts, '+')
end
--- the alignment key of one kid of a keyed node, or nil with the reason
function M.key_of(t, kid)
    if type(kid) ~= 'table' then return nil, 'not a node' end
    if t.key == true then
        if kid.k == 'lit' then return tostring(kid.v) end
        return nil, 'a set of primitives holds literals, got ' .. tostring(kid.k)
    end
    if t.key then
        if is_hole(kid) then return nil, 'a hole cannot carry the merge key ' .. M.key_spec(t) end
        local comps = key_components(t)
        if #comps == 1 and type(comps[1]) == 'string' then
            local v, why = component_of(kid, comps[1])
            if v == nil then return nil, why end
            return v
        end
        local parts = {}
        for _, c in ipairs(comps) do
            local v, why = component_of(kid, c)
            if v == nil then return nil, why end
            parts[#parts + 1] = (type(c) == 'string' and c or (tostring(c.field) .. '/' .. tostring(c.by))) .. '=' .. (type(c) == 'string' and esc(v) or v)
        end
        return table.concat(parts, ',')
    end
    if kid.k ~= 'pair' or not (kid.kids and kid.kids[1] and kid.kids[1].k == 'lit') then return nil, 'not a pair with a literal key' end
    return tostring(kid.kids[1].v)
end
--- the kids of a keyed node with their keys, in CANONICAL order: sorted by key for
--- `keyed`, the given order for `keyed-ordered`. Canonical order is load-bearing:
--- generalize's memo and the demand traces hash through `show`.
function M.keys(t)
    local out = {}
    for i, kid in ipairs(t.kids or {}) do
        local k, why = M.key_of(t, kid)
        if not k then error(('keyed %s: kid %d: %s'):format(t.k, i, why)) end
        out[#out + 1] = { key = k, kid = kid, i = i }
    end
    if t.align ~= 'keyed-ordered' then table.sort(out, function(a, b) return a.key < b.key end) end
    return out
end
--- a keyed node: `opts.ordered` for keyed-ordered, `opts.key` for a merge-keyed list.
--- A duplicate key or an unkeyable kid is refused by name.
function M.keyed(k, kids, opts)
    opts = opts or {}
    local t = { k = k, kids = kids, align = opts.ordered and 'keyed-ordered' or 'keyed', key = opts.key }
    local seen = {}
    for i, kid in ipairs(kids) do
        local key, why = M.key_of(t, kid)
        if not key then error(('keyed %s: kid %d: %s'):format(k, i, why)) end
        if seen[key] then error(('keyed %s: duplicate key %s'):format(k, key)) end
        seen[key] = true
    end
    return t
end
--- the kid of a keyed node under a key, and its index
function M.kid_by_key(t, key)
    for i, kid in ipairs(t.kids or {}) do if M.key_of(t, kid) == key then return kid, i end end
    return nil
end
--- the path step to kid i of t: the key for a keyed node, the index otherwise
function M.step(t, i)
    if t.align then local k = M.key_of(t, t.kids[i]); if k then return k end end
    return i
end
--- PRESENCE: a pair present in some members carries a presence hole (`opt`), whose value
--- is one of two nodes. They are nodes and not booleans so a real column of true/false
--- literals can never share a hole with a presence vector (the memo keys on the value).
function M.present() return { k = 'present' } end
function M.absent() return { k = 'absent' } end
local function is_absent(v) return type(v) == 'table' and v.k == 'absent' end
--- mark a pair optional under presence hole h
function M.optional(pair, h) local p = M.copy(pair); p.opt = h; return p end
--- does a term contain a keyed node anywhere?
function M.has_keyed(t)
    if type(t) ~= 'table' then return false end
    if t.align then return true end
    for _, c in ipairs(t.kids or {}) do if M.has_keyed(c) then return true end end
    return false
end

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
    -- the alignment discipline is part of the node's identity (a span is not: it stays ignored)
    if a.align ~= b.align or not same_key(a.key, b.key) then return false end
    if (a.opt or false) ~= (b.opt or false) then return false end
    local ka, kb = a.kids or {}, b.kids or {}
    if #ka ~= #kb then return false end
    if a.align == 'keyed' then
        for _, e in ipairs(M.keys(a)) do
            local other = M.kid_by_key(b, e.key)
            if not other or not M.eq(e.kid, other) then return false end
        end
        return true
    end
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
    if t.align then
        for i, e in ipairs(M.keys(t)) do parts[i] = M.show(e.kid) end
        local mark = '[' .. (t.key and ('key=' .. M.key_spec(t)) or 'keyed') .. (t.align == 'keyed-ordered' and ',ordered' or '') .. ']'
        return '(' .. t.k .. mark .. (#parts > 0 and ' ' or '') .. table.concat(parts, ' ') .. ')'
    end
    for i, c in ipairs(t.kids or {}) do parts[i] = M.show(c) end
    local opt = t.opt and ('?' .. t.opt .. ':') or ''
    return '(' .. opt .. t.k .. (#parts > 0 and ' ' or '') .. table.concat(parts, ' ') .. ')'
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
--- the longest common subsequence of two kid lists as matched index pairs (Myers 1986 §2:
--- a trace; the LCS and the shortest edit script are dual). The quadratic table, not the
--- O(ND) greedy: kid lists are short and `eq` on subtrees is the cost, computed once per
--- pair. Ties break to the earliest match on both sides (this prototype's choice).
function M.lcs(A_, B_, eqf)
    eqf = eqf or M.eq
    local n, m = #A_, #B_
    local E = {}
    for i = 1, n do E[i] = {} for j = 1, m do E[i][j] = eqf(A_[i], B_[j]) and true or false end end
    local L = {}
    for i = 0, n do L[i] = {} for j = 0, m do L[i][j] = 0 end end
    for i = n - 1, 0, -1 do
        for j = m - 1, 0, -1 do
            if E[i + 1][j + 1] then L[i][j] = L[i + 1][j + 1] + 1 else L[i][j] = math.max(L[i + 1][j], L[i][j + 1]) end
        end
    end
    local out, i, j = {}, 0, 0
    while i < n and j < m do
        if E[i + 1][j + 1] then out[#out + 1] = { i + 1, j + 1 }; i = i + 1; j = j + 1
        elseif L[i + 1][j] >= L[i][j + 1] then i = i + 1 else j = j + 1 end
    end
    return out
end
-- an anchor for an alignment: a kid common to both lists; a hole never anchors
local function anchor_eq(x, y) return not is_hole(x) and not is_hole(y) and M.eq(x, y) end
-- can template kid t stand for kid x at one position: ground by eq, a term hole for any one
-- kid, a node with holes inside by kind, arity and kids (the forced rule's placement test)
local function fits(t, x)
    if is_hole(t) then return not t.rep and not t.ctx and not (is_hole(x) and (x.rep or x.ctx)) end
    if is_hole(x) then return false end
    if t.k == 'lit' or t.k == 'name' or M.ground(t) then return M.eq(t, x) end
    if t.k ~= x.k or #(t.kids or {}) ~= #(x.kids or {}) then return false end
    for i, c in ipairs(t.kids or {}) do if not fits(c, x.kids[i]) then return false end end
    return true
end
-- an anchor by fit: equal kids, or a NODE with holes inside that fits the other, so a statement
-- a family already abstracted still anchors; a bare hole never anchors (it would fit anything,
-- and the fold of join would then differ from n-ary generalize); join and generalize share it
local function anchor_fit(x, y) return anchor_eq(x, y) or (not is_hole(x) and not is_hole(y) and (fits(x, y) or fits(y, x))) end
local function hedged_run(kids, from, to) for x = from, to do if is_hole(kids[x]) and kids[x].rep then return true end end; return false end
local function child(path, i) local p = { unpack(path) }; p[#p + 1] = i; return p end

local function at(t, path)
    for _, i in ipairs(path) do
        if type(i) == 'string' then t = t and t.align and M.kid_by_key(t, i) or nil
        else t = t and t.kids and t.kids[i] end
    end
    return t
end
M.at = at
--- order on path steps: an index before a key, each kind in its own order
local function step_lt(a, b)
    local ta, tb = type(a), type(b)
    if ta ~= tb then return ta == 'number' end
    return a < b
end
M.step_lt = step_lt

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
--- a repetition domain; `period` > 1 (REPETITION.md) means the sequence is read in chunks of
--- that many kids and `of` admits each CHUNK (a seq); min/max still count kids
function M.rep(of, min, max, period) return { kind = 'rep', of = of, min = min or 0, max = max, period = (period and period > 1) and period or nil } end
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
    if D.kind == 'rep' then return M.show_domain(D.of) .. (D.period and ('/' .. D.period) or '') .. '{' .. D.min .. ',' .. (D.max or '') .. '}' end
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
        return false, '@' .. D.name .. ' refused: ' .. (m.refusal and m.refusal.why or 'no match')
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
        if D.period then -- the unit is a chunk of `period` kids (Kolpakov & Kucherov: an integer power u^k)
            if n % D.period ~= 0 then return false, ('length %d is not a multiple of the period %d'):format(n, D.period) end
            for c = 1, n / D.period do
                local kids = {}
                for j = 1, D.period do kids[j] = v.kids[(c - 1) * D.period + j] end
                local ok, why = M.admits(D.of, M.seq(kids), env)
                if not ok then return false, ('chunk %d: %s'):format(c, why) end
            end
            return true
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
    if A.kind == 'rep' and B.kind == 'rep' then -- every sequence A admits, B admits: elements, bounds, period
        if not M.entails(A.of, B.of, env) then return false end
        if A.min < B.min then return false end
        if B.max and (not A.max or A.max > B.max) then return false end
        if B.period and A.period ~= B.period then return false end
        return true
    end
    return false
end

--- a hedge hole's domain against a slice that holds HEDGE VARIABLES of a query template
--- (instance_of, minimize: the instance is itself a template): `plain` are the slice's
--- ordinary elements, `hedges` the domains of its hedge variables. Admitted iff every
--- sequence the slice can stand for is admitted: each plain element and each variable's
--- element domain under the repetition's, the lengths the variables allow within its bounds.
--- A period claim is not checked across a variable, nor a claim that is not a repetition,
--- except by identity (a variable claiming exactly this domain, nothing beside it).
function M.admits_slice(D, plain, hedges, env)
    if #hedges == 0 then return M.admits(D, M.seq(plain), env) end
    if D.kind == 'open' then return true end
    if #plain == 0 and #hedges == 1 and M.show_domain(hedges[1]) == M.show_domain(D) then return true end -- identity: a variable claiming exactly this domain
    if D.kind ~= 'rep' then
        for _, q in ipairs(hedges) do
            if M.show_domain(q) ~= M.show_domain(D) then return false, ('a hedge variable of %s cannot be checked against %s'):format(M.show_domain(q), M.show_domain(D)) end
        end
        if #plain > 0 then return false, 'elements beside a hedge variable cannot be checked against ' .. M.show_domain(D) end
        return true
    end
    if D.period then return false, ('a period claim %s cannot be checked across a hedge variable'):format(M.show_domain(D)) end
    for i, e in ipairs(plain) do
        local ok, why = M.admits(D.of, e, env)
        if not ok then return false, ('element %d: %s'):format(i, why) end
    end
    local lo, hi = #plain, #plain
    for _, q in ipairs(hedges) do
        local qof, qmin, qmax = M.open(), 0, nil
        if q.kind == 'rep' then qof, qmin, qmax = q.of, q.min, q.max
        elseif q.kind ~= 'open' then return false, ('a hedge variable of %s cannot be checked against %s'):format(M.show_domain(q), M.show_domain(D)) end
        if not M.entails(qof, D.of, env) then return false, ('a hedge variable of %s does not entail %s'):format(M.show_domain(q), M.show_domain(D)) end
        lo = lo + qmin
        hi = (hi and qmax) and hi + qmax or nil
    end
    if lo < D.min then return false, ('count at least %d, below {%d,%s}'):format(lo, D.min, tostring(D.max or '')) end
    if D.max and (not hi or hi > D.max) then return false, ('count up to %s, above {%d,%d}'):format(hi and tostring(hi) or 'any', D.min, D.max) end
    return true
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
        if not holes[h] then holes[h] = { domain = e.presence and e.domain or (e.ctx and M.context() or M.open()), origin = 'derived' } end
        holes[h].rep, holes[h].ctx, holes[h].presence = e.rep, e.ctx, e.presence
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
    local step = path[i]
    for j, c in ipairs(t.kids or {}) do
        local here = type(step) == 'string' and (t.align and M.key_of(t, c) == step) or (j == step)
        kids[j] = here and M.put(c, path, sub, i + 1) or c
    end
    return M.rebuild(t, kids)
end
--- every position of a term in preorder, with its subterm: { {path, node}, .. }
function M.positions(t)
    local out = {}
    local function walk(x, path)
        out[#out + 1] = { path = path, node = x }
        for i, c in ipairs(x.kids or {}) do walk(c, child(path, M.step(x, i))) end
    end
    walk(t, {})
    return out
end

--- H: every hole's sites and domain, read off the body
function M.sites(T)
    local H = {}
    local through = {} -- grammar boundaries on the way down: { {path, g}, .. }
    local under = {}   -- presence holes on the way down: { {h, path}, .. } (a site under an absent pair has no value)
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
            if #under > 0 then site.under = M.copy(under) end
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
        for i, c in ipairs(t.kids or {}) do
            local p = child(path, M.step(t, i))
            if t.align and c.opt then
                -- the presence hole of an optional pair sits AT the pair's key step
                local e = H[c.opt]
                if not e then
                    e = { sites = {}, domain = (T.holes and T.holes[c.opt] and T.holes[c.opt].domain) or M.kinds { 'present', 'absent' },
                        origin = (T.holes and T.holes[c.opt] and T.holes[c.opt].origin) or 'derived', rep = false, presence = true }
                    H[c.opt] = e
                end
                local site = { path = p, presence = true }
                if #under > 0 then site.under = M.copy(under) end
                e.sites[#e.sites + 1] = site
                under[#under + 1] = { h = c.opt, path = p }
                walk(c, p)
                under[#under] = nil
            else
                walk(c, p)
            end
        end
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
    if t.align then
        -- an optional pair whose presence is absent is dropped; unfilled presence stays as is
        local kids = {}
        for _, c in ipairs(t.kids) do
            if c.opt and is_absent(V[c.opt]) then -- dropped
            else
                local c2 = subst(c, V, unfilled)
                if c.opt and V[c.opt] == nil then unfilled[c.opt] = true else c2.opt = nil end
                kids[#kids + 1] = c2
            end
        end
        return M.rebuild(t, kids)
    end
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
--- is a site under a pair whose presence value is absent? (then the hole owes no value there)
local function site_dropped(s, V)
    for _, u in ipairs(s.under or {}) do if is_absent(V[u.h]) then return true end end
    return false
end
M.site_dropped = site_dropped
--- is hole h required by V: some site of it is not under an absent pair
local function required(e, V)
    for _, s in ipairs(e.sites) do if not site_dropped(s, V) then return true end end
    return false
end
function M.instantiate(T, V, env)
    local H = M.sites(T)
    local missing, rejected, extra = {}, {}, {}
    for h in pairs(V) do if not H[h] then extra[#extra + 1] = h end end
    for h, e in pairs(H) do
        if V[h] == nil then
            if required(e, V) then missing[#missing + 1] = h end
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
    local last = path[#path]
    if type(last) == 'string' then
        local _, i = M.kid_by_key(parent, last)
        if not i then error('set_at: no kid under key ' .. last) end
        last = i
    end
    parent.kids[last] = node
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
--- the kid a path names inside a keyed parent must keep a key of its own, and not another
--- kid's (KEYED.md): a keyed node never holds an unkeyed kid, so an edit that would put one
--- there is refused by name rather than raising in the next `show`
local function keyed_parent_ok(who, root, path, kid)
    if #path == 0 then return true end
    local parent = at(root, { unpack(path, 1, #path - 1) })
    if not (parent and parent.align) then return true end
    local k, why = M.key_of(parent, kid)
    if not k then return false, ('%s: the kid under a keyed %s must carry a key (%s)'):format(who, parent.k, why) end
    local step = path[#path]
    for i, c in ipairs(parent.kids) do
        local ck = M.key_of(parent, c)
        if ck == k and not (type(step) == 'string' and ck == step) and not (type(step) == 'number' and i == step) then
            return false, ('%s: key %s is already a kid of this %s'):format(who, k, parent.k)
        end
    end
    return true
end
function M.dig(T, path, h, domain)
    if is_hole(at(T.body, path)) then return nil, 'already a hole' end
    local okp, pwhy = keyed_parent_ok('dig', T.body, path, M.hole(h))
    if not okp then return nil, pwhy .. '; dig the pair\'s value instead' end
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
    local names, own = {}, M.sites(T)
    for _, h in ipairs(M.hole_names(T)) do names[h] = true end
    local function check(t)
        if is_hole(t) then
            if not names[t.h] then return false, 'rewrite: unknown hole ' .. t.h end
            if t.ctx then return false, 'rewrite: repetition/context holes not supported' end
            -- a hedge the template already has may move with a rewrite (CLASSIFY.md); one it lacks is refused
            if t.rep and not (own[t.h] and own[t.h].rep) then return false, 'rewrite: repetition/context holes not supported' end
        end
        if t.align then -- a keyed node inside the substitution must be well-formed
            local okk, kwhy = pcall(M.keys, t)
            if not okk then return false, 'rewrite: ' .. tostring(kwhy) end
        end
        for _, c in ipairs(t.kids or {}) do
            local ok, why = check(c)
            if not ok then return ok, why end
        end
        return true
    end
    local ok, why = check(sub)
    if not ok then return nil, why end
    local okp, pwhy = keyed_parent_ok('rewrite', T.body, path, sub)
    if not okp then return nil, pwhy end
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

-- ── the lossless `lua` grammar (READER.md). A concrete syntax tree whose leaves are the
-- source's tokens as literal kids and whose gaps (whitespace, which tree-sitter keeps out of
-- the tree) are literal kids too, so print is the concatenation of every leaf in order and
-- print after parse is the input byte for byte. parse needs tree-sitter: a bridge running
-- under Neovim installs it in M.parsers.lua (experiments/lua_reader.lua); without it the
-- grammar reads nothing and an embed refuses "does not parse".
M.parsers = {}
function M.cst_print(t)
    local buf = {}
    local function go(x)
        if x.k == 'lit' then buf[#buf + 1] = tostring(x.v)
        elseif x.k == 'name' then buf[#buf + 1] = tostring(x.n)
        elseif is_hole(x) then error('cst_print: unfilled hole ' .. tostring(x.h))
        else for _, c in ipairs(x.kids or {}) do go(c) end end
    end
    go(t)
    return table.concat(buf)
end
M.grammar('lua', {
    print = function(t) local ok, text = pcall(M.cst_print, t); if ok then return text end return nil end,
    parse = function(s) local p = M.parsers.lua; if p then return p(s) end return nil end,
})

-- ── the `hbs` grammar: a template language as a store (EXPRESS.md) ─────────────────────
-- mustache(5) read for the tag types, the Handlebars guide for expressions and the built-in
-- helpers. A template is a term: `text`, `var` (escaped) and `raw` (triple-stash) lookups of a
-- dotted path, `comment`, `partial`, and `block` (kind: section, inverted, if, unless, each,
-- with) with a body and an else part. Parse keeps the mustache spec's standalone rule for
-- the tags that stand alone on a line (comment, partial, section open and close, inverted,
-- else): the line is consumed, a standalone partial keeping its indentation. Print is
-- canonical, tags inline, so print then parse is the identity on every term. `hbs_render`
-- is the evaluator the tests and the census judge by: mustache's lookup through the context
-- stack, sections over lists and objects, the Handlebars falsiness for if/unless/each
-- (false, nil, "", 0, an empty list), @index/@first/@last/@key/this, HTML escaping of & < >
-- " ' for `var` and none for `raw`.
local HBS_ESC = { ['&'] = '&amp;', ['<'] = '&lt;', ['>'] = '&gt;', ['"'] = '&quot;', ["'"] = '&#39;' }
local function hbs_parse(src)
    if type(src) ~= 'string' then return nil end
    local pos, n = 1, #src
    local toks = {} -- { kind, a, b, text/path/indent, standalone }
    -- tokenize into text and tags
    while pos <= n do
        local s, e = src:find('{{', pos, true)
        if not s then toks[#toks + 1] = { kind = 'text', text = src:sub(pos) }; break end
        if s > pos then toks[#toks + 1] = { kind = 'text', text = src:sub(pos, s - 1) } end
        local close, ce
        if src:sub(e + 1, e + 1) == '{' then close, ce = src:find('}}}', e + 2, true); if not close then return nil end
            toks[#toks + 1] = { kind = 'raw', path = src:sub(e + 2, close - 1):match('^%s*(.-)%s*$') }
            pos = ce + 1
        else
            close, ce = src:find('}}', e + 1, true); if not close then return nil end
            local inner = src:sub(e + 1, close - 1):match('^%s*(.-)%s*$')
            local sigil, rest = inner:sub(1, 1), inner:sub(2):match('^%s*(.-)%s*$')
            if sigil == '!' then toks[#toks + 1] = { kind = 'comment', text = inner:sub(2) }
            elseif sigil == '>' then toks[#toks + 1] = { kind = 'partial', name = rest }
            elseif sigil == '&' then toks[#toks + 1] = { kind = 'raw', path = rest }
            elseif sigil == '^' then toks[#toks + 1] = { kind = 'open', block = 'inverted', path = rest }
            elseif sigil == '/' then toks[#toks + 1] = { kind = 'close', path = rest }
            elseif sigil == '#' then
                local head, arg = rest:match('^(%S+)%s*(.-)$')
                if (head == 'if' or head == 'unless' or head == 'each' or head == 'with') and arg ~= '' then toks[#toks + 1] = { kind = 'open', block = head, path = arg }
                else toks[#toks + 1] = { kind = 'open', block = 'section', path = rest } end
            elseif inner == 'else' then toks[#toks + 1] = { kind = 'else' }
            else toks[#toks + 1] = { kind = 'var', path = inner } end
            pos = ce + 1
        end
    end
    -- the standalone rule (the mustache spec, as the manual's examples render): a tag alone on
    -- its line, whitespace aside, takes the line with it; a standalone partial keeps its indent
    local standalone = { comment = true, partial = true, open = true, close = true, ['else'] = true }
    for i, t in ipairs(toks) do
        if standalone[t.kind] then
            local prev, nxt = toks[i - 1], toks[i + 1]
            local before = prev == nil and '' or (prev.kind == 'text' and prev.text or nil)
            local after = nxt == nil and '' or (nxt.kind == 'text' and nxt.text or nil)
            if before and after then
                local bl = before:match('([ \t]*)$')
                -- a text token that begins where a consumed tail ended begins a line
                local line_start = prev == nil or before:sub(1, #before - #bl):match('\n$') ~= nil or ((i == 2 or (prev and prev.starts_line)) and #before == #bl)
                local tail = after:match('^[ \t]*\r?\n')
                local line_end = tail ~= nil or (nxt == nil and after == '')
                if line_start and line_end then
                    if prev then prev.text = before:sub(1, #before - #bl) end
                    if nxt and tail then nxt.text = after:sub(#tail + 1); nxt.starts_line = true end
                    if t.kind == 'partial' then t.indent = bl end
                    t.standalone = true
                end
            end
        end
    end
    -- build the tree
    local i = 0
    local function body(open)
        local kids, elsek = {}, nil
        local cur = kids
        while true do
            i = i + 1
            local t = toks[i]
            if t == nil then if open then return nil end; break end
            if t.kind == 'text' then if t.text ~= '' then cur[#cur + 1] = M.node('text', M.lit(t.text)) end
            elseif t.kind == 'var' then cur[#cur + 1] = M.node('var', M.lit(t.path))
            elseif t.kind == 'raw' then cur[#cur + 1] = M.node('raw', M.lit(t.path))
            elseif t.kind == 'comment' then cur[#cur + 1] = M.node('comment', M.lit(t.text))
            elseif t.kind == 'partial' then cur[#cur + 1] = M.node('partial', M.lit(t.name), M.lit(t.indent or ''))
            elseif t.kind == 'open' then
                local b, e2 = body(t)
                if not b then return nil end
                cur[#cur + 1] = M.node('block', M.lit(t.block), M.lit(t.path), M.node('body', unpack(b)), M.node('else', unpack(e2 or {})))
            elseif t.kind == 'else' then
                if not open then return nil end
                elsek = {}; cur = elsek
            elseif t.kind == 'close' then
                if not open then return nil end
                if open.block ~= 'section' and open.block ~= 'inverted' and t.path ~= open.block then return nil end
                if (open.block == 'section' or open.block == 'inverted') and t.path ~= open.path then return nil end
                return kids, elsek
            end
        end
        return kids, elsek
    end
    local kids = body(nil)
    if not kids then return nil end
    return M.node('hbs', unpack(kids))
end
local function hbs_print(t)
    local out = {}
    local function go(x)
        if x.k == 'hbs' or x.k == 'body' or x.k == 'else' then for _, c in ipairs(x.kids) do go(c) end
        elseif x.k == 'text' then out[#out + 1] = tostring(x.kids[1].v)
        elseif x.k == 'var' then out[#out + 1] = '{{' .. x.kids[1].v .. '}}'
        elseif x.k == 'raw' then out[#out + 1] = '{{{' .. x.kids[1].v .. '}}}'
        elseif x.k == 'comment' then out[#out + 1] = '{{!' .. x.kids[1].v .. '}}'
        elseif x.k == 'partial' then out[#out + 1] = '{{> ' .. x.kids[1].v .. '}}'
        elseif x.k == 'block' then
            local kind, path = x.kids[1].v, x.kids[2].v
            out[#out + 1] = kind == 'section' and ('{{#' .. path .. '}}') or kind == 'inverted' and ('{{^' .. path .. '}}') or ('{{#' .. kind .. ' ' .. path .. '}}')
            go(x.kids[3])
            if #x.kids[4].kids > 0 then out[#out + 1] = '{{else}}'; go(x.kids[4]) end
            out[#out + 1] = (kind == 'section' or kind == 'inverted') and ('{{/' .. path .. '}}') or ('{{/' .. kind .. '}}')
        elseif is_hole(x) then error('hbs: unfilled hole ' .. tostring(x.h))
        else error('hbs: no print for ' .. tostring(x.k)) end
    end
    go(t)
    return table.concat(out)
end
M.grammar('hbs', {
    parse = hbs_parse,
    print = function(t) local ok, s = pcall(hbs_print, t); if ok then return s end return nil end,
})
--- the evaluator: render a template term against data (Lua tables; a list is a table with
--- kids 1..n; false/nil are false), with partials by name
function M.hbs_render(t, data, partials)
    local function is_list(v) return type(v) == 'table' and (#v > 0 or next(v) == nil) end
    local function lookup(stack, path)
        if path == '.' or path == 'this' then return stack[#stack].ctx end
        local first, rest = path:match('^([^.]+)%.?(.*)$')
        local v
        if first:sub(1, 1) == '@' then
            for d = #stack, 1, -1 do if stack[d].data and stack[d].data[first] ~= nil then v = stack[d].data[first]; break end end
        elseif first == 'this' then v = stack[#stack].ctx
        else
            for d = #stack, 1, -1 do
                local c = stack[d].ctx
                if type(c) == 'table' and c[first] ~= nil then v = c[first]; break end
            end
        end
        if rest ~= '' then for seg in rest:gmatch('[^.]+') do if type(v) ~= 'table' then return nil end; v = v[seg] end end
        return v
    end
    local function str(v) if v == nil or v == false then return '' end; if type(v) == 'table' then return '' end; return tostring(v) end
    local function falsy(v) return v == nil or v == false or v == '' or v == 0 or (type(v) == 'table' and next(v) == nil) end
    local out = {}
    local function render(x, stack, indent)
        if x.k == 'hbs' or x.k == 'body' or x.k == 'else' then for _, c in ipairs(x.kids) do render(c, stack, indent) end
        elseif x.k == 'text' then out[#out + 1] = tostring(x.kids[1].v)
        elseif x.k == 'var' then out[#out + 1] = (str(lookup(stack, x.kids[1].v)):gsub('[&<>"\']', HBS_ESC))
        elseif x.k == 'raw' then out[#out + 1] = str(lookup(stack, x.kids[1].v))
        elseif x.k == 'comment' then -- nothing
        elseif x.k == 'partial' then
            local p = partials and partials[x.kids[1].v]
            if p then
                local pt = type(p) == 'string' and hbs_parse(p) or p
                local sub = M.hbs_render(pt, stack[#stack].ctx, partials)
                local ind = x.kids[2].v
                if ind ~= '' then sub = ind .. sub:gsub('\n(.)', '\n' .. ind .. '%1') end
                out[#out + 1] = sub
            end
        elseif x.k == 'block' then
            local kind, path, bodyk, elsek = x.kids[1].v, x.kids[2].v, x.kids[3], x.kids[4]
            local v = lookup(stack, path)
            local function push(ctx, data) local s = {}; for i2, f in ipairs(stack) do s[i2] = f end; s[#s + 1] = { ctx = ctx, data = data }; return s end
            if kind == 'section' then
                if v == nil or v == false or (type(v) == 'table' and next(v) == nil and #v == 0) then return end
                if is_list(v) then for _, item in ipairs(v) do render(bodyk, push(item)) end
                elseif type(v) == 'table' then render(bodyk, push(v))
                else render(bodyk, stack) end
            elseif kind == 'inverted' then
                if v == nil or v == false or (type(v) == 'table' and next(v) == nil) then render(bodyk, stack) end
            elseif kind == 'if' then if falsy(v) then render(elsek, stack) else render(bodyk, stack) end
            elseif kind == 'unless' then if falsy(v) then render(bodyk, stack) else render(elsek, stack) end
            elseif kind == 'with' then if falsy(v) then render(elsek, stack) else render(bodyk, push(v)) end
            elseif kind == 'each' then
                if falsy(v) then render(elsek, stack) return end
                if is_list(v) then
                    for i2, item in ipairs(v) do render(bodyk, push(item, { ['@index'] = i2 - 1, ['@first'] = i2 == 1, ['@last'] = i2 == #v })) end
                else
                    local keys = {}
                    for k in pairs(v) do keys[#keys + 1] = k end
                    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
                    for i2, k in ipairs(keys) do render(bodyk, push(v[k], { ['@key'] = k, ['@index'] = i2 - 1, ['@first'] = i2 == 1, ['@last'] = i2 == #keys })) end
                end
            end
        end
    end
    render(t, { { ctx = data } })
    return table.concat(out)
end

--- EXPRESSIBILITY (EXPRESS.md): a Lua string-building expression, as the lossless reader
--- gives it, generated as a Handlebars template. Rules, kept small: a string is text; an
--- identifier or a dotted chain is a raw lookup (Lua's `..` never escapes, so `{{{x}}}`);
--- `..` flattens; `tostring(lookup)` is the lookup; a number literal is text; a format call
--- (`('fmt'):format(...)`, `string.format`) splits at its directives, `%s`/`%d`/`%i` on a
--- lookup a lookup, `%%` a percent, any other directive STAGED with its argument;
--- `table.concat(list, 'sep')` is `#each` with the separator under `#unless @last`; an `or`
--- or `and` is STAGED, since Lua's falsiness (nil, false) is not Handlebars' (also "", 0,
--- []); `#x`, arithmetic, calls, index expressions and anything else in an interpolation
--- position are STAGED: the computation moves to the producing side and a lookup `sN`
--- stands for it, the computation listed by kind. The kind of the whole: `as-is` when
--- nothing is staged, `staged` when something is beside text or a lookup, `not` when a
--- template would add nothing (only staged lookups, or nothing).
function M.hbs_of(t)
    local kids, staged, lookups, n = {}, {}, {}, 0
    local function text(s) -- adjacent texts merge, as the grammar's parse would read them
        if s == '' then return end
        local last = kids[#kids]
        if last and last.k == 'text' then last.kids[1] = M.lit(tostring(last.kids[1].v) .. s) else kids[#kids + 1] = M.node('text', M.lit(s)) end
    end
    local function path_of(x)
        if x.k == 'identifier' then return x.kids[1].v end
        if x.k == 'dot_index_expression' then
            local a = path_of(x.kids[1])
            local b = x.kids[#x.kids]
            if a and b.k == 'identifier' then return a .. '.' .. b.kids[1].v end
        end
        return nil
    end
    local function paths_in(node) -- the dotted paths a computation reads (not callees, methods or field names)
        local out, seen = {}, {}
        local function walk(y, callee)
            if type(y) ~= 'table' then return end
            if y.k == 'identifier' or y.k == 'dot_index_expression' then
                local pth = path_of(y)
                if pth then -- a whole path: recorded once, its prefix not walked
                    if not callee and not seen[pth] then seen[pth] = true; out[#out + 1] = pth end
                    return
                end
                if y.k == 'dot_index_expression' then walk(y.kids[1], callee) end
                return
            end
            if y.k == 'function_call' then walk(y.kids[1], true); for i2 = 2, #y.kids do walk(y.kids[i2], false) end; return end
            if y.k == 'method_index_expression' then walk(y.kids[1], false); return end
            for _, c in ipairs(y.kids or {}) do walk(c, false) end
        end
        walk(node, false)
        return out
    end
    local function stage(kind, node, text_override, node_override)
        n = n + 1
        local refs = paths_in(node)
        -- a readable name: the last segment of the first path the computation reads, a length
        -- adding `_count`; `sN` when there is none or the name is taken
        local cand = refs[1] and refs[1]:match('([%w_]+)$') or nil
        if cand and kind == 'length' then cand = cand .. '_count' end
        if cand then for _, r in ipairs(refs) do if r == cand and kind ~= 'length' then cand = cand .. '_text' end end end -- not the name of a variable it reads
        local taken = lookups[cand] or cand == nil
        for _, e in ipairs(staged) do if e.name == cand then taken = true end end
        local name = taken and ('s' .. n) or cand
        staged[#staged + 1] = { name = name, kind = kind, text = text_override or M.cst_print(node), refs = refs, node = node_override or node }
        kids[#kids + 1] = M.node('raw', M.lit(name))
    end
    local ESC = { n = '\n', t = '\t', r = '\r', a = '\a', b = '\b', f = '\f', v = '\v', ['\\'] = '\\', ["'"] = "'", ['"'] = '"', ['\n'] = '\n' }
    local function unescape(raw) -- the Lua escapes a string_content carries as written
        return (tostring(raw):gsub('\\(%d%d?%d?)', function(d) return string.char(tonumber(d)) end):gsub('\\(.)', function(c) return ESC[c] or ('\\' .. c) end))
    end
    local function string_content(x)
        if x.k ~= 'string' then return nil end
        local out = {}
        local long = x.kids[1] and x.kids[1].k == 'lit' and tostring(x.kids[1].v):sub(1, 1) == '[' -- a long bracket string: no escapes, and Lua drops a first newline
        for _, c in ipairs(x.kids) do if c.k == 'string_content' then out[#out + 1] = long and M.cst_print(c) or unescape(M.cst_print(c)) end end -- an escape is a node inside the content: the leaves, unescaped
        local str = table.concat(out)
        if long then str = str:gsub('^\r?\n', '', 1) end
        return str
    end
    local function args_of(call)
        local args = {}
        for _, c in ipairs(call.kids) do if c.k == 'arguments' then for _, a in ipairs(c.kids) do if a.k ~= 'lit' then args[#args + 1] = a end end end end
        return args
    end
    local lookup_nodes = {}
    local function lookup(x) local p = path_of(x); if p then lookups[p] = true; lookup_nodes[p] = lookup_nodes[p] or x; kids[#kids + 1] = M.node('raw', M.lit(p)); return true end; return false end
    local part
    local function format_split(fmt, args, call)
        local i, ai, buf = 1, 1, {}
        while i <= #fmt do
            local c = fmt:sub(i, i)
            if c == '%' then
                if fmt:sub(i + 1, i + 1) == '%' then buf[#buf + 1] = '%'; i = i + 2
                else
                    local spec = fmt:match('^%%[-+ #0]*%d*%.?%d*[a-zA-Z]', i)
                    if not spec then buf[#buf + 1] = fmt:sub(i); break end
                    text(table.concat(buf)); buf = {}
                    local arg = args[ai]; ai = ai + 1
                    if (spec == '%s' or spec == '%d' or spec == '%i') and arg then part(arg) -- a lookup, or the argument's own rule
                    elseif arg then -- the producing side formats it: the call as a term in the reader's shape
                        local fcall = M.node('function_call', M.node('method_index_expression', M.node('parenthesized_expression', M.lit '(', M.node('string', M.lit "'", M.node('string_content', M.lit(spec)), M.lit "'"), M.lit ')'), M.lit ':', M.node('identifier', M.lit 'format')), M.node('arguments', M.lit '(', M.copy(arg), M.lit ')'))
                        stage('format:' .. spec, arg, ("('%s'):format(%s)"):format(spec, M.cst_print(arg)), fcall)
                    else stage('format:' .. spec, call) end
                    i = i + #spec
                end
            else buf[#buf + 1] = c; i = i + 1 end
        end
        text(table.concat(buf))
    end
    local function is_concat(y) if y.k ~= 'binary_expression' then return false end; for _, c in ipairs(y.kids) do if c.k == 'lit' and c.v == '..' then return true end end; return false end
    local BIN = { ['..'] = 'concat', ['or'] = 'or', ['and'] = 'or', ['+'] = 'arith', ['-'] = 'arith', ['*'] = 'arith', ['/'] = 'arith', ['%'] = 'arith', ['^'] = 'arith', ['=='] = 'arith', ['~='] = 'arith', ['<'] = 'arith', ['>'] = 'arith', ['<='] = 'arith', ['>='] = 'arith' }
    part = function(x)
        if x.k == 'string' then text(string_content(x) or '') return end
        if x.k == 'number' then text(tostring(x.kids[1].v)) return end
        if x.k == 'parenthesized_expression' then for _, c in ipairs(x.kids) do if c.k ~= 'lit' then return part(c) end end; return end
        if path_of(x) then lookup(x) return end
        if x.k == 'binary_expression' then
            local op
            for _, c in ipairs(x.kids) do if c.k == 'lit' and BIN[c.v] then op = BIN[c.v] end end
            if op == 'concat' then for _, c in ipairs(x.kids) do if c.k ~= 'lit' then part(c) end end; return end
            stage(op or 'other', x) return
        end
        if x.k == 'unary_expression' then
            local o = x.kids[1]
            stage((o.k == 'lit' and o.v == '#') and 'length' or 'arith', x) return
        end
        if x.k == 'function_call' then
            local head = x.kids[1]
            if head.k == 'identifier' and head.kids[1].v == 'tostring' then -- `..` coerces anyway: the argument's own rule
                local a = args_of(x)
                if #a == 1 then part(a[1]) return end
                stage('call', x) return
            end
            if head.k == 'method_index_expression' then
                local last = head.kids[#head.kids]
                if last.k == 'identifier' and last.kids[1].v == 'format' then
                    local recv = head.kids[1]
                    local function literal_text(y) -- a string, or a `..` chain of strings, folded
                        if y.k == 'string' then return string_content(y) end
                        if y.k == 'parenthesized_expression' then for _, c in ipairs(y.kids) do if c.k ~= 'lit' then return literal_text(c) end end; return nil end
                        if is_concat(y) then
                            local parts = {}
                            for _, c in ipairs(y.kids) do if c.k ~= 'lit' then local t2 = literal_text(c); if not t2 then return nil end; parts[#parts + 1] = t2 end end
                            return table.concat(parts)
                        end
                        return nil
                    end
                    local fmt = literal_text(recv)
                    if fmt then format_split(fmt, args_of(x), x) return end
                end
                stage('call', x) return
            end
            local hp = head.k == 'dot_index_expression' and path_of(head) or nil
            if hp == 'string.format' then
                local a = args_of(x)
                local fmt = a[1] and string_content(a[1])
                if fmt then table.remove(a, 1); format_split(fmt, a, x) return end
                stage('call', x) return
            end
            if hp == 'table.concat' then
                local a = args_of(x)
                local lp = a[1] and path_of(a[1])
                local sep = a[2] and string_content(a[2])
                if lp and #a <= 2 and (#a == 1 or sep) then -- a range (i, j) is a computation, staged below
                    lookups[lp] = true; lookup_nodes[lp] = lookup_nodes[lp] or a[1]
                    local body = { M.node('raw', M.lit 'this') }
                    if sep and sep ~= '' then body[#body + 1] = M.node('block', M.lit 'unless', M.lit '@last', M.node('body', M.node('text', M.lit(sep))), M.node('else')) end
                    kids[#kids + 1] = M.node('block', M.lit 'each', M.lit(lp), M.node('body', unpack(body)), M.node('else'))
                    return
                end
                stage('call', x) return
            end
            stage('call', x) return
        end
        if x.k == 'bracket_index_expression' then stage('index', x) return end
        stage('other', x)
    end
    part(t)
    local shaped = false
    local staged_name = {}
    for _, e in ipairs(staged) do staged_name[e.name] = true end
    for _, k in ipairs(kids) do if k.k == 'text' or k.k == 'block' or (k.k == 'raw' and not staged_name[k.kids[1].v]) then shaped = true end end
    local kind = #staged == 0 and (shaped and 'as-is' or 'not') or (shaped and 'staged' or 'not')
    local names = {}
    for p2 in pairs(lookups) do names[#names + 1] = p2 end
    table.sort(names)
    return { term = M.node('hbs', unpack(kids)), kind = kind, staged = staged, lookups = names, lookup_nodes = lookup_nodes }
end
--- THE RENDER CALL (RENDER.md): the producing side written by a template. `RENDER_CALL` is the
--- generator in the lossless reader's own shape, `render('<name>', { k = v, ... })`, the fields
--- a hedge; `render_call(name, fields)` is its instance, `render_call_of(term)` reads one back
--- through the same template (the writer's inverse is a match), and `move_to_template` composes
--- the move: the expression's template with its lookups flattened to field keys, the fields
--- (a lookup's own node, a staged computation's node) and the call. `move_law` is the sample
--- law on the pair, the fields evaluated on the producing side.
M.RENDER_CALL = M.template(M.node('function_call', M.node('identifier', M.lit 'render'),
    M.node('arguments', M.lit '(', M.node('string', M.lit "'", M.node('string_content', M.hole 'name'), M.lit "'"), M.lit ',', M.lit ' ',
        M.node('table_constructor', M.lit '{', M.hole('fields', true), M.lit '}'), M.lit ')')))
function M.render_call(name, fields)
    local kids = {}
    local function has_comment(x) if x.k == 'comment' then return true end; for _, c in ipairs(x.kids or {}) do if type(c) == 'table' and has_comment(c) then return true end end; return false end
    for _, f in ipairs(fields) do -- a field is printed on the call's one line: a comment inside it would swallow the rest
        if has_comment(f.value) then return nil, ('render_call: the field %s holds a comment and cannot be inlined'):format(f.key) end
    end
    for i, f in ipairs(fields) do
        kids[#kids + 1] = M.lit(i == 1 and ' ' or ' ')
        kids[#kids + 1] = M.node('field', M.node('identifier', M.lit(f.key)), M.lit ' ', M.lit '=', M.lit ' ', M.copy(f.value))
        if i < #fields then kids[#kids + 1] = M.lit ',' end
    end
    if #fields > 0 then kids[#kids + 1] = M.lit ' ' end
    local r = M.instantiate(M.RENDER_CALL, { name = M.lit(name), fields = M.seq(kids) })
    if not r.ok then return nil, 'render_call: ' .. M.unfold_why(r) end
    return r.term
end
function M.render_call_of(t, env)
    local m = M.match(M.RENDER_CALL, t, env)
    if not m.ok then return nil, m.refusal and m.refusal.why or 'not a render call' end
    local out = { name = tostring(m.values.name.v), fields = {} }
    for _, k in ipairs(m.values.fields.kids) do
        if k.k == 'field' then out.fields[#out.fields + 1] = { key = tostring(k.kids[1].kids[1].v), value = k.kids[#k.kids] } end
    end
    return out
end
--- the move of one expression into a template named `name`: the hbs term with dotted lookups
--- flattened to field keys (the last segment, the segments joined by `_` on a collision, `sN`
--- after that), the fields in source order, the render call. kind and staged are hbs_of's.
function M.move_to_template(expr, name)
    local H = M.hbs_of(expr)
    local taken, flat, fields = {}, {}, {}
    for _, e in ipairs(H.staged) do taken[e.name] = true end
    for _, pth in ipairs(H.lookups) do
        local cand = pth:match('([%w_]+)$')
        if taken[cand] then cand = pth:gsub('%.', '_') end
        local n = 0
        while taken[cand] do n = n + 1; cand = 's' .. n end
        taken[cand] = true
        flat[pth] = cand
    end
    local function rename(x)
        if x.k == 'raw' or x.k == 'var' then local pth = tostring(x.kids[1].v); if flat[pth] then return M.node(x.k, M.lit(flat[pth])) end; return x end
        if x.k == 'block' then
            local pth = tostring(x.kids[2].v)
            local kids = { x.kids[1], flat[pth] and M.lit(flat[pth]) or x.kids[2] }
            for i = 3, #x.kids do kids[i] = rename(x.kids[i]) end
            return M.node(x.k, unpack(kids))
        end
        if x.kids and x.k ~= 'lit' then local kids = {}; for i, c in ipairs(x.kids) do kids[i] = rename(c) end; return M.node(x.k, unpack(kids)) end
        return x
    end
    local tpl = rename(H.term)
    -- the fields in the order their lookups and computations appear in the template
    local order, seen = {}, {}
    local function collect(x)
        if x.k == 'raw' or x.k == 'var' then local nm = tostring(x.kids[1].v); if not seen[nm] then seen[nm] = true; order[#order + 1] = nm end end
        if x.k == 'block' then local nm = tostring(x.kids[2].v); if not seen[nm] then seen[nm] = true; order[#order + 1] = nm end end
        for _, c in ipairs(x.kids or {}) do if type(c) == 'table' and c.k ~= 'lit' then collect(c) end end
    end
    collect(tpl)
    local by_name = {}
    for pth, f in pairs(flat) do by_name[f] = { key = f, value = H.lookup_nodes[pth], path = pth } end
    for _, e in ipairs(H.staged) do by_name[e.name] = { key = e.name, value = e.node, staged = e } end
    for _, nm in ipairs(order) do if by_name[nm] then fields[#fields + 1] = by_name[nm] end end
    local call, why = M.render_call(name, fields)
    if not call then return nil, why end
    return { template = tpl, text = M.grammars.hbs.print(tpl), call = call, fields = fields, kind = H.kind, staged = H.staged, lookups = H.lookups, name = name }
end
--- the sample law on the moved pair: the expression against the template rendered on the data
--- the render call's fields produce under the same environment
function M.move_law(mv, expr, opts)
    opts = opts or {}
    local paths, seen = {}, {}
    for _, f in ipairs(mv.fields) do
        local refs = f.path and { f.path } or (f.staged and f.staged.refs or {})
        for _, pth in ipairs(refs) do if not seen[pth] then seen[pth] = true; paths[#paths + 1] = pth end end
    end
    local iterated = {}
    local function walk(x) if x.k == 'block' and x.kids[1].v == 'each' then iterated[x.kids[2].v] = true end; for _, c in ipairs(x.kids or {}) do if type(c) == 'table' and c.k ~= 'lit' then walk(c) end end end
    walk(mv.template)
    local scalars = { 'x', 'a&b<c>', '', 7, 0, nil }
    local listsamples = { { 'a', 'b' }, {}, { 'x' } }
    local tried, agree, bad = 0, 0, {}
    for si = 1, (opts.samples or 6) do
        local env = {}
        for _, path in ipairs(paths) do
            local segs = {}
            for seg in path:gmatch('[^.]+') do segs[#segs + 1] = seg end
            local cur = env
            for i = 1, #segs - 1 do if type(cur[segs[i]]) ~= 'table' then cur[segs[i]] = {} end; cur = cur[segs[i]] end
            local flatname
            for _, f in ipairs(mv.fields) do if f.path == path then flatname = f.key end end
            if type(cur[segs[#segs]]) ~= 'table' then cur[segs[#segs]] = (flatname and iterated[flatname]) and listsamples[(si - 1) % #listsamples + 1] or scalars[si] end
        end
        local meta = setmetatable(env, { __index = _G })
        local f = loadstring('return ' .. expr)
        if f then
            setfenv(f, meta)
            local ok, v = pcall(f)
            if ok then
                local data, fields_ok = {}, true
                for _, fd in ipairs(mv.fields) do
                    local g = loadstring('return ' .. M.cst_print(fd.value))
                    if not g then fields_ok = false break end
                    setfenv(g, meta)
                    local ok2, val = pcall(g)
                    if not ok2 then fields_ok = false break end
                    data[fd.key] = val
                end
                if fields_ok then
                    tried = tried + 1
                    local r = M.hbs_render(mv.template, data)
                    if tostring(v) == r then agree = agree + 1 else bad[#bad + 1] = ('sample %d: lua %q, template %q'):format(si, tostring(v), r) end
                end
            end
        end
    end
    return tried, agree, bad
end

--- THE SAMPLE LAW: the Lua expression evaluated under sample data agrees with the generated
--- template rendered on the same data. The round trip proves only syntax; escaping and
--- falsiness live here, so the samples carry an empty string, 0 and a markup-bearing string
--- beside a plain one, and a lookup iterated by `#each` takes list samples (a list, an empty
--- list, one element). A sample the Lua side cannot evaluate (a nil operand) is not tried.
--- The sixth sample is a MISSING value (nil), where Lua's `%s` prints "nil" and a template
--- renders nothing: a claim that holds on the five defined samples and not on the sixth is
--- as-is under the precondition that the value is present; `opts.samples = 5` asks for the
--- defined samples only. Returns tried, agreed, and the disagreements.
function M.hbs_sample_law(H, expr, opts)
    opts = opts or {}
    local iterated = {}
    local function walk(x) if x.k == 'block' and x.kids[1].v == 'each' then iterated[x.kids[2].v] = true end; for _, c in ipairs(x.kids or {}) do if type(c) == 'table' and c.k ~= 'lit' then walk(c) end end end
    walk(H.term)
    local scalars = { 'x', 'a&b<c>', '', 7, 0, nil }
    local listsamples = { { 'a', 'b' }, {}, { 'x' } }
    -- the paths the expression reads: the template's lookups and what its staged computations read
    local paths, seen = {}, {}
    for _, pth in ipairs(H.lookups) do if not seen[pth] then seen[pth] = true; paths[#paths + 1] = pth end end
    for _, e in ipairs(H.staged or {}) do for _, pth in ipairs(e.refs or {}) do if not seen[pth] then seen[pth] = true; paths[#paths + 1] = pth end end end
    local tried, agree, bad = 0, 0, {}
    for si = 1, (opts.samples or 6) do -- opts.samples = 5 leaves the missing value out
        local env = {}
        for _, path in ipairs(paths) do
            local segs = {}
            for seg in path:gmatch('[^.]+') do segs[#segs + 1] = seg end
            local cur = env -- every path the expression reads is data here, callees excluded by paths_in
            for i = 1, #segs - 1 do
                if type(cur[segs[i]]) ~= 'table' then cur[segs[i]] = {} end -- a deeper path wins over a scalar at its prefix
                cur = cur[segs[i]]
            end
            if type(cur[segs[#segs]]) ~= 'table' then cur[segs[#segs]] = iterated[path] and listsamples[(si - 1) % #listsamples + 1] or scalars[si] end
        end
        local meta = setmetatable(env, { __index = _G })
        local f = loadstring('return ' .. expr)
        if f then
            setfenv(f, meta)
            local ok, v = pcall(f)
            if ok then
                -- the producing side: every staged computation evaluated under the same environment
                local data, staged_ok = {}, true
                for k2, v2 in pairs(env) do data[k2] = v2 end
                for _, e in ipairs(H.staged or {}) do
                    local g = loadstring('return ' .. e.text)
                    if not g then staged_ok = false break end
                    setfenv(g, meta)
                    local ok2, val = pcall(g)
                    if not ok2 then staged_ok = false break end
                    data[e.name] = val
                end
                if staged_ok then
                    tried = tried + 1
                    local r = M.hbs_render(H.term, data)
                    if tostring(v) == r then agree = agree + 1 else bad[#bad + 1] = ('sample %d: lua %q, template %q'):format(si, tostring(v), r) end
                end
            end
        end
    end
    return tried, agree, bad
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

local function ax(theory, t) return (theory and t and t.kids and theory[t.k]) or nil end
local function isA(theory, t) local a = ax(theory, t); return a and a.A end

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
local function absence(name, at, why, extra)
    assert(M.ABSENCE[name], 'undeclared absence: ' .. tostring(name)) -- CART-0831: the set is a table
    local a = { absence = name, at = at, why = why, licenses = M.ABSENCE[name].licenses }
    for k, v in pairs(extra or {}) do a[k] = v end
    return a
end
local function prefix_of(p, q) -- p ancestor-or-equal of q
    if #p > #q then return false end
    for i = 1, #p do if p[i] ~= q[i] then return false end end
    return true
end

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
    local v = M.track(task, fetch)
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

local function occurs(h, t)
    if is_hole(t) then return t.h == h end
    for _, c in ipairs(t.kids or {}) do if occurs(h, c) then return true end end
    return false
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
    local truncated = false
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
local function cat_lists(...) -- concatenation of several lists (the pairwise `cat` above is no longer shadowed)
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


local function below(x, y) return is_strict_prefix(y, x) end -- x proper descendant of y
local function same(p, q) return key(p) == key(q) end
local function no_ancestors(a, b, c)
    return not (prefix_eq(a, b) or prefix_eq(b, a) or prefix_eq(a, c) or prefix_eq(c, a)
        or prefix_eq(b, c) or prefix_eq(c, b))
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
M.kv_kind = kv_kind -- CART-1041: `kv_classify` (classify.lua) reads the same kinds
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

-- ── SURGERY: the sheet's byte ranges and the hunks an edit makes (SURGERY.md) ─────────
-- Toomim, Begel, Graham 2004 (linked editing): linked clones share "blue" regions that
-- stay identical under a simultaneous edit and "yellow" differences a single-clone edit
-- adds to. Here the blue part is the template's fixed part and the yellow the holes; the
-- surgery an edit makes on a member is read off two unfoldings of that member, before and
-- after: `spans` says where every position lies in the printed sheet, a positional
-- refinement finds the smallest changed regions, and `trace` says whether each came from
-- the fixed part (a simultaneous edit, every member gets it) or from a hole (one member's
-- own). Spans are under `cst_print`, leaf concatenation, the `lua` grammar's print.

--- byte span of every position of t under cst_print: { [key(path)] = { from, to } },
--- 1-based and inclusive, an empty node having to = from - 1. Second result: the text.
function M.spans(t)
    local out, buf, pos = {}, {}, 0
    local function walk(x, path)
        local from = pos + 1
        if x.k == 'lit' then local s = tostring(x.v); buf[#buf + 1] = s; pos = pos + #s
        elseif x.k == 'name' then local s = tostring(x.n); buf[#buf + 1] = s; pos = pos + #s
        elseif is_hole(x) then error('spans: unfilled hole ' .. tostring(x.h))
        else for i, c in ipairs(x.kids or {}) do walk(c, child(path, i)) end end
        out[key(path)] = { from = from, to = pos }
    end
    walk(t, {})
    return out, table.concat(buf)
end

local function covers(p, q) -- p a prefix of q, equality included
    if #p > #q then return false end
    for i = 1, #p do if p[i] ~= q[i] then return false end end
    return true
end

--- the smallest positional hunks between two terms a and b at paths pa and pb: the kids
--- common to both lists (their LCS under eq) are the anchors, a run of equal length between
--- two anchors is refined kid by kid, an unequal run is one hunk (an insertion or a
--- deletion when one side of it is empty). Exported so the re-derivation pass can replace it.
function M.refine_hunks(a, b, pa, pb, S1, X1, S2, X2, out)
    if M.eq(a, b) then return end
    if a.kids and b.kids and a.k == b.k then
        local na, nb = #a.kids, #b.kids
        local anchors = M.lcs(a.kids, b.kids)
        anchors[#anchors + 1] = { na + 1, nb + 1 }
        local i, j = 1, 1
        for _, an in ipairs(anchors) do
            local ra, rb = an[1] - i, an[2] - j -- the runs before this anchor
            if ra == rb then
                for d = 0, ra - 1 do M.refine_hunks(a.kids[i + d], b.kids[j + d], child(pa, i + d), child(pb, j + d), S1, X1, S2, X2, out) end
            else
                local from = ra > 0 and S1[key(child(pa, i))].from or (i > 1 and S1[key(child(pa, i - 1))].to + 1 or S1[key(pa)].from)
                local to = ra > 0 and S1[key(child(pa, an[1] - 1))].to or from - 1
                local nfrom = rb > 0 and S2[key(child(pb, j))].from or (j > 1 and S2[key(child(pb, j - 1))].to + 1 or S2[key(pb)].from)
                local nto = rb > 0 and S2[key(child(pb, an[2] - 1))].to or nfrom - 1
                out[#out + 1] = { from = from, to = to, old = X1:sub(from, to), new = X2:sub(nfrom, nto),
                    at = pa, kids = { i, an[1] - 1 }, at2 = pb, kids2 = { j, an[2] - 1 } }
            end
            i, j = an[1] + 1, an[2] + 1
        end
        return
    end
    local sa, sb = S1[key(pa)], S2[key(pb)]
    out[#out + 1] = { from = sa.from, to = sa.to, old = X1:sub(sa.from, sa.to), new = X2:sub(sb.from, sb.to), at = pa, at2 = pb }
end

--- one sentence for a refused unfolding (instantiate's record has no `why` of its own)
function M.unfold_why(r)
    if r.why then return tostring(r.why) end
    local parts = {}
    if r.unfilled and #r.unfilled > 0 then parts[#parts + 1] = 'unfilled ' .. table.concat(r.unfilled, ',') end
    if r.rejected and #r.rejected > 0 then parts[#parts + 1] = 'rejected ' .. table.concat(r.rejected, '; ') end
    if r.extra and #r.extra > 0 then parts[#parts + 1] = 'extra ' .. table.concat(r.extra, ',') end
    return #parts > 0 and table.concat(parts, '; ') or 'refused'
end

--- the surgery on one member: the hunks that turn instantiate(T, V) into instantiate(T2, V2)
--- (T2 defaults to T, V2 to V), each with `from`, `to`, `old`, `new` in the member's own
--- bytes and its attribution: src = 'template' (a fixed position: the edit reaches every
--- member; `edit` is the index in T2.edits of the rewrite whose region holds it) or
--- src = 'value' with `hole` (this member's own). Returns the list sorted by position and
--- the member's new text; nil and why when either side does not unfold.
function M.hunks(T, V, T2, V2, env)
    T2 = T2 or T; V2 = V2 or V
    local r1 = M.trace(T, V, env); if not r1.ok then return nil, 'before: ' .. M.unfold_why(r1) end
    local r2 = M.trace(T2, V2, env); if not r2.ok then return nil, 'after: ' .. M.unfold_why(r2) end
    local S1, X1 = M.spans(r1.term)
    local S2, X2 = M.spans(r2.term)
    local out = {}
    M.refine_hunks(r1.term, r2.term, {}, {}, S1, X1, S2, X2, out)
    local n1 = #(T.edits or {})
    local function hole_on(body, path) -- the hole a template path lies at or under, if any
        local t = body
        if is_hole(t) then return t.h end
        for _, s in ipairs(path) do
            t = t.kids and t.kids[s]
            if not t then return nil end
            if is_hole(t) then return t.h end
        end
        return nil
    end
    local function attribute(h)
        -- the old text's origin, and the new text's; a hole on either side makes the hunk
        -- this member's own (a value edit, or a dug region this member changed)
        local o1, o2
        if h.kids then
            if h.kids[2] >= h.kids[1] then o1 = r1.origins[key(child(h.at, h.kids[1]))] end
            if h.kids2[2] >= h.kids2[1] then o2 = r2.origins[key(child(h.at2, h.kids2[1]))] end
        else o1, o2 = r1.origins[key(h.at)], r2.origins[key(h.at2)] end
        local hole = (o1 and o1.src == 'hole' and o1.hole) or (o2 and o2.src == 'hole' and o2.hole)
        local before = o1 and o1.src == 'fixed' and o1.at or nil -- a template path in T's coordinates
        local after = o2 and o2.src == 'fixed' and o2.at or nil  -- and in T2's, where the edits' paths live
        if not hole and (after or before) then hole = hole_on(T2.body, after or before) or (before and hole_on(T.body, before)) or nil end
        if hole then h.src = 'value'; h.hole = hole
        elseif after or before then h.src = 'template'
        else h.src = 'unknown' end
        if after or before then
            for k = n1 + 1, #(T2.edits or {}) do -- the last edit whose region holds the position
                local op = T2.edits[k]
                if op.path and covers(op.path, after or before) then h.edit = k end
            end
        end
    end
    for _, h in ipairs(out) do attribute(h) end
    table.sort(out, function(a, b) return a.from < b.from end)
    return out, X2
end

--- apply hunks to a text, from the end backwards; a hunk whose recorded old text is not
--- what the sheet holds refuses by name (the sheet moved under the plan), as do overlaps.
function M.apply_hunks(text, hunks)
    local hs = {}
    for i, h in ipairs(hunks) do hs[i] = h end
    table.sort(hs, function(a, b) return a.from > b.from end)
    local last_from
    for _, h in ipairs(hs) do
        if last_from and h.to >= last_from then return nil, ('hunk %d..%d overlaps the one after it'):format(h.from, h.to) end
        last_from = h.from
        local found = text:sub(h.from, h.to)
        if found ~= h.old then return nil, ('hunk %d..%d: expected %q, the sheet holds %q'):format(h.from, h.to, h.old, found) end
        text = text:sub(1, h.from - 1) .. h.new .. text:sub(h.to + 1)
    end
    return text
end

--- the same hunks moved by delta bytes: a member's hunks in the coordinates of the file it
--- sits in (delta = the member's span start in the file, minus one)
function M.shift_hunks(hunks, delta)
    local out = {}
    for i, h in ipairs(hunks) do
        local g = {}
        for k, v in pairs(h) do g[k] = v end
        g.from, g.to = h.from + delta, h.to + delta
        out[i] = g
    end
    return out
end

-- ── EXTRACT: a family's template becomes a helper, its values the calls (LOOP.md; Fowler,
-- Extract Function, the catalog page's example only) ───────────────────────────────────
--- The fold's description length made program text: the template once as a helper whose
--- parameters stand where the holes stood, and each member as a call passing its own values.
--- `extract(T, opts)` takes a family whose body is a `function_definition` and gives the
--- HELPER term (`local function <name>(<params>) return <body'> end`, the body reindented by
--- `opts.reindent`) and the CALL template (`<name>(<arg1>, ..)`), whose holes are T's own, so a
--- member's call is `instantiate(call, V)` with the SAME value map. Each hole is lifted at
--- the nearest node the destination can pass as a value; the rules for lua:
---   string   a hole in `string_content` under `string`: the string is the argument as it stands
---   field    a hole naming the field of `a.<h>`: the index becomes `a[<param>]` and the
---            argument is the name quoted, `'<h>'`
---   number   a hole that is a `number`'s text: the number is the argument
--- A hole that names a variable, a hedge, or any other position is refused by name: passing a
--- variable would evaluate it at the call, not inside the function. Conservation: every hole of
--- T has exactly one site in the call template, and the helper mentions the hole's parameter at
--- the hole's former lift site. `extract_call(X, V)` is the guarded writer for one member: the
--- values must be literals (the call is evaluated where the callback was written, the
--- callback's own code runs unchanged), and the reader verifies the writer (a match reads the
--- values back). `extract_call_of(X, t)` is that inverse alone.
M.EXTRACT_RULES = {
    lua = {
        -- rule name -> given the hole's ancestors (nearest first), the lift: { at = depth, replace = fn(node, param), arg = fn(node, h) }
        string = { test = function(anc) return anc[1] and anc[1].k == 'string_content' and anc[2] and anc[2].k == 'string' end,
            depth = 2, replace = function(_, p) return M.node('identifier', M.lit(p)) end,
            arg = function(n) return M.copy(n) end },
        field = { test = function(anc, idx) return anc[1] and anc[1].k == 'identifier' and anc[2] and anc[2].k == 'dot_index_expression' and idx[2] == #anc[2].kids end,
            depth = 2, replace = function(n, p)
                local kids = { M.copy(n.kids[1]), M.lit '[', M.node('identifier', M.lit(p)), M.lit ']' }
                return M.node('bracket_index_expression', unpack(kids))
            end,
            arg = function(n, h) return M.node('string', M.lit "'", M.node('string_content', M.hole(h)), M.lit "'") end },
        number = { test = function(anc) return anc[1] and anc[1].k == 'number' end,
            depth = 1, replace = function(_, p) return M.node('identifier', M.lit(p)) end,
            arg = function(n) return M.copy(n) end },
        variable = { test = function(anc) return anc[1] and anc[1].k == 'identifier' end, refuse = 'names a variable; its binding is the function\'s own, not a value' },
    },
}
--- reindent a term's own newlines (the whitespace lits outside strings and comments) by `by`
function M.reindent(t, by)
    if by == nil or by == '' then return t end
    local function go(x, inside)
        if type(x) ~= 'table' then return x end
        if x.k == 'lit' then
            if inside or type(x.v) ~= 'string' or not x.v:find('\n', 1, true) then return x end
            return M.lit((x.v:gsub('\n', '\n' .. by)))
        end
        if x.k == 'hole' or not x.kids then return x end
        local kids = {}
        local inner = inside or x.k == 'string' or x.k == 'comment'
        for i, c in ipairs(x.kids) do kids[i] = go(c, inner) end
        return M.rebuild(x, kids)
    end
    return go(t, false)
end
function M.extract(T, opts)
    opts = opts or {}
    local rules = M.EXTRACT_RULES[opts.lang or 'lua']
    if not rules then return nil, 'extract: no lift rules for ' .. tostring(opts.lang) end
    local name = opts.name or 'extracted'
    if T.body.k ~= 'function_definition' then return nil, 'extract: the template is a ' .. tostring(T.body.k) .. ', not a function_definition' end
    local S = M.sites(T)
    local order = M.hole_names(T)
    local lifts, params = {}, {}
    for i, h in ipairs(order) do
        local e = S[h]
        if e.rep then return nil, 'extract: hole ' .. h .. ' is a hedge; a sequence is not one value' end
        if e.ctx then return nil, 'extract: hole ' .. h .. ' is a context hole' end
        local p = (opts.params and opts.params[h]) or ('p' .. i)
        params[#params + 1] = { hole = h, param = p }
        local arg_shown
        for _, site in ipairs(e.sites) do
            -- the ancestors of the site, nearest first, and the index each holds in its parent
            local anc, idx, t = {}, {}, T.body
            local chain = { t }
            for _, s in ipairs(site.path) do t = t.kids[s]; chain[#chain + 1] = t end
            for k = #chain - 1, 1, -1 do anc[#anc + 1] = chain[k]; idx[#idx + 1] = site.path[k] end
            -- a lifting rule first; a refusing rule speaks only when no lift applies (an
            -- identifier under a dot index is a field, not a variable)
            local hit, rname
            for rn, r in pairs(rules) do if not r.refuse and r.test(anc, idx) then hit, rname = r, rn end end
            if not hit then for rn, r in pairs(rules) do if r.refuse and r.test(anc, idx) then hit, rname = r, rn end end end
            if not hit then return nil, ('extract: hole %s at %s: no lift rule for a %s'):format(h, key(site.path), tostring(anc[1] and anc[1].k)) end
            if hit.refuse then return nil, ('extract: hole %s at %s %s'):format(h, key(site.path), hit.refuse) end
            local at = { unpack(site.path, 1, #site.path - hit.depth) }
            local node = anc[hit.depth]
            local arg = hit.arg(node, h)
            if arg_shown and arg_shown ~= M.show(arg) then return nil, ('extract: hole %s is lifted two ways (%s / %s)'):format(h, arg_shown, M.show(arg)) end
            arg_shown = M.show(arg)
            lifts[#lifts + 1] = { hole = h, param = p, at = at, rule = rname, arg = arg, lift = hit }
        end
    end
    -- the helper: the lifts applied deepest first so shallower paths stay valid
    table.sort(lifts, function(a, b) if #a.at ~= #b.at then return #a.at > #b.at end; return key(a.at) > key(b.at) end)
    local body = M.copy(T.body)
    for _, l in ipairs(lifts) do -- the node as it stands after the deeper lifts (a field's object may hold another hole)
        local node = at(body, l.at)
        l.replace = l.lift.replace(node, l.param); l.lift = nil
        body = set_at(body, l.at, M.copy(l.replace))
    end
    body = M.reindent(body, opts.reindent)
    local ind = opts.indent or ''
    local pk = { M.lit '(' }
    for i, pr in ipairs(params) do
        if i > 1 then pk[#pk + 1] = M.lit ','; pk[#pk + 1] = M.lit ' ' end
        pk[#pk + 1] = M.node('identifier', M.lit(pr.param))
    end
    pk[#pk + 1] = M.lit ')'
    local helper = M.node('function_declaration', M.lit 'local', M.lit ' ', M.lit 'function', M.lit ' ', M.node('identifier', M.lit(name)),
        M.node('parameters', unpack(pk)), M.lit('\n' .. ind .. '    '),
        M.node('block', M.node('return_statement', M.lit 'return', M.lit ' ', M.node('expression_list', body))), M.lit('\n' .. ind), M.lit 'end')
    -- the call template: the arguments in parameter order, each carrying its hole
    local ak = { M.lit '(' }
    local by_hole = {}
    for _, l in ipairs(lifts) do by_hole[l.hole] = l.arg end
    for i, pr in ipairs(params) do
        if i > 1 then ak[#ak + 1] = M.lit ','; ak[#ak + 1] = M.lit ' ' end
        ak[#ak + 1] = M.copy(by_hole[pr.hole])
    end
    ak[#ak + 1] = M.lit ')'
    local call = M.template(M.node('function_call', M.node('identifier', M.lit(name)), M.node('arguments', unpack(ak))), T.holes)
    -- conservation: T's holes, each once, in the call
    local CS = M.sites(call)
    for _, h in ipairs(order) do if not CS[h] or #CS[h].sites ~= 1 then return nil, 'extract: hole ' .. h .. ' is not passed exactly once' end end
    for h in pairs(CS) do if not S[h] then return nil, 'extract: the call mentions a hole the template lacks: ' .. h end end
    return { helper = helper, call = call, params = params, lifts = lifts, name = name, from = T }
end
--- one member's call, guarded: every value a literal, the writer verified by the reader
function M.extract_call(X, V, env)
    for _, pr in ipairs(X.params) do
        local v = V[pr.hole]
        if v == nil then return { ok = false, absence = 'absent', why = 'extract_call: no value for hole ' .. pr.hole } end
        if v.k ~= 'lit' then return { ok = false, absence = 'refused', why = ('extract_call: hole %s: the value %s is not a literal; the call would evaluate it where the callback was written'):format(pr.hole, M.show(v)) } end
    end
    local r = M.instantiate(X.call, V, env)
    if not r.ok then return { ok = false, absence = M.absence_of(r).absence, why = 'extract_call: ' .. M.unfold_why(r) } end
    local m = M.match(X.call, r.term, env)
    if not m.ok then return { ok = false, absence = 'refused', why = 'extract_call: the reader does not verify the writer: ' .. m.refusal.why } end
    for _, pr in ipairs(X.params) do
        if not M.eq(m.values[pr.hole], V[pr.hole]) then return { ok = false, absence = 'refused', why = 'extract_call: the reader reads back a different value at ' .. pr.hole } end
    end
    return { ok = true, term = r.term, verified = true }
end
function M.extract_call_of(X, t, env)
    local m = M.match(X.call, t, env)
    if not m.ok then return nil, m.refusal and m.refusal.why or 'not a call of ' .. X.name end
    return m.values
end

-- ── DESTINATIONS: where a moved text may go, ranked (DESTINATION.md; Tsantalis and
-- Chatzigeorgiou, IEEE TSE 2009, Move Method identification) ──────────────────────────
--- The names a Lua term reads, binds and assigns, read off the tree: a FLAT approximation
--- (no shadowing, `local x = x` counts x as both). Binds: parameters, `local` variable
--- lists, `local function` names, for-clause variables. Not reads: the field after `.` or
--- `:`, a table field's key, a bind. Assigns: the variable list of an assignment that is
--- not a declaration. `free` is reads minus binds. `requires` lists the literal modules.
M.SCOPE_RULES = { lua = { library = { vim = true, require = true, pairs = true, ipairs = true, type = true, tostring = true, tonumber = true,
    table = true, string = true, math = true, os = true, io = true, error = true, assert = true, pcall = true, xpcall = true, select = true,
    setmetatable = true, getmetatable = true, next = true, unpack = true, rawget = true, rawset = true, rawequal = true, rawlen = true, print = true, _G = true,
    debug = true, package = true, load = true, loadstring = true, loadfile = true, dofile = true, setfenv = true, getfenv = true, jit = true,
    collectgarbage = true, coroutine = true, bit = true, arg = true, _VERSION = true, _ENV = true } } }
function M.lua_names(t)
    local out = { reads = {}, binds = {}, assigns = {}, requires = {}, order = {} }
    local function ident(x) return type(x) == 'table' and x.k == 'identifier' and x.kids and type(x.kids[1]) == 'table' and x.kids[1].k == 'lit' and tostring(x.kids[1].v) or nil end
    local function bind(x) local nm = ident(x); if nm then out.binds[nm] = true end end
    local function walk(x, role)
        if type(x) ~= 'table' or x.k == 'lit' or x.k == 'hole' then return end
        if x.k == 'identifier' then
            local nm = ident(x)
            if nm then
                if role == 'bind' then out.binds[nm] = true
                elseif role == 'assign' then out.assigns[nm] = true; out.reads[nm] = true
                elseif role ~= 'field' then if not out.reads[nm] then out.order[#out.order + 1] = nm end; out.reads[nm] = true end
            end
            return
        end
        if x.k == 'function_call' then
            local callee = x.kids[1]
            local args
            for i = 2, #x.kids do if type(x.kids[i]) == 'table' and x.kids[i].k ~= 'lit' then args = x.kids[i]; break end end -- `require 'x'` keeps a space lit before the string
            if ident(callee) == 'require' and args and (args.k == 'arguments' or args.k == 'string') then
                local strs = args.k == 'string' and { args } or args.kids
                for _, a in ipairs(strs) do if type(a) == 'table' and a.k == 'string' then
                    for _, c in ipairs(a.kids) do if type(c) == 'table' and c.k == 'string_content' and type(c.kids[1]) == 'table' and c.kids[1].k == 'lit' then out.requires[#out.requires + 1] = tostring(c.kids[1].v) end end
                end end
            end
        end
        if x.k == 'parameters' then for _, c in ipairs(x.kids) do walk(c, 'bind') end; return end
        if x.k == 'variable_declaration' then
            for _, c in ipairs(x.kids) do
                if type(c) == 'table' and c.k == 'assignment_statement' then
                    for _, d in ipairs(c.kids) do if type(d) == 'table' and d.k == 'variable_list' then walk(d, 'bind') else walk(d, role) end end
                elseif type(c) == 'table' and c.k == 'variable_list' then walk(c, 'bind')
                else walk(c, role) end
            end
            return
        end
        if x.k == 'assignment_statement' then
            for _, d in ipairs(x.kids) do if type(d) == 'table' and d.k == 'variable_list' then walk(d, 'assign') else walk(d, role) end end
            return
        end
        if x.k == 'function_declaration' then
            local is_local = type(x.kids[1]) == 'table' and x.kids[1].k == 'lit' and x.kids[1].v == 'local'
            local seen_name = false
            for _, c in ipairs(x.kids) do
                if type(c) == 'table' and c.k == 'identifier' and not seen_name then seen_name = true; if is_local then bind(c) else out.assigns[ident(c)] = true; out.reads[ident(c)] = true end
                else walk(c, role) end
            end
            return
        end
        if x.k == 'for_numeric_clause' or x.k == 'for_generic_clause' then
            local before = true
            for _, c in ipairs(x.kids) do
                if type(c) == 'table' and c.k == 'lit' and (c.v == '=' or c.v == 'in') then before = false
                elseif before then walk(c, 'bind') else walk(c, role) end
            end
            return
        end
        if x.k == 'dot_index_expression' or x.k == 'method_index_expression' then
            walk(x.kids[1], role)
            for i = 2, #x.kids do walk(x.kids[i], 'field') end
            return
        end
        if x.k == 'field' then
            -- `key = value`: the key is not a read; `[expr] = value` and a bare value are
            local kids = x.kids
            if type(kids[1]) == 'table' and kids[1].k == 'identifier' and #kids >= 3 then
                for i = 2, #kids do walk(kids[i], role) end
            else for _, c in ipairs(kids) do walk(c, role) end end
            return
        end
        for _, c in ipairs(x.kids or {}) do walk(c, role) end
    end
    walk(t, nil)
    out.free = {}
    for nm in pairs(out.reads) do if not out.binds[nm] then out.free[nm] = true end end
    return out
end
--- the names a Lua block binds in ITS OWN scope: its `local` declarations and `local function`
--- names, not the binds inside nested functions (the home's entities, DESTINATION.md)
function M.lua_scope_binds(block)
    local B = {}
    local function ident(x) return type(x) == 'table' and x.k == 'identifier' and x.kids and type(x.kids[1]) == 'table' and x.kids[1].k == 'lit' and tostring(x.kids[1].v) or nil end
    local function stmt(c)
        if type(c) ~= 'table' then return end
        if c.k == 'variable_declaration' then
            local function vl(x)
                if type(x) ~= 'table' then return end
                if x.k == 'variable_list' then for _, v in ipairs(x.kids) do local nm = ident(v); if nm then B[nm] = true end end return end
                if x.k == 'assignment_statement' then for _, d in ipairs(x.kids) do vl(d) end end
            end
            for _, d in ipairs(c.kids) do vl(d) end
        elseif c.k == 'function_declaration' and type(c.kids[1]) == 'table' and c.kids[1].k == 'lit' and c.kids[1].v == 'local' then
            for _, d in ipairs(c.kids) do local nm = ident(d); if nm then B[nm] = true; break end end
        end
    end
    if block.k == 'variable_declaration' or block.k == 'function_declaration' then stmt(block) else for _, c in ipairs(block.kids or {}) do stmt(c) end end
    return B
end
--- the set operations the ranking needs
local function set_count(S) local n = 0; for _ in pairs(S) do n = n + 1 end; return n end
local function set_inter(A_, B_) local r = {}; for k in pairs(A_) do if B_[k] then r[k] = true end end; return r end
local function set_union(A_, B_) local r = {}; for k in pairs(A_) do r[k] = true end; for k in pairs(B_) do r[k] = true end; return r end
local function set_list(S) local r = {}; for k in pairs(S) do r[#r + 1] = k end; table.sort(r); return r end
function M.jaccard_distance(A_, B_)
    local u = set_count(set_union(A_, B_))
    if u == 0 then return 0 end
    return 1 - set_count(set_inter(A_, B_)) / u
end
--- Where a moved text may go: the paper's algorithm (§3.3) over declared inputs, with its
--- preconditions (§3.2) as refusals by name.
---   m     = { name, entities = set, free = set, calls = { { home = id }, .. }, assigns = set }
---           entities: the system entities the text accesses (library names removed here);
---           free: every name that must be bound at the destination; calls: where each call is.
---   homes = { { id, entities = set, bound = set, reach = set of home ids visible from here
---              (default: itself), plumbing = cost to become visible everywhere (nil: cannot),
---              copies = n (a composite home: one copy per member home), holds = bool (the
---              text already belongs here: Definition 2) }, .. }
---   opts  = { helper_cost, call_extra (per call per parameterized name), parameterize, all }
--- Step 1: the candidate targets are the homes holding an entity the text accesses (with
--- `all`, every home, marked `provenance = 'prototype'`). Step 2: sorted by accessed
--- entities descending, then Jaccard distance ascending (the smaller home first on a tie,
--- which the paper wants). Step 3, modifies-a-data-structure, has no reading here and is not
--- modelled. Step 4: the suggestion is the first candidate passing the preconditions, ties
--- all suggested. Preconditions: compilation, a local of the same name at the target refuses;
--- behaviour, every call must reach the text (visible, or visible after plumbing at its
--- cost; a free name not bound at the target refuses unless `parameterize`, which passes it
--- at a cost per call); quality, a text that assigns an outer name refuses everywhere.
--- The PRICE beside the paper's order: helper_cost per copy plus plumbing plus the per-call
--- extra; `by_price` is the same candidates in that order, the prototype's own knob.
function M.destinations(m, homes, opts)
    opts = opts or {}
    local helper_cost, call_extra = opts.helper_cost or 1, opts.call_extra or 1
    local ent = {}
    local lib = (M.SCOPE_RULES[opts.lang or 'lua'] or {}).library or {}
    for k in pairs(m.entities or {}) do if not lib[k] then ent[k] = true end end
    local out = { candidates = {}, suggested = {}, by_price = {} }
    if m.assigns and next(m.assigns) then
        local a = set_list(m.assigns)
        out.refused_all = 'the text assigns an outer name (' .. table.concat(a, ', ') .. '): quality precondition 1'
    end
    for _, h in ipairs(homes) do
        local acc = set_count(set_inter(ent, h.entities or {}))
        if acc > 0 or opts.all then
            local S = h.entities or {}
            if h.holds then S = {}; for k in pairs(h.entities or {}) do if k ~= m.name then S[k] = true end end end
            local c = { id = h.id, acc = acc, distance = M.jaccard_distance(ent, S), provenance = acc > 0 and 'paper' or 'prototype', cost = helper_cost * (h.copies or 1), copies = h.copies or 1, why = {} }
            -- compilation: no local of that name at the target
            if m.name and (h.bound or {})[m.name] then c.why[#c.why + 1] = ('a local %s is already bound at %s'):format(m.name, h.id) end
            -- behaviour: every free name bound, or passed
            local unbound = {}
            for k in pairs(m.free or {}) do if not lib[k] and not (h.bound or {})[k] then unbound[#unbound + 1] = k end end
            table.sort(unbound)
            if #unbound > 0 then
                if opts.parameterize then c.parameterized = unbound; c.cost = c.cost + #unbound * call_extra * #(m.calls or {})
                else c.why[#c.why + 1] = ('%s not bound at %s'):format(table.concat(unbound, ', '), h.id) end
            end
            -- behaviour: every call reaches the text
            local reach = h.reach or { [h.id] = true }
            local far = {}
            for _, call in ipairs(m.calls or {}) do if not reach[call.home] then far[call.home] = true end end
            if next(far) then
                if h.plumbing then c.cost = c.cost + h.plumbing; c.after_plumbing = set_list(far)
                else c.why[#c.why + 1] = ('not visible from the call in %s'):format(table.concat(set_list(far), ', ')) end
            end
            if out.refused_all then c.why[#c.why + 1] = out.refused_all end
            c.ok = #c.why == 0
            out.candidates[#out.candidates + 1] = c
        end
    end
    -- the paper's order (step 2) and the price: two declared orders over one preference primitive
    local paper = M.then_(M.by(function(c) return c.acc end, true), M.by(function(c) return c.distance end))
    local price = M.by(function(c) return c.cost end)
    table.sort(out.candidates, function(a, b) if paper(a, b) then return true end; if paper(b, a) then return false end; return a.id < b.id end)
    out.suggested = M.best(out.candidates, paper) -- step 4: the first passing candidate and its ties (the refused are dropped by best)
    table.sort(out.suggested, function(a, b) return a.id < b.id end)
    for _, c in ipairs(out.candidates) do if c.ok then out.by_price[#out.by_price + 1] = c end end
    table.sort(out.by_price, function(a, b) if price(a, b) then return true end; if price(b, a) then return false end; return a.id < b.id end)
    out.cheapest = M.best(out.candidates, price)
    return out
end
--- The positions inside one Lua block where a `local function` may be declared: after the
--- last statement binding a name it needs, before the first statement calling it. The four
--- canonical picks, named before looking: after the last needed binding; after the block's
--- opening run of binding statements; adjacent to the last existing local function in the
--- range; before the first use (a comment directly above the use stays with it). Kid indexes.
function M.lua_positions(block, spec)
    local needs, calls, name = spec.needs or {}, spec.calls or {}, spec.name
    local first_call
    for _, c in ipairs(calls) do if not first_call or c < first_call then first_call = c end end
    if not first_call then return nil, 'lua_positions: no call in the block' end
    local last_need, opening, last_helper, clash = 0, 0, nil, nil
    local in_opening = true
    local before, after = {}, {} -- the needed names bound before the first call, and only after it
    for i, c in ipairs(block.kids) do
        if type(c) == 'table' and c.k ~= 'lit' and c.k ~= 'comment' then
            local B = M.lua_scope_binds(c) -- the statement's own binds, not its callbacks'
            local binds_here = false
            for k in pairs(B) do if needs[k] then binds_here = true; if i < first_call then before[k] = true else after[k] = true end end end
            if binds_here and i < first_call then last_need = i end
            if name and B[name] then clash = i end
            if c.k == 'variable_declaration' and in_opening then opening = i else in_opening = false end
            if c.k == 'function_declaration' and i < first_call then last_helper = i end
        end
    end
    for k in pairs(after) do
        if not before[k] then return nil, ('lua_positions: the call at kid %d precedes the binding of %s it needs'):format(first_call, k) end
    end
    if clash then return nil, ('lua_positions: %s is already bound at kid %d'):format(name, clash) end
    local use_at = first_call - 1
    while use_at > 0 and type(block.kids[use_at]) == 'table' and (block.kids[use_at].k == 'lit' or block.kids[use_at].k == 'comment') do use_at = use_at - 1 end
    local picks = {
        after_needed = last_need,
        after_opening = math.max(opening, last_need),
        with_helpers = (last_helper and last_helper > last_need) and last_helper or nil,
        before_use = use_at,
    }
    return { from = last_need, to = first_call, picks = picks }
end

-- ── PREFERENCE: the best among the admitted (PRIMITIVES.md) ──────────────────────────────
--- The one order primitive the additions were each rolling by hand: given candidates and a
--- strict order `less`, drop the refused (a candidate with `ok == false` or a `why`), and
--- return every candidate no other beats. A SET: two survivors are an ambiguity to the
--- resolver, two suggestions to the ranking; which tie policy applies is the caller's. An
--- order is a declared parameter, like `eq` and `show` and MDL's cost, not something the
--- lattice yields; `lex_order(rank)` builds the stepwise order over label sequences from a
--- rank table (Fig. 2's D < I < P is `lex_order{D=1, I=2, P=3}`), `by(key)` the order of a
--- numeric key, and `then_(a, b)` the lexicographic composition of two orders.
function M.best(cands, less, opts)
    opts = opts or {}
    local pool = {}
    for _, c in ipairs(cands) do
        local refused = type(c) == 'table' and (c.ok == false or (c.why ~= nil and c.ok ~= true))
        if not refused or opts.keep_refused then pool[#pool + 1] = c end
    end
    local out = {}
    for _, c in ipairs(pool) do
        local beaten = false
        for _, d in ipairs(pool) do if d ~= c and less(d, c) then beaten = true; break end end
        if not beaten then out[#out + 1] = c end
    end
    return out
end
function M.lex_order(rank, key)
    key = key or function(x) return x end
    return function(p, q)
        p, q = key(p), key(q)
        for i = 1, math.max(#p, #q) do
            local a, b = p[i], q[i]
            if not a or not b then return false end
            local ra, rb = rank[type(a) == 'table' and a.k or a], rank[type(b) == 'table' and b.k or b]
            if ra ~= rb then return ra < rb end
        end
        return false
    end
end
function M.by(key, desc)
    return function(a, b) local x, y = key(a), key(b); if desc then return x > y end; return x < y end
end
function M.then_(first, second)
    return function(a, b) if first(a, b) then return true end; if first(b, a) then return false end; return second(a, b) end
end

-- ── RESOLVE: scope graphs and resolution paths (RESOLVE.md; Néron, Tolmach, Visser,
-- Wachsmuth, "A Theory of Name Resolution", ESOP 2015) ───────────────────────────────
--- A scope graph (Fig. 1): scopes with at most one parent, each holding declarations (a name,
--- optionally an associated scope), references, and imports (references whose resolution's
--- associated scope becomes reachable). Resolution paths (Fig. 2) are steps D(decl), I(ref,
--- decl) and P; well-formed paths are P*·I*; the specificity order is D < I < P, lexicographic.
--- `resolve` is the algorithm of Fig. 18: the visible environment of a scope is its own
--- declarations, shadowing (◁) the imported ones, shadowing the parent's, with the seen-imports
--- set I (an import never resolves itself) and the seen-scopes set S; each declaration carries
--- the path that reached it, so the most specific path comes out of ◁ without enumeration. Two
--- declarations of one name surviving ◁ are AMBIGUOUS and both returned (Fig. 5). The
--- prototype's additions, marked as such: a declaration may carry a `value_ref` (an alias, as
--- `local live = H.live` or the field `live = live`), and `resolve_through` follows the chain
--- to the end; an import or a declaration carries a `kind` (lexical, field, module, call, user)
--- so a path can be classified; `sg_bind_param` is the CALL edge, a parameter given the record
--- its argument carries at a call site, which is not syntactic and is supplied as data.
function M.scope_graph()
    return { scopes = {}, decls = {}, refs = {}, n = 0, modules = {} }
end
function M.sg_scope(G, parent, label)
    G.n = G.n + 1
    local S = { id = G.n, parent = parent, label = label, decls = {}, refs = {}, imports = {} }
    G.scopes[S.id] = S
    return S.id
end
function M.sg_decl(G, S, name, opts)
    opts = opts or {}
    G.n = G.n + 1
    local d = { id = G.n, name = name, scope = S, site = opts.site, assoc = opts.assoc, kind = opts.kind or 'lexical', value_ref = opts.value_ref, fn_scope = opts.fn_scope, file = opts.file }
    G.decls[d.id] = d
    local L = G.scopes[S].decls
    L[name] = L[name] or {}
    L[name][#L[name] + 1] = d
    G.memo = nil -- a declaration added after a resolve changes the answers
    return d.id
end
function M.sg_ref(G, S, name, opts)
    opts = opts or {}
    G.n = G.n + 1
    local r = { id = G.n, name = name, scope = S, site = opts.site, kind = opts.kind or 'lexical', file = opts.file, deferred = opts.deferred }
    G.refs[r.id] = r
    local L = G.scopes[S].refs
    L[#L + 1] = r
    G.memo = nil
    return r.id
end
function M.sg_import(G, S, ref, kind)
    local L = G.scopes[S].imports
    L[#L + 1] = { ref = ref, kind = kind or G.refs[ref].kind }
    G.import_refs = G.import_refs or {}
    G.import_refs[ref] = true
    G.memo = nil
end
function M.sg_bind_param(G, decl, assoc)
    local d = G.decls[decl]
    d.assoc = assoc; d.kind = 'call'
    G.memo = nil -- a record bound after a resolve changes the answers (an opaque field becomes a call)
end
M.STEP_RANK = { D = 1, I = 2, P = 3 }
--- a resolution path as a TERM: a sequence of step nodes; the well-formed language P*·I*·D of
--- Fig. 2 is a template with two hedges (the domain algebra expresses the concatenation of two
--- stars; `match` admits P·I·D and refuses I·P·D)
M.WF_PATH = M.template(M.node('path', M.hole('ps', true), M.hole('is', true), M.node('D', M.hole 'd')), { ps = M.rep(M.kinds { 'P' }), is = M.rep(M.kinds { 'I' }) })
function M.path_term(p)
    local ks = {}
    for i, st in ipairs(p) do
        if st.k == 'D' then ks[i] = M.node('D', M.lit(tostring(st.decl)))
        elseif st.k == 'I' then ks[i] = M.node('I', M.lit(tostring(st.ref)))
        else ks[i] = M.node('P') end
    end
    return M.node('path', unpack(ks))
end
function M.well_formed_path(p) return M.match(M.WF_PATH, M.path_term(p)).ok end
M.path_less = M.lex_order(M.STEP_RANK) -- the specificity order of Fig. 2, lexicographic over steps
function M.show_path(G, p)
    local t = {}
    for _, s in ipairs(p) do
        if s.k == 'P' then t[#t + 1] = 'P'
        elseif s.k == 'D' then t[#t + 1] = 'D(' .. G.decls[s.decl].name .. ')'
        else t[#t + 1] = 'I(' .. G.refs[s.ref].name .. (s.kind ~= 'lexical' and (':' .. s.kind) or '') .. ')' end
    end
    return table.concat(t, '·')
end
local function setkey(set) local t = {}; for k in pairs(set) do t[#t + 1] = k end; table.sort(t); return table.concat(t, ',') end
local function with(set, k) local c = {}; for x in pairs(set) do c[x] = true end; c[k] = true; return c end
--- the environments of Fig. 18, each entry { decl, path } keyed by name, the paths tagged
function M.resolve(G, ref, seen_imports)
    local memo = G.memo or {}; G.memo = memo
    -- the environments are computed for ONE name at a time: ◁ acts per name, so the visible
    -- declarations of x in S are the same whether or not the other names are carried along;
    -- this keeps one small entry list per (scope, name) instead of a whole environment per scope
    local import_refs = G.import_refs or {}
    local function shadow(L1, L2) if #L1 > 0 then return L1 end; return L2 end
    local function prefix(step, L)
        local out = {}
        for i, e in ipairs(L) do local p = { step }; for _, q in ipairs(e.path) do p[#p + 1] = q end; out[i] = { decl = e.decl, path = p } end
        return out
    end
    local EnvV, EnvL, Res
    local function EnvD(I, Sn, S, x)
        if Sn[S] then return {} end
        local out = {}
        for i, d in ipairs(G.scopes[S].decls[x] or {}) do out[i] = { decl = d.id, path = { { k = 'D', decl = d.id } } } end
        return out
    end
    local function EnvI(I, Sn, S, x)
        if Sn[S] then return {} end
        local out = {}
        for _, imp in ipairs(G.scopes[S].imports) do
            if not I[imp.ref] then
                local R = Res(I, imp.ref)
                for _, e in ipairs(R.entries) do
                    local d = G.decls[e.decl]
                    if d.assoc then
                        local step = { k = 'I', ref = imp.ref, decl = d.id, kind = imp.kind }
                        for _, y in ipairs(prefix(step, EnvL(I, with(Sn, S), d.assoc, x))) do out[#out + 1] = y end
                    end
                end
            end
        end
        return out
    end
    local function EnvP(I, Sn, S, x)
        if Sn[S] then return {} end
        local P = G.scopes[S].parent
        if not P then return {} end
        return prefix({ k = 'P' }, EnvV(I, Sn, P, x))
    end
    EnvL = function(I, Sn, S, x) return shadow(EnvD(I, Sn, S, x), EnvI(I, Sn, S, x)) end
    EnvV = function(I, Sn, S, x)
        local key = 'V' .. S .. ':' .. x .. '|' .. setkey(I) .. '|' .. setkey(Sn)
        if memo[key] then return memo[key] end
        local L = shadow(EnvL(I, Sn, S, x), EnvP(I, Sn, S, x))
        memo[key] = L
        return L
    end
    Res = function(I, r)
        local R = G.refs[r]
        local I2 = import_refs[r] and with(I, r) or I
        local key = 'R' .. r .. '|' .. setkey(I2)
        if memo[key] then return memo[key] end
        local entries = EnvV(I2, {}, R.scope, R.name)
        -- ◁ kept the most specific level; rule V over it is the preference primitive
        local keep = M.best(entries, function(a, b) return M.path_less(a.path, b.path) end)
        local out = { ref = r, entries = keep, ambiguous = #keep > 1, absent = #keep == 0 }
        memo[key] = out
        return out
    end
    return Res(seen_imports or {}, ref)
end
--- the alias chain: the paper stops at the declaration; the prototype follows a declaration's
--- `value_ref` (an alias) to the end, refusing to loop
function M.resolve_through(G, ref)
    local hops, seen = {}, {}
    local r = ref
    while true do
        local R = M.resolve(G, r)
        hops[#hops + 1] = R
        if R.absent or R.ambiguous then return { hops = hops, ends = R.entries, ambiguous = R.ambiguous, absent = R.absent } end
        local d = G.decls[R.entries[1].decl]
        if not d.value_ref or seen[d.id] then return { hops = hops, ends = R.entries, decl = d.id } end
        seen[d.id] = true
        r = d.value_ref
    end
end
--- the class of a resolution, read off the winning path's steps and the alias hops:
--- unresolved | ambiguous | call | module | field | user | library | lexical
function M.resolution_class(G, T)
    if T.absent then
        -- a field of a known object whose record is not known (a call's result, a parameter
        -- without a call edge) is OPAQUE, not unresolved; a field of a library object is library;
        -- a chain reaching a module reference is a module reference whether the module is
        -- loaded or not (the census counts the unloaded ones apart)
        local last = T.hops[#T.hops]
        local r = G.refs[last.ref]
        if r.kind == 'module' then return 'module' end
        if r.kind == 'field' then
            local imp = G.scopes[r.scope].imports[1]
            if not imp then return 'opaque' end
            local O = M.resolve_through(G, imp.ref)
            local oc = M.resolution_class(G, O) -- the object's own class decides: a field of a library object is library, of an unknown name unresolved
            if oc == 'library' or oc == 'unresolved' or oc == 'ambiguous' then return oc end
            return 'opaque'
        end
        return 'unresolved'
    end
    if T.ambiguous then return 'ambiguous' end
    local seen = { lexical = true }
    for _, R in ipairs(T.hops) do
        for _, s in ipairs(R.entries[1].path) do
            if s.k == 'I' then
                seen[s.kind] = true
                seen[G.refs[s.ref].kind] = true -- a field of a require is a module reference
                if G.decls[s.decl].kind == 'call' then seen.call = true end
            end
        end
        local d = G.decls[R.entries[1].decl]
        if d.kind == 'library' then seen.library = true end
        if d.kind == 'call' then seen.call = true end
    end
    for _, c in ipairs({ 'call', 'module', 'field', 'user', 'library' }) do if seen[c] then return c end end
    return 'lexical'
end
--- a fresh reference of `name` placed in scope S, resolved: "what would this name mean here"
function M.resolve_name(G, S, name)
    local r = M.sg_ref(G, S, name, { kind = 'probe' })
    G.memo = nil
    local T = M.resolve_through(G, r)
    return T
end

--- The Lua mapping (Section 4's construction, for tree-sitter Lua terms), syntactic except
--- where marked: a chunk is a scope under the library root; a `local` declaration is the
--- SEQUENTIAL let of Fig. 14 (the right-hand side in the scope before it, a new scope after
--- it), `local function f` declares before its body (self-visible), a function's parameters
--- and body are one scope, loops and branches open scopes, for-clause variables live in the
--- loop scope with the `in` list outside it; identifiers in read position are references, a
--- bare assignment target a reference of kind assign; `a.b` is Fig. 15's anonymous scope with
--- no parent importing the reference `a`; a table constructor on the right of a local
--- declaration is the local's associated record scope, its fields declarations with the
--- field's value as `value_ref` when it is a name; `require 'm'` is a reference in the
--- modules scope to the module declaration whose associated scope is the record `return M`
--- returns; `M.f = ..` and `function M.f` declare `f` into the record of `M`, which needs `M`
--- resolved first and is done in a second pass (`sg_link`), the prototype's, not the paper's.
function M.lua_scope_graph(t, G, opts)
    opts = opts or {}
    G = G or M.scope_graph()
    if not G.root then
        G.root = M.sg_scope(G, nil, 'library')
        local lib = (M.SCOPE_RULES[opts.lang or 'lua'] or {}).library or {}
        for nm in pairs(lib) do M.sg_decl(G, G.root, nm, { kind = 'library' }) end
        G.modules_scope = M.sg_scope(G, nil, 'modules')
        G.pending = {}
        G.skipped = 0
    end
    local file = opts.file
    local fn_depth = 0
    local function ident(x) return type(x) == 'table' and x.k == 'identifier' and x.kids and type(x.kids[1]) == 'table' and x.kids[1].k == 'lit' and tostring(x.kids[1].v) or nil end
    local function string_of(x)
        if type(x) ~= 'table' or x.k ~= 'string' then return nil end
        for _, c in ipairs(x.kids) do if type(c) == 'table' and c.k == 'string_content' and type(c.kids[1]) == 'table' and c.kids[1].k == 'lit' then return tostring(c.kids[1].v) end end
        return ''
    end
    local expr, block
    -- an expression: creates references; returns the reference id when the expression IS a name
    -- (an identifier, a field chain, a require), so a local's right-hand side can alias it
    expr = function(x, S, path)
        if type(x) ~= 'table' or x.k == 'lit' or x.k == 'hole' or x.k == 'comment' or x.k == 'string' or x.k == 'number' then return nil end
        if x.k == 'identifier' then return M.sg_ref(G, S, ident(x), { site = path, file = file, deferred = fn_depth > 0 }) end
        if x.k == 'dot_index_expression' or x.k == 'method_index_expression' then
            local objref = expr(x.kids[1], S, child(path, 1))
            local fld = x.kids[#x.kids]
            local fname = ident(fld)
            if not fname then G.skipped = G.skipped + 1; return nil end
            local A = M.sg_scope(G, nil, 'field')
            if objref then M.sg_import(G, A, objref, 'field') else G.skipped = G.skipped + 1 end
            return M.sg_ref(G, A, fname, { site = child(path, #x.kids), file = file, kind = 'field', deferred = fn_depth > 0 })
        end
        if x.k == 'function_call' then
            local callee, args = x.kids[1], nil
            for i = 2, #x.kids do if type(x.kids[i]) == 'table' and x.kids[i].k ~= 'lit' then args = x.kids[i]; break end end
            if ident(callee) == 'require' and args and (args.k == 'arguments' or args.k == 'string') then
                local mod = string_of(args)
                if not mod then for _, a in ipairs(args.kids) do mod = mod or string_of(a) end end
                if mod then
                    M.sg_ref(G, S, 'require', { site = child(path, 1), file = file, deferred = fn_depth > 0 })
                    return M.sg_ref(G, G.modules_scope, mod, { site = path, file = file, kind = 'module', deferred = fn_depth > 0 })
                end
            end
            expr(callee, S, child(path, 1))
            for i = 2, #x.kids do expr(x.kids[i], S, child(path, i)) end
            return nil
        end
        if x.k == 'function_definition' then
            local F = M.sg_scope(G, S, 'function')
            fn_depth = fn_depth + 1
            for i, c in ipairs(x.kids) do
                if type(c) == 'table' and c.k == 'parameters' then for j, p in ipairs(c.kids) do if ident(p) then M.sg_decl(G, F, ident(p), { site = child(child(path, i), j), file = file, kind = 'parameter' }) end end
                elseif type(c) == 'table' and c.k == 'block' then block(c, F, child(path, i)) end
            end
            fn_depth = fn_depth - 1
            return nil
        end
        if x.k == 'table_constructor' then
            for i, f in ipairs(x.kids) do
                if type(f) == 'table' and f.k == 'field' then
                    local kids = f.kids
                    if type(kids[1]) == 'table' and kids[1].k == 'identifier' and #kids >= 3 then expr(kids[#kids], S, child(child(path, i), #kids))
                    else for j, c in ipairs(kids) do expr(c, S, child(child(path, i), j)) end end
                end
            end
            return nil
        end
        if x.k == 'parenthesized_expression' then
            local r
            for i, c in ipairs(x.kids) do local q = expr(c, S, child(path, i)); r = r or q end
            return r
        end
        for i, c in ipairs(x.kids or {}) do expr(c, S, child(path, i)) end
        return nil
    end
    -- a statement list: returns the scope the list ends in (sequential locals open scopes)
    local function statement(c, S, path)
        if c.k == 'variable_declaration' then
            local assign, a_i = nil, nil
            for i, d in ipairs(c.kids) do if type(d) == 'table' and d.k == 'assignment_statement' then assign, a_i = d, i end end
            local vl, el, v_i, e_i
            for i, d in ipairs((assign or c).kids) do
                if type(d) == 'table' and d.k == 'variable_list' then vl, v_i = d, i elseif type(d) == 'table' and d.k == 'expression_list' then el, e_i = d, i end
            end
            -- the TRUE tree paths of the lists (the statement, the assignment when there is one, the list)
            local base = a_i and child(path, a_i) or path
            local vpath, epath = vl and child(base, v_i) or nil, el and child(base, e_i) or nil
            -- the right-hand sides, walked ONCE: a table constructor becomes the local's record,
            -- its named fields declarations whose values are walked here and nowhere else
            local vrefs, records = {}, {}
            if el then
                local k = 0
                for i, e in ipairs(el.kids) do
                    if type(e) == 'table' and e.k ~= 'lit' then
                        k = k + 1
                        local ep = child(epath, i)
                        if e.k == 'table_constructor' then
                            local rec = M.sg_scope(G, nil, 'record')
                            for j, f in ipairs(e.kids) do
                                if type(f) == 'table' and f.k == 'field' then
                                    local fk = f.kids
                                    if type(fk[1]) == 'table' and fk[1].k == 'identifier' and #fk >= 3 then
                                        local val = fk[#fk]
                                        local vref = expr(val, S, child(child(ep, j), #fk))
                                        M.sg_decl(G, rec, ident(fk[1]), { site = child(child(ep, j), 1), file = file, kind = 'field', value_ref = vref })
                                    else for m, c in ipairs(fk) do expr(c, S, child(child(ep, j), m)) end end
                                end
                            end
                            records[k] = rec
                        else
                            vrefs[k] = expr(e, S, ep)
                        end
                    end
                end
            end
            local S2 = M.sg_scope(G, S, 'local')
            local k = 0
            for i, v in ipairs(vl and vl.kids or {}) do
                if ident(v) then
                    k = k + 1
                    M.sg_decl(G, S2, ident(v), { site = child(vpath, i), file = file, value_ref = vrefs[k], assoc = records[k] })
                end
            end
            return S2
        end
        if c.k == 'function_declaration' then
            local is_local = type(c.kids[1]) == 'table' and c.kids[1].k == 'lit' and c.kids[1].v == 'local'
            local name_node, params, body
            for i, d in ipairs(c.kids) do
                if type(d) == 'table' and (d.k == 'identifier' or d.k == 'dot_index_expression' or d.k == 'method_index_expression') and not name_node then name_node = { node = d, i = i }
                elseif type(d) == 'table' and d.k == 'parameters' then params = { node = d, i = i }
                elseif type(d) == 'table' and d.k == 'block' then body = { node = d, i = i } end
            end
            local S2 = S
            local F
            if is_local and ident(name_node.node) then
                S2 = M.sg_scope(G, S, 'local')
                F = M.sg_scope(G, S2, 'function')
                M.sg_decl(G, S2, ident(name_node.node), { site = child(path, name_node.i), file = file, kind = 'function', fn_scope = F })
            elseif ident(name_node.node) then
                F = M.sg_scope(G, S, 'function')
                M.sg_ref(G, S, ident(name_node.node), { site = child(path, name_node.i), file = file, kind = 'assign' })
            else
                -- function M.f / M:f: f is declared into M's record once M resolves (second pass)
                F = M.sg_scope(G, S, 'function')
                local nn = name_node.node
                local objref = expr(nn.kids[1], S, child(child(path, name_node.i), 1))
                local fname = ident(nn.kids[#nn.kids])
                if objref and fname then G.pending[#G.pending + 1] = { ref = objref, name = fname, site = child(path, name_node.i), file = file, fn_scope = F }
                else G.skipped = G.skipped + 1 end
                if nn.k == 'method_index_expression' then M.sg_decl(G, F, 'self', { kind = 'parameter', file = file }) end
            end
            fn_depth = fn_depth + 1
            if params then for j, p in ipairs(params.node.kids) do if ident(p) then M.sg_decl(G, F, ident(p), { site = child(child(path, params.i), j), file = file, kind = 'parameter' }) end end end
            if body then block(body.node, F, child(path, body.i)) end
            fn_depth = fn_depth - 1
            return S2
        end
        if c.k == 'assignment_statement' then
            local vl, el, v_i, e_i
            for i, d in ipairs(c.kids) do if type(d) == 'table' and d.k == 'variable_list' then vl, v_i = d, i elseif type(d) == 'table' and d.k == 'expression_list' then el, e_i = d, i end end
            if el then for i, e in ipairs(el.kids) do expr(e, S, child(child(path, e_i), i)) end end
            for i, v in ipairs(vl and vl.kids or {}) do
                local vp = child(child(path, v_i), i)
                if ident(v) then M.sg_ref(G, S, ident(v), { site = vp, file = file, kind = 'assign', deferred = fn_depth > 0 })
                elseif type(v) == 'table' and (v.k == 'dot_index_expression' or v.k == 'method_index_expression') then
                    local objref = expr(v.kids[1], S, child(vp, 1))
                    local fname = ident(v.kids[#v.kids])
                    if objref and fname then G.pending[#G.pending + 1] = { ref = objref, name = fname, site = child(vp, #v.kids), file = file }
                    else G.skipped = G.skipped + 1 end
                elseif type(v) == 'table' and v.k == 'bracket_index_expression' then expr(v, S, vp)
                elseif type(v) == 'table' and v.k ~= 'lit' then G.skipped = G.skipped + 1 end
            end
            return S
        end
        if c.k == 'for_statement' then
            local L = M.sg_scope(G, S, 'for')
            for i, d in ipairs(c.kids) do
                if type(d) == 'table' and (d.k == 'for_numeric_clause' or d.k == 'for_generic_clause') then
                    local before = true
                    for j, e in ipairs(d.kids) do
                        if type(e) == 'table' and e.k == 'lit' and (e.v == '=' or e.v == 'in') then before = false
                        elseif before then
                            if ident(e) then M.sg_decl(G, L, ident(e), { site = child(child(path, i), j), file = file, kind = 'loop' })
                            elseif type(e) == 'table' and e.k == 'variable_list' then for m, v in ipairs(e.kids) do if ident(v) then M.sg_decl(G, L, ident(v), { site = child(child(child(path, i), j), m), file = file, kind = 'loop' }) end end end
                        else expr(e, S, child(child(path, i), j)) end
                    end
                elseif type(d) == 'table' and d.k == 'block' then block(d, L, child(path, i)) end
            end
            return S
        end
        if c.k == 'while_statement' or c.k == 'if_statement' or c.k == 'do_statement' or c.k == 'repeat_statement' or c.k == 'elseif_statement' or c.k == 'else_statement' then
            local B = M.sg_scope(G, S, c.k)
            local last = B
            for i, d in ipairs(c.kids) do
                if type(d) == 'table' and d.k == 'block' then last = block(d, B, child(path, i))
                elseif type(d) == 'table' and (d.k == 'elseif_statement' or d.k == 'else_statement') then statement(d, S, child(path, i))
                elseif type(d) == 'table' and d.k ~= 'lit' then expr(d, c.k == 'repeat_statement' and last or S, child(path, i)) end
            end
            return S
        end
        if c.k == 'return_statement' then
            for i, d in ipairs(c.kids) do
                if type(d) == 'table' and d.k == 'expression_list' then
                    for j, e in ipairs(d.kids) do
                        local r = expr(e, S, child(child(path, i), j))
                        if r and opts.module and ident(e) then G.module_returns = G.module_returns or {}; G.module_returns[opts.module] = r end
                    end
                end
            end
            return S
        end
        expr(c, S, path)
        return S
    end
    block = function(b, S, path)
        local cur = S
        for i, c in ipairs(b.kids) do
            if type(c) == 'table' and c.k ~= 'lit' and c.k ~= 'comment' then cur = statement(c, cur, child(path, i)) end
        end
        return cur
    end
    local C = M.sg_scope(G, G.root, 'chunk:' .. tostring(file or opts.module or '?'))
    G.chunks = G.chunks or {}
    G.chunks[#G.chunks + 1] = { scope = C, file = file, module = opts.module }
    if t.k == 'chunk' then block(t, C, {}) else statement(t, C, {}) end
    return G, C
end
--- the second pass: field declarations into the records of their objects (needs the object
--- resolved), and each module's declaration in the modules scope with the returned record as
--- its associated scope; then the memo is cleared
function M.sg_link(G)
    G.memo = nil
    -- resolve every pending object first, then declare: a field declaration clears the memo,
    -- and none of the objects (`M` in `M.f`) resolves through a field
    local targets = {}
    for i, p in ipairs(G.pending) do
        local R = M.resolve(G, p.ref)
        if not R.absent and not R.ambiguous then targets[i] = G.decls[R.entries[1].decl] end
    end
    for i, p in ipairs(G.pending) do
        local d = targets[i]
        if d then
            if not d.assoc then d.assoc = M.sg_scope(G, nil, 'record') end
            M.sg_decl(G, d.assoc, p.name, { site = p.site, file = p.file, kind = 'field', fn_scope = p.fn_scope })
        end
    end
    G.pending = {}
    for mod, r in pairs(G.module_returns or {}) do
        local R = M.resolve(G, r)
        if not R.absent and not R.ambiguous then
            local d = G.decls[R.entries[1].decl]
            if not d.assoc then d.assoc = M.sg_scope(G, nil, 'record') end
            local id = M.sg_decl(G, G.modules_scope, mod, { kind = 'module', assoc = d.assoc, file = d.file })
            G.modules[mod] = id
        end
    end
    G.module_returns = {}
    G.memo = nil
    return G
end
--- every reference resolved and classified: the census
function M.resolve_census(G)
    local out = { by_class = {}, refs = {}, total = 0 }
    local ids = {}
    for id in pairs(G.refs) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
        local r = G.refs[id]
        if r.kind ~= 'probe' then
            local T = M.resolve_through(G, id)
            local c = M.resolution_class(G, T)
            out.by_class[c] = (out.by_class[c] or 0) + 1
            out.total = out.total + 1
            out.refs[id] = { class = c, T = T }
        end
    end
    return out
end

-- ── the Lua mapping as TEMPLATES (PRIMITIVES.md, the second check): scope kinds, declaration
-- templates with name holes, non-reference positions; a generic builder ──────────────────────
--- locals.scm's three capture lists as the algebra's own data: `scopes` are node kinds that
--- open a scope; each declaration is a TEMPLATE (matched by `match` at a statement or a node)
--- with a hedge or hole naming the declared identifiers, a REGION saying where the names are
--- visible (`rest`: the rest of the enclosing block, the sequential let, the right-hand side
--- walked before; `self`: the declaring statement itself and the rest, a local function;
--- `construct`: the scope the construct opened, parameters and for-clause variables) and a
--- kind; `non_references` are the positions where an identifier is not a read (the field
--- after `.` or `:`, a table field's key). Records, modules, fields and aliases are not in this
--- mapping: it is the LEXICAL half, judged against `lua_scope_graph` on the same terms.
local function tpl(body, doms) return M.template(body, doms) end
M.SCOPE_TEMPLATES = { lua = {
    scopes = { chunk = true, function_definition = true, function_declaration = true, for_statement = true, do_statement = true,
        while_statement = true, repeat_statement = true, if_statement = true, elseif_statement = true, else_statement = true },
    declarations = {
        { rule = 'local', region = 'rest', kind = 'lexical', names = 'names', values = 'values',
          template = tpl(M.node('variable_declaration', M.lit 'local', M.lit ' ', M.node('assignment_statement', M.node('variable_list', M.hole('names', true)), M.hole('ws', true), M.node('expression_list', M.hole('values', true))))) },
        { rule = 'local_bare', region = 'rest', kind = 'lexical', names = 'names',
          template = tpl(M.node('variable_declaration', M.lit 'local', M.lit ' ', M.node('variable_list', M.hole('names', true)))) },
        { rule = 'local_function', region = 'self', kind = 'function', names = 'name',
          template = tpl(M.node('function_declaration', M.lit 'local', M.lit ' ', M.lit 'function', M.lit ' ', M.node('identifier', M.hole 'name'), M.hole('rest', true))) },
        { rule = 'parameters', region = 'construct', kind = 'parameter', names = 'ps',
          template = tpl(M.node('parameters', M.lit '(', M.hole('ps', true), M.lit ')')) },
        { rule = 'for_generic', region = 'construct', kind = 'loop', names = 'vars', values = 'exprs',
          template = tpl(M.node('for_generic_clause', M.node('variable_list', M.hole('vars', true)), M.hole('ws', true), M.lit 'in', M.hole('ws2', true), M.node('expression_list', M.hole('exprs', true)))) },
        { rule = 'for_numeric', region = 'construct', kind = 'loop', names = 'var', values = 'rest',
          template = tpl(M.node('for_numeric_clause', M.node('identifier', M.hole 'var'), M.hole('rest', true))) },
        { rule = 'method', region = 'scope', kind = 'parameter', implicit = { 'self' },
          template = tpl(M.node('function_declaration', M.lit 'function', M.lit ' ', M.node('method_index_expression', M.hole('obj', true)), M.hole('rest', true))) },
    },
    tail_visible = { repeat_statement = true },
    non_references = {
        { parent = 'dot_index_expression', from_kid = 2 }, { parent = 'method_index_expression', from_kid = 2 },
        { parent = 'field', kid = 1, followed_by = '=' },
    },
    library = M.SCOPE_RULES.lua.library,
} }
--- where a hole sits in a declaration template, the same place in the matched node: the node
--- there and its TRUE path (the algebra's own sites, so both mappings site a name identically)
local function hole_node(d, h, x, path)
    -- the template's path to the hole, mapped level by level onto the instance: a fixed kid
    -- before any hedge keeps its index, a fixed kid after the hedges keeps its index from the
    -- end (the hedges absorb the middle); the hedge itself covers the kids in between
    local site = M.sites(d.template)[h].sites[1].path
    local tnode, node, p = d.template.body, x, { unpack(path) }
    for depth = 1, #site - 1 do
        local ti = site[depth]
        local hedge_at
        for j, c in ipairs(tnode.kids) do if type(c) == 'table' and c.k == 'hole' and c.rep and j < ti then hedge_at = j end end
        local ii = ti
        if hedge_at then ii = #node.kids - (#tnode.kids - ti) end
        tnode, node = tnode.kids[ti], node.kids[ii]
        p[#p + 1] = ii
    end
    -- the range of instance kids the hole covers (a hedge), or its single index
    local ti = site[#site]
    local from, to = ti, ti
    local hole = tnode.kids[ti]
    if type(hole) == 'table' and hole.k == 'hole' and hole.rep then
        from = ti
        to = #node.kids - (#tnode.kids - ti)
    else
        local hedge_before = false
        for j, c in ipairs(tnode.kids) do if type(c) == 'table' and c.k == 'hole' and c.rep and j < ti then hedge_before = true end end
        if hedge_before then from = #node.kids - (#tnode.kids - ti); to = from end
    end
    return node, p, from, to
end
local function declared_names(d, h, x, path) -- (name, site) of every identifier the names hole covers
    local node, p, from, to = hole_node(d, h, x, path)
    local out = {}
    local hole = M.locate_at(d.template.body, M.sites(d.template)[h].sites[1].path)
    local function ident(y) return type(y) == 'table' and y.k == 'identifier' and type(y.kids[1]) == 'table' and y.kids[1].k == 'lit' and tostring(y.kids[1].v) or nil end
    if hole.rep then
        for i = from, to do local c = node.kids[i]; if ident(c) then out[#out + 1] = { name = ident(c), site = child(p, i) } end end
    else -- a term hole inside an identifier: the identifier is the parent node
        if ident(node) then out[#out + 1] = { name = ident(node), site = p } end
    end
    return out
end
function M.scope_graph_from_templates(t, RULES, G, opts)
    opts = opts or {}
    G = G or M.scope_graph()
    if not G.root then
        G.root = M.sg_scope(G, nil, 'library')
        for nm in pairs(RULES.library or {}) do M.sg_decl(G, G.root, nm, { kind = 'library' }) end
        G.skipped = 0
    end
    local file = opts.file
    local function ident(x) return type(x) == 'table' and x.k == 'identifier' and x.kids and type(x.kids[1]) == 'table' and x.kids[1].k == 'lit' and tostring(x.kids[1].v) or nil end
    local function non_ref(parent, i)
        for _, nr in ipairs(RULES.non_references) do
            if parent.k == nr.parent then
                if nr.from_kid and i >= nr.from_kid then return true end
                if nr.kid == i and nr.followed_by then
                    for j = i + 1, #parent.kids do local c = parent.kids[j]; if type(c) == 'table' and c.k == 'lit' and not tostring(c.v):match('^%s*$') then return c.v == nr.followed_by end end
                end
            end
        end
        return false
    end
    local function declaration_of(x)
        for _, d in ipairs(RULES.declarations) do
            if d.template.body.k == x.k then -- a template matches only a node of its own kind
                local m = M.match(d.template, x)
                if m.ok then return d, m.values end
            end
        end
        return nil
    end
    local walk
    -- walk the kids of x (or the range from..to) in scope S; returns the scope the sequence
    -- ends in (a `rest` declaration opens one)
    local function kids(x, S, path, from, to)
        local cur = S
        for i = from or 1, to or #(x.kids or {}) do
            local c = x.kids[i]
            if type(c) == 'table' and c.k ~= 'lit' and c.k ~= 'comment' then
                if c.k == 'identifier' then
                    if not non_ref(x, i) and ident(c) then M.sg_ref(G, cur, ident(c), { site = child(path, i), file = file }) end
                else
                    cur = walk(c, cur, child(path, i))
                end
            end
        end
        return cur
    end
    walk = function(x, S, path)
        local d = declaration_of(x)
        if d then
            local function values_in(scope) -- the kids the values hole covers, walked in `scope` at their true paths
                if not d.values then return end
                local node, p, from, to = hole_node(d, d.values, x, path)
                kids(node, scope, p, from, to)
            end
            if d.region == 'scope' then
                -- the construct opens its scope and declares implicit names in it (a method's self)
                local S2 = M.sg_scope(G, S, d.rule)
                for _, nm in ipairs(d.implicit or {}) do M.sg_decl(G, S2, nm, { file = file, kind = d.kind }) end
                kids(x, S2, path)
                return S
            end
            if d.region == 'rest' then
                -- the sequential let: values in the scope before, names in a new scope for the rest
                values_in(S)
                local S2 = M.sg_scope(G, S, d.rule)
                for _, nm in ipairs(declared_names(d, d.names, x, path)) do M.sg_decl(G, S2, nm.name, { site = nm.site, file = file, kind = d.kind }) end
                return S2
            elseif d.region == 'self' then
                local S2 = M.sg_scope(G, S, d.rule)
                for _, nm in ipairs(declared_names(d, d.names, x, path)) do M.sg_decl(G, S2, nm.name, { site = nm.site, file = file, kind = d.kind }) end
                local F = M.sg_scope(G, S2, 'function')
                -- the rest of the declaration (parameters, body) in the function's scope
                for i, c in ipairs(x.kids) do if type(c) == 'table' and c.k ~= 'lit' and c.k ~= 'identifier' then walk(c, F, child(path, i)) end end
                return S2
            else -- construct: the names live in the scope the construct opened (the current one)
                for _, nm in ipairs(declared_names(d, d.names, x, path)) do M.sg_decl(G, S, nm.name, { site = nm.site, file = file, kind = d.kind }) end
                values_in(G.scopes[S].parent or S) -- the `in` list and the bounds outside the loop scope
                return S
            end
        end
        if RULES.scopes[x.k] then
            local S2 = M.sg_scope(G, S, x.k)
            if RULES.tail_visible and RULES.tail_visible[x.k] then
                -- repeat .. until: the condition sees the block's tail scope
                local cur = S2
                for i, c in ipairs(x.kids) do
                    if type(c) == 'table' and c.k == 'block' then cur = kids(c, cur, child(path, i))
                    elseif type(c) == 'table' and c.k ~= 'lit' and c.k ~= 'comment' then
                        if c.k == 'identifier' then if not non_ref(x, i) and ident(c) then M.sg_ref(G, cur, ident(c), { site = child(path, i), file = file }) end
                        else walk(c, cur, child(path, i)) end
                    end
                end
            else
                kids(x, S2, path)
            end
            return S
        end
        kids(x, S, path)
        return S
    end
    local C = M.sg_scope(G, G.root, 'chunk:' .. tostring(file or '?'))
    G.chunks = G.chunks or {}
    G.chunks[#G.chunks + 1] = { scope = C, file = file }
    kids(t, C, {})
    return G, C
end
--- the comparison of the two mappings on one term: declarations and references as (name, site)
--- sets for the lexical kinds, and the resolution class of every shared reference
function M.compare_mappings(t)
    local G1 = M.lua_scope_graph(t, nil, { file = 'f' }); M.sg_link(G1)
    local G2 = M.scope_graph_from_templates(t, M.SCOPE_TEMPLATES.lua, nil, { file = 'f' })
    local function decls(G, want)
        local S = {}
        for _, d in pairs(G.decls) do if want[d.kind] and d.site then S[d.name .. '@' .. table.concat(d.site, '/')] = d end end
        return S
    end
    local function refs(G, skip)
        local S = {}
        for _, r in pairs(G.refs) do if not skip[r.kind] and r.site then S[r.name .. '@' .. table.concat(r.site, '/')] = r end end
        return S
    end
    local lex = { lexical = true, parameter = true, loop = true, function_ = true }
    lex['function'] = true
    local D1, D2 = decls(G1, lex), decls(G2, lex)
    local R1, R2 = refs(G1, { field = true, module = true, probe = true }), refs(G2, { probe = true })
    local out = { decl_only_code = {}, decl_only_templates = {}, ref_only_code = {}, ref_only_templates = {}, shared = 0, same_class = 0, class_diffs = {} }
    for k in pairs(D1) do if not D2[k] then out.decl_only_code[#out.decl_only_code + 1] = k end end
    for k in pairs(D2) do if not D1[k] then out.decl_only_templates[#out.decl_only_templates + 1] = k end end
    out.same_binder, out.binder_diffs = 0, {}
    local function binder(G, id) -- the paper's end: the declaration the reference resolves to, by name and site
        local Rr = M.resolve(G, id)
        if Rr.absent then return 'absent' end
        local t = {}
        for _, e in ipairs(Rr.entries) do local d = G.decls[e.decl]; t[#t + 1] = d.name .. '@' .. (d.site and table.concat(d.site, '/') or d.kind) end
        table.sort(t)
        return table.concat(t, '|')
    end
    for k, r in pairs(R1) do
        if not R2[k] then out.ref_only_code[#out.ref_only_code + 1] = k
        else
            out.shared = out.shared + 1
            local b1, b2 = binder(G1, r.id), binder(G2, R2[k].id)
            if b1 == b2 then out.same_binder = out.same_binder + 1 else out.binder_diffs[#out.binder_diffs + 1] = k .. ': ' .. b1 .. ' / ' .. b2 end
            local c1 = M.resolution_class(G1, M.resolve_through(G1, r.id))
            local c2 = M.resolution_class(G2, M.resolve_through(G2, R2[k].id))
            if c1 == c2 then out.same_class = out.same_class + 1 else out.class_diffs[#out.class_diffs + 1] = k .. ': ' .. c1 .. ' / ' .. c2 end
        end
    end
    for k in pairs(R2) do if not R1[k] then out.ref_only_templates[#out.ref_only_templates + 1] = k end end
    for _, l in pairs(out) do if type(l) == 'table' then table.sort(l) end end
    out.decls = { code = 0, templates = 0 }
    for _ in pairs(D1) do out.decls.code = out.decls.code + 1 end
    for _ in pairs(D2) do out.decls.templates = out.decls.templates + 1 end
    return out
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
--
-- ★ EVERY NAME HERE IS DERIVED, NOT COPIED (re-vendor 2026-09-19, CART-0912):
-- a name is supplied iff it is (a) a module-level local of core, (b) read by a
-- part's body outside a field position and (c) not defined by that part — the
-- three conditions the parts fence asserts, now computed rather than asserted.
-- The 2026-09-13 cut had to list `cat`/`cat_flat` and `is_prefix`/
-- `is_strict_prefix` as BOTH VARIANTS BY DISTINCT NAMES (CART-0924/0925),
-- because two same-named locals with different semantics shadowed each other
-- HERE, at the bottom of the file. The donor has since made that same rename
-- upstream (`cat_lists`, `is_strict_prefix`), so the hazard is the donor's own
-- now and this table simply follows it. `derived`, `occurrences`, `RUNG_RANK`
-- and `cat_flat` left the list because no part reads them any more.
local PARTS = { absence = absence, anchor_fit = anchor_fit, at = at, ax = ax,
    below = below, cat = cat, cat_lists = cat_lists, child = child, derived = derived,
    distinct = distinct, family = family, family_of = family_of, fits = fits, hash = hash,
    hedged_run = hedged_run, isA = isA, is_hole = is_hole,
    is_strict_prefix = is_strict_prefix, key = key, lcp = lcp,
    lcs_alignments = lcs_alignments, lexlt = lexlt, no_ancestors = no_ancestors,
    occurrences = occurrences, occurs = occurs, prefix_eq = prefix_eq,
    prefix_of = prefix_of, same = same, same_key = same_key, set_at = set_at,
    slice = slice, subst = subst, unpack = unpack, vsym = vsym }
require('cartograph.algebra.hopau')(M, PARTS)
require('cartograph.algebra.termgraph')(M, PARTS)
require('cartograph.algebra.eau')(M, PARTS)
require('cartograph.algebra.materialize')(M, PARTS)
require('cartograph.algebra.tai')(M, PARTS)
require('cartograph.algebra.vertical')(M, PARTS)
require('cartograph.algebra.mdl')(M, PARTS)
require('cartograph.algebra.join')(M, PARTS)
require('cartograph.algebra.corr')(M, PARTS)
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
