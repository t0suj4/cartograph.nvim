-- The CPP language spec (L0 grammar binding + L1 name model)
-- extracted from the engine ([[cartograph-spec-layering]] P1). Pure motion.

-- @langs cpp — a spec IS one grammar's mapping, so every node type here is
-- cpp's by construction.

local tsutil = require 'cartograph.spec.tsutil'
local node_text = tsutil.node_text

return {
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
        qualified_identifier = 'name', -- N::NAME
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
    -- ★★ A MACRO BETWEEN `class` AND ITS NAME DISSOLVES THE WHOLE CLASS (CART-0439).
    -- `class V8_EXPORT_PRIVATE Foo : public Base { … };` does not parse as a class at
    -- all: the class_specifier TERMINATES AT THE MACRO (which becomes its `name`), the
    -- real name falls into an ERROR or a bare declarator, and the class BODY becomes a
    -- function_definition's compound_statement — so the class node, every method, the
    -- base clause and the access specifiers are all gone at once, and every member is
    -- harvested as a FREE FUNCTION. 903 declarations in v8 alone (611 V8_EXPORT_PRIVATE,
    -- 205 V8_NODISCARD, …), and it is the DOMINANT class-declaration idiom of any C++
    -- library with an export macro. src/objects/tagged.h: 59 functions, ZERO classes.
    --
    -- THE REPAIR IS THE ONE THE GRAMMAR CANNOT DO: blank the macro token with SPACES and
    -- re-parse. Length-preserving, so every byte offset, line and column is unchanged —
    -- the repaired tree is byte-for-byte addressable exactly as the raw one — and the
    -- resulting tree is the CONTROL tree, so `interface`, `qualify`, `is_method`,
    -- `block_skip` and flow all work unmodified. A query-level fix could only ever mint
    -- the class node back; it could not turn a labeled_statement into an access
    -- specifier or a compound_statement into a field_declaration_list.
    --
    -- ★ THE GATE IS STRUCTURAL, AND IT FIRES ONLY WHERE THE PARSE IS ALREADY WRONG —
    -- which is why this needs NO macro list and no SCREAMING_CAPS heuristic, and cannot
    -- fabricate. A function_definition whose `type:` is a BODYLESS class/struct/union
    -- specifier is either this wreck or a genuine elaborated-type return
    -- (`class JitPage* JitPage() { … }`, `struct Foo make() { … }`) — and the genuine one
    -- is exactly the case whose declarator unwraps to a function_declarator with no ERROR
    -- sitting BEFORE it. The ERROR-before-declarator test is load-bearing: v8's
    -- `class V8_EXPORT_PRIVATE AsmCallableType : public NON_EXPORTED_BASE(ZoneObject)`
    -- parses its BASE CLAUSE as the function_declarator, so declarator shape alone would
    -- have called 55 of 250 measured wrecks genuine.
    --
    -- Iterated to a fixpoint by the caller: `class V8_EXPORT_PRIVATE V8_NODISCARD Foo`
    -- needs two rounds, and `extern template class EXPORT_TEMPLATE_DECLARE(V8_EXPORT_PRIVATE)`
    -- never converges to a class — the `name` requirement stops it after one.
    src_repair = function (root, src)
        -- ★ A PLAIN-TEXT SUPERSET FILTER FIRST, because the tree walk is paid by every
        -- C++ file and collected by almost none. The wreck ALWAYS reads
        -- `class <ident> <ident>` in the bytes (the macro then the real name), so a
        -- file without that text cannot hold one. MEASURED: it rejects 93% of colobot's
        -- 467 C++ files and 94% of 7kaa's 514 before any tree is walked, and what
        -- survives costs 2.9% / 4.0% of a cold extract. A superset — it can only save
        -- work, never skip a hit.
        if not (src:find('%f[%w_]class%s+[%a_][%w_]*%s+[%a_]')
                or src:find('%f[%w_]struct%s+[%a_][%w_]*%s+[%a_]')
                or src:find('%f[%w_]union%s+[%a_][%w_]*%s+[%a_]')) then
            return nil
        end
        local hits
        local function fn_declarator(d)
            while d do
                local t = d:type()
                if t == 'function_declarator' then return true end
                if t ~= 'pointer_declarator' and t ~= 'reference_declarator' then
                    return false
                end
                d = d:field('declarator')[1]
            end
            return false
        end
        local function scan (n)
            if n:type() == 'function_definition' then
                local ty = n:field('type')[1]
                local tt = ty and ty:type()
                if (tt == 'class_specifier' or tt == 'struct_specifier'
                        or tt == 'union_specifier')
                    and ty:field('name')[1] and #ty:field('body') == 0 then
                    local decl = n:field('declarator')[1]
                    local genuine = fn_declarator(decl)
                    if genuine and decl then
                        -- …unless an ERROR sits between the specifier and the
                        -- declarator: then the "function declarator" is a mangled
                        -- base clause, not a signature.
                        local _, _, db = decl:start()
                        for c in n:iter_children() do
                            if c:type() == 'ERROR' then
                                local _, _, eb = c:start()
                                if eb < db then genuine = false break end
                            end
                        end
                    end
                    if not genuine then
                        local nm = ty:field('name')[1]
                        local _, _, sb = nm:start()
                        local _, _, eb = nm:end_()
                        -- ★★ AND IS THE SPECIFIER'S `name` REALLY THE MACRO? A wreck can
                        -- ALSO come from a macro in the BASE CLAUSE
                        -- (`struct TSCallDescriptor : public NON_EXPORTED_BASE(ZoneObject)`,
                        -- 5 sites measured), where the specifier's name is the REAL CLASS
                        -- NAME and blanking it DESTROYS it — measured: it cost
                        -- operations.h its EffectHandler struct and both its methods. The
                        -- tell is what follows the name: another identifier means the name
                        -- was a macro and the real one is next; `:`/`{`/`(`/`<` means the
                        -- name is the class and the damage is downstream, which this
                        -- repair does not claim to fix. `final` is a class-virt-specifier,
                        -- not a name — the one keyword this has to know.
                        local body = n:field('body')[1]
                        local bb = eb
                        if body then local _, _, b = body:start(); bb = b end
                        local after = src:sub(eb + 1, bb):gsub('^%s+', '')
                        if after:match('^[A-Za-z_]') and not after:match('^final%f[%W]')
                        then
                            hits = hits or {}
                            hits[#hits + 1] = { sb, eb }
                        end
                    end
                end
            end
            for c in n:iter_children() do
                if c:named() or c:type() == 'ERROR' then scan(c) end
            end
        end
        scan(root)
        if not hits then return nil end
        -- blank back-to-front so earlier offsets stay valid
        table.sort(hits, function (a, b) return a[1] > b[1] end)
        for _, h in ipairs(hits) do
            src = src:sub(1, h[1]) .. (' '):rep(h[2] - h[1]) .. src:sub(h[2] + 1)
        end
        return src
    end,
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
        -- a lambda is a function SCOPE, not a def: it never reaches the
        -- `functions` query (no name), but "which function encloses this?"
        -- must answer the lambda, not the member it sits inside.
        fn_types = { function_definition = true, lambda_expression = true },
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
