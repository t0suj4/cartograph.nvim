-- divergecensus — WHAT SHOULD A TEMPLATE BE ABLE TO SAY? (CART-0732)
--
--   nvim --headless -u NONE -l tools/divergecensus.lua <corpus|path>
--        [--max-dist N] [--below N] [--show kinds|features|witnesses|all]
--
-- clones' anti-unifier names exactly TWO kinds of divergence: a VALUE hole (a
-- literal/name/operator that differs — a clean parameter) and a STRUCT hole
-- (the shapes differ — give up, the pair is not extractable). Everything the
-- template language cannot express lands in the second bucket undifferentiated,
-- so "which hole kind should we add next?" had no evidence behind it and was
-- answered by guessing.
--
-- This censuses that bucket: every divergence the named kinds cannot take,
-- tabulated by node-kind pair and by derived FEATURES, so the next hole kind is
-- FOUND rather than proposed.
--
-- ★ THE METHOD HAS ONE PRIOR SUCCESS, WHICH IS WHY IT IS WORTH TRUSTING.
-- CART-0349 did this by hand: it noticed `lit` facing `name` inside the struct
-- bucket was a class of its own — one copy HARDCODES what the other READS — and
-- named it DRIFT, which is now a shipped report. The census re-discovers that
-- class unprompted (`drift(lit/name)`), which is the only validation a method
-- like this can have.
--
-- ★ READ THE FEATURE TABLE, NOT THE KIND TABLE. `rcanon` falls back to
-- `?<tree-sitter type>` for constructs the expression IR does not model, so on a
-- mixed corpus the kind table measures IR COVERAGE rather than a missing hole
-- kind. MEASURED: elasticsearch/libs carries a native tail (28 .cc, 6 .h) and
-- its top kind-pairs are `?method_invocation` / `?cast_expression` /
-- `?sizeof_expression` — C++ constructs, not a template-language gap. The
-- feature table keys on SHAPE and does not have that problem.
--
-- ★ WHAT THE FIRST RUN FOUND (2026-09-03), and it is the reason this shipped:
-- the top features are not structural variants at all. `call-vs-expr` witnesses
-- `provably_dead(n,…)` against its own INLINED premise list; `leaf-vs-tree`
-- witnesses a bare local against the expression it was assigned from;
-- `containment` witnesses one side wrapped in extra conjuncts. Those are
-- EXTRACT/INLINE and ADD-A-GUARD — refactoring relations, i.e. A NAMING BOUNDARY
-- MOVED — and no amount of enumerating structural shapes reaches them.
--
-- ★ AND ONE NORMALIZATION FALLS OUT: the guard witnesses are LEFT-NESTED CHAINS
-- (`a and b and c and …` parses as nested `bin`). That is semantically a LIST
-- and structurally deep nesting, so ASSOCIATIVE OPERATORS MAKE REPETITION LOOK
-- LIKE RECURSION. Flattening them is cheaper than a recursive hole and shrinks
-- what one has to cover — do it first.
--
-- POPULATION: pairs that share >= 2 distinctive statements and are EXCLUDED at
-- the shipped near-clone cap (`--below`, default 2). That is exactly the set
-- the tool declines to report today, which is where a missing hole kind must be
-- if it is anywhere.
--
-- ★ THE RECORDED RUN IS PART OF THE OUTPUT, not a comment: a census whose
-- numbers nobody can diff is an anecdote. Ours is below and prints beside the
-- live one.

local here = debug.getinfo(1, 'S').source:sub(2):match('^(.*)/[^/]*$')
package.path = './lua/?.lua;./lua/?/init.lua;' .. package.path
local bench = dofile(here .. '/bench.lua')
bench.bootstrap()
local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local clones = require 'cartograph.clones'

-- the RECORDED run (2026-09-03, CART-0732), for comparison only. Feature counts
-- at --max-dist 32 --below 2. A count that MOVED is the review question: a new
-- divergence class, or an IR change that reclassified an old one.
local RECORDED = {
    -- `libs` is a GATED corpus at a pinned revision, so its numbers mean the
    -- same thing next month. A count that MOVED is the review question: a new
    -- divergence class, or an expression-IR change that reclassified an old one.
    --
    -- ★ RE-RECORDED TWICE, AND THE TWO CORRECTIONS ARE THE INTERESTING PART.
    -- Both times the numbers moved because THE INSTRUMENT COULD NOT SEE THE
    -- CORPUS, not because the corpus changed — the revision is pinned and has
    -- not moved since the first run.
    --
    -- 2026-09-03  first run.
    -- 2026-09-04  CART-0737: dc_kids had no branch for a GENERIC node, so every
    --             unmodelled expression returned ZERO children and
    --             `leaf-vs-tree` fired on "generic faces modelled". It ranked #1
    --             on an artifact; `(no feature)` rose to #1 at 52.8%.
    -- 2026-09-05  CART-0224 + CART-0741: the EXPRESSION IR itself was blind to
    --             java. Literals, field/index access and — the big one — the
    --             CALL LAYER were unmodelled, so `?method_invocation` stood
    --             where a call belonged. `call-vs-expr` was reporting 795 on a
    --             corpus where its own concept occurs 5681 times: 14% coverage,
    --             and nothing said so. The 795 were the C++ tail (28 .cc/6 .h),
    --             whose `call_expression` WAS in the map.
    --
    -- 09-05b  CART-0742: the C/C++ tail's literals (libs holds 28 .cc / 6 .h).
    --         Small HERE because libs is java-dominant; on the pinned `cpp`
    --         corpus the same two names move `?` -38.6% and `lit` x17.6.
    --
    --   feature            09-03    09-04   09-05a   09-05b
    --   call-vs-expr         842      795     5681     5665
    --   (no feature)         946     8545     4553     4527   #1 -> #2
    --   size-skew           3395     3963     3163     3158
    --   leaf-vs-tree        3422     2666     2847     2846   was #1 on an artifact
    --   one-side-absent     2590     2590     2522     2561
    --   containment         1451     1035     1358     1348
    --   drift(lit/name)       65      135     1010     1043   25% -> 98% (CART-0739)
    --   divergences         8438    16198    16293    16319
    --   pairs scanned       2432     2432     2429     2435
    --
    -- ⚠ FOUR RE-RECORDS IN THREE DAYS, AND NONE OF THEM WAS DRIFT. That is what
    -- a baseline pinned to an instrument under active repair looks like, and it
    -- is worth saying rather than hiding behind tidy numbers: this table is only
    -- a drift detector once the IR stops moving. Until then a `-> MOVED` row
    -- means "check which change did it", and the FIRST thing to check is
    -- whether the lua control moved with it.
    --
    -- ★★ SO: A COUNT IS NOT A CLASS, AND A RANKING IS NOT A FINDING until the
    -- instrument can see every language it is run on. Three rankings, three
    -- honest measurements, and the first two were wrong one layer down. The
    -- fence that would have caught it on day one is the one that caught it on
    -- day three: A CONTROL CORPUS IN A LANGUAGE THE INSTRUMENT FULLY MODELS.
    -- cartograph (lua) was byte-identical through every one of these changes.
    -- If the java numbers move and lua does not, THE INSTRUMENT MOVED, NOT THE
    -- WORLD — and that is the only reading of a `-> MOVED` row that is safe to
    -- take at face value.
    -- 09-05c  CART-0742 item 3: a TYPE in expression position became a kind.
    --         Types now key BY NAME in all three structural keys, so pairs that
    --         differed only in a type stop matching — pairs scanned 2435 -> 2356
    --         and every feature falls slightly. Fewer pairs, not fewer findings.
    --
    -- ★★ 09-05d  CART-0742 item 2, AND IT IS THE FIFTH SELF-MEASUREMENT — the
    --         only one that failed in TWO directions at once. A bare statement
    --         (`foo();`) built as `?expression_statement(<call>)`, so:
    --
    --         (a) IT MINTED `call-vs-expr`. The predicate is `(kx == 'call' or
    --             ky == 'call') and kx ~= ky`, and a WRAPPER facing a call
    --             satisfies it exactly — `?` is not `call`. Nothing was
    --             extracted or inlined; one side was simply a statement.
    --         (b) IT BLINDED THE WALK. `walk` returns on `x.k ~= y.k`, so every
    --             comparison under a wrapped statement was never made at all.
    --
    --         The kind-pair table is the proof, and it is a near-exact transfer:
    --           ? | call     2983 -> 1492   (-1491)
    --           call | call  2641 -> 4116   (+1475)
    --         The same comparisons, now aligned — and DESCENDED INTO, which is
    --         why total divergences RISE (15865 -> 16653) while the pair set is
    --         unchanged. More divergences, each located at the real difference
    --         instead of at a wrapper. Every rise below is that descent.
    --
    --   feature            09-05c   09-05d
    --   call-vs-expr         5585     5027   #1 -> #2, and ~half of it was the wrapper
    --   (no feature)         4440     5485   #2 -> #1
    --   size-skew            3107     3496
    --   leaf-vs-tree         2780     3129
    --   one-side-absent      2359     2363
    --   containment          1326     1487
    --   drift(lit/name)      1030     1131
    --   divergences         15865    16653
    --   pairs scanned         2356     2356   unchanged
    --
    -- ⚠ SO CART-0732'S HEADLINE NEEDS A FOOTNOTE. `call-vs-expr` was read as
    -- "EXTRACT/INLINE A CALL is the most valuable missing hole kind", and on
    -- this corpus half its population was a statement wrapper. The class is
    -- REAL — 5027 survive, and the C++ witness that opened it is genuine — but
    -- its RANK was inflated by the same coverage artifact as `leaf-vs-tree`
    -- (09-04) before it. THAT IS FIVE, AND THE PATTERN IS ALWAYS THE SAME: the
    -- number describes the instrument, and it describes it most loudly where
    -- the instrument is blindest.
    -- ★ 09-05e  CART-0742 item 4: the OPTIONAL-ARGUMENT hole ships as a
    --         predicate, `arity` + its strong refinement `arity(appended)`. It
    --         adds no divergences (16653 unchanged) — it NAMES 363 that were
    --         `(no feature)`, which falls 5485 -> 5124. Only the strong form is
    --         a DC_RELATION, so the pair rollup moves barely: fully explained
    --         266 -> 279, SHARP 154 -> 159. Promoting the WEAK form instead
    --         would have moved it far more and mostly wrongly — see the
    --         DC_RELATION comment in clones.lua.
    -- ★ 09-05f  CART-0744: the SOLE WRAPPERS — php `argument`, C++
    --         `subscript_argument_list` and `condition_clause`. On THIS corpus
    --         it is the C++ TAIL moving (28 .cc / 6 .h): the two C++ names are
    --         C++-only per the grammars' own symbol tables, and java declares
    --         neither. pairs 2356 -> 2347, divergences 16653 -> 16486. `arity`
    --         and `arity(appended)` hold EXACTLY, which is the tell that the
    --         call layer itself did not move — only what sits inside it.
    --         Where it really pays is php: `?` falls 72% (5447 -> 1544) and 81%
    --         on sylius, with READS/NAMES/call/lit identical throughout.
    ['libs'] = { pairs = 2347,
        f = { ['(no feature)'] = 5044, ['call-vs-expr'] = 4998, ['size-skew'] = 3469,
              ['leaf-vs-tree'] = 3158, ['one-side-absent'] = 2312,
              ['containment'] = 1538, ['drift(lit/name)'] = 1160,
              ['arity'] = 363, ['arity(appended)'] = 145 } },
    -- ★ `self` DELIBERATELY HAS NO ROW. corpora.lua calls it a LIVING corpus,
    -- "NOT GATED: every commit invalidates a snapshot baseline by construction",
    -- and recording numbers against it here would manufacture exactly the drift
    -- that note warns about. Run it freely; compare it to nothing.
}

local target = arg[1]
if not target then
    print('usage: nvim --headless -u NONE -l tools/divergecensus.lua <corpus|path> '
        .. '[--max-dist N] [--below N] [--show kinds|features|witnesses|pairs|sigs|all]')
    os.exit(2)
end
local max_dist, below, show = 32, 2, 'all'
for i = 2, #(arg or {}) do
    if arg[i] == '--max-dist' then max_dist = tonumber(arg[i + 1]) or max_dist end
    if arg[i] == '--below' then below = tonumber(arg[i + 1]) or below end
    if arg[i] == '--show' then show = arg[i + 1] or show end
end

-- a registered corpus name, else a bare path
local reg = dofile(here .. '/corpora.lua')
local c = reg[target]
local root = c and vim.fn.expand(c.root) or vim.fn.expand(target)
if vim.fn.isdirectory(root) ~= 1 then
    print('not a directory: ' .. root)
    os.exit(2)
end

local data = ts.extract(root, c and c.packs and { packs = c.packs } or nil)
data.root = data.root or root
store.ingest(data)

local res = clones.divergence_census(store, { max_dist = max_dist, below = below,
    by_pair = show == 'all' or show == 'pairs' or show == 'sigs' })

local function ranked(t)
    local rows = {}
    for k, v in pairs(t) do rows[#rows + 1] = { k, v } end
    table.sort(rows, function (a, b)
        if a[2] ~= b[2] then return a[2] > b[2] end
        return a[1] < b[1]              -- total order, or the rank is not a fact
    end)
    return rows
end

io.write(('divergecensus %s   (max_dist=%d, excluded below dist>%d)\n')
    :format(root, max_dist, below))
io.write(('  pairs scanned %d   unnamed divergences %d\n\n')
    :format(res.pairs_scanned, res.divergences))

-- ★ THE COMPARISON IS ONLY MEANINGFUL AT THE RECORDED PARAMETERS. A run with a
-- different --below or --max-dist scans a DIFFERENT POPULATION, and every row
-- then prints `-> MOVED` for no reason at all — a drift detector that cries
-- wolf across an axis hides the drift it was built to catch. Caught in-session:
-- `--below 0` reported "(no feature) 8545 -> MOVED 8653" when nothing had
-- changed but the floor.
local REC_MAXDIST, REC_BELOW = 32, 2
local rec = RECORDED[target]
if rec and (max_dist ~= REC_MAXDIST or below ~= REC_BELOW) then
    io.write(('  (recorded run is max_dist=%d below=%d — NOT COMPARED at %d/%d:'
        .. ' a different population is not drift)\n'):format(
        REC_MAXDIST, REC_BELOW, max_dist, below))
    rec = nil
end
if show == 'all' or show == 'features' then
    io.write('FEATURES — a divergence can carry several. READ THIS TABLE FIRST.\n')
    if rec then io.write('     count   recorded 2026-09-05   feature\n')
    else io.write('     count   feature\n') end
    for _, r in ipairs(ranked(res.features)) do
        if rec then
            local was = rec.f[r[1]]
            io.write(('  %8d   %-19s   %s\n'):format(r[2],
                was and (was == r[2] and tostring(was) or (was .. ' -> MOVED')) or 'new', r[1]))
        else
            io.write(('  %8d   %s\n'):format(r[2], r[1]))
        end
    end
    if rec then
        for k, v in pairs(rec.f) do
            if res.features[k] == nil then io.write(('  %8s   %-19s   %s\n'):format('0', v .. ' -> GONE', k)) end
        end
        io.write(('  (recorded pairs scanned: %d)\n'):format(rec.pairs))
    end
    io.write('\n')
end

if show == 'all' or show == 'kinds' then
    io.write('NODE-KIND PAIRS — contaminated by IR coverage where kinds print as `?type`.\n')
    local rows = ranked(res.kindpairs)
    for i = 1, math.min(#rows, 15) do io.write(('  %8d   %s\n'):format(rows[i][2], rows[i][1])) end
    if #rows > 15 then io.write(('  … %d more\n'):format(#rows - 15)) end
    io.write('\n')
end

if (show == 'all' or show == 'pairs') and res.by_pair then
    -- THE CENSUS'S MISSING HALF. Feature counts answer "which divergence
    -- classes exist"; they cannot answer "which PAIRS are fully explained by a
    -- refactoring relation", which is the question a FINDING would need. Same
    -- walk, different accumulator.
    --
    -- ⚠ AND THE ANSWER SO FAR IS "ALMOST NONE, AND NOT THE ONES YOU WANT". On
    -- libs, 93 of 2205 diverging pairs are fully explained, 50 of them in one
    -- direction with <=2 divergences — and three of three hand-read witnesses
    -- were NOT half-applied refactorings but parallel implementations that
    -- differ in one expression (two distance formulas; two ways to compute a
    -- vector byte size). The tags are PROXIES: `leaf-vs-tree` cannot know
    -- whether the leaf IS the tree, because rcanon alpha-renames a local and
    -- never substitutes its binding. Read the witnesses before believing a row.
    local full, sharp = 0, {}
    for _, p in ipairs(res.by_pair) do
        if p.explained == p.div then
            full = full + 1
            if p.dir ~= 'both' and p.div <= 2 then sharp[#sharp + 1] = p end
        end
    end
    io.write('PAIRS — fully explained by a refactoring-relation proxy.\n')
    io.write(('  %d diverging pairs · %d fully explained · %d SHARP (one direction, <=2 divergences)\n')
        :format(#res.by_pair, full, #sharp))
    table.sort(sharp, function (m, n) return (m.dist or 0) < (n.dist or 0) end)
    for i = 1, math.min(#sharp, 10) do
        local p = sharp[i]
        local ks = {}
        for k, v in pairs(p.tags) do ks[#ks + 1] = k .. 'x' .. v end
        table.sort(ks)
        io.write(('  %-30s %-30s dist=%d dir=%s [%s]\n')
            :format((p.an or '?'):sub(-30), (p.bn or '?'):sub(-30), p.dist,
                tostring(p.dir), table.concat(ks, ',')))
        if p.wit then
            io.write(('     A %s\n     B %s\n'):format(p.wit.a:sub(1, 96), p.wit.b:sub(1, 96)))
        end
    end
    io.write('\n')
end

if (show == 'all' or show == 'sigs') and res.sigs then
    -- ★★ THE PAIR IS THE WRONG UNIT FOR "ONE THING DONE TWO WAYS". Counted per
    -- pair, `Float.BYTES` facing a local reads as a scatter of unrelated rows;
    -- counted per SIGNATURE it is ONE disagreement with 111 sites, and that is
    -- a thing a reader new to the codebase can act on. Measured on libs: 493 of
    -- 1028 signatures RECUR. This is the greenspun steer's other half — the
    -- finding does not deserve standing attention, and it is exactly what you
    -- want when you are LOOKING for it.
    --
    -- ⚠ THE ROWS ARE CANON STRINGS, not prose, and `L` is an ALPHA-RENAMED
    -- LOCAL — not a literal (literals print `Lint:`/`?decimal_integer_literal`).
    -- Misreading that turns "a constant inlined vs held in a local" into "a
    -- magic number", which is a different finding. Read the canon, not the gist.
    local rows = {}
    for k, e in pairs(res.sigs) do rows[#rows + 1] = { k, e } end
    -- ★ RANKED BY DISTINCT OWNERS, NOT SITES. Eight sites inside one function is
    -- a local habit; the same disagreement across eight classes is a fact about
    -- the codebase. Sorting by count alone buried the second under the first —
    -- and on the first run with this order the top unnamed row turned out to be
    -- a literal facing a named value across 38 owners (CART-0739).
    table.sort(rows, function (a, b)
        if a[2].nowners ~= b[2].nowners then return a[2].nowners > b[2].nowners end
        if a[2].n ~= b[2].n then return a[2].n > b[2].n end
        return a[1] < b[1]              -- total order, or the rank is not a fact
    end)
    local recur = 0
    for _, x in ipairs(rows) do if x[2].n > 1 then recur = recur + 1 end end
    -- ★ A SHORTLIST, AND A `ranked-open` ONE (CART-0755). This prints the top 15
    -- of #rows, so an absence here means "did not rank highly", NEVER "does not
    -- exist" — the opposite of the entries census, which is exhaustive. Stating
    -- which it is, in the header, is the whole contract: a narrowing presented as
    -- complete makes a reader stop looking.
    local shortlist = require 'cartograph.shortlist'
    local srows = {}
    for i = 1, math.min(#rows, 15) do
        srows[#srows + 1] = { key = rows[i][1], n = rows[i][2].n,
            owners = rows[i][2].nowners, where = rows[i][2].where }
    end
    local list = shortlist.new{
        subject = 'the same disagreement, counted across pairs',
        scope = ('%d distinct signatures, %d of which RECUR'):format(#rows, recur),
        complete = shortlist.RANKED_OPEN, rows = srows,
    }
    io.write(table.concat(list:render(function (r)
        return ('owners=%-3d x%-4d %s\n               %s'):format(r.owners, r.n,
            r.key:sub(1, 112), table.concat(r.where, ' · '):sub(1, 112))
    end), '\n'))
    io.write('\n\n')
end

if show == 'all' or show == 'witnesses' then
    io.write('WITNESS per feature combination (first seen) — open one and the class settles.\n')
    local tags = {}
    for k in pairs(res.witnesses) do tags[#tags + 1] = k end
    table.sort(tags)
    for _, t in ipairs(tags) do
        local w = res.witnesses[t]
        io.write(('  %s\n     %s\n     %s\n'):format(t, w.a:sub(1, 96), w.b:sub(1, 96)))
    end
end
