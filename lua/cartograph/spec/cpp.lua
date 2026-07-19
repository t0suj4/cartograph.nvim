-- The CPP language spec (L0 grammar binding + L1 name model)
-- extracted from the engine ([[cartograph-spec-layering]] P1). Pure motion.

local tsutil = require 'cartograph.spec.tsutil'
local node_text = tsutil.node_text

return {
        exts = { 'cpp', 'hpp', 'cc', 'hh', 'cxx', 'hxx' },
        functions = [=[
            (function_definition
                declarator: (function_declarator declarator: (_) @name)) @def
            (function_definition
                declarator: (pointer_declarator
                    declarator: (function_declarator declarator: (_) @name))) @def
            (function_definition
                declarator: (reference_declarator
                    (function_declarator declarator: (_) @name))) @def
        ]=],
        calls = [=[
            (call_expression function: (identifier) @name) @call
            (call_expression function: (field_expression) @name) @call
            (call_expression function: (qualified_identifier) @name) @call
        ]=],
        vars = [=[
            (declaration declarator: (init_declarator
                declarator: (identifier) @vname value: (_) @value)) @vdef
            (declaration declarator: (init_declarator
                declarator: (array_declarator declarator: (identifier) @vname)
                value: (_) @value)) @vdef
        ]=],
        -- the header interface, as in C, plus C++ class/struct definitions
        interface = [=[
            (declaration declarator:
                (function_declarator declarator: (_) @proto)) @def
            (declaration declarator: (pointer_declarator declarator:
                (function_declarator declarator: (_) @proto))) @def
            (preproc_function_def name: (identifier) @macrofn) @def
            (preproc_def name: (identifier) @macro) @def
            (struct_specifier name: (type_identifier) @struct
                body: (field_declaration_list)) @def
            (union_specifier name: (type_identifier) @struct
                body: (field_declaration_list)) @def
            (class_specifier name: (type_identifier) @struct
                body: (field_declaration_list)) @def
            (enum_specifier name: (type_identifier) @enum
                body: (enumerator_list)) @def
            (type_definition declarator: (type_identifier) @typedef) @def
        ]=],
        params_field = 'parameters',
        body_field = 'body',
        litdata_types = { initializer_list = true },
        -- x.f() and x->f() are member dispatch: never a free function
        dot_calls_are_methods = true,
        -- ctor member-initializers (count(count)) parse as calls; skip
        call_skip_within = { field_initializer_list = true,
            field_initializer = true },
        -- inline class/struct methods carry their class (Unit::GetTarget);
        -- out-of-class definitions already capture the qualified text
        qualify = function (name, defn, src)
            if name:find('::', 1, true) then return name end
            local p = defn:parent()
            while p do
                local t = p:type()
                if t == 'class_specifier' or t == 'struct_specifier' then
                    local cn = p:field('name')[1]
                    return cn and (node_text(cn, src)
                        .. '::' .. name) or name
                end
                p = p:parent()
            end
            return name
        end,
        -- Engine::go, inline class methods, destructors: all dispatch-ish
        is_method = function (name, def)
            if name:find('::') or name:find('~', 1, true) then return true end
            local p = def:parent()
            while p do
                local t = p:type()
                if t == 'class_specifier' or t == 'struct_specifier' then return true end
                p = p:parent()
            end
            return false
        end,
        entry_names = { main = true },
        -- namespaces/classes wrap real content; they are not "loose statements"
        block_skip = { namespace_definition = true, class_specifier = true,
            struct_specifier = true, template_declaration = true,
            enum_specifier = true, linkage_specification = true },
        -- STL vocabulary: a project method named `size` must not absorb
        -- every container .size() in the codebase
        stdlib_names = { size = true, empty = true, begin = true, ['end'] = true,
            clear = true, push_back = true, pop_back = true, insert = true,
            erase = true, find = true, count = true, at = true, data = true,
            c_str = true, front = true, back = true, reserve = true,
            resize = true, get = true, reset = true, str = true, swap = true,
            emplace_back = true, first = true, second = true, length = true,
            substr = true, append = true, record = true, type = true,
            value = true, key = true, name = true, id = true },
        -- both "quoted" and <angled> (see the C spec): a project's own
        -- headers reached through -Iinclude are angle-bracketed too
        import_query = [=[ (preproc_include path: [(string_literal) (system_lib_string)] @path) ]=],
        resolve_import = function (path, files, from)
            path = path:gsub('^[<"]', ''):gsub('[>"]$', '')
            local dir = from:match('^(.*)/[^/]*$')
            for _, cand in ipairs({ dir and (dir .. '/' .. path) or path, path }) do
                if files[cand] then return cand end
            end
            -- -I roots: unique path-suffix match (openmw: apps/, components/)
            local hit
            for f in pairs(files) do
                if f:sub(-#path - 1) == '/' .. path then
                    if hit then return nil end
                    hit = f
                end
            end
            return hit
        end,
}
