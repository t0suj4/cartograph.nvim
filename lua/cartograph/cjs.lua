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
local tsutil = require 'cartograph.spec.tsutil' -- (tsutil.inext: indexed child iteration, CART-1453)
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
    for _, c in tsutil.inext, n, -1 do if c:named() and c:type() ~= 'comment' then out[#out + 1] = c end end
    return out
end

function M.emit(sources, opts)
    opts = opts or {}
    local X = opts.exact
    local refusals = {}
    local cur_src
    local function text(n) return vim.treesitter.get_node_text(n, cur_src) end
    local cur_fn -- the function being emitted: every refusal names it (a boundary probe attributes refusals by function)
    local function refuse(n, kind, why)
        refusals[#refusals + 1] = { kind = kind, why = why, line = n and (n:start() + 1) or 0, fn = cur_fn }
        return ('$crefuse(%q)'):format(kind .. ': ' .. why)
    end

    -- ── the declarations of every source: typedef'd structs, functions, global arrays, enum-carried messages ──────
    local structs, funcs, globals, errmsg = {}, {}, {}, {}
    -- exact mode: typedefs of non-struct types, struct TAGS (`struct pow_log_data {…}`), prototypes (a template's
    -- types), struct-valued globals (a JS object each)
    local typedefs, tags, protos, sglobals = {}, {}, {}, {}
    -- exact mode, HEAP LAYOUTS (opts.heap.types = { [type name] = { size, fields = { [f] = { off, cls } } } }): a struct
    -- or union named there lives in the BYTE HEAP — its layout the HOST COMPILER's (sizeof/offsetof printed by a C
    -- program the recipe builds with the build's flags), never re-derived here; a field is a typed load/store at
    -- base + off (cls: f64 u64 i64 u32 i32 u16 i16 u8 i8), so a union's punning is exact by construction
    local HEAP = X and opts.heap and opts.heap.types or {}
    -- exact mode: every enumerator's VALUE (explicit, or the previous + 1 — C's own rule)
    local enums = {}
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
            -- a SHORT is 16 bits of storage (`sw`) whose value promotes to a signed int: its unsignedness is the
            -- storage's (`su`: the load zero-extends, a store masks), never the arithmetic's
            if tx:find('short') then return { k = 'int', w = 32, sw = 16, su = tx:find('unsigned') and true or nil } end
            return { k = 'int', w = tx:find('long') and 64 or 32, u = tx:find('unsigned') and true or nil }
        end
        if X and t == 'primitive_type' and tx == 'float' then return { k = 'float' } end
        if X and t == 'enum_specifier' then
            -- an enum is an int; its body's enumerators get their values (C's rule: explicit, else previous + 1)
            -- a value that is not a plain literal (`A = 1 << 3`, `B = A + 1`) is NOT guessed: it and the implicit ones
            -- after it stay unknown, so a use refuses by name instead of reading a wrong number
            local body, nextv = field_of(tn, 'body'), 0
            for _, en in ipairs(body and named_kids(body) or {}) do
                if en:type() == 'enumerator' then
                    local v = field_of(en, 'value')
                    if v then nextv = tonumber((text(v):gsub('[uUlL]+$', ''))) end -- (one value: gsub's count is no base)
                    if nextv then enums[text(field_of(en, 'name'))] = nextv; nextv = nextv + 1 end
                end
            end
            return { k = 'int', w = 32 }
        end
        if X and t == 'union_specifier' then
            local nm = field_of(tn, 'name')
            local ty = { k = 'struct', name = nm and text(nm) or ('anon@' .. tn:start()), union = true, node = tn }
            if field_of(tn, 'body') then ty.fields = struct_fields(tn); if nm then tags[text(nm)] = ty.fields end
            elseif nm then ty.fields = tags[text(nm)] end
            return ty
        end
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
                ty = { k = 'array', of = ty, size = sz and tonumber(text(sz)), size_node = sz }
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
        for _, n in tsutil.inext, tr.root, -1 do
            local t = n:type()
            if t == 'type_definition' then
                local ty, nm = field_of(n, 'type'), field_of(n, 'declarator')
                if ty and ty:type() == 'struct_specifier' and nm then structs[text(nm)] = struct_fields(ty)
                elseif X and ty and ty:type() == 'union_specifier' and nm and nm:type() == 'type_identifier' then
                    -- `typedef union TValue {…} TValue;` — a union is a struct whose fields share offset 0 (its heap layout
                    -- says where each one really is)
                    structs[text(nm)] = struct_fields(ty)
                    base_type(ty)
                -- (the stdint names parse as PRIMITIVE types, declarator included: `typedef __int16_t int16_t;` —
                -- recorded too, so an int16_t is the 16-bit type the source says, not a plain int)
                elseif X and ty and nm and (nm:type() == 'type_identifier' or nm:type() == 'primitive_type') then typedefs[text(nm)] = base_type(ty) end
            elseif X and (t == 'struct_specifier' or t == 'union_specifier' or t == 'enum_specifier') then
                base_type(n) -- `struct tab { … };` / `enum { A, B };` alone: a tag, or enumerator values
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
    --- opts.opaque = { [struct tag] = true }: types the emitted code may hold only as ADDRESSES — a boundary probe names
    --- the VM's own objects here (a field read, a cast to one, arithmetic over one, a value of one is REFUSED as kind
    --- 'boundary', naming the type) -> the opaque type's name | nil
    local function opaq(ty)
        while ty and (ty.k == 'ptr' or ty.k == 'array') do ty = ty.to or ty.of end
        return ty and ty.k == 'struct' and opts.opaque and opts.opaque[ty.name] and ty.name or nil
    end

    -- ── reachability from the roots: only what the roots call is emitted ─────────────────────────────────────────
    local want, order, calls = {}, {}, {} -- (calls: each emitted function's callee NAMES, in source order — info.calls)
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
        calls[name] = callees
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
    local base, image_js, gbase, wide_image = 1, {}, {}, false
    local gnames = {}
    for g in pairs(used_globals) do gnames[#gnames + 1] = g end
    table.sort(gnames)

    local scope -- name -> { js, type }
    local fused, muldef, mtemps = {}, {}, {} -- exact mode: the compiler's contractions in the current function (below)
    local contract_seen = {} -- every site that resolved (a fused addition, or an explicit fma) — the rest are reported
    local expr, stmt
    local I32 = { k = 'int', w = 32 }
    -- exact mode, HEAP fields: the layout of a heap-resident struct/union type, and a field's typed load / store
    local HCLS = {
        f64 = { get = 'getFloat64', set = 'setFloat64', ty = { k = 'double' } },
        u64 = { get = 'getBigUint64', set = 'setBigUint64', ty = { k = 'int', w = 64, u = true } },
        i64 = { get = 'getBigInt64', set = 'setBigInt64', ty = { k = 'int', w = 64 } },
        u32 = { get = 'getUint32', set = 'setUint32', ty = { k = 'int', w = 32, u = true } },
        i32 = { get = 'getInt32', set = 'setInt32', ty = { k = 'int', w = 32 } },
        u16 = { get = 'getUint16', set = 'setUint16', ty = { k = 'int', w = 32 } },
        i16 = { get = 'getInt16', set = 'setInt16', ty = { k = 'int', w = 32 } },
        u8 = { get = 'getUint8', set = 'setUint8', ty = { k = 'int', w = 32 } },
        i8 = { get = 'getInt8', set = 'setInt8', ty = { k = 'int', w = 32 } },
    }
    local function heap_layout(ty) return X and ty and ty.k == 'struct' and (ty.hlayout or HEAP[ty.name]) or nil end
    --- a heap field at address js `addr` -> load js, its type (carrying `hstore`: the store of a value js). `prefix`:
    --- the member path so far (`u32.` of `t.u32.hi`) — the layout's offsets are from the TYPE's start, so the address
    --- stays the outer one and only the path grows
    local function heap_field(addr, layout, fname, n, prefix)
        local key = (prefix or '') .. fname
        local f = layout.fields[key]
        local c = f and HCLS[f.cls]
        if not c then
            -- a NAMED nested struct/union member: not a value, a path into the same object
            for k in pairs(layout.fields) do
                if k:sub(1, #key + 1) == key .. '.' then return addr, { k = 'struct', hlayout = layout, hpath = key .. '.' } end
            end
            return refuse(n, 'field', 'no scalar heap field `' .. key .. '` in the layout'), I32
        end
        local a = ('(%s + %d)'):format(addr, f.off)
        local ty = vim.deepcopy(c.ty)
        ty.hstore = function (v) return ('DV.%s(%s, %s, true)'):format(c.set, a, v) end
        return ('DV.%s(%s, true)'):format(c.get, a), ty
    end
    local function is64(t) return t and t.k == 'int' and t.w == 64 end
    local function isD(t) return t and t.k == 'double' end
    -- exact heap mode, a SCALAR in the heap: its class (HCLS) by storage width (`sw`: a short is 16 bits, stored; its
    -- value is promoted to int) and its byte width
    local CW = { f64 = 8, u64 = 8, i64 = 8, u32 = 4, i32 = 4, u16 = 2, i16 = 2, u8 = 1, i8 = 1 }
    local function elcls(el)
        if not el then return nil end
        if isD(el) then return 'f64' end
        if el.k == 'char' then return 'i8' end
        if el.k == 'uchar' then return 'u8' end
        if el.k == 'int' and el.w then return ((el.u or el.su) and 'u' or 'i') .. (el.sw or el.w) end
    end
    --- the byte width of a WIDE heap element (> 1 byte: bytes keep their H[...] forms) | nil
    local function wide(el) local w = X and opts.heap and CW[elcls(el) or ''] return w and w > 1 and w or nil end
    --- the STEP of pointer arithmetic over `el` in exact heap mode: a wide scalar's width, or a heap-laid struct's size
    --- (the compiler's sizeof) | nil
    local function step(el) local hl = X and opts.heap and heap_layout(el) return (hl and hl.size) or wide(el) end
    --- an element INDEX as a JS number, its value kept (a 64-bit one Number()'d; a uint32 above 2^31 must not wrap
    --- negative, as a conversion to int would)
    local function index(ijs, ity) return is64(ity) and ('Number(' .. ijs .. ')') or ('(' .. ijs .. ')') end
    --- a typed load of the heap scalar at address js `addr` (its type carries `hstore`, as a heap field's does)
    local function hderef(addr, el)
        local c = HCLS[elcls(el)]
        local ty = vim.deepcopy(c.ty)
        ty.hstore = function (v) return ('DV.%s(%s, %s, true)'):format(c.set, addr, v) end
        return ('DV.%s(%s, true)'):format(c.get, addr), ty
    end
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
        if to.sw == 16 then
            -- a short: the value as an int, then wrapped to 16 bits (zero- or sign-extended back, as C's conversion)
            local j = conv(js, from, I32)
            return to.su and ('((%s) & 65535)'):format(j) or ('((%s) << 16 >> 16)'):format(j)
        end
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
        if opaq(el) then return refuse(n, 'boundary', ('a dereference of the VM object `%s`'):format(opaq(el))), { k = 'int' } end
        if wide(el) then return hderef('(' .. ptrjs .. ')', el) end
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
            if X and enums[nm] then return tostring(enums[nm]), I32 end -- an enumerator: its value
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
                -- exact mode: a pointer to a SCALAR is a one-cell box (an out-parameter: `double_t *tail`); in HEAP mode
                -- only a pointer known to be one (`&local`) — every other scalar pointer is a heap address
                if X and ty and ty.k == 'ptr' and (isD(ty.to) or (ty.to.k == 'int' and ty.to.w)) and (not opts.heap or ty.box) then return js .. '[0]', ty.to end
                return deref(js, ty, n)
            end
            if X and a:type() == 'identifier' and scope[text(a)] and scope[text(a)].box then
                local v = scope[text(a)]
                return v.box, { k = 'ptr', to = v.type, box = true }
            end
            -- a HEAP local (a struct/union or an array placed on the heap stack): its js IS its address
            if X and a:type() == 'identifier' and scope[text(a)] and scope[text(a)].heap then
                local v = scope[text(a)]
                return v.js, { k = 'ptr', to = v.type.k == 'array' and v.type.of or v.type }
            end
            return refuse(n, 'address-of', 'taking an address (`&`)'), { k = 'int' }
        elseif t == 'subscript_expression' then
            local ajs, aty = expr(field_of(n, 'argument'))
            local ijs, ity = expr(field_of(n, 'index'))
            local el = aty and (aty.k == 'ptr' and aty.to or aty.k == 'array' and aty.of) or nil
            -- exact heap mode: an element of a heap-laid struct array IS its address (field reads go through it)
            if X and opts.heap and heap_layout(el) then return ('(%s + %s * %d)'):format(ajs, index(ijs, ity), step(el)), el end
            if el and el.k == 'struct' then return ('%s[%s]'):format(ajs, ijs), el end
            -- exact mode: an array of scalars (a struct global's field) is a JS array; the index a JS number
            if X and el and aty.k == 'array' and not aty.heap and (isD(el) or (el.k == 'int' and el.w)) then
                return ('%s[%s]'):format(ajs, conv(ijs, ity, I32)), el
            end
            -- exact heap mode: a wide element's address is base + index * its width
            if wide(el) then return deref(('%s + %s * %d'):format(ajs, index(ijs, ity), wide(el)), aty, n) end
            return deref(('%s + %s'):format(ajs, ijs), aty, n)
        elseif t == 'field_expression' then
            local ajs, aty = expr(field_of(n, 'argument'))
            local op = text(field_of(n, 'operator'))
            local fname = text(field_of(n, 'field'))
            local sty = op == '->' and aty and aty.k == 'ptr' and aty.to or aty
            if opaq(sty) then return refuse(n, 'boundary', ('a field (%s) of the VM object `%s`'):format(fname, opaq(sty))), I32 end
            -- exact mode: a HEAP struct/union — `p->f` (p an address) and `x.f` (a heap local IS its address) alike
            local hl = heap_layout(sty)
            if hl then return heap_field(ajs, hl, fname, n, sty.hpath) end
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
                if lp and rp and op == '-' then
                    local w = step(lty.k == 'ptr' and lty.to or lty.of)
                    if w then return ('((%s - %s) / %d)'):format(ljs, rjs, w), I32 end
                    return ('(%s - %s)'):format(ljs, rjs), { k = 'int' }
                end
                local pty = lp and lty or rp and rty
                if pty then
                    local el = pty.k == 'ptr' and pty.to or pty.of
                    if opaq(el) then return refuse(n, 'boundary', ('arithmetic over the VM object `%s`'):format(opaq(el))), pty end
                    local w = step(el)
                    if w then
                        -- exact heap mode: p + i is the address i ELEMENTS on (`i + p` too; `p - i` back)
                        local pjs, ijs, ity = lp and ljs or rjs, lp and rjs or ljs, lp and rty or lty
                        return ('(%s %s %s * %d)'):format(pjs, op, index(ijs, ity), w), { k = 'ptr', to = el }
                    end
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
            local prefix = n:child(0):type() == op
            if ty and ty.k == 'ptr' and step(ty.to) then
                -- exact heap mode: one ELEMENT on; a postfix form's value is the old address
                local w, o = step(ty.to), op == '++' and '+' or '-'
                if prefix then return ('(%s %s= %d)'):format(js, o, w), ty end
                return ('((%s %s= %d) %s %d)'):format(js, o, w, o == '+' and '-' or '+', w), ty
            end
            if ty and ty.k == 'ptr' and ty.to.k ~= 'char' and ty.to.k ~= 'uchar' then return refuse(n, 'pointer-arith', '++/-- on a pointer to ' .. ty.to.k), ty end
            return prefix and (op .. js) or (js .. op), ty
        elseif t == 'assignment_expression' then
            local op = text(field_of(n, 'operator'))
            local l = field_of(n, 'left')
            local ljs, lty = expr(l)
            local rjs, rty = expr(field_of(n, 'right'))
            if (op == '+=' or op == '-=') and lty and lty.k == 'ptr' and step(lty.to) then
                -- exact heap mode: `p += i` moves i ELEMENTS
                return ('%s %s %s * %d'):format(ljs, op, index(rjs, rty), step(lty.to)), lty
            end
            if X and lty and lty.hstore then
                -- a HEAP field: a typed store (`a op= b` is `a = (T)(a op b)`, the load read once more)
                if op == '=' then return lty.hstore(conv(rjs, rty, lty)), lty end
                local js, ty = arith(op:sub(1, -2), ljs, lty, rjs, rty)
                if not js then return refuse(n, 'operator', 'the compound operator ' .. op), lty end
                return lty.hstore(conv(js, ty, lty)), lty
            end
            if X and opts.heap and (ljs:match('^%(H%[') or ljs:match('^H%[')) then
                -- exact heap mode: a byte store through a pointer (the Uint8Array truncates mod 256, as C's conversion
                -- to an unsigned char does); a signed char's sign-extending read form is not a place, so its H[...] is
                local place = ljs:match('^%(H%[(.*)%] << 24 >> 24%)$') or ljs:match('^H%[(.*)%]$')
                if not place then return refuse(n, 'store', 'a store through a pointer of this shape'), lty end
                local v = op == '=' and conv(rjs, rty, I32) or (select(1, arith(op:sub(1, -2), ljs, I32, rjs, rty)))
                return ('H[%s] = %s'):format(place, v), I32
            end
            if ljs:match('^%(H%[') or ljs:match('^H%[') then return refuse(n, 'store', 'a store through a pointer'), lty end
            if X then
                -- exact mode: the value converted to the target's type; `a op= b` is `a = (T)(a op b)`
                if op == '=' then return ('%s = %s'):format(ljs, conv(rjs, rty, lty)), lty end
                local js, ty = arith(op:sub(1, -2), ljs, lty, rjs, rty)
                if not js then return refuse(n, 'operator', 'the compound operator ' .. op), lty end
                return ('%s = %s'):format(ljs, conv(js, ty, lty)), lty
            end
            return ('%s %s %s'):format(ljs, op, rjs), lty
        elseif X and t == 'comma_expression' then
            -- C's comma operator IS JavaScript's: the left for its effects, the value and type the right's
            local ljs = expr(field_of(n, 'left'))
            local rjs, rty = expr(field_of(n, 'right'))
            return ('(%s, %s)'):format(ljs, rjs), rty
        elseif X and t == 'sizeof_expression' then
            -- sizeof(<type>): the COMPILER's answer (opts.sizes, printed by a program the recipe builds) — a size_t,
            -- unsigned 64-bit on LP64; anything the table lacks is refused, never guessed
            local td = field_of(n, 'type')
            local key = td and vim.trim(text(td))
            local v = key and (opts.sizes or {})[key]
            if not v then return refuse(n, 'sizeof', 'no compiler size for `' .. tostring(key or text(n)) .. '`'), I32 end
            return tostring(v) .. 'n', { k = 'int', w = 64, u = true }
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
            if opaq(ty) then return refuse(n, 'boundary', ('a cast to the VM object `%s`'):format(opaq(ty))), ty end
            if X and (isD(ty) or (ty.k == 'int' and ty.w)) and vty and (isD(vty) or vty.k == 'int') then return conv(vjs, vty, ty), ty end
            if X and ty.k == 'void' then return 'void (' .. vjs .. ')', ty end
            if ty.k == 'ptr' and ty.to.k == 'void' and vjs == '0' then return 'null', ty end
            if ty.k == 'uchar' then return ('((%s) & 255)'):format(vjs), { k = 'int' } end
            if ty.k == 'char' then return ('((%s) << 24 >> 24)'):format(vjs), { k = 'int' } end
            if ty.k == 'int' then return vjs, { k = 'int' } end
            if ty.k == 'ptr' and vty and vty.k == 'ptr' then return vjs, ty end
            -- exact heap mode: a heap array's value IS its address — reinterpreting it is an address kept (the loads
            -- through the new pointer read the element width they name)
            if X and opts.heap and ty.k == 'ptr' and vty and vty.k == 'array' and vty.heap then return vjs, ty end
            return refuse(n, 'cast', 'a cast to ' .. text(td)), ty
        elseif t == 'call_expression' then
            -- `(T)(x)` with T a TYPEDEF is a CAST the grammar cannot see (it does not know typedef names, so it reads a
            -- call of a parenthesized identifier — TSGAP): a known type name in the callee's parentheses decides it
            local callee = field_of(n, 'function')
            if X and callee:type() == 'parenthesized_expression' and callee:named_child_count() == 1
                and callee:named_child(0):type() == 'identifier' then
                local tn = text(callee:named_child(0))
                local cty = EXACT_NAMED[tn] or typedefs[tn]
                local cargs = named_kids(field_of(n, 'arguments'))
                if cty and #cargs == 1 then
                    local vjs, vty = expr(cargs[1])
                    if (isD(cty) or (cty.k == 'int' and cty.w)) and vty and (isD(vty) or vty.k == 'int') then return conv(vjs, vty, cty), cty end
                    return refuse(n, 'cast', 'a cast to the typedef ' .. tn .. ' of this operand'), cty
                end
            end
            local fn = text(field_of(n, 'function'))
            local args, atys = {}, {}
            for _, a in ipairs(named_kids(field_of(n, 'arguments'))) do
                local js, ty = expr(a)
                -- heap mode: the callee reads a scalar pointer as a HEAP address — a box passed there would read address 0
                if X and opts.heap and ty and ty.box then return refuse(a, 'address-of', 'a boxed local passed as a pointer in heap mode'), I32 end
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
    local allocas = false -- exact heap mode: the current function places a local on the heap stack
    --- the byte size of a heap-stack local: a heap struct/union (its layout's size), or an array of scalars — bytes
    --- (char / uint8_t), else a heap-layout scalar class by width (1, 4, 8) -> js size expression | nil
    local function heap_local_size(ty)
        local hl = heap_layout(ty)
        if hl then return tostring(hl.size) end
        if ty and ty.k == 'array' and ty.size_node then
            local el = ty.of
            local w = (el.k == 'uchar' or el.k == 'char') and 1 or (isD(el) and 8) or (el.k == 'int' and el.w and (el.sw or el.w) / 8) or nil
            if not w then return nil end
            local sjs = expr(ty.size_node)
            return ('(Math.trunc(%s) * %d)'):format(sjs, w)
        end
        return nil
    end
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
    --- a declaration -> `let …;`. With `hoist` (the goto-lowered form, below): every name is added to hoist.names
    --- (declared once at the function's top), a heap-stack local's $alloca to hoist.entry (made once, at entry — a
    --- re-entered block must not allocate again), and only the INITIALIZATIONS are returned, as assignments in place
    local function declaration(n, hoist)
        local bt = base_type(field_of(n, 'type'))
        local parts = {}
        for c, f in n:iter_children() do
            if f == 'declarator' then
                local nm, ty = declarator(c, bt)
                if nm then
                    local js = JS_RESERVED[nm] and (nm .. '$') or nm
                    -- hoisted, a name declared again (a sibling or inner block's own) gets its own variable: `d$2`
                    -- (the dispatch form restores the scope at each block's end, so the outer name comes back)
                    if hoist and hoist.seen[js] then
                        local k = 2
                        while hoist.seen[js .. '$' .. k] do k = k + 1 end
                        js = js .. '$' .. k
                    end
                    local hsize = X and opts.heap and (ty.k == 'struct' or ty.k == 'array') and heap_local_size(ty) or nil
                    if hsize then
                        -- a HEAP-STACK local: its js is its address (freed when the function returns)
                        allocas = true
                        scope[nm] = { js = js, type = vim.tbl_extend('force', {}, ty, { heap = true }), heap = true }
                        if hoist then
                            if not (hsize:match('^%d+$') or hsize:match('^%(Math%.trunc%([%d.]+%) %* %d+%)$')) then
                                return refuse(n, 'goto-lowering', 'a heap local of run-time size in a goto-lowered function')
                            end
                            hoist.seen[js] = true
                            hoist.names[#hoist.names + 1] = js
                            hoist.entry[#hoist.entry + 1] = ('%s = $alloca(%s);'):format(js, hsize)
                        else
                            parts[#parts + 1] = ('%s = $alloca(%s)'):format(js, hsize)
                        end
                        goto next_declarator
                    end
                    if ty.k == 'struct' and opaq(ty) then return refuse(n, 'boundary', ('a local VM object `%s` (a value, not an address)'):format(opaq(ty))), nil end
                    if ty.k == 'struct' then return refuse(n, 'local-struct', 'a struct value as a local'), nil end
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
                    if hoist then
                        hoist.seen[js] = true
                        hoist.names[#hoist.names + 1] = js
                    end
                end
            end
            ::next_declarator::
        end
        if hoist then
            local inits = vim.tbl_filter(function (p) return p:find(' = ', 1, true) ~= nil end, parts)
            return #inits > 0 and (table.concat(inits, '; ') .. ';') or ''
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
            for _, c in tsutil.inext, n, -1 do if c:named() and c:type() ~= 'statement_identifier' then body = c end end
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
            for _, c in tsutil.inext, hoist.node, -1 do if c:named() and c:type() ~= 'statement_identifier' then inner = c end end
            local hb = '$blk' .. swcount
            -- the hoisted body is the labeled statement AND every statement after it in its case: a C label names ONE
            -- statement, the rest of the case are its siblings (measured: `default: plainnumber: if (…) break; n = …;
            -- o->n = n; return fmt;` hoisted only the `if`, and every number took the slow path)
            local parts = { stmt(inner, { gotos = g, brk = hb }) }
            local after = false
            for _, k in ipairs(named_kids(hoist.case)) do
                if after then parts[#parts + 1] = stmt(k, { gotos = g, brk = hb }) end
                if k == hoist.node then after = true end
            end
            return ('{ let %s = false;\n%s\nif (%s) %s: {\n%s\n} }'):format(flag, sjs, flag, hb, table.concat(parts, '\n'))
        end
        return refuse(n, t, 'no form for this C statement kind') .. ';'
    end

    --- THE GOTO FALLBACK: a function body whose gotos the structured forms above cannot express (into a sibling block,
    --- backward into an earlier one, out of an if-chain to a shared tail) lowered to a LABEL-DISPATCH loop — every
    --- statement flattened into numbered blocks of `$d: for (;;) switch ($L)`, each C transfer of control (a goto, an
    --- if's branches, a loop's test and back edge, break, continue, a switch's cases) a `{ $L = n; continue $d; }`.
    --- No JS loop or switch survives inside it, so no JS break/continue can mean the wrong construct. Locals are hoisted
    --- to the function's top (declaration's hoist mode), heap-stack locals allocated once at entry.
    local function dispatch(body)
        local out, nlab = {}, 0
        local hoist = { names = {}, seen = {}, entry = {} }
        local user = {}
        local function newlab() nlab = nlab + 1; return nlab end
        local function jump(l) return ('{ $L = %d; continue $d; }'):format(l) end
        local function emit(s) out[#out + 1] = s end
        local function place(l) emit(('case %d:'):format(l)) end
        local lq = vim.treesitter.query.parse('c', '(labeled_statement label: (statement_identifier) @l)')
        for _, c in lq:iter_captures(body, cur_src, 0, -1) do user[text(c)] = newlab() end
        local lower
        -- C's BLOCK SCOPE: a block's declarations end with it (the flat scope map is saved and restored around it)
        local function scoped(f)
            local saved = {}
            for k, v in pairs(scope) do saved[k] = v end
            f()
            scope = saved
        end
        local function cjump(cond_node, negate, l)
            local c, cty = expr(cond_node)
            emit(('if (%s%s) %s'):format(negate and '!' or '', T(c, cty), jump(l)))
        end
        function lower(n, cx)
            local t = n:type()
            if t == 'compound_statement' then
                scoped(function () for _, k in ipairs(named_kids(n)) do lower(k, cx) end end)
            elseif (t == 'for_statement' or t == 'switch_statement') and cx.scoped ~= n then
                -- (a for's own declaration, a switch body's, end with the statement)
                scoped(function () lower(n, vim.tbl_extend('force', cx, { scoped = n })) end)
            elseif t == 'declaration' then
                local js = declaration(n, hoist)
                if js ~= '' then emit(js) end
            elseif t == 'expression_statement' or t == 'return_statement' then
                emit(stmt(n, {}))
            elseif t == 'if_statement' then
                local lelse, lend = newlab(), newlab()
                cjump(field_of(n, 'condition'), true, lelse)
                lower(field_of(n, 'consequence'), cx)
                local alt = field_of(n, 'alternative')
                if alt then emit(jump(lend)) end
                place(lelse)
                if alt then lower(alt:type() == 'else_clause' and named_kids(alt)[1] or alt, cx) end
                place(lend)
            elseif t == 'while_statement' then
                local top, lend = newlab(), newlab()
                place(top)
                cjump(field_of(n, 'condition'), true, lend)
                lower(field_of(n, 'body'), { brk = lend, cont = top })
                emit(jump(top))
                place(lend)
            elseif t == 'do_statement' then
                local top, lc, lend = newlab(), newlab(), newlab()
                place(top)
                lower(field_of(n, 'body'), { brk = lend, cont = lc })
                place(lc)
                cjump(field_of(n, 'condition'), false, top)
                place(lend)
            elseif t == 'for_statement' then
                local init, cond, upd = field_of(n, 'initializer'), field_of(n, 'condition'), field_of(n, 'update')
                if init then
                    if init:type() == 'declaration' then local js = declaration(init, hoist); if js ~= '' then emit(js) end
                    else emit(expr(init) .. ';') end
                end
                local top, lc, lend = newlab(), newlab(), newlab()
                place(top)
                if cond then cjump(cond, true, lend) end
                lower(field_of(n, 'body'), { brk = lend, cont = lc })
                place(lc)
                if upd then emit(expr(upd) .. ';') end
                emit(jump(top))
                place(lend)
            elseif t == 'break_statement' then
                emit(cx.brk and jump(cx.brk) or (refuse(n, 'goto-lowering', 'a break outside a loop or switch') .. ';'))
            elseif t == 'continue_statement' then
                emit(cx.cont and jump(cx.cont) or (refuse(n, 'goto-lowering', 'a continue outside a loop') .. ';'))
            elseif t == 'goto_statement' then
                local label = text(field_of(n, 'label'))
                emit(user[label] and jump(user[label]) or (refuse(n, 'goto', 'a goto to no label of this function (`' .. label .. '`)') .. ';'))
            elseif t == 'labeled_statement' then
                place(user[text(field_of(n, 'label'))])
                for _, c in tsutil.inext, n, -1 do if c:named() and c:type() ~= 'statement_identifier' then lower(c, cx) end end
            elseif t == 'switch_statement' then
                local sv = '$s' .. newlab()
                hoist.names[#hoist.names + 1] = sv
                local cjs, cty = expr(field_of(n, 'condition'))
                emit(('%s = %s;'):format(sv, cjs))
                local lend, deflab, cases = newlab(), nil, {}
                for _, cs in ipairs(named_kids(field_of(n, 'body'))) do
                    if cs:type() == 'case_statement' then
                        local l, v = newlab(), field_of(cs, 'value')
                        cases[#cases + 1] = { l = l, node = cs, v = v }
                        if v then
                            local vjs, vty = expr(v)
                            emit(('if (%s === %s) %s'):format(sv, conv(vjs, vty, cty), jump(l)))
                        else deflab = l end
                    end
                end
                emit(jump(deflab or lend))
                for _, c in ipairs(cases) do
                    place(c.l)
                    for _, k in ipairs(named_kids(c.node)) do if k ~= c.v then lower(k, { brk = lend, cont = cx.cont }) end end
                end
                place(lend)
            else
                emit(refuse(n, t, 'no form for this C statement kind in a goto-lowered function') .. ';')
            end
        end
        lower(body, {})
        local head = { '{' }
        if #hoist.names > 0 then head[#head + 1] = 'let ' .. table.concat(hoist.names, ', ') .. ';' end
        vim.list_extend(head, hoist.entry)
        vim.list_extend(head, { 'let $L = 0;', '$d: for (;;) switch ($L) {', 'case 0:' })
        vim.list_extend(head, out)
        vim.list_extend(head, { 'return;', '}', '}' })
        return table.concat(head, '\n')
    end

    -- ── emit: the heap image, then every reachable function ──────────────────────────────────────────────────────
    for _, g in ipairs(gnames) do
        local gl = globals[g]
        cur_src = gl.src
        scope = {}
        gbase[g] = base
        local vals = {}
        local el = gl.type.of
        local w = wide(el)
        if w then
            -- exact heap mode: a WIDE element array — each value converted to the element's type, stored by the
            -- DataView at its class (the third field), the array 8-aligned
            base = math.ceil(base / 8) * 8
            gbase[g] = base
            local c = HCLS[elcls(el)]
            for _, v in ipairs(named_kids(gl.init)) do local vjs, vty = expr(v); vals[#vals + 1] = conv(vjs, vty, c.ty) end
            local count = gl.type.size or #vals
            image_js[#image_js + 1] = ('  // %s[%d] at %d\n  [%d, [%s], %q],'):format(g, count, base, base, table.concat(vals, ', '), c.set)
            base = base + count * w
            wide_image = true
        else
            for _, v in ipairs(named_kids(gl.init)) do vals[#vals + 1] = (expr(v)) end
            image_js[#image_js + 1] = ('  // %s[%d] at %d\n  [%d, [%s]],'):format(g, gl.type.size or #vals, base, base, table.concat(vals, ', '))
            base = base + (gl.type.size or #vals)
        end
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
        cur_fn = name
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
        allocas = false
        local nref = #refusals
        local body = stmt(field_of(f.node, 'body'), { gotos = {} })
        -- a goto the structured forms refused: the WHOLE function takes the dispatch form instead (only then — every
        -- function they express keeps its output)
        local refused_goto = false
        for i = nref + 1, #refusals do if refusals[i].kind == 'goto' then refused_goto = true end end
        if refused_goto then
            for i = #refusals, nref + 1, -1 do refusals[i] = nil end
            if X then contract_prepass(f.node, (opts.contract or {})[f.sname]) end
            allocas = false
            body = dispatch(field_of(f.node, 'body'))
        end
        if allocas then
            -- the heap stack is restored on EVERY exit (each return, and a throw)
            body = '{\nconst $sp = SP;\ntry ' .. body .. ' finally { SP = $sp; }\n}'
        end
        if X and #mtemps > 0 then
            local d = {}
            for _, tn in ipairs(mtemps) do d[#d + 1] = tn .. 'a, ' .. tn .. 'b' end
            body = body:gsub('^{\n', '{\nlet ' .. table.concat(d, ', ') .. ';\n', 1)
        end
        fns[#fns + 1] = ('function %s(%s) %s'):format(name, table.concat(params, ', '), body)
    end
    local exports = {}
    for _, name in ipairs(order) do exports[#exports + 1] = name end
    for _, name in ipairs(opts.exports or {}) do exports[#exports + 1] = name end -- the recipe's adapter
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
        -- (a WIDE array's entry names its DataView setter; without one the line is the byte form, unchanged)
        wide_image and ('function image() { const h = new Uint8Array(IMAGE_END), dv = new DataView(h.buffer);\n'
            .. '  const W = { setFloat64: 8, setBigUint64: 8, setBigInt64: 8, setUint32: 4, setInt32: 4, setUint16: 2, setInt16: 2 };\n'
            .. '  for (const [at, vals, set] of IMAGE) { if (!set) h.set(vals, at); else vals.forEach((v, i) => dv[set](at + i * W[set], v, true)); }\n'
            .. '  return h; }')
            or 'function image() { const h = new Uint8Array(IMAGE_END); for (const [at, vals] of IMAGE) h.set(vals, at); return h; }',
        -- exact HEAP mode: the module OWNS its heap — the image, then a stack region growing down (8-aligned); folded
        -- into the prelude's entry, so a legacy recipe's output gains no line
        ((X and opts.heap) and (table.concat({
            ('const $STACK = %d;'):format(opts.heap.stack or 65536),
            'H = new Uint8Array(IMAGE_END + $STACK); H.set(image());',
            'const DV = new DataView(H.buffer);',
            'let SP = H.length;',
            'const $alloca = n => { SP = (SP - n) & ~7; if (SP < IMAGE_END) throw new Error("[cjs] heap stack overflow"); return SP; };',
        }, '\n') .. '\n') or '') .. (opts.prelude or ''),
        -- (the struct globals, exact mode only — '' otherwise, so a legacy recipe's output is unchanged)
        table.concat(sg_js, '\n') .. (#sg_js > 0 and '\n' or '') .. table.concat(fns, '\n\n') .. (opts.epilogue and ('\n\n' .. opts.epilogue) or ''),
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
    local lines = {} -- each emitted function's source line count (a probe weighs code by it)
    for _, name in ipairs(order) do local r0, _, r1 = funcs[name].node:range(); lines[name] = r1 - r0 + 1 end
    return js, refusals, { functions = order, globals = gnames, messages = errmsg, unresolved_sites = unresolved, calls = calls, lines = lines }
end

-- ── the HOST COMPILER's answers about C layout (exact heap mode never re-derives C's layout rules) ──────────────
--- build and run a C program `body` (inside main) with `opts.cflags`, `-I opts.include`, including opts.header ->
--- stdout | nil, why
local function crun(opts, name, body)
    local tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, 'p')
    local c = tmp .. '/' .. name .. '.c'
    local f = assert(io.open(c, 'w'))
    f:write('#include <stdio.h>\n#include <stddef.h>\n', opts.header and ('#include "' .. opts.header .. '"\n') or '', opts.prelude or '',
        'int main(void) {\n', body, '  return 0;\n}\n')
    f:close()
    local cmd = { 'gcc', '-w', '-o', tmp .. '/' .. name }
    vim.list_extend(cmd, opts.cflags or {})
    if opts.include then cmd[#cmd + 1] = '-I' .. opts.include end
    cmd[#cmd + 1] = c
    local r = vim.system(cmd, { text = true }):wait()
    if r.code ~= 0 then vim.fn.delete(tmp, 'rf'); return nil, 'the layout program failed: ' .. (r.stderr or '') end
    local out = vim.system({ tmp .. '/' .. name }, { text = true }):wait().stdout
    vim.fn.delete(tmp, 'rf')
    return out
end

--- a struct/union typedef's LAYOUT, as the compiler lays it out: the fields read from the type's own definition in
--- `opts.src` (preprocessed text; a member of an ANONYMOUS struct/union is the type's own, a member of a NAMED one is
--- not), then every scalar field's offset / size / class (__builtin_classify_type: 1 integer, 8 real) and signedness.
--- opts: { src, type, header, include, cflags, prelude? } -> { size, fields = { [f] = { off, cls } } }, { 'f@off:cls' … }
--- | nil, why
function M.compiler_layout(opts)
    local tree = vim.treesitter.get_string_parser(opts.src, 'c'):parse()[1]
    local q = vim.treesitter.query.parse('c', '(type_definition type: [(union_specifier) (struct_specifier)] @u declarator: (type_identifier) @n)')
    local spec
    for id, node in q:iter_captures(tree:root(), opts.src, 0, -1) do
        if q.captures[id] == 'n' and vim.treesitter.get_node_text(node, opts.src) == opts.type then spec = node:parent():field('type')[1] end
    end
    if not spec then return nil, 'no typedef of `' .. opts.type .. '` in the source' end
    local fields = {}
    -- a member of a NAMED inline struct/union is a PATH (`u32.hi`: offsetof takes it, from the outer type's start)
    local function walk(s, prefix)
        local body = s:field('body')[1]
        for fd in (body and body:iter_children() or function () end) do
            if fd:type() == 'field_declaration' then
                local decls = fd:field('declarator')
                local inner = fd:field('type')[1]
                local agg = inner and (inner:type() == 'struct_specifier' or inner:type() == 'union_specifier') and inner:field('body')[1]
                if #decls == 0 then
                    if agg then walk(inner, prefix) end
                else
                    for _, d in ipairs(decls) do
                        if agg and d:type() == 'field_identifier' then
                            walk(inner, prefix .. vim.treesitter.get_node_text(d, opts.src) .. '.')
                        else
                            while d:type() == 'array_declarator' or d:type() == 'pointer_declarator' do d = d:field('declarator')[1] end
                            if d:type() == 'field_identifier' then fields[#fields + 1] = prefix .. vim.treesitter.get_node_text(d, opts.src) end
                        end
                    end
                end
            end
        end
    end
    walk(spec, '')
    local T = opts.type
    local p1 = { ('  printf("size %%zu\\n", sizeof(%s));\n'):format(T) }
    for _, f in ipairs(fields) do
        p1[#p1 + 1] = ('  printf("%s %%zu %%zu %%d\\n", offsetof(%s, %s), sizeof(((%s *)0)->%s), __builtin_classify_type(((%s *)0)->%s));\n')
            :format(f, T, f, T, f, T, f)
    end
    local out1, why = crun(opts, 'layout1', table.concat(p1))
    if not out1 then return nil, why end
    local layout, scalars = { fields = {} }, {}
    for line in out1:gmatch('[^\n]+') do
        local sz = line:match('^size (%d+)$')
        if sz then layout.size = tonumber(sz)
        else
            local f, off, size, cls = line:match('^(%S+) (%d+) (%d+) (%d+)$')
            if f and (cls == '1' or cls == '8') then scalars[#scalars + 1] = { f = f, off = tonumber(off), size = tonumber(size), real = cls == '8' } end
        end
    end
    local p2 = {}
    for _, s in ipairs(scalars) do p2[#p2 + 1] = ('  printf("%s %%d\\n", (int)((__typeof__(((%s *)0)->%s))-1 < 0));\n'):format(s.f, T, s.f) end
    local out2, why2 = crun(opts, 'layout2', table.concat(p2))
    if not out2 then return nil, why2 end
    local signed = {}
    for line in out2:gmatch('[^\n]+') do local f, sg = line:match('^(%S+) (%d)$'); if f then signed[f] = sg == '1' end end
    local desc = {}
    for _, s in ipairs(scalars) do
        local cls = s.real and (s.size == 8 and 'f64' or nil) or ((signed[s.f] and 'i' or 'u') .. (s.size * 8))
        if cls then layout.fields[s.f] = { off = s.off, cls = cls }; desc[#desc + 1] = ('%s@%d:%s'):format(s.f, s.off, cls) end
    end
    return layout, desc
end

--- every `sizeof(<type>)` in `opts.src` (or the type texts `opts.types`), answered by the compiler -> { [type text] =
--- bytes } | nil, why. With `opts.types`, a type the header does not define is SKIPPED (each type then asked alone),
--- not a failure of all — a probe over many units asks for types only some of them define
function M.compiler_sizes(opts)
    local types = {}
    if opts.types then
        for _, ty in ipairs(opts.types) do types[ty] = true end
    else
        local tree = vim.treesitter.get_string_parser(opts.src, 'c'):parse()[1]
        local q = vim.treesitter.query.parse('c', '(sizeof_expression type: (type_descriptor) @t)')
        for _, node in q:iter_captures(tree:root(), opts.src, 0, -1) do types[vim.trim(vim.treesitter.get_node_text(node, opts.src))] = true end
    end
    local sp = {}
    for ty in pairs(types) do sp[#sp + 1] = ('  printf("%%zu %s\\n", sizeof(%s));\n'):format(ty, ty) end
    table.sort(sp)
    if #sp == 0 then return {} end
    local out, why = crun(opts, 'sizes', table.concat(sp))
    if not out and opts.types then
        local parts = {}
        for _, line in ipairs(sp) do parts[#parts + 1] = crun(opts, 'size1', line) end
        out = table.concat(parts)
    end
    if not out then return nil, why end
    local sizes = {}
    for line in out:gmatch('[^\n]+') do local v, ty = line:match('^(%d+) (.+)$'); if v then sizes[ty] = tonumber(v) end end
    return sizes
end

--- the COMPILER BUILTINS and libc leaves exact-mode recipes share, as templates (one line each: the hardware's or
--- the compiler's meaning, which has no C body). Each names the runtime it needs: $clz64 / $ldexp from
--- lua/cartograph/luajs/fpu.js (each with its own C oracle in tests/luajs_spec.lua), $memcmp from the recipe's prelude
--- (over its heap). A boundary probe (cartograph.luajs.boundary) uses the same set, so a builtin is never a "gap".
M.BUILTINS = {
    __builtin_expect = { js = '$1', ret = 'arg1' },
    __builtin_clz = { js = 'Math.clz32($1)', ret = 'i32' },                 -- (undefined for 0 in C)
    __builtin_ctz = { js = '(31 - Math.clz32(($1) & -($1)))', ret = 'i32' },
    __builtin_clzll = { js = '$clz64($1)', ret = 'i32' },
    ldexp = '$ldexp($1, $2)',                                                  -- one rounding (fpu.js)
    memcmp = { js = '$memcmp($1, $2, $3)', ret = 'i32' },
}

return M
