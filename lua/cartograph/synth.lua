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

--- What one expression tree requires of the name `p`. Accumulates into `sh`:
---   sh.kind    any | function | number | string | table | conflict
---   sh.fields  name -> sub-shape, for a table (the field names come free with the access)
---   sh.methods name -> true, for `p:m()`
---   sh.why     the usages that decided it, so a reader can disagree with us
local function usage(e, p, sh, depth)
    if depth > 6 then return end
    expr.walk(e, function (n)
        local function is(x) return x and x.k == 'name' and x.n == p end
        local function note(w) sh.why[#sh.why + 1] = w end
        if n.k == 'field' and is(n.b) then
            if n.method then
                sh.methods[n.n] = true
                sh.kind = merge(sh.kind,
                    M.STRING_METHODS[n.n] and 'string' or 'table')
                note(('p:%s()'):format(n.n))
            else
                sh.kind = merge(sh.kind, 'table')
                sh.fields[n.n] = sh.fields[n.n] or M.new()
                note(('p.%s'):format(n.n))
            end
        elseif n.k == 'index' and is(n.b) then
            sh.kind = merge(sh.kind, 'table')
            note('p[k]')
        elseif n.k == 'call' and is(n.f) then
            sh.kind = merge(sh.kind, 'function')
            note('p()')
        elseif n.k == 'un' and n.op == '#' and is(n.e) then
            -- `#p` on a real table answers correctly, unlike on a sandbox sentinel where
            -- __len never fires (5.1) — so synthesis is strictly SAFER here than a proxy.
            sh.kind = merge(sh.kind, 'table')
            note('#p')
        elseif n.k == 'un' and n.op == '-' and is(n.e) then
            sh.kind = merge(sh.kind, 'number'); note('-p')
        elseif n.k == 'bin' and (is(n.l) or is(n.r)) then
            local op = n.op or ''
            if op == '+' or op == '-' or op == '*' or op == '/' or op == '%'
                or op == '^' or op == '//' then
                sh.kind = merge(sh.kind, 'number'); note('p ' .. op .. ' x')
            elseif op == '..' then
                sh.kind = merge(sh.kind, 'string'); note('p .. x')
            elseif op == '<' or op == '>' or op == '<=' or op == '>=' then
                -- ORDER COMPARISON, and in 5.1 a mixed-type compare RAISES rather than
                -- returning false, so guessing wrong here aborts the run instead of taking
                -- a branch. `number` is the reading that keeps the run alive.
                sh.kind = merge(sh.kind, 'number'); note('p ' .. op .. ' x')
            end
        elseif n.k == 'call' and n.f and n.f.k == 'name'
            and (n.f.n == 'ipairs' or n.f.n == 'pairs' or n.f.n == 'next'
                or n.f.n == 'unpack') then
            for _, a in ipairs(n.a or {}) do
                if is(a) then sh.kind = merge(sh.kind, 'table')
                    note(n.f.n .. '(p)') end
            end
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
--- A ROW IS NOT A NODE. `s.expr` is `{ lhs = {…}, rhs = {…} }`, so walking the row visits
--- one node and stops — the blind spot that made the first measurement of this report 100%
--- unconstrained, and the same one already recorded against the length check. Walk the LISTS.
function M.shape_of_rows(rows, p)
    local sh = M.new()
    for _, s in ipairs(rows or {}) do
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
function M.basis(sh, name)
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
