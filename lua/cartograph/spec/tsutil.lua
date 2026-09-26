-- Shared tree-sitter helpers for the spec modules AND the engine — the L0
-- grammar-binding substrate ([[cartograph-spec-layering]]). A spec module
-- (spec/<lang>.lua) requires this for the common node primitives instead of
-- reaching into the engine, which would be a require cycle (the engine
-- requires the spec modules). The engine aliases these too, so there is ONE
-- definition. Pure: depends on nothing.

-- @langs any — a SHARED helper over every spec: the node types it names are
-- cross-grammar UNIONS (see COMMENT below), never one grammar's vocabulary
-- imposed on the rest.

local M = {}

-- ★ WHAT EVERY GRAMMAR CALLS A COMMENT, and it is not one name. Most say
-- `comment`; JAVA and RUST say `line_comment`/`block_comment` (rust adds
-- `doc_comment`), and scheme has `block_comment` beside `comment`.
--
-- This table exists because 32 sites across flow, the extractor, the expression
-- IR and narrow each tested `type() ~= 'comment'` — so in java and rust a comment
-- was a STATEMENT, an expression CHILD and a narrowable point. Measured when the
-- first of them was fixed: elasticsearch/libs 42766 -> 40354 flow rows (-5.6%),
-- ripgrep 11906 -> 10955 (-8.0%), with defs and uses IDENTICAL — the signature of
-- phantom EMPTY rows disappearing rather than real statements being lost. Found by
-- tools/langaudit.lua (CART-0304); no test could see it, because the suite is
-- lua-only and lua calls its comments `comment`.
--
-- ONE definition, here, because the point of the finding was that thirty-two
-- copies of a language assumption drift independently — and the df/flow parity
-- gate's own header names exactly that hazard ("a per-language fix landed on ONE
-- side").
M.COMMENT = {
    comment = true,                             -- lua, ruby, php, python, go, js, c…
    line_comment = true, block_comment = true,  -- java, rust, scheme
    doc_comment = true,                         -- rust `///`
}

--- Is `node` a comment in ANY grammar we bind? Cheap membership, no language
--- parameter needed: the names do not collide across the roster.
function M.is_comment(node)
    return node ~= nil and M.COMMENT[node:type()] == true
end

-- PAREN WRAPPERS to peel before reading a condition or a literal. Ruby's is
-- `parenthesized_statements`, not `_expression` — so `while (true)` and every
-- parenthesised guard went unpeeled there. Three sites had their own copy of the
-- single-name test (flow's const_cond, the extractor's param_conj and its else-arm
-- negation); one definition, for the reason COMMENT above is one definition.
M.PARENS = {
    parenthesized_expression = true,   -- most grammars
    parenthesized_statements = true,   -- ruby
}

-- THE ELSEIF VOCABULARY, third resident of this file for the same reason as the
-- two above (CART-0304). Lived as a cfg.lua local; exprlint and optimize each
-- reached for the single literal `elseif_statement` instead, which is LUA's name.
--
-- ★ AND THE TWO GRAMMAR FAMILIES ARE THE POINT, not the spellings. FLAT grammars
-- give an elseif its own node type (lua `elseif_statement`, python `elif_clause`,
-- ruby `elsif`) and it is a SIBLING alternative. NESTED grammars (c, php, js) have
-- NO elseif node at all — `else if` is a plain `if_statement` inside an
-- `else_clause`. So a table can never answer "is this an elseif" for the nested
-- family, and a consumer that walks an if-CHAIN by node type is not merely missing
-- entries there, it is asking a question the grammar does not answer. That is a
-- REFUSAL to declare, not a table row to add.
M.ELSEIF = {
    elseif_statement = true,   -- lua
    elseif_clause = true,
    else_if_clause = true,
    elif_clause = true,        -- python
    elsif = true,              -- ruby
}

-- if-statement HEADS. Deliberately NOT cfg's `COND`, which also carries while /
-- ternary / comprehension because it answers "does this node guard something".
-- An if-chain walker wants the `if` family alone (the FNDECL test from CART-0308:
-- same shape is not the same question).
M.IF_HEAD = {
    if_statement = true,       -- lua, python, c, php, js, java, go, …
    ['if'] = true,             -- ruby
    if_expression = true,      -- rust
    if_modifier = true,        -- ruby `x if cond`
}

--- Peel paren wrappers off `node`, returning the innermost named child.
function M.unparen(node)
    while node and M.PARENS[node:type()] do
        local inner
        for c in node:iter_children() do if c:named() then inner = c break end end
        if not inner then break end
        node = inner
    end
    return node
end

-- Node text, hot-path fast form. vim.treesitter.get_node_text allocates two
-- throwaway tables (opts, metadata) on EVERY call before doing this same
-- byte-slice; over a big corpus that is millions of dead tables feeding the
-- GC. We only ever pass a string source and never metadata, so the slice is
-- byte-for-byte identical (multiline included) without the allocation.
function M.node_text(n, src)
    return src:sub(select(3, n:start()) + 1, select(3, n:end_()))
end

-- indexed child iteration, replacing TSNode:iter_children() everywhere:
-- iter_children allocates a TSTreeCursor userdata + a closure PER CALL —
-- measured 2.7x slower and ~2x more transient garbage than indexed access.
-- STATELESS iterator (zero alloc), same sequence as iter_children (ALL
-- children, anonymous tokens included — existing named()/type() guards
-- filter):  for _, c in tsutil.inext, node, -1 do ... end
function M.inext(n, i)
    i = i + 1
    local c = n:child(i)
    if c then return i, c end
end

-- a REFUSAL is a place: when resolution declines to pick, the call keeps the
-- rule that refused and (capped, sorted — worker == inline) the candidate ids
-- it refused between, so the browser can descend into the fork, not a dead end.
function M.refusal(rule, list)
    if not list or #list == 0 then return { rule = rule } end
    local ids = {}
    for i = 1, math.min(#list, 8) do ids[i] = list[i].id end
    table.sort(ids)
    return { rule = rule, cands = ids, n = #list }
end

-- THE CAP IS A PROPERTY OF THE INSTRUMENT, NOT OF THE CODE (CART-0670/0682).
-- `M.refusal` records both halves — `cands` is a capped SAMPLE and `n` is the
-- true count — and a consumer that reads one without the other is silently
-- wrong wherever they differ. On an 8k-file Java monorepo that was 21.6% of the
-- refusals carrying a list, and the consumer reading `#cands` was the premise
-- deciding whether a definition may be DELETED.
--
-- ⚠ TWO PREDICATES, NOT ONE, AND THE GAP BETWEEN THEM IS REAL. `n` is absent on
-- refusals this constructor did not build (providers/tokens.lua:832 mints an
-- `ambiguous` record from an UNCAPPED roster and records no count), so "known
-- incomplete" and "known complete" are not negations of each other — a record
-- with no `n` is neither. Ask the question you actually need:
--   truncated  the elided tail EXISTS   → a candidate you cannot see may be it
--   complete   the list is ALL of them  → an argument may quantify over it
function M.truncated(r)
    return type(r) == 'table' and r.cands ~= nil
        and r.n ~= nil and r.n > #r.cands
end

-- ★ C LINKAGE (CART-1079): is this C/C++ declaration inside `extern "C"`, i.e. under a linkage_specification whose
-- value is "C"? `extern "C" int f() {}` and `extern "C" { int f(); }` both parse that way. A C++ function a C file
-- can call must have C linkage, so this is the evidence the name join's C/C++ bridge asks for (providers/treesitter.lua
-- M._join_lang_ok): a definition, or a prototype in a header, is enough.
-- ★ FILE-LOCAL C/C++ NAMES (CART-1081): a `static` free function and a function-like macro defined in a SOURCE file are
-- invisible to every other file by name, however unique the name looks corpus-wide. Headers are exempt: their contents
-- are included textually, so a header's `static inline` or macro IS visible to each includer. A static MEMBER function
-- (in a class body) has class linkage and is exempt too. Found when the C/C++ join bridge (CART-1079) linked
-- luanti's noise.cpp `next()` to lua's llex.c `next` macro and codeql's scanner.cc `advance` to another grammar's static.
local C_HEADER = { h = true, hh = true, hpp = true, hxx = true, inl = true, ipp = true, tcc = true }
function M.c_file_local(defn, src, file)
    local ext = file and file:match('%.([%w]+)$')
    if not ext or C_HEADER[ext:lower()] then return false end
    local t = defn:type()
    if t == 'preproc_function_def' then return true end
    if t ~= 'function_definition' then return false end
    local p = defn:parent()
    if p and p:type() == 'field_declaration_list' then return false end
    for c in defn:iter_children() do
        if c:type() == 'storage_class_specifier' and M.node_text(c, src) == 'static' then return true end
    end
    return false
end

-- ★ C/C++ TEARING BY CONTEXT, NOT BY POSITION (CART-1084). The default torn policy tears every def after a file's first
-- parse error, calibrated on truncated PHP classes whose later methods float unqualified. In C/C++ that tore 58.5% of v8's
-- functions (41k of them torn by POSITION ALONE: clean subtree, clean ancestors) and hid the real definitions of v8's
-- CHECK and scip's SCIP_CALL behind a distant error. What the default protects against is real, and it has a SHAPE in
-- C++: error recovery parses a class body as a FUNCTION body, so its inline methods come out as free functions nested
-- inside a bogus function_definition (v8 instruction.h `successors`, bigint.cc `set_digit`, sampled). A genuine
-- definition only ever sits under structural containers. So a def is torn when its HEAD has an error (a function's
-- body may hold errors without moving its name), an ancestor is an ERROR node, or an ancestor is anything but a
-- structural container. A function-like macro is
-- self-contained (its extent is the #define and its continuations): only its own error or an ERROR ancestor tears it.
local C_STRUCTURAL = {
    translation_unit = true, declaration_list = true, namespace_definition = true, linkage_specification = true,
    template_declaration = true, field_declaration_list = true, class_specifier = true, struct_specifier = true,
    union_specifier = true, friend_declaration = true, preproc_if = true, preproc_ifdef = true, preproc_else = true,
    preproc_elif = true, preproc_elifdef = true,
}
-- does `n` hold an actual ERROR node? has_error() alone is not the question: it is also true for MISSING tokens, and on
-- a preproc_function_def it can be true with NO ERROR or MISSING node anywhere below (scip def.h SCIP_CALL_ABORT@342,
-- luanti mini-gmp.c gmp_umul_ppmm@102, both kept by the old positional rule because they precede the first ERROR). The
-- positional rule only ever looked at ERROR nodes, so this does too; has_error() is only the pruning hint.
local function has_error_node(n)
    if n:type() == 'ERROR' then return true end
    if not n:has_error() then return false end
    for c in n:iter_children() do
        if has_error_node(c) then return true end
    end
    return false
end
-- is this function_definition's declarator a qualified name (`X::m`, `ns::f`, `X::~X`, `X::operator=`)?
local C_DECL_WRAP = { pointer_declarator = true, reference_declarator = true, parenthesized_declarator = true,
    attributed_declarator = true }
local function c_qualified_def(dn)
    if dn:type() ~= 'function_definition' then return false end
    local d = dn:field('declarator')[1]
    while d and C_DECL_WRAP[d:type()] do d = d:field('declarator')[1] or d:named_child(0) end
    if not (d and d:type() == 'function_declarator') then return false end
    local name = d:field('declarator')[1]
    return name ~= nil and name:type() == 'qualified_identifier'
end
function M.c_torn_context(dn, dname)
    -- the def's IDENTITY is its head (type, declarator, name), not its body: an error inside the body does not move
    -- the name, and the old positional rule kept exactly those defs when they started before the first error (7kaa
    -- OGAMENCY.cpp disp_picture, OSPREOFF.cpp use_offset_method: clean heads at top level, ERRORs in the body)
    local body = dn:type() == 'function_definition' and dn:field('body')[1] or nil
    if body then
        local bid = body:id()
        for c in dn:iter_children() do
            if c:id() ~= bid and has_error_node(c) then return true end
        end
    elseif has_error_node(dn) then
        return true
    end
    -- a QUALIFIED declarator (`void MacroAssembler::LoadPC(...)`) names its own class: what the structural check guards
    -- against is an UNQUALIFIED inline method that lost its class, and a qualified one cannot. v8's
    -- macro-assembler-ppc.cc nests every later definition inside a function body (an #if/#else with braces split across
    -- the branches), and 213 correctly named methods there were torn by the structural check alone.
    -- and so does a def cartograph NAMED with its class (`JSCallReducerAssembler::ReceiverInput`, recovered from a class
    -- body parsed as a function body, the old rule's pre-error survivors): only an UNQUALIFIED name is at risk
    local free = dn:type() == 'preproc_function_def' or c_qualified_def(dn)
        or (dname ~= nil and dname:find('::', 1, true) ~= nil)
    local p = dn:parent()
    while p do
        local t = p:type()
        if t == 'ERROR' then return true end
        if not free and not C_STRUCTURAL[t] then return true end
        p = p:parent()
    end
    return false
end

function M.c_linkage(defn, src)
    local p = defn
    while p do
        if p:type() == 'linkage_specification' then
            local v = p:field('value')[1]
            return v ~= nil and M.node_text(v, src) == '"C"'
        end
        p = p:parent()
    end
    return false
end

function M.complete(r)
    return type(r) == 'table' and r.cands ~= nil
        and r.n ~= nil and r.n <= #r.cands
end

-- ── guard substrate ──────────────────────────────────────────────────────
-- Shared by the language `guards` specs (lua, php, …) AND the engine's generic
-- guard machinery. Grammar-agnostic node predicates; each language's GUARDS
-- table wires them into its own set-once/presence/absence tests. Lives here
-- (not the engine) so a spec module can require them without a require cycle.

-- whitespace-stripped node text, for the rare longer-span comparison fallback
local function ntext(x, src) return (M.node_text(x, src):gsub('%s', '')) end

-- text-equality of a node's source span against a target `chain` string,
-- span-length-gated (most comparisons reject on a cheap byte-length check).
-- A longer span falls back to whitespace-insensitive compare (format variance).
function M.chain_eq(x, src, chain)
    local d = select(3, x:end_()) - select(3, x:start())
    if d < #chain then return false end
    if d == #chain then return M.node_text(x, src) == chain end
    return ntext(x, src) == chain -- longer: whitespace variance, rare
end

-- anonymous nodes' type() IS their literal text: no string extraction
function M.optext_is(n, _, want)
    for i = 0, n:child_count() - 1 do
        local ch = n:child(i)
        if not ch:named() and want[ch:type()] then return true end
    end
    return false
end

--- IS THIS MENTION A WRITE, for the C FAMILY (CART-0532). Shared by c.lua and
--- cpp.lua because the two grammars spell every write form identically — the same
--- reason chain_eq/optext_is live here rather than in lua.lua and php.lua twice.
--- Declared as a PAIR with each spec's `write_gate`, which the suite enforces.
---
--- MEASURED BEFORE BUILDING: c/cpp is the largest population with no write facts —
--- 2073 var nodes on the cpp corpus (.h 1181 · .cpp 829 · .c 31) and 686 on
--- cppmodern, all carrying no `rw`, no `gw`, no `gp`, no `flds`. It was missing from
--- the write-axis census entirely because the `zig` corpus's 35 vars and 52 use
--- edges — which ARE C++, that corpus being the zig compiler — had been read as
--- zig's (CART-0538).
---
--- THE BINDINGS ARE `init_declarator` (`int x = 7;`) and `declaration` (`int x;`),
--- neither of which is a write: that is what keeps set-once reachable, and the
--- initializer-less form is CART-0537's case one language over (`extern int x;` in
--- a header, where headers hold MORE vars than sources on this corpus).
function M.cfamily_is_write(c, n)
    local cur, p = c, n
    while p do
        local pt = p:type()
        if pt == 'field_expression' or pt == 'qualified_identifier'
            or pt == 'pointer_expression' then
            -- `o.f` · `s->f` (one node type for both) · `N::q` · `*p`. Every level
            -- of a nested chain rides, as in lua/go/java.
            cur, p = p, p:parent()
        elseif pt == 'subscript_expression' then
            -- `a[i] = v` writes a; the INDEX reads. cpp wraps the index in a
            -- `subscript_argument_list`, so an index mention never even reaches
            -- this arm — it breaks out below and fails the assignment test.
            if p:field('argument')[1] ~= cur then return false end
            cur, p = p, p:parent()
        else
            break
        end
    end
    if not p then return false end
    local pt = p:type()
    if pt == 'assignment_expression' then
        return p:named_child(0) == cur -- one node type for `=` and `+=`
    elseif pt == 'update_expression' then
        return true -- g++ / --g
    end
    return false
end

-- descend through parenthesized wrappers to the inner expression
function M.unparen(n)
    while n and n:type() == 'parenthesized_expression' do n = n:named_child(0) end
    return n
end

return M
