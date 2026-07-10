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

-- indexed child iteration, replacing TSNode:iter_children() everywhere:
-- iter_children allocates a TSTreeCursor userdata + a closure PER CALL —
-- measured 2.7x slower and ~2x more transient garbage than indexed access,
-- at every tree shape including an 8000-statement chunk (no O(width^2)
-- penalty in practice; the per-node allocation dominates). STATELESS
-- iterator (zero alloc), same sequence as iter_children (ALL children,
-- anonymous tokens included — existing named()/type() guards filter):
--   for _, c in inext, node, -1 do ... end
local function inext(n, i)
    i = i + 1
    local c = n:child(i)
    if c then return i, c end
end

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
    for _, c in inext, node, -1 do
        if c:type() == 'local_variable_declaration' then
            local ty, row = java_base_type(c:field('type')[1], src), select(1, c:range())
            if ty == 'var' then ty = nil end -- `var x = ...`: no declared name
            for _, d in inext, c, -1 do
                if d:type() == 'variable_declarator' then
                    local nm = d:field('name')[1]
                    if nm then
                        local b = { ty = ty, row = row }
                        if ty == nil then
                            -- typed only by the INITIALIZER: `new Foo()`
                            -- names the type right here; a call's return
                            -- type is knowable only after resolution, so
                            -- record the call site as INIT PROVENANCE for
                            -- the return-type rounds (graph-VM MVP)
                            local v = d:field('value')[1]
                            local vt = v and v:type()
                            if vt == 'object_creation_expression' then
                                b.ty = java_base_type(v:field('type')[1], src)
                            elseif vt == 'method_invocation' then
                                local vn = v:field('name')[1]
                                if vn then
                                    local r2, c2 = vn:range()
                                    b.init = { r = r2, c = c2 }
                                end
                            end
                        end
                        out[node_text(nm, src)] = b
                    end
                end
            end
        end
    end
end
local function jvt_params(node, src, out) -- name -> {ty}
    local ps = node:field('parameters')[1]
    for _, c in (ps and inext or NOOP), ps, -1 do
        if c:type() == 'formal_parameter' or c:type() == 'spread_parameter' then
            local nm = c:field('name')[1]
            if nm then out[node_text(nm, src)] = { ty = java_base_type(c:field('type')[1], src) } end
        end
    end
end
local function jvt_fields(node, src, out) -- name -> {ty}
    for _, c in inext, node, -1 do
        if c:type() == 'field_declaration' then
            local ty = java_base_type(c:field('type')[1], src)
            for _, d in inext, c, -1 do
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

-- Lua scope spec (untyped language: binders carry no ty — position and
-- kind are the value). `kind = 'module'` on chunk: a top-level local IS the
-- module-level entity (the id pass pins it to THIS file); inner kinds mean
-- the mention names a local, not any module var.
local function lua_locals(node, src, out) -- chunk/block statement locals
    for _, stmt in inext, node, -1 do
        local t = stmt:type()
        if t == 'variable_declaration' then
            -- `local a, b = 1, 2` wraps an assignment_statement; a bare
            -- `local a` holds the variable_list directly
            local row = select(1, stmt:range())
            for _, a in inext, stmt, -1 do
                local vl = a:type() == 'variable_list' and a or nil
                if not vl and a:type() == 'assignment_statement' then
                    for _, c in inext, a, -1 do
                        if c:type() == 'variable_list' then vl = c break end
                    end
                end
                for _, v in (vl and inext or NOOP), vl, -1 do
                    if v:type() == 'identifier' then
                        out[node_text(v, src)] = { row = row }
                    end
                end
            end
        elseif t == 'function_declaration' then
            local islocal = false
            for _, c in inext, stmt, -1 do
                if c:type() == 'local' then islocal = true break end
            end
            if islocal then
                local nm = stmt:field('name')[1]
                if nm and nm:type() == 'identifier' then
                    out[node_text(nm, src)] = { row = select(1, stmt:range()) }
                end
            end
        end
    end
end
local function lua_params(node, src, out)
    local ps = node:field('parameters')[1]
    for _, c in (ps and inext or NOOP), ps, -1 do
        if c:type() == 'identifier' then out[node_text(c, src)] = {} end
    end
end
local function lua_forvars(node, src, out)
    local row = select(1, node:range())
    for _, cl in inext, node, -1 do
        local t = cl:type()
        if t == 'for_numeric_clause' then
            local v = cl:named_child(0) -- ONLY the loop var; bounds are exprs
            if v and v:type() == 'identifier' then
                out[node_text(v, src)] = { row = row }
            end
        elseif t == 'for_generic_clause' then
            for _, c in inext, cl, -1 do
                if c:type() == 'variable_list' then -- the vars, not the iterator
                    for _, v in inext, c, -1 do
                        if v:type() == 'identifier' then
                            out[node_text(v, src)] = { row = row }
                        end
                    end
                end
            end
        end
    end
end
local LUA_SCOPES = {
    chunk                = { kind = 'module', harvest = lua_locals },
    block                = { kind = 'local', harvest = lua_locals },
    function_declaration = { kind = 'param', harvest = lua_params },
    function_definition  = { kind = 'param', harvest = lua_params },
    for_statement        = { kind = 'local', harvest = lua_forvars },
}

-- ONE scope model per parse tree, shared by extract_defs (df binder tags)
-- and extract_calls (receiver typing) — keyed by TREE IDENTITY (the same
-- tsroot userdata flows to both passes), so per-tree lifetime is
-- structural: node ids cannot alias across trees, and the two-models-per-
-- file redundancy is gone. nil when the language has no scope spec.
local jvt_sm, jvt_root = nil, nil
local function tree_model(tsroot, src, spec)
    if jvt_root ~= tsroot then
        jvt_root = tsroot
        jvt_sm = spec.scopes
            and require('cartograph.scope').model(src, spec.scopes) or nil
    end
    return jvt_sm
end

-- the declared type name of a simple variable `ident` visible at `from`.
-- MECHANISM: scope.resolve — every visible binder, nearest first (inner
-- shadows outer; block locals position-checked). POLICY (here, deliberately):
--   * a param answers unconditionally, even untyped — matching a param ends
--     the question;
--   * an untyped local/field (scoped-generic base java_base_type can't name)
--     is TRANSPARENT — the shadowed outer binder answers, but the answer is
--     a GUESS (the real receiver is the nearer binder of an unnameable type),
--     so it returns a HEDGE alongside: resolve-but-mark, the edge keeps its
--     recall and gains `~` (scope-model step 2; pinned by shadowedSameFile).
-- `fields_only` restricts to class fields (a `this.field` receiver).
-- Returns ty, hedge, defer — hedge = { rule, row? } naming the walked-past
-- binder; defer = { r, c } = the INIT-PROVENANCE call site when the binder
-- is typed only by its initializer's return (the return-type rounds settle
-- it — precise beats the walk-out guess, so defer preempts the hedge).
local function java_var_type(ident, from, fields_only)
    if not jvt_sm then return end
    local chain, k = jvt_sm.resolve(ident, from, fields_only and 'field' or nil)
    local skipped -- the nearest untyped binder walked past (the witness)
    for i = 1, k do
        local b = chain[i]
        if b.kind == 'param' or b.ty ~= nil then
            return b.ty, (skipped and b.ty ~= nil)
                and { rule = 'shadow-walkout', row = skipped.row } or nil
        end
        if b.init then return nil, nil, b.init end
        skipped = skipped or b
    end
end

M.spec = {
    lua = {
        exts = { 'lua' },
        scopes = LUA_SCOPES, -- lexical-first id pass (scope-model step 3)
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
                    (variable_list name: (identifier) @vname)
                    (expression_list value: (_) @value))) @vdef
            (chunk
                (assignment_statement
                    (variable_list name: (identifier) @vname)
                    (expression_list value: (_) @value)) @vdef)
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
            for _, c in inext, as, -1 do
                if c:type() == 'variable_list' then vl = c break end
            end
            if not vl then return nil end
            local vi, i = 0, 0
            for _, c in inext, el, -1 do
                if c:named() then
                    i = i + 1
                    if c:equal(calln) then vi = i end
                end
            end
            i = 0
            for _, c in inext, vl, -1 do
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
                for _, v in inext, vl, -1 do
                    if v:named() then
                        local n = node_text(v, src)
                        locals[n:match('^[%w_]+') or n] = true
                    end
                end
            end
            for _, stmt in inext, root, -1 do
                local t = stmt:type()
                if t == 'variable_declaration' then
                    for _, c in inext, stmt, -1 do
                        if c:type() == 'assignment_statement' then
                            for _, vl in inext, c, -1 do
                                if vl:type() == 'variable_list' then
                                    collect_names(vl)
                                end
                            end
                        end
                    end
                elseif t == 'function_declaration' then
                    local islocal = false
                    for _, c in inext, stmt, -1 do
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
            for _, stmt in inext, root, -1 do
                local t = stmt:type()
                if t == 'function_call' then
                    return true -- a bare call runs at load time
                elseif t == 'assignment_statement' then
                    for _, vl in inext, stmt, -1 do
                        if vl:type() == 'variable_list' then
                            for _, v in inext, vl, -1 do
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
                    for _, c in inext, stmt, -1 do
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
        mention_types = { variable = true },
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
                for _, c in inext, n, -1 do
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
                for _, d in inext, lb, -1 do
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
            ((list . (symbol) @_kw . (symbol) @vname . (number) @value) @vdef
                (#eq? @_kw "define"))
            ((list . (symbol) @_kw . (symbol) @vname . (string) @value) @vdef
                (#eq? @_kw "define"))
        ]=],
        body_field = nil,
        mention_types = { symbol = true },
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
                (variable_declarator name: (identifier) @vname value: (_) @value) @vdef))
            (program (variable_declaration
                (variable_declarator name: (identifier) @vname value: (_) @value) @vdef))
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
        ]=],
        -- call_user_func('name', ...) CALLS name: the literal resolves as
        -- the real callee (the string is the dispatch mechanism, not a ~)
        indirect_calls = { call_user_func = 1, call_user_func_array = 1 },
        -- a variable in callee position is runtime state ($fn()) — by NODE
        -- TYPE: jQuery's $() is a plain identifier and must stay a call
        dynamic_callee_types = { variable_name = true },
        vars = [=[
            (program (expression_statement (assignment_expression
                left: (variable_name (name) @vname) right: (_) @value) @vdef))
            (const_declaration (const_element (name) @vname (_) @value) @vdef)
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
                    for _, c in inext, p2, -1 do
                        if c:type() == 'base_clause' then
                            for _, pc in inext, c, -1 do
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
    bash = {
        exts = { 'sh', 'bash' },
        functions = [=[
            (function_definition name: (word) @name) @def
        ]=],
        -- every command is application; builtins/coreutils opt out via
        -- stdlib_names. `local`/`declare`/`export` are declaration_command
        -- in the grammar, so they never reach here.
        calls = [=[
            (command name: (command_name (word) @name)) @call
        ]=],
        -- top-level assignments (bash vars are PROCESS-GLOBAL by default —
        -- which is also why this spec has NO scopes table: name matching
        -- across files is the semantically honest default, and `local` is
        -- DYNAMIC scoping our lexical model must not fake; banked design)
        vars = [=[
            (program (variable_assignment name: (variable_name) @vname value: (_) @value) @vdef)
            (program (declaration_command (variable_assignment name: (variable_name) @vname value: (_) @value) @vdef))
        ]=],
        litdata_types = { string = true, raw_string = true, array = true,
            word = true, number = true },
        body_field = 'body',
        -- $x expansions carry variable_name; a bare word in argument
        -- position can NAME a function (trap cleanup EXIT) — both mention
        -- kinds feed the id pass
        mention_types = { word = true, variable_name = true },
        df_ids = { variable_name = true },
        -- typed-string SINK: eval's arg IS code — the literal head names
        -- the real callee (the aperture-analyzer side of the eval story)
        string_sinks = { eval = { arg = 1, ty = 'code' } },
        -- bash has NO qualification syntax: a command names its function
        -- literally (slashed ble/* names are exact identifiers) — never
        -- tail-match, never tail-vocab
        literal_names = true,
        -- APERTURE emission (scope-model memo: emit from day one, zero
        -- analyzers — the refusal IS the contract): eval conjures
        -- functions and vars no static pass can enumerate. Witness sites
        -- ride the module node; resolution turns "namespaced name with
        -- no def" into refusal-with-witness instead of presuming an
        -- external command. Capture name = the aperture rule.
        aperture_query = [=[
            ((command name: (command_name (word) @_kw)) @eval
                (#eq? @_kw "eval"))
            ((command name: (command_name (word) @_b)
                . argument: (word) @_arg) @eval
                (#eq? @_b "builtin") (#eq? @_arg "eval"))
        ]=],
        -- a bash function_definition is self-contained (no class context
        -- to escape), and tree-sitter-bash chokes locally on exotic
        -- parameter expansions (`${1//&/&amp;}` tears testssl.sh at line
        -- 580 of 26k): tear only defs whose OWN subtree holds the error
        torn_by_node = true,
        is_method = function () return false end,
        -- source/. splice a file in at RUN time: resolve like C includes —
        -- relative to the sourcing file, then the root, then a unique
        -- basename (ambiguity refuses, as everywhere). Runtime cwd is the
        -- honest unknowable; this is the conventional layout.
        import_query = [=[
            ((command name: (command_name (word) @_kw) argument: (word) @path)
                (#any-of? @_kw "source" "."))
        ]=],
        resolve_import = function (path, files, from)
            local dir = from:match('^(.*)/[^/]*$')
            for _, cand in ipairs({ dir and (dir .. '/' .. path) or path,
                (path:gsub('^%./', '')) }) do
                if files[cand] then return cand end
            end
            local base, hit = path:match('([^/]+)$'), nil
            for f in pairs(files) do
                if f:match('([^/]+)$') == base then
                    if hit then return nil end
                    hit = f
                end
            end
            return hit
        end,
        -- a script IS its top level: any statement that isn't a function
        -- def / comment runs on load (a top-level assignment writes a
        -- process-global, which is an effect too)
        module_effects = function (root)
            for _, c in inext, root, -1 do
                local t = c:type()
                if c:named() and t ~= 'function_definition' and t ~= 'comment' then
                    return true
                end
            end
            return false
        end,
        stdlib_names = (function ()
            local t = {}
            for _, n in ipairs({
                -- builtins
                'echo', 'printf', 'read', 'cd', 'pwd', 'export', 'unset',
                'shift', 'exit', 'return', 'source', 'eval', 'exec', 'trap',
                'set', 'test', 'true', 'false', 'wait', 'kill', 'ulimit',
                'umask', 'getopts', 'command', 'type', 'hash', 'alias',
                'break', 'continue', 'let', 'readonly', 'caller', 'shopt',
                'complete', 'compgen', 'bind', 'builtin', 'enable', 'mapfile',
                'readarray', 'suspend', 'times', 'disown', 'bg', 'fg', 'jobs',
                -- ubiquitous externals
                'ls', 'cat', 'grep', 'egrep', 'fgrep', 'sed', 'awk', 'cut',
                'tr', 'sort', 'uniq', 'head', 'tail', 'wc', 'find', 'xargs',
                'rm', 'mv', 'cp', 'mkdir', 'rmdir', 'touch', 'chmod', 'chown',
                'ln', 'basename', 'dirname', 'date', 'sleep', 'curl', 'wget',
                'tar', 'gzip', 'git', 'which', 'env', 'id', 'whoami', 'uname',
                'hostname', 'tee', 'stat', 'du', 'df', 'ps', 'mktemp', 'seq',
                'expr', 'dig', 'openssl', 'sudo', 'apt', 'yum', 'dnf',
            }) do t[n] = true end
            return t
        end)(),
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
                left: (constant) @vname right: (_) @value) @vdef)
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
                name: (identifier) @vname value: (_) @value)) @vdef
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
        scopes = JAVA_SCOPES, -- lexical-first id pass (scope-model step 3)
        -- declared return type = the per-method SUMMARY (graph-VM MVP)
        def_ret = function (defn, src)
            if defn:type() == 'method_declaration' then
                return java_base_type(defn:field('type')[1], src)
            end
        end,
        qualify_call = function (calln, name, src)
            if calln:type() ~= 'method_invocation' then return nil end
            local obj = calln:field('object')[1]
            local cls, hedge, defer
            if not obj then -- implicit this
                cls = java_enclosing_class(calln, src)
            else
                local ot = obj:type()
                if ot == 'this' then
                    cls = java_enclosing_class(calln, src)
                elseif ot == 'super' then
                    local _, cnode = java_enclosing_class(calln, src)
                    local sup = cnode and cnode:field('superclass')[1]
                    for _, c in (sup and inext or NOOP), sup, -1 do
                        if c:type() == 'type_identifier' then
                            cls = node_text(c, src)
                            break
                        end
                    end
                elseif ot == 'identifier' then
                    local objname = node_text(obj, src)
                    cls, hedge, defer = java_var_type(objname, calln)
                    if not cls and not defer and objname:match('^%u') then
                        -- no binder and PascalCase: a STATIC call on the
                        -- class named right here (convention-sound; the
                        -- qualification just exact/tail-matches like any
                        -- other, so a miss costs nothing). This is what
                        -- lets `var f = Finder.of(...)` chains settle: the
                        -- determining static call resolves, its ret flows.
                        cls = objname
                    end
                elseif ot == 'method_invocation' then
                    -- CHAINED receiver f().g(): g's class is f's return type,
                    -- knowable only after f resolves — defer to the
                    -- return-type rounds, recording f's call site
                    local vn = obj:field('name')[1]
                    if vn then
                        local r2, c2 = vn:range()
                        defer = { r = r2, c = c2 }
                    end
                elseif ot == 'object_creation_expression' then
                    -- new Foo().m(): the type is right here
                    cls = java_base_type(obj:field('type')[1], src)
                elseif ot == 'field_access' then
                    local fo, ff = obj:field('object')[1], obj:field('field')[1]
                    if fo and fo:type() == 'this' and ff then
                        cls, hedge = java_var_type(
                            node_text(ff, src), calln, true)
                    end
                end
            end
            -- a JDK-typed receiver dispatches into the stdlib, not a project
            -- def: leave it bare for the stdlib_names/prefix gate to skip
            if cls and JAVA_JDK_TYPES[cls] then return nil end
            -- the hedge rides the qualification: a hedged qualification makes
            -- the resulting edge INFERRED even where resolution is confident
            return cls and (cls .. '::' .. name) or nil, cls and hedge or nil,
                (not cls) and defer or nil
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
                for _, c in inext, mods, -1 do
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
                name: (identifier) @vname value: (_) @value) @vdef))
            (source_file (const_declaration (const_spec
                name: (identifier) @vname value: (_) @value) @vdef))
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
            (const_item name: (identifier) @vname value: (_) @value) @vdef
            (static_item name: (identifier) @vname value: (_) @value) @vdef
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
            for _, c in inext, defn, -1 do
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
                (assignment left: (identifier) @vname right: (_) @value) @vdef))
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

-- The raw-parser rider (fusion Stage C): the extract hot loop parses via
-- a REUSED raw TSParser per language — LanguageTree construction
-- (injection scanning, a per-file object graph) measured ~16% of parse
-- cost, and extraction queries only ever visit the host tree. Containers
-- keep LanguageTree (injections ARE their content); anything raw can't
-- serve falls back to it. Trees are immutable: reusing one parser across
-- files is safe, earlier trees stay valid while referenced.
local RAW_PARSERS = {} -- lang -> TSParser | false (raw unavailable)
local function raw_parse(lang, src)
    local p = RAW_PARSERS[lang]
    if p == nil then
        p = false
        if vim._create_ts_parser then
            local ok, added = pcall(vim.treesitter.language.add, lang)
            if ok and added then
                local okc, np = pcall(vim._create_ts_parser, lang)
                if okc then p = np end
            end
        end
        RAW_PARSERS[lang] = p
    end
    if not p then return nil end
    local ok, tree = pcall(p.parse, p, nil, src)
    if ok then return tree end
    return nil
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

-- `memo` (optional, PER TREE — node ids alias across trees) caches the
-- answer at every ancestor visited: call sites in the same function stop
-- one level up instead of re-walking to the root each time.
local IF_PATH = {} -- scratch: ids visited this walk (single-threaded)
local function in_function(n, spec, memo)
    local types = spec and spec.fn_types or DEFAULT_FN_TYPES
    local p = n:parent()
    if not memo then
        while p do
            if types[p:type()] then return p end
            p = p:parent()
        end
        return nil
    end
    local np = 0
    while p do
        local id = p:id()
        local hit = memo[id]
        if hit == nil and types[p:type()] then hit = p end
        if hit ~= nil then
            for i = 1, np do memo[IF_PATH[i]] = hit end
            memo[id] = hit
            return hit or nil
        end
        np = np + 1
        IF_PATH[np] = id
        p = p:parent()
    end
    for i = 1, np do memo[IF_PATH[i]] = false end
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
        for _, item in inext, n, -1 do
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
                    for _, c2 in inext, item, -1 do
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
        for _, el in inext, a, -1 do
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
            for _, c in inext, n, -1 do
                if c:named() then hunt(c, depth + 1) end
            end
        end
        hunt(a, 0)
        return found
    end
    return nil
end

local function fn_params(def, spec, src, method)
    local ps = spec.params_field and def:field(spec.params_field)[1]
    local out = method and { 'self' } or {}
    if ps then
        for _, c in inext, ps, -1 do
            if c:type() == 'identifier' or c:type() == 'variable' then
                out[#out + 1] = node_text(c, src)
            elseif c:type() == 'variable_name' then -- php $param
                out[#out + 1] = node_text(c, src):gsub('^%$', '')
            elseif c:named() then -- c parameter_declaration / defaulted params
                for _, id in inext, c, -1 do
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
-- memoized by EXTENSION: elang_for runs once per call site during
-- resolution (87k on server), and lang_for underneath is a spec-registry
-- scan. The registry is static (no runtime spec mutation), so the memo
-- cannot go stale.
local EXT_ELANG = {} -- ext -> { lang|false, spec|false }
local function elang_for(file)
    local ext = file:match('%.([%w]+)$') or ''
    local hit = EXT_ELANG[ext]
    if hit then return hit[1] or nil, hit[2] or nil end
    local lang, spec
    if CONTAINERS[ext] then
        lang, spec = 'javascript', M.spec.javascript
    else
        lang, spec = lang_for(file)
        if lang == 'typescript' then lang, spec = 'javascript', M.spec.javascript end
    end
    EXT_ELANG[ext] = { lang or false, spec or false }
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

-- Return-type rounds (the graph-VM MVP — see the graph-vm design memo).
-- A call whose receiver is ANOTHER call (f().g()) or a local typed only by
-- its initializer's return (`var x = f(); x.g()`) could not be qualified
-- lexically; extract recorded the DETERMINING call site on it (c.rt). Once
-- that call resolves, its target's declared return type (n.ret — the
-- per-method summary) qualifies this one: Ret::method, exact-matched with
-- the same language-fit/ambiguity discipline as resolve_super. Chains
-- settle in ROUNDS — a().b().c() unlocks one link per pass: the
-- types⇄call-graph mutual fixpoint in its smallest form. Round count is
-- returned for the measurement protocol. Shared by extract and relink.
local function resolve_returns(calls, node_index, exact, addref)
    local callidx = {}
    -- the deferred WORKLIST: rounds iterate only the calls still carrying
    -- unresolved rt provenance, not the whole call array per round (which
    -- profiled at ~2% of extract on server — 3 rounds x 240k calls)
    local deferred, dn = {}, 0
    for _, c in ipairs(calls or {}) do
        if c.at and c.at.start then
            callidx[c.file .. '\31' .. c.at.start.line .. '\31' .. c.at.start.char] = c
        end
        if c.rt and not c.to and c.callee then
            dn = dn + 1
            deferred[dn] = c
        end
    end
    local n, rounds = 0, 0
    repeat
        local progress = false
        rounds = rounds + 1
        local keep, kn = {}, 0
        for i = 1, dn do
            local c = deferred[i]
            local settled = false
            do
                local d = callidx[c.file .. '\31' .. c.rt.r .. '\31' .. c.rt.c]
                local ret = d and d.to and node_index[d.to] and node_index[d.to].ret
                if not ret and d and d.refused and d.refused.cands
                    and d.refused.n and d.refused.n <= #d.refused.cands then
                    -- overloads refuse the CALL, but when every candidate
                    -- declares the same return type, the TYPE is unambiguous
                    -- and the chain continues (untruncated cands only — a
                    -- capped list can't prove agreement)
                    local agree
                    for _, id in ipairs(d.refused.cands) do
                        local r = node_index[id] and node_index[id].ret
                        if not r or (agree and r ~= agree) then agree = nil break end
                        agree = r
                    end
                    ret = agree
                end
                -- a JDK return type dispatches into the stdlib: no project def
                if ret and not JAVA_JDK_TYPES[ret] then
                    local clang = elang_for(c.file)
                    local fit, dup
                    for _, node in ipairs(exact[ret .. '::' .. c.callee] or {}) do
                        if elang_for(node.file) == clang then
                            if fit then dup = true else fit = node end
                        end
                    end
                    if fit and not dup then
                        c.to = fit.id
                        c.inferred = true -- type INFERRED through a summary
                        c.refused = nil
                        -- c.rt STAYS: a worker settles chains slice-locally,
                        -- the parallel audit nulls every inferred resolution,
                        -- and relink must re-derive from the provenance
                        -- (idempotent — the `not c.to` guard skips settled
                        -- calls; name-ambiguous chains have no tail rescue)
                        if c.fn then addref(c.fn, fit.id, c.at, true) end
                        n = n + 1
                        progress = true
                        settled = true
                    end
                end
            end
            if not settled then
                kn = kn + 1
                keep[kn] = c
            end
        end
        deferred, dn = keep, kn
    until not progress or dn == 0
    return n, rounds
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
        for _, c in inext, node, -1 do
            if c:named() and c:type() == 'list' then out[#out + 1] = c end
        end
        return out
    end
    local function scan(n)
        for _, c in inext, n, -1 do
            if c:named() and c:type() ~= 'comment' then
                local t = c:type()
                if SUBSTMT_BLOCKS[t] then
                    for _, g in inext, c, -1 do
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

-- trace-time scope service: a tiny content-stamped cache of (parse tree +
-- scope model) for the few files a trace hops through — derived on demand,
-- never in the graph, evicted FIFO (trees die with their entry)
local BND_CACHE, BND_ORDER = {}, {}
local function binder_ctx(abs, file)
    local lang, spec = lang_for(file)
    if not (lang and spec and spec.scopes) then return nil end
    local st = vim.uv.fs_stat(abs)
    if not st then return nil end
    local stamp = st.mtime.sec .. ':' .. st.mtime.nsec .. ':' .. st.size
    local e = BND_CACHE[abs]
    if e and e.stamp == stamp then return e end
    local fd = io.open(abs, 'r')
    if not fd then return nil end
    local src = fd:read('a')
    fd:close()
    local okp, parser = pcall(vim.treesitter.get_string_parser, src, lang)
    if not okp then return nil end
    e = { stamp = stamp, parser = parser, root = parser:parse()[1]:root(),
        sm = require('cartograph.scope').model(src, spec.scopes) }
    BND_CACHE[abs] = e
    BND_ORDER[#BND_ORDER + 1] = abs
    if #BND_ORDER > 4 then BND_CACHE[table.remove(BND_ORDER, 1)] = nil end
    return e
end

--- The binder visible for `name` at 0-based `row` of `file` (abs = the
--- resolved path — store.abs keeps this multi-root-safe). The trace-time
--- shadow disambiguation service (scope-model phase 1): a returned binder
--- is a handle comparable BY IDENTITY across calls on the same file
--- content — same table ⇒ same binder. `row` resolves from the deepest
--- named node containing the line start, so the precision is the scope
--- chain of the enclosing statement. Returns nil when the language has no
--- scope spec, the file is unreadable/stale, or the name is free there —
--- callers fall back to name matching, exactly the old behavior.
function M.binder_at(abs, file, name, row)
    local e = binder_ctx(abs, file)
    if not e then return nil end
    local node = e.root:named_descendant_for_range(row, 0, row, 0)
    if not node then return nil end
    -- the entry node may BE a scope (a block containing the line): resolve
    -- includes it, with the query row as the visibility row
    local chain, k = e.sm.resolve(name, node, nil, row)
    -- chain is the model's reused array: take the binder handle out NOW
    return k > 0 and chain[1] or nil
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
            for _, c in inext, node, -1 do
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
            for _, c in inext, stmt, -1 do
                if c:named() and c:type() ~= 'comment'
                    and not SUBSTMT_BLOCKS[c:type()] then cond = c break end
            end
        end
        if cond then mk('cond', cond) end
        return items -- the body is the block lens's concern, not the detail's
    end
    local function walk(n)
        for _, c in inext, n, -1 do
            if c:named() and c:type() ~= 'comment' and not SUBSTMT_BLOCKS[c:type()] then
                if ARG_LISTS[c:type()] then
                    for _, a in inext, c, -1 do
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

-- ── mentions: collect (phase 1, tree live) + reduce (lookups ready) ──────
-- The id pass needs GLOBAL lookups (uniqueness is corpus-wide), so it used
-- to be a second read+parse of every file after the node set settled. Split
-- it instead: collect_mentions rides the phase-1 tree and packs every
-- identifier occurrence into a per-file varint string; reduce_mentions
-- replays the id-pass decisions over that buffer — pure table lookups, no
-- tree, no second parse. Lexical boundness (scope-model step 3) is the one
-- decision that needs the tree, so collect computes it EAGERLY with a scope
-- STACK folded on the fly during its single DFS: harvest a scope's symtab
-- on entry, pop on exit, answer per identifier from that name's active
-- binders — measured 3x cheaper than per-mention resolve() ancestor walks,
-- bound-for-bound identical on libs/self/server. Buffers stay small
-- (server: ~7 MB packed occurrences + ~4 MB interned names).

local MENTION_ID = { identifier = true }
local NO_NAMES = {}
-- pure-content pieces of a string literal, per grammar: anything ELSE
-- inside a string is interpolation (typed-strings v1: k='lit' means KNOWN)
local STR_PARTS = { string_content = true, string_value = true,
    string_fragment = true, string_start = true, string_end = true,
    escape_sequence = true, heredoc_start = true, heredoc_end = true }

-- LEB128, little-endian base-128
local function vput(parts, v)
    while v >= 0x80 do
        parts[#parts + 1] = string.char(v % 0x80 + 0x80)
        v = math.floor(v / 0x80)
    end
    parts[#parts + 1] = string.char(v)
end
local function vget(s, i)
    local v, m = 0, 1
    local b = s:byte(i)
    while b >= 0x80 do
        v = v + (b - 0x80) * m
        m = m * 0x80
        i = i + 1
        b = s:byte(i)
    end
    return v + b * m, i + 1
end

local MF_ELIGIBLE = 1 -- >=3 chars, non-stdlib: fn-ref / name-index candidate
local MF_CALLEE = 2   -- call position (the call pass already owns it)
local MF_BOUND = 4    -- lexically bound at the use site (scope stack)
local MF_SCOPED = 8   -- collected under a spec WITH a scope model
local MF_RANGE = 16   -- token isn't single-line name-width: explicit end follows

-- the buffer must SHIP (worker chunk, binary codec): no spec table (it
-- holds functions), just the two spec facts the reduce needs
local function mention_buf(spec)
    return { names = {}, nidx = {}, ok = {}, parts = {}, n = 0,
        fnrefs = spec.id_fn_refs ~= false,
        noindex = spec.name_index == false }
end

--- One DFS over a phase-1 tree: pack identifier occurrences (with
--- eligible/callee/bound flags) into buf — and, when extract registered
--- function bodies in `dfreg`, compute df-lite IN THE SAME WALK (the
--- second rider). df-lite: each body's top-level statements with def/use
--- NAME lists and def->use dependencies — approximate (no scoping) but
--- structurally the lua-ls df contract, so the fn altitude and extract
--- engine work. Nested fn bodies feed EVERY enclosing context (a stack),
--- exactly as the old per-fn walks did. Binder tags (scope-model phase 2)
--- come straight off the LIVE scope stack at the def site — the same
--- answer jvt_sm.resolve gave post-walk, without retaining nodes.
--- Shared by the fused extract and the standalone id_pass (refresh path,
--- which passes no dfreg — extract already computed df for those files).
local function collect_mentions(buf, tsroot, src, spec, dfreg)
    local scopes = spec.scopes
    local idt = spec.mention_types or MENTION_ID
    local dfid = spec.df_ids
    local stdlib = spec.stdlib_names or NO_NAMES
    local names, nidx, nok, parts = buf.names, buf.nidx, buf.ok, buf.parts
    local scoped = scopes and MF_SCOPED or 0
    local active = {} -- name -> stack of visibility rows (false = scope-wide)
    local ctxs, nctx = {}, 0 -- open df contexts, innermost last

    -- the binder tag, from the live stack: nearest VISIBLE binder's
    -- 0-based decl row; -1 = row-less binder (param/field), -2 = free
    local function tag_of(name, row)
        local a = active[name]
        if a then
            for j = #a, 1, -1 do
                local r = a[j]
                if r == false then return -1 end
                if r <= row then return r end
            end
        end
        return -2
    end

    local function walk(n, defpos, dfon)
        local nt = n:type()
        local pushed
        local entry = scopes and scopes[nt]
        if entry then
            local t = {}
            entry.harvest(n, src, t)
            pushed = {}
            for name, b in pairs(t) do
                local a = active[name]
                if not a then a = {} active[name] = a end
                a[#a + 1] = b.row or false
                pushed[#pushed + 1] = name
            end
        end
        local bodyctx = dfreg and dfreg[n:id()]
        if bodyctx then
            nctx = nctx + 1
            ctxs[nctx] = bodyctx
            bodyctx.stmts = {}
            bodyctx.defsites = scopes and {} or nil
        end
        local iscall = nt == 'call_expression' or nt == 'function_call'
            or nt == 'call' or nt == 'apply'
        local head = nt == 'list' -- sexp head IS the callee (no fields)
        -- df def positions are THIS node's gift to its children:
        -- assignment lefts, declarators, transparent wrappers
        local asgleft, decld, dfk
        if nctx > 0 then
            if nt == 'assignment_statement' or nt == 'assignment'
                or nt == 'assignment_expression'
                or nt == 'augmented_assignment_expression'
                or nt == 'variable_assignment' then -- bash x=… (name field)
                asgleft = n:field('left')[1] or n:field('name')[1]
                    or n:child(0)
                dfk = 1
            elseif nt == 'declaration_command' then -- bash local/declare
                dfk = 2
            elseif nt == 'init_declarator' or nt == 'variable_declarator' then
                decld = n:field('declarator')[1] or n:field('name')[1]
                dfk = 3
            else
                -- def position survives transparent wrappers only
                dfk = defpos and (nt == 'variable_list'
                    or nt == 'variable_name')
            end
        end
        local i, c = 0, n:child(0)
        while c do
            local ct = c:type()
            -- LAZY per-child facts: named() is an FFI call and most java
            -- children are anonymous tokens — pay it only on paths that
            -- consume it (the regression the first fused draft measured)
            local cnamed, cdfon, name
            local cdefpos, cdfid
            if nctx > 0 then
                cnamed = c:named()
                if bodyctx and cnamed and ct ~= 'comment' then
                    -- a body's direct named children ARE its statements
                    bodyctx.cur = { l = c:range() + 1,
                        def = {}, use = {}, dep = {} }
                    bodyctx.sd, bodyctx.su = {}, {}
                    bodyctx.stmts[#bodyctx.stmts + 1] = bodyctx.cur
                end
                if dfon and cnamed then
                    if dfk == 1 then cdefpos = c == asgleft
                    elseif dfk == 2 then cdefpos = ct == 'variable_name'
                    elseif dfk == 3 then cdefpos = c == decld
                    else cdefpos = dfk end
                    if ct == 'identifier' or ct == 'name'
                        or (dfid and dfid[ct]) then cdfid = true end
                end
                cdfon = dfon and cnamed and not cdfid
            else
                cdfon = true -- df restarts fresh at the next body anyway
            end
            if cdfid then
                name = node_text(c, src)
                for k = 1, nctx do
                    local x = ctxs[k]
                    local st = x.cur
                    if st then
                        if cdefpos then
                            if not x.sd[name] then
                                x.sd[name] = true
                                st.def[#st.def + 1] = name
                                if x.defsites then
                                    local ds = x.defsites[name]
                                    if not ds then ds = {} x.defsites[name] = ds end
                                    ds[#ds + 1] = { si = #x.stmts, di = #st.def,
                                        tag = tag_of(name, (c:range())) }
                                end
                            end
                        elseif not x.su[name] and not x.sd[name] then
                            x.su[name] = true
                            st.use[#st.use + 1] = name
                        end
                    end
                end
            end
            if idt[ct] and (cnamed or cnamed == nil and c:named()) then
                if name == nil then name = node_text(c, src) end
                local sr, sc, er, ec = c:range()
                local callee = iscall
                    and (n:field('function')[1] == c or n:field('name')[1] == c)
                    or head -- the mention guard already proved c named
                local idx = nidx[name]
                if not idx then
                    idx = buf.n + 1
                    buf.n = idx
                    nidx[name] = idx
                    names[idx] = name
                    nok[idx] = (#name >= 3 and not stdlib[name]) or nil
                end
                local bound
                local a = active[name]
                if a then
                    for j = #a, 1, -1 do
                        local r = a[j]
                        if r == false or r <= sr then bound = true break end
                    end
                end
                local flags = scoped + (nok[idx] and MF_ELIGIBLE or 0)
                    + (callee and MF_CALLEE or 0) + (bound and MF_BOUND or 0)
                local simple = er == sr and ec == sc + #name
                if not simple then flags = flags + MF_RANGE end
                vput(parts, idx)
                vput(parts, sr)
                vput(parts, sc)
                parts[#parts + 1] = string.char(flags)
                if not simple then
                    vput(parts, er)
                    vput(parts, ec)
                end
            end
            if head and (cnamed or cnamed == nil and c:named()) then
                head = false
            end
            if c:child(0) then walk(c, cdefpos, cdfon) end
            i = i + 1
            c = n:child(i)
        end
        if bodyctx then
            nctx = nctx - 1
            bodyctx.cur, bodyctx.sd, bodyctx.su = nil, nil, nil
            local stmts = bodyctx.stmts
            if #stmts > 0 then
                -- binder tags: only names that CAN be shadow-ambiguous —
                -- several def sites, or a def shadowing a param. s.defr is
                -- sparse, aligned with s.def indices; untagged names keep
                -- name semantics.
                if bodyctx.defsites then
                    local isparam = {}
                    for _, p in ipairs(bodyctx.params or {}) do
                        isparam[p] = true
                    end
                    for name, ds in pairs(bodyctx.defsites) do
                        if #ds > 1 or isparam[name] then
                            for _, site in ipairs(ds) do
                                local st = stmts[site.si]
                                st.defr = st.defr or {}
                                st.defr[site.di] = site.tag
                            end
                        end
                    end
                end
                -- dependencies + free inputs
                local defined, inputs, inset = {}, {}, {}
                for _, p in ipairs(bodyctx.params or {}) do defined[p] = 0 end
                for si, st in ipairs(stmts) do
                    for _, u in ipairs(st.use) do
                        local from = defined[u]
                        if from and from > 0 then
                            st.dep[#st.dep + 1] = { from = from, var = u }
                        elseif from == nil and not inset[u] then
                            inset[u] = true
                            inputs[#inputs + 1] = u
                        end
                    end
                    for _, d in ipairs(st.def) do
                        defined[d] = defined[d] or si
                    end
                end
                bodyctx.node.df = { inputs = inputs, stmts = stmts }
            end
            bodyctx.stmts, bodyctx.defsites = nil, nil
        end
        if pushed then
            for k = #pushed, 1, -1 do
                local a = active[pushed[k]]
                a[#a] = nil
            end
        end
    end
    walk(tsroot, false, true)
end

--- Replay the id-pass decisions over a collected buffer: pure lookups
--- against L (the same callback contract id_pass always took).
local function reduce_mentions(file, buf, L)
    local ranges = L.fn_ranges[file]
    if not ranges then return end
    local fnrefs = buf.fnrefs
    local names = buf.names
    local function fn_at(line)
        local best
        for _, r in ipairs(ranges) do
            if r.s <= line and line <= r.e
                and (not best or r.s >= best.s) then best = r end
        end
        return best and best.id
    end
    local useEdge, regEdge = {}, {}
    local m = buf.m
    local i, len = 1, #m
    while i <= len do
        local idx, sr, sc, flags
        idx, i = vget(m, i)
        sr, i = vget(m, i)
        sc, i = vget(m, i)
        flags = m:byte(i)
        i = i + 1
        local name = names[idx]
        local er, ec = sr, sc + #name
        if flags >= MF_RANGE then
            flags = flags - MF_RANGE
            er, i = vget(m, i)
            ec, i = vget(m, i)
        end
        local scoped = flags >= MF_SCOPED
        local bound = flags % MF_SCOPED >= MF_BOUND
        local callee = flags % MF_BOUND >= MF_CALLEE
        local eligible = flags % MF_CALLEE >= MF_ELIGIBLE
        if eligible and not callee and fnrefs then
            local u = L.fn_unique[name]
            if u and L.scopes and L.scopes[u.file] ~= L.scopes[file] then
                u = nil -- unique, but across a boundary
            end
            -- lexical-first (scope-model step 3): a BOUND name never
            -- crosses the file boundary
            if u and scoped and u.file ~= file and bound then u = nil end
            if u and not (u.file == file and sr == u.line) then
                local from = fn_at(sr)
                local at = { start = { line = sr, char = sc },
                    ['end'] = { line = er, char = ec } }
                if from then
                    L.addref(from, u.id, at, true)
                else
                    -- referenced from top-level DATA (a dispatch table /
                    -- registry): the fn is kept alive, and the reference is
                    -- a REGISTRATION edge from this module — an alibi you
                    -- can descend into
                    L.mark_cbarg(u)
                    local rk = file .. '\31' .. u.id
                    local e = regEdge[rk]
                    if not e then
                        e = { from = file, to = u.id, kind = 'reg', at = {} }
                        regEdge[rk] = e
                        L.adduse(e)
                    end
                    e.at[#e.at + 1] = at
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
                -- the cross-file unique fallback only for FREE names:
                -- bound never crosses the file boundary
                if not (scoped and bound) then var = cands[1] end
            end
            if var and not (var.file == file and sr == var.line) then
                local from = fn_at(sr)
                if from then
                    local k = from .. '\31' .. var.id
                    local e = useEdge[k]
                    if not e then
                        e = { from = from, to = var.id, kind = 'use', at = {} }
                        useEdge[k] = e
                        L.adduse(e)
                    end
                    e.at[#e.at + 1] = { start = { line = sr, char = sc },
                        ['end'] = { line = er, char = ec } }
                end
            end
        end
    end
    -- the per-file identifier NAME SET (the mention index): what lets a
    -- later splice answer "which files mention this global?" without a
    -- corpus scan
    if L.add_names and not buf.noindex and buf.n > 0 then
        local ns = {}
        for j = 1, buf.n do
            if buf.ok[j] then ns[#ns + 1] = names[j] end
        end
        if #ns > 0 then
            table.sort(ns) -- deterministic pack (worker == inline)
            L.add_names(file, '\31' .. table.concat(ns, '\31') .. '\31')
        end
    end
end

-- The id pass: identifier occurrences naming a known top-level var (same
-- file, or unique across the workspace) or — outside call position — a
-- unique function (dispatch tables, registry values). A top-level
-- function reference marks the target dynamically dispatched (cbarg): a
-- dispatch-table entry is not dead code. Takes SUPPLIED lookups because
-- every decision is corpus-global: slice-local uniqueness is not global
-- uniqueness. This standalone form (read + parse + collect + reduce) is
-- the REFRESH path; the fused extract collects during phase 1 and only
-- reduces here-style at the end — no second parse.
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
        if L.fn_ranges[file] then
            local lang, spec = lang_for(file)
            local clang = container_for(file)
            if clang then lang, spec = 'javascript', M.spec.javascript end
            local fd = io.open(abs(file), 'r')
            local src = fd and fd:read('a')
            if fd then fd:close() end
            local okp, parser = pcall(vim.treesitter.get_string_parser,
                src or '', clang or lang)
            if src and okp then
                local troots = container_trees(parser, clang)
                    or { { root = parser:parse()[1]:root(), spec = spec,
                        lang = lang } }
                local buf = mention_buf(spec)
                for _, tr in ipairs(troots) do
                    collect_mentions(buf, tr.root, src, tr.spec)
                end
                buf.m = table.concat(buf.parts)
                reduce_mentions(file, buf, L)
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
local function idpass_sink(lookups)
    local out = { edges = {}, cbarg = {}, names = {} }
    local refEdge, seen_cb = {}, {}
    local L = {
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
    }
    return L, out
end

function M.id_pass(root, files, lookups, abs)
    local L, out = idpass_sink(lookups)
    id_pass(root, files, L, abs)
    return out
end

--- Parallel phase 2 without processes: reduce SHIPPED mention buffers
--- (collected by phase-1 workers) against parent-built global lookups.
--- Same output contract as M.id_pass.
function M.mention_reduce(files, mentions, lookups)
    local L, out = idpass_sink(lookups)
    for _, file in ipairs(files) do
        local buf = mentions[file]
        if buf then reduce_mentions(file, buf, L) end
    end
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
    local mentions = {}        -- file -> packed mention buffer (Stage B)
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
    local function extract_defs(file, lang, spec, src, tsroot, dfreg)
        tree_model(tsroot, src, spec) -- df binder tags read the shared model
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
                for _, c in inext, n, -1 do
                    local r = rec(c)
                    if r and (not best or r < best) then best = r end
                end
                return best
            end
            errow = rec(tsroot)
        end
        -- torn policy. Default: everything beyond the FIRST error row —
        -- calibrated on truncated class contexts (magento php5), where a
        -- def after the error has lost its enclosing qualifier. Languages
        -- whose defs carry no enclosing context opt into NODE-LOCAL
        -- tearing (spec.torn_by_node): torn only when the error sits
        -- inside the def's own subtree. bash needs this — one exotic
        -- parameter expansion at line 580 must not tear the remaining 98%
        -- of a 26k-line script (testssl.sh, ble.sh contribs measured).
        local function torn_of(dn, sp)
            if spec.torn_by_node then
                return errow ~= nil and dn:has_error() or nil
            end
            return errow and sp.start.line >= errow or nil
        end
        -- functions / vars / interface / super: ONE cursor (fusion
        -- Stage A). Every query cursor walks the WHOLE tree in C, and
        -- this ran four of them per file; the sections' captures are
        -- disjoint (@name = function, @vname = var, @child/@parent =
        -- super, a category capture = interface), so each match of the
        -- CONCATENATED query self-identifies and dispatches inline.
        -- Section-relative match order is a subsequence of tree order —
        -- all the order the sections ever relied on (merge_equations,
        -- seen_var). Underscore captures (@_kw) are predicate helpers
        -- and never dispatch.
        -- start line of every fn/method def, for block flushing. Keyed by
        -- LINE, not node: TSNode identity does not survive across
        -- traversals (== is a metamethod, table keys are raw).
        local fnDefLines = {}
        -- a multi-assignment (`a, b = 1, 2`) cross-products name×value in
        -- the query, so dedup by the (name,line) id it produces
        local seen_var = {}
        local function handle_fn(defn, namen)
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
                local torn = torn_of(defn, sp)
                nodes[#nodes + 1] = { id = id, name = name,
                    kind = method and 'method' or 'function', file = file,
                    range = sp, order = sp.start.line, params = params,
                    cbarg = isfield or nil,
                    exported = exp,
                    torn = torn,
                    entry = (spec.entry_names or {})[name] or nil,
                    -- declared return type (base name): the per-function
                    -- SUMMARY the return-type rounds ride (graph-VM MVP)
                    ret = spec.def_ret and spec.def_ret(defn, src) or nil,
                    df = spec.dataflow
                        and spec.dataflow(defn, spec, src, params) or nil }
                lastFn[file] = nodes[#nodes]
                -- generic df rides the mention DFS: register this body
                -- (per-tree keying — node ids are stable within a tree)
                if not spec.dataflow and spec.body_field then
                    local b = defn:field(spec.body_field)[1]
                    if b then
                        dfreg[b:id()] = { params = params, node = nodes[#nodes] }
                    end
                end
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
        local function handle_var(defn, namen, valn)
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
                    local torn = torn_of(defn, sp)
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
        -- header/interface elements (C/C++): prototypes, macros and types.
        -- A prototype is a DECLARATION (never indexed, marked decl); a
        -- function-like macro IS a call target and indexes. namen here is
        -- the CATEGORY capture node; cat its capture name.
        local function handle_iface(defn, namen, cat)
            if defn and namen then
                local name = node_text(namen, src):gsub('%s+', '')
                local sp = pos_of(defn)
                local torn = torn_of(defn, sp)
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
        local function handle_super(childn, parentn)
            local child = node_text(childn, src)
            local t = node_text(parentn, src)
            local parent = t:match('[^\\]+$') or t
            data.extends = data.extends or {}
            data.extends[#data.extends + 1] =
                { child = child, parent = parent, file = file }
        end
        local combined = spec._defs_query
        if combined == nil then
            combined = table.concat({ spec.functions or '', spec.vars or '',
                spec.interface or '', spec.super_query or '' }, '\n')
            spec._defs_query = combined
        end
        local q = parse_query(lang, combined)
        if q then
            for _, match in q:iter_matches(tsroot, src, 0, -1) do
                local defn, namen, vdefn, vnamen, valn
                local childn, parentn, catn, cat
                for id, ns in pairs(match) do
                    local capn = q.captures[id]
                    local n = cap_node(ns)
                    if capn == 'def' then defn = n
                    elseif capn == 'name' then namen = n
                    elseif capn == 'vdef' then vdefn = n
                    elseif capn == 'vname' then vnamen = n
                    elseif capn == 'value' then valn = n
                    elseif capn == 'child' then childn = n
                    elseif capn == 'parent' then parentn = n
                    elseif capn:sub(1, 1) ~= '_' then catn, cat = n, capn end
                end
                if childn and parentn then
                    handle_super(childn, parentn)
                elseif vdefn and vnamen then
                    handle_var(vdefn, vnamen, valn)
                elseif defn and catn then
                    handle_iface(defn, catn, cat)
                elseif defn and namen then
                    handle_fn(defn, namen)
                end
            end
        end

        -- regions: runs of top-level statements that aren't function defs
        do
            local lines = vim.split(src, '\n', { plain = true })
            local container = tsroot
            if spec.block_container then
                for _, c in inext, tsroot, -1 do
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
            for _, stmt in inext, container, -1 do
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


    end

    -- calls: inventory + reference sites (resolved after all files).
    -- Containers also run this over TEMPLATE EXPRESSION trees — an
    -- @click="save(item)" is a real call_expression at absolute rows
    local function extract_calls(file, lang, spec, src, tsroot)
        tree_model(tsroot, src, spec) -- shared with extract_defs (same tree)
        local ifmemo = {} -- per TREE by construction (dies with this call)
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
                    local qhedge, qdefer
                    if spec.qualify_call then
                        local q, h, d = spec.qualify_call(calln, full, src)
                        full, qhedge, qdefer = q or full, h, d
                    end
                    -- the inventory names the VERB (lint configs match on it);
                    -- the full expression text drives resolution. A dynamic
                    -- callee keeps its sigil: `→ $op` says what it is
                    local dynamic = spec.dynamic_callee_types
                        and spec.dynamic_callee_types[namen:type()] or nil
                    local callee = dynamic and full
                        or full:match('([%w_]+)$') or full
                    local sp = pos_of(calln)
                    local encl = in_function(calln, spec, ifmemo)
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
                    local argnodes
                    if not argsn then
                        -- bash: arguments are repeated `argument:` fields
                        -- on the command itself, no container node
                        local fa = calln:field('argument')
                        if fa and #fa > 0 then argnodes = fa end
                    end
                    for _, a in (argsn and argsn.child and inext)
                        or (argnodes and ipairs(argnodes)) or NOOP,
                        argnodes or argsn, argnodes and 0 or -1 do
                        if a:named() and a:type() ~= 'comment' then
                            if a:type() == 'argument' then -- php wraps each arg
                                a = a:named_child(0) or a
                            end
                            local t = a:type()
                            if t == 'string' or t == 'string_literal'
                                or t == 'encapsed_string' then -- php "..."
                                -- interpolated string (typed-strings v1):
                                -- k='lit' must mean KNOWN — "$var" IS the
                                -- variable, "lead $x…" only proves a PREFIX
                                local exp
                                for _, sc2 in inext, a, -1 do
                                    if sc2:named() and not STR_PARTS[sc2:type()] then
                                        exp = sc2
                                        break
                                    end
                                end
                                if exp then
                                    local txt = node_text(a, src)
                                    local asr, asc = a:range()
                                    local esr, esc = exp:range()
                                    local head = esr == asr
                                        and txt:sub(2, esc - asc) or nil
                                    local lone = txt:gsub('^["\']', '')
                                        :gsub('["\']$', '')
                                        :match('^%${?([%w_]+)}?$')
                                    args[#args + 1] = ''
                                    if head and head ~= '' then
                                        argv[#argv + 1] = { k = 'concat',
                                            prefix = head }
                                    elseif lone then
                                        argv[#argv + 1] = { k = 'local',
                                            name = lone,
                                            l = select(1, a:range()) }
                                    else
                                        argv[#argv + 1] = { k = 'expr' }
                                    end
                                else
                                    local v = node_text(a, src)
                                        :gsub('^["\']', ''):gsub('["\']$', '')
                                    args[#args + 1] = v
                                    argv[#argv + 1] = { k = 'lit', v = v }
                                end
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
                        hedge = qhedge, -- hedged qualification: edge gets ~
                        rt = qdefer, -- receiver typed by ANOTHER call's
                        -- return: the return-type rounds settle it
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
        local regdfs = {}
        for ri, r in ipairs(regions) do
            local script = false
            for _, x in ipairs(scripts) do
                if r.s >= x.s and r.s <= x.e then script = true break end
            end
            -- per-REGION df registry: regions are separate trees, and
            -- node ids alias across trees
            regdfs[ri] = {}
            if script then
                extract_defs(file, r.lang, r.spec, src, r.root, regdfs[ri])
            end
            extract_calls(file, r.lang, r.spec, src, r.root)
        end
        if fnRanges[file] then
            local buf = mention_buf(M.spec.javascript)
            for ri, r in ipairs(regions) do
                collect_mentions(buf, r.root, src, r.spec, regdfs[ri])
            end
            buf.m = table.concat(buf.parts)
            buf.parts, buf.nidx = nil, nil
            mentions[file] = buf
        end
        -- the template as ONE visible block row (a jump target): its
        -- extent is the top-level markup that isn't script/style
        local tps, tpe
        for _, c in inext, croot, -1 do
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
            local tsroot
            local rawtree = raw_parse(lang, src) -- keep referenced: nodes
            -- below live only as long as their tree does
            if rawtree then
                tsroot = rawtree:root()
            else
                local okp, parser = pcall(vim.treesitter.get_string_parser, src, lang)
                if not okp then
                    no_parser[lang] = true
                    goto next_file
                end
                tsroot = parser:parse()[1]:root()
            end
            stamp(file)
            nodes[#nodes + 1] = { id = file, name = file, kind = 'module', file = file,
                range = pos_of(tsroot), order = -1,
                effects = spec.module_effects
                    and spec.module_effects(tsroot, src) or nil }
            if spec.aperture_query then
                local aq = parse_query(lang, spec.aperture_query)
                if aq then
                    local aps
                    for cid, an in aq:iter_captures(tsroot, src, 0, -1) do
                        local cap = aq.captures[cid]
                        if cap:sub(1, 1) ~= '_' then
                            aps = aps or {}
                            aps[#aps + 1] = { rule = cap, line = (an:range()) }
                        end
                    end
                    nodes[#nodes].apertures = aps
                end
            end
            local dfreg = {}
            extract_defs(file, lang, spec, src, tsroot, dfreg)
            extract_calls(file, lang, spec, src, tsroot)
            -- fusion Stage B: mentions ride the SAME tree — the id pass
            -- never parses again (files without functions stay out, the
            -- same gate the id pass always had). df rides the same walk
            -- via dfreg (registered by extract_defs above).
            if fnRanges[file] then
                local buf = mention_buf(spec)
                collect_mentions(buf, tsroot, src, spec, dfreg)
                buf.m = table.concat(buf.parts)
                buf.parts, buf.nidx = nil, nil
                mentions[file] = buf
            end
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
    -- aperture witnesses + corpus fn NAMESPACES (literal-name languages):
    -- an unresolved call whose first /-or-# segment matches a known fn
    -- namespace is corpus-internal (ble/bash/read), not an external
    -- command — with conjuring sites in the corpus, the honest answer is
    -- refusal-with-witness, not silence. Witness pick is deterministic
    -- (same file first, else lexicographically smallest file's first site)
    local apertures, ns_pfx, global_witness = {}, {}, nil
    for _, n in ipairs(nodes) do
        if n.kind == 'module' and n.apertures then
            apertures[n.file] = n.apertures
            if not global_witness or n.file < global_witness.file then
                global_witness = { file = n.file, line = n.apertures[1].line }
            end
        elseif n.kind == 'function' or n.kind == 'method' then
            local pfx = n.name:match('^([^/#]+)[/#]')
            if pfx then
                local _, dsp = elang_for(n.file)
                if dsp and dsp.literal_names then ns_pfx[pfx] = true end
            end
        end
    end
    local function aperture_refusal(name, file)
        local pfx = name:match('^([^/#]+)[/#]')
        if not (pfx and ns_pfx[pfx]) then return nil end
        local w = apertures[file]
            and { file = file, line = apertures[file][1].line }
            or global_witness
        if not w then return nil end -- nothing conjures: stay silent
        return { rule = 'aperture', witness = w.file .. ':' .. (w.line + 1) }
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
        -- on a fully-qualified name (Engine::new) clears first. Literal-
        -- name languages (bash) have no qualification syntax at all — a
        -- slashed fn like ble/bash/read must not vocab-die on tail `read`
        if not cands and not (spec and spec.literal_names)
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
        -- literal-name languages never tail-match: a bash command names
        -- its function EXACTLY (slashes are just characters), so `split`
        -- must not fuzzy-hit thousands of ble/string#split-style defs —
        -- an unknown name is an external command, not a near-miss...
        -- UNLESS it wears a known fn namespace and the corpus contains
        -- conjuring sites: then refusal-with-witness (the aperture)
        if spec and spec.literal_names then
            local ar = aperture_refusal(name, file)
            if ar then return nil, nil, ar end
            return nil
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
    -- typed-strings: STRING recovery for a sink arg — the prize is the
    -- VALUE: the def line's quoted string, full when the quote closes
    -- into plain punctuation, otherwise an honest PREFIX (multiline SQL,
    -- '…' . $x concatenation). One def in the fn = CONFIDENT. Several
    -- defs = the NEAREST ABOVE the use, HEDGED: right for sequential
    -- reuse (mantis redefines $t_query per query), but a branch may have
    -- chosen — the tier says so (the literal-flow analyzer, mantis cut).
    local function flow_string(file, line0, varname)
        local fnid = fn_at(file, line0)
        if not (varname and fnid) then return nil end
        local df = node_index[fnid] and node_index[fnid].df
        if not df then return nil end
        local ndefs = 0
        for _, st in ipairs(df.stmts) do
            for _, d in ipairs(st.def) do
                if d == varname then ndefs = ndefs + 1 end
            end
        end
        if ndefs == 0 then return nil end
        local hedged = ndefs > 1 or nil
        local fnrow = 0
        for _, r in ipairs(fnRanges[file] or {}) do
            if r.id == fnid then fnrow = r.s break end
        end
        if src_cache[file] == nil then
            local fd = io.open(abs(file), 'r')
            src_cache[file] = fd
                and vim.split(fd:read('a'), '\n', { plain = true }) or false
            if fd then fd:close() end
        end
        -- the assignment may sit NESTED inside its statement (an
        -- if-guard) and `.=` appends may follow it — appends PRESERVE the
        -- base as a prefix, so scan the source upward from the use over
        -- the whole fn for the nearest PLAIN assignment (`.=` never
        -- matches); df already hedged multi-def flows
        local line, qch, pos
        for l = line0, fnrow + 1, -1 do
            local cand = src_cache[file] and src_cache[file][l] or ''
            qch, pos = cand:match('%$?' .. varname .. [=[%s*=%s*(['"])()]=])
            if qch then
                line = cand
                break
            end
            -- php heredoc (<<<SQL … SQL;): the following lines ARE the
            -- literal, until the terminator (or the use = still a prefix)
            local hd = cand:match('%$?' .. varname .. '%s*=%s*<<<%s*[\'"]?(%u+)')
            if hd then
                local parts = {}
                for hl = l + 1, line0 do
                    local t2 = src_cache[file][hl] or ''
                    if t2:match('^%s*' .. hd .. '%s*;?%s*$') then
                        return table.concat(parts, ' '), nil, hedged
                    end
                    parts[#parts + 1] = t2
                end
                return table.concat(parts, ' '), true, hedged
            end
        end
        if not qch then return nil end
        local rest = line:sub(pos)
        local close = rest:find(qch, 1, true)
        if not close then return rest, true, hedged end -- off the line: prefix
        local v = rest:sub(1, close - 1)
        local after = rest:sub(close + 1):match('^%s*(%p?)')
        if after == '' or after == ';' or after == ',' or after == ')' then
            return v, nil, hedged
        end
        return v, true, hedged -- concatenation continues: a prefix
    end

    -- cbarg marks are RESOLUTION INPUT (same-file priority skips dispatched
    -- defs), so they must be COMPLETE BEFORE the pass, not minted during it:
    -- a mid-pass mint made the tier depend on call order, and a cross-pass
    -- one (worker pass vs relink pass) made inline and parallel disagree —
    -- both found by the --parallel parity gate. The pre-scan marks
    -- module-level identifier args naming a globally-unique fn (the
    -- name-only core of the upgrade's criterion; the upgrade itself still
    -- runs in the pass, it just no longer marks).
    for _, p in ipairs(pending) do
        if not fn_at(p.file, p.at.start.line) then
            for _, a in ipairs(p.call.argv) do
                if a.k == 'local' and a.name then
                    local cands = exact[a.name]
                    if cands and #cands == 1 and (cands[1].kind == 'function'
                        or cands[1].kind == 'method') then
                        cands[1].cbarg = true
                    end
                end
            end
        end
    end
    for _, p in ipairs(pending) do
        -- typed-string SINKS (typed-strings v1): recover the sink arg —
        -- literal, literal-headed concat (PREFIX), or single-assignment
        -- local (flow). ty='sql' rides the call for the sql miner;
        -- ty='code' (eval) exposes the head token as the REAL callee via
        -- the traced machinery (relink re-derives after a parallel audit,
        -- exactly like $fn literal flow).
        do
            local _, psp = elang_for(p.file)
            local sink = psp and psp.string_sinks
                and psp.string_sinks[p.full or p.call.callee]
            local a = sink and p.call.argv[sink.arg]
            if a then
                local v, pre, hedged
                if a.k == 'lit' then v = a.v
                elseif a.k == 'concat' then v, pre = a.prefix, true
                elseif a.k == 'local' and a.name then
                    v, pre, hedged =
                        flow_string(p.file, p.at.start.line, a.name)
                end
                if v and v ~= '' then
                    p.call.strarg = { ty = sink.ty, v = v, pre = pre or nil,
                        hedge = hedged or nil }
                    -- a hedged head must not mint a confident dispatch
                    if sink.ty == 'code' and not hedged
                        and not p.call.traced then
                        -- head only when its boundary is PROVEN: trailing
                        -- whitespace, or the whole string was read
                        local head = pre
                            and v:match('^%s*([^%s$\'"`;|&<>]+)%s')
                            or v:match('^%s*([^%s$\'"`;|&<>]+)%s*$')
                            or v:match('^%s*([^%s$\'"`;|&<>]+)%s')
                        if head and #head >= 3 then p.call.traced = head end
                    end
                end
            end
        end
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
        if not target and not p.call.dynamic
            and type(p.call.traced) == 'string' then
            -- code sink: the eval'd HEAD is the dispatch (literal, so not ~)
            local t2 = resolve(p.call.traced, p.file)
            if t2 then target, inferred, refused = t2, false, nil end
        end
        if target then
            p.call.to = target.id
            -- a hedged qualification caps the edge at ~ even where the
            -- name-match itself is confident (same-file): the RECEIVER TYPE
            -- was a shadow-walkout guess, and the edge must say so
            local hedged = inferred or p.call.hedge ~= nil
            p.call.inferred = hedged or nil
            local from = fn_at(p.file, p.at.start.line)
            p.call.fn = from
            if from then addref(from, target.id, p.at, hedged) end
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
                        -- module is the registrant (a descendable alibi).
                        -- The cbarg MARK happened in the pre-scan; minting
                        -- it here made resolution order-dependent
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

    -- return-type rounds: settle the receiver-deferred calls (c.rt) now
    -- that plain + super resolution populated the determining calls
    local retn, retrounds = resolve_returns(calls, node_index, exact, addref)
    if retn > 0 then data.ret_resolved, data.ret_rounds = retn, retrounds end

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
        local L = {
            fn_unique = fn_unique,
            var_named = var_named,
            fn_ranges = fnRanges,
            scopes = seq_any and seq_scopes or nil,
            addref = addref,
            adduse = function (e) edges[#edges + 1] = e end,
            mark_cbarg = function (u) u.node.cbarg = true end,
            add_names = function (f, s) data.names[f] = s end,
        }
        for _, file in ipairs(files) do
            local buf = mentions[file]
            if buf then reduce_mentions(file, buf, L) end
        end
    else
        -- the parallel driver needs each slice's function extents AND
        -- mention buffers to run the reduce later (all decisions global)
        data.fn_ranges = fnRanges
        data.mentions = mentions
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
    local apertures, ns_pfx, global_witness = {}, {}, nil
    for _, n in ipairs(data.nodes) do
        if n.kind == 'module' and n.apertures then
            apertures[n.file] = n.apertures
            if not global_witness or n.file < global_witness.file then
                global_witness = { file = n.file, line = n.apertures[1].line }
            end
        elseif n.kind == 'function' or n.kind == 'method' then
            local pfx = n.name:match('^([^/#]+)[/#]')
            if pfx then
                local _, dsp = elang_for(n.file)
                if dsp and dsp.literal_names then ns_pfx[pfx] = true end
            end
        end
    end
    local function aperture_refusal(name, file)
        local pfx = name:match('^([^/#]+)[/#]')
        if not (pfx and ns_pfx[pfx]) then return nil end
        local w = apertures[file]
            and { file = file, line = apertures[file][1].line }
            or global_witness
        if not w then return nil end
        return { rule = 'aperture', witness = w.file .. ':' .. (w.line + 1) }
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
        -- on a fully-qualified name (Engine::new) clears first. Literal-
        -- name languages (bash) have no qualification syntax at all — a
        -- slashed fn like ble/bash/read must not vocab-die on tail `read`
        if not cands and not (spec and spec.literal_names)
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
        -- literal-name languages never tail-match: a bash command names
        -- its function EXACTLY (slashes are just characters), so `split`
        -- must not fuzzy-hit thousands of ble/string#split-style defs —
        -- an unknown name is an external command, not a near-miss...
        -- UNLESS it wears a known fn namespace and the corpus contains
        -- conjuring sites: then refusal-with-witness (the aperture)
        if spec and spec.literal_names then
            local ar = aperture_refusal(name, file)
            if ar then return nil, nil, ar end
            return nil
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
    -- cbarg pre-scan, mirroring extract's: marks are resolution INPUT and
    -- must be complete before the pass (see extract; --parallel parity).
    -- An arg a WORKER already upgraded arrives as k='func' with a.up —
    -- it still testifies (skipping it hid the mark from relink while the
    -- inline pre-scan saw it: a tier flip the parity gate caught)
    for _, c in ipairs(data.calls or {}) do
        if not c.fn then
            for _, a in ipairs(c.argv or {}) do
                if (a.k == 'local' or (a.k == 'func' and a.up)) and a.name then
                    local cands = exact[a.name]
                    if cands and #cands == 1 and (cands[1].kind == 'function'
                        or cands[1].kind == 'method') then
                        cands[1].cbarg = true
                    end
                end
            end
        end
    end
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
                -- (including the hedged-qualification cap, see extract)
                local hedged = inferred or c.hedge ~= nil
                c.inferred = hedged or nil
                c.refused = nil
                if c.dynamic then c.dynamic = nil end -- pinned by the trace
                n = n + 1
                if touched then touched[c.file] = true end
                if c.fn then
                    addref(c.fn, target.id, c.at
                        or { start = { line = c.line, char = 0 },
                            ['end'] = { line = c.line, char = 0 } }, hedged)
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
                        -- the MARK happened in the pre-scan (see extract)
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
    -- and the return-type rounds, for the same parity (cross-chunk chains:
    -- a worker slice may hold the chain but not the determining target)
    local node_index = {}
    for _, nn in ipairs(data.nodes) do node_index[nn.id] = nn end
    local retn = resolve_returns(data.calls, node_index, exact, addref)
    return n + retn
end

return M
