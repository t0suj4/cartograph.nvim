-- The PHP language spec + its base helpers, extracted via the move-set flow
-- ([[cartograph-spec-layering]]). close_moveset({php_is_write, PHP_GUARDS,
-- PHP_BASENAMES}) → exactly those three (ordered by source line); the guard
-- substrate (chain_eq/optext_is/unparen) is SHARED with lua's GUARDS so it was
-- relocated into spec/tsutil.lua rather than pulled in here — both this module
-- and the engine require it from there. node_text/inext are the other shared
-- deps. Pure motion; behaviour-identical.

-- @langs php — a spec IS one grammar's mapping, so every node type here is
-- php's by construction.

local tsutil = require 'cartograph.spec.tsutil'
local node_text = tsutil.node_text
local inext = tsutil.inext
local chain_eq = tsutil.chain_eq
local optext_is = tsutil.optext_is
local unparen = tsutil.unparen

-- php PSR-4 suffix imports: basename -> {files} index, memoized per
-- fileset (weak keys: dies with the fileset, workers build their own)
local PHP_BASENAMES = setmetatable({}, { __mode = 'k' })

-- ── CLASS NAMES BY PHP'S OWN RULES (CART-0735) ───────────────────────────────────────────────────────────────────
-- A definition key is a BARE class name (`Request::m`), so a qualified call bound to whichever project class carries
-- that short name: `new Request()` reached Sylius\Behat\Client\Request while the file says `use Symfony\Component\
-- HttpFoundation\Request` (4.1% of sylius's resolved `new`, 25 of them a vendor class). PHP decides a class name from
-- the CALLING file: a leading `\` is literal; an unqualified name goes through the file's `use` aliases, else the
-- file's namespace (no global fallback for classes); a qualified `A\B` resolves its first segment the same way.
-- `use function` / `use const` bind no class; a group `use A\{B, C as D}` binds each member. A file with several
-- namespaces, or a braced one, is not read (`multi`): its names are not decided.
local function php_class_names(root, src)
    local ns, nsn, braced, alias, traits = '', 0, false, {}, nil
    for _, c in inext, root, -1 do
        local t = c:type()
        -- (EXTRA SUPERTYPES, as written: a class's or trait's TRAIT uses — `use Helps;` in its body, whose methods are the
        -- class's — and an INTERFACE's parents — `interface I extends J, K` — CART-1967. The class veto walks them like
        -- a supertype. Not data.extends: build_super reads a second parent there as a name collision and drops the
        -- class's whole chain)
        if t == 'interface_declaration' then
            local nm = c:field('name')[1]
            for _, k in inext, c, -1 do
                if nm and k:type() == 'base_clause' then
                    for _, u in inext, k, -1 do
                        local ut = u:type()
                        if ut == 'name' or ut == 'qualified_name' then
                            traits = traits or {}
                            local key = node_text(nm, src):lower()
                            local l = traits[key]; if not l then l = {}; traits[key] = l end
                            l[#l + 1] = node_text(u, src)
                        end
                    end
                end
            end
        end
        if t == 'class_declaration' or t == 'trait_declaration' then
            local nm, body = c:field('name')[1], c:field('body')[1]
            if nm and body then
                for _, d in inext, body, -1 do
                    if d:type() == 'use_declaration' then
                        for _, u in inext, d, -1 do
                            local ut = u:type()
                            if ut == 'name' or ut == 'qualified_name' then
                                traits = traits or {}
                                local k = node_text(nm, src):lower()
                                local l = traits[k]; if not l then l = {}; traits[k] = l end
                                l[#l + 1] = node_text(u, src)
                            end
                        end
                    end
                end
            end
        end
        if t == 'namespace_definition' then
            nsn = nsn + 1
            if c:field('body')[1] then braced = true end
            local nm = c:field('name')[1]
            ns = nm and node_text(nm, src) or ''
        elseif t == 'namespace_use_declaration' then
            do -- (`use function` / `use const`: the keyword is a child of each CLAUSE, which clause() refuses)
                local prefix = ''
                for _, k in inext, c, -1 do
                    if k:type() == 'namespace_name' then prefix = node_text(k, src) .. '\\' end
                end
                local function clause(cl)
                    local al, q = cl:field('alias')[1], nil
                    for _, k in inext, cl, -1 do
                        local kt = k:type()
                        if not k:named() and (kt == 'function' or kt == 'const') then return end
                        if (kt == 'qualified_name' or kt == 'name') and not (al and k:equal(al)) then q = q or k end
                    end
                    if not q then return end
                    local full = (prefix .. node_text(q, src)):gsub('^\\', '')
                    local short = al and node_text(al, src) or full:match('([^\\]+)$')
                    if short then alias[short:lower()] = full end
                end
                for _, k in inext, c, -1 do
                    if k:type() == 'namespace_use_clause' then clause(k)
                    elseif k:type() == 'namespace_use_group' then
                        for _, g in inext, k, -1 do if g:type() == 'namespace_use_clause' then clause(g) end end
                    end
                end
            end
        end
    end
    if nsn > 1 or braced then return { multi = true } end
    return { ns = ns, alias = alias, traits = traits }
end
-- the fully qualified name of class `cls` (as written) seen from a file whose names are `cn`; nil when undecided
local function php_class_fqcn(cls, cn)
    if not (cls and cn) or cn.multi then return nil end
    if cls:sub(1, 1) == '\\' then return cls:sub(2) end
    local pre = (cn.ns or '') ~= '' and (cn.ns .. '\\') or ''
    local first, rest = cls:match('^([^\\]+)\\(.+)$')
    if first then
        local a = cn.alias[first:lower()]
        return a and (a .. '\\' .. rest) or (pre .. cls)
    end
    return cn.alias[cls:lower()] or (pre .. cls)
end

-- the KEY's class for a name as written: the last segment of its FQCN — an ALIAS (`use A\\Thing as T`) names Thing,
-- whose definition key is `Thing::m`, not `T::m`. The file's names are read once per source (the calls of one file
-- are qualified in a row)
local CN_SRC, CN_VAL
local function php_key_class(node, src, written)
    if CN_SRC ~= src then CN_SRC, CN_VAL = src, php_class_names(node:tree():root(), src) end
    local fq = php_class_fqcn(written, CN_VAL)
    return ((fq or written):match('[^\\]+$')) or written
end

-- the class a self / parent form names from `node`: (bare key name, the name as written) — the enclosing class / trait
-- / interface for 'self', the class its base_clause names for 'parent'; nil when there is none
local function php_enclosing(node, src, kind)
    local p2 = node:parent()
    while p2 do
        local tt = p2:type()
        if tt == 'class_declaration' or tt == 'trait_declaration' or tt == 'interface_declaration' then
            if kind == 'self' then
                local cn = p2:field('name')[1]
                if not cn then return nil end
                local c = node_text(cn, src)
                return c, c
            end
            for _, c in inext, p2, -1 do
                if c:type() == 'base_clause' then
                    for _, pc in inext, c, -1 do
                        local pt = pc:type()
                        if pt == 'name' or pt == 'qualified_name' then
                            local ptxt = node_text(pc, src)
                            -- (PSR-0 Mage_Core_X has no '\\': it stays whole; an alias names its real class)
                            return php_key_class(pc, src, ptxt), ptxt
                        end
                    end
                end
            end
            return nil
        end
        p2 = p2:parent()
    end
end

-- ── A TYPED RECEIVER (CART-1967) ────────────────────────────────────────────────────────────────────────────────────
-- `function f(FooInterface $x) { $x->m(); }`: the parameter's class type hint is enforced when the call starts, so `$x`
-- holds a FooInterface — until something rebinds it. Typed only when the parameter is a single CLASS type (`Foo`,
-- `?Foo`; not a union / intersection, not a built-in), not by-reference, not variadic, and NOTHING in the function
-- writes the variable: an assignment (or a destructuring one), a foreach binder, a catch variable, `global` / `static`,
-- a by-reference closure `use`, a reference taken of it — or code that can write any local (`$$v`, extract, parse_str,
-- include). A closure sees an outer parameter only through `use ($x)`, an arrow function directly. Passing `$x` as a
-- call ARGUMENT may rebind it through a by-reference parameter this pass cannot see: such a receiver is HEDGED (~).
local FN_TYPES = { method_declaration = true, function_definition = true, anonymous_function = true, arrow_function = true }
local BUILTIN_TYPES = { mixed = true, object = true, callable = true, iterable = true, array = true, string = true,
    int = true, float = true, bool = true, void = true, never = true, null = true, ['false'] = true, ['true'] = true }
local LOCAL_WRITERS = { extract = true, parse_str = true }
-- does anything in `fn` write `var`? -> 'write' | 'arg' (passed as an argument somewhere) | nil
local function php_writes(fn, var, src)
    local arg = false
    local function under_left(n)
        local cur, p = n, n:parent()
        while p do
            local pt = p:type()
            if pt == 'assignment_expression' or pt == 'augmented_assignment_expression'
                or pt == 'reference_assignment_expression' then
                local l = p:field('left')[1]
                if l and l:equal(cur) then return true end
                -- (the RIGHT of `$y = &$x` aliases $x: a write through $y rebinds it)
                if pt == 'reference_assignment_expression' and cur:type() == 'variable_name' then return true end
                return false
            elseif pt == 'list_literal' or pt == 'array_creation_expression' or pt == 'array_element_initializer'
                or pt == 'pair' and p:parent() and p:parent():type() ~= 'foreach_statement' then
                cur, p = p, p:parent()
            else return false end
        end
        return false
    end
    local found
    local function walk(n)
        if found then return end
        local t = n:type()
        if t == 'dynamic_variable_name' or t == 'include_expression' or t == 'include_once_expression'
            or t == 'require_expression' or t == 'require_once_expression'
            or t == 'global_declaration' and node_text(n, src):find(var, 1, true)
            or t == 'function_static_declaration' and node_text(n, src):find(var, 1, true) then
            found = 'write'; return
        end
        if t == 'function_call_expression' then
            local f = n:field('function')[1]
            if f and f:type() == 'name' and LOCAL_WRITERS[node_text(f, src):lower()] then found = 'write'; return end
        end
        if t == 'variable_name' and node_text(n, src) == var then
            local p = n:parent()
            local pt = p and p:type()
            if under_left(n) or pt == 'catch_clause' or pt == 'by_ref'
                or pt == 'foreach_statement' and not (p:named_child(0) and p:named_child(0):equal(n))
                or pt == 'pair' and p:parent() and p:parent():type() == 'foreach_statement' then
                found = 'write'; return
            end
            if pt == 'argument' then arg = true end
        end
        for _, c in inext, n, -1 do if c:named() then walk(c) end end
    end
    local body = fn:field('body')[1]
    if body then walk(body) end
    -- (a closure's by-reference `use (&$x)` sits beside its body, not in it)
    for _, c in inext, fn, -1 do if c:type() == 'anonymous_function_use_clause' then walk(c) end end
    return found or (arg and 'arg') or nil
end
-- the class `var` is declared as, seen from `node`: (class as written, hedge) or nil
local function php_param_class(node, var, src, depth)
    depth = depth or 0
    if depth > 8 then return nil end
    local fn = node:parent()
    while fn and not FN_TYPES[fn:type()] do fn = fn:parent() end
    if not fn then return nil end
    local params, found = fn:field('parameters')[1], nil
    for _, p in (params and inext or function () end), params, -1 do
        local pt = p:type()
        if pt == 'simple_parameter' or pt == 'property_promotion_parameter' or pt == 'variadic_parameter' then
            local nm = p:field('name')[1]
            if nm and node_text(nm, src) == var then found = p; break end
        end
    end
    if found then
        if found:type() == 'variadic_parameter' or found:field('reference_modifier')[1] then return nil end
        local ty = found:field('type')[1]
        if ty and ty:type() == 'optional_type' then ty = ty:named_child(0) end
        if not (ty and ty:type() == 'named_type') then return nil end
        local tn = ty:named_child(0)
        local tw = tn and node_text(tn, src)
        if not tw or BUILTIN_TYPES[tw:lower()] then return nil end
        local w = php_writes(fn, var, src)
        if w == 'write' then return nil end
        local lw = tw:lower()
        if lw == 'self' or lw == 'static' or lw == 'parent' then
            local _, written = php_enclosing(fn, src, lw == 'parent' and 'parent' or 'self')
            if not written then return nil end
            tw = written
        end
        return tw, w == 'arg' and 'byref-arg' or nil
    end
    -- not a parameter here: an arrow function sees the enclosing scope, a closure only what it `use`s BY VALUE
    if fn:type() == 'arrow_function' then
        if php_writes(fn, var, src) == 'write' then return nil end
        return php_param_class(fn, var, src, depth + 1)
    elseif fn:type() == 'anonymous_function' then
        for _, c in inext, fn, -1 do
            if c:type() == 'anonymous_function_use_clause' then
                for _, u in inext, c, -1 do
                    if u:type() == 'variable_name' and node_text(u, src) == var then
                        if php_writes(fn, var, src) == 'write' then return nil end
                        return php_param_class(fn, var, src, depth + 1)
                    end
                end
            end
        end
    end
    return nil
end

-- ── A TYPED PROPERTY RECEIVER (CART-1967) ───────────────────────────────────────────────────────────────────────────
-- `$this->repo->find()` where the ENCLOSING class declares `private RepoInterface $repo;` (or promotes it in its
-- constructor: `public function __construct(private RepoInterface $repo)`): a typed property's type is enforced on
-- EVERY assignment (PHP 7.4), so no rebinding check is needed. Same class only — an inherited property, a trait's, a
-- docblock `@var` (unenforced) are not read. -> the class as written, or nil
local function php_prop_class(node, prop, src)
    local cls = node:parent()
    while cls and cls:type() ~= 'class_declaration' and cls:type() ~= 'trait_declaration' do cls = cls:parent() end
    local body = cls and cls:field('body')[1]
    if not body then return nil end
    local function typed(ty)
        if ty and ty:type() == 'optional_type' then ty = ty:named_child(0) end
        if not (ty and ty:type() == 'named_type') then return nil end
        local tn = ty:named_child(0)
        local tw = tn and node_text(tn, src)
        if not tw or BUILTIN_TYPES[tw:lower()] then return nil end
        local lw = tw:lower()
        if lw == 'self' or lw == 'static' or lw == 'parent' then
            local _, written = php_enclosing(ty, src, lw == 'parent' and 'parent' or 'self')
            return written
        end
        return tw
    end
    for _, d in inext, body, -1 do
        local dt = d:type()
        if dt == 'property_declaration' then
            local static = false
            for _, k in inext, d, -1 do if k:type() == 'static_modifier' then static = true end end
            if not static then
                for _, el in inext, d, -1 do
                    if el:type() == 'property_element' then
                        local nm = el:field('name')[1]
                        if nm and node_text(nm, src) == prop then return typed(d:field('type')[1]) end
                    end
                end
            end
        elseif dt == 'method_declaration' then
            local mn = d:field('name')[1]
            if mn and node_text(mn, src):lower() == '__construct' then
                local ps = d:field('parameters')[1]
                for _, p in (ps and inext or function () end), ps, -1 do
                    if p:type() == 'property_promotion_parameter' then
                        local nm = p:field('name')[1]
                        if nm and node_text(nm, src) == prop then return typed(p:field('type')[1]) end
                    end
                end
            end
        end
    end
    return nil
end

local function php_is_write(c, n)
    local cur, p = c, n
    if p:type() == 'variable_name' then      -- $x: unwrap the sigil
        cur, p = p, p:parent()
    elseif p:type() ~= 'member_access_expression' then
        return false                          -- ->name rides the chain below
    end
    while p do
        local pt = p:type()
        if pt == 'subscript_expression' then
            if p:named_child(0) ~= cur then return false end -- key = a read
            cur, p = p, p:parent()
        elseif pt == 'member_access_expression' then
            cur, p = p, p:parent() -- object and field both ride the chain
        elseif pt == 'assignment_expression'
            or pt == 'augmented_assignment_expression'
            or pt == 'reference_assignment_expression' then
            return p:named_child(0) == cur
        elseif pt == 'update_expression' then -- $x++ / --$x (a READ when its value is used, CART-1595)
            return true, nil, tsutil.update_reads(p)
        elseif pt == 'unset_statement' then
            return true
        elseif pt == 'by_ref' then            -- foreach ($a as &$v): $v aliases
            return true
        elseif pt == 'foreach_statement' then
            -- the ITERATED array is written only when iterated by reference
            if p:named_child(0) ~= cur then return false end
            for _, ch in tsutil.inext, p, -1 do
                if ch:type() == 'by_ref' then return true end
            end
            return false
        elseif pt == 'list_literal' then      -- list($a, $b) = f()
            local gp = p:parent()
            return gp ~= nil and gp:type() == 'assignment_expression'
                and gp:named_child(0) == p
        else
            return false                      -- a plain read context
        end
    end
    return false
end

local PHP_GUARDS = {
    cond = { if_statement = true, else_if_clause = true, while_statement = true },
    else_t = 'else_clause', elseif_t = 'else_if_clause',
    fn = { function_definition = true, method_declaration = true,
        anonymous_function_creation_expression = true, arrow_function = true },
    binop = 'binary_expression', andops = { ['&&'] = true, ['and'] = true },
    negop = 'unary_op_expression', negtok = '!', pfield = 'parameters',
    -- `!isset(X)` / `empty(X)` / `!X` / `X === null` / `null === X`
    abs_test = function (n, src, chain)
        local t = n:type()
        if t == 'unary_op_expression' then
            local op = n:child(0)
            if op and not op:named() and op:type() == '!' then
                local x = unparen(n:named_child(0))
                if not x then return false end
                if chain_eq(x, src, chain) then return true end
                if x:type() == 'function_call_expression' then
                    local fname = x:field('function')[1]
                    if fname and node_text(fname, src) == 'isset' then
                        local args = x:field('arguments')[1]
                        local a = args and args:named_child(0)
                        return a ~= nil and chain_eq(a, src, chain)
                    end
                end
            end
        elseif t == 'function_call_expression' then
            local fname = n:field('function')[1]
            if fname and node_text(fname, src) == 'empty' then
                local args = n:field('arguments')[1]
                local a = args and args:named_child(0)
                return a ~= nil and chain_eq(a, src, chain)
            end
        elseif t == 'binary_expression'
            and optext_is(n, src, { ['==='] = true, ['=='] = true }) then
            local a, b = n:named_child(0), n:named_child(1)
            if a and b then
                if a:type() == 'null' then return chain_eq(b, src, chain) end
                if b:type() == 'null' then return chain_eq(a, src, chain) end
            end
        end
        return false
    end,
    presence = function (cond, src, chain)
        cond = unparen(cond)
        if cond == nil then return false end
        if chain_eq(cond, src, chain) then return true end
        if cond:type() == 'function_call_expression' then
            local fname = cond:field('function')[1]
            if fname and node_text(fname, src) == 'isset' then
                local args = cond:field('arguments')[1]
                local a = args and args:named_child(0)
                return a ~= nil and chain_eq(a, src, chain)
            end
        end
        return false
    end,
    -- `X ??= v` / `X = X ?? v`
    rhs_setonce = function (top, src, chain)
        local p = top:parent()
        if not p then return false end
        local pt = p:type()
        if pt == 'augmented_assignment_expression'
            and p:named_child(0) == top
            and optext_is(p, src, { ['??='] = true }) then
            return true
        end
        if pt == 'assignment_expression' and p:named_child(0) == top then
            local rhs = p:named_child(1)
            if rhs and rhs:type() == 'binary_expression'
                and optext_is(rhs, src, { ['??'] = true }) then
                local l = rhs:named_child(0)
                return l ~= nil and chain_eq(l, src, chain())
            end
        end
        return false
    end,
}

-- ── LEXICAL SCOPES (CART-1598, php) ───────────────────────────────────────────────────────────────────────────────
-- php declared no scope model, so a function's `$token` param or `$config` local joined another file's file-scope
-- `$token` / `$config` — a GLOBAL, which a php function never sees without `global`. A function / method / closure
-- binds its params and EVERY variable its body names (function-wide: php has no block scope and no implicit
-- globals), minus its `global` names and the superglobals; an arrow fn only its params
-- (it sees the enclosing scope). The binder is the variable's NAME, the mention php's spec declares.
local function php_var(vn, src, out)
    if vn and vn:type() == 'variable_name' then
        local nm = vn:named_child(0)
        if nm then out[node_text(nm, src)] = {} end
    end
end
local function php_params(node, src, out)
    local ps = node:field('parameters')[1]
    if ps then
        for _, p in tsutil.inamed, ps, -1 do
            php_var(p:field('name')[1], src, out)
        end
    end
end
local PHP_OWN_SCOPE = { function_definition = true, method_declaration = true, anonymous_function = true,
    arrow_function = true, class_declaration = true }
-- EVERY variable a function's body names is its own — php has no implicit globals: an unassigned `$config` read in
-- a function is an undefined LOCAL, never the file-scope `$config` — except its `global` names and the superglobals
-- (`$_GET` …); a closure's `use ($x)` capture is named in its body too
local function php_fn_scope(node, src, out)
    php_params(node, src, out)
    local glob = {}
    local function walk(n)
        for _, c in tsutil.inext, n, -1 do
            local t = c:type()
            if not PHP_OWN_SCOPE[t] then
                if t == 'variable_name' then
                    local nm = c:named_child(0)
                    local s = nm and node_text(nm, src)
                    if s and not s:match('^_%u') then out[s] = {} end -- (`$_GET` …: superglobal)
                elseif t == 'global_declaration' then
                    local g = {}
                    for _, v in tsutil.inext, c, -1 do php_var(v, src, g) end
                    for nm in pairs(g) do glob[nm] = true end
                end
                walk(c)
            end
        end
    end
    local body = node:field('body')[1]
    if body then walk(body) end
    for g in pairs(glob) do out[g] = nil end
end
local PHP_LEXICAL_SCOPES = {
    function_definition = { kind = 'param', harvest = php_fn_scope }, method_declaration = { kind = 'param', harvest = php_fn_scope },
    anonymous_function = { kind = 'param', harvest = php_fn_scope }, arrow_function = { kind = 'param', harvest = php_params },
}

return {
    lexical_scopes = PHP_LEXICAL_SCOPES, -- CART-1598
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
        subscript_expression = 0, -- $t[$k] · child 0, no field
    },
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
        member_access_expression = 'name', -- $o->NAME
        class_constant_access_expression = 1, -- C::NAME
    },
    -- CALL POSITIONS (CART-0499): parent node type -> which child holds the
    -- CALLEE NAME, as a field name or a named-child index. Replaces a
    -- hardcoded four-name or-chain inline in the provider that php, java,
    -- bash, rust macros, ruby and haskell were all missing from -- so a call
    -- to a corpus-unique function became a fn REFERENCE and minted a `reg`
    -- edge ("kept alive by top-level DATA"), a different fact. 96.6% of
    -- mantisbt's reg occurrences were mislabelled calls.
    call_positions = {
        function_call_expression = 'function', -- foo(1)
        member_call_expression = 'name', -- $o->m(2) -- the method NAME, not the receiver
        scoped_call_expression = 'name', -- C::s(3)
    },
    exts = { 'php' },
    -- Laravel blade templates reuse the .php extension and are NOT php: no
    -- `<?php` tag, so the grammar parses the whole file as inline text without
    -- erroring and mints a region named after a `@directive` (CART-0347).
    -- Cross-language by construction — a template convention that reuses its
    -- host's extension is exactly what this field is for.
    ext_disclaim = { 'blade.php' },
    -- BINDER NODES: see spec/lua.lua. `foreach ($t as $k => $v)` binds through a
    -- `pair`, or directly for `foreach ($t as $x)`.
    binders = {
        { node = 'foreach_statement', child = 'pair' },
    },
    write_gate = { variable_name = true, member_access_expression = true },
    is_write = php_is_write,
    guards = PHP_GUARDS,
    -- typed-string SINKS (typed-strings v1): the API contract types
    -- the arg — CONFIDENT, unlike content sniffing (~ by design)
    string_sinks = {
        db_query = { arg = 1, ty = 'sql' },     -- mantis/drupal wrapper
        mysql_query = { arg = 1, ty = 'sql' },
        mysqli_query = { arg = 2, ty = 'sql' },
        pg_query = { arg = 1, ty = 'sql' },
    },
    functions = [=[
        (function_definition name: (name) @name) @def
        (method_declaration name: (name) @name) @def
    ]=],
    calls = [=[
        (function_call_expression function: (name) @name) @call
        (member_call_expression name: (name) @name) @call
        (scoped_call_expression name: (name) @name) @call
        (function_call_expression function: (variable_name) @name) @call
        (member_call_expression name: (variable_name) @name) @call
        (scoped_call_expression name: (variable_name) @name) @call
        (object_creation_expression [(name) (qualified_name) (variable_name)] @name) @call
    ]=],
    -- (CART-0735: a file's namespace + `use` aliases, recorded at extraction — data.classnames — and the FQCN rule over
    -- them; the resolver's class veto compares a call's class with its target's by these)
    class_names = php_class_names,
    class_fqcn = php_class_fqcn,
    -- ── CART-0734: VARIABLE DISPATCH WAS INVISIBLE, NOT DYNAMIC ─────────────
    -- The `member_call_expression` / `scoped_call_expression` patterns above
    -- used to require `name: (name)`, so `$obj->$method()` and `$obj::$method()`
    -- matched NOTHING -- no call record at all, hence no callee, no refusal, and
    -- nothing for census.disp to classify. A method reached only that way had no
    -- incoming call and entered the dead-code population: a false deletion
    -- licence, and a QUIETER one than a wrong answer, because AN ABSENT RECORD
    -- CANNOT BE HEDGED.
    -- The captured node is a `variable_name`, already in `dynamic_callee_types`,
    -- so these arrive flagged `dynamic` and resolve to nothing by the same route
    -- `$fn()` takes. Shapes verified by parsing a snippet, per this file's own
    -- rule -- and the braced form `$obj->{$method}()` NORMALISES to the same
    -- `name: (variable_name)`, so it needs no pattern of its own.
    -- STILL UNMODELLED and deliberately out of scope here: `new $class()`, which
    -- is a special case of php recording NO constructor call at all (not even
    -- `new T()`) -- see CART-0735.
    -- call_user_func('name', ...) CALLS name: the literal resolves as
    -- the real callee (the string is the dispatch mechanism, not a ~)
    indirect_calls = { call_user_func = 1, call_user_func_array = 1 },
    -- a variable in callee position is runtime state ($fn()) — by NODE
    -- TYPE: jQuery's $() is a plain identifier and must stay a call
    -- `$op()` was already here; `$a[$k]()` is the same fact through a subscript
    -- (CART-0344). Node names verified by parsing a snippet, not guessed.
    dynamic_callee_types = { variable_name = true, subscript_expression = true },
    -- ★ A LITERAL KEY IS NOT DYNAMIC: `$a['lit']()` names its member in the
    -- source. `$op()`'s callee is a variable_name whose key child is a `name`,
    -- which is deliberately NOT in this set, so the existing php behaviour is
    -- unchanged.
    dynamic_callee_static_key = { string = true, encapsed_string = true,
        integer = true },
    vars = [=[
        (program (expression_statement (assignment_expression
            left: (variable_name (name) @vname) right: (_) @value) @vdef))
        (const_declaration (const_element (name) @vname (_) @value) @vdef)
    ]=],
    params_field = 'parameters',
    body_field = 'body',
    -- ACCESS BY STRING KEY ([[cartograph-keyaccess]]): the table through which a
    -- variable can be reached by NAME, and the operator that builds that name.
    -- Together they are all keyaccess needs to DERIVE an accessor's transform
    -- from its own body -- mantis's `$GLOBALS['g_' . $p_option]` -- instead of
    -- being told the convention, which is the difference between reading the
    -- code and guessing it. php's `$$name` is a second spelling, not modelled.
    global_table = { GLOBALS = true },
    concat_op = '.',
    -- a php file-scope assignment IS a global: `$x = 1;` outside any function is
    -- exactly `$GLOBALS['x']`, with no keyword to distinguish. So a derived name
    -- may resolve to a file-scope var node here.
    global_scope_vars = true,
    -- `anonymous_function`, NOT `anonymous_function_creation_expression`: the
    -- grammar renamed it and the dead entry sat here unnoticed, because nothing
    -- audits a TABLE of node types the way a query gets compiled (CART-0306).
    fn_types = { function_definition = true, method_declaration = true,
        anonymous_function = true, arrow_function = true },
    is_method = function (_, def) return def:type() == 'method_declaration' end,
    -- methods carry their class: Worker::work (ambiguity semantics match cpp)
    qualify = function (name, defn, src)
        local p2 = defn:parent()
        while p2 do
            local t = p2:type()
            if t == 'class_declaration' or t == 'interface_declaration'
                or t == 'trait_declaration' then
                local cn = p2:field('name')[1]
                return cn and (node_text(cn, src) .. '::' .. name)
                    or name
            end
            p2 = p2:parent()
        end
        return name
    end,
    -- an ATTRIBUTE with arguments registers the method with a
    -- framework (#[Route('/x')]) — the java annotation-with-args
    -- lesson; bare markers (#[\Override]) don't register anything
    cbarg_def = function (defn, src)
        for _, c in inext, defn, -1 do
            if c:type() == 'attribute_list'
                and node_text(c, src)
                    :find('(', 1, true) then
                return true
            end
        end
        return false
    end,
    -- $this->m() / self::m() / static::m(): the receiver IS the
    -- enclosing class — resolve as Class::m before any tail guess.
    -- parent::m() is the receiver's SUPERCLASS — read the enclosing
    -- class's `extends` (base_clause) and resolve as Parent::m. This
    -- is the single largest refusal bucket in every OO php tree: every
    -- class has a __construct, so a bare parent::__construct tail-
    -- matches ALL of them (2313 candidates in magento) and refuses.
    qualify_call = function (calln, name, src)
        local t = calln:type()
        -- ★ `new T()` CALLS T's CONSTRUCTOR (CART-0735). It recorded nothing at all, so every __construct read as
        -- uncalled and every `new` was a dependency the graph lacked. `full` names the member, so the exact lookup
        -- finds T::__construct; the 5th value is the class AS WRITTEN, which the resolver's class veto reads through
        -- the file's `use` table. `new $cls()` is runtime state: left dynamic.
        if t == 'object_creation_expression' then
            if name:sub(1, 1) == '$' then return nil end
            if name == 'self' or name == 'static' or name == 'parent' then
                local cls, written = php_enclosing(calln, src, name == 'parent' and 'parent' or 'self')
                if not cls then return nil end
                return cls .. '::__construct', nil, nil, nil, written
            end
            return php_key_class(calln, src, name) .. '::__construct', nil, nil, nil, name
        end
        if name:find(':', 1, true) then return nil end
        local kind
        if t == 'member_call_expression' then
            local o = calln:field('object')[1]
            if o and o:type() == 'variable_name'
                and node_text(o, src) == '$this' then
                kind = 'self'
            elseif o and o:type() == 'variable_name' then
                -- (a TYPED parameter receiver, CART-1967: keyed by its declared class, the class veto decides)
                local tw, hedge = php_param_class(calln, node_text(o, src), src)
                if tw then return php_key_class(calln, src, tw) .. '::' .. name, hedge, nil, nil, tw end
            elseif o and o:type() == 'member_access_expression' then
                -- (a TYPED PROPERTY of the enclosing class, `$this->repo->m()`, CART-1967)
                local base, pn = o:field('object')[1], o:field('name')[1]
                if base and base:type() == 'variable_name' and node_text(base, src) == '$this'
                    and pn and pn:type() == 'name' then
                    local tw = php_prop_class(calln, '$' .. node_text(pn, src), src)
                    if tw then return php_key_class(calln, src, tw) .. '::' .. name, nil, nil, nil, tw end
                end
            end
        elseif t == 'scoped_call_expression' then
            local s = calln:field('scope')[1]
            if s and s:type() == 'relative_scope' then
                kind = node_text(s, src) == 'parent'
                    and 'parent' or 'self'
            end
        end
        if not kind then return nil end
        -- self:: / $this-> name a method of the ENCLOSING class; parent:: the superclass its base_clause names. A trait
        -- has no base_clause (its parent is the using class, unknown here): declined, a refusal. Def keys use the BARE
        -- class name; the 5th value keeps the name as written for the class veto (CART-0735)
        local cls, written = php_enclosing(calln, src, kind)
        if not cls then return nil end
        return cls .. '::' .. name, nil, nil, nil, written
    end,
    mention_types = { name = true },
    -- OO extends: child class -> superclass name (bare last segment,
    -- the same key form defs use). Feeds transitive parent::m resolution.
    super_query = [=[
        (class_declaration
            name: (name) @child
            (base_clause [(name) (qualified_name)] @parent))
    ]=],
    block_skip = { php_tag = true, class_declaration = true,
        interface_declaration = true, trait_declaration = true },
    litdata_types = { array_creation_expression = true },
    -- ★ php IS the language where this fact lives: four forms, two independent
    -- bits, and the graph collapsed all four into one edge until CART-0510.
    -- `once` = does a second execution re-run the file (so a var inside it is
    -- assigned once PER INCLUSION, which is what makes a set-once claim about it
    -- unsound). `soft` = failure warns instead of aborting, which is what makes
    -- the include CONDITIONAL and caps a stitch closure at an over-approximation.
    import_kinds = {
        require_once_expression = { once = true },
        require_expression      = { once = false },
        include_once_expression = { once = true,  soft = true },
        include_expression      = { once = false, soft = true },
    },
    import_query = [=[
        (require_once_expression (string) @path)
        (require_expression (string) @path)
        (include_once_expression (string) @path)
        (include_expression (string) @path)
        ; ★ THE PARENTHESISED FORM, and it is the one everyone writes.
        ; `require_once( 'x' )` parses as require_once_expression ->
        ; parenthesized_expression -> string, so the four DIRECT-CHILD patterns
        ; above match only the bare `require_once 'x';` spelling and mantis's 185
        ; literal require_once('core.php') produced ZERO import edges (CART-0483,
        ; whose cause this corrects -- it was read as a path-resolution edge case
        ; and is actually the whole parenthesised half of php file inclusion).
        ; @path stays on the STRING, not on the alternation, so resolve_import
        ; still receives a quoted literal and not "( 'x' )".
        ; A computed path (`require_once( $dir . 'x' )`) nests a binary_expression
        ; instead and is deliberately still unmatched: that is the non-enumerable
        ; include, and it is the case that must stay a frontier.
        (require_once_expression (parenthesized_expression (string) @path))
        (require_expression (parenthesized_expression (string) @path))
        (include_once_expression (parenthesized_expression (string) @path))
        (include_expression (parenthesized_expression (string) @path))
        (namespace_use_clause (qualified_name) @path)
        (base_clause (name) @path)
        (base_clause (qualified_name) @path)
        (class_interface_clause (name) @path)
        (class_interface_clause (qualified_name) @path)
    ]=],
    resolve_import = function (path, files, from)
        path = path:gsub('^["\']', ''):gsub('["\']$', '')
        -- (a leading `\` only says FULLY QUALIFIED: `extends \Base_Handler` names the global Base_Handler, whose PSR-0
        -- file is Base/Handler.php — with the `\` kept, the underscore form was never tried, CART-0735)
        path = path:gsub('^\\', '')
        -- a namespaced class (use App\X, extends \App\X) or a PSR-0
        -- underscore class (extends Mage_Core_Model_Abstract): both
        -- name a file by convention. PSR-4 roots REMAP prefixes
        -- (composer: BitBag\OpenMarketplace\ -> src/), so try
        -- progressively SHORTER suffixes, longest first; a match
        -- counts only while unique, ambiguity refuses, as ever
        local sep = path:find('\\') and '\\'
            or (path:match('^%u[%w]*_[%w_]+$') and '_')
        if sep then
            local idx = PHP_BASENAMES[files]
            if not idx then
                idx = {}
                for f in pairs(files) do
                    local b = f:match('([^/]+)$')
                    local l = idx[b]
                    if l then l[#l + 1] = f else idx[b] = { f } end
                end
                PHP_BASENAMES[files] = idx
            end
            local segs = {}
            for s in path:gmatch('[^' .. sep .. ']+') do segs[#segs + 1] = s end
            local cands = idx[segs[#segs] .. '.php']
            if not cands then return nil end
            for i = 1, #segs do
                local suffix, hit = table.concat(segs, '/', i) .. '.php', nil
                for _, f in ipairs(cands) do
                    if f == suffix or f:sub(-#suffix - 1) == '/' .. suffix then
                        if hit then return nil end -- ambiguous: refuse
                        hit = f
                    end
                end
                if hit then return hit end
            end
            return nil
        end
        local dir = from:match('^(.*)/[^/]*$')
        for _, cand in ipairs({ dir and (dir .. '/' .. path) or path, path }) do
            if files[cand] then return cand end
        end
        -- a bare filename (custom loaders pass 'bug_api.php', the
        -- loader supplies the directory): unique basename decides
        if not path:find('/') then
            local idx = PHP_BASENAMES[files]
            if not idx then
                idx = {}
                for f in pairs(files) do
                    local b = f:match('([^/]+)$')
                    local l = idx[b]
                    if l then l[#l + 1] = f else idx[b] = { f } end
                end
                PHP_BASENAMES[files] = idx
            end
            local cands = idx[path]
            if cands and #cands == 1 then return cands[1] end
        end
    end,
    -- CUSTOM loaders (mantis's require_api('bug_api.php')): a verb
    -- named like a loader whose literal argument is a php file
    -- includes that file — name-matched, so the edge carries ~
    import_call_like = function (name, arg)
        return arg:sub(-4) == '.php'
            and (name:match('^require_') or name:match('^include_')
                or name:match('^load_')) ~= nil
    end,
    stdlib_names = { isset = true, unset = true, empty = true,
        count = true, define = true, defined = true, sprintf = true,
        printf = true, implode = true, explode = true, in_array = true,
        array_merge = true, array_map = true, array_filter = true,
        array_keys = true, array_values = true, str_replace = true,
        strlen = true, substr = true, strpos = true, trim = true,
        intval = true, strval = true, is_array = true, is_null = true,
        is_string = true, is_int = true, is_numeric = true,
        trigger_error = true, function_exists = true,
        class_exists = true },
}
