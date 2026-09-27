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
--   [A, B | T]       cons(A, cons(B, T))      atom / integer / plain binary -> lit (quotes and <<"">> dropped)
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
    decl = { fun_decl = true },
}
local RAISES = require('cartograph.spec.erlang').raises or {}

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

-- ── the session: hole names, their reasons, the summary memo and counters ────────────────────────────────────────
function M.session()
    return { n = 0, reasons = {}, domains = {}, kinds = {}, memo = {}, stack = {}, depth = 0, evals = 0, top = {},
        loops = {}, stats = { recursive = 0, depth = 0, budget = 0, summaries = 0, memo_hits = 0, loops = 0,
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
    for i, c in ipairs(t.kids) do kids[i] = subst(c, map); changed = changed or kids[i] ~= c end
    return changed and A().rebuild(t, kids) or t
end

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
    return mine[h] == true
end

function M.match(pat, subj, mine)
    local a = A()
    local arity = {}
    pat, subj = as_tuples(pat, arity), as_tuples(subj, arity)
    if not M.OFF.kinds and kinds_clash(pat, subj) then return 'no' end
    local U = a.unify(a.template(pat), a.template(subj))
    if not U then return 'no' end
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
                ren[n] = fresh(S, why_diff or 'the arms differ here (a join)')
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
    if text == '[]' then return a.node('nil') end
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
            if not names then return pfresh('a record pattern with no declaration in scope') end
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
                if T.pipe[c:type()] then items[#items + 1] = conv(c:field('lhs')[1]); tail = conv(c:field('rhs')[1])
                else items[#items + 1] = conv(c) end
            end
            local tm = tail or A().node('nil')
            for i = #items, 1, -1 do tm = A().node('cons', items[i], tm) end
            return tm
        end
        if T.tuple[t] then
            local items = {}
            for _, c in ipairs(n:field('expr')) do items[#items + 1] = conv(c) end
            return A().node('tuple', unpack(items, 1, #items))
        end
        if T.atom[t] or T.integer[t] or T.string[t] or T.char[t] or T.float[t] or T.macro[t] or T.binary[t] then
            local v = M.eval(n, env, S)
            if v.k == 'lit' then return v end
            return pfresh('a pattern constant we cannot read')
        end
        return pfresh('a ' .. t .. ' pattern')
    end
    return conv(x), binds, mine
end

-- bind a pattern against a subject: the verdict and the variables' values
local function bind(patnode, subj, env, S)
    local p, binds, mine = M.pattern(patnode, env, S)
    local verdict, vals = M.match(p, subj, mine)
    if verdict == 'no' then return 'no' end
    local out = {}
    for nm, t in pairs(binds) do
        local v = subst(t, vals)
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
            if guarded(cl, m.src) and not M.OFF.guards then verdict = 'maybe' end
            local le = last_expr(cl)
            vals[#vals + 1] = le and M.eval(le, cenv, S) or fresh(S, 'an empty body')
            if verdict == 'yes' then break end
        end
    end
    return vals
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

local function loop(m, id, clauses, args, S)
    local a = A()
    local state, value = a.node('tuple', unpack(args, 1, #args)), RAISE
    local L = { value = value }
    S.loops[id] = L
    S.stats.loops = S.stats.loops + 1
    for i = 1, M.MAX_ITER do
        L.value, L.next = value, nil
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
    -- a self-call inside its own loop: record the next state, answer with the current approximation
    local L = S.loops[id]
    if L and S.cur == id and not M.OFF.loops then
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
    local r
    if M.OFF.loops then
        r = join_all(S, run_clauses(m, id, clauses, args, S), ('%s: no clause admits the arguments'):format(id))
    else
        r = loop(m, id, clauses, args, S)
    end
    S.cur = prev
    S.depth = S.depth - 1
    S.stack[id] = S.stack[id] > 1 and S.stack[id] - 1 or nil
    S.memo[mkey] = r
    return r
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
    if not e or not T.atom[e:type()] then return fresh(S, 'a call to a fun value') end
    local fn = txt(e, src):gsub("^'(.*)'$", '%1')
    local args = {}
    for i, an in ipairs(named(c:field('args')[1])) do args[i] = M.eval(an, env, S) end
    if has_raise(args) then return RAISE end
    local P = ctx.program
    local here = P and mod == ctx.module and P:module(mod)
    local local_def = here and here.fns[fn .. '/' .. #args]
    if not M.OFF.raises and RAISES[fn] and (mod == 'erlang' or (x == c and not local_def)) then return RAISE end
    if not P or M.OFF.calls then return fresh(S, 'a call result (no program to summarize it)') end
    if x == c and not local_def then return fresh(S, ('%s/%d: a BIF or an imported function'):format(fn, #args)) end
    return summary(P, mod, fn, args, S)
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
        local tm = tail or a.node('nil')
        for i = #items, 1, -1 do tm = a.node('cons', items[i], tm) end
        return tm
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
        local parts = {}
        for _, e in ipairs(x:field('elements')) do
            local el = e:field('element')[1]
            if not el or not T.string[el:type()] or e:field('size')[1] or e:field('types')[1] then
                return fresh(S, 'a binary built at runtime')
            end
            parts[#parts + 1] = txt(el, src):sub(2, -2)
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
            if verdict ~= 'no' then
                if guarded(cl, src) and not M.OFF.guards then verdict = 'maybe' end
                local le = last_expr(cl)
                vals[#vals + 1] = le and M.eval(le, with_vars(env, vars), S) or fresh(S, 'an empty arm')
                if verdict == 'yes' then break end
            end
        end
        return join_all(S, vals, 'a case no arm of which admits the subject')
    end
    if T.ifx[t] then
        if M.OFF.join then return fresh(S, 'a case/if value') end
        local vals = {}
        for _, cl in ipairs(x:field('clauses')) do
            local le = last_expr(cl)
            vals[#vals + 1] = le and M.eval(le, env, S) or fresh(S, 'an empty arm')
            if not guarded(cl, src) then break end
        end
        return join_all(S, vals, 'an if with no arm')
    end
    if T.call[t] or T.remote[t] then return call_value(x, env, S) end
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
---          ctx_of = fn(src, path, P) -> ctx (optional: records from elsewhere than an include graph) }
function M.program(opts)
    local P = { dirs = opts.dirs or {}, E = opts.E, ctx_of = opts.ctx_of, mods = {} }
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
        m = { path = path, src = src, root = root, fns = fns,
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
