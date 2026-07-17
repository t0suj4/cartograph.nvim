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

local M = {}

local function txt(n, src) return n and vim.treesitter.get_node_text(n, src) or '' end

-- ── per-language guard vocabulary ────────────────────────────────────────────
-- vocab[lang](cond_node, src) -> { {var, kind, when}, ... }
local vocab = {}

-- Lua: nil-check (x==nil / x~=nil), truthiness (x / not x), and-conjunctions.
-- TODO(later increments): type(x)=='T' (type-test), x.tag==… (discriminant).
local function lua_classify(cond, src)
    if not cond then return {} end
    local t = cond:type()
    if t == 'parenthesized_expression' then
        return lua_classify(cond:named_child(0), src)
    elseif t == 'unary_expression' then
        if txt(cond:child(0), src) == 'not' then -- `not X` flips X's polarity
            local inner = lua_classify(cond:named_child(0), src)
            for _, f in ipairs(inner) do f.when = not f.when end
            return inner
        end
        return {}
    elseif t == 'binary_expression' then
        local l, r = cond:named_child(0), cond:named_child(1)
        local op = txt(cond:child(1), src)
        if op == 'and' then -- conjunction: every conjunct holds when cond is true
            local out = lua_classify(l, src)
            for _, f in ipairs(lua_classify(r, src)) do out[#out + 1] = f end
            return out
        elseif op == '==' or op == '~=' then -- x == nil / x ~= nil (either order)
            local var
            if txt(r, src) == 'nil' and l:type() == 'identifier' then var = txt(l, src)
            elseif txt(l, src) == 'nil' and r:type() == 'identifier' then var = txt(r, src) end
            if var then return { { var = var, kind = 'non-nil', when = (op == '~=') } } end
            return {}
        end
        return {} -- `or`, comparisons to non-nil, arithmetic → no narrowing (sound)
    elseif t == 'identifier' then
        return { { var = txt(cond, src), kind = 'non-nil', when = true } } -- `if x`
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

    local points, seenguard = {}, {}
    local function visit(n)
        for c in n:iter_children() do
            if c:named() then
                if c:type() == 'block' then
                    for stmt in c:iter_children() do
                        if stmt:named() and stmt:type() ~= 'comment' then
                            local env = {}
                            for _, g in ipairs(cfg.guards_over(stmt, src)) do
                                for _, f in ipairs(classify(g.cond, src)) do
                                    if f.when == (not g.neg) then
                                        env[f.var] = env[f.var] or f.kind
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
                visit(c)
            end
        end
    end
    visit(fn)
    table.sort(points, function (a, b) return a.line < b.line end)
    local nguards = 0
    for _ in pairs(seenguard) do nguards = nguards + 1 end
    return { lang = lang, points = points, nguards = nguards }
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
    L[#L + 1] = ''
    L[#L + 1] = 'a fact holds only where its guard PROVES it (nil-check / truthiness /'
    L[#L + 1] = 'and-conjunction; `or` and negated compounds do not narrow). Sound knowledge,'
    L[#L + 1] = 'not a guess — feeds redundant-check elimination + null-deref (INC 2/3).'
    return L
end

return M
