-- Nil-flow: a per-function nullability reading for the NULL-DEREF lint
-- ([[cartograph-nil-flow]] N1 first cut, [[cartograph-luanti-corpus]] oracle).
--
-- The luanti null-deref probe found the reverse-guards_over half is READY (it
-- flags an unguarded deref and excludes a guarded one) — the blocker was the
-- nullness SEED: a name-global heuristic marked a pointer nullable across the
-- WHOLE file, so params and unrelated locals sharing the name fired (~50:1 FP).
--
-- The fix here is a PER-DEF seed: a var is maybe-nil only while its LAST
-- assignment was a nullable-RETURN call (`p = m->getBlockNoCreateNoEx(...)`),
-- tracked in tree (statement) order and reset per function. A deref `p->x` is a
-- null-deref candidate iff p is maybe-nil at that point AND is not narrowed to
-- non-nil by a dominating guard — `guards_over` (`if(p)` / `if(!p) return`) OR an
-- `assert(p)` earlier in scope. This scopes nullability to a DEF, not a NAME:
-- a `p` PARAM has no nullable-return def → never a candidate (the FP class gone).
--
-- SOUNDNESS / SCOPE (honest, hedged ~): tree-order tracking is one-pass and not
-- branch-merge precise (a var nulled on one arm and dereffed after the merge is
-- approximated by the last def seen); guards_over gives the precise narrowing that
-- matters. The nullable-return SET is a name heuristic (no declared C++ nullability)
-- — extensible via config. Full CFG-merge + a real nullable-return lattice are the
-- banked refinement (nil-flow N2/N4). Definite findings only; no maybe-tier lint.

local cfg = require 'cartograph.cfg'

local M = {}

-- nullable-RETURN heuristic: a call whose callee tail matches RETURNS a
-- possibly-NULL pointer. Extensible (config.nullable_returns adds names/patterns).
-- The luanti/irrlicht convention is the **NoEx suffix** = "no exception, NULL on
-- miss" — DELIBERATELY NOT bare `NoCreate`: `getBlockNoCreate` (no Ex) THROWS
-- InvalidPositionException (caught by a surrounding try/catch), so its result is
-- non-null where dereferenced — scale-testing on map.cpp caught that as the FP
-- class. `emergeBlock` also returns NULL on failure (callers null-check it).
local DEFAULT_NULLABLE = { 'NoEx$', '^emergeBlock$' }
local function nullable_call(callee, extra)
    for _, pat in ipairs(DEFAULT_NULLABLE) do if callee:find(pat) then return true end end
    for _, pat in ipairs(extra or {}) do if callee:find(pat) then return true end end
    return false
end

-- v appears as a BARE identifier in text (not `v->x` / `v.x`) — the AST-precise
-- guard the memo flagged (substring match false-positives on FIELDS like p->x).
local function bare(v, t)
    local i = 1
    while true do
        local s, e = t:find('%f[%w_]' .. v .. '%f[^%w_]', i)
        if not s then return false end
        local after = t:sub(e + 1):match('^%s*(..?)') or ''
        if after ~= '->' and after:sub(1, 1) ~= '.' then return true end
        i = e + 1
    end
end

-- a condition (paren-peeled) that PROVES `v` non-null on its true branch:
-- `v` alone, or `v != NULL/nullptr/0`. Shared by if-guards and assert().
local function cond_proves_nonnil(v, core)
    return core == v
        or (bare(v, core) and (core:find('!=%s*NULL') or core:find('!=%s*nullptr') or core:find('!=%s*0')))
end

-- does any dominating guard (guards_over) establish `v` non-nil at the deref?
-- neg=false: `if(v)` / `if(v != NULL)`; neg=true (early-exit ¬): `if(!v)` / `if(v==NULL) return`.
local function guarded_nonnil(v, guards, txt)
    for _, g in ipairs(guards) do
        -- a condition may be wrapped in parens (a cpp `condition_clause`, or plain
        -- `(...)`); peel one balanced layer so `(!block)` reads as `!block`.
        local t = txt(g.cond):gsub('%s+', ' ')
        local core = t:match('^%((.*)%)$') or t
        if not g.neg then
            if cond_proves_nonnil(v, core) then return true end
        else
            -- early-exit `if(!v){…return/continue}` / `if(v==NULL){…}`: ¬cond
            -- dominates the deref, so v is non-null after the guard
            if core:match('^!%s*' .. v .. '%f[^%w_]')
                or (bare(v, core) and (core:find(v .. '%s*==%s*NULL')
                    or core:find(v .. '%s*==%s*nullptr') or core:find(v .. '%s*==%s*0'))) then
                return true
            end
        end
    end
    return false
end

-- callee name of a call_expression (the tail member for a method call)
local function callee_of(call, txt)
    local fn = call:field('function')[1]
    if not fn then return nil end
    if fn:type() == 'field_expression' then return txt(fn:field('field')[1]) end
    return txt(fn)
end

--- Null-deref candidates in C++ source `src`. Returns { {fn, line, var, src_line}, … }.
--- `opts.nullable` extends the nullable-return heuristic. Requires the cpp parser.
function M.null_derefs(src, opts)
    local ok, parser = pcall(vim.treesitter.get_string_parser, src, 'cpp')
    if not ok or not parser then return {} end
    local root = parser:parse()[1]:root()
    local function txt(n) return n and vim.treesitter.get_node_text(n, src) or '' end
    local function line1(n) return (select(1, n:range())) + 1 end
    local extra = opts and opts.nullable
    local out = {}

    -- one function body: a tree-order pass tracking per-var nil-state
    -- ('maybe' after a nullable-return def; cleared/non-nil otherwise).
    local function analyze_fn(body, fnname)
        local nilst = {} -- var -> 'maybe' while its last def is a nullable-return
        local function visit(n)
            local t = n:type()
            -- assert(v ...) narrows v non-nil for the rest of the scope
            if t == 'expression_statement' then
                local e = n:child(0)
                if e and e:type() == 'call_expression' and txt(e:field('function')[1]) == 'assert' then
                    -- assert(COND) proves COND on the fall-through → treat like a
                    -- positive guard: `assert(p)` / `assert(p != NULL)` narrow p.
                    local args = e:field('arguments')[1]
                    local at = args and txt(args):gsub('%s+', ' ') or ''
                    local core = at:match('^%((.*)%)$') or at
                    for v in pairs(nilst) do
                        if cond_proves_nonnil(v, core) then nilst[v] = nil end
                    end
                end
            end
            -- a def: `T *v = <call>` (declaration) or `v = <call>` (assignment)
            if t == 'init_declarator' then
                local d, val = n:field('declarator')[1], n:field('value')[1]
                local name
                if d and d:type() == 'pointer_declarator' then
                    local dd = d:field('declarator')[1]
                    if dd and dd:type() == 'identifier' then name = txt(dd) end
                end
                if name then
                    nilst[name] = (val and val:type() == 'call_expression'
                        and nullable_call(callee_of(val, txt) or '', extra)) and 'maybe' or nil
                end
            elseif t == 'assignment_expression' then
                local l, r = n:field('left')[1], n:field('right')[1]
                if l and l:type() == 'identifier' then
                    nilst[txt(l)] = (r and r:type() == 'call_expression'
                        and nullable_call(callee_of(r, txt) or '', extra)) and 'maybe' or nil
                end
            end
            -- a deref: `v->field` on a maybe-nil v, not guarded → candidate
            if t == 'field_expression' and txt(n):find('%->') then
                local arg = n:field('argument')[1]
                if arg and arg:type() == 'identifier' then
                    local v = txt(arg)
                    if nilst[v] == 'maybe'
                        and not guarded_nonnil(v, cfg.guards_over(n, src), txt) then
                        out[#out + 1] = { fn = fnname, line = line1(n), var = v }
                    end
                end
            end
            for c in n:iter_children() do visit(c) end
        end
        visit(body)
    end

    local function walk(n)
        if n:type() == 'function_definition' then
            local body = n:field('body')[1]
            local decl = n:field('declarator')[1]
            if body then analyze_fn(body, decl and txt(decl):match('([%w_:~]+)%s*%(') or '?') end
        end
        for c in n:iter_children() do walk(c) end
    end
    walk(root)
    return out
end

return M
