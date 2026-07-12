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
    switch_statement = true, match_expression = true, try_statement = true }
-- clause nodes carrying a sub-region's statements
-- POST-condition loops: the condition runs AFTER the body
local POST = { do_statement = true, repeat_statement = true }
local CLAUSE = { else_statement = true, elseif_statement = true,
    else_clause = true, elseif_clause = true, else_if_clause = true,
    case_statement = true, default_statement = true,
    catch_clause = true, finally_clause = true }
local ELSEIF = { elseif_statement = true, elseif_clause = true, else_if_clause = true }

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
local WRAP = { variable_list = true, variable_name = true } -- def-pos passes through

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
local function du(root, src, stop_body)
    if not root then return {}, {} end
    local def, use, dseen, useen = {}, {}, {}, {}
    local function rec(node, defpos)
        local t = node:type()
        local asgleft, decld, k
        if ASSIGN[t] then
            asgleft = node:field('left')[1] or node:field('name')[1] or node:child(0)
            k = 1
        elseif DECL[t] then
            decld = node:field('declarator')[1] or node:field('name')[1]; k = 3
        elseif t == 'variable_declaration' or t == 'local_declaration' then
            k = 4 -- lua bare `local a, b` (no `=`): the variable_list is a DEF
        elseif t == 'catch_clause' then
            k = 5 -- catch(Type $e): the variable_name is a BINDING (DEF), type a use
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
                else cdefpos = k end
                if DFID[c:type()] then
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
    if DFID[root:type()] and root:named() and root:child_count() == 0 then
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
    local stmts = {}
    local emit, region, clause -- fwd

    -- emit `node` as a statement row (parent/pol) and recurse its sub-regions
    function emit(node, parent, pol)
        local t = node:type()
        local idx = #stmts + 1
        local d, u = du(node, src, CTRL[t] and true or false)
        stmts[idx] = { l = line(node), kind = CTRL[t] and t or 'stmt',
            parent = parent, pol = pol, def = d, use = u,
            regime = regimetab[t] or 'function' }
        if CTRL[t] then
            local cond = node:field('condition')[1]
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
                local cd, cu = du(cond, src, false)
                stmts[#stmts + 1] = { l = line(cond), kind = 'cond',
                    parent = idx, pol = 'cond', def = cd, use = cu }
            end
        end
    end

    -- a block/region: its direct named children are statements
    function region(block, parent, pol)
        for c in block:iter_children() do
            if c:named() and c:type() ~= 'comment' then emit(c, parent, pol) end
        end
    end

    -- a clause (else/elseif/case/catch): elseif is its own guard (control row);
    -- the rest region their statements under `parent`
    function clause(node, parent)
        if ELSEIF[node:type()] then
            emit(node, parent, 'elseif')
            return
        end
        if node:type() == 'catch_clause' then
            -- the header binds the exception var (DEF) and references the type
            -- (use); the body regions under it. Without this the caught var is
            -- unbound in the fine model and df's spurious use of it is unmatched.
            local d, u = du(node, src, true)
            local idx = #stmts + 1
            stmts[idx] = { l = line(node), kind = 'catch', parent = parent,
                pol = 'catch', def = d, use = u }
            local b = node:field('body')[1]
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

return M
