-- The PYTHON language spec (L0 grammar binding + L1 name model)
-- extracted from the engine ([[cartograph-spec-layering]] P1). Pure motion.

-- @langs python — a spec IS one grammar's mapping, so every node type here is
-- python's by construction.

local tsutil = require 'cartograph.spec.tsutil'
local node_text = tsutil.node_text
local inext = tsutil.inext

-- IS THIS MENTION A WRITE? (CART-0532) The third language to answer, after lua
-- and php — and until it did, python's 913 use edges carried NO `rw`, no `gw`,
-- no `gp` and no `flds`, because all four hang off one `if wmode then` in the
-- reduce. Absence read as `unclassified` rather than as "never written", so
-- nothing lied; the cost was precision (effects keys a write summary per-VAR
-- instead of per-FIELD, so two functions touching different fields of one
-- object read as conflicting).
--
-- Shape follows lua_is_write / php_is_write exactly: walk UP through the
-- member-access wrappers that a write chain may pass through, then ask what the
-- top sits in. EVERY FORM BELOW WAS PARSED, not recalled — python spells its
-- targets with five different node types and two of them are wrappers.
-- MEMO CALLS (CART-1585): `d.setdefault(k, v)` writes d, and only an ABSENT key — set-once by the method's contract.
-- `fn` is the call's callee chain `X.setdefault`, X the receiver.
local PY_MEMO = { setdefault = true }
local function py_memo_call(p, fn, src)
    -- (an attribute whose parent is a call IS its callee: the arguments sit in an argument_list)
    if not (src and p and p:type() == 'call' and fn:type() == 'attribute') then return false end
    local nm = fn:field('attribute')[1]
    return nm ~= nil and PY_MEMO[node_text(nm, src)] == true
end
local function python_is_write(c, n, src)
    local cur, p = c, n
    while p do
        local pt = p:type()
        if pt == 'attribute' then
            -- `o.NAME = v`: object AND field both ride the chain, as in lua's
            -- dot_index_expression and php's member_access_expression
            cur, p = p, p:parent()
        elseif pt == 'subscript' then
            -- `t[k] = v` writes t; the KEY is a read (`t[k]` where c is k)
            if p:named_child(0) ~= cur then return false end
            cur, p = p, p:parent()
        elseif pt == 'pattern_list' or pt == 'tuple_pattern'
            or pt == 'list_pattern' or pt == 'list_splat_pattern' then
            -- destructuring wrappers: `a, b = f()` · `c, *rest = g()`. They are
            -- target-position by construction, so keep climbing.
            cur, p = p, p:parent()
        else
            break
        end
    end
    if not p then return false end
    local pt = p:type()
    -- (the receiver IS the mention: a dynamic key of it, `'[]'` — the capture would name `setdefault` the field)
    if py_memo_call(p, cur, src) then return true, cur:field('object')[1] == c and '[]' or nil, true end -- (and READS: it tests the key)
    if pt == 'assignment' or pt == 'augmented_assignment' then
        -- child 0 is the target; `y: int = 2` inserts a `type` child AFTER it,
        -- so the index is stable across the annotated form
        return p:named_child(0) == cur
    elseif pt == 'named_expression' then -- the walrus, `w := h()`
        return p:named_child(0) == cur
    elseif pt == 'for_statement' then
        -- the loop target is a write to the name: at module level it rebinds a
        -- global. The ITERATED expression is child 1 and stays a read.
        return p:named_child(0) == cur
    elseif pt == 'as_pattern_target' then -- `with open(p) as fh`
        return true
    elseif pt == 'delete_statement' then  -- `del x` / `del t[k]`
        return true
    end
    return false
end

-- ── THE GUARD GRAMMAR (CART-1574) ─────────────────────────────────────────────────────────────────────────────────
-- What providers/treesitter.lua guard_class needs to call a write GUARDED or SET-ONCE. python's memo spellings:
-- `if x is None: x = …`, `if not x: x = …`, `if k not in cache: cache[k] = …` — a MEMBERSHIP test, whose chain
-- `cache[k]` is never spelled in the condition, so it is rebuilt from the operands —, the else arm of `if x:` /
-- `if x is not None:` / `if k in cache:`, and `x = x or v` (the `or` caveat of lua's idiom: a stored falsy value is
-- overwritten).
local chain_eq, optext_is, unparen = tsutil.chain_eq, tsutil.optext_is, tsutil.unparen
-- is `n` (a comparison) `L <op> R` with R the absence literal None -> L, or `L <op> None`?
local function py_against_none(n, ops)
    if n:type() ~= 'comparison_operator' or not optext_is(n, nil, ops) or n:named_child_count() ~= 2 then return nil end
    local a, b = unparen(n:named_child(0)), unparen(n:named_child(1))
    if b and b:type() == 'none' then return a end
    if a and a:type() == 'none' then return b end
    return nil
end
-- `k <op> c` (`in` / `not in`) whose subscript `c[k]` is the written chain
local function py_member_chain(n, ops, src, chain)
    if n:type() ~= 'comparison_operator' or not optext_is(n, nil, ops) or n:named_child_count() ~= 2 then return false end
    local k, c = n:named_child(0), n:named_child(1)
    return chain == node_text(c, src) .. '[' .. node_text(k, src) .. ']'
end
local PY_GUARDS = {
    cond = { if_statement = true, elif_clause = true, while_statement = true },
    else_t = 'else_clause', elseif_t = 'elif_clause',
    fn = { function_definition = true, lambda = true },
    binop = 'boolean_operator', andops = { ['and'] = true },
    negop = 'not_operator', negtok = 'not', pfield = 'parameters',
    pw_refsem = true, -- objects are reference-typed: a store into a param mutates the caller's
    abs_test = function (n, src, chain)
        local t = n:type()
        if t == 'not_operator' then
            local x = unparen(n:named_child(0))
            return x ~= nil and chain_eq(x, src, chain)
        end
        local x = py_against_none(n, { ['is'] = true, ['=='] = true })
        if x then return chain_eq(x, src, chain) end
        return py_member_chain(n, { ['not in'] = true }, src, chain)
    end,
    presence = function (cond, src, chain)
        cond = unparen(cond)
        if cond == nil then return false end
        if chain_eq(cond, src, chain) then return true end
        local x = py_against_none(cond, { ['is not'] = true, ['!='] = true })
        if x then return chain_eq(x, src, chain) end
        return py_member_chain(cond, { ['in'] = true }, src, chain)
    end,
    -- `x = x or v`, and the memo call `d.setdefault(k, v)` (CART-1585)
    rhs_setonce = function (top, src, chain)
        local p = top:parent()
        if py_memo_call(p, top, src) then return true end
        if not (p and p:type() == 'assignment' and p:field('left')[1] == top) then return false end
        local rhs = unparen(p:field('right')[1])
        if not (rhs and rhs:type() == 'boolean_operator' and optext_is(rhs, src, { ['or'] = true })) then return false end
        local l = unparen(rhs:named_child(0))
        return l ~= nil and chain_eq(l, src, chain())
    end,
}

-- ── LEXICAL SCOPES (CART-1597) ────────────────────────────────────────────────────────────────────────────────────
-- python declared no scope model, so no mention was ever MF_BOUND and the cross-file unique join claimed every local:
-- community.general's RedfishUtils.get_logs read its own `_data` as _django.py's module var. A function's scope is
-- python's: its params AND every name its body assigns ANYWHERE (`x = …`, `x += …`, a for / with / except target, a
-- walrus) — function-wide, whatever the row —, minus `global` / `nonlocal` names; a nested def / class / lambda /
-- comprehension is its own scope. Module level binds nothing: an assignment there IS the module var. An `import`
-- inside a function stays free (the require exemption, CART-1594: the join gets that one right).
local PY_OWN_SCOPE = { function_definition = true, class_definition = true, lambda = true,
    list_comprehension = true, set_comprehension = true, dictionary_comprehension = true, generator_expression = true }
local function py_target_names(t, src, out)
    if not t then return end
    local ty = t:type()
    if ty == 'identifier' then out[node_text(t, src)] = {}
    elseif ty == 'pattern_list' or ty == 'tuple_pattern' or ty == 'list_pattern' or ty == 'list_splat_pattern'
        or ty == 'dictionary_splat_pattern' or ty == 'as_pattern_target' then
        for _, c in inext, t, -1 do if c:named() then py_target_names(c, src, out) end end
    end -- (an attribute / subscript target binds nothing: it stores into an object)
end
local function py_params(node, src, out)
    local ps = node:field('parameters')[1]
    if not ps then return end
    for _, c in inext, ps, -1 do
        local t = c:type()
        if t == 'identifier' then out[node_text(c, src)] = {}
        elseif t == 'default_parameter' or t == 'typed_default_parameter' then py_target_names(c:field('name')[1], src, out)
        elseif t == 'typed_parameter' then py_target_names(c:named_child(0), src, out) -- (`x: T`, `*a: T`)
        elseif t == 'list_splat_pattern' or t == 'dictionary_splat_pattern' then py_target_names(c, src, out)
        end
    end
end
local function py_fn_scope(node, src, out)
    py_params(node, src, out)
    if node:type() == 'lambda' then return end
    local glob = {}
    local function walk(n)
        for _, c in inext, n, -1 do
            local t = c:type()
            if PY_OWN_SCOPE[t] then
                -- (a nested `def g():` binds g here too, but mints g as a same-file def: the name is never the
                -- cross-file unique, so binding it would change nothing — and it IS the function an argument names)
            else
                if t == 'assignment' or t == 'augmented_assignment' or t == 'for_statement' then
                    py_target_names(c:field('left')[1], src, out)
                elseif t == 'as_pattern_target' then py_target_names(c, src, out)
                elseif t == 'named_expression' then py_target_names(c:field('name')[1], src, out)
                elseif t == 'global_statement' or t == 'nonlocal_statement' then
                    for _, g in inext, c, -1 do if g:type() == 'identifier' then glob[node_text(g, src)] = true end end
                end
                walk(c)
            end
        end
    end
    walk(node:field('body')[1] or node)
    for g in pairs(glob) do out[g] = nil end
end
local function py_comp_scope(node, src, out) -- `[k for k in xs]`: the for_in_clause targets
    for _, c in inext, node, -1 do
        if c:type() == 'for_in_clause' then py_target_names(c:field('left')[1], src, out) end
    end
end
local PY_LEXICAL_SCOPES = {
    function_definition = { kind = 'param', harvest = py_fn_scope }, lambda = { kind = 'param', harvest = py_fn_scope },
    list_comprehension = { kind = 'local', harvest = py_comp_scope }, set_comprehension = { kind = 'local', harvest = py_comp_scope },
    dictionary_comprehension = { kind = 'local', harvest = py_comp_scope },
    generator_expression = { kind = 'local', harvest = py_comp_scope },
}

return {
    lexical_scopes = PY_LEXICAL_SCOPES, -- CART-1597
    -- the call-argument gate's local binders (fn.locals): the same scope — df tracks only a plain `x = …` (CART-1597)
    fn_locals = py_fn_scope,
    guards = PY_GUARDS,
    -- INDEX POSITIONS (CART-0533): parent node type -> the child holding the
    -- OBJECT of a BRACKET-style access. Separate from `member_positions` because
    -- the two answer different questions: a member name is a NAME (and must not
    -- be matched against the bare-name function index), while a bracket key is an
    -- EXPRESSION and the mention inside it is a genuine value read.
    -- ★ TEN LANGUAGES SPELL ONE CONCEPT SIX WAYS — array / operand / object /
    -- value / argument / bare child 0 — which is why this is declared and not
    -- hardcoded. It was hardcoded, and java's `array_access` was absent, so
    -- `atanTab[i] = v` against `private static final double[] atanTab` recorded a
    -- WHOLE-VAR write: a claimed REBIND of a `final` field, which is a compile
    -- error. 47 of those in libs alone.
    index_positions = {
        subscript = 'value', -- t[k]
    },
    is_write = python_is_write,
    -- ★ THE PREFILTER `is_write` IS USELESS WITHOUT. collect_mentions computes
    -- `wgate and wgate[nt] and is_write(c, n)`, so a spec that declares the
    -- classifier and NOT the gate never calls it: every mention classifies as a
    -- READ, and `wmode` is still true — which means atlas mints `const` over a
    -- write detection that never ran. Every IMMEDIATE PARENT type a write
    -- mention can have must be listed here; the classifier does the rest.
    write_gate = { assignment = true, augmented_assignment = true,
        attribute = true, subscript = true, pattern_list = true,
        tuple_pattern = true, list_pattern = true, list_splat_pattern = true,
        for_statement = true, as_pattern_target = true,
        delete_statement = true, named_expression = true },
    -- MEMBER-NAME POSITIONS (CART-0529): parent node type -> the child holding a
    -- MEMBER NAME, i.e. a name that is reached THROUGH A RECEIVER. Same shape as
    -- `call_positions`, and read for the opposite purpose: a mention here must
    -- NOT be matched against the corpus-wide unique-function index, because a
    -- bare name match says nothing about which object the receiver holds.
    -- Measured on wow_addons: 724 of 2988 reg occurrences (24.2%) sat in member
    -- position, and the sample held outright cross-file fabrication
    -- (`db.ResetProfile = DBObjectLib.ResetProfile` pointing at an unrelated
    -- addon's local ResetProfile).
    -- ★ BRACKET FORMS ARE DELIBERATELY ABSENT (`t[k]`, `t["k"]`, subscript_*):
    -- their key is an EXPRESSION, so the mention inside is a genuine value read
    -- and vetoing it would lose a real reference. Only dot-style member NAMES
    -- belong here.
    member_positions = {
        attribute = 1, -- o.NAME -- child 1, no field
    },
    -- CALL POSITIONS (CART-0499): parent node type -> which child holds the
    -- CALLEE NAME, as a field name or a named-child index. Replaces a
    -- hardcoded four-name or-chain inline in the provider that php, java,
    -- bash, rust macros, ruby and haskell were all missing from -- so a call
    -- to a corpus-unique function became a fn REFERENCE and minted a `reg`
    -- edge ("kept alive by top-level DATA"), a different fact. 96.6% of
    -- mantisbt's reg occurrences were mislabelled calls.
    call_positions = {
        call = 'function', -- foo(1)
    },
        exts = { 'py' },
        functions = [[ (function_definition name: (identifier) @name) @def ]],
        calls = [[ (call function: (_) @name) @call ]],
        vars = [[
            (module (expression_statement
                (assignment left: (identifier) @vname right: (_) @value) @vdef))
        ]],
        params_field = 'parameters',
        body_field = 'body',
        fn_types = { function_definition = true, lambda = true },
        -- ── DYNAMIC DISPATCH: THE MEMBER IS RUNTIME STATE (CART-0345/0344) ──
        -- `d[k]()` selects its callee at run time — the `dynamic` rung, "a call the
        -- graph KNOWS IT CANNOT SEE", which is a different fact from `frontier`
        -- ("we failed to resolve"). Undeclared here until now, so every such call
        -- landed in frontier and any measurement of dynamic dispatch on a python
        -- corpus would have reported it as absent.
        -- ★ A LITERAL KEY IS NOT DYNAMIC: `d["lit"]()` names its member in
        -- the source, and claiming we cannot see it would be a false negative
        -- FACT. Node names verified by parsing a snippet per grammar, not guessed.
        dynamic_callee_types = { subscript = true },
        dynamic_callee_static_key = { string = true, integer = true, float = true },
        -- `lambda` encloses, but the `functions` query mints only
        -- function_definition — so it is not a sound flow stop (CART-0308).
        fn_unminted = { lambda = true },
        is_method = function (_, def)
            local p = def:parent()
            while p do
                if p:type() == 'class_definition' then return true end
                p = p:parent()
            end
            return false
        end,
        -- methods carry their class (Product.save): without this, the ONE
        -- project method named `all`/`create` reads as globally unique and
        -- absorbs every ORM `.all()`/`.create()` in the codebase
        qualify = function (name, defn, src)
            local p = defn:parent()
            while p do
                if p:type() == 'class_definition' then
                    local cn = p:field('name')[1]
                    return cn and (node_text(cn, src)
                        .. '.' .. name) or name
                end
                p = p:parent()
            end
            return name
        end,
        -- a function whose decorator is a CALL (@receiver(signal),
        -- @register.filter(...)) is passed INTO something: registered,
        -- framework-dispatched, not dead. Plain decorators (@property,
        -- @staticmethod) wrap without registering — they don't count.
        cbarg_def = function (defn, _)
            local p = defn:parent()
            if p and p:type() == 'decorated_definition' then
                for _, c in inext, p, -1 do
                    if c:type() == 'decorator' then
                        local inner = c:named_child(0)
                        if inner and inner:type() == 'call' then return true end
                    end
                end
            end
            return false
        end,
        -- python/Django vocabulary: stdlib builtins, dunder protocol, dict/
        -- list/str methods, ORM queryset verbs — a project def with one of
        -- these names must never absorb the language's own calls
        stdlib_names = { get = true, all = true, filter = true, exclude = true,
            create = true, save = true, delete = true, count = true,
            first = true, last = true, exists = true, update = true,
            values = true, values_list = true, url = true, data = true,
            items = true, keys = true, append = true, extend = true,
            insert = true, remove = true, pop = true, sort = true,
            format = true, join = true, split = true, strip = true,
            replace = true, startswith = true, endswith = true,
            lower = true, upper = true, encode = true, decode = true,
            read = true, write = true, close = true, open = true,
            len = true, print = true, range = true, isinstance = true,
            super = true, getattr = true, setattr = true, hasattr = true,
            type = true, str = true, int = true, float = true, bool = true,
            list = true, dict = true, set = true, tuple = true, next = true,
            iter = true, sorted = true, reversed = true, enumerate = true,
            zip = true, map = true, sum = true, min = true, max = true,
            abs = true, repr = true, hash = true, copy = true, add = true,
            -- logging/messages vocabulary (logger.info, messages.success)
            debug = true, info = true, warning = true, error = true,
            critical = true, exception = true, success = true },
        resolve_import = function (mod, files)
            local slashed = mod:gsub('%.', '/')
            for _, cand in ipairs({ slashed .. '.py', slashed .. '/__init__.py' }) do
                if files[cand] then return cand end
            end
        end,
        litdata_types = { dictionary = true, list = true },
}
