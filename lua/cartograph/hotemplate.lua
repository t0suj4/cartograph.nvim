-- hotemplate.lua — THE HIGHER-ORDER TEMPLATE: a hole that knows what it is
-- computed FROM (CART-0698, hoau absorption).
--
-- USER (2026-09-20): "I guess we can absorb it once we finish automation."
--
-- ── WHAT THIS ADDS THAT THE FIRST-ORDER TEMPLATE CANNOT SAY ────────────────
--
-- `clones.analyze_pair` answers WHAT VARIES between two near-clones: one
-- parameter per distinct varying leaf. That is the right answer for a hole that
-- is a VALUE. It is the wrong answer — silently — for a hole that is an
-- EXPRESSION OVER THE FUNCTION'S OWN LOCALS, because such a hole cannot be
-- passed as a value at all: the caller does not have the locals.
--
-- Higher-order pattern anti-unification (`A.hoau`, Baumgartner/Kutsia) answers
-- both at once. Encode each function as a λ-term with its locals as BINDERS
-- (`algebra.ho_fn_term`) and every difference comes back as `Y(x1..xk)` — a
-- hole tagged with exactly the bound variables it depends on:
--
--     k = 0   a CLOSED hole    -> a VALUE parameter of the helper
--     k > 0   a DEPENDENT hole -> a FUNCTION parameter of arity k
--
-- ★★★ THAT PAIR OF NUMBERS IS THE HELPER SIGNATURE, and it is the first thing
-- this codebase has produced that answers "what would the extracted helper
-- LOOK LIKE" rather than "how similar are these two". MEASURED on this tree
-- (43 near pairs at max_dist 3): 21 pairs carry at least one dependent hole —
-- so on HALF of our own near-clones, the first-order reading is not merely
-- coarser, it names a parameter the call site could not supply.
--
-- ── ⚠ IT IS A PRODUCER, AND IT DOES NOT EXTRACT ────────────────────────────
-- Nothing here feeds `cloneextract`. Handing it function parameters is an
-- EXTRACTION-BEHAVIOUR CHANGE (cache VERSION bump, gate re-save, a diff of every
-- generated helper) and it is the next rung, not this one — filed rather than
-- smuggled in. What lands here is: produce the template, give it an identity
-- through `templates.record`, and reproduce the prototype's census against the
-- shipped code (`tools/hocensus.lua`).
--
-- ── THREE THINGS THE RESULT IS CHECKED FOR, AND WHY EACH IS A REFUSAL ───────
--
--  1. IT MUST BE A PATTERN (`A.ho_is_pattern`). A non-pattern lgg has holes
--     applied to non-variables, and those cannot be read as parameters at all —
--     the signature would be a number computed from a shape that does not
--     support it.
--  2. IT MUST REBUILD BOTH SIDES (`ho_apply(result, sigmaL) ≡ left`). This is
--     the algebra's own law — holes-plus-a-valuation IS the instance — and it is
--     the one check that catches an ENCODER bug rather than an algebra bug. An
--     encoding that drops a child still anti-unifies happily; it just no longer
--     describes the functions it came from.
--  3. THE PAD MUST BE COMPUTED OVER BOTH SIDES. `hoau`'s Abs rule pairs binders
--     positionally, so unequal λ-prefixes misalign silently rather than failing.
--
-- ⚠ AND A REFUSAL HERE IS AN ANSWER, NOT A FAILURE — the same distinction
-- `templates.record` draws for a donorless element result. "These two functions
-- have no higher-order template" is a fact about the pair.
--
-- ⚠⚠ THE STORE IS MANDATORY. `expr.of` is what supplies `fl.params` and
-- `fl.stmts`, and without them a side encodes with no binders at all — every
-- hole then reads CLOSED and the signature says "all value parameters", which is
-- a plausible, confident, wrong answer. That failure shape cost a session
-- already (`clones.analyze_pair` without a store returned `no_store` for every
-- non-literal hole and the verdict was right for the wrong reason), so the
-- argument is required rather than defaulted.

local algebra = require 'cartograph.algebra'
local expr = require 'cartograph.expr'

local M = {}

--- Strip the `#N` freshening suffix `A.ho_distinct` adds, so a signature reads
--- in the names the source actually uses.
--- @param name any
--- @return string
function M.strip(name) return (tostring(name):gsub('#%d+$', '')) end

--- A λ-term in source names, for reports. ⚠ NOT `A.ho_show`, which prints de
--- Bruijn indices — right for a canonical key, unreadable as a signature.
function M.show(t)
    if type(t) ~= 'table' then return tostring(t) end
    if t.k == 'lam' then return 'λ' .. M.strip(t.x) .. '.' .. M.show(t.body) end
    local as = {}
    for i, a in ipairs(t.args or {}) do as[i] = M.show(a) end
    local head = t.k == 'fv' and t.name or (t.bv and M.strip(t.bv) or t.h)
    return tostring(head) .. (#as > 0 and ('(' .. table.concat(as, ',') .. ')') or '')
end

--- Classify one store entry from `hoau`.
---
--- ★ `local-vs-term` IS COUNTED AS DEPENDENT, AND THAT IS A JUDGEMENT WORTH
--- STATING. One side is a bare local and the other is an arbitrary term, so the
--- helper cannot take a value: on the local's side it would have to be passed
--- the local, and on the other side an expression. It is the asymmetric case of
--- a dependent hole, not a third kind of value.
local function classify(e)
    local t, s = e.t, e.s
    local tb = t.k == 'app' and t.bv ~= nil and #t.args == 0
    local sb = s.k == 'app' and s.bv ~= nil and #s.args == 0
    if tb and sb then return 'rename' end
    if tb ~= sb then return 'local-vs-term' end
    if #e.ys == 0 then return 'closed' end
    return 'dep'
end

--- The aligned rows of a near pair: cartograph's `sub` and `match` ops, in
--- order. ⚠ INS/DEL ROWS ARE NOT ALIGNED AND ARE DROPPED — their definitions
--- are carried forward by `ho_fn_term`, so the names they bind survive even
--- though the rows do not.
--- @return table kept_a, table kept_b
local function aligned(pair)
    local subs = {}
    for _, o in ipairs(pair.ops or {}) do
        if o.op == 'sub' or o.op == 'match' then subs[#subs + 1] = o end
    end
    table.sort(subs, function (x, y) return x.i < y.i end)
    local ka, kb = {}, {}
    for n, o in ipairs(subs) do ka[n], kb[n] = o.i, o.j end
    return ka, kb
end

--- Recover the HIGHER-ORDER template of a near pair.
--- @param store table   required — see the header
--- @param pair table    a `clones.near` pair
--- @return table|nil ho, string|nil why
function M.of_pair(store, pair)
    if type(store) ~= 'table' then
        return nil, 'a store is required — without expr.of neither side has binders, '
            .. 'and every hole would read as closed'
    end
    if type(pair) ~= 'table' or not (pair.a and pair.b) then
        return nil, 'not a near pair'
    end
    local A, aerr = algebra.load()
    if not A then
        return nil, ('the algebra is unavailable: %s'):format(tostring(aerr or 'no reason'))
    end
    local ka, kb = aligned(pair)
    if #ka == 0 then
        -- ⚠ A REAL STATE, NOT A GUARD AGAINST NONSENSE: two functions can be
        -- near neighbours entirely through insertions and deletions, and then
        -- there is no aligned row to anti-unify. The `row~` marker keeps arity
        -- honest for a MISSING row; it cannot invent an alignment.
        return nil, 'no aligned rows — the pair differs only by insertions and deletions'
    end
    local ok_a, eoa = pcall(expr.of, store, pair.a.id)
    local ok_b, eob = pcall(expr.of, store, pair.b.id)
    if not (ok_a and type(eoa) == 'table' and eoa.fl) then
        return nil, ('no expression view for %s'):format(tostring(pair.a.name))
    end
    if not (ok_b and type(eob) == 'table' and eob.fl) then
        return nil, ('no expression view for %s'):format(tostring(pair.b.name))
    end
    -- ⚠ THE PAD IS COMPUTED OVER BOTH SIDES BEFORE EITHER TERM IS BUILT.
    local da = algebra.ho_def_counts(pair.a, eoa, ka)
    local db = algebra.ho_def_counts(pair.b, eob, kb)
    local pad = { params = math.max(#(eoa.fl.params or {}), #(eob.fl.params or {})), defs = {} }
    for n = 1, #ka do pad.defs[n] = math.max(da[n] or 0, db[n] or 0) end
    local ta = algebra.ho_fn_term(pair.a, eoa, ka, pad)
    local tb = algebra.ho_fn_term(pair.b, eob, kb, pad)
    if not (ta and tb) then return nil, 'the higher-order encoding produced no term' end
    -- ⚠ THE MESSAGE IS THE ALGEBRA'S OWN, NOT A SUMMARY OF IT. `hoau` asserts on
    -- states its transformation set cannot take, and that assertion names the
    -- state; swallowing it would turn a diagnosable input into "it failed".
    local ok, r = pcall(A.hoau, ta, tb, { queue = true })
    if not ok then
        return nil, ('higher-order anti-unification raised: %s'):format(tostring(r))
    end
    if not A.ho_is_pattern(r.result) then
        return nil, 'the result is not a higher-order PATTERN — its holes are applied to '
            .. 'terms rather than to distinct bound variables, so they cannot be read as parameters'
    end
    local rebuilt = A.alpha_eq(A.ho_apply(r.result, r.sigmaL), r.left)
        and A.alpha_eq(A.ho_apply(r.result, r.sigmaR), r.right)
    if not rebuilt then
        -- ★ THE ONE CHECK THAT CATCHES AN ENCODER BUG RATHER THAN AN ALGEBRA ONE.
        return nil, 'the template does not rebuild both sides — that is an answer about '
            .. 'the encoding, not a template'
    end
    -- ⚠ `holes` IS EVERY STORE ENTRY; THE SIGNATURE IS NOT ITS LENGTH. A RENAME
    -- is a difference but not a parameter — the helper takes neither a value nor
    -- a function for it, because the two sides are alpha-equivalent there. So
    -- `#holes` answers "how many differences" and `signature.value + signature.fn`
    -- answers "how many parameters", and they are not the same number. Conflating
    -- them would overstate every helper's arity by the rename count (15 of 95 on
    -- this tree).
    local holes, sig = {}, { value = 0, fn = 0, arities = {} }
    local map_ab, map_ba, renamed, consistent = {}, {}, 0, true
    for _, e in ipairs(r.store) do
        local kind = classify(e)
        local ys = {}
        for i, y in ipairs(e.ys) do ys[i] = M.strip(y) end
        holes[#holes + 1] = { kind = kind, Y = e.Y, ys = ys,
            left = e.t, right = e.s, arity = #e.ys }
        if kind == 'closed' then
            sig.value = sig.value + 1
        elseif kind == 'rename' then
            renamed = renamed + 1
            local xa, xb = M.strip(e.t.bv), M.strip(e.s.bv)
            -- ★ A RENAMING IS ONLY ALPHA-EQUIVALENCE WHEN IT IS A BIJECTION.
            -- Two locals mapping onto one is a genuine difference wearing a
            -- rename's clothes, and it is why this is reported rather than
            -- dropped as "just names".
            if map_ab[xa] and map_ab[xa] ~= xb then consistent = false end
            if map_ba[xb] and map_ba[xb] ~= xa then consistent = false end
            map_ab[xa], map_ba[xb] = xb, xa
        else
            sig.fn = sig.fn + 1
            sig.arities[#sig.arities + 1] = #e.ys
        end
    end
    return {
        subject = {
            a = { id = pair.a.id, name = pair.a.name, file = pair.a.file, line = pair.a.line },
            b = { id = pair.b.id, name = pair.b.name, file = pair.b.file, line = pair.b.line },
        },
        result = r.result,
        holes = holes,
        signature = sig,
        rows = #ka,
        pattern = true,
        rebuild = true,
        -- 'none' when nothing was renamed at all; a pair that renames
        -- INCONSISTENTLY is not alpha-equivalent and the caller must know.
        renaming = renamed == 0 and 'none' or (consistent and 'consistent' or 'inconsistent'),
    }
end

--- The helper signature as one line, in the words CART-0698 asks for.
--- @param ho table a result of `M.of_pair`
--- @return string
function M.signature_text(ho)
    local s = ho.signature
    local ar = {}
    for _, a in ipairs(s.arities) do ar[#ar + 1] = tostring(a) end
    return ('%d value param%s, %d function param%s%s'):format(
        s.value, s.value == 1 and '' or 's',
        s.fn, s.fn == 1 and '' or 's',
        #ar > 0 and (' (arities ' .. table.concat(ar, ',') .. ')') or '')
end

return M
