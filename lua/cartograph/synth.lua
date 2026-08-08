-- SYNTHESIZE AN INPUT FROM HOW THE BODY USES IT (CART-0290, user: "I think there should
-- be very few functions we cannot run with filled holes").
--
-- THE MISTAKE THIS CORRECTS. `holes.blocking` treats an input hole as an unconditional
-- wall, commented "we cannot choose the value". We can ALWAYS choose a value. That comment
-- encodes "we do not know the RIGHT value" — a claim about GENERALITY wearing the costume
-- of a claim about RUNNABILITY. CART-0282 settled the distinction already, for asserted
-- conditions: `n = 11` is a real value, so what an assertion weakens is generality, not the
-- measurement. It was never applied to the input hole itself.
--
-- MEASURED on this repo before building anything: 1494 functions (43%) are blocked ONLY by
-- input holes, and of the 4411 blocking input params, 46.9% are UNCONSTRAINED — never
-- indexed, called, added or concatenated, so literally any value runs — while 53.1% carry a
-- shape the BODY ITSELF pins (30.6% table, 10.1% method receiver, 4.1% string-or-number,
-- 2.3% number, 1.4% function). Every one of them has a runnable fill.
--
-- ── WHAT A SYNTHESIZED INPUT IS, AND WHAT IT IS NOT ─────────────────────────
-- It is OUR value. So the tier is ours: `derived` when the shape comes from body usage,
-- and that is the ceiling — never `measured`, which belongs to a value the code itself
-- demonstrated. The channel is `by='synthesized'`, separate from the tier, because
-- "we chose this" and "how strong is it" are different facts (arc invariant 3).
--
-- AND A MINIMAL VALUE PICKS A PATH. `{}` for a parameter the body loops over characterizes
-- the EMPTY case: a real behaviour, and the shallowest one. So a spec built this way must
-- SAY that its input was chosen by us, and "we ran it" must never be rendered as "we
-- characterized what it does". This is why synthesis is an EXPLICIT verb and why the census
-- counts it as its OWN number instead of folding it into `emittable` — diluting real
-- evidence with our own guesses, on the largest hole population in the corpus, is the one
-- thing the arc exists to prevent.
--
-- Use headless ([[cartograph-apply-for-agent]]):
--   local synth = require 'cartograph.synth'
--   local shape = synth.shape_of(store, fn_id, 'items')   -- what the body requires
--   local src   = synth.value(shape)                      -- '{ }' / '0' / '""' / …
--   local n     = synth.fill(store, plan)                 -- fill every unfilled input

local M = {}
local expr = require 'cartograph.expr'

-- STRING METHODS, so a `p:match(…)` receiver can be told from a table's. The ambiguity is
-- real — `:m()` needs only "something with an `m`" — and this is the one place a NAME
-- decides it. A name not on this list means a table carrying a function field, which is
-- the safer reading: it cannot accidentally satisfy a string operation later.
M.STRING_METHODS = {}
for w in ('byte char find format gmatch gsub len lower match rep reverse sub upper')
    :gmatch('%S+') do
    M.STRING_METHODS[w] = true
end

-- The shapes, ordered by how much they constrain. A CONFLICT is not an error here: the body
-- using one parameter as both a number and a table is either a real defect or our
-- misreading, and either way it is reported rather than resolved by picking a winner.
M.KINDS = { any = 0, ['function'] = 1, number = 2, string = 3, table = 4, conflict = 9 }

-- The `type()` results that name a shape we can BUILD A VALUE FOR (CART-0328).
-- `boolean`, `nil`, `userdata` and `thread` are real answers with no kind in M.KINDS,
-- and they are left alone rather than approximated: an unrepresentable constraint must
-- not quietly become a nearby representable one. Keyed by the string the guard compares
-- against, so this is also the closed list of guards that constrain anything.
M.TYPE_GUARD = { table = 'table', string = 'string', number = 'number',
    ['function'] = 'function' }

local function merge(a, b)
    if not a or a == 'any' then return b end
    if not b or b == 'any' then return a end
    if a == b then return a end
    -- string vs table is the `:method()` ambiguity resolving the other way; prefer the
    -- more specific evidence rather than declaring a conflict
    if (a == 'string' and b == 'table') or (a == 'table' and b == 'string') then
        return 'table'
    end
    return 'conflict'
end

-- ── SHAPES ARE PER ACCESS PATH, NOT PER PARAMETER (CART-0297) ───────────────
-- The first version matched a bare NAME node, so it derived a shape for `p` and merely
-- CREATED empty ones for `p.foo` — `sh.fields[n] = M.new()` and then nothing. `M.value` filled
-- those with the opaque string `"<synth:foo>"`, and a body doing `ipairs(p.items)` raised.
--
-- MEASURED: that single gap is 169 of 196 `bad argument to a builtin` raises (143 ipairs, 26
-- pairs) — the largest failure category in the whole verified run, and it was never about the
-- PARAMETER's type. The field names already came free with the access; this is their TYPES.
--
-- So the operand test becomes a PATH test: every rule below applies to whatever path it is
-- applied to, one level down as readily as at the root. `p`, `p.items`, `p.items.name`.

-- How deep a path is followed. A synthesized value nested deeper than this is more scaffolding
-- than input, and the bound is stated rather than discovered by a stack overflow.
M.MAX_PATH = 4

--- The access path `e` denotes, if it is rooted at `p`. Returns a list of field names ({} for
--- the root itself) or nil. An INDEX (`p[k]`) ends the path: it says its base is a table, but
--- the key is not a name we can synthesize a field for.
local function path_of(e, p)
    if not e then return nil end
    if e.k == 'name' then return e.n == p and {} or nil end
    if e.k == 'field' and not e.method then
        local base = path_of(e.b, p)
        if not base or #base >= M.MAX_PATH then return nil end
        local out = {}
        for i, x in ipairs(base) do out[i] = x end
        out[#out + 1] = e.n
        return out
    end
    return nil
end

--- The sub-shape at `path`, created on the way down. Every intermediate step is a table by
--- construction — you cannot read `a.b.c` unless `a.b` is indexable — so that is recorded
--- rather than inferred later.
local function shape_at(sh, path)
    local cur = sh
    for _, k in ipairs(path or {}) do
        cur.kind = merge(cur.kind, 'table')
        cur.fields[k] = cur.fields[k] or M.new()
        cur = cur.fields[k]
    end
    return cur
end

local function pname(p, path)
    return p .. (#(path or {}) > 0 and ('.' .. table.concat(path, '.')) or '')
end

--- What one expression tree requires of `p` AND OF EVERY PATH UNDER IT. Accumulates into `sh`:
---   sh.kind    any | function | number | string | table | conflict
---   sh.fields  name -> sub-shape (the names come free with the access, the types from here)
---   sh.methods name -> true, for `p:m()`
---   sh.why     the usages that decided it, so a reader can disagree with us
---   sh.inspected  the body TESTS this path (compares or type-tests it) even where no
---                 shape follows — the check that lets M.basis claim non-inspection
local function usage(e, p, sh, depth)
    if depth > 6 then return end
    expr.walk(e, function (n)
        -- DEDUPED, which is what lets the CONDITION be walked on its own (CART-0326).
        -- A control head carries its condition in `cond` AND in `rhs`, so reading both
        -- visits the same expression twice; without this the basis line would read
        -- "(p.x, p.x, p.y, p.y)". Collapsing identical usages loses nothing a reader
        -- wanted — `p.x` three times says no more than `p.x` — and it makes the walk
        -- IDEMPOTENT, so no future caller has to know which rows overlap.
        local function note(w)
            sh.seen = sh.seen or {}
            if sh.seen[w] then return end
            sh.seen[w] = true
            sh.why[#sh.why + 1] = w
        end
        -- CONSTRAIN the shape at whatever path the operand denotes
        local function put(operand, kind, fmt)
            local path = path_of(operand, p)
            if not path then return false end
            local at_ = shape_at(sh, path)
            at_.kind = merge(at_.kind, kind)
            note(fmt:format(pname(p, path)))
            return true
        end
        if n.k == 'field' then
            local base = path_of(n.b, p)
            if base then
                local at_ = shape_at(sh, base)
                if n.method then
                    at_.methods[n.n] = true
                    at_.kind = merge(at_.kind,
                        M.STRING_METHODS[n.n] and 'string' or 'table')
                    note(('%s:%s()'):format(pname(p, base), n.n))
                else
                    at_.kind = merge(at_.kind, 'table')
                    at_.fields[n.n] = at_.fields[n.n] or M.new()
                    note(('%s.%s'):format(pname(p, base), n.n))
                end
            end
        elseif n.k == 'index' then
            put(n.b, 'table', '%s[k]')
        elseif n.k == 'call' and n.f and path_of(n.f, p) then
            put(n.f, 'function', '%s()')
        elseif n.k == 'un' and n.op == '#' then
            -- `#p` on a real table answers correctly, unlike on a sandbox sentinel where
            -- __len never fires (5.1) — so synthesis is strictly SAFER here than a proxy.
            put(n.e, 'table', '#%s')
        elseif n.k == 'un' and n.op == '-' then
            put(n.e, 'number', '-%s')
        elseif n.k == 'bin' then
            local op = n.op or ''
            -- NEVER INTERPOLATE SOURCE TEXT INTO A FORMAT STRING. `op` can be `%`, which
            -- makes `'%s ' .. op .. ' x'` read `% ` as a conversion spec and crashes
            -- `format` mid-sweep. The operator is data, and data gets escaped.
            local ops = op:gsub('%%', '%%%%')
            local kind, fmt
            if op == '+' or op == '-' or op == '*' or op == '/' or op == '%'
                or op == '^' or op == '//' then
                kind, fmt = 'number', '%s ' .. ops .. ' x'
            elseif op == '..' then
                kind, fmt = 'string', '%s .. x'
            elseif op == '<' or op == '>' or op == '<=' or op == '>=' then
                -- ORDER COMPARISON, and in 5.1 a mixed-type compare RAISES rather than
                -- returning false, so guessing wrong here aborts the run instead of taking
                -- a branch. `number` is the reading that keeps the run alive.
                kind, fmt = 'number', '%s ' .. ops .. ' x'
            end
            if kind then
                if not put(n.l, kind, fmt) then put(n.r, kind, fmt) end
            end
        end
        -- ITERATION, the case that motivated all of this: `ipairs(p.items)` must make
        -- `items` a table, not the opaque string a field with no derived shape gets.
        if n.k == 'call' and n.f and n.f.k == 'name'
            and (n.f.n == 'ipairs' or n.f.n == 'pairs' or n.f.n == 'next'
                or n.f.n == 'unpack') then
            for _, a in ipairs(n.a or {}) do
                put(a, 'table', n.f.n .. '(%s)')
            end
        end
        -- ── THE BODY TESTS THE VALUE (CART-0328) ────────────────────────────
        -- `type(p) == 'table'` names the type outright, and in a body that never
        -- indexes or calls `p` it is the ONLY evidence there is — which is exactly
        -- where this walker used to return `any` and `M.basis` went on to claim
        -- nothing in the body inspects it. Measured: 70 of the 1092 sentinel fills
        -- carry a test like this.
        --
        -- ★ ONLY `==`. `type(p) ~= 'function'` is EXCLUSION — it says what `p` is NOT.
        -- The reading that makes it a function (the guard is an early exit, so the
        -- rest of the body runs only when it IS one) needs GUARD DOMINANCE, which
        -- narrow.lua computes and this walker cannot see. Filling from an exclusion
        -- would be a guess wearing evidence's clothes, and this module's whole point
        -- is that the two are different.
        if n.k == 'bin' and n.op == '==' then
            local function typearg(x)
                if x and x.k == 'call' and x.f and x.f.k == 'name' and x.f.n == 'type' then
                    return x.a and x.a[1] or nil
                end
            end
            local ta, lit = typearg(n.l), n.r
            if not ta then ta, lit = typearg(n.r), n.l end
            -- READ THE LITERAL THROUGH `expr.eval`, NOT `lit.v`. A str literal's `v` is
            -- the RAW SOURCE TEXT INCLUDING ITS QUOTES ("raw text incl. quotes; eval
            -- strips", expr.lua) — so `M.TYPE_GUARD[lit.v]` looks up `'table'` WITH the
            -- quote characters and never matches. Measured: the rule silently did
            -- nothing on all three equality guards before this. eval is the one place
            -- that decides what a literal MEANS, and a second spelling of it here would
            -- be a disagreement waiting to be found by whoever trusts the wrong one.
            local kind
            if ta and lit then
                local known, val = expr.eval(lit)
                if known and type(val) == 'string' then kind = M.TYPE_GUARD[val] end
            end
            if kind then put(ta, kind, 'type(%s) == ' .. kind) end
        end
        -- AND EVEN WHEN THE TEST CONSTRAINS NOTHING WE MUST NOT SAY IT DOES NOT
        -- EXIST. `p == 'param'` pins no shape and `type(p) ~= 'function'` is refused
        -- above, but both mean the body INSPECTS `p` and the arbitrary value we pick
        -- decides which path runs. Recorded on the shape AT THE TESTED PATH, so a
        -- test of `p.x` never speaks for `p`.
        local function mark(operand)
            local path = path_of(operand, p)
            if path then shape_at(sh, path).inspected = true end
        end
        if n.k == 'bin' and (n.op == '==' or n.op == '~=' or n.op == '!=') then
            mark(n.l); mark(n.r)
        end
        if n.k == 'call' and n.f and n.f.k == 'name' and n.f.n == 'type' then
            for _, a in ipairs(n.a or {}) do mark(a) end
        end
    end)
end

--- An empty shape.
function M.new()
    return { kind = 'any', fields = {}, methods = {}, why = {} }
end

--- WHAT THE BODY REQUIRES OF ONE PARAMETER. Returns a shape (never nil — `any` is a real
--- answer meaning "nothing in the body inspects it", which is the 47% case and the easiest
--- one to fill). `rows` is the expression rows; pass them in so a caller sweeping a corpus
--- materializes them once.
---
--- A ROW IS NOT A NODE. `s.expr` is `{ lhs = {…}, rhs = {…}, cond = … }`, so walking the
--- row visits one node and stops — the blind spot that made the first measurement of this
--- report 100% unconstrained, and the same one already recorded against the length check.
--- Walk the LISTS.
---
--- ── AND THE CONDITION, EXPLICITLY (CART-0326) ───────────────────────────────
--- This used to read {lhs, rhs} only, which says every `if type(p) == 'table'` should be
--- invisible here. MEASURED over 2466 input holes and 3209 cond-carrying rows: zero
--- difference — because expr.harvest_row's `ctrlhead` branch puts EVERY non-body,
--- non-clause child into `rhs`, the condition among them. So the condition arrived by a
--- SECOND ROAD and this walker's coverage of conditions was entirely INCIDENTAL.
---
--- That is a coupling nothing tested and the duplication LOOKS redundant: `cond` is right
--- there, and `rhs` repeating it reads like a bug. Tidying it away would have cost
--- synthesis every condition in every corpus, silently — no gate covers it, and the
--- census number would have moved with no attributable cause. Reading `cond` here makes
--- the coverage intentional, and picks up the rows where it is the ONLY copy (`hint='cond'`
--- post-loop re-emit and `casehead`, which carry an EMPTY rhs).
function M.shape_of_rows(rows, p)
    local sh = M.new()
    for _, s in ipairs(rows or {}) do
        if s.expr and s.expr.cond then usage(s.expr.cond, p, sh, 0) end
        for _, side in ipairs({ 'lhs', 'rhs' }) do
            for _, e in ipairs(s.expr and s.expr[side] or {}) do
                usage(e, p, sh, 0)
            end
        end
    end
    return sh
end

--- The same, from a function id.
function M.shape_of(store, fn_id, p)
    local eo = expr.of(store, fn_id)
    local fl = eo and eo.fl
    if not fl then return nil, 'no expression rows' end
    return M.shape_of_rows(fl.stmts, p)
end

--- A shape as Lua SOURCE. Returns (src, nil) or (nil, why) — a CONFLICT is refused rather
--- than resolved, because picking one side would run the function under a premise we have
--- evidence against.
---
--- THE `any` VALUE IS ARBITRARY AND SAYS SO. Nothing in the body inspects it, so no choice
--- is more correct than another; a distinctive STRING is used because it is serializable
--- (a metatable-carrying sentinel would make the recorded RETURN unserializable when the
--- subject passes its argument through) and because it is RECOGNISABLE in the recorded
--- value — an empty table could be mistaken for a real one the caller meant.
function M.value(sh, name)
    if not sh then return nil, 'no shape' end
    if sh.kind == 'conflict' then
        return nil, ('the body uses `%s` as more than one type (%s) — synthesizing either'
            .. ' would run it under a premise the code contradicts')
            :format(tostring(name), table.concat(sh.why, ', ', 1,
                math.min(4, #sh.why)))
    end
    if sh.kind == 'number' then return '0' end
    if sh.kind == 'string' then return '""' end
    if sh.kind == 'function' then return 'function () end' end
    if sh.kind == 'table' then
        local keys = {}
        for k in pairs(sh.fields) do keys[#keys + 1] = k end
        for k in pairs(sh.methods) do
            if not sh.fields[k] then keys[#keys + 1] = k end
        end
        table.sort(keys)
        if #keys == 0 then return '{ }' end
        local parts = {}
        for _, k in ipairs(keys) do
            local v
            if sh.methods[k] then v = 'function () end'
            else
                local sub = sh.fields[k]
                -- A REFUSAL PROPAGATES. `or <opaque string>` would turn a CONFLICTED field
                -- into a plausible value — the body says this field is two types and we would
                -- answer with a string. Refusing the whole value is the honest response, and
                -- it is the same rule the top level already follows.
                if sub and sub.kind == 'conflict' then
                    return nil, ('the field `%s` is used as more than one type (%s)')
                        :format(k, table.concat(sub.why, ', ', 1,
                            math.min(3, #sub.why)))
                end
                v = (sub and M.value(sub, k)) or ('%q'):format('<synth:' .. k .. '>')
            end
            -- a field name that is a keyword needs bracket form, the bug CART-0289 found
            -- in the serializer; do not re-earn it here
            if k:match('^[%a_][%w_]*$') and not M.RESERVED[k] then
                parts[#parts + 1] = ('%s = %s'):format(k, v)
            else
                parts[#parts + 1] = ('[%q] = %s'):format(k, v)
            end
        end
        return '{ ' .. table.concat(parts, ', ') .. ' }'
    end
    return ('%q'):format('<synth:' .. tostring(name or '?') .. '>')
end

M.RESERVED = require('cartograph.runoracle').RESERVED

--- The BASIS line for a synthesized fill: what we chose and what the code said. This is the
--- sentence a reader uses to disagree with us, so it names the usages rather than asserting
--- a type.
---
--- ★ AND IT MAY ONLY CLAIM WHAT `usage` CHECKED (CART-0328). This used to open "nothing
--- in the body inspects `p`" for EVERY `any` shape — a statement about the whole body,
--- from a walker that only ever looked for SHAPE requirements. Measured: false for 70 of
--- the 1092 sentinel fills, where the body compares `p` against a literal or type-tests
--- it. `sh.inspected` is the check behind the claim; without it the sentence is unearned.
function M.basis(sh, name)
    if sh.kind == 'any' and sh.inspected then
        return ('no SHAPE requirement was found for `%s` — nothing indexes, calls or'
            .. ' iterates it — but the body TESTS it, so this arbitrary value decides'
            .. ' WHICH PATH runs and the choice is not free')
            :format(tostring(name))
    end
    if sh.kind == 'any' then
        return ('nothing in the body inspects `%s`, so ANY value runs and this one is'
            .. ' arbitrary — what it characterizes does not depend on the choice')
            :format(tostring(name))
    end
    local w = {}
    for i = 1, math.min(4, #sh.why) do w[i] = (sh.why[i]:gsub('^p', name)) end
    return ('the body requires `%s` to be a %s (%s%s) — a MINIMAL value of that shape,'
        .. ' chosen by us, so it exercises ONE path and the choice is ours not a caller\'s')
        :format(tostring(name), sh.kind, table.concat(w, ', '),
            #sh.why > 4 and (', +' .. (#sh.why - 4) .. ' more') or '')
end

--- FILL EVERY UNFILLED INPUT HOLE of a plan by synthesis. Returns (n_filled, refusals) —
--- refusals is a list of { name, why } and is NOT an error: a conflict is a finding.
--- The tier is `derived` when the body constrained the shape and `claim` when it did not,
--- because "the code told us" and "we picked something harmless" are different strengths
--- and the arc's whole discipline is not to blur them.
function M.fill(store, plan)
    local ch = require 'cartograph.characterize'
    local eo = expr.of(store, plan.fn_id)
    local fl = eo and eo.fl
    if not fl then return nil, 'no expression rows' end
    local fills, refusals, n = {}, {}, 0
    for _, h in ipairs(plan.holes) do
        if h.kind == 'input' and not h.value then
            local sh = M.shape_of_rows(fl.stmts, h.name)
            local src, why = M.value(sh, h.name)
            if src then
                n = n + 1
                fills[h.id] = { value = src, basis = M.basis(sh, h.name),
                    by = 'synthesized',
                    tier = sh.kind == 'any' and 'claim' or 'derived' }
            else
                refusals[#refusals + 1] = { name = h.name, why = why }
            end
        end
    end
    if n > 0 then
        local okf, ferr = ch.fill(plan, fills)
        if not okf then return nil, ferr end
    end
    plan.synthesized = n > 0 and n or nil
    return n, refusals
end

--- Report rows for one function's synthesis: what we would supply, and on what evidence.
function M.report(store, fn_id, plan)
    local ch = require 'cartograph.characterize'
    plan = plan or ch.plan(store, fn_id)
    if not plan then return { 'no plan for this function' }, {} end
    local L, A = {}, {}
    local function add(s, a) L[#L + 1] = s; A[#A + 1] = a end
    add(('synthesized inputs — %s (%s)'):format(plan.fn, plan.file), { file = plan.file })
    add('  a synthesized input is OURS: `derived` when the body pins the shape, `claim`', nil)
    add('  when nothing inspects it. It exercises ONE path, and the path is our choice.', nil)
    add('', nil)
    local eo = expr.of(store, plan.fn_id)
    local fl = eo and eo.fl
    local any = false
    for _, h in ipairs(plan.holes) do
        if h.kind == 'input' then
            any = true
            if h.value and h.by ~= 'synthesized' then
                add(('  %-14s %s  [%s, by %s]'):format(h.name, h.value,
                    h.filled_tier or '?', h.by or '?'), nil)
            else
                local sh = fl and M.shape_of_rows(fl.stmts, h.name) or nil
                local src, why = M.value(sh, h.name)
                if src then
                    add(('  %-14s %s'):format(h.name, src), nil)
                    add(('                 %s'):format(M.basis(sh, h.name)), nil)
                else
                    add(('  %-14s REFUSED — %s'):format(h.name, tostring(why)), nil)
                end
            end
        end
    end
    if not any then add('  this function takes no parameters', nil) end
    return L, A
end

return M
