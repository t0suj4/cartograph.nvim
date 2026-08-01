-- EXPR — the per-flow-row EXPRESSION layer ([[cartograph-expression-layer]] INC 1).
-- flow rows carry def/use/parent/rmw but NOTHING about the value expression
-- (operator, operands, callee, literals, allocations); every consumer re-derived
-- that from SOURCE TEXT or a private AST re-walk (optimize's `{`/`function` scans,
-- narrow's re-parse, sinkflow's ~20 text probes). This module harvests ONE
-- canonical, closed, language-agnostic expression IR per row and exposes derived
-- predicates that subsume those heuristics.
--
-- CLOSED SCHEMA (the uniform-honesty invariant applied to expressions — any
-- construct the harvest doesn't model becomes `?`, never a lie):
--   { k='lit',   ty='num'|'str'|'bool'|'nil', v=<value> }
--   { k='name',  n='x' }
--   { k='field', b=<expr>, n='sel', method=<bool> }   -- a.b / a:b
--   { k='index', b=<expr>, i=<expr> }                 -- a[b]
--   { k='call',  f=<expr>, a={<expr>...}, method=<bool> }
--   { k='un',    op='-'|'not'|'#'|..., e=<expr> }
--   { k='bin',   op='+'|'..'|'and'|'or'|'=='|..., l=<expr>, r=<expr> }
--   { k='table' }                                     -- ALLOCATION (fresh identity)
--   { k='pair',  key=<expr>, val=<expr>? }            -- a constructor's k=v entry;
--       `key` is a str lit when the property name is KNOWN, an expression when the
--       key is computed. `kids` carries both halves so kids-walkers still see them.
--   { k='fn' }                                        -- ALLOCATION (closure)
--   { k='vararg' }
--   { k='?', t=<node type>, kids={<expr>...} }         -- honest unknown; kids keep
--       the sub-expressions so `?` NEVER hides a name (the self-gate can't be
--       fooled by an unmapped construct).
-- Per row: { lhs={<expr>...}, rhs={<expr>...}, cond=<expr>? }.
--
-- ALIGNMENT BY CONSTRUCTION: the harvest is CO-EMITTED inside flow.build's own
-- statement walk (via the cfg.expr seam), at the single row-birth point — by then
-- rust/labeled unwrapping has happened and `node` IS the row's node, so row↔expr
-- is 1:1 with no fragile (l,c)→node mapping. `expr.of` re-runs that build on demand
-- (INC 1 is in-memory, not folded → no cache VERSION bump); the FOLD lands as its
-- own later cut (id-equality = free CSE key).
--
-- THE FREE SELF-GATE: `expr.reads(row)` (identifier leaves the expr tree reads) is
-- an INDEPENDENT derivation of `row.use ∪ row.rmw` (du's read census over the same
-- node). They must match exactly — a mismatch is a real bug on ONE side (the
-- disagreement-oracle discipline, inside the substrate). `expr.gate` runs it.

local at = require 'cartograph.at'

local M = {}

-- a sentinel distinguishing a KNOWN nil value (`eval` of a `nil` literal) from
-- "unknown" (eval returning nil,nil). Never leaks into the schema.
local NIL = setmetatable({}, { __tostring = function () return 'nil' end })
M.NIL = NIL

-- calls returning a FRESH mutable object (new identity each call) — pure w.r.t. the
-- world but unsafe to reuse/hoist the same way `{}` is. Matched by callee base name.
-- Mirrors optimize.KNOWN_ALLOC; kept here so `allocates` is a pure fn of the IR.
local KNOWN_ALLOC = { deepcopy = true, setmetatable = true, tbl_extend = true,
    tbl_deep_extend = true, list_extend = true, list_slice = true, split = true,
    tbl_keys = true, tbl_values = true, tbl_map = true, tbl_filter = true }

local function txt(n, src) return n and vim.treesitter.get_node_text(n, src) or '' end

-- literal node types (Lua-first; the shared cross-language names). A per-language
-- harvest can extend these — anything unlisted falls to the `?` honest-unknown path.
local LIT = { number = 'num', integer = 'num', float = 'num', string = 'str',
    string_literal = 'str', true_ = 'bool', ['true'] = 'bool', ['false'] = 'bool',
    boolean = 'bool', ['nil'] = 'nil', null = 'nil' }
local NAME = { identifier = true, name = true }
-- LANGUAGE COVERAGE IS PARTIAL, AND JAVA IS ESSENTIALLY UNMODELLED. Measured
-- 2026-07-26 on 200 java functions from the elasticsearch libs corpus: 766 rows
-- carrying expressions, 2074 OPAQUE (`?`) nodes, ZERO field nodes, zero dotted
-- reads — and optimize found 0 hoists and 0 CSE across 120 methods. The
-- expression-based analyzers (optimize's LICM/CSE, narrow, untangle, exprlint) are
-- therefore blind on Java, not because Java lacks opportunities but because an
-- opaque node has an opaque key: no two expressions compare equal and no purity
-- gate passes.
--
-- THE GAP IS BROAD, NOT ONE ENTRY. Top opaque node types: argument_list 532,
-- method_invocation 501 (java's CALL, absent from the CALL table below),
-- expression_statement 301, decimal_integer_literal 98, line_comment 62,
-- type_identifier 52, assignment_expression 45, object_creation_expression 31,
-- null_literal 29, array_access 21. Calls, literals, assignment, allocation and
-- indexing are all unmodelled.
--
-- ADDING `field_access` ALONE WAS TRIED AND REVERTED, deliberately. It did what it
-- said (opaque 2074 -> 1966, 108 field nodes, 91 dotted reads) but unblocked
-- nothing — optimize stayed at 0/0, since the surrounding method_invocation nodes
-- remain opaque — and it DOUBLED greenspun's registry-audit findings on the corpus,
-- 6 -> 12, all spurious: ordinary java methods (`assertRectangleResult`,
-- `setBucket`, `getRank`) reported as registries with "100 key(s) dispatched".
-- A partial grammar makes a downstream detector noisier without making any analyzer
-- more capable.
--
-- SO JAVA COVERAGE IS A PROJECT, not a one-word change, and it carries SEMANTIC
-- risk rather than merely structural: method_invocation decides is_pure,
-- object_creation_expression decides allocates, and optimize can APPLY rewrites. A
-- wrong entry there proposes an UNSOUND edit rather than a missing one. Whoever
-- takes it should add the entries together, with the purity/allocation semantics
-- checked, and re-measure registry-audit as the canary.
local FIELD = { dot_index_expression = true, field_expression = true,
    member_expression = true }
local INDEX = { bracket_index_expression = true, subscript_expression = true,
    index_expression = true }
local METHOD = { method_index_expression = true }
local CALL = { function_call = true, call_expression = true, call = true,
    function_call_expression = true }
local BIN = { binary_expression = true, binary_operation = true }
local UN = { unary_expression = true, unary_operation = true }
local TABLE = { table_constructor = true, table = true }
local ALLOCFN = { function_definition = true, function_declaration = true,
    anonymous_function = true, arrow_function = true, lambda_expression = true }
local VARARG = { vararg_expression = true, vararg = true, spread_element = true }
-- KEY-VALUE PAIRS inside a constructor (CART-0220). VERIFIED per language by
-- parsing a snippet and reading the grammar's own node names — not guessed:
--   lua           `field`   in table_constructor   (name/value field accessors)
--   javascript    `pair`    in object
--   typescript    `pair`    in object
--   python        `pair`    in dictionary
--   ruby          `pair`    in hash (and in keyword arguments, which is the same shape)
--   php           `array_element_initializer` in array_creation_expression
--   rust          `field_initializer` in field_initializer_list
--   haskell       `field_update` in record
-- DELIBERATELY ABSENT, each for a reason:
--   zig — its `.key = 1` parses as `assignment_expression`, a node used for ordinary
--     assignment everywhere else. Adding it would re-kind every assignment in the
--     language, which is the "a wrong entry proposes an unsound edit" hazard the java
--     note above describes.
--   go / c / cpp / odin — their pair nodes (`keyed_element`, `initializer_pair`, …)
--     did not reproduce in the verification snippets, so they are unverified. Add one
--     only with its own parse check; an unverified name is a silent no-op, and a
--     WRONG one is worse.
local PAIR = { field = true, pair = true, array_element_initializer = true,
    field_initializer = true, field_update = true }
local PAREN = { parenthesized_expression = true }
local UNWRAP = { expression_list = true, variable_list = true }

-- ── the recursive harvest: a TS node → a schema expr ─────────────────────────
local build, build_core

-- OPERAND nodes = named, non-COMMENT children. Comments are named children, so a
-- `--` between operands of a multi-line expression would otherwise shift
-- `named_child(N)` onto the comment and drop the real operand ([[self-gate found
-- this]]). Filtering comments makes operand extraction position-stable.
local function operands(node)
    local out = {}
    for c in node:iter_children() do
        if c:named() and c:type() ~= 'comment' then out[#out + 1] = c end
    end
    return out
end
-- the OPERATOR token = the first UNNAMED child (operators are anonymous tokens;
-- operands and comments are named). Robust to interspersed comments.
local function op_token(node, src)
    for c in node:iter_children() do
        if not c:named() then
            local x = vim.trim(txt(c, src))
            if x ~= '' then return x end
        end
    end
    return ''
end

-- callee + flattened argument nodes of a call (handles `f(a,b)`, `f{}`, `f"s"`)
local function call_parts(node)
    local callee, args, i = nil, {}, 0
    for c in node:iter_children() do
        if c:named() and c:type() ~= 'comment' then
            if i == 0 then callee = c
            elseif c:type() == 'arguments' or c:type() == 'argument_list' then
                for a in c:iter_children() do
                    if a:named() and a:type() ~= 'comment' then args[#args + 1] = a end
                end
            else args[#args + 1] = c end
            i = i + 1
        end
    end
    return callee, args
end

-- build_core produces the schema node; `build` (below) wraps it to stamp `.at`
-- (the source byte-range) on every node — the enabler for source-precise consumers
-- (clone-extraction hole substitution, refactoring). `.at` is a plain range table
-- { start={line,char}, end={line,char} } (0-based rows, as at.sl/sc/el/ec read); the
-- coordinates are FILE-ABSOLUTE because expr.of parses the whole file. The IR is rebuilt
-- on demand (never folded/persisted) so this is additive — no cache/VERSION impact.
function build_core(node, src)
    if not node then return { k = '?', t = '<nil>', kids = {} } end
    local t = node:type()
    if PAREN[t] then return build(node:named_child(0), src) end
    if UNWRAP[t] then -- a list where one expr is expected: build the sole child, else `?`
        local only, n = nil, 0
        for c in node:iter_children() do if c:named() and c:type() ~= 'comment' then only = c; n = n + 1 end end
        if n == 1 then return build(only, src) end
    end
    local lty = LIT[t]
    if lty then
        local v
        if lty == 'num' then v = tonumber((txt(node, src)))
        elseif lty == 'str' then v = txt(node, src) -- raw text incl. quotes; eval strips
        elseif lty == 'bool' then v = (txt(node, src) == 'true')
        elseif lty == 'nil' then v = NIL end
        return { k = 'lit', ty = lty, v = v }
    end
    if NAME[t] then return { k = 'name', n = txt(node, src) } end
    if t == 'variable_name' then -- php $x: the inner name is the variable
        local inner = node:named_child(0)
        return { k = 'name', n = (txt(inner or node, src):gsub('^%$', '')) }
    end
    if FIELD[t] then
        local o = operands(node)
        return { k = 'field', b = build(o[1], src), n = txt(o[2], src), method = false }
    end
    if METHOD[t] then
        local o = operands(node)
        return { k = 'field', b = build(o[1], src), n = txt(o[2], src), method = true }
    end
    if INDEX[t] then
        local o = operands(node)
        return { k = 'index', b = build(o[1], src), i = build(o[2], src) }
    end
    if CALL[t] then
        local callee, argnodes = call_parts(node)
        local a = {}
        for _, an in ipairs(argnodes) do a[#a + 1] = build(an, src) end
        local f = build(callee, src)
        return { k = 'call', f = f, a = a, method = (f.k == 'field' and f.method) or false }
    end
    if BIN[t] then
        local o = operands(node)
        return { k = 'bin', op = op_token(node, src), l = build(o[1], src), r = build(o[2], src) }
    end
    if UN[t] then
        local o = operands(node)
        return { k = 'un', op = op_token(node, src), e = build(o[1], src) }
    end
    if TABLE[t] then
        -- an ALLOCATION (fresh identity) but its field VALUES/keys READ names — carry
        -- them as kids so the read-set stays faithful to du (which descends the table).
        local kids = {}
        for c in node:iter_children() do
            if c:named() and c:type() ~= 'comment' then kids[#kids + 1] = build(c, src) end
        end
        return { k = 'table', kids = kids }
    end
    if PAIR[t] then
        -- A KEY-VALUE PAIR. `key`/`val` name the halves so a consumer never has to
        -- know the grammar; `kids` is kept as well so every traversal that walks kids
        -- keeps seeing both, which is what stops a name inside a constructor from
        -- disappearing from the read-set.
        --
        -- THE KEY IS NORMALIZED HERE, because only the harvest knows the language:
        -- in Lua `{x = 1}` and `{["x"] = 1}` are the SAME key, while `{[x] = 1}` is a
        -- computed one — and the grammar reports `name=identifier` for both the first
        -- and the last. A bracketed key is detected by the `[` token and kept as an
        -- EXPRESSION; a bare identifier becomes a string literal, so a consumer's test
        -- is uniform: `key.k == 'lit'` means the property name is known.
        -- NB a synthesized key literal carries no quotes, exactly as its source text
        -- has none; a real `["x"]` keeps the source quotes like every other str lit.
        local kn = node:field('name')[1] or node:field('key')[1]
        local vn = node:field('value')[1]
        local ops = operands(node)
        if not (kn or vn) then vn = ops[1] end
        -- POSITIONAL element (`{1, 2}`): no key at all, so emit the VALUE itself
        -- rather than a pair with a hole. Keeps the read-set byte-identical to before
        -- for array-style constructors, which are the common case in every language.
        if not kn then return vn and build(vn, src) or { k = '?', t = t, kids = {} } end
        local bracketed = false
        for c in node:iter_children() do
            if not c:named() and vim.trim(txt(c, src)) == '[' then bracketed = true; break end
        end
        local key
        if not bracketed and kn:type():match('identifier') then
            key = { k = 'lit', ty = 'str', v = txt(kn, src) }
        else
            key = build(kn, src)
        end
        local val = vn and build(vn, src) or nil
        return { k = 'pair', key = key, val = val,
            kids = val and { key, val } or { key } }
    end
    if ALLOCFN[t] then return { k = 'fn' } end -- NEVER descend a closure body (du doesn't either)
    if VARARG[t] then return { k = 'vararg' } end
    -- honest unknown: keep the named children as kids so no name is hidden
    local kids = {}
    for c in node:iter_children() do
        if c:named() and c:type() ~= 'comment' then kids[#kids + 1] = build(c, src) end
    end
    return { k = '?', t = t, kids = kids }
end

-- stamp the source range on every node built (see build_core's note). A node built
-- from no TS node (build(nil)) has no range → `.at` stays nil.
function build(node, src)
    local e = build_core(node, src)
    if node and type(e) == 'table' then
        local sr, sc, er, ec = node:range()
        e.at = { start = { line = sr, char = sc }, ['end'] = { line = er, char = ec } }
    end
    return e
end
M.build = build

-- ── per-row harvest ──────────────────────────────────────────────────────────
-- assignment left/right targets (fields for php/js, node types for lua)
local function assign_sides(node)
    local left = node:field('left')[1]
    local right = node:field('right')[1] or node:field('value')[1]
    if not left or not right then
        for c in node:iter_children() do
            if c:named() then
                local ct = c:type()
                if ct == 'variable_list' and not left then left = c
                elseif ct == 'expression_list' and not right then right = c end
            end
        end
    end
    return left, right
end
local function list_children(node) -- the named exprs of a *_list (or the node itself)
    if not node then return {} end
    if UNWRAP[node:type()] then
        local out = {}
        for c in node:iter_children() do
            if c:named() and c:type() ~= 'comment' then out[#out + 1] = c end
        end
        return out
    end
    return { node }
end

local ASSIGN = { assignment_statement = true, assignment = true,
    assignment_expression = true, augmented_assignment_expression = true,
    variable_assignment = true }
local LOCALDECL = { variable_declaration = true, local_declaration = true,
    local_variable_declaration = true }
local RET = { return_statement = true }
-- sub-region boundaries harvest must NOT descend from a control HEAD (mirrors du's
-- stop_body: the head owns its condition/clause, not the body or sibling clauses).
local BODY = { block = true, compound_statement = true, statement_block = true }
local CLAUSE = { else_statement = true, elseif_statement = true, elseif_clause = true,
    else_clause = true, else_if_clause = true, elif_clause = true,
    case_statement = true, default_statement = true, expression_case = true,
    default_case = true, catch_clause = true, except_clause = true, finally_clause = true }

--- harvest a statement node into a row-expr record. `hint` (set by flow.build at the
--- row-birth point, so flow's emit policy drives the boundary):
---   'cond'     — the node IS a bare condition expression (POST-loop cond re-emit)
---   'ctrlhead' — a control head: condition + clause, NOT the body (du's stop_body)
---   'casehead' — a switch case: only its `value` label
---   (nil)      — a plain statement (assignment / return / bare expression)
--- @return table { lhs={expr...}, rhs={expr...}, cond=expr? }
function M.harvest_row(node, src, hint)
    if hint == 'cond' then return { lhs = {}, rhs = {}, cond = build(node, src) } end
    if hint == 'casehead' then
        local v = node:field('value')[1]
        return { lhs = {}, rhs = {}, cond = v and build(v, src) or nil }
    end
    if hint == 'ctrlhead' then
        local cond = node:field('condition')[1] or node:field('value')[1]
        local rhs = {}
        for c in node:iter_children() do
            if c:named() then
                local ct = c:type()
                if ct ~= 'comment' and not BODY[ct] and not CLAUSE[ct] then
                    rhs[#rhs + 1] = build(c, src)
                end
            end
        end
        return { lhs = {}, rhs = rhs, cond = cond and build(cond, src) or nil }
    end
    local t = node:type()
    -- lua `local x = e` wraps an assignment_statement; unwrap to it
    if LOCALDECL[t] then
        for c in node:iter_children() do
            if c:named() and ASSIGN[c:type()] then return M.harvest_row(c, src) end
        end
        -- bare `local a, b` (no initializer): the names are defs, no value exprs
        local lhs = {}
        for c in node:iter_children() do
            for _, tn in ipairs(list_children(c)) do
                if NAME[tn:type()] or tn:type() == 'variable_list' then
                    lhs[#lhs + 1] = build(tn, src)
                end
            end
        end
        return { lhs = lhs, rhs = {} }
    end
    if ASSIGN[t] then
        local left, right = assign_sides(node)
        local lhs, rhs = {}, {}
        for _, tn in ipairs(list_children(left)) do lhs[#lhs + 1] = build(tn, src) end
        for _, vn in ipairs(list_children(right)) do rhs[#rhs + 1] = build(vn, src) end
        return { lhs = lhs, rhs = rhs }
    end
    -- control heads carry a condition (the switched value for go switch)
    local cond = node:field('condition')[1] or node:field('value')[1]
    if cond then return { lhs = {}, rhs = {}, cond = build(cond, src) } end
    if RET[t] then
        local rhs = {}
        for c in node:iter_children() do
            for _, vn in ipairs(list_children(c)) do
                if vn:named() and vn:type() ~= 'comment' then rhs[#rhs + 1] = build(vn, src) end
            end
        end
        return { lhs = {}, rhs = rhs }
    end
    -- default: a bare expression statement (a call, etc.) — the whole node is a value
    return { lhs = {}, rhs = { build(node, src) } }
end

-- ── traversal + predicates ─────────────────────────────────────────────────
-- visit every expr node in a tree (pre-order)
local function walk(e, fn)
    if not e then return end
    fn(e)
    if e.k == 'field' then walk(e.b, fn)
    elseif e.k == 'index' then walk(e.b, fn); walk(e.i, fn)
    elseif e.k == 'call' then walk(e.f, fn); for _, a in ipairs(e.a) do walk(a, fn) end
    elseif e.k == 'un' then walk(e.e, fn)
    elseif e.k == 'bin' then walk(e.l, fn); walk(e.r, fn)
    elseif e.k == '?' or e.k == 'table' or e.k == 'pair' then
        for _, c in ipairs(e.kids or {}) do walk(c, fn) end
    end
end
M.walk = walk

--- canonical STRUCTURAL key — equal keys ⟺ structurally-identical expressions.
--- Order-sensitive (commutativity is a later refinement). ALLOCATIONS (table/fn)
--- get a constant opaque key; equality-based consumers MUST gate on `is_pure`
--- (two `{}` are NOT the same value). The free CSE identity once folded.
function M.key(e)
    if not e then return '_' end
    local k = e.k
    if k == 'lit' then return 'L' .. e.ty .. ':' .. tostring(e.v) end
    if k == 'name' then return 'N' .. e.n end
    if k == 'field' then return (e.method and 'M' or 'F') .. M.key(e.b) .. '.' .. e.n end
    if k == 'index' then return 'I' .. M.key(e.b) .. '[' .. M.key(e.i) .. ']' end
    if k == 'call' then
        local parts = {}
        for _, a in ipairs(e.a) do parts[#parts + 1] = M.key(a) end
        return 'C' .. M.key(e.f) .. '(' .. table.concat(parts, ',') .. ')'
    end
    if k == 'un' then return 'U' .. e.op .. M.key(e.e) end
    if k == 'bin' then return 'B' .. e.op .. '(' .. M.key(e.l) .. ',' .. M.key(e.r) .. ')' end
    if k == 'pair' then
        return 'P' .. M.key(e.key) .. ':' .. (e.val and M.key(e.val) or '')
    end
    if k == 'table' then return 'T' end
    if k == 'fn' then return 'Fn' end
    if k == 'vararg' then return 'V' end
    local parts = {}
    for _, c in ipairs(e.kids or {}) do parts[#parts + 1] = M.key(c) end
    return '?' .. (e.t or '') .. '(' .. table.concat(parts, ',') .. ')'
end

--- the DOTTED path of a name/field chain (`vim.api.nvim_x`), or nil if it isn't a
--- pure name.field.field… chain (an index/call/etc. in the way → nil).
function M.dotted(e)
    if not e then return nil end
    if e.k == 'name' then return e.n end
    if e.k == 'field' then
        local b = M.dotted(e.b)
        return b and (b .. '.' .. e.n) or nil
    end
    return nil
end

--- the ROOT name of a name/field/index/call chain (`vim` in `vim.api.f(x)`), or nil.
function M.rootname(e)
    if not e then return nil end
    if e.k == 'name' then return e.n end
    if e.k == 'field' or e.k == 'index' then return M.rootname(e.b) end
    if e.k == 'call' then return M.rootname(e.f) end
    return nil
end

--- The OUTERMOST dotted chains READ inside an expression — every `a.b.c` that is
--- not merely a prefix of a longer one. M.dotted answers for a whole expression and
--- returns nil the moment an index or call is in the way, so it cannot see the
--- `game.entity_prototypes` inside `game.entity_prototypes["x"]`; this walks in and
--- reports the chains it finds. Descent STOPS at a hit, so prefixes (`game`) are not
--- reported alongside the chain that contains them.
---
--- THE CALLEE POSITION IS NOT A READ, and is skipped. `string.find(x)` is a CALL —
--- the call surface already holds it — so including it here would make the two
--- surfaces overlap and neither could be reported as evidence of its own kind. What
--- remains is precisely "names touched but not invoked", which is the class the
--- call-derived surface can never see. Arguments ARE read, so they descend.
---
--- The traversal lives here because this layer owns the closed schema: a consumer
--- hand-rolling the `k` cases would be a second place to update when it changes.
function M.dotted_reads(e, out)
    out = out or {}
    if not e then return out end
    local d = M.dotted(e)
    if d and d:find('%.') then out[#out + 1] = d; return out end
    if e.k == 'field' then M.dotted_reads(e.b, out)
    elseif e.k == 'index' then M.dotted_reads(e.b, out); M.dotted_reads(e.i, out)
    elseif e.k == 'call' then
        -- e.f (the callee) deliberately NOT descended: see above
        for _, a in ipairs(e.a or {}) do M.dotted_reads(a, out) end
    elseif e.k == 'un' then M.dotted_reads(e.e, out)
    elseif e.k == 'bin' then M.dotted_reads(e.l, out); M.dotted_reads(e.r, out)
    elseif e.k == '?' or e.k == 'table' or e.k == 'pair' then
        for _, c in ipairs(e.kids or {}) do M.dotted_reads(c, out) end
    end
    return out
end

--- PURE = no call / allocation / unknown / vararg anywhere. The single safety gate
--- for every key-equality lint (comparing two side-effecting operands is unsound).
function M.is_pure(e)
    local pure = true
    walk(e, function (n)
        if n.k == 'call' or n.k == 'table' or n.k == 'fn' or n.k == '?' or n.k == 'vararg' then
            pure = false
        end
    end)
    return pure
end

--- ALLOCATES = does evaluating this expression create a fresh-identity object
--- (a table constructor, a closure, or a KNOWN_ALLOC call)? Subsumes optimize's
--- `{`/`function` text scan + alloc-callee line map, structurally.
function M.allocates(e)
    local yes = false
    walk(e, function (n)
        if n.k == 'table' or n.k == 'fn' then yes = true
        elseif n.k == 'call' then
            -- base name of the callee (name / field selector)
            local base = (n.f.k == 'name' and n.f.n) or (n.f.k == 'field' and n.f.n)
            if base and KNOWN_ALLOC[base] then yes = true end
        end
    end)
    return yes
end

--- READS-CONTENT = does it structurally read a container's contents (index / field /
--- length)? These are values a mutation elsewhere can change (du can't see them) —
--- what optimize's `[%[%]#]` scan approximated. A pure MODULE receiver (string in
--- string.format) is exempt STRUCTURALLY: a field whose base is a bare name used as
--- a call target isn't a content read. INC 1 keeps it simple: any field/index/`#`.
function M.reads_content(e)
    local yes = false
    walk(e, function (n)
        if n.k == 'field' or n.k == 'index' then yes = true
        elseif n.k == 'un' and n.op == '#' then yes = true end
    end)
    return yes
end

-- identifier-leaf READS of one expression, du-faithfully: a `name` is a read; a
-- dot/method field SELECTOR counts (du counts the `k` identifier in `a.k`); an
-- allocation/`?` recurses its operands. This is the leaf census the self-gate
-- reconciles with du — NOT the semantic variable set (a field selector isn't a var).
local function expr_reads(e, acc)
    if not e then return end
    local k = e.k
    if k == 'name' then acc[e.n] = true
    elseif k == 'field' then expr_reads(e.b, acc); if e.n and e.n ~= '' then acc[e.n] = true end
    elseif k == 'index' then expr_reads(e.b, acc); expr_reads(e.i, acc)
    elseif k == 'call' then expr_reads(e.f, acc); for _, a in ipairs(e.a) do expr_reads(a, acc) end
    elseif k == 'un' then expr_reads(e.e, acc)
    elseif k == 'bin' then expr_reads(e.l, acc); expr_reads(e.r, acc)
    elseif k == '?' or k == 'table' or k == 'pair' then
        for _, c in ipairs(e.kids or {}) do expr_reads(c, acc) end
    end
    -- lit / fn / vararg: no leaf reads
end

-- the READS of an lhs TARGET: a plain name is a DEF (not read); a field/index target
-- reads its base + key + selector (`t.k = v` reads t and the selector k).
local function target_reads(e, acc)
    if not e then return end
    if e.k == 'name' then return end -- pure def
    expr_reads(e, acc)
end

--- the identifier leaves READ by a whole row (rhs values + lhs target bases/keys +
--- condition). Equals `row.use ∪ row.rmw` when the harvest is faithful (the gate).
--- @return string[] (sorted)
function M.reads(row)
    local acc = {}
    for _, e in ipairs(row.rhs or {}) do expr_reads(e, acc) end
    for _, e in ipairs(row.lhs or {}) do target_reads(e, acc) end
    if row.cond then expr_reads(row.cond, acc) end
    local out = {}
    for n in pairs(acc) do out[#out + 1] = n end
    table.sort(out)
    return out
end

--- names semantically READ (a field selector is NOT a variable) — for lints / eval env.
function M.names(row)
    local acc = {}
    local function vars(e)
        if not e then return end
        local k = e.k
        if k == 'name' then acc[e.n] = true
        elseif k == 'field' then vars(e.b)
        elseif k == 'index' then vars(e.b); vars(e.i)
        elseif k == 'call' then vars(e.f); for _, a in ipairs(e.a) do vars(a) end
        elseif k == 'un' then vars(e.e)
        elseif k == 'bin' then vars(e.l); vars(e.r)
        elseif k == '?' or k == 'table' or k == 'pair' then
            for _, c in ipairs(e.kids or {}) do vars(c) end
        end
    end
    for _, e in ipairs(row.rhs or {}) do vars(e) end
    for _, e in ipairs(row.lhs or {}) do if e.k ~= 'name' then vars(e) end end
    vars(row.cond)
    local out = {}
    for n in pairs(acc) do out[#out + 1] = n end
    table.sort(out)
    return out
end

--- EVAL — the VM's value layer, INC-1 minimal: fold LITERALS and pure operations
--- over them (arith / comparison / concat / and-or / not / unary minus). ⊤ (returns
--- nil) for anything with a name, call, allocation, or unmapped op. Grows into
--- const-fold steps 2/4 ([[cartograph-const-fold]]) and the VM.
--- @return boolean known, any value  (value may be M.NIL for a known-nil)
function M.eval(e)
    if not e then return false end
    if e.k == 'lit' then
        if e.ty == 'str' then
            -- strip one layer of matching quotes for value comparison; leave raw if odd
            local s = e.v or ''
            local q = s:sub(1, 1)
            if (q == '"' or q == "'") and s:sub(-1) == q and #s >= 2 then return true, s:sub(2, -2) end
            return true, s
        end
        return true, e.v
    end
    if e.k == 'un' then
        local ok, v = M.eval(e.e)
        if not ok then return false end
        if e.op == 'not' or e.op == '!' then return true, not (v and v ~= NIL) end
        if e.op == '-' then if type(v) == 'number' then return true, -v end end
        return false
    end
    if e.k == 'bin' then
        local okl, l = M.eval(e.l)
        -- short-circuit and/or need only sometimes evaluate the right
        if e.op == 'and' then
            if not okl then return false end
            if not (l and l ~= NIL) then return true, l end -- falsy → l
            return M.eval(e.r)
        end
        if e.op == 'or' then
            if not okl then return false end
            if l and l ~= NIL then return true, l end -- truthy → l
            return M.eval(e.r)
        end
        local okr, r = M.eval(e.r)
        if not (okl and okr) then return false end
        local op = e.op
        if op == '..' then
            local ls = (l == NIL) and nil or l; local rs = (r == NIL) and nil or r
            if (type(ls) == 'string' or type(ls) == 'number')
                and (type(rs) == 'string' or type(rs) == 'number') then
                return true, tostring(ls) .. tostring(rs)
            end
            return false
        end
        if op == '==' then return true, l == r end
        if op == '~=' or op == '!=' then return true, l ~= r end
        if type(l) == 'number' and type(r) == 'number' then
            if op == '+' then return true, l + r end
            if op == '-' then return true, l - r end
            if op == '*' then return true, l * r end
            if op == '/' then if r ~= 0 then return true, l / r end return false end
            if op == '%' then if r ~= 0 then return true, l % r end return false end
            if op == '<' then return true, l < r end
            if op == '<=' then return true, l <= r end
            if op == '>' then return true, l > r end
            if op == '>=' then return true, l >= r end
        end
        return false
    end
    return false -- name / call / field / index / table / fn / vararg / '?'
end

-- truthiness of an eval result (lua semantics: nil and false are falsy)
function M.truthy(v) return v ~= nil and v ~= false and v ~= NIL end

-- ── on-demand entry (INC 1: re-parse + rebuild; not folded) ────────────────
local spec = require('cartograph.providers.treesitter').spec
local FN_TYPES = { function_declaration = true, function_definition = true,
    method_declaration = true, method_definition = true, function_item = true }
local EXT = {} -- file ext → lang key in spec (only those with a body_field flow)
for lang, s in pairs(spec) do
    if s.body_field and s.exts then for _, e in ipairs(s.exts) do EXT[e] = lang end end
end

local function fn_node(node, src, lang)
    local ok, parser = pcall(vim.treesitter.get_string_parser, src, lang)
    if not ok then return nil end
    local root = parser:parse()[1]:root()
    local d = root:named_descendant_for_range(at.sl(node.range), at.sc(node.range),
        at.el(node.range), at.ec(node.range))
    while d do if FN_TYPES[d:type()] then return d end; d = d:parent() end
    return nil
end

--- The tree ROOT for a whole file — a module's statement sequence, where fn_node
--- would look for an enclosing function and find none.
local function root_node(src, lang)
    local ok, parser = pcall(vim.treesitter.get_string_parser, src, lang)
    if not ok then return nil end
    local tree = parser:parse()[1]
    return tree and tree:root() or nil
end

--- the focused fn's flow record WITH per-row `.expr` harvested (aligned 1:1). INC 1
--- rebuilds on demand (re-parse, like narrow) — not folded, no VERSION bump.
--- @return table? { fl={stmts,params}, lang, node } or nil
function M.of(store, fn_id)
    local node = store.node and store.node(fn_id)
    if not node or not node.file then return nil end
    local lang = EXT[node.file:match('%.(%w+)$') or '']
    if not lang or not spec[lang] then return nil end
    local s = spec[lang]
    local src = table.concat(store.content(node) or {}, '\n')
    local fn = fn_node(node, src, lang)
    if not fn then return nil end
    local cfg = { pfield = s.params_field, df_ids = s.df_ids, regime = s.regime,
        method = (node.kind == 'method') and lang == 'lua',
        expr = function (n, ns, hint) return M.harvest_row(n, ns, hint) end }
    local flow = require 'cartograph.flow'
    local fl = flow.build(fn, src, cfg)
    return { fl = fl, lang = lang, node = node,
        bound = M.bound_names(fn, src, s.binders) }
end

--- A MODULE's TOP-LEVEL statement sequence, harvested with the same machinery.
--- Same shape as M.of, so a consumer reads `.fl.stmts[i].expr` identically.
---
--- WHY THIS EXISTS. `M.of` is function-scoped: it locates the enclosing function
--- node and walks its body, so it returns nil for a module. That is the whole
--- reason config-as-code is invisible to the expression layer — MEASURED on a
--- Factorio 1.1 mod, `harvest_row` parses 344/344 of its field-shaping
--- assignments perfectly while the graph represents 0, and **249 of those sites
--- (72%) are module top level**: every prototype, every `data:extend` argument,
--- every `deepcopy(base)` + field-override sequence. Not a parser gap and not
--- Factorio-specific — a Rails initializer and a webpack config are the same
--- shape ([[cartograph-bench]] item 0).
---
--- A SEPARATE ENTRY, not a widening of M.of, deliberately: exprlint / optimize /
--- untangle / hoistclosure take the FOCUSED node, so teaching M.of about modules
--- would silently start analyzing module top-level code in four analyzers at
--- once — a lint-output change nobody measured. Module-level analysis is opt-in;
--- each consumer migrates with its own gate check.
---
--- Nested function bodies stay OPAQUE: a top-level `function f() … end` is one
--- row of the sequence (emit does not recurse into a non-control node), which is
--- what a module's own statement list means. Their insides are M.of's job.
--- @return table? { fl={stmts,params={}}, lang, node, bound } or nil
function M.of_module(store, mod_id)
    local node = store.node and store.node(mod_id)
    if not (node and node.file and node.kind == 'module') then return nil end
    -- the SAME supported-language set as M.of (EXT is built from the langs that
    -- declare a body_field flow), so this never claims a language M.of refuses
    local lang = EXT[node.file:match('%.(%w+)$') or '']
    if not lang or not spec[lang] then return nil end
    local s = spec[lang]
    -- a MISSING file must refuse, not report an empty module. store.content
    -- returns nil when the file is gone and a (possibly empty) table when it is
    -- readable, so the distinction lives here and nowhere else: `or {}` would
    -- concat to '', parse to a childless root, and hand back a record with zero
    -- rows — an unreadable file rendered as "this module has no statements",
    -- which is the absence-as-silence class this codebase keeps paying for.
    local lines = store.content(node)
    if not lines then return nil end
    local src = table.concat(lines, '\n')
    local root = root_node(src, lang)
    if not root then return nil end
    local cfg = { seq = true, df_ids = s.df_ids, regime = s.regime,
        expr = function (n, ns, hint) return M.harvest_row(n, ns, hint) end }
    local flow = require 'cartograph.flow'
    return { fl = flow.build(root, src, cfg), lang = lang, node = node,
        bound = M.bound_names(root, src, s.binders) }
end

-- NAME-ish leaves, across the languages that declare binders
local BINDNAME = { identifier = true, name = true, variable_name = true }

--- Names BOUND by a declared binder node inside `fn` — loop variables, chiefly.
--- Read from the TREESITTER tree, not the expression IR: the IR keeps node TYPES on
--- opaque nodes but discards FIELD names, and JS's `for (const g of t)` has binding
--- and iterated as two indistinguishable identifier children. So the tree is the only
--- place the answer exists.
---
--- THE RULE, one shape for three grammars: a binder's own direct name children are
--- bindings, plus every name inside a declared `child` container. The `body` field is
--- never descended.
--- Lua `for_generic_clause` puts them in a `variable_list`; `for_numeric_clause` has
--- the name directly. JS `for_in_statement` has it directly. PHP `foreach_statement`
--- binds through a `pair`, or directly.
---
--- IMPRECISION, deliberate and in the safe direction: where the ITERATED expression
--- is itself a bare name (`for (const g of items)`), it is collected as a binding
--- too. That can only make a genuinely external name look LOCAL, which
--- under-reports rather than over-claims. A chain or call on the right — the common
--- case, and the one that matters (`pairs(global.saved)`) — is untouched.
function M.bound_names(fn, src, binders)
    local out = {}
    if not (fn and binders and #binders > 0) then return out end
    local by_node = {}
    for _, b in ipairs(binders) do by_node[b.node] = b end
    local function collect_names(n)
        if BINDNAME[n:type()] then out[txt(n, src)] = true end
        for c in n:iter_children() do
            if c:named() then collect_names(c) end
        end
    end
    local function walk(n)
        local b = by_node[n:type()]
        if b then
            for c, field in n:iter_children() do
                if c:named() and field ~= 'body' then
                    if BINDNAME[c:type()] then out[txt(c, src)] = true
                    elseif b.child and c:type() == b.child then collect_names(c) end
                end
            end
        end
        for c in n:iter_children() do
            if c:named() then walk(c) end
        end
    end
    walk(fn)
    return out
end

-- a row whose OWN node is a function declaration: `du` counts the whole closure
-- body as uses (its FN-stop only fires on a CHILD fn node, never the root), while
-- the expr layer honestly models the row as a `fn` ALLOCATION. This is a documented
-- du over-reach — the ONE row class where reads ≠ use∪rmw by design (anonymous-fn
-- ASSIGNMENTS, where the fn is a child, du stops and both agree). The gate skips it.
local FNDECL = { function_declaration = true, function_definition = true,
    method_declaration = true, method_definition = true, function_item = true,
    local_function = true, arrow_function = true, lambda_expression = true }

--- the SELF-GATE: for each row, `expr.reads(row)` must equal `use ∪ rmw`. Returns a
--- list of disagreements (empty = clean). Used by syngate + tests + dogfooding.
--- @return table[] { row, line, reads, du, missing, extra }
function M.gate(fl)
    local bad = {}
    for i, s in ipairs(fl.stmts or {}) do
        if s.expr and not FNDECL[s.t or ''] then
            local reads = {}
            for _, n in ipairs(M.reads(s.expr)) do reads[n] = true end
            local du = {}
            for _, n in ipairs(s.use or {}) do du[n] = true end
            for _, n in ipairs(s.rmw or {}) do du[n] = true end
            local missing, extra = {}, {} -- du has it, expr doesn't / expr has it, du doesn't
            for n in pairs(du) do if not reads[n] then missing[#missing + 1] = n end end
            for n in pairs(reads) do if not du[n] then extra[#extra + 1] = n end end
            if #missing > 0 or #extra > 0 then
                table.sort(missing); table.sort(extra)
                bad[#bad + 1] = { row = i, line = s.l, missing = missing, extra = extra }
            end
        end
    end
    return bad
end

return M
