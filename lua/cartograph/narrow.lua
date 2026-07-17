-- narrow.lua — branch-sensitive NARROWING (INC 1: Lua nil/truthiness), the TYPE
-- sibling of const-fold ([[cartograph-type-narrowing]]). A per-language GUARD
-- VOCABULARY classifies a guard condition into narrowing FACTS `{var, kind, when}`
-- (`when` = the cond truth value under which the fact holds). cfg.guards_over gives
-- which guards structurally dominate a point (+ `neg` = ¬cond holds there), so a
-- fact is ACTIVE at a point when `fact.when == (not guard.neg)`. Read-only
-- knowledge, SOUND only where the predicate proves it (conjunctions narrow; `or`
-- and negated compounds don't). The vocab is EXTENSIBLE per language — INC 1 fills
-- Lua nil/truthiness; typeof/instanceof/discriminant (JS/Java) slot in later
-- (instanceof matters for other codebases — the table is ready for it).

local cfg = require 'cartograph.cfg'
local at = require 'cartograph.at'
local flowmod = require 'cartograph.flow'

local M = {}

-- vars REASSIGNED (an assignment_statement, not a fresh `local`) anywhere in the fn.
-- guards_over is purely structural — it can't see that `if x then … x = f() … use(x)`
-- reassigns x between the guard and the use, staling the narrowing. Conservatively
-- kill narrowing for any reassigned var (sound: never under-kills). Reuses flow's def.
local function mutated_of(store_node)
    local m = {}
    local fl = store_node and flowmod.present(store_node) and flowmod.record(store_node)
    if fl and fl.stmts then
        for _, s in ipairs(fl.stmts) do
            if s.t == 'assignment_statement' then
                for _, v in ipairs(s.def or {}) do m[v] = true end
            end
        end
    end
    return m
end

local function txt(n, src) return n and vim.treesitter.get_node_text(n, src) or '' end

-- ── per-language guard vocabulary ────────────────────────────────────────────
-- vocab[lang](cond, src, holds) -> { {var, kind}, ... } = the facts that MUST hold
-- given the condition evaluates to `holds` (true for positive nesting, false for a
-- passed early-exit). Polarity is pushed THROUGH the connectives (De Morgan) rather
-- than flipped per-fact, so a conjunction under negation (`if not a and b then
-- return` → after, ¬(a∧b) proves NOTHING) is sound. kind: 'truthy' (from `if x` —
-- non-nil AND non-false) or 'non-nil' (from x~=nil); truthy ⟹ non-nil.
local vocab = {}

local function lua_classify(cond, src, holds)
    if not cond then return {} end
    local t = cond:type()
    if t == 'parenthesized_expression' then
        return lua_classify(cond:named_child(0), src, holds)
    elseif t == 'unary_expression' then
        if txt(cond:child(0), src) == 'not' then -- ¬X holds ⟺ X holds with flipped value
            return lua_classify(cond:named_child(0), src, not holds)
        end
        return {}
    elseif t == 'binary_expression' then
        local l, r = cond:named_child(0), cond:named_child(1)
        local op = txt(cond:child(1), src)
        if op == 'and' then
            if not holds then return {} end -- ¬(a∧b) = ¬a∨¬b → nothing certain
            local out = lua_classify(l, src, true)
            for _, f in ipairs(lua_classify(r, src, true)) do out[#out + 1] = f end
            return out
        elseif op == 'or' then
            if holds then return {} end -- (a∨b) → nothing; ¬(a∨b) = ¬a∧¬b → both hold
            local out = lua_classify(l, src, false)
            for _, f in ipairs(lua_classify(r, src, false)) do out[#out + 1] = f end
            return out
        elseif op == '==' or op == '~=' then -- x == nil / x ~= nil (either order)
            local var
            if txt(r, src) == 'nil' and l:type() == 'identifier' then var = txt(l, src)
            elseif txt(l, src) == 'nil' and r:type() == 'identifier' then var = txt(r, src) end
            if var and ((op == '~=') == holds) then return { { var = var, kind = 'non-nil' } } end
            return {}
        end
        return {}
    elseif t == 'identifier' then
        if holds then return { { var = txt(cond, src), kind = 'truthy' } } end -- `if x`
        return {}
    end
    return {}
end
vocab.lua = lua_classify

local EXT_LANG = { lua = 'lua' } -- INC 1: Lua only; add js/java as the vocab grows

-- ── the fn's AST (re-parse; guards_over is inherently AST-based, like taint) ──
local FN_TYPES = { function_declaration = true, function_definition = true }
local function fn_node(node, src, lang)
    local ok, parser = pcall(vim.treesitter.get_string_parser, src, lang)
    if not ok then return nil end
    local root = parser:parse()[1]:root()
    local sl, sc, el, ec = at.sl(node.range), at.sc(node.range),
        at.el(node.range), at.ec(node.range)
    local d = root:named_descendant_for_range(sl, sc, el, ec)
    while d do
        if FN_TYPES[d:type()] then return d end
        d = d:parent()
    end
    return nil
end

--- Branch-sensitive narrowing of the focused fn. Walks the body's statements; at
--- each, cfg.guards_over gives the dominating guards, the vocab classifies each into
--- facts, and a fact is kept when its polarity matches the guard's truth value.
--- @return table { lang, unsupported?, points: { {line, kind, env: {[var]=kind}} }, nguards }
function M.narrow(store, fn_id)
    local node = store.node and store.node(fn_id)
    if not node or not node.file then return { points = {} } end
    local lang = EXT_LANG[node.file:match('%.(%w+)$') or '']
    if not lang or not vocab[lang] then
        return { lang = node.file:match('%.(%w+)$'), unsupported = true, points = {} }
    end
    local src = table.concat(store.content(node) or {}, '\n')
    local fn = fn_node(node, src, lang)
    if not fn then return { lang = lang, points = {} } end
    local classify = vocab[lang]
    local mutated = mutated_of(node)

    local points, seenguard = {}, {}
    local function visit(n)
        for c in n:iter_children() do
            if c:named() then
                if c:type() == 'block' then
                    for stmt in c:iter_children() do
                        if stmt:named() and stmt:type() ~= 'comment' then
                            local env = {}
                            for _, g in ipairs(cfg.guards_over(stmt, src)) do
                                for _, f in ipairs(classify(g.cond, src, not g.neg)) do
                                    if not mutated[f.var] then -- reassigned → stale, skip
                                        env[f.var] = 'non-nil' -- narrowing = non-nil (truthy ⟹ non-nil)
                                        seenguard[g.cond:id()] = true
                                    end
                                end
                            end
                            if next(env) then
                                points[#points + 1] = { line = stmt:start() + 1,
                                    kind = stmt:type(), env = env }
                            end
                        end
                    end
                end
                if not FN_TYPES[c:type()] then visit(c) end -- nested fns = their own scope
            end
        end
    end
    visit(fn)
    table.sort(points, function (a, b) return a.line < b.line end)
    local nguards = 0
    for _ in pairs(seenguard) do nguards = nguards + 1 end
    return { lang = lang, points = points, nguards = nguards }
end

-- the narrowing env active AT a node from its DOMINATING guards (excludes the
-- node's own condition — guards_over walks parents). Keeps the STRONGEST kind
-- (truthy ⊐ non-nil), which redundant-check determination needs.
local function env_of(node, src, classify, mutated)
    local env = {}
    for _, g in ipairs(cfg.guards_over(node, src)) do
        for _, f in ipairs(classify(g.cond, src, not g.neg)) do
            if not (mutated and mutated[f.var]) then
                if f.kind == 'truthy' then env[f.var] = 'truthy'
                elseif not env[f.var] then env[f.var] = 'non-nil' end
            end
        end
    end
    return env
end

-- is a SIMPLE condition already DETERMINED by `env`? → 'always-true' (tautology,
-- then-branch always taken) | 'dead' (contradiction, then-branch dead) | nil.
-- `if x` needs TRUTHY (x could be false, so non-nil alone doesn't determine it);
-- `x~=nil`/`x==nil` need non-nil; `not x` dead only under truthy.
local function determine(cond, src, env)
    local t = cond:type()
    if t == 'parenthesized_expression' then return determine(cond:named_child(0), src, env) end
    if t == 'identifier' then
        if env[txt(cond, src)] == 'truthy' then return 'always-true' end
        return nil
    end
    if t == 'unary_expression' and txt(cond:child(0), src) == 'not' then
        local inner = cond:named_child(0)
        if inner and inner:type() == 'identifier' and env[txt(inner, src)] == 'truthy' then
            return 'dead'
        end
        return nil
    end
    if t == 'binary_expression' then
        local l, r = cond:named_child(0), cond:named_child(1)
        local op = txt(cond:child(1), src)
        local var
        if txt(r, src) == 'nil' and l:type() == 'identifier' then var = txt(l, src)
        elseif txt(l, src) == 'nil' and r:type() == 'identifier' then var = txt(r, src) end
        if var and (env[var] == 'truthy' or env[var] == 'non-nil') then
            if op == '~=' then return 'always-true' end -- x~=nil, x known non-nil
            if op == '==' then return 'dead' end        -- x==nil, x known non-nil
        end
    end
    return nil
end

--- REDUNDANT-CHECK ELIMINATION (INC 2, the paving-stone lint). An `if` whose
--- condition re-tests a fact a DOMINATING guard already established is dead: the
--- env at the guard already determines the condition. `always=true` → the
--- then-branch is always taken (the check is a tautology); `always=false` → the
--- then-branch is dead (the check contradicts what's known). The TYPE twin of
--- const-fold's dead-branch. Sound: only where a proven fact determines the test.
--- @return table { lang, unsupported?, checks: { {line, var, kind, always, cond} } }
function M.redundant(store, fn_id)
    local node = store.node and store.node(fn_id)
    if not node or not node.file then return { checks = {} } end
    local lang = EXT_LANG[node.file:match('%.(%w+)$') or '']
    if not lang or not vocab[lang] then
        return { lang = node.file:match('%.(%w+)$'), unsupported = true, checks = {} }
    end
    local src = table.concat(store.content(node) or {}, '\n')
    local fn = fn_node(node, src, lang)
    if not fn then return { lang = lang, checks = {} } end
    local classify = vocab[lang]
    local mutated = mutated_of(node)
    -- determine() handles only SINGLE predicates, so a conjunction `cond and other()`
    -- (where only `cond` is known) is correctly NOT flagged — the other conjunct still
    -- gates the branch.
    local checks = {}
    local function visit(n)
        for c in n:iter_children() do
            if c:named() then
                if c:type() == 'if_statement' then
                    local cond = c:field('condition')[1]
                    if cond then
                        local d = determine(cond, src, env_of(c, src, classify, mutated))
                        if d then
                            checks[#checks + 1] = { line = cond:start() + 1,
                                always = (d == 'always-true'), cond = txt(cond, src) }
                        end
                    end
                end
                if not FN_TYPES[c:type()] then visit(c) end -- nested fns = their own scope
            end
        end
    end
    visit(fn)
    table.sort(checks, function (a, b) return a.line < b.line end)
    return { lang = lang, checks = checks }
end

--- The lens surface (:CartographNarrow): where a guard narrows a variable, and to
--- what. Per statement under a narrowing guard, its active facts (`x: non-nil`).
function M.report(store, fn_id)
    local node = store.node and store.node(fn_id)
    if not node then return { 'narrow: no such node' } end
    local res = M.narrow(store, fn_id)
    if res.unsupported then
        return { ('narrow: %s not yet supported (INC 1 = Lua nil/truthiness)')
            :format(res.lang or '?') }
    end
    if #res.points == 0 then
        return { ('narrow: %s — no guard-narrowed regions'):format(node.name or fn_id) }
    end
    local L = { ('narrow: %s — %d narrowing guard(s) over %d statement(s)')
        :format(node.name or fn_id, res.nguards, #res.points), '' }
    for _, p in ipairs(res.points) do
        local facts = {}
        for var, kind in pairs(p.env) do facts[#facts + 1] = ('%s: %s'):format(var, kind) end
        table.sort(facts)
        L[#L + 1] = ('  L%-4d %-16s %s'):format(p.line, p.kind, table.concat(facts, ', '))
    end
    -- INC 2: redundant checks — an `if` re-testing an already-proven fact
    local red = M.redundant(store, fn_id)
    if #red.checks > 0 then
        L[#L + 1] = ''
        L[#L + 1] = ('redundant check(s) — %d (already determined by a dominating guard):')
            :format(#red.checks)
        for _, c in ipairs(red.checks) do
            L[#L + 1] = ('  L%-4d if %s  →  %s'):format(c.line, c.cond,
                c.always and 'always true, then-branch always taken'
                    or 'always false, then-branch dead')
        end
    end
    L[#L + 1] = ''
    L[#L + 1] = 'a fact holds only where its guard PROVES it (nil-check / truthiness /'
    L[#L + 1] = 'and-conjunction; `or` and negated compounds do not narrow). Sound knowledge,'
    L[#L + 1] = 'not a guess — feeds redundant-check elimination + null-deref (INC 2/3).'
    return L
end

return M
