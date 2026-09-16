-- elemdrive — DOES THE LGG REPRODUCE `element_template`'s HOLES? (CART-0939)
--
--   nvim --headless -u NONE -l tools/elemdrive.lua <corpus|dir> [--fns N] [--show N]
--
-- ★★★ THE SECOND WALKER CONSUMER, AND THE ONE THAT CAN ACTUALLY BE FINISHED.
-- `clones.anti_unify` has THREE callers and they are not equally easy to migrate:
--
--     analyze_pair       binary, WITH locals, and it GROUPS holes into parameters
--                        by (kind, a, b) -- a grouping the lgg does not share, so
--                        swapping it changes a proposed helper signature (CART-0939
--                        blocker 2, a decision and not a measurement)
--     element_template   pairwise against `ms[1]`, EMPTY locals, NO grouping --
--                        `varying` is keyed by the donor's source span and every
--                        occurrence is kept. Nothing to decide.
--     clones.match       donor against one payload, empty locals
--
-- So this driver measures the middle one. If its hole sets agree, `element_template`
-- migrates as a straight substitution with no behaviour to adjudicate.
--
-- ★★ WHAT IS DIFFERENT FROM `algebradrive`, AND IT IS NOT JUST THE POPULATION. The
-- lgg is natively n-ARY; `element_template` is PAIRWISE AGAINST THE DONOR, n-1
-- calls accumulating into one list. Those are different operations and the
-- difference is not obviously nil:
--   · pairwise-vs-donor puts a hole wherever ANY member disagrees WITH THE DONOR
--   · n-ary puts a hole wherever the members disagree WITH EACH OTHER
-- MEASURED rather than reasoned: identical on every alignable container across
-- four corpora. `linear = true` is passed because `element_template` IS the linear
-- variant (summaries.lua names it as such: it keys holes per donor span, so no
-- hole occurs twice) -- not because the flag reconciles the two.
--
-- ⚠ AND THE FLAG THAT WOULD HAVE MATTERED DOES NOT EXIST. `generalize` hedges a
-- differing-arity child list UNCONDITIONALLY; `align` is `join`'s option, not its.
-- The reconciliation is done here, by mapping a `rep` hole back to our
-- `struct why='arity'` -- see the note at the call.
--
-- ⚠ IT WRITES NOTHING AND TOUCHES NO SHIPPED PATH. Same contract as algebradrive.

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
local here = repo .. '/tools/'
dofile(here .. 'bench.lua').bootstrap()

local alg = require 'cartograph.algebra'
local A = alg.load()
if not A then
    local _, why = alg.available()
    print('the prototype algebra is not available: ' .. tostring(why))
    os.exit(2)
end

local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local expr = require 'cartograph.expr'
local clones = require 'cartograph.clones'
local atm = require 'cartograph.at'

local target, fns, show = arg[1], 400, 3
local i = 2
while arg[i] do
    if arg[i] == '--fns' then fns = tonumber(arg[i + 1]); i = i + 2
    elseif arg[i] == '--show' then show = tonumber(arg[i + 1]); i = i + 2
    else print('unknown argument: ' .. arg[i]); os.exit(2) end
end
if not target then
    print('usage: elemdrive.lua <corpus|dir> [--fns N] [--show N]')
    os.exit(2)
end

local reg = dofile(here .. 'corpora.lua')
local c = reg[target]
local root = c and vim.fn.expand(c.root) or vim.fn.expand(target)
if vim.fn.isdirectory(root) ~= 1 then print('not a directory: ' .. root); os.exit(2) end

local data = ts.extract(root, c and c.packs and { packs = c.packs } or nil)
store.ingest(data)

local counts, order = {}, {}
local function bump(k, n)
    k = tostring(k)
    if not counts[k] then order[#order + 1] = k end
    counts[k] = (counts[k] or 0) + (n or 1)
end

local function span_key(a)
    if not a then return nil end
    return ('%d:%d-%d:%d'):format(atm.sl(a), atm.sc(a), atm.el(a), atm.ec(a))
end

local shown, seen, containers = 0, 0, 0

--- ONE CONTAINER: our template against the lgg's.
local function compare(cn)
    local ms = cn.kids or {}
    if #ms < 2 then return end
    containers = containers + 1

    local ours = clones.element_template(cn)
    -- ⚠ EMPTY LOCALS, matching `element_template`'s own reason: a container's
    -- members are declarations, not a function body, so nothing is alpha-renameable
    -- and a locals map would equate two DIFFERENT names as "both local".
    local terms = {}
    for k, m in ipairs(ms) do
        local t = alg.term(m, {})
        if not t then bump('SKIP: a member the adapter cannot build'); return end
        terms[k] = t
    end

    -- ★★★ `align = 'none'` IS THE FIXED-ARITY LGG, AND WITHOUT IT THIS COMPARES
    -- TWO DIFFERENT OPERATIONS. By default `generalize` may place a HEDGE hole -- a
    -- slice of a child list -- so a container whose members have DIFFERENT ARITIES
    -- gets `(table ?h1...)`: one repetition hole swallowing the whole list. Our
    -- walker has no hedge and refuses on differing arity, so the two disagreed on
    -- exactly that class. MEASURED on jquery's Deferred tuples (members of arity
    -- 5, 6, 6): ours `alignable = false`, the lgg a template that rebuilds all three.
    --
    -- ⚠ AND THE HEDGE TEMPLATE IS NOT THE BETTER ANSWER HERE, WHICH IS WHY THIS IS
    -- A FLAG AND NOT A FINDING. `element_template`'s holes exist to DISCRIMINATE --
    -- "a payload diverging THERE is instantiating the template, one diverging
    -- anywhere ELSE is a different shape wearing the same outline". A hole around
    -- the entire member list matches every container of any shape, which is the
    -- degenerate case `algebradrive`'s coverage bands were built to catch.
    -- ⇒ THE HEDGE IS A REAL CAPABILITY WE LACK (ALGEBRA.md: "`analyze_pair` has no
    --   hedge hole ... a repetition claim has nowhere to land yet"). It is a
    --   SEPARATE question from this migration and must not ride in on it.
    local okg, g = pcall(A.generalize, terms, { linear = true, align = 'none' })
    if not okg or not g or not g.template then bump('SKIP: generalize refused'); return end

    -- ★★★ CLASSIFY PAIRWISE AGAINST THE DONOR, WHICH IS WHAT WE ARE COMPARING TO.
    -- `element_template` runs `anti_unify(ms[1], ms[i])` for each i and accumulates,
    -- so a site's kind on our side is decided by the donor and ONE other member at a
    -- time. Reading the lgg's n values all at once would be a different question
    -- wearing the same name.
    local derived, refuse = {}, false
    for k = 2, #terms do
        for _, st in ipairs(alg.hole_sites(g.template.body, terms[1], terms[k])) do
            -- ⚠ A HEDGE HOLE IS OUR `struct why='arity'`. `generalize` absorbs a
            -- differing-arity child list into one repetition hole; `anti_unify`
            -- refuses. MEASURED on jquery's Deferred tuples (arities 5, 6, 6): the
            -- lgg returns `(table ?h1...)`, a hole around the ENTIRE member list,
            -- which rebuilds all three members and matches every container of any
            -- shape. `element_template`'s holes exist to DISCRIMINATE, so taking the
            -- template would trade a refusal for a predicate that fires on
            -- everything. Mapping it back to the refusal is what makes this
            -- migration behaviour-preserving; the hedge is a real capability we lack
            -- and it is a SEPARATE question (ALGEBRA.md's `analyze_pair has no hedge
            -- hole` row), not one to settle by leaving a flag at its default.
            local kd = (st.rep and 'struct') or alg.hole_kind(st.a, st.b, st.pk, st.idx)
            if kd == 'struct' then
                refuse = true
            else
                local key = span_key(st.at)
                if key then
                    -- a later member must not silently overwrite an earlier verdict
                    if derived[key] and derived[key] ~= kd then
                        bump('★ the same site got TWO kinds across members')
                    end
                    derived[key] = kd
                else
                    bump('lgg site with no span (would be `unkeyed`)')
                end
            end
        end
    end

    -- ★ ALIGNABILITY IS THE VERDICT `M.match` READS, so it is compared first and on
    -- its own: `element_template` returns `alignable = false` on ANY struct hole and
    -- `M.match` refuses outright on it. A hole-set difference under a shared refusal
    -- reaches no consumer; a refusal difference reaches every one.
    local agree = (refuse == (ours.alignable == false))
    bump(('ALIGNABLE: %s'):format(agree and 'agrees' or '★ DIFFERS'))
    if not agree and shown < show then
        shown = shown + 1
        print(('\n★ ALIGNABLE DIFFERS (n=%d) at %s: ours=%s  lgg refuses=%s')
            :format(#ms, tostring(span_key(cn.at)), tostring(ours.alignable), tostring(refuse)))
        for k = 1, math.min(#ms, 4) do print('    member ' .. k .. ': ' .. A.show(terms[k])) end
        print('    T = ' .. A.show(g.template.body))
    end

    if not ours.alignable then bump('  ↳ (both refuse — sets not compared)'); return end

    local same = true
    for k, kd in pairs(ours.varying or {}) do
        if derived[k] ~= kd.kind then same = false end
    end
    for k, kd in pairs(derived) do
        local mine = (ours.varying or {})[k]
        if not mine or mine.kind ~= kd then same = false end
    end
    bump('VARYING SET: ' .. (same and 'identical' or '★ differs'))
    -- ⚠ `unkeyed` IS NOT COSMETIC: `M.match` REFUSES when it is non-zero, so a
    -- template with a spanless hole matches nothing at all. CART-0940 makes it
    -- non-zero for every ruby/php container holding a method call, and the lgg
    -- recovers the enclosing span there — which would turn a refusal into a match.
    bump(('UNKEYED: ours %s'):format((ours.unkeyed or 0) > 0 and '> 0 (match REFUSES)' or '0'))

    if not same and shown < show then
        shown = shown + 1
        print(('\n★ VARYING SET DIFFERS (n=%d)'):format(#ms))
        local ks = {}
        for k in pairs(ours.varying or {}) do ks[#ks + 1] = 'ours ' .. k .. ' ' .. (ours.varying[k].kind) end
        for k in pairs(derived) do ks[#ks + 1] = 'lgg  ' .. k .. ' ' .. derived[k] end
        table.sort(ks)
        for _, k in ipairs(ks) do print('    ' .. k) end
    end
end

for _, n in ipairs(data.nodes) do
    if (n.kind == 'function' or n.kind == 'method') and seen < fns then
        local ok, eo = pcall(expr.of, store, n.id)
        if ok and eo and eo.fl then
            seen = seen + 1
            for _, r in ipairs(eo.fl.stmts or {}) do
                if r.expr then
                    for _, side in ipairs({ 'lhs', 'rhs' }) do
                        for _, e in ipairs(r.expr[side] or {}) do
                            expr.walk(e, function (x) if x.k == 'table' then compare(x) end end)
                        end
                    end
                end
            end
        end
    end
end

print(('\ncorpus %s: %d function(s) walked, %d container(s) with n>=2')
    :format(target, seen, containers))
table.sort(order, function (a, b)
    if counts[a] ~= counts[b] then return counts[a] > counts[b] end
    return a < b
end)
for _, k in ipairs(order) do print(('  %-46s %5d'):format(k, counts[k])) end
