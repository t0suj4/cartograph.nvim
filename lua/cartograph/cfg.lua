-- CFG phase 1: the structural GUARDED-REGION / dominance relation over a
-- function's AST ([[cartograph-cfg-scope]]). The reusable control-flow
-- primitive `df` lacks — `df` has numbered statements + local dataflow deps
-- but no branch structure. This is the cheap, syntactic slice: a node is
-- POSITIVELY DOMINATED by a guard condition G iff it is nested in the guarded
-- region of the construct headed by G — an if/elseif then-body, a while body,
-- a ternary then-branch. The else/alternative path is NOT positively dominated
-- (soundness: a value validated in a condition is NOT guaranteed valid on the
-- else path — a consumer must still fire there) — but it carries the NEGATIVE
-- fact instead: in the `else` of `if C`, ¬C provably holds, and in an
-- `elseif D`, ¬C ∧ D. Those were simply never emitted before CART-0257; the
-- omission read as a claim about positive domination while four consumers
-- (narrow / nilflow / sinkflow / lint) silently lost precision on the most
-- idiomatic branch shape there is.
--
-- Computed on demand from an AST node (like df.get reads a node); NOT yet
-- extract+folded (phase 1b — deferred; the weight measurement put it at ~1% of
-- df, so it folds cheaply WHEN a non-re-parsing consumer needs it). Phase 2
-- (successor edges: joins, loop back-edges) is a separate cut for liveness /
-- resource-pairing.
--
-- @langs lua ruby python php c javascript typescript
--
-- Per-grammar: covers if/elseif/while, php/c/JS/python ternaries, python
-- comprehension if-clauses, ruby's if/unless/elsif/while/until + their statement
-- MODIFIERS, and short-circuit `&&`/`||`/`and`/`or` right operands. Loops without
-- a boolean condition (for/foreach) don't contribute (sound).
--
-- RUBY ADDED CART-0298, and it brought a case no earlier language had: an
-- INVERTED construct. In every grammar above, the consequence is the positive
-- branch — but `unless C` guards its body with ¬C and its `else` with C, and
-- `until C` guards its body with ¬C. So a construct's polarity is a PROPERTY OF
-- THE CONSTRUCT (the INVERTED set), not a constant, and the same flip has to run
-- through all three emitters: positive nesting, the else/elseif chain, and the
-- early-exit guard clause — where it is the whole point, because ruby's guard
-- clause is `return unless p`, after which p is TRUTHY.

local M = {}

-- constructs whose condition positively dominates their guarded body.
-- Ternaries: php/c `conditional_expression` + JS/TS `ternary_expression` expose
-- `condition`+`alternative` fields (consequence = neither → the guarded child);
-- python `conditional_expression` has NO fields — positional named children
-- [consequence, condition, alternative]. Comprehensions carry the guard in an
-- `if_clause`; only the `body` (element) is guarded. positive_guard() below
-- resolves each shape.
-- ruby: the construct names are bare (`if`/`unless`/`while`/`until`/`elsif`),
-- the ternary is `conditional`, and a trailing MODIFIER (`use(p) if p`) is its
-- own node with `condition` + `body` — the same field shape, so it needs no
-- special case beyond being listed.
local COND = {
    if_statement = true, while_statement = true,
    conditional_expression = true, ternary_expression = true,
    list_comprehension = true, set_comprehension = true,
    dictionary_comprehension = true, generator_expression = true,
    ['if'] = true, ['unless'] = true, ['while'] = true, ['until'] = true,
    if_modifier = true, unless_modifier = true, conditional = true,
}
-- INVERTED constructs: the condition guards the body with ¬cond and the else
-- with cond. Ruby's `unless`/`until` (and the `unless` modifier) are the only
-- ones so far, and they are why polarity is looked up per construct instead of
-- being hardcoded false at each emitter.
local INVERTED = { ['unless'] = true, unless_modifier = true, ['until'] = true }
local COMPREHENSION = {
    list_comprehension = true, set_comprehension = true,
    dictionary_comprehension = true, generator_expression = true,
}
-- short-circuit boolean ops: the RIGHT operand is conditionally evaluated.
-- `a && b` → b guarded by a (positive); `a || b` → b guarded by ¬a (negated).
-- (`??` is nullish, not a boolean validator guard — excluded.)
-- (ruby's is plain `binary` and covers every operator; shortcircuit_guard reads
-- the `operator` field and returns nil for the arithmetic/comparison ones.)
local SHORTCIRCUIT = {
    binary_expression = true, boolean_operator = true, binary = true,
}
local SC_AND = { ['&&'] = true, ['and'] = true }
local SC_OR = { ['||'] = true, ['or'] = true }
-- ── the else/elseif chain (CART-0257) ────────────────────────────────────────
-- An ELSEIF clause carries its OWN condition (positively dominating its body,
-- hence folded into COND below) and stands on the negation of every condition
-- the chain tested BEFORE it. A plain ELSE adds no condition and negates them
-- all. TWO GRAMMAR FAMILIES, both handled by negated_chain():
--   FLAT   (lua `elseif_statement` / python `elif_clause`): the clauses are
--          `alternative` SIBLINGS of the one if_statement, so the preceding
--          conditions are preceding siblings.
--   NESTED (c/php/JS `else_clause`): `alternative` is a single else node the
--          next if lives inside, so each hop up the chain contributes its own.
-- `elif_clause` was missing from both tables, which is why python was not
-- merely imprecise but UNSOUND: from the 2nd `elif` the walk reached the
-- if_statement with a child that was neither its `alternative`[1] nor a known
-- else type, so the if's condition was emitted as POSITIVELY dominating.
-- ruby is the NESTED family (`elsif` carries the next clause as its alternative)
-- and its plain else is the bare type `else`.
-- ONE HOME, beside COMMENT and PARENS (CART-0304): exprlint and optimize each
-- reached for the bare literal `elseif_statement` instead — lua's name — so this
-- set moved to spec/tsutil rather than being copied a third and fourth time.
local ELSEIF = require('cartograph.spec.tsutil').ELSEIF
local ELSE_ONLY = { else_clause = true, else_statement = true, ['else'] = true }
-- direct-child types that put us on the NEGATED (else/elseif) path of an
-- enclosing if — the positive condition above does not dominate through them
local ELSE = {}
for _, t in ipairs { ELSEIF, ELSE_ONLY } do
    for k in pairs(t) do ELSE[k] = true end
end
for k in pairs(ELSEIF) do COND[k] = true end
-- climbing stops here: a guard OUTSIDE the enclosing function does not
-- dominate its body (params/sources are fresh per call)
-- ruby: `method`/`singleton_method`, plus BLOCKS (`do_block`, brace `block`,
-- `lambda`) — a block body is treated as its own scope like every other
-- language's callback here. That is conservative rather than exact (a
-- synchronously-invoked `xs.each` block DOES run under the enclosing guard), and
-- conservative is the right direction: it withholds a fact, never invents one.
-- `class`/`module` are deliberately NOT boundaries — a class body executes
-- inline, so a guard around it really does dominate it, and any method inside
-- stops the climb on its own.
local FN_BOUND = {
    function_definition = true, function_declaration = true,
    method_declaration = true, anonymous_function = true,
    arrow_function = true, lambda_expression = true,
    constructor_declaration = true,
    method = true, singleton_method = true, do_block = true, lambda = true,
}
-- ★ `block` is a TYPE-NAME COLLISION: ruby's brace block `{ |v| … }` and lua's
-- statement block are both `block`, and one is a scope boundary while the other
-- is the ordinary body of an `if`. Putting the name in FN_BOUND would have made
-- every lua guard stop dominating at the first block — i.e. silently disabled
-- guards_over for lua. They are distinguishable WITHOUT a language parameter:
-- ruby's carries a `body` field (a `block_body`), lua's has no fields at all.
-- An empty ruby `{ }` has no body and reads as the lua shape, which is harmless
-- because it contains nothing to dominate.
local function fn_bound(p)
    local t = p:type()
    if FN_BOUND[t] then return true end
    if t == 'block' then return p:field('body')[1] ~= nil end
    return false
end

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
-- p's condition, tolerating python's FIELD-LESS positional ternary
-- (`consequence if condition else alternative` → named children [0,1,2]).
local function condition_of(p)
    local c = p:field('condition')[1]
    if c then return c end
    -- @langs-ok the python-only field-less positional shape again: c/php name the same
    -- node but expose a `condition` field, which the line above already returned on
    if p:type() == 'conditional_expression' then return p:named_child(1) end
    return nil
end

-- p's ALTERNATIVE branch. For an if, this is an else-typed NODE and `ELSE` is the
-- trigger; for a TERNARY there is no such node — the else-value is an arbitrary
-- expression — so the trigger has to be the child's IDENTITY with the alternative
-- (CART-0299). Grammars that point `alternative` straight at a statement rather
-- than at an else_clause land here too, and the emitted fact is the same one.
local function alternative_of(p)
    local alt = p:field('alternative')[1]
    if alt then return alt end
    -- @langs-ok same python-only positional shape as positive_guard's, same discriminator
    if p:type() == 'conditional_expression' and not p:field('condition')[1] then
        return p:named_child(2)
    end
    return nil
end

local function positive_guard(p, child)
    local pt = p:type()
    if COMPREHENSION[pt] then
        local body = p:field('body')[1]
        if not (body and same(child, body)) then return nil end
        for c in p:iter_children() do
            -- @langs-ok if_clause exists only in python; the enclosing branch is
            -- already gated on COMPREHENSION, which no other declared grammar has
            if c:type() == 'if_clause' then return c:named_child(0) end
        end
        return nil
    end
    local cond = p:field('condition')[1]
    -- @langs-ok python-only shape: a field-LESS conditional_expression. c/php name the
    -- same node but expose a `condition` field, so `not cond` is the discriminator.
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

-- The ¬-facts owed to standing on if-like `p`'s NEGATED path, appended to `out`:
-- p's own condition, plus (FLAT grammars) every ELSEIF clause of p that the
-- chain tested before reaching `child`. The trigger is the CLAUSE node, not its
-- body, because a node inside an `elseif`'s CONDITION is on the negated path
-- too — `elseif D` is only evaluated once every earlier condition failed.
-- Each clause's contribution is `not INVERTED[clause]`: reaching the `else` of
-- `if C` means ¬C, but reaching the `else` of ruby's `unless C` means C HELD.
local function negated_chain(p, child, out)
    local cond = condition_of(p)
    if not cond then return end
    for c in p:iter_children() do
        if same(c, child) then break end
        if c:named() and ELSEIF[c:type()] then
            local cc = c:field('condition')[1]
            if cc then out[#out + 1] = { cond = cc, neg = not INVERTED[c:type()] } end
        end
    end
    out[#out + 1] = { cond = cond, neg = not INVERTED[p:type()] }
end

-- statements that unconditionally leave the flow, so a preceding
-- `if(C){…this}` guard-clause makes ¬C hold for everything after it
-- (ruby's are bare: `return`/`next`/`break`. `raise` is deliberately NOT here —
-- it is an ordinary `call`, and matching the callee by name would fire on C's
-- `raise(SIGSTOP)`, which does not leave the function. Recognising it needs a
-- per-language hook that guards_over does not take yet, and a wrong "terminates"
-- yields an unsound ¬C, so it stays refused: CART-0298's note.)
local TERM = {
    return_statement = true, throw_statement = true, break_statement = true,
    continue_statement = true, goto_statement = true, exit_statement = true,
    ['return'] = true, ['next'] = true, ['break'] = true,
}
-- statement CONTAINERS: where the early-exit sibling scan looks for a preceding
-- guard clause. ruby's are `body_statement` (a method/class body), `then` (an
-- if/unless consequence), `do` (a loop body), `block_body`, and `else`.
local BLOCK = {
    block = true, compound_statement = true, program = true,
    body_statement = true, ['then'] = true, ['do'] = true, block_body = true,
    ['else'] = true,
}
-- constructs that can BE a preceding early-exit guard clause. Ruby's dominant
-- form is the MODIFIER (`return unless p`), which is exactly why this had to stop
-- being a hardcoded `== 'if_statement'` test: the idiom this whole mechanism
-- exists for is spelled with the INVERTED keyword in the language where it is
-- most common.
local GUARD_CLAUSE = {
    if_statement = true,
    ['if'] = true, ['unless'] = true, if_modifier = true, unless_modifier = true,
}

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
    -- a BRACELESS single-statement body (`if(!p) continue;`) IS the terminating
    -- statement itself, not a block whose last child terminates — check it directly
    -- (else early-exit guards without braces are silently missed, [[cartograph-nil-flow]]).
    if TERM[body:type()] then return true end
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
--- positive nesting (cond holds at node); neg=true = ¬cond holds at node, from
--- a preceding terminating guard-clause `if(cond){…exit}`, an `||` left operand,
--- or an else/elseif chain the node stands on. A node inside a condition is not
--- dominated by it. Every consumer reads `neg` as pure POLARITY (the asserted
--- truth value is `not neg`), so the three sources are interchangeable.
function M.guards_over(node, src)
    local out = {}
    local child, p = node, node:parent()
    while p do
        if fn_bound(p) then break end
        if COND[p:type()] then
            local cond = positive_guard(p, child)
            if cond then
                out[#out + 1] = { cond = cond, neg = INVERTED[p:type()] or false }
            elseif ELSE[child:type()] or same(child, alternative_of(p)) then
                -- an else-typed node, OR the alternative BRANCH of a ternary
                negated_chain(p, child, out)
            end
        elseif SHORTCIRCUIT[p:type()] then
            local cond, neg = shortcircuit_guard(p, child, src)
            if cond then out[#out + 1] = { cond = cond, neg = neg } end
        end
        -- early-exit guard-clauses: preceding `if(C){…exit}` siblings of the
        -- statement `child`, within this block, make ¬C dominate `node` — or C
        -- itself, when the clause is INVERTED (`return unless p` ⇒ p is truthy
        -- after it, which is the ruby guard clause).
        if BLOCK[p:type()] then
            for c in p:iter_children() do
                if same(c, child) then break end
                if c:named() and GUARD_CLAUSE[c:type()]
                    and not c:field('alternative')[1] then -- no else branch
                    local cond = c:field('condition')[1]
                    if cond and terminates(if_body(c), src) then
                        out[#out + 1] = { cond = cond, neg = not INVERTED[c:type()] }
                    end
                end
            end
        end
        child, p = p, p:parent()
    end
    return out
end

-- ── the EXECUTABLE graph (CART-1240 leaf 3) ─────────────────────────────────────────────────────────────────────────
--- A function body as an executable CONTROL-FLOW GRAPH: one node per simple statement / condition, each with its AST
--- node, and LABELED edges — a condition's `T` and `F`, a switch's `case` (with the case's value node) and `default`,
--- `always` otherwise. goto, break, continue, a switch's fall-through and a loop's back edge are plain edges; a label is
--- a node a goto points at. (flow.successors is the NAME-dataflow CFG over flow's rows — unlabeled edges, no AST node,
--- over-approximated cases; this one is for a consumer that EVALUATES conditions: cartograph.luajs.cpath.)
--- @langs c
--- -> { nodes = { [id] = { k = 'stmt'|'cond'|'switch'|'ret'|'nop', ast, succ = { { to, on, val } } } }, entry, exit = 'exit',
---      heads = { [id] = true } (targets of a back edge: where a fixpoint widens) }
function M.graph(fnnode, src)
    local nodes, labels, gotos = {}, {}, {}
    local function kids(n) local o = {} for c in n:iter_children() do if c:named() and c:type() ~= 'comment' then o[#o + 1] = c end end return o end
    local function new(k, ast) local id = #nodes + 1; nodes[id] = { k = k, ast = ast, succ = {} }; return id end
    local function edge(a, b, on, val) table.insert(nodes[a].succ, { to = b, on = on or 'always', val = val }) end
    local lower
    local function seq(list, nxt, cx)
        local cur = nxt
        for i = #list, 1, -1 do cur = lower(list[i], cur, cx) end
        return cur
    end
    function lower(n, nxt, cx)
        local t = n:type()
        if t == 'compound_statement' then return seq(kids(n), nxt, cx)
        elseif t == 'if_statement' then
            local c = new('cond', n:field('condition')[1])
            local alt = n:field('alternative')[1]
            if alt and alt:type() == 'else_clause' then alt = kids(alt)[1] end -- @langs-ok M.graph is C only (its @langs c)
            edge(c, lower(n:field('consequence')[1], nxt, cx), 'T')
            edge(c, alt and lower(alt, nxt, cx) or nxt, 'F')
            return c
        elseif t == 'while_statement' then
            local c = new('cond', n:field('condition')[1])
            edge(c, lower(n:field('body')[1], c, { brk = nxt, cont = c }), 'T')
            edge(c, nxt, 'F')
            return c
        elseif t == 'do_statement' then
            local c = new('cond', n:field('condition')[1])
            local body = lower(n:field('body')[1], c, { brk = nxt, cont = c })
            edge(c, body, 'T')
            edge(c, nxt, 'F')
            return body
        elseif t == 'for_statement' then
            local cond, upd, init = n:field('condition')[1], n:field('update')[1], n:field('initializer')[1]
            local head = cond and new('cond', cond) or new('nop', n)
            local un = upd and new('stmt', upd) or head
            if upd then edge(un, head) end
            local body = lower(n:field('body')[1], un, { brk = nxt, cont = un })
            if cond then edge(head, body, 'T'); edge(head, nxt, 'F') else edge(head, body) end
            if init then local i = new('stmt', init); edge(i, head); return i end
            return head
        elseif t == 'switch_statement' then
            local sw = new('switch', n:field('condition')[1])
            local cases = {}
            for _, c in ipairs(kids(n:field('body')[1])) do if c:type() == 'case_statement' then cases[#cases + 1] = c end end -- @langs-ok M.graph is C only
            local sub = { brk = nxt, cont = cx.cont }
            local entry, after = {}, nxt
            for i = #cases, 1, -1 do
                local v = cases[i]:field('value')[1]
                local stmts = {}
                for _, s in ipairs(kids(cases[i])) do if not (v and s:equal(v)) then stmts[#stmts + 1] = s end end
                entry[i] = seq(stmts, after, sub) -- (falling through into the next case's statements)
                after = entry[i]
            end
            local hasdef = false
            for i, c in ipairs(cases) do
                local v = c:field('value')[1]
                if v then edge(sw, entry[i], 'case', v) else edge(sw, entry[i], 'default'); hasdef = true end
            end
            if not hasdef then edge(sw, nxt, 'default') end
            return sw
        elseif t == 'return_statement' then
            local r = new('ret', n)
            edge(r, 'exit')
            return r
        elseif t == 'break_statement' then local j = new('nop', n); edge(j, cx.brk or nxt); return j
        elseif t == 'continue_statement' then local j = new('nop', n); edge(j, cx.cont or nxt); return j
        elseif t == 'goto_statement' then
            local j = new('nop', n)
            gotos[#gotos + 1] = { j, vim.treesitter.get_node_text(n:field('label')[1], src) }
            return j
        elseif t == 'labeled_statement' then
            local inner
            for c in n:iter_children() do if c:named() and c:type() ~= 'statement_identifier' then inner = c end end -- @langs-ok M.graph is C only
            local l = new('nop', n)
            edge(l, inner and lower(inner, nxt, cx) or nxt)
            labels[vim.treesitter.get_node_text(n:field('label')[1], src)] = l
            return l
        elseif t == 'expression_statement' or t == 'declaration' then
            local s = new('stmt', n)
            edge(s, nxt)
            return s
        end
        local s = new('nop', n) -- (anything else passes through: an empty statement, a type definition)
        edge(s, nxt)
        return s
    end
    local entry = lower(fnnode:field('body')[1], 'exit', {})
    for _, g in ipairs(gotos) do edge(g[1], labels[g[2]] or 'exit') end
    -- the LOOP HEADS: every target of a back edge (a depth-first walk from the entry)
    local heads, state = {}, {}
    local function dfs(id)
        state[id] = 1
        for _, e in ipairs(nodes[id].succ) do
            if e.to ~= 'exit' then
                if state[e.to] == 1 then heads[e.to] = true
                elseif not state[e.to] then dfs(e.to) end
            end
        end
        state[id] = 2
    end
    if entry ~= 'exit' then dfs(entry) end
    -- REVERSE POSTORDER (a fixpoint visits a node after its forward predecessors: one pass for acyclic code)
    local rpo, post, seen = {}, {}, {}
    local function po(id)
        seen[id] = true
        for _, e in ipairs(nodes[id].succ) do if e.to ~= 'exit' and not seen[e.to] then po(e.to) end end
        post[#post + 1] = id
    end
    if entry ~= 'exit' then po(entry) end
    for i = #post, 1, -1 do rpo[post[i]] = #post - i + 1 end
    return { nodes = nodes, entry = entry, exit = 'exit', heads = heads, rpo = rpo }
end

return M
