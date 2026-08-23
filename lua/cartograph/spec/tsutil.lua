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
