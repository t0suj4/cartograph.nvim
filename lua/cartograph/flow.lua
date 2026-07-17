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
        if c:named() and c:type() ~= 'comment' then return normlbl(txt(c, src)) end
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
        if c:named() and c:type() ~= 'comment' and c ~= lf then
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
--
-- THIRD return `sus` = does the walked subtree contain a suspension point
-- (yield/await)? FUSED in here (was a separate has_suspend walk over the SAME
-- node set under the SAME stop-rules — a measured ~33% of flow.build spent
-- re-traversing every statement just to usually return false). Set on any
-- visited node whose type is in SUSPEND; the root is checked too.
local function du(root, src, stop_body, ids)
    ids = ids or DFID
    if not root then return {}, {}, false end
    local def, use, dseen, useen = {}, {}, {}, {}
    local sus = SUSPEND[root:type()] or false
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
            if c:named() then
              local ct = c:type() -- cache the per-child type FFI (was called 2-6× below)
              if not FN[ct]
                and not (stop_body and (BODY[ct] or CLAUSE[ct])) then
                if SUSPEND[ct] then sus = true end -- fused suspension detection
                local cdefpos
                if k == 1 then cdefpos = same(c, asgleft)
                elseif k == 3 then cdefpos = same(c, decld)
                elseif k == 4 then cdefpos = (ct == 'variable_list'
                    or ct == 'identifier')
                elseif k == 5 then cdefpos = (ct == 'variable_name')
                elseif k == 6 then cdefpos = (ct == 'variable_name')
                elseif k == 7 then
                    cdefpos = false
                    for _, dd in ipairs(declist) do if same(c, dd) then cdefpos = true; break end end
                else cdefpos = k end
                if ids[ct] then
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
    end
    -- a statement that IS a bare name leaf — e.g. a rust/ml tail-expression
    -- `out` (implicit return), an enum `None`. du only inspects CHILDREN, so a
    -- root name would be missed; count it as a use (a root has no def-context).
    if ids[root:type()] and root:named() and root:child_count() == 0 then
        local nm = txt(root, src)
        if not dseen[nm] and not useen[nm] then useen[nm] = true; use[#use + 1] = nm end
    end
    rec(root, false)
    return def, use, sus
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
        -- labeled_statement (go/java/js/c): DEFINES a label over the wrapped
        -- statement — unwrap, emit the inner statement, and tag its HEAD row with
        -- the label so break/continue/goto can target it. An empty target (C
        -- `done: ;`) emits a bare `label` marker row.
        if LABELED[t] then
            local lbl, inner = labeled_parts(node, src)
            if inner then
                local before = #stmts
                emit(inner, parent, pol)
                if lbl and stmts[before + 1] then stmts[before + 1].label = lbl end
            else
                stmts[#stmts + 1] = { l = line(node), c = startcol(node), kind = 'label',
                    parent = parent, pol = pol, def = {}, use = {}, t = t, label = lbl }
            end
            return
        end
        local idx = #stmts + 1
        local sb = CTRL[t] and true or false
        local d, u, sus = du(node, src, sb, ids)
        stmts[idx] = { l = line(node), c = startcol(node), kind = CTRL[t] and t or 'stmt',
            parent = parent, pol = pol, def = d, use = u,
            regime = regimetab[t] or 'function', t = t, -- t = raw node type (CFG terminators)
            suspend = sus or nil, -- yield/await = a Tier-1 continuation point (fused from du)
            -- control-transfer label: TARGET on break/continue/goto, else the
            -- loop's OWN label (rust). def/use above are unaffected.
            label = (TRANSFER[t] and target_label(node, src))
                or (CTRL[t] and loop_label(node, src)) or nil }
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
                if gc:named() and gc ~= cond then
                    local gt = gc:type()
                    if gt == 'comment' then -- skip
                    elseif BODY[gt] then
                        region(gc, idx, 'body')          -- php block body / loop body
                    elseif CLAUSE[gt] then
                        clause(gc, idx)                  -- else/elseif/case/catch
                    else
                        emit(gc, idx, 'body')            -- lua inline body statement
                    end
                end
            end
            if POST[t] and cond then
                local cd, cu = du(cond, src, false, ids)
                stmts[#stmts + 1] = { l = line(cond), c = startcol(cond), kind = 'cond',
                    parent = idx, pol = 'cond', def = cd, use = cu }
            end
        end
    end

    -- a block/region: its direct named children are statements. CLAUSE children
    -- (a C switch body is a compound_statement of `case_statement`s) route to
    -- clause() so their bodies are regioned, not folded.
    function region(block, parent, pol)
        for c in block:iter_children() do
            if c:named() then
                local ct = c:type()
                if ct ~= 'comment' then
                    if CLAUSE[ct] then clause(c, parent) else emit(c, parent, pol) end
                end
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
            stmts[idx] = { l = line(node), c = startcol(node), kind = 'case', parent = parent,
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
            stmts[idx] = { l = line(node), c = startcol(node), kind = node:type(), parent = parent,
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
            stmts[idx] = { l = line(node), c = startcol(node), kind = 'catch', parent = parent,
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
            elseif kids and PRELOOP[s.kind] then
                -- PRE-condition loop (while/for): test first → zero-trip skip,
                -- suppressed when constant-true (while(true), rust `loop`).
                local lb = s.label and extend(lbls, s.label, { brk = nxt, cont = r }) or lbls
                add(r, wire(kids['body'], r, nxt, r, lb)) -- body, back-edge to head
                if s.const ~= true then add(r, nxt) end
                for pol, rr in pairs(kids) do -- python for/while `else`, etc.
                    if pol ~= 'body' then add(r, wire(rr, nxt, brk, cont, lbls)) end
                end
            elseif kids and TRY_T[t] then
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
            elseif kids and IF_T[s.kind] then
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
            elseif kids and SWITCH[t] then
                -- switch: cases fall through in order; break exits the switch, so
                -- the case bodies are wired with brk = nxt (the switch join).
                for _, rr in pairs(kids) do add(r, wire(rr, nxt, nxt, cont, lbls)) end
                add(r, nxt) -- no case matched (no default)
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
    -- SCOPE of a def = the region it lives in: a BLOCK-regime def is scoped to
    -- its enclosing region (its parent); everything else (function/hoisted,
    -- assignments, params) is function-scoped (region 0). This is what makes a
    -- block-scoped def's KILL region-local (below).
    local function scope_of(r)
        if r == 0 then return 0 end
        return S[r].regime == 'block' and S[r].parent or 0
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
                    local sn = scope_of(n)
                    local kept = { [n] = true }
                    for m in pairs(i[v] or {}) do
                        if not subscope(scope_of(m), sn) then kept[m] = true end -- enclosing → mask
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
        for _, v in ipairs(S[u].use) do
            local reaching, from, hset = rin[u] and rin[u][v], {}, nil
            if reaching then
                local ex = rin_exact[u] and rin_exact[u][v]
                -- NEAREST-scope preference (the restore half): among the visible
                -- reaching defs, keep only those in the INNERMOST scope — a
                -- shadowing inner masks the enclosing def AT THE USE, while the
                -- enclosing def, never killed, is what reaches uses AFTER the block.
                local best = math.huge
                for r in pairs(reaching) do
                    if visible(r, u) then
                        local dr = depth[scope_of(r)] or math.huge
                        if dr < best then best = dr end
                    end
                end
                for r in pairs(reaching) do
                    if visible(r, u) and (depth[scope_of(r)] or math.huge) == best then
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

local char, byte, concat = string.char, string.byte, table.concat

-- LE packed column at the given BYTE width (2 or 4) + a matching 1-based getter.
-- Width is chosen per column at fold time from the measured max value: u16 while
-- it fits (< 65536), else u32. The getter captures its own width, so materialize
-- is width-agnostic.
local function pack(arr, len, w)
    local parts = {}
    if w == 2 then
        for i = 1, len do
            local v = arr[i]
            parts[i] = char(v % 256, (v - v % 256) / 256 % 256)
        end
    else
        for i = 1, len do
            local v = arr[i]
            local lo = v % 65536
            parts[i] = char(lo % 256, (lo - lo % 256) / 256,
                (v - v % 65536) / 65536 % 256, (v - v % 16777216) / 16777216 % 256)
        end
    end
    return concat(parts)
end
local function getter(s, w)
    if w == 2 then
        return function (i)
            local p = (i - 1) * 2 + 1
            local a, b = byte(s, p, p + 1)
            return a + b * 256
        end
    end
    return function (i)
        local p = (i - 1) * 4 + 1
        local a, b, c, d = byte(s, p, p + 3)
        return a + b * 256 + c * 65536 + d * 16777216
    end
end
local function width_for(maxv) return maxv < 65536 and 2 or 4 end

-- materialize one row from the columns (M.build-identical shape). The row's whole
-- categorical descriptor is one `shape` id into col.shapes (a captured table with
-- exactly the fields the built row had — absent keys stay absent, so a `cond` row
-- with no t/regime round-trips; const=false and suspend=true are preserved as the
-- shape captured them). def then use pack contiguously in `nm` (df's end-
-- derivation: use start = def end = u0[g], use end = d0[g+1]).
local function row_view(col, g)
    local nms = col.names
    local d = col.shapes[col.shape(g)]
    local s = { l = col.l(g), c = col.c(g), parent = col.parent(g), def = {}, use = {},
        kind = d.kind, pol = d.pol, t = d.t,
        regime = d.regime, const = d.const, suspend = d.suspend,
        label = col.labels[g] } -- sparse (control-transfer): nil for the vast majority
    local b, e = col.d0(g), col.u0(g)
    for j = 1, e - b do s.def[j] = nms[col.nm(b + j)] end
    b, e = e, col.d0(g + 1)
    for j = 1, e - b do s.use[j] = nms[col.nm(b + j)] end
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
function M.record(n)
    if not n then return nil end
    local col = n._flow
    if col then
        local params = {}
        for i = 1, n._flowpn do params[i] = col.names[col.pm(n._flowp0 + i)] end
        return { stmts = M.rows(n), params = params }
    end
    return n.flow
end

--- fold every node's `.flow` record into one columnar store; drop the records.
--- Idempotent (a second call no-ops via data._flowcol). Mirrors df.fold's
--- lifecycle: run at ingest, AFTER raw records are encoded to shards.
function M.fold(data)
    if data._flowcol then return 0 end
    local col = {
        shape = {}, l = {}, c = {}, parent = {},
        d0 = {}, u0 = {}, nm = {}, pm = {}, names = {}, shapes = {},
        labels = {}, -- SPARSE (global-row → label name): control-transfer targets/
        -- definitions, rare enough that a plain map beats a packed column (a
        -- merge-friendly sparse (row,name-id) packing is a later refinement).
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
    for _, node in ipairs(data.nodes or {}) do
        local fl = node.flow
        if fl and fl.stmts and not node._flow then
            local s0 = ns
            for _, s in ipairs(fl.stmts) do
                ns = ns + 1
                col.shape[ns] = shape_of(s)
                col.l[ns] = s.l
                col.c[ns] = s.c
                if s.label then col.labels[ns] = s.label end
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
            node._flow = col
            node._flow0, node._flown = s0, ns - s0
            node._flowp0, node._flowpn = p0, np - p0
            node.flow = nil
        end
    end
    col.d0[ns + 1] = nn -- sentinel: closes the last row's derived use count
    -- per-column widths from the measured max: name-ids over #names, parent over
    -- maxp, shape over #shapes; l and the nm-offsets (d0/u0) stay u32 (source
    -- lines + global name-pool offsets both exceed u16 at scale).
    local nw = width_for(#col.names)
    local pw = width_for(maxp)
    local sw = width_for(#col.shapes)
    local cw = width_for(maxc) -- u16 normal; u32 only for extreme minified lines
    local packed = {
        shape = getter(pack(col.shape, ns, sw), sw),
        l = getter(pack(col.l, ns, 4), 4),
        c = getter(pack(col.c, ns, cw), cw),
        parent = getter(pack(col.parent, ns, pw), pw),
        d0 = getter(pack(col.d0, ns + 1, 4), 4),
        u0 = getter(pack(col.u0, ns, 4), 4),
        nm = getter(pack(col.nm, nn, nw), nw),
        pm = getter(pack(col.pm, np, nw), nw),
        names = col.names,
        shapes = col.shapes,
        labels = col.labels, -- sparse map (global-row → label), passed through
    }
    for _, node in ipairs(data.nodes or {}) do
        if node._flow == col then node._flow = packed end
    end
    data._flowcol = packed
    return ns
end

return M
