-- The PYTHON language spec (L0 grammar binding + L1 name model)
-- extracted from the engine ([[cartograph-spec-layering]] P1). Pure motion.

-- @langs python — a spec IS one grammar's mapping, so every node type here is
-- python's by construction.

local tsutil = require 'cartograph.spec.tsutil'
local node_text = tsutil.node_text
local inext = tsutil.inext

return {
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
