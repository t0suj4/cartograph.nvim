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
--   { k='field', b=<expr>, n='sel', method=<bool>, selid=<bool> }  -- a.b / a:b
--       `selid` = does du count this SELECTOR as an identifier leaf in this language?
--       A property of the GRAMMAR, not of the code: lua/java/python/ruby/php/odin/zig
--       spell the `k` in `a.k` with a type in their `ids` set, while c/cpp/go/rust/js/
--       ts spell it `field_identifier`/`property_identifier`, which du never counts.
--       Recorded at BUILD time because that is the only point where the selector's
--       node TYPE is in hand — by `reads` there is only a string (CART-0402).
--   { k='index', b=<expr>, i=<expr> }                 -- a[b]
--   { k='call',  f=<expr>, a={<expr>...}, method=<bool> }
--   { k='un',    op='-'|'not'|'#'|..., e=<expr> }
--   { k='bin',   op='+'|'..'|'and'|'or'|'=='|..., l=<expr>, r=<expr> }
--   { k='table' }                                     -- ALLOCATION (fresh identity)
--   { k='pair',  key=<expr>, val=<expr>? }            -- a constructor's k=v entry;
--       `key` is a str lit when the property name is KNOWN, an expression when the
--       key is computed. `kids` carries both halves so kids-walkers still see them.
--   { k='assign', t=<target>, v=<value>, kids={t,v} } -- an assignment used as a VALUE
--       (`a = b = c`, a for-init comma list). The TARGET is a def, not a read — which is
--       the whole reason this is a kind and not a `?` (CART-0415). Augmented forms
--       (`a += b`) stay on the `?` path: they DO read their target.
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

-- @langs bash c cpp go haskell java javascript lua odin php python ruby rust scheme tsx typescript zig
-- The IR is LANGUAGE-AGNOSTIC by design (a closed schema, `?` for anything unmodelled),
-- so the harvest runs on every extracted language and its node-type knowledge belongs in
-- per-language tables. Declared so the language fence checks that claim.

local at = require 'cartograph.at'
local tsutil = require 'cartograph.spec.tsutil'

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
-- remain opaque. That is the reason it was reverted: no analyzer got more capable.
--
-- IT ALSO DOUBLED greenspun's registry-audit findings 6 -> 12, and THAT HALF WAS
-- MISREAD as a second reason. registry-audit is `disposition = 'suggestive'`
-- (lint.lua) — a proposal, not a verdict — so finding more when a language's
-- expressions first become visible is EXPECTED, and java is full of genuine handler
-- maps and listener registries. Whoever measured it judged the 12 "all spurious"
-- (`assertRectangleResult`, `setBucket`, `getRank` reported as registries); that may
-- well be right, but it is a NOISE observation to be resolved by a user-supplied
-- template ([[greenspun-is-suggestive]]), not evidence of unsoundness. Do NOT cite it
-- as a canary for a grammar change.
--
-- THE ACTUAL CANARY for this work is the purity/allocation semantics below, because
-- those feed rewrites that get APPLIED.
--
-- SO JAVA COVERAGE IS A PROJECT, not a one-word change, and it carries SEMANTIC
-- risk rather than merely structural: method_invocation decides is_pure,
-- object_creation_expression decides allocates, and optimize can APPLY rewrites. A
-- wrong entry there proposes an UNSOUND edit rather than a missing one. Whoever
-- takes it should add the entries together, with the purity/allocation semantics
-- checked, and re-measure registry-audit as the canary.
-- FIELD / INDEX node names, per language, VERIFIED BY PARSING (CART-0224). The IR
-- was effectively a LUA IR with partial JS: measured `?` share was 5.4% on our own
-- tree but ~40% on php and ~38% on python, and php had ZERO `field` nodes while
-- python had zero `field` AND zero `index` — their node names simply were not here.
-- Each addition below was confirmed by parsing a snippet and reading the grammar's own
-- child list, not from memory:
--   php    member_access_expression  "$a->b"    operands: variable_name , name
--   python attribute                 "a.b"      operands: identifier , identifier
--   python subscript                 "a[1]"     operands: identifier , integer
--   go     selector_expression       "a.b"      operands: identifier , field_identifier
-- All four are base-first / selector-second with exactly two named children, which is
-- what the FIELD and INDEX branches below assume, and all four NEST correctly (`a.b.c`
-- has the inner `a.b` node as its base) so a chain still forms for expr.dotted.
-- php's base is `variable_name`, which line ~210 already unwraps.
--
-- DELIBERATELY NOT ADDED: php's `member_call_expression` ($a->b(1)). That is a CALL
-- form, and CALL decides is_pure / allocates and feeds rewrites optimize can APPLY, so
-- it needs the callee-position and method-flag semantics checked together — the same
-- care the java note below demands, and the same reason `field_access` alone was
-- reverted there. A read-position addition cannot propose an unsound edit; a call-form
-- one can.
local FIELD = { dot_index_expression = true, field_expression = true,
    member_expression = true,
    member_access_expression = true,  -- php   $a->b
    attribute = true,                 -- python a.b — AND lua 5.4 `<const>`, see COLLIDE
    selector_expression = true }      -- go    a.b

-- ── WHERE A NODE NAME MEANS TWO THINGS (CART-0234) ────────────────────────────────
-- These maps are keyed on the tree-sitter node TYPE and shared by every language, which
-- is only safe while no two grammars reuse a name for a different construct. MEASURED
-- FALSE: `attribute` is python's `a.b` AND lua 5.4's variable attribute (`local x
-- <const>`). A shared map keyed on a bare node type is a collision waiting for the next
-- grammar (TSGAP-0004), so a collision gets named here rather than being resolved by
-- luck.
--
-- A VETO, not a per-language rebuild of every map: the global tables stay the fast path
-- and only a MEASURED collision carries an entry. `lang` is nil on the `expr.build`
-- entry point (the transliterator, tests), and a nil lang vetoes nothing — the shape
-- check above is what protects that path, which is why containment had to be part of
-- this fix rather than an alternative to it.
-- The set lives in the SPEC (`spec.binding_modifiers`), which is the per-language home and
-- is also what flow.lua's du reads — one declared fact, two consumers, so the two sides of
-- the expr self-gate cannot drift apart again the way they did here.
-- LAZY on purpose: `spec` is required further down this file (module load order), so a
-- direct reference here would read a nil GLOBAL and silently disable both consumers — the
-- absence-as-falseness failure this very ticket is about.
local specs
local function modset(lang)
    if not lang then return nil end
    specs = specs or require('cartograph.providers.treesitter').spec
    local s = specs and specs[lang]
    return s and s.binding_modifiers or nil
end
local function VETO(lang, t)
    local m = modset(lang)
    return m ~= nil and m[t] == true
end
-- DESTRUCTURING/IMPORT BINDERS (CART-0358) — the same declared fact du reads, reached the
-- same LAZY way and for the same reason as `modset` above: `spec` is required further down
-- this file, so a direct reference here compiles to a nil GLOBAL and silently disables the
-- consumer. Returns (binder_fields, leaf-ids) so a caller gets both halves of the rule or
-- neither.
local function binderset(lang)
    if not lang then return nil end
    specs = specs or require('cartograph.providers.treesitter').spec
    local s = specs and specs[lang]
    if not (s and s.binder_fields) then return nil end
    return s.binder_fields, require('cartograph.flow').leaf_ids(s.df_ids), s.binder_paren
end

-- A declaration modifier standing in an assignment TARGET list. It binds nothing, reads
-- nothing, and the def side already reports the name it modifies — so it is not an
-- expression and must not enter the row at all.
--
-- THE VETO ALONE WOULD NOT HAVE BEEN ENOUGH: it routes `attribute` to `?`, and `?`
-- deliberately keeps its children so a name can never be hidden — so the identifier
-- `const` would still be a kid and expr.reads would still report a read of it. MEASURED on
-- desynced: 7 phantom fields and 7 fabricated `const` reads before, 0 and 0 after, with
-- the `?` census unchanged at 4582 (the modifier leaves the row entirely rather than
-- becoming an honest-unknown). The ticket's "23 fabricated reads" counted 16 legitimate
-- reads of a real field named `close` alongside them — there was only ever ONE leak path,
-- not two.
local function is_modifier(lang, node)
    local m = modset(lang)
    return m ~= nil and m[node:type()] == true
end
local INDEX = { bracket_index_expression = true, subscript_expression = true,
    index_expression = true,
    subscript = true }                -- python a[1] (a[1:2] keeps `?` for the slice)
local METHOD = { method_index_expression = true }
local CALL = { function_call = true, call_expression = true, call = true,
    function_call_expression = true }
-- BINARY operator nodes. `comparison_operator`/`boolean_operator` are PYTHON's
-- spellings, and their absence is why every purity-gated analyzer was dead there:
-- `x > 1` fell to the honest-unknown `?` path, and `is_pure` correctly refuses an
-- unknown, so narrow / exprlint / optimize all declined python conditions without
-- ever saying they could not read them (CART-0314).
-- ★ `comparison_operator` IS N-ARY. Python chains: `1 < x < 9` has THREE operands,
-- and the 2-operand model below would silently drop the third — a vanished read,
-- which is the one thing the closed schema exists to prevent. The build guard sends
-- any arity but 2 to `?`, whose `kids` keep every sub-expression, so a chain stays
-- honest rather than becoming wrong. (`not x` is `not_operator`, a separate UN
-- entry that is deliberately still unmodelled — it reads as `?`.)
local BIN = { binary_expression = true, binary_operation = true,
    comparison_operator = true, boolean_operator = true }
local UN = { unary_expression = true, unary_operation = true }
-- CONSTRUCTOR / AGGREGATE-LITERAL nodes = the ALLOCATION marker (CART-0357). VERIFIED
-- per language by parsing a snippet and asking which node is the PARENT of a PAIR-set
-- node — the same discipline, and the same question, as the PAIR table below.
--   lua           table_constructor          javascript/typescript/tsx  object, array
--   python        dictionary, list, set      ruby                       hash, array
--   php           array_creation_expression  rust    field_initializer_list, array_expression
--   haskell       record   (the record UPDATE `r { a = 2 }` — an expression)
--
-- ★ THE FAILURE IS ASYMMETRIC HERE, WHICH IS WHY THIS SET MAY BE GENEROUS AND THE PAIR
-- SET BELOW MUST NOT BE. A MISSING entry makes allocates() answer FALSE for a fresh
-- object — and false is a positive claim, not an honest unknown — so optimize's
-- `not allocates(r)` guard opens and LICM certifies hoisting an allocation out of a
-- loop, which is semantics-changing. That is exactly what shipped for every non-Lua
-- language until this list existed. An EXTRA entry only makes allocates() over-report,
-- which refuses a legal rewrite: lossy, never wrong. So an immutable python `tuple` or
-- a stack-allocated rust `[1,2]` belongs here even though hoisting it would have been
-- safe — the cost of including them is a declined optimisation, and the cost of
-- omitting them is a broken program.
--
-- ★ DELIBERATELY ABSENT, each verified and each for a reason:
--   haskell `fields` / odin `struct_declaration` — these hold PAIR-set nodes but they are
--     TYPE DECLARATIONS (`data R = R { a :: Int }`), not values. Nothing is allocated by
--     writing one, and calling a declaration an allocation is a lie in the other direction.
--   go `literal_value > keyed_element` and cpp `initializer_list > initializer_pair` —
--     these DO reproduce now (the PAIR note below says they did not), but their pair nodes
--     are not in PAIR, so adding the container alone buys nothing. Add both together, with
--     a parse check, and decide the identity question first: a go struct literal and a C++
--     aggregate init are VALUES, whereas a go map/slice literal is a fresh object.
--   zig / java — no pair node reproduces (zig has struct_initializer / initializer_list,
--     java array_initializer). Consistent with the PAIR note. Unverified stays out.
local TABLE = { table_constructor = true, table = true,
    object = true, array = true,                      -- javascript / typescript / tsx
    dictionary = true, list = true, set = true, tuple = true,  -- python
    hash = true,                                      -- ruby (array shared with js)
    array_creation_expression = true,                 -- php
    field_initializer_list = true, array_expression = true,    -- rust
    record = true }                                   -- haskell record UPDATE
local ALLOCFN = { function_definition = true, function_declaration = true,
    anonymous_function = true, arrow_function = true, lambda_expression = true }
-- ★ THE ONE OWNER OF "WHAT IS A REGION / CLAUSE / ATTACHED BLOCK IN THIS LANGUAGE" is
-- flow.classes, and this module used to keep its own base-only copy (see the BODY/CLAUSE
-- tables further down, and the ★ note beside them for what that cost on ruby). Memoised per
-- language because build_core consults it per node. Lazy requires: expr is loaded from both
-- flow's callers and treesitter, so a module-level require here would close a cycle.
local CLS_OF = setmetatable({}, { __index = function (t, lang)
    local c = require('cartograph.flow').classes(
        require('cartograph.providers.treesitter').spec[lang] or {})
    rawset(t, lang, c)
    return c
end })
-- ★ THE NESTED-FUNCTION STOP, THE SAME ONE du USES, for the same reason (CART-0395).
-- ALLOCFN below is a five-name base list, so a nested body spelled anything else was walked
-- straight into by the `?` honest-unknown path — and its names counted as reads of the
-- enclosing row. MEASURED on elasticsearch/libs: a `return new Runnable() { @Override public
-- void run() {…} }` made its `return` row read `Override, closeInternal, onClose, run,
-- toString`, none of which du sees, because du stops at `method_declaration`. That is the
-- bulk of a 1076-instance class. Reading the stop from `ts.flow_stop(lang)` makes the two
-- sides agree BY CONSTRUCTION rather than by two lists happening to match — which is exactly
-- the drift CART-0308 found between flow's FN set and this module's copy of it.
local FNSTOP_OF = setmetatable({}, { __index = function (t, lang)
    local s = require('cartograph.providers.treesitter').flow_stop(lang)
    rawset(t, lang, s)
    return s
end })
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
local ASSIGN = { assignment_statement = true, assignment = true,
    assignment_expression = true, augmented_assignment_expression = true,
    variable_assignment = true }
-- ASSIGN minus the augmented forms — the ones whose target is written and NOT read.
-- Ruby's `operator_assignment` is in neither table: ruby `x += 1` is unmodelled
-- today, and widening that here would be a separate change with its own measurement
-- (CART-0316).
local PLAIN_ASSIGN = { assignment_statement = true, assignment = true,
    assignment_expression = true, variable_assignment = true }

-- ★ DOES du COUNT THIS SELECTOR? (CART-0402) The `k` in `a.k` is a leaf du reads only
-- when the grammar spells it with a type in that language's `ids` set — `identifier` in
-- lua/java/python/ruby/odin/zig and `name` in php, but `field_identifier` in c/cpp/go/
-- rust and `property_identifier` in js/ts, neither of which du has ever counted. The IR
-- counted it UNCONDITIONALLY, which is a LUA-SHAPED ASSUMPTION INSIDE A LANGUAGE-AGNOSTIC
-- IR — the closed schema's own defect one level down: the schema is language-agnostic and
-- the reads function was not.
--
-- The set comes from flow.leaf_ids, never a local copy: du is the other implementation in
-- this two-implementation oracle, and an oracle whose two sides read different copies of
-- the same rule tests the copies.
-- LAZY, for the reason `modset` above already gives: `spec` is required further down
-- this file, so touching it here would read a nil GLOBAL and quietly answer false for
-- every language — which in THIS function means "no selector is ever an identifier",
-- i.e. the absence-as-falseness failure the ticket is about, reintroduced by the fix.
-- ★ AND AN UNKNOWN LANGUAGE FALLS BACK TO du's DEFAULT SET, NOT TO `false`. Returning
-- false for a nil lang would mean "no selector is ever an identifier" — the same
-- absence-as-falseness the paragraph above warns about, committed by the fix for it.
-- (It cost one red spec: a harness that builds a lua flow without threading lang, where
-- `t.k = b` correctly reads `k`.) `leaf_ids(nil)` is DFID — identifier/name — which is
-- exactly what du falls back to for a spec with no df_ids, so the two sides still agree.
local IDS_OF = {}
local function sel_is_id(seln, lang)
    if not seln then return false end
    local key = lang or '\0default'
    local ids = IDS_OF[key]
    if not ids then
        if lang then specs = specs or require('cartograph.providers.treesitter').spec end
        ids = require('cartograph.flow').leaf_ids(lang and (specs[lang] or {}).df_ids or nil)
        IDS_OF[key] = ids
    end
    return ids[seln:type()] == true
end

-- `named_child(N)` onto the comment and drop the real operand ([[self-gate found
-- this]]). Filtering comments makes operand extraction position-stable.
local function operands(node)
    local out = {}
    for c in node:iter_children() do
        if c:named() and not tsutil.is_comment(c) then out[#out + 1] = c end
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
        if c:named() and not tsutil.is_comment(c) then
            if i == 0 then callee = c
            -- @langs-ok the WRAPPER is what varies: haskell/scheme/bash have no
            -- argument-list node at all (juxtaposition / list / word call models) and
            -- odin exposes each argument directly, and all of those land in the `else`
            -- below, which takes an unwrapped child AS an argument. Verified: odin call
            -- args do reach the IR.  @langs-ok the wrapper varies; the else-branch covers it
            elseif c:type() == 'arguments' or c:type() == 'argument_list' then
                for a in c:iter_children() do
                    if a:named() and not tsutil.is_comment(a) then args[#args + 1] = a end
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
function build_core(node, src, lang)
    if not node then return { k = '?', t = '<nil>', kids = {} } end
    local t = node:type()
    if PAREN[t] then return build(node:named_child(0), src) end
    if UNWRAP[t] then -- a list where one expr is expected: build the sole child, else `?`
        local only, n = nil, 0
        for c in node:iter_children() do if c:named() and not tsutil.is_comment(c) then only = c; n = n + 1 end end
        if n == 1 then return build(only, src, lang) end
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
    -- ★ A SHORTHAND PROPERTY IN AN OBJECT LITERAL IS A REFERENCE (CART-0418). `{a}` is
    -- `{a: a}`, so it READS `a`. Its pattern-position sibling is one letter longer
    -- (`shorthand_property_identifier_pattern`) and BINDS instead — handled by
    -- `binder_fields`, and the two must not be confused. Base-set rather than per-language
    -- because the node name is javascript's alone across the 17 loaded grammars, and
    -- because BOTH sides move together here: js `df_ids` gains the same name, so the
    -- self-gate stays a test of the rule and not of one copy of it.
    if NAME[t] or t == 'shorthand_property_identifier' then
        return { k = 'name', n = txt(node, src) }
    end
    if t == 'variable_name' then -- php $x: the inner name is the variable
        local inner = node:named_child(0)
        return { k = 'name', n = (txt(inner or node, src):gsub('^%$', '')) }
    end
    -- CONTAINMENT (CART-0234). Every one of these arms is documented above as
    -- base-first / selector-second with TWO named children. Reading `o[2]` without
    -- checking it exists is how a one-operand node from some other grammar became a
    -- confident field access with an EMPTY name: lua 5.4's `local x <const>` parses as
    -- `attribute` — which is python's name for `a.b` — with the single child `const`,
    -- so `txt(nil)` returned '' and the IR claimed a read of a variable called `const`.
    -- The `?` arm exists for exactly this, and the shape check is what routes there.
    -- INCOMPLETE MAPS UNDER-REPORT; COLLIDING MAPS FABRICATE.
    if FIELD[t] and not VETO(lang, t) then
        local o = operands(node)
        if o[1] and o[2] then
            return { k = 'field', b = build(o[1], src, lang), n = txt(o[2], src),
                method = false, selid = sel_is_id(o[2], lang) }
        end
    end
    if METHOD[t] and not VETO(lang, t) then
        local o = operands(node)
        if o[1] and o[2] then
            return { k = 'field', b = build(o[1], src, lang), n = txt(o[2], src),
                method = true, selid = sel_is_id(o[2], lang) }
        end
    end
    if INDEX[t] and not VETO(lang, t) then
        local o = operands(node)
        if o[1] and o[2] then
            return { k = 'index', b = build(o[1], src, lang), i = build(o[2], src, lang) }
        end
    end
    if CALL[t] then
        local callee, argnodes = call_parts(node)
        local a = {}
        for _, an in ipairs(argnodes) do a[#a + 1] = build(an, src, lang) end
        local f = build(callee, src, lang)
        return { k = 'call', f = f, a = a, method = (f.k == 'field' and f.method) or false }
    end
    if BIN[t] and #operands(node) == 2 then
        local o = operands(node)
        return { k = 'bin', op = op_token(node, src), l = build(o[1], src, lang), r = build(o[2], src, lang) }
    end
    if UN[t] then
        local o = operands(node)
        return { k = 'un', op = op_token(node, src), e = build(o[1], src, lang) }
    end
    if TABLE[t] then
        -- an ALLOCATION (fresh identity) but its field VALUES/keys READ names — carry
        -- them as kids so the read-set stays faithful to du (which descends the table).
        local kids = {}
        for c in node:iter_children() do
            if c:named() and not tsutil.is_comment(c) then kids[#kids + 1] = build(c, src, lang) end
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
        if not kn then return vn and build(vn, src, lang) or { k = '?', t = t, kids = {} } end
        local bracketed = false
        for c in node:iter_children() do
            if not c:named() and vim.trim(txt(c, src)) == '[' then bracketed = true; break end
        end
        local key
        if not bracketed and kn:type():match('identifier') then
            key = { k = 'lit', ty = 'str', v = txt(kn, src) }
        else
            key = build(kn, src, lang)
        end
        local val = vn and build(vn, src, lang) or nil
        return { k = 'pair', key = key, val = val,
            kids = val and { key, val } or { key } }
    end
    -- ★ AN ATTACHED BLOCK IS A CLOSURE LITERAL AND THE IR ALREADY HAS THE RIGHT SHAPE FOR
    -- ONE. `xs.each do |x| … end` is syntactically an anonymous function passed to `each`,
    -- and `{k='fn'}` is exactly "an allocation whose body is not this row's business" —
    -- which is also what du now says, since the block's names live on the block's OWN rows.
    -- Without this the call row's expr read the whole block while its `use` did not, and the
    -- self-gate is the thing that would have caught it (had it ever been run on ruby).
    if ALLOCFN[t] or (lang and (FNSTOP_OF[lang][t]
        or (CLS_OF[lang].blocks and CLS_OF[lang].blocks[t]))) then
        return { k = 'fn' } -- NEVER descend a closure body (du doesn't either)
    end
    -- ★ AN ASSIGNMENT IN AN EXPRESSION POSITION (CART-0415). C spells `a = b = c` as
    -- `a = (b = c)` and a for-init comma list as a chain of assignment_expressions, so the
    -- inner assignment reaches build() as a value. It used to land on the `?` path below —
    -- which is HONEST (it keeps both names) and still wrong for `reads`, because a `?`'s
    -- kids are walked uniformly and one of them is in DEF POSITION. `?` is for constructs
    -- the harvest does not model; an assignment is very much modellable.
    -- PLAIN_ASSIGN, not ASSIGN: an augmented form (`a += b`) genuinely READS its target, so
    -- it keeps falling through to `?`, where both kids are read — which is correct there.
    -- `kids` is carried for the same reason `pair` carries it: kids-walkers keep seeing
    -- both halves, so a consumer that has never heard of this kind loses nothing.
    if PLAIN_ASSIGN[t] then
        local o = operands(node)
        local tgt = node:field('left')[1] or o[1]
        local val = node:field('right')[1] or o[2]
        if tgt and val then
            local T, V = build(tgt, src, lang), build(val, src, lang)
            return { k = 'assign', t = T, v = V, kids = { T, V } }
        end
    end
    if VARARG[t] then return { k = 'vararg' } end
    -- honest unknown: keep the named children as kids so no name is hidden
    local kids = {}
    for c in node:iter_children() do
        if c:named() and not tsutil.is_comment(c) then kids[#kids + 1] = build(c, src, lang) end
    end
    return { k = '?', t = t, kids = kids }
end

-- stamp the source range on every node built (see build_core's note). A node built
-- from no TS node (build(nil)) has no range → `.at` stays nil.
function build(node, src, lang)
    local e = build_core(node, src, lang)
    if node and type(e) == 'table' then
        local sr, sc, er, ec = node:range()
        e.at = { start = { line = sr, char = sc }, ['end'] = { line = er, char = ec } }
    end
    return e
end

-- A BINDER IS A NAME even when its node type is outside the base NAME set — js spells the
-- binder of `const {SHIFT} = …` (the commonest destructuring form) as a
-- `shorthand_property_identifier_pattern`, which `build` models as an opaque `?`. Leaving
-- it opaque hands every consumer an unknown TARGET for a name we can plainly read.
--
-- ★ AND THIS DELIBERATELY DOES NOT LIVE INSIDE `build` (CART-0358). Widening the GLOBAL
-- leaf rule to each language's `df_ids` fixed the targets and simultaneously made those
-- leaves readable INSIDE opaque `?` subtrees — a nested callback that the IR descends and
-- du stops at — converting a PRE-EXISTING IR over-reach into 30+ fresh gate findings on
-- ghost. The widening is only sound where a node is KNOWN to be a binder, which is here.
-- A capability that widens WHICH leaves you can name is a test of every stage downstream.
local function build_binder(node, src, lang)
    local e = build(node, src, lang)
    if type(e) == 'table' and e.k ~= 'name' then
        return { k = 'name', n = txt(node, src), at = e.at }
    end
    return e
end
M.build = build

-- ── per-row harvest ──────────────────────────────────────────────────────────
-- assignment left/right targets (fields for php/js, node types for lua)
local ASSIGN_OP = { ['='] = true, [':='] = true, ['+='] = true, ['-='] = true,
    ['*='] = true, ['/='] = true, ['%='] = true, ['||='] = true, ['&&='] = true,
    ['|='] = true, ['&='] = true, ['^='] = true, ['<<='] = true, ['>>='] = true,
    ['**='] = true, ['//='] = true, ['??='] = true, ['.='] = true }
local function assign_sides(node, src)
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
    -- ★ POSITIONAL FALLBACK. Odin's `assignment_statement` carries NO fields and no
    -- *_list wrappers — its children are just `identifier`, the operator TOKEN, and
    -- the value — so both branches above came back empty and every odin assignment
    -- harvested to an EMPTY expression row. The IR's whole promise is that an
    -- unmodelled construct becomes `?` rather than a lie, and this was neither: it
    -- was silence. Split on the operator token, which is the one thing every
    -- assignment grammar has in common. (CART-0304, found by declaring expr's @langs.)
    if not (left and right) and src then
        local before, after, seen = {}, {}, false
        for c in node:iter_children() do
            if not c:named() then
                if ASSIGN_OP[vim.treesitter.get_node_text(c, src)] then seen = true end
            elseif not tsutil.is_comment(c) then
                if seen then after[#after + 1] = c else before[#before + 1] = c end
            end
        end
        -- N targets and M values, because odin's multi-return idiom (`v, ok := m[k]`)
        -- is a QUARTER of its assignments — a 1:1-only fallback would have left the
        -- most characteristic shape in the language unharvested. The separator commas
        -- are anonymous tokens, so the named children ARE the operands.
        if seen and #before > 0 and #after > 0 then return nil, nil, before, after end
    end
    return left, right
end
local function list_children(node) -- the named exprs of a *_list (or the node itself)
    if not node then return {} end
    if UNWRAP[node:type()] then
        local out = {}
        for c in node:iter_children() do
            if c:named() and not tsutil.is_comment(c) then out[#out + 1] = c end
        end
        return out
    end
    return { node }
end

-- statement wrappers: grammars that make an assignment an EXPRESSION need a
-- statement node around it (js, python, c, java, go).
local STMT_WRAP = { expression_statement = true }
local LOCALDECL = { variable_declaration = true, local_declaration = true,
    local_variable_declaration = true,
    -- js/ts `let`/`const`. Its absence had the same effect as the missing
    -- expression_statement unwrap one line up: `let y = x` harvested whole, so the
    -- declared NAME counted as a read (gate extra=[y]) (CART-0314).
    lexical_declaration = true }
-- the name=value pair inside a declaration, where the grammar uses one rather than
-- nesting a whole assignment node (js/ts `let y = x`, java `int y = x`). The bare
-- path below cannot serve these: it collects every NAME child as a target, which
-- for a declarator would put the VALUE `x` in the lhs and leave rhs empty.
local DECLARATOR = { variable_declarator = true, init_declarator = true }
-- C/C++ wrap the declared name in a pointer/array declarator (`Foo *p`, `int a[4]`) — the
-- same set du walks through with DECLWRAP, so the two find the same name.
local DECLWRAP = { pointer_declarator = true, array_declarator = true }
-- ★ THE LOCAL-DECLARATION SET, PER LANGUAGE (CART-0404). C spells it `declaration`, and
-- `declaration` is a node type in NINE of the seventeen grammars — several of them as a
-- SUPERTYPE, a distinction a name-keyed base set cannot make. So it lives in the spec
-- (`spec.localdecl`) and merges here, memoised, exactly like CLS_OF above. Same lesson as
-- `pattern` in six grammars and `block` in eight.
local LOCALDECL_OF = setmetatable({}, { __index = function (t, lang)
    local base = require('cartograph.providers.treesitter').spec[lang]
    local out = {}
    for k in pairs(LOCALDECL) do out[k] = true end
    for k in pairs((base or {}).localdecl or {}) do out[k] = true end
    rawset(t, lang, out)
    return out
end })
local RET = { return_statement = true }
-- sub-region boundaries harvest must NOT descend from a control HEAD (mirrors du's
-- stop_body: the head owns its condition/clause, not the body or sibling clauses).
local BODY = { block = true, compound_statement = true, statement_block = true }
local CLAUSE = { else_statement = true, elseif_statement = true, elseif_clause = true,
    else_clause = true, else_if_clause = true, elif_clause = true,
    case_statement = true, default_statement = true, expression_case = true,
    default_case = true, catch_clause = true, except_clause = true, finally_clause = true }
-- ★ …AND THOSE TWO ARE THE SIXTH COPY OF FLOW'S CLASS SETS, ALREADY DRIFTED (part B).
-- They hold the BASE spellings, so ruby's `then` and `do` are not in them, so a ruby control
-- head's expression IR harvested its ENTIRE BODY while the row's own `use` correctly stopped
-- at the boundary. Measured on an 8-line ruby fixture: the `if` head's expr read `r`, a name
-- assigned in its consequence — SIX self-gate disagreements, in a language the self-gate has
-- never been run on (syngate's corpora are lua/java/js). Same seam-feeds-one-function shape
-- as PRELOOP, IF_T, TRY_T, CATCH and du's stop_body before it. So neither table is consulted
-- any more when the language is known: `CLS_OF` (declared above build_core, which needs it)
-- asks flow, the one owner. They remain as the `lang == nil` fallback — the lua-only fixtures.

--- harvest a statement node into a row-expr record. `hint` (set by flow.build at the
--- row-birth point, so flow's emit policy drives the boundary):
---   'cond'     — the node IS a bare condition expression (POST-loop cond re-emit)
---   'ctrlhead' — a control head: condition + clause, NOT the body (du's stop_body)
---   'casehead' — a switch case: only its `value` label
---   (nil)      — a plain statement (assignment / return / bare expression)
--- @return table { lhs={expr...}, rhs={expr...}, cond=expr? }
function M.harvest_row(node, src, hint, lang)
    if hint == 'cond' then return { lhs = {}, rhs = {}, cond = build(node, src, lang) } end
    if hint == 'casehead' then
        -- ★ THE LABEL IS NOT ALWAYS A `value` FIELD, AND NOT ALWAYS ONE NODE (CART-0395).
        -- C/go spell it `value`; java hangs a `switch_label` CHILD; ruby's `when 1, 2` has
        -- TWO `pattern` fields. flow.clause has read all three since CART-0387 — this side
        -- read `value` alone and so MISSED java's label entirely (`missing={FAST}` on the
        -- bestiary: a name du counts and the IR does not). flow.case_labels is now the one
        -- reader, so the two cannot drift apart again.
        local labels = require('cartograph.flow').case_labels(node)
        if #labels == 0 then return { lhs = {}, rhs = {} } end
        if #labels == 1 then
            return { lhs = {}, rhs = {}, cond = build(labels[1], src, lang) }
        end
        -- several labels guard the same arm: they are alternatives, all read
        local rhs = {}
        for _, x in ipairs(labels) do rhs[#rhs + 1] = build(x, src, lang) end
        return { lhs = {}, rhs = rhs }
    end
    if hint == 'ctrlhead' then
        local cond = node:field('condition')[1] or node:field('value')[1]
        local rhs = {}
        -- the language's OWN region spellings, not the base ones (see CLS_OF above)
        local cls = lang and CLS_OF[lang]
        local B, C = (cls and cls.body) or BODY, (cls and cls.clause) or CLAUSE
        local BLK = cls and cls.blocks
        -- ★ A NESTED CONTROL CHILD IS HARVESTED AS A HEAD, NOT AS AN EXPRESSION. Java (and
        -- C, C++, js) spell `else if` as a NESTED `if_statement` in the `alternative` field —
        -- neither a BODY nor a CLAUSE, so it fell through to build(), whose `?` path recurses
        -- every named child and dragged the WHOLE chain's BODIES into the outer head's IR.
        -- du walks the nested statement too but stops at ITS block, so what the two disagreed
        -- about was exactly the chain's bodies — not its conditions.
        -- ★ SO SKIPPING THE CHILD OUTRIGHT IS WRONG, AND MEASURED WRONG: it drops the nested
        -- CONDITION, which du does keep, trading 36 `extra` for 51 `missing` on cpp and 12 on
        -- bash. Recursing as a 'ctrlhead' keeps the condition and drops the body, which is
        -- what du does — the boundary belongs at the same place on both sides.
        -- ★ FOUND BY THE COMBINATORIAL GRID ON ITS FIRST RUN (CART-0405), the way only a grid
        -- can: EVERY `c_ifs_*_ch2` and `_ch3` cell fired and NO `_ch1` cell did, which NAMES
        -- the axis — if x CHAIN-LENGTH — without anyone having to guess it. The per-form
        -- bestiary has an `else if`; it has exactly ONE link, so it never could.
        local CT = (cls and cls.ctrl) or {}
        -- ★ A CONTROL HEAD THAT BINDS DOES NOT READ WHAT IT BINDS. ruby's `|x|`, java's
        -- `for (String x : xs)`, js's for-of `left`, cpp's range-for declarator: all DEFS in
        -- du, all read as names here until this existed. What a binder genuinely READS is a
        -- default expression (`|opt = f(z)|` evaluates `f(z)`), and the split comes from
        -- flow.head_binders so du and this cannot draw it differently.
        -- ★ A TRY HEAD EVALUATES NOTHING, and flow has said so since CART-0386 — it blanks
        -- the row's def/use because a container is not a computation. This side did not
        -- know, and for java/js/python it did not matter: their `try` holds a `block`, which
        -- the BODY skip below already excludes. RUBY'S `begin` HANGS ITS STATEMENTS DIRECTLY,
        -- so the harvest walked the whole body and read every name in it while du read none.
        -- MEASURED by the ruby grid on its first run: expr:begin = 190, every instance an
        -- `inrescue` shell. The two sides agree by MIRRORING flow's rule, not by re-deriving
        -- it — the same reason head_binders and case_labels are exported rather than copied.
        if cls and cls.try and cls.try[node:type()] then return { lhs = {}, rhs = {} } end
        -- ★ A HEAD-ONLY FORM EVALUATES EXACTLY ITS HEAD FIELD (CART-0380). Conditional
        -- compilation hangs its statements DIRECTLY under the directive, so the child loop
        -- below — which skips by TYPE — has nothing to skip and would harvest the whole
        -- branch, exactly as ruby's `begin` did before CART-0386. Mirrored from flow, not
        -- re-derived: `false` means the form has no head at all (`#else`).
        local hf = require('cartograph.flow').head_field(node:type())
        if hf ~= nil then
            local h = hf and node:field(hf)[1] or nil
            return { lhs = {}, rhs = {}, cond = h and build(h, src, lang) or nil }
        end
        local bn, bskip, bvals = require('cartograph.flow').head_binders(node, src, cls)
        local lhs = {}
        if bn then
            for _, n in ipairs(bn) do lhs[#lhs + 1] = { k = 'name', n = n } end
            for _, v in ipairs(bvals or {}) do rhs[#rhs + 1] = build(v, src, lang) end
            -- a BLOCK head has nothing else to evaluate; a loop head still has its collection
            if BLK and BLK[node:type()] then return { lhs = lhs, rhs = rhs } end
        end
        -- ★ AND A BODY IS A ROLE, NOT A TYPE (CART-0414). Every skip below is a TYPE test,
        -- so an UNBRACED body — `if (c) x = 1;` — is a bare `expression_statement` that
        -- none of them name, and the head harvested it: 985 instances on 7kaa, the largest
        -- class in the census once the selector fix stopped masking it. flow.body_children
        -- asks the GRAMMAR for the body FIELD, and this side calls it rather than
        -- re-deriving — the same reason head_binders and case_labels are exported. A
        -- mirrored rule is one rule; two rules that agree today are two rules.
        local bodyc = require('cartograph.flow').body_children(node, CT, C)
        for c in node:iter_children() do
            if c:named() then
                local ct = c:type()
                if not tsutil.COMMENT[ct] and not B[ct] and not C[ct]
                    and not (BLK and BLK[ct]) and not (bskip and bskip[c:id()])
                    and not (bodyc and bodyc[c:id()]) then
                    if CT[ct] then -- a nested head: its condition, never its body
                        local sub = M.harvest_row(c, src, 'ctrlhead', lang)
                        if sub.cond then rhs[#rhs + 1] = sub.cond end
                        for _, e in ipairs(sub.rhs or {}) do rhs[#rhs + 1] = e end
                        for _, e in ipairs(sub.lhs or {}) do lhs[#lhs + 1] = e end
                    else
                        rhs[#rhs + 1] = build(c, src, lang)
                    end
                end
            end
        end
        return { lhs = lhs, rhs = rhs, cond = cond and build(cond, src, lang) or nil }
    end
    local t = node:type()
    -- ★ AN `expression_statement` WRAPPING A PLAIN ASSIGNMENT, unwrapped exactly as
    -- lua's `local x = e` is below. js and python put `y = x` inside one, so the
    -- ASSIGN branch never saw it and the whole statement harvested as a single rhs
    -- value: `lhs` came back EMPTY and the assignment TARGET counted as a read. Not
    -- silence this time but a real disagreement, and expr.gate was already reporting
    -- it (extra=[y]) — on real js and python, where nobody was running it, while the
    -- synthetic js corpus happens to contain no bare `y = x;` to catch it.
    -- PLAIN forms only. An augmented `x += 1` must keep the whole-node reading:
    -- du records x in `rmw`, the IR has no rmw concept on a target, so splitting it
    -- would make reads={x,1} disagree with use∪rmw={x} — trading a fixed gate
    -- finding for a new one (CART-0314).
    if STMT_WRAP[t] then
        -- ★ THE ASSIGNMENT CAN SIT INSIDE PARENTHESES (CART-0358). `({body: b} = await x)`
        -- is the only way to destructure into EXISTING bindings, because a statement may
        -- not begin with `{` — so js wraps it, the unwrap below looked for an assignment
        -- CHILD and found a `parenthesized_expression`, and the whole row fell to the `?`
        -- default where every binder read as a use. du was never affected: its walk
        -- descends every child and meets the pattern regardless of what encloses it.
        -- A STRUCTURAL WALK AND A POSITIONAL READ DO NOT FAIL ON THE SAME INPUTS, which is
        -- the whole reason the two-implementation gate earns its keep.
        local _, _, wrapt = binderset(lang)
        for c in node:iter_children() do
            if wrapt and c:named() and c:type() == wrapt then
                local inner = c:named_child(0)
                if inner and PLAIN_ASSIGN[inner:type()] then
                    return M.harvest_row(inner, src, nil, lang)
                end
            end
        end
        for c in node:iter_children() do
            if c:named() and PLAIN_ASSIGN[c:type()] then
                return M.harvest_row(c, src, nil, lang)
            end
        end
    end
    -- ★ AN IMPORT STATEMENT IS A BINDING STATEMENT (CART-0358). It fell to the `?` default,
    -- whose kids made every imported name a READ — so a module's own imports came back as
    -- reads of names nothing defines, i.e. external-surface material. The row is its
    -- binders and nothing else: the module path is a string, not a name, and the linkage
    -- rides the import EDGE. Keyed on the same declared `binder_fields` du uses, so a
    -- language that declares no import binders is untouched.
    do
        local bindf, bids = binderset(lang)
        if bindf and bindf[t] then
            local bn, br = require('cartograph.flow').pattern_binders(node, bindf, bids)
            if #bn > 0 or #br > 0 then
                local ilhs, irhs = {}, {}
                for _, x in ipairs(bn) do ilhs[#ilhs + 1] = build_binder(x, src, lang) end
                for _, x in ipairs(br) do irhs[#irhs + 1] = build(x, src, lang) end
                return { lhs = ilhs, rhs = irhs }
            end
        end
    end
    -- lua `local x = e` wraps an assignment_statement; unwrap to it
    if (lang and LOCALDECL_OF[lang][t]) or LOCALDECL[t] then
        for c in node:iter_children() do
            if c:named() and ASSIGN[c:type()] then return M.harvest_row(c, src, nil, lang) end
        end
        -- a DECLARATOR child carries name/value as fields — split it like an assignment
        -- ★ ALL OF THEM, NOT THE FIRST. This used to `return` inside the loop, which is right
        -- for js/java (one declarator per statement is the idiom) and WRONG for C, where
        -- `int c = g(n), d = 7;` is one `declaration` with two `init_declarator` children —
        -- the second name and its initialiser both vanished from the row. du has always read
        -- the declarator FIELD as a LIST (its k==7 branch); this now matches.
        -- ★ AND IT UNWRAPS `Foo *p` / `int a[4]`: the declared name is inside a pointer or
        -- array declarator, which is the same DECLWRAP walk du does, so the two arrive at the
        -- same identifier instead of one of them reading the wrapper.
        local dlhs, drhs, seen = {}, {}, false
        for c in node:iter_children() do
            if c:named() and DECLARATOR[c:type()] then
                seen = true
                local nm = c:field('name')[1] or c:field('declarator')[1]
                while nm and DECLWRAP[nm:type()] do nm = nm:field('declarator')[1] end
                local vl = c:field('value')[1]
                -- ★ A DESTRUCTURING PATTERN IS N TARGETS, NOT ONE OPAQUE ONE (CART-0358).
                -- `build` has no pattern case, so the whole `{a, b}` came back as a `?`
                -- whose kids made every BOUND name read as a USE — the IR half of the same
                -- defect du had. Expanded through flow's own rule so the two cannot draw
                -- it differently, and the pattern's genuine reads (a default's right side,
                -- a computed key) join the RHS, exactly where du counts them as uses.
                local bindf, bids = binderset(lang)
                if nm and bindf and bindf[nm:type()] then
                    local bn, br = require('cartograph.flow')
                        .pattern_binders(nm, bindf, bids)
                    for _, x in ipairs(bn) do dlhs[#dlhs + 1] = build_binder(x, src, lang) end
                    for _, x in ipairs(br) do drhs[#drhs + 1] = build(x, src, lang) end
                elseif nm then dlhs[#dlhs + 1] = build(nm, src, lang) end
                if vl then drhs[#drhs + 1] = build(vl, src, lang) end
            elseif c:named() and DECLWRAP[c:type()] then
                -- a declarator with NO initialiser (`Foo *p;`) hangs directly off the
                -- declaration, with no init_declarator to wrap it
                seen = true
                local nm = c
                while nm and DECLWRAP[nm:type()] do nm = nm:field('declarator')[1] end
                if nm then dlhs[#dlhs + 1] = build(nm, src, lang) end
            end
        end
        if seen and #dlhs > 0 then return { lhs = dlhs, rhs = drhs } end
        -- bare `local a, b` (no initializer): the names are defs, no value exprs
        -- ★ THIS FALLBACK IS LOSSY BY CONSTRUCTION — it keeps NAMES and drops everything
        -- else — and that was fine while only lua/js/java reached it, where a declaration
        -- with no declarator really is just names. C++ broke the assumption: `Foo f(x);` is
        -- a `declaration` whose declarator is a `function_declarator`, and dropping it loses
        -- the READ of `x`. MEASURED when this branch first took C's `declaration`:
        -- binder:declaration 75190 -> 102 (the fix working) but missing:declaration 0 ->
        -- 139174 (the fallback swallowing shapes it does not model) — a NET WORSE number,
        -- from a change that was right about the case it aimed at.
        -- So the fallback now only claims a row when every named child is ACCOUNTED FOR;
        -- anything else falls through to the generic `?` path below, which keeps the names
        -- rather than inventing an lhs. An honest unknown beats a confident partial answer.
        local lhs, all = {}, true
        local tyf = node:field('type')[1]
        for c in node:iter_children() do
            if c:named() and not tsutil.is_comment(c) then
                local cn = false
                if tyf and c:id() == tyf:id() then cn = true end -- a TYPE reads no variable
                for _, tn in ipairs(list_children(c)) do
                    -- @langs-ok `variable_list` is lua's bare-`local a, b` target wrapper;
                    -- no other grammar in the roster wraps an initialiser-less declaration
                    if NAME[tn:type()] or tn:type() == 'variable_list' then
                        lhs[#lhs + 1] = build(tn, src, lang); cn = true
                    end
                end
                if not cn then all = false end
            end
        end
        if all and #lhs > 0 then return { lhs = lhs, rhs = {} } end
    end
    if ASSIGN[t] then
        local left, right, lpos, rpos = assign_sides(node, src)
        local lhs, rhs = {}, {}
        local abindf, abids, awrapt = binderset(lang)
        for _, tn in ipairs(lpos or list_children(left)) do
            -- a declaration MODIFIER in a target list is not a target (CART-0234)
            if is_modifier(lang, tn) then goto nexttarget end
            -- ★ AN ASSIGNMENT TARGET CAN BE A PATTERN TOO — `[a, b] = [b, a]` (CART-0358).
            -- du keys on the PATTERN node, so it covers the declarator, the assignment and
            -- a js `catch` alike; the IR has three separate construction paths, and fixing
            -- only the declarator one made the gate WORSE, not better: du started defining
            -- these binders while the IR still READ them, so `binder:expression_statement`
            -- ROSE by 37 on ghost. Fixing one side of a shared error moves the number the
            -- wrong way — the disagreement is the thing to drive to zero, not either side.
            --
            -- ★ AND THE TARGET CAN BE PARENTHESISED: `({body: b} = await agent…)` is the
            -- idiomatic way to destructure into EXISTING bindings, because a statement may
            -- not begin with `{`. du never noticed — its walk descends every child and
            -- meets the pattern regardless of what wraps it — so the wrapper stayed
            -- invisible until the IR had to find that same node BY POSITION. A structural
            -- walk and a positional read do not fail on the same inputs, which is exactly
            -- what makes the two-implementation gate worth running.
            while awrapt and tn and tn:type() == awrapt do
                local inner = tn:named_child(0)
                if not inner then break end
                tn = inner
            end
            if abindf and abindf[tn:type()] then
                local bn, br = require('cartograph.flow')
                    .pattern_binders(tn, abindf, abids)
                for _, x in ipairs(bn) do lhs[#lhs + 1] = build_binder(x, src, lang) end
                for _, x in ipairs(br) do rhs[#rhs + 1] = build(x, src, lang) end
            else lhs[#lhs + 1] = build(tn, src, lang) end
            ::nexttarget::
        end
        for _, vn in ipairs(rpos or list_children(right)) do rhs[#rhs + 1] = build(vn, src, lang) end
        return { lhs = lhs, rhs = rhs }
    end
    -- control heads carry a condition (the switched value for go switch)
    local cond = node:field('condition')[1] or node:field('value')[1]
    if cond then return { lhs = {}, rhs = {}, cond = build(cond, src, lang) } end
    if RET[t] then
        local rhs = {}
        for c in node:iter_children() do
            for _, vn in ipairs(list_children(c)) do
                if vn:named() and not tsutil.is_comment(vn) then rhs[#rhs + 1] = build(vn, src, lang) end
            end
        end
        return { lhs = {}, rhs = rhs }
    end
    -- default: a bare expression statement (a call, etc.) — the whole node is a value
    return { lhs = {}, rhs = { build(node, src, lang) } }
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
--- The pure TRAVERSAL, exported (CART-0280) so a consumer walking for a construct does not
--- have to reimplement it. Every duplicate walker in this codebase has eventually disagreed
--- with the original about one node kind; there is one walk.
function M.walk(e, fn) return walk(e, fn) end

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
local target_reads -- fwd: an `assign`'s target is a DEF, and target_reads knows the rule
local function expr_reads(e, acc)
    if not e then return end
    local k = e.k
    if k == 'name' then acc[e.n] = true
    elseif k == 'field' then
        expr_reads(e.b, acc)
        -- the SELECTOR counts only where du counts it — `selid`, decided at build time
        -- from the grammar (CART-0402). Unconditionally counting it was 88% of the cpp
        -- census: `a->action_para` reported a read of `action_para`, which du has never
        -- claimed and which is not a variable in any of these languages.
        if e.selid and e.n and e.n ~= '' then acc[e.n] = true end
    elseif k == 'assign' then target_reads(e.t, acc); expr_reads(e.v, acc)
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
function target_reads(e, acc)
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
local ts = require('cartograph.providers.treesitter')
local spec = ts.spec
-- THE FUNCTION-NODE set fn_node walks up to. A language whose function node is not
-- in it gets NO expression records at all, however complete the rest of the layer is —
-- which is how ruby came to have 2104 flow records and zero expression ones
-- (CART-0228): its nodes are `method` / `singleton_method`, and neither was listed.
--
-- ★ IT USED TO BE A HARDCODED UNION, and a union is the wrong shape for a
-- per-language set: it is right for whichever language you last checked and
-- silently partial for the rest. Measured on the sampled def population it named
-- 0% of haskell, 0% of scheme, 35% of javascript, 66% of typescript, 87% of java
-- and 99% of rust — and it DISAGREED with the provider, which was already reading
-- `spec.fn_types` for the same question, so two modules gave two answers about
-- which function encloses the same node. Now there is one owner per language and
-- the spec audit checks it (CART-0306).
-- ★★ THE SUPPORT FILTER IS OURS; THE LANGUAGE IS NOT (CART-0410). This used to be a
-- private ext→lang table, i.e. A SECOND COPY OF THE ANSWER — the same defect the
-- comment directly above describes for fn_types, one field over. It cost a real bug:
-- the provider and this module both decided what a file's language is, so nothing
-- could make them disagree LOUDLY, and when `.h` turned out to be wrong it was wrong
-- in two places independently.
--
-- ★ AND THE OWNER IS `parse_lang`, NOT `lang_of`. lang_of folds typescript/tsx into
-- the javascript RESOLUTION family; this module RE-PARSES, and TS syntax errors out
-- under the JS grammar. VERIFIED EXT-BY-EXT before the swap: the old table agreed
-- with parse_lang on all 27 registered extensions and with lang_of on 25 — the two
-- exceptions being exactly .ts and .tsx. So this substitution is behaviour-identical
-- today and, unlike the copy, follows the provider when the provider learns something.
local SUPPORTED = {} -- langs with a body-bearing flow
for lang, s in pairs(spec) do
    -- body_of is the POSITIONAL twin of body_field (CART-0305): a language that
    -- reaches its body by descent is just as supported as one that names it.
    if s.body_field or s.body_of then SUPPORTED[lang] = true end
end

--- The language to RE-PARSE `file` as, or nil when this layer does not support it.
---
--- ★ THE CONTAINER GUARD IS NOT DEFENSIVE, IT RESTORES A REFUSAL. The private table
--- this replaces was built from spec `exts`, and vue/svelte are in NO spec's exts —
--- so containers resolved to nil and this layer refused them. `parse_lang` answers
--- `javascript` for them (the SCRIPT REGION's grammar), so routing without this guard
--- would silently START parsing whole SFCs as JS. ★ MY EXT-BY-EXT VERIFICATION MISSED
--- IT BECAUSE IT ITERATED THE 27 REGISTERED SPEC EXTS — and a container is precisely
--- an extension no spec claims. A check over the wrong population, in the change that
--- exists to fix a check over the wrong population.
local function lang_of_file(file)
    if not file or ts.is_container(file) then return nil end
    local lang = ts.parse_lang(file)
    return (lang and SUPPORTED[lang]) and lang or nil
end

local function fn_node(node, src, lang)
    local ok, parser = pcall(vim.treesitter.get_string_parser, src, lang)
    if not ok then return nil end
    local root = parser:parse()[1]:root()
    local d = root:named_descendant_for_range(at.sl(node.range), at.sc(node.range),
        at.el(node.range), at.ec(node.range))
    local fnt = ts.fn_types(lang)
    while d do if fnt[d:type()] then return d end; d = d:parent() end
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
    local lang = lang_of_file(node.file)
    if not lang or not spec[lang] then return nil end
    local s = spec[lang]
    local src = table.concat(store.content(node) or {}, '\n')
    local fn = fn_node(node, src, lang)
    if not fn then return nil end
    local cfg = { pfield = s.params_field, df_ids = s.df_ids, regime = s.regime,
        ctrl = s.ctrl, preloop = s.preloop, body = s.body, clause = s.clause, -- CART-0363
        blocks = s.blocks,                          -- attached blocks (part B)
        mods = s.binding_modifiers, -- CART-0234
        binder_fields = s.binder_fields, -- destructuring/imports (CART-0358)
        body_of = s.body_of, params_of = s.params_of, -- CART-0305
        fn_types = ts.flow_stop(lang), -- the STOP set, not enclosure (CART-0308)
        method = (node.kind == 'method') and lang == 'lua',
        expr = function (n, ns, hint) return M.harvest_row(n, ns, hint, lang) end }
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
    -- the SAME resolution as M.of (one helper, one support set), so this never
    -- claims a language M.of refuses
    local lang = lang_of_file(node.file)
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
        ctrl = s.ctrl, preloop = s.preloop, body = s.body, clause = s.clause, -- CART-0363
        blocks = s.blocks,                  -- THREE cfg sites; all must agree
        mods = s.binding_modifiers, -- CART-0234
        binder_fields = s.binder_fields, -- destructuring/imports (CART-0358)
        expr = function (n, ns, hint) return M.harvest_row(n, ns, hint, lang) end }
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
-- ★ SO THIS SET IS NOT A SEPARATE JUDGEMENT — IT IS FLOW'S STOP-SET. The exclusion
-- exists precisely because `du`'s FN-stop did not fire at the root, so the two must
-- name the same node types or the gate mis-fires. They were written out separately
-- and DID NOT AGREE (CART-0308): flow's set had php `anonymous_function` and java
-- `constructor_declaration` that this one lacked; this one had rust `function_item`
-- and js `method_definition` that flow's lacked, plus `local_function`, which is a
-- node type in NO installed grammar — the same dead-name defect the spec audit
-- caught in `spec.fn_types`, one table over, where the audit cannot see it.
-- Both now derive from the language's declared set, so they agree by construction.
local FN_FALLBACK = require('cartograph.providers.treesitter').flow_stop('lua')

--- the SELF-GATE: for each row, `expr.reads(row)` must equal `use ∪ rmw`. Returns a
--- list of disagreements (empty = clean). Used by syngate + tests + dogfooding.
--- `lang` must be the language the flow was BUILT for — pass `of()`'s `lang` field.
--- Omitting it falls back to lua, which is what the lua-only test fixtures want and
--- is wrong for anything else, so pass it.
--- @return table[] { row, line, reads, du, missing, extra }
function M.gate(fl, lang)
    local FNDECL = lang
        and require('cartograph.providers.treesitter').flow_stop(lang)
        or FN_FALLBACK
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
