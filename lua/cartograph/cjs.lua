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
-- ★ EXACT MODE (opts.exact, CART-1211: a libm function): C's arithmetic as C states it, LP64. A type is
-- { k = 'double' } or { k = 'int', w = 32 | 64, u = true|nil }; a 64-bit value is a BigInt wrapped to 64 bits after
-- every operation, a uint32_t a JS number wrapped by `>>> 0`, a signed 32-bit int a plain JS number (its overflow is
-- undefined behaviour in C, so exact arithmetic within range is the whole contract). Off by default: the lstrmatch
-- recipe's output is byte-identical with it off.
local EXACT_NAMED = {
    uint64_t = { k = 'int', w = 64, u = true }, int64_t = { k = 'int', w = 64 }, uint32_t = { k = 'int', w = 32, u = true },
    int32_t = { k = 'int', w = 32 }, int = { k = 'int', w = 32 }, double = { k = 'double' }, double_t = { k = 'double' },
}

local function field_of(n, name) for c, f in n:iter_children() do if f == name then return c end end end
local function named_kids(n)
    local out = {}
    for c in n:iter_children() do if c:named() and c:type() ~= 'comment' then out[#out + 1] = c end end
    return out
end

function M.emit(sources, opts)
    opts = opts or {}
    local X = opts.exact
    local refusals = {}
    local cur_src
    local function text(n) return vim.treesitter.get_node_text(n, cur_src) end
    local function refuse(n, kind, why)
        refusals[#refusals + 1] = { kind = kind, why = why, line = n and (n:start() + 1) or 0 }
        return ('$crefuse(%q)'):format(kind .. ': ' .. why)
    end

    -- ── the declarations of every source: typedef'd structs, functions, global arrays, enum-carried messages ──────
    local structs, funcs, globals, errmsg = {}, {}, {}, {}
    -- exact mode: typedefs of non-struct types, struct TAGS (`struct pow_log_data {…}`), prototypes (a template's
    -- types), struct-valued globals (a JS object each)
    local typedefs, tags, protos, sglobals = {}, {}, {}, {}
    local trees = {}
    for _, s in ipairs(sources) do
        local tree = vim.treesitter.get_string_parser(s.text, 'c'):parse()[1]
        trees[#trees + 1] = { root = tree:root(), src = s.text, name = s.name }
    end

    local struct_fields -- (defined below; base_type reads a struct's fields in exact mode)
    local params_of -- (defined below, once declarator exists)
    --- a C type from a `type` node (+ qualifiers) -> { k = 'int' | 'char' | 'uchar' | 'struct' | 'void' | 'opaque', name? }
    local function base_type(tn)
        if not tn then return { k = 'int' } end
        local t = tn:type()
        local tx = text(tn)
        if X and (t == 'primitive_type' or t == 'type_identifier') and (EXACT_NAMED[tx] or typedefs[tx]) then
            return EXACT_NAMED[tx] or typedefs[tx]
        end
        if X and t == 'sized_type_specifier' and not tx:find('char') then
            -- `unsigned long int`, `long long`, `unsigned`: LP64 — a `long` is 64 bits
            return { k = 'int', w = tx:find('long') and 64 or 32, u = tx:find('unsigned') and true or nil }
        end
        if X and t == 'primitive_type' and tx == 'float' then return { k = 'float' } end
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
            local ty = { k = 'struct', name = nm and text(nm) or ('anon@' .. tn:start()), node = tn }
            if X then
                -- a struct with a BODY defines its tag (`extern const struct pow_log_data {…} __pow_log_data`); a bare
                -- `struct pow_log_data` reads it back
                if field_of(tn, 'body') then
                    ty.fields = struct_fields(tn)
                    if nm then tags[text(nm)] = ty.fields end
                elseif nm then ty.fields = tags[text(nm)] end
            end
            return ty
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
    --- exact mode: a function's parameter types in order — read in ITS source's text (a prototype from a header)
    function params_of(fdecl)
        local out, saved = {}, cur_src
        cur_src = fdecl.src or cur_src
        for _, pd in ipairs(fdecl.type.params and named_kids(fdecl.type.params) or {}) do
            if pd:type() == 'parameter_declaration' then
                local _, ty = declarator(field_of(pd, 'declarator'), base_type(field_of(pd, 'type')))
                out[#out + 1] = ty
            end
        end
        cur_src = saved
        return out
    end
    function struct_fields(sn)
        local body = field_of(sn, 'body')
        local fields = {}
        local order = X and {} or nil -- exact mode: declaration order, for a POSITIONAL initializer
        for _, fd in ipairs(body and named_kids(body) or {}) do
            if fd:type() == 'field_declaration' then
                local bt = base_type(field_of(fd, 'type'))
                if bt.k == 'struct' and bt.node then bt.fields = struct_fields(bt.node) end
                for c, f in fd:iter_children() do
                    if f == 'declarator' then
                        local nm, ty = declarator(c, bt)
                        if nm then fields[nm] = ty; if order then order[#order + 1] = nm end end
                    end
                end
            end
        end
        if order then fields.__order = order end
        return fields
    end
    for _, tr in ipairs(trees) do
        cur_src = tr.src
        for n in tr.root:iter_children() do
            local t = n:type()
            if t == 'type_definition' then
                local ty, nm = field_of(n, 'type'), field_of(n, 'declarator')
                if ty and ty:type() == 'struct_specifier' and nm then structs[text(nm)] = struct_fields(ty)
                elseif X and ty and nm and nm:type() == 'type_identifier' then typedefs[text(nm)] = base_type(ty) end
            elseif X and t == 'struct_specifier' then
                base_type(n) -- `struct tab { … };` alone: it defines the tag (base_type registers a body's fields)
            elseif t == 'function_definition' then
                local nm, fty = declarator(field_of(n, 'declarator'), base_type(field_of(n, 'type')))
                if nm then funcs[nm] = { node = n, type = fty, src = tr.src, sname = tr.name } end
            elseif t == 'declaration' then
                local bt = base_type(field_of(n, 'type'))
                for c, f in n:iter_children() do
                    if f == 'declarator' and c:type() == 'init_declarator' then
                        local nm, ty = declarator(c, bt)
                        local val = field_of(c, 'value')
                        if nm and ty.k == 'array' and val and val:type() == 'initializer_list' then
                            globals[nm] = { type = ty, init = val, src = tr.src }
                        elseif X and nm and ty.k == 'struct' and val and val:type() == 'initializer_list' then
                            sglobals[nm] = { type = ty, init = val, src = tr.src }
                        end
                    elseif X and f == 'declarator' and c:type() == 'function_declarator' then
                        local nm, ty = declarator(c, bt) -- a prototype: the types a template's call converts to
                        if nm then protos[nm] = { type = ty, src = tr.src } end
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
        -- a TEMPLATED name is not emitted even when C defines it (asuint64's union body: the template IS its meaning)
        if want[name] or not funcs[name] or (opts.templates or {})[name] then return end
        want[name] = true
        cur_src = funcs[name].src
        local q = vim.treesitter.query.parse('c', '(call_expression function: (identifier) @f)')
        -- the callee NAMES first, then the recursion: a callee in another source switches cur_src, and reading the
        -- rest of this body's names through that text read garbage (measured: pow's callees in pow.c were lost once
        -- math_err.c's definitions were visited — a single-source recipe never shows it)
        local callees = {}
        for _, c in q:iter_captures(funcs[name].node, cur_src, 0, -1) do callees[#callees + 1] = text(c) end
        for _, c in ipairs(callees) do visit(c) end
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
    local fused, muldef, mtemps = {}, {}, {} -- exact mode: the compiler's contractions in the current function (below)
    local contract_seen = {} -- every site that resolved (a fused addition, or an explicit fma) — the rest are reported
    local expr, stmt
    local I32 = { k = 'int', w = 32 }
    local function is64(t) return t and t.k == 'int' and t.w == 64 end
    local function isD(t) return t and t.k == 'double' end
    --- C truthiness; exact mode reads the TYPE (a BigInt 0n is truthy to JS's `!== 0`)
    local function T(js, ty)
        if X and is64(ty) then return '(' .. js .. ' !== 0n)' end
        if X and isD(ty) then return '(' .. js .. ' !== 0)' end
        return '$T(' .. js .. ')'
    end
    --- exact mode: the value `js` of C type `from` converted to C type `to` (assignment, argument, cast, operand)
    local function conv(js, from, to)
        if not X or not from or not to then return js end
        if to.k == 'double' then return is64(from) and ('Number(' .. js .. ')') or js end
        if to.k ~= 'int' then return js end
        if to.w == 64 then
            local fn = to.u and 'asUintN' or 'asIntN'
            if is64(from) then return (not from.u) == (not to.u) and js or ('BigInt.%s(64, %s)'):format(fn, js) end
            if isD(from) then return ('BigInt.%s(64, BigInt(Math.trunc(%s)))'):format(fn, js) end
            return to.u and ('BigInt.asUintN(64, BigInt(%s))'):format(js) or ('BigInt(%s)'):format(js)
        end
        if is64(from) then return ('Number(BigInt.%s(32, %s))'):format(to.u and 'asUintN' or 'asIntN', js) end
        if isD(from) then return to.u and ('(Math.trunc(%s) >>> 0)'):format(js) or ('(Math.trunc(%s) | 0)'):format(js) end
        if to.u and not from.u then return '((' .. js .. ') >>> 0)' end
        if not to.u and from.u then return '((' .. js .. ') | 0)' end
        return js
    end
    --- exact mode: the usual arithmetic conversions -> the common type
    local function common(a, b)
        if isD(a) or isD(b) then return { k = 'double' } end
        local a64, b64 = is64(a), is64(b)
        if a64 and b64 then return { k = 'int', w = 64, u = (a.u or b.u) or nil } end
        if a64 then return a end -- a signed 64-bit type holds every 32-bit value, signed or not
        if b64 then return b end
        return { k = 'int', w = 32, u = (a and a.u or b and b.u) or nil }
    end
    --- exact mode: `op` over typed operands -> js, type | nil (not an arithmetic case)
    local function arith(op, ljs, lty, rjs, rty)
        if op == '<<' or op == '>>' then
            local ty = is64(lty) and lty or { k = 'int', w = 32, u = lty and lty.u or nil } -- the PROMOTED LEFT type
            if is64(ty) then
                local r = conv(rjs, rty or I32, { k = 'int', w = 64 })
                if op == '<<' then return ('BigInt.%s(64, %s << %s)'):format(ty.u and 'asUintN' or 'asIntN', ljs, r), ty end
                return ('(%s >> %s)'):format(ljs, r), ty -- a u64 is non-negative: BigInt >> is the logical shift
            end
            if ty.u then return op == '<<' and ('((%s << %s) >>> 0)'):format(ljs, rjs) or ('(%s >>> %s)'):format(ljs, rjs), ty end
            return ('(%s %s %s)'):format(ljs, op, rjs), ty
        end
        local ct = common(lty, rty)
        local a, b = conv(ljs, lty, ct), conv(rjs, rty, ct)
        local CMP = { ['=='] = '===', ['!='] = '!==', ['<'] = '<', ['>'] = '>', ['<='] = '<=', ['>='] = '>=' }
        if CMP[op] then return ('+(%s %s %s)'):format(a, CMP[op], b), I32 end
        if isD(ct) then
            if op == '+' or op == '-' or op == '*' or op == '/' then return ('(%s %s %s)'):format(a, op, b), ct end
            return nil
        end
        if is64(ct) then
            if op == '/' or op == '%' then return ('(%s %s %s)'):format(a, op, b), ct end -- BigInt truncates, as C
            return ('BigInt.%s(64, %s %s %s)'):format(ct.u and 'asUintN' or 'asIntN', a, op, b), ct
        end
        if ct.u then
            if op == '*' then return ('(Math.imul(%s, %s) >>> 0)'):format(a, b), ct end
            if op == '/' then return ('Math.trunc(%s / %s)'):format(a, b), ct end
            if op == '%' then return ('(%s %% %s)'):format(a, b), ct end
            return ('((%s %s %s) >>> 0)'):format(a, op, b), ct
        end
        -- signed 32: overflow is undefined behaviour, so exact JS arithmetic within range is C's; `/` truncates
        if op == '/' then return ('Math.trunc(%s / %s)'):format(a, b), ct end
        return ('(%s %s %s)'):format(a, op, b), ct
    end

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
            if sglobals[nm] then return nm, sglobals[nm].type end
            if funcs[nm] then return nm, funcs[nm].type end
            if nm:match('^LJ_ERR_') then return ('%q'):format(errmsg[nm] or nm), { k = 'errcode' } end
            return refuse(n, 'identifier', 'no declaration for `' .. nm .. '`'), { k = 'int' }
        elseif t == 'string_literal' or t == 'concatenated_string' then
            -- a C string literal as a JS string of the same bytes (only plain text and \n / \t / \\ / \" occur here)
            local parts = {}
            local q = vim.treesitter.query.parse('c', '(string_literal) @s')
            for _, lit in q:iter_captures(n, cur_src, 0, -1) do parts[#parts + 1] = text(lit):sub(2, -2) end
            return '"' .. table.concat(parts) .. '"', { k = 'ptr', to = { k = 'char' } }
        elseif t == 'number_literal' and X then
            -- exact mode: a literal's TYPE is C11's (6.4.4.1, LP64); a floating literal (hex included) is its value, read
            -- by LuaJIT's own reader and printed with 17 digits — an exact round trip
            -- tree-sitter's C grammar takes a leading SIGN into the literal in an initializer (`-0x1p-1`, `-2`): split it
            -- off — the type is the magnitude's, the sign a negation (measured: `-0x1p-1` classed as an integer)
            local sign, raw = text(n):match('^([+-]?)(.*)$')
            local neg = sign == '-'
            local body = raw:gsub('[uUlL]+$', '')
            local suffix = raw:sub(#body + 1):lower()
            local hex = body:match('^0[xX]') ~= nil
            if (hex and body:find('[pP.]')) or (not hex and body:find('[.eE]')) then
                local v = tonumber((body:gsub('[fF]$', '')))
                if not v then return refuse(n, 'literal', 'a floating literal Lua cannot read: ' .. raw), { k = 'double' } end
                return ('%.17g'):format(neg and -v or v), { k = 'double' }
            end
            local octal = not hex and body:match('^0%d')
            local bits
            if hex then
                local d = body:sub(3):gsub('^0+', '')
                -- the leading digit's bit length (1 -> 1, 2..3 -> 2, 4..7 -> 3, 8..f -> 4) + 4 per further digit
                bits = #d == 0 and 0 or ((#d - 1) * 4 + ({ 1, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 4, 4, 4, 4 })[tonumber(d:sub(1, 1), 16)])
            else
                local v = tonumber(octal and body:sub(2) or body, octal and 8 or 10) or 0
                bits = v == 0 and 0 or math.floor(math.log(v, 2)) + 1
            end
            local u, w
            if suffix:find('u') then u = true; w = (suffix:find('l') or bits > 32) and 64 or 32
            elseif suffix:find('l') then w = 64; u = (hex or octal) and bits > 63 or nil
            elseif bits <= 31 then w = 32
            elseif (hex or octal) and bits <= 32 then w = 32; u = true
            elseif bits <= 63 then w = 64
            else w = 64; u = true end
            local js = octal and tostring(tonumber(body:sub(2), 8)) or body
            if w == 64 then js = js .. 'n' end
            local ty = { k = 'int', w = w, u = u }
            if neg then
                -- the negation of the magnitude, in its type (an unsigned one wraps)
                if w == 64 then return ('BigInt.%s(64, -%s)'):format(u and 'asUintN' or 'asIntN', js), ty end
                return u and ('((-%s) >>> 0)'):format(js) or ('(-' .. js .. ')'), ty
            end
            return js, ty
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
                -- exact mode: a pointer to a SCALAR is a one-cell box (an out-parameter: `double_t *tail`)
                if X and ty and ty.k == 'ptr' and (isD(ty.to) or (ty.to.k == 'int' and ty.to.w)) then return js .. '[0]', ty.to end
                return deref(js, ty, n)
            end
            if X and a:type() == 'identifier' and scope[text(a)] and scope[text(a)].box then
                local v = scope[text(a)]
                return v.box, { k = 'ptr', to = v.type }
            end
            return refuse(n, 'address-of', 'taking an address (`&`)'), { k = 'int' }
        elseif t == 'subscript_expression' then
            local ajs, aty = expr(field_of(n, 'argument'))
            local ijs = expr(field_of(n, 'index'))
            local el = aty and (aty.k == 'ptr' and aty.to or aty.k == 'array' and aty.of) or nil
            if el and el.k == 'struct' then return ('%s[%s]'):format(ajs, ijs), el end
            -- exact mode: an array of scalars (a struct global's field) is a JS array; the index a JS number
            if X and el and aty.k == 'array' and (isD(el) or (el.k == 'int' and el.w)) then
                local _, ity = expr(field_of(n, 'index'))
                return ('%s[%s]'):format(ajs, conv(ijs, ity, I32)), el
            end
            return deref(('%s + %s'):format(ajs, ijs), aty, n)
        elseif t == 'field_expression' then
            local ajs, aty = expr(field_of(n, 'argument'))
            local op = text(field_of(n, 'operator'))
            local fname = text(field_of(n, 'field'))
            local sty = op == '->' and aty and aty.k == 'ptr' and aty.to or aty
            local fields = struct_of(sty)
            if not fields or not fields[fname] then return refuse(n, 'field', 'no struct field `' .. fname .. '`'), { k = 'int' } end
            return ('%s.%s'):format(ajs, fname), fields[fname]
        elseif t == 'binary_expression' and X and (fused[n:id()] or muldef[n:id()]) then
            -- a multiply-add the host compiler FUSED: one rounding ($fma), exactly what its FMA instruction computes
            local D = { k = 'double' }
            local md = muldef[n:id()]
            if md then
                -- a product fused into an addition in a LATER statement: its operands kept for it
                local ajs, aty = expr(field_of(n, 'left'))
                local bjs, bty = expr(field_of(n, 'right'))
                return ('(%sa = %s, %sb = %s, %sa * %sb)'):format(md, conv(ajs, aty, D), md, conv(bjs, bty, D), md, md), D
            end
            local f = fused[n:id()]
            local A, B
            if f.var then A, B = f.var .. 'a', f.var .. 'b'
            else
                local ajs, aty = expr(field_of(f.mul, 'left'))
                local bjs, bty = expr(field_of(f.mul, 'right'))
                A, B = conv(ajs, aty, D), conv(bjs, bty, D)
            end
            local cjs_, cty = expr(f.addend)
            local C = conv(cjs_, cty, D)
            if f.sub then
                if f.mul_left then return ('$fma(%s, %s, -(%s))'):format(A, B, C), D end -- a*b - c
                return ('$fma(-(%s), %s, %s)'):format(A, B, C), D                        -- c - a*b
            end
            return ('$fma(%s, %s, %s)'):format(A, B, C), D
        elseif t == 'binary_expression' then
            local op = text(field_of(n, 'operator'))
            local ljs, lty = expr(field_of(n, 'left'))
            local rjs, rty = expr(field_of(n, 'right'))
            local lp = lty and (lty.k == 'ptr' or lty.k == 'array')
            local rp = rty and (rty.k == 'ptr' or rty.k == 'array')
            if op == '&&' or op == '||' then return ('+(%s %s %s)'):format(T(ljs, lty), op, T(rjs, rty)), X and I32 or { k = 'int' } end
            if X and not lp and not rp then
                local js, ty = arith(op, ljs, lty, rjs, rty)
                if js then return js, ty end
                return refuse(n, 'operator', ('the operator %s on %s'):format(op, lty and lty.k or '?')), I32
            end
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
            local js, aty = expr(field_of(n, 'argument'))
            if X then
                -- exact mode: the operand's (promoted) type; a 64-bit / unsigned result wraps
                if op == '!' then return ('+!%s'):format(T(js, aty)), I32 end
                if op == '+' then return js, aty end
                if isD(aty) then
                    if op == '-' then return '(-' .. js .. ')', aty end
                elseif is64(aty) then
                    return ('BigInt.%s(64, %s%s)'):format(aty.u and 'asUintN' or 'asIntN', op, js), aty
                elseif aty and aty.u then
                    return ('((%s%s) >>> 0)'):format(op, js), aty
                elseif op == '-' or op == '~' then
                    return '(' .. op .. js .. ')', I32
                end
                return refuse(n, 'operator', 'the unary operator ' .. op .. ' here'), I32
            end
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
            local rjs, rty = expr(field_of(n, 'right'))
            if ljs:match('^%(H%[') or ljs:match('^H%[') then return refuse(n, 'store', 'a store through a pointer'), lty end
            if X then
                -- exact mode: the value converted to the target's type; `a op= b` is `a = (T)(a op b)`
                if op == '=' then return ('%s = %s'):format(ljs, conv(rjs, rty, lty)), lty end
                local js, ty = arith(op:sub(1, -2), ljs, lty, rjs, rty)
                if not js then return refuse(n, 'operator', 'the compound operator ' .. op), lty end
                return ('%s = %s'):format(ljs, conv(js, ty, lty)), lty
            end
            return ('%s %s %s'):format(ljs, op, rjs), lty
        elseif t == 'conditional_expression' then
            local c, cty = expr(field_of(n, 'condition'))
            local a, aty = expr(field_of(n, 'consequence'))
            local b, bty = expr(field_of(n, 'alternative'))
            if X and aty and bty and (aty.k == 'int' or isD(aty)) and (bty.k == 'int' or isD(bty)) then
                local ct = common(aty, bty) -- both arms in their common type, as C converts them
                return ('(%s ? %s : %s)'):format(T(c, cty), conv(a, aty, ct), conv(b, bty, ct)), ct
            end
            return ('(%s ? %s : %s)'):format(T(c, cty), a, b), aty
        elseif t == 'cast_expression' then
            local td = field_of(n, 'type')
            local bt = base_type(field_of(td, 'type'))
            local _, ty = declarator(field_of(td, 'declarator'), bt)
            local vjs, vty = expr(field_of(n, 'value'))
            if X and (isD(ty) or (ty.k == 'int' and ty.w)) and vty and (isD(vty) or vty.k == 'int') then return conv(vjs, vty, ty), ty end
            if X and ty.k == 'void' then return 'void (' .. vjs .. ')', ty end
            if ty.k == 'ptr' and ty.to.k == 'void' and vjs == '0' then return 'null', ty end
            if ty.k == 'uchar' then return ('((%s) & 255)'):format(vjs), { k = 'int' } end
            if ty.k == 'char' then return ('((%s) << 24 >> 24)'):format(vjs), { k = 'int' } end
            if ty.k == 'int' then return vjs, { k = 'int' } end
            if ty.k == 'ptr' and vty and vty.k == 'ptr' then return vjs, ty end
            return refuse(n, 'cast', 'a cast to ' .. text(td)), ty
        elseif t == 'call_expression' then
            local fn = text(field_of(n, 'function'))
            local args, atys = {}, {}
            for _, a in ipairs(named_kids(field_of(n, 'arguments'))) do
                local js, ty = expr(a)
                args[#args + 1], atys[#atys + 1] = js, ty
            end
            local tpl = (opts.templates or {})[fn]
            -- exact mode: every argument converted to its PARAMETER's type (the definition's, else the prototype's)
            local fdecl = X and (funcs[fn] or protos[fn]) or nil
            local fty = fdecl and fdecl.type
            if fty then
                local ptys = params_of(fdecl)
                for i = 1, #args do if ptys[i] then args[i] = conv(args[i], atys[i], ptys[i]) end end
            end
            if tpl then
                local js = (type(tpl) == 'table' and tpl.js or tpl):gsub('%$(%d)', function (i) return args[tonumber(i)] or 'undefined' end)
                if X then
                    -- its type: declared with the template, else the C function's own, else its first argument's
                    local R = { double = { k = 'double' }, u64 = { k = 'int', w = 64, u = true }, i32 = I32, u32 = { k = 'int', w = 32, u = true } }
                    local rt = type(tpl) == 'table' and tpl.ret
                    return js, (rt == 'arg1' and atys[1]) or R[rt] or (fty and fty.ret) or atys[1] or I32
                end
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
    local boxed, cur_ret = {}, nil -- exact mode: the current function's locals whose address is taken; its return type
    -- exact mode, CONTRACTION (opts.contract = { [source name] = { ['line:col'] = true } }): the multiply-adds the HOST
    -- COMPILER fused (read from its own GIMPLE dump by the recipe — never re-derived by rule here). `fused[id]` marks an
    -- addition: { mul = the `*` node | nil, var = its temps when the product was computed in another statement,
    -- addend = the other operand, sub = '-' , mul_left }; `muldef[id]` marks such a product's own `*` node
    local function strip(nd) while nd and nd:type() == 'parenthesized_expression' do nd = named_kids(nd)[1] end return nd end
    local function is_mul(nd) nd = strip(nd); return nd and nd:type() == 'binary_expression' and text(field_of(nd, 'operator')) == '*' and nd or nil end
    local function contract_prepass(fnode, sites)
        fused, muldef, mtemps = {}, {}, {}
        if not sites then return end
        local r0, _, r1 = fnode:range()
        -- SORTED: the temporaries' numbering follows this order, and a pairs() walk made it hash order
        local keys = vim.tbl_keys(sites)
        table.sort(keys, function (a, b)
            local la, ca = a:match('^(%d+):(%d+)$')
            local lb, cb = b:match('^(%d+):(%d+)$')
            if tonumber(la) ~= tonumber(lb) then return tonumber(la) < tonumber(lb) end
            return tonumber(ca) < tonumber(cb)
        end)
        for _, key in ipairs(keys) do
            local line, col = key:match('^(%d+):(%d+)$')
            local row, c = tonumber(line) - 1, tonumber(col) - 1
            if row >= r0 and row <= r1 then
                local tok = fnode:descendant_for_range(row, c, row, c)
                local add
                if tok and (tok:type() == '+' or tok:type() == '-') then add = tok:parent()
                elseif tok and tok:type() == '=' then
                    local p = tok:parent()
                    add = strip(p:type() == 'assignment_expression' and field_of(p, 'right') or field_of(p, 'value'))
                elseif tok and tok:type() == 'identifier' and tok:parent():type() == 'call_expression' then
                    -- an inlined call whose argument is the addition — or an EXPLICIT fma(), which is already one
                    if text(tok) ~= 'fma' then add = strip(named_kids(field_of(tok:parent(), 'arguments'))[1]) end
                end
                if add and add:type() == 'binary_expression' and (text(field_of(add, 'operator')) == '+' or text(field_of(add, 'operator')) == '-') then
                    local L, R = field_of(add, 'left'), field_of(add, 'right')
                    local ml, mr = is_mul(L), is_mul(R)
                    local rec = { sub = text(field_of(add, 'operator')) == '-' }
                    if ml and mr then refuse(add, 'contract', 'both operands of a fused addition are products (line ' .. line .. ')')
                    elseif ml or mr then rec.mul, rec.addend, rec.mul_left = ml or mr, ml and R or L, ml ~= nil
                    else
                        -- the product was computed in ANOTHER statement: `p = ar3 * (…)` … `lo = … + p`
                        for side, opnd in pairs { left = L, right = R } do
                            local o = strip(opnd)
                            if not rec.var and o:type() == 'identifier' then
                                local v, def = text(o), nil
                                local aq = vim.treesitter.query.parse('c', '(assignment_expression left: (identifier) @l right: (_) @r)')
                                for id, cap in aq:iter_captures(fnode, cur_src, 0, -1) do
                                    if aq.captures[id] == 'r' and text(field_of(cap:parent(), 'left')) == v and cap:start() < add:start() then def = cap end
                                end
                                local dm = def and is_mul(def)
                                if dm then
                                    mtemps[#mtemps + 1] = '$m' .. #mtemps + 1
                                    local tn = mtemps[#mtemps]
                                    muldef[dm:id()] = tn
                                    rec.var, rec.addend, rec.mul_left = tn, side == 'left' and R or L, side == 'left'
                                end
                            end
                        end
                        if not rec.var then refuse(add, 'contract', 'a fused addition with no product operand (line ' .. line .. ')') end
                    end
                    if rec.mul or rec.var then fused[add:id()] = rec; contract_seen[key] = true end
                elseif tok and tok:type() == 'identifier' and text(tok) == 'fma' then
                    contract_seen[key] = true -- an explicit fma(): already one
                else
                    refuse(fnode, 'contract', 'a compiler FMA site that names no addition (line ' .. line .. ':' .. col .. ')')
                end
            end
        end
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
                    local v = c:type() == 'init_declarator' and field_of(c, 'value')
                    -- the name is in scope from the end of its declarator, its initializer included (C's own rule)
                    local box = X and boxed[nm]
                    scope[nm] = box and { js = js .. '[0]', type = ty, box = js } or { js = js, type = ty }
                    local vjs, vty
                    if v then vjs, vty = expr(v) end
                    if box then
                        -- an out-parameter's target: a one-cell box, read and written as box[0]
                        parts[#parts + 1] = js .. ' = [' .. (v and conv(vjs, vty, ty) or '0') .. ']'
                    else
                        parts[#parts + 1] = v and (js .. ' = ' .. (X and conv(vjs, vty, ty) or vjs)) or js
                    end
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
            if e and X then
                local js, ty = expr(e)
                return 'return ' .. conv(js, ty, cur_ret) .. ';'
            end
            return e and ('return ' .. expr(e) .. ';') or 'return;'
        elseif t == 'if_statement' then
            local c, cty = expr(field_of(n, 'condition'))
            local out = 'if (' .. T(c, cty) .. ') ' .. stmt(field_of(n, 'consequence'), ctx)
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
    -- exact mode: every STRUCT global a wanted function reads, as a JS object literal (designated and positional
    -- initializers, each value converted to its field's type)
    local sg_js = {}
    if X then
        local used = {}
        for _, name in ipairs(order) do
            cur_src = funcs[name].src
            for _, c in gq:iter_captures(funcs[name].node, cur_src, 0, -1) do if sglobals[text(c)] then used[text(c)] = true end end
        end
        local function zero(ty)
            if is64(ty) then return '0n' end
            if ty and ty.k == 'array' then return '[]' end
            return '0'
        end
        local init_js
        function init_js(v, ty)
            if ty and ty.k == 'struct' then
                local fields = ty.fields or struct_of(ty) or {}
                local ord = fields.__order or {}
                local vals, pos = {}, 1
                for _, item in ipairs(named_kids(v)) do
                    if item:type() == 'initializer_pair' then
                        local fname = text(field_of(item, 'designator')):gsub('^%.', '')
                        vals[fname] = init_js(field_of(item, 'value'), fields[fname])
                        for i, fnm in ipairs(ord) do if fnm == fname then pos = i + 1 end end
                    else
                        local fname = ord[pos]
                        pos = pos + 1
                        if fname then vals[fname] = init_js(item, fields[fname]) end
                    end
                end
                local parts = {}
                for _, fnm in ipairs(ord) do parts[#parts + 1] = fnm .. ': ' .. (vals[fnm] or zero(fields[fnm])) end
                return '{ ' .. table.concat(parts, ', ') .. ' }'
            elseif ty and ty.k == 'array' then
                local parts = {}
                for _, item in ipairs(named_kids(v)) do parts[#parts + 1] = init_js(item, ty.of) end
                return '[' .. table.concat(parts, ', ') .. ']'
            end
            local js, vty = expr(v)
            return conv(js, vty, ty)
        end
        local names = vim.tbl_keys(used)
        table.sort(names)
        for _, g in ipairs(names) do
            cur_src = sglobals[g].src
            scope = {}
            sg_js[#sg_js + 1] = ('const %s = %s;'):format(g, init_js(sglobals[g].init, sglobals[g].type))
        end
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
        if X then
            -- the locals whose address the body takes (`&lo`): boxed; and the type every `return` converts to
            boxed = {}
            local aq = vim.treesitter.query.parse('c', '(pointer_expression operator: "&" argument: (identifier) @x)')
            for _, c in aq:iter_captures(f.node, cur_src, 0, -1) do boxed[text(c)] = true end
            cur_ret = f.type.ret
            contract_prepass(f.node, (opts.contract or {})[f.sname])
        end
        local body = stmt(field_of(f.node, 'body'), { gotos = {} })
        if X and #mtemps > 0 then
            local d = {}
            for _, tn in ipairs(mtemps) do d[#d + 1] = tn .. 'a, ' .. tn .. 'b' end
            body = body:gsub('^{\n', '{\nlet ' .. table.concat(d, ', ') .. ';\n', 1)
        end
        fns[#fns + 1] = ('function %s(%s) %s'):format(name, table.concat(params, ', '), body)
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
        -- (the struct globals, exact mode only — '' otherwise, so a legacy recipe's output is unchanged)
        table.concat(sg_js, '\n') .. (#sg_js > 0 and '\n' or '') .. table.concat(fns, '\n\n'),
        ('module.exports = { setheap: h => { H = h; }, image, IMAGE_END, STRUCTS: %s, %s };')
            :format((function ()
                -- keys SORTED: a Lua table's pairs order is its hash order, so vim.json.encode made the generated file
                -- differ run to run (measured on lstrmatch.js: same keys, a new order each regeneration)
                local snames = vim.tbl_keys(structs)
                table.sort(snames)
                local out = {}
                for _, sname in ipairs(snames) do
                    local fnames = {}
                    for fname, ty in pairs(structs[sname]) do if type(ty) == 'table' and ty.k == 'array' and ty.size then fnames[#fnames + 1] = fname end end
                    table.sort(fnames)
                    local fs = {}
                    for _, fname in ipairs(fnames) do fs[#fs + 1] = vim.json.encode(fname) .. ':' .. vim.json.encode(structs[sname][fname].size) end
                    out[#out + 1] = vim.json.encode(sname) .. ':' .. (#fs > 0 and ('{' .. table.concat(fs, ',') .. '}') or '[]')
                end
                return '{' .. table.concat(out, ',') .. '}'
            end)(), table.concat(exports, ', ')),
    }, '\n') .. '\n'
    -- the contraction sites that resolved to NOTHING in an emitted function (outside every wanted function, or no
    -- addition there): the caller must fail on them — a lost contraction is a silent last-bit difference
    local unresolved = {}
    for _, sites in pairs(opts.contract or {}) do
        for key in pairs(sites) do if not contract_seen[key] then unresolved[#unresolved + 1] = key end end
    end
    table.sort(unresolved)
    return js, refusals, { functions = order, globals = gnames, messages = errmsg, unresolved_sites = unresolved }
end

return M
