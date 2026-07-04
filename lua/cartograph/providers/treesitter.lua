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

local function parse_query(lang, q)
    local ok, query = pcall(vim.treesitter.query.parse, lang, q)
    return ok and query or nil
end

local function in_function(n)
    local p = n:parent()
    while p do
        local t = p:type()
        if t == 'function_definition' or t == 'function_declaration' then return p end
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
                if it == 'field' or it == 'pair' then
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

-- df-lite: the body's top-level statements with def/use NAME lists and
-- def->use dependencies. Approximate (no scoping) but structurally the same
-- contract as the lua-ls df, so the fn altitude and extract engine work.
local function dataflow(def, spec, src, params)
    local body = def:field(spec.body_field)[1]
    if not body then return nil end
    local stmts = {}
    for stmt in body:iter_children() do
        if stmt:named() and stmt:type() ~= 'comment' then
            local defs, uses, seen_d, seen_u = {}, {}, {}, {}
            local function walk(n, defpos)
                local t = n:type()
                if t == 'identifier' then
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
                    or t == 'assignment_expression' then
                    local left = n:field('left')[1] or n:child(0)
                    for c in n:iter_children() do
                        if c:named() then walk(c, c == left or c:type() == 'variable_list') end
                    end
                    return
                end
                if t == 'init_declarator' then
                    local d = n:field('declarator')[1]
                    for c in n:iter_children() do
                        if c:named() then walk(c, c == d) end
                    end
                    return
                end
                for c in n:iter_children() do
                    if c:named() then walk(c, defpos and t == 'variable_list') end
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
    local ps = def:field(spec.params_field)[1]
    local out = method and { 'self' } or {}
    if ps then
        for c in ps:iter_children() do
            if c:type() == 'identifier' then
                out[#out + 1] = node_text(c, src)
            elseif c:named() then -- c parameter_declaration / defaulted params
                for id in c:iter_children() do
                    if id:type() == 'identifier' then
                        out[#out + 1] = node_text(id, src)
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

local function list_files(root)
    local out = {}
    local function rec(rel)
        local it = vim.uv.fs_scandir(rel == '' and root or (root .. '/' .. rel))
        while it do
            local name, t = vim.uv.fs_scandir_next(it)
            if not name then break end
            if name:sub(1, 1) ~= '.' then
                local r = rel == '' and name or (rel .. '/' .. name)
                if t == 'directory' then
                    rec(r)
                elseif lang_for(r) then
                    out[#out + 1] = r
                end
            end
        end
    end
    rec('')
    table.sort(out)
    return out
end

--- Extract a neutral-schema graph from a directory tree. Any file whose
--- extension has a spec (and an available parser) participates.
---@param root string
---@return table data  the schema-1 graph (ready for store.ingest)
function M.extract(root)
    root = vim.fn.fnamemodify(vim.fn.expand(root), ':p'):gsub('/+$', '')
    local files = list_files(root)
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
                if defn and namen then
                    local name = node_text(namen, src):gsub('%s+', '')
                    local sp = pos_of(defn)
                    local method = spec.is_method(name, defn)
                    local id = ('%s::%s@%d'):format(file, name, sp.start.line)
                    local params = fn_params(defn, spec, src, method and lang == 'lua')
                    local isfield = spec.field_fn_cbarg
                        and namen:parent() and namen:parent():type() == 'field'
                    nodes[#nodes + 1] = { id = id, name = name,
                        kind = method and 'method' or 'function', file = file,
                        range = sp, order = sp.start.line, params = params,
                        cbarg = isfield or nil,
                        entry = (spec.entry_names or {})[name] or nil,
                        df = dataflow(defn, spec, src, params) }
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
                if defn and namen and not in_function(defn) then
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
            for stmt in tsroot:iter_children() do
                if stmt:named() and stmt:type() ~= 'comment' then
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
                if calln and namen then
                    local full = node_text(namen, src):gsub('%s+', '')
                    -- the inventory names the VERB (lint configs match on it);
                    -- the full expression text drives resolution
                    local callee = full:match('([%w_]+)$') or full
                    local method = full:find(':') ~= nil
                    local sp = pos_of(calln)
                    local encl = in_function(calln)
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
                            else
                                args[#args + 1] = ''
                                argv[#argv + 1] = { k = 'expr' }
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
                        top = encl == nil or nil }
                    calls[#calls + 1] = c
                    pending[#pending + 1] = { call = c, file = file, full = full,
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
        local cands = exact[name]
        if cands then
            local same
            for _, n in ipairs(cands) do
                if n.file == file then
                    if same then return nil end -- ambiguous within the file
                    same = n
                end
            end
            if same then return same, false end
            if #cands == 1 then return cands[1], true end
            return nil
        end
        local tl = name:match('([%w_]+)$')
        local tc = tl and (tail[tl] or exact[tl])
        if tc and #tc == 1 then return tc[1], true end
        return nil
    end
    for _, p in ipairs(pending) do
        local target, inferred = resolve(p.full or p.call.callee, p.file)
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
        local lang, _ = lang_for(file)
        local fd = io.open(root .. '/' .. file, 'r')
        local src = fd and fd:read('a')
        if fd then fd:close() end
        local okp, parser = pcall(vim.treesitter.get_string_parser, src or '', lang)
        if src and okp and fnRanges[file] then
            local tsroot = parser:parse()[1]:root()
            local q = parse_query(lang, '(identifier) @id')
            local useEdge = {}
            if q then
                for _, n in q:iter_captures(tsroot, src, 0, -1) do
                    local name = node_text(n, src)
                    local parent = n:parent()
                    local pt = parent and parent:type() or ''
                    local callee_pos = (pt == 'call_expression' or pt == 'function_call'
                            or pt == 'call')
                        and (parent:field('function')[1] == n or parent:field('name')[1] == n)
                    if not callee_pos then
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

    data.no_parser = next(no_parser) and vim.tbl_keys(no_parser) or nil
    return data
end

return M
