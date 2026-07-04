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

-- ── per-language specs ───────────────────────────────────────────────────────
-- Each spec: file extensions, tree-sitter queries with a shared capture
-- protocol (@def/@name for functions and vars, @call/@name for calls), and
-- small hooks where grammars genuinely differ.

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
        litdata_types = { table_constructor = true },
        -- stdlib receivers must not tail-match a project def: string.format
        -- would otherwise link to the one module that defines M.format
        stdlib_prefixes = { 'string.', 'table.', 'math.', 'os.', 'io.',
            'coroutine.', 'debug.', 'bit.', 'jit.', 'ffi.', 'vim.' },
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
            (declaration declarator: (identifier) @name) @def
        ]],
        params_field = 'parameters',
        body_field = 'body',
        is_method = function () return false end,
        entry_names = { main = true },
        import_query = [[ (preproc_include path: (string_literal) @path) ]],
        resolve_import = function (path, files, from)
            path = path:gsub('^"', ''):gsub('"$', '')
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
        ]=],
        params_field = 'parameters',
        body_field = 'body',
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
            substr = true, append = true, record = true },
        import_query = [=[ (preproc_include path: (string_literal) @path) ]=],
        resolve_import = function (path, files, from)
            path = path:gsub('^"', ''):gsub('"$', '')
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
                    local t = vim.treesitter.get_node_text(n, src)
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
                            def = namen and { vim.treesitter.get_node_text(namen, src) } or {},
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
        -- a call runs at load unless its OUTERMOST form is a define
        is_top = function (calln, src)
            local n, outer = calln, calln
            while n:parent() do
                if n:parent():type() == 'program' then outer = n break end
                n = n:parent()
            end
            if outer == calln then return true end
            local head = outer:named_child(0)
            local t = head and vim.treesitter.get_node_text(head, src) or ''
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
        litdata_types = { object = true, array = true },
        import_query = [=[ (import_statement source: (string) @path) ]=],
        resolve_import = function (path, files, from)
            path = path:gsub('^["\']', ''):gsub('["\']$', '')
            local dir = from:match('^(.*)/[^/]*$')
            local cand = path:gsub('^%./', '')
            cand = dir and (dir .. '/' .. cand) or cand
            for _, c in ipairs({ cand, cand .. '.js', cand .. '.ts',
                (cand:gsub('%.js$', '.ts')) }) do
                if files[c] then return c end
            end
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
                    return cn and (vim.treesitter.get_node_text(cn, src) .. '::' .. name)
                        or name
                end
                p2 = p2:parent()
            end
            return name
        end,
        id_query = '(name) @id',
        block_skip = { php_tag = true, class_declaration = true,
            interface_declaration = true, trait_declaration = true },
        litdata_types = { array_creation_expression = true },
        import_query = [=[
            (require_once_expression (string) @path)
            (require_expression (string) @path)
            (include_once_expression (string) @path)
            (include_expression (string) @path)
            (namespace_use_clause (qualified_name) @path)
        ]=],
        resolve_import = function (path, files, from)
            path = path:gsub('^["\']', ''):gsub('["\']$', '')
            if path:find('\\') then -- a namespaced class: PSR-ish suffix
                local suffix, hit = path:gsub('\\', '/') .. '.php', nil
                for f in pairs(files) do
                    if f == suffix or f:sub(-#suffix - 1) == '/' .. suffix then
                        if hit then return nil end
                        hit = f
                    end
                end
                return hit
            end
            local dir = from:match('^(.*)/[^/]*$')
            for _, cand in ipairs({ dir and (dir .. '/' .. path) or path, path }) do
                if files[cand] then return cand end
            end
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
        import_query = [[ (import_statement name: (dotted_name) @path)
                          (import_from_statement module_name: (dotted_name) @path) ]],
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

local function node_text(n, src) return vim.treesitter.get_node_text(n, src) end

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
                if it == 'array_element_initializer' then
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

local EXCLUDE_DIRS = { node_modules = true, vendor = true, dist = true,
    build = true, cache = true, minified = true }

local function list_files(root, subdirs)
    local out, minified = {}, {}
    local function in_scope(rel)
        if not subdirs then return true end
        for _, p in ipairs(subdirs) do
            if rel:sub(1, #p) == p then return true end
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
                    if not EXCLUDE_DIRS[name:lower()] then rec(r) end
                elseif lang_for(r) and want(r) then
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

--- Extract a neutral-schema graph from a directory tree. Any file whose
--- extension has a spec (and an available parser) participates.
---@param root string
---@return table data  the schema-1 graph (ready for store.ingest)
function M.extract(root, opts)
    root = vim.fn.fnamemodify(vim.fn.expand(root), ':p'):gsub('/+$', '')
    local files, minified = list_files(root, opts and opts.subdirs)
    local fileset = {}
    for _, f in ipairs(files) do fileset[f] = true end

    local data = { schema = 1, root = root, provider = 'treesitter',
        capabilities = { calls = true, litdata = true, df = 'lite' },
        nodes = {}, edges = {}, calls = {} }
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

    for _, file in ipairs(files) do
        local lang, spec = lang_for(file)
        local fd = io.open(root .. '/' .. file, 'r')
        local src = fd and fd:read('a')
        if fd then fd:close() end
        local okp, parser = pcall(vim.treesitter.get_string_parser, src or '', lang)
        if not src or not okp then
            no_parser[lang] = true
            goto next_file
        end
        local tree = parser:parse()[1]
        local tsroot = tree:root()

        nodes[#nodes + 1] = { id = file, name = file, kind = 'module', file = file,
            range = pos_of(tsroot), order = -1 }

        -- functions
        local q = parse_query(lang, spec.functions)
        local fnDefs = {} -- def node -> true (for block grouping)
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
                    local isfield = spec.field_fn_cbarg
                        and namen:parent() and namen:parent():type() == 'field'
                    if spec.cbarg_within and not isfield then
                        local a = defn:parent()
                        while a do
                            if spec.cbarg_within[a:type()] then isfield = true break end
                            a = a:parent()
                        end
                    end
                    -- multi-equation definitions (haskell) are ONE function:
                    -- fold this equation into the previous node
                    local prev = spec.merge_equations and lastFn[file]
                    if prev and prev.name == name then
                        prev.range['end'] = sp['end']
                        for _, r in ipairs(fnRanges[file] or {}) do
                            if r.id == prev.id then r.e = sp['end'].line break end
                        end
                        fnDefs[defn] = true
                        goto fn_done
                    end
                    nodes[#nodes + 1] = { id = id, name = name,
                        kind = method and 'method' or 'function', file = file,
                        range = sp, order = sp.start.line, params = params,
                        cbarg = isfield or nil,
                        entry = (spec.entry_names or {})[name] or nil,
                        df = (spec.dataflow or dataflow)(defn, spec, src, params) }
                    lastFn[file] = nodes[#nodes]
                    fnDefs[defn] = true
                    -- the outermost query pattern may match a nested def too;
                    -- ranges keep the innermost containing fn for attribution
                    fnRanges[file] = fnRanges[file] or {}
                    table.insert(fnRanges[file], { s = sp.start.line, e = sp['end'].line, id = id })
                    exact[name] = exact[name] or {}
                    table.insert(exact[name], nodes[#nodes])
                    local tl = name:match('([%w_]+)$')
                    if tl and tl ~= name then
                        tail[tl] = tail[tl] or {}
                        table.insert(tail[tl], nodes[#nodes])
                    end
                    ::fn_done::
                end
            end
        end

        -- top-level vars (+ litdata)
        q = parse_query(lang, spec.vars)
        if q then
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
                    local d = valn and (spec.litdata_types or {})[valn:type()]
                        and litval(valn, src, spec, 0) or nil
                    nodes[#nodes + 1] = { id = id, name = name, kind = 'var',
                        file = file, range = sp, order = sp.start.line,
                        data = type(d) == 'table' and d or nil }
                    varsByName[name] = varsByName[name] or {}
                    table.insert(varsByName[name], nodes[#nodes])
                end
            end
        end

        -- blocks: runs of top-level statements that aren't function defs
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
                    local id = ('%s::block@%d'):format(file, run.s.start.line)
                    nodes[#nodes + 1] = { id = id, name = run.name, kind = 'block',
                        file = file, order = run.s.start.line,
                        range = { start = run.s.start, ['end'] = run.e['end'] } }
                    run = nil
                end
            end
            for stmt in container:iter_children() do
                if stmt:named() and stmt:type() ~= 'comment'
                    and not (spec.block_skip or {})[stmt:type()] then
                    if fnDefs[stmt]
                        or (stmt:child(0) and fnDefs[stmt:child(0)]) then
                        flush()
                    else
                        local p = pos_of(stmt)
                        if not run then
                            run = { s = p, e = p,
                                name = (lines[p.start.line + 1] or ''):match('^%s*(.-)%s*$'):sub(1, NAME_CAP) }
                        else
                            run.e = p
                        end
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

        -- calls (inventory + reference sites, resolved after all files)
        q = parse_query(lang, spec.calls)
        if q then
            for _, match in q:iter_matches(tsroot, src, 0, -1) do
                local calln, namen
                for id, ns in pairs(match) do
                    local cap = q.captures[id]
                    local n = cap_node(ns)
                    if cap == 'call' then calln = n elseif cap == 'name' then namen = n end
                end
                if calln and namen
                    and not (spec.call_skip or {})[node_text(namen, src)] then
                    local full = node_text(namen, src):gsub('%s+', '')
                    -- the inventory names the VERB (lint configs match on it);
                    -- the full expression text drives resolution. A dynamic
                    -- callee keeps its sigil: `→ $op` says what it is
                    local dynamic = spec.dynamic_callee_types
                        and spec.dynamic_callee_types[namen:type()] or nil
                    local callee = dynamic and full
                        or full:match('([%w_]+)$') or full
                    local method = full:find(':') ~= nil
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
                    for a in (argsn and argsn.iter_children and argsn:iter_children() or function () end) do
                        if a:named() and a:type() ~= 'comment' then
                            if a:type() == 'argument' then -- php wraps each arg
                                a = a:named_child(0) or a
                            end
                            local t = a:type()
                            if t == 'string' or t == 'string_literal' then
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
                    -- an import call also emits the module edge
                    if spec.import_call and full == spec.import_call then
                        local target = args[1] and args[1] ~= ''
                            and spec.resolve_import(args[1], fileset, file)
                        if target and target ~= file then
                            local pt = calln:parent()
                            local ptt = pt and pt:type() or ''
                            edges[#edges + 1] = { from = file, to = target, kind = 'import',
                                sideeffect = (ptt == 'chunk' or ptt == 'block'
                                    or ptt:find('expression_statement')) and true or nil }
                        end
                    end
                    local c = { callee = callee, args = args, argv = argv,
                        file = file, line = sp.start.line, method = method,
                        full = full ~= callee and full or nil,
                        dynamic = dynamic,
                        top = is_top or nil }
                    calls[#calls + 1] = c
                    local indirect = (spec.indirect_calls or {})[callee]
                    indirect = indirect and args[indirect + (method and 1 or 0)]
                    pending[#pending + 1] = { call = c, file = file, full = full,
                        indirect = indirect ~= '' and indirect or nil,
                        at = pos_of(namen), encl = encl and pos_of(encl) }
                end
            end
        end
        ::next_file::
    end

    -- ── resolution pass: name-matched, ambiguity refuses to link ─────────────
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
    local function resolve(name, file)
        -- 1-2 char names are shadow-bait (pattern vars, loop counters):
        -- name-matching them is noise-dominated in every language
        if #name < 3 then return nil end
        local _, spec = lang_for(file)
        local snames = spec and spec.stdlib_names or {}
        if snames[name] or snames[name:match('([%w_%-]+)$') or ''] then return nil end
        local cands = exact[name]
        if cands then
            -- same-file priority is a FILE-SCOPE assumption (lua locals, C
            -- statics); dynamically-dispatched defs (instance methods) don't
            -- get it — they link only when globally unique
            local same
            for _, n in ipairs(cands) do
                if n.file == file and not n.cbarg then
                    if same then return nil end -- ambiguous within the file
                    same = n
                end
            end
            if same then return same, false end
            if #cands == 1 then return cands[1], true end
            return nil
        end
        for _, pre in ipairs(spec and spec.stdlib_prefixes or {}) do
            if name:sub(1, #pre) == pre then return nil end
        end
        local tl = name:match('([%w_]+)$')
        local tc = tl and (tail[tl] or exact[tl])
        if tc and #tc == 1 then return tc[1], true end
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
            local fd = io.open(root .. '/' .. p.file, 'r')
            src_cache[p.file] = fd and vim.split(fd:read('a'), '\n', { plain = true }) or false
            if fd then fd:close() end
        end
        local line = src_cache[p.file] and src_cache[p.file][defstmt.l] or ''
        local lit = line:match('%$' .. varname .. [=[%s*=%s*['"]([%w_:\]+)['"]]=])
        return lit and resolve(lit, p.file) or nil
    end

    for _, p in ipairs(pending) do
        local target, inferred
        if p.call.dynamic then
            -- $fn(...): frontier — unless single-assignment literal flow
            -- pins the name down within the function
            target = literal_flow(p)
            if target then
                p.call.traced = true
                p.call.dynamic = nil -- pinned down: no longer a frontier
            end
        elseif p.indirect then
            target = resolve(p.indirect, p.file)
            inferred = false -- the literal IS the dispatch mechanism
        else
            target, inferred = resolve(p.full or p.call.callee, p.file)
        end
        if target then
            p.call.to = target.id
            p.call.inferred = inferred or nil
            local from = fn_at(p.file, p.at.start.line)
            p.call.fn = from
            if from then addref(from, target.id, p.at, inferred) end
        else
            p.call.fn = fn_at(p.file, p.at.start.line)
        end
        -- callback pattern: an identifier argument naming a unique function
        for _, a in ipairs(p.call.argv) do
            if a.k == 'local' and a.name then
                local t2, _ = resolve(a.name, p.file)
                if t2 and (t2.kind == 'function' or t2.kind == 'method') then
                    a.k, a.to = 'func', t2.id
                    local from = p.call.fn
                    if from then addref(from, t2.id, p.at, true) end
                end
            end
        end
    end

    -- use edges + function references: identifier occurrences naming a
    -- known top-level var (same file, or unique across the workspace) or —
    -- outside call position — a unique function (dispatch tables, registry
    -- values). A top-level function reference marks the target dynamically
    -- dispatched (cbarg): a dispatch-table entry is not dead code.
    for _, file in ipairs(files) do
        local lang, spec = lang_for(file)
        local fd = io.open(root .. '/' .. file, 'r')
        local src = fd and fd:read('a')
        if fd then fd:close() end
        local okp, parser = pcall(vim.treesitter.get_string_parser, src or '', lang)
        if src and okp and fnRanges[file] then
            local tsroot = parser:parse()[1]:root()
            local q = parse_query(lang, spec.id_query or '(identifier) @id')
            local useEdge = {}
            if q then
                for _, n in q:iter_captures(tsroot, src, 0, -1) do
                    local name = node_text(n, src)
                    local parent = n:parent()
                    local pt = parent and parent:type() or ''
                    local callee_pos = (pt == 'call_expression' or pt == 'function_call'
                            or pt == 'call' or pt == 'apply')
                        and (parent:field('function')[1] == n or parent:field('name')[1] == n)
                        -- sexp grammars have no fields: the head IS the callee
                        or (pt == 'list' and parent:named_child(0) == n)
                    if not callee_pos and #name >= 3
                        and not (spec.stdlib_names or {})[name] then
                        local fns = exact[name]
                        if fns and #fns == 1 then
                            local t = fns[1]
                            local line = select(1, n:range())
                            if not (t.file == file and line == t.range.start.line) then
                                local from = fn_at(file, line)
                                if from then
                                    addref(from, t.id, pos_of(n), true)
                                else
                                    t.cbarg = true -- referenced from top-level data
                                end
                            end
                        end
                    end
                    local cands = varsByName[name]
                    if cands then
                        local var
                        for _, v in ipairs(cands) do
                            if v.file == file then var = v break end
                        end
                        if not var and #cands == 1 then var = cands[1] end
                        local line = select(1, n:range())
                        if var and not (var.file == file
                            and line == var.range.start.line) then
                            local from = fn_at(file, line)
                            if from then
                                local k = from .. '\31' .. var.id
                                local e = useEdge[k]
                                if not e then
                                    e = { from = from, to = var.id, kind = 'use', at = {} }
                                    useEdge[k] = e
                                    edges[#edges + 1] = e
                                end
                                e.at[#e.at + 1] = pos_of(n)
                            end
                        end
                    end
                end
            end
        end
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
    data.no_parser = next(no_parser) and vim.tbl_keys(no_parser) or nil
    return data
end

return M
