-- exprcensus — DOES ANY COLUMN GATE THE EXPRESSION IR? IT DID NOT (CART-0395).
--
-- `expr.gate` is a genuine two-implementation oracle: `expr.reads(row)` (the identifier
-- leaves the expression tree reads) is an INDEPENDENT derivation of `row.use ∪ row.rmw`
-- (du's read census over the same node), so a disagreement is a real bug on ONE side. It
-- has existed since the expression layer shipped. Nothing ran it on a real corpus.
--
-- ★ WHAT "IT WAS RUN" ACTUALLY MEANT. tools/syngate.lua calls it and prints
-- "exprgate: 0 disagreement(s)" — over `gen.analysis('lua', …)`, a generated LUA corpus,
-- iterating `n.kind == 'function'`. Two restrictions compound: the corpus is one language,
-- and the subject set excludes every METHOD — which in java and ruby is essentially all
-- code. A clean zero from that is a statement about lua functions, and it was read as a
-- statement about the expression IR.
--
-- MEASURED the moment it was pointed anywhere else: elasticsearch/libs 3128 disagreements
-- (409 functions, 9978 methods); activesupport 450 across 2104 methods; and the SYNTHETIC
-- corpora the matrix already pins — synjava 6, synjs 33, synlua 49 — none of which any
-- runner looked at.
--
-- ★ SO THIS IS A CENSUS, NOT A PASS/FAIL. The same argument as tools/rowcensus.lua: a gate
-- that must be zero cannot land while four defect classes are open, and a class that is
-- open is not a reason to keep the number invisible. Pin it per corpus, diff it every run,
-- and the review question is directional: A COUNT THAT ROSE IS A NEW DISAGREEMENT; a count
-- that fell is a fix. Classes are keyed separately so a class that goes to zero says so.
--
-- ★ AND THE CLASSIFICATION IS THE USEFUL PART, because "3128 disagreements" is not
-- actionable and "1378 of them are C declarations" is. The key is (axis, row type):
--   binder    — `extra` ⊆ the row's own DEF names: the IR reads what the row BINDS
--   extra     — the IR reads a name du does not (a leaked nested body, a field selector)
--   missing   — du reads a name the IR does not (a table KEY, a java annotation)
--   both      — disagreement in both directions on one row
--
--   nvim --headless -u NONE -l tools/exprcensus.lua <dir> [--lang <l>] [--show <class>]

local M = {}

--- ★★ WHY THIS WALKS BY FILE (CART-0423). The census was UNRUNNABLE on four of the
--- thirty-seven corpora — zig, odin, v8 and wow produced no output at all, and the exit
--- code was laundered so it read as a clean zero rather than a death. MEASURED: they run
--- OUT OF MEMORY. `expr.of` re-parses the whole enclosing file once per subject, one parse
--- costs 21–53 bytes of RSS per source byte, and the census's growth rate inside a file
--- matched the isolated per-parse cost exactly (16.9 MB/subject in zig's InternPool.zig,
--- both ways). zig died 21.7 s in, at subject 570 of 8590 — never slow, just fatal.
---
--- ★ THE ORDER IS HALF THE FIX. expr's parse cache holds ONE tree, so it only pays when
--- consecutive subjects share a file. Extraction already emits nodes file by file — which
--- is exactly why relying on that would be the WRONG shape: it would work on every corpus
--- that happens to be ordered and degrade silently to the old cost on one that is not,
--- which is unobservable from the outside until a corpus dies. So the grouping is made
--- explicit, and the cache's hit rate is reported (`M.parse_stats`) rather than assumed.
---
--- STABLE, and that matters beyond tidiness: buckets are keyed in FIRST-APPEARANCE order
--- and nodes keep their order within a bucket, so an already-grouped corpus is walked in
--- exactly the order it was before. `instances` lists keep their existing order and
--- `--show` output does not move for a change that is pure performance.
local NOFILE = '\0nofile' -- the one bucket that is not a file (see below)
local function by_file(nodes)
    local order, buckets = {}, {}
    for _, n in ipairs(nodes or {}) do
        -- ★ FUNCTIONS *AND* METHODS. The single-word restriction that hid all of this.
        if n.kind == 'function' or n.kind == 'method' then
            -- a node with no file still gets a bucket: expr.of refuses it, and dropping
            -- it here instead would change WHICH subjects are attempted
            local key = n.file or NOFILE
            local b = buckets[key]
            if not b then b = {}; buckets[key] = b; order[#order + 1] = key end
            b[#b + 1] = n
        end
    end
    return order, buckets
end

--- Census the expr self-gate over an extracted graph.
--- Returns { fns, methods, total, cats } where `cats` is the DIFFABLE map (mirrors
--- rowcensus.check / dfparity.check so a caller can treat all three identically).
---@param store table  an INGESTED store (expr.of needs content, not just nodes)
function M.check(store)
    local expr = require 'cartograph.expr'
    local cats = { total = 0 }
    local fns, methods = 0, 0
    local instances = {}
    local order, buckets = by_file(store.data.nodes)
    -- counters are PROCESS-cumulative (the cache outlives any one call), so this call's
    -- share is a delta — otherwise a second corpus in the same process reports the first
    -- one's hits as its own
    local p0 = expr.parse_stats()
    local freed = 0
    for _, fkey in ipairs(order) do
        for _, n in ipairs(buckets[fkey]) do
            local ok, got = pcall(expr.of, store, n.id)
            if ok and got and got.fl then
                if n.kind == 'method' then methods = methods + 1 else fns = fns + 1 end
                local S = got.fl.stmts or {}
                for _, d in ipairs(expr.gate(got.fl, got.lang)) do
                    local s = S[d.row] or {}
                    local dset = {}
                    for _, x in ipairs(s.def or {}) do dset[x] = true end
                    local all_defs = #d.extra > 0
                    for _, x in ipairs(d.extra) do if not dset[x] then all_defs = false end end
                    local axis = (#d.missing == 0 and all_defs and 'binder')
                        or (#d.missing == 0 and 'extra')
                        or (#d.extra == 0 and 'missing') or 'both'
                    local key = axis .. ':' .. tostring(s.t or s.kind or '?')
                    cats.total = cats.total + 1
                    cats[key] = (cats[key] or 0) + 1
                    local L = instances[key]
                    if not L then L = {}; instances[key] = L end
                    L[#L + 1] = { file = n.file, l = d.line, kind = n.kind,
                        missing = d.missing, extra = d.extra }
                end
            end
        end
        -- ★ RELEASE AT THE BOUNDARY, then collect ON A BYTE BUDGET. Two measurements
        -- decided the pair, and neither alone was enough: an ISOLATED re-parse loop with a
        -- forced collect held RSS flat (28.8 MB over 20 iterations vs 350.3 without),
        -- while the real census with a collect every 20 subjects and NO release recovered
        -- only ~30% and still died. Dropping the reference is what lets the collection
        -- work at all.
        --
        -- ★ BUT COLLECTING PER FILE COSTS MORE THAN IT SAVES — MEASURED, and it is the one
        -- thing in this change that made anything WORSE. go has 923 files, and a full
        -- collect after each took the census from 38 s to 179 s, a 4.7× slowdown, for a
        -- peak that was already down to the extract's. So the trigger is the quantity that
        -- actually drives the peak: SOURCE BYTES released since the last collect.
        --
        -- The budget is derived, not picked: a parse costs a MEASURED 21–53 bytes of RSS
        -- per source byte, so 8 MB of released source is at most ~400 MB of dead tree
        -- awaiting collection — comfortably under any corpus budget, while a small-file
        -- corpus now collects a handful of times instead of once per file. A single file
        -- larger than the budget (zig's 11 MB CodeGen.zig) trips it on its own, which is
        -- exactly the case that needs it.
        freed = freed + expr.parse_release()
        if freed >= 8 * 1024 * 1024 then collectgarbage(); freed = 0 end
    end
    local p1 = expr.parse_stats()
    -- ★ THE REUSE RATE IS ONLY READABLE BESIDE THE FILE COUNT (CART-0429). `miss` IS the
    -- parse count, and the by-file walk's whole claim is that it TRACKS THE FILE COUNT — so
    -- a bare "99.7% reuse" can be checked against nothing, while "1 miss over 1 file" can be
    -- checked at a glance. A corpus whose misses run well ahead of its files has either lost
    -- the grouping or is failing to PARSE: `parse_root` counts the miss BEFORE its pcall and
    -- caches nothing on failure, so an unparseable file misses once per SUBJECT rather than
    -- once per file. Which is also why this is REPORTED AND NOT GATED — the same two numbers
    -- mean "the walk regressed" and "this corpus has an unparseable file", and the census
    -- output is IDENTICAL either way, so nothing else in the harness can see it at all.
    local nfiles, nofile = 0, 0
    for _, k in ipairs(order) do
        if k == NOFILE then nofile = #buckets[k] else nfiles = nfiles + 1 end
    end
    return { fns = fns, methods = methods, total = cats.total, cats = cats,
        instances = instances,
        parse = { hit = p1.hit - p0.hit, miss = p1.miss - p0.miss,
            concat = p1.concat - p0.concat, files = nfiles, nofile = nofile } }
end

--- Census one-liner (stable order: total first, then classes by descending count).
function M.census(cats)
    local parts = { ('disagreements=%d'):format(cats.total or 0) }
    local ord = {}
    for k, v in pairs(cats) do
        if k ~= 'total' then ord[#ord + 1] = { k = k, v = v } end
    end
    table.sort(ord, function (a, b)
        if a.v ~= b.v then return a.v > b.v end
        return a.k < b.k
    end)
    for _, e in ipairs(ord) do parts[#parts + 1] = e.k .. '=' .. e.v end
    return table.concat(parts, ' ')
end

--- ★ HOW MANY ROWS ARE ACTUALLY BEHIND A COUNT (CART-0410). `cats` counts INSTANCES, and
--- M.check iterates FUNCTIONS: a row reachable from several function nodes is counted once
--- per node. On the cpp corpus that is not a rounding error — `missing:declaration` is 10667
--- instances over 414 distinct (file,line) rows, 25.8×, because a C++ class body parsed as C
--- becomes ONE function_definition that every method in the header resolves to.
---
--- ★ AND THE INFLATION IS PER-CLASS, WHICH IS WHY IT CORRUPTS THE RANKING, not just the
--- magnitude: 1.0× for binder:if_statement against 25.8× here. The two classes CART-0404
--- called "the single biggest IR/du gap" are the two MOST duplicated in the census; by
--- distinct rows they are mid-table. A census whose classes inflate at different rates
--- cannot be read as a priority order, and nothing said so for the first nineteen corpora.
---
--- Deliberately NOT folded into `cats`: every EXPECTED pin is keyed on instances, and
--- re-keying would move all nineteen at once for a reporting change. Two numbers, both
--- printed, neither pretending to be the other.
---@return table  { [class] = distinct row count, total = distinct across all classes }
function M.distinct(instances)
    local out, all = { total = 0 }, {}
    for class, list in pairs(instances or {}) do
        local seen, n = {}, 0
        for _, it in ipairs(list) do
            local key = (it.file or '?') .. ':' .. tostring(it.l)
            if not seen[key] then seen[key] = true; n = n + 1 end
            all[class .. '|' .. key] = true
        end
        out[class] = n
    end
    for _ in pairs(all) do out.total = out.total + 1 end
    return out
end

--- Census one-liner with the distinct split — `class=instances/distinct`, and a class whose
--- two numbers agree prints one. Ordered by DISTINCT rows, because that is the ranking a
--- reader wants and the instance ranking is the one that misled CART-0404.
function M.census_distinct(cats, dist)
    local parts = { ('disagreements=%d rows=%d'):format(cats.total or 0, dist.total or 0) }
    local ord = {}
    for k, v in pairs(cats) do
        if k ~= 'total' then ord[#ord + 1] = { k = k, v = v, d = dist[k] or 0 } end
    end
    table.sort(ord, function (a, b)
        if a.d ~= b.d then return a.d > b.d end
        if a.v ~= b.v then return a.v > b.v end
        return a.k < b.k
    end)
    for _, e in ipairs(ord) do
        parts[#parts + 1] = e.k .. '=' .. (e.v == e.d and tostring(e.v)
            or ('%d/%d'):format(e.v, e.d))
    end
    return table.concat(parts, ' ')
end

--- Diff against a pinned census; returns report lines (empty = agree).
--- Mirrors rowcensus.diff / dfparity.diff exactly.
function M.diff(cats, expected)
    local out, seen = {}, {}
    for k, v in pairs(cats) do
        seen[k] = true
        local e = expected[k]
        if e ~= v then out[#out + 1] = ('    %s %s→%d'):format(k, e == nil and '(new)' or e, v) end
    end
    for k, e in pairs(expected) do
        if not seen[k] then out[#out + 1] = ('    %s %d→0 (GONE)'):format(k, e) end
    end
    table.sort(out)
    return out
end

--- Render collected instances of a class (the `--show` output).
function M.show_instances(list, class, cap)
    cap = cap or 40
    local n = list and #list or 0
    local L = { ('%s: %d instance(s)%s'):format(class, n,
        n > cap and (' (showing first ' .. cap .. ')') or ''), '' }
    for i = 1, math.min(n, cap) do
        local it = list[i]
        L[#L + 1] = ('%s:%d [%s]'):format(it.file, it.l, it.kind)
        L[#L + 1] = ('    missing={%s}  extra={%s}'):format(
            table.concat(it.missing, ','), table.concat(it.extra, ','))
    end
    return L
end

-- ★ PINNED per-corpus census. Only corpora with a pinned rev or a deterministic synthetic
-- identity, the same rule rowcensus.EXPECTED and dfparity.EXPECTED follow — a living corpus
-- moves the number for free, so a delta there would never mean a regression.
--
-- ★ EVERY ENTRY BELOW IS A KNOWN DEFECT WITH A TICKET, and that is the point of pinning
-- rather than asserting zero:
--   binder:try_with_resources_statement  CART-0400 — the head binds `r` in `try (var r = …)`
--       but its `resources` child also holds the INITIALIZERS, so neither skipping it nor
--       taking its leaves is exact; needs a per-resource split.
--   binder:statement_block               CART-0401 — a BARE `{ … }` block is emitted as ONE
--       opaque row, so its declarations read as defs of the block itself. A region with no
--       rows: the same class as every language in CART-0363.
--   extra:*  on js                       CART-0402 — `xs.length`: expr counts a field
--       SELECTOR as a read (true for lua, where it is an `identifier`), du does not count
--       js's `property_identifier`. A lua-shaped assumption in a language-agnostic IR.
--   missing:*  on lua/java               CART-0403 — du counts a table-constructor KEY
--       (`{ k = 2 }`) and a java ANNOTATION (`@SuppressWarnings`) as reads. Neither is a
--       variable read; this side is du's, and fixing it moves the df census.
--   binder:declaration                   CART-0404 — the DECLARATOR long tail: cpp 110,
--       cppmodern 106, v8 3859 distinct rows. C/C++ only, and it is what is LEFT after the
--       flat-declaration split below; the shapes here have an `init_declarator` and no `=`
--       at declaration level (`Foo f(x);`, `Foo f{x};`), which is why the split cannot reach
--       them. ★ The header said "1378 on elasticsearch, C/C++ only" for five days after zig
--       became the biggest instance of the same defect — a doc line is a claim too.
--   binder:variable_declaration          CART-0404, THE ZIG HALF, FIXED — 14002 -> 1371 (zig
--       total 16088 -> 3456, 78.5% of the corpus's census). zig's declaration is FLAT:
--       `const x: T = y;` has no declarator node, so the row fell to the generic `?` walk,
--       which reads every identifier including THE DECLARED NAME. The fix reuses the
--       operator split built for odin's field-less assignments (CART-0304); the type is a
--       READ, because in zig a type IS a value.
--   binder:variable_declaration          CART-0431, THE DU HALF, ALSO FIXED — 1371 -> 74,
--       and it took NINE OTHER CLASSES with it (block_expression 498 -> 285, switch_case
--       298 -> 132, `missing:variable_declaration` 236 -> 0): zig total 3456 -> 1495, and
--       16088 -> 1495 across the pair. du's `k = 4` said every direct `identifier` child of
--       a declaration is def-position — right for lua, which reaches that branch only
--       without an operator, and wrong for zig, where name, type and value all sit at depth
--       1: `var i: usize = index;` stored `def={i,index} use={}`, KILLING A PARAMETER'S
--       incoming definition and never counting the read.
--       ★★ THE GATE WAS SILENT ON IT BECAUSE BOTH SIDES WERE WRONG. Fixing the IR is what
--       exposed du. The two now split a flat declaration on the same ASSIGN_OP token, and
--       that table has ONE OWNER (`flow.ASSIGN_TOK`) rather than a copy on each side.
--
-- ── recalib @ CART-0405, the combinatorial grid's FIRST RUN ─────────────────────────────
-- The grid (tools/genmatrix.lua + tools/gridgate.lua) fired on EVERY `c_ifs_*_ch2` and
-- `_ch3` cell and on NO `_ch1` cell — which NAMES the axis, if x CHAIN-LENGTH, without
-- anyone having to guess it. Java spells `else if` as a NESTED `if_statement`: neither a
-- BODY nor a CLAUSE, so it fell through to build(), whose `?` path recurses every named
-- child and swallowed the whole chain's BODIES.
-- ★ AND THE FIRST FIX WAS MEASURED WRONG BEFORE IT SHIPPED. Skipping the nested child
-- outright also drops its CONDITION, which du keeps — trading 36 `extra` for 51 `missing` on
-- cpp and 12 on bash: a bigger disagreement wearing a different label. Recursing it as a
-- 'ctrlhead' keeps the condition and drops the body, which is where du draws the line.
-- NET: cpp 114631->114626 · bash 5737->5735, and on bash 32 rows moved `both` -> `missing`,
-- which is flat in COUNT and strictly better in KIND (a two-sided disagreement became
-- one-sided). Every other pinned corpus unmoved.
M.EXPECTED = {
    -- recalib 2026-09-01 (AN INTERPOLATED STRING IS NOT A LITERAL, CART-0665): 5029 ->
    -- 1047, a 79% fall from ONE change. `"$prefix-${n}"` is a bash `string` whose kids are
    -- a simple_expansion and an expansion — two variable READS — and the literal branch
    -- returned {k='lit'} and dropped them. 17360 strings, 13287 simple_expansions and 4011
    -- expansions on this corpus never reached the IR.
    --
    -- ★★ AND THE CENSUS'S OWN RANKING NAMED THE CONTAINER, NOT THE CAUSE. Its top row was
    -- `missing:command` at 1133, and CART-0665 said to model `command` first because in
    -- bash a command IS the fundamental expression form. That would have been the wrong
    -- move: command went 1133 -> 0 with nothing touching commands, because the reads it was
    -- losing were inside the STRINGS its arguments are made of. A disagreement is attributed
    -- to the enclosing ROW's node type, so this list ranks containers — tools/gramdiff.lua
    -- reaches the same gap from the GRAMMAR side and named string / simple_expansion /
    -- expansion outright. Two instruments, and only the second one pointed at the cause.
    -- recalib 2026-09-01 (A BINDER'S NAMES ARE NOT READS, CART-0665): 1047 -> 669.
    -- `local i len` binds two names and the IR reported both as reads; du had them in
    -- `def`. spec/bash.lua declares declaration_command as a binder with `defs = true`.
    -- ⚠ `defs` IS OPT-IN AND THAT COST A MEASUREMENT: applying it to every declared
    -- binder took the SELF corpus 1961 -> 2967 (missing:for_numeric_clause 0 -> 504),
    -- because du puts lua's `for i = 1, n` binding in `use` and bash's in `def`. One
    -- language's fix was another's regression until the spec opted in per binder.
    -- recalib 2026-09-01 (THE BASE CLASS SETS HAD BASH BACKWARDS, CART-0667): 669 -> 484.
    -- flow's shared CASE set holds `case_statement`, which in C/php/java IS one arm — in
    -- bash it is the whole `case X in … esac` and the arms are `case_item`. So the switch
    -- was classified as an arm and each arm as a plain STATEMENT whose `def` swallowed its
    -- entire body: on a 15-line fixture one arm row carried `def=[a b]` for two separate
    -- assignments, and 5 rows stood where 10 belong.
    --   missing:case_item      199 -> 0
    --   missing:case_statement  15 -> 0
    -- ⚠ AND SOME NEIGHBOURS ROSE, which is not a regression: the arms' bodies are ROWS
    -- now, so statements that were folded invisibly into an arm are visible and can
    -- disagree on their own — extra:if_statement 19 -> 27, missing:if_statement 137 -> 141.
    -- Net -185, and ctrlcensus goes from 6 of 6 forms to 7 of 7 with case_item classified
    -- for the first time.
    bash = { total = 484,
        ['missing:if_statement'] = 141, ['missing:list'] = 123,
        ['missing:c_style_for_statement'] = 88, ['extra:if_statement'] = 27,
        ['binder:elif_clause'] = 23, ['missing:test_command'] = 23,
        ['missing:variable_assignment'] = 17, ['missing:elif_clause'] = 13,
        ['both:if_statement'] = 6, ['binder:if_statement'] = 5,
        ['extra:elif_clause'] = 5, ['missing:do_group'] = 5,
        ['missing:redirected_statement'] = 4, ['binder:redirected_statement'] = 1,
        ['binder:while_statement'] = 1, ['both:elif_clause'] = 1,
        ['missing:while_statement'] = 1 },
    -- ★ RE-PINNED @ CART-0404's C/C++ half: `binder:declaration` cpp 110 -> 1 and
    -- cppmodern 106 -> 1, `both:declaration` GONE. TWO defects, both C++-only shapes that a
    -- set written against C could not have: a REFERENCE declarator (`Config &c = x;`), and a
    -- declaration MODIFIER with no initialiser (`static String str;`). No new class either.
    cpp = { total = 1379, ['missing:preproc_def'] = 858, ['missing:declaration'] = 469,
        ['binder:declaration'] = 1, ['missing:preproc_function_def'] = 22,
        ['binder:if_statement'] = 6, ['binder:compound_statement'] = 5,
        ['missing:declaration_command'] = 5, ['missing:command'] = 4,
        ['binder:for_statement'] = 2, ['missing:expression_statement'] = 2,
        ['binder:declaration_command'] = 1, ['both:pipeline'] = 1,
        ['missing:if_statement'] = 1, ['missing:list'] = 1,
        ['missing:variable_assignment'] = 1 },
    -- ★ pinned from the FINAL state, not a mid-arc reading: my first attempt wrote 41,
    -- measured after the reference-declarator fix and BEFORE the modifier one, and the pin
    -- went red on its own next run. `binder:declaration` reaches 0 here — cppmodern is C++
    -- throughout, so both C++-only shapes were its whole residual.
    cppmodern = { total = 40, ['binder:if_statement'] = 25,
        ['missing:declaration'] = 12, ['missing:for_range_loop'] = 2,
        ['binder:compound_statement'] = 1 },
    -- recalib 2026-08-16 (CART-0422, A SPREAD IS NOT A VARARG): -2. go was NOT expected to
    -- move — the fix was described as js-only — but `VARARG` is a BASE set, so any grammar
    -- with a spread-ish node carrying an operand rides it. The direction settles it: two
    -- rows where du counted the operand and the IR did not, now agreeing. Prior: 3055.
    go = { total = 3053, ['missing:assignment_statement'] = 2748, ['missing:type_case'] = 68,
        ['missing:for_clause'] = 58, ['missing:expression_statement'] = 37,
        ['extra:type_switch_statement'] = 37, ['extra:if_statement'] = 22,
        ['missing:short_var_declaration'] = 13, ['missing:type_switch_statement'] = 13,
        ['missing:defer_statement'] = 9, ['missing:send_statement'] = 9,
        ['binder:for_statement'] = 8, ['both:type_switch_statement'] = 8,
        ['binder:expression_statement'] = 5, ['missing:declaration_command'] = 3,
        ['missing:if_statement'] = 2, ['extra:for_statement'] = 2, ['missing:command'] = 2,
        ['missing:declaration'] = 2, ['missing:return_statement'] = 2,
        ['missing:variable_assignment'] = 2, ['binder:declaration_command'] = 1,
        ['missing:list'] = 1, ['missing:var_declaration'] = 1 },
    grocy = { total = 239, ['missing:return_statement'] = 100, ['missing:expression_statement'] = 91,
        ['binder:expression_statement'] = 31, ['missing:foreach_statement'] = 6,
        ['missing:pair'] = 6, ['missing:if_statement'] = 4,
        ['both:expression_statement'] = 1 },
    haskell = { total = 0 },
    jquery = { total = 22, ['binder:expression_statement'] = 18, ['binder:variable_declaration'] = 3,
        ['missing:if_statement'] = 1 },
    -- recalib @ CART-0405 (the ruby grid's findings, applied everywhere): 975 -> 305.
    -- extra:try_with_resources_statement 670 -> 0. flow blanks a TRY head's def/use since
    -- CART-0386 (a container is not a computation) and the expression harvest did not know;
    -- it does now, by MIRRORING flow's rule rather than re-deriving it. The same change also
    -- cleared the head's `rmw`, which the blanking had left behind — a row's read census is
    -- `use u rmw`, so half the names survived a zeroing that meant to remove all of them.
    libs = { total = 205, ['missing:declaration'] = 133, ['binder:class_declaration'] = 21,
        ['missing:local_variable_declaration'] = 16, ['binder:return_statement'] = 13,
        ['binder:block'] = 6, ['missing:match_arm'] = 5,
        ['binder:local_variable_declaration'] = 3, ['binder:call_expression'] = 2,
        ['binder:for_statement'] = 2, ['extra:match_block'] = 2,
        ['extra:match_expression'] = 2 },
    mootools = { total = 17, ['binder:expression_statement'] = 13, ['binder:for_statement'] = 2,
        ['binder:sequence_expression'] = 1, ['binder:variable_declaration'] = 1 },
    nio = { total = 34, ['missing:return_statement'] = 15, ['missing:variable_declaration'] = 9,
        ['missing:assignment_statement'] = 6, ['missing:function_call'] = 4 },
    -- ★★ FIRST PIN EVER (CART-0423). odin could not be censused at ALL until the per-file
    -- parse landed — it ran out of memory at subject 4150 of 32370 and reported nothing,
    -- so this corpus has been listed, extracted and pinned for `counts` while contributing
    -- ZERO to the expression census since the census shipped. 16585 is not a regression;
    -- it is the first sight of a number that was always there.
    -- ★ READ IT WITH CART-0427 IN HAND: 66.7% of odin's 32370 subjects live in six
    -- GENERATED files, so these classes are weighted by a code generator's idiom, not by
    -- odin's. `missing:assignment_statement` 6490 is the same wound as CART-0304 (odin
    -- harvested 0 of 23178 assignments) seen from the census side.
    odin = { total = 16585, ['missing:assignment_statement'] = 6490,
        ['missing:member_expression'] = 3783, ['missing:switch_case'] = 3553,
        ['missing:call_expression'] = 668, ['missing:return_statement'] = 522,
        ['missing:if_statement'] = 517, ['missing:defer_statement'] = 221,
        ['missing:switch_statement'] = 186, ['missing:block'] = 134,
        ['missing:when_statement'] = 120, ['both:switch_statement'] = 83,
        ['extra:switch_statement'] = 76, ['missing:for_statement'] = 54,
        ['missing:or_return_expression'] = 47, ['missing:label_statement'] = 33,
        ['missing:update_statement'] = 30, ['missing:struct_declaration'] = 22,
        ['binder:expression_statement'] = 16, ['missing:else_if_clause'] = 7,
        ['missing:const_declaration'] = 6, ['missing:binary_expression'] = 3,
        ['missing:case_statement'] = 2, ['missing:or_break_expression'] = 2,
        ['missing:variable_assignment'] = 2, ['missing:variable_declaration'] = 2,
        ['binder:for_statement'] = 1, ['both:else_if_clause'] = 1,
        ['missing:case_item'] = 1, ['missing:declaration_command'] = 1,
        ['missing:range_expression'] = 1, ['missing:var_declaration'] = 1 },
    php = { total = 857, ['binder:expression_statement'] = 437, ['missing:pair'] = 140,
        ['missing:foreach_statement'] = 139, ['missing:expression_statement'] = 103,
        ['missing:return_statement'] = 31, ['missing:if_statement'] = 5,
        ['missing:echo_statement'] = 2 },
    -- recalib 2026-09-01 (AN INTERPOLATED STRING IS NOT A LITERAL, CART-0665): the change
    -- was made for bash and every interpolating language gained from it, which is the tell
    -- that it is a rule and not a bash shim.
    -- python 7 -> 4: an f-string's `interpolation` kid now yields its reads.
    python = { total = 4, ['binder:expression_statement'] = 3,
        ['missing:subscript'] = 1 },
    -- recalib @ CART-0405: as ruby.
    -- rails 463 -> 32, the largest fall of any corpus here: ruby interpolation is
    -- everywhere in a rails app, and `missing:string` 83 -> 0 took `assignment` and `call`
    -- with it — the reads were inside the strings those rows are made of.
    rails = { total = 32, ['missing:conditional'] = 28, ['missing:assignment'] = 2,
        ['missing:call'] = 1, ['missing:while_modifier'] = 1 },
    -- recalib @ CART-0405: as ruby.
    -- rspec 10 -> 0. A census reaching zero is worth pausing on rather than celebrating:
    -- it means every row this corpus has, the IR and du now agree about — not that the
    -- corpus is fully modelled.
    rspec = { total = 0 },
    -- recalib @ CART-0405: the `begin` head no longer harvests its own body (see libs).
    -- ruby 336 -> 67: `missing:string` 52 -> 0 and the rows it was hiding inside went
    -- with it (call 130 -> 0, assignment 56 -> 4, binary 25 -> 0).
    ruby = { total = 67, ['missing:conditional'] = 61, ['missing:assignment'] = 4,
        ['missing:hash'] = 1, ['missing:while_modifier'] = 1 },
    rust = { total = 828, ['missing:match_arm'] = 479, ['missing:let_declaration'] = 123,
        ['extra:match_block'] = 73, ['extra:match_expression'] = 72,
        ['missing:attribute_item'] = 35, ['missing:const_item'] = 16,
        ['missing:static_item'] = 9, ['missing:case_statement'] = 5,
        ['binder:let_declaration'] = 3, ['missing:inner_attribute_item'] = 2,
        ['missing:match_block'] = 2, ['missing:match_expression'] = 2,
        ['both:match_arm'] = 1, ['both:match_block'] = 1, ['both:match_expression'] = 1,
        ['missing:case_item'] = 1, ['missing:pipeline'] = 1,
        ['missing:struct_expression'] = 1, ['missing:variable_assignment'] = 1 },
    synjava = { total = 0 },
    synjs = { total = 10, ['binder:statement_block'] = 10 },
    synlua = { total = 49, ['missing:variable_declaration'] = 35, ['missing:function_call'] = 6,
        ['missing:return_statement'] = 4, ['missing:elseif_statement'] = 2,
        ['missing:cond'] = 1, ['missing:if_statement'] = 1 },
    -- ★★ FIRST PIN EVER (CART-0423), and the FOURTH and last of the corpora that could not
    -- be censused at all. v8 is also the one that says the per-file parse was not merely a
    -- big-file fix: it never hit a CodeGen.zig-sized file, it died on 146k subjects.
    -- ⚠ READ `total` WITH THE DISTINCT COUNT BESIDE IT: 165533 instances over 10274 DISTINCT
    -- rows — 16.1×, the highest of any corpus. That is CART-0410's wound at full size: a .h
    -- C++ header parsed as C becomes ONE function_definition that every method in the header
    -- resolves to, so a row is counted once per enclosing function. `missing:preproc_
    -- function_def` is 77685 instances over 1403 rows (55×) and `binder:declaration` 30547
    -- over 3859 (7.9×) — the inflation is PER-CLASS, so this list is NOT a priority order.
    -- Rank v8's work by the distinct column the CLI prints, never by these numbers.
    -- Pinned on instances anyway, because every other pin is, and re-keying would move all
    -- twenty-three at once for a reporting change.
    -- ★ RE-PINNED @ CART-0404's C/C++ half. `binder:declaration` 30547 -> 11289 instances,
    -- and 3859 -> 462 DISTINCT rows — this was the ticket's own named gate, an 88% cut of the
    -- class it was opened for. `both:declaration` 156 -> 0.
    -- ★ AND `missing:declaration` ROSE BY EXACTLY 156, WHICH IS NOT A REGRESSION: it is the
    -- same 156 rows, moved from `both` to `missing`. A two-sided disagreement became
    -- one-sided — flat in COUNT and strictly better in KIND, the same shape CART-0405
    -- recorded on bash. Reading the rise without the fall would have called this a loss.
    v8 = { total = 146275, ['missing:preproc_function_def'] = 77685,
        ['binder:declaration'] = 11289, ['missing:declaration'] = 20947,
        ['binder:compound_statement'] = 17461, ['missing:expression_statement'] = 7157,
        ['missing:if_statement'] = 4169, ['missing:case_statement'] = 3643,
        ['missing:preproc_def'] = 1871, ['binder:if_statement'] = 1470,
        ['missing:for_range_loop'] = 192,
        ['binder:namespace_definition'] = 133, ['missing:compound_statement'] = 47,
        ['binder:ERROR'] = 37, ['both:expression_statement'] = 35,
        ['binder:while_statement'] = 33, ['binder:expression_statement'] = 27,
        ['both:compound_statement'] = 24, ['extra:if_statement'] = 14,
        ['missing:return_statement'] = 12, ['binder:for_statement'] = 10,
        ['both:if_statement'] = 7, ['binder:template_declaration'] = 6,
        ['missing:static_assert_declaration'] = 4,
        ['missing:assignment_expression'] = 1, ['missing:attributed_statement'] = 1 },
    -- ★★ FIRST PIN EVER (CART-0423). wow is the third corpus the per-file parse unlocked.
    -- ★ AND IT IS THE ONE THAT SAYS THE FIX IS NOT ABOUT BIG FILES. wow is 353 addons of
    -- ordinary-sized Lua — it died on VOLUME (39748 subjects), not on any single enormous
    -- file the way zig did, and the same change carries both. Its shape is also the
    -- cleanest evidence that the census's classes are language-idiom-driven rather than
    -- size-driven: three `missing` classes hold 99% of it, and `missing:function_call` 945
    -- is the string-dispatch idiom [[wow-addons-corpus]] keeps this corpus for.
    -- ⚠⚠ AND NOTHING SWEEPS THIS PIN — I ADDED IT AND THEN MEASURED THAT (CART-0428).
    -- matrix's default roster is "every corpus with PINNED EXPECTED COUNTS" (matrix.lua:627,
    -- gated on `v.expected`). corpora.lua leaves wow's `counts` unpinned DELIBERATELY,
    -- because it is a LOCAL addon tree that drifts as addons update. So wow is not in the
    -- 31-corpus sweep, and this number is only ever compared when a human names wow.
    -- ★ WHICH MEANS AN EQUALITY PIN IS THE WRONG SHAPE HERE, not merely an unswept one.
    -- matrix.lua:632 already argues it for `self`: a LIVING corpus goes red by DRIFT rather
    -- than by regression, "the worst kind of gate, because the only way to green it is to
    -- re-save, which blesses whatever drifted unread" — and the answer there was a RATCHET
    -- (a count that may not RISE), asserted by dogfood.lua. That is what wow wants too.
    -- Kept as a recorded number, NOT presented as gated, until someone builds the ratchet.
    wow = { total = 3261, ['missing:assignment_statement'] = 1367,
        ['missing:function_call'] = 945, ['missing:variable_declaration'] = 905,
        ['missing:return_statement'] = 42, ['missing:for_generic_clause'] = 1,
        ['missing:for_statement'] = 1 },
    -- ★★ FIRST PIN EVER (CART-0423), same story as odin: zig died at subject 570 of 8590
    -- and reported nothing, so its 16088 disagreements have been invisible since the
    -- census shipped. NOT a regression — a first sighting.
    -- ★ AND THE HEADLINE IS ONE CLASS: `binder:variable_declaration` = 14002, 87% of the
    -- whole corpus, over 14002 DISTINCT rows (1.0×, no inflation — this is real breadth).
    -- ★★ IT IS CART-0404 IN A THIRD LANGUAGE, not a destructuring gap. PROBED, because the
    -- class NAME invites the wrong story: every instance is `missing={} extra={<the declared
    -- name>}` on an ordinary single-name declaration — `const ip = &zcu.intern_pool;`,
    -- `var n: usize = 0;`. The row's own TARGET is being harvested as a READ. That is the
    -- INVERSE of the vanished-binder family (CART-0358 / CART-0420), where a binder's names
    -- were LOST; here du is right and the IR over-reads. zig has essentially no correct
    -- declaration handling, which is why one class is 87% of a corpus.
    -- Pinned, not asserted zero, for rowcensus's reason: an open class is not a reason to
    -- keep the count invisible.
    -- ★ RE-PINNED @ CART-0404's zig half: total 16088 -> 3456, `binder:variable_declaration`
    -- 14002 -> 1371, `missing:variable_declaration` 237 -> 236. Every other class UNMOVED and
    -- NO NEW CLASS APPEARED — which is the check this ticket's first C/C++ cut failed, where
    -- fixing the aimed-at class minted 139174 rows of another and the NET went up 56%.
    -- ★ RE-PINNED AGAIN @ CART-0431, du's half: 3456 -> 1495, and 16088 -> 1495 across the
    -- pair — 90.7% of this corpus's census, from two changes that had to be made in that
    -- ORDER. TEN classes moved, ALL DOWNWARD, two GONE, and again no new class appeared.
    -- ★★ AND ONLY ONE OF THE TEN IS THE CLASS EITHER TICKET NAMED. `binder:block_expression`
    -- 498 -> 285, `binder:switch_case` 298 -> 132, `binder:block` 94 -> 58: a region row's
    -- def set was inflated by the declarations INSIDE it, because the same `k = 4` rule
    -- decided def-position for every identifier the walk reached. A defect measured on one
    -- node type was never confined to it, and the count that names a class is a LOWER bound
    -- on the change fixing it makes.
    -- ★ The 74 that remain are pinned, NOT asserted zero — the residual shapes have not been
    -- read yet, and a class nobody has looked at is exactly what this pin exists to keep
    -- visible rather than to bless.
    zig = { total = 1495, ['extra:switch_expression'] = 812,
        ['binder:block_expression'] = 285, ['binder:switch_case'] = 132,
        ['binder:variable_declaration'] = 74, ['binder:block'] = 58,
        ['binder:if_statement'] = 40,
        ['binder:declaration'] = 25, ['binder:comptime_statement'] = 13,
        ['extra:for_statement'] = 13, ['extra:while_statement'] = 12,
        ['extra:if_statement'] = 11, ['binder:expression_statement'] = 8,
        ['binder:compound_statement'] = 4, ['binder:errdefer_statement'] = 2,
        ['extra:identifier'] = 2, ['binder:defer_statement'] = 1,
        ['binder:for_range_loop'] = 1,
        ['extra:while_expression'] = 1, ['missing:expression_statement'] = 1 },
}

-- ── THE RUNNER (CART-0409) ──────────────────────────────────────────────────────────────
-- The header above documented this CLI from the day the module shipped. IT DID NOT EXIST:
-- the file was `local M = {}` … `return M`, and under `nvim -l` a module that only returns a
-- table is a SUCCESSFUL NO-OP. So the documented command printed nothing and exited 0 —
-- which from a census tool is indistinguishable from "no disagreements found". A gate that
-- cannot fire proves nothing; a gate that cannot RUN says something false.
--
-- ★ THE GUARD IS LOAD-BEARING, NOT DEFENSIVE. tools/matrix.lua:241 consumes this module by
-- `dofile`, so an unguarded script body would execute inside every `--cols expr` row, and
-- `arg` there is MATRIX's argv — it would re-extract a corpus of its own choosing mid-row.
-- Keying on arg[0] (the script nvim was pointed at) is what separates "invoked" from
-- "required": direct invocation runs, dofile stays inert, and no caller has to opt out.
local invoked = arg and arg[0]
    and vim.fn.fnamemodify(arg[0], ':p') == vim.fn.fnamemodify(
        debug.getinfo(1, 'S').source:sub(2), ':p')

if invoked then
    local here = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h')
    local bench = dofile(here .. '/bench.lua')
    bench.bootstrap()

    local target, want_lang, show, bucket, cap = nil, nil, nil, nil, 40
    local only = nil
    local i = 1
    while arg and arg[i] do
        if arg[i] == '--lang' then i = i + 1; want_lang = arg[i]
        elseif arg[i] == '--show' then i = i + 1; show = arg[i]
        elseif arg[i] == '--bucket' then i = i + 1; bucket = arg[i]
        elseif arg[i] == '--file' then i = i + 1; only = arg[i]
        elseif arg[i] == '--cap' then i = i + 1; cap = tonumber(arg[i]) or cap
        else target = arg[i] end
        i = i + 1
    end
    if not target then
        print('usage: exprcensus <corpus|dir> [--lang <l>] [--show <class>]'
            .. ' [--bucket <class>] [--file <pat>] [--cap N]')
        print('  <class> is an (axis:rowtype) key from the census, e.g. missing:declaration')
        print('  --file <pat>  SCOPE the run to files whose path matches the lua pattern.')
        print('                Filters EXTRACTION, not just the census — measured 135s -> 2.8s')
        print('                on zig. A scoped run is NOT comparable to a pin (see below).')
        os.exit(2)
    end

    local corpus = bench.corpus(target)

    -- ── --file: SCOPE THE LOOP (CART-0429) ─────────────────────────────────────────────
    -- ★★ IT HAS TO REACH EXTRACTION OR IT IS A LIE. Filtering SUBJECTS after the fact would
    -- save only the census (zig: 52.9s) and leave the extract (106.8s) — a 33% win sold as
    -- a 48× one. The provider already takes an explicit `opts.files` (workers batch with
    -- it), so the filter threads all the way down and the loop really does collapse.
    --
    -- WHY THIS EXISTS: `bench.extract` never consults the cache — correct for a GATE, since
    -- a cache can mask the bug being gated, but it means every iteration on an analyzer
    -- re-pays a full extraction. Scoping is the honest way to get a fast loop without
    -- teaching the gate path to trust a cache.
    --
    -- ⚠⚠ AND A SCOPED RUN IS NOT A PIN. A subset extraction has INCOMPLETE CROSS-FILE
    -- RESOLUTION: a name defined in an excluded file does not resolve, and node KINDS can
    -- depend on that (a function attached to a class declared elsewhere). The per-row gate
    -- verdict is intra-file — `expr.of` re-parses the enclosing file and `expr.gate`
    -- compares reads against du over the same node — so a file's own rows are expected to
    -- match its share of the full run, and that is VERIFIED below rather than assumed.
    -- What must never happen is a scoped total being read as a corpus number, so the pin
    -- comparison is REFUSED outright and the banner says SCOPED on every line that matters.
    local opts
    if only then
        local ts = require 'cartograph.providers.treesitter'
        local all = ts.list_files(corpus.root, corpus.subdirs)
        local keep = {}
        for _, f in ipairs(all or {}) do
            if f:match(only) then keep[#keep + 1] = f end
        end
        if #keep == 0 then
            print(('--file %q matched NONE of %d files under %s')
                :format(only, #(all or {}), corpus.root))
            print('  (it is a LUA PATTERN, not a glob: use "%.zig$" not "*.zig")')
            os.exit(2)
        end
        print(('SCOPED: --file %q matched %d of %d files — NOT a corpus census, pin'
            .. ' comparison refused'):format(only, #keep, #(all or {})))
        opts = { files = keep }
    end

    local data = bench.extract(target, opts)

    -- the same SHIM the matrix column builds — node lookup + file content over the shared
    -- extract, not a second ingest. Kept identical on purpose: a sampling tool that saw a
    -- different store than the pinned column would answer a different question.
    local nidx = {}
    for _, nn in ipairs(data.nodes or {}) do nidx[nn.id] = nn end
    local cf, cl
    local shim = { data = data, node = function (id) return nidx[id] end,
        content = function (n)
            if not (n and n.file) then return nil end
            if n.file ~= cf then
                cf = n.file
                local p = corpus.root .. '/' .. n.file
                cl = vim.fn.filereadable(p) == 1 and vim.fn.readfile(p) or nil
            end
            return cl
        end }

    local r = M.check(shim)

    -- --lang filters INSTANCES by the provider's own answer for the file, never by
    -- extension: `lang_of` is what decided the parse, so anything else is a second opinion.
    if want_lang then
        local ts = require 'cartograph.providers.treesitter'
        local keep, cats = {}, { total = 0 }
        for key, list in pairs(r.instances) do
            for _, it in ipairs(list) do
                if ts.lang_of(corpus.root .. '/' .. (it.file or '')) == want_lang then
                    local L = keep[key]; if not L then L = {}; keep[key] = L end
                    L[#L + 1] = it
                    cats[key] = (cats[key] or 0) + 1
                    cats.total = cats.total + 1
                end
            end
        end
        r.instances, r.cats = keep, cats
    end

    local dist = M.distinct(r.instances)
    print(('%s  fns=%d methods=%d%s'):format(target, r.fns, r.methods,
        want_lang and ('  [lang=' .. want_lang .. ']') or ''))
    -- ★ THE CACHE'S HIT RATE IS PRINTED, NOT ASSUMED (CART-0423). The by-file walk and the
    -- one-entry parse cache are useless apart, and a silent no-hit degrades to EXACTLY the
    -- old cost — which is how four corpora came to be unrunnable without anyone noticing.
    -- `miss` is the number of PARSES: it should track the file count, and a miss count
    -- near the subject count means the grouping stopped working. That is the whole proof.
    if r.parse then
        print(('  parse: %d hit / %d miss (parses) over %d file(s)%s / %d concat'
            .. ' — %.1f%% reuse'):format(
            r.parse.hit, r.parse.miss, r.parse.files or 0,
            (r.parse.nofile or 0) > 0
                and (' + %d subject(s) with no file'):format(r.parse.nofile) or '',
            r.parse.concat,
            100 * r.parse.hit / math.max(1, r.parse.hit + r.parse.miss)))
    end
    print('  ' .. M.census_distinct(r.cats, dist))
    if (r.cats.total or 0) > (dist.total or 0) then
        print(('  ↑ %d instance(s) over %d distinct row(s) — %.1f× — a row is counted once'
            .. ' per enclosing function'):format(r.cats.total, dist.total,
            r.cats.total / math.max(1, dist.total)))
    end

    -- ⚠ `only` REFUSES the pin, and refusing is the whole point: a scoped run's total is a
    -- statement about the files it saw, and the pin is a statement about the corpus. Letting
    -- them meet would print "PINNED: 22 class(es) moved" for a run that deliberately looked
    -- at two files — a red gate that means nothing, which is worse than no gate at all.
    if M.EXPECTED[target] and not want_lang and not only then
        local d = M.diff(r.cats, M.EXPECTED[target])
        print(#d == 0 and '  PINNED: matches' or ('  PINNED: %d class(es) moved'):format(#d))
        for _, l in ipairs(d) do print(l) end
    elseif M.EXPECTED[target] and only then
        print('  PINNED: not compared — this run is SCOPED (--file)')
    end

    -- reading the SOURCE LINE is the point of --show: the census says "10667 declarations",
    -- and a declaration's SHAPE is what decides which branch of the harvest owns it.
    local function srcline(it)
        local p = corpus.root .. '/' .. (it.file or '')
        if vim.fn.filereadable(p) ~= 1 then return nil end
        local ls = vim.fn.readfile(p, '', it.l or 0)
        return ls and ls[it.l] and vim.trim(ls[it.l]) or nil
    end

    if show then
        for _, l in ipairs(M.show_instances(r.instances[show], show, cap)) do print(l) end
        print('')
        print('── with source ──')
        for k = 1, math.min(cap, #(r.instances[show] or {})) do
            local it = r.instances[show][k]
            print(('%s:%d  %s'):format(it.file, it.l, srcline(it) or '<unreadable>'))
        end
    end

    -- ★ BUCKETING IS A SAMPLING AID, NOT AN ORACLE. It normalises the source line
    -- (identifiers→x, numbers→0, strings→s) and counts shapes, so a 10000-instance class
    -- names its own top forms instead of being read 40 at a time. It can merge genuinely
    -- different constructs that happen to normalise alike — which is why the shapes it
    -- surfaces get PROBED DIRECTLY before anything is changed. The last cut on CART-0404
    -- failed by reasoning about shapes nobody had counted.
    if bucket then
        local list = r.instances[bucket] or {}
        local tally, ex = {}, {}
        for _, it in ipairs(list) do
            local s = srcline(it)
            if s then
                local norm = s:gsub('"[^"]*"', 's'):gsub("'[^']*'", 's')
                    :gsub('%d+', '0'):gsub('[%a_][%w_]*', 'x'):gsub('%s+', ' ')
                tally[norm] = (tally[norm] or 0) + 1
                if not ex[norm] then ex[norm] = ('%s:%d  %s'):format(it.file, it.l, s) end
            end
        end
        local ord = {}
        for k, v in pairs(tally) do ord[#ord + 1] = { k = k, v = v } end
        table.sort(ord, function (a, b)
            if a.v ~= b.v then return a.v > b.v end
            return a.k < b.k -- ties by shape, so the report is deterministic
        end)
        print('')
        print(('── %s: %d instance(s) in %d shape(s) ──'):format(bucket, #list, #ord))
        for k = 1, math.min(cap, #ord) do
            print(('%6d  %s'):format(ord[k].v, ord[k].k))
            print(('        e.g. %s'):format(ex[ord[k].k]))
        end
    end
end

return M
