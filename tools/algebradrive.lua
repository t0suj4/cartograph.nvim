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

-- ★★★ THE LOADER AND THE ADAPTER BOTH LIVE IN THE SHIPPED TREE NOW
-- (`cartograph.algebra`, CART-0889). They were BORN here, and leaving a second
-- copy behind after promoting them would be precisely the bug this file's own
-- header warns about -- two adapters drifting apart, and TWO `dofile`s of a
-- 6001-line module with internal memo state live in one process.
local alg = require 'cartograph.algebra'
local A = alg.load()
if not A then
    local _, why = alg.available()
    print('the prototype algebra is not available: ' .. tostring(why))
    print('set config.algebra_path or $CARTOGRAPH_ALGEBRA. NO COPY IS CARRIED.')
    os.exit(2)
end

local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local clones = require 'cartograph.clones'

local target, want_pairs, show, dist, rigid, sizes, maxsize, stride, timing =
    arg[1], 60, 3, nil, false, false, nil, 1, false
local i = 2
while arg[i] do
    if arg[i] == '--pairs' then want_pairs = tonumber(arg[i + 1]); i = i + 2
    elseif arg[i] == '--show' then show = tonumber(arg[i + 1]); i = i + 2
    -- ⚠ THE POPULATION IS GATED BEFORE THE ALGEBRA EVER SEES IT. `clones.near`
    -- admits a pair only at `max_dist` row-edits or fewer (default 2), so a pair
    -- CANNOT carry many divergences and can barely mix shapes. Any claim about
    -- what shapes co-occur is a claim about THIS GATE until the gate is moved.
    elseif arg[i] == '--dist' then dist = tonumber(arg[i + 1]); i = i + 2
    -- the rigid path costs 0.2-12 s per pair on sides of 40-220 nodes (the prototype
    -- measured it and called it "fine for a probe, NOT for the interactive path"), so
    -- it is opt-in and carries a size guard.
    elseif arg[i] == '--rigid' then rigid = true; i = i + 1
    -- ⚠ WALL-CLOCK BUCKETS ARE OPT-IN because they are NONDETERMINISTIC and this
    -- tool's oracle is that two runs over one tree agree BYTE FOR BYTE.
    elseif arg[i] == '--time' then timing = true; i = i + 1
    -- ★ SIZE ONLY: how many pairs could the rigid path even attempt? The alignment
    -- DP is memoized over string keys and the prototype guards at nS*nQ > 400000;
    -- this runs the guard and nothing else, so a corpus can be sized in one pass
    -- instead of discovered by a run that never finishes.
    elseif arg[i] == '--sizes' then sizes = true; rigid = true; i = i + 1
    -- ⚠⚠ `clones.near` RETURNS ITS PAIRS RANKED BY (shared, dist), SO THE LIST IS
    -- ORDERED MOST-EXPENSIVE-FIRST. Taking `--pairs N` off the front is therefore
    -- NOT A SAMPLE OF THE POPULATION — it is the worst N, and on wow it walks
    -- straight into the band that costs minutes per pair. (Measured: 54 of 4000
    -- wow pairs exceed the guard, but the first two do.) `--maxsize` filters by
    -- the alignment's actual cost driver so a run can cover the population it
    -- claims to. Same family as the max_dist gate: a measurement inherits the
    -- ORDER its population arrives in, not just the filter that selected it.
    elseif arg[i] == '--maxsize' then maxsize = tonumber(arg[i + 1]); i = i + 2
    -- ★ AND A CAP ALONE DOES NOT FIX THE ORDER. Taking the first N pairs UNDER the
    -- cap is still the most expensive N OF THAT BAND. `--stride` walks the ranked
    -- list so a sample spans it instead of sitting on one end.
    elseif arg[i] == '--stride' then stride = tonumber(arg[i + 1]); i = i + 2
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
local unsupported = {}

-- The adapter itself is `cartograph.algebra`; these wrappers exist only to feed
-- this tool's own unsupported-kind tally, which the shipped seam takes as an
-- optional out-parameter rather than owning.
local function to_term(e, locals) return alg.term(e, locals, unsupported) end
local function row_term(r, locals) return alg.row_term(r, locals, unsupported) end

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

--- ★★★ THE RIGID PATH: THE ARROW THE POSITIONAL ONE COULD NOT EXPRESS.
--- Everything above drives `A.generalize`, the POSITIONAL lgg, which has no context
--- variable and therefore cannot represent a WRAPPER — one side enclosing what the
--- other has bare. That is the largest class in cartograph's "structural" bucket
--- (20 of 31 on the lua corpus), so every aggregate the positional path produced was
--- measuring an arrow that was blind to the majority case.
---
--- ⚠ THE UNIT IS THE WHOLE FUNCTION, NOT THE DIVERGING ROWS. My positional run fed
--- `generalize` only the `sub` rows, which is wrong for vertical generalization: an
--- alignment is over the entire row sequence, and inserted/deleted rows are part of
--- what it aligns AROUND. The prototype's own bridge encodes a function as a seq of
--- rows and hands the whole thing to `vertical`; this follows it.
local function fn_term(f)
    local rows = {}
    for i = 1, #(f.exprs or {}) do
        rows[i] = row_term(f.exprs[i], f.locals) or A.node('row~')
    end
    return A.seq(rows)
end

local function count_holes(t, acc)
    acc = acc or { hedge = 0, ctx = 0 }
    if t.k == 'hole' then
        if t.ctx then acc.ctx = acc.ctx + 1 else acc.hedge = acc.hedge + 1 end
    end
    for _, c in ipairs(t.kids or {}) do count_holes(c, acc) end
    return acc
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
            local ta, tb = row_term(p.a.exprs[o.i], p.a.locals), row_term(p.b.exprs[o.j], p.b.locals)
            if not ta or not tb then return nil end
            as[#as + 1] = ta; bs[#bs + 1] = tb
        end
    end
    if #as == 0 then return nil end
    return A.seq(as), A.seq(bs)
end

local shown, examined = 0, 0
for pi = 1, math.min(#pairs_, want_pairs), stride do
    local p = pairs_[pi]
    local ours = clones.analyze_pair(p)
    if rigid then
        -- ★★★ THE MEASUREMENT THAT SUPERSEDES THE POSITIONAL ONE. `vertical` under the
        -- JWZ skeleton returns a template with HEDGE holes (a slice of a row list) and
        -- CONTEXT holes (a wrapper around a base). `ctx > 0` is the algebra's own answer
        -- to "is this a wrapper", derived rather than inferred from hole KINDS — which
        -- is exactly what `clones.analyze_pair.shape` has to approximate by counting.
        -- So this is a FRESH ORACLE for that rule, on any corpus, not just the one
        -- snapshot the prototype measured.
        local S, Q = fn_term(p.a), fn_term(p.b)
        local nS, nQ = A.size(S), A.size(Q)
        if sizes then
            local prod = nS * nQ
            local band = prod > 400000 and 'D: OVER THE GUARD (unattemptable)'
                or prod > 100000 and 'C: 100k-400k (minutes)'
                or prod > 20000 and 'B: 20k-100k'
                or 'A: under 20k (the prototype measured here)'
            bump('size ' .. band)
            bump('cartograph kind: ' .. tostring(ours.kind))
            goto next_pair
        end
        if maxsize and nS * nQ > maxsize then
            bump('rigid: filtered out by --maxsize')
            bump('cartograph kind: ' .. tostring(ours.kind))
            goto next_pair
        end
        if nS * nQ > 400000 then
            bump('rigid: SKIPPED, too big (the prototype\'s own guard)')
        else
            local t0 = os.clock()
            local okv, v = pcall(A.vertical, S, Q, { skeleton = 'jwz' })
            local dt = os.clock() - t0
            if not okv or not v or not v.templates or not v.templates[1] then
                bump('rigid: REFUSED — ' .. tostring(v):sub(1, 50))
            else
                local T = v.templates[1]
                local h = count_holes(T.body)
                -- the law on real IR: instantiating either valuation reproduces its side
                local r1 = A.instantiate(T, T.values[1])
                local r2 = A.instantiate(T, T.values[2])
                local rebuilt = r1 and r2 and A.eq(r1.term, S) and A.eq(r2.term, Q)
                bump(rebuilt and 'rigid: REBUILDS BOTH' or '★ rigid: does NOT rebuild')
                -- per-pair line, so the adapter can be validated against the
                -- prototype's own experiments/nearclones_detail-*.txt rather than
                -- only in aggregate (an aggregate with no names cannot be checked)
                print(('PAIR\t%d\t%s\t%d\t%d\t%s\t%s'):format(pi, ours.kind,
                    h.hedge, h.ctx, tostring(ours.shape), tostring(rebuilt)))
                bump(h.ctx > 0 and 'rigid: has a CONTEXT variable (a wrapper)'
                    or 'rigid: hedge variables only')
                if dt > 5 then bump('rigid: slow pair (>5s)') end
                -- ★ SCORE clones.analyze_pair.shape AGAINST IT, which is the point
                if ours.kind == 'structural' then
                    local mine = ours.shape == 'wrapper' or ours.shape == 'mixed'
                    bump(((mine == (h.ctx > 0)) and 'SHAPE AGREES with rigid'
                        or ('★ SHAPE DISAGREES: mine=' .. tostring(ours.shape)
                            .. ' rigid ctx=' .. h.ctx))
                        )
                    -- ★ WHICH SIGNAL FIRED? The rule is `struct > 0 OR field/op`.
                    -- Knowing which half over-claims is the difference between
                    -- "the rule is 93%" and a mechanism that can be fixed.
                    -- ★★★ LET THE ALGEBRA CHARACTERISE THE DIVERGENCE ITSELF.
                    -- Instead of reading witnesses one at a time, anti-unify the two
                    -- diverging nodes of every `kind` struct hole and ask what the
                    -- lgg RETAINED. If it is a bare hole, the two sides have nothing
                    -- in common at all — a whole-term replacement, which encloses
                    -- nothing. If structure survives, something is genuinely shared
                    -- and a wrapper is possible. This is the machinery answering the
                    -- question the counts could not, on its own terms.
                    -- ⚠⚠ MY FIRST CUT ASKED `A.generalize` WHETHER THE LGG RETAINED
                    -- STRUCTURE, AND THAT TEST IS VACUOUS BY DEFINITION. A `kind`
                    -- struct hole means the two nodes have DIFFERENT ROOT SYMBOLS —
                    -- that is why the hole exists — and the anti-unification of two
                    -- terms with different roots IS a variable. It answered "bare
                    -- hole" on 11 of 11 and could never have answered anything else:
                    -- a constant standing where a computation belonged, which is the
                    -- exact shape of the payload-accessor error.
                    -- ⇒ THE RIGHT INSTRUMENT IS THE SAME ONE, APPLIED LOCALLY.
                    -- `vertical` finds context variables; run it on the two small
                    -- diverging NODES instead of the whole function and it answers
                    -- "is one of these a context applied to the other" directly, and
                    -- cheaply, because subterms are small.
                    local retained, kindholes = 0, 0
                    for _, sh in ipairs(ours.structs or {}) do
                        if sh.why ~= 'arity' and sh.why ~= 'localglobal' and sh.xn and sh.yn then
                            kindholes = kindholes + 1
                            local tx = to_term(sh.xn, p.a.locals)
                            local ty = to_term(sh.yn, p.b.locals)
                            if tx and ty then
                                local t0n = timing and os.clock() or 0
                                local okg, gv = pcall(A.vertical, tx, ty, { skeleton = 'jwz' })
                                -- ⚠ OFF BY DEFAULT: a wall-clock bucket is
                                -- NONDETERMINISTIC, and this tool's whole value is
                                -- that two runs of the same tree are BYTE-IDENTICAL.
                                -- An always-on timer silently destroys that oracle.
                                if timing then
                                    local dtn = os.clock() - t0n
                                    bump(dtn < 0.01 and 'node-vertical: <10ms'
                                        or dtn < 0.1 and 'node-vertical: 10-100ms'
                                        or dtn < 1 and 'node-vertical: 0.1-1s'
                                        or 'node-vertical: >1s')
                                end
                                if okg and gv and gv.templates and gv.templates[1] then
                                    local hh = count_holes(gv.templates[1].body)
                                    if hh.ctx > 0 then retained = retained + 1 end
                                end
                            end
                        end
                    end
                    if kindholes > 0 then
                        bump(('LOCAL vertical on kind holes: %s'):format(
                            retained > 0 and 'a CONTEXT variable' or 'no context'))
                        bump(('   ⤷ vs rigid: %s'):format(
                            ((retained > 0) == (h.ctx > 0)) and 'agrees' or '★ differs'))
                    end
                    -- ★★★ SCORE THE CANDIDATE NARROWING TOO: a `kind` struct hole
                    -- counts as wrapper evidence ONLY IF the two sides share a
                    -- subterm (enclosure keeps something; replacement does not).
                    -- arity and localglobal holes stop counting entirely.
                    -- ⚠ BOTH DIRECTIONS ARE SCORED. The shipped rule's value is that
                    -- it has ZERO under-reports, so `shape` reads as an UPPER BOUND;
                    -- a narrowing that buys precision by losing that is not an
                    -- improvement, it is a different and weaker claim.
                    local w = ours.struct_why or {}
                    -- ⚠ A PAIR HAS MANY HOLES WITH DIFFERENT CAUSES, so a narrowing
                    -- must be per-HOLE while the verdict is per-PAIR. My first cut
                    -- dropped arity and localglobal evidence entirely and under-
                    -- reported 7 true wrappers on lua alone — pairs that carry an
                    -- inserted argument AND a wrapper elsewhere. Narrow only the
                    -- bucket the argument was about: a `kind` hole must share a
                    -- subterm; arity and localglobal keep whatever they were worth.
                    local cand = (ours.evidence == 'selector')
                        or (w.kind or 0) > 0 and (w.kind_shared or 0) > 0
                        or (w.arity or 0) > 0 or (w.localglobal or 0) > 0
                    -- the same rule with LOCAL VERTICAL replacing the containment
                    -- test on the kind bucket — the algebra's own answer, node-scale
                    local cand2 = (ours.evidence == 'selector')
                        or (kindholes > 0 and retained > 0)
                        or (w.arity or 0) > 0 or (w.localglobal or 0) > 0
                    local truth = h.ctx > 0
                    bump(cand2 == truth and 'CAND2 (local vertical) agrees'
                        or (cand2 and '★ CAND2 over-reports' or '★★ CAND2 UNDER-REPORTS'))
                    bump(cand == truth and 'CANDIDATE agrees'
                        or (cand and '★ CANDIDATE over-reports' or '★★ CANDIDATE UNDER-REPORTS'))
                    if mine ~= cand then
                        bump('   ⤷ candidate differs from shipped: ' ..
                            (cand and 'candidate says wrapper' or 'candidate says rows')
                            .. (truth == cand and ' (and is RIGHT)' or ' (and is WRONG)'))
                    end
                    -- ★ SCORE BY EVIDENCE, which is the claim the field makes:
                    -- `selector` is documented as having zero false positives, so
                    -- a single disagreement in that bucket falsifies the field's
                    -- own docstring. `shape` is documented as carrying them all.
                    bump(('   EVIDENCE %s: %s'):format(tostring(ours.evidence),
                        (mine == (h.ctx > 0)) and 'agrees' or '★ DISAGREES'))
                    if mine ~= (h.ctx > 0) then
                        local fo = false
                        for _, x in ipairs(ours.holes) do
                            if x.kind == 'field' or x.kind == 'operator' then fo = true end
                        end
                        local w = ours.struct_why or {}
                        bump(('   ⤷ struct cause: arity=%d kind=%d localglobal=%d')
                            :format(w.arity or 0, w.kind or 0, w.localglobal or 0))
                        bump('   ⤷ over-report by: ' ..
                            ((ours.struct > 0 and fo) and 'BOTH signals'
                             or (ours.struct > 0) and 'STRUCT hole only'
                             or 'FIELD/OP hole only'))
                        bump(('   ⤷ witness: %s:%s / %s:%s'):format(
                            p.a.file, tostring(p.a.line), p.b.file, tostring(p.b.line)))
                    end
                    if mine ~= (h.ctx > 0) and shown < show then
                        shown = shown + 1
                        print(('\n★ SHAPE/RIGID DISAGREEMENT %d — %s:%s / %s:%s\n'
                            .. '   mine=%s (struct=%d insdel=%d)  rigid: ctx=%d hedge=%d')
                            :format(shown, p.a.file, tostring(p.a.line), p.b.file,
                                tostring(p.b.line), tostring(ours.shape), ours.struct,
                                ours.insdel, h.ctx, h.hedge))
                    end
                end
            end
        end
        bump('cartograph kind: ' .. tostring(ours.kind))
        goto next_pair
    end
    -- align the SAME rows the analyzer used, so the two sides see one input
    for _, o in ipairs(p.ops) do
        if o.op == 'sub' then
            local ra, rb = p.a.exprs[o.i], p.b.exprs[o.j]
            local ta, tb = row_term(ra, p.a.locals), row_term(rb, p.b.locals)
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
        -- ⚠ I FIRST REPORTED THIS AS "an adapter gap, honest" AND IT IS NOT A GAP.
        -- Diagnosed on wow: all 57 such pairs have NO `sub` ops at all — their whole
        -- divergence is rows present on one side only. There are no diverging rows to
        -- anti-unify, so `pair_terms` correctly builds nothing. That is not a hole in
        -- the adapter; it is the ROWS-ONLY class (clones.analyze_pair's `shape`), and
        -- calling it a gap hid a whole class behind a word that sounded like candour.
        local nsub = 0
        for _, o in ipairs(p.ops) do if o.op == 'sub' then nsub = nsub + 1 end end
        bump(nsub == 0 and 'rows-only pair (no diverging rows — not a gap)'
            or 'DIFF: no pair term (a real adapter gap)')
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
    ::next_pair::
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
