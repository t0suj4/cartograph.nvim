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

--- Census the expr self-gate over an extracted graph.
--- Returns { fns, methods, total, cats } where `cats` is the DIFFABLE map (mirrors
--- rowcensus.check / dfparity.check so a caller can treat all three identically).
---@param store table  an INGESTED store (expr.of needs content, not just nodes)
function M.check(store)
    local expr = require 'cartograph.expr'
    local cats = { total = 0 }
    local fns, methods = 0, 0
    local instances = {}
    for _, n in ipairs(store.data.nodes or {}) do
        -- ★ FUNCTIONS *AND* METHODS. The single-word restriction that hid all of this.
        if n.kind == 'function' or n.kind == 'method' then
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
    end
    return { fns = fns, methods = methods, total = cats.total, cats = cats,
        instances = instances }
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
--   binder:declaration                   CART-0404 — 1378 on elasticsearch, C/C++ only.
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
    bash = { total = 5673, ['missing:command'] = 1126, ['binder:declaration_command'] = 916,
        ['missing:variable_assignment'] = 897, ['missing:if_statement'] = 517,
        ['missing:list'] = 338, ['both:if_statement'] = 278,
        ['both:declaration_command'] = 273, ['missing:case_item'] = 199,
        ['missing:redirected_statement'] = 156, ['both:list'] = 151,
        ['both:elif_clause'] = 133, ['missing:test_command'] = 94,
        ['missing:c_style_for_statement'] = 88, ['binder:if_statement'] = 86,
        ['missing:elif_clause'] = 86, ['binder:list'] = 84, ['missing:case_statement'] = 62,
        ['both:do_group'] = 45, ['binder:elif_clause'] = 33, ['missing:do_group'] = 27,
        ['both:redirected_statement'] = 25, ['binder:do_group'] = 11,
        ['missing:for_statement'] = 10, ['missing:string'] = 9, ['both:command'] = 7,
        ['missing:pipeline'] = 5, ['binder:command'] = 3,
        ['binder:redirected_statement'] = 2, ['binder:while_statement'] = 2,
        ['extra:if_statement'] = 2, ['missing:negated_command'] = 2,
        ['missing:while_statement'] = 2, ['both:pipeline'] = 1,
        ['both:variable_assignment'] = 1, ['both:variable_assignments'] = 1,
        ['missing:command_substitution'] = 1 },
    cpp = { total = 2578, ['missing:preproc_def'] = 858, ['missing:declaration'] = 469,
        ['binder:expression_statement'] = 453, ['binder:comma_expression'] = 234,
        ['binder:if_statement'] = 229, ['binder:for_statement'] = 134,
        ['binder:declaration'] = 116, ['binder:compound_statement'] = 42,
        ['missing:preproc_function_def'] = 22, ['binder:while_statement'] = 5,
        ['both:declaration_command'] = 5, ['missing:command'] = 4,
        ['missing:expression_statement'] = 2, ['binder:declaration_command'] = 1,
        ['both:pipeline'] = 1, ['missing:if_statement'] = 1, ['missing:list'] = 1,
        ['missing:variable_assignment'] = 1 },
    cppmodern = { total = 197, ['binder:declaration'] = 108, ['binder:expression_statement'] = 41,
        ['binder:if_statement'] = 28, ['missing:declaration'] = 11,
        ['binder:while_statement'] = 3, ['binder:return_statement'] = 2,
        ['missing:for_range_loop'] = 2, ['binder:compound_statement'] = 1,
        ['both:declaration'] = 1 },
    go = { total = 2938, ['missing:assignment_statement'] = 2745, ['missing:for_clause'] = 58,
        ['extra:type_switch_statement'] = 45, ['extra:if_statement'] = 22,
        ['binder:for_statement'] = 15, ['binder:expression_statement'] = 11,
        ['binder:if_statement'] = 11, ['missing:send_statement'] = 9,
        ['binder:declaration_command'] = 3, ['binder:while_statement'] = 3,
        ['both:declaration_command'] = 3, ['extra:for_statement'] = 2,
        ['missing:command'] = 2, ['missing:declaration'] = 2, ['missing:if_statement'] = 2,
        ['missing:variable_assignment'] = 2, ['binder:sequence_expression'] = 1,
        ['both:list'] = 1, ['missing:expression_statement'] = 1 },
    grocy = { total = 248, ['missing:return_statement'] = 100, ['missing:expression_statement'] = 91,
        ['binder:expression_statement'] = 36, ['missing:foreach_statement'] = 6,
        ['missing:pair'] = 6, ['missing:if_statement'] = 4, ['binder:if_statement'] = 3,
        ['binder:return_statement'] = 1, ['both:expression_statement'] = 1 },
    haskell = { total = 1, ['binder:expression_statement'] = 1 },
    jquery = { total = 104, ['binder:expression_statement'] = 44, ['binder:if_statement'] = 32,
        ['binder:while_statement'] = 14, ['binder:for_statement'] = 5,
        ['binder:sequence_expression'] = 3, ['binder:variable_declaration'] = 3,
        ['binder:return_statement'] = 2, ['missing:if_statement'] = 1 },
    -- recalib @ CART-0405 (the ruby grid's findings, applied everywhere): 975 -> 305.
    -- extra:try_with_resources_statement 670 -> 0. flow blanks a TRY head's def/use since
    -- CART-0386 (a container is not a computation) and the expression harvest did not know;
    -- it does now, by MIRRORING flow's rule rather than re-deriving it. The same change also
    -- cleared the head's `rmw`, which the blanking had left behind — a row's read census is
    -- `use u rmw`, so half the names survived a zeroing that meant to remove all of them.
    libs = { total = 251, ['missing:declaration'] = 133, ['binder:class_declaration'] = 21,
        ['binder:for_statement'] = 18, ['binder:while_statement'] = 17,
        ['missing:local_variable_declaration'] = 16, ['binder:return_statement'] = 13,
        ['binder:block'] = 10, ['binder:local_variable_declaration'] = 8,
        ['missing:match_arm'] = 5, ['binder:call_expression'] = 2,
        ['binder:comma_expression'] = 2, ['binder:cond'] = 2, ['extra:match_block'] = 2,
        ['extra:match_expression'] = 2 },
    mootools = { total = 21, ['binder:expression_statement'] = 17, ['binder:for_statement'] = 2,
        ['binder:sequence_expression'] = 1, ['binder:variable_declaration'] = 1 },
    nio = { total = 34, ['missing:return_statement'] = 15, ['missing:variable_declaration'] = 9,
        ['missing:assignment_statement'] = 6, ['missing:function_call'] = 4 },
    php = { total = 960, ['binder:expression_statement'] = 440, ['missing:pair'] = 140,
        ['missing:foreach_statement'] = 139, ['missing:expression_statement'] = 103,
        ['binder:while_statement'] = 84, ['missing:return_statement'] = 31,
        ['binder:if_statement'] = 16, ['missing:if_statement'] = 5,
        ['missing:echo_statement'] = 2 },
    python = { total = 10, ['binder:expression_statement'] = 6, ['missing:expression_statement'] = 3,
        ['missing:subscript'] = 1 },
    -- recalib @ CART-0405: as ruby.
    rails = { total = 540, ['missing:assignment'] = 147, ['missing:call'] = 138, ['missing:string'] = 83,
        ['binder:if'] = 55, ['missing:binary'] = 39, ['missing:conditional'] = 28,
        ['missing:operator_assignment'] = 11, ['binder:unless_modifier'] = 9,
        ['binder:elsif'] = 5, ['binder:unless'] = 5, ['binder:operator_assignment'] = 3,
        ['missing:hash'] = 3, ['missing:if'] = 3, ['missing:return'] = 3,
        ['missing:heredoc_body'] = 2, ['binder:if_modifier'] = 1, ['both:if'] = 1,
        ['missing:if_modifier'] = 1, ['missing:unary'] = 1, ['missing:while_modifier'] = 1,
        ['missing:yield'] = 1 },
    -- recalib @ CART-0405: as ruby.
    rspec = { total = 11, ['missing:assignment'] = 5, ['missing:call'] = 4, ['binder:call'] = 1,
        ['missing:string'] = 1 },
    -- recalib @ CART-0405: the `begin` head no longer harvests its own body (see libs).
    ruby = { total = 379, ['missing:call'] = 130, ['missing:conditional'] = 61, ['missing:assignment'] = 56,
        ['missing:string'] = 52, ['binder:if'] = 26, ['missing:binary'] = 25,
        ['binder:while'] = 6, ['binder:elsif'] = 5, ['binder:assignment'] = 4,
        ['missing:unary'] = 3, ['missing:array'] = 2, ['missing:operator_assignment'] = 2,
        ['missing:unless_modifier'] = 2, ['binder:binary'] = 1, ['binder:case'] = 1,
        ['missing:hash'] = 1, ['missing:return'] = 1, ['missing:while_modifier'] = 1 },
    rust = { total = 834, ['missing:match_arm'] = 477, ['missing:let_declaration'] = 123,
        ['extra:match_block'] = 73, ['extra:match_expression'] = 72,
        ['missing:attribute_item'] = 35, ['missing:const_item'] = 16,
        ['missing:static_item'] = 9, ['missing:case_statement'] = 5,
        ['binder:let_declaration'] = 4, ['both:match_arm'] = 3,
        ['binder:expression_statement'] = 2, ['missing:inner_attribute_item'] = 2,
        ['missing:match_block'] = 2, ['missing:match_expression'] = 2,
        ['binder:match_arm'] = 1, ['binder:match_block'] = 1,
        ['binder:match_expression'] = 1, ['both:match_block'] = 1,
        ['both:match_expression'] = 1, ['missing:case_item'] = 1, ['missing:pipeline'] = 1,
        ['missing:struct_expression'] = 1, ['missing:variable_assignment'] = 1 },
    synjava = { total = 0 },
    synjs = { total = 10, ['binder:statement_block'] = 10 },
    synlua = { total = 49, ['missing:variable_declaration'] = 35, ['missing:function_call'] = 6,
        ['missing:return_statement'] = 4, ['missing:elseif_statement'] = 2,
        ['missing:cond'] = 1, ['missing:if_statement'] = 1 },
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
    local i = 1
    while arg and arg[i] do
        if arg[i] == '--lang' then i = i + 1; want_lang = arg[i]
        elseif arg[i] == '--show' then i = i + 1; show = arg[i]
        elseif arg[i] == '--bucket' then i = i + 1; bucket = arg[i]
        elseif arg[i] == '--cap' then i = i + 1; cap = tonumber(arg[i]) or cap
        else target = arg[i] end
        i = i + 1
    end
    if not target then
        print('usage: exprcensus <corpus|dir> [--lang <l>] [--show <class>]'
            .. ' [--bucket <class>] [--cap N]')
        print('  <class> is an (axis:rowtype) key from the census, e.g. missing:declaration')
        os.exit(2)
    end

    local corpus = bench.corpus(target)
    local data = bench.extract(target)

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
    print('  ' .. M.census_distinct(r.cats, dist))
    if (r.cats.total or 0) > (dist.total or 0) then
        print(('  ↑ %d instance(s) over %d distinct row(s) — %.1f× — a row is counted once'
            .. ' per enclosing function'):format(r.cats.total, dist.total,
            r.cats.total / math.max(1, dist.total)))
    end

    if M.EXPECTED[target] and not want_lang then
        local d = M.diff(r.cats, M.EXPECTED[target])
        print(#d == 0 and '  PINNED: matches' or ('  PINNED: %d class(es) moved'):format(#d))
        for _, l in ipairs(d) do print(l) end
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
