-- FLOW — the fine-grained statement+control model, the df successor
-- ([[cartograph-df-strangler]]). df collapses control statements' bodies into
-- one row; flow emits statements at EVERY nesting level and records a
-- CONTROL-PARENT (the region tree = CFG dominance df can't express). Increment
-- 1: the STRUCTURE only (l/kind/parent/pol), on-demand from an AST node (like
-- cfg.lua); def/use/dep + fold + extraction-fusion are later strangler steps.
--
-- PARITY ORACLE: flow's TOP-LEVEL rows (parent==0) reproduce df's coarse
-- statement partition (same lines) — that is what lets df's read-contract and
-- its `.l`-span consumers (extract/trace/reorder) stay unchanged while new
-- consumers opt into the fine view.

local M = {}

-- a region body: lua `block`, C/php `compound_statement`, JS/TS `statement_block`
local BODY = { block = true, compound_statement = true, statement_block = true }
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
    for_expression = true, match_block = true }
-- clause nodes carrying a sub-region's statements
-- POST-condition loops: the condition runs AFTER the body
local POST = { do_statement = true, repeat_statement = true }
-- PRE-condition loops (test FIRST → a zero-trip skip is feasible). do/repeat are
-- POST (tested above the back-edge); lua `do...end` is NEITHER — a plain block.
local PRELOOP = { while_statement = true, for_statement = true,
    for_numeric_statement = true, for_generic_statement = true,
    foreach_statement = true, while_expression = true, for_expression = true,
    loop_expression = true } -- rust `loop {}` = infinite (const-true, no zero-trip)
local TRY_T = { try_statement = true }
local CLAUSE = { else_statement = true, elseif_statement = true,
    else_clause = true, elseif_clause = true, else_if_clause = true,
    elif_clause = true, -- python elif
    case_statement = true, default_statement = true,
    expression_case = true, default_case = true,
    catch_clause = true, except_clause = true, finally_clause = true }
local ELSEIF = { elseif_statement = true, elseif_clause = true,
    else_if_clause = true, elif_clause = true } -- + python elif (ruby `if` isn't
    -- in CTRL yet, so ruby `elsif` is out of scope — left folded, parity-clean)
-- exception handlers (bind an exception var, then region a body): java/php/JS
-- `catch_clause`, python `except_clause`
local CATCH = { catch_clause = true, except_clause = true }
-- switch CASES: a label (`value` field = a use) guarding a body of statements
-- that must be REGIONED as rows (not folded into the case row). C/php/java
-- `case_statement`/`default_statement`, go `expression_case`/`default_case`.
local CASE = { case_statement = true, default_statement = true,
    expression_case = true, default_case = true }
-- switch-like heads (the switched expr is under `value` for go, `condition`
-- elsewhere; a `break` inside a case exits the switch, its join)
local SWITCH = { switch_statement = true, expression_switch_statement = true,
    type_switch_statement = true, select_statement = true }

-- SCOPE-REGIME classification (df-strangler step 2b): per language, which
-- declaration node types are BLOCK-scoped (the binding dies at its region's
-- end). Everything unlisted defaults to 'function' — function-scoped, the
-- binding survives block exit (php/python variables, JS `var` (a distinct node
-- type from let/const), lua globals). This is the input the FINE reaching scan
-- (M.reaching) consumes to decide whether a def in a now-closed block still
-- reaches a later use. NOTE: this is flow's reference copy; the intent is for
-- it to migrate into the shared per-language cfg alongside pfield/dfid.
local REGIME = {
    lua        = { variable_declaration = 'block', local_declaration = 'block',
                   local_variable_declaration = 'block' },
    javascript = { lexical_declaration = 'block' }, -- let/const; var = variable_declaration = function (hoisted)
    typescript = { lexical_declaration = 'block' },
    rust       = { let_declaration = 'block' },
    c          = { declaration = 'block' },
    cpp        = { declaration = 'block' },
    java       = { local_variable_declaration = 'block' },
    go         = { short_var_declaration = 'block', var_declaration = 'block' },
    -- function-scoped languages: no block scope; every def defaults to
    -- 'function'. Explicit (empty) so callers can name them without a nil.
    php        = {},
    python     = {},
    ruby       = {},
}
M.REGIME = REGIME

local function line(n) return (select(1, n:range())) + 1 end
local function txt(n, src) return vim.treesitter.get_node_text(n, src) end

-- constant loop condition → EDGE FEASIBILITY. `do{}while(0)` (the C one-shot
-- macro idiom) has no back-edge; `while(true)` / rust `loop` never take the
-- zero-trip or condition-exit edge (only `break` leaves). Returns true|false|nil
-- (nil = unknown → keep both edges, the sound default). Unwraps parens.
local FALSE_LIT = { ['0'] = true, ['0.0'] = true, ['false'] = true,
    ['False'] = true, ['nil'] = true, ['null'] = true }
local TRUE_LIT = { ['true'] = true, ['True'] = true, ['1'] = true }
local function const_cond(node, src)
    while node and node:type() == 'parenthesized_expression' do
        local inner
        for c in node:iter_children() do if c:named() then inner = c break end end
        node = inner
    end
    if not node then return nil end
    local s = vim.trim(txt(node, src))
    if FALSE_LIT[s] then return false end
    if TRUE_LIT[s] then return true end
    return nil
end

local FN = { function_definition = true, function_declaration = true,
    method_declaration = true, anonymous_function = true, arrow_function = true,
    lambda_expression = true, constructor_declaration = true }
-- def-position roots (df's dfk): the assignment left / declarator names are
-- DEFS; everything else is a USE
local ASSIGN = { assignment_statement = true, assignment = true,
    assignment_expression = true, augmented_assignment_expression = true,
    variable_assignment = true }
local DECL = { init_declarator = true, variable_declarator = true }
-- LEAF identifiers to count. NB `variable_name` (php `$x`) is a WRAPPER around
-- an inner `name` — count the inner name only (df does), else `$x` AND `x`
-- double-count; but variable_name still propagates def-position (WRAP).
local DFID = { identifier = true, name = true }
-- def-position passes THROUGH these transparent wrappers to the inner name.
-- `reference_declarator` (C++ `Type &r`) has no `declarator` field — its only
-- named child IS the inner declarator — so it rides the blanket WRAP path.
local WRAP = { variable_list = true, variable_name = true,
    reference_declarator = true }
-- C/C++ declarator wrappers WITH a `declarator` field (a `*`/`[]` around the
-- declared name): def-position continues down that field, NOT to siblings like
-- an array `size` or pointer `type_qualifier` (which are uses/non-names). So
-- `SMesh *mesh = f()` and `char **pp`, `int arr[4]` all DEF the inner name.
local DECLWRAP = { pointer_declarator = true, array_declarator = true }

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
local function du(root, src, stop_body, ids)
    ids = ids or DFID
    if not root then return {}, {} end
    local def, use, dseen, useen = {}, {}, {}, {}
    local function rec(node, defpos)
        local t = node:type()
        local asgleft, decld, k, declist
        if ASSIGN[t] then
            asgleft = node:field('left')[1] or node:field('name')[1] or node:child(0)
            k = 1
        elseif DECL[t] then
            decld = node:field('declarator')[1] or node:field('name')[1]; k = 3
        elseif t == 'let_declaration' then
            decld = node:field('pattern')[1]; k = 3 -- rust `let <pat> = …`
        elseif t == 'variable_declaration' or t == 'local_declaration' then
            k = 4 -- lua bare `local a, b` (no `=`): the variable_list is a DEF
        elseif t == 'catch_clause' then
            k = 5 -- catch(Type $e): the variable_name is a BINDING (DEF), type a use
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
            if c:named() and not FN[c:type()]
                and not (stop_body and (BODY[c:type()] or CLAUSE[c:type()])) then
                local cdefpos
                if k == 1 then cdefpos = same(c, asgleft)
                elseif k == 3 then cdefpos = same(c, decld)
                elseif k == 4 then cdefpos = (c:type() == 'variable_list'
                    or c:type() == 'identifier')
                elseif k == 5 then cdefpos = (c:type() == 'variable_name')
                elseif k == 6 then cdefpos = (c:type() == 'variable_name')
                elseif k == 7 then
                    cdefpos = false
                    for _, dd in ipairs(declist) do if same(c, dd) then cdefpos = true; break end end
                else cdefpos = k end
                if ids[c:type()] then
                    local nm = txt(c, src)
                    if cdefpos then
                        if not dseen[nm] then dseen[nm] = true; def[#def + 1] = nm end
                    elseif not useen[nm] and not dseen[nm] then
                        useen[nm] = true; use[#use + 1] = nm
                    end
                end
                rec(c, cdefpos)
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
    return def, use
end

-- parameter binder names of a fn node — mirrors df's fn_params (treesitter.lua)
-- for coarse-dep PARITY: the pfield container's leaves; php `variable_name`
-- drops its `$`; a method seeds 'self' first; nested declarators (C params,
-- pointers) descend to the first name. `pfield` comes from the language cfg.
local function param_names(fn, src, pfield, method)
    local out = method and { 'self' } or {}
    local ps = pfield and fn:field(pfield)[1]
    if ps then
        for c in ps:iter_children() do
            local t = c:type()
            if t == 'identifier' or t == 'variable' then
                out[#out + 1] = txt(c, src)
            elseif t == 'variable_name' then
                out[#out + 1] = txt(c, src):gsub('^%$', '')
            elseif c:named() then
                for id in c:iter_children() do
                    local it = id:type()
                    if it == 'identifier' then out[#out + 1] = txt(id, src); break end
                    if it == 'variable_name' then out[#out + 1] = txt(id, src):gsub('^%$', ''); break end
                    if it == 'pointer_declarator' then
                        local inner = id:field('declarator')[1]
                        if inner and inner:type() == 'identifier' then out[#out + 1] = txt(inner, src) end
                        break
                    end
                end
            end
        end
    end
    return out
end

-- the function body region (php `body` field / lua block child)
local function fn_body(fn)
    local b = fn:field('body')[1]
    if b then return b end
    for c in fn:iter_children() do if c:named() and BODY[c:type()] then return c end end
    return nil -- no body block (e.g. `function() end`) → no statements; NEVER
    -- fall back to `fn` itself (that walks the parameters as bogus statements)
end

-- cfg (the per-language seam — the config flow should CONSUME rather than
-- hardcode, [[cartograph-df-strangler]]): { pfield=<params field>,
-- regime=<scope-regime table/fn>, ... }. Absent → best-effort defaults.
function M.build(fnnode, src, cfg)
    cfg = cfg or {}
    local regimetab = cfg.regime or {}
    -- leaf-name set = DFID + the language's df_ids extension (bash variable_name)
    local ids = DFID
    if cfg.df_ids then
        ids = {}
        for k in pairs(DFID) do ids[k] = true end
        for k in pairs(cfg.df_ids) do ids[k] = true end
    end
    local stmts = {}
    local emit, region, clause -- fwd

    -- emit `node` as a statement row (parent/pol) and recurse its sub-regions
    function emit(node, parent, pol)
        local t = node:type()
        -- rust: control is EXPRESSIONS wrapped in an expression_statement.
        -- Unwrap a sole CTRL child so it is regioned like a control statement.
        if t == 'expression_statement' then
            local inner
            for c in node:iter_children() do
                if c:named() and c:type() ~= 'comment' then
                    if inner then inner = nil; break end
                    inner = c
                end
            end
            if inner and CTRL[inner:type()] then return emit(inner, parent, pol) end
        end
        local idx = #stmts + 1
        local d, u = du(node, src, CTRL[t] and true or false, ids)
        stmts[idx] = { l = line(node), kind = CTRL[t] and t or 'stmt',
            parent = parent, pol = pol, def = d, use = u,
            regime = regimetab[t] or 'function', t = t } -- t = raw node type (CFG terminators)
        if CTRL[t] then
            local cond = node:field('condition')[1]
                or (SWITCH[t] and node:field('value')[1]) -- go switch: `value` is the switched expr
            -- loop feasibility flag (do{}while(0) / while(true) / rust loop)
            if POST[t] or PRELOOP[t] then
                stmts[idx].const = (t == 'loop_expression') and true or const_cond(cond, src)
            end
            -- POST-condition loops (do-while, lua repeat-until): the condition
            -- runs AFTER the body, so its def/use must be ordered after it (a
            -- var def'd in the body and read in the condition is not a free
            -- use). Drop it from the control row; re-emit as a trailing row.
            if POST[t] then stmts[idx].def, stmts[idx].use = {}, {} end
            for gc in node:iter_children() do
                if gc:named() and gc ~= cond and gc:type() ~= 'comment' then
                    local gt = gc:type()
                    if BODY[gt] then
                        region(gc, idx, 'body')          -- php block body / loop body
                    elseif CLAUSE[gt] then
                        clause(gc, idx)                  -- else/elseif/case/catch
                    elseif not BODY[gt] then
                        emit(gc, idx, 'body')            -- lua inline body statement
                    end
                end
            end
            if POST[t] and cond then
                local cd, cu = du(cond, src, false, ids)
                stmts[#stmts + 1] = { l = line(cond), kind = 'cond',
                    parent = idx, pol = 'cond', def = cd, use = cu }
            end
        end
    end

    -- a block/region: its direct named children are statements. CLAUSE children
    -- (a C switch body is a compound_statement of `case_statement`s) route to
    -- clause() so their bodies are regioned, not folded.
    function region(block, parent, pol)
        for c in block:iter_children() do
            if c:named() and c:type() ~= 'comment' then
                if CLAUSE[c:type()] then clause(c, parent) else emit(c, parent, pol) end
            end
        end
    end

    -- a clause (else/elseif/case/catch): elseif is its own guard (control row);
    -- the rest region their statements under `parent`
    function clause(node, parent)
        if CASE[node:type()] then
            -- a switch case: the `value` label is a USE; the statement body is
            -- REGIONED as rows (was folded into the case row, hiding it from the
            -- fine model + blocking case CFG feasibility). break rows inside now
            -- surface — successors routes them to the switch join.
            local vf = node:field('value')[1]
            local d, u = du(vf, src, false, ids) -- default (no value) → {},{}
            local idx = #stmts + 1
            stmts[idx] = { l = line(node), kind = 'case', parent = parent,
                pol = 'case', def = d, use = u, t = node:type() }
            for c in node:iter_children() do
                if c:named() and c ~= vf and c:type() ~= 'comment' then
                    if BODY[c:type()] then region(c, idx, 'body') else emit(c, idx, 'body') end
                end
            end
            return
        end
        if ELSEIF[node:type()] then
            -- an elseif is a guard (its condition) over a body: emit the control
            -- row (condition only, stop_body) and REGION its consequence as rows
            -- (was folded — the body statements were invisible). lua
            -- `elseif_statement` / python `elif_clause`: body under `consequence`.
            local d, u = du(node, src, true, ids)
            local idx = #stmts + 1
            stmts[idx] = { l = line(node), kind = node:type(), parent = parent,
                pol = 'elseif', def = d, use = u, t = node:type() }
            local cons = node:field('consequence')[1] or node:field('body')[1]
            if cons and BODY[cons:type()] then
                region(cons, idx, 'body')
            else -- fallback: region non-condition named children
                local condn = node:field('condition')[1]
                for c in node:iter_children() do
                    if c:named() and c ~= condn and c:type() ~= 'comment' then
                        if BODY[c:type()] then region(c, idx, 'body') else emit(c, idx, 'body') end
                    end
                end
            end
            return
        end
        if CATCH[node:type()] then
            -- the header binds the exception var (DEF) and references the type
            -- (use); the body regions under it. Without this the caught var is
            -- unbound in the fine model and df's spurious use of it is unmatched.
            local d, u = du(node, src, true, ids)
            local idx = #stmts + 1
            stmts[idx] = { l = line(node), kind = 'catch', parent = parent,
                pol = 'catch', def = d, use = u }
            -- python `except_clause` has no `body` field (the block is an unnamed
            -- child); fall back to the first BODY-type child.
            local b = node:field('body')[1]
            if not (b and BODY[b:type()]) then
                for c in node:iter_children() do
                    if BODY[c:type()] then b = c break end
                end
            end
            if b and BODY[b:type()] then region(b, idx, 'catch') end
            return
        end
        local ct = node:type()
        local pol = ct:find('else') and 'else' or ct:find('case') and 'case'
            or ct:find('catch') and 'catch' or ct:find('finally') and 'finally'
            or ct:find('default') and 'default' or 'clause'
        local b = node:field('body')[1]
        if b and BODY[b:type()] then region(b, parent, pol) return end
        for c in node:iter_children() do
            if c:named() and c:type() ~= 'comment' then
                if BODY[c:type()] then region(c, parent, pol)
                else emit(c, parent, pol) end
            end
        end
    end

    local body = fn_body(fnnode)
    if body then region(body, 0, nil) end
    -- `cfg.method` seeds an implicit 'self' param — a per-language POLICY the
    -- caller decides (df seeds self only for lua colon-methods: `method and
    -- lang=='lua'`). Default false: no implicit receiver.
    return { stmts = stmts, cfg = cfg,
        params = param_names(fnnode, src, cfg.pfield, cfg.method or false) }
end

--- coarse projection: df's partition — TOP-LEVEL statements, each aggregating
--- its whole subtree's def/use (df's control-row semantics), with df's rules
--- (def deduped; a name def'd in the coarse stmt is not also a use).
function M.coarse(flow)
    local stmts = flow.stmts
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
        for _, nm in ipairs(s.def) do
            if not sd[t][nm] then sd[t][nm] = true; def[t][#def[t] + 1] = nm end
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
    -- reaching (block vs function/hoisted regimes) is the FINE model, M.reaching
    -- — the coarse partition has no blocks to scope over. ([[cartograph-df-strangler]])
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

--- FINE, SCOPE-REGIME-aware reaching (df-strangler step 2b, the value-add over
--- df's flat coarse dep). For each use it names the def that reaches it,
--- honoring block vs function scoping — the thing the coarse projection CAN'T
--- express (its blocks are collapsed). Returns a list of edges
--- `{ at=<use row>, var, from=<def row | nil>, kind='lexical'|'function-scope'|'free' }`.
---
--- Rule: (1) the nearest def of the var in an ENCLOSING region (an ancestor of
--- the use, before the branch the use descends into) reaches — it is lexically
--- in scope regardless of regime; (2) else the latest FUNCTION/hoisted-regime
--- def before the use reaches, even from a now-CLOSED sibling/prior block (it
--- survived block exit) — but a BLOCK-regime def in a closed block does NOT
--- (this is the scope-regime payoff: JS `let` in an if-block is unreachable
--- after it, `var` is reachable); (3) else free (a param or an outer/undeclared
--- name). LIMITATION: branch JOINS (both arms define the var → a set) and loop
--- BACK-EDGES are approximated as the nearest prior def; exact multi-def
--- reaching rides CFG phase-2 successor edges ([[cartograph-cfg-scope]]).
function M.reaching(flow)
    local stmts = flow.stmts
    local defsByVar = {}
    for i, s in ipairs(stmts) do
        for _, d in ipairs(s.def) do
            local l = defsByVar[d]; if not l then l = {}; defsByVar[d] = l end
            l[#l + 1] = i
        end
    end
    -- is def row `dr` in a region that ENCLOSES use row `ur` (same region, or a
    -- region on ur's ancestor chain with the def placed before that branch)?
    local function encloses(dr, ur)
        if stmts[dr].parent == stmts[ur].parent then return dr < ur end
        local p = stmts[ur].parent
        while p ~= 0 do
            if stmts[dr].parent == stmts[p].parent then return dr < p end
            p = stmts[p].parent
        end
        return stmts[dr].parent == 0 and dr < ur
    end
    local edges = {}
    for i, s in ipairs(stmts) do
        for _, u in ipairs(s.use) do
            local defs, from, kind = defsByVar[u], nil, 'free'
            if defs then
                for k = #defs, 1, -1 do -- (1) nearest enclosing def
                    if defs[k] < i and encloses(defs[k], i) then from, kind = defs[k], 'lexical'; break end
                end
                if not from then -- (2) latest function-scoped def that survived block exit
                    for k = #defs, 1, -1 do
                        if defs[k] < i and stmts[defs[k]].regime ~= 'block' then
                            from, kind = defs[k], 'function-scope'; break
                        end
                    end
                end
            end
            edges[#edges + 1] = { at = i, var = u, from = from, kind = kind }
        end
    end
    return edges
end

-- ── CFG phase 2: successor edges over the fine rows ─────────────────────────
local IF_T = { if_statement = true, if_expression = true }
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
    local function add(a, b) local l = succ[a]; if not l then l = {}; succ[a] = l end l[#l + 1] = b end
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
    -- wire `rows` as a sequence completing to `after`; brk/cont = loop exit/head
    local function wire(rows, after, brk, cont)
        if not rows or #rows == 0 then return after end
        for i = 1, #rows do
            local r, nxt = rows[i], (rows[i + 1] or after)
            local s, kids = S[r], region[r]
            local t = s.t
            if RET_T[t] then add(r, 'exit')
            elseif t == 'break_statement' then add(r, brk or 'exit')
            elseif t == 'continue_statement' then add(r, cont or 'exit')
            elseif kids and kids['cond'] then
                -- POST-condition loop (do-while / lua repeat-until): body runs
                -- once before the test → NO zero-trip; the `cond` row is the join.
                local condrow = kids['cond'][1]
                local bentry = wire(kids['body'], condrow, nxt, condrow) -- break→exit, continue→cond
                add(r, bentry)                                    -- always enter body
                if s.const ~= false then add(condrow, bentry) end -- back-edge (dropped for do{}while(0))
                if s.const ~= true then add(condrow, nxt) end     -- loop exit
                for pol, rr in pairs(kids) do
                    if pol ~= 'body' and pol ~= 'cond' then add(r, wire(rr, nxt, brk, cont)) end
                end
            elseif kids and PRELOOP[s.kind] then
                -- PRE-condition loop (while/for): test first → zero-trip skip,
                -- suppressed when constant-true (while(true), rust `loop`).
                add(r, wire(kids['body'], r, nxt, r)) -- body, back-edge to head
                if s.const ~= true then add(r, nxt) end
                for pol, rr in pairs(kids) do -- python for/while `else`, etc.
                    if pol ~= 'body' then add(r, wire(rr, nxt, brk, cont)) end
                end
            elseif kids and TRY_T[t] then
                -- exception edges: a throw may occur at ANY try-body point, so
                -- every catch handler is reachable from every such point (sound).
                -- finally (if present) is on the normal completion path; the
                -- uncaught-propagation path to fn-exit is left implicit (a hedge —
                -- it only ever adds `exit`, whose live-in is empty, so liveness
                -- stays sound).
                local after2 = kids['finally'] and wire(kids['finally'], nxt, brk, cont) or nxt
                add(r, wire(kids['body'], after2, brk, cont)) -- normal entry
                if kids['catch'] then
                    local trybody = subtree(kids['body'])
                    for _, crow in ipairs(kids['catch']) do
                        local centry = wire(region[crow] and region[crow]['catch'], after2, brk, cont)
                        add(crow, centry)                          -- bind exc var → handler body
                        add(r, crow)                               -- exception at/near entry
                        for tr in pairs(trybody) do add(tr, crow) end -- throw anywhere in the try
                    end
                end
                for pol, rr in pairs(kids) do -- python try/except `else` etc.: sound over-approx
                    if pol ~= 'body' and pol ~= 'catch' and pol ~= 'finally' then add(r, wire(rr, after2, brk, cont)) end
                end
            elseif kids and IF_T[s.kind] then
                add(r, wire(kids['body'], nxt, brk, cont))
                local hasfalse = false
                for _, pol in ipairs({ 'elseif', 'else' }) do
                    if kids[pol] then
                        for _, e in ipairs(kids[pol]) do add(r, e); wire({ e }, nxt, brk, cont) end
                        hasfalse = true
                    end
                end
                if not hasfalse then add(r, nxt) end -- no else → condition may fall through
            elseif kids and t == 'do_statement' then
                add(r, wire(kids['body'], nxt, brk, cont)) -- lua `do...end`: plain block
            elseif kids and SWITCH[t] then
                -- switch: cases fall through in order; break exits the switch, so
                -- the case bodies are wired with brk = nxt (the switch join).
                for _, rr in pairs(kids) do add(r, wire(rr, nxt, nxt, cont)) end
                add(r, nxt) -- no case matched (no default)
            elseif kids then -- match/try/other control head: sound over-approx
                for _, rr in pairs(kids) do add(r, wire(rr, nxt, brk, cont)) end
                add(r, nxt)
            else
                add(r, nxt)
            end
        end
        return rows[1]
    end
    local entry = wire(region[0] and region[0][''], 'exit', nil, nil)
    return { succ = succ, entry = entry, EXIT = 'exit' }
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

return M
