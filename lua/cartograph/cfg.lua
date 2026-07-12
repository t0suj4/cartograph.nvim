-- CFG phase 1: the structural GUARDED-REGION / dominance relation over a
-- function's AST ([[cartograph-cfg-scope]]). The reusable control-flow
-- primitive `df` lacks — `df` has numbered statements + local dataflow deps
-- but no branch structure. This is the cheap, syntactic slice: a node is
-- POSITIVELY DOMINATED by a guard condition G iff it is nested in the guarded
-- region of the construct headed by G — an if/elseif then-body, a while body,
-- a ternary then-branch. The else/alternative path is NEGATED and excluded
-- (soundness: a value validated in a condition is NOT guaranteed valid on the
-- else path — a consumer must still fire there).
--
-- Computed on demand from an AST node (like df.get reads a node); NOT yet
-- extract+folded (phase 1b — deferred; the weight measurement put it at ~1% of
-- df, so it folds cheaply WHEN a non-re-parsing consumer needs it). Phase 2
-- (successor edges: joins, loop back-edges) is a separate cut for liveness /
-- resource-pairing.
--
-- Per-grammar: covers if/elseif/while, php/c/JS/python ternaries, python
-- comprehension if-clauses, and short-circuit `&&`/`||` right operands. Loops
-- without a boolean condition (for/foreach) don't contribute (sound).

local M = {}

-- constructs whose condition positively dominates their guarded body.
-- Ternaries: php/c `conditional_expression` + JS/TS `ternary_expression` expose
-- `condition`+`alternative` fields (consequence = neither → the guarded child);
-- python `conditional_expression` has NO fields — positional named children
-- [consequence, condition, alternative]. Comprehensions carry the guard in an
-- `if_clause`; only the `body` (element) is guarded. positive_guard() below
-- resolves each shape.
local COND = {
    if_statement = true, elseif_statement = true, elseif_clause = true,
    else_if_clause = true, while_statement = true,
    conditional_expression = true, ternary_expression = true,
    list_comprehension = true, set_comprehension = true,
    dictionary_comprehension = true, generator_expression = true,
}
local COMPREHENSION = {
    list_comprehension = true, set_comprehension = true,
    dictionary_comprehension = true, generator_expression = true,
}
-- short-circuit boolean ops: the RIGHT operand is conditionally evaluated.
-- `a && b` → b guarded by a (positive); `a || b` → b guarded by ¬a (negated).
-- (`??` is nullish, not a boolean validator guard — excluded.)
local SHORTCIRCUIT = { binary_expression = true, boolean_operator = true }
local SC_AND = { ['&&'] = true, ['and'] = true }
local SC_OR = { ['||'] = true, ['or'] = true }
-- direct-child types that put us on the NEGATED (else/elseif) path of an
-- enclosing if — the positive condition above does not dominate through them
local ELSE = {
    else_clause = true, else_statement = true, elseif_statement = true,
    elseif_clause = true, else_if_clause = true,
}
-- climbing stops here: a guard OUTSIDE the enclosing function does not
-- dominate its body (params/sources are fresh per call)
local FN_BOUND = {
    function_definition = true, function_declaration = true,
    method_declaration = true, anonymous_function = true,
    arrow_function = true, lambda_expression = true,
    constructor_declaration = true,
}

local function same(a, b)
    if not (a and b) then return false end
    local a1, a2, a3, a4 = a:range()
    local b1, b2, b3, b4 = b:range()
    return a1 == b1 and a2 == b2 and a3 == b3 and a4 == b4
end

-- ELSE-path node types (forward decl; ELSE is defined above)
-- The condition that positively dominates `child` within COND-node `p`, or nil.
-- Handles: (1) field-based if/while/ternary (php/c/JS) — cond=condition field,
-- guarded = anything but the condition/alternative/else; (2) python
-- `conditional_expression` (no fields) — positional [consequence, condition,
-- alternative], guarded = consequence; (3) comprehensions — cond = the
-- `if_clause` filter, guarded = the `body` (element) only.
local function positive_guard(p, child)
    local pt = p:type()
    if COMPREHENSION[pt] then
        local body = p:field('body')[1]
        if not (body and same(child, body)) then return nil end
        for c in p:iter_children() do
            if c:type() == 'if_clause' then return c:named_child(0) end
        end
        return nil
    end
    local cond = p:field('condition')[1]
    if not cond and pt == 'conditional_expression' then -- python positional ternary
        local cons = p:named_child(0)
        if cons and same(child, cons) then return p:named_child(1) end
        return nil
    end
    local alt = p:field('alternative')[1]
    if cond and not same(child, cond) and not same(child, alt)
        and not ELSE[child:type()] then
        return cond
    end
    return nil
end

-- statements that unconditionally leave the flow, so a preceding
-- `if(C){…this}` guard-clause makes ¬C hold for everything after it
local TERM = {
    return_statement = true, throw_statement = true, break_statement = true,
    continue_statement = true, goto_statement = true, exit_statement = true,
}
local BLOCK = { block = true, compound_statement = true, program = true }

local function txt(n, src) return vim.treesitter.get_node_text(n, src) end

-- short-circuit guard: within `a && b` / `a || b`, only the RIGHT operand is
-- conditionally evaluated. Returns (cond, neg) when `child` IS the right
-- operand — cond = the left operand; neg=false for &&/and (left holds),
-- neg=true for ||/or (¬left holds when the right runs). nil otherwise.
-- NB this models EVALUATION-dominance of the right operand (uniform across
-- languages), NOT the expression's RESULT value: php `&&`/`||` COERCE their
-- result to bool (so `$q = cond && $x` detaints — a coercion-sanitizer),
-- whereas `?:`/`??` and JS/python `&&`/`||` pass an operand VALUE through.
-- That result-value distinction is a taint value-flow concern, not a guard one
-- ([[cartograph-taint-analysis]]).
local function shortcircuit_guard(p, child, src)
    local right = p:field('right')[1]
    if not (right and same(child, right)) then return nil end
    local op, left = p:field('operator')[1], p:field('left')[1]
    if not (op and left) then return nil end
    local ot = txt(op, src)
    if SC_AND[ot] then return left, false end
    if SC_OR[ot] then return left, true end
    return nil
end

-- does `body` definitely terminate — last named stmt is a TERM, or an
-- exit()/die() expression-statement? (favors NON-termination when unsure, so
-- a non-terminating `if` is not mistaken for a guard-clause → no over-suppress)
local function terminates(body, src)
    if not body then return false end
    local last
    for c in body:iter_children() do if c:named() then last = c end end
    if not last then return false end
    if TERM[last:type()] then return true end
    local s = txt(last, src)
    return s:match('^%s*exit%f[^%w_]') ~= nil or s:match('^%s*die%f[^%w_]') ~= nil
end

-- the if's consequence body (grammar-varying: field, or inline block child)
local function if_body(ifnode)
    local b = ifnode:field('body')[1] or ifnode:field('consequence')[1]
    if b then return b end
    for c in ifnode:iter_children() do
        if c:named() and BLOCK[c:type()] then return c end
    end
end

--- Guards that structurally dominate `node`, as { cond, neg }: neg=false =
--- positive nesting (cond holds at node); neg=true = a preceding terminating
--- guard-clause `if(cond){…exit}` (so ¬cond holds at node). A node inside a
--- condition, or reached via an else/alternative, is not positively dominated.
function M.guards_over(node, src)
    local out = {}
    local child, p = node, node:parent()
    while p do
        if FN_BOUND[p:type()] then break end
        if COND[p:type()] then
            local cond = positive_guard(p, child)
            if cond then out[#out + 1] = { cond = cond, neg = false } end
        elseif SHORTCIRCUIT[p:type()] then
            local cond, neg = shortcircuit_guard(p, child, src)
            if cond then out[#out + 1] = { cond = cond, neg = neg } end
        end
        -- early-exit guard-clauses: preceding `if(C){…exit}` siblings of the
        -- statement `child`, within this block, make ¬C dominate `node`
        if BLOCK[p:type()] then
            for c in p:iter_children() do
                if same(c, child) then break end
                if c:named() and c:type() == 'if_statement'
                    and not c:field('alternative')[1] then -- no else branch
                    local cond = c:field('condition')[1]
                    if cond and terminates(if_body(c), src) then
                        out[#out + 1] = { cond = cond, neg = true }
                    end
                end
            end
        end
        child, p = p, p:parent()
    end
    return out
end

return M
