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
    bash = { total = 5735, ['missing:command'] = 1126, ['binder:declaration_command'] = 916,
        ['missing:variable_assignment'] = 897, ['missing:if_statement'] = 518,
        ['missing:list'] = 338, ['both:if_statement'] = 277, ['both:declaration_command'] = 273,
        ['missing:case_item'] = 199, ['missing:redirected_statement'] = 156, ['both:list'] = 151,
        ['both:elif_clause'] = 133, ['missing:test_command'] = 94,
        ['missing:c_style_for_statement'] = 88, ['binder:if_statement'] = 87,
        ['missing:elif_clause'] = 86, ['binder:list'] = 84, ['missing:case_statement'] = 62,
        ['both:do_group'] = 45, ['binder:elif_clause'] = 33, ['both:for_statement'] = 31,
        ['missing:do_group'] = 27, ['both:redirected_statement'] = 25,
        ['missing:for_statement'] = 16, ['binder:do_group'] = 11, ['binder:for_statement'] = 9,
        ['both:while_statement'] = 9, ['missing:string'] = 9, ['both:command'] = 7,
        ['binder:while_statement'] = 5, ['missing:pipeline'] = 5, ['binder:command'] = 3,
        ['binder:redirected_statement'] = 2, ['extra:for_statement'] = 2,
        ['extra:if_statement'] = 2, ['extra:while_statement'] = 2,
        ['missing:negated_command'] = 2, ['both:pipeline'] = 1, ['both:variable_assignment'] = 1,
        ['both:variable_assignments'] = 1, ['missing:command_substitution'] = 1,
        ['missing:while_statement'] = 1 },
    -- recalib @ CART-0404: 114626 -> 53418, the single biggest cut this column has seen.
    -- `binder:declaration` 75190 -> 3313: C's `declaration` is a LOCAL DECLARATION and the IR
    -- did not know it, so every declared NAME read as a use while du called it a def.
    -- ★ THE FIRST CUT WAS MEASURED WORSE AND KEPT ANYWAY WOULD HAVE BEEN A DISASTER: adding
    -- `declaration` to the branch routed EVERY C/C++ declaration into a fallback that keeps
    -- NAMES and drops everything else, so `Foo f(x);` lost the read of `x` — binder 75190->102
    -- and missing 0->139174, a NET WORSE total from a change that was right about its target.
    -- The fallback now claims a row only when every named child is ACCOUNTED FOR; anything
    -- else falls through to the generic `?` path, which keeps the names. AN HONEST UNKNOWN
    -- BEATS A CONFIDENT PARTIAL ANSWER. Residual missing:declaration 10667 + binder 3313 is
    -- the C++ declarator long tail — still the next-biggest class, still on CART-0404.
    cpp = { total = 53418, ['extra:expression_statement'] = 21548,
        ['missing:declaration'] = 10667, ['extra:if_statement'] = 10557,
        ['binder:declaration'] = 3313, ['extra:declaration'] = 2774,
        ['extra:for_statement'] = 733, ['binder:expression_statement'] = 556,
        ['binder:if_statement'] = 520, ['extra:return_statement'] = 381,
        ['missing:preproc_if'] = 381, ['extra:compound_statement'] = 342,
        ['extra:preproc_ifdef'] = 327, ['missing:preproc_def'] = 287,
        ['binder:comma_expression'] = 211, ['extra:switch_statement'] = 208,
        ['extra:assignment_expression'] = 136, ['binder:for_statement'] = 126,
        ['extra:while_statement'] = 112, ['binder:preproc_ifdef'] = 67,
        ['binder:compound_statement'] = 52, ['missing:expression_statement'] = 27,
        ['extra:cond'] = 24, ['missing:preproc_function_def'] = 22,
        ['extra:call_expression'] = 14, ['binder:assignment_expression'] = 8,
        ['both:declaration_command'] = 5, ['both:expression_statement'] = 4,
        ['extra:comma_expression'] = 4, ['missing:command'] = 4, ['both:declaration'] = 3,
        ['binder:declaration_command'] = 1, ['both:pipeline'] = 1, ['missing:if_statement'] = 1,
        ['missing:list'] = 1, ['missing:variable_assignment'] = 1 },
    -- recalib @ CART-0404: 45821 -> 33188 (same fix; see the cpp note).
    cppmodern = { total = 33188, ['extra:expression_statement'] = 23095,
        ['extra:if_statement'] = 4024, ['extra:declaration'] = 1923,
        ['missing:declaration'] = 1400, ['binder:ERROR'] = 686, ['binder:if_statement'] = 666,
        ['extra:return_statement'] = 436, ['binder:declaration'] = 412,
        ['extra:for_statement'] = 176, ['extra:for_range_loop'] = 152,
        ['binder:expression_statement'] = 106, ['extra:switch_statement'] = 30,
        ['extra:while_statement'] = 21, ['extra:ERROR'] = 20, ['extra:throw_statement'] = 13,
        ['extra:compound_statement'] = 11, ['both:declaration'] = 4, ['missing:preproc_if'] = 3,
        ['extra:assignment_expression'] = 2, ['missing:for_range_loop'] = 2,
        ['missing:if_statement'] = 2, ['binder:preproc_ifdef'] = 1, ['both:if_statement'] = 1,
        ['extra:preproc_ifdef'] = 1, ['missing:expression_statement'] = 1 },
    go = { total = 35668, ['extra:expression_statement'] = 11245,
        ['extra:short_var_declaration'] = 7713, ['extra:if_statement'] = 4388,
        ['extra:return_statement'] = 3769, ['extra:assignment_statement'] = 2879,
        ['both:assignment_statement'] = 1536, ['missing:assignment_statement'] = 1196,
        ['extra:for_statement'] = 732, ['extra:range_clause'] = 543,
        ['extra:expression_case'] = 340, ['extra:defer_statement'] = 265,
        ['extra:type_case'] = 213, ['extra:expression_switch_statement'] = 153,
        ['extra:variable_declaration'] = 105, ['extra:type_switch_statement'] = 104,
        ['extra:call_expression'] = 84, ['missing:for_clause'] = 52, ['extra:for_clause'] = 42,
        ['extra:var_declaration'] = 42, ['extra:declaration'] = 31, ['extra:inc_statement'] = 31,
        ['extra:go_statement'] = 27, ['extra:lexical_declaration'] = 25,
        ['extra:communication_case'] = 23, ['binder:expression_statement'] = 13,
        ['extra:select_statement'] = 11, ['extra:binary_expression'] = 9, ['extra:block'] = 9,
        ['missing:send_statement'] = 9, ['extra:dec_statement'] = 8,
        ['binder:variable_declaration'] = 7, ['both:for_clause'] = 6,
        ['extra:throw_statement'] = 6, ['extra:while_statement'] = 6,
        ['binder:if_statement'] = 5, ['binder:lexical_declaration'] = 5,
        ['extra:switch_case'] = 5, ['extra:switch_statement'] = 5, ['extra:object'] = 4,
        ['binder:declaration_command'] = 3, ['both:declaration_command'] = 3,
        ['extra:sequence_expression'] = 2, ['missing:command'] = 2, ['missing:declaration'] = 2,
        ['missing:variable_assignment'] = 2, ['binder:for_statement'] = 1,
        ['binder:while_statement'] = 1, ['both:if_statement'] = 1, ['both:list'] = 1,
        ['extra:for_in_statement'] = 1, ['extra:member_expression'] = 1,
        ['missing:expression_statement'] = 1, ['missing:if_statement'] = 1 },
    grocy = { total = 4742, ['extra:expression_statement'] = 3290, ['extra:if_statement'] = 670,
        ['extra:variable_declaration'] = 510, ['missing:return_statement'] = 100,
        ['missing:expression_statement'] = 91, ['extra:return_statement'] = 27,
        ['binder:expression_statement'] = 13, ['binder:variable_declaration'] = 12,
        ['extra:call_expression'] = 6, ['missing:foreach_statement'] = 6, ['missing:pair'] = 6,
        ['both:if_statement'] = 4, ['binder:if_statement'] = 3,
        ['extra:lexical_declaration'] = 2, ['binder:return_statement'] = 1,
        ['both:expression_statement'] = 1 },
    haskell = { total = 2, ['binder:expression_statement'] = 1, ['extra:if_statement'] = 1 },
    jquery = { total = 1780, ['extra:expression_statement'] = 948, ['extra:if_statement'] = 309,
        ['extra:return_statement'] = 273, ['extra:variable_declaration'] = 132,
        ['binder:expression_statement'] = 33, ['binder:variable_declaration'] = 17,
        ['extra:for_statement'] = 15, ['extra:while_statement'] = 11,
        ['binder:if_statement'] = 10, ['binder:while_statement'] = 10,
        ['extra:assignment_expression'] = 7, ['extra:for_in_statement'] = 6,
        ['binder:for_statement'] = 4, ['extra:sequence_expression'] = 3,
        ['binder:return_statement'] = 1, ['both:if_statement'] = 1 },
    -- recalib @ CART-0404: 2230 -> 975 — libs carries .c/.rs files too.
    libs = { total = 975, ['extra:try_with_resources_statement'] = 670,
        ['missing:declaration'] = 129, ['extra:declaration'] = 23,
        ['binder:class_declaration'] = 21, ['extra:expression_statement'] = 21,
        ['binder:for_statement'] = 18, ['binder:while_statement'] = 17,
        ['missing:local_variable_declaration'] = 16, ['binder:return_statement'] = 13,
        ['binder:block'] = 10, ['binder:local_variable_declaration'] = 8,
        ['missing:expression_statement'] = 5, ['extra:call_expression'] = 4,
        ['missing:match_arm'] = 3, ['binder:comma_expression'] = 2, ['binder:cond'] = 2,
        ['both:match_arm'] = 2, ['extra:if_expression'] = 2, ['extra:match_block'] = 2,
        ['extra:match_expression'] = 2, ['missing:preproc_if'] = 2, ['binder:if_statement'] = 1,
        ['binder:preproc_ifdef'] = 1, ['extra:return_statement'] = 1 },
    mootools = { total = 1232, ['extra:expression_statement'] = 539,
        ['extra:if_statement'] = 219, ['extra:return_statement'] = 196,
        ['extra:variable_declaration'] = 175, ['extra:for_statement'] = 38,
        ['binder:variable_declaration'] = 26, ['extra:for_in_statement'] = 16,
        ['binder:expression_statement'] = 10, ['binder:if_statement'] = 3,
        ['extra:switch_statement'] = 3, ['extra:while_statement'] = 3,
        ['extra:assignment_expression'] = 2, ['binder:for_statement'] = 1,
        ['binder:sequence_expression'] = 1 },
    nio = { total = 34, ['missing:return_statement'] = 15, ['missing:variable_declaration'] = 9,
        ['missing:assignment_statement'] = 6, ['missing:function_call'] = 4 },
    php = { total = 967, ['binder:expression_statement'] = 440, ['missing:pair'] = 140,
        ['missing:foreach_statement'] = 139, ['missing:expression_statement'] = 99,
        ['binder:while_statement'] = 84, ['missing:return_statement'] = 22,
        ['binder:if_statement'] = 16, ['both:return_statement'] = 9,
        ['extra:expression_statement'] = 7, ['both:if_statement'] = 5,
        ['both:expression_statement'] = 4, ['both:echo_statement'] = 1,
        ['missing:echo_statement'] = 1 },
    python = { total = 341, ['extra:expression_statement'] = 231,
        ['extra:variable_declaration'] = 72, ['extra:if_statement'] = 18,
        ['extra:return_statement'] = 8, ['binder:expression_statement'] = 5,
        ['missing:expression_statement'] = 3, ['binder:variable_declaration'] = 1,
        ['extra:for_in_statement'] = 1, ['extra:for_statement'] = 1, ['missing:subscript'] = 1 },
    rails = { total = 641, ['missing:assignment'] = 147, ['missing:call'] = 138,
        ['missing:string'] = 83, ['binder:if'] = 55, ['binder:if_modifier'] = 49,
        ['missing:binary'] = 40, ['extra:begin'] = 35, ['missing:conditional'] = 28,
        ['binder:unless_modifier'] = 13, ['missing:if_modifier'] = 11,
        ['missing:operator_assignment'] = 11, ['binder:elsif'] = 5, ['binder:unless'] = 5,
        ['binder:operator_assignment'] = 3, ['missing:hash'] = 3, ['missing:if'] = 3,
        ['missing:return'] = 3, ['missing:heredoc_body'] = 2, ['missing:unless_modifier'] = 2,
        ['both:if'] = 1, ['both:if_modifier'] = 1, ['missing:unary'] = 1,
        ['missing:while_modifier'] = 1, ['missing:yield'] = 1 },
    rspec = { total = 11, ['missing:assignment'] = 5, ['missing:call'] = 4, ['binder:call'] = 1,
        ['missing:string'] = 1 },
    ruby = { total = 435, ['missing:call'] = 130, ['missing:conditional'] = 61,
        ['missing:assignment'] = 56, ['missing:string'] = 52, ['extra:begin'] = 32,
        ['binder:if'] = 26, ['missing:binary'] = 25, ['missing:if_modifier'] = 12,
        ['binder:if_modifier'] = 7, ['binder:while'] = 6, ['binder:elsif'] = 5,
        ['missing:unless_modifier'] = 5, ['binder:assignment'] = 4, ['missing:unary'] = 3,
        ['both:unless_modifier'] = 2, ['missing:array'] = 2, ['missing:operator_assignment'] = 2,
        ['binder:binary'] = 1, ['binder:case'] = 1, ['missing:hash'] = 1, ['missing:return'] = 1,
        ['missing:while_modifier'] = 1 },
    rust = { total = 5525, ['extra:let_declaration'] = 1518,
        ['extra:expression_statement'] = 1501, ['extra:call_expression'] = 585,
        ['extra:if_expression'] = 558, ['both:match_arm'] = 253, ['missing:match_arm'] = 227,
        ['extra:match_expression'] = 152, ['extra:match_block'] = 132,
        ['extra:for_expression'] = 100, ['both:let_declaration'] = 90,
        ['extra:reference_expression'] = 63, ['binder:let_declaration'] = 45,
        ['extra:match_arm'] = 44, ['extra:struct_expression'] = 42,
        ['extra:binary_expression'] = 38, ['both:attribute_item'] = 35,
        ['extra:while_expression'] = 32, ['missing:let_declaration'] = 30,
        ['extra:field_expression'] = 17, ['missing:const_item'] = 16,
        ['extra:unary_expression'] = 7, ['extra:tuple_expression'] = 6,
        ['missing:static_item'] = 6, ['missing:case_statement'] = 5, ['both:match_block'] = 3,
        ['both:match_expression'] = 3, ['both:static_item'] = 3, ['extra:range_expression'] = 3,
        ['extra:try_expression'] = 3, ['both:inner_attribute_item'] = 2,
        ['binder:match_block'] = 1, ['both:struct_expression'] = 1,
        ['extra:type_cast_expression'] = 1, ['missing:case_item'] = 1, ['missing:pipeline'] = 1,
        ['missing:variable_assignment'] = 1 },
    synjava = { total = 1, ['extra:try_with_resources_statement'] = 1 },
    synjs = { total = 30, ['extra:return_statement'] = 18, ['binder:statement_block'] = 10,
        ['extra:expression_statement'] = 2 },
    synlua = { total = 49, ['missing:variable_declaration'] = 35, ['missing:function_call'] = 6,
        ['missing:return_statement'] = 4, ['missing:elseif_statement'] = 2, ['missing:cond'] = 1,
        ['missing:if_statement'] = 1 },
}

return M
