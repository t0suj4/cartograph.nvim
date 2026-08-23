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
local function python_is_write(c, n)
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

return {
    is_write = python_is_write,
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
