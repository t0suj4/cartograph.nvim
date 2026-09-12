-- algebradrive — DRIVE THE PROVEN ALGEBRA WITH REAL CARTOGRAPH IR (CART-0881).
--
--   nvim --headless -u NONE -l tools/algebradrive.lua <corpus|dir> [--pairs N] [--show N]
--
-- USER (2026-09-12): "We should start reconciliating the algebra into our
-- codebase" → "Maybe we could build a tool to drive the prototype into what we
-- need".
--
-- ★★★ WHY A DRIVER AND NOT A PORT. The algebra at `~/tools/templates` is BUILT
-- AND PROVEN -- 243 busted tests, a four-arrow basis from which 18 of 20
-- operators are re-derived, each judged by two oracles. What is NOT proven is
-- that it survives contact with cartograph's IR, because the prototype works on
-- plain terms: no spans, no surface text, uniform `kids`. Porting first would
-- mean GUESSING which arrows survive; driving first MEASURES it. This tool
-- touches no shipped analysis path and writes nothing.
--
-- ★★ IT NEVER COPIES THE PROTOTYPE. `dofile` of the real module, or nothing.
-- A copied algebra would be a second authority that drifts, which is the failure
-- this whole arc exists to avoid (CART-0746: A COPIED WALKER IS A COPIED BUG).
-- If the prototype moves, this tool breaks loudly rather than answering from a
-- stale snapshot.
--
-- ★★ AND SPANS RIDE THROUGH THE ALGEBRA FOR FREE -- checked in the source, not
-- assumed. `M.rebuild(t, kids)` carries "every field that is not the child
-- list", and `M.eq` compares only `k`, `v`, `n` and `kids`. So an `at` span
-- attached to a term node SURVIVES every arrow that rebuilds it and DISTURBS NO
-- COMPARISON. That is the licence for the adapter below to carry cartograph's
-- source ranges into a model that has no notion of text -- and it is what would
-- let a result be mapped back to a buffer.
--
-- WHAT IT MEASURES: a DIFFERENTIAL between cartograph's hand-written
-- `clones.anti_unify` and the prototype's `generalize` (the lgg) over the SAME
-- real near-clone pairs. Disagreement is a finding either way -- our bug, or a
-- translation gap this adapter has to name.

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
local here = repo .. '/tools/'
dofile(here .. 'bench.lua').bootstrap()

-- ⚠ `table.unpack or unpack` ONCE, AND NEVER INSIDE an `and`/`or`. The first cut
-- resolved the two names inline in the argument list, which is wrong TWICE:
-- an `and`/`or` expression TRUNCATES A MULTIPLE RETURN TO ONE VALUE, so every
-- node silently got its FIRST child only -- and the jquery run then reported
-- "RETRACTION HOLDS" over those truncated terms, which is precisely the shape of
-- a result that confirms you without having checked anything
-- ([[test-the-premise-not-the-consequence]]). The zero-child case crashed on
-- LuaJIT, and that crash is the only reason the truncation was ever seen.
local tunpack = table.unpack or unpack

local ALG = os.getenv('CARTOGRAPH_ALGEBRA')
    or (os.getenv('HOME') .. '/tools/templates/algebra.lua')
if vim.fn.filereadable(ALG) ~= 1 then
    print('the prototype algebra is not readable at: ' .. ALG)
    print('set CARTOGRAPH_ALGEBRA to its path. THIS TOOL DOES NOT CARRY A COPY.')
    os.exit(2)
end
local A = dofile(ALG)

local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local expr = require 'cartograph.expr'
local clones = require 'cartograph.clones'

local target, want_pairs, show, dist = arg[1], 60, 3, nil
local i = 2
while arg[i] do
    if arg[i] == '--pairs' then want_pairs = tonumber(arg[i + 1]); i = i + 2
    elseif arg[i] == '--show' then show = tonumber(arg[i + 1]); i = i + 2
    -- ⚠ THE POPULATION IS GATED BEFORE THE ALGEBRA EVER SEES IT. `clones.near`
    -- admits a pair only at `max_dist` row-edits or fewer (default 2), so a pair
    -- CANNOT carry many divergences and can barely mix shapes. Any claim about
    -- what shapes co-occur is a claim about THIS GATE until the gate is moved.
    elseif arg[i] == '--dist' then dist = tonumber(arg[i + 1]); i = i + 2
    else print('unknown argument: ' .. arg[i]); os.exit(2) end
end
if not target then
    print('usage: algebradrive.lua <corpus|dir> [--pairs N] [--show N]')
    os.exit(2)
end

-- ── the adapter: cartograph expr IR → prototype term ────────────────────────
--
-- ⚠ DISCRIMINANTS GO IN THE KIND, NOT IN A FIELD. `A.eq` compares `k`, `v`, `n`
-- and the kid list ONLY, so a `bin` carrying `op = '+'` and one carrying
-- `op = '-'` would compare EQUAL if the operator lived in a field -- and would
-- then anti-unify to nothing instead of to a hole. Encoding it as `bin:+`
-- mirrors `expr.key`'s own discriminants, and the prototype expects exactly
-- this shape (EAU.md: "operator theories would be a profile table over `bin:*`").
--
-- ⚠ A LITERAL CARRIES ITS TYPE for the same reason: `expr.key` writes
-- `L<ty>:<v>`, so number 1 and string "1" are distinct there. Dropping the type
-- here would make them equal and silently under-report divergence.
local function kind_of(e)
    local k = e.k
    if k == 'bin' or k == 'un' then return k .. ':' .. tostring(e.op) end
    if k == 'field' then return (e.method and 'method.' or 'field.') .. tostring(e.n) end
    return k
end

local unsupported = {}
local function to_term(e)
    if e == nil then return nil end
    if type(e) ~= 'table' or e.k == nil then return nil end
    local k = e.k
    local t
    if k == 'lit' then
        t = A.lit(tostring(e.ty) .. ':' .. tostring(e.v))
    elseif k == 'name' then
        t = A.name(tostring(e.n))
    else
        -- ★ THE CHILD LIST COMES FROM `expr.children`, THE SOURCE `walk` ITSELF
        -- CONSUMES (CART-0882). Not a per-kind descent written here -- that
        -- would be the fourth hand-written traversal in this codebase and the
        -- third chance to omit a kind silently.
        local kids = {}
        for _, c in ipairs(expr.children(e)) do
            local ct = to_term(c)
            if ct then kids[#kids + 1] = ct end
        end
        if #kids == 0 and not (k == 'table' or k == '?' or k == 'type') then
            -- a leaf kind the adapter does not model: counted, never guessed at
            unsupported[k] = (unsupported[k] or 0) + 1
        end
        t = A.node(kind_of(e), tunpack(kids))
    end
    -- the span, carried as a non-child field: rebuild keeps it, eq ignores it
    if e.at then t.at = e.at end
    return t
end

--- a clone ROW ({lhs, rhs, cond}) as one term, so a pair of rows is a pair of
--- instances the lgg can take. Shape mirrors `clones.anti_unify_row`.
local function row_term(r)
    if type(r) ~= 'table' then return nil end
    if r.k ~= nil then return to_term(r) end
    local kids = {}
    local function push(list)
        local seq = {}
        for _, x in ipairs(list or {}) do
            local t = to_term(x); if t then seq[#seq + 1] = t end
        end
        kids[#kids + 1] = A.seq(seq)
    end
    push(r.lhs); push(r.rhs)
    local c = r.cond and to_term(r.cond) or nil
    if c then kids[#kids + 1] = c end
    return A.node('row', tunpack(kids))
end

--- ★★★ IS A DIFFERING-ARITY `table` REPETITION, OR IS IT KEYED DATA?
--- The two have DIFFERENT RIGHT ANSWERS and the positional lgg cannot tell them
--- apart: it aligns by POSITION, so it appends one hedge hole at the END even
--- when the extra members were INSERTED IN THE MIDDLE -- which is why retraction
--- then fails. The prototype has a SECOND generalizer for this shape,
--- `kv_generalize` (objects by key; "a key present in some instances is a
--- presence hole over the rest"). If that one rebuilds both sides, the failure
--- was never a missing capability -- it was THE WRONG ARROW.
---
--- ⚠ VALUES ARE FLATTENED TO THEIR PRINTED FORM here, deliberately: this asks
--- only whether the two objects ALIGN BY KEY, and a scalar is enough for that.
--- It is not a claim about nested structure.
local function to_kv(t)
    if type(t) ~= 'table' or t.k ~= 'table' then return nil end
    local o, keys = {}, {}
    for _, kid in ipairs(t.kids or {}) do
        if kid.k ~= 'pair' then return nil end
        local kt, vt = (kid.kids or {})[1], (kid.kids or {})[2]
        if not kt or kt.k ~= 'lit' then return nil end
        local key = tostring(kt.v)
        if o[key] ~= nil then return nil end -- duplicate key: not an object
        o[key] = vt and A.show(vt) or ''
        keys[#keys + 1] = key
    end
    if #keys == 0 then return nil end
    return { o = o, keys = keys }
end

--- the two nodes that first disagree on arity, not just the fact that they do
local function arity_nodes(x, y)
    if type(x) ~= 'table' or type(y) ~= 'table' or x.k ~= y.k then return nil end
    local kx, ky = x.kids or {}, y.kids or {}
    if #kx ~= #ky then return x, y end
    for i = 1, #kx do
        local a, b = arity_nodes(kx[i], ky[i])
        if a then return a, b end
    end
    return nil
end

--- Where do two terms first disagree on CHILD-LIST LENGTH? A differing arity is
--- the hedge case: the lgg at arity 2 can record a repetition hypothesis but
--- cannot CONFIRM it (CART-0730 -- two samples evidence neither repetition nor
--- recursion), so the template it returns need not reproduce either instance.
--- Naming the cause is the difference between "18 failures" and a finding.
local function arity_split(x, y)
    if type(x) ~= 'table' or type(y) ~= 'table' then return nil end
    if x.k ~= y.k then return nil end
    local kx, ky = x.kids or {}, y.kids or {}
    if #kx ~= #ky then return ('%s %d vs %d'):format(tostring(x.k), #kx, #ky) end
    for i = 1, #kx do
        local d = arity_split(kx[i], ky[i])
        if d then return d end
    end
    return nil
end

-- ── run ─────────────────────────────────────────────────────────────────────
local reg = dofile(here .. 'corpora.lua')
local c = reg[target]
local root = c and vim.fn.expand(c.root) or vim.fn.expand(target)
if vim.fn.isdirectory(root) ~= 1 then print('not a directory: ' .. root); os.exit(2) end

local data = ts.extract(root, c and c.packs and { packs = c.packs } or nil)
store.ingest(data)
local pairs_ = clones.near(store, dist and { max_dist = dist } or {})
print(('corpus %s: %d functions, %d near pairs'):format(target, #data.nodes, #pairs_))

local tally, order = {}, {}
local function bump(k, n)
    if not tally[k] then order[#order + 1] = k end
    tally[k] = (tally[k] or 0) + (n or 1)
end

--- ★★★ THE ACTUAL DIFFERENTIAL: OUR ANTI-UNIFIER AGAINST THE PROVEN ONE.
--- ⚠ IT MUST BE PAIR-WIDE, NOT PER-ROW, or the two sides are not asked the same
--- question. `analyze_pair` groups its holes by (kind, a, b) across EVERY row, so
--- one varying leaf that recurs in three rows is ONE param. The lgg shares a hole
--- between equal divergent tuples only WITHIN the term it is given. So the terms
--- handed to `generalize` are the WHOLE diverging body on each side -- then both
--- sides dedup over the same extent and the counts mean the same thing.
local function pair_terms(p)
    local as, bs = {}, {}
    for _, o in ipairs(p.ops) do
        if o.op == 'sub' then
            local ta, tb = row_term(p.a.exprs[o.i]), row_term(p.b.exprs[o.j])
            if not ta or not tb then return nil end
            as[#as + 1] = ta; bs[#bs + 1] = tb
        end
    end
    if #as == 0 then return nil end
    return A.seq(as), A.seq(bs)
end

local shown, examined = 0, 0
for pi = 1, math.min(#pairs_, want_pairs) do
    local p = pairs_[pi]
    local ours = clones.analyze_pair(p)
    -- align the SAME rows the analyzer used, so the two sides see one input
    for _, o in ipairs(p.ops) do
        if o.op == 'sub' then
            local ra, rb = p.a.exprs[o.i], p.b.exprs[o.j]
            local ta, tb = row_term(ra), row_term(rb)
            if ta and tb then
                examined = examined + 1
                local ok, g = pcall(A.generalize, { ta, tb })
                if not ok then
                    bump('REFUSED by generalize: ' .. tostring(g):sub(1, 60))
                else
                    local nh = 0
                    for _ in pairs(g.template.holes or {}) do nh = nh + 1 end
                    -- the lgg's own law, checked on real code: instantiating
                    -- either valuation must reproduce its instance exactly
                    local r1 = A.instantiate(g.template, g.values[1])
                    local r2 = A.instantiate(g.template, g.values[2])
                    local law = r1 and r2 and A.eq(r1.term, ta) and A.eq(r2.term, tb)
                    if law then
                        bump('RETRACTION HOLDS')
                    else
                        local why = arity_split(ta, tb)
                        bump('★ RETRACTION FAILS')
                        bump(why and ('  ⤷ differing arity: ' .. why)
                            or '  ⤷ SAME ARITY THROUGHOUT (not the hedge case)')
                        -- repetition, or keyed data the positional lgg mis-aligned?
                        local xa, xb = arity_nodes(ta, tb)
                        local ka, kb = xa and to_kv(xa), xb and to_kv(xb)
                        if ka and kb then
                            local okk, r = pcall(A.kv_generalize, { ka, kb })
                            if okk and r and r.instantiate then
                                local good = pcall(function ()
                                    return A.kv_eq_keyed(r.instantiate(1), ka)
                                        and A.kv_eq_keyed(r.instantiate(2), kb)
                                end)
                                local rebuilt = good and A.kv_eq_keyed(r.instantiate(1), ka)
                                    and A.kv_eq_keyed(r.instantiate(2), kb)
                                bump(rebuilt and '  ⤷⤷ KEYED: kv_generalize REBUILDS both'
                                    or '  ⤷⤷ keyed route also fails')
                            else
                                bump('  ⤷⤷ kv_generalize refused')
                            end
                        else
                            bump('  ⤷⤷ not an object (真 repetition candidate)')
                        end
                    end
                    bump(nh == 0 and 'rows identical (0 holes)'
                        or ('lgg holes = ' .. math.min(nh, 6) .. (nh > 6 and '+' or '')))
                    if not law and shown < show then
                        shown = shown + 1
                        print(('\n★ RETRACTION FAILURE %d (UNTRUNCATED — keyed vs repetition?)\n  a = %s\n\n  b = %s\n\n  T = %s')
                            :format(shown, A.show(ta), A.show(tb), A.show(g.template.body)))
                    end
                end
            else
                bump('adapter produced no term for a row')
            end
        end
    end
    -- ★★★ IS ONE ARROW PER PAIR EVEN THE RIGHT QUESTION?
    -- USER (2026-09-12): "Perhaps the right result is a combination of
    -- primitives." Testable: classify every divergence in a pair by the SHAPE it
    -- sits in -- a keyed object (wants kv_generalize + presence holes), a
    -- variable-length sequence (wants a hedge), or a fixed-arity position (wants
    -- the plain lgg). If pairs routinely carry MORE THAN ONE shape, then
    -- selecting a single generalizer per pair is wrong BY CONSTRUCTION, and the
    -- template has to be a COMPOSITION chosen per position.
    local function shapes_in(x, y, acc)
        if type(x) ~= 'table' or type(y) ~= 'table' then return acc end
        if x.k ~= y.k then acc.leaf = true; return acc end
        local kx, ky = x.kids or {}, y.kids or {}
        if #kx ~= #ky then
            if to_kv(x) and to_kv(y) then acc.keyed = true else acc.seq = true end
            return acc
        end
        if #kx == 0 and not A.eq(x, y) then acc.leaf = true; return acc end
        for i = 1, #kx do shapes_in(kx[i], ky[i], acc) end
        return acc
    end

    -- the differential
    local TA, TB = pair_terms(p)
    if not TA then
        bump('DIFF: no pair term')
    else
        local ok, g = pcall(A.generalize, { TA, TB })
        if not ok then
            bump('DIFF: generalize refused')
        else
            local lgg = 0
            for _ in pairs(g.template.holes or {}) do lgg = lgg + 1 end
            local mine = #(ours.holes or {})
            -- ★★★ "THE LGG FOUND HOLES" IS NOT "THE LGG FOUND A VALID TEMPLATE".
            -- The differential counts holes; it never asked whether the template
            -- REPRODUCES the two bodies it was derived from. For the 214 pairs we
            -- refuse, that is the whole question -- an over-general template with
            -- one hole is not a clone we can extract, it is a wrong answer with a
            -- small number attached. So check the law pair-wide, where the
            -- comparison is actually being made.
            local r1 = A.instantiate(g.template, g.values[1])
            local r2 = A.instantiate(g.template, g.values[2])
            local valid = r1 and r2 and A.eq(r1.term, TA) and A.eq(r2.term, TB)
            -- ★★★ A VALID TEMPLATE IS NOT AN EXTRACTABLE ONE. The lgg is the
            -- LEAST general generalization, but at a structural divergence the
            -- least it can do is still ABSTRACT THE WHOLE DIFFERING SUBTREE into
            -- one hole. That template rebuilds both sides perfectly and is
            -- useless: a parameter covering 80% of the body is not a clone you
            -- can extract, it is "these two functions differ" with a hole drawn
            -- round the difference. USER (2026-09-12): "I would expect it to find
            -- more, it's supposed to be more general" -- generality is the risk,
            -- not the prize, so measure WHAT FRACTION OF THE BODY THE HOLES EAT.
            local eaten = 0
            for h in pairs(g.template.holes or {}) do
                local v = g.values[1] and g.values[1][h]
                if type(v) == 'table' then eaten = eaten + A.size(v)
                elseif type(v) == 'table' and v.terms then
                    for _, x in ipairs(v.terms) do eaten = eaten + A.size(x) end
                end
            end
            local whole = A.size(TA)
            local frac = whole > 0 and (eaten / whole) or 0
            local band = frac >= 0.75 and 'B: 75-100% (a hole round the difference)'
                or frac >= 0.50 and 'B: 50-75%'
                or frac >= 0.25 and 'B: 25-50%'
                or frac >= 0.10 and 'B: 10-25%'
                or 'B: <10% (a real parameter)'
            if valid then bump('HOLE COVERAGE ' .. band) end
            local sh = shapes_in(TA, TB, {})
            local names, n = {}, 0
            for _, key in ipairs({ 'keyed', 'seq', 'leaf' }) do
                if sh[key] then n = n + 1; names[#names + 1] = key end
            end
            bump(('SHAPES IN ONE PAIR: %d (%s)'):format(n, table.concat(names, '+')))
            if ours.kind == 'structural' then
                bump(('DIFF: ours REFUSED (structural), lgg found %s holes')
                    :format(lgg == 0 and '0' or (lgg <= 2 and tostring(lgg) or '3+')))
                bump(valid and '   ↳ and that template IS VALID (rebuilds both)'
                    or '   ↳ ⚠ but that template DOES NOT rebuild both')
                if valid then bump('   ↳↳ refused-by-us, ' .. band) end
            elseif ours.kind == 'value' then
                bump(valid and '   ↳ value pair: lgg template valid'
                    or '   ↳ ⚠ value pair: lgg template INVALID')
            end
            if false then
            elseif mine == lgg then bump('DIFF: AGREE on hole count')
            elseif mine < lgg then bump('DIFF: ours FEWER holes than the lgg')
            else bump('DIFF: ours MORE holes than the lgg') end
        end
    end
    bump('cartograph kind: ' .. tostring(ours.kind))
end

print(('\nexamined %d diverging rows across %d pairs\n'):format(examined, math.min(#pairs_, want_pairs)))
table.sort(order)
for _, k in ipairs(order) do print(('  %-46s %6d'):format(k, tally[k])) end
if next(unsupported) then
    print('\n⚠ expr kinds the adapter met as childless non-leaves (counted, not guessed):')
    local ks = {}
    for k in pairs(unsupported) do ks[#ks + 1] = k end
    table.sort(ks)
    for _, k in ipairs(ks) do print(('  %-20s %6d'):format(k, unsupported[k])) end
end
