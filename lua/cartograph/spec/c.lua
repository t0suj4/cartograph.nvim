-- The C language spec (L0 grammar binding + L1 name model)
-- extracted from the engine ([[cartograph-spec-layering]] P1). Pure motion.

-- @langs c — a spec IS one grammar's mapping, so every node type here is
-- c's by construction.

local tsutil = require 'cartograph.spec.tsutil'

return {
    is_write = tsutil.cfamily_is_write,
    -- the PREFILTER: every immediate parent type a write mention can have here.
    -- Without it the classifier is never invoked (v147 shipped that mistake).
    write_gate = { assignment_expression = true, update_expression = true,
        field_expression = true, subscript_expression = true,
        pointer_expression = true, qualified_identifier = true },
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
        subscript_expression = 'argument', -- a[i]
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
        field_expression = 'field', -- o.NAME
    },
    -- CALL POSITIONS (CART-0499): parent node type -> which child holds the
    -- CALLEE NAME, as a field name or a named-child index. Replaces a
    -- hardcoded four-name or-chain inline in the provider that php, java,
    -- bash, rust macros, ruby and haskell were all missing from -- so a call
    -- to a corpus-unique function became a fn REFERENCE and minted a `reg`
    -- edge ("kept alive by top-level DATA"), a different fact. 96.6% of
    -- mantisbt's reg occurrences were mislabelled calls.
    call_positions = {
        call_expression = 'function', -- g(1)
    },
    -- ★ C's `declaration` IS a local declaration and the expression IR did not know it
    -- (CART-0404). `int a = 5;` fell past expr's LOCALDECL unwrap, so the declared NAME was
    -- harvested as a READ while du correctly called it a def — 75190 rows on the cpp corpus,
    -- 14429 on cppmodern, the single largest IR/du disagreement class there was.
    -- ★ IN THE SPEC AND NOT A BASE TABLE, because `declaration` is a node type in NINE of the
    -- seventeen grammars (c cpp haskell java javascript lua odin tsx typescript — several as
    -- a SUPERTYPE, which is exactly the kind of distinction a name-keyed base set cannot
    -- make). Same lesson as `pattern` in six and `block` in eight.
    localdecl = { declaration = true },
    -- ★ A STORAGE CLASS AND A CV-QUALIFIER DECORATE A DECLARATION AND READ NOTHING
    -- (CART-0404). `static String str;` has no `init_declarator` and no declarator wrapper,
    -- so it reaches the IR's lossy fallback, which claims a row only when EVERY named child
    -- is accounted for — and `static` was not, so the row fell to the generic `?` walk that
    -- reads the DECLARED NAME. Same category as lua's `<const>`/`<close>` (CART-0234), which
    -- is why it belongs in this declared key and not in a base table: `storage_class_specifier`
    -- is a c/cpp node type and a name-keyed base set cannot say so.
    binding_modifiers = { storage_class_specifier = true, type_qualifier = true },
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
        -- ★★ A `function_definition` HAS NO `parameters` FIELD, so `params_field` alone found
        -- NOTHING and EVERY c/cpp function carried an EMPTY param list — silently, for as long as
        -- the spec has existed (CART-0438). The list hangs one level down, on the
        -- `function_declarator`, and through a pointer/reference wrapper for `int *f(int a)`.
        -- ★ THE INNERMOST declarator, not the first: a C++20 constrained constructor nests a
        -- SECOND `function_declarator` whose `parameters` is the misparsed member-init args
        -- (CART-0435), so the outermost one answers the wrong list. Same descent the name walk
        -- makes, for the same reason.
        params_of = function (def)
            local d, last = def:field('declarator')[1], nil
            while d do
                if d:type() == 'function_declarator' then last = d end
                d = d:field('declarator')[1]
            end
            return last and last:field('parameters')[1] or nil
        end,
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
