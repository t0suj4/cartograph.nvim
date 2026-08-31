-- FLOW — the fine-grained statement+control model, the df successor
-- ([[cartograph-df-strangler]]). df collapses control statements' bodies into
-- one row; flow emits statements at EVERY nesting level and records a
-- CONTROL-PARENT (the region tree = CFG dominance df can't express). Increment
-- 1: the STRUCTURE only (l/kind/parent/pol), on-demand from an AST node (like
-- cfg.lua). Since shipped: fine def/use (step 2), scope-regime reaching (2b),
-- per-language config seam (2c), and the COLUMNAR FOLD (step 3, M.fold +
-- dual-mode accessors at the foot of this file). REMAINING: extraction-fusion
-- (step 4 — emit rows in collect_mentions, VERSION bump) → migrate df consumers
-- → retire df.
--
-- PARITY ORACLE: flow's TOP-LEVEL rows (parent==0) reproduce df's coarse
-- statement partition (same lines) — that is what lets df's read-contract and
-- its `.l`-span consumers (extract/trace/reorder) stay unchanged while new
-- consumers opt into the fine view.

-- @langs bash c cpp go haskell java javascript lua odin php python ruby rust scheme tsx typescript zig
-- flow is the SUBSTRATE every extracted language rides, so its claim is the whole
-- spec roster. The per-language TABLES below (BODY / CTRL / …) are the pattern that
-- makes that claim honest; a direct comparison against one grammar's node name is
-- what the language fence is looking for.

local M = {}
local tsutil = require 'cartograph.spec.tsutil'

-- COMMENTS are skipped everywhere below, and there is no single node NAME for one:
-- java/rust say line_comment/block_comment. spec/tsutil holds the union, because
-- 32 sites across this file, the extractor, expr and narrow each had their own
-- copy of the lua-only test (CART-0304).
local COMMENT = tsutil.COMMENT
-- a region body: lua `block`, C/php `compound_statement`, JS/TS `statement_block`,
-- java `switch_block` (a switch's cases live in one, and it is NOT a `block`)
local BODY = { block = true, compound_statement = true, statement_block = true,
    switch_block = true }
-- control statements: recurse into their sub-regions
local CTRL = { if_statement = true, while_statement = true, for_statement = true,
    for_numeric_statement = true, for_generic_statement = true,
    foreach_statement = true, repeat_statement = true, do_statement = true,
    switch_statement = true, match_expression = true, try_statement = true,
    expression_switch_statement = true, type_switch_statement = true,
    select_statement = true, -- go switch/select
    -- rust control is EXPRESSIONS (wrapped in expression_statement — emit
    -- unwraps); node types are rust-unique so listing them is language-safe
    if_expression = true, while_expression = true, loop_expression = true,
    for_expression = true, match_block = true,
    -- ── CART-0363, cpp + java. Same language-unique criterion as rust above, so these
    -- sit in the BASE set rather than the spec seam: a base entry reaches all THREE cfg
    -- constructions (extraction, expr.of, expr.of_module) for free, and the three-way
    -- agreement hazard is what cost part A a debugging round.
    -- ── CART-0380: CONDITIONAL COMPILATION IS CONTROL FLOW, at a different phase.
    -- `preproc_*` node types exist only in the c/cpp grammars, so this is the same
    -- language-unique criterion as rust and for_range_loop above.
    -- ★ TODAY'S MODELLING IS STRICTLY WORSE THAN A BRANCH: the body is attributed to the
    -- enclosing function AS IF UNCONDITIONAL, so `#if A / #else / #endif` reads as BOTH
    -- bodies running in sequence. Opening them as alternative branches is a sound
    -- over-approximation and it is the machinery every other conditional already gets.
    -- ★ AND IT DOES NOT NEED THE `#if` EVALUATOR. Deciding WHICH branch is live is the
    -- banked TU-walk ([[cartograph-cpp-tu-walk]]); that would NARROW this, not replace it.
    -- The ticket sat at P3 for a year on the premise that the evaluator had to come
    -- first — the cheap half was separable all along.
    -- MEASURED on 7kaa: 156 folded containers in 200 files (ctrlcensus --folded), and 383
    -- distinct rows of the expression census spread across FOUR classes, so none of them
    -- ranked (the same classification-hides-a-cause trap as CART-0402).
    preproc_if = true, preproc_ifdef = true,
    for_range_loop = true,                  -- cpp `for (auto &x : v)`
    enhanced_for_statement = true,          -- java `for (String s : xs)`
    -- ★ JAVA'S SWITCH IS `switch_expression` WHETHER OR NOT IT IS USED AS A VALUE, and its
    -- container is `switch_block`, not `block`. Both spellings had to be found by PROBE:
    -- the structural census could not flag it, because a census that asks "contains a
    -- recognised region" is blind to a node whose region spelling is also unrecognised.
    -- The same blind spot hid ruby's `then`/`do` bodies. Java switches were 100% opaque.
    switch_expression = true,
    synchronized_statement = true,          -- java `synchronized (lock) { … }`
    try_with_resources_statement = true }   -- java try-with-resources (also in TRY_T)
-- clause nodes carrying a sub-region's statements
-- POST-condition loops: the condition runs AFTER the body
local POST = { do_statement = true, repeat_statement = true }
-- PRE-condition loops (test FIRST → a zero-trip skip is feasible). do/repeat are
-- POST (tested above the back-edge); lua `do...end` is NEITHER — a plain block.
local PRELOOP = { while_statement = true, for_statement = true,
    for_numeric_statement = true, for_generic_statement = true,
    foreach_statement = true, while_expression = true, for_expression = true,
    loop_expression = true, -- rust `loop {}` = infinite (const-true, no zero-trip)
    -- CART-0363: both iterate a collection, so an EMPTY one is a zero-trip skip
    for_range_loop = true, enhanced_for_statement = true }
local TRY_T = { try_statement = true, try_with_resources_statement = true }
-- ★ CONTROL FORMS WHOSE `body` FIELD IS THE WHOLE BODY, so every OTHER named child is a
-- HEADER PART and must not be emitted as a statement that appears to run each iteration
-- (the defect part A fixed for js for-of, where `for (const x of xs)` gained two bogus
-- `identifier` rows). Their header uses still reach the control row through du(stop_body).
-- Deliberately NOT a blanket rule over CTRL: the base languages keep their current
-- modelling, wrong or not, so this cannot move a lua/php/python row (CART-0362's business).
-- try-with-resources is deliberately ABSENT — its `resources` child DEFINES variables, and
-- dropping it would lose the def. It is pre-emitted instead, exactly like a for-init.
local BODYFIELD = { for_range_loop = true, enhanced_for_statement = true,
    synchronized_statement = true }
-- ★ THE MIRROR OF BODYFIELD (CART-0380): control forms whose HEAD is exactly one FIELD, so
-- every OTHER named child is a BODY statement. Conditional compilation hangs its statements
-- DIRECTLY under the directive — there is no block — which is the ruby-`begin` shape: du's
-- type-based body stop has nothing to stop at, so the head row harvested the whole branch.
-- `false` = the form has no head at all (`#else`), which blanks it the way a TRY head is
-- blanked: a container is not a computation.
local HEADFIELD = { preproc_if = 'condition', preproc_elif = 'condition',
    preproc_ifdef = 'name', preproc_ifndef = 'name', preproc_else = false }
-- a clause whose case LABEL is a CHILD rather than a `value` field (java `switch_label`)
local CASELABEL = { switch_label = true }
-- control forms with an acquire step that runs BEFORE the head, like a three-part for's
-- init: java try-with-resources' `resources` (it defines the resource variables)
local PREFIELD = { try_with_resources_statement = 'resources' }
local CLAUSE = { else_statement = true, elseif_statement = true,
    else_clause = true, elseif_clause = true, else_if_clause = true,
    elif_clause = true, -- python elif
    case_statement = true, default_statement = true,
    expression_case = true, default_case = true,
    -- java: the classic `case 1: … break;` group and the arrow form `case 1 -> …`
    switch_block_statement_group = true, switch_rule = true,
    catch_clause = true, except_clause = true, finally_clause = true,
    -- cpp conditional-compilation alternatives (CART-0380), c/cpp-unique spellings
    preproc_elif = true, preproc_else = true }
local ELSEIF = { elseif_statement = true, elseif_clause = true,
    else_if_clause = true, elif_clause = true,
    -- cpp conditional-compilation chain links (CART-0380): `#elif` carries the next
    -- link in its own `alternative`, exactly like ruby's nested `elsif`, and `#else`
    -- is the terminal link. Routing them here gets the head row + regioned body +
    -- chain-walk for free rather than re-deriving any of it.
    preproc_elif = true, preproc_else = true } -- + python elif (ruby `if` isn't
    -- in CTRL yet, so ruby `elsif` is out of scope — left folded, parity-clean)
-- exception handlers (bind an exception var, then region a body): java/php/JS
-- `catch_clause`, python `except_clause`
local CATCH = { catch_clause = true, except_clause = true }
-- switch CASES: a label (`value` field = a use) guarding a body of statements
-- that must be REGIONED as rows (not folded into the case row). C/php/java
-- `case_statement`/`default_statement`, go `expression_case`/`default_case`.
-- IF-shaped control: the successors branch that detects an EXHAUSTIVE false arm (an
-- else/elseif) and withholds the skip edge. Declared HERE, beside the other class sets and
-- above M.classes, because a local declared after a function body is invisible inside it.
local IF_T = { if_statement = true, if_expression = true }
local CASE = { case_statement = true, default_statement = true,
    expression_case = true, default_case = true,
    switch_block_statement_group = true, switch_rule = true } -- java, both switch forms
-- switch-like heads (the switched expr is under `value` for go, `condition`
-- elsewhere; a `break` inside a case exits the switch, its join)
local SWITCH = { switch_statement = true, expression_switch_statement = true,
    type_switch_statement = true, select_statement = true }
-- SUSPENSION points (continuations, Tier 1): a `yield`/`await` suspends — control
-- may leave to the caller/scheduler HERE (a suspend edge to exit) — then RESUMES
-- at the next statement (the normal sequential successor). python `yield`/`await`,
-- JS/TS `yield_expression`/`await_expression`.
local SUSPEND = { yield = true, await = true,
    yield_expression = true, await_expression = true }

-- CONTROL TRANSFER (non-local-transfer model, [[cartograph-nonlocal-transfer]]):
-- break/continue carry an optional TARGET label; `goto` targets a label;
-- `labeled_statement` (go/java/js/c) DEFINES a label over the statement it wraps;
-- rust loops carry their own `label` child. Every such row stores the label name
-- in `s.label` — a TARGET on break/continue/goto rows, a DEFINITION elsewhere
-- (successors disambiguates by node type). def/use are UNTOUCHED (du runs as
-- before → coarse parity unchanged); `label` is orthogonal, for CFG wiring only.
local TRANSFER = { break_statement = true, continue_statement = true,
    goto_statement = true }
local LABELED = { labeled_statement = true }

-- SCOPE-REGIME classification (df-strangler step 2b): per language, which
-- declaration node types are BLOCK-scoped (the binding dies at its region's
-- end). Everything unlisted defaults to 'function' — the binding survives block
-- exit (php/python vars, JS `var`, lua globals). flow.build consumes it via
-- `cfg.regime`; the FINE reaching scan (M.reaching_cfg's scope filter) uses the
-- per-row `regime` tag to decide whether a def in a now-closed block still
-- reaches. The DATA lives with the other per-language config in the extraction
-- spec (ts.spec[lang].regime) — flow is decoupled, receiving it through the cfg
-- seam alongside pfield/df_ids/method.

local function line(n) return (select(1, n:range())) + 1 end
-- start COLUMN (1-based, matching line's convention). Carried on every fine row
-- so same-line entities — minified/generated blobs, chained one-liners — are
-- ORDERED and JUMP-LOCATABLE by (l,c); coarse stays line-only (df parity). The
-- fold's width-narrowing keeps `c` u16 normally and auto-upgrades to u32 only for
-- the extreme minified line (e.g. a 113k-col bundle). ([[cartograph-df-strangler]])
local function startcol(n) return (select(2, n:range())) + 1 end
local function txt(n, src) return vim.treesitter.get_node_text(n, src) end

-- normalise a label (rust strips leading `'`; a label node may include a `:`)
local function normlbl(s) return (vim.trim(s):gsub("^'", ""):gsub(":$", "")) end
-- the label a break/continue/goto TARGETS (its sole label operand), or nil.
-- go break: a `label_name` child; js/c: `label` field; java: a bare identifier;
-- rust: a `label` child.
local function target_label(node, src)
    local lf = node:field('label')[1]
    if lf then return normlbl(txt(lf, src)) end
    for c in node:iter_children() do
        if c:named() and not COMMENT[c:type()] then return normlbl(txt(c, src)) end
    end
    return nil
end
-- (label, wrapped statement) for a labeled_statement: `label` field (go/js/c) or
-- a leading bare identifier (java); the OTHER named child is the wrapped stmt.
local function labeled_parts(node, src)
    local lf = node:field('label')[1]
    local label = lf and normlbl(txt(lf, src)) or nil
    local inner
    for c in node:iter_children() do
        if c:named() and not COMMENT[c:type()] and c ~= lf then
            local ct = c:type()
            if not label and (ct == 'identifier' or ct == 'statement_identifier'
                or ct == 'label_name') then
                label = normlbl(txt(c, src))
            elseif not inner then inner = c end
        end
    end
    return label, inner
end
-- a loop's OWN label (rust `'outer: loop`), else nil
local function loop_label(node, src)
    for c in node:iter_children() do
        -- @langs-ok `label` is rust's (and haskell's) node; no other grammar in the
        -- roster has labelled loops at all, so there is nothing to mirror it with
        if c:type() == 'label' then return normlbl(txt(c, src)) end
    end
    return nil
end

-- constant loop condition → EDGE FEASIBILITY. `do{}while(0)` (the C one-shot
-- macro idiom) has no back-edge; `while(true)` / rust `loop` never take the
-- zero-trip or condition-exit edge (only `break` leaves). Returns true|false|nil
-- (nil = unknown → keep both edges, the sound default). Unwraps parens.
local FALSE_LIT = { ['0'] = true, ['0.0'] = true, ['false'] = true,
    ['False'] = true, ['nil'] = true, ['null'] = true }
local TRUE_LIT = { ['true'] = true, ['True'] = true, ['1'] = true }
local function const_cond(node, src)
    node = tsutil.unparen(node)
    if not node then return nil end
    local s = vim.trim(txt(node, src))
    if FALSE_LIT[s] then return false end
    if TRUE_LIT[s] then return true end
    return nil
end

-- THE NESTED-FUNCTION STOP: the walk does not descend into a nested function,
-- because a closure's interior is its own scope and its rows are not these rows.
-- Threaded per-language via `cfg.fn_types` (CART-0308); this union is the FALLBACK
-- for a caller that supplies none — the test fixtures, which are all lua.
--
-- ★ IT IS A FALLBACK, NOT A DEFAULT, and the difference matters: a union is right
-- for whichever language you last checked and silently partial for the rest. This
-- one has neither ruby's `method`, nor rust's `function_item`/`closure_expression`,
-- nor go's `func_literal`, nor odin's `procedure_declaration` — so on those
-- languages the walk descended STRAIGHT INTO nested functions and folded their
-- statements into the enclosing function's rows. Every production caller now
-- passes the language's declared set; if you are adding one, pass it.
local FN_FALLBACK = { function_definition = true, function_declaration = true,
    method_declaration = true, anonymous_function = true, arrow_function = true,
    lambda_expression = true, constructor_declaration = true }
-- def-position roots (df's dfk): the assignment left / declarator names are
-- DEFS; everything else is a USE
-- ★ THE ASSIGNMENT OPERATOR TOKENS, AND THIS MODULE OWNS THEM (CART-0431). du's
-- flat-declaration split below and the expression IR's must land on THE SAME TOKEN, so
-- `expr.lua` reads this table rather than holding its own copy: the sides then agree because
-- they ask the same question of the same node, not because someone kept two tables in step.
-- ★ Which is not a style preference — it is this exact bug's shape one level up. `=` alone
-- is not enough either: zig spells `extra_index += items.len;` as a `variable_declaration`,
-- and a scan that does not know `+=` drops the row to a fallback that reads its target.
-- (expr requires flow; flow never requires expr, so this direction has no cycle.)
M.ASSIGN_TOK = { ['='] = true, [':='] = true, ['+='] = true, ['-='] = true,
    ['*='] = true, ['/='] = true, ['%='] = true, ['||='] = true, ['&&='] = true,
    ['|='] = true, ['&='] = true, ['^='] = true, ['<<='] = true, ['>>='] = true,
    ['**='] = true, ['//='] = true, ['??='] = true, ['.='] = true }
local ASSIGN_TOK = M.ASSIGN_TOK
local ASSIGN = { assignment_statement = true, assignment = true,
    assignment_expression = true, augmented_assignment_expression = true,
    variable_assignment = true }
local DECL = { init_declarator = true, variable_declarator = true }
-- LEAF identifiers to count. NB `variable_name` (php `$x`) is a WRAPPER around
-- an inner `name` — count the inner name only (df does), else `$x` AND `x`
-- double-count; but variable_name still propagates def-position (WRAP).
local DFID = { identifier = true, name = true }

-- ★★ A BODY IS A ROLE, AND `compound_statement` IS ONE SPELLING OF IT (CART-0414).
-- Every body test here was a TYPE test, so an UNBRACED body — `if (c) x = 1;` — was not
-- recognised as a body at all and the head row walked straight into it. Both sides then
-- folded the body's name onto the head, in different categories: du as a DEF (a control
-- head that assigns something), the IR as a READ. The gate saw them disagree about the
-- CATEGORY and so caught it; nothing would have caught the leak itself, because dfparity
-- compares df against flow and both are built from this same walk.
-- MEASURED on 7kaa: 985 instances / 947 distinct rows, the largest class in the census
-- once CART-0402 stopped masking it.
--
-- ★ SO ASK THE GRAMMAR FOR THE FIELD, which is exactly the CART-0397 elsif fix one
-- construct over. Probed, and they agree: c/cpp/java/js spell the unbraced consequence
-- `consequence=expression_statement` and the unbraced loop body `body=expression_statement`;
-- php spells an if's body `body`. Hence three field names, not a guess.
local BODY_FIELDS = { 'body', 'consequence', 'alternative' }

--- The children of `node` that ARE its body, identified by FIELD rather than by type.
--- Returns an id-keyed set, or nil when there are none.
---
--- ★ A FIELD CHILD THAT IS ITSELF A CONTROL FORM OR A CLAUSE IS DELIBERATELY EXCLUDED.
--- `else if` is a NESTED if_statement in the `alternative` field (java/c/cpp/js), and its
--- CONDITION belongs to the head row — du walks it and stops at ITS body, and the IR
--- recurses it as a 'ctrlhead'. Stopping at it outright would drop that condition, which
--- is the regression CART-0405 measured when the first cut skipped the child instead of
--- recursing it (36 `extra` traded for 51 `missing` on cpp). A clause likewise owns its
--- own row. What is left is precisely the bare-statement body this exists for.
---@param ctrlset table?  the language's merged ctrl set (cls.ctrl)
---@param clauseset table? the language's merged clause set (cls.clause)
function M.body_children(node, ctrlset, clauseset)
    local CT, CL = ctrlset or CTRL, clauseset or CLAUSE
    local out
    for _, f in ipairs(BODY_FIELDS) do
        local v = node:field(f)[1]
        if v then
            local vt = v:type()
            if not CT[vt] and not CL[vt] then
                out = out or {}
                out[v:id()] = true
            end
        end
    end
    return out
end

--- The HEAD FIELD of a head-only control form, or nil when the form is not one
--- (CART-0380). Returns `false` for a form with NO head (`#else`). Exported so the
--- expression harvest asks rather than re-derives — the same reason head_binders,
--- case_labels, body_children and leaf_ids are exported.
function M.head_field(t) return HEADFIELD[t] end

--- The leaf-name set du counts as a read for a language: DFID plus that language's
--- `df_ids` extension. EXPORTED because the expression IR needs the SAME answer at
--- harvest time (CART-0402), and a private copy is how this codebase keeps growing
--- two-answers bugs — `.h` (CART-0410) and `ext_disclaim` (CART-0412) inside one
--- week, and a sixth copy of the control classes before those. One owner, asked.
---@param df_ids table?  the language's spec.df_ids (nil = the default set)
function M.leaf_ids(df_ids)
    if not df_ids then return DFID end
    local ids = {}
    for k in pairs(DFID) do ids[k] = true end
    for k in pairs(df_ids) do ids[k] = true end
    return ids
end

-- def-position passes THROUGH these transparent wrappers to the inner name.
-- `reference_declarator` (C++ `Type &r`) has no `declarator` field — its only
-- named child IS the inner declarator — so it rides the blanket WRAP path.
local WRAP = { variable_list = true, variable_name = true,
    reference_declarator = true, exception_variable = true } -- ruby `rescue … => e`
-- C/C++ declarator wrappers WITH a `declarator` field (a `*`/`[]` around the
-- declared name): def-position continues down that field, NOT to siblings like
-- an array `size` or pointer `type_qualifier` (which are uses/non-names). So
-- `SMesh *mesh = f()` and `char **pp`, `int arr[4]` all DEF the inner name.
local DECLWRAP = { pointer_declarator = true, array_declarator = true }
-- ★ A COLLECTION LOOP BINDS ITS LOOP VARIABLE, so that name is a DEF and not a use
-- (CART-0363). Nothing here declares it the way a three-part `for` does: java's
-- `for (String s : xs)` hangs a bare `name` FIELD, cpp's `for (auto &x : v)` a declarator
-- CHILD with no field at all, and js's for-of a bare `left` — none is an ASSIGN or a DECL
-- node, so du classed all three as USES. Measured before this fix, the head row of every
-- collection loop read `def={} use={s,xs}`: a read of a variable nothing defines, which
-- every consumer of that row (liveness, reaching_cfg, narrowing) then believed. The
-- three-part `for` beside it was correct (`def={i}`), which is exactly why it hid — and
-- dfparity cannot catch it, because its per-statement def/use comparison only runs when the
-- coarse counts MATCH, and they do not for the functions holding these very forms.
-- Value = the FIELD holding the binder; `false` = no field, take the non-header children.
local LOOPVAR = { enhanced_for_statement = 'name', for_in_statement = 'left',
    for_range_loop = false }
-- cpp for_range_loop's non-binder fields; every other named child is the declarator
local RANGE_HEAD = { 'type', 'right', 'body' }

-- the DEFAULT du stop: base body ∪ clause, used when a caller supplies no merged set
local DU_STOP = {}
for t in pairs(BODY) do DU_STOP[t] = true end
for t in pairs(CLAUSE) do DU_STOP[t] = true end

local function same(a, b)
    if not (a and b) then return false end
    local a1, a2, a3, a4 = a:range(); local b1, b2, b3, b4 = b:range()
    return a1 == b1 and a2 == b2 and a3 == b3 and a4 == b4
end

-- def/use over `root` (df's dfk def-position rules), NOT descending into
-- nested function bodies. Deduped per the df contract (a def name is not also
-- a use; first occurrence wins). When `stop_body` (a control head's OWN row),
-- also stop at sub-region boundaries (BODY blocks AND sibling CLAUSE nodes) so
-- the row owns only its condition — an elseif/else/case condition belongs to
-- that clause's row, not the head's (else it lands at the wrong DFS position
-- and defeats the order-sensitive shadow).
-- `ids` = the leaf-name node types to count = DFID plus the language's df_ids
-- extension (bash counts `variable_name` as a LEAF; php descends it as a WRAP —
-- so this is the one genuinely per-language-conflicting set, gated by cfg).
--
-- THIRD return `sus` = does the walked subtree contain a suspension point
-- (yield/await)? FUSED in here (was a separate has_suspend walk over the SAME
-- node set under the SAME stop-rules — a measured ~33% of flow.build spent
-- re-traversing every statement just to usually return false). Set on any
-- visited node whose type is in SUSPEND; the root is checked too.
-- `stopset` = the MERGED body+clause types for this language. ★ IT USED TO BE THE BASE
-- BODY/CLAUSE TABLES, read straight off the module (CART-0363), so du walked STRAIGHT THROUGH
-- a region whose spelling the spec had supplied — ruby's `then` and `do`. Measured, a ruby
-- `if` head reported def={zz} use={a,q,w}: the ENTIRE BODY harvested onto the head row, where
-- js's correctly read use={a}. Every ruby control row's def/use was inflated with its whole
-- subtree, which is also why the `try` head needed zeroing by hand in CART-0386 — that was
-- the symptom, this is the cause. Same seam-feeds-one-function shape as PRELOOP, IF_T, TRY_T
-- and CATCH before it; this is the FIFTH consumer holding a base set the spec never reached.
local function du(root, src, stop_body, lang, FN, stopset, ctrlset, clauseset)
    local ids = (lang and lang.ids) or DFID
    local mods, bindf = lang and lang.mods, lang and lang.binder_fields
    if not root then return {}, {}, false, {}, {} end
    local def, use, dseen, useen = {}, {}, {}, {}
    local blks = {} -- ATTACHED BLOCKS skipped on the way (see the 'always' stop below)
    local rmw, rmwseen = {}, {} -- read-modify-write LHS names (see the branch below)
    local sus = SUSPEND[root:type()] or false
    local function rec(node, defpos)
        local t = node:type()
        -- ★ THE BODY-FIELD STOP IS PER NODE, NOT PER ROOT (CART-0414). An `else if`
        -- chain is a NESTED if_statement in the `alternative` field, deliberately NOT
        -- stopped (its CONDITION belongs to this head) — so the walk descends into it,
        -- and the LINK's own unbraced body has to be stopped there too. Computing the
        -- set once for the root left du reading `acc, step` out of every chain link's
        -- body while the IR correctly stopped: 18 cells of the java grid, EVERY ONE an
        -- `unbraced_ch2`/`ch3`, which is exactly the intersection the grid exists for.
        local bodyc = (stop_body and ctrlset and ctrlset[t])
            and M.body_children(node, ctrlset, clauseset) or nil
        local asgleft, decld, k, declist, rngskip, bindset, bindskip, flatskip
        -- ★★ A DESTRUCTURING PATTERN DECIDES DEF-POSITION FOR ITS OWN CHILDREN (CART-0358),
        -- and it does so UNCONDITIONALLY — this branch is first, and it ignores the incoming
        -- `defpos`. That is what makes ONE table cover three sites that had nothing in
        -- common before: a declarator hands def-position to the pattern (k=3), an ASSIGNMENT
        -- hands it to the same pattern node (k=1, `[a, b] = [b, a]`), and a js `catch
        -- ({message})` hands it to NOTHING (k=5 tests for `variable_name`, which js does not
        -- spell) — yet all three bind. A declarator-shaped fix would have caught one of the
        -- three. Safe only because every node listed is binding-only BY GRAMMAR: the
        -- `_pattern` suffix and the import cluster never appear in a value position.
        --
        -- Before this, the walk reached the pattern with defpos=true and then dropped it at
        -- `k = defpos and WRAP[t] or false` (a pattern is in no WRAP set), so every bound
        -- name fell through to `use` — a DEF counted as a READ OF THE STATEMENT DEFINING IT.
        local bf = bindf and bindf[t]
        if bf then
            bindset, bindskip = {}, {}
            if bf == true then
                for c in node:iter_children() do
                    if c:named() then bindset[c:id()] = true end
                end
            else
                -- an ORDERED field list: the FIRST field present binds, and the OTHERS
                -- LISTED ARE SKIPPED ENTIRELY — neither def nor use. The fields in one
                -- list all name the SAME binding in different namespaces, so exactly one
                -- of them is a local name and the rest are not local READS either. js
                -- `import_specifier` is {'alias','name'}: `N2 as N3` binds N3, and N2
                -- names an export of the OTHER module. Leaving N2 as a use would
                -- re-fabricate the very phantom-read this change removes, and the module
                -- linkage does not need it — the import EDGE carries that, from
                -- import_query's @path capture, which is unconditional.
                local taken
                for _, f in ipairs(bf) do
                    local x = node:field(f)[1]
                    if x then
                        if taken then bindskip[x:id()] = true
                        else bindset[x:id()] = true; taken = true end
                    end
                end
            end
            k = 10
        elseif LOOPVAR[t] ~= nil then
            -- a collection loop's binder (see LOOPVAR): a FIELD where the grammar gives one,
            -- otherwise every named child that is not part of the header
            if LOOPVAR[t] then decld = node:field(LOOPVAR[t])[1]; k = 3
            else
                rngskip = {}
                for _, f in ipairs(RANGE_HEAD) do
                    local x = node:field(f)[1]
                    if x then rngskip[x:id()] = true end
                end
                k = 8
            end
        elseif ASSIGN[t] then
            asgleft = node:field('left')[1] or node:field('name')[1] or node:child(0)
            k = 1
        elseif DECL[t] then
            decld = node:field('declarator')[1] or node:field('name')[1]; k = 3
        elseif t == 'let_declaration' then
            decld = node:field('pattern')[1]; k = 3 -- rust `let <pat> = …`
        elseif t == 'variable_declaration' or t == 'local_declaration' then
            k = 4 -- lua bare `local a, b` (no `=`): the variable_list is a DEF
            -- ★★ …AND `k = 4` SAYS EVERY DIRECT `identifier` CHILD IS A DEF, WHICH IS A
            -- LUA-SHAPED RULE IN A LANGUAGE-AGNOSTIC WALK (CART-0431). lua reaches this
            -- branch only for a declaration with NO `=` — `local x = 1` hangs an
            -- `assignment_statement` child that re-dispatches as ASSIGN — so "every
            -- identifier binds" is exactly right there. zig's `variable_declaration` is
            -- FLAT: `var i: usize = index;` puts the NAME, the TYPE and the VALUE all at
            -- depth 1, so du recorded `def={i,index} use={}` and A PARAMETER APPEARED
            -- REDEFINED at that line — its incoming definition killed, the read of it not
            -- counted at all. Silent in every census, and wrong for reaching-definitions,
            -- liveness and everything layered on them.
            --
            -- ★ IT WAS INVISIBLE BECAUSE THE OTHER SIDE WAS ALSO WRONG. The expression IR's
            -- `?` fallback read both names too (CART-0404), so the self-gate AGREED on these
            -- rows. Fixing the IR is what exposed this; two wrong sides agreeing is what a
            -- two-implementation gate exists to break.
            --
            -- So a declaration that HAS an `=` splits there: only children BEFORE the
            -- operator can bind, and the `type` field never binds. Both are position facts
            -- about the same token the IR's `assign_sides` splits on, so the two agree BY
            -- CONSTRUCTION rather than by two tables being kept in step. A declaration with
            -- no `=` is untouched, which is every lua node that reaches here.
            local past = false
            for c in node:iter_children() do
                if not c:named() then
                    if ASSIGN_TOK[txt(c, src)] then past = true end
                elseif past then
                    flatskip = flatskip or {}
                    flatskip[c:id()] = true
                end
            end
            for _, ty in ipairs(node:field('type')) do
                flatskip = flatskip or {}
                flatskip[ty:id()] = true
            end
        elseif t == 'catch_clause' then
            k = 5 -- catch(Type $e): the variable_name is a BINDING (DEF), type a use
        elseif t == 'rescue' then
            -- ★ ruby `rescue E => e`: the BINDING hangs under `exception_variable`, and the
            -- `exceptions` sibling is a TYPE reference (a use). Without this `e` lands as a
            -- free use — a read of a variable nothing defines, the same defect class as the
            -- collection-loop variable (CART-0363). `rescue` is ruby-unique among the
            -- grammars we support, the same criterion the rust and cpp entries use.
            k = 9
        elseif t == 'declaration_command' then
            k = 6 -- bash `local/declare x`: a direct variable_name child is a DEF
        elseif defpos and DECLWRAP[t] then
            decld = node:field('declarator')[1]; k = 3 -- C/C++ *ptr / arr[]: continue to the inner name
        elseif t == 'declaration' then
            -- C/C++ declaration: EVERY `declarator`-field child is def-position
            -- (or continues to one — bare `int x;`, `Foo *p;`, multi `int a, b;`,
            -- and `= init` via init_declarator). The `type` field is left alone
            -- (types aren't counted names). This is what makes a NO-INITIALIZER
            -- declaration def its name (init_declarator only exists WITH `=`).
            declist = node:field('declarator'); k = 7
        else
            k = defpos and WRAP[t] or false
        end
        for c in node:iter_children() do
            if c:named() then
              local ct = c:type() -- cache the per-child type FFI (was called 2-6× below)
              -- a BINDING MODIFIER decorates the declaration and reads nothing; descending
              -- it invented a read of `const` from lua's `local x <const>` (CART-0234).
              -- Language-declared, because the node name means `a.b` in python.
              if mods and mods[ct] then goto skipchild end
              -- a LISTED-BUT-NOT-CHOSEN binder field (the foreign name of an
              -- aliased import): not a binding, and not a local read either.
              if bindskip and bindskip[c:id()] then goto skipchild end
              -- ★ AN 'always' STOP IS AN ATTACHED BLOCK, AND du IS WHAT FINDS IT (part B).
              -- A ruby `xs.each do |x| … end` hangs its block off a `call` that can sit
              -- ANYWHERE inside the statement — `q = xs.map { … }` puts it under an
              -- assignment's RHS — so the block cannot be found by asking the ROW's node for
              -- a field. It has to be found by a walk, and this walk already runs, under
              -- exactly the stop rules block emission needs (nested functions excluded,
              -- sub-regions excluded when this is a control head). A SECOND walk over the
              -- same nodes under the same stops is precisely what `sus` was fused in here to
              -- stop being — measured ~33% of flow.build, itself 43-57% of the profile.
              -- So the blocks handed back are BY CONSTRUCTION exactly the ones this row's
              -- def/use excluded: one source of truth, and EVERY du caller (plain row,
              -- control head, elseif, catch, case label, post-loop cond) gets block emission
              -- from one line instead of each having to re-derive which stops to mirror.
              -- `true` (body/clause) still stops only for a control head; 'always' stops
              -- unconditionally, because an attached block is never part of the statement
              -- carrying it, control head or not.
              local st = (stopset or DU_STOP)[ct]
              if st == 'always' then blks[#blks + 1] = c; goto skipchild end
              -- ★ AND BY FIELD, not only by type (CART-0414): an UNBRACED body is a bare
              -- `expression_statement` in the `consequence`/`body` position, which no type
              -- test names. It is NOT appended to `blks` — the caller's own child loop
              -- already emits it as a row (verified: the body row survives this stop), so
              -- re-emitting it here would double it.
              if stop_body and bodyc and bodyc[c:id()] then goto skipchild end
              if not FN[ct] and not (stop_body and st) then
                if SUSPEND[ct] then sus = true end -- fused suspension detection
                local cdefpos
                if k == 10 then cdefpos = bindset[c:id()] or false -- pattern/import binder
                elseif k == 1 then cdefpos = same(c, asgleft)
                elseif k == 3 then cdefpos = same(c, decld)
                elseif k == 4 then cdefpos = (ct == 'variable_list'
                    or ct == 'identifier') and not (flatskip and flatskip[c:id()])
                elseif k == 5 then cdefpos = (ct == 'variable_name')
                elseif k == 6 then cdefpos = (ct == 'variable_name')
                elseif k == 7 then
                    cdefpos = false
                    for _, dd in ipairs(declist) do if same(c, dd) then cdefpos = true; break end end
                elseif k == 8 then cdefpos = not rngskip[c:id()] -- cpp range-for declarator
                elseif k == 9 then cdefpos = (ct == 'exception_variable') -- ruby rescue binding
                else cdefpos = k end
                if ids[ct] then
                    local nm = txt(c, src)
                    if cdefpos then
                        if not dseen[nm] then dseen[nm] = true; def[#def + 1] = nm end
                    elseif dseen[nm] then
                        -- use-position but ALREADY a def in this statement = a
                        -- read-modify-write (`a = a + …`). The df contract drops it
                        -- from `use` (a def name is not also a use), losing the READ.
                        -- Record it SEPARATELY so reaching_cfg can see the self-read
                        -- without perturbing the du/df census or the rw edge kinds
                        -- ([[flow-precision-gaps]] #1).
                        if not rmwseen[nm] and not useen[nm] then
                            rmwseen[nm] = true; rmw[#rmw + 1] = nm
                        end
                    elseif not useen[nm] then
                        useen[nm] = true; use[#use + 1] = nm
                    end
                end
                rec(c, cdefpos)
              end
              ::skipchild::
            end
        end
    end
    -- a statement that IS a bare name leaf — e.g. a rust/ml tail-expression
    -- `out` (implicit return), an enum `None`. du only inspects CHILDREN, so a
    -- root name would be missed; count it as a use (a root has no def-context).
    if ids[root:type()] and root:named() and root:child_count() == 0 then
        local nm = txt(root, src)
        if not dseen[nm] and not useen[nm] then useen[nm] = true; use[#use + 1] = nm end
    end
    rec(root, false)
    return def, use, sus, rmw, blks
end


-- parameter binder names of a fn node — mirrors df's fn_params (treesitter.lua)
-- for coarse-dep PARITY: the pfield container's leaves; php `variable_name`
-- drops its `$`; a method seeds 'self' first; nested declarators (C params,
-- pointers) descend to the first name. `pfield` comes from the language cfg.
-- ★ A DESTRUCTURING BINDER BINDS EVERY NAME IN IT, NOT THE FIRST ONE. The wrapper rule
-- below ("take the first identifier child") is right for `*rest` / `k: 1` / `x = f(z)`,
-- where the first identifier IS the binder and the rest is a default expression — but for
-- ruby's `|(a, b)|` it drops `b`, which then reads as a FREE USE of a name nothing defines.
-- That is the same defect class as the collection-loop variable, the exception variable and
-- the block parameter (CART-0363): a phantom free variable, believed by every consumer of
-- the row. `destructured_parameter` is ruby-only across all 17 grammars (checked via
-- language.inspect), the same criterion the `rescue` and cpp range-for entries use, so it is
-- safe as a base entry. It also reaches ruby METHOD params (`def m((a, b))`), deliberately:
-- one rule for one language's binder, not one for blocks and another for methods.
local DESTRUCT = { destructured_parameter = true }
local function param_names(fn, src, pfield, method, params_of)
    local out = method and { 'self' } or {}
    -- params_of: the POSITIONAL twin of pfield, for a grammar that does not label the
    -- parameter list either (odin nests `parameters` inside its `procedure` wrapper).
    local ps = (pfield and fn:field(pfield)[1]) or (params_of and params_of(fn))
    if ps then
        for c in ps:iter_children() do
            local t = c:type()
            if t == 'identifier' or t == 'variable' then
                out[#out + 1] = txt(c, src)
            elseif t == 'variable_name' then
                out[#out + 1] = txt(c, src):gsub('^%$', '')
            elseif DESTRUCT[t] then
                -- every name inside, at any nesting (`|(a, (b, c))|`)
                local function collect(n)
                    for id in n:iter_children() do
                        local it = id:type()
                        if it == 'identifier' then out[#out + 1] = txt(id, src)
                        elseif DESTRUCT[it] then collect(id) end
                    end
                end
                collect(c)
            elseif c:named() then
                for id in c:iter_children() do
                    local it = id:type()
                    if it == 'identifier' then out[#out + 1] = txt(id, src); break end
                    if it == 'variable_name' then out[#out + 1] = txt(id, src):gsub('^%$', ''); break end
                    if it == 'pointer_declarator' then
                        local inner = id:field('declarator')[1]
                        -- @langs-ok inside a C/C++ pointer_declarator, whose inner
                        -- declarator is an identifier in exactly those grammars
                        if inner and inner:type() == 'identifier' then out[#out + 1] = txt(inner, src) end
                        break
                    end
                end
            end
        end
    end
    return out
end

--- ★ THE BINDER RULE, EXPORTED, BECAUSE TWO SIDES HAVE TO AGREE ABOUT IT (CART-0363 part B).
--- A block head's `|x, opt = f(z)|` splits into names it DEFINES and expressions it READS,
--- and du and the expression harvest must draw that line in the same place or the expr
--- self-gate fires. Measured before this existed: the head's expr read `x`, which du had
--- correctly called a def — and the identical divergence is live today for java's
--- enhanced-for and js's for-of loop variables, hidden because the gate's caller iterates
--- only `kind == 'function'` and never sees a METHOD (filed separately).
--- `names` is param_names' answer, unchanged. `values` is everything a binder WRAPPER holds
--- after its first identifier — a default expression, which really is read.
---@return string[] names, table[] values  (tree-sitter nodes)
function M.binders(node, src, field)
    local names = param_names(node, src, field, false)
    local values = {}
    local ps = field and node:field(field)[1]
    if ps then
        for c in ps:iter_children() do
            local t = c:type()
            if c:named() and t ~= 'identifier' and not DESTRUCT[t] then
                local bound = false -- the FIRST identifier is the binder; the rest is a value
                for x in c:iter_children() do
                    if x:named() then
                        -- @langs-ok reached only for a language that DECLARES a `blocks`
                        -- spec key — ruby alone, whose binder leaves are `identifier`
                        if not bound and x:type() == 'identifier' then bound = true
                        else values[#values + 1] = x end
                    end
                end
            end
        end
    end
    return names, values
end

--- ★ WHAT A CONTROL HEAD BINDS, for the OTHER side of the row — the expression harvest
--- (CART-0395). du and the IR must draw the def/read line in the same place or the expr
--- self-gate fires, and MEASURED on the java bestiary it did: every `for (String x : xs)`
--- head reported `extra={x}` — a def in du, a read in the IR. 430 instances on
--- elasticsearch's libs, 3 on the synthetic corpus that is supposed to gate it.
--- Returns (names, skip, values):
---   names  — what the head DEFINES (goes in the row expr's `lhs`, where a plain name reads
---            nothing), matching du's `def` for the same row
---   skip   — node ids the harvest must NOT descend, because their leaves are those names
---   values — nodes it must build ANYWAY (a binder wrapper's default expression is read)
--- nil when this node type binds nothing, which is every language's ordinary control head.
---
--- ★ ONLY THE FORMS WHERE THE BINDER IS SELF-CONTAINED. java's try-with-resources binds too
--- (`try (var r = open())`), but its `resources` child holds the INITIALIZERS as well, so
--- skipping it would hide real reads and taking its leaves would fabricate defs from
--- `new BufferedReader(…)`. That one needs a per-resource split and is filed, not guessed at
--- here: a binder rule that is exact for four forms and approximate for a fifth is worse
--- than one that declines the fifth.
--- What a DESTRUCTURING PATTERN (or an import statement) BINDS, and what it READS —
--- BY THE SAME RULE `du` APPLIES, which is the entire point of exporting it (CART-0358).
--- du computes def/use over these nodes and the expression IR has to model the same row;
--- two implementations of one rule is how `expr.fn_node` and the provider ended up giving
--- different answers about which function encloses a node (CART-0306), and how five copies
--- of the frontier predicate happened (CART-0308).
---
--- Returns (names, reads): binder NODES, and the sub-expressions that genuinely read.
--- A pattern child is one of three things and never two — the binder (a name, or a nested
--- pattern to descend), a listed-but-not-chosen alternate (skipped entirely: the foreign
--- name of an aliased import), or a READ (an `object_assignment_pattern`'s default, a
--- computed key). A bare leaf outside `ids` is dropped rather than read, mirroring du:
--- a `pair_pattern`'s `property_identifier` key is not a variable in any of these
--- languages, so it is neither a def nor a use.
---@param node userdata  the pattern / import node
---@param bindf table|nil  the language's `binder_fields`
---@param ids table|nil  the language's leaf-name set (defaults to DFID)
function M.pattern_binders(node, bindf, ids)
    ids = ids or DFID
    local names, reads = {}, {}
    local function rec(n)
        local bf = bindf and bindf[n:type()]
        local bindset, bindskip = {}, {}
        if bf == true then
            for c in n:iter_children() do
                if c:named() then bindset[c:id()] = true end
            end
        elseif bf then
            local taken
            for _, f in ipairs(bf) do
                local x = n:field(f)[1]
                if x then
                    if taken then bindskip[x:id()] = true
                    else bindset[x:id()] = true; taken = true end
                end
            end
        end
        for c in n:iter_children() do
            if c:named() and not bindskip[c:id()] then
                local ct = c:type()
                if bindset[c:id()] then
                    if bindf[ct] then rec(c)                    -- a nested pattern
                    elseif ids[ct] then names[#names + 1] = c end
                elseif not (c:named_child_count() == 0 and not ids[ct]) then
                    reads[#reads + 1] = c                        -- a genuine read
                end
            end
        end
    end
    rec(node)
    return names, reads
end

---@param node userdata  the control head node
---@param src string
---@param cls table|nil  the record's class table (M.classes), for the `blocks` map
function M.head_binders(node, src, cls)
    local t = node:type()
    local blocks = cls and cls.blocks
    if blocks and blocks[t] then                      -- ruby's `do…end` / `{…}` parameters
        local names, values = M.binders(node, src, blocks[t])
        local ps = node:field(blocks[t])[1]
        return names, ps and { [ps:id()] = true } or {}, values
    end
    if LOOPVAR[t] == nil then return nil end
    local nodes = {}
    if LOOPVAR[t] then
        local x = node:field(LOOPVAR[t])[1]           -- java `name`, js `left`
        if x then nodes[1] = x end
    else                                              -- cpp range-for: the declarator child
        local hdr = {}
        for _, f in ipairs(RANGE_HEAD) do
            local x = node:field(f)[1]
            if x then hdr[x:id()] = true end
        end
        for c in node:iter_children() do
            if c:named() and not hdr[c:id()] then nodes[#nodes + 1] = c end
        end
    end
    local names, skip = {}, {}
    local function leaves(n)
        if n:named() and n:child_count() == 0 then
            -- @langs-ok reached only through LOOPVAR, whose forms exist in java/js/ts/cpp
            -- alone — and in all four the collection loop's binder leaf is `identifier`
            if n:type() == 'identifier' then names[#names + 1] = txt(n, src) end
            return
        end
        for c in n:iter_children() do if c:named() then leaves(c) end end
    end
    for _, b in ipairs(nodes) do skip[b:id()] = true; leaves(b) end
    return names, skip, {}
end

--- ★ THE CASE LABEL, EXPORTED FOR THE SAME REASON. flow.clause reads `value` ∪ `pattern` as
--- a LIST and falls back to a `switch_label` CHILD (java hangs one); the expression harvest
--- read only `node:field('value')` and so MISSED java's label entirely — `missing={FAST}` on
--- the bestiary, a name du counts and the IR does not. One reader, two callers.
function M.case_labels(node)
    local labels = {}
    for _, f in ipairs({ 'value', 'pattern' }) do
        for _, x in ipairs(node:field(f)) do labels[#labels + 1] = x end
    end
    if #labels == 0 then
        for c in node:iter_children() do
            if c:named() and CASELABEL[c:type()] then labels[#labels + 1] = c end
        end
    end
    return labels
end

-- the function body region (php `body` field / lua block child)
local function fn_body(fn)
    local b = fn:field('body')[1]
    if b then return b end
    for c in fn:iter_children() do if c:named() and BODY[c:type()] then return c end end
    return nil -- no body block (e.g. `function() end`) → no statements; NEVER
    -- fall back to `fn` itself (that walks the parameters as bogus statements)
end

--- ★ THE ONE OWNER OF "WHAT COUNTS AS CONTROL IN THIS LANGUAGE" (CART-0363). The base sets
--- above are one family's SPELLING; a language spelling it otherwise had its whole body
--- folded into a single opaque row. The spec supplies the rest, merged HERE.
---
--- EXPORTED ON PURPOSE. This ticket exists because a SECOND copy of flow's CTRL had drifted
--- (opaque.lua's, in the very probe measuring the fix), so anything that needs to know what
--- flow opens must ask rather than restate it. `tools/ctrlcensus.lua` is the first caller.
---
--- FOUR node classes, each a per-language extension of a base set. `ctrl` says "this is a
--- control statement", `preloop` "its test runs before the body", `body` "this node IS a
--- region of statements", `clause` "this is a sub-region with its own condition".
--- ★ RUBY NEEDED ALL FOUR AND THAT IS THE POINT: its control is `if`/`while`/`case`, its
--- REGIONS are `then`/`do` (not `block`), and its sub-regions are `elsif`/`else`/`when`.
--- Adding only `ctrl` opens the loop and then folds its whole body into one row, because the
--- container is not recognised as a region — measurably no better than before.
---@param cfg table|nil  the language cfg (spec.ctrl/.preloop/.body/.clause)
---@return table  { ctrl, preloop, body, clause, elseif_, case, post }
function M.classes(cfg)
    cfg = cfg or {}
    local function extend_set(base, extra)
        if not extra then return base end
        local out = {}
        for k, v in pairs(base) do out[k] = v end
        for k, v in pairs(extra) do out[k] = v end
        return out
    end
    -- ★ `clause` IS A MAP, NOT A SET, and that is deliberate: clause() dispatches on WHICH
    -- KIND of sub-region a node is, so a bare set would need two more spec keys to say it.
    -- `{ elsif = 'elseif', ['else'] = 'else', when = 'case' }` — the value names the class.
    -- A set entry (value `true`) still works and means "a clause with no special handling".
    local elseif_, case_ = ELSEIF, CASE
    if cfg.clause then
        elseif_, case_ = extend_set(ELSEIF, {}), extend_set(CASE, {})
        for k, v in pairs(cfg.clause) do
            if v == 'elseif' then elseif_[k] = true
            elseif v == 'case' then case_[k] = true
            -- ⚠ A SPEC MUST BE ABLE TO SAY "NOT HERE" (CART-0667). The base sets carry
            -- one spelling per meaning across grammars, and `case_statement` means
            -- opposite things in two of them: in C/php/java it IS one arm, in BASH it is
            -- the whole `case X in … esac` and the arms are `case_item`. The map could
            -- only ADD, so bash inherited a false claim it had no way to retract — its
            -- switch classified as an arm and its arms as plain statements whose `def`
            -- swallowed their entire bodies. `false` removes; `extend_set` already
            -- overlays it into the main clause set, and consumers read truthiness.
            elseif v == false then elseif_[k] = nil; case_[k] = nil end
        end
    end
    -- ★ `ctrl` IS A MAP FROM NODE TYPE TO ROLE, not a bare set (CART-0382). `clause` set the
    -- precedent and it is the right one here: a ROLE that lives on `ctrl` cannot drift away
    -- from it. A sibling `ifs` key would have created a pair that can disagree — a type in
    -- `ifs` but not `ctrl` never emits as control, so the entry dies silently — whereas
    -- `ifs ⊆ ctrl` is true BY CONSTRUCTION when the role is the value. Every consumer reads
    -- `ctrl` for truthiness only (`cls.ctrl[t]`, `cfg.ctrl[t]`, `pairs`), verified by grep,
    -- so a string value is compatible everywhere. `true` = a control statement with no
    -- special role; 'if' = the successors IF branch (exhaustive-arm detection).
    local ifs, try_, switch_ = IF_T, TRY_T, SWITCH
    if cfg.ctrl then
        ifs, try_ = extend_set(IF_T, {}), extend_set(TRY_T, {})
        switch_ = extend_set(SWITCH, {})
        for k, v in pairs(cfg.ctrl) do
            if v == 'if' then ifs[k] = true
            elseif v == 'try' then try_[k] = true
            elseif v == 'switch' then switch_[k] = true end
        end
    end
    -- CATCH is the fourth base-only set the CFG path held (after PRELOOP, IF_T, TRY_T):
    -- clause() reads it directly to give an exception clause its BINDING treatment. Derived
    -- from the clause map's 'catch' role, so ruby's `rescue` reaches it (CART-0386).
    local catch_ = CATCH
    if cfg.clause then
        catch_ = extend_set(CATCH, {})
        for k, v in pairs(cfg.clause) do if v == 'catch' then catch_[k] = true end end
    end
    return {
        ctrl = extend_set(CTRL, cfg.ctrl),
        preloop = extend_set(PRELOOP, cfg.preloop),
        body = extend_set(BODY, cfg.body),
        clause = extend_set(CLAUSE, cfg.clause),
        elseif_ = elseif_, case = case_, post = POST, ifs = ifs,
        -- ★ THE ONE ANSWER TO "IS THIS NODE A LOOP" (CART-0383). FOUR modules each held a
        -- private LOOPISH table — exprlint, optapply, optimize, untangle — and measured, every
        -- PAIR of them disagreed: on loop_expression, on for_numeric/for_generic_statement, on
        -- foreach_statement. None knew `enhanced_for_statement`, `for_range_loop`,
        -- `for_expression` or `while_expression`, so flow opened loops that LICM, CSE, the
        -- expression lints and untangle could not see. All four also carried
        -- `loop_statement`, which NO grammar we support spells — a phantom copied from set to
        -- set, which is the tell that they were duplicated rather than derived.
        -- ★ `do_statement` IS DELIBERATELY EXCLUDED. C spells do-while that way and lua
        -- spells a plain `do…end` block that way, and only the presence of a CONDITION tells
        -- them apart — a question about the NODE, not the type. Every consumer already
        -- excluded it; a set keyed by type cannot answer it, so it must not pretend to.
        loops = (function ()
            local L = extend_set(extend_set(PRELOOP, cfg.preloop), { repeat_statement = true })
            return L
        end)(),
        try = try_, catch = catch_, clausemap = cfg.clause, switch = switch_,
        -- ★ ATTACHED BLOCKS — the fifth class, and the only one with NO base member
        -- (CART-0363 part B). A map <block node type> -> <field holding its binder list>,
        -- because the value is needed anyway and a sibling key would be a drift pair
        -- (the `ctrl`-role lesson). Ruby is the only language we support that has the
        -- form at all; `block` is in EIGHT grammars — and in lua it IS the region
        -- container — so this can only ever live in the spec, never in a base set.
        blocks = cfg.blocks,
    }
end

-- cfg (the per-language seam — the config flow should CONSUME rather than
-- hardcode, [[cartograph-df-strangler]]): { pfield=<params field>,
-- regime=<scope-regime table/fn>, ... }. Absent → best-effort defaults.
function M.build(fnnode, src, cfg)
    cfg = cfg or {}
    local regimetab = cfg.regime or {}
    -- ── PER-LANGUAGE CONTROL NODES (CART-0363) ──────────────────────────────────
    -- CTRL/PRELOOP above are one language's SPELLING of "this is a control statement".
    -- A language whose node is spelled otherwise had its whole body folded into one
    -- opaque row. The spec supplies the rest; merged HERE, per build, so the module-level
    -- tables stay the shared base and nothing leaks between languages.
    -- ★ STASHED ON THE RECORD, because the CFG phases (M.successors and friends) are
    -- SEPARATE FUNCTIONS that ask "is this row a pre-condition loop?" of a row built here.
    -- A build-local set they cannot see is how the first cut of this crashed them.
    -- FOUR node classes, each a per-language extension of a base set. `ctrl` says "this is
    -- a control statement", `preloop` "its test runs before the body", `body` "this node IS
    -- a region of statements", `clause` "this is a sub-region with its own condition".
    -- ★ RUBY NEEDED ALL FOUR AND THAT IS THE POINT: its control is `if`/`while`/`case`, its
    -- REGIONS are `then`/`do` (not `block`), and its sub-regions are `elsif`/`else`/`when`.
    -- Adding only `ctrl` opens the loop and then folds its whole body into one row, because
    -- the container is not recognised as a region — measurably no better than before.
    local cls = M.classes(cfg)
    local CTRL_, PRELOOP_, BODY_, CLAUSE_ = cls.ctrl, cls.preloop, cls.body, cls.clause
    local ELSEIF_, CASE_ = cls.elseif_, cls.case
    local CATCH_, CLAUSEMAP, TRY_, SWITCH_ = cls.catch, cls.clausemap, cls.try, cls.switch
    -- the MERGED region set du must stop at (see du's header): base ∪ this language's
    local DUSTOP = {}
    for t in pairs(BODY_) do DUSTOP[t] = true end
    for t in pairs(CLAUSE_) do DUSTOP[t] = true end
    -- ATTACHED BLOCKS stop du UNCONDITIONALLY ('always'), control head or not, and come back
    -- as its fifth return so the caller can emit them as rows of their own. Written LAST so
    -- the stronger stop wins if a type were ever in both.
    -- ★ M.coarse NEEDS NO CHANGE HERE, because it does not call du at all — it re-aggregates
    -- the FINE rows into their top-level ancestor, so a block's names leave the call row and
    -- arrive back on the coarse row through the block's new child rows. It DOES need one
    -- change of its own, and the opposite of what looked right at first: the block
    -- parameter's DEF is skipped there. Coarse is scope-blind by contract and cannot hold a
    -- block-scoped binding, and admitting one made 37 call sites claim a false refusal. The
    -- reasoning is written where the skip is.
    local BLOCKS_ = cls.blocks
    if BLOCKS_ then for t in pairs(BLOCKS_) do DUSTOP[t] = 'always' end end
    local FN = cfg.fn_types or FN_FALLBACK -- the nested-function stop (CART-0308)
    -- leaf-name set = DFID + the language's df_ids extension (bash variable_name)
    -- BINDING MODIFIERS (CART-0234): per-language node types to skip entirely, because
    -- they decorate a declaration and read nothing. Threaded exactly like df_ids.
    local ids = M.leaf_ids(cfg.df_ids)
    -- ★ THE PER-LANGUAGE NODE TABLES TRAVEL AS ONE BUNDLE (CART-0358 folded this).
    -- `ids`, `mods` and `binder_fields` are all node-keyed language data read at a single
    -- point in the walk, and du already carried nine positional arguments — a tenth would
    -- have meant nil-padding at three of the six call sites, which is how a caller ends up
    -- passing the wrong table. One bundle, passed unchanged by every caller.
    local lang = { ids = ids, mods = cfg.mods, binder_fields = cfg.binder_fields }
    local stmts = {}
    local emit, region, clause -- fwd

    -- ★ ONE LINE PER du CALLER, AND THAT IS THE POINT (CART-0363 part B). du hands back the
    -- attached blocks it declined to walk (its fifth return), so every row that owns a
    -- def/use — plain statement, control head, elseif guard, rescue header, case label,
    -- post-loop condition — gives its blocks rows here without re-deriving which stops to
    -- mirror. `blks` is nil only for a du call this build predates; treated as empty.
    local function emit_blocks(blks, idx)
        for _, b in ipairs(blks or {}) do emit(b, idx, 'body') end
    end

    -- ── the INIT CLAUSE of a three-part `for` (CART-0359) ────────────────────────
    -- `for (let i = 0; i < n; i++)` has a header clause that runs ONCE, BEFORE the
    -- loop. Emitted as a child of the loop it became the first row of the BODY, and
    -- every consumer that asks "what runs each iteration" then got the wrong answer:
    -- LICM asked whether its value is the same every iteration (it is), and offered
    -- hoisting a JS `let` out of a for-header — which breaks per-iteration binding,
    -- so a closure made in the body sees the final value. Certified, and unhedged.
    -- It is returned here so the caller can emit it as an ORDINARY SIBLING before the
    -- head, which is what it is: `within()` is structural, so it stops being a loop
    -- member with no special case anywhere downstream, and as a plain sibling it
    -- falls through to the head exactly once.
    --
    -- ★ SCOPED TO THE THREE-PART FORM ON PURPOSE. The discriminator needs a `body`
    -- field (so an UNBRACED body — `for (…) f(i);`, which is why the emit-as-body
    -- fallback exists at all — is never mistaken for a header clause) and a
    -- `condition` field to sit before. That admits js/ts/cpp by their `initializer`
    -- field and java/php positionally, and admits NOBODY else: lua's
    -- `for_numeric_clause` and go's `for_clause` have no sibling `condition`, so they
    -- keep their current modelling. They are body rows too, and wrongly, but they
    -- escape LICM by row kind rather than by luck of position, and moving them would
    -- reorder every lua function's rows for no soundness gain.
    local function for_init(node)
        if not node:field('body')[1] then return nil end
        local init = node:field('initializer')[1]
        if init then return init end
        local cond = node:field('condition')[1]
        if not cond then return nil end
        -- java / php: the initializer carries no field name, so take the named child
        -- that PRECEDES the condition (and is not a clause or the body).
        for c in node:iter_children() do
            if c:id() == cond:id() then return nil end
            if c:named() and not COMMENT[c:type()]
                and not BODY_[c:type()] and not CLAUSE_[c:type()] then return c end
        end
        return nil
    end

    -- emit `node` as a statement row (parent/pol) and recurse its sub-regions
    function emit(node, parent, pol)
        local t = node:type()
        -- rust: control is EXPRESSIONS wrapped in an expression_statement.
        -- Unwrap a sole CTRL child so it is regioned like a control statement.
        if t == 'expression_statement' then
            local inner
            for c in node:iter_children() do
                if c:named() and not COMMENT[c:type()] then
                    if inner then inner = nil; break end
                    inner = c
                end
            end
            if inner and CTRL_[inner:type()] then return emit(inner, parent, pol) end
        end
        -- labeled_statement (go/java/js/c): DEFINES a label over the wrapped
        -- statement — unwrap, emit the inner statement, and tag its HEAD row with
        -- the label so break/continue/goto can target it. An empty target (C
        -- `done: ;`) emits a bare `label` marker row.
        if LABELED[t] then
            local lbl, inner = labeled_parts(node, src)
            if inner then
                -- ★ ASK emit WHICH ROW IS THE HEAD; do not assume it is the first one
                -- emitted. A three-part for emits its INIT clause first (CART-0359), so
                -- `before + 1` would tag `let i = 0` as the labelled statement and every
                -- `continue outer` would target it instead of the loop.
                local before = #stmts
                local head = emit(inner, parent, pol) or (before + 1)
                if lbl and stmts[head] then stmts[head].label = lbl end
            else
                stmts[#stmts + 1] = { l = line(node), c = startcol(node), kind = 'label',
                    parent = parent, pol = pol, def = {}, use = {}, t = t, label = lbl }
            end
            return
        end
        -- the three-part for's init runs BEFORE the head, so it is emitted before it
        -- the three-part for's init runs BEFORE the head, and so does a try-with-resources'
        -- `resources` acquisition — same shape, same treatment (CART-0363)
        local finit = (CTRL_[t] and PRELOOP_[t]) and for_init(node) or nil
        if not finit and PREFIELD[t] then finit = node:field(PREFIELD[t])[1] end
        if finit then emit(finit, parent, pol) end
        local idx = #stmts + 1
        local sb = CTRL_[t] and true or false
        -- ★ A HEAD-ONLY FORM IS WALKED AT ITS HEAD FIELD, NOT AT ITSELF (CART-0380).
        -- `#if COND` hangs its statements directly under the directive, so a type-based
        -- body stop has nothing to stop at and the head would harvest the whole branch —
        -- the same shape as ruby's `begin` (CART-0386). Walking the condition alone is
        -- exact rather than a blanking, because unlike a `try` head this one DOES evaluate
        -- something. `false` (an `#else`) has no head: nothing to walk.
        local hfd = HEADFIELD[t]
        local dunode = node
        if hfd ~= nil then dunode = hfd and node:field(hfd)[1] or nil end
        local d, u, sus, rmw, blks
        if dunode then
            d, u, sus, rmw, blks = du(dunode, src, sb, lang, FN, DUSTOP,
                CTRL_, CLAUSE_)
        else
            d, u, sus, rmw, blks = {}, {}, false, nil, {}
        end
        stmts[idx] = { l = line(node), c = startcol(node), kind = CTRL_[t] and t or 'stmt',
            parent = parent, pol = pol, def = d, use = u,
            regime = regimetab[t] or 'function', t = t, -- t = raw node type (CFG terminators)
            suspend = sus or nil, -- yield/await = a Tier-1 continuation point (fused from du)
            rmw = (rmw and rmw[1]) and rmw or nil, -- read-modify-write reads (sparse)
            -- control-transfer label: TARGET on break/continue/goto, else the
            -- loop's OWN label (rust). def/use above are unaffected.
            label = (TRANSFER[t] and target_label(node, src))
                or (CTRL_[t] and loop_label(node, src)) or nil }
        -- CO-EMIT the expression IR at the row-birth point ([[cartograph-expression-layer]]):
        -- by here rust/labeled unwrapping is done and `node` IS the row's node, so
        -- row↔expr is 1:1 by construction. Off unless a consumer set cfg.expr (a
        -- harvester fn). CTRL rows are harvested below (flow knows POST-stripping +
        -- the body/clause boundary du stops at); plain rows here. The hot ingest path
        -- never even builds the closure.
        if cfg.expr and not CTRL_[t] then stmts[idx].expr = cfg.expr(node, src) end
        -- ATTACHED BLOCKS, emitted as rows UNDER this one: a ruby `do…end` / `{…}` is a
        -- region of statements that the statement carrying it merely PASSES — 18-20% of
        -- ruby statements sit inside one, and until now the whole block was folded into the
        -- call row. Emitted HERE, before any body/clause rows below, because a block in a
        -- CONDITION (`while xs.any? { … }`) runs before the body does.
        emit_blocks(blks, idx)
        if CTRL_[t] then
            -- ★ THE SWITCHED SUBJECT IS THE HEAD'S CONDITION, NOT A BODY STATEMENT. go spells
            -- it `value` and so does ruby's `case`; without this the subject was emitted as a
            -- row that appears to EXECUTE as an arm of its own (ruby `case a` gained an
            -- `identifier` row with pol='body'). Read through the language-aware switch set,
            -- so a language that declares the role gets it (CART-0387).
            local hf = HEADFIELD[t]
            local cond
            if hf ~= nil then                       -- a HEAD-ONLY form (CART-0380)
                cond = hf and node:field(hf)[1] or nil
            else
                cond = node:field('condition')[1]
                    or (SWITCH_[t] and node:field('value')[1])
            end
            -- loop feasibility flag (do{}while(0) / while(true) / rust loop)
            if POST[t] or PRELOOP_[t] then
                stmts[idx].const = (t == 'loop_expression') and true or const_cond(cond, src)
            end
            -- the head expr: 'ctrlhead' = condition + clause (skipping body — mirrors
            -- du's stop_body); POST loops strip their cond onto a trailing 'cond' row
            -- (below), so their head carries no expr.
            if cfg.expr then
                stmts[idx].expr = POST[t] and { lhs = {}, rhs = {} }
                    or cfg.expr(node, src, 'ctrlhead')
            end
            -- POST-condition loops (do-while, lua repeat-until): the condition
            -- runs AFTER the body, so its def/use must be ordered after it (a
            -- var def'd in the body and read in the condition is not a free
            -- use). Drop it from the control row; re-emit as a trailing row.
            -- ★ AND `rmw` TOO. A row's read census is `use ∪ rmw` — rmw holds the READ half
            -- of a read-modify-write, which the df contract drops from `use` — so blanking
            -- def/use and leaving rmw keeps exactly the names the blanking meant to remove.
            -- Found by the ruby grid (CART-0405): the `begin` head came back def={} use={}
            -- reads={} and the self-gate still said missing={acc}, because `acc = step(acc)`
            -- in the body had put `acc` in the head's rmw. Two fields, one claim.
            if POST[t] then stmts[idx].def, stmts[idx].use, stmts[idx].rmw = {}, {}, nil end
            -- ★ A TRY HEAD EVALUATES NOTHING. It has no condition and no header — the
            -- acquisition, if any, is its own row (PREFIELD) and the body/handlers are
            -- theirs. For java/js/python that fell out for free, because du(stop_body) halts
            -- at the `block` child; ruby's `begin` hangs its body statements DIRECTLY, so du
            -- walked them and the head row claimed to def the exception variable and read
            -- every name in the block. A container is not a computation.
            if TRY_[t] then stmts[idx].def, stmts[idx].use, stmts[idx].rmw = {}, {}, nil end
            -- ★ A BLOCK HEAD BINDS ITS PARAMETERS — and reading that off du would have
            -- fabricated defs OR invented free uses, which is why it is read off
            -- param_names instead (CART-0363 part B). `|x|` was a USE until now: the third
            -- phantom free variable after the collection-loop variable and the exception
            -- variable, and the same defect class — a read of a name nothing defines,
            -- believed by liveness, reaching and narrowing alike.
            -- THE TWO WAYS TO GET IT WRONG, both avoided here. Marking the whole
            -- `block_parameters` subtree def-position (the LOOPVAR/WRAP route) turns
            -- `|opt = f(z)|` into defs of `f` and `z` — a FABRICATED def, the worse of the
            -- two failure modes. Taking only each wrapper's first identifier (the plain
            -- param_names rule) drops `b` from `|(a, b)|` and leaves it a free use — hence
            -- the DESTRUCT recursion added there. What is left over after subtracting the
            -- binders is a genuine READ: a default expression is evaluated, so `f` and `z`
            -- stay uses of the head row.
            local bf = BLOCKS_ and BLOCKS_[t]
            if bf then
                local pd = param_names(node, src, bf, false)
                local bound = {}
                for _, nm in ipairs(pd) do bound[nm] = true end
                local u2 = {}
                for _, nm in ipairs(stmts[idx].use) do
                    if not bound[nm] then u2[#u2 + 1] = nm end
                end
                stmts[idx].def, stmts[idx].use = pd, u2
                -- (the COARSE projection must not take these defs — see M.coarse, which
                --  recognises them from `cls.blocks[s.t]` rather than a stored flag: a
                --  field would have to survive the fold, and a set the store drops is
                --  precisely how PRELOOP broke)
            end
            -- ★ A HEADER PART IS NOT A BODY STATEMENT. A for-of's `left`/`right` are fielded
            -- children that are neither the condition nor the body, and the fallback below
            -- emits any such child as a body row — so `for (const x of xs)` gained two
            -- `identifier` rows that appear to execute each iteration. Scoped to the types the
            -- SPEC added (cfg.ctrl): the base languages keep their current modelling, wrong or
            -- not, so this change cannot move a lua/php/python row. Their header rows are
            -- CART-0362's business, and moving them here would reorder every lua function.
            local body_field = ((cfg.ctrl and cfg.ctrl[t]) or BODYFIELD[t])
                and node:field('body')[1] or nil
            -- a HEAD-ONLY form has no `body` field at all: every named child that is not
            -- the head and not a clause IS a body statement, which is what the generic
            -- loop below already does once body_field stays nil.
            for gc in node:iter_children() do
                if gc:named() and gc ~= cond and not (finit and gc:id() == finit:id())
                    and not (body_field and gc:id() ~= body_field:id()
                             and not CLAUSE_[gc:type()]) then
                    local gt = gc:type()
                    if COMMENT[gt] then -- skip
                    elseif BODY_[gt] then
                        region(gc, idx, 'body')          -- php block body / loop body
                    elseif CLAUSE_[gt] then
                        clause(gc, idx)                  -- else/elseif/case/catch
                    else
                        emit(gc, idx, 'body')            -- lua inline body statement
                    end
                end
            end
            if POST[t] and cond then
                local cd, cu, _, _, cblk = du(cond, src, false, lang, FN, DUSTOP)
                local ci = #stmts + 1
                stmts[ci] = { l = line(cond), c = startcol(cond), kind = 'cond',
                    parent = idx, pol = 'cond', def = cd, use = cu,
                    expr = cfg.expr and cfg.expr(cond, src, 'cond') or nil }
                emit_blocks(cblk, ci)
            end
        end
        return idx -- the HEAD row of this statement, for the labeled path above
    end

    -- a block/region: its direct named children are statements. CLAUSE children
    -- (a C switch body is a compound_statement of `case_statement`s) route to
    -- clause() so their bodies are regioned, not folded.
    function region(block, parent, pol)
        for c in block:iter_children() do
            if c:named() then
                local ct = c:type()
                if not COMMENT[ct] then
                    if CLAUSE_[ct] then clause(c, parent) else emit(c, parent, pol) end
                end
            end
        end
    end

    -- a clause (else/elseif/case/catch): elseif is its own guard (control row);
    -- the rest region their statements under `parent`
    function clause(node, parent)
        if CASE_[node:type()] then
            -- a switch case: the `value` label is a USE; the statement body is
            -- REGIONED as rows (was folded into the case row, hiding it from the
            -- fine model + blocking case CFG feasibility). break rows inside now
            -- surface — successors routes them to the switch join.
            -- ★ THE LABEL IS NOT ALWAYS A FIELD. C/go spell it `value`; java hangs a
            -- `switch_label` CHILD instead. Without this the label emitted as its own
            -- statement row — a row for something that does not execute — and the case row
            -- carried no uses at all.
            -- ★ THE LABEL IS NOT ALWAYS A `value` FIELD, AND IT IS NOT ALWAYS ONE NODE.
            -- C/go spell it `value`; java hangs a `switch_label` CHILD; ruby's `when` has a
            -- `pattern` FIELD and `when 1, 2` has TWO of them. A label does not EXECUTE, so
            -- every one of these must be a USE on the case row and NONE of them a body
            -- statement — ruby's `pattern` was emitting as a row of its own.
            -- ★ BY FIELD, NEVER BY THE TYPE NAME `pattern`: js, ts, tsx, python, java and
            -- haskell all have a `pattern` node too (checked via language.inspect), so a base
            -- set keyed on it would reach six languages that never asked (CART-0387).
            local labels = M.case_labels(node) -- ONE reader; the expr harvest calls it too
            local islabel = {}
            for _, x in ipairs(labels) do islabel[x:id()] = true end
            local d, u, lblk = {}, {}, {}
            do -- def/use over EVERY label, deduped
                local ds, us = {}, {}
                for _, x in ipairs(labels) do
                    local xd, xu, _, _, xb = du(x, src, false, lang, FN, DUSTOP)
                    for _, nm in ipairs(xd) do if not ds[nm] then ds[nm] = true; d[#d + 1] = nm end end
                    for _, nm in ipairs(xu) do if not us[nm] then us[nm] = true; u[#u + 1] = nm end end
                    for _, b in ipairs(xb or {}) do lblk[#lblk + 1] = b end
                end
            end
            -- ★ A DEFAULT ARM IS THE ONE WITH NO LABEL, and that is decidable HERE without
            -- another name set: `default:` / `switch_default` / go's `default_case` all carry
            -- no value and no pattern. Marking it distinctly is what lets successors know a
            -- switch is EXHAUSTIVE — the CASE branch used to stamp pol='case' on every arm,
            -- so a C/java/php `default:` was indistinguishable from a case arm and the
            -- exhaustiveness rule could not fire for those languages at all (CART-0390).
            local idx = #stmts + 1
            stmts[idx] = { l = line(node), c = startcol(node), kind = 'case', parent = parent,
                pol = (#labels == 0) and 'default' or 'case', def = d, use = u, t = node:type() }
            if cfg.expr then stmts[idx].expr = cfg.expr(node, src, 'casehead') end
            emit_blocks(lblk, idx)  -- a block inside a case LABEL (`when xs.any? { … }`)
            for c in node:iter_children() do
                if c:named() and not islabel[c:id()] and not COMMENT[c:type()] then
                    if BODY_[c:type()] then region(c, idx, 'body') else emit(c, idx, 'body') end
                end
            end
            return
        end
        if ELSEIF_[node:type()] then
            -- an elseif is a guard (its condition) over a body: emit the control
            -- row (condition only, stop_body) and REGION its consequence as rows
            -- (was folded — the body statements were invisible). lua
            -- `elseif_statement` / python `elif_clause`: body under `consequence`.
            -- a HEAD-ONLY link (`#elif COND`, `#else`) is walked at its head field, for
            -- the reason the CTRL head gives: its statements hang directly under it.
            local hfe = HEADFIELD[node:type()]
            local dn = node
            if hfe ~= nil then dn = hfe and node:field(hfe)[1] or nil end
            local d, u, _, _, eblk = {}, {}, nil, nil, {}
            if dn then
                d, u, _, _, eblk = du(dn, src, true, lang, FN, DUSTOP, CTRL_, CLAUSE_)
            end
            local idx = #stmts + 1
            stmts[idx] = { l = line(node), c = startcol(node), kind = node:type(), parent = parent,
                pol = 'elseif', def = d, use = u, t = node:type() }
            if cfg.expr then stmts[idx].expr = cfg.expr(node, src, 'ctrlhead') end
            emit_blocks(eblk, idx)  -- a block inside the guard (`elsif xs.any? { … }`)
            -- ★ AN elsif CHAIN THAT NESTS WAS TRUNCATED AT THE FIRST LINK (found while
            -- measuring part B; shipped by part A). lua, python and bash make their
            -- elseif/elif clauses SIBLINGS of the `if`, so the loop that emits the if's
            -- children walks the whole chain. RUBY NESTS: an `elsif` carries the next
            -- `elsif`/`else` as its own `alternative`, and this branch regioned the
            -- CONSEQUENCE and returned — so everything past the first `elsif` had NO ROWS.
            -- MEASURED on `if a … elsif b … elsif c … else … end`: ruby produced 4 rows
            -- where python's identical chain produced 7. Real code hit it — activesupport's
            -- parameter_filter lost a whole `elsif` guard and its `else`.
            -- ★ BY THE `alternative` FIELD, NEVER BY "any CLAUSE-typed child". The first cut
            -- routed every CLAUSE child and BROKE BASH, because `case_statement` is in the
            -- base CLAUSE set as C/php's switch ARM while bash spells its whole `case … esac`
            -- CONTROL statement that way — so a bash `case` inside an elif started emitting
            -- as a switch arm of the enclosing `if`. Same name-collision lesson as `pattern`
            -- and `block`: ask the grammar for the FIELD that means "the rest of the chain".
            -- ROUTED TO `parent`, NOT `idx`: the chain is semantically FLAT, and flat under
            -- the `if` head is exactly what lua/python/bash already produce and what
            -- successors' exhaustive-arm rule reads.
            local cons = node:field('consequence')[1] or node:field('body')[1]
            local alt = node:field('alternative')[1]
            if cons and BODY_[cons:type()] then
                region(cons, idx, 'body')
            else -- fallback: region non-condition named children
                local condn = node:field('condition')[1]
                for c in node:iter_children() do
                    if c:named() and c ~= condn and c ~= alt and not COMMENT[c:type()] then
                        if BODY_[c:type()] then region(c, idx, 'body') else emit(c, idx, 'body') end
                    end
                end
            end
            if alt and CLAUSE_[alt:type()] then clause(alt, parent) end
            return
        end
        if CATCH_[node:type()] then
            -- the header binds the exception var (DEF) and references the type
            -- (use); the body regions under it. Without this the caught var is
            -- unbound in the fine model and df's spurious use of it is unmatched.
            local d, u, _, _, kblk = du(node, src, true, lang, FN, DUSTOP,
                CTRL_, CLAUSE_)
            local idx = #stmts + 1
            stmts[idx] = { l = line(node), c = startcol(node), kind = 'catch', parent = parent,
                pol = 'catch', def = d, use = u }
            emit_blocks(kblk, idx)
            -- python `except_clause` has no `body` field (the block is an unnamed
            -- child); fall back to the first BODY-type child.
            local b = node:field('body')[1]
            if not (b and BODY_[b:type()]) then
                for c in node:iter_children() do
                    if BODY_[c:type()] then b = c break end
                end
            end
            if b and BODY_[b:type()] then region(b, idx, 'catch') end
            return
        end
        local ct = node:type()
        -- ★ THE CLAUSE MAP NAMES THE POL when it can. The name-substring fallback below only
        -- works for languages that spell a clause after its role — ruby's `ensure` contains
        -- neither "finally" nor any other tell, and would have landed as a generic 'clause',
        -- which successors' TRY branch routes as an ordinary sibling instead of the
        -- normal-completion path. A declared role beats a guess at the spelling.
        local declared = CLAUSEMAP and CLAUSEMAP[ct]
        local pol = (type(declared) == 'string' and declared ~= 'elseif' and declared) or nil
        pol = pol or (ct:find('else') and 'else' or ct:find('case') and 'case'
            or ct:find('catch') and 'catch' or ct:find('finally') and 'finally'
            or ct:find('default') and 'default' or 'clause')
        local b = node:field('body')[1]
        if b and BODY_[b:type()] then region(b, parent, pol) return end
        for c in node:iter_children() do
            if c:named() and not COMMENT[c:type()] then
                if BODY_[c:type()] then region(c, parent, pol)
                else emit(c, parent, pol) end
            end
        end
    end

    -- `cfg.seq`: the node IS the statement sequence, not a function whose body
    -- must be found. A MODULE's top-level statements are the tree ROOT (lua
    -- `chunk`) — a sequence with no enclosing `body` field — so fn_body finds
    -- nothing there and every config-as-code file (a Factorio prototype, a Rails
    -- initializer) came back with zero rows. MEASURED on a Factorio 1.1 mod: 249
    -- of its 344 field-shaping assignments (72%) are module top level.
    -- region() only iterates named children, so it needs no BODY-type node.
    -- cfg.body_of: the per-language POSITIONAL body reader, for a grammar that does
    -- not label the body (odin nests it inside a `procedure` wrapper). fn_body's
    -- field-then-direct-child search cannot see a GRANDCHILD, and it must not fall
    -- back to `fnnode` itself — that walks the parameters as bogus statements.
    local body = cfg.seq and fnnode
        or (cfg.body_of and cfg.body_of(fnnode)) or fn_body(fnnode)
    if body then region(body, 0, nil) end
    -- `cfg.method` seeds an implicit 'self' param — a per-language POLICY the
    -- caller decides (df seeds self only for lua colon-methods: `method and
    -- lang=='lua'`). Default false: no implicit receiver.
    -- A sequence has no parameters: a chunk has no `parameters` field, so
    -- param_names would return {} anyway — skipped explicitly because asking a
    -- non-function for its parameters is a category error, not a lucky nil.
    -- ★ THE WHOLE CLASS TABLE RIDES ON THE RECORD, not just `preloop` (CART-0382). Two
    -- persistence paths for two classes is exactly how the preloop bug happened: build
    -- stashed one field, the store dropped it, and the CFG phases fell back to base. One
    -- table, one accessor, one fallback.
    return { stmts = stmts, cfg = cfg, preloop = PRELOOP_, cls = cls,
        params = (not cfg.seq)
            and param_names(fnnode, src, cfg.pfield, cfg.method or false, cfg.params_of) or {} }
end

--- coarse projection: df's partition — TOP-LEVEL statements, each aggregating
--- its whole subtree's def/use (df's control-row semantics), with df's rules
--- (def deduped; a name def'd in the coarse stmt is not also a use).
-- The PRE-condition-loop set this flow record was built with. `build` merges the spec's
-- per-language `preloop` into the base and stashes it; the CFG phases below are separate
-- functions and cannot see a build-local (CART-0363). Falls back to the base for a record
-- built before the field existed, or by a caller that passed no spec.
local function PRELOOP_OF(flow) return (flow and flow.preloop) or PRELOOP end
local function IFS_OF(flow) return (flow and flow.cls and flow.cls.ifs) or IF_T end
local function TRY_OF(flow) return (flow and flow.cls and flow.cls.try) or TRY_T end
local function SWITCH_OF(flow) return (flow and flow.cls and flow.cls.switch) or SWITCH end

--- "is this node type a LOOP", for the consumers that used to each keep their own answer
--- (CART-0383). Language-aware via the record's class table; falls back to the base set.
---@param fl table|nil  a flow record (M.build or M.record)
---@return table  a set of node types
function M.loops_of(fl)
    if fl and fl.cls and fl.cls.loops then return fl.cls.loops end
    local L = {}
    for k in pairs(PRELOOP) do L[k] = true end
    L.repeat_statement = true
    return L
end

function M.coarse(flow)
    local stmts = flow.stmts
    -- attached-block heads, DERIVED from the record's class table rather than read off a
    -- per-row flag: a flag would have to survive the columnar fold, and a set the store
    -- silently drops is exactly how PRELOOP broke (CART-0382). M.record attaches `cls`.
    local BLK = flow.cls and flow.cls.blocks
    -- map each row to its top-level ancestor (parent==0)
    local top = {}
    for i, s in ipairs(stmts) do
        top[i] = s.parent == 0 and i or top[s.parent]
    end
    -- ORDER-SENSITIVE aggregation (df's per-statement rule): rows are in
    -- pre-order DFS = df's walk order. A name is a USE only if used before it
    -- is def'd in the coarse stmt (so `while i… do i=i+1` keeps i as BOTH use
    -- and def); a def def'd first shadows a later use.
    local order, def, use, sd, su = {}, {}, {}, {}, {}
    for i, s in ipairs(stmts) do
        local t = top[i]
        if s.parent == 0 then
            order[#order + 1] = i
            def[t], use[t], sd[t], su[t] = {}, {}, {}, {}
        end
        for _, nm in ipairs(s.use) do
            if not sd[t][nm] and not su[t][nm] then
                su[t][nm] = true; use[t][#use[t] + 1] = nm
            end
        end
        -- ★ A BINDING THIS PROJECTION CANNOT SCOPE MUST NOT SHADOW (CART-0363 part B).
        -- An attached block's parameter is scoped to the BLOCK, and coarse is by contract
        -- "deliberately flat and scope-BLIND" — so a `|value|` admitted here becomes a
        -- function-level binding, and every later bare `value` call in the method reads as
        -- a call through a local. MEASURED: 37 calls across rails + activesupport moved
        -- `unresolved` -> `refused (fn-value)`, and the two read by hand are both FALSE —
        -- `Duration.new(value + …)` sits AFTER the block that binds `value`, and
        -- `message_pack_pool.packer do |packer|` has the parameter shadowing the very
        -- method the block is passed to. An unresolved call says "I do not know"; a refusal
        -- says "it is a call through a local", which is a POSITIVE CLAIM and here a wrong
        -- one — the failure mode this repo names everywhere else.
        -- ★ THE TRADE IS DELIBERATE AND NAMED: the block parameter goes back to being a
        -- free USE at the COARSE level, which is exactly parity with legacy df (it has no
        -- such def either) — and the FINE model, the model of record, still binds it. So
        -- the truth is not lost, only kept out of a projection that cannot hold it.
        -- Its USES stay: `|opt = f(z)|` really does read f and z. Lifts when ruby block
        -- scope lands (CART-0396), which is where this belongs.
        if not (BLK and s.t and BLK[s.t]) then
            for _, nm in ipairs(s.def) do
                if not sd[t][nm] then sd[t][nm] = true; def[t][#def[t] + 1] = nm end
            end
        end
    end
    local out = {}
    for _, i in ipairs(order) do
        out[#out + 1] = { l = stmts[i].l, def = def[i], use = use[i], dep = {} }
    end
    -- dep + free inputs: df's flat FIRST-def-wins reaching scan over the coarse
    -- statements (params seed defined=0; a use is a dep on the FIRST stmt that
    -- defined it, else a free input). This is the coarse PARITY projection —
    -- deliberately flat and scope-BLIND, matching df exactly. Scope-aware
    -- reaching (block vs function/hoisted regimes) is the FINE model,
    -- M.reaching_cfg — the coarse partition has no blocks to scope over.
    -- ([[cartograph-df-strangler]])
    local defined, inset, inputs = {}, {}, {}
    for _, p in ipairs(flow.params or {}) do defined[p] = 0 end
    for si, st in ipairs(out) do
        for _, u in ipairs(st.use) do
            local from = defined[u]
            if from and from > 0 then
                st.dep[#st.dep + 1] = { from = from, var = u }
            elseif from == nil and not inset[u] then
                inset[u] = true; inputs[#inputs + 1] = u
            end
        end
        for _, d in ipairs(st.def) do
            defined[d] = defined[d] or si
        end
    end
    return out, inputs
end

-- ── CFG phase 2: successor edges over the fine rows ─────────────────────────
local RET_T = { return_statement = true, throw_statement = true,
    raise_statement = true }

--- Structured control-flow SUCCESSOR edges over flow's fine rows (CFG phase 2 +
--- 2b, [[cartograph-cfg-scope]]). Returns { succ = {[row] = <succ ids>},
--- entry = <id|'exit'>, EXIT = 'exit' }. Node ids are row indices; 'exit' is
--- the function-exit sentinel. Models:
---  • sequential flow; early exits (return/throw/raise→exit);
---  • if/then/else (elseif rows are alternatives off the head);
---  • PRE-condition loops (while/for): body + back-edge to head + zero-trip skip
---    (suppressed when the condition is constant-true — while(true)/rust `loop`);
---    break→loop exit, continue→head;
---  • POST-condition loops (do-while / lua repeat-until, phase-2b): body runs
---    once BEFORE the test, so NO zero-trip; the trailing `cond` row is the loop
---    join (back-edge to body + exit); `do{}while(0)` (const-false) drops the
---    back-edge (one-shot); break→exit, continue→cond;
---  • lua `do...end`: a plain lexical block (no loop);
---  • try/catch/finally (phase-2b): a throw may occur at ANY try-body point, so
---    every catch is reachable from every such point (sound); finally is on the
---    normal completion path.
--- SOUND over-approximation for the rest — switch/match branch to every
--- sub-region entry + the join (infeasible edges possible → CONSERVATIVE
--- dataflow, never unsound). Chained-elseif / distinct-case feasibility is
--- blocked on build folding clause bodies into the clause row (remaining).
function M.successors(flow)
    local S = flow.stmts
    local region = {} -- region[parent][pol] = ordered row ids
    for i, s in ipairs(S) do
        local p, pol = s.parent, s.pol or ''
        local rp = region[p]; if not rp then rp = {}; region[p] = rp end
        local rr = rp[pol]; if not rr then rr = {}; rp[pol] = rr end
        rr[#rr + 1] = i
    end
    local succ = {}
    local hedged = {} -- CONSERVATIVE edges (may be infeasible): [a][b]=true. Reaching
    -- via ONLY these is `~` (INC C). Currently the try "may-throw-anywhere" edges.
    local function add(a, b) local l = succ[a]; if not l then l = {}; succ[a] = l end l[#l + 1] = b end
    local function addh(a, b) add(a, b); local h = hedged[a]; if not h then h = {}; hedged[a] = h end h[b] = true end
    -- every row transitively under `roots` (via all sub-regions) — the try-body
    -- subtree for exceptional edges
    local function subtree(roots)
        local seen, stack = {}, {}
        for _, x in ipairs(roots or {}) do stack[#stack + 1] = x end
        while #stack > 0 do
            local x = table.remove(stack)
            if not seen[x] then
                seen[x] = true
                local rr = region[x]
                if rr then for _, l in pairs(rr) do for _, y in ipairs(l) do stack[#stack + 1] = y end end end
            end
        end
        return seen
    end
    -- CONTROL TRANSFER (non-local-transfer): `gotomap` = label DEFINITIONS (a
    -- labeled loop's head, a C label target) → row, for `goto`'s unstructured
    -- jump (global — goto reaches any label). Labeled break/continue instead ride
    -- `lbls`, a SCOPED map {label → {brk,cont}} for ENCLOSING labeled loops,
    -- threaded through wire and extended per labeled loop.
    local gotomap = {}
    for i, s in ipairs(S) do
        if s.label and not TRANSFER[s.t] then gotomap[s.label] = i end
    end
    local function extend(m, k, v) return setmetatable({ [k] = v }, { __index = m }) end
    -- wire `rows` as a sequence completing to `after`; brk/cont = innermost loop
    -- exit/head; lbls = labeled-loop targets in scope
    local function wire(rows, after, brk, cont, lbls)
        if not rows or #rows == 0 then return after end
        for i = 1, #rows do
            local r, nxt = rows[i], (rows[i + 1] or after)
            local s, kids = S[r], region[r]
            local t = s.t
            -- SUSPENSION (yield/await): control may leave to the caller/scheduler
            -- here (suspend → exit), IN ADDITION to resuming at the normal
            -- successor the dispatch below adds. Resume-scheduling is external → a
            -- `~` in spirit; the edge itself is sound (control can leave here).
            if s.suspend then add(r, 'exit') end
            if RET_T[t] then add(r, 'exit')
            elseif t == 'break_statement' then
                local tgt = s.label and lbls[s.label] -- labeled → that loop's exit
                add(r, tgt and tgt.brk or brk or 'exit')
            elseif t == 'continue_statement' then
                local tgt = s.label and lbls[s.label] -- labeled → that loop's head
                add(r, tgt and tgt.cont or cont or 'exit')
            elseif t == 'goto_statement' then
                add(r, (s.label and gotomap[s.label]) or 'exit') -- jump; no fall-through
            elseif kids and kids['cond'] then
                -- POST-condition loop (do-while / lua repeat-until): body runs
                -- once before the test → NO zero-trip; the `cond` row is the join.
                local condrow = kids['cond'][1]
                local lb = s.label and extend(lbls, s.label, { brk = nxt, cont = condrow }) or lbls
                local bentry = wire(kids['body'], condrow, nxt, condrow, lb) -- break→exit, continue→cond
                add(r, bentry)                                    -- always enter body
                if s.const ~= false then add(condrow, bentry) end -- back-edge (dropped for do{}while(0))
                if s.const ~= true then add(condrow, nxt) end     -- loop exit
                for pol, rr in pairs(kids) do
                    if pol ~= 'body' and pol ~= 'cond' then add(r, wire(rr, nxt, brk, cont, lbls)) end
                end
            elseif kids and PRELOOP_OF(flow)[s.kind] then
                -- PRE-condition loop (while/for): test first → zero-trip skip,
                -- suppressed when constant-true (while(true), rust `loop`).
                local lb = s.label and extend(lbls, s.label, { brk = nxt, cont = r }) or lbls
                add(r, wire(kids['body'], r, nxt, r, lb)) -- body, back-edge to head
                if s.const ~= true then add(r, nxt) end
                for pol, rr in pairs(kids) do -- python for/while `else`, etc.
                    if pol ~= 'body' then add(r, wire(rr, nxt, brk, cont, lbls)) end
                end
            elseif kids and TRY_OF(flow)[t] then
                -- exception edges: a throw may occur at ANY try-body point, so
                -- every catch handler is reachable from every such point (sound).
                -- finally (if present) is on the normal completion path; the
                -- uncaught-propagation path to fn-exit is left implicit (a hedge —
                -- it only ever adds `exit`, whose live-in is empty, so liveness
                -- stays sound).
                local after2 = kids['finally'] and wire(kids['finally'], nxt, brk, cont, lbls) or nxt
                add(r, wire(kids['body'], after2, brk, cont, lbls)) -- normal entry
                if kids['catch'] then
                    local trybody = subtree(kids['body'])
                    for _, crow in ipairs(kids['catch']) do
                        local centry = wire(region[crow] and region[crow]['catch'], after2, brk, cont, lbls)
                        add(crow, centry)                          -- bind exc var → handler body
                        addh(r, crow)                              -- exception at/near entry (conservative)
                        for tr in pairs(trybody) do addh(tr, crow) end -- throw anywhere (conservative)
                    end
                end
                for pol, rr in pairs(kids) do -- python try/except `else` etc.: sound over-approx
                    if pol ~= 'body' and pol ~= 'catch' and pol ~= 'finally' then add(r, wire(rr, after2, brk, cont, lbls)) end
                end
            elseif kids and IFS_OF(flow)[s.kind] then
                add(r, wire(kids['body'], nxt, brk, cont, lbls))
                local hasfalse = false
                for _, pol in ipairs({ 'elseif', 'else' }) do
                    if kids[pol] then
                        for _, e in ipairs(kids[pol]) do add(r, e); wire({ e }, nxt, brk, cont, lbls) end
                        hasfalse = true
                    end
                end
                if not hasfalse then add(r, nxt) end -- no else → condition may fall through
            elseif kids and t == 'do_statement' then
                add(r, wire(kids['body'], nxt, brk, cont, lbls)) -- lua `do...end`: plain block
            elseif kids and SWITCH_OF(flow)[t] then
                -- switch: cases fall through in order; break exits the switch, so
                -- the case bodies are wired with brk = nxt (the switch join).
                -- ★ LANGUAGE-AWARE (CART-0387): ruby spells it `case`, so it never reached
                -- this branch and fell to the generic one — which passes `brk` THROUGH, so a
                -- `break` inside a ruby case escaped to the ENCLOSING LOOP instead of the
                -- switch join. Reaching the branch fixes that for free.
                for _, rr in pairs(kids) do add(r, wire(rr, nxt, nxt, cont, lbls)) end
                -- ★ AND AN EXHAUSTIVE SWITCH CANNOT BE SKIPPED, the same rule the IF branch
                -- already applies: a `default`/`else` arm means control MUST enter one of the
                -- arms, so the head does not also fall through. Without this the CFG claimed
                -- every switch could be skipped entirely — and optapply's PRE is built on
                -- exactly this exhaustiveness property.
                local hasfalse = false
                for _, pol in ipairs({ 'default', 'else' }) do
                    if kids[pol] then hasfalse = true end
                end
                if not hasfalse then add(r, nxt) end -- no default → no arm may match
            elseif kids then -- match/try/other control head: sound over-approx
                for _, rr in pairs(kids) do add(r, wire(rr, nxt, brk, cont, lbls)) end
                add(r, nxt)
            else
                add(r, nxt)
            end
        end
        return rows[1]
    end
    local entry = wire(region[0] and region[0][''], 'exit', nil, nil, {})
    return { succ = succ, entry = entry, EXIT = 'exit', hedged = hedged }
end

--- PREDECESSOR edges — the transpose of M.successors. Returns
--- `pred = {[row] = { predecessor rows }}`, with `pred['exit']` = the rows that
--- flow to the function exit (return/throw/fall-through end) — the roots for a
--- BACKWARD walk, the mirror of `entry` for the forward direction. A backward
--- walk needs a visited-set (loop back-edges make the reverse graph cyclic too)
--- and inherits the successor graph's conservative over-approximation (it may
--- over-include predecessors — same uniform honesty as forward). The substrate
--- for backward slicing + reaching-with-joins ([[cartograph-cfg-scope]]).
function M.predecessors(flow)
    local succ = M.successors(flow).succ
    local pred = {}
    for a, outs in pairs(succ) do
        for _, b in ipairs(outs) do
            local p = pred[b]; if not p then p = {}; pred[b] = p end
            p[#p + 1] = a
        end
    end
    return pred
end

--- LIVENESS over the successor graph (backward dataflow to fixpoint) — the
--- canonical phase-2 consumer (data-lifecycle reading (a)). Returns
--- { live_in = {[row]=set}, live_out = {[row]=set} } (set = name→true). A var
--- is live at a point if it may be READ before being overwritten on some path.
--- live_out[n] = ∪ live_in[succ]; live_in[n] = use[n] ∪ (live_out[n] \ def[n]).
--- Over-approximate where M.successors is (conservative — never misses a live).
function M.liveness(flow)
    local S = flow.stmts
    local succ = M.successors(flow).succ
    local li, lo = {}, {}
    for i = 1, #S do li[i] = {}; lo[i] = {} end
    local function seteq(a, b)
        for k in pairs(a) do if not b[k] then return false end end
        for k in pairs(b) do if not a[k] then return false end end
        return true
    end
    local changed, guard = true, 0
    while changed and guard < 100000 do
        changed = false; guard = guard + 1
        for i = #S, 1, -1 do
            local o = {}
            for _, s in ipairs(succ[i] or {}) do
                if s ~= 'exit' and li[s] then for k in pairs(li[s]) do o[k] = true end end
            end
            local n = {}
            for k in pairs(o) do n[k] = true end
            for _, d in ipairs(S[i].def) do n[d] = nil end
            for _, u in ipairs(S[i].use) do n[u] = true end
            if not seteq(o, lo[i]) or not seteq(n, li[i]) then changed = true end
            lo[i], li[i] = o, n
        end
    end
    return { live_in = li, live_out = lo }
end

--- REACHING DEFINITIONS over the CFG (forward dataflow to fixpoint) — INC A of
--- reaching-on-CFG ([[cartograph-cfg-scope]]). For each use, the SET of defs
--- that reach it along successor paths: a branch join → multiple defs; a loop
--- back-edge → the pre-loop def AND the loop's own. Params reach from the entry
--- sentinel 0. gen[n]={(v,n):v∈def[n]}, kill = the other defs of those vars;
--- reach_in[n] = ∪ reach_out[pred] (+ params at entry); reach_out = gen ∪
--- (reach_in \ kill). Control reaching (INC A) is then SCOPE-FILTERED (INC B):
--- a block-regime def in a now-closed block is dropped (block-death),
--- function/hoisted-regime survives, params are always in scope. INC C: each
--- edge also carries `hedged` = the subset of `from` that reaches ONLY via a
--- CONSERVATIVE edge (in `from` but not in the exact-edges reaching) — currently
--- the try may-throw-anywhere edges; a def reaching a catch use is `~`. (Switch
--- fall-through / go-no-fall-through is language-dependent → not tagged yet.)
--- Returns a list of { at=<use row>, var, from={def rows; 0=param/entry},
--- hedged={def rows reaching only conservatively, ~} | nil }.
function M.reaching_cfg(flow)
    local S = flow.stmts
    local cfg = M.successors(flow)
    local pred = M.predecessors(flow)
    local hedged = cfg.hedged or {}
    local entry = cfg.entry
    local seed = {} -- params reach from sentinel 0
    for _, p in ipairs(flow.params or {}) do
        seed[p] = seed[p] or {}; seed[p][0] = true
    end
    -- EXACT predecessors = pred MINUS the conservative (hedged) edges. Reaching
    -- computed over these is what feasibly reaches; a def in the full set but not
    -- this one reaches ONLY via a conservative edge → `~` (INC C).
    local pred_exact = {}
    for n, ps in pairs(pred) do
        local keep = {}
        for _, a in ipairs(ps) do
            if not (type(a) == 'number' and hedged[a] and hedged[a][n]) then keep[#keep + 1] = a end
        end
        pred_exact[n] = keep
    end
    local function mergeinto(dst, src)
        for v, defs in pairs(src) do
            local d = dst[v]; if not d then d = {}; dst[v] = d end
            for r in pairs(defs) do d[r] = true end
        end
    end
    local function eqmap(a, b)
        for v, defs in pairs(a) do
            local bd = b[v]; if not bd then return false end
            for r in pairs(defs) do if not bd[r] then return false end end
        end
        for v, defs in pairs(b) do
            if not a[v] then return false end
            for r in pairs(defs) do if not a[v][r] then return false end end
        end
        return true
    end
    -- block-declared vars per region (a BLOCK-regime def, keyed by its enclosing
    -- region S[d].parent) — the binding table an assignment resolves against.
    local blockdecl = {}
    for d = 1, #S do
        if S[d].regime == 'block' then
            local set = blockdecl[S[d].parent]
            if not set then set = {}; blockdecl[S[d].parent] = set end
            for _, v in ipairs(S[d].def) do set[v] = true end
        end
    end
    -- SCOPE of a def of `v` at row `r` = the region the BINDING lives in. A BLOCK
    -- declaration is scoped to its enclosing region (its parent). A plain
    -- ASSIGNMENT does NOT open a scope — it writes the binding visible at its
    -- position — so it is scoped to the nearest ENCLOSING region that block-declares
    -- `v` (walk r's region-parent chain); a function-level binding / no enclosing
    -- decl → function scope (region 0). This is what makes a block-local's KILL and
    -- its later in-block reads region-correct even when the write is a reassignment
    -- nested in an inner loop ([[flow-precision-gaps]] #2, comprehensive fix).
    local function scope_of(r, v)
        if r == 0 then return 0 end
        if S[r].regime == 'block' then return S[r].parent end
        local R = S[r].parent
        while R ~= 0 do
            if blockdecl[R] and blockdecl[R][v] then return R end
            R = S[R].parent
        end
        return 0
    end
    -- region `a` is `b` or nested inside it (walk a's region-parent chain to b)
    local function subscope(a, b)
        if b == 0 then return true end -- the function scope encloses everything
        local cur = a
        while cur ~= 0 do
            if cur == b then return true end
            cur = S[cur].parent
        end
        return false
    end
    -- reaching-definitions fixpoint over a predecessor map → reach_in per row
    local function run(predof)
        local rout, rin = {}, {}
        for i = 1, #S do rout[i] = {} end
        local changed, guard = true, 0
        while changed and guard < 100000 do
            changed = false; guard = guard + 1
            for n = 1, #S do
                local i = {}
                if n == entry then mergeinto(i, seed) end
                for _, p in ipairs(predof[n] or {}) do
                    if type(p) == 'number' then mergeinto(i, rout[p]) end
                end
                rin[n] = i
                local defset = {}
                for _, v in ipairs(S[n].def) do defset[v] = true end
                local o = {}
                for v, defs in pairs(i) do -- reach_in \ kill (vars n does NOT redefine survive)
                    if not defset[v] then
                        local d = {}; for r in pairs(defs) do d[r] = true end; o[v] = d
                    end
                end
                -- gen with SCOPED kill (INC B′, shadow/restore-as-edges): n's def
                -- of v kills prior defs whose scope is n's scope or NESTED inside
                -- it; it only MASKS defs in an ENCLOSING scope (they survive past
                -- n and are RESTORED once n's block exits — the fix for the
                -- block-kill leak). regime drives the scope: a `local` shadow in a
                -- block masks the outer; a plain assignment (function-scoped)
                -- kills it. ([[cartograph-df-strangler]] step-5 fine half)
                for _, v in ipairs(S[n].def) do
                    local sn = scope_of(n, v)
                    local kept = { [n] = true }
                    for m in pairs(i[v] or {}) do
                        if not subscope(scope_of(m, v), sn) then kept[m] = true end -- enclosing → mask
                    end
                    o[v] = kept
                end
                if not eqmap(o, rout[n]) then rout[n] = o; changed = true end
            end
        end
        return rin
    end
    local rin = run(pred)              -- all edges (INC A/B)
    local rin_exact = run(pred_exact)  -- exact edges only (INC C)
    -- INC B: LEXICAL-SCOPE filter over the control-reaching set. region_encloses
    -- (dr, ur) = dr's region is ur's or an ANCESTOR — the binding is OPEN at ur.
    -- Order-INDEPENDENT (control order is INC A's job; conflating them with a
    -- dr<ur ordering, as the RETIRED structural reaching did, wrongly drops a
    -- block-regime def reaching an earlier same-block use via a back-edge). A block-regime
    -- def in a now-CLOSED sibling/prior block is dropped (block-death); a
    -- function/hoisted-regime def survives block exit; a param (0) is always in.
    local function region_encloses(dr, ur)
        if S[dr].parent == S[ur].parent then return true end
        local p = S[ur].parent
        while p ~= 0 do
            if S[dr].parent == S[p].parent then return true end
            p = S[p].parent
        end
        return S[dr].parent == 0
    end
    local function visible(dr, ur)
        return dr == 0 or S[dr].regime ~= 'block' or region_encloses(dr, ur)
    end
    local edges = {} -- a use of v at u sees reach_in[u][v], scope-filtered; `hedged`
    -- = the subset of `from` that reaches ONLY via a conservative edge (INC C, ~).
    for u = 1, #S do
        -- u's enclosing-region depths (0 = innermost = u's own region), for the
        -- NEAREST-scope preference below
        local depth, d, p = {}, 0, S[u].parent
        while true do depth[p] = d; if p == 0 then break end; d = d + 1; p = S[p].parent end
        -- reads = uses PLUS read-modify-write LHS names (`a = a + …`), whose self-read
        -- the df contract drops from `use` (kept in `rmw`) — [[flow-precision-gaps]] #1.
        local reads = S[u].use
        if S[u].rmw then
            reads = {}
            for _, v in ipairs(S[u].use) do reads[#reads + 1] = v end
            for _, v in ipairs(S[u].rmw) do reads[#reads + 1] = v end
        end
        for _, v in ipairs(reads) do
            local reaching, from, hset = rin[u] and rin[u][v], {}, nil
            if reaching then
                local ex = rin_exact[u] and rin_exact[u][v]
                -- NEAREST-scope preference (the restore half): among the visible
                -- reaching defs, keep only those in the INNERMOST scope — a
                -- shadowing inner masks the enclosing def AT THE USE, while the
                -- enclosing def, never killed, is what reaches uses AFTER the block.
                -- scope_of resolves an assignment to its binding's region, so a
                -- reassignment of a block-local now shares the declaration's depth
                -- and the depth filter keeps it (no special-case needed — the
                -- comprehensive fix for [[flow-precision-gaps]] #2).
                local best = math.huge
                for r in pairs(reaching) do
                    if visible(r, u) then
                        local dr = depth[scope_of(r, v)] or math.huge
                        if dr < best then best = dr end
                    end
                end
                for r in pairs(reaching) do
                    if visible(r, u) and (depth[scope_of(r, v)] or math.huge) == best then
                        from[#from + 1] = r
                        if not (ex and ex[r]) then hset = hset or {}; hset[r] = true end -- ~ (no exact path)
                    end
                end
                table.sort(from)
            end
            edges[#edges + 1] = { at = u, var = v, from = from, hedged = hset }
        end
    end
    -- OUTPUT (WAW) dependencies — the PDG's second value ([[cartograph-untangle-pdg]]):
    -- row n's def of v is output-dependent on every PRIOR def of v that reaches n
    -- (in rin[n][v]). Returned as a SEPARATE 2nd value so the RAW-edge contract
    -- (every existing caller reads only the first return) is unchanged. The
    -- scope-regime reaching already keeps reused BLOCK-locals from reaching across
    -- their blocks, so this doesn't falsely couple reused temps; a function-scoped
    -- reuse (plain reassignment) IS a real output-dep and correctly couples. Each
    -- entry is {n, d} = "n's def is output-dependent on d". (WAR/anti-deps fall out
    -- transitively for connectivity: a use rides its RAW def, which WAW-chains to
    -- the later def.)
    local waw = {}
    for n = 1, #S do
        for _, v in ipairs(S[n].def) do
            local rr = rin[n] and rin[n][v]
            if rr then
                for d in pairs(rr) do
                    if d ~= 0 and d ~= n then waw[#waw + 1] = { n, d } end
                end
            end
        end
    end
    return edges, waw
end

-- ── the fold: nested flow records → one columnar store (df-strangler step 3) ──
-- A flow record ({ stmts = {rows}, params = {names} }) is the df successor and
-- the LARGER datum — a row per statement at EVERY nesting level. The fold
-- collapses every node's record into ONE columnar store per graph, leaving each
-- node an offset+count slice (_flow0/_flown into rows, _flowp0/_flowpn into
-- params). Row VIEWS materialize on demand, shaped EXACTLY like M.build's rows,
-- so successors/coarse/liveness/reaching_cfg (all PURE functions of the rows)
-- read identically whether folded or raw. Dual-mode accessors (folded slice when
-- n._flow is set, raw n.flow otherwise) = the argv/df fold lifecycle.
--
-- SHAPE INTERNING (the flow-specific win over df's uniform-u32 scheme): df rows
-- are payload (l + variable def/use/dep); flow rows are dominated by CATEGORICAL
-- descriptors (kind/pol/t/regime/const/suspend) whose distinct combinations are
-- BOUNDED BY THE GRAMMAR, not the corpus — MEASURED at 55-71 across Java/C++/Lua
-- and a full PHP framework+deps tree. So the whole descriptor tuple interns to
-- ONE small `shape` id per row (a ~70-entry decode table) instead of six columns.
-- The remaining columns pack at their MEASURED width (parent/name-ids fit u16 on
-- every corpus; u32 fallback chosen at fold time for a pathological outlier).
-- This roughly HALVES the store vs the naive layout — putting flow's fine model
-- below df's coarse one in bytes despite carrying ~1.3-2.6x the rows.
--
-- cfg is BUILD-TIME ONLY: regime/pfield/df_ids/method are baked into each row at
-- build (regime as a per-row tag, the rest into def/use), and NOTHING reads
-- flow.cfg downstream — so cfg is not folded. This is why fold + its future
-- extraction-fusion carry no VERSION dependency on the cfg seam.

local concat = table.concat

-- shared serializable width columns (u8/u16/u32 { s, w }); df.lua uses the same module.
-- flow keeps its own per-column width choices at fold time (some from a pool size rather
-- than the array max), so it calls pack/width_for directly rather than packcol.
local bytecol = require 'cartograph.bytecol'
local pack, width_for, rd = bytecol.pack, bytecol.width_for, bytecol.rd

-- materialize one row from the columns (M.build-identical shape). The row's whole
-- categorical descriptor is one `shape` id into col.shapes (a captured table with
-- exactly the fields the built row had — absent keys stay absent, so a `cond` row
-- with no t/regime round-trips; const=false and suspend=true are preserved as the
-- shape captured them). def then use pack contiguously in `nm` (df's end-
-- derivation: use start = def end = u0[g], use end = d0[g+1]).
local function row_view(col, g)
    local nms = col.names
    local d = col.shapes[rd(col.shape, g)]
    local s = { l = rd(col.l, g), c = rd(col.c, g), parent = rd(col.parent, g), def = {}, use = {},
        kind = d.kind, pol = d.pol, t = d.t,
        regime = d.regime, const = d.const, suspend = d.suspend,
        label = col.labels[g], -- sparse (control-transfer): nil for the vast majority
        rmw = col.rmw and col.rmw[g] or nil } -- sparse (read-modify-write reads)
    local b, e = rd(col.d0, g), rd(col.u0, g)
    for j = 1, e - b do s.def[j] = nms[rd(col.nm, b + j)] end
    b, e = e, rd(col.d0, g + 1)
    for j = 1, e - b do s.use[j] = nms[rd(col.nm, b + j)] end
    return s
end

-- ── dual-mode accessors ──────────────────────────────────────────────────

--- does this node carry (non-empty) flow?
function M.has(n)
    if not n then return false end
    if n._flow then return n._flown > 0 end
    return n.flow and n.flow.stmts and #n.flow.stmts > 0 or false
end

--- has a flow record at all (may be 0-row) — the absent-vs-empty distinction
function M.present(n)
    if not n then return false end
    if n._flow then return true end
    return n.flow and n.flow.stmts ~= nil or false
end

--- row count (the common size query)
function M.count(n)
    if not n then return 0 end
    if n._flow then return n._flown end
    return (n.flow and n.flow.stmts) and #n.flow.stmts or 0
end

--- the fine rows for a node (empty when none), for ipairs iteration. Folded
--- nodes materialize views FRESH per call (transient, M.build-shaped).
function M.rows(n)
    if not n then return {} end
    local col = n._flow
    if col then
        local out, g = {}, n._flow0
        for i = 1, n._flown do out[i] = row_view(col, g + i) end
        return out
    end
    return (n.flow and n.flow.stmts) or {}
end

--- the whole flow record { stmts, params } (the shape successors/coarse/liveness/
--- reaching_cfg consume). cfg is build-time only → not restored.
-- ★ THE MERGED CLASSES ARE NOT PERSISTED, AND A LOOP THAT IS NOT A LOOP IS UNSOUND
-- (CART-0363). Extraction stores `flow = { stmts, params }` only, so a record read back from
-- the store lost the per-language sets M.build had merged, and PRELOOP_OF fell through to the
-- BASE table. Measured: a js `for…of` read from the store had NO BACK EDGE from its body to
-- its head (succ={after}, where a `while` beside it gave succ={head}), and the same held for
-- every ruby loop. That is not imprecision — reaching and liveness then believe a def in the
-- loop body never reaches the next iteration.
-- DERIVED, NOT STORED: the sets are a pure function of the LANGUAGE, so persisting them would
-- spend bytes per node on what a file extension answers — and M.classes is the one owner, so
-- the derivation cannot drift from what M.build used. Cached per language.
local cls_cache = {}
local function classes_for_node(n)
    local okts, ts = pcall(require, 'cartograph.providers.treesitter')
    if not okts or type(ts.lang_of) ~= 'function' then return nil end
    local lang = n.file and ts.lang_of(n.file)
    if not lang then return nil end
    if cls_cache[lang] == nil then
        cls_cache[lang] = M.classes((ts.spec and ts.spec[lang]) or {})
    end
    return cls_cache[lang]
end

function M.record(n)
    if not n then return nil end
    local col = n._flow
    local rec
    if col then
        local params = {}
        for i = 1, n._flowpn do params[i] = col.names[rd(col.pm, n._flowp0 + i)] end
        rec = { stmts = M.rows(n), params = params }
    else
        rec = n.flow
    end
    if rec and not rec.cls then
        local c = classes_for_node(n)
        if c then
            -- never MUTATE the stored record (it rides into the cache): copy the thin header
            if col then rec.cls, rec.preloop = c, c.preloop
            else rec = { stmts = rec.stmts, params = rec.params,
                preloop = c.preloop, cls = c } end
        end
    end
    return rec
end

--- fold every node's `.flow` record into one columnar store; drop the records.
--- Idempotent (a second call no-ops via data._flowcol). Mirrors df.fold's
--- lifecycle: run at ingest, AFTER raw records are encoded to shards.
-- The fold as an ACCUMULATOR (mirrors df.accumulator): add(nodes) folds a batch of nodes'
-- flow rows into the growing columnar state; finalize() packs it + stamps _flow. M.fold =
-- add(all)+finalize (whole-graph); the PARALLEL merge calls add() per CHUNK so the parent
-- never holds all the fat flow at once (the merge-peak lever). Byte-identical to one whole-
-- graph fold: shared interners (var names + shapes) + monotone global offsets.
function M.accumulator()
    local col = {
        shape = {}, l = {}, c = {}, parent = {},
        d0 = {}, u0 = {}, nm = {}, pm = {}, names = {}, shapes = {},
        labels = {}, -- SPARSE (global-row → label name): control-transfer targets/
        -- definitions, rare enough that a plain map beats a packed column (a
        -- merge-friendly sparse (row,name-id) packing is a later refinement).
        rmw = {}, -- SPARSE (global-row → {name,…}): read-modify-write reads dropped
        -- from `use` by the df contract; consumed by reaching_cfg. Rare → plain map.
    }
    local nid = {} -- var-name -> interned id (build-time only); 0 = nil
    local function id(nm)
        if nm == nil then return 0 end
        local i = nid[nm]
        if not i then i = #col.names + 1; col.names[i] = nm; nid[nm] = i end
        return i
    end
    -- intern the categorical descriptor tuple → a small shape id. The key
    -- distinguishes const nil/true/false and suspend nil/true (tostring), and
    -- the STORED descriptor keeps exactly the fields the row had (nil = absent).
    local sid = {}
    local function shape_of(s)
        local key = concat({ s.kind or '', s.pol or '', s.t or '',
            s.regime or '', tostring(s.const), tostring(s.suspend) }, '\1')
        local i = sid[key]
        if not i then
            i = #col.shapes + 1
            col.shapes[i] = { kind = s.kind, pol = s.pol, t = s.t,
                regime = s.regime, const = s.const, suspend = s.suspend }
            sid[key] = i
        end
        return i
    end
    local ns, nn, np, maxp, maxc = 0, 0, 0, 0, 0
    local folded = {} -- nodes folded here → stamp _flow at finalize
    local A = {}
    function A.add(nodes)
        for _, node in ipairs(nodes or {}) do
            local fl = node.flow
            if fl and fl.stmts and not node._flow then
                local s0 = ns
                for _, s in ipairs(fl.stmts) do
                    ns = ns + 1
                    col.shape[ns] = shape_of(s)
                    col.l[ns] = s.l
                    col.c[ns] = s.c
                    if s.label then col.labels[ns] = s.label end
                    if s.rmw then col.rmw[ns] = s.rmw end
                    col.parent[ns] = s.parent
                    if s.parent > maxp then maxp = s.parent end
                    if s.c > maxc then maxc = s.c end
                    col.d0[ns] = nn
                    for _, d in ipairs(s.def) do nn = nn + 1; col.nm[nn] = id(d) end
                    col.u0[ns] = nn
                    for _, u in ipairs(s.use) do nn = nn + 1; col.nm[nn] = id(u) end
                end
                local p0 = np
                for _, p in ipairs(fl.params or {}) do np = np + 1; col.pm[np] = id(p) end
                node._flow0, node._flown = s0, ns - s0
                node._flowp0, node._flowpn = p0, np - p0
                node.flow = nil
                folded[#folded + 1] = node
            end
        end
    end
    function A.finalize()
        col.d0[ns + 1] = nn -- sentinel: closes the last row's derived use count
        -- per-column widths from the measured max (u8/u16/u32) — EVERY column: l = source
        -- lines (u16 normally, u32 auto only for 65k+-line files), the nm-offsets d0/u0 =
        -- global name-pool offsets (u32 at scale, u16 for small graphs).
        local maxl = 0
        for i = 1, ns do local v = col.l[i]; if v and v > maxl then maxl = v end end
        local nw = width_for(#col.names)
        local pw = width_for(maxp)
        local sw = width_for(#col.shapes)
        local cw = width_for(maxc) -- u16 normal; u32 only for extreme minified lines
        local lw = width_for(maxl)
        local ow = width_for(nn) -- d0/u0 index the nm pool (max = nn)
        local packed = {
            shape = { s = pack(col.shape, ns, sw), w = sw },
            l = { s = pack(col.l, ns, lw), w = lw },
            c = { s = pack(col.c, ns, cw), w = cw },
            parent = { s = pack(col.parent, ns, pw), w = pw },
            d0 = { s = pack(col.d0, ns + 1, ow), w = ow },
            u0 = { s = pack(col.u0, ns, ow), w = ow },
            nm = { s = pack(col.nm, nn, nw), w = nw },
            pm = { s = pack(col.pm, np, nw), w = nw },
            names = col.names,
            shapes = col.shapes,
            labels = col.labels, -- sparse map (global-row → label), passed through
            rmw = col.rmw, -- sparse map (global-row → {name,…}), passed through
        }
        for _, node in ipairs(folded) do node._flow = packed end
        return packed, ns
    end
    return A
end

-- fold the WHOLE graph (inline extract / ingest): add all nodes, finalize.
-- Idempotent + multi-store-safe via the data._flowcol guard (mirrors df.fold): first fold
-- stamps the whole-graph store, later calls no-op (refresh's fresh raw nodes stay raw); in
-- the worker-fold path data._flowcol starts nil so it folds only the raw stragglers, leaving
-- worker-folded nodes on their per-chunk stores (add() skips any node with _flow set).
function M.fold(data)
    if data._flowcol then return 0 end -- already folded (whole-graph store)
    local a = M.accumulator()
    a.add(data.nodes or {})
    local packed, ns = a.finalize()
    data._flowcol = packed
    return ns
end

-- ── multi-store IPC: detach / attach (worker fold-emit, mirrors df.lua) ──
-- A worker shipping a FOLDED chunk detaches the per-node _flow ref (keeps the offsets
-- _flow0/_flown/_flowp0/_flowpn) so the store rides ONCE as data._flowcol, not duplicated
-- per node; the parent re-attaches on receipt. A folded node is marked by _flow0; raw /
-- flow-less nodes are skipped (no-op on a raw chunk).
function M.detach(data)
    if not data._flowcol then return end
    for _, n in ipairs(data.nodes or {}) do n._flow = nil end
end
function M.attach(data)
    local store = data._flowcol
    if not store then return end
    for _, n in ipairs(data.nodes or {}) do
        if n._flow0 ~= nil then n._flow = store end
    end
end

return M
