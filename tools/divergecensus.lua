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
    -- ★ RE-RECORDED 2026-09-04 (CART-0737) AND THE FIRST RUN WAS WRONG. dc_kids
    -- had no branch for a GENERIC node, so every unmodelled expression returned
    -- ZERO children: the walk stopped there instead of descending, and
    -- `leaf-vs-tree` fired on "generic faces modelled" rather than on a leaf.
    -- On java a method call IS generic (`?method_invocation` — the expression IR
    -- is a LUA IR, CART-0224), so the largest class of java expressions read as
    -- leaves. The 2026-09-03 numbers are kept BESIDE the new ones because the
    -- correction is the interesting part, not the tidy table:
    --     leaf-vs-tree   3422 -> 2666   was ranked #1, is now #3
    --     (no feature)    946 -> 8545   *** IS NOW #1, BY A FACTOR OF TWO ***
    --     divergences    8438 -> 16198  the walk now reaches what it skipped
    -- ★★ THE HEADLINE INVERTS. CART-0732 concluded "the missing hole kinds are
    -- REFACTORING RELATIONS" on the strength of leaf-vs-tree ranking first.
    -- Corrected, the largest class by far is the one with NO NAME AT ALL —
    -- 52.8% of divergences. What the taxonomy is missing is mostly not a
    -- refactoring relation; it is unnamed.
    ['libs'] = { pairs = 2432,
        f = { ['(no feature)'] = 8545, ['size-skew'] = 3963, ['leaf-vs-tree'] = 2666,
              ['one-side-absent'] = 2590, ['containment'] = 1035, ['call-vs-expr'] = 795,
              ['drift(lit/name)'] = 135 } },
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

local rec = RECORDED[target]
if show == 'all' or show == 'features' then
    io.write('FEATURES — a divergence can carry several. READ THIS TABLE FIRST.\n')
    if rec then io.write('     count   recorded 2026-09-03   feature\n')
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
    table.sort(rows, function (a, b)
        if a[2].n ~= b[2].n then return a[2].n > b[2].n end
        return a[1] < b[1]              -- total order, or the rank is not a fact
    end)
    local recur = 0
    for _, x in ipairs(rows) do if x[2].n > 1 then recur = recur + 1 end end
    io.write('SIGNATURES — the same disagreement, counted across pairs.\n')
    io.write(('  %d distinct · %d RECUR (>1 site)\n'):format(#rows, recur))
    for i = 1, math.min(#rows, 15) do
        io.write(('  x%-4d %s\n'):format(rows[i][2].n, rows[i][1]:sub(1, 120)))
        io.write(('        %s\n'):format(table.concat(rows[i][2].where, ' · '):sub(1, 120)))
    end
    io.write('\n')
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
