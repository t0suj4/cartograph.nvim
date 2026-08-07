-- The C language spec (L0 grammar binding + L1 name model)
-- extracted from the engine ([[cartograph-spec-layering]] P1). Pure motion.

-- @langs c — a spec IS one grammar's mapping, so every node type here is
-- c's by construction.

return {
        exts = { 'c', 'h' },
        functions = [[
            (function_definition
                declarator: (function_declarator declarator: (identifier) @name)) @def
            (function_definition
                declarator: (pointer_declarator
                    declarator: (function_declarator declarator: (identifier) @name))) @def
        ]],
        calls = [[ (call_expression function: (identifier) @name) @call
                   (call_expression function: (field_expression) @name) @call ]],
        vars = [[
            (declaration declarator: (init_declarator
                declarator: (identifier) @vname value: (_) @value)) @vdef
            (declaration declarator: (init_declarator
                declarator: (array_declarator declarator: (identifier) @vname)
                value: (_) @value)) @vdef
            (declaration declarator: (identifier) @vname) @vdef
        ]],
        litdata_types = { initializer_list = true },
        -- a header's INTERFACE: prototypes (decl), macros (fn-like + object),
        -- and types (struct/union/enum/typedef). Browsing a .h now shows what
        -- it declares, not one opaque #ifndef block.
        interface = [[
            (declaration declarator:
                (function_declarator declarator: (identifier) @proto)) @def
            (declaration declarator: (pointer_declarator declarator:
                (function_declarator declarator: (identifier) @proto))) @def
            (preproc_function_def name: (identifier) @macrofn) @def
            (preproc_def name: (identifier) @macro) @def
            (struct_specifier name: (type_identifier) @struct
                body: (field_declaration_list)) @def
            (union_specifier name: (type_identifier) @struct
                body: (field_declaration_list)) @def
            (enum_specifier name: (type_identifier) @enum
                body: (enumerator_list)) @def
            (type_definition declarator: (type_identifier) @typedef) @def
        ]],
        params_field = 'parameters',
        body_field = 'body',
        fn_types = { function_definition = true },
        is_method = function () return false end,
        entry_names = { main = true },
        -- both forms: "quoted" (relative) AND <angled>. Angle-bracket
        -- includes are conventionally -I lookups — most are external system
        -- headers (no project file → no edge), but a project's own headers
        -- pulled in via -Iinclude are angled too, and those DO resolve.
        import_query = [[ (preproc_include path: [(string_literal) (system_lib_string)] @path) ]],
        resolve_import = function (path, files, from)
            path = path:gsub('^[<"]', ''):gsub('[>"]$', '')
            local dir = from:match('^(.*)/[^/]*$')
            for _, cand in ipairs({ dir and (dir .. '/' .. path) or path, path }) do
                if files[cand] then return cand end
            end
            -- -I include paths are invisible here: a unique basename match
            -- stands in (ambiguity refuses, as everywhere)
            local base, hit = path:match('([^/]+)$'), nil
            for f in pairs(files) do
                if f:match('([^/]+)$') == base then
                    if hit then return nil end
                    hit = f
                end
            end
            return hit
        end,
}
