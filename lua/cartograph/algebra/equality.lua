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
    hash = function (t, _, scope) return M.content_id(M.rename_holes(t), scope) end }
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
