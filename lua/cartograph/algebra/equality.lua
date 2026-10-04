-- A PART OF `cartograph.algebra.core` (see core.lua's PARTS). BREAK UP EQUALITY (CART-1398, rung 1 = CART-1399): the
-- algebra's equalities as a NAMED FAMILY — Lisp's eq / eql / equal / equalp, Baker's EGAL (structural for values,
-- identity for mutable things) — each with its HASH (a relation holds iff the hashes agree) and its ORDER (consistent
-- with it: equal => neither sorts first), and a table that makes every memo / hash / sort DECLARE which one it means
-- (Lisp's :test). Built from what exists — term = M.eq + content_id, ordered = the same with written order, theory =
-- eau's eq_mod + canon, bisimilar = tg_bisimilar, equivalent = instance_of both ways; new here: identity, literal, the
-- VARIANT renaming, the table and the memo.
--   identity    the same object (rawequal) — mutable things, handles
--   literal     a literal's value and type under the LITERAL POLICY (one today: Lua's ==, -0 == 0, NaN refused; an
--               adapter declares another — YAML's float_canon, Erlang's =:= — when one needs it)
--   ordered     every identity field on every kind, kids in WRITTEN order (Lisp equal)
--   term        ordered, a keyed node a SET by key — M.eq, the default
--   variant     term modulo hole RENAMING (hole names and presence marks renamed by first occurrence)
--   theory      term modulo an equational theory ({ [kind] = { A, C } }) — eau's canon
--   bisimilar   term graphs (cycles) — no hash
--   equivalent  templates with the same instances, domains included — instance_of both ways; no hash
-- LAWS (tests/equality_spec.lua): rel <=> same hash; ordered => term => variant => equivalent; term => theory; each order
-- consistent with its relation.
return function (M, SHARED)

-- ── VARIANT: hole names renamed canonically ────────────────────────────────────────────────────────────────────────
--- a copy of t with every HOLE NAME — a hole's `h` and a presence mark's `opt`, one namespace — renamed `v1, v2, …` by
--- first occurrence in preorder (a keyed node's kids in KEY order: keys hold no holes, so the order is the term's own).
--- opts.keep(name) -> true keeps a name (a PARTIAL variant: modulo renaming of the other holes — a generator's
--- parameters keep theirs); opts.prefix replaces `v` (xmpppeer's outputs are `o1, o2, …`)
function M.rename_holes(t, opts)
    opts = opts or {}
    local map, n, prefix = {}, 0, opts.prefix or 'v'
    local function name(h)
        if opts.keep and opts.keep(h) then return h end
        if not map[h] then n = n + 1; map[h] = prefix .. n end
        return map[h]
    end
    local function go(u)
        local c = {}
        for f, x in pairs(u) do if f ~= 'kids' then c[f] = x end end
        if u.opt then c.opt = name(u.opt) end
        if u.k == 'hole' then c.h = name(u.h) end
        if u.kids then
            c.kids = {}
            if u.align == 'keyed' then
                -- (visit in key order so the renaming is the term's own; the kids keep their written places)
                local slot = {}
                for _, e in ipairs(M.keys(u)) do slot[e.i] = go(e.kid) end
                for i = 1, #u.kids do c.kids[i] = slot[i] end
            else
                for i, k in ipairs(u.kids) do c.kids[i] = go(k) end
            end
        end
        return c
    end
    return go(t)
end

-- ── VARIANT IDS FOR EVERY SUBTERM AT ONCE (CART-1426): hashing modulo alpha-equivalence, Maziarz, Ellis, Lawrence,
-- Fitzgibbon and Peyton Jones, PLDI 2021 (arXiv 2105.02856). A node's E-SUMMARY is its STRUCTURE (the node with every
-- variable occurrence anonymous) and a VARIABLE MAP (each variable -> the tree of positions where it occurs). Two terms
-- are variants (equal modulo a consistent renaming of hole names and presence marks — REL.variant) iff they have one
-- structure and one SET of position trees, the names dropped. The summary is COMPOSITIONAL: a node's comes from its
-- kids' — so one pass gives every subterm's id, and a summary already made (a row's) is reused by every term above it
-- (each window of rows) instead of the term being renamed and re-interned whole.
--   ★ THE PAPER'S TWO MOVES, kept: (1) a node merges its SMALLER kids' maps into the BIGGEST (the big kid's entries stay
--   untouched; each small entry becomes a JOIN tagged with this node's structure id — which no substructure shares —
--   and the kid's index, so the map is invertible: the paper's `rebuild` argument), O(n log n) entries touched; (2) the
--   map's hash is the XOR of its entries' hashes, so an entry changes in O(1).
--   Generalized: n-ary kids (the index rides in the join); a KEYED node's kids in KEY order (it is a set by key, as
--   content_id reads it); a hole's name and a presence mark are OCCURRENCES at their node (pseudo-kids 0 and -1).
--   ⚠ EXACT EXCEPT ONE PLACE: structure ids and position-tree ids are INTERNED (equal iff equal); the map hash is two
--   independent 32-bit lanes (murmur's fmix over the position-tree id), so two different maps collide with probability
--   about 2^-64 per pair. The final id interns (structure, size, lanes).
--   ⚠ SCOPED ONLY: ids are interned in an ID SCOPE (M.id_scope, CART-1412) and mean nothing outside it; the unscoped
--   variant hash stays the stable digest of the renamed term (the wire, persistence).
--   ⚠ A MAP IS TAKEN, NOT COPIED, only inside one pass (the paper's persistence, done by ownership): a summary from an
--   EARLIER call (a memoized row under a window) is copied before it is extended, and a node whose map was taken leaves
--   the memo (it is recomputed if met again).
local bit = require 'bit'
local bxor, band, lshift, rshift, tobit = bit.bxor, bit.band, bit.lshift, bit.rshift, bit.tobit
-- the low 32 bits of a 32 x 32 product, exactly (a double holds 53 bits: multiply by 16-bit halves)
local function mul32(a, b)
    local al, ah, bl, bh = band(a, 0xffff), rshift(a, 16), band(b, 0xffff), rshift(b, 16)
    return tobit(al * bl + lshift(tobit(al * bh + ah * bl), 16))
end
local function fmix(h)
    h = bxor(h, rshift(h, 16)); h = mul32(h, 0x85ebca6b); h = bxor(h, rshift(h, 13)); h = mul32(h, 0xc2b2ae35)
    return bxor(h, rshift(h, 16))
end
-- an ENTRY's two lanes: a function of its position-tree id alone (names dropped: the variant relation)
local function lanes(p) return fmix(bxor(mul32(p, 0x9E3779B1), 0x27D4EB2F)), fmix(bxor(mul32(p, 0x85EBCA77), 0x165667B1)) end
local HERE = 1 -- the position tree of an occurrence at the node itself
local function vstate(scope)
    local st = scope.variant_st
    if not st then
        st = { s = {}, ns = 0, p = {}, np = HERE, v = {}, nv = 0, pass = 0, memo = setmetatable({}, { __mode = 'k' }) }
        scope.variant_st = st
    end
    return st
end
-- the node's own label with its variable names anonymous (a hole's name, a presence mark's)
local function vlabel(u)
    if u.k ~= 'hole' and not u.opt then return M.node_label(u) end
    local c = {}
    for f, x in pairs(u) do if f ~= 'kids' then c[f] = x end end
    if c.opt then c.opt = '*' end
    if c.k == 'hole' then c.h = '*' end
    return M.node_label(c)
end
local function here(name, P) local a, b = lanes(HERE); return { s = 0, vm = { [name] = HERE }, n = 1, z1 = a, z2 = b, pass = P } end
-- a node's summary from its kids' (ks[lo .. #ks]; 0 and -1 are the pseudo-kids, outside the structure)
local function combine(st, lab, ks, lo, P, nosteal)
    local b, bn = nil, 0
    for i = lo, #ks do local k = ks[i]; if k and k.n > bn then b, bn = i, k.n end end
    local sk = {}
    for i = 1, #ks do sk[i] = ks[i].s end
    -- (the paper's SApp flag — which kid's map was the bigger — is NOT in the key: here it is derivable. The structure
    -- shows every variable slot, and each smaller kid holding one appears by its index in a join tagged with this node,
    -- so the bigger is the one slot-bearing kid no join names. MEASURED without it: 0 collisions over every set
    -- partition of up to 6 variable leaves, 888 shapes / 111,138 terms; without the TAG, 17,616)
    local skey = lab .. '(' .. table.concat(sk, ',') .. ')'
    local s = st.s[skey]
    if not s then st.ns = st.ns + 1; s = st.ns; st.s[skey] = s end
    local vm, n, z1, z2 = nil, 0, 0, 0
    if b then
        local big = ks[b]
        if big.pass == P and not nosteal then vm = big.vm; big.vm = nil
        else vm = {}; for v, p in pairs(big.vm) do vm[v] = p end end
        n, z1, z2 = big.n, big.z1, big.z2
    else vm = {} end
    for i = lo, #ks do
        local k = ks[i]
        if k and i ~= b and k.n > 0 then
            for v, p in pairs(k.vm) do
                local old = vm[v]
                local pkey = s .. ',' .. (old or 0) .. ',' .. i .. ',' .. p
                local np = st.p[pkey]
                if not np then st.np = st.np + 1; np = st.np; st.p[pkey] = np end
                if old then local a1, a2 = lanes(old); z1, z2 = bxor(z1, a1), bxor(z2, a2) else n = n + 1 end
                local a1, a2 = lanes(np); z1, z2 = bxor(z1, a1), bxor(z2, a2)
                vm[v] = np
            end
        end
    end
    return { s = s, vm = vm, n = n, z1 = z1, z2 = z2, pass = P }
end
local function summarize(st, u, P, each)
    local m = st.memo[u]
    if m and m.vm then
        -- (a memoized node still names its subterms when every id is asked for: they are summarized — or met in the
        -- memo — on the way down, and nothing above them takes their maps)
        if each then
            for _, c in ipairs(u.kids or {}) do summarize(st, c, P, each) end
            each(u, m)
        end
        return m
    end
    local ks, nodes, lo, seen, dup = {}, {}, 1, {}, false
    if u.kids then
        if u.align == 'keyed' then
            for _, e in ipairs(M.keys(u)) do nodes[#nodes + 1] = e.kid end
        else
            for i, c in ipairs(u.kids) do nodes[i] = c end
        end
        for i, c in ipairs(nodes) do
            local r = summarize(st, c, P, each)
            if seen[r] then dup = true end
            seen[r] = true
            ks[i] = r
        end
    end
    if u.k == 'hole' then ks[0] = here(u.h, P); lo = 0 end
    if u.opt then ks[-1] = here(u.opt, P); lo = -1 end
    local r = combine(st, vlabel(u), ks, lo, P, dup)
    for _, c in ipairs(nodes) do local mc = st.memo[c]; if mc and not mc.vm then st.memo[c] = nil end end
    st.memo[u] = r
    if each then each(u, r) end
    return r
end
local function vid(st, r)
    local key = r.s .. ':' .. r.n .. ':' .. r.z1 .. ':' .. r.z2
    local id = st.v[key]
    if not id then st.nv = st.nv + 1; id = st.nv; st.v[key] = id end
    return id
end
--- the VARIANT id of t inside an ID SCOPE (equal iff t and t' are variants, up to the lanes' 2^-64), its summary
--- memoized in the scope — so a term built from terms already summarized costs only its own nodes
function M.variant_id(t, scope)
    if t == nil then return 0 end
    local st = vstate(scope)
    st.pass = st.pass + 1
    return vid(st, summarize(st, t, st.pass))
end
--- every SUBTERM's variant id in one pass -> { [node] = id } (the subterm tier: two equal ids anywhere are variants)
function M.variant_ids(t, scope)
    local st = vstate(scope)
    st.pass = st.pass + 1
    local out = {}
    summarize(st, t, st.pass, function (u, r) out[u] = vid(st, r) end)
    return out
end

-- ── MODULO TRIVIA (CART-1404): code terms equal ignoring whitespace and comments ────────────────────────────────────
--- t without its TRIVIA: every occurrence its ADAPTER marked `trivia` when it read the code (algebraread: the gaps it
--- keeps between tokens and the nodes the parser reports as extras — comments) dropped at every level; the rest shared,
--- never copied. The marks are made per occurrence by the reader, so the answer is a function of the term alone — no
--- set of kinds learned from earlier reads, and whitespace INSIDE a token (`" "`) is content, never trivia.
function M.strip_trivia(t)
    local function go(u)
        if not u.kids then return u end
        local kids, changed = {}, false
        for _, c in ipairs(u.kids) do
            if type(c) == 'table' and c.trivia then changed = true
            else
                local s = go(c)
                if s ~= c then changed = true end
                kids[#kids + 1] = s
            end
        end
        if not changed then return u end
        return M.rebuild(u, kids)
    end
    return go(t)
end

-- ── LITERAL ────────────────────────────────────────────────────────────────────────────────────────────────────────
M.LITERAL_POLICY = 'lua' -- the one policy implemented: Lua's == (an adapter that needs another declares it; CART-1398)
local function lit_key(t)
    local v = t.v
    return type(v) .. ':' .. (type(v) == 'number' and M.content_num(v) or tostring(v))
end

-- ── THE TABLE ──────────────────────────────────────────────────────────────────────────────────────────────────────
local function by_hash(hash) return function (a, b) return hash(a) < hash(b) end end
local REL = {}
REL.identity = { of = 'any', eq = rawequal, hash = function (x) return x end,
    less = function (a, b) -- (by type first: tostring alone ordered "1" and 1 as one)
        if type(a) ~= type(b) then return type(a) < type(b) end
        return tostring(a) < tostring(b)
    end }
REL.literal = { of = 'lit', eq = function (a, b) return a.k == 'lit' and b.k == 'lit' and lit_key(a) == lit_key(b) end, hash = lit_key }
-- (every term-valued hash takes an optional ID SCOPE third — `M.id_scope()`, CART-1412: interned ids, exact and cheap,
-- meaningful only inside that scope; without one, the stable digest. The second slot is the relation's parameter.)
REL.ordered = { of = 'term', eq = function (a, b) return M.eq(a, b, true) end, hash = function (t, _, scope) return M.content_id(t, scope, true) end }
REL.term = { of = 'term', eq = function (a, b) return M.eq(a, b) end, hash = function (t, _, scope) return M.content_id(t, scope) end }
REL.variant = { of = 'term', eq = function (a, b) return M.eq(M.rename_holes(a), M.rename_holes(b)) end,
    -- (in a scope, the compositional summary — CART-1426; without one, the stable digest of the renamed term)
    hash = function (t, _, scope)
        if scope then return M.variant_id(t, scope) end
        return M.content_id(M.rename_holes(t))
    end }
REL.theory = { of = 'term', parameter = 'theory', eq = function (a, b, theory) return M.eq_mod(a, b, theory) end,
    hash = function (t, theory, scope) return M.content_id(M.canon(t, theory), scope) end }
REL.trivia = { of = 'term',
    eq = function (a, b) return M.eq(M.strip_trivia(a), M.strip_trivia(b)) end,
    hash = function (t, _, scope) return M.content_id(M.strip_trivia(t), scope) end }
REL.bisimilar = { of = 'graph', eq = function (a, b) return (M.tg_bisimilar(a, b)) end }
REL.equivalent = { of = 'template', eq = function (a, b) return M.instance_of(a, b) and M.instance_of(b, a) end }
for _, r in pairs(REL) do if r.hash and not r.less then r.less = by_hash(r.hash) end end
for name, r in pairs(REL) do r.name = name end
M.EQUALITIES = REL

--- the relation called `name` -> { name, of, eq, hash?, less?, parameter? } — an unknown name is REFUSED (an equality
--- nobody can name is not a declared test)
function M.equality(name)
    local r = REL[name]
    if not r then
        local names = vim.tbl_keys(REL); table.sort(names)
        error(('no equality %q (have: %s)'):format(tostring(name), table.concat(names, ', ')), 2)
    end
    return r
end

--- a MEMO keyed by a NAMED relation (Lisp's make-hash-table :test): { get(x), put(x, v), has(x), size() }. A relation
--- with no hash (bisimilar, equivalent) is refused by name; `identity` keys weakly (a dead object leaves the table).
function M.table_by(name, param)
    local r = M.equality(name)
    if not r.hash then error(('equality %q has no hash: a memo cannot key on it'):format(name), 2) end
    local store = name == 'identity' and setmetatable({}, { __mode = 'k' }) or {}
    local n = 0
    local T = {}
    function T.get(x) return store[r.hash(x, param)] end
    function T.has(x) return store[r.hash(x, param)] ~= nil end
    function T.put(x, v)
        local k = r.hash(x, param)
        if store[k] == nil and v ~= nil then n = n + 1 elseif store[k] ~= nil and v == nil then n = n - 1 end
        store[k] = v
    end
    function T.size() return n end
    T.relation = name
    return T
end

end
