-- qlower — LIFT the Lua backing a plan operator to a term, SPECIALIZE it with the facts the plan knows, LOWER it back
-- to Lua (CART-1142 S5b). The reify -> manipulate -> reflect loop on code.
--
--   lift(src)          the algebra's lossless `lua` grammar, TRIVIA STRIPPED (whitespace and comments dropped, except
--                      inside string literals): laws match the code, not its formatting
--   lower(term)        leaves joined by single spaces (string literals verbatim): valid Lua, a BUILD ARTIFACT — the
--                      original source stays the source
--   specialize(t, laws, facts)   apply code LAWS (template pairs over the stripped CST) to a fixpoint; a law fires only
--                      when its side condition holds for the stated FACTS (e.g. `transfer` is known nil)
--
-- ★ SOUNDNESS lives in the facts: a law is constant folding under a stated fact, and a fold that keeps a branch wraps it
-- in `do … end` so no local changes scope. Nothing here INFERS a fact — the plan states them (CART-1143 is inference).
local M = {}

local function A() return require('cartograph.algebra').load() end

-- the values for the rhs's own holes: a law may DROP a hole the lhs bound (`if X then B end` -> nothing), and
-- instantiate refuses a value for a hole its template does not have
local function only_holes(T, values)
    local out = {}
    for h in pairs(T.holes or {}) do out[h] = values[h] end
    return out
end


local function strip(t)
    if t.k == 'lit' then return t end
    if t.k == 'comment' then return nil end
    if t.k == 'string' then return t end        -- verbatim: its leaves are its value
    local kids = {}
    for _, c in ipairs(t.kids or {}) do
        if c.k == 'lit' then
            if not tostring(c.v):match('^%s*$') then kids[#kids + 1] = c end
        else
            local s = strip(c)
            if s then kids[#kids + 1] = s end
        end
    end
    return A().rebuild(t, kids)
end

--- source -> the stripped CST, or nil, why
function M.lift(src)
    local G = A().grammars.lua
    local t = G and G.parse(src)
    if not t then return nil, 'the lua grammar does not parse it (or tree-sitter lua is unavailable)' end
    return strip(t)
end

--- the stripped CST -> Lua text
function M.lower(t)
    local buf = {}
    local function raw(x)
        if x.k == 'lit' then buf[#buf + 1] = tostring(x.v); return end
        for _, c in ipairs(x.kids or {}) do raw(c) end
    end
    local function go(x)
        if x.k == 'lit' then
            buf[#buf + 1] = ' '; buf[#buf + 1] = tostring(x.v)
        elseif x.k == 'string' then
            buf[#buf + 1] = ' '; raw(x)
        else
            for _, c in ipairs(x.kids or {}) do go(c) end
        end
    end
    go(t)
    return table.concat(buf)
end

--- the function declaration named `name` (local or not): path, node
function M.find_function(t, name)
    for _, pos in ipairs(A().positions(t)) do
        local n = pos.node
        if n.k == 'function_declaration' then
            for _, c in ipairs(n.kids or {}) do
                if c.k == 'identifier' and c.kids and c.kids[1] and c.kids[1].v == name then return pos.path, n end
            end
        end
    end
end

--- a code law: lhs/rhs are stripped-CST terms with holes; `when(facts, values) -> ok, why`
function M.law(name, lhs, rhs, when)
    local a = A()
    return { name = name, lhs = a.template(lhs), rhs = a.template(rhs), when = when }
end

--- apply `laws` to a fixpoint (preorder, first match), under `facts`. -> term, log = { { law, path } }
function M.specialize(t, laws, facts, limit)
    local a = A()
    local log = {}
    for _ = 1, limit or 200 do
        local fired = false
        for _, pos in ipairs(a.positions(t)) do
            for _, L in ipairs(laws) do
                local m = a.match(L.lhs, pos.node)
                if m.ok and (not L.when or L.when(facts, m.values)) then
                    local inst = a.instantiate(L.rhs, only_holes(L.rhs, m.values))
                    if inst.ok then
                        t = a.put(t, pos.path, inst.term)
                        log[#log + 1] = { law = L.name, path = pos.path }
                        fired = true
                        break
                    end
                end
            end
            if fired then break end
        end
        if not fired then break end
    end
    return t, log
end

-- ── the CONSTANT-FOLDING laws: a name the plan states is known nil / known non-nil ───────────────────────────────
local function N(k, ...) return A().node(k, ...) end
local function L_(v) return A().lit(v) end
local function H(h) return A().hole(h) end

--- the laws over a fact table { [name] = 'nil' | 'set' }
function M.fold_laws()
    local laws = {}
    local function named(values) return values.x and values.x.kids and values.x.kids[1] and values.x.kids[1].v end
    -- `if X then B end` with X known nil: the statement goes (an empty node prints nothing)
    laws[#laws + 1] = M.law('if-nil drops', N('if_statement', L_'if', H'x', L_'then', H'b', L_'end'), N('empty'),
        function (facts, v) return v.x.k == 'identifier' and facts[named(v)] == 'nil' end)
    -- `if X then B end` with X known set: B, in its own scope
    laws[#laws + 1] = M.law('if-set keeps', N('if_statement', L_'if', H'x', L_'then', H'b', L_'end'),
        N('do_statement', L_'do', H'b', L_'end'),
        function (facts, v) return v.x.k == 'identifier' and facts[named(v)] == 'set' end)
    -- `if X then A else B end`: A when X is known set, B when known nil
    laws[#laws + 1] = M.law('if-else set', N('if_statement', L_'if', H'x', L_'then', H'a', N('else_statement', L_'else', H'b'), L_'end'),
        N('do_statement', L_'do', H'a', L_'end'),
        function (facts, v) return v.x.k == 'identifier' and facts[named(v)] == 'set' end)
    laws[#laws + 1] = M.law('if-else nil', N('if_statement', L_'if', H'x', L_'then', H'a', N('else_statement', L_'else', H'b'), L_'end'),
        N('do_statement', L_'do', H'b', L_'end'),
        function (facts, v) return v.x.k == 'identifier' and facts[named(v)] == 'nil' end)
    -- `not X or E` with X known nil: true
    laws[#laws + 1] = M.law('not-nil or', N('binary_expression', N('unary_expression', L_'not', H'x'), L_'or', H'e'),
        N('true', L_'true'),
        function (facts, v) return v.x.k == 'identifier' and facts[named(v)] == 'nil' end)
    -- `E and (true)`: E
    laws[#laws + 1] = M.law('and true', N('binary_expression', H'e', L_'and', N('parenthesized_expression', L_'(', N('true', L_'true'), L_')')),
        H'e')
    return laws
end

return M
