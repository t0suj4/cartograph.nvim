-- The JAVASCRIPT language spec (L0 grammar binding + L1 name model)
-- extracted from the engine ([[cartograph-spec-layering]] P1). Pure motion.

local tsutil = require 'cartograph.spec.tsutil'
local node_text = tsutil.node_text

return {
        exts = { 'js', 'mjs', 'cjs', 'jsx' }, -- the JS grammar handles JSX
        -- BINDER NODES: see spec/lua.lua. `for (const g of t)` binds g as a direct
        -- identifier child; a classic `for` binds inside its initializer.
        binders = {
            { node = 'for_in_statement' },
            { node = 'for_statement', child = 'lexical_declaration' },
        },
        functions = [=[
            (function_declaration name: (identifier) @name) @def
            (method_definition name: (property_identifier) @name) @def
            (variable_declarator name: (identifier) @name value: (arrow_function) @def)
            (variable_declarator name: (identifier) @name value: (function_expression) @def)
            (pair key: (property_identifier) @name value: (arrow_function) @def)
            (pair key: (property_identifier) @name value: (function_expression) @def)
            (arguments (arrow_function) @adef)
            (arguments (function_expression) @adef)
            (assignment_expression
                left: (member_expression
                    object: (member_expression property: (property_identifier) @_pp)) @name
                right: (function_expression) @def (#eq? @_pp "prototype"))
            (assignment_expression
                left: (member_expression
                    object: (member_expression property: (property_identifier) @_pp)) @name
                right: (arrow_function) @def (#eq? @_pp "prototype"))
        ]=],
        calls = [=[
            (call_expression function: (identifier) @name) @call
            (call_expression function: (member_expression) @name) @call
        ]=],
        vars = [=[
            (program (lexical_declaration
                (variable_declarator name: (identifier) @vname value: (_) @value) @vdef))
            (program (variable_declaration
                (variable_declarator name: (identifier) @vname value: (_) @value) @vdef))
        ]=],
        -- V2 ctor-typing: `const o = new C(...)` (ANYWHERE, incl. in-function)
        -- binds o to class C; resolve_local_ctor types o.member → C.member. The
        -- callee stored is the bare class C (not lua's `C.new` convention) → the
        -- JS cut in resolve_local_ctor keys on is_class[callee] directly.
        ctor_query = [=[
            (variable_declarator name: (identifier) @cvar
                value: (new_expression constructor: (identifier) @cctor))
            (assignment_expression left: (identifier) @cvar
                right: (new_expression constructor: (identifier) @cctor))
        ]=],
        params_field = 'parameters',
        body_field = 'body',
        fn_types = { function_declaration = true, method_definition = true,
            arrow_function = true, function_expression = true },
        is_method = function (_, def) return def:type() == 'method_definition' end,
        -- ES6 methods carry their class: `class C { m(){} }` -> `C.m` (the JS
        -- analog of lua `C:m` / php `C::m`). A method_definition is a class
        -- member IFF its DIRECT parent is class_body — object-literal methods
        -- (`{ m(){} }`, incl. ones nested inside a class method) parent an
        -- `object`, so they stay bare, never falsely borrowing an outer class.
        -- `.` separator: aligns the key with how methods are called (obj.m),
        -- so a `ClassName.m()` reference exact-matches, while the tail index
        -- ([%w_]+$ -> `m`) still catches the unqualified `x.m()` receiver calls.
        -- Anonymous class expressions borrow their binding variable's name
        -- (`const C = class {…}`); a truly nameless class leaves methods bare.
        qualify = function (name, defn, src)
            -- pre-ES6 prototype method (pivot B4): `X.prototype.m = function` is
            -- captured with @name = the whole LHS `X.prototype.m`; collapse to the
            -- class key `X.m` (the same shape B1 gives ES6 methods, so B3
            -- this-typing / resolve_super treat a prototype "class" identically).
            -- `A.B.prototype.m` → `A.B.m`. The query's #eq? "prototype" gate means
            -- only genuine prototype assignments reach here in this form.
            local powner, pmethod = name:match('^(.+)%.prototype%.([%w_]+)$')
            if powner then return powner .. '.' .. pmethod end
            local body = defn:parent()
            -- field-arrow (`class C { m = () => {} }`): the fn's parent is the
            -- field def, whose parent is class_body — unwrap so C.m keys like a method.
            if body and (body:type() == 'field_definition'
                or body:type() == 'public_field_definition') then
                body = body:parent()
            end
            if not (body and body:type() == 'class_body') then return name end
            local cls = body:parent()
            if not cls then return name end
            local nm = cls:field('name')[1]
            local owner = nm and node_text(nm, src)
            if not owner and cls:type() == 'class' then
                local par = cls:parent() -- `const C = class {…}`
                if par and par:type() == 'variable_declarator' then
                    local vn = par:field('name')[1]
                    owner = vn and node_text(vn, src)
                end
            end
            return owner and (owner .. '.' .. name) or name
        end,
        -- in-function local declarations, for fn_locals (the local-shadow gate);
        -- df doesn't track JS locals so the destructured `const [x,setX]=…` hook
        -- setters would name-match a global without this.
        local_decls = { lexical_declaration = true, variable_declaration = true },
        stdlib_prefixes = { 'console.', 'JSON.', 'Object.', 'Array.', 'Math.',
            'Promise.', 'window.', 'document.', 'chrome.' },
        -- the WORKSPACE PACKAGE (nearest package.json ancestor) scopes
        -- bare names: monorepo packages import across, never leak across
        scope = function (file, _, root)
            if not root then return '' end
            local dir = file:match('^(.*)/[^/]*$') or ''
            while dir ~= '' do
                if vim.uv.fs_stat(root .. '/' .. dir .. '/package.json') then
                    return dir
                end
                dir = dir:match('^(.*)/[^/]*$') or ''
            end
            return ''
        end,
        -- dom/framework vocabulary
        stdlib_names = { getAttribute = true, setAttribute = true,
            addEventListener = true, removeEventListener = true,
            querySelector = true, querySelectorAll = true,
            createElement = true, appendChild = true, dispatch = true,
            subscribe = true, push = true, pop = true, shift = true,
            slice = true, splice = true, join = true, split = true,
            filter = true, map = true, forEach = true, reduce = true,
            find = true, includes = true, indexOf = true, replace = true,
            trim = true, toString = true, concat = true, keys = true,
            values = true, entries = true, assign = true, freeze = true,
            stringify = true, parse = true, emit = true, on = true,
            off = true, once = true, get = true, set = true, has = true,
            add = true, delete = true, clear = true, next = true,
            startsWith = true, endsWith = true, some = true, every = true,
            sort = true, reverse = true, flat = true, substring = true,
            toLowerCase = true, toUpperCase = true, padStart = true,
            charAt = true,
            ['$emit'] = true, ['$on'] = true, ['$nextTick'] = true },
        litdata_types = { object = true, array = true },
        -- ESM imports + CommonJS require + dynamic import(). require/import
        -- match ONLY a lone string literal argument — computed paths stay
        -- unresolved (honest frontier, not a guess). Predicates demand
        -- iter_matches in the consumer (iter_captures ignores #eq?).
        -- @bind is the LOCAL NAME an import introduces, which is what lets a call
        -- through that name be attributed to the imported file (resolve_module_alias,
        -- and the `unread-file` disposition for a call into an opaque bundle). Only
        -- SINGLE-bind forms are captured: a default import, a namespace import, and
        -- CommonJS `const x = require(...)`. NAMED imports (`import {a, b}`) bind
        -- several names to one edge and the edge carries one `bind`, so they stay
        -- uncaptured rather than being represented wrongly — a deliberate gap, not
        -- an oversight.
        --
        -- Several patterns can match ONE import site (a namespace import matches the
        -- general form too, and a CJS require matches both the declaration and the
        -- bare-call form). The consumer dedupes on the @path NODE, so the edge set is
        -- exactly what it was before binds existed; only the bind is added.
        import_query = [=[
            (import_statement
                (import_clause [
                    (identifier) @bind
                    (namespace_import (identifier) @bind)
                ])?
                source: (string) @path)
            (lexical_declaration (variable_declarator
                name: (identifier) @bind
                value: (call_expression
                    function: (identifier) @_rq (#eq? @_rq "require")
                    arguments: (arguments . (string) @path .))))
            (call_expression
                function: (identifier) @_fn (#eq? @_fn "require")
                arguments: (arguments . (string) @path .))
            (call_expression
                function: (import)
                arguments: (arguments . (string) @path .))
        ]=],
        resolve_import = function (path, files, from)
            path = path:gsub('^["\']', ''):gsub('["\']$', '')
            local function norm(p) -- ./ and ../ segments
                local parts = {}
                for seg in p:gmatch('[^/]+') do
                    if seg == '..' then parts[#parts] = nil
                    elseif seg ~= '.' then parts[#parts + 1] = seg end
                end
                return table.concat(parts, '/')
            end
            local function try(cand)
                cand = norm(cand)
                for _, c in ipairs({ cand, cand .. '.js', cand .. '.ts',
                    (cand:gsub('%.js$', '.ts')),
                    cand .. '/index.js', cand .. '/index.ts' }) do
                    if files[c] then return c end
                end
            end
            local dir = from:match('^(.*)/[^/]*$')
            if path:match('^[@~]/') then
                -- bundler alias ('@/x', '~/x'): the package's src/ (vite)
                -- or the app root itself (nuxt). The package.json isn't in
                -- the fileset, so walk ancestors and let existence decide
                local x = path:sub(3)
                local anc = dir
                while anc do
                    local hit = try(anc .. '/src/' .. x) or try(anc .. '/' .. x)
                    if hit then return hit end
                    anc = anc:match('^(.*)/[^/]*$')
                end
                return try('src/' .. x) or try(x)
            end
            return try(dir and (dir .. '/' .. path) or path)
        end,
}
