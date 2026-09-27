-- erlterms — an erlang VALUE expression as an algebra TERM: what a function builds, in the same decoded-record
-- encoding the wire merge unifies on (CART-1112, the term side of CART-1108).
-- @langs erlang
--
-- ★★ THE HARD REVERSES ARE THE SIDE WHERE THE TERM IS COMPUTED, and CART-1112 measured how it is formed at the 184
-- places ejabberd sends a stanza (make_iq_result arg 2, ejabberd_router:route arg 1): a record literal, a variable
-- bound to one, a record update (step 1, an ENCODING); a case/if (step 2, a JOIN over the arms); a call result
-- (step 3, the callee's SUMMARY instantiated at the call); a parameter (step 4, a summary hole); a variable bound by
-- a pattern (step 5, the MATCHED INPUT). Steps 2 and 5 are one mechanism, and step 3 is built from both:
--
-- ★★★ A CLAUSE IS A PATTERN MATCHED AGAINST A SUBJECT. A case arm's pattern against the case's subject, a function
-- clause's head against the call's arguments, a `Pat = Expr` match against its right side. The pattern is encoded
-- as a term whose variables are holes, and A.unify against the subject's term answers THREE-VALUED:
--   no     unify fails, or two literals of different kinds meet (`get` is not `<<"get">>`): the clause is not taken
--   yes    it succeeds binding nothing on the subject side to structure, and there is no guard — FIRST MATCH: no
--          later clause can run
--   maybe  it succeeds only by assuming structure the subject does not state, or a guard decides
-- The value is the JOIN (A.join, the generalization lattice) of the arms that may be taken, up to the first `yes`.
-- A pattern variable's value is what unify bound it to: the subject's part at that position.
--
-- ★★ A CALL IS ITS CALLEE'S CLAUSES, EVALUATED ON DEMAND with the argument terms (a function of this module, or of a
-- module of the tree or of a dependency's source — `program`), memoized on (callee, argument terms). A function
-- that calls ITSELF is a LOOP (see `loop` below: its state and value iterated to a fixpoint over the join lattice);
-- MUTUAL recursion and a call deeper than MAX_DEPTH are holes with their own reasons, counted — no shared solver
-- (CART-1037), and its need is MEASURED on the population, not assumed.
-- Arms that never return (error/exit/throw — the spec's `raises`, a language fact — or a callee every clause of
-- which raises) are dropped from a join rather than generalizing it to a bare hole.
--
-- ENCODING (identical to xmppmerge's client decode, so the two sides unify):
--   #r{f = V}        rec:r(field_1 .. field_n) in the record's DECLARED field order (the ctx's record_fields); a
--                    field the construction does not set takes its DECLARED DEFAULT (`<<>>` -> "", `[]` -> nil,
--                    none -> "undefined": an unset record field IS undefined); a default we cannot read is a hole.
--                    ⚠ IN A PATTERN an unmentioned field is a WILDCARD, never its default.
--   X#r{f = V}       the base's term with those fields replaced; an unknown base leaves the others as holes
--   X#r.f            the base's field
--   [A, B | T]       list(A, B, T…): a FLAT sequence (CART-1130 flat sequences). A tail that is a known list is
--                    spliced in; an unknown tail is a HEDGE hole (?T…, the algebra's sequence variable), so a join of
--                    lists of different lengths is list(?j…) with a repetition claim over its elements, not a bare
--                    hole. A tail known to be something else (an improper list) keeps cons(A, cons(B, T)).
--                    atom / integer / plain binary -> lit (quotes and <<"">> dropped)
--   {A, B}           tuple(A, B)
--   ?NS_X / ?MODULE  the macro's value from the distilled vocabulary / the module's own name; #{} -> map
-- A literal carries `lk` (its kind: atom, bin, str, int, float) beside `v`. A.eq reads only k/v/n/kids, so the wire
-- merge sees `get` and <<"get">> alike, as it must; only clause selection reads lk.
-- ctx = { module, record_fields = fn(rec) -> names | nil, defaults = fn(rec) -> { field -> text } | nil,
--         program = M.program(...) | nil (calls stay holes without one), macros = { name -> value } | nil }
-- -> term, holes { name -> reason }, session  (a whole-hole term means nothing was readable)
local M = {}
local unpack = table.unpack or unpack

local function A() return assert(require('cartograph.algebra').load()) end

M.MAX_DEPTH = 6     -- nested summary evaluations along one path
M.MAX_ALTS = 12     -- the arms kept beside a join that says nothing at the root (S.alts)
M.BUDGET = 20000    -- summary evaluations per session (a runaway guard, counted when hit)
M.UNROLL = 1        -- how many times one function may be on the evaluation stack (1: a recursive call is a hole)

-- the erlang node types a value is spelled in, tabled for the language fence
local T = {
    record = { record_expr = true }, update = { record_update_expr = true }, field = { record_field_expr = true },
    list = { list = true }, pipe = { pipe = true }, tuple = { tuple = true }, var = { var = true },
    atom = { atom = true }, integer = { integer = true }, float = { float = true }, string = { string = true },
    char = { char = true }, binary = { binary = true }, match = { match_expr = true }, paren = { paren_expr = true },
    call = { call = true }, remote = { remote = true }, case = { case_expr = true }, ifx = { if_expr = true },
    clause = { function_clause = true }, arm = { cr_clause = true }, fn = { anonymous_fun = true },
    funclause = { fun_clause = true }, macro = { macro_call_expr = true }, map = { map_expr = true },
    binop = { binary_op_expr = true }, unop = { unary_op_expr = true }, lc = { list_comprehension = true }, try = { try_expr = true },
    generator = { generator = true },
    decl = { fun_decl = true }, funref = { internal_fun = true, external_fun = true }, extfun = { external_fun = true },
}
local RAISES = require('cartograph.spec.erlang').raises or {}
local STUB = require('cartograph.spec.erlang').bif_stub or {}
-- a term with no hole anywhere
local function ground_term(t)
    if t.k == 'hole' or t.k == 'raise' then return false end
    for _, c in ipairs(t.kids or {}) do if not ground_term(c) then return false end end
    return true
end

-- the conversion BIFs: a result when every argument is a known literal, nil otherwise
local function textof(t)
    if t.k == 'lit' and (t.lk == 'bin' or t.lk == 'str' or t.lk == nil) then return tostring(t.v) end
    if t.k == 'list' then
        local out = {}
        for _, c in ipairs(t.kids or {}) do
            local s = textof(c)
            if not s then return nil end
            out[#out + 1] = s
        end
        return table.concat(out)
    end
    return nil
end
local function binlit(v) local l = A().lit(v); l.lk = 'bin'; return l end
local CONVERT = {
    atom_to_binary = function (a) local t = a[1]; return t.k == 'lit' and t.lk == 'atom' and binlit(t.v) or nil end,
    atom_to_list = function (a) local t = a[1]; if t.k == 'lit' and t.lk == 'atom' then local l = A().lit(t.v); l.lk = 'str'; return l end end,
    integer_to_binary = function (a) local t = a[1]; return #a == 1 and t.k == 'lit' and t.lk == 'int' and binlit(t.v) or nil end,
    iolist_to_binary = function (a) local s = textof(a[1]); return s and binlit(s) or nil end,
    list_to_binary = function (a) local s = textof(a[1]); return s and binlit(s) or nil end,
    -- the decoders' direction (dec_enum, dec_int): a known binary back to an atom or an integer
    binary_to_atom = function (a) local t = a[1]; if t.k == 'lit' and (t.lk == 'bin' or t.lk == nil) then local l = A().lit(t.v); l.lk = 'atom'; return l end end,
    binary_to_existing_atom = function (a) local t = a[1]; if t.k == 'lit' and (t.lk == 'bin' or t.lk == nil) then local l = A().lit(t.v); l.lk = 'atom'; return l end end,
    binary_to_integer = function (a)
        local t = a[1]
        local n = #a == 1 and t.k == 'lit' and (t.lk == 'bin' or t.lk == nil) and tostring(t.v):match('^%s*([+-]?%d+)%s*$')
        if n then local l = A().lit(tostring(tonumber(n))); l.lk = 'int'; return l end
    end,
    integer_to_list = function (a) local t = a[1]; if #a == 1 and t.k == 'lit' and t.lk == 'int' then local l = A().lit(t.v); l.lk = 'str'; return l end end,
    list_to_atom = function (a) local t = a[1]; if t.k == 'lit' and (t.lk == 'str' or t.lk == nil) then local l = A().lit(t.v); l.lk = 'atom'; return l end end,
    byte_size = function (a)
        local t = a[1]
        if t.k == 'lit' and (t.lk == 'bin' or t.lk == nil) then local l = A().lit(tostring(#tostring(t.v))); l.lk = 'int'; return l end
    end,
}
-- THE NIFs' MEANING, for the few stubs xmpp's codecs call (a stub body is erlang:nif_error: the C implementation's
-- documented behaviour is all there is). Known arguments only; anything else stays the stub's hole.
local function flat_known(t)
    if t.k ~= 'list' then return nil end
    for _, c in ipairs(t.kids or {}) do if c.k == 'hole' then return nil end end
    return t.kids or {}
end
local STUB_EVAL = {
    ['lists:member/2'] = function (a)
        local xs = flat_known(a[2])
        if not xs or not ground_term(a[1]) then return nil end
        for _, y in ipairs(xs) do
            if ground_term(y) and A().eq(a[1], y) and (a[1].lk == nil or y.lk == nil or a[1].lk == y.lk) then return A().lit('true') end
        end
        for _, y in ipairs(xs) do if not ground_term(y) then return nil end end
        local f = A().lit('false'); f.lk = 'atom'; return f
    end,
    ['lists:reverse/2'] = function (a)
        local xs = flat_known(a[1])
        if not xs or a[2].k ~= 'list' then return nil end
        local out = {}
        for i = #xs, 1, -1 do out[#out + 1] = xs[i] end
        for _, y in ipairs(a[2].kids or {}) do out[#out + 1] = y end
        return A().node('list', unpack(out, 1, #out))
    end,
    ['lists:keyfind/3'] = function (a)
        local n = a[2].k == 'lit' and a[2].lk == 'int' and tonumber(a[2].v)
        local xs = flat_known(a[3])
        if not (n and xs and ground_term(a[1])) then return nil end
        for _, y in ipairs(xs) do
            local k = (y.k == 'tuple' or y.k:match('^rec:')) and (y.k == 'tuple' and y.kids[n] or (n == 1 and A().lit(y.k:sub(5)) or y.kids[n - 1]))
            if not k or not ground_term(k) then return nil end
            if A().eq(k, a[1]) then return y end
        end
        local f = A().lit('false'); f.lk = 'atom'; return f
    end,
}
-- the type-test guard BIFs and the literal node kinds each admits (the spec's guard_kinds, a language fact)
local GUARD_KINDS = require('cartograph.spec.erlang').guard_kinds or {}

-- the macro vocabulary the erlang spec reads call arguments with (erl-macros, distilled from the dependency's
-- headers by tools/hrldistill.lua): ?NS_DISCO_INFO -> its URI
local MACROS
local function macros()
    if MACROS == nil then
        local ok, prof = pcall(require, 'cartograph.spec.profile')
        local a = ok and prof and prof.load and prof.load('erl-macros')
        MACROS = a and a.values or false
    end
    return MACROS or nil
end

local function txt(n, src) return vim.treesitter.get_node_text(n, src) end
local function lit(v, lk) local l = A().lit(v); l.lk = lk; return l end
local RAISE = { k = 'raise' }   -- the value of an expression that never returns; never leaves this module
local binop                     -- the operators (defined beside M.eval)
local comprehension             -- list comprehensions (defined beside M.eval)

local function named(x)
    local out = {}
    if x then for c in x:iter_children() do if c:named() then out[#out + 1] = c end end end
    return out
end
local function last_expr(clause)
    local body = clause:field('body')[1]
    local l
    for _, c in ipairs(body and body:field('exprs') or {}) do l = c end
    return l
end
-- a guard decides the clause (a literal `true` guard does not)
local function guarded(clause, src)
    local g = clause:field('guard')[1]
    return g ~= nil and vim.trim(txt(g, src)) ~= 'true'
end

-- a term's truth: lit true / lit false (atoms, or a literal of unknown kind) / nil when not known
local function truth(t)
    if t and t.k == 'lit' and (t.lk == 'atom' or t.lk == nil) then
        if t.v == 'true' then return true elseif t.v == 'false' then return false end
    end
    return nil
end

--- ★ A GUARD IS EVALUATED, THREE-VALUED (CART-1135: `if El == undefined -> []; true -> [El] end` in
--- xmpp:make_iq_result joined [] with [El] because every guard read as "maybe"). A guard is a disjunction (`;`) of
--- conjunctions (`,`) of expressions, each evaluated with the clause's own bindings: all true -> yes, any false ->
--- that conjunction is no, otherwise maybe. -> 'yes' | 'no' | 'maybe'
function M.guard(clause, env, S)
    local g = clause:field('guard')[1]
    if not g then return 'yes' end
    if M.OFF.guards then return 'yes' end
    if M.OFF.guardeval then return guarded(clause, env.src) and 'maybe' or 'yes' end
    local any_maybe = false
    for _, gc in ipairs(g:field('clauses')) do
        local conj = 'yes'
        for _, e in ipairs(gc:field('exprs')) do
            local v = truth(M.eval(e, env, S))
            if v == false then conj = 'no'; break end
            if v == nil then conj = 'maybe' end
        end
        if conj == 'yes' then return 'yes' end
        if conj == 'maybe' then any_maybe = true end
    end
    return any_maybe and 'maybe' or 'no'
end

-- ── the session: hole names, their reasons, the summary memo and counters ────────────────────────────────────────
function M.session()
    return { n = 0, reasons = {}, domains = {}, kinds = {}, alts = {}, hedges = {}, elems = {}, memo = {}, stack = {}, depth = 0, evals = 0, top = {},
        funs = {}, nfun = 0, loops = {}, stats = { applies = 0, stubs = 0, unfolded = 0, refused = 0, onepass = 0, recursive = 0, depth = 0, budget = 0, summaries = 0, memo_hits = 0, loops = 0,
            iterations = 0, unconverged = 0 } }
end

local function fresh(S, why, prefix)
    S.n = S.n + 1
    local h = (prefix or 'V') .. S.n
    S.reasons[h] = why
    return A().hole(h)
end

local function subst(t, map)
    if t.k == 'hole' then return map[t.h] or t end
    if not t.kids then return t end
    local kids, changed = {}, false
    for _, c in ipairs(t.kids) do
        local v = subst(c, map)
        changed = changed or v ~= c
        -- a hedge variable's value is a seq: it SPLICES into its parent's children, it is not one child
        if v.k == 'seq' and c.k == 'hole' then
            for _, x in ipairs(v.kids or {}) do kids[#kids + 1] = x end
        else kids[#kids + 1] = v end
    end
    return changed and A().rebuild(t, kids) or t
end

-- ── FLAT LISTS: list(e1 … en), a hedge hole for an unknown rest ────────────────────────────────────────────────────
-- the hedge hole standing for an unknown tail term `t` (one per term hole, so the same Rest is the same sequence)
local function hedge_of(S, t)
    local h = S.hedges[t.h]
    if not h then
        S.n = S.n + 1
        h = A().hole('R' .. S.n, true)
        S.reasons[h.h] = S.reasons[t.h] or 'the rest of a list'
        S.hedges[t.h] = h
    end
    return h
end
local function hfresh(S, why)
    S.n = S.n + 1
    local h = A().hole('R' .. S.n, true)
    S.reasons[h.h] = why
    return h
end
-- [items | tail]: splice a known list, a hedge for an unknown one, cons for an improper tail
local function mklist(S, items, tail)
    local a = A()
    if tail == nil then return a.node('list', unpack(items, 1, #items)) end
    if tail.k == 'list' then
        local kids = {}
        for _, x in ipairs(items) do kids[#kids + 1] = x end
        for _, x in ipairs(tail.kids or {}) do kids[#kids + 1] = x end
        return a.node('list', unpack(kids, 1, #kids))
    end
    if tail.k == 'hole' then
        local kids = {}
        for _, x in ipairs(items) do kids[#kids + 1] = x end
        kids[#kids + 1] = tail.rep and tail or hedge_of(S, tail)
        return a.node('list', unpack(kids, 1, #kids))
    end
    local tm = tail
    for i = #items, 1, -1 do tm = a.node('cons', items[i], tm) end
    return tm
end
M.mklist = function (items, tail, S) return mklist(S or M.session(), items, tail) end

local function has_raise(kids) for _, c in ipairs(kids) do if c == RAISE then return true end end return false end
local function mk(k, kids) if has_raise(kids) then return RAISE end return A().node(k, unpack(kids, 1, #kids)) end

-- ── three-valued match of a pattern term against a subject term ─────────────────────────────────────────────────
-- two literals whose kinds differ never match, though A.eq (the wire's view) calls them equal
local function kinds_clash(p, s)
    if p.k == 'hole' or s.k == 'hole' then return false end
    if p.k == 'lit' and s.k == 'lit' then return p.lk ~= nil and s.lk ~= nil and p.lk ~= s.lk end
    if p.k ~= s.k or not p.kids or not s.kids or #p.kids ~= #s.kids then return false end
    for i = 1, #p.kids do if kinds_clash(p.kids[i], s.kids[i]) then return true end end
    return false
end

-- ★ A RECORD IS A TUPLE: #r{f1 .. fn} is {r, f1 .. fn}, and generated code matches it that way (xmpp_codec's
-- get_mod({message, _, …})). Matching reads both sides as tuples; the values it binds are read back as records.
local function as_tuples(t, arity)
    if not t.kids then return t end
    local kids = {}
    for i, c in ipairs(t.kids) do kids[i] = as_tuples(c, arity) end
    local r = t.k:match('^rec:(.+)$')
    if r then
        arity[r] = #kids
        table.insert(kids, 1, lit(r, 'atom'))
        return A().node('tuple', unpack(kids, 1, #kids))
    end
    return A().rebuild(t, kids)
end
local function as_records(t, arity)
    if not t.kids then return t end
    local kids = {}
    for i, c in ipairs(t.kids) do kids[i] = as_records(c, arity) end
    local h = kids[1]
    if t.k == 'tuple' and h and h.k == 'lit' and arity[h.v] == #kids - 1 then
        return A().node('rec:' .. h.v, unpack(kids, 2, #kids))
    end
    return A().rebuild(t, kids)
end

--- 'no' | 'yes' | 'maybe', and the pattern holes' values (terms over the subject's holes)
-- ★★ YES MEANS THE SUBJECT CERTAINLY MATCHES. Unify treats every hole as a variable, but only the pattern's OWN
-- holes (the fresh variables and wildcards it minted: the set `mine`) are free to bind. A subject hole bound to
-- anything but one of them — structure, another subject hole, or a hole the pattern took from an already-bound
-- variable (`case get_name(El) of TagName -> …` with TagName a parameter) — is an ASSUMPTION: maybe. Taken as yes,
-- that arm ended the first match and every later arm was lost (match_tag with unknown arguments answered `true`).
local function own(h, mine)
    if not mine then return true end
    return mine[h] == true or mine[h] == 'constrained'
end

function M.match(pat, subj, mine)
    local a = A()
    local arity = {}
    pat, subj = as_tuples(pat, arity), as_tuples(subj, arity)
    if not M.OFF.kinds and kinds_clash(pat, subj) then return 'no' end
    local U, why = a.unify(a.template(pat), a.template(subj))
    if not U then
        -- a STRUCTURAL clash is no; a refusal (a budget, several hedges in one list, a shape unify does not solve,
        -- a join's summary domain) is not knowledge: the arm may run
        local w = tostring(why or '')
        if w:match('^kind ') or w:match('^literal ') or w:match('^name ') or w:match('^arity') or w:match('no finite instance') then
            return 'no'
        end
        return 'maybe', {}, w
    end
    local verdict, back = 'yes', {}
    for g, t in pairs(U.right) do
        if t.k == 'hole' then
            if t.h ~= g then
                -- two subject holes meeting in one pattern variable ({Z, Z} against {X, Y}) is an equality nobody knows
                if back[t.h] and not M.OFF.own then verdict = 'maybe' end
                back[t.h] = a.hole(g)
                if not own(t.h, mine) and not M.OFF.own then verdict = 'maybe' end
            end
        else
            verdict = 'maybe'
        end
    end
    -- a hole the pattern did not create (a bound variable's value) must stay itself
    for h, t in pairs(U.left) do
        if not own(h, mine) and not M.OFF.own and not (t.k == 'hole' and (t.h == h or back[t.h])) then verdict = 'maybe' end
    end
    local vals = {}
    for h, t in pairs(U.left) do vals[h] = as_records(subst(t, back), arity) end
    -- a constrained hole (a pattern we cannot read) never makes the match certain
    if verdict == 'yes' and mine then
        for h in pairs(U.left) do if mine[h] == 'constrained' then verdict = 'maybe'; break end end
    end
    return verdict, vals
end

-- ── the join of several arm values, reasons carried through ─────────────────────────────────────────────────────
local function join_all(S, vals, why_empty, why_diff)
    local a = A()
    local live = {}
    for _, v in ipairs(vals) do if v ~= RAISE then live[#live + 1] = v end end
    if #live == 0 then return #vals > 0 and RAISE or fresh(S, why_empty) end
    local acc = live[1]
    for i = 2, #live do
        local J = a.join(a.template(acc), a.template(live[i]))
        if not J then return fresh(S, 'arms that do not join') end
        -- a hole the join KEPT (the same hole on both sides) keeps its reason; every other one is new
        local ren = {}
        for n, f in pairs(J.frags or {}) do
            local kept = f.left and f.left.k == 'hole' and f.left.h == n and f.right and f.right.k == 'hole' and f.right.h == n
            if not kept then
                local hr = J.template.holes[n]
                if hr and hr.rep then
                    -- a SEQUENCE the arms disagree on the length of: a hedge hole, and its elements' template
                    ren[n] = hfresh(S, why_diff and (why_diff .. ' (a sequence)') or 'the arms differ here (a sequence: a list of …)')
                    local els = {}
                    for _, side in ipairs { f.left, f.right } do
                        if side and side.k == 'seq' then
                            for _, x in ipairs(side.kids or {}) do
                                if x.k == 'hole' and x.rep then
                                    for _, y in ipairs(S.elems[x.h] or {}) do els[#els + 1] = y end
                                else els[#els + 1] = x end
                            end
                        elseif side and side.k == 'hole' and side.rep then
                            for _, y in ipairs(S.elems[side.h] or {}) do els[#els + 1] = y end
                        elseif side and side.k ~= 'hole' then els[#els + 1] = side end
                    end
                    if #els > 0 then S.elems[ren[n].h] = els end
                else
                    ren[n] = fresh(S, why_diff or 'the arms differ here (a join)')
                end
                -- the join's DOMAIN for the hole: which values or kinds the arms put there (A.join's summary)
                local d = J.template.holes[n] and J.template.holes[n].domain
                if d then S.domains[ren[n].h] = d end
            end
        end
        acc = subst(J.template.body, ren)
    end
    -- ★ THE LATTICE HAS NO UNION: arms of different kinds (#iq, #message, #presence out of xmpp:set_from_to on an
    -- unknown stanza) generalize to a bare hole. The set of kinds the arms had is kept beside it (S.kinds), so a
    -- consumer can still say "one of these records" where the term says nothing.
    -- ★ AND THE ARMS THEMSELVES, when the join says nothing at the root: the lgg of an error reply, a result reply and
    -- an unknown is a bare hole, but "one of these replies" is what a reader asks (CART-1135's response leg). Kept
    -- beside the hole (S.alts, capped, a hole arm's own alternatives flattened in) — the union the lattice lacks.
    if acc.k == 'hole' and #live > 1 then
        local alts, seen_alt, opened = {}, {}, {}
        local function add(v)
            if v.k == 'hole' and S.alts[v.h] then
                -- a hole's alternatives can mention a hole whose own do (a loop's value joined into itself): once each
                if opened[v.h] then return end
                opened[v.h] = true
                for _, w in ipairs(S.alts[v.h]) do add(w) end
                return
            end
            local key = v.k == 'hole' and ('?' .. (S.reasons[v.h] or '')) or A().show(v)
            if not seen_alt[key] and #alts < M.MAX_ALTS then seen_alt[key] = true; alts[#alts + 1] = v end
        end
        for _, v in ipairs(live) do add(v) end
        S.alts[acc.h] = alts
    end
    if acc.k == 'hole' and #live > 1 then
        local ks, seen = {}, {}
        for _, v in ipairs(live) do
            if v.k == 'hole' then ks = nil; break end
            if not seen[v.k] then seen[v.k] = true; ks[#ks + 1] = v.k end
        end
        if ks then
            table.sort(ks)
            S.kinds[acc.h] = ks
            S.reasons[acc.h] = 'one of ' .. table.concat(ks, ' | ') .. ' (a join of different kinds)'
        end
    end
    return acc
end

-- a declared default's TEXT as a term, when it is a literal we can read
local function default_term(text, S)
    local a = A()
    if text == nil then return lit('undefined', 'atom') end
    text = vim.trim(text):gsub('%s*::.*$', '')
    if text == '<<>>' or text == '<<"">>' then return lit('', 'bin') end
    if text == '[]' then return a.node('list') end
    if text == '#{}' then return a.node('map') end
    local b = text:match('^<<"(.*)">>$')
    if b then return lit(b, 'bin') end
    if text:match('^[a-z][%w_@]*$') then return lit(text, 'atom') end
    if text:match("^'.*'$") then return lit(text:sub(2, -2), 'atom') end
    if text:match('^%-?%d+$') then return lit(text, 'int') end
    return fresh(S, 'default ' .. text)
end

local function rec_name(x, src)
    local rn = x:field('name')[1]
    rn = rn and (rn:field('name')[1] or rn)
    return rn and txt(rn, src)
end

-- is `nm` (the variable at `n`, inside a pattern) bound BEFORE that pattern: in an enclosing head, an enclosing
-- arm's pattern, or a `Pat = Expr` match earlier in the clause body — erlang's "a bound name in a pattern is a test"
local function bound_before(n, nm, src)
    local function has(x)
        if T.var[x:type()] and txt(x, src) == nm then return true end
        for c in x:iter_children() do if c:named() and has(c) then return true end end
        return false
    end
    local function within(a, b)
        local sr, sc, er, ec = a:range()
        local osr, osc, oer, oec = b:range()
        return (sr > osr or (sr == osr and sc >= osc)) and (er < oer or (er == oer and ec <= oec))
    end
    local at = select(3, n:start())
    local x = n:parent()
    while x do
        local t = x:type()
        if T.clause[t] or T.funclause[t] then
            local args = x:field('args')[1]
            if args and not within(n, args) and has(args) then return true end
            local found = false
            local function walk(y)
                for c in y:iter_children() do
                    if found or select(3, c:start()) >= at then return end
                    if T.match[c:type()] then
                        local l = c:field('lhs')[1]
                        if l and not within(n, l) and has(l) then found = true; return end
                    end
                    if not T.fn[c:type()] then walk(c) end
                end
            end
            walk(x:field('body')[1] or x)
            if found then return true end
            if T.clause[t] then return false end
        elseif T.arm[t] then
            local pat = x:field('pat')[1]
            if pat and not within(n, pat) and has(pat) then return true end
        end
        x = x:parent()
    end
    return false
end

-- ── PATTERNS: a term whose variables are holes; `binds` maps each variable to its term ───────────────────────────
-- a variable env.vars already binds is a CONSTRAINT (erlang: a bound name in a pattern is a match test)
function M.pattern(x, env, S)
    local src, ctx = env.src, env.ctx
    local mine = {}        -- the holes this pattern mints: its own variables and wildcards
    local function pfresh(why) local h = fresh(S, why, 'p'); mine[h.h] = true; return h end
    -- ★ A PATTERN WE CANNOT READ IS NOT A WILDCARD: a binary pattern (<<"!", Rest/binary>>), a map pattern, a record
    -- with no declaration in scope STILL REJECTS what does not fit. Its hole is the pattern's own but CONSTRAINED:
    -- a match through it is at most maybe (mine[h] = 'constrained'), or first-match would stop at it and every
    -- later clause would read unreachable (CART-1110: parse_single_what, route_probe_reply).
    local function cfresh(why) local h = fresh(S, why, 'p'); mine[h.h] = M.OFF.constrained and true or 'constrained'; return h end
    local binds = {}
    -- only `_` is a wildcard: `_X` is a variable like any other (it merely silences the unused warning)
    local function real(n) local nm = n and T.var[n:type()] and txt(n, src); return nm and nm ~= '_' and nm or nil end
    local conv
    function conv(n)
        local t = n:type()
        if T.paren[t] then return conv(n:named_child(0)) end
        if T.match[t] then
            -- `Pat = Var` / `Var = Pat` inside a pattern: an ALIAS, both sides are one value
            local l, r = n:field('lhs')[1], n:field('rhs')[1]
            local lv, rv = real(l), real(r)
            if rv and not lv and not env.vars[rv] then local p = conv(l); binds[rv] = binds[rv] or p; return p end
            if lv and not rv and not env.vars[lv] then local p = conv(r); binds[lv] = binds[lv] or p; return p end
            local p = conv(l)
            if rv and not env.vars[rv] and not binds[rv] then binds[rv] = p end
            return p
        end
        if T.var[t] then
            local nm = real(n)
            if not nm then return pfresh('a wildcard') end
            if env.vars[nm] then return env.vars[nm] end
            -- already bound where the function's arguments are unknown (a head variable, an earlier match): a
            -- CONSTRAINT, its value the variable's, never a fresh binder
            if not binds[nm] and not M.OFF.own and bound_before(n, nm, src) then return M.eval(n, env, S) end
            if not binds[nm] then binds[nm] = pfresh('pattern variable ' .. nm) end
            return binds[nm]
        end
        if T.record[t] then
            local rec = rec_name(n, src)
            local names = rec and ctx.record_fields and ctx.record_fields(rec)
            if not names then return cfresh('a record pattern with no declaration in scope') end
            local set = {}
            for _, rf in ipairs(n:field('fields')) do
                local fname = rf:field('name')[1]
                local fe = rf:field('expr')[1]
                local vn = fe and (fe:field('expr')[1] or fe)
                if fname and vn then set[txt(fname, src)] = conv(vn) end
            end
            local kids = {}
            for i, f in ipairs(names) do
                kids[i] = set[f] or (M.OFF.wildcards and default_term((ctx.defaults and ctx.defaults(rec) or {})[f], S))
                    or pfresh('a field the pattern does not mention')
            end
            return A().node('rec:' .. rec, unpack(kids, 1, #names))
        end
        if T.list[t] then
            local items, tail = {}, nil
            for _, c in ipairs(n:field('exprs')) do
                if T.pipe[c:type()] then
                    items[#items + 1] = conv(c:field('lhs')[1])
                    local r = c:field('rhs')[1]
                    local nm = r and real(r)
                    if r and T.var[r:type()] and not nm then tail = hfresh(S, 'a wildcard'); mine[tail.h] = true
                    elseif nm and not env.vars[nm] and not binds[nm] and not bound_before(r, nm, src) then
                        -- the tail VARIABLE of a pattern binds a SEQUENCE: a hedge hole, its value a list
                        tail = hfresh(S, 'pattern variable ' .. nm)
                        mine[tail.h] = true
                        binds[nm] = tail
                    else tail = conv(r) end
                else items[#items + 1] = conv(c) end
            end
            return mklist(S, items, tail)
        end
        if T.tuple[t] then
            local items = {}
            for _, c in ipairs(n:field('expr')) do items[#items + 1] = conv(c) end
            return A().node('tuple', unpack(items, 1, #items))
        end
        if T.binary[t] then
            -- a binary PATTERN binds its segments (<<Prefix:3/binary, Rest/binary>>): only an all-string one is a
            -- constant; evaluating the segments would look up the very variables this pattern binds (a loop)
            for _, e in ipairs(n:field('elements')) do
                local el = e:field('element')[1]
                if not el or not T.string[el:type()] or e:field('size')[1] or e:field('types')[1] then
                    return cfresh('a binary pattern')
                end
            end
        end
        if T.atom[t] or T.integer[t] or T.string[t] or T.char[t] or T.float[t] or T.macro[t] or T.binary[t] then
            local v = M.eval(n, env, S)
            if v.k == 'lit' then return v end
            return cfresh('a pattern constant we cannot read')
        end
        return cfresh('a ' .. t .. ' pattern')
    end
    return conv(x), binds, mine
end

-- bind a pattern against a subject: the verdict and the variables' values
local function bind(patnode, subj, env, S)
    local p, binds, mine = M.pattern(patnode, env, S)
    local verdict, vals, refused = M.match(p, subj, mine)
    if refused then S.stats.refused = S.stats.refused + 1 end
    if verdict == 'no' then return 'no' end
    local out = {}
    for nm, t in pairs(binds) do
        local v = subst(t, vals)
        -- a tail variable bound a sequence: as a value it is the list of those elements
        if t.k == 'hole' and t.rep then
            if v.k == 'seq' then v = A().node('list', unpack(v.kids or {}, 1, #(v.kids or {})))
            elseif v.k == 'hole' then v = A().node('list', v) end
        end
        -- still the pattern's own hole: the variable names a part of the subject the subject does not state
        if v.k == 'hole' and (S.reasons[v.h] or ''):match('^pattern variable') then
            S.reasons[v.h] = nm .. ': a part of the subject it does not state'
        end
        out[nm] = v
    end
    return verdict, out
end

local function with_vars(env, add)
    local vars = setmetatable({}, { __index = env.vars })
    for k, v in pairs(add or {}) do vars[k] = v end
    return { src = env.src, ctx = env.ctx, vars = vars, args = env.args, fname = env.fname }
end

-- ── VARIABLES: head binders, enclosing case arms, `Pat = Expr` matches before the use ────────────────────────────
local function contains_var(n, name, src)
    if T.var[n:type()] and txt(n, src) == name then return true end
    for c in n:iter_children() do if c:named() and contains_var(c, name, src) then return true end end
    return false
end
local function inside(n, outer)
    local sr, sc, er, ec = n:range()
    local osr, osc, oer, oec = outer:range()
    return (sr > osr or (sr == osr and sc >= osc)) and (er < oer or (er == oer and ec <= oec))
end

local function site_key(x, env) return (env.ctx.module or env.src:sub(1, 64)) .. ':' .. select(3, x:start()) end

-- the variable's value where the function's own arguments are NOT known: the head pattern against a parameter hole.
-- ONE binding per (clause, argument), cached, so every variable of one pattern shares its holes (`to = I` is the
-- very hole the pattern bound to `id`)
local function from_head(x, p, i, name, env, S)
    local src = env.src
    -- keyed by the module and the byte where the clause starts: a node id is unique only within ITS tree, and
    -- one session spans every file
    local key = site_key(x, env) .. '#' .. i
    local b = S.top[key]
    if not b then
        local fname = (x:field('name')[1] and txt(x:field('name')[1], src) or '?') .. '/' .. #named(x:field('args')[1])
        local param = fresh(S, ('parameter %d of %s'):format(i, fname))
        b = { param = param, vals = {} }
        if not T.var[p:type()] and not M.OFF.pattern then
            local verdict, vals = bind(p, param, env, S)
            b.no = verdict == 'no'
            for nm, v in pairs(vals or {}) do
                if v.k == 'hole' and (S.reasons[v.h] or ''):match(': a part of the subject it does not state$') then
                    S.reasons[v.h] = ('%s: part of parameter %d of %s'):format(nm, i, fname)
                end
                b.vals[nm] = v
            end
        end
        S.top[key] = b
    end
    if T.var[p:type()] then return b.param end
    if M.OFF.pattern then return fresh(S, name .. ': bound by a pattern') end
    if b.no then return fresh(S, name .. ': a head no argument can match') end
    return b.vals[name] or fresh(S, name .. ': bound in the head')
end

-- a `Pat = Expr` match before the use, in this clause's body (erlang binds once per clause); nil when there is none
local function matched(x, var, name, at, env, S)
    local src = env.src
    local found
    local function walk(y)
        for c in y:iter_children() do
            if found or select(3, c:start()) >= at then return end
            if T.match[c:type()] then
                local l = c:field('lhs')[1]
                if l and contains_var(l, name, src) then found = c; return end
            end
            if not T.fn[c:type()] then walk(c) end
        end
    end
    walk(x:field('body')[1] or x)
    if not found then return nil end
    local l, r = found:field('lhs')[1], found:field('rhs')[1]
    if (S.chain or 0) >= 8 then return fresh(S, name .. ' (binding chain too long)') end
    S.chain = (S.chain or 0) + 1
    local rt = r and M.eval(r, env, S) or fresh(S, 'nothing')
    S.chain = S.chain - 1
    if T.var[l:type()] then return rt end
    if rt == RAISE then return RAISE end
    if M.OFF.pattern then return fresh(S, name .. ': bound by a pattern') end
    local verdict, vals = bind(l, rt, env, S)
    if verdict == 'no' then return fresh(S, name .. ': a match that cannot succeed') end
    return vals[name] or fresh(S, name .. ': bound by a match')
end

local function lookup(var, env, S)
    -- a runaway chain of lookups (a binding that reaches itself through arms and matches) ends as a hole
    S.lookups = (S.lookups or 0) + 1
    if S.lookups > 200 then S.lookups = S.lookups - 1; return fresh(S, 'a binding chain too long to follow') end
    local r = M._lookup(var, env, S)
    S.lookups = S.lookups - 1
    return r
end
function M._lookup(var, env, S)
    local src = env.src
    -- a BYTE offset: node:start() returns row, col, byte, and a row alone hides a match on the use's own line
    local name, at = txt(var, src), select(3, var:start())
    local v = env.vars[name]
    if v then return v end
    local x = var:parent()
    while x do
        local t = x:type()
        if T.arm[t] then
            local pat = x:field('pat')[1]
            if pat and not inside(var, pat) and contains_var(pat, name, src) then
                if M.OFF.pattern then return fresh(S, name .. ': bound by a pattern') end
                -- one binding per arm (cached where the function's arguments are unknown), so the arm's variables
                -- share their holes
                local key = not env.args and ('arm' .. site_key(x, env))
                local b = key and S.top[key]
                if not b then
                    local case = x:parent()
                    local subj = case and T.case[case:type()] and case:field('expr')[1]
                    local st = subj and M.eval(subj, env, S) or fresh(S, 'a receive/try subject')
                    if st == RAISE then return RAISE end
                    local verdict, vals = bind(pat, st, env, S)
                    b = { no = verdict == 'no', vals = vals or {} }
                    if key then S.top[key] = b end
                end
                if b.no then return fresh(S, name .. ': an arm the subject cannot take') end
                return b.vals[name] or fresh(S, name .. ': bound by a pattern')
            end
        elseif T.funclause[t] then
            local args = x:field('args')[1]
            if args and contains_var(args, name, src) then return fresh(S, name .. ': a fun parameter') end
            -- bound inside the fun's own body, or else a variable the fun closes over (keep walking out)
            local r = matched(x, var, name, at, env, S)
            if r then return r end
        elseif T.clause[t] then
            local args = x:field('args')[1]
            for i, p in ipairs(named(args)) do
                if contains_var(p, name, src) then
                    -- with the arguments known the head already bound it; reaching here means it did not
                    if env.args then return fresh(S, name .. ': unbound by the head') end
                    return from_head(x, p, i, name, env, S)
                end
            end
            local r = matched(x, var, name, at, env, S)
            return r or fresh(S, name .. ': unbound before its use')
        end
        x = x:parent()
    end
    return fresh(S, name .. ': no clause')
end

-- ── CALLS: the callee's clauses against the argument terms ──────────────────────────────────────────────────────
-- the clauses of `id` against `args`, first match: the value of each clause that may run
local function run_clauses(m, id, clauses, args, S)
    local vals = {}
    for _, cl in ipairs(clauses) do
        local cenv = { src = m.src, ctx = m.ctx, vars = {}, args = args, fname = id }
        local verdict = 'yes'
        for i, p in ipairs(named(cl:field('args')[1])) do
            local v, bv = bind(p, args[i], cenv, S)
            if v == 'no' then verdict = 'no'; break end
            if v == 'maybe' then verdict = 'maybe' end
            for nm, t in pairs(bv) do cenv.vars[nm] = t end
        end
        if verdict ~= 'no' then
            local gv = M.guard(cl, cenv, S)
            if gv == 'no' then verdict = 'no' elseif gv == 'maybe' then verdict = 'maybe' end
        end
        if verdict ~= 'no' then
            local le = last_expr(cl)
            vals[#vals + 1] = le and M.eval(le, cenv, S) or fresh(S, 'an empty body')
            if verdict == 'yes' then break end
        end
    end
    return vals
end

--- THE DEFINITIONS a call may run: one normally; for -ifdef variants every one, or the one a VANTAGE decides
--- (P.defines = { MACRO = true | false }: each definition's condition path, read from the file's -ifdef regions, must
--- agree with it). -> { run… } (a run = the definition's clauses, in order)
function M.variants(P, m, key)
    local runs = (m.defs and m.defs[key]) or { m.fns[key] }
    if #runs < 2 or M.OFF.variants then
        if #runs >= 2 then
            local flat = {}
            for _, r in ipairs(runs) do for _, c in ipairs(r) do flat[#flat + 1] = c end end
            return { flat }
        end
        return runs
    end
    if P and P.defines then
        local V = require 'cartograph.erlvariants'
        m.regions = m.regions or require('cartograph.erlfeatures').regions(m.path)
        local agree = {}
        for _, run in ipairs(runs) do
            local path = V.path_at(m.regions, run[1]:start() + 1)
            local ok, decided = true, false
            for macro, pol in pairs(path) do
                local d = P.defines[macro]
                if d ~= nil then
                    decided = true
                    if d ~= pol then ok = false end
                end
            end
            if ok and decided then agree[#agree + 1] = run end
        end
        if #agree == 1 then return agree end
    end
    return runs
end

--- WHICH CLAUSE a call selects, without evaluating a body: each clause's verdict ('yes' | 'maybe' | 'no') for the
--- argument terms — its head patterns and its guard, first match. The generated peer's contract check (peergen,
--- CART-1138): the request built for clause k must leave every earlier clause at 'no'.
--- -> { verdict… } in clause order, { definition index… } per clause (first match is within one) | nil, why
function M.clause_verdicts(P, mod, fn, args, S)
    S = S or M.session()
    local m = P:module(mod)
    if not m then return nil, 'no source for ' .. tostring(mod) end
    local clauses = m.fns[fn .. '/' .. #args]
    if not clauses then return nil, ('%s:%s/%d not defined'):format(mod, fn, #args) end
    -- which definition each clause belongs to (first match is WITHIN a definition: -ifdef variants are separate)
    local run_of = {}
    for ri, run in ipairs((m.defs and m.defs[fn .. '/' .. #args]) or { clauses }) do
        for _, c in ipairs(run) do run_of[c] = ri end
    end
    local out, runs = {}, {}
    for ci, cl in ipairs(clauses) do
        runs[ci] = run_of[cl] or 1
        local cenv = { src = m.src, ctx = m.ctx, vars = {}, args = args, fname = mod .. ':' .. fn }
        local verdict = 'yes'
        for i, p in ipairs(named(cl:field('args')[1])) do
            local v, bv = bind(p, args[i], cenv, S)
            if v == 'no' then verdict = 'no'; break end
            if v == 'maybe' then verdict = 'maybe' end
            for nm, t in pairs(bv) do cenv.vars[nm] = t end
        end
        if verdict ~= 'no' then
            local gv = M.guard(cl, cenv, S)
            if gv == 'no' then verdict = 'no' elseif gv == 'maybe' then verdict = 'maybe' end
        end
        out[#out + 1] = verdict
    end
    return out, runs
end

local function iso(x, y)
    if x == RAISE or y == RAISE then return x == y end
    local a = A()
    return a.iso(a.template(x), a.template(y))
end

-- ★★ SIMPLE RECURSION IS A LOOP (USER 2026-09-27: "support simple recursion if it can be modelled as a loop").
-- A function calling ITSELF is a loop whose STATE is its argument tuple and whose value is what the clauses return.
-- Both are iterated from the call's own arguments and from BOTTOM (no value yet: an arm whose value needs it is
-- dropped, as a raise is):
--   state_{i+1} = join(state_i, the argument tuples of every self-call made in iteration i)
--   value_{i+1} = join of the clauses evaluated under state_i, each self-call returning value_i
-- until neither changes (A.iso). A strict generalization step replaces a subterm by a hole, so a chain is bounded by
-- the size of the first state: MAX_ITER is a safety net, and hitting it is a counted hole. A loop that no clause
-- ever leaves (no base case) never returns. Only DIRECT self-recursion is a loop; a call back into a function
-- deeper on the stack (mutual recursion) stays a counted cut.
M.MAX_ITER = 8
M.MAX_SPINE = 64    -- levels of a structural recursion folded exactly before it joins into the loop

-- some argument of the self-call is a proper subterm of the same argument of the current one (and that argument
-- is not a hole): structural recursion on a known spine
local function decreasing(new, cur)
    local a = A()
    local function sub(t, x)
        for _, c in ipairs(t.kids or {}) do
            if c == x or a.eq(c, x) or sub(c, x) then return true end
        end
        return false
    end
    -- a flat list's tail is a proper SUFFIX of its children
    local function suffix(c, n)
        if c.k ~= 'list' or n.k ~= 'list' then return false end
        local ck, nk = c.kids or {}, n.kids or {}
        if #nk >= #ck then return false end
        for j = 1, #nk do if not a.eq(ck[#ck - #nk + j], nk[j]) then return false end end
        return true
    end
    for i = 1, math.min(#new, #cur) do
        if cur[i].k ~= 'hole' and new[i].k ~= 'hole' and (suffix(cur[i], new[i]) or sub(cur[i], new[i])) then return true end
    end
    return false
end

-- ★ WIDENING AT THE LOOP HEAD. A join aligns the fixed ends of two sequences, so an accumulator that grows by one
-- element per pass — list(?R…) then list(?R'…, H) then list(?R''…, H', H) — never repeats and the loop never
-- converges. At the loop head a list that already holds a hedge hole is widened to ONE sequence of unknown length,
-- its elements kept as the element claim: the chain is then bounded again (a list is either of known length or
-- list(?X…)).
local function widen(S, t)
    if not t.kids then return t end
    local kids, changed = {}, false
    for i, c in ipairs(t.kids) do kids[i] = widen(S, c); changed = changed or kids[i] ~= c end
    if t.k == 'list' then
        local has = false
        for _, c in ipairs(kids) do if c.k == 'hole' and c.rep then has = true end end
        if has and #kids > 1 then
            local h = hfresh(S, 'a loop variable (a list that changes length across iterations)')
            local els = {}
            for _, c in ipairs(kids) do
                if c.k == 'hole' and c.rep then for _, y in ipairs(S.elems[c.h] or {}) do els[#els + 1] = y end
                elseif c.k ~= 'hole' then els[#els + 1] = c
                else els[#els + 1] = c end
            end
            if #els > 0 then S.elems[h.h] = els end
            return A().node('list', h)
        end
    end
    return changed and A().rebuild(t, kids) or t
end

-- ★★ THE NARROWED FIXPOINT (CART-1037: "do we need to evaluate recursion if we can analyze the control flow?"). Each
-- argument position of a self-recursive function is classified ONCE, from its clauses, across every self-call (the
-- carried-argument census: 61% of hand-written ejabberd's positions are invariant or decreasing):
--   inv      passed through unchanged (the head's variable at that position): its state is the initial argument
--   dec      a proper part of the head's pattern there (T of [H|T]) or a counter N - K: the traversal
--   prepend  [E | X] with X the head's variable there: the accumulator's closed form is a sequence of the E's
--   other    anything else — a call (State2 = handle(State)), a case/receive-bound value, a rebuilt term
--   elem     a part of ANOTHER argument's pattern (an element of what is traversed); const a literal; counter N + K
-- and whether every self-call is in TAIL position. A TAIL loop with no 'other' position and an unknown traversal is
-- then its CLOSED FORM, evaluated in ONE pass (below): no iteration. Everything else iterates as before.
-- ⚠ MEASURED 2026-09-27 on ejabberd's 184 send sites (2043 entries into a recursive function): closed form 86, a
-- known traversal (folded exactly) 601, body recursion 216, an 'other' position 1140 — dominated by OTP's lists:sort
-- internals (mergel/umergel/split_*), then re-dispatches (gen_mod:get_module_opt(global, …) ->
-- get_module_opt(get_myname(), …)). Per-position narrowing INSIDE the iteration (never joining an inv position,
-- skipping a tail self-call's value, the prepend closed form) changed 0 terms and 0 rounds — the rounds are bounded
-- by the state's convergence, not the value's — and was removed. The one-pass closed form stays.
function M.carried(m, key, clauses)
    m.carried = m.carried or {}
    if m.carried[key] then return m.carried[key] end
    local src = m.src
    local name, ar = key:match('^(.+)/(%d+)$')
    ar = tonumber(ar)
    local class, tail, rec = {}, true, false
    local RANK = { inv = 1, dec = 2, const = 3, counter = 3, elem = 3, prepend = 3, other = 4 }
    local function worst(a, b) if not a or RANK[b] > RANK[a] then return b end return a end
    for _, cl in ipairs(clauses) do
        local heads = named(cl:field('args')[1])
        local whole, part = {}, {}
        for i, p in ipairs(heads) do
            local function scan(n, depth)
                local t = n:type()
                if T.var[t] then
                    local v = txt(n, src)
                    if v ~= '_' then if depth == 0 then whole[v] = i elseif not whole[v] then part[v] = part[v] or i end end
                    return
                end
                if T.match[t] then scan(n:field('lhs')[1], depth); scan(n:field('rhs')[1], depth); return end
                for c in n:iter_children() do if c:named() then scan(c, depth + 1) end end
            end
            scan(p, 0)
        end
        local body = cl:field('body')[1]
        local exprs = body and body:field('exprs') or {}
        local last = exprs[#exprs]
        local function tailpos(n)
            local x = n
            while true do
                if x == last then return true end
                local pp = x:parent()
                if not pp or pp:type() ~= 'clause_body' then return false end
                local ex = pp:field('exprs')
                if ex[#ex] ~= x then return false end
                local arm = pp:parent()
                if not arm or not (T.arm[arm:type()] or arm:type() == 'if_clause') then return false end
                x = arm:parent()
                if not (T.case[x:type()] or T.ifx[x:type()]) then return false end
            end
        end
        local function classify(a, i)
            local t = a:type()
            if T.paren[t] then return classify(a:named_child(0), i) end
            if T.var[t] then
                local v = txt(a, src)
                if whole[v] == i then return 'inv' end
                if part[v] == i then return 'dec' end
                -- a part of ANOTHER argument's pattern: an element of what is traversed (decode_*_attrs' _val)
                if part[v] then return 'elem' end
                return 'other'
            end
            if T.atom[t] or T.integer[t] or T.string[t] or T.binary[t] then return 'const' end
            if t == 'binary_op_expr' then
                local op = a:child(1) and txt(a:child(1), src)
                local l, r = a:field('lhs')[1], a:field('rhs')[1]
                if l and T.var[l:type()] and whole[txt(l, src)] == i and r and T.integer[r:type()] then
                    if op == '-' then return 'dec' end
                    if op == '+' then return 'counter' end
                end
                return 'other'
            end
            if T.list[t] then
                for _, c in ipairs(a:field('exprs')) do
                    if T.pipe[c:type()] then
                        local rr = c:field('rhs')[1]
                        if rr and T.var[rr:type()] and whole[txt(rr, src)] == i then return 'prepend' end
                    end
                end
            end
            return 'other'
        end
        local function walk(x)
            for c in x:iter_children() do
                if T.call[c:type()] and not T.remote[c:parent():type()] then
                    local e = c:field('expr')[1]
                    local cargs = named(c:field('args')[1])
                    if e and T.atom[e:type()] and txt(e, src) == name and #cargs == ar then
                        rec = true
                        if not tailpos(c) then tail = false end
                        for i, an in ipairs(cargs) do class[i] = worst(class[i], classify(an, i)) end
                    end
                end
                if not T.fn[c:type()] then walk(c) end
            end
        end
        walk(cl)
    end
    for i = 1, ar do class[i] = class[i] or 'inv' end
    m.carried[key] = { class = class, tail = rec and tail, rec = rec }
    return m.carried[key]
end

local function loop(m, id, clauses, args, S)
    local a = A()
    local state, value = a.node('tuple', unpack(args, 1, #args)), RAISE
    local C = not M.OFF.narrow and M.carried(m, id:match(':(.+)$'), clauses) or nil
    local L = { value = value, clauses = clauses }
    S.loops[id] = L
    S.stats.loops = S.stats.loops + 1
    -- ★ ONE PASS WHEN THE CONTROL FLOW SAYS IT ALL: a TAIL loop with no 'other' position, whose traversed (dec)
    -- arguments are already unknown (a known spine is folded exactly instead, above). Its final state is then its
    -- closed form — inv and dec positions stay the entry arguments, a prepend accumulator is a sequence — and its value
    -- is the join of the exits under that state: nothing to iterate. The prepended elements are read off this very
    -- pass's self-calls and added to the sequence's element claim.
    if C and C.rec then
        -- why this loop iterates (or not): the report's breakdown
        local k = not C.tail and 'body recursion' or nil
        if not k then
            for j = 1, #args do
                if C.class[j] == 'other' then
                    k = 'tail, an other position'
                    S.stats.other_ids = S.stats.other_ids or {}
                    S.stats.other_ids[id .. '#' .. j] = (S.stats.other_ids[id .. '#' .. j] or 0) + 1
                end
            end
        end
        if not k then
            for j = 1, #args do if C.class[j] == 'dec' and args[j].k ~= 'hole' then k = 'tail, a known traversal' end end
        end
        k = k or 'tail, closed form'
        S.stats.loop_kinds = S.stats.loop_kinds or {}
        S.stats.loop_kinds[k] = (S.stats.loop_kinds[k] or 0) + 1
    end
    if C and C.tail and not M.OFF.onepass then
        local closed, acc = true, {}
        for j = 1, #args do
            local cls = C.class[j]
            if cls == 'other' then closed = false
            elseif cls == 'dec' and args[j].k ~= 'hole' then closed = false
            elseif cls == 'prepend' then acc[#acc + 1] = j end
        end
        if closed then
            local kids = {}
            for j = 1, #args do
                local cls = C.class[j]
                if cls == 'elem' or cls == 'counter' or cls == 'const' then
                    -- what the loop puts there differs from the entry value (an element, a count, a reset): unknown
                    kids[j] = fresh(S, ('a loop variable of %s (%s)'):format(id,
                        cls == 'elem' and 'an element of what it traverses' or cls == 'counter' and 'a counter' or 'reset to a constant'))
                else kids[j] = args[j] end
            end
            local seqs = {}
            for _, j in ipairs(acc) do
                local h = hfresh(S, ('an accumulator of %s (a list the loop prepends to)'):format(id))
                local els = {}
                for _, x in ipairs(args[j].k == 'list' and args[j].kids or {}) do
                    if x.k == 'hole' and x.rep then for _, y in ipairs(S.elems[x.h] or {}) do els[#els + 1] = y end
                    else els[#els + 1] = x end
                end
                S.elems[h.h] = els
                seqs[j] = h
                kids[j] = a.node('list', h)
            end
            L.args, L.next = kids, nil
            local vals = run_clauses(m, id, clauses, kids, S)
            S.stats.iterations = S.stats.iterations + 1
            S.stats.onepass = S.stats.onepass + 1
            -- what this pass prepended joins the accumulator's element claim
            for j, h in pairs(seqs) do
                local nx = L.next and L.next.kids and L.next.kids[j]
                for _, x in ipairs(nx and nx.k == 'list' and nx.kids or {}) do
                    if not (x.k == 'hole' and x.rep) then table.insert(S.elems[h.h], x) end
                end
            end
            S.loops[id] = nil
            if not L.next then S.stats.loops = S.stats.loops - 1 end
            return join_all(S, vals, ('%s: no clause admits the arguments'):format(id))
        end
    end
    for i = 1, M.MAX_ITER do
        L.value, L.next, L.args = value, nil, state.kids
        local vals = run_clauses(m, id, clauses, state.kids, S)
        local nvalue = join_all(S, vals, ('%s: no clause admits the arguments'):format(id))
        -- no self-call was made: not a loop, the one pass is the value
        if i == 1 and not L.next then S.loops[id] = nil; S.stats.loops = S.stats.loops - 1; return nvalue end
        -- ascending: the value only ever generalizes
        if value ~= RAISE and nvalue ~= RAISE then
            local up = join_all(S, { value, nvalue }, 'nothing', ('the value of the loop %s (it changes across iterations)'):format(id))
            -- already as general as the join: keep it, and the reasons its own holes carry
            if not iso(up, nvalue) then nvalue = up end
        elseif nvalue == RAISE then nvalue = value end
        local nstate = state
        if L.next then
            nstate = join_all(S, { state, L.next }, 'nothing', ('a loop variable of %s (it changes across iterations)'):format(id))
            if not M.OFF.widen then nstate = widen(S, nstate) end
        end
        S.stats.iterations = S.stats.iterations + 1
        if iso(nvalue, value) and iso(nstate, state) then S.loops[id] = nil; return value end
        if nstate.k ~= 'tuple' then
            -- the whole state generalized to one hole: rebuild the tuple of per-argument holes
            local kids = {}
            for j = 1, #args do kids[j] = fresh(S, ('a loop variable of %s (it changes across iterations)'):format(id)) end
            nstate = a.node('tuple', unpack(kids, 1, #kids))
        end
        state, value = nstate, nvalue
        if i == M.MAX_ITER then S.stats.unconverged = S.stats.unconverged + 1 end
    end
    S.loops[id] = nil
    return fresh(S, ('a loop of %s that did not converge in %d iterations'):format(id, M.MAX_ITER))
end

local function summary(P, mod, fn, args, S)
    local m = P:module(mod)
    if not m then return fresh(S, ('a call into %s (no source)'):format(mod)) end
    local key = fn .. '/' .. #args
    local clauses = m.fns[key]
    if not clauses then return fresh(S, ('%s:%s (not defined there)'):format(mod, key)) end
    local a = A()
    local id = mod .. ':' .. key
    -- a BIF whose source body is a stub (every clause only calls erlang:nif_error): not its meaning
    m.stub = m.stub or {}
    if m.stub[key] == nil then
        local all = true
        for _, cl in ipairs(clauses) do
            local le = last_expr(cl)
            local ok = false
            if le and T.remote[le:type()] then
                local mn = le:field('module')[1]
                local ma = mn and (mn:field('module')[1] or mn:named_child(0))
                local f = le:field('fun')[1]
                local fe = f and f:field('expr')[1]
                ok = ma and fe and STUB[txt(ma, m.src) .. ':' .. txt(fe, m.src)] or false
            end
            all = all and ok
        end
        m.stub[key] = all
    end
    if m.stub[key] and not M.OFF.stubs then
        -- a stub with a known meaning (the NIF's documented behaviour) answers for known arguments
        local ev = not M.OFF.bifs and STUB_EVAL[id]
        local r = ev and ev(args)
        if r then return r end
        S.stats.stubs = S.stats.stubs + 1
        return fresh(S, ('%s: a BIF (its source is a nif_error stub)'):format(id))
    end
    -- a self-call inside its own loop: record the next state, answer with the current approximation
    local L = S.loops[id]
    if L and S.cur == id and not M.OFF.loops then
        -- ★ A KNOWN SPINE IS FOLDED EXACTLY (USER: "most recursions can be expressed as foldl or foldr"). When an
        -- argument of the self-call is a PROPER SUBTERM of the same argument now (the Tail of a known [H | Tail]),
        -- the recursion is structural and terminates: evaluate it as it runs, one level deeper, instead of joining it
        -- into the loop. lists:map(F, [A, B]) is then [F(A), F(B)], not "one of cons | nil".
        -- ★ AND A GROUND RE-DISPATCH IS EVALUATED EXACTLY TOO (CART-1136 lever 2): jid:to_string(#jid{…}) calls
        -- to_string({U, S, R}) — not a smaller term, but a KNOWN one; joining it into a loop made jid:encode of a known
        -- jid unknown. A self-call whose arguments hold no hole is a pure computation on known values: run it, one
        -- level deeper, under the same MAX_SPINE budget (past it the loop takes over, so a runaway still ends).
        local exact = decreasing(args, L.args)
        if not exact and not M.OFF.ground then
            exact = true
            for _, t in ipairs(args) do if not ground_term(t) then exact = false; break end end
        end
        if not M.OFF.spine and L.args and (L.spine or 0) < M.MAX_SPINE and exact then
            local saved = L.args
            L.args, L.spine = args, (L.spine or 0) + 1
            S.stats.unfolded = S.stats.unfolded + 1
            local r = join_all(S, run_clauses(m, id, L.clauses or clauses, args, S), ('%s: no clause admits the arguments'):format(id))
            L.args, L.spine = saved, L.spine - 1
            return r
        end
        local st = a.node('tuple', unpack(args, 1, #args))
        L.next = L.next and join_all(S, { L.next, st }, 'nothing', ('a loop variable of %s (it changes across iterations)'):format(id)) or st
        return L.value
    end
    local shown = {}
    for i, t in ipairs(args) do shown[i] = a.show(t) end
    local mkey = id .. '(' .. table.concat(shown, ', ') .. ')'
    if S.memo[mkey] then S.stats.memo_hits = S.stats.memo_hits + 1; return S.memo[mkey] end
    if (S.stack[id] or 0) >= M.UNROLL then
        S.stats.recursive = S.stats.recursive + 1
        S.stats.cut_ids = S.stats.cut_ids or {}
        S.stats.cut_ids[id] = (S.stats.cut_ids[id] or 0) + 1
        return fresh(S, ('a recursive call to %s (mutual recursion: no fixpoint, CART-1037)'):format(id))
    end
    if S.depth >= M.MAX_DEPTH then S.stats.depth = S.stats.depth + 1; return fresh(S, 'call depth ' .. M.MAX_DEPTH) end
    if S.evals >= M.BUDGET then S.stats.budget = S.stats.budget + 1; return fresh(S, 'evaluation budget') end
    S.evals = S.evals + 1
    S.stats.summaries = S.stats.summaries + 1
    S.stack[id] = (S.stack[id] or 0) + 1
    S.depth = S.depth + 1
    local prev = S.cur
    S.cur = id
    -- ★ PREPROCESSOR VARIANTS ARE SEPARATE DEFINITIONS (CART-1139): each -ifdef branch's definition is evaluated on
    -- its own, first match within it, and their values JOINED — the set over the builds, as erlvariants gives the
    -- call graph. A VANTAGE (the program's `defines`, e.g. { OTP_BELOW_26 = false }) that decides the branch keeps
    -- that definition alone.
    local runs = M.variants(P, m, key)
    local vals = {}
    for _, run in ipairs(runs) do
        if M.OFF.loops then
            vals[#vals + 1] = join_all(S, run_clauses(m, id, run, args, S), ('%s: no clause admits the arguments'):format(id))
        else
            vals[#vals + 1] = loop(m, id, run, args, S)
        end
    end
    local r = #vals == 1 and vals[1] or join_all(S, vals, ('%s: no definition returns'):format(id))
    S.cur = prev
    S.depth = S.depth - 1
    S.stack[id] = S.stack[id] > 1 and S.stack[id] - 1 or nil
    S.memo[mkey] = r
    return r
end

-- ★★ A FUN IS A VALUE (CART-1130's open item, and what lists:map/foldl/foreach need: every one of them calls its
-- argument). An anonymous fun evaluates to a CLOSURE term `fun:<n>` — its clauses and the environment it was created
-- in are kept beside it (S.funs), so the term itself joins and unifies by identity. `fun f/N` / `fun m:f/N` are
-- closures naming a function. Applying one runs its clauses against the arguments exactly as a call does; a named
-- fun (`fun Loop(N) -> … Loop(N - 1) end`) sees itself under its name. Anything else in callee position is a hole.
function M.apply(fv, args, S)
    local id = fv.k and fv.k:match('^fun:(%d+)$')
    local F = id and S.funs[tonumber(id)]
    if not F then return fresh(S, 'a call to a fun value we cannot see') end
    if F.mod then
        local P = F.program
        if not P then return fresh(S, 'a call result (no program to summarize it)') end
        if F.arity ~= #args then return fresh(S, ('fun %s:%s/%d applied to %d argument(s)'):format(F.mod, F.fn, F.arity, #args)) end
        return summary(P, F.mod, F.fn, args, S)
    end
    if S.depth >= M.MAX_DEPTH then S.stats.depth = S.stats.depth + 1; return fresh(S, 'call depth ' .. M.MAX_DEPTH) end
    S.depth = S.depth + 1
    S.stats.applies = S.stats.applies + 1
    local vals = {}
    for _, cl in ipairs(F.clauses) do
        local cenv = with_vars(F.env, {})
        if F.name then cenv.vars[F.name] = fv end
        local verdict = 'yes'
        local ps = named(cl:field('args')[1])
        if #ps ~= #args then verdict = 'no' end
        for i, p in ipairs(verdict ~= 'no' and ps or {}) do
            local v, bv = bind(p, args[i], cenv, S)
            if v == 'no' then verdict = 'no'; break end
            if v == 'maybe' then verdict = 'maybe' end
            for nm, t in pairs(bv) do cenv.vars[nm] = t end
        end
        if verdict ~= 'no' then
            local gv = M.guard(cl, cenv, S)
            if gv == 'no' then verdict = 'no' elseif gv == 'maybe' then verdict = 'maybe' end
        end
        if verdict ~= 'no' then
            local le = last_expr(cl)
            vals[#vals + 1] = le and M.eval(le, cenv, S) or fresh(S, 'an empty fun body')
            if verdict == 'yes' then break end
        end
    end
    S.depth = S.depth - 1
    return join_all(S, vals, 'a fun no clause of which admits the arguments')
end

local function closure(S, F)
    S.nfun = S.nfun + 1
    S.funs[S.nfun] = F
    return A().node('fun:' .. S.nfun)
end

local function call_value(x, env, S)
    local src, ctx = env.src, env.ctx
    local c, mod = x, ctx.module
    if T.remote[x:type()] then
        local mn = x:field('module')[1]
        local ma = mn and (mn:field('module')[1] or mn:named_child(0))
        c = x:field('fun')[1]
        if not ma or not c then return fresh(S, 'a remote call of an unusual shape') end
        if T.macro[ma:type()] then
            local nn = ma:field('name')[1]
            if not (nn and txt(nn, src) == 'MODULE') then return fresh(S, 'a call into a macro-named module') end
        elseif T.atom[ma:type()] then mod = (txt(ma, src):gsub("^'(.*)'$", '%1'))
        else
            -- the module is a VALUE: when it evaluates to one atom (`Mod = get_mod(Term)`), the call is static
            local mv = not M.OFF.dynmod and M.eval(ma, env, S)
            if mv == RAISE then return RAISE end
            if not (mv and mv.k == 'lit' and mv.lk == 'atom') then return fresh(S, 'a dynamic call (the module is a value)') end
            mod = mv.v
        end
    end
    local e = c:field('expr')[1]
    if not e then return fresh(S, 'a call of an unusual shape') end
    if not T.atom[e:type()] then
        -- `F(Args)`: the callee is a VALUE — a fun, applied with its own clauses and the environment it closed over
        if M.OFF.funs then return fresh(S, 'a call to a fun value') end
        local fv = M.eval(e, env, S)
        if fv == RAISE then return RAISE end
        local args = {}
        for i, an in ipairs(named(c:field('args')[1])) do args[i] = M.eval(an, env, S) end
        if has_raise(args) then return RAISE end
        return M.apply(fv, args, S)
    end
    local fn = txt(e, src):gsub("^'(.*)'$", '%1')
    local args = {}
    for i, an in ipairs(named(c:field('args')[1])) do args[i] = M.eval(an, env, S) end
    if has_raise(args) then return RAISE end
    local P = ctx.program
    local here = P and mod == ctx.module and P:module(mod)
    local local_def = here and here.fns[fn .. '/' .. #args]
    if not M.OFF.raises and RAISES[fn] and (mod == 'erlang' or (x == c and not local_def)) then return RAISE end
    -- THE LANGUAGE'S OWN CONVERSIONS (auto-imported BIFs; their meaning is the reference manual's, like the operators):
    -- a known argument gives a known result, anything else a hole. What xmpp's encoders call: enc_enum ->
    -- atom_to_binary, enc_int -> integer_to_binary, jid:encode -> iolist_to_binary.
    local conv = not M.OFF.bifs and (mod == 'erlang' or (x == c and not local_def)) and CONVERT[fn]
    if conv then
        local r = conv(args)
        if r then return r end
        return fresh(S, ('%s/%d of an unknown'):format(fn, #args))
    end
    -- a TYPE TEST (is_binary/1 …, the spec's guard_kinds): yes when the term is of an admitted kind, no when it is
    -- known to be of another, a hole when it is unknown
    if GUARD_KINDS[fn] and #args == 1 and not M.OFF.typetests and (mod == 'erlang' or (x == c and not local_def)) then
        local v = args[1]
        local function kind_of(t)
            if t.k == 'hole' then return nil end
            if t.k == 'lit' then
                return ({ atom = 'atom', int = 'integer', float = 'float', bin = 'binary', str = 'string' })[t.lk or ''] or nil
            end
            if t.k == 'list' then return 'list' end
            if t.k == 'tuple' or t.k:match('^rec:') then return 'tuple' end
            if t.k == 'map' then return 'map_expr' end
            return 'other'
        end
        local k = kind_of(v)
        if not k then return fresh(S, fn .. ' of an unknown') end
        for _, admitted in ipairs(GUARD_KINDS[fn]) do if admitted == k then return lit('true', 'atom') end end
        return lit('false', 'atom')
    end
    -- apply(F, [A…]) and apply(M, F, [A…]): the auto-imported erlang:apply, its argument list read off the term
    if fn == 'apply' and not M.OFF.funs and (mod == 'erlang' or (x == c and not local_def)) and (#args == 2 or #args == 3) then
        local list = {}
        local l = args[#args]
        if l.k ~= 'list' then return fresh(S, 'an apply whose argument list is not known') end
        for _, x in ipairs(l.kids or {}) do
            if x.k == 'hole' and x.rep then return fresh(S, 'an apply whose argument count is not known') end
            list[#list + 1] = x
        end
        if #args == 2 then return M.apply(args[1], list, S) end
        local am, af = args[1], args[2]
        if not (am.k == 'lit' and am.lk == 'atom' and af.k == 'lit' and af.lk == 'atom') then
            return fresh(S, 'a dynamic call (apply/3 of values)')
        end
        if not P then return fresh(S, 'a call result (no program to summarize it)') end
        return summary(P, am.v, af.v, list, S)
    end
    if not P or M.OFF.calls then return fresh(S, 'a call result (no program to summarize it)') end
    if x == c and not local_def then return fresh(S, ('%s/%d: a BIF or an imported function'):format(fn, #args)) end
    return summary(P, mod, fn, args, S)
end

-- ── OPERATORS, three-valued: a comparison of two terms that are known (or that clash structurally), the short-circuit
-- booleans, integer arithmetic. Anything that depends on a hole is a hole — a wrong `false` would drop an arm.
local function ground(t)
    if t.k == 'hole' then return false end
    for _, c in ipairs(t.kids or {}) do if not ground(c) then return false end end
    return true
end
local function same(a, b)
    -- nil: not known. Ground terms compare exactly (lk included where both have one); a structural clash is false.
    if ground(a) and ground(b) then
        local function eqk(x, y)
            if x.k ~= y.k then return false end
            if x.k == 'lit' then return x.v == y.v and (x.lk == nil or y.lk == nil or x.lk == y.lk) end
            if #(x.kids or {}) ~= #(y.kids or {}) then return false end
            for i = 1, #(x.kids or {}) do if not eqk(x.kids[i], y.kids[i]) then return false end end
            return true
        end
        return eqk(a, b)
    end
    local v = M.match(a, b)
    if v == 'no' then return false end
    return nil
end
function binop(x, env, S)
    local src = env.src
    local op = x:child(1) and txt(x:child(1), src)
    local l = M.eval(x:field('lhs')[1], env, S)
    if l == RAISE then return RAISE end
    if op == 'andalso' or op == 'orelse' then
        local lb = truth(l)
        if op == 'andalso' and lb == false then return lit('false', 'atom') end
        if op == 'orelse' and lb == true then return lit('true', 'atom') end
        local r = M.eval(x:field('rhs')[1], env, S)
        if r == RAISE then return RAISE end
        if lb ~= nil then return r end
        local rb = truth(r)
        if op == 'andalso' and rb == false then return lit('false', 'atom') end
        if op == 'orelse' and rb == true then return lit('true', 'atom') end
        return fresh(S, ('an %s of an unknown'):format(op))
    end
    local r = M.eval(x:field('rhs')[1], env, S)
    if r == RAISE then return RAISE end
    if op == '==' or op == '=:=' or op == '/=' or op == '=/=' then
        local e = same(l, r)
        if e == nil then return fresh(S, 'a comparison of unknowns') end
        if op == '/=' or op == '=/=' then e = not e end
        return lit(e and 'true' or 'false', 'atom')
    end
    local ln = l.k == 'lit' and l.lk == 'int' and tonumber(l.v)
    local rn = r.k == 'lit' and r.lk == 'int' and tonumber(r.v)
    if ln and rn then
        if op == '<' then return lit(ln < rn and 'true' or 'false', 'atom') end
        if op == '>' then return lit(ln > rn and 'true' or 'false', 'atom') end
        if op == '=<' then return lit(ln <= rn and 'true' or 'false', 'atom') end
        if op == '>=' then return lit(ln >= rn and 'true' or 'false', 'atom') end
        if op == '+' then return lit(tostring(ln + rn), 'int') end
        if op == '-' then return lit(tostring(ln - rn), 'int') end
        if op == '*' then return lit(tostring(ln * rn), 'int') end
    end
    return fresh(S, 'a ' .. tostring(op) .. ' value')
end

-- ── LIST COMPREHENSIONS: [E || P <- L, Filter, …] over a KNOWN list is the list of E for every element the
-- qualifiers admit; an element a pattern or a filter only MAYBE admits makes the length unknown (a sequence, with
-- what E would be as its element claim); an unknown generator list is a sequence of E over an unknown element.
function comprehension(x, env, S)
    local a = A()
    local body = x:field('exprs')[1]
    local lce = x:field('lc_exprs')[1]
    local quals = {}
    for _, q in ipairs(lce and lce:field('exprs') or {}) do quals[#quals + 1] = q:named_child(0) end
    local out, uncertain, claim = {}, false, {}
    local function run(i, e)
        if i > #quals then
            local v = M.eval(body, e, S)
            if v ~= RAISE then out[#out + 1] = v; claim[#claim + 1] = v end
            return
        end
        local q = quals[i]
        if q and T.generator[q:type()] then
            local lt = M.eval(q:field('rhs')[1], e, S)
            if lt == RAISE then return end
            local xs = flat_known(lt)
            if not xs then
                -- an unknown list: E over an unknown element, a sequence of unknown length
                uncertain = true
                local _, vars = bind(q:field('lhs')[1], fresh(S, 'an element of an unknown list'), e, S)
                run(i + 1, with_vars(e, vars or {}))
                return
            end
            for _, el in ipairs(xs) do
                local verdict, vars = bind(q:field('lhs')[1], el, e, S)
                if verdict ~= 'no' then
                    if verdict == 'maybe' then uncertain = true end
                    run(i + 1, with_vars(e, vars))
                end
            end
            return
        end
        if not q then return end
        local b = truth(M.eval(q, e, S))
        if b == false then return end
        if b == nil then uncertain = true end
        run(i + 1, e)
    end
    run(1, env)
    if not uncertain then return a.node('list', unpack(out, 1, #out)) end
    local h = hfresh(S, 'a comprehension of unknown length')
    S.elems[h.h] = claim
    return a.node('list', h)
end

-- ── VALUES ──────────────────────────────────────────────────────────────────────────────────────────────────────
function M.eval(x, env, S)
    local a = A()
    local src, ctx = env.src, env.ctx
    if not x then return fresh(S, 'nothing') end
    local t = x:type()
    local function record(rec, set, base)
        local names = ctx.record_fields and ctx.record_fields(rec)
        if not names then return fresh(S, '#' .. rec .. ' (no declaration in scope)') end
        if base == RAISE then return RAISE end
        local defaults = (ctx.defaults and ctx.defaults(rec)) or {}
        local kids = {}
        for i, f in ipairs(names) do
            if set[f] then kids[i] = set[f]
            elseif base and base.k == 'rec:' .. rec and base.kids and base.kids[i] then kids[i] = base.kids[i]
            elseif base then kids[i] = fresh(S, '#' .. rec .. '.' .. f .. ' (from an unknown base)')
            else kids[i] = default_term(defaults[f], S) end
        end
        return mk('rec:' .. rec, kids)
    end
    local function rec_fields(n)
        local set = {}
        for _, rf in ipairs(n:field('fields')) do
            local fname = rf:field('name')[1]
            local fe = rf:field('expr')[1]
            local vn = fe and (fe:field('expr')[1] or fe)
            if fname and vn then set[txt(fname, src)] = M.eval(vn, env, S) end
        end
        return set
    end
    if T.paren[t] then return M.eval(x:named_child(0), env, S) end
    if T.record[t] then
        local rec = rec_name(x, src)
        if not rec then return fresh(S, 'a record named by a macro') end
        return record(rec, rec_fields(x))
    end
    if T.update[t] then
        local rec = rec_name(x, src)
        if not rec then return fresh(S, 'a record named by a macro') end
        local b = x:field('expr')[1]
        return record(rec, rec_fields(x), b and M.eval(b, env, S) or nil)
    end
    if T.field[t] then
        local rec = rec_name(x, src)
        local fnn = x:field('field')[1]
        fnn = fnn and (fnn:field('name')[1] or fnn)
        local names = rec and ctx.record_fields and ctx.record_fields(rec)
        local b = x:field('expr')[1]
        if not (names and fnn and b) then return fresh(S, 'a record field read') end
        local base = M.eval(b, env, S)
        if base == RAISE then return RAISE end
        local f = txt(fnn, src)
        for i, nm in ipairs(names) do
            if nm == f then
                if base.k == 'rec:' .. rec and base.kids[i] then return base.kids[i] end
                return fresh(S, ('#%s.%s of an unknown base'):format(rec, f))
            end
        end
        return fresh(S, ('#%s has no field %s'):format(rec, f))
    end
    if T.list[t] then
        local items, tail = {}, nil
        for _, c in ipairs(x:field('exprs')) do
            if T.pipe[c:type()] then
                items[#items + 1] = M.eval(c:field('lhs')[1], env, S)
                tail = M.eval(c:field('rhs')[1], env, S)
            else items[#items + 1] = M.eval(c, env, S) end
        end
        if has_raise(items) or tail == RAISE then return RAISE end
        return mklist(S, items, tail)
    end
    if T.tuple[t] then
        local items = {}
        for _, c in ipairs(x:field('expr')) do items[#items + 1] = M.eval(c, env, S) end
        -- {r, F1 .. Fn} with r a record of n fields in scope IS #r{…} (the generated codecs build records so)
        local h = items[1]
        local names = h and h.k == 'lit' and h.lk == 'atom' and ctx.record_fields and ctx.record_fields(h.v)
        if names and #names == #items - 1 and not M.OFF.rectuple then
            return mk('rec:' .. h.v, { unpack(items, 2, #items) })
        end
        return mk('tuple', items)
    end
    if T.atom[t] then return lit((txt(x, src):gsub("^'(.*)'$", '%1')), 'atom') end
    if T.integer[t] or T.char[t] then return lit(txt(x, src), 'int') end
    if T.float[t] then return lit(txt(x, src), 'float') end
    if T.string[t] then return lit((txt(x, src):gsub('^"(.*)"$', '%1')), 'str') end
    if T.binary[t] then
        -- a binary BUILT from parts: a string segment is its text, a `/binary` segment (or an untyped one holding a
        -- known binary) the text of its value; a size, a numeric or a utf8 segment is not text we can read
        local parts = {}
        for _, e in ipairs(x:field('elements')) do
            local el = e:field('element')[1]
            local ty = e:field('types')[1]
            -- the type list's text includes its slash: `/binary`
            local tyt = ty and (vim.trim(txt(ty, src)):gsub('^/', '')) or nil
            if not el or e:field('size')[1] then return fresh(S, 'a binary built at runtime') end
            if T.string[el:type()] and not ty then parts[#parts + 1] = txt(el, src):sub(2, -2)
            elseif not M.OFF.binaries and (tyt == 'binary' or tyt == nil) then
                local v = M.eval(el, env, S)
                if v == RAISE then return RAISE end
                if not (v.k == 'lit' and (v.lk == 'bin' or v.lk == 'str' or v.lk == nil)) then
                    return fresh(S, 'a binary built at runtime')
                end
                parts[#parts + 1] = tostring(v.v)
            else return fresh(S, 'a binary built at runtime') end
        end
        return lit(table.concat(parts), 'bin')
    end
    if T.var[t] then
        if txt(x, src) == '_' then return fresh(S, '_') end
        return lookup(x, env, S)
    end
    if T.match[t] then return M.eval(x:field('rhs')[1], env, S) end
    if T.macro[t] then
        local nn = x:field('name')[1]
        local nm = nn and txt(nn, src)
        if x:field('args')[1] then return fresh(S, '?' .. tostring(nm) .. '(…) (a macro with arguments)') end
        if nm == 'MODULE' and ctx.module then return lit(ctx.module, 'atom') end
        local v = nm and (ctx.macros or macros() or {})[nm]
        -- the vocabulary keeps the TEXT, not whether the define was "…" or <<"…">>: an unknown kind (no lk) never clashes
        if type(v) == 'string' then return lit(v, nil) end
        return fresh(S, '?' .. tostring(nm) .. ' (no value in the vocabulary)')
    end
    if T.map[t] then
        if #x:field('fields') == 0 then return a.node('map') end
        return fresh(S, 'a map with fields')
    end
    if T.case[t] then
        if M.OFF.join then return fresh(S, 'a case/if value') end
        local subj = M.eval(x:field('expr')[1], env, S)
        if subj == RAISE then return RAISE end
        local vals = {}
        for _, cl in ipairs(x:field('clauses')) do
            local verdict, vars = bind(cl:field('pat')[1], subj, env, S)
            local aenv = verdict ~= 'no' and with_vars(env, vars) or nil
            if verdict ~= 'no' then
                local gv = M.guard(cl, aenv, S)
                if gv == 'no' then verdict = 'no' elseif gv == 'maybe' then verdict = 'maybe' end
            end
            if verdict ~= 'no' then
                local le = last_expr(cl)
                vals[#vals + 1] = le and M.eval(le, aenv, S) or fresh(S, 'an empty arm')
                if verdict == 'yes' then break end
            end
        end
        return join_all(S, vals, 'a case no arm of which admits the subject')
    end
    if T.ifx[t] then
        if M.OFF.join then return fresh(S, 'a case/if value') end
        local vals = {}
        for _, cl in ipairs(x:field('clauses')) do
            local gv = M.guard(cl, env, S)
            if gv ~= 'no' then
                local le = last_expr(cl)
                vals[#vals + 1] = le and M.eval(le, env, S) or fresh(S, 'an empty arm')
                if gv == 'yes' then break end
            end
        end
        return join_all(S, vals, 'an if with no arm')
    end
    if T.call[t] or T.remote[t] then return call_value(x, env, S) end
    if T.lc[t] and not M.OFF.lc then return comprehension(x, env, S) end
    if T.try[t] and not M.OFF.try then
        -- ★ try Body [of Clauses] catch … end (CART-1138: xmpp's generated decoders wrap every conversion in one).
        -- The value is the body's, through the `of` clauses as a case would; a catch arm runs only if the body raises,
        -- and one that may: a known (ground) body value raises nothing, so its catch arms are left out; an unknown one
        -- may, and its arms join in — a re-raising arm (erlang:error, the decoders' way) drops out as a raise does.
        local exprs = x:field('exprs')
        local bv = fresh(S, 'an empty try')
        for _, e in ipairs(exprs) do bv = M.eval(e, env, S) end
        local vals = {}
        if bv ~= RAISE then
            local ofs = x:field('clauses')
            if #ofs == 0 then vals[#vals + 1] = bv
            else
                for _, cl in ipairs(ofs) do
                    local verdict, vars = bind(cl:field('pat')[1], bv, env, S)
                    local aenv = verdict ~= 'no' and with_vars(env, vars) or nil
                    if verdict ~= 'no' then
                        local gv = M.guard(cl, aenv, S)
                        if gv == 'no' then verdict = 'no' elseif gv == 'maybe' then verdict = 'maybe' end
                    end
                    if verdict ~= 'no' then
                        local le = last_expr(cl)
                        vals[#vals + 1] = le and M.eval(le, aenv, S) or fresh(S, 'an empty arm')
                        if verdict == 'yes' then break end
                    end
                end
            end
        end
        if bv == RAISE or not ground_term(bv) then
            for _, cc in ipairs(x:field('catch')) do
                local le = last_expr(cc)
                vals[#vals + 1] = le and M.eval(le, env, S) or fresh(S, 'an empty catch arm')
            end
        end
        return join_all(S, vals, 'a try none of whose arms returns')
    end
    if T.binop[t] and not M.OFF.ops then return binop(x, env, S) end
    if T.unop[t] and not M.OFF.ops then
        local op = x:child(0) and txt(x:child(0), src)
        local v = M.eval(x:field('operand')[1], env, S)
        if v == RAISE then return RAISE end
        if op == 'not' then
            local b = truth(v)
            if b ~= nil then return lit(b and 'false' or 'true', 'atom') end
            return fresh(S, 'a negation of an unknown')
        end
        if op == '-' and v.k == 'lit' and v.lk == 'int' and tonumber(v.v) then return lit(tostring(-tonumber(v.v)), 'int') end
        return fresh(S, 'a unary ' .. tostring(op) .. ' value')
    end
    if T.fn[t] and not M.OFF.funs then
        local cls = x:field('clauses')
        local nn = cls[1] and cls[1]:field('name')[1]
        return closure(S, { clauses = cls, env = env, name = nn and txt(nn, src) or nil })
    end
    if T.funref[t] and not M.OFF.funs then
        local fnn, an = x:field('fun')[1], x:field('arity')[1]
        local av = an and (an:field('value')[1] or an)
        local mod = ctx.module
        if T.extfun[t] then
            local mn = x:field('module')[1]
            local ma = mn and (mn:field('name')[1] or mn:named_child(0))
            mod = ma and T.atom[ma:type()] and (txt(ma, src):gsub("^'(.*)'$", '%1')) or nil
        end
        local arity = av and tonumber(txt(av, src))
        if not (mod and fnn and T.atom[fnn:type()] and arity) then return fresh(S, 'a fun reference to a value') end
        return closure(S, { mod = mod, fn = (txt(fnn, src):gsub("^'(.*)'$", '%1')), arity = arity, program = ctx.program })
    end
    return fresh(S, 'a ' .. t .. ' value')
end

-- the mechanisms, each switchable off: the increments are measured one at a time and every guard is revertable
M.OFF = {}

--- the value of `node` (a tree-sitter node in `src`) as a term; `S` (optional) shares one session across calls
function M.term(node, src, ctx, S)
    S = S or M.session()
    local tm = M.eval(node, { src = src, ctx = ctx, vars = {} }, S)
    if tm == RAISE then tm = fresh(S, 'never returns (every path raises)') end
    local holes = {}
    local function walk(t)
        if t.k == 'hole' then holes[t.h] = S.reasons[t.h] or 'unnamed'; return end
        for _, c in ipairs(t.kids or {}) do walk(c) end
    end
    walk(tm)
    return tm, holes, S
end

--- THE ELEMENT CLAIM of a sequence hole: the generalization (A.generalize) of every element the joined lists put
--- there — "a list of #disco_info{node = ?}", where A.join's own summary says only "{rec:disco_info}{0,}". nil when
--- no element was seen (a sequence nothing is known about).
function M.elements(S, h)
    local els = S.elems[h]
    if not els or #els == 0 then return nil end
    if #els == 1 then return els[1] end
    local G = A().generalize(els)
    return G and G.template and G.template.body or nil
end

--- THE VALUE OF A CALL `mod:fn(args…)` — the callee's clauses against the argument terms, as any call inside an
--- evaluation. The response leg (xmppserver.responses) calls a handler with the CLIENT's request term.
--- -> term, holes { name -> reason }
function M.call(P, mod, fn, args, S)
    S = S or M.session()
    local tm = summary(P, mod, fn, args, S)
    if tm == RAISE then tm = fresh(S, 'never returns (every path raises)') end
    local holes = {}
    local function walk(t)
        if t.k == 'hole' then holes[t.h] = S.reasons[t.h] or 'unnamed'; return end
        for _, c in ipairs(t.kids or {}) do walk(c) end
    end
    walk(tm)
    return tm, holes
end

--- a declared record default's TEXT as a term (`<<>>` -> "", `[]` -> list(), none -> undefined), or a hole
function M.default_term(text, S) return default_term(text, S or M.session()) end

--- a term's completeness: 'complete' (no holes), 'partial', or 'opaque' (the term IS a hole)
function M.status(term)
    if term.k == 'hole' then return 'opaque' end
    local any = false
    local function walk(t)
        if t.k == 'hole' then any = true; return end
        for _, c in ipairs(t.kids or {}) do walk(c) end
    end
    walk(term)
    return any and 'partial' or 'complete'
end

-- ── THE PROGRAM: the modules a call can reach, read lazily from the tree's and the dependencies' source ──────────
--- the ctx of one file: its module name and the records its include graph puts in scope (E = erlrecords env)
function M.file_ctx(src, path, E, program)
    local scope = E and E:scope(path)
    return {
        module = src:match('%-module%(%s*([%w_]+)%s*%)'),
        program = program,
        record_fields = function (rec)
            local d = scope and scope.records[rec]
            if not d then return nil end
            local out = {}
            for i, fl in ipairs(d.fields) do out[i] = fl.name end
            return out
        end,
        defaults = function (rec)
            local d = scope and scope.records[rec]
            if not d then return nil end
            local out = {}
            for _, fl in ipairs(d.fields) do out[fl.name] = fl.default end
            return out
        end,
    }
end

--- opts = { dirs = { dir | { dir, E }, … } searched in order for <module>.erl (the tree first, then each dependency's
---          src — the caller supplies where a dependency lives, the tree only names the module; a dependency's own
---          record env resolves ITS includes), E = erlrecords env (for plain dirs),
---          ctx_of = fn(src, path, P) -> ctx (optional: records from elsewhere than an include graph),
---          defines = { MACRO = true | false } (a VANTAGE: the build's defines pick one -ifdef variant; none -> all) }
function M.program(opts)
    local P = { dirs = opts.dirs or {}, E = opts.E, ctx_of = opts.ctx_of, defines = opts.defines, mods = {} }
    function P:module(name)
        if not name then return nil end
        local m = self.mods[name]
        if m ~= nil then return m or nil end
        local path, src, E
        for _, d in ipairs(self.dirs) do
            local dir = type(d) == 'table' and d.dir or d
            local fd = io.open(dir .. '/' .. name .. '.erl', 'rb')
            if fd then
                src = fd:read('a'); fd:close(); path = dir .. '/' .. name .. '.erl'
                E = type(d) == 'table' and d.E or self.E
                break
            end
        end
        local ok, parser = pcall(vim.treesitter.get_string_parser, src or '', 'erlang')
        if not src or not ok then self.mods[name] = false; return nil end
        local root = parser:parse()[1]:root()
        local fns = {}
        for d in root:iter_children() do
            if T.decl[d:type()] then
                for _, cl in ipairs(d:field('clause')) do
                    local nn = cl:field('name')[1]
                    if nn then
                        local key = txt(nn, src):gsub("^'(.*)'$", '%1') .. '/' .. #named(cl:field('args')[1])
                        fns[key] = fns[key] or {}
                        table.insert(fns[key], cl)
                    end
                end
            end
        end
        -- ★ DEFINITIONS, NOT JUST CLAUSES (CART-1139): the grammar gives each clause its own fun_decl, so two -ifdef
        -- branches' definitions of one name/arity arrive as ONE list, and first-match would always take the file's
        -- first branch. A definition ends at the clause whose text ends with `.`: defs[key] = { run, run… }.
        local defs = {}
        for key, cls in pairs(fns) do
            local runs, cur = {}, {}
            for _, cl in ipairs(cls) do
                cur[#cur + 1] = cl
                local dt = cl:parent() and vim.trim(txt(cl:parent(), src)) or ''
                if dt:sub(-1) == '.' then runs[#runs + 1] = cur; cur = {} end
            end
            if #cur > 0 then runs[#runs + 1] = cur end
            defs[key] = runs
        end
        m = { path = path, src = src, root = root, fns = fns, defs = defs,
            ctx = self.ctx_of and self.ctx_of(src, path, self) or M.file_ctx(src, path, E, self) }
        self.mods[name] = m
        return m
    end
    --- the program's view of a file it did not load by module name (the send site's own file)
    function P:adopt(_, src)
        local name = src:match('%-module%(%s*([%w_]+)%s*%)')
        return name and self:module(name) or nil
    end
    return P
end

return M
