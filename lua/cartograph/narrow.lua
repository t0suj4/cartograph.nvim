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

-- is `name` BOUND (a param or a local/assignment target) anywhere in the fn? A `type`
-- bound here SHADOWS the global builtin, so `type(x)` is not the real type() and its
-- type-test narrowing would be unsound — the gate below drops those facts. Conservative:
-- a shadow anywhere (even a sibling scope) disables type narrowing for the whole fn.
local function binds(store_node, name)
    local fl = store_node and flowmod.present(store_node) and flowmod.record(store_node)
    if not fl then return false end
    for _, p in ipairs(fl.params or {}) do if p == name then return true end end
    for _, s in ipairs(fl.stmts or {}) do for _, d in ipairs(s.def or {}) do if d == name then return true end end end
    return false
end

-- wrap the raw classifier so TYPE-test facts are dropped when `type` is shadowed in the
-- fn (they bubble up to the flat result list, so filtering the top level catches all
-- nesting depths). nil/truthy facts are untouched. Returns the raw classifier unchanged
-- when type is the genuine global.
local function gated_classify(raw, type_shadowed)
    if not type_shadowed then return raw end
    return function (cond, src, holds)
        local out = {}
        for _, f in ipairs(raw(cond, src, holds)) do
            if not f.kind:match('^type:') then out[#out + 1] = f end
        end
        return out
    end
end

-- ── per-language guard vocabulary ────────────────────────────────────────────
-- vocab[lang](cond, src, holds) -> { {var, kind}, ... } = the facts that MUST hold
-- given the condition evaluates to `holds` (true for positive nesting, false for a
-- passed early-exit). Polarity is pushed THROUGH the connectives (De Morgan) rather
-- than flipped per-fact, so a conjunction under negation (`if not a and b then
-- return` → after, ¬(a∧b) proves NOTHING) is sound. kind: 'truthy' (from `if x` —
-- non-nil AND non-false) or 'non-nil' (from x~=nil); truthy ⟹ non-nil.
local vocab = {}

-- `type(x)` over a single identifier → x's name, else nil (the type-test devirt seed)
local function type_call_var(n, src)
    if not n or n:type() ~= 'function_call' then return nil end
    local callee = n:named_child(0)
    if not (callee and callee:type() == 'identifier' and txt(callee, src) == 'type') then return nil end
    local args = n:field('arguments')[1]
    local arg = args and args:named_child(0)
    if arg and arg:type() == 'identifier' and not args:named_child(1) then return txt(arg, src) end
    return nil
end
-- the content of a string literal (quotes stripped), else nil
local function str_lit(n, src)
    if not n or n:type() ~= 'string' then return nil end
    return (txt(n, src):match('^["\'](.-)["\']$'))
end

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
            -- TYPE-TEST (narrow v2, devirt seed): type(x) == 'T' / ~= 'T' (either order).
            -- Sound like var narrowing — a call can't change a local's type, only reassignment
            -- (mutated_of kills it). Positive only: x IS T when (== & holds) or (~= & ¬holds).
            local tv = type_call_var(l, src) and str_lit(r, src) and { type_call_var(l, src), str_lit(r, src) }
                or (type_call_var(r, src) and str_lit(l, src) and { type_call_var(r, src), str_lit(l, src) })
            if tv and ((op == '==') == holds) then return { { var = tv[1], kind = 'type:' .. tv[2] } } end
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
    local classify = gated_classify(vocab[lang], binds(node, 'type'))
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
                                        -- nil/truthy collapse to 'non-nil' (the sound floor);
                                        -- a TYPE fact (devirt seed) is preserved as 'type:T'
                                        env[f.var] = f.kind:match('^type:') and f.kind or 'non-nil'
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
                local cur = env[f.var]
                -- STRONGEST wins: type:T ⊐ truthy ⊐ non-nil (a type proves both)
                if f.kind:match('^type:') then env[f.var] = f.kind
                elseif f.kind == 'truthy' and not (cur and cur:match('^type:')) then env[f.var] = 'truthy'
                elseif not cur then env[f.var] = 'non-nil' end
            end
        end
    end
    return env
end

-- env-fact interrogation: a TYPE fact implies non-nil (type(nil)=='nil'), and truthy for
-- every type except boolean (false is truthy-negative) and nil.
local function env_type(env, v) local e = env[v]; return e and e:match('^type:(.+)$') end
local function env_nonnil(env, v)
    local e = env[v]
    return e == 'truthy' or e == 'non-nil' or (env_type(env, v) and env_type(env, v) ~= 'nil') or false
end
local function env_truthy(env, v)
    if env[v] == 'truthy' then return true end
    local ty = env_type(env, v)
    return ty ~= nil and ty ~= 'boolean' and ty ~= 'nil'
end

-- is a SIMPLE condition already DETERMINED by `env`? → 'always-true' (tautology,
-- then-branch always taken) | 'dead' (contradiction, then-branch dead) | nil.
-- `if x` needs TRUTHY; `x~=nil`/`x==nil` need non-nil; `not x` dead under truthy; a
-- type-test is determined by a proven TYPE fact (redundant re-test / contradiction).
local function determine(cond, src, env)
    local t = cond:type()
    if t == 'parenthesized_expression' then return determine(cond:named_child(0), src, env) end
    if t == 'identifier' then
        if env_truthy(env, txt(cond, src)) then return 'always-true' end
        return nil
    end
    if t == 'unary_expression' and txt(cond:child(0), src) == 'not' then
        local inner = cond:named_child(0)
        if inner and inner:type() == 'identifier' and env_truthy(env, txt(inner, src)) then
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
        if var and env_nonnil(env, var) then
            if op == '~=' then return 'always-true' end -- x~=nil, x known non-nil
            if op == '==' then return 'dead' end        -- x==nil, x known non-nil
        end
        -- type-test determined by a proven type fact
        if op == '==' or op == '~=' then
            local tv = type_call_var(l, src) and str_lit(r, src) and { type_call_var(l, src), str_lit(r, src) }
                or (type_call_var(r, src) and str_lit(l, src) and { type_call_var(r, src), str_lit(l, src) })
            local known = tv and env_type(env, tv[1])
            if known then
                local same = (known == tv[2])
                if op == '==' then return same and 'always-true' or 'dead' end
                return same and 'dead' or 'always-true' -- ~=
            end
        end
    end
    return nil
end

-- ── parameter-nilability ([[cartograph-expression-layer]] Rung 2) ────────────
-- a nil-UNSAFE dereference of a parameter at node `n` → the param name, else nil. In
-- Lua these all ERROR on nil: p.x / p[i] / p:m() / p() / #p / arithmetic|concat on p.
local DEREF_INDEX = { dot_index_expression = true, bracket_index_expression = true,
    method_index_expression = true }
local ARITH = { ['+'] = true, ['-'] = true, ['*'] = true, ['/'] = true,
    ['%'] = true, ['^'] = true, ['..'] = true, ['//'] = true }
-- returns the list of parameter names dereffed at `n` (arithmetic touches BOTH operands)
local function param_derefs(n, src, params)
    local out, t = {}, n:type()
    local function add(o)
        if o and o:type() == 'identifier' and params[txt(o, src)] then out[#out + 1] = txt(o, src) end
    end
    if DEREF_INDEX[t] then add(n:named_child(0))
    elseif t == 'function_call' then add(n:named_child(0))
    elseif t == 'unary_expression' then
        if txt(n:child(0), src) == '#' then add(n:named_child(0)) end
    elseif t == 'binary_expression' then
        if ARITH[txt(n:child(1), src)] then add(n:named_child(0)); add(n:named_child(1)) end
    end
    return out
end

-- the LuaCATS `---@param` annotations in the doc block directly above the fn's
-- top-level statement → { [name] = 'optional' | 'non-nil' }. Optional = `name?`,
-- a `?`-suffixed type, or a `nil` union member (what lua-ls treats as nilable).
-- optionality of a `---@param` TYPE (the text after `name[?] `): 'optional' /
-- 'non-nil' when CONFIDENT, else nil = "don't compare" (a complex table/fun type we
-- won't risk mis-reading — the oracle must never false-conflict on a parser guess).
local function ann_optional(rest)
    rest = vim.trim(rest or '')
    local tok = rest:match('^(%S+)') -- the first token = a SIMPLE type, or the start of a complex one
    if not tok then return nil end
    if tok:match('^[{(]') or tok == 'fun' then return nil end -- `{…}` / `fun(…)` → unsure
    if tok:match('%?$') then return 'optional' end
    if ('|' .. tok .. '|'):match('|nil|') then return 'optional' end -- a nil union member
    if tok:match('^[%w_%.%[%]|]+$') then return 'non-nil' end -- a clean plain type
    return nil
end
local STMT_PARENT = { block = true, chunk = true }
local function param_annotations(fn, src)
    local s = fn
    while s:parent() and not STMT_PARENT[s:parent():type()] do s = s:parent() end
    local ann, block = {}, {}
    local sib = s:prev_named_sibling()
    while sib and sib:type() == 'comment' do block[#block + 1] = txt(sib, src); sib = sib:prev_named_sibling() end
    for _, line in ipairs(block) do
        local name, opt, rest = line:match('^%s*%-%-%-?@param%s+([%w_]+)(%??)%s*(.*)$')
        if name then
            local a = opt == '?' and 'optional' or ann_optional(rest)
            if a then ann[name] = a end -- nil (unsure) → leave unset, no comparison
        end
    end
    return ann
end

--- PARAMETER-NILABILITY inference (Rung 2, the lua-ls DISAGREEMENT ORACLE). For each
--- parameter, infer whether the body REQUIRES it non-nil (an unguarded nil-unsafe
--- deref, or an `assert`), TOLERATES nil (every deref guarded / short-circuited /
--- nil-tested), or is UNCONSTRAINED. Sound-first: a deref is protected by a dominating
--- guard (env_of/guards_over — incl. early-exit), an enclosing short-circuit
--- (`p and p.x`, `p ~= nil and …`), or an assert; a REASSIGNED param (`p = p or {}`)
--- is left unconstrained (conservative). Compared against the `---@param` annotation:
--- inferred REQUIRED + annotated OPTIONAL (`?`) = a real defect (the body crashes on a
--- nil the type permits) — the keystone disagreement.
--- @return table { lang, unsupported?, params: { {name, verdict, site?, annotated?, conflict?} } }
function M.param_nilability(store, fn_id)
    local node = store.node and store.node(fn_id)
    if not node or not node.file then return { params = {} } end
    local lang = EXT_LANG[node.file:match('%.(%w+)$') or '']
    if not lang or not vocab[lang] then
        return { lang = node.file:match('%.(%w+)$'), unsupported = true, params = {} }
    end
    local src = table.concat(store.content(node) or {}, '\n')
    local fn = fn_node(node, src, lang)
    if not fn then return { lang = lang, params = {} } end
    local classify, mutated = gated_classify(vocab[lang], binds(node, 'type')), mutated_of(node)
    local fl = flowmod.present(node) and flowmod.record(node)
    local plist = (fl and fl.params) or {}
    local params = {}
    for _, p in ipairs(plist) do if p ~= 'self' then params[p] = true end end
    if not next(params) then return { lang = lang, params = {} } end

    local unguarded, asserted, tested = {}, {}, {}
    local function note_tested(cond)
        for _, f in ipairs(classify(cond, src, true)) do tested[f.var] = true end
        for _, f in ipairs(classify(cond, src, false)) do tested[f.var] = true end
    end
    local CONDN = { if_statement = true, elseif_statement = true, while_statement = true,
        repeat_statement = true }
    local function walk(n, proven)
        local t = n:type()
        if t == 'function_call' then -- assert(cond) proves its conjuncts non-nil
            local callee = n:named_child(0)
            if callee and callee:type() == 'identifier' and txt(callee, src) == 'assert' then
                local args = n:field('arguments')[1]
                local cond = args and args:named_child(0)
                if cond then for _, f in ipairs(classify(cond, src, true)) do
                    asserted[f.var] = true; tested[f.var] = true
                end end
            end
        end
        if CONDN[t] then local c = n:field('condition')[1]; if c then note_tested(c) end end
        for _, p in ipairs(param_derefs(n, src, params)) do
            if not proven[p] and not env_of(n, src, classify, mutated)[p] then
                unguarded[p] = unguarded[p] or (n:start() + 1)
            end
        end
        if t == 'binary_expression' then
            local op = txt(n:child(1), src)
            local l, r = n:named_child(0), n:named_child(1)
            if (op == 'and' or op == 'or') and l and r then
                walk(l, proven)
                local p2 = {}; for k in pairs(proven) do p2[k] = true end
                for _, f in ipairs(classify(l, src, op == 'and')) do p2[f.var] = true; tested[f.var] = true end
                walk(r, p2)
                return
            end
        end
        for c in n:iter_children() do
            if c:named() and not FN_TYPES[c:type()] then walk(c, proven) end
        end
    end
    walk(fn, {})

    local ann = param_annotations(fn, src)
    local out = {}
    for _, p in ipairs(plist) do
        if p ~= 'self' then
            -- REQUIRED is HIGH-CONFIDENCE (the oracle must be trustworthy): either an
            -- `assert`, or an unguarded deref of a param that is NEVER nil-tested
            -- anywhere in the body — if the author checks it even once they are
            -- nil-aware (a correlated guard through an intermediate we can't track →
            -- optional), so a nil-tested param is never called required. Conservative:
            -- under-infers required, never false-flags a defended param.
            local verdict, site
            if mutated[p] then verdict = 'unknown'
            elseif asserted[p] then verdict = 'required'
            elseif unguarded[p] and not tested[p] then verdict, site = 'required', unguarded[p]
            elseif tested[p] or unguarded[p] then verdict = 'optional'
            else verdict = 'unknown' end
            local a = ann[p]
            local conflict = (verdict == 'required' and a == 'optional')
                or (verdict == 'optional' and a == 'non-nil')
            out[#out + 1] = { name = p, verdict = verdict, site = site, annotated = a,
                conflict = conflict or nil }
        end
    end
    return { lang = lang, params = out }
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
    local classify = gated_classify(vocab[lang], binds(node, 'type'))
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
        for var, kind in pairs(p.env) do
            facts[#facts + 1] = ('%s: %s'):format(var, (kind:gsub('^type:', 'is ')))
        end
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

--- The lens surface (:CartographParamNil): the focused fn's inferred parameter
--- nilability contracts, and any DISAGREEMENT with the `---@param` annotations.
function M.param_report(store, fn_id)
    local node = store.node and store.node(fn_id)
    if not node then return { 'param-nil: no such node' } end
    local res = M.param_nilability(store, fn_id)
    if res.unsupported then
        return { ('param-nil: %s not yet supported (Lua only)'):format(res.lang or '?') }
    end
    if #res.params == 0 then
        return { ('param-nil: %s — no parameters'):format(node.name or fn_id) }
    end
    local L = { ('param-nil: %s — inferred parameter nilability'):format(node.name or fn_id), '' }
    local nconf = 0
    for _, p in ipairs(res.params) do
        local mark = p.conflict and '⚠' or ' '
        if p.conflict then nconf = nconf + 1 end
        local ann = p.annotated and (' [@param: ' .. p.annotated .. ']') or ''
        local site = p.site and (' — deref @L' .. p.site) or ''
        L[#L + 1] = ('  %s %-16s %-10s%s%s'):format(mark, p.name, p.verdict, ann, site)
    end
    L[#L + 1] = ''
    if nconf > 0 then
        L[#L + 1] = ('⚠ %d DISAGREEMENT(S) with the annotations — inferred non-nil-required vs'):format(nconf)
        L[#L + 1] = '  a nilable `?` param (the body derefs a nil the type permits), or the'
        L[#L + 1] = '  reverse (a defended param the type forbids nil for). A real defect on one side.'
    else
        L[#L + 1] = '(required = an unguarded deref / assert assumes non-nil; optional = every'
        L[#L + 1] = ' deref is guarded / short-circuited; unknown = never dereferenced, or reassigned.'
        L[#L + 1] = ' Where a `---@param` annotation exists, a mismatch is flagged ⚠.)'
    end
    return L
end

return M
