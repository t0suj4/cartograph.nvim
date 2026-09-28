-- cartograph.cjs — A NARROW C -> JAVASCRIPT EMITTER for a CLOSED region of preprocessed C (CART-1197: LuaJIT's pattern
-- matcher, transliterated instead of re-authored). Input is `gcc -E` output — the HOST COMPILER expands the macros, so
-- nothing here re-types what the headers say.
--
--   emit(sources, opts) -> js, refusals, info
--     sources   { { text = <preprocessed C>, name = <for messages> }, … } (the matcher's file, plus the files that
--               DEFINE the data it reads — lj_char.c's lj_char_bits)
--     opts      { roots = { <function names> }, templates = { [c function name] = js template }, header = <string> }
--
-- THE MEMORY MODEL is Emscripten's: ONE byte HEAP (`H`, a Uint8Array the caller installs), a POINTER is an integer
-- offset into it, and `static const` arrays the code reads are ALLOCATED INTO the heap at fixed offsets (their
-- initializers evaluated as the C expressions they are). So C's reliance on a NUL terminator, pointer differences and
-- `(table + 1)[c]` are all exact. A deref's SIGN and WIDTH come from the DECLARED pointee type (C states it — nothing
-- is inferred): `char` reads signed (H[p] << 24 >> 24), unsigned char / uint8_t unsigned. Offset 0 is never a valid
-- pointer (the heap reserves it), so NULL is JS null and a pointer's truthiness is `!== null`.
-- A STRUCT is a JS object; a pointer to one is the object; its array fields are JS arrays of objects.
-- C's relational and logical operators yield 0/1 (`+(a < b)`), and every condition tests C truthiness ($T).
-- GOTO: the two structured shapes the region uses, and only those —
--   BACKWARD   `L: stmt` with every `goto L` inside stmt  ->  `L: for (;;) { stmt; break; }` and `continue L`
--   INTO DEFAULT  `default: L: stmt` of a switch, gotos from the switch's other cases (a nested switch included) ->
--              the labeled body HOISTED after the switch behind a flag; `goto L` sets the flag and breaks the switch;
--              the body's own switch-level `break`s exit the hoisted block
-- Anything else — another goto shape, address-of, sizeof, a pointer to a non-byte type used arithmetically, a call with
-- no definition and no template — is REFUSED by name.
local M = {}

local JS_RESERVED = {}
for w in ('abstract arguments await boolean byte class delete eval export extends final finally function implements '
    .. 'import in instanceof interface let native new null package private protected public super synchronized this '
    .. 'throw throws transient try typeof var void with yield undefined NaN Infinity H'):gmatch('%S+') do JS_RESERVED[w] = true end

local TYPEDEF_INT = { size_t = true, ptrdiff_t = true, int32_t = true, uint32_t = true, MSize = true, int64_t = true,
    uint64_t = true, intptr_t = true, uintptr_t = true, lua_Integer = true, BCPos = true }
local TYPEDEF_UCHAR = { uint8_t = true }

local function field_of(n, name) for c, f in n:iter_children() do if f == name then return c end end end
local function named_kids(n)
    local out = {}
    for c in n:iter_children() do if c:named() and c:type() ~= 'comment' then out[#out + 1] = c end end
    return out
end

function M.emit(sources, opts)
    opts = opts or {}
    local refusals = {}
    local cur_src
    local function text(n) return vim.treesitter.get_node_text(n, cur_src) end
    local function refuse(n, kind, why)
        refusals[#refusals + 1] = { kind = kind, why = why, line = n and (n:start() + 1) or 0 }
        return ('$crefuse(%q)'):format(kind .. ': ' .. why)
    end

    -- ── the declarations of every source: typedef'd structs, functions, global arrays, enum-carried messages ──────
    local structs, funcs, globals, errmsg = {}, {}, {}, {}
    local trees = {}
    for _, s in ipairs(sources) do
        local tree = vim.treesitter.get_string_parser(s.text, 'c'):parse()[1]
        trees[#trees + 1] = { root = tree:root(), src = s.text, name = s.name }
    end

    --- a C type from a `type` node (+ qualifiers) -> { k = 'int' | 'char' | 'uchar' | 'struct' | 'void' | 'opaque', name? }
    local function base_type(tn)
        if not tn then return { k = 'int' } end
        local t = tn:type()
        local tx = text(tn)
        if t == 'primitive_type' then
            -- tree-sitter C parses the stdint names (uint8_t, size_t, …) as PRIMITIVE types
            if TYPEDEF_UCHAR[tx] then return { k = 'uchar' } end
            if tx == 'char' then return { k = 'char' } end
            if tx == 'void' then return { k = 'void' } end
            return { k = 'int' }
        elseif t == 'sized_type_specifier' then
            if tx:find('char') then return tx:find('unsigned') and { k = 'uchar' } or { k = 'char' } end
            return { k = 'int' }
        elseif t == 'type_identifier' then
            if TYPEDEF_INT[tx] then return { k = 'int' } end
            if TYPEDEF_UCHAR[tx] then return { k = 'uchar' } end
            if structs[tx] then return { k = 'struct', name = tx } end
            return { k = 'opaque', name = tx }
        elseif t == 'struct_specifier' then
            local nm = field_of(tn, 'name')
            return { k = 'struct', name = nm and text(nm) or ('anon@' .. tn:start()), node = tn }
        end
        return { k = 'opaque', name = tx }
    end
    --- apply a declarator to a base type -> name, type (pointers, arrays, functions, init)
    local function declarator(d, ty)
        while d do
            local t = d:type()
            if t == 'identifier' or t == 'field_identifier' or t == 'type_identifier' then return text(d), ty
            elseif t == 'pointer_declarator' or t == 'abstract_pointer_declarator' then ty = { k = 'ptr', to = ty }; d = field_of(d, 'declarator')
            elseif t == 'array_declarator' then
                local sz = field_of(d, 'size')
                ty = { k = 'array', of = ty, size = sz and tonumber(text(sz)) }
                d = field_of(d, 'declarator')
            elseif t == 'init_declarator' then d = field_of(d, 'declarator')
            elseif t == 'function_declarator' then ty = { k = 'func', ret = ty, params = field_of(d, 'parameters') }; d = field_of(d, 'declarator')
            elseif t == 'parenthesized_declarator' then d = named_kids(d)[1]
            else return nil, ty end
        end
        return nil, ty
    end
    local function struct_fields(sn)
        local body = field_of(sn, 'body')
        local fields = {}
        for _, fd in ipairs(body and named_kids(body) or {}) do
            if fd:type() == 'field_declaration' then
                local bt = base_type(field_of(fd, 'type'))
                if bt.k == 'struct' and bt.node then bt.fields = struct_fields(bt.node) end
                for c, f in fd:iter_children() do
                    if f == 'declarator' then
                        local nm, ty = declarator(c, bt)
                        if nm then fields[nm] = ty end
                    end
                end
            end
        end
        return fields
    end
    for _, tr in ipairs(trees) do
        cur_src = tr.src
        for n in tr.root:iter_children() do
            local t = n:type()
            if t == 'type_definition' then
                local ty, nm = field_of(n, 'type'), field_of(n, 'declarator')
                if ty and ty:type() == 'struct_specifier' and nm then structs[text(nm)] = struct_fields(ty) end
            elseif t == 'function_definition' then
                local nm, fty = declarator(field_of(n, 'declarator'), base_type(field_of(n, 'type')))
                if nm then funcs[nm] = { node = n, type = fty, src = tr.src } end
            elseif t == 'declaration' then
                local bt = base_type(field_of(n, 'type'))
                for c, f in n:iter_children() do
                    if f == 'declarator' and c:type() == 'init_declarator' then
                        local nm, ty = declarator(c, bt)
                        local val = field_of(c, 'value')
                        if nm and ty.k == 'array' and val and val:type() == 'initializer_list' then
                            globals[nm] = { type = ty, init = val, src = tr.src }
                        end
                    end
                end
            elseif t == 'enum_specifier' or (t == 'declaration' and false) then
                -- handled below (the enum is nested in a declaration in the preprocessed output)
            end
        end
        -- `LJ_ERR_X_ = LJ_ERR_X + sizeof("…" "…")-1`: the MESSAGE of LJ_ERR_X, exactly as lj_errmsg.h spells it —
        -- read from the enumerator's own string literals (a message holds parentheses, so no text pattern can cut it)
        local eq = vim.treesitter.query.parse('c', '(enumerator name: (identifier) @n value: (_) @v)')
        local sq = vim.treesitter.query.parse('c', '(string_literal) @s')
        local cur
        for id, node in eq:iter_captures(tr.root, tr.src, 0, -1) do
            if eq.captures[id] == 'n' then cur = text(node)
            elseif cur and cur:match('^LJ_ERR_.*_$') and text(node):find('sizeof', 1, true) then
                local parts = {}
                for _, lit in sq:iter_captures(node, tr.src, 0, -1) do parts[#parts + 1] = text(lit):sub(2, -2) end
                errmsg[cur:sub(1, -2)] = table.concat(parts)
            end
        end
    end
    local function struct_of(ty)
        if ty and ty.k == 'struct' then return ty.fields or structs[ty.name] end
    end

    -- ── reachability from the roots: only what the roots call is emitted ─────────────────────────────────────────
    local want, order = {}, {}
    local function visit(name)
        if want[name] or not funcs[name] then return end
        want[name] = true
        cur_src = funcs[name].src
        local q = vim.treesitter.query.parse('c', '(call_expression function: (identifier) @f)')
        for _, c in q:iter_captures(funcs[name].node, cur_src, 0, -1) do visit(text(c)) end
        order[#order + 1] = name
    end
    for _, r in ipairs(opts.roots or {}) do visit(r) end

    -- ── the heap image: every global array a wanted function reads, at a fixed offset ────────────────────────────
    local used_globals = {}
    local gq = vim.treesitter.query.parse('c', '(identifier) @id')
    for _, name in ipairs(order) do
        cur_src = funcs[name].src
        for _, c in gq:iter_captures(funcs[name].node, cur_src, 0, -1) do
            local g = text(c)
            if globals[g] then used_globals[g] = true end
        end
    end
    local base, image_js, gbase = 1, {}, {}
    local gnames = {}
    for g in pairs(used_globals) do gnames[#gnames + 1] = g end
    table.sort(gnames)

    local scope -- name -> { js, type }
    local expr, stmt
    local function T(js) return '$T(' .. js .. ')' end

    -- ── expressions: -> js, type ──────────────────────────────────────────────────────────────────────────────────
    local function deref(ptrjs, ty, n)
        local el = ty and (ty.k == 'ptr' and ty.to or ty.k == 'array' and ty.of) or nil
        if not el then return refuse(n, 'deref', 'a dereference of a non-pointer'), { k = 'int' } end
        if el.k == 'char' then return ('(H[' .. ptrjs .. '] << 24 >> 24)'), { k = 'int' } end
        if el.k == 'uchar' then return ('H[' .. ptrjs .. ']'), { k = 'int' } end
        return refuse(n, 'deref', 'a dereference of a pointer to ' .. el.k), { k = 'int' }
    end
    local function charlit(n)
        local s = text(n):sub(2, -2)
        local ESC = { n = 10, t = 9, r = 13, ['0'] = 0, ['\\'] = 92, ["'"] = 39, ['"'] = 34, a = 7, b = 8, f = 12, v = 11 }
        if s:sub(1, 1) == '\\' then
            local r = s:sub(2)
            if r:match('^[0-7]+$') then return tonumber(r, 8) end
            if r:match('^x%x+$') then return tonumber(r:sub(2), 16) end
            return ESC[r]
        end
        return s:byte(1)
    end
    function expr(n)
        local t = n:type()
        if t == 'parenthesized_expression' then
            local js, ty = expr(named_kids(n)[1])
            return '(' .. js .. ')', ty
        elseif t == 'identifier' then
            local nm = text(n)
            local v = scope[nm]
            if v then return v.js, v.type end
            if gbase[nm] then return tostring(gbase[nm]), { k = 'ptr', to = globals[nm].type.of } end
            if funcs[nm] then return nm, funcs[nm].type end
            if nm:match('^LJ_ERR_') then return ('%q'):format(errmsg[nm] or nm), { k = 'errcode' } end
            return refuse(n, 'identifier', 'no declaration for `' .. nm .. '`'), { k = 'int' }
        elseif t == 'string_literal' or t == 'concatenated_string' then
            -- a C string literal as a JS string of the same bytes (only plain text and \n / \t / \\ / \" occur here)
            local parts = {}
            local q = vim.treesitter.query.parse('c', '(string_literal) @s')
            for _, lit in q:iter_captures(n, cur_src, 0, -1) do parts[#parts + 1] = text(lit):sub(2, -2) end
            return '"' .. table.concat(parts) .. '"', { k = 'ptr', to = { k = 'char' } }
        elseif t == 'number_literal' then
            local v = text(n):gsub('[uUlL]+$', '')
            return v, { k = 'int' }
        elseif t == 'char_literal' then
            local v = charlit(n)
            if not v then return refuse(n, 'char', 'an escape this emitter does not read: ' .. text(n)), { k = 'int' } end
            return tostring(v), { k = 'int' }
        elseif t == 'pointer_expression' then
            local op = text(field_of(n, 'operator'))
            local a = field_of(n, 'argument')
            if op == '*' then
                local js, ty = expr(a)
                return deref(js, ty, n)
            end
            return refuse(n, 'address-of', 'taking an address (`&`)'), { k = 'int' }
        elseif t == 'subscript_expression' then
            local ajs, aty = expr(field_of(n, 'argument'))
            local ijs = expr(field_of(n, 'index'))
            local el = aty and (aty.k == 'ptr' and aty.to or aty.k == 'array' and aty.of) or nil
            if el and el.k == 'struct' then return ('%s[%s]'):format(ajs, ijs), el end
            return deref(('%s + %s'):format(ajs, ijs), aty, n)
        elseif t == 'field_expression' then
            local ajs, aty = expr(field_of(n, 'argument'))
            local op = text(field_of(n, 'operator'))
            local fname = text(field_of(n, 'field'))
            local sty = op == '->' and aty and aty.k == 'ptr' and aty.to or aty
            local fields = struct_of(sty)
            if not fields or not fields[fname] then return refuse(n, 'field', 'no struct field `' .. fname .. '`'), { k = 'int' } end
            return ('%s.%s'):format(ajs, fname), fields[fname]
        elseif t == 'binary_expression' then
            local op = text(field_of(n, 'operator'))
            local ljs, lty = expr(field_of(n, 'left'))
            local rjs, rty = expr(field_of(n, 'right'))
            local lp = lty and (lty.k == 'ptr' or lty.k == 'array')
            local rp = rty and (rty.k == 'ptr' or rty.k == 'array')
            if op == '&&' or op == '||' then return ('+(%s %s %s)'):format(T(ljs), op, T(rjs)), { k = 'int' } end
            if op == '==' or op == '!=' then return ('+(%s %s %s)'):format(ljs, op == '==' and '===' or '!==', rjs), { k = 'int' } end
            if op == '<' or op == '>' or op == '<=' or op == '>=' then return ('+(%s %s %s)'):format(ljs, op, rjs), { k = 'int' } end
            if op == '+' or op == '-' then
                if lp and rp and op == '-' then return ('(%s - %s)'):format(ljs, rjs), { k = 'int' } end
                local pty = lp and lty or rp and rty
                if pty then
                    local el = pty.k == 'ptr' and pty.to or pty.of
                    if el.k ~= 'char' and el.k ~= 'uchar' then return refuse(n, 'pointer-arith', 'arithmetic on a pointer to ' .. el.k), pty end
                    return ('(%s %s %s)'):format(ljs, op, rjs), { k = 'ptr', to = el }
                end
                return ('(%s %s %s)'):format(ljs, op, rjs), { k = 'int' }
            end
            if op == '*' or op == '&' or op == '|' or op == '^' or op == '<<' or op == '>>' then return ('(%s %s %s)'):format(ljs, op, rjs), { k = 'int' } end
            if op == '/' then return ('Math.trunc(%s / %s)'):format(ljs, rjs), { k = 'int' } end
            if op == '%' then return ('(%s %% %s)'):format(ljs, rjs), { k = 'int' } end
            return refuse(n, 'operator', 'the binary operator ' .. op), { k = 'int' }
        elseif t == 'unary_expression' then
            local op = text(field_of(n, 'operator'))
            local js = expr(field_of(n, 'argument'))
            if op == '!' then return ('+!%s'):format(T(js)), { k = 'int' } end
            if op == '-' or op == '~' or op == '+' then return op .. js, { k = 'int' } end
            return refuse(n, 'operator', 'the unary operator ' .. op), { k = 'int' }
        elseif t == 'update_expression' then
            local op = text(field_of(n, 'operator'))
            local a = field_of(n, 'argument')
            local js, ty = expr(a)
            if ty and ty.k == 'ptr' and ty.to.k ~= 'char' and ty.to.k ~= 'uchar' then return refuse(n, 'pointer-arith', '++/-- on a pointer to ' .. ty.to.k), ty end
            local prefix = n:child(0):type() == op
            return prefix and (op .. js) or (js .. op), ty
        elseif t == 'assignment_expression' then
            local op = text(field_of(n, 'operator'))
            local l = field_of(n, 'left')
            local ljs, lty = expr(l)
            local rjs = expr(field_of(n, 'right'))
            if ljs:match('^%(H%[') or ljs:match('^H%[') then return refuse(n, 'store', 'a store through a pointer'), lty end
            return ('%s %s %s'):format(ljs, op, rjs), lty
        elseif t == 'conditional_expression' then
            local c = expr(field_of(n, 'condition'))
            local a, aty = expr(field_of(n, 'consequence'))
            local b = expr(field_of(n, 'alternative'))
            return ('(%s ? %s : %s)'):format(T(c), a, b), aty
        elseif t == 'cast_expression' then
            local td = field_of(n, 'type')
            local bt = base_type(field_of(td, 'type'))
            local _, ty = declarator(field_of(td, 'declarator'), bt)
            local vjs, vty = expr(field_of(n, 'value'))
            if ty.k == 'ptr' and ty.to.k == 'void' and vjs == '0' then return 'null', ty end
            if ty.k == 'uchar' then return ('((%s) & 255)'):format(vjs), { k = 'int' } end
            if ty.k == 'char' then return ('((%s) << 24 >> 24)'):format(vjs), { k = 'int' } end
            if ty.k == 'int' then return vjs, { k = 'int' } end
            if ty.k == 'ptr' and vty and vty.k == 'ptr' then return vjs, ty end
            return refuse(n, 'cast', 'a cast to ' .. text(td)), ty
        elseif t == 'call_expression' then
            local fn = text(field_of(n, 'function'))
            local args = {}
            for _, a in ipairs(named_kids(field_of(n, 'arguments'))) do args[#args + 1] = (expr(a)) end
            local tpl = (opts.templates or {})[fn]
            if tpl then
                local js = tpl:gsub('%$(%d)', function (i) return args[tonumber(i)] or 'undefined' end)
                return js, { k = 'int' }
            end
            if funcs[fn] and want[fn] then return ('%s(%s)'):format(fn, table.concat(args, ', ')), funcs[fn].type.ret end
            return refuse(n, 'call', 'no definition and no template for `' .. fn .. '`'), { k = 'int' }
        end
        return refuse(n, t, 'no form for this C expression kind'), { k = 'int' }
    end

    -- ── statements ────────────────────────────────────────────────────────────────────────────────────────────────
    --- ctx: { gotos = { [label] = 'continue' | { flag, sw } }, brk = <js label for a switch-level break in a hoisted body> }
    local labels_in -- label -> { stmt node }
    local function gotos_to(n, label)
        local q = vim.treesitter.query.parse('c', '(goto_statement label: (statement_identifier) @l)')
        local found = {}
        for _, c in q:iter_captures(n, cur_src, 0, -1) do if text(c) == label then found[#found + 1] = c end end
        return found
    end
    local swcount = 0
    local function block(n, ctx)
        local out = {}
        for _, k in ipairs(named_kids(n)) do out[#out + 1] = stmt(k, ctx) end
        return table.concat(out, '\n')
    end
    local function declaration(n)
        local bt = base_type(field_of(n, 'type'))
        local parts = {}
        for c, f in n:iter_children() do
            if f == 'declarator' then
                local nm, ty = declarator(c, bt)
                if nm then
                    if ty.k == 'struct' then return refuse(n, 'local-struct', 'a struct value as a local'), nil end
                    local js = JS_RESERVED[nm] and (nm .. '$') or nm
                    scope[nm] = { js = js, type = ty }
                    local v = c:type() == 'init_declarator' and field_of(c, 'value')
                    parts[#parts + 1] = v and (js .. ' = ' .. (expr(v))) or js
                end
            end
        end
        return 'let ' .. table.concat(parts, ', ') .. ';'
    end
    function stmt(n, ctx)
        local t = n:type()
        if t == 'compound_statement' then return '{\n' .. block(n, ctx) .. '\n}'
        elseif t == 'declaration' then return declaration(n)
        elseif t == 'expression_statement' then
            local e = named_kids(n)[1]
            return e and (expr(e) .. ';') or ';'
        elseif t == 'return_statement' then
            local e = named_kids(n)[1]
            return e and ('return ' .. expr(e) .. ';') or 'return;'
        elseif t == 'if_statement' then
            local c = expr(field_of(n, 'condition'))
            local out = 'if (' .. T(c) .. ') ' .. stmt(field_of(n, 'consequence'), ctx)
            local alt = field_of(n, 'alternative')
            if alt then
                local a = alt:type() == 'else_clause' and named_kids(alt)[1] or alt
                out = out .. ' else ' .. stmt(a, ctx)
            end
            return out
        elseif t == 'while_statement' then
            return ('while (%s) %s'):format(T(expr(field_of(n, 'condition'))), stmt(field_of(n, 'body'), { gotos = ctx.gotos }))
        elseif t == 'do_statement' then
            return ('do %s while (%s);'):format(stmt(field_of(n, 'body'), { gotos = ctx.gotos }), T(expr(field_of(n, 'condition'))))
        elseif t == 'for_statement' then
            local init, cond, upd = field_of(n, 'initializer'), field_of(n, 'condition'), field_of(n, 'update')
            local ijs = init and (init:type() == 'declaration' and declaration(init):gsub(';$', '') or expr(init)) or ''
            return ('for (%s; %s; %s) %s'):format(ijs, cond and T(expr(cond)) or '', upd and expr(upd) or '', stmt(field_of(n, 'body'), { gotos = ctx.gotos }))
        elseif t == 'break_statement' then
            return ctx.brk and ('break ' .. ctx.brk .. ';') or 'break;'
        elseif t == 'continue_statement' then return 'continue;'
        elseif t == 'goto_statement' then
            local label = text(field_of(n, 'label'))
            local g = ctx.gotos and ctx.gotos[label]
            if g == 'continue' then return ('continue %s;'):format(label) end
            if type(g) == 'table' then return ('{ %s = true; break %s; }'):format(g.flag, g.sw) end
            return refuse(n, 'goto', 'a goto of a shape this emitter does not structure (`' .. label .. '`)') .. ';'
        elseif t == 'labeled_statement' then
            local label = text(field_of(n, 'label'))
            local body = named_kids(n)[2] or named_kids(n)[1]
            for c in n:iter_children() do if c:named() and c:type() ~= 'statement_identifier' then body = c end end
            local inside = #gotos_to(body, label)
            if inside > 0 then
                -- BACKWARD: every goto to it lies inside the labeled statement -> a loop, `continue label`
                local g = setmetatable({ [label] = 'continue' }, { __index = ctx.gotos })
                return ('%s: for (;;) {\n%s\nbreak;\n}'):format(label, stmt(body, { gotos = g }))
            end
            return stmt(body, ctx)
        elseif t == 'switch_statement' then
            swcount = swcount + 1
            local sw = '$sw' .. swcount
            local cond = expr(field_of(n, 'condition'))
            local body = field_of(n, 'body')
            -- INTO DEFAULT: `default: L: stmt` whose label other cases jump to
            local hoist
            for _, cs in ipairs(named_kids(body)) do
                if cs:type() == 'case_statement' and not field_of(cs, 'value') then
                    local ks = named_kids(cs)
                    if ks[1] and ks[1]:type() == 'labeled_statement' then
                        local label = text(field_of(ks[1], 'label'))
                        if #gotos_to(body, label) > #gotos_to(ks[1], label) then hoist = { label = label, node = ks[1], case = cs } end
                    end
                end
            end
            local g = ctx.gotos
            local flag
            if hoist then
                flag = '$go' .. swcount
                g = setmetatable({ [hoist.label] = { flag = flag, sw = sw } }, { __index = ctx.gotos })
            end
            local cases = {}
            for _, cs in ipairs(named_kids(body)) do
                if cs:type() == 'case_statement' then
                    local v = field_of(cs, 'value')
                    local head = v and ('case ' .. (expr(v)) .. ':') or 'default:'
                    local stmts = {}
                    if hoist and cs == hoist.case then stmts[1] = flag .. ' = true;'
                    else
                        for _, k in ipairs(named_kids(cs)) do if k ~= v then stmts[#stmts + 1] = stmt(k, { gotos = g }) end end
                    end
                    cases[#cases + 1] = head .. '\n' .. table.concat(stmts, '\n')
                end
            end
            local sjs = ('%s: switch (%s) {\n%s\n}'):format(sw, cond, table.concat(cases, '\n'))
            if not hoist then return sjs end
            local inner
            for c in hoist.node:iter_children() do if c:named() and c:type() ~= 'statement_identifier' then inner = c end end
            local hb = '$blk' .. swcount
            return ('{ let %s = false;\n%s\nif (%s) %s: {\n%s\n} }'):format(flag, sjs, flag, hb, stmt(inner, { gotos = g, brk = hb }))
        end
        return refuse(n, t, 'no form for this C statement kind') .. ';'
    end

    -- ── emit: the heap image, then every reachable function ──────────────────────────────────────────────────────
    for _, g in ipairs(gnames) do
        local gl = globals[g]
        cur_src = gl.src
        scope = {}
        gbase[g] = base
        local vals = {}
        for _, v in ipairs(named_kids(gl.init)) do vals[#vals + 1] = (expr(v)) end
        image_js[#image_js + 1] = ('  // %s[%d] at %d\n  [%d, [%s]],'):format(g, gl.type.size or #vals, base, base, table.concat(vals, ', '))
        base = base + (gl.type.size or #vals)
    end
    local fns = {}
    for _, name in ipairs(order) do
        local f = funcs[name]
        cur_src = f.src
        scope = {}
        local params = {}
        local pl = f.type.params
        for _, pd in ipairs(pl and named_kids(pl) or {}) do
            if pd:type() == 'parameter_declaration' then
                local nm, ty = declarator(field_of(pd, 'declarator'), base_type(field_of(pd, 'type')))
                if nm then
                    local js = JS_RESERVED[nm] and (nm .. '$') or nm
                    scope[nm] = { js = js, type = ty }
                    params[#params + 1] = js
                end
            end
        end
        fns[#fns + 1] = ('function %s(%s) %s'):format(name, table.concat(params, ', '), stmt(field_of(f.node, 'body'), { gotos = {} }))
    end
    local exports = {}
    for _, name in ipairs(order) do exports[#exports + 1] = name end
    local js = table.concat({
        opts.header or '// GENERATED by cartograph.cjs — do not edit',
        "'use strict';",
        '// C truthiness: nonzero and non-NULL (offset 0 is never a valid pointer)',
        'const $T = x => x !== 0 && x !== null && x !== undefined;',
        'const $crefuse = what => { throw new Error("[cjs] no faithful form: " + what); };',
        'let H = null; // the byte heap, installed by the caller (setheap)',
        '// the heap image: every static array the code reads, at its fixed offset (offset 0 reserved)',
        'const IMAGE = [\n' .. table.concat(image_js, '\n') .. '\n];',
        ('const IMAGE_END = %d;'):format(base),
        'function image() { const h = new Uint8Array(IMAGE_END); for (const [at, vals] of IMAGE) h.set(vals, at); return h; }',
        opts.prelude or '',
        table.concat(fns, '\n\n'),
        ('module.exports = { setheap: h => { H = h; }, image, IMAGE_END, STRUCTS: %s, %s };')
            :format(vim.json.encode((function ()
                local o = {}
                for sname, fields in pairs(structs) do
                    o[sname] = {}
                    for fname, ty in pairs(fields) do if ty.k == 'array' then o[sname][fname] = ty.size end end
                end
                return o
            end)()), table.concat(exports, ', ')),
    }, '\n') .. '\n'
    return js, refusals, { functions = order, globals = gnames, messages = errmsg }
end

return M
