-- cartograph.byexample — A REWRITE RULE LEARNED FROM ONE EXAMPLE, applied wherever it matches (the toolbelt's
-- `learn`; USER 2026-09-28: "can we create a tactic from an example?").
--
-- transplant.apply learns an edit from an exemplar too, but at FUNCTION granularity: a target must share the
-- exemplar's whole shape. MEASURED on lua/cartograph for `x == nil` -> `not x`: 111 functions contain the pattern and
-- transplant derived the edit for 1. The edit is LOCAL, so this learns a RULE for the region that changed:
--   1. read     before and after with the LOSSLESS reader (algebraread: cst_print(read(src)) == src)
--   2. cut      the region that differs (A.diff_regions): `x == nil` / `not x`
--   3. abstract the subterms the edit CARRIES OVER (in both regions, containing a name) become holes:
--               `?1 == nil` -> `not ?1`. A constant stays fixed: it is part of what the example means.
--   4. apply    every non-overlapping match of the left side, in any file, is replaced by the right side
--               instantiated with the TARGET's own subterms — printed losslessly, so everything outside the rewritten
--               span is byte-identical, and the rewritten span keeps the target's operands exactly as written.
-- ⚠ AN EXAMPLE IS A CLAIM, NOT A PROOF: `x == nil` -> `not x` itself changes behaviour when x is false. The rule
-- applies what was demonstrated and claims nothing more (`preserves = 'none'`); the caller's specs are the oracle.
-- ⚠ WHERE IT APPLIES IS A DECISION: the matches are inferred, so without a `scope` the plan refuses as a decision
-- that lists them (the wrong-symbol lesson: nothing inferred is applied behind the caller).
-- ⚠ FIRST CUT, MEASURED: matching is TRIVIA-SENSITIVE — `y==nil` does not match an example written `x == nil`.
local tsutil = require 'cartograph.spec.tsutil' -- (tsutil.inext: indexed child iteration, CART-1453)
local M = {}

local function A() return require('cartograph.algebra').load() end

local function get(t, path) for _, i in ipairs(path) do t = t.kids[i] end return t end

-- (a NAME by the grammars' convention, the tokens their `word` rule lexes: `identifier` and its kinds — lua, python, js's
-- `property_identifier`, go's `field_identifier` — or `name`, php's: a rule learned in php held NO hole until this
-- read past `identifier`, so `$c` matched only `$c`). The reader ESCAPES a kind the algebra reserves (php's `name` is
-- read as `name_`), so the term's kind is mapped back through its grammar's escapes first.
local function name_kinds(lang)
    local back = {}
    for k, esc in pairs(require('cartograph.algebraread').escapes(lang)) do back[esc] = k end
    return setmetatable({}, { __index = function (t, k)
        local orig = back[k] or k
        local v = orig == 'name' or orig:sub(-10) == 'identifier'
        rawset(t, k, v); return v
    end })
end

local function has_name(t, nk)
    if nk[t.k] then return true end
    for _, c in ipairs(t.kids or {}) do if has_name(c, nk) then return true end end
    return false
end

local function subtrees(t, out)
    out[#out + 1] = t
    for _, c in ipairs(t.kids or {}) do subtrees(c, out) end
    return out
end

--- the values the right side's holes need (instantiate refuses a value for a hole its template does not have)
local function only_holes(T, values)
    local out = {}
    for h in pairs(T.holes or {}) do out[h] = values[h] end
    return out
end

-- ── SPACING-INDEPENDENT MATCHING (CART-1664) ─────────────────────────────────────────────────────────────────────
-- The matcher compared whitespace tokens too, so a one-line example matched only one-line targets. A rule now ALSO
-- carries its sides without whitespace tokens; a target that does not match exactly is matched on structure, and the
-- edit is applied as a TOKEN SCRIPT on the target's own text (kept tokens keep their spacing, a deleted token takes its
-- preceding whitespace, an inserted one takes the example's), a moved body re-indented by the removed wrapper's level,
-- and the result PARSED BACK: it must read as the rule's right side, else the site is refused — that check is what keeps
-- a whitespace-significant language (python's indentation) honest without listing it. A comment is NOT whitespace: it
-- stays in the structure, and one beside a deleted token refuses the site (it may describe the deleted code).
local function ws_lit(t) return t.k == 'lit' and t.trivia and not tostring(t.v):match('%S') end
-- (the MATCHING view also drops comment nodes — tsutil.COMMENT, every grammar's comment types: printing walks the
-- ORIGINAL, so a comment inside a body travels with it, and one beside a deleted token refuses the site by name)
local function strip(a, t, orig)
    if t.k == 'hole' or not t.kids then return t end
    local kids = {}
    for _, c in ipairs(t.kids) do if not ws_lit(c) and not tsutil.COMMENT[c.k] then kids[#kids + 1] = strip(a, c, orig) end end
    local s = a.rebuild(t, kids)
    if orig then orig[s] = t end
    return s
end
M._strip = strip

-- ★ DOES THE RULE KEEP BEHAVIOUR? (CART-1664) An example is a claim; `x == nil -> not x` RELAXES the check — it also
-- takes `false`. Before any site is touched, a Lua EXPRESSION rule is run on both sides over sampled values for its
-- holes, and the first disagreement is NAMED: the plan then stops for a decision. A side that reads a name the sample
-- does not model (`f(a)`: `f` is free) or raises on every sample is UNCHECKED, never "equal" — both sides raising
-- on every value compared nothing. A statement rule (a loop) is unchecked: the sample has no world to run.
-- -> { verdict = 'equal' | 'differs' | 'unchecked', why, at = { hole = label }, left, right, samples }
local SAMPLES = { { 'nil' }, { 'false', false }, { 'true', true }, { '0', 0 }, { '1', 1 }, { '-1', -1 }, { '0.5', 0.5 },
    { "''", '' }, { "'a'", 'a' }, { "'0'", '0' }, { '{}', {} }, { '{1}', { 1 } } }
local function sample_rule(a, lhs, rhs, names, lang)
    if lang ~= 'lua' then return { verdict = 'unchecked', why = 'the sampler runs the sides as LuaJIT code' } end -- @langs-ok the sampler evaluates with LuaJIT itself
    local hs = {}
    for h in pairs(lhs.holes or {}) do hs[#hs + 1] = h end
    table.sort(hs)
    local function rep_in(t) if t.k == 'hole' and t.rep then return true end for _, c in ipairs(t.kids or {}) do if rep_in(c) then return true end end end
    if rep_in(lhs.body or lhs) or rep_in(rhs.body or rhs) then return { verdict = 'unchecked', why = 'a sequence hole: a statement rule, no expression to run' } end
    if #hs > 3 then return { verdict = 'unchecked', why = ('%d holes: too many to sample'):format(#hs) } end
    local V, params = {}, {}
    for i, h in ipairs(hs) do V[h] = a.lit('_h' .. i); params[i] = '_h' .. i end
    local free = {}
    local env = setmetatable({}, { __index = function (_, k) free[k] = true end, __newindex = function (_, k) free[k] = true end })
    local function compile(T)
        local inst = a.instantiate(T, only_holes(T, V))
        if not inst.ok then return nil end
        local chunk = loadstring('return function (' .. table.concat(params, ', ') .. ') return ' .. a.cst_print(inst.term) .. '\nend')
        if not chunk then return nil end
        setfenv(chunk, env)
        return chunk()
    end
    local fl, fr = compile(lhs), compile(rhs)
    if not fl or not fr then return { verdict = 'unchecked', why = 'a side is no Lua expression' } end
    local function norm(err) return (tostring(err):gsub('^%[string [^%]]*%]:%d+: ', '')) end
    local idx, total, raised, first = {}, 0, 0, nil
    local bad = {} -- (EVERY differing sample: { [hole] = sample index } — a site is cleared only if it avoids them all)
    for i = 1, #hs do idx[i] = 1 end
    while true do
        local args = {}
        for i = 1, #hs do local v = SAMPLES[idx[i]][2]; args[i] = type(v) == 'table' and vim.deepcopy(v) or v end
        local ok1, r1 = pcall(fl, unpack(args, 1, #hs))
        local ok2, r2 = pcall(fr, unpack(args, 1, #hs))
        total = total + 1
        if next(free) then
            local n = {}
            for k in pairs(free) do n[#n + 1] = '`' .. tostring(k) .. '`' end
            table.sort(n)
            return { verdict = 'unchecked', why = ('it reads %s, which the sample does not model'):format(table.concat(n, ', ')) }
        end
        local same
        -- (both raising agrees: the messages name the variables differently — `x .. nil` and `nil .. x` both fail)
        if ok1 and ok2 then same = rawequal(r1, r2) elseif not ok1 and not ok2 then same = true; raised = raised + 1 else same = false end
        if not same then
            local tuple = {}
            for i, h in ipairs(hs) do tuple[h] = idx[i] end
            bad[#bad + 1] = tuple
            if not first then
                local at = {}
                for i, h in ipairs(hs) do at[names[h] or h] = SAMPLES[idx[i]][1] end
                local function show(ok_, r) return ok_ and vim.inspect(r) or ('raises: ' .. norm(r)) end
                first = { verdict = 'differs', at = at, left = show(ok1, r1), right = show(ok2, r2) }
            end
        end
        local i = 1
        while i <= #hs and idx[i] == #SAMPLES do idx[i] = 1; i = i + 1 end
        if i > #hs then break end
        idx[i] = idx[i] + 1
    end
    if first then first.samples, first.bad = total, bad; return first end
    if raised == total then return { verdict = 'unchecked', why = 'both sides raise on every sample' } end
    return { verdict = 'equal', samples = total }
end

-- ★ PER SITE (CART-1668): a rule that changes behaviour may still keep it at a site whose operand CANNOT take the
-- values it treats differently — `x == nil -> not x` under `if type(x) == 'table'`. `facts` = the narrowing facts at
-- the site (narrow.facts_at: dominating guards, raw kinds); a hole bound to a closed constant knows its own type. A
-- fact rules a sample out by its TYPE or truthiness only — an exact value (`eq:`) rules out only by its type, since
-- the sample is not the domain (`x > 0 -> x >= 1` differs at 0.7, sampled only at 0.5). Relative to the sample, as
-- the verdict is. -> true when every differing sample is ruled out by some hole's evidence
local function kind_pred(kind)
    if kind == 'truthy' then return function (v) return v ~= nil and v ~= false end end
    if kind == 'non-nil' then return function (v) return v ~= nil end end
    local ty = kind:match('^type:(.+)$') or (kind:match('^eq:s:') and 'string') or (kind:match('^eq:n:') and 'number')
    if ty then return function (v) return type(v) == ty end end
end
function M.site_keeps(rule, values, facts)
    local s = rule.sample
    if not s or s.verdict ~= 'differs' then return true end
    if not s.bad then return false end
    local a = A()
    local pred = {}
    for h, v in pairs(values or {}) do
        if type(v) == 'table' and v.k then
            local text = a.cst_print(v)
            local kind = facts and facts[text]
            if kind then pred[h] = kind_pred(kind) end
            if not pred[h] then
                -- (a closed constant: no name read, no error — its own type is its evidence)
                -- (no call: a literal's method — `("x"):rep(1e10)` — reads no name and still runs)
                local chunk = not text:find('[(:]') and loadstring('return ' .. text)
                if chunk then
                    local read = false
                    setfenv(chunk, setmetatable({}, { __index = function () read = true end }))
                    local ok_, c = pcall(chunk)
                    if ok_ and not read then pred[h] = function (x) return type(x) == type(c) end end
                end
            end
        end
    end
    for _, tuple in ipairs(s.bad) do
        local ruled_out = false
        for h, i in pairs(tuple) do
            if pred[h] and not pred[h](SAMPLES[i][2]) then ruled_out = true; break end
        end
        if not ruled_out then return false end
    end
    return true
end

--- the sampled verdict as a sentence (the plan's decision, the learned rule's report)
function M.behaviour_text(r)
    local v = r.sample
    if not v then return nil end
    if v.verdict == 'differs' then
        local at = {}
        for k, x in pairs(v.at) do at[#at + 1] = k .. ' = ' .. x end
        table.sort(at)
        return ('`%s` -> `%s` CHANGES BEHAVIOUR: %s the left side gives %s, the right %s'):format(r.lhs_text, r.rhs_text,
            #at > 0 and ('at ' .. table.concat(at, ', ')) or 'always:', v.left, v.right)
    elseif v.verdict == 'equal' then
        return ('`%s` -> `%s`: both sides agree on %d sampled value(s) — a sample, not a proof'):format(r.lhs_text, r.rhs_text, v.samples)
    end
    return ('`%s` -> `%s`: behaviour unchecked (%s)'):format(r.lhs_text, r.rhs_text, v.why)
end

--- Learn the rules an example demonstrates. -> { { lhs, rhs, lhs_text, rhs_text } } | nil, why, class
function M.learn(before, after, lang)
    lang = lang or 'lua' -- @langs-ok the reader roster decides; algebraread refuses an unregistered language by name
    local a = A()
    if not a then return nil, 'algebra unavailable', 'environment' end
    local R = require 'cartograph.algebraread'
    local nk = name_kinds(lang)
    local Tb, bwhy = R.read(before, lang)
    if not Tb then return nil, 'the BEFORE text does not read: ' .. tostring(bwhy), 'ill-posed' end
    local Ta, awhy = R.read(after, lang)
    if not Ta then return nil, 'the AFTER text does not read: ' .. tostring(awhy), 'ill-posed' end
    local regions = {}
    a.diff_regions(Tb, Ta, {}, regions)
    if #regions == 0 then return nil, 'before and after are the same term: the example demonstrates no edit', 'ill-posed' end
    -- ★ DEPENDENT REGIONS ARE ONE EDIT (CART-1435). A region's rule carries over only ITS OWN subterms, so a move that
    -- takes a subterm OUT of one region and INTO another — `x:SetFont(D:GetContentFont("normal"))` ->
    -- `D:SetContentFont(x, "normal")`, the receiver moving into the arguments — was learned as independent token rules,
    -- one of them `iconText -> TSMAPI.Design` (83 sites in TSM). When one region's AFTER side carries a named subterm of
    -- another's BEFORE side, the two are merged at their lowest common ancestor (and every region under it dropped),
    -- to a fixpoint: the rule is then the whole demonstrated edit, its moved subterm a hole on both sides.
    -- (lifted FIRST: a bare-token region is its node — the per-region loop below says why — and a dependence between
    -- regions is between nodes: `f(a, b)` -> `g(b, a)` reports the literals `a` and `b`, the identifiers carry them)
    for k, path in ipairs(regions) do
        while #path > 0 and (get(Tb, path).k == 'lit' or get(Ta, path).k == 'lit') do
            local up = {}
            for i = 1, #path - 1 do up[i] = path[i] end
            path = up
        end
        regions[k] = path
    end
    local function carries(pi, pj)
        local bsubs, found = subtrees(get(Tb, pi), {}), false
        local function look(t)
            if found then return end
            if t.k ~= 'lit' and has_name(t, nk) then
                for _, s in ipairs(bsubs) do if a.eq(s, t) then found = true; return end end
            end
            for _, c in ipairs(t.kids or {}) do look(c) end
        end
        look(get(Ta, pj))
        return found
    end
    local function under(p, q) -- is q at or below p?
        if #q < #p then return false end
        for i = 1, #p do if p[i] ~= q[i] then return false end end
        return true
    end
    local merged = true
    while merged and #regions > 1 do
        merged = false
        for i = 1, #regions do
            for j = 1, #regions do
                if not merged and i ~= j and carries(regions[i], regions[j]) then
                    local l = {}
                    for k = 1, math.min(#regions[i], #regions[j]) do
                        if regions[i][k] ~= regions[j][k] then break end
                        l[k] = regions[i][k]
                    end
                    local keep = { l }
                    for _, r in ipairs(regions) do if not under(l, r) then keep[#keep + 1] = r end end
                    regions, merged = keep, true
                end
            end
        end
    end
    -- ★ ONE STATEMENT, ONE EDIT (CART-1664). Two regions inside the SAME top-level statement of the example are one
    -- demonstrated edit even when neither carries the other's subterms: `for _, c in tsutil.inext, n, -1 do if
    -- c:named() then walk(c) end end` -> `for _, c in tsutil.inamed, n, -1 do walk(c) end` was learned as `inext ->
    -- inamed` (every inext loop, check or not) plus `if c:named() then walk(c) end -> walk(c)` (every named check,
    -- loop or not) — each wrong alone. Merged at their lowest common ancestor. Edits in DIFFERENT top-level statements
    -- stay separate rules (an example of two independent edits is two statements); two independent edits nested in
    -- one statement become one, more specific, rule — show them as two statements instead.
    local merged2 = true
    while merged2 and #regions > 1 do
        merged2 = false
        for i = 1, #regions do
            for j = i + 1, #regions do
                local ri, rj = regions[i], regions[j]
                if not merged2 and #ri > 0 and #rj > 0 and ri[1] == rj[1] then
                    local l = {}
                    for k = 1, math.min(#ri, #rj) do
                        if ri[k] ~= rj[k] then break end
                        l[k] = ri[k]
                    end
                    local keep = { l }
                    for _, r in ipairs(regions) do if not under(l, r) then keep[#keep + 1] = r end end
                    regions, merged2 = keep, true
                end
            end
        end
    end
    -- a region's RULE SIDES: its before and after subterms with the carried-over subterms made holes -> lhs term, rhs
    -- term, Lb, La, the number of holes
    local function sides(path)
        local Lb, La = get(Tb, path), get(Ta, path)
        -- the carried-over subterms: MAXIMAL subtrees of the after-region equal to one in the before-region
        local bsubs, picks = subtrees(Lb, {}), {}
        -- ★ A NAME USED TWICE IS ONE HOLE (CART-1664): `for _, c in … do if c:named() …` — the maximal pick `_, c` held
        -- the loop variable, so `c:named()` kept a literal `c` and a loop over `x` never matched. A subterm holding a
        -- name the before-region uses MORE THAN ONCE is not picked whole; the pick descends, and the name is a hole of
        -- its own wherever it occurs
        local count = {}
        local function count_names(t)
            if t.k ~= 'lit' and not (t.kids and #t.kids > 1) then
                local s = a.cst_print(t):match('^%s*([%a_][%w_]*)%s*$')
                if s then count[s] = (count[s] or 0) + 1 end
            end
            for _, c in ipairs(t.kids or {}) do count_names(c) end
        end
        count_names(Lb)
        local function holds_repeat(t)
            for _, c in ipairs(t.kids or {}) do
                local s = c.k ~= 'lit' and a.cst_print(c):match('^%s*([%a_][%w_]*)%s*$')
                if (s and (count[s] or 0) > 1) or holds_repeat(c) then return true end
            end
            return false
        end
        -- ★ A SOLE STATEMENT IS ITS SEQUENCE (CART-1664): a node of the after-region that is the ONLY non-token child of
        -- its parent, and is carried over intact from a before-node that is the only non-token child of ITS parent (a
        -- loop body's one statement in the example), stands for any sequence there — both parents' children become one
        -- HEDGE hole, so the rule matches a body of any length and prints the target's own, formatting included.
        -- Decided BEFORE the picks: a repeated name inside it (`walk(c)`) must not split it
        local function sole(parent, child)
            if not parent then return false end
            local n = 0
            for _, c in ipairs(parent.kids or {}) do
                if c.k ~= 'lit' then n = n + 1; if c ~= child then return false end end
            end
            return n == 1
        end
        local function parents(root, out)
            for _, c in ipairs(root.kids or {}) do out[c] = root; parents(c, out) end
            return out
        end
        local pa_of, pb_of = parents(La, {}), parents(Lb, {})
        local SB = require('cartograph.narrow').STMT_BLOCK
        local seqs, seq_kid = {}, {} -- seqs: parent node (either side, by identity) -> hole name; seq_kid: the after kid
        local nseq = 0
        local function find_seq(t)
            local pa = pa_of[t]
            if t.k ~= 'lit' and pa and pa ~= La and sole(pa, t) then
                for b, pb in pairs(pb_of) do
                    -- (both parents the SAME kind — a body is a body — or both STATEMENT BLOCKS of the grammar
                    -- (narrow.STMT_BLOCK: ruby's if `then` and a block's `body_statement`, CART-1666); and the carried
                    -- node more than one name: an identifier is a hole of its own, and `a` of `local a` must not pair
                    -- with the `a` of `return a`)
                    if b.k ~= 'lit' and pb ~= Lb and a.eq(b, t) and sole(pb, b) and not seqs[pb]
                        and (pa.k == pb.k or (SB[pa.k] and SB[pb.k])) and not a.cst_print(t):match('^%s*[%a_][%w_]*%s*$') then
                        nseq = nseq + 1
                        seqs[pa], seqs[pb], seq_kid[t] = 's' .. nseq, 's' .. nseq, true
                        return
                    end
                end
            end
            for _, c in ipairs(t.kids or {}) do find_seq(c) end
        end
        find_seq(La)
        local function pick(t)
            if seq_kid[t] then return end
            if t.k ~= 'lit' and has_name(t, nk) and not holds_repeat(t) then
                for _, s in ipairs(bsubs) do
                    if a.eq(s, t) then
                        for _, p in ipairs(picks) do if a.eq(p, t) then return end end
                        picks[#picks + 1] = t
                        return
                    end
                end
            end
            for _, c in ipairs(t.kids or {}) do pick(c) end
        end
        pick(La)
        local function holed(t)
            if seqs[t] then return a.rebuild(t, { a.hole(seqs[t], true) }) end
            for k, p in ipairs(picks) do if a.eq(p, t) then return a.hole('h' .. k) end end
            if t.k == 'lit' or not t.kids then return t end
            local kids = {}
            for i, c in ipairs(t.kids) do kids[i] = holed(c) end
            return a.rebuild(t, kids)
        end
        -- ★ EVERY HOLE THE RIGHT SIDE USES MUST BE BOUND BY THE LEFT (CART-1173). MEASURED: inserting `a = a + 1`
        -- between `local a = 1` and `return a` picked the two statements AND the identifier `a`; the left side's
        -- statement holes swallowed every `a`, so the right side's `a` hole was bound by nothing, instantiation failed
        -- at every site, and the rule "matched nothing" on an identical body. So a larger pick that CONTAINS a pick the
        -- right side still needs unbound is dropped, until every right-side hole is bound: the rule becomes
        -- `local ?1 = 1; return ?1` -> `local ?1 = 1; ?1 = ?1 + 1; return ?1`.
        local function holes_of(t, out)
            out = out or {}
            if t.k == 'hole' and t.h then out[t.h] = true end -- algebra/core: { k = 'hole', h = <name> }
            for _, c in ipairs(t.kids or {}) do holes_of(c, out) end
            return out
        end
        local function contains(big, small)
            if a.eq(big, small) then return true end
            for _, c in ipairs(big.kids or {}) do if contains(c, small) then return true end end
            return false
        end
        for _ = 1, #picks do
            local hb, ha = holes_of(holed(Lb)), holes_of(holed(La))
            local unbound = {}
            for k, p in ipairs(picks) do if ha['h' .. k] and not hb['h' .. k] then unbound[#unbound + 1] = p end end
            if #unbound == 0 then break end
            local keep = {}
            for _, p in ipairs(picks) do
                local swallows = false
                for _, u in ipairs(unbound) do if p ~= u and contains(p, u) then swallows = true; break end end
                if not swallows then keep[#keep + 1] = p end
            end
            if #keep == #picks then break end
            picks = keep
        end
        return holed(Lb), holed(La), Lb, La, #picks
    end
    -- ★ A REGION WITH NO CONSTANT IS NO EVIDENCE (CART-1452). When its rule's LEFT side holds nothing but holes and
    -- node kinds, it matches any node of that kind: `for c in n:iter_children()` -> `for _, c in tsutil.inext, n, -1`
    -- made the binder list a region of its own, `c -> _, c` (`?1 -> _, ?1`), which rewrote EVERY one-name list in a
    -- file (547 corrupt declarations in flow.lua) while its demonstration passed. Such a region is lifted to its parent
    -- until its left side holds a constant (a token: here the clause's `in`), and a region it then contains is part of it
    local function constant(t)
        if t.k == 'lit' then return tostring(t.v):match('%S') ~= nil end
        for _, c in ipairs(t.kids or {}) do if constant(c) then return true end end
        return false
    end
    for _ = 1, 10000 do
        local lifted = false
        for k, path in ipairs(regions) do
            if #path > 0 and not constant((sides(path))) then
                local up = {}
                for i = 1, #path - 1 do up[i] = path[i] end
                local keep = { up }
                for j, r in ipairs(regions) do if j ~= k and not under(up, r) then keep[#keep + 1] = r end end
                regions, lifted = keep, true
                break
            end
        end
        if not lifted then break end
    end
    local rules = {}
    for _, path in ipairs(regions) do
        -- ⚠ A REGION THAT IS A BARE TOKEN IS LIFTED TO ITS NODE. `x == 0` -> `x <= 0` differs only in the operator,
        -- and a rule `== -> <=` would rewrite EVERY `==` in a file (`x == nil` included): the demonstrated edit is
        -- the comparison, so the region is the expression that holds the token
        while #path > 0 and (get(Tb, path).k == 'lit' or get(Ta, path).k == 'lit') do
            local up = {}
            for i = 1, #path - 1 do up[i] = path[i] end
            path = up
        end
        local hl, hr, Lb, La, nholes = sides(path)
        local lhs, rhs = a.template(hl), a.template(hr)
        -- (the spacing-free sides; an example that differs ONLY in spacing would match everything, its output included)
        local sl, sr = strip(a, hl), strip(a, hr)
        if a.eq(sl, sr) then
            return nil, ('the example differs only in spacing (`%s`): a spacing-free rule would match everything'):format(a.cst_print(Lb)), 'ill-posed'
        end
        local lhs_ws, rhs_ws = a.template(sl), a.template(sr)
        if a.match(lhs_ws, strip(a, La)).ok then
            return nil, ('the learned rule `%s -> %s` matches its own output once spacing is ignored — applying it again would rewrite forever')
                :format(a.cst_print(Lb), a.cst_print(La)), 'ill-posed'
        end
        -- ★ A RULE THAT MATCHES ITS OWN OUTPUT NEVER RUNS OUT OF WORK (and could not be re-run as `empty`)
        if a.match(lhs, La).ok then
            return nil, ('the learned rule `%s -> %s` matches its own output — applying it again would rewrite forever')
                :format(a.cst_print(Lb), a.cst_print(La)), 'ill-posed'
        end
        -- (the holes by the example's own spelling — `x`, not `h1` — for the behaviour verdict)
        local names, mb = {}, a.match(lhs, Lb)
        for h, v in pairs(mb.ok and mb.values or {}) do if type(v) == 'table' and v.k then names[h] = a.cst_print(v) end end
        rules[#rules + 1] = { lhs = lhs, rhs = rhs, lhs_text = a.cst_print(Lb), rhs_text = a.cst_print(La), holes = nholes,
            lhs_ws = lhs_ws, rhs_ws = rhs_ws, rhs_term = hr, sample = sample_rule(a, lhs, rhs, names, lang) }
    end
    return rules
end

-- one SPACING-INDEPENDENT site: the target node `o` (original), its stripped view `s` (orig maps stripped -> original),
-- the match's values, `reread(text)` (the file with the node's text replaced, read again -> the node's term at its
-- place | nil, why) -> the new text of the node, its re-read term | nil, why, class
local function ws_edit(a, rule, o, s, values, orig, reread)
    -- 1. the left side's UNITS over the target, in order: a fixed token (its original lit), or a hole (its nodes)
    local lu = {}
    local function walk(tt, st)
        local j = 1
        for _, tk in ipairs(tt.kids or {}) do
            if tk.k == 'hole' then
                local v = values[tk.h]
                local n = tk.rep and (v and v.kids and #v.kids or 0) or 1
                local nodes = {}
                for x = j, j + n - 1 do nodes[#nodes + 1] = orig[st.kids[x]] or st.kids[x] end
                lu[#lu + 1] = { key = 'H:' .. tk.h, nodes = nodes }
                j = j + n
            elseif tk.k == 'lit' then
                -- (a token's key includes its PARENT's kind: the `if`'s `end` is not the `for`'s. Not the whole ancestry:
                -- a carried call's `(` `)` keep their parent when the `if` around them goes — keyed by the path, ruby's
                -- `f(it)` lost its `)` to a delete + insert)
                lu[#lu + 1] = { key = 'L:' .. tostring(tk.v) .. '@' .. tostring(tt.k), lit = st.kids[j] }
                j = j + 1
            else
                walk(tk, st.kids[j])
                j = j + 1
            end
        end
    end
    walk(rule.lhs_ws.body or rule.lhs_ws, s)
    -- 2. the right side's units, and the whitespace the example puts before each fixed token
    local ru = {}
    local function rwalk(t)
        for _, c in ipairs(t.kids or {}) do
            if c.k == 'hole' then ru[#ru + 1] = { key = 'H:' .. c.h, h = c.h }
            elseif c.k == 'lit' then ru[#ru + 1] = { key = 'L:' .. tostring(c.v) .. '@' .. tostring(t.k), lit = c }
            else rwalk(c) end
        end
    end
    rwalk(rule.rhs_ws.body or rule.rhs_ws)
    local before_ws, before_hole, last = {}, {}, ''
    local function wwalk(t)
        for _, c in ipairs(t.kids or {}) do
            if c.k == 'lit' then
                if ws_lit(c) then last = last .. tostring(c.v) else before_ws[c] = last; last = '' end
            elseif c.k == 'hole' then if before_hole[c.h] == nil then before_hole[c.h] = last end; last = ''
            else wwalk(c) end
        end
    end
    wwalk(rule.rhs_term)
    -- 3. align them (a longest common subsequence of the unit keys): what is kept, deleted, inserted
    local n1, n2 = #lu, #ru
    local L = {}
    for i = 0, n1 do L[i] = {}; for j = 0, n2 do L[i][j] = 0 end end
    for i = n1, 1, -1 do for j = n2, 1, -1 do
        L[i - 1] = L[i - 1] or {}
        if lu[i].key == ru[j].key then L[i - 1][j - 1] = L[i][j] + 1
        else L[i - 1][j - 1] = math.max(L[i][j - 1], L[i - 1][j]) end
    end end
    local keep, ins_before = {}, {} -- keep[lhs unit] = true; ins_before[lhs unit index | n1+1] = { rhs units }
    local i, j = 1, 1
    while i <= n1 and j <= n2 do
        if lu[i].key == ru[j].key then keep[i] = j; i = i + 1; j = j + 1
        elseif L[i][j - 1] >= L[i - 1][j] then i = i + 1
        else ins_before[i] = ins_before[i] or {}; table.insert(ins_before[i], ru[j]); j = j + 1 end
    end
    while j <= n2 do ins_before[n1 + 1] = ins_before[n1 + 1] or {}; table.insert(ins_before[n1 + 1], ru[j]); j = j + 1 end
    -- (a hole INSERTED is a move — the exact path's business; a hole occurrence DROPPED is deleted text, its value
    -- kept wherever else the right side uses it: the `c` of the deleted `c:named()`)
    for _, list in pairs(ins_before) do for _, u in ipairs(list) do if u.h then return nil, 'a hole the edit moves', 'frontier' end end end
    -- 4. roles of the original leaves: the first leaf of each unit (where insertions go), the deleted lits
    local first_of, deleted = {}, {}
    local function first_leaf(t) if t.k == 'lit' then return t end for _, c in ipairs(t.kids or {}) do local f = first_leaf(c); if f then return f end end end
    local function leaves(t, out) if t.k == 'lit' then out[#out + 1] = t end for _, c in ipairs(t.kids or {}) do leaves(c, out) end return out end
    for k, u in ipairs(lu) do
        local f = u.lit or (u.nodes[1] and first_leaf(u.nodes[1]))
        if f then first_of[f] = k end
        if not keep[k] and u.lit then deleted[u.lit] = true end
        if not keep[k] and u.nodes then
            for _, nd in ipairs(u.nodes) do for _, lf in ipairs(leaves(nd, {})) do if not ws_lit(lf) then deleted[lf] = true end end end
        end
    end
    local hedge_first, hedge_last = {}, {}
    for k, u in ipairs(lu) do
        if u.nodes and #u.nodes > 0 and keep[k] then hedge_first[u.nodes[1]] = k; hedge_last[u.nodes[#u.nodes]] = k end
    end
    -- 5. emit the original's leaves, applying the script
    local buf, blen = {}, 0
    local function put(x) buf[#buf + 1] = x end
    local function text() return table.concat(buf) end
    local refused
    local just_deleted = false
    local owed, owed_mark -- (a deleted line-start's line break, owed to the next kept code; the text offset it is owed at)
    local marks = {} -- hedge unit -> { start offset, end offset } in the output
    local first_deleted_line_indent
    local function emit_ins(k)
        if not ins_before[k] then return end
        -- (inserted tokens go BEFORE the spacing that leads to the kept token, on its line: `a == null` -> `a === null`,
        -- not `a  ===null`. A leading LINE BREAK stays first: what is inserted starts that line.)
        -- (the first starts where the target's spacing did when it opens the right side; between the last and the kept
        -- token after it, the EXAMPLE's spacing: `x in` -> `_, x in`, `(y)` -> `not (y)`)
        local s0 = text()
        local body = s0:gsub('[ \t]*$', '')
        local trail = s0:sub(#body + 1)
        local moved = trail ~= '' and not body:find('\n$')
        if moved then buf = { body } end
        for x, u in ipairs(ins_before[k]) do
            local ws = before_ws[u.lit] or ''
            if x == 1 and moved and (ws == '' and u == ru[1]) then ws = trail end
            put(ws .. tostring(u.lit.v))
        end
        local nx = keep[k] and ru[keep[k]]
        if nx then put((nx.lit and before_ws[nx.lit]) or (nx.h and before_hole[nx.h]) or '')
        elseif moved then put(trail) end
    end
    local frozen = {} -- (a token that spans lines — a long string, a block comment — keeps its CONTINUATION lines as they
    -- are: they are the token's VALUE, like a heredoc's, so re-indenting skips them; { first, last offset } in the output)
    local function walk_out(t)
        if hedge_first[t] then local k = hedge_first[t]; marks[k] = marks[k] or {}; marks[k][1] = #text() end
        if tsutil.COMMENT[t.k] and just_deleted then refused = 'a comment beside a deleted token (it may describe the deleted code)' end
        if t.k == 'lit' then
            local k = first_of[t]
            if k then emit_ins(k) end
            if deleted[t] then
                -- the deleted token takes its preceding whitespace; the indentation of a line it STARTED is noted, and
                -- that line break is owed to the next kept code if it would otherwise land on the line before — only the
                -- break right after KEPT code: one between two deleted tokens was the deleted code's own layout (php's
                -- `) {` + `\n if (…) {` keeps the inner `{` on the loop's line, as written)
                local s0 = text()
                local stripped = s0:gsub('[ \t]*\n?[ \t]*$', '')
                local ws0 = s0:sub(#stripped + 1)
                if ws0:find('\n') then
                    if not first_deleted_line_indent then first_deleted_line_indent = #(s0:match('\n([ \t]*)$') or '') end
                    if not owed and not just_deleted then owed = ws0:match('\n[ \t]*$') end
                end
                buf = { stripped }
                owed_mark = #stripped
                just_deleted = true
            else
                if not ws_lit(t) then
                    just_deleted = false
                    -- (kept code after a deleted line-start: on its own line, as the deleted token was)
                    if owed then
                        local since = text():sub(owed_mark + 1)
                        if not since:find('\n') then
                            buf = { text():sub(1, owed_mark) }
                            put(owed)
                        end
                        owed = nil
                    end
                end
                local v = tostring(t.v)
                if not ws_lit(t) and v:find('\n') then frozen[#frozen + 1] = { #text() + 1, #text() + #v } end
                put(v)
            end
        else
            for _, c in ipairs(t.kids or {}) do walk_out(c) end
        end
        if hedge_last[t] then local k = hedge_last[t]; marks[k] = marks[k] or {}; marks[k][2] = #text() end
    end
    walk_out(o)
    emit_ins(n1 + 1)
    if refused then return nil, refused, 'decision' end
    local out = text()
    local undented = out
    -- 6. a moved body follows its new parent: its LINES dedented by the level the removed wrapper line had (the body's
    -- indent minus the anchor's — the kept line before it — minus that level), when every body line can give it; the
    -- continuation lines of a token spanning lines stay as they are (a long string's lines, like a heredoc's, are its value)
    if first_deleted_line_indent then
        local lines = vim.split(out, '\n', { plain = true })
        local function line_at(off) local _, nl = out:sub(1, off):gsub('\n', ''); return nl + 1 end
        local keep = {}
        -- (a line whose line break BEFORE it is a character of a token's value: its indentation, even none — the column a
        -- python string's closing quotes sit at — is that value's)
        for _, f in ipairs(frozen) do
            local p = f[1] - 1
            while true do p = out:find('\n', p + 1, true); if not p or p > f[2] then break end; keep[line_at(p)] = true end
        end
        for _, m in pairs(marks) do
            if m[1] and m[2] then
                local l1, l2 = line_at(m[1] + 1), line_at(math.max(m[2], m[1] + 1))
                -- (a body that STARTS mid-line — php's kept `{ … }` block after the loop's `)` — is re-indented from
                -- its next line: its first line is the line it joined)
                local ls = (out:sub(1, m[1]):match('.*\n()') or 1)
                if out:sub(ls, m[1]):match('%S') then l1 = l1 + 1 end
                while l1 <= l2 and (keep[l1] or not lines[l1]:match('%S')) do l1 = l1 + 1 end
                local anchor_line
                for x = l1 - 1, 1, -1 do if lines[x]:match('%S') then anchor_line = x; break end end
                if anchor_line and l1 <= l2 then
                    local anchor = #lines[anchor_line]:match('^[ \t]*')
                    local cur = #lines[l1]:match('^[ \t]*')
                    local delta = cur - first_deleted_line_indent
                    local ok_ = delta > 0 and first_deleted_line_indent > anchor
                    for x = l1, l2 do if not keep[x] and lines[x]:match('%S') and #lines[x]:match('^[ \t]*') < delta then ok_ = false end end
                    if ok_ then for x = l1, l2 do if not keep[x] and lines[x]:match('%S') then lines[x] = lines[x]:sub(delta + 1) end end end
                end
            end
        end
        out = table.concat(lines, '\n')
    end
    -- 7. PARSED BACK, IN ITS FILE: the new text must read as the rule's right side where it stands — a fragment read
    -- alone is not the language (php's is inline HTML without its `<?php`; python's indentation means something only
    -- inside its block), and the rest of the file must read as it did. And every CARRIED value must read as it did
    -- but for layout: the right side's holes match anything, so a re-indent that changed a string's content — php's
    -- heredoc lines are separated by whitespace GAPS the reader takes for layout — passed until this compared them.
    -- A re-indent that fails is retried without it (the body keeps its old depth: valid, only less tidy).
    local function check(text)
        local stmt, rwhy = reread(text)
        if not stmt then return nil, rwhy, 'frontier' end
        local m2 = a.match(rule.rhs_ws, strip(a, stmt))
        if not m2.ok then return nil, 'the rewritten text does not read as the rule\'s right side', 'frontier' end
        for h, v in pairs(m2.values or {}) do
            if values[h] ~= nil and not a.eq(values[h], v, true) then return nil, ('the carried `%s` reads differently after the edit'):format(h), 'frontier' end
        end
        return stmt
    end
    local stmt, cwhy = check(out)
    if not stmt and undented ~= out then out = undented; stmt, cwhy = check(out) end
    if not stmt then return nil, cwhy, 'frontier' end
    return out, stmt
end

--- Apply rules to a source text. -> new text, sites (the number of rewrites), refused (spacing-independent sites
--- matched but refused: { { line, why } }) | nil, why
-- `admit(site)` (optional, CART-1668): asked before a site is taken — site = { rule, values, where } where `where()`
-- gives the site's 0-based row, col in `src` while the text is still `src` (the first pass, before any put), else
-- nil; a site it declines is UNDECIDED: left as written and listed.
local function rewrite_once(rules, src, lang, admit, pristine)
    local a = A()
    local t, why = require('cartograph.algebraread').read(src, lang or 'lua') -- @langs-ok as learn
    if not t then return nil, why, 'frontier' end
    local sites, refused, undecided = 0, {}, {}
    local function admitted(rule, values, pos)
        if not admit then return true end
        local site = { rule = rule, values = values, where = function ()
            if not pristine then return nil end
            local marked = a.cst_print(a.put(t, pos.path, a.lit('\0')))
            local off = marked:find('\0', 1, true) - 1
            local before = src:sub(1, off)
            local _, row = before:gsub('\n', '')
            return row, #before:match('[^\n]*$')
        end }
        if admit(site) then return true end
        -- (named by its LINE when the text is still `src`: an expression site alone — `q == nil` — locates nothing)
        local row = site.where()
        local line = row and (src:match(('[^\n]*\n'):rep(row) .. '([^\n]*)') or ''):gsub('^%s+', '')
        undecided[#undecided + 1] = { line = row and row + 1, text = line or (a.cst_print(pos.node):match('^[^\n]*')) }
        return false
    end
    for _, rule in ipairs(rules) do
        local hits, covered = {}, {}
        local function inside(path)
            for _, c in ipairs(covered) do
                if #c <= #path then
                    local pre = true
                    for i = 1, #c do if c[i] ~= path[i] then pre = false; break end end
                    if pre then return true end
                end
            end
            return false
        end
        -- (the rule's template is STATIC across every position: match COMPILED to it, accepted by its sample law
        -- first — cartograph.compiledverb, CART-1339; refused or disabled, the interpreted A.match)
        -- (only `ok` and a hit's `values` are read here: refusals without details, -31% matching — CART-1465)
        local compiled = require('cartograph.compiledverb').match(rule.lhs, { refusal = 'none' })
        -- (and only at the positions that CAN be a match root: an anchor token's ancestor at its fixed depth —
        -- cartograph.prefilter, sound; no anchor, or CARTOGRAPH_PREFILTER=0, every position)
        local poss = os.getenv('CARTOGRAPH_PREFILTER') ~= '0' and require('cartograph.prefilter').candidates(t, rule.lhs, src) or a.positions(t)
        -- (SPACING-INDEPENDENT, CART-1664: a position is matched on STRUCTURE — the token script edits the target's
        -- own text, parsed back before it is taken -> its re-read term | nil, why)
        local function ws_try(pos, exact)
            local orig = {}
            local sn = strip(a, pos.node, orig)
            local m = a.match(rule.lhs_ws, sn)
            if not m.ok then return nil end
            if not exact and not admitted(rule, m.values, pos) then return nil end
            local function reread(text)
                local mark = a.lit(text)
                local t2 = require('cartograph.algebraread').read(a.cst_print(a.put(t, pos.path, mark)), lang or 'lua') -- @langs-ok as learn
                if not t2 then return nil, 'the rewritten file does not read', 'frontier' end
                local ok_, n2 = pcall(get, t2, pos.path)
                if not ok_ or not n2 then return nil, 'the rewritten file has no node where the site was', 'frontier' end
                if a.cst_print(n2) ~= text then return nil, 'the rewritten text does not read as one node where the site was', 'frontier' end
                if not a.eq(a.put(t2, pos.path, mark), a.put(t, pos.path, mark)) then return nil, 'the rest of the file reads differently around the rewritten text', 'frontier' end
                return n2
            end
            local newtext, stmt_or_why = ws_edit(a, rule, pos.node, sn, m.values, orig, reread)
            if newtext then return stmt_or_why end
            return nil, stmt_or_why, 'frontier'
        end
        local ws_hits = {}
        for _, pos in ipairs(poss) do
            if not inside(pos.path) then
                local m = compiled and compiled(pos.node) or a.match(rule.lhs, pos.node)
                if m.ok and admitted(rule, m.values, pos) then
                    -- (an EXACT match takes the token script too when it can: instantiating moves a carried body
                    -- with the indentation and the trailing whitespace of its OLD depth — php's `}` landed indented
                    -- under the loop it closed. Refused there, the instantiation stands: the example spelled it.)
                    local stmt = rule.lhs_ws and ws_try(pos, true)
                    if stmt then ws_hits[#ws_hits + 1] = { path = pos.path, term = stmt }
                    else hits[#hits + 1] = { path = pos.path, values = m.values } end
                    covered[#covered + 1] = pos.path
                elseif m.ok then
                    covered[#covered + 1] = pos.path -- (undecided: not matched again on structure below)
                end
            end
        end
        -- (a position the exact match missed)
        if rule.lhs_ws then
            local rootk = (rule.lhs_ws.body or rule.lhs_ws).k
            for _, pos in ipairs(a.positions(t)) do
                if pos.node.k == rootk and not inside(pos.path) then
                    local stmt, why2 = ws_try(pos)
                    if stmt then ws_hits[#ws_hits + 1] = { path = pos.path, term = stmt }; covered[#covered + 1] = pos.path
                    elseif why2 then refused[#refused + 1] = { why = why2, text = (a.cst_print(pos.node):match('^[^\n]*')) } end
                end
            end
        end
        -- disjoint subtrees: replacing one never moves another's path
        for k = #hits, 1, -1 do
            local inst = a.instantiate(rule.rhs, only_holes(rule.rhs, hits[k].values))
            if inst.ok then t = a.put(t, hits[k].path, inst.term); sites = sites + 1 end
        end
        for k = #ws_hits, 1, -1 do t = a.put(t, ws_hits[k].path, ws_hits[k].term); sites = sites + 1 end
        if sites > 0 then pristine = false end
    end
    return a.cst_print(t), sites, refused, undecided
end

--- Apply rules to a source text, to a FIXPOINT: a match nested inside a rewritten site (a loop inside a loop) is skipped
--- by its pass — its path was covered — and taken by the next; the rule never matches its own output (refused at learn),
--- so the passes end. `admit` (optional): rewrite_once's — a declined site is UNDECIDED, left as written.
--- -> new text, sites, refused, undecided | nil, why, class
function M.rewrite(rules, src, lang, admit)
    local total, last, und = 0, {}, {}
    for pass = 1, 8 do
        local out, n, refused, undecided = rewrite_once(rules, src, lang, admit, pass == 1)
        if not out then return out, n, refused end
        total, src, last = total + n, out, refused or {}
        -- (the first pass's undecided sites carry their LINE — the text was still the file's; a later pass sees them
        -- again without it, and adds only a site the rewrites exposed)
        if pass == 1 then und = undecided or {}
        else for i = #und + 1, #(undecided or {}) do und[#und + 1] = undecided[i] end end
        if n == 0 then break end
    end
    return src, total, last, und -- (the refusals and undecided sites of the LAST pass: the sites still left as written)
end

local function files_in(store, scope, lang)
    local out = {}
    if scope == 'all' then
        -- the files OF THE RULE'S LANGUAGE, by the graph's own path -> parser rule (not an extension typed here)
        local ts = require 'cartograph.providers.treesitter'
        lang = lang or 'lua' -- @langs-ok the reader's audited roster decides (the declaration in algebraread's header)
        for _, f in ipairs(store.files or {}) do if ts.parse_lang(f) == lang then out[#out + 1] = f end end
    else
        for f in tostring(scope):gmatch('[^,]+') do out[#out + 1] = (f:gsub('^%s+', ''):gsub('%s+$', '')) end
    end
    table.sort(out)
    return out
end

--- A txn plan applying the example's rules: { before, after, scope = 'all' | 'a.lua,b.lua' }.
--- Without a scope it refuses as a DECISION that says where the rule matches.
function M.plan(store, opts)
    opts = opts or {}
    local txn = require 'cartograph.txn'
    local rules, why, class = M.learn(opts.before or '', opts.after or '', opts.lang)
    if not rules then return nil, why, class or 'ill-posed' end
    local root = store.data.root
    -- (what the sample says about each rule: a rule that CHANGES behaviour is applied only on `changes = 'accept'`)
    local behaviour, changing = {}, {}
    for _, r in ipairs(rules) do
        behaviour[#behaviour + 1] = M.behaviour_text(r)
        if r.sample and r.sample.verdict == 'differs' then changing[#changing + 1] = M.behaviour_text(r) end
    end
    local function changes_stop()
        if #changing == 0 or opts.changes == 'accept' then return nil end
        return table.concat(changing, '; ') .. ' — applying it is YOUR decision: changes = \'accept\' (or show an example that keeps behaviour)'
    end
    -- ★ PER SITE (CART-1668): with the change not accepted, a site is still taken when its operands are SHOWN never to
    -- take a value the rule treats differently — narrow's guard facts at the site, a constant's own type
    -- (M.site_keeps); every other site is UNDECIDED, left as written and listed. `drow`, `dcol`: where `text`'s
    -- rewritten slice starts in the file (the `within` path rewrites a function's slice).
    local discharged = 0
    local function mk_admit(rel, text, drow, dcol)
        if #changing == 0 or opts.changes == 'accept' then return nil end
        local N = require 'cartograph.narrow'
        return function (site)
            if not site.rule.sample or site.rule.sample.verdict ~= 'differs' then return true end
            local row, col = site.where()
            local facts
            if row then
                if row == 0 then col = col + (dcol or 0) end
                facts = N.facts_at(store, rel, text, row + (drow or 0), col)
            end
            local keep = M.site_keeps(site.rule, site.values, facts)
            if keep then discharged = discharged + 1 end
            return keep
        end
    end
    local preserves_why = 'the rewrite applies what ONE example demonstrated; nothing checks that it preserves behaviour'
    if #behaviour > 0 then preserves_why = 'the rewrite applies what ONE example demonstrated: ' .. table.concat(behaviour, '; ') end
    -- ★ WITHIN ONE FUNCTION (CART-1176, edit-in): `within` = a durable ref (or a node id). The rule rewrites only that
    -- node's own source slice — read as a chunk, or as `return <expr>` when it is an expression (a function value in a
    -- table) — and the slice is spliced back; nothing outside the function can match. Terms carry no spans, so the
    -- scope is the TEXT the graph's range names, not a position filter.
    if opts.within ~= nil then
        local id = type(opts.within) == 'table' and store.resolve_ref(opts.within) or opts.within
        local n = id and store.node(id)
        if not n then return nil, ('the function to edit within does not resolve (%s)'):format(vim.inspect(opts.within)), 'stale' end
        local atr = require 'cartograph.at'
        local text = txn.read_file(root, n.file)
        if not text then return nil, ('cannot read %s'):format(n.file), 'stale' end
        local lines = vim.split(text, '\n', { plain = true })
        local sl, sc, el, ec = atr.sl(n.range), atr.sc(n.range), atr.el(n.range), atr.ec(n.range)
        local function offset(l, c) local o = 0; for i = 1, l do o = o + #lines[i] + 1 end; return o + c end
        local s0, e0 = offset(sl, sc), offset(el, ec)
        local slice = text:sub(s0 + 1, e0)
        local new, n_sites, _, und = M.rewrite(rules, slice, opts.lang, mk_admit(n.file, text, sl, sc))
        local wrapped = false
        if not new then
            new, n_sites, _, und = M.rewrite(rules, 'return ' .. slice, opts.lang, mk_admit(n.file, text, sl, sc - #'return '))
            if new then new, wrapped = new:gsub('^return ', '', 1), true end
        end
        und = und or {}
        local rule_text = {}
        for _, r in ipairs(rules) do rule_text[#rule_text + 1] = ('`%s` -> `%s`'):format(r.lhs_text, r.rhs_text) end
        if not new then return nil, ('%s does not read losslessly on its own: %s'):format(tostring(n.name), tostring(n_sites)), 'frontier' end
        if n_sites == 0 and #und > 0 then
            return nil, ('%s; no site inside %s is shown to avoid it (%d undecided)'):format(changes_stop(), tostring(n.name), #und), 'decision'
        end
        if n_sites == 0 then
            return nil, ('the rule %s matches nothing inside %s'):format(table.concat(rule_text, ', '), tostring(n.name)), 'empty'
        end
        local plan = {
            verb = 'rewrite-by-example', guards = { 'parses' }, generation = store.generation,
            touched = { n.file }, stamps = { [n.file] = txn.disk_stamp(root, n.file) },
            refspecs = { { id = n.id, name = n.name, ref = store.ref_of(n.id), what = 'symbol' } },
            edits = { [n.file] = text:sub(1, s0) .. new .. text:sub(e0 + 1) }, rules = rule_text, sites = n_sites,
            within = n.name, wrapped = wrapped or nil,
            preserves = 'none', preserves_why = preserves_why, behaviour = behaviour, discharged = discharged,
            hazards = #und > 0 and { require('cartograph.hazard').new('sites-undecided', ('%d site(s) left as written: no evidence there rules out the values the rule treats differently — changes = \'accept\' rewrites them too'):format(#und),
                nil, { undecided = und }, 'informational') } or {},
            desc = ('rewrite by example within %s: %s, %d site(s)'):format(tostring(n.name), table.concat(rule_text, ', '), n_sites),
        }
        return txn.protocol(plan, function (p) return function (rel, before) return p.edits[rel] or before end end)
    end
    local scan = files_in(store, opts.scope or 'all', opts.lang)
    local edits, touched, stamps, per, total, unread = {}, {}, {}, {}, 0, {}
    local undecided, nfiles = {}, 0 -- (sites of a behaviour-changing rule nothing showed safe, by file: CART-1668)
    local refusals = {} -- (spacing-independent sites matched and refused, by file: a comment beside a deleted token, a
    -- result that does not read as the right side)
    -- ★ THE PREFILTER (cartograph.prefilter): a file whose text lacks a fixed token of EVERY rule cannot hold a match —
    -- a sound necessary condition, so it is skipped before it is parsed (CARTOGRAPH_PREFILTER=0 turns it off)
    local filters = {}
    if os.getenv('CARTOGRAPH_PREFILTER') ~= '0' then
        for i, r in ipairs(rules) do filters[i] = require('cartograph.prefilter').text(r.lhs) end
    end
    local function may_match(text)
        if #filters == 0 then return true end
        for _, f in ipairs(filters) do if f(text) then return true end end
        return false
    end
    local prefiltered = 0
    for _, rel in ipairs(scan) do
        local text = txn.read_file(root, rel)
        if text and not may_match(text) then prefiltered = prefiltered + 1; text = nil end
        if text then
            local new, n, refused, und = M.rewrite(rules, text, opts.lang, mk_admit(rel, text))
            for _, r in ipairs(new and refused or {}) do refusals[#refusals + 1] = ('%s: `%s` — %s'):format(rel, r.text, r.why) end
            for _, u in ipairs(new and und or {}) do undecided[#undecided + 1] = ('%s%s: `%s`'):format(rel, u.line and (':' .. u.line) or '', u.text) end
            -- a file the lossless reader cannot read was NOT looked at: say so, never count it as "no match"
            if not new then unread[#unread + 1] = rel end
            local matched = new and n + #(und or {}) or 0
            if matched > 0 then per[#per + 1] = ('%s (%d)'):format(rel, matched); nfiles = nfiles + 1 end
            if new and n > 0 then
                edits[rel] = new; touched[#touched + 1] = rel
                stamps[rel] = txn.disk_stamp(root, rel)
                total = total + n
            end
        end
    end
    local rule_text = {}
    for _, r in ipairs(rules) do rule_text[#rule_text + 1] = ('`%s` -> `%s`'):format(r.lhs_text, r.rhs_text) end
    if total + #undecided == 0 then
        return nil, ('the rule %s matches nothing in %d file(s)%s'):format(table.concat(rule_text, ', '), #scan,
            #refusals > 0 and (' (%d site(s) refused: %s)'):format(#refusals, table.concat(refusals, '; ', 1, math.min(#refusals, 4))) or ''), 'empty'
    end
    if not opts.scope then
        return nil, ('the rule %s matches %d site(s) in %d file(s): %s — where it applies is YOUR decision: scope = \'all\', or a comma list of files')
            :format(table.concat(rule_text, ', '), total + #undecided, nfiles, table.concat(per, ', ', 1, math.min(#per, 8))
                .. (#per > 8 and (', and %d more file(s)'):format(#per - 8) or '')), 'decision'
    end
    if total == 0 then
        return nil, ('%s; no site is shown to avoid it (%d undecided: %s)'):format(changes_stop(), #undecided,
            table.concat(undecided, '; ', 1, math.min(#undecided, 4))), 'decision'
    end
    local plan = {
        verb = 'rewrite-by-example',
        guards = { 'parses' },
        generation = store.generation,
        touched = touched, stamps = stamps, refspecs = {},
        edits = edits, rules = rule_text, sites = total, prefiltered = prefiltered,
        -- an example is a claim, not a proof: the rule applies what was demonstrated
        preserves = 'none', preserves_why = preserves_why, behaviour = behaviour, discharged = discharged,
        hazards = (function ()
            local hz = {}
            if #undecided > 0 then hz[#hz + 1] = require('cartograph.hazard').new('sites-undecided', ('%d site(s) left as written: no evidence there rules out the values the rule treats differently — changes = \'accept\' rewrites them too: %s')
                :format(#undecided, table.concat(undecided, '; ', 1, math.min(#undecided, 6))), nil, { undecided = undecided }, 'informational') end
            if #unread > 0 then hz[#hz + 1] = require('cartograph.hazard').new('unread', ('%d file(s) in scope were not read by the lossless reader, so they were not looked at: %s')
                :format(#unread, table.concat(unread, ', ', 1, math.min(#unread, 6))), nil, { files = unread }, 'frontier') end
            if #refusals > 0 then hz[#hz + 1] = require('cartograph.hazard').new('sites-refused', ('%d matched site(s) left as written: %s')
                :format(#refusals, table.concat(refusals, '; ', 1, math.min(#refusals, 6))), nil, { refused = refusals }, 'informational') end
            return hz
        end)(),
        desc = ('rewrite by example: %s, %d site(s) in %d file(s)'):format(table.concat(rule_text, ', '), total, #touched),
    }
    return txn.protocol(plan, function (p) return function (rel, before) return p.edits[rel] or before end end)
end

return M
