-- Tree-sitter GraphProvider: the SECOND provider, and the one that makes the
-- cockpit language-agnostic. It produces the same neutral schema the lua-ls
-- CLI emits (nodes/edges/calls), from nothing but parse trees — in-editor,
-- no server, any language with a parser and a spec below.
--
-- Honesty contract: tree-sitter has no type resolution, so every cross-file
-- link is NAME-MATCHED — exactly the `~`/inferred vocabulary the browser
-- already renders. Same-file exact matches are kept plain; cross-file unique
-- names are inferred; ambiguous names refuse to link (the lua-ls fallback
-- rule). Capabilities are partial by construction: `df` is a lite
-- approximation (statement lines, def/use names), `effects`/`rets` are not
-- emitted; consumers already degrade to honest frontiers.

local M = {}

-- Node text, hot-path fast form. vim.treesitter.get_node_text allocates two
-- throwaway tables (opts, metadata) on EVERY call before doing this same
-- byte-slice; over a big corpus that is millions of dead tables feeding the
-- GC. We only ever pass a string source and never metadata, so the slice is
-- byte-for-byte identical (multiline included) without the allocation.
local function node_text(n, src)
    return src:sub(select(3, n:start()) + 1, select(3, n:end_()))
end

-- shared empty iterator: the `... or function () end` fallback used to allocate
-- a fresh closure on every nil-children branch in hot loops
local function NOOP() end

-- ── per-language specs ───────────────────────────────────────────────────────
-- Each spec: file extensions, tree-sitter queries with a shared capture
-- protocol (@def/@name for functions and vars, @call/@name for calls), and
-- small hooks where grammars genuinely differ.

-- php PSR-4 suffix imports: basename -> {files} index, memoized per
-- fileset (weak keys: dies with the fileset, workers build their own)
local PHP_BASENAMES = setmetatable({}, { __mode = 'k' })

-- a REFUSAL is a place: when resolution declines to pick, the call
-- keeps the rule that refused and (capped, sorted — worker == inline)
-- the candidates it refused between, so the browser can descend into
-- the fork instead of a dead end
local function refusal(rule, list)
    if not list or #list == 0 then return { rule = rule } end
    local ids = {}
    for i = 1, math.min(#list, 8) do ids[i] = list[i].id end
    table.sort(ids)
    return { rule = rule, cands = ids, n = #list }
end

-- Java receiver typing. Unlike php's `$var` (untyped), Java DECLARES the type
-- of every receiver lexically, so a call's receiver often resolves to a
-- concrete class by a bounded lexical lookup — no flow analysis, no server.
-- The base name of a type node: `List<Pet>` -> List, `a.b.Foo` -> Foo.
local function java_base_type(tnode, src)
    if not tnode then return nil end
    local t = tnode:type()
    if t == 'type_identifier' then
        return node_text(tnode, src)
    elseif t == 'generic_type' then
        local first = tnode:child(0) -- the erased base precedes type_arguments
        if first and first:type() == 'type_identifier' then
            return node_text(first, src)
        end
    elseif t == 'scoped_type_identifier' then
        return node_text(tnode, src):match('([%w_]+)%s*$')
    end
    return nil
end

-- JDK types whose methods are stdlib vocabulary, not project defs: a
-- receiver of this type must NOT be qualified (Optional::get would tail-match
-- a project get()). Best-effort — the common collection/util/lang surface.
local JAVA_JDK_TYPES = {}
for _, t in ipairs({ 'String', 'StringBuilder', 'StringBuffer', 'CharSequence',
    'Object', 'Class', 'Integer', 'Long', 'Double', 'Float', 'Boolean', 'Byte',
    'Short', 'Character', 'Number', 'Math', 'System', 'Thread', 'Optional',
    'List', 'ArrayList', 'LinkedList', 'Map', 'HashMap', 'TreeMap',
    'LinkedHashMap', 'Set', 'HashSet', 'TreeSet', 'LinkedHashSet', 'Collection',
    'Collections', 'Arrays', 'Iterator', 'Iterable', 'Stream', 'Queue',
    'Deque', 'Stack', 'File', 'Path', 'Paths', 'Files', 'Date', 'Calendar',
    'LocalDate', 'LocalDateTime', 'Instant', 'Duration', 'BigDecimal',
    'BigInteger', 'Pattern', 'Matcher', 'Objects', 'Comparator' }) do
    JAVA_JDK_TYPES[t] = true
end

-- the enclosing class/interface/enum/record: its name + declaration node
local function java_enclosing_class(node, src)
    local p = node:parent()
    while p do
        local t = p:type()
        if t == 'class_declaration' or t == 'interface_declaration'
            or t == 'enum_declaration' or t == 'record_declaration' then
            local cn = p:field('name')[1]
            return cn and node_text(cn, src) or nil, p
        end
        p = p:parent()
    end
end

-- Java scope spec for the ScopeModel (cartograph.scope): which node types
-- open scopes and how to harvest their binders. This IS the old memoized
-- jvt_scope_sym, expressed as data + three harvesters; the model owns the
-- lazy per-scope memo (profiling: the per-call AST re-walk this replaces was
-- ~35% of extraction).
local function jvt_locals(node, src, out) -- name -> {ty, row} (position-checked)
    for c in node:iter_children() do
        if c:type() == 'local_variable_declaration' then
            local ty, row = java_base_type(c:field('type')[1], src), select(1, c:range())
            for d in c:iter_children() do
                if d:type() == 'variable_declarator' then
                    local nm = d:field('name')[1]
                    if nm then out[node_text(nm, src)] = { ty = ty, row = row } end
                end
            end
        end
    end
end
local function jvt_params(node, src, out) -- name -> {ty}
    local ps = node:field('parameters')[1]
    for c in (ps and ps:iter_children() or NOOP) do
        if c:type() == 'formal_parameter' or c:type() == 'spread_parameter' then
            local nm = c:field('name')[1]
            if nm then out[node_text(nm, src)] = { ty = java_base_type(c:field('type')[1], src) } end
        end
    end
end
local function jvt_fields(node, src, out) -- name -> {ty}
    for c in node:iter_children() do
        if c:type() == 'field_declaration' then
            local ty = java_base_type(c:field('type')[1], src)
            for d in c:iter_children() do
                if d:type() == 'variable_declarator' then
                    local nm = d:field('name')[1]
                    if nm then out[node_text(nm, src)] = { ty = ty } end
                end
            end
        end
    end
end
local JAVA_SCOPES = {
    block                   = { kind = 'local', harvest = jvt_locals },
    constructor_body        = { kind = 'local', harvest = jvt_locals },
    method_declaration      = { kind = 'param', harvest = jvt_params },
    constructor_declaration = { kind = 'param', harvest = jvt_params },
    lambda_expression       = { kind = 'param', harvest = jvt_params },
    class_body              = { kind = 'field', harvest = jvt_fields },
    enum_body               = { kind = 'field', harvest = jvt_fields },
}

-- one model per file being extracted; reset in extract_calls (per-tree
-- lifetime — node ids cannot alias across trees)
local jvt_sm, jvt_src = nil, nil
local function jvt_model(src)
    if not jvt_sm or jvt_src ~= src then
        jvt_sm = require('cartograph.scope').model(src, JAVA_SCOPES)
        jvt_src = src
    end
    return jvt_sm
end

-- the declared type name of a simple variable `ident` visible at `from`.
-- MECHANISM: scope.resolve — every visible binder, nearest first (inner
-- shadows outer; block locals position-checked). POLICY (here, deliberately):
--   * a param answers unconditionally, even untyped — matching a param ends
--     the question;
--   * an untyped local/field (scoped-generic base java_base_type can't name)
--     is TRANSPARENT — the shadowed outer binder answers. Optimistic: pinned
--     by the shadowedTally test; the resolve-but-mark change (step 2) flips
--     exactly this loop, knowingly.
-- `fields_only` restricts to class fields (a `this.field` receiver).
local function java_var_type(ident, from, src, fields_only)
    local chain, k = jvt_model(src).resolve(ident, from, fields_only and 'field' or nil)
    for i = 1, k do
        local b = chain[i]
        if b.kind == 'param' or b.ty ~= nil then return b.ty end
    end
end

M.spec = {
    lua = {
        exts = { 'lua' },
        functions = [[
            (function_declaration name: (_) @name) @def
            (assignment_statement
                (variable_list name: (_) @name)
                (expression_list value: (function_definition) @def))
            (field name: (identifier) @name value: (function_definition) @def)
        ]],
        -- a function VALUE in a table field is registry-style: invoked
        -- through the table, invisible to a name graph
        field_fn_cbarg = true,
        calls = [[ (function_call name: (_) @name) @call ]],
        vars = [[
            (variable_declaration
                (assignment_statement
                    (variable_list name: (identifier) @name)
                    (expression_list value: (_) @value))) @def
            (chunk
                (assignment_statement
                    (variable_list name: (identifier) @name)
                    (expression_list value: (_) @value)) @def)
        ]],
        params_field = 'parameters',
        body_field = 'body',
        is_method = function (name) return name:find(':') ~= nil end,
        -- `require "x"` / `local x = require "x"`: module -> file
        import_call = 'require',
        resolve_import = function (mod, files)
            local slashed = mod:gsub('%.', '/')
            for _, cand in ipairs({ slashed .. '.lua', slashed .. '/init.lua', mod .. '.lua' }) do
                if files[cand] then return cand end
            end
        end,
        -- which LOCAL names this import: `local util = require 'x'`
        -- binds util (positional in multi-assignments; nil when unclear)
        import_bind = function (calln, src)
            local el = calln:parent()
            if not el or el:type() ~= 'expression_list' then return nil end
            local as = el:parent()
            if not as or as:type() ~= 'assignment_statement' then return nil end
            local vl
            for c in as:iter_children() do
                if c:type() == 'variable_list' then vl = c break end
            end
            if not vl then return nil end
            local vi, i = 0, 0
            for c in el:iter_children() do
                if c:named() then
                    i = i + 1
                    if c:equal(calln) then vi = i end
                end
            end
            i = 0
            for c in vl:iter_children() do
                if c:named() then
                    i = i + 1
                    if i == vi then
                        local n = node_text(c, src)
                        return n:match('^[%w_]+$') and n or nil
                    end
                end
            end
        end,
        -- what a NEW import of `dest` looks like here, and the alias it
        -- introduces — the write side of the wiring the verbs disclose
        import_line = function (dest)
            local mod = dest:gsub('%.lua$', ''):gsub('/init$', ''):gsub('/', '.')
            local alias = dest:match('([%w_]+)%.lua$')
            if alias == 'init' then alias = dest:match('([%w_]+)/init%.lua$') end
            if not alias then return nil end
            return ('local %s = require \'%s\''):format(alias, mod), alias
        end,
        -- lines that ARE imports (placement: a new one goes after the last)
        import_pats = { '^local%s+[%w_,%s]-=%s*require%f[%W]', '^require%f[%W]' },
        litdata_types = { table_constructor = true },
        -- stdlib receivers must not tail-match a project def: string.format
        -- would otherwise link to the one module that defines M.format
        stdlib_prefixes = { 'string.', 'table.', 'math.', 'os.', 'io.',
            'coroutine.', 'debug.', 'bit.', 'jit.', 'ffi.', 'vim.' },
        -- load-time side effects (ported from the retired lua-ls --graph
        -- CLI): assigning a global, mutating a global-rooted table
        -- (function table.x() included), or a bare call at the top
        -- level. Feeds sideeffect-vs-deadimport classification and the
        -- move verbs' load-order hazard.
        module_effects = function (root, src)
            local locals = {}
            local function collect_names(vl)
                for v in vl:iter_children() do
                    if v:named() then
                        local n = node_text(v, src)
                        locals[n:match('^[%w_]+') or n] = true
                    end
                end
            end
            for stmt in root:iter_children() do
                local t = stmt:type()
                if t == 'variable_declaration' then
                    for c in stmt:iter_children() do
                        if c:type() == 'assignment_statement' then
                            for vl in c:iter_children() do
                                if vl:type() == 'variable_list' then
                                    collect_names(vl)
                                end
                            end
                        end
                    end
                elseif t == 'function_declaration' then
                    local islocal = false
                    for c in stmt:iter_children() do
                        if c:type() == 'local' then islocal = true end
                    end
                    if islocal then
                        local nm = stmt:field('name')[1]
                        if nm then
                            locals[node_text(nm, src)] = true
                        end
                    end
                end
            end
            for stmt in root:iter_children() do
                local t = stmt:type()
                if t == 'function_call' then
                    return true -- a bare call runs at load time
                elseif t == 'assignment_statement' then
                    for vl in stmt:iter_children() do
                        if vl:type() == 'variable_list' then
                            for v in vl:iter_children() do
                                if v:named() then
                                    local rootname = node_text(v, src):match('^[%w_]+')
                                    if rootname and not locals[rootname] then
                                        return true -- global(-rooted) write
                                    end
                                end
                            end
                        end
                    end
                elseif t == 'function_declaration' then
                    local islocal = false
                    for c in stmt:iter_children() do
                        if c:type() == 'local' then islocal = true end
                    end
                    if not islocal then
                        local nm = stmt:field('name')[1]
                        local rootname = nm and node_text(nm, src):match('^[%w_]+')
                        if rootname and not locals[rootname] then
                            return true -- global fn / global-rooted method
                        end
                    end
                end
            end
        end,
    },
    c = {
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
                declarator: (identifier) @name value: (_) @value)) @def
            (declaration declarator: (init_declarator
                declarator: (array_declarator declarator: (identifier) @name)
                value: (_) @value)) @def
            (declaration declarator: (identifier) @name) @def
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
    },
    cpp = {
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
                declarator: (identifier) @name value: (_) @value)) @def
            (declaration declarator: (init_declarator
                declarator: (array_declarator declarator: (identifier) @name)
                value: (_) @value)) @def
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
    },
    haskell = {
        exts = { 'hs' },
        functions = [=[
            (function name: (variable) @name) @def
            (bind name: (variable) @name) @def
        ]=],
        -- application is a nested spine; the innermost apply holds the head
        calls = [=[ (apply function: (variable) @name) @call ]=],
        vars = nil,
        params_field = 'patterns',
        body_field = nil, -- df comes from the custom hook below
        fn_types = { ['function'] = true, bind = true },
        id_query = '(variable) @id',
        -- where-clause binds are a function's INTERIOR (df rows), not nodes:
        -- indexing `e`/`go`/`args` by name would link every pattern variable
        toplevel_only = true,
        merge_equations = true, -- step 0 = ...; step x = ... is ONE function
        cbarg_within = { instance_declarations = true }, -- typeclass dispatch
        block_container = 'declarations',
        block_skip = { signature = true, pragma = true },
        is_method = function () return false end,
        entry_names = { main = true },
        import_query = [=[ (import module: (module) @path) ]=],
        resolve_import = function (mod, files)
            -- source roots differ (compiler/, libraries/x/src/) and the
            -- extraction root may sit INSIDE the module hierarchy: match
            -- path suffixes in either direction, unique-or-refuse
            local suffix, hit = mod:gsub('%.', '/') .. '.hs', nil
            for f in pairs(files) do
                local m = f == suffix
                    or f:sub(-#suffix - 1) == '/' .. suffix
                    or suffix:sub(-#f - 1) == '/' .. f
                if m then
                    if hit then return nil end
                    hit = f
                end
            end
            return hit
        end,
        -- df-lite from the equation body + where clause: each where-bind is
        -- a "statement" (def = its name), the match expression leads
        dataflow = function (def, spec, src)
            local stmts = {}
            local function names(n, out, seen)
                if n:type() == 'variable' then
                    local t = node_text(n, src)
                    if not seen[t] then seen[t] = true out[#out + 1] = t end
                    return
                end
                for c in n:iter_children() do
                    if c:named() then names(c, out, seen) end
                end
            end
            local m = def:field('match')[1]
            if m then
                local use = {}
                names(m, use, {})
                stmts[#stmts + 1] = { l = m:range() + 1, def = {}, use = use, dep = {} }
            end
            local lb = def:field('binds')[1]
            if lb then
                for d in lb:iter_children() do
                    if d:named() and (d:type() == 'bind' or d:type() == 'function') then
                        local namen = d:field('name')[1]
                        local use = {}
                        names(d, use, {})
                        stmts[#stmts + 1] = { l = d:range() + 1,
                            def = namen and { node_text(namen, src) } or {},
                            use = use, dep = {} }
                    end
                end
            end
            if #stmts == 0 then return nil end
            table.sort(stmts, function (a, b) return a.l < b.l end)
            return { inputs = {}, stmts = stmts }
        end,
    },
    scheme = {
        exts = { 'scm' },
        functions = [=[
            ((list . (symbol) @_kw . (list . (symbol) @name)) @def
                (#eq? @_kw "define"))
            ((list . (symbol) @_kw . (symbol) @name . (list . (symbol) @_l)) @def
                (#eq? @_kw "define") (#eq? @_l "lambda"))
            ((list . (symbol) @_kw . (list . (symbol) @name)) @def
                (#eq? @_kw "define-public"))
            ((list . (symbol) @_kw . (symbol) @name . (list . (symbol) @_l)) @def
                (#eq? @_kw "define-public") (#eq? @_l "lambda"))
        ]=],
        -- every list head is application — special forms opt out below
        calls = [=[ (list . (symbol) @name) @call ]=],
        vars = [=[
            ((list . (symbol) @_kw . (symbol) @name . (number) @value) @def
                (#eq? @_kw "define"))
            ((list . (symbol) @_kw . (symbol) @name . (string) @value) @def
                (#eq? @_kw "define"))
        ]=],
        body_field = nil,
        id_query = '(symbol) @id',
        toplevel_parent = 'program', -- internal defines are a function's interior
        is_method = function () return false end,
        entry_names = { main = true },
        -- the R5RS core + named-let idiom names: guile DEFINES apply/map in
        -- scheme (self-hosted), but a call to `apply` means the primitive
        stdlib_names = { apply = true, map = true, error = true, list = true,
            cons = true, car = true, cdr = true, append = true, filter = true,
            assoc = true, assq = true, assv = true, member = true, memq = true,
            length = true, reverse = true, vector = true, string = true,
            format = true, display = true, write = true, equal = true,
            loop = true, lp = true, iter = true, recur = true, rec = true,
            fold = true, reduce = true, cont = true, ['for-each'] = true },
        call_skip = { define = true, ['define*'] = true, ['define-public'] = true,
            ['define-syntax'] = true, ['define-module'] = true,
            ['define-record-type'] = true, lambda = true, ['lambda*'] = true,
            let = true, ['let*'] = true, letrec = true, ['letrec*'] = true,
            ['if'] = true, cond = true, case = true, when = true, unless = true,
            begin = true, ['and'] = true, ['or'] = true, ['else'] = true,
            ['set!'] = true, quote = true, quasiquote = true, unquote = true,
            ['do'] = true, delay = true, parameterize = true,
            ['with-syntax'] = true, ['syntax-rules'] = true, ['syntax-case'] = true,
            ['use-modules'] = true, export = true, import = true },
        -- the signature/param list of a define/lambda is NOT an application:
        -- `(define (f x) …)` / `(lambda (x) …)` — the `(f x)` / `(x)` is the
        -- form's SECOND element, and treating it as a call made every fn its
        -- own (bogus) caller. Real calls are the body forms (3rd+ elements).
        skip_call = function (calln, src)
            local p = calln:parent()
            if not (p and p:type() == 'list') then return false end
            local head = p:named_child(0)
            if not (head and head:type() == 'symbol') then return false end
            local kw = node_text(head, src)
            local sig = kw == 'lambda' or kw == 'lambda*' or kw:match('^define')
            return sig and calln == p:named_child(1) or false
        end,
        -- a call runs at load unless its OUTERMOST form is a define
        is_top = function (calln, src)
            local n, outer = calln, calln
            while n:parent() do
                if n:parent():type() == 'program' then outer = n break end
                n = n:parent()
            end
            if outer == calln then return true end
            local head = outer:named_child(0)
            local t = head and node_text(head, src) or ''
            return not t:match('^define')
        end,
        import_query = [=[
            ((list . (symbol) @_kw (list) @path) (#eq? @_kw "use-modules"))
            ((keyword) @_k . (list) @path (#eq? @_k "#:use-module"))
        ]=],
        resolve_import = function (mod, files)
            local parts = {}
            for w in mod:gmatch('[^%s()]+') do parts[#parts + 1] = w end
            local suffix, hit = table.concat(parts, '/') .. '.scm', nil
            for f in pairs(files) do
                local m = f == suffix
                    or f:sub(-#suffix - 1) == '/' .. suffix
                    or suffix:sub(-#f - 1) == '/' .. f
                if m then
                    if hit then return nil end
                    hit = f
                end
            end
            return hit
        end,
    },
    javascript = {
        exts = { 'js', 'mjs', 'cjs' },
        functions = [=[
            (function_declaration name: (identifier) @name) @def
            (method_definition name: (property_identifier) @name) @def
            (variable_declarator name: (identifier) @name value: (arrow_function) @def)
            (variable_declarator name: (identifier) @name value: (function_expression) @def)
            (pair key: (property_identifier) @name value: (arrow_function) @def)
            (pair key: (property_identifier) @name value: (function_expression) @def)
        ]=],
        calls = [=[
            (call_expression function: (identifier) @name) @call
            (call_expression function: (member_expression) @name) @call
        ]=],
        vars = [=[
            (program (lexical_declaration
                (variable_declarator name: (identifier) @name value: (_) @value) @def))
            (program (variable_declaration
                (variable_declarator name: (identifier) @name value: (_) @value) @def))
        ]=],
        params_field = 'parameters',
        body_field = 'body',
        fn_types = { function_declaration = true, method_definition = true,
            arrow_function = true, function_expression = true },
        is_method = function (_, def) return def:type() == 'method_definition' end,
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
        import_query = [=[ (import_statement source: (string) @path) ]=],
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
    },
    php = {
        exts = { 'php' },
        functions = [=[
            (function_definition name: (name) @name) @def
            (method_declaration name: (name) @name) @def
        ]=],
        calls = [=[
            (function_call_expression function: (name) @name) @call
            (member_call_expression name: (name) @name) @call
            (scoped_call_expression name: (name) @name) @call
            (function_call_expression function: (variable_name) @name) @call
        ]=],
        -- call_user_func('name', ...) CALLS name: the literal resolves as
        -- the real callee (the string is the dispatch mechanism, not a ~)
        indirect_calls = { call_user_func = 1, call_user_func_array = 1 },
        -- a variable in callee position is runtime state ($fn()) — by NODE
        -- TYPE: jQuery's $() is a plain identifier and must stay a call
        dynamic_callee_types = { variable_name = true },
        vars = [=[
            (program (expression_statement (assignment_expression
                left: (variable_name (name) @name) right: (_) @value) @def))
            (const_declaration (const_element (name) @name (_) @value) @def)
        ]=],
        params_field = 'parameters',
        body_field = 'body',
        fn_types = { function_definition = true, method_declaration = true,
            anonymous_function_creation_expression = true, arrow_function = true },
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
            for c in defn:iter_children() do
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
            if name:find(':', 1, true) then return nil end
            local t, kind = calln:type(), nil
            if t == 'member_call_expression' then
                local o = calln:field('object')[1]
                if o and o:type() == 'variable_name'
                    and node_text(o, src) == '$this' then
                    kind = 'self'
                end
            elseif t == 'scoped_call_expression' then
                local s = calln:field('scope')[1]
                if s and s:type() == 'relative_scope' then
                    kind = node_text(s, src) == 'parent'
                        and 'parent' or 'self'
                end
            end
            if not kind then return nil end
            local p2 = calln:parent()
            while p2 do
                local tt = p2:type()
                if tt == 'class_declaration' or tt == 'trait_declaration'
                    or tt == 'interface_declaration' then
                    if kind == 'self' then
                        local cn = p2:field('name')[1]
                        return cn and (node_text(cn, src)
                            .. '::' .. name) or nil
                    end
                    -- parent::m — resolve to the superclass named by the
                    -- enclosing class's base_clause. A trait has no
                    -- base_clause (its parent is the using class, unknown
                    -- here) → decline and stay a refusal. When the direct
                    -- parent only INHERITS m (no exact Parent::m def), the
                    -- name falls through to the tail path unchanged — no
                    -- worse than today, honest about the chain we can't walk.
                    for c in p2:iter_children() do
                        if c:type() == 'base_clause' then
                            for pc in c:iter_children() do
                                local pt = pc:type()
                                if pt == 'name' or pt == 'qualified_name' then
                                    -- def keys use the bare class name; take
                                    -- the last namespace segment (\App\Foo→Foo;
                                    -- PSR-0 Mage_Core_X has no '\' → stays whole)
                                    local ptxt = node_text(pc, src)
                                    return (ptxt:match('[^\\]+$') or ptxt)
                                        .. '::' .. name
                                end
                            end
                        end
                    end
                    return nil
                end
                p2 = p2:parent()
            end
        end,
        id_query = '(name) @id',
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
        import_query = [=[
            (require_once_expression (string) @path)
            (require_expression (string) @path)
            (include_once_expression (string) @path)
            (include_expression (string) @path)
            (namespace_use_clause (qualified_name) @path)
            (base_clause (name) @path)
            (base_clause (qualified_name) @path)
            (class_interface_clause (name) @path)
            (class_interface_clause (qualified_name) @path)
        ]=],
        resolve_import = function (path, files, from)
            path = path:gsub('^["\']', ''):gsub('["\']$', '')
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
    },
    ruby = {
        exts = { 'rb' },
        functions = [=[
            (method name: (_) @name) @def
            (singleton_method name: (_) @name) @def
        ]=],
        calls = [=[
            (call method: (identifier) @name) @call
            (call method: (constant) @name) @call
        ]=],
        vars = [=[
            (program (assignment
                left: (constant) @name right: (_) @value) @def)
        ]=],
        params_field = 'parameters',
        body_field = 'body',
        is_method = function (_, def)
            if def:type() == 'singleton_method' then return true end
            local p = def:parent()
            while p do
                local t = p:type()
                if t == 'class' or t == 'module'
                    or t == 'singleton_class' then return true end
                p = p:parent()
            end
            return false
        end,
        -- Owner#full_name (instance) / Owner.find_by_city (singleton)
        qualify = function (name, defn, src)
            local sep = defn:type() == 'singleton_method' and '.' or '#'
            local p = defn:parent()
            while p do
                local t = p:type()
                if t == 'class' or t == 'module' then
                    local cn = p:field('name')[1]
                    return cn and (node_text(cn, src)
                        .. sep .. name) or name
                end
                p = p:parent()
            end
            return name
        end,
        -- classes/modules wrap the real content
        block_skip = { class = true, module = true, singleton_class = true },
        -- bare calls dispatch on self, and inheritance/mixins make the
        -- target unknowable beyond the file: ruby's scope IS the file —
        -- bare names never link cross-file. Honesty over reach: most
        -- ruby calls SHOULD stay unresolved frontiers.
        scope = function (file, _)
            return file
        end,
        id_fn_refs = false,
        -- ruby/rails vocabulary: Object protocol, Enumerable, ActiveRecord
        -- query/persistence verbs — never absorbed by a project def
        stdlib_names = { new = true, save = true, update = true,
            destroy = true, find = true, where = true, all = true,
            first = true, last = true, count = true, create = true,
            name = true, id = true, to_s = true, to_a = true, to_h = true,
            each = true, map = true, select = true, reject = true,
            include = true, present = true, blank = true, empty = true,
            length = true, size = true, push = true, params = true,
            render = true, call = true, run = true, perform = true,
            process = true, build = true, valid = true, inspect = true,
            hash = true, dup = true, freeze = true, fetch = true,
            dig = true, merge = true, join = true, split = true,
            strip = true, gsub = true, sub = true, match = true,
            scan = true, upcase = true, downcase = true, key = true,
            keys = true, values = true, sort = true, uniq = true,
            flatten = true, compact = true, reduce = true, inject = true,
            title = true, body = true, value = true, type = true,
            status = true, message = true, errors = true, user = true },
        import_call = 'require_relative',
        resolve_import = function (mod, files, from)
            local dir = from and from:match('^(.*)/[^/]*$') or ''
            local rel = (dir ~= '' and dir .. '/' or '') .. mod .. '.rb'
            -- normalize ../ segments
            while rel:find('/[^/]+/%.%./') do
                rel = rel:gsub('/[^/]+/%.%./', '/', 1)
            end
            rel = rel:gsub('^%./', '')
            if files[rel] then return rel end
        end,
    },
    java = {
        exts = { 'java' },
        functions = [=[
            (method_declaration name: (identifier) @name) @def
            (constructor_declaration name: (identifier) @name) @def
        ]=],
        calls = [=[
            (method_invocation name: (identifier) @name) @call
            (object_creation_expression type: (type_identifier) @name) @call
        ]=],
        vars = [=[
            (field_declaration declarator: (variable_declarator
                name: (identifier) @name value: (_) @value)) @def
        ]=],
        params_field = 'parameters',
        body_field = 'body',
        is_method = function () return true end,
        -- methods carry their class, `::` like php (and Java's own method-ref
        -- syntax): OwnerController::processFindForm
        qualify = function (name, defn, src)
            local cls = java_enclosing_class(defn, src)
            return cls and (cls .. '::' .. name) or name
        end,
        -- receiver-aware qualification: Java declares receiver types, so a
        -- call's target class is often recoverable lexically. this.m()/bare
        -- m() dispatch on the enclosing class; super.m() on its superclass;
        -- x.m()/this.f.m() on x's/the field's DECLARED type. Rewriting to
        -- Class::m turns the largest refusal bucket (getters/setters shared
        -- across many model classes) into exact or inheritance-walked links.
        qualify_call = function (calln, name, src)
            if calln:type() ~= 'method_invocation' then return nil end
            local obj = calln:field('object')[1]
            local cls
            if not obj then -- implicit this
                cls = java_enclosing_class(calln, src)
            else
                local ot = obj:type()
                if ot == 'this' then
                    cls = java_enclosing_class(calln, src)
                elseif ot == 'super' then
                    local _, cnode = java_enclosing_class(calln, src)
                    local sup = cnode and cnode:field('superclass')[1]
                    for c in (sup and sup:iter_children() or NOOP) do
                        if c:type() == 'type_identifier' then
                            cls = node_text(c, src)
                            break
                        end
                    end
                elseif ot == 'identifier' then
                    cls = java_var_type(
                        node_text(obj, src), calln, src)
                elseif ot == 'field_access' then
                    local fo, ff = obj:field('object')[1], obj:field('field')[1]
                    if fo and fo:type() == 'this' and ff then
                        cls = java_var_type(
                            node_text(ff, src), calln, src, true)
                    end
                end
            end
            -- a JDK-typed receiver dispatches into the stdlib, not a project
            -- def: leave it bare for the stdlib_names/prefix gate to skip
            if cls and JAVA_JDK_TYPES[cls] then return nil end
            return cls and (cls .. '::' .. name) or nil
        end,
        -- single-inheritance chain (superclass only — interfaces would poison
        -- the one-parent-per-class model resolve_super relies on): feeds
        -- transitive super.m()/inherited this.m() resolution once built
        super_query = [=[
            (class_declaration
                name: (identifier) @child
                superclass: (superclass (type_identifier) @parent))
        ]=],
        entry_names = { main = true },
        -- an ANNOTATION WITH ARGUMENTS passes the method into a framework
        -- (@RequestMapping("/x"), @Scheduled(...)): registered, not dead —
        -- marker annotations (@Override) wrap without registering
        cbarg_def = function (defn, _)
            local mods = defn:child(0)
            if mods and mods:type() == 'modifiers' then
                for c in mods:iter_children() do
                    if c:type() == 'annotation' then return true end
                end
            end
            return false
        end,
        exported_def = function (defn, src)
            local mods = defn:child(0)
            if mods and mods:type() == 'modifiers' then
                return node_text(mods, src)
                    :find('public') ~= nil
            end
            return false
        end,
        -- the package (directory) scopes bare calls; qualified crosses
        scope = function (file, _)
            return file:match('^(.*)/[^/]*$') or ''
        end,
        id_fn_refs = false,
        stdlib_names = { get = true, set = true, add = true, size = true,
            isEmpty = true, toString = true, equals = true, hashCode = true,
            valueOf = true, of = true, build = true, builder = true,
            stream = true, collect = true, map = true, filter = true,
            forEach = true, format = true, println = true, append = true,
            put = true, remove = true, contains = true, length = true,
            charAt = true, substring = true, split = true, trim = true,
            parse = true, close = true, run = true, apply = true,
            accept = true, test = true, compare = true, next = true,
            iterator = true, getName = true, getId = true, getValue = true,
            setValue = true, orElse = true, orElseThrow = true },
        stdlib_prefixes = { 'System.', 'String.', 'Objects.', 'List.',
            'Map.', 'Set.', 'Collections.', 'Arrays.', 'Optional.',
            'Stream.', 'Integer.', 'Long.', 'Math.', 'Files.', 'Paths.' },
        import_query = [=[ (import_declaration (scoped_identifier) @path) ]=],
        resolve_import = function (path, files, _)
            -- com.example.pkg.Class -> the in-repo suffix .../pkg/Class.java
            local segs = {}
            for seg in path:gmatch('[%w_]+') do segs[#segs + 1] = seg end
            for i = 1, #segs do
                local cand = table.concat(segs, '/', i) .. '.java'
                if files[cand] then return cand end
                -- maven layout: the suffix sits under some src root the
                -- rel path includes; try the common prefix
                for _, pre in ipairs({ 'src/main/java/', 'src/test/java/' }) do
                    if files[pre .. cand] then return pre .. cand end
                end
            end
            return nil
        end,
    },
    go = {
        exts = { 'go' },
        functions = [=[
            (function_declaration name: (identifier) @name) @def
            (method_declaration name: (field_identifier) @name) @def
        ]=],
        calls = [=[
            (call_expression function: (identifier) @name) @call
            (call_expression function: (selector_expression) @name) @call
        ]=],
        vars = [=[
            (source_file (var_declaration (var_spec
                name: (identifier) @name value: (_) @value) @def))
            (source_file (const_declaration (const_spec
                name: (identifier) @name value: (_) @value) @def))
        ]=],
        params_field = 'parameters',
        body_field = 'body',
        is_method = function (_, def)
            return def:type() == 'method_declaration'
        end,
        -- methods carry their receiver type: Site.render
        qualify = function (name, defn, src)
            if defn:type() ~= 'method_declaration' then return name end
            local recv = defn:field('receiver')[1]
            if recv then
                local t = node_text(recv, src)
                    :match('%*?([%w_]+)%s*%)')
                    or node_text(recv, src)
                        :match('%*?([%w_]+)')
                if t then return t .. '.' .. name end
            end
            return name
        end,
        -- func main + func init: runtime-invoked, never dead
        entry_names = { main = true, init = true },
        -- the PACKAGE (directory) is Go's bare-name boundary
        scope = function (file, _)
            return file:match('^(.*)/[^/]*$') or ''
        end,
        -- capitalized = exported: no in-repo caller says nothing
        exported_def = function (defn, src)
            local nm = defn:field('name')[1]
            nm = nm and node_text(nm, src) or ''
            return nm:match('^%u') ~= nil
        end,
        -- Go identifiers are mostly locals/fields; fn-as-value flows
        -- through call args (argv upgrade), like rust
        id_fn_refs = false,
        stdlib_names = { append = true, len = true, cap = true, make = true,
            new = true, copy = true, delete = true, panic = true,
            recover = true, print = true, println = true, close = true,
            Error = true, String = true, Len = true, Less = true,
            Swap = true, Read = true, Write = true, Close = true,
            New = true, Get = true, Set = true, Do = true, Run = true,
            Add = true, Wait = true, Done = true, Lock = true,
            Unlock = true, Sprintf = true, Errorf = true, Printf = true },
        stdlib_prefixes = { 'fmt.', 'strings.', 'strconv.', 'os.', 'io.',
            'errors.', 'bytes.', 'time.', 'sync.', 'context.', 'filepath.',
            'path.', 'sort.', 'math.', 'net.', 'http.', 'url.', 'regexp.',
            'reflect.', 'json.', 'bufio.', 'log.', 'slices.', 'maps.',
            'atomic.', 'rand.', 'unicode.', 'utf8.', 'hex.', 'base64.',
            'sha256.', 'exec.', 'testing.', 'assert.', 'require.' },
        import_query = [=[ (import_spec path: (interpreted_string_literal) @path) ]=],
        resolve_import = function (path, files, _)
            -- module-path imports: find the suffix that exists in-repo,
            -- resolving to the package dir's eponymous or first-known file
            path = path:gsub('"', '')
            local segs = {}
            for seg in path:gmatch('[^/]+') do segs[#segs + 1] = seg end
            for i = 1, #segs do
                local dir = table.concat(segs, '/', i)
                local last = segs[#segs]
                for _, cand in ipairs({ dir .. '/' .. last .. '.go',
                    dir .. '/doc.go', dir .. '/' .. last .. 's.go' }) do
                    if files[cand] then return cand end
                end
            end
            return nil
        end,
    },
    rust = {
        exts = { 'rs' },
        functions = [[
            (function_item name: (identifier) @name) @def
            (macro_definition name: (identifier) @name) @def
        ]],
        calls = [[
            (call_expression function: (identifier) @name) @call
            (call_expression function: (field_expression) @name) @call
            (call_expression function: (scoped_identifier) @name) @call
            (macro_invocation macro: (identifier) @name) @call
        ]],
        vars = [[
            (const_item name: (identifier) @name value: (_) @value) @def
            (static_item name: (identifier) @name value: (_) @value) @def
        ]],
        params_field = 'parameters',
        body_field = 'body',
        -- fns inside impl/trait blocks are methods, carrying their type:
        -- Config::new — which also keeps every type's `new` distinct
        is_method = function (_, def)
            local p = def:parent()
            while p do
                local t = p:type()
                if t == 'impl_item' or t == 'trait_item' then return true end
                p = p:parent()
            end
            return false
        end,
        qualify = function (name, defn, src)
            local p = defn:parent()
            while p do
                local t = p:type()
                if t == 'impl_item' or t == 'trait_item' then
                    local ty = p:field('type')[1] or p:field('name')[1]
                    -- generics (Foo<T>) reduce to the base type name
                    if ty then
                        local txt = node_text(ty, src)
                            :match('^([%w_]+)')
                        if txt then return txt .. '::' .. name end
                    end
                    return name
                end
                p = p:parent()
            end
            return name
        end,
        entry_names = { main = true },
        -- impl/trait/mod wrap real content; type declarations are data
        block_skip = { impl_item = true, trait_item = true, mod_item = true,
            foreign_mod_item = true },
        -- `impl Trait for Type` methods are called through the trait —
        -- trait objects, generics — invisibly to a name graph: registered
        -- by construction, never dead (the @receiver lesson, rust edition)
        cbarg_def = function (defn, src)
            -- #[test]/#[bench]/#[no_mangle]: invoked by harness or linker
            local sib = defn:prev_named_sibling()
            while sib and sib:type() == 'attribute_item' do
                local t = node_text(sib, src)
                if t:find('test') or t:find('no_mangle')
                    or t:find('bench') then
                    return true
                end
                sib = sib:prev_named_sibling()
            end
            local p = defn:parent()
            while p do
                if p:type() == 'impl_item' then
                    return p:field('trait')[1] ~= nil
                end
                p = p:parent()
            end
            return false
        end,
        -- pub fns are a library crate's exported surface: no in-repo
        -- caller says nothing about their liveness
        exported_def = function (defn, _)
            for c in defn:iter_children() do
                if c:type() == 'visibility_modifier' then return true end
            end
            return false
        end,
        -- rust identifiers are mostly LOCALS (`let args = ...` shadows any
        -- fn named args); bare-fn-as-value flows through call arguments
        -- (the argv upgrade), so the id-pass mention branch is noise here
        id_fn_refs = false,
        -- x.foo() is METHOD syntax: it can never reach a free function,
        -- so dotted callees only ever match method defs
        dot_calls_are_methods = true,
        -- the CRATE is the name-resolution boundary: a bare identifier in
        -- one crate can never legally reach another crate's private fn,
        -- so workspace-unique is tested within the crate, never across
        scope = function (file, files)
            local dir = file:match('^(.*)/[^/]*$') or ''
            while dir ~= '' do
                if files[dir .. '/lib.rs'] or files[dir .. '/main.rs'] then
                    return dir
                end
                dir = dir:match('^(.*)/[^/]*$') or ''
            end
            return ''
        end,
        -- iterator/Option/Result vocabulary and ubiquitous trait methods:
        -- a project def with one of these names must not absorb the
        -- language's own calls
        stdlib_names = { clone = true, unwrap = true, expect = true,
            into = true, from = true, to_string = true, as_str = true,
            as_ref = true, as_bytes = true, iter = true, into_iter = true,
            next = true, len = true, push = true, pop = true, insert = true,
            get = true, map = true, and_then = true, unwrap_or = true,
            unwrap_or_else = true, collect = true, to_owned = true,
            borrow = true, lock = true, read = true, write = true,
            send = true, recv = true, join = true, spawn = true,
            contains = true, starts_with = true, ends_with = true,
            split = true, trim = true, parse = true, is_empty = true,
            is_some = true, is_none = true, ok = true, err = true,
            default = true, new = true, fmt = true, eq = true, cmp = true,
            hash = true, drop = true, deref = true, extend = true,
            -- std macros (captured as calls by the macro_invocation query)
            format = true, print = true, println = true, eprintln = true,
            vec = true, panic = true, assert = true, assert_eq = true,
            assert_ne = true, debug_assert = true, matches = true,
            todo = true, unimplemented = true, unreachable = true,
            include_str = true, concat = true, env = true, cfg = true },
        stdlib_prefixes = { 'std::', 'core::', 'alloc::', 'String::',
            'Vec::', 'Box::', 'Arc::', 'Rc::', 'Option::', 'Result::',
            'Path::', 'PathBuf::', 'HashMap::', 'HashSet::', 'BTreeMap::' },
        import_query = [[ (use_declaration argument: (_) @path) ]],
        resolve_import = function (path, files, from)
            -- crate::a::b -> <src root>/a/b.rs | a/b/mod.rs | a.rs (the
            -- last segment may be an item, not a module); super/self are
            -- relative; a foreign first segment is another crate: honest nil
            path = path:gsub('%s', ''):gsub('{.*$', ''):gsub('%*$', '')
            local segs = {}
            for s in path:gmatch('[%w_]+') do segs[#segs + 1] = s end
            if #segs == 0 then return nil end
            local dir = from:match('^(.*)/[^/]*$') or ''
            local base
            if segs[1] == 'crate' then
                -- the crate root: nearest ancestor holding lib.rs/main.rs
                local d = dir
                while d ~= '' do
                    if files[d .. '/lib.rs'] or files[d .. '/main.rs'] then
                        base = d
                        break
                    end
                    d = d:match('^(.*)/[^/]*$') or ''
                end
                table.remove(segs, 1)
            elseif segs[1] == 'super' then
                base = dir:match('^(.*)/[^/]*$') or ''
                table.remove(segs, 1)
            elseif segs[1] == 'self' then
                base = dir
                table.remove(segs, 1)
            else
                return nil
            end
            if not base or #segs == 0 then return nil end
            for last = #segs, math.max(#segs - 1, 1), -1 do
                local p = base
                for i = 1, last do p = p .. '/' .. segs[i] end
                if files[p .. '.rs'] then return p .. '.rs' end
                if files[p .. '/mod.rs'] then return p .. '/mod.rs' end
            end
            -- a single-segment item lives in the base module itself
            for _, cand in ipairs({ base .. '/lib.rs', base .. '/main.rs',
                base .. '/mod.rs', base .. '.rs' }) do
                if files[cand] then return cand end
            end
            return nil
        end,
    },
    python = {
        exts = { 'py' },
        functions = [[ (function_definition name: (identifier) @name) @def ]],
        calls = [[ (call function: (_) @name) @call ]],
        vars = [[
            (module (expression_statement
                (assignment left: (identifier) @name right: (_) @value) @def))
        ]],
        params_field = 'parameters',
        body_field = 'body',
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
                for c in p:iter_children() do
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
    },
}

-- typescript is the javascript spec under another parser
M.spec.typescript = vim.tbl_extend('force', {}, M.spec.javascript)
M.spec.typescript.exts = { 'ts' }

local LIT_DEPTH, LIT_ITEMS, NAME_CAP = 6, 64, 48

-- ── helpers ──────────────────────────────────────────────────────────────────


local function pos_of(n)
    local sr, sc, er, ec = n:range()
    return { start = { line = sr, char = sc }, ['end'] = { line = er, char = ec } }
end

local function cap_node(ns)
    if type(ns) == 'table' and ns[1] ~= nil then return ns[#ns] end
    return ns
end

local QUERY_ERRORS = {}
local function parse_query(lang, q)
    if not q then return nil end -- the spec doesn't define this concept
    local ok, query = pcall(vim.treesitter.query.parse, lang, q)
    if not ok then
        -- a broken query must be LOUD: silently emitting nothing for a
        -- whole language looks like an empty project
        local key = lang .. '\31' .. q:sub(1, 40)
        if not QUERY_ERRORS[key] then
            QUERY_ERRORS[key] = true
            vim.notify(('cartograph/treesitter: %s query failed: %s')
                :format(lang, tostring(query):match('[^\n]*')), vim.log.levels.WARN)
        end
        return nil
    end
    return query
end

local DEFAULT_FN_TYPES = { function_definition = true, function_declaration = true }

local function in_function(n, spec)
    local types = spec and spec.fn_types or DEFAULT_FN_TYPES
    local p = n:parent()
    while p do
        if types[p:type()] then return p end
        p = p:parent()
    end
    return nil
end

-- literal data, the lua-ls litdata contract: strings/numbers/booleans,
-- {ref='name'} for identifiers, {expr='...'} frontiers for the rest,
-- nested tables recurse (mixed array+hash stringifies integer keys)
local function litval(n, src, spec, depth)
    local t = n:type()
    if t == 'string' or t == 'string_literal' then
        local txt = node_text(n, src)
        return (txt:gsub('^["\'%[=]+', ''):gsub('["\'%]=]+$', ''))
    end
    if t == 'number' or t == 'number_literal' or t == 'integer' or t == 'float' then
        return tonumber(node_text(n, src)) or node_text(n, src)
    end
    if t == 'true' then return true end
    if t == 'false' then return false end
    if t == 'identifier' or t == 'dot_index_expression' or t == 'field_expression'
        or t == 'attribute' or t == 'dotted_name' then
        return { ref = node_text(n, src) }
    end
    if t == 'function_definition' or t == 'lambda' then return { expr = 'function' } end
    if t == 'function_call' or t == 'call_expression' or t == 'call' then
        return { expr = node_text(n, src):gsub('%s+', ' '):sub(1, NAME_CAP) }
    end
    if (spec.litdata_types or {})[t] and depth < LIT_DEPTH then
        local arr, map, count = {}, {}, 0
        for item in n:iter_children() do
            if item:named() and item:type() ~= 'comment' then
                count = count + 1
                if count > LIT_ITEMS then break end
                local it = item:type()
                if it == 'initializer_pair' then
                    -- C designated initializer: .field = value
                    local des = item:field('designator')
                    local vf = item:field('value')[1]
                    local v = vf and litval(vf, src, spec, depth + 1)
                    local k = des and des[1]
                        and node_text(des[1], src):gsub('^[%.%[]', ''):gsub('%]$', '')
                    if k and v ~= nil then
                        map[k] = v
                    elseif v ~= nil then
                        arr[#arr + 1] = v
                    end
                elseif it == 'array_element_initializer' then
                    -- php: positional children; 2 = key => value, 1 = element
                    local kids = {}
                    for c2 in item:iter_children() do
                        if c2:named() and c2:type() ~= 'comment' then kids[#kids + 1] = c2 end
                    end
                    local v = kids[#kids] and litval(kids[#kids], src, spec, depth + 1)
                    if #kids >= 2 and v ~= nil then
                        local k = node_text(kids[1], src):gsub('^["\']', ''):gsub('["\']$', '')
                        map[k] = v
                    elseif v ~= nil then
                        arr[#arr + 1] = v
                    end
                elseif it == 'field' or it == 'pair' then
                    local kf = item:field('name')[1] or item:field('key')[1]
                    local vf = item:field('value')[1]
                    local v = vf and litval(vf, src, spec, depth + 1)
                    if kf and v ~= nil then
                        local k = node_text(kf, src):gsub('^["\']', ''):gsub('["\']$', '')
                        map[k] = v
                    elseif not kf and v ~= nil then
                        arr[#arr + 1] = v
                    end
                else
                    local v = litval(item, src, spec, depth + 1)
                    arr[#arr + 1] = v ~= nil and v or { expr = '?' }
                end
            end
        end
        local hasA, hasM = #arr > 0, next(map) ~= nil
        if hasA and hasM then
            for i, v in ipairs(arr) do map[tostring(i)] = v end
            return map
        end
        if hasA then return arr end
        return map
    end
    return nil
end

-- a callable ARGUMENT shape, classified at parse time (they are free
-- here; recovering them later means re-reading source):
--   [obj, 'method'] / array($o, 'm')  -> the string names the method
--   &Class::method (possibly inside a Bind-style wrapper call)
local function callable_arg(a, src)
    local t = a:type()
    if t == 'array_creation_expression' or t == 'array' then
        local els = {}
        for el in a:iter_children() do
            if el:named() and el:type() ~= 'comment' then
                if el:type() == 'array_element_initializer' then
                    el = el:named_child(0) or el
                end
                els[#els + 1] = el
            end
        end
        local last = els[#els]
        if #els >= 2 and last and last:type():find('string') then
            return node_text(last, src):gsub('^["\']', ''):gsub('["\']$', '')
        end
        return nil
    end
    if t == 'pointer_expression' or t == 'call_expression' then
        local found
        local function hunt(n, depth)
            if found or depth > 4 then return end
            if n:type() == 'qualified_identifier'
                and n:parent() and n:parent():type() == 'pointer_expression' then
                found = node_text(n, src)
                return
            end
            for c in n:iter_children() do
                if c:named() then hunt(c, depth + 1) end
            end
        end
        hunt(a, 0)
        return found
    end
    return nil
end

-- df-lite: the body's top-level statements with def/use NAME lists and
-- def->use dependencies. Approximate (no scoping) but structurally the same
-- contract as the lua-ls df, so the fn altitude and extract engine work.
local function dataflow(def, spec, src, params)
    local body = spec.body_field and def:field(spec.body_field)[1]
    if not body then return nil end
    local stmts = {}
    for stmt in body:iter_children() do
        if stmt:named() and stmt:type() ~= 'comment' then
            local defs, uses, seen_d, seen_u = {}, {}, {}, {}
            local function walk(n, defpos)
                local t = n:type()
                if t == 'identifier' or t == 'name' then
                    local name = node_text(n, src)
                    if defpos and not seen_d[name] then
                        seen_d[name] = true
                        defs[#defs + 1] = name
                    elseif not defpos and not seen_u[name] and not seen_d[name] then
                        seen_u[name] = true
                        uses[#uses + 1] = name
                    end
                    return
                end
                -- definition positions: declaration/assignment left sides
                if t == 'assignment_statement' or t == 'assignment'
                    or t == 'assignment_expression'
                    or t == 'augmented_assignment_expression' then
                    local left = n:field('left')[1] or n:child(0)
                    for c in n:iter_children() do
                        if c:named() then walk(c, c == left) end
                    end
                    return
                end
                if t == 'init_declarator' or t == 'variable_declarator' then
                    local d = n:field('declarator')[1] or n:field('name')[1]
                    for c in n:iter_children() do
                        if c:named() then walk(c, c == d) end
                    end
                    return
                end
                for c in n:iter_children() do
                    if c:named() then
                        -- def position survives transparent wrappers only
                        walk(c, defpos and (t == 'variable_list'
                            or t == 'variable_name'))
                    end
                end
            end
            walk(stmt, false)
            stmts[#stmts + 1] = { l = stmt:range() + 1, def = defs, use = uses, dep = {} }
        end
    end
    if #stmts == 0 then return nil end
    -- dependencies + free inputs
    local defined, inputs, inset = {}, {}, {}
    for _, p in ipairs(params or {}) do defined[p] = 0 end
    for i, s in ipairs(stmts) do
        for _, u in ipairs(s.use) do
            local from = defined[u]
            if from and from > 0 then
                s.dep[#s.dep + 1] = { from = from, var = u }
            elseif from == nil and not inset[u] then
                inset[u] = true
                inputs[#inputs + 1] = u
            end
        end
        for _, d in ipairs(s.def) do defined[d] = defined[d] or i end
    end
    return { inputs = inputs, stmts = stmts }
end

local function fn_params(def, spec, src, method)
    local ps = spec.params_field and def:field(spec.params_field)[1]
    local out = method and { 'self' } or {}
    if ps then
        for c in ps:iter_children() do
            if c:type() == 'identifier' or c:type() == 'variable' then
                out[#out + 1] = node_text(c, src)
            elseif c:type() == 'variable_name' then -- php $param
                out[#out + 1] = node_text(c, src):gsub('^%$', '')
            elseif c:named() then -- c parameter_declaration / defaulted params
                for id in c:iter_children() do
                    if id:type() == 'identifier' then
                        out[#out + 1] = node_text(id, src)
                        break
                    end
                    if id:type() == 'variable_name' then
                        out[#out + 1] = node_text(id, src):gsub('^%$', '')
                        break
                    end
                    if id:type() == 'pointer_declarator' then
                        local inner = id:field('declarator')[1]
                        if inner and inner:type() == 'identifier' then
                            out[#out + 1] = node_text(inner, src)
                        end
                        break
                    end
                end
            end
        end
    end
    return #out > 0 and out or nil
end

-- ── extraction ───────────────────────────────────────────────────────────────

local function lang_for(file)
    local ext = file:match('%.([%w]+)$')
    if not ext then return nil end
    for lang, spec in pairs(M.spec) do
        for _, e in ipairs(spec.exts) do
            if e == ext then return lang, spec end
        end
    end
end

-- container files: one FILE, several language regions (vue/svelte SFCs).
-- The container grammar's injection queries yield host-language trees at
-- ABSOLUTE positions, so extraction runs the host spec over each region
-- with no offset arithmetic anywhere.
local CONTAINERS = { vue = 'vue', svelte = 'svelte' }

local function container_for(file)
    local ext = file:match('%.([%w]+)$')
    return ext and CONTAINERS[ext] or nil
end

-- effective language: what governs a file's RESOLUTION semantics (the
-- never-cross-languages gate, stdlib vocabulary, scope hook). Containers
-- resolve as their host; typescript IS the javascript spec under another
-- parser — so js/ts/vue/svelte collapse to ONE family, the way TS
-- legally imports JS (allowJs) and SFC scripts import both.
local function elang_for(file)
    if container_for(file) then return 'javascript', M.spec.javascript end
    local lang, spec = lang_for(file)
    if lang == 'typescript' then return 'javascript', M.spec.javascript end
    return lang, spec
end

-- Transitive superclass resolution. `parent::m()` where the DIRECT parent
-- only INHERITS m (no exact `Parent::m` def) tail-refuses across every
-- class's m; walk the `extends` chain (data.extends: bare child->parent
-- names) to the nearest ancestor that actually DEFINES m. Sound for single
-- inheritance (php/java): if nothing between the two overrides m, the
-- inherited m IS that ancestor's. Runs as an enrichment over the fully
-- built graph, not the hot resolve loop, and is BOUNDED by a step limit +
-- cycle guard so a deep or malformed hierarchy can never walk away.
local SUPER_STEP_LIMIT = 32
local function build_super(extends)
    local super = {}
    for _, e in ipairs(extends or {}) do
        local prev = super[e.child]
        if prev == nil then super[e.child] = e.parent
        elseif prev ~= e.parent then super[e.child] = false end -- name collision
    end
    return super
end
-- Upgrade still-refused `Head::method` calls in place (addref + inferred);
-- returns how many resolved. `exact` and `addref` come from whichever pass
-- calls this (extract or relink) so it reads the CURRENT full node set.
local function resolve_super(calls, extends, exact, addref)
    if not (extends and extends[1]) then return 0 end
    local super = build_super(extends)
    local n = 0
    for _, c in ipairs(calls or {}) do
        if not c.to and c.refused and c.refused.cands and c.full then
            local head, method = c.full:match('^([%w_]+)::([%w_]+)$')
            if head and super[head] then
                local clang = elang_for(c.file)
                local seen, cur, target = { [head] = true }, head, nil
                for _ = 1, SUPER_STEP_LIMIT do
                    local par = super[cur]
                    if not par or seen[par] then break end -- top of chain / cycle
                    seen[par] = true
                    local cands = exact[par .. '::' .. method]
                    if cands then
                        local fit, dup = nil, false
                        for _, node in ipairs(cands) do
                            if elang_for(node.file) == clang then
                                if fit then dup = true else fit = node end
                            end
                        end
                        if dup then break end -- ambiguous where defined: refuse
                        if fit then target = fit; break end
                    end
                    cur = par
                end
                if target then
                    c.to = target.id
                    c.inferred = true
                    c.refused = nil
                    if c.fn then
                        addref(c.fn, target.id, c.at
                            or { start = { line = c.line, char = 0 },
                                ['end'] = { line = c.line, char = 0 } }, true)
                    end
                    n = n + 1
                end
            end
        end
    end
    return n
end

-- leading lines that BELONG to a def — comments, decorators,
-- attributes, annotations: what must travel with its text when an
-- edit verb moves it. Keyed by effective language.
local ATTACH = {
    lua = { '^%s*%-%-' },
    haskell = { '^%s*%-%-' },
    scheme = { '^%s*;' },
    c = { '^%s*//', '^%s*/%*', '^%s*%*' },
    cpp = { '^%s*//', '^%s*/%*', '^%s*%*' },
    javascript = { '^%s*//', '^%s*/%*', '^%s*%*', '^%s*@' },
    php = { '^%s*//', '^%s*#', '^%s*/%*', '^%s*%*' },
    ruby = { '^%s*#' },
    java = { '^%s*//', '^%s*/%*', '^%s*%*', '^%s*@' },
    go = { '^%s*//' },
    rust = { '^%s*//', '^%s*/%*', '^%s*%*', '^%s*#%[' },
    python = { '^%s*#', '^%s*@' },
}

function M.attach_pats(file)
    local lang = elang_for(file)
    return lang and ATTACH[lang] or {}
end

-- the effective language, for verbs that need a hazard decision
function M.lang_of(file)
    return (elang_for(file))
end

-- a NEW file's obligatory first lines (extract-module creates files)
function M.file_header(file)
    if elang_for(file) == 'php' then return { '<?php', '' } end
    return {}
end

-- the import line a file would use to reach `dest`, and its alias —
-- nil when this language's wiring is not mechanically writable
function M.import_line(from_file, dest)
    local _, spec = elang_for(from_file)
    if not (spec and spec.import_line) then return nil end
    return spec.import_line(dest)
end

-- patterns matching this file's import lines (new-import placement)
function M.import_pats(file)
    local _, spec = elang_for(file)
    return spec and spec.import_pats or nil
end

-- ── body-descent (browser) ────────────────────────────────────────────────
-- The block/scope nodes whose named children ARE statements (imperative
-- langs), and the clause wrappers a block hides behind (else/elif/case…).
-- Used to walk ONE level of nesting into a compound statement.
local SUBSTMT_BLOCKS = {
    block = true, compound_statement = true, statement_block = true,
    suite = true, do_block = true, declaration_list = true,
    field_declaration_list = true, class_body = true, switch_body = true,
}
local SUBSTMT_CLAUSES = {
    else_statement = true, elseif_statement = true, else_clause = true,
    elif_clause = true, elseif_clause = true, catch_clause = true,
    finally_clause = true, ['then'] = true, do_statement = true,
    case_statement = true, switch_case = true, when_entry = true,
}
-- lisp: nesting is child LIST forms, not blocks
local LISP_LANGS = { scheme = true, commonlisp = true, clojure = true, fennel = true, janet = true }
-- top-of-file containers whose named children are statements (position mode)
local ROOT_TYPES = { chunk = true, program = true, source_file = true,
    translation_unit = true, module = true, block = true, ['end'] = true }

-- immediate sub-forms of `node`: nested statements (through block/clause
-- wrappers) for imperative langs; child list forms for lisp (the head symbol
-- and, for a def/lambda, the signature list are not sub-forms).
local function child_forms(node, lisp)
    local out = {}
    if lisp then
        -- every child list is a nested form (the caller drops the signature
        -- list of a def/lambda); bare symbols/atoms are leaves, not forms
        for c in node:iter_children() do
            if c:named() and c:type() == 'list' then out[#out + 1] = c end
        end
        return out
    end
    local function scan(n)
        for c in n:iter_children() do
            if c:named() and c:type() ~= 'comment' then
                local t = c:type()
                if SUBSTMT_BLOCKS[t] then
                    for g in c:iter_children() do
                        if g:named() and g:type() ~= 'comment' then out[#out + 1] = g end
                    end
                elseif SUBSTMT_CLAUSES[t] then
                    scan(c)
                end
            end
        end
    end
    scan(node)
    return out
end

--- Immediate sub-forms of a form in `file`, for the browser's block descent.
--- Two modes:
---   * EXACT node — pass the full range (sr,sc,er,ec) of a known node (a
---     function's body, or a sub-form returned by a previous call).
---   * POSITION — pass only (sr,sc): the enclosing STATEMENT at that point
---     (walking up but stopping before its block), e.g. a df row's line.
--- Returns a list of { sr, sc, er, ec (0-based, ec exclusive), text, branch },
--- branch = true when that sub-form has its own sub-forms (descend again).
--- Recomputed on demand — nothing is cached in the graph.
function M.forms(file, sr, sc, er, ec)
    local lang, spec = elang_for(file)
    if not (lang and spec) then return {} end
    local fd = io.open(file, 'r')
    if not fd then return {} end
    local src = fd:read('a'); fd:close()
    local ok, parser = pcall(vim.treesitter.get_string_parser, src, lang)
    if not ok then return {} end
    local tree = parser:parse()[1]
    if not tree then return {} end
    local root = tree:root()
    local lisp = LISP_LANGS[lang] or false

    local n
    if er then
        -- exact node spanning the given range (ec exclusive -> inclusive probe)
        n = root:named_descendant_for_range(sr, sc, er, math.max(sc, ec - 1))
    else
        -- position mode: the statement that STARTS on row `sr` — the child of
        -- a block/root that begins there (indentation-agnostic; col ignored)
        local function find_stmt(node)
            local container = SUBSTMT_BLOCKS[node:type()] or ROOT_TYPES[node:type()]
            for c in node:iter_children() do
                if c:named() and c:type() ~= 'comment' then
                    local csr, _, cer = c:range()
                    if container and csr == sr then return c end
                    if sr >= csr and sr <= cer then
                        local f = find_stmt(c)
                        if f then return f end
                    end
                end
            end
        end
        n = find_stmt(root)
    end
    if not n then return {} end

    -- a lisp def/lambda/let: the first list child is the signature/bindings,
    -- not a body form
    local drop_first_list = false
    if lisp then
        local head = n:named_child(0)
        if head and head:type() == 'symbol' then
            local h = node_text(head, src)
            if h:match('^define') or h:match('^lambda') or h:match('^let')
                or h == 'named-lambda' then
                drop_first_list = true
            end
        end
    end

    local subs = child_forms(n, lisp)
    if lisp and drop_first_list and subs[1] then table.remove(subs, 1) end

    local out = {}
    for _, s in ipairs(subs) do
        local ssr, ssc, ser, sec = s:range()
        -- the form's OWN text (first line), so several forms sharing a source
        -- line read distinctly; whitespace collapsed, truncated
        local text = node_text(s, src):gsub('%s+', ' '):gsub('^%s*', ''):sub(1, 80)
        out[#out + 1] = { sr = ssr, sc = ssc, er = ser, ec = sec, text = text,
            branch = #child_forms(s, lisp) > 0 }
    end
    return out
end

-- argument-list containers and conditional statements, for the detail lens
local ARG_LISTS = { arguments = true, argument_list = true }
local COND_TYPES = { if_statement = true, elseif_statement = true,
    while_statement = true, repeat_statement = true, switch_statement = true,
    ['for_statement'] = true, for_in_statement = true, when = true }

-- a statement's DETAIL items: for a conditional, its condition; otherwise the
-- arguments of any calls it makes (not descending into nested blocks — those
-- belong to the block lens). Each item is { kind='cond'|'arg', sr,sc,er,ec, text }.
local function detail_items(stmt, src)
    local items = {}
    local function mk(kind, n)
        local a, b, c, d = n:range()
        items[#items + 1] = { kind = kind, sr = a, sc = b, er = c, ec = d,
            text = node_text(n, src):gsub('%s+', ' '):gsub('^%s*', ''):sub(1, 80) }
    end
    if COND_TYPES[stmt:type()] then
        local cond = stmt:field('condition')[1]
        if not cond then
            for c in stmt:iter_children() do
                if c:named() and c:type() ~= 'comment'
                    and not SUBSTMT_BLOCKS[c:type()] then cond = c break end
            end
        end
        if cond then mk('cond', cond) end
        return items -- the body is the block lens's concern, not the detail's
    end
    local function walk(n)
        for c in n:iter_children() do
            if c:named() and c:type() ~= 'comment' and not SUBSTMT_BLOCKS[c:type()] then
                if ARG_LISTS[c:type()] then
                    for a in c:iter_children() do
                        if a:named() and a:type() ~= 'comment' then mk('arg', a) end
                    end
                else
                    walk(c)
                end
            end
        end
    end
    walk(stmt)
    return items
end

--- The detail-lens rows for a code range: each top-level statement with its
--- detail items (a conditional's condition; a call's arguments). Same on-demand
--- parse as M.forms; returns { {sr,sc,er,ec,text, items={...}}, ... }.
function M.detail(file, sr, sc, er, ec)
    local lang, spec = elang_for(file)
    if not (lang and spec) then return {} end
    local fd = io.open(file, 'r'); if not fd then return {} end
    local src = fd:read('a'); fd:close()
    local ok, parser = pcall(vim.treesitter.get_string_parser, src, lang)
    if not ok then return {} end
    local tree = parser:parse()[1]; if not tree then return {} end
    local root = tree:root()
    local lisp = LISP_LANGS[lang] or false
    local n = root:named_descendant_for_range(sr, sc, er or sr, er and math.max(sc, ec - 1) or sc)
    if not n then return {} end
    if not er then
        while n:parent() do
            local pr, pc = n:parent():start()
            if pr == sr and pc == sc and not SUBSTMT_BLOCKS[n:parent():type()] then
                n = n:parent()
            else break end
        end
    end
    local stmts = child_forms(n, lisp)
    local out = {}
    for _, s in ipairs(stmts) do
        local a, b, c, d = s:range()
        out[#out + 1] = { sr = a, sc = b, er = c, ec = d,
            text = node_text(s, src):gsub('%s+', ' '):gsub('^%s*', ''):sub(1, 80),
            items = detail_items(s, src) }
    end
    return out
end

-- parse a container file and return its host-language trees in
-- DETERMINISTIC position order (the LanguageTree child table has no
-- stable iteration order; worker output must equal inline output).
-- nil for plain files, so callers can fall back to the single root.
local function container_trees(parser, clang)
    if not clang then return nil end
    -- injection queries may use nvim-treesitter's CUSTOM directives
    -- (svelte: set-lang-from-mimetype! for lang="ts" attributes). Workers
    -- have the plugin on their rtp but never load it — register the
    -- directives before the first injected parse. Idempotent.
    pcall(require, 'nvim-treesitter.query_predicates')
    local out = {}
    -- a failed injection parse degrades to an EMPTY region list (module
    -- skeleton, honest frontier), never to misreading the container tree
    -- as host code
    if not pcall(parser.parse, parser, true) then return out end
    parser:for_each_tree(function (tree, ltree)
        local hl = ltree:lang()
        if hl ~= clang and M.spec[hl] then
            local rt = tree:root()
            local sr, sc, er = rt:range()
            out[#out + 1] = { root = rt, lang = hl, spec = M.spec[hl],
                s = sr, c = sc, e = er }
        end
    end)
    table.sort(out, function (a, b)
        if a.s ~= b.s then return a.s < b.s end
        if a.c ~= b.c then return a.c < b.c end
        return a.e > b.e
    end)
    return out
end

local EXCLUDE_DIRS = { node_modules = true, vendor = true, dist = true,
    build = true, cache = true, minified = true,
    -- vendored-source conventions (hugo's deps/, azerothcore's deps/)
    deps = true, third_party = true, thirdparty = true, external = true }

local function list_files(root, subdirs)
    local out, minified = {}, {}
    local function in_scope(rel)
        if not subdirs then return true end
        for _, p in ipairs(subdirs) do
            if rel == p or rel:sub(1, #p + 1) == p .. '/' then return true end
        end
        return false
    end
    local function want(rel)
        if rel:match('%.min%.js$') then -- bundles: opaque frontiers, not source
            if in_scope(rel) then minified[#minified + 1] = rel end
            return false
        end
        return in_scope(rel)
    end
    local function rec(rel)
        local it = vim.uv.fs_scandir(rel == '' and root or (root .. '/' .. rel))
        while it do
            local name, t = vim.uv.fs_scandir_next(it)
            if not name then break end
            if name:sub(1, 1) ~= '.' then
                local r = rel == '' and name or (rel .. '/' .. name)
                if t == 'directory' then
                    local ex = EXCLUDE_DIRS[name:lower()]
                    if not ex then
                        for _, x in ipairs(require('cartograph.config').exclude or {}) do
                            if name == x then ex = true break end
                        end
                    end
                    if not ex then rec(r) end
                elseif (lang_for(r) or container_for(r)) and want(r) then
                    out[#out + 1] = r
                end
            end
        end
    end
    rec('')
    table.sort(out)
    table.sort(minified)
    return out, minified
end
-- the cache diffs the tree with the same walk/exclusion rules extraction uses
function M.list_files(root, subdirs) return list_files(root, subdirs) end

-- The id pass: identifier occurrences naming a known top-level var (same
-- file, or unique across the workspace) or — outside call position — a
-- unique function (dispatch tables, registry values). A top-level
-- function reference marks the target dynamically dispatched (cbarg): a
-- dispatch-table entry is not dead code. Takes SUPPLIED lookups so the
-- parallel driver can run it in workers against parent-built GLOBAL
-- indexes: slice-local uniqueness is not global uniqueness.
-- L = { fn_unique = name -> {id,file,line,node?} (globally unique fns),
--       var_named = name -> { {id,file,line}, ... } (top-level vars),
--       fn_ranges = file -> { {s,e,id}, ... },
--       addref(from,to,at,inferred), adduse(edge), mark_cbarg(entry),
--       add_names(file, packed)? — per-file identifier NAME SET (the
--       mention index: \31-separated, sorted; ≥3 chars, stdlib excluded),
--       recorded while we're iterating every identifier anyway. This is
--       what lets a later splice answer "which files mention this
--       global?" without a corpus scan. Gated per language:
--       spec.name_index = false opts a language out (when bare-identifier
--       mention does not imply potential global use). }
local function id_pass(root, files, L, abs)
    abs = abs or function (f) return root .. '/' .. f end
    for _, file in ipairs(files) do
        local lang, spec = lang_for(file)
        local clang = container_for(file)
        if clang then lang, spec = 'javascript', M.spec.javascript end
        local ranges = L.fn_ranges[file]
        if ranges then
            local fd = io.open(abs(file), 'r')
            local src = fd and fd:read('a')
            if fd then fd:close() end
            local okp, parser = pcall(vim.treesitter.get_string_parser,
                src or '', clang or lang)
            if src and okp then
                local nameset = (L.add_names and spec.name_index ~= false)
                    and {} or nil
                local function fn_at(line)
                    local best
                    for _, r in ipairs(ranges) do
                        if r.s <= line and line <= r.e
                            and (not best or r.s >= best.s) then best = r end
                    end
                    return best and best.id
                end
                local troots = container_trees(parser, clang)
                    or { { root = parser:parse()[1]:root(), spec = spec,
                        lang = lang } }
                local useEdge, regEdge = {}, {}
                for _, tr in ipairs(troots) do
                local q = parse_query(tr.lang, tr.spec.id_query or '(identifier) @id')
                if q then
                    for _, n in q:iter_captures(tr.root, src, 0, -1) do
                        local name = node_text(n, src)
                        if nameset and #name >= 3
                            and not (tr.spec.stdlib_names or {})[name] then
                            nameset[name] = true
                        end
                        local parent = n:parent()
                        local pt = parent and parent:type() or ''
                        local callee_pos = (pt == 'call_expression' or pt == 'function_call'
                                or pt == 'call' or pt == 'apply')
                            and (parent:field('function')[1] == n or parent:field('name')[1] == n)
                            -- sexp grammars have no fields: the head IS the callee
                            or (pt == 'list' and parent:named_child(0) == n)
                        if not callee_pos and #name >= 3
                            and tr.spec.id_fn_refs ~= false
                            and not (tr.spec.stdlib_names or {})[name] then
                            local u = L.fn_unique[name]
                            if u and L.scopes
                                and L.scopes[u.file] ~= L.scopes[file] then
                                u = nil -- unique, but across a boundary
                            end
                            if u then
                                local line = select(1, n:range())
                                if not (u.file == file and line == u.line) then
                                    local from = fn_at(line)
                                    if from then
                                        L.addref(from, u.id, pos_of(n), true)
                                    else
                                        -- referenced from top-level DATA (a
                                        -- dispatch table / registry): the fn
                                        -- is kept alive, and the reference is
                                        -- a REGISTRATION edge from this module
                                        -- — an alibi you can descend into
                                        L.mark_cbarg(u)
                                        local rk = file .. '\31' .. u.id
                                        local e = regEdge[rk]
                                        if not e then
                                            e = { from = file, to = u.id,
                                                kind = 'reg', at = {} }
                                            regEdge[rk] = e
                                            L.adduse(e)
                                        end
                                        e.at[#e.at + 1] = pos_of(n)
                                    end
                                end
                            end
                        end
                        local cands = L.var_named[name]
                        if cands then
                            local var
                            for _, v in ipairs(cands) do
                                if v.file == file then var = v break end
                            end
                            if not var and #cands == 1
                            and not (L.scopes and L.scopes[cands[1].file]
                                ~= L.scopes[file]) then
                            var = cands[1]
                        end
                            local line = select(1, n:range())
                            if var and not (var.file == file and line == var.line) then
                                local from = fn_at(line)
                                if from then
                                    local k = from .. '\31' .. var.id
                                    local e = useEdge[k]
                                    if not e then
                                        e = { from = from, to = var.id, kind = 'use', at = {} }
                                        useEdge[k] = e
                                        L.adduse(e)
                                    end
                                    e.at[#e.at + 1] = pos_of(n)
                                end
                            end
                        end
                    end
                end
                end
                if nameset and next(nameset) then
                    local ns = vim.tbl_keys(nameset)
                    table.sort(ns) -- deterministic pack (worker == inline)
                    L.add_names(file, '\31' .. table.concat(ns, '\31') .. '\31')
                end
            end
        end
    end
end

--- Global name lookups for the standalone id pass, from a full node set.
--- Used by the parallel driver (phase 2) and refresh (changed files).
function M.lookups(nodes, root)
    local count = {}
    for _, n in ipairs(nodes) do
        if (n.kind == 'function' or n.kind == 'method') and not n.torn
            and not n.decl then -- a prototype declaration is not a call target
            count[n.name] = (count[n.name] or 0) + 1
        end
    end
    local fn_unique, var_named = {}, {}
    for _, n in ipairs(nodes) do
        if n.torn then -- beyond a parse error: never name-matched
        elseif (n.kind == 'function' or n.kind == 'method')
            and not n.decl and count[n.name] == 1 then
            fn_unique[n.name] = { id = n.id, file = n.file,
                line = n.range.start.line }
        elseif n.kind == 'var' and not n.sql and not n.ctype then
            -- interface types/macros (ctype) are browse-only, not use targets
            var_named[n.name] = var_named[n.name] or {}
            table.insert(var_named[n.name],
                { id = n.id, file = n.file, line = n.range.start.line })
        end
    end
    -- scope map: languages with a resolution boundary (rust crates) get
    -- their id-pass matches confined to it
    local fileset, scopes, any = {}, {}, false
    for _, n in ipairs(nodes) do
        if n.kind == 'module' then fileset[n.file] = true end
    end
    for f in pairs(fileset) do
        local _, sp = elang_for(f)
        if sp and sp.scope then
            scopes[f] = sp.scope(f, fileset, root)
            any = true
        end
    end
    return { fn_unique = fn_unique, var_named = var_named,
        scopes = any and scopes or nil }
end

--- Fold a standalone id-pass result into a graph: ref pairs dedup into
--- existing edges (like addref), cbarg marks apply. Shared by refresh
--- and the parallel driver.
function M.merge_idpass(data, out, touched)
    local refEdge = {}
    for _, e in ipairs(data.edges) do
        if e.kind == 'ref' then refEdge[e.from .. '\31' .. e.to] = e end
    end
    local byid = {}
    for _, n in ipairs(data.nodes) do byid[n.id] = n end
    for _, e in ipairs(out.edges or {}) do
        local k = e.kind == 'ref' and (e.from .. '\31' .. e.to)
        local ex = k and refEdge[k]
        if ex then
            for _, at in ipairs(e.at or {}) do ex.at[#ex.at + 1] = at end
            if not e.inferred then ex.inferred = nil end
        else
            if k then refEdge[k] = e end
            data.edges[#data.edges + 1] = e
        end
        if touched then
            touched[e.from:match('^(.-)::') or e.from] = true
        end
    end
    for _, id in ipairs(out.cbarg or {}) do
        if byid[id] then
            byid[id].cbarg = true
            if touched then touched[byid[id].file] = true end
        end
    end
    if out.names then
        data.names = data.names or {}
        for f, s in pairs(out.names) do data.names[f] = s end
    end
end

--- Standalone id pass over `files` with global lookups (parallel phase
--- 2, run inside a worker). Returns { edges = {...}, cbarg = {id, ...} }.
function M.id_pass(root, files, lookups, abs)
    local out = { edges = {}, cbarg = {}, names = {} }
    local refEdge, seen_cb = {}, {}
    id_pass(root, files, {
        fn_unique = lookups.fn_unique,
        var_named = lookups.var_named,
        fn_ranges = lookups.fn_ranges,
        scopes = lookups.scopes,
        add_names = function (f, s) out.names[f] = s end,
        addref = function (from, to, at, inferred)
            local k = from .. '\31' .. to
            local e = refEdge[k]
            if not e then
                e = { from = from, to = to, kind = 'ref', at = {},
                    self = (from == to) or nil, inferred = inferred or nil }
                refEdge[k] = e
                out.edges[#out.edges + 1] = e
            end
            if not inferred then e.inferred = nil end
            e.at[#e.at + 1] = at
        end,
        adduse = function (e) out.edges[#out.edges + 1] = e end,
        mark_cbarg = function (u)
            if not seen_cb[u.id] then
                seen_cb[u.id] = true
                out.cbarg[#out.cbarg + 1] = u.id
            end
        end,
    }, abs)
    return out
end

--- Extract a neutral-schema graph from a directory tree. Any file whose
--- extension has a spec (and an available parser) participates.
---@param root string
---@return table data  the schema-1 graph (ready for store.ingest)
function M.extract(root, opts)
    -- a URI root (self://loaded — the running instance's multi-root corpus)
    -- keeps off the filesystem's path rules: its files are plugin-labelled
    -- keys (telescope.nvim/lua/…) that resolve to real directories through
    -- opts.abs. A plain directory root joins as before.
    if not root:match('^%w+://') then
        root = vim.fn.fnamemodify(vim.fn.expand(root), ':p'):gsub('/+$', '')
    end
    local abs = (opts and opts.abs) or function (f) return root .. '/' .. f end
    local files, minified
    if opts and opts.files then
        -- explicit work list (parallel batches, demand extraction):
        -- no tree walk, no bundle synthesis — the caller owns both
        files, minified = opts.files, {}
    else
        files, minified = list_files(root, opts and opts.subdirs)
    end
    local fileset = {}
    for _, f in ipairs(opts and opts.fileset or files) do fileset[f] = true end
    for _, f in ipairs(files) do fileset[f] = true end

    -- stamps: what each parsed file's truth is keyed to (mtime+size — a
    -- display-honesty gate for edits that arrive OUTSIDE nvim, not an
    -- eviction key, so no content hash needed). store.stale() compares.
    local data = { schema = 1, root = root, provider = 'treesitter',
        capabilities = { calls = true, litdata = true, df = 'lite' },
        nodes = {}, edges = {}, calls = {}, stamps = {} }
    local nodes, edges, calls = data.nodes, data.edges, data.calls
    local no_parser = {}

    -- per-name def indexes for the resolution pass
    local exact, tail = {}, {} -- name -> {fn node,...}; last segment -> {...}
    local varsByName = {}      -- name -> {var node,...}
    local lastFn = {}          -- file -> last emitted fn node (equation merging)
    local fnRanges = {}        -- file -> { {s=line, e=line, id=id}, ... }
    local pending = {}         -- unresolved references, matched after all files

    local function fn_at(file, line)
        local best
        for _, r in ipairs(fnRanges[file] or {}) do
            if r.s <= line and line <= r.e and (not best or r.s >= best.s) then best = r end
        end
        return best and best.id
    end

    local function stamp(file)
        local st = vim.uv.fs_stat(abs(file))
        if st then
            data.stamps[file] = ('%d:%d:%d')
                :format(st.mtime.sec, st.mtime.nsec, st.size)
        end
    end

    -- defs: functions, top-level vars, blocks, imports — one TREE at
    -- a time, so container files (vue/svelte SFCs) can run it once per
    -- script region while plain files run it on their single root
    local function extract_defs(file, lang, spec, src, tsroot)
        -- a def extracted from BEYOND a parse error has escaped its
        -- context (magento's php5 `$s{0}` truncates the class; the
        -- methods after it float unqualified and absorb tails). Torn
        -- defs stay visible — jumpable nodes — but are never indexed
        -- for name matching: refuse, don't absorb
        local errow
        if tsroot:has_error() then
            local function rec(n)
                if n:type() == 'ERROR' then return (n:range()) end
                if not n:has_error() then return nil end
                local best
                for c in n:iter_children() do
                    local r = rec(c)
                    if r and (not best or r < best) then best = r end
                end
                return best
            end
            errow = rec(tsroot)
        end
        -- functions
        local q = parse_query(lang, spec.functions)
        -- start line of every fn/method def, for block flushing. Keyed by
        -- LINE, not node: the defs come from iter_matches but the block loop
        -- walks iter_children, and TSNode identity does not survive across
        -- traversals (== is a metamethod, table keys are raw) — a node-keyed
        -- set never hits, so every file collapsed into one giant region.
        local fnDefLines = {}
        if q then
            for _, match in q:iter_matches(tsroot, src, 0, -1) do
                local defn, namen
                for id, ns in pairs(match) do
                    local cap = q.captures[id]
                    local n = cap_node(ns)
                    if cap == 'def' then defn = n elseif cap == 'name' then namen = n end
                end
                if defn and namen and not (spec.toplevel_only
                    and in_function(defn, spec))
                    and not (spec.toplevel_parent and defn:parent()
                        and defn:parent():type() ~= spec.toplevel_parent) then
                    local name = node_text(namen, src):gsub('%s+', '')
                    if spec.qualify then name = spec.qualify(name, defn, src) end
                    local sp = pos_of(defn)
                    local method = spec.is_method(name, defn)
                    local id = ('%s::%s@%d'):format(file, name, sp.start.line)
                    local params = fn_params(defn, spec, src, method and lang == 'lua')
                    -- tri-state visibility: true/false = the provider's
                    -- verdict (lint trusts it over kind heuristics);
                    -- nil = this language has no visibility concept
                    local exp
                    if spec.exported_def then
                        exp = spec.exported_def(defn, src) == true
                    end
                    local isfield = spec.field_fn_cbarg
                        and namen:parent() and namen:parent():type() == 'field'
                    if spec.cbarg_within and not isfield then
                        local a = defn:parent()
                        while a do
                            if spec.cbarg_within[a:type()] then isfield = true break end
                            a = a:parent()
                        end
                    end
                    if spec.cbarg_def and not isfield then
                        isfield = spec.cbarg_def(defn, src) or false
                    end
                    -- multi-equation definitions (haskell) are ONE function:
                    -- fold this equation into the previous node
                    local prev = spec.merge_equations and lastFn[file]
                    if prev and prev.name == name then
                        prev.range['end'] = sp['end']
                        for _, r in ipairs(fnRanges[file] or {}) do
                            if r.id == prev.id then r.e = sp['end'].line break end
                        end
                        fnDefLines[sp.start.line] = true
                        goto fn_done
                    end
                    local torn = errow and sp.start.line >= errow or nil
                    nodes[#nodes + 1] = { id = id, name = name,
                        kind = method and 'method' or 'function', file = file,
                        range = sp, order = sp.start.line, params = params,
                        cbarg = isfield or nil,
                        exported = exp,
                        torn = torn,
                        entry = (spec.entry_names or {})[name] or nil,
                        df = (spec.dataflow or dataflow)(defn, spec, src, params) }
                    lastFn[file] = nodes[#nodes]
                    fnDefLines[sp.start.line] = true
                    -- the outermost query pattern may match a nested def too;
                    -- ranges keep the innermost containing fn for attribution
                    fnRanges[file] = fnRanges[file] or {}
                    table.insert(fnRanges[file], { s = sp.start.line, e = sp['end'].line, id = id })
                    if not torn then
                        exact[name] = exact[name] or {}
                        table.insert(exact[name], nodes[#nodes])
                        local tl = name:match('([%w_]+)$')
                        if tl and tl ~= name then
                            tail[tl] = tail[tl] or {}
                            table.insert(tail[tl], nodes[#nodes])
                        end
                    end
                    ::fn_done::
                end
            end
        end

        -- top-level vars (+ litdata)
        q = parse_query(lang, spec.vars)
        if q then
            -- a multi-assignment (`a, b = 1, 2`) cross-products name×value in
            -- the query, so dedup by the (name,line) id it produces
            local seen_var = {}
            for _, match in q:iter_matches(tsroot, src, 0, -1) do
                local defn, namen, valn
                for id, ns in pairs(match) do
                    local cap = q.captures[id]
                    local n = cap_node(ns)
                    if cap == 'def' then defn = n
                    elseif cap == 'name' then namen = n
                    elseif cap == 'value' then valn = n end
                end
                if defn and namen and not in_function(defn, spec)
                    and not (spec.toplevel_parent and defn:parent()
                        and defn:parent():type() ~= spec.toplevel_parent) then
                    local name = node_text(namen, src)
                    local sp = pos_of(defn)
                    local id = ('%s::var:%s@%d'):format(file, name, sp.start.line)
                    if not seen_var[id] then
                        seen_var[id] = true
                        local d = valn and (spec.litdata_types or {})[valn:type()]
                            and litval(valn, src, spec, 0) or nil
                        local torn = errow and sp.start.line >= errow or nil
                        nodes[#nodes + 1] = { id = id, name = name, kind = 'var',
                            file = file, range = sp, order = sp.start.line,
                            torn = torn,
                            data = type(d) == 'table' and d or nil }
                        if not torn then
                            varsByName[name] = varsByName[name] or {}
                            table.insert(varsByName[name], nodes[#nodes])
                        end
                    end
                end
            end
        end

        -- header/interface elements (C/C++): prototypes, macros and types,
        -- so a header shows what it EXPOSES instead of one #ifndef block. A
        -- prototype is a DECLARATION, not a definition — it stays OUT of the
        -- resolution indexes (the .c definition is the real call target) and
        -- is marked decl. A function-like macro IS a call target and indexes.
        if spec.interface then
            local iq = parse_query(lang, spec.interface)
            if iq then
                for _, match in iq:iter_matches(tsroot, src, 0, -1) do
                    local defn, namen, cat
                    for cid, ns in pairs(match) do
                        local cap = iq.captures[cid]
                        if cap == 'def' then defn = cap_node(ns)
                        else namen, cat = cap_node(ns), cap end
                    end
                    if defn and namen then
                        local name = node_text(namen, src):gsub('%s+', '')
                        local sp = pos_of(defn)
                        local torn = errow and sp.start.line >= errow or nil
                        if cat == 'proto' or cat == 'macrofn' then
                            local node = { name = name, kind = 'function',
                                id = ('%s::%s@%d'):format(file, name, sp.start.line),
                                file = file, range = sp, order = sp.start.line,
                                torn = torn, decl = cat == 'proto' or nil,
                                macro = cat == 'macrofn' or nil }
                            nodes[#nodes + 1] = node
                            -- prototypes never index; a fn-like macro resolves
                            if not torn and cat == 'macrofn' then
                                exact[name] = exact[name] or {}
                                table.insert(exact[name], node)
                                local tl = name:match('([%w_]+)$')
                                if tl and tl ~= name then
                                    tail[tl] = tail[tl] or {}
                                    table.insert(tail[tl], node)
                                end
                            end
                        else -- struct / union / enum / typedef / object macro
                            nodes[#nodes + 1] = { name = name, kind = 'var',
                                id = ('%s::type:%s@%d'):format(file, name, sp.start.line),
                                file = file, range = sp, order = sp.start.line,
                                torn = torn, ctype = cat }
                        end
                    end
                end
            end
        end

        -- regions: runs of top-level statements that aren't function defs
        do
            local lines = vim.split(src, '\n', { plain = true })
            local container = tsroot
            if spec.block_container then
                for c in tsroot:iter_children() do
                    if c:type() == spec.block_container then container = c break end
                end
            end
            local run = nil
            local function flush()
                if run then
                    local id = ('%s::region@%d'):format(file, run.s.start.line)
                    nodes[#nodes + 1] = { id = id, name = run.name, kind = 'region',
                        file = file, order = run.s.start.line,
                        range = { start = run.s.start, ['end'] = run.e['end'] } }
                    run = nil
                end
            end
            for stmt in container:iter_children() do
                if stmt:named() and stmt:type() ~= 'comment'
                    and not (spec.block_skip or {})[stmt:type()] then
                    local p = pos_of(stmt)
                    -- a top-level fn def statement starts on the def's line
                    -- (`function f()`, and `f = function()` share the line);
                    -- it ends the current run rather than joining it
                    if fnDefLines[p.start.line] then
                        flush()
                    elseif not run then
                        run = { s = p, e = p,
                            name = (lines[p.start.line + 1] or ''):match('^%s*(.-)%s*$'):sub(1, NAME_CAP) }
                    else
                        run.e = p
                    end
                end
            end
            flush()
        end

        -- imports
        if spec.import_query then
            q = parse_query(lang, spec.import_query)
            if q then
                for id, n in q:iter_captures(tsroot, src, 0, -1) do
                    if q.captures[id] == 'path' then
                        local target = spec.resolve_import(node_text(n, src), fileset, file)
                        if target and target ~= file then
                            edges[#edges + 1] = { from = file, to = target, kind = 'import' }
                        end
                    end
                end
            end
        end

        -- OO extends pairs (child class -> superclass, bare names): feeds
        -- transitive parent::m resolution once the full graph is built
        if spec.super_query then
            q = parse_query(lang, spec.super_query)
            if q then
                for _, match in q:iter_matches(tsroot, src, 0, -1) do
                    local child, parent
                    for cid, ns in pairs(match) do
                        local cap = q.captures[cid]
                        if cap == 'child' then
                            child = node_text(cap_node(ns), src)
                        elseif cap == 'parent' then
                            local t = node_text(cap_node(ns), src)
                            parent = t:match('[^\\]+$') or t
                        end
                    end
                    if child and parent then
                        data.extends = data.extends or {}
                        data.extends[#data.extends + 1] =
                            { child = child, parent = parent, file = file }
                    end
                end
            end
        end

    end

    -- calls: inventory + reference sites (resolved after all files).
    -- Containers also run this over TEMPLATE EXPRESSION trees — an
    -- @click="save(item)" is a real call_expression at absolute rows
    local function extract_calls(file, lang, spec, src, tsroot)
        -- drop the receiver-typing scope model unconditionally: its guard is
        -- src VALUE-equality, but node:id() is only unique within one tree —
        -- two byte-identical files whose first tree got collected could
        -- otherwise alias ids into a stale model
        jvt_sm, jvt_src = nil, nil
        -- calls (inventory + reference sites, resolved after all files)
        local q = parse_query(lang, spec.calls)
        if q then
            for _, match in q:iter_matches(tsroot, src, 0, -1) do
                local calln, namen
                for id, ns in pairs(match) do
                    local cap = q.captures[id]
                    local n = cap_node(ns)
                    if cap == 'call' then calln = n elseif cap == 'name' then namen = n end
                end
                -- context skip: constructs that merely LOOK like calls
                -- (C++ constructor member-initializers: count(count))
                if calln and spec.call_skip_within then
                    local a, hops = calln:parent(), 0
                    while a and hops < 3 do
                        if spec.call_skip_within[a:type()] then
                            calln = nil
                            break
                        end
                        a = a:parent()
                        hops = hops + 1
                    end
                end
                -- positional skip: a list that only LOOKS like an application
                -- because of the syntax (scheme: a define/lambda's parameter
                -- list `(f x)` is not a call to f — it was the self-caller bug)
                if calln and spec.skip_call and spec.skip_call(calln, src) then
                    calln = nil
                end
                if calln and namen
                    and not (spec.call_skip or {})[node_text(namen, src)] then
                    local full = node_text(namen, src):gsub('%s+', '')
                    -- method-ness reads the SOURCE text: a receiver-aware
                    -- rewrite below must not shift the implicit-self arg
                    local method = full:find(':') ~= nil
                    -- receiver-aware qualification: a $this->/self:: call
                    -- names a method of the ENCLOSING class, so the spec
                    -- may rewrite the resolution key to Class::name —
                    -- exact match beats every tail fallback; inheritance
                    -- still falls through to tails
                    if spec.qualify_call then
                        full = spec.qualify_call(calln, full, src) or full
                    end
                    -- the inventory names the VERB (lint configs match on it);
                    -- the full expression text drives resolution. A dynamic
                    -- callee keeps its sigil: `→ $op` says what it is
                    local dynamic = spec.dynamic_callee_types
                        and spec.dynamic_callee_types[namen:type()] or nil
                    local callee = dynamic and full
                        or full:match('([%w_]+)$') or full
                    local sp = pos_of(calln)
                    local encl = in_function(calln, spec)
                    local is_top = encl == nil
                    if spec.is_top then is_top = spec.is_top(calln, src) end
                    local args, argv = {}, {}
                    if method then
                        args[1] = ''
                        argv[1] = { k = 'expr' }
                    end
                    local argsn = calln:field('arguments')[1]
                    if argsn and (argsn:type() == 'string' or argsn:type() == 'table_constructor') then
                        local v = argsn:type() == 'string'
                            and node_text(argsn, src):gsub('^["\']', ''):gsub('["\']$', '') or ''
                        args[#args + 1] = v
                        argv[#argv + 1] = v ~= '' and { k = 'lit', v = v } or { k = 'expr' }
                        argsn = nil
                    end
                    for a in (argsn and argsn.iter_children and argsn:iter_children() or NOOP) do
                        if a:named() and a:type() ~= 'comment' then
                            if a:type() == 'argument' then -- php wraps each arg
                                a = a:named_child(0) or a
                            end
                            local t = a:type()
                            if t == 'string' or t == 'string_literal'
                                or t == 'encapsed_string' then -- php "..."
                                local v = node_text(a, src):gsub('^["\']', ''):gsub('["\']$', '')
                                args[#args + 1] = v
                                argv[#argv + 1] = { k = 'lit', v = v }
                            elseif t == 'identifier' then
                                args[#args + 1] = ''
                                argv[#argv + 1] = { k = 'local', name = node_text(a, src),
                                    l = select(1, a:range()) }
                            elseif t == 'function_definition' or t == 'lambda' then
                                args[#args + 1] = ''
                                argv[#argv + 1] = { k = 'func' }
                            elseif t == 'variable_name' then -- php $var
                                args[#args + 1] = ''
                                argv[#argv + 1] = { k = 'local',
                                    name = node_text(a, src):gsub('^%$', ''),
                                    l = select(1, a:range()) }
                            elseif t == 'binary_expression'
                                and a:field('left')[1]
                                and a:field('left')[1]:type():find('string') then
                                -- 'prefix_' . x — the key is a PREFIX FAMILY
                                local pre = node_text(a:field('left')[1], src)
                                    :gsub('^["\']', ''):gsub('["\']$', '')
                                args[#args + 1] = ''
                                argv[#argv + 1] = { k = 'concat', prefix = pre }
                            else
                                local cname = callable_arg(a, src)
                                args[#args + 1] = ''
                                argv[#argv + 1] = cname
                                    and { k = 'callable', name = cname }
                                    or { k = 'expr' }
                            end
                        end
                    end
                    -- an import call also emits the module edge — with
                    -- the LOCAL it binds, when the spec can read it
                    -- (requalification needs to know which name means
                    -- which module)
                    if spec.import_call and full == spec.import_call then
                        local target = args[1] and args[1] ~= ''
                            and spec.resolve_import(args[1], fileset, file)
                        if target and target ~= file then
                            local pt = calln:parent()
                            local ptt = pt and pt:type() or ''
                            edges[#edges + 1] = { from = file, to = target, kind = 'import',
                                bind = spec.import_bind
                                    and spec.import_bind(calln, src) or nil,
                                sideeffect = (ptt == 'chunk' or ptt == 'block'
                                    or ptt:find('expression_statement')) and true or nil }
                        end
                    end
                    -- custom loader verbs (mantis require_api): the spec
                    -- recognizes loader-SHAPED names with a source-file
                    -- literal; the edge is name-matched, so it carries ~
                    if spec.import_call_like and args[1] and args[1] ~= ''
                        and spec.import_call_like(full, args[1]) then
                        local target = spec.resolve_import(args[1], fileset, file)
                        if target and target ~= file then
                            edges[#edges + 1] = { from = file, to = target,
                                kind = 'import', inferred = true }
                        end
                    end
                    local c = { callee = callee, args = args, argv = argv,
                        file = file, line = sp.start.line, method = method,
                        full = full ~= callee and full or nil,
                        dynamic = dynamic,
                        at = pos_of(namen), -- callee token range: relink
                        -- rebuilds edges at full fidelity, not line-anchored
                        top = is_top or nil }
                    calls[#calls + 1] = c
                    local indirect = (spec.indirect_calls or {})[callee]
                    indirect = indirect and args[indirect + (method and 1 or 0)]
                    indirect = indirect ~= '' and indirect or nil
                    c.indirect = indirect
                    pending[#pending + 1] = { call = c, file = file, full = full,
                        indirect = indirect,
                        at = pos_of(namen), encl = encl and pos_of(encl) }
                end
            end
        end
    end

    local cunparsed = {}

    -- container SFCs: the injection queries hand back host-language
    -- trees at absolute positions — script regions get the full pass,
    -- template expression trees the call pass (the id pass walks both
    -- later). Missing grammar → an opaque frontier module, like *.min.js.
    local function extract_container(file, clang, src)
        local okp, parser = pcall(vim.treesitter.get_string_parser, src, clang)
        if not okp then
            no_parser[clang] = true
            nodes[#nodes + 1] = { id = file, name = file, kind = 'module',
                file = file, unparsed = true, order = -1,
                range = { start = { line = 0, char = 0 }, ['end'] = { line = 0, char = 0 } } }
            cunparsed[#cunparsed + 1] = file
            return
        end
        local regions = container_trees(parser, clang) or {}
        local croot = parser:trees()[1]:root()
        stamp(file)
        nodes[#nodes + 1] = { id = file, name = file, kind = 'module', file = file,
            range = pos_of(croot), order = -1 }
        -- which regions are <script>? (the rest are template expressions)
        local scripts = {}
        local cq = parse_query(clang, '(script_element (raw_text) @s)')
        if cq then
            for _, n in cq:iter_captures(croot, src, 0, -1) do
                local s, _, e = n:range()
                scripts[#scripts + 1] = { s = s, e = e }
            end
        end
        for _, r in ipairs(regions) do
            local script = false
            for _, x in ipairs(scripts) do
                if r.s >= x.s and r.s <= x.e then script = true break end
            end
            if script then extract_defs(file, r.lang, r.spec, src, r.root) end
            extract_calls(file, r.lang, r.spec, src, r.root)
        end
        -- the template as ONE visible block row (a jump target): its
        -- extent is the top-level markup that isn't script/style
        local tps, tpe
        for c in croot:iter_children() do
            local t = c:type()
            if c:named() and t ~= 'script_element' and t ~= 'style_element'
                and t ~= 'comment' then
                local s, _, e = c:range()
                if not tps or s < tps then tps = s end
                if not tpe or e > tpe then tpe = e end
            end
        end
        if tps then
            nodes[#nodes + 1] = { id = ('%s::template@%d'):format(file, tps),
                name = 'template', kind = 'region', file = file, order = tps,
                range = { start = { line = tps, char = 0 },
                    ['end'] = { line = tpe, char = 0 } } }
        end
    end

    for _, file in ipairs(files) do
        local fd = io.open(abs(file), 'r')
        local src = fd and fd:read('a')
        if fd then fd:close() end
        if not src then goto next_file end
        local clang = container_for(file)
        if clang then
            extract_container(file, clang, src)
            goto next_file
        end
        do
            local lang, spec = lang_for(file)
            -- vendored bundles that dodge the *.min.js name (nocodb's
            -- swagger-ui-bundle.js): a line no human wrote means BUNDLE —
            -- content decides what the filename doesn't say. Opaque
            -- frontier, same as *.min.js
            if lang == 'javascript' or lang == 'typescript' then
                for line in src:sub(1, 32768):gmatch('[^\n]+') do
                    if #line > 5000 then
                        stamp(file)
                        nodes[#nodes + 1] = { id = file, name = file,
                            kind = 'module', file = file, unparsed = true,
                            order = -1, range = { start = { line = 0, char = 0 },
                                ['end'] = { line = 0, char = 0 } } }
                        cunparsed[#cunparsed + 1] = file
                        goto next_file
                    end
                end
            end
            local okp, parser = pcall(vim.treesitter.get_string_parser, src, lang)
            if not okp then
                no_parser[lang] = true
                goto next_file
            end
            local tsroot = parser:parse()[1]:root()
            stamp(file)
            nodes[#nodes + 1] = { id = file, name = file, kind = 'module', file = file,
                range = pos_of(tsroot), order = -1,
                effects = spec.module_effects
                    and spec.module_effects(tsroot, src) or nil }
            extract_defs(file, lang, spec, src, tsroot)
            extract_calls(file, lang, spec, src, tsroot)
        end
        ::next_file::
    end

    -- ── resolution pass: name-matched, ambiguity refuses to link ─────────────
    local scope_cache = {}
    local function scope_of(f)
        if scope_cache[f] == nil then
            local _, sp = elang_for(f)
            scope_cache[f] = sp and sp.scope
                and sp.scope(f, fileset, root) or false
        end
        return scope_cache[f] or nil
    end
    local refEdge = {}
    local function addref(from, to, at, inferred)
        local k = from .. '\31' .. to
        local e = refEdge[k]
        if not e then
            e = { from = from, to = to, kind = 'ref', at = {},
                self = (from == to) or nil, inferred = inferred or nil }
            refEdge[k] = e
            edges[#edges + 1] = e
        end
        if not inferred then e.inferred = nil end
        e.at[#e.at + 1] = at
    end
    -- a REGISTRATION edge: fn passed as data at load time (a callback
    -- list, an operations table) is kept alive by its module — an alibi
    local regEdge = {}
    local function addreg(from, to, at)
        local k = from .. '\31' .. to
        local e = regEdge[k]
        if not e then
            e = { from = from, to = to, kind = 'reg', at = {} }
            regEdge[k] = e
            edges[#edges + 1] = e
        end
        if at then e.at[#e.at + 1] = at end
    end
    local function resolve(name, file)
        -- 1-2 char names are shadow-bait (pattern vars, loop counters):
        -- name-matching them is noise-dominated in every language
        if #name < 3 then return nil end
        local clang, spec = elang_for(file)
        local snames = spec and spec.stdlib_names or {}
        if snames[name] then return nil end
        local cands = exact[name]
        -- the stdlib TAIL gate guards the fallbacks below; an exact match
        -- on a fully-qualified name (Engine::new) clears first
        if not cands
            and snames[name:match('([%w_%-]+)$') or ''] then
            return nil, nil, { rule = 'vocab' }
        end
        if cands then
            -- same-file priority is a FILE-SCOPE assumption (lua locals, C
            -- statics); dynamically-dispatched defs (instance methods) don't
            -- get it — they link only when globally unique
            local same, samedup
            for _, n in ipairs(cands) do
                if n.file == file and not n.cbarg then
                    if same then -- ambiguous within the file: refuse
                        samedup = samedup or { same }
                        samedup[#samedup + 1] = n
                    else
                        same = n
                    end
                end
            end
            if samedup then return nil, nil, refusal('samefile', samedup) end
            if same then return same, false end
            -- workspace-unique, but never across a scope boundary (rust
            -- crates: bare names cannot legally cross); dotted callees
            -- are method syntax and never match free functions
            local sc = scope_of(file)
            -- QUALIFIED references (pkg.Fn, x.method) are how code legally
            -- crosses a scope boundary, so they match globally — rust
            -- additionally knows x.f() is method dispatch; bare
            -- identifiers never cross, so their uniqueness is scope-local
            -- (`::` is a qualified receiver too — Class::m explicitly names
            -- the class and crosses packages, same as the tail path below)
            local dotted = name:find('.', 1, true) ~= nil
                or name:find('->', 1, true) ~= nil
                or name:find('::', 1, true) ~= nil
            local fitset = {}
            for _, n in ipairs(cands) do
                local fits
                if dotted then
                    fits = not (spec and spec.dot_calls_are_methods)
                        or n.kind == 'method'
                else
                    fits = sc == nil or scope_of(n.file) == sc
                end
                -- a name never crosses LANGUAGES: that is xlang's job,
                -- explicit and string-keyed — js .replace() must not
                -- tail-match a ruby #replace
                if fits and elang_for(n.file) ~= clang then fits = false end
                if fits then fitset[#fitset + 1] = n end
            end
            if #fitset == 1 then return fitset[1], true end
            -- the refusal is a PLACE: who was refused, and by which rule
            return nil, nil, refusal(#fitset > 1 and 'ambiguous' or 'blocked',
                #fitset > 0 and fitset or cands)
        end
        for _, pre in ipairs(spec and spec.stdlib_prefixes or {}) do
            if name:sub(1, #pre) == pre then return nil end
        end
        local tl = name:match('([%w_]+)$')
        local tc = tl and (tail[tl] or exact[tl])
        if tc then
            local sc = scope_of(file)
            local dotted = name:find('.', 1, true) ~= nil
                or name:find('->', 1, true) ~= nil
                or name:find('::', 1, true) ~= nil
            local fitset = {}
            for _, n in ipairs(tc) do
                local fits
                if dotted then
                    fits = not (spec and spec.dot_calls_are_methods)
                        or n.kind == 'method'
                else
                    fits = sc == nil or scope_of(n.file) == sc
                end
                -- a name never crosses LANGUAGES: that is xlang's job,
                -- explicit and string-keyed — js .replace() must not
                -- tail-match a ruby #replace
                if fits and elang_for(n.file) ~= clang then fits = false end
                if fits then fitset[#fitset + 1] = n end
            end
            if #fitset == 1 then return fitset[1], true end
            return nil, nil, refusal(#fitset > 1 and 'ambiguous' or 'blocked',
                #fitset > 0 and fitset or tc)
        end
        return nil
    end
    -- single-assignment literal flow: `$fn = 'compute'; $fn(3)` resolves —
    -- but ONLY when the variable has exactly one def in the function (two
    -- defs mean a branch chose, and we will not pick sides)
    local src_cache = {}
    local node_index = {}
    for _, n in ipairs(nodes) do node_index[n.id] = n end
    local function literal_flow(p)
        local fnid = fn_at(p.file, p.at.start.line)
        local fnode
        for _, r in ipairs(fnRanges[p.file] or {}) do
            if r.id == fnid then fnode = r end
        end
        local varname = p.full:match('^%$([%w_]+)$')
        if not (varname and fnid) then return nil end
        local df = node_index[fnid] and node_index[fnid].df
        if not df then return nil end
        local defstmt, ndefs = nil, 0
        for _, st in ipairs(df.stmts) do
            for _, d in ipairs(st.def) do
                if d == varname then
                    ndefs = ndefs + 1
                    defstmt = st
                end
            end
        end
        if ndefs ~= 1 or not defstmt then return nil end
        if src_cache[p.file] == nil then
            local fd = io.open(abs(p.file), 'r')
            src_cache[p.file] = fd and vim.split(fd:read('a'), '\n', { plain = true }) or false
            if fd then fd:close() end
        end
        local line = src_cache[p.file] and src_cache[p.file][defstmt.l] or ''
        local lit = line:match('%$' .. varname .. [=[%s*=%s*['"]([%w_:\]+)['"]]=])
        if not lit then return nil end
        return resolve(lit, p.file), lit
    end

    for _, p in ipairs(pending) do
        local target, inferred, refused
        if p.call.dynamic then
            -- $fn(...): frontier — unless single-assignment literal flow
            -- pins the name down within the function
            local lit
            target, lit = literal_flow(p)
            -- traced carries the LITERAL whenever one was found (truthy as
            -- before) so relink can re-resolve it — a parallel slice may
            -- know the literal but not see its target
            if lit then p.call.traced = lit end
            if target then
                p.call.dynamic = nil -- pinned down: no longer a frontier
            end
        elseif p.indirect then
            target = resolve(p.indirect, p.file)
            inferred = false -- the literal IS the dispatch mechanism
        else
            target, inferred, refused = resolve(p.full or p.call.callee, p.file)
        end
        if target then
            p.call.to = target.id
            p.call.inferred = inferred or nil
            local from = fn_at(p.file, p.at.start.line)
            p.call.fn = from
            if from then addref(from, target.id, p.at, inferred) end
        else
            p.call.fn = fn_at(p.file, p.at.start.line)
            p.call.refused = refused
        end
        -- callback pattern: an identifier argument naming a unique function
        for _, a in ipairs(p.call.argv) do
            if a.k == 'local' and a.name then
                local t2, _ = resolve(a.name, p.file)
                if t2 and (t2.kind == 'function' or t2.kind == 'method') then
                    a.k, a.to, a.up = 'func', t2.id, true
                    local from = p.call.fn
                    if from then
                        addref(from, t2.id, p.at, true)
                    else
                        -- passed as data at load time (RunPython(forward),
                        -- operations lists): registered, not dead — and the
                        -- module is the registrant (a descendable alibi)
                        t2.cbarg = true
                        addreg(p.file, t2.id, p.at)
                    end
                end
            end
        end
    end

    -- transitive parent::m — for the refusals the direct-parent qualify
    -- couldn't settle (parent only inherits m), walk the extends chain to
    -- the nearest ancestor that defines it. Bounded; over the full graph.
    resolve_super(calls, data.extends, exact, addref)

    -- use edges + function references (the id pass — factored so parallel
    -- extraction can run it in workers against PARENT-built global
    -- lookups; slice-local uniqueness is not global uniqueness)
    if not (opts and opts.skip_idpass) then
        local fn_unique = {}
        for name, fns in pairs(exact) do
            if #fns == 1 then
                fn_unique[name] = { id = fns[1].id, file = fns[1].file,
                    line = fns[1].range.start.line, node = fns[1] }
            end
        end
        local var_named = {}
        for name, vars in pairs(varsByName) do
            local list = {}
            for _, v in ipairs(vars) do
                list[#list + 1] = { id = v.id, file = v.file,
                    line = v.range.start.line }
            end
            var_named[name] = list
        end
        data.names = {}
        local seq_scopes, seq_any = {}, false
        for f in pairs(fileset) do
            local _, sp = elang_for(f)
            if sp and sp.scope then
                seq_scopes[f] = sp.scope(f, fileset, root)
                seq_any = true
            end
        end
        id_pass(root, files, {
            fn_unique = fn_unique,
            var_named = var_named,
            fn_ranges = fnRanges,
            scopes = seq_any and seq_scopes or nil,
            addref = addref,
            adduse = function (e) edges[#edges + 1] = e end,
            mark_cbarg = function (u) u.node.cbarg = true end,
            add_names = function (f, s) data.names[f] = s end,
        }, abs)
    else
        -- the parallel driver needs each slice's function extents to run
        -- the id pass later (fn_at over these files)
        data.fn_ranges = fnRanges
    end

    -- minified bundles as OPAQUE frontiers: visible modules, no parsed
    -- content — descend reaches into them by lazy text search (store)
    local okc, cfg = pcall(require, 'cartograph.config')
    if #minified > 0 and not (okc and cfg.unparsed == false) then
        data.unparsed = minified
        for _, f in ipairs(minified) do
            nodes[#nodes + 1] = { id = f, name = f, kind = 'module', file = f,
                unparsed = true, order = -1,
                range = { start = { line = 0, char = 0 }, ['end'] = { line = 0, char = 0 } } }
        end
    end
    -- container files whose grammar is missing already have their frontier
    -- module node; the list feeds the same lazy text-search descend
    if #cunparsed > 0 then
        data.unparsed = data.unparsed or {}
        for _, f in ipairs(cunparsed) do
            table.insert(data.unparsed, f)
        end
    end
    data.no_parser = next(no_parser) and vim.tbl_keys(no_parser) or nil
    return data
end

--- Re-resolve name-matched links over a (possibly spliced) graph: every
--- call lacking `to` gets another chance against the CURRENT node set,
--- and its ref edge is added (deduped against existing edges). Mirrors
--- extract()'s resolution semantics — same-file non-cbarg priority,
--- unique-tail fallback, stdlib gates, min-length guard. Used by live
--- refresh, where a changed file's calls (and other files' calls INTO
--- the changed file) need relinking.
function M.relink(data, touched)
    local relset = {}
    for _, n in ipairs(data.nodes) do
        if n.kind == 'module' then relset[n.file] = true end
    end
    local scope_cache = {}
    local function scope_of(f)
        if scope_cache[f] == nil then
            local _, sp = elang_for(f)
            scope_cache[f] = sp and sp.scope
                and sp.scope(f, relset, data.root) or false
        end
        return scope_cache[f] or nil
    end
    local exact, tail = {}, {}
    for _, n in ipairs(data.nodes) do
        if (n.kind == 'function' or n.kind == 'method') and not n.torn
            and not n.decl then -- a prototype declaration is not a call target
            exact[n.name] = exact[n.name] or {}
            table.insert(exact[n.name], n)
            local tl = n.name:match('([%w_]+)$')
            if tl and tl ~= n.name then
                tail[tl] = tail[tl] or {}
                table.insert(tail[tl], n)
            end
        end
    end
    local refEdge, regEdge = {}, {}
    for _, e in ipairs(data.edges) do
        if e.kind == 'ref' then refEdge[e.from .. '\31' .. e.to] = e
        elseif e.kind == 'reg' then regEdge[e.from .. '\31' .. e.to] = e end
    end
    local function addref(from, to, at, inferred)
        local k = from .. '\31' .. to
        local e = refEdge[k]
        if not e then
            e = { from = from, to = to, kind = 'ref', at = {},
                self = (from == to) or nil, inferred = inferred or nil }
            refEdge[k] = e
            data.edges[#data.edges + 1] = e
        end
        if not inferred then e.inferred = nil end
        e.at[#e.at + 1] = at
    end
    local function addreg(from, to, at)
        local k = from .. '\31' .. to
        if regEdge[k] then return end -- already registered from this module
        local e = { from = from, to = to, kind = 'reg', at = at and { at } or {} }
        regEdge[k] = e
        data.edges[#data.edges + 1] = e
    end
    local function resolve(name, file)
        if #name < 3 then return nil end
        local clang, spec = elang_for(file)
        local snames = spec and spec.stdlib_names or {}
        if snames[name] then return nil end
        local cands = exact[name]
        -- the stdlib TAIL gate guards the fallbacks below; an exact match
        -- on a fully-qualified name (Engine::new) clears first
        if not cands
            and snames[name:match('([%w_%-]+)$') or ''] then
            return nil, nil, { rule = 'vocab' }
        end
        if cands then
            local same, samedup
            for _, n in ipairs(cands) do
                if n.file == file and not n.cbarg then
                    if same then -- ambiguous within the file: refuse
                        samedup = samedup or { same }
                        samedup[#samedup + 1] = n
                    else
                        same = n
                    end
                end
            end
            if samedup then return nil, nil, refusal('samefile', samedup) end
            if same then return same, false end
            -- workspace-unique, but never across a scope boundary (rust
            -- crates: bare names cannot legally cross); dotted callees
            -- are method syntax and never match free functions
            local sc = scope_of(file)
            -- QUALIFIED references (pkg.Fn, x.method) are how code legally
            -- crosses a scope boundary, so they match globally — rust
            -- additionally knows x.f() is method dispatch; bare
            -- identifiers never cross, so their uniqueness is scope-local
            -- (`::` is a qualified receiver too — Class::m explicitly names
            -- the class and crosses packages, same as the tail path below)
            local dotted = name:find('.', 1, true) ~= nil
                or name:find('->', 1, true) ~= nil
                or name:find('::', 1, true) ~= nil
            local fitset = {}
            for _, n in ipairs(cands) do
                local fits
                if dotted then
                    fits = not (spec and spec.dot_calls_are_methods)
                        or n.kind == 'method'
                else
                    fits = sc == nil or scope_of(n.file) == sc
                end
                -- a name never crosses LANGUAGES: that is xlang's job,
                -- explicit and string-keyed — js .replace() must not
                -- tail-match a ruby #replace
                if fits and elang_for(n.file) ~= clang then fits = false end
                if fits then fitset[#fitset + 1] = n end
            end
            if #fitset == 1 then return fitset[1], true end
            -- the refusal is a PLACE: who was refused, and by which rule
            return nil, nil, refusal(#fitset > 1 and 'ambiguous' or 'blocked',
                #fitset > 0 and fitset or cands)
        end
        for _, pre in ipairs(spec and spec.stdlib_prefixes or {}) do
            if name:sub(1, #pre) == pre then return nil end
        end
        local tl = name:match('([%w_]+)$')
        local tc = tl and (tail[tl] or exact[tl])
        if tc then
            local sc = scope_of(file)
            local dotted = name:find('.', 1, true) ~= nil
                or name:find('->', 1, true) ~= nil
                or name:find('::', 1, true) ~= nil
            local fitset = {}
            for _, n in ipairs(tc) do
                local fits
                if dotted then
                    fits = not (spec and spec.dot_calls_are_methods)
                        or n.kind == 'method'
                else
                    fits = sc == nil or scope_of(n.file) == sc
                end
                -- a name never crosses LANGUAGES: that is xlang's job,
                -- explicit and string-keyed — js .replace() must not
                -- tail-match a ruby #replace
                if fits and elang_for(n.file) ~= clang then fits = false end
                if fits then fitset[#fitset + 1] = n end
            end
            if #fitset == 1 then return fitset[1], true end
            return nil, nil, refusal(#fitset > 1 and 'ambiguous' or 'blocked',
                #fitset > 0 and fitset or tc)
        end
        return nil
    end
    local n = 0
    for _, c in ipairs(data.calls or {}) do
        -- dynamic calls stay frontiers UNLESS a literal-flow trace already
        -- named the callee (a parallel slice may know the literal but not
        -- have seen its target)
        if not c.to and (not c.dynamic or type(c.traced) == 'string') then
            local target, inferred, refused
            if type(c.traced) == 'string' then
                target = resolve(c.traced, c.file)
                inferred = false
            elseif c.indirect then
                target = resolve(c.indirect, c.file)
                inferred = false
            else
                target, inferred, refused = resolve(c.full or c.callee, c.file)
            end
            if target then
                c.to = target.id
                -- the ~ mark is part of the resolution, not decoration:
                -- a relinked call must carry the same honesty as extract's
                c.inferred = inferred or nil
                c.refused = nil
                if c.dynamic then c.dynamic = nil end -- pinned by the trace
                n = n + 1
                if touched then touched[c.file] = true end
                if c.fn then
                    addref(c.fn, target.id, c.at
                        or { start = { line = c.line, char = 0 },
                            ['end'] = { line = c.line, char = 0 } }, inferred)
                end
            else
                -- the refusal recomputed against the CURRENT global
                -- node set (a worker's slice-local refusal is stale)
                c.refused = refused
            end
        end
        -- callback-pattern mirror: an identifier argument naming a unique
        -- function upgrades to a resolved 'func' arg (extract does this;
        -- without the mirror a splice or audit loses the upgrade)
        for _, a in ipairs(c.argv or {}) do
            if a.k == 'local' and a.name then
                local t2 = resolve(a.name, c.file)
                if t2 and (t2.kind == 'function' or t2.kind == 'method') then
                    a.k, a.to, a.up = 'func', t2.id, true
                    if touched then touched[c.file] = true end
                    if c.fn then
                        addref(c.fn, t2.id,
                            { start = { line = c.line, char = 0 },
                                ['end'] = { line = c.line, char = 0 } }, true)
                    else
                        t2.cbarg = true -- load-time data reference (mirror)
                        addreg(c.file, t2.id,
                            { start = { line = c.line, char = 0 },
                                ['end'] = { line = c.line, char = 0 } })
                        if touched then touched[t2.file] = true end
                    end
                end
            end
        end
    end
    -- transitive parent::m over the full (merged/spliced) graph — mirrors
    -- extract's enrichment so the parallel and refresh paths resolve the
    -- same superclass chains the sequential path does
    n = n + resolve_super(data.calls, data.extends, exact, addref)
    return n
end

return M
