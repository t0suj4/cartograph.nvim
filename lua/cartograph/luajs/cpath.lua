-- cartograph.luajs.cpath — ARGUMENT TYPES BY PATH: for any C function over the Lua API, which value tags each argument
-- slot may hold on the paths that reach no no-return raiser (CART-1240 leaf 2). No checker is named: a three-valued
-- interpreter walks the preprocessed C, the slot holding the SET of every tag (each a REPRESENTATIVE the compiler
-- builds with LuaJIT's own setters) at every argument count, one run per (function, position).
--
-- Every fact is the tree's: the tags and their setters (lj_obj.h), lua.h's type codes, the no-return raisers (the
-- noreturn macros), TValue's layout (the compiler's), a sentinel's tag (its initializer: setnilV(&g->nilnode.val)),
-- the result convention (lj_lib.h's FFH_RES / FFH_RETRY), the first-class tags (the API's own lua_type), a builtin's
-- meaning (cartograph.cjs.BUILTINS). A tag per position is ALWAYS accepted, CONTENT-dependent (some paths return,
-- some reject: a numeric string), or NEVER; ABSENT is one more.
-- LOOPS without unrolling (CART-1240 leaf 3): each body runs over its EXECUTABLE graph (cfg.graph) to a fixpoint — a
-- node joins what reaches it within a loop token, a loop head keeps up to 8 distinct states and then WIDENS; goto,
-- break, continue and a switch's fall-through are edges. The STACK is a value of the path: L->top / L->base move
-- (lua_settop's fill loop), and a reallocated stack keeps its indices (the origin is wherever L->stack points).
-- ⚠ LIMITS, reported and never silent: the per-run step budget (`over`); an FFI conversion is content-dependent; a
-- recursive call is OPTIMISTIC (every element returns, the stack where it was — CART-1243); a char* step counts
-- TValues, not bytes (CART-1244).
local M = {}

local function readfile(p) local fd = io.open(p, 'rb'); if not fd then return nil end local s = fd:read('a'); fd:close(); return s end

--- the TAGS and their representatives, from the compiler: every `#define LJ_T<NAME> (~Nu)` of lj_obj.h, built with the
--- setter lj_obj.h itself gives its kind (a primitive — at or above LJ_TISPRI — through setpriV, the number through
--- setnumV, a GC object through setgcVraw), printed as its 64-bit word; and every `tvis*` predicate over every one of
--- them (the REFERENCE the interpreter must reproduce) -> { order = { names }, tag = { [name] = { value, u64 } },
--- tvis = { names }, matrix = { [pred] = { [name] = 0|1 } } } | nil, why
function M.reps(src, cflags)
    local objh = readfile(src .. '/lj_obj.h') or ''
    local order, seen = {}, {}
    for name in objh:gmatch('#define%s+LJ_T(%u+)%s+%(~%d+u%)') do if not seen[name] then seen[name] = true; order[#order + 1] = name end end
    local preds, pseen = {}, {}
    for p in objh:gmatch('#define%s+(tvis[%w_]+)%(o%)') do if not pseen[p] then pseen[p] = true; preds[#preds + 1] = p end end
    local body = { '  static double cell[8]; TValue v;' }
    for _, name in ipairs(order) do
        local T = 'LJ_T' .. name
        body[#body + 1] = ('  if (%s >= LJ_TISPRI) setpriV(&v, %s); else if (%s == LJ_TNUMX) setnumV(&v, 1.5); else setgcVraw(&v, (GCobj *)cell, %s);'):format(T, T, T, T)
        local row = {}
        for _, p in ipairs(preds) do row[#row + 1] = ('%s(&v) ? 1 : 0'):format(p) end
        body[#body + 1] = ('  printf("%s %%u %%016llx'):format(name) .. string.rep(' %d', #preds) .. ('\\n", (unsigned)%s, (unsigned long long)v.u64, %s);'):format(T, table.concat(row, ', '))
    end
    local tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, 'p')
    local c = tmp .. '/reps.c'
    local fd = assert(io.open(c, 'w'))
    fd:write('#include <stdio.h>\n#include "lj_obj.h"\nint main(void) {\n', table.concat(body, '\n'), '\n  return 0;\n}\n')
    fd:close()
    local cmd = { 'gcc', '-w', '-o', tmp .. '/reps' }
    vim.list_extend(cmd, cflags or {})
    vim.list_extend(cmd, { '-I' .. src, c })
    local r = vim.system(cmd, { text = true }):wait()
    if r.code ~= 0 then vim.fn.delete(tmp, 'rf'); return nil, 'the representatives program failed: ' .. (r.stderr or '') end
    local out = vim.system({ tmp .. '/reps' }, { text = true }):wait().stdout or ''
    vim.fn.delete(tmp, 'rf')
    local R = { order = order, tag = {}, tvis = preds, matrix = {} }
    for _, p in ipairs(preds) do R.matrix[p] = {} end
    for line in out:gmatch('[^\n]+') do
        local f = vim.split(line, ' ', { plain = true })
        R.tag[f[1]] = { value = tonumber(f[2]), u64 = f[3] }
        for i, p in ipairs(preds) do R.matrix[p][f[1]] = tonumber(f[3 + i]) end
    end
    return R
end

-- ── THE INTERPRETER: three-valued C over the preprocessed AST ────────────────────────────────────────────────────────
-- VALUES: an integer { k='i', v=int64 bits, w=8|16|32|64, u=bool } (C's own widths and conversions), a double
-- { k='d', v }, a pointer to argument SLOT i { k='slot', i } (L->base is slot 1, L->top slot count+1), a SENTINEL
-- { k='sym', s } (an address the code compares against: niltv's `&G(L)->nilnode.val`), the state { k='L' }, a field of
-- a slot being read { k='field', i, path }, and UNKNOWN (nil). Arithmetic on an unknown is unknown; `&&`/`||` keep C's
-- short circuit, so `false && ?` is false.
local ffi = require 'ffi'
local I64 = ffi.typeof('int64_t')
local U64 = ffi.typeof('uint64_t')

local function wrap(v, w, u)
    v = I64(v)
    if w < 64 then
        local m = bit.lshift(I64(1), w) - 1
        v = bit.band(v, m)
        if not u and bit.band(v, bit.lshift(I64(1), w - 1)) ~= 0 then v = v - bit.lshift(I64(1), w) end
    end
    return v
end
local function int(v, w, u) return { k = 'i', v = wrap(v, w or 32, u), w = w or 32, u = u or false } end
M._int = int
local function promote(a) if a.w < 32 then return { k = 'i', v = a.v, w = 32, u = false } end return a end
local function common(a, b)
    a, b = promote(a), promote(b)
    if a.w == b.w then return a.w, a.u or b.u end
    local wide = a.w > b.w and a or b
    return wide.w, wide.u
end
local function asnum(a) -- an integer's value as a Lua number (exact below 2^53)
    if a.u and a.w == 64 then return tonumber(U64(a.v)) end
    return tonumber(a.v)
end
local function truth(a)
    if a == nil then return nil end
    if a.k == 'i' then return a.v ~= 0 end
    if a.k == 'd' then return a.v ~= 0 end
    if a.k == 'slot' or a.k == 'sym' or a.k == 'L' or a.k == 'str' then return true end
    if a.k == 'null' then return false end
    return nil
end
M._truth = truth
local function boolv(b) if b == nil then return nil end return int(b and 1 or 0, 32, false) end

--- C's binary operators on two known values (nil: not decidable here)
local function binop(op, a, b)
    if a == nil or b == nil then return nil end
    if op == '@index' then if a.k == 'slot' and b.k == 'i' then return { k = 'slotv', i = a.i + tonumber(b.v) } end return nil end
    -- pointers: slot indices compare and step; sentinels are distinct memory (equal only to themselves)
    local pa, pb = a.k == 'slot' or a.k == 'sym' or a.k == 'null' or a.k == 'org', b.k == 'slot' or b.k == 'sym' or b.k == 'null' or b.k == 'org'
    if pa or pb then
        -- (two images of the stack's origin: no distance apart, so a pointer rebased by their difference keeps its index)
        if a.k == 'org' and b.k == 'org' then
            if op == '-' then return int(0, 64, false) elseif op == '==' then return boolv(true) elseif op == '!=' then return boolv(false) end
            return nil
        end
        if a.k == 'slot' and b.k == 'i' and (op == '+' or op == '-') then return { k = 'slot', i = a.i + (op == '+' and 1 or -1) * asnum(b) } end
        if a.k == 'slot' and b.k == 'slot' then
            local x, y = a.i, b.i
            if op == '-' then return int(x - y, 64, false) end
            if op == '<' then return boolv(x < y) elseif op == '<=' then return boolv(x <= y) elseif op == '>' then return boolv(x > y)
            elseif op == '>=' then return boolv(x >= y) elseif op == '==' then return boolv(x == y) elseif op == '!=' then return boolv(x ~= y) end
        end
        if op == '==' or op == '!=' then
            local same = a.k == b.k and (a.k ~= 'sym' or a.s == b.s) and (a.k ~= 'slot' or a.i == b.i)
            if a.k == 'null' or b.k == 'null' then same = a.k == b.k end
            if a.k == 'i' and b.k == 'null' then same = a.v == 0 end
            if b.k == 'i' and a.k == 'null' then same = b.v == 0 end
            if (a.k == 'slot' and b.k == 'sym') or (a.k == 'sym' and b.k == 'slot') then same = false end
            return boolv(op == '==' and same or (op == '!=' and not same))
        end
        return nil
    end
    if a.k == 'd' or b.k == 'd' then
        local x = a.k == 'd' and a.v or asnum(a)
        local y = b.k == 'd' and b.v or asnum(b)
        if op == '+' then return { k = 'd', v = x + y } elseif op == '-' then return { k = 'd', v = x - y }
        elseif op == '*' then return { k = 'd', v = x * y } elseif op == '/' then return { k = 'd', v = x / y }
        elseif op == '<' then return boolv(x < y) elseif op == '<=' then return boolv(x <= y) elseif op == '>' then return boolv(x > y)
        elseif op == '>=' then return boolv(x >= y) elseif op == '==' then return boolv(x == y) elseif op == '!=' then return boolv(x ~= y) end
        return nil
    end
    if a.k ~= 'i' or b.k ~= 'i' then return nil end
    if op == '<<' or op == '>>' then
        local pa2 = promote(a)
        local n = asnum(b)
        if n < 0 or n >= pa2.w then return nil end
        local v = pa2.u and U64(bit.band(pa2.v, pa2.w == 64 and I64(-1) or (bit.lshift(I64(1), pa2.w) - 1))) or pa2.v
        local r = op == '<<' and bit.lshift(v, n) or (pa2.u and bit.rshift(v, n) or bit.arshift(v, n))
        return int(r, pa2.w, pa2.u)
    end
    local w, u = common(a, b)
    local x = wrap(a.v, w, u)
    local y = wrap(b.v, w, u)
    local ux, uy = U64(x), U64(y)
    if w < 64 and u then ux, uy = U64(bit.band(x, bit.lshift(I64(1), w) - 1)), U64(bit.band(y, bit.lshift(I64(1), w) - 1)) end
    if op == '+' then return int(x + y, w, u) elseif op == '-' then return int(x - y, w, u) elseif op == '*' then return int(x * y, w, u)
    elseif op == '/' then if y == 0 then return nil end return int(u and I64(ux / uy) or x / y, w, u)
    elseif op == '%' then if y == 0 then return nil end return int(u and I64(ux % uy) or x % y, w, u)
    elseif op == '&' then return int(bit.band(x, y), w, u) elseif op == '|' then return int(bit.bor(x, y), w, u)
    elseif op == '^' then return int(bit.bxor(x, y), w, u) end
    local lt, eqv = (u and ux < uy or (not u and x < y)), x == y
    if op == '<' then return boolv(lt) elseif op == '<=' then return boolv(lt or eqv) elseif op == '>' then return boolv(not lt and not eqv)
    elseif op == '>=' then return boolv(not lt) elseif op == '==' then return boolv(eqv) elseif op == '!=' then return boolv(not eqv) end
    return nil
end
M._binop = binop

--- a C type's text -> { k = 'i', w, u } | { k = 'd' } | { k = 'p' } | nil, through the unit's typedefs
local INT = { char = { 8, false }, ['signed char'] = { 8, false }, ['unsigned char'] = { 8, true }, short = { 16, false },
    ['short int'] = { 16, false }, ['unsigned short'] = { 16, true }, ['unsigned short int'] = { 16, true }, int = { 32, false },
    signed = { 32, false }, ['signed int'] = { 32, false }, unsigned = { 32, true }, ['unsigned int'] = { 32, true },
    long = { 64, false }, ['long int'] = { 64, false }, ['long long'] = { 64, false }, ['long long int'] = { 64, false },
    ['unsigned long'] = { 64, true }, ['unsigned long int'] = { 64, true }, ['unsigned long long'] = { 64, true },
    ['unsigned long long int'] = { 64, true }, _Bool = { 8, true } }
M.INT = INT -- (C's own integer types under LP64: the language, not a library)
function M.ctype(text, typedefs, depth)
    depth = depth or 0
    text = vim.trim((text or ''):gsub('%f[%w_]const%f[^%w_]', ''):gsub('%f[%w_]volatile%f[^%w_]', ''):gsub('%s+', ' '))
    if text:find('%*') then return { k = 'p' } end
    if text == 'double' or text == 'float' then return { k = 'd' } end
    local i = INT[text]
    if i then return { k = 'i', w = i[1], u = i[2] } end
    local td = typedefs[text]
    if td and depth < 12 then return M.ctype(td, typedefs, depth + 1) end
    return nil
end

-- ── THE WALKER: one run carries EVERY tag of the analyzed slot ─────────────────────────────────────────────────────
-- A path holds the SET of tags the analyzed ("focus") slot may have on it; a value read from that slot is a VECTOR
-- { k='vec', by = { [tag] = value } } (collapsed to a scalar when every tag agrees). A condition over a vector
-- PARTITIONS the set (true / false / undecided), and each branch continues with its part — so one run answers for
-- every tag what a per-tag walk would, without repeating the walk per tag. The ARGUMENT COUNT is the same kind of
-- dimension: an element is `<tag>@<count>`, and `L->top` is a vector of slot pointers over the elements.
local function tx(n, src) return vim.treesitter.get_node_text(n, src) end
local function kids(n) local o = {} for c in n:iter_children() do if c:named() and c:type() ~= 'comment' then o[#o + 1] = c end end return o end
local function veq(a, b)
    if a == nil or b == nil then return a == b end
    if a.k ~= b.k then return false end
    if a.k == 'i' then return a.v == b.v and a.w == b.w and a.u == b.u end
    if a.k == 'd' then return a.v == b.v or (a.v ~= a.v and b.v ~= b.v) end
    if a.k == 'slot' then return a.i == b.i end
    if a.k == 'sym' then return a.s == b.s end
    if a.k == 'field' then return a.i == b.i and a.path == b.path end
    if a.k == 'vec' then
        for t, v in pairs(a.by) do if not veq(v or nil, b.by[t] or nil) then return false end end
        for t in pairs(b.by) do if a.by[t] == nil then return false end end
        return true
    end
    return true
end
local function setof(t) local s = {} for k in pairs(t) do s[k] = true end return s end
local ecache = {}
--- an element's tag and argument count (`STR@2`)
local function elem(e)
    local c = ecache[e]
    if not c then local t, n = e:match('^(.-)@(%d+)$'); c = { t or e, tonumber(n) or 0 }; ecache[e] = c end
    return c[1], c[2]
end
local function union(a, b) local s = setof(a) for k in pairs(b) do s[k] = true end return s end
local function empty(s) return next(s) == nil end
local function skey(s) local l = vim.tbl_keys(s); table.sort(l); return table.concat(l, ',') end
--- a value AT one tag
local function at(v, t) if v and v.k == 'vec' then local x = v.by[t]; return x or nil end return v end
--- a per-tag function over a set, collapsed when every tag agrees
local function vmap(set, fn)
    local by, first, uniform, any = {}, nil, true, false
    for t in pairs(set) do
        local r = fn(t)
        by[t] = r or false
        if not any then first = r; any = true elseif not veq(first, r) then uniform = false end
    end
    if uniform then return first end
    return { k = 'vec', by = by }
end
local function key_of(v)
    if v == nil then return '?' end
    if v.k == 'i' then return 'i' .. tostring(v.v) .. ':' .. v.w .. (v.u and 'u' or 's') end
    if v.k == 'slot' then return 's' .. v.i end
    if v.k == 'sym' then return 'y' .. v.s end
    if v.k == 'vec' then
        local l = {}
        for t, x in pairs(v.by) do l[#l + 1] = t .. '=' .. key_of(x or nil) end
        table.sort(l)
        return '[' .. table.concat(l, ';') .. ']'
    end
    return v.k
end
local function copy(st)
    local e, sl = {}, {}
    for k, v in pairs(st.env) do e[k] = v end
    for k, v in pairs(st.slots) do sl[k] = v end
    return { env = e, slots = sl, types = st.types, src = st.src, unit = st.unit, fname = st.fname,
        fi = st.fi, fset = setof(st.fset), fwrite = st.fwrite, tok = st.tok }
end
--- the JOIN of two states, EXACT per tag where their sets are disjoint (a partition's two branches meeting again)
local function join(a, b)
    if not a then return b end
    if not b then return a end
    local r = copy(a)
    r.fset = union(a.fset, b.fset)
    r.fwrite = a.fwrite or b.fwrite
    local names = setof(a.env)
    for k in pairs(b.env) do names[k] = true end
    for k in pairs(names) do
        local va, vb = a.env[k], b.env[k]
        if veq(va, vb) then r.env[k] = va
        else
            r.env[k] = vmap(r.fset, function (t)
                local ia, ib = a.fset[t], b.fset[t]
                if ia and not ib then return at(va, t) elseif ib and not ia then return at(vb, t) end
                local x, y = at(va, t), at(vb, t)
                if veq(x, y) then return x end
                return nil
            end)
        end
    end
    local keys = setof(a.slots)
    for k in pairs(b.slots) do keys[k] = true end
    for k in pairs(keys) do if a.slots[k] ~= b.slots[k] then r.slots[k] = '?' end end
    return r
end
--- a state narrowed to a subset of its tags (nil when empty)
local function narrow(st, set)
    if empty(set) then return nil end
    local r = copy(st)
    r.fset = setof(set)
    return r
end
--- the three-way PARTITION of a state's tags by a value's truth -> T, F, U
local function split(v, set)
    local T, F, U = {}, {}, {}
    for t in pairs(set) do
        local b = truth(at(v, t))
        if b == true then T[t] = true elseif b == false then F[t] = true else U[t] = true end
    end
    return T, F, U
end

--- a C number literal -> value
local function literal(t)
    local low = t:lower()
    if low:find('[%.p]') and not low:find('^0x[%x]+[ul]*$') or (low:find('e') and not low:find('^0x')) then
        local v = tonumber((low:gsub('[fl]+$', '')))
        return v and { k = 'd', v = v } or nil
    end
    local u = low:find('u') ~= nil
    local long = select(2, low:gsub('l', '')) > 0
    local digits = low:gsub('[ul]+$', '')
    local v
    if digits:find('^0x') then v = tonumber(digits:sub(3), 16) elseif digits:find('^0%d') then v = tonumber(digits, 8) else v = tonumber(digits) end
    if not v then return nil end
    local w = long and 64 or 32
    if not long and not u and v > 0x7fffffff then if v <= 0xffffffff and digits:find('^0x') then u = true else w = 64 end end
    if not long and u and v > 0xffffffff then w = 64 end
    return int(v, w, u)
end
M._literal = literal

--- C's conversion of a value to a type (nil: not decidable)
local function convert(ty, a)
    if not ty or a == nil then return nil end
    if ty.k == 'i' then
        if a.k == 'i' then return int(a.v, ty.w, ty.u) end
        if a.k == 'd' then if a.v ~= a.v or a.v == math.huge or a.v == -math.huge then return nil end return int(I64(a.v >= 0 and math.floor(a.v) or -math.floor(-a.v)), ty.w, ty.u) end
        return nil
    elseif ty.k == 'd' then
        if a.k == 'i' then return { k = 'd', v = asnum(a) } end
        if a.k == 'd' then return a end
        return nil
    end
    if a.k == 'slot' or a.k == 'sym' or a.k == 'null' or a.k == 'str' or a.k == 'org' then return a end
    if a.k == 'i' and a.v == 0 then return { k = 'null' } end
    return nil
end

--- a field of a scalar base (the per-element half of field_expression) — `e` the element, for L->top
function M._field(base, op, f, st, layout, read_field, e)
    if base == nil then return nil end
    if base.k == 'L' and op == '->' then
        if f == 'base' then return { k = 'slot', i = 1 } end
        if f == 'top' then local _, c = (e or ''):match('^(.-)@(%d+)$'); return { k = 'slot', i = (tonumber(c) or 0) + 1 } end
        -- the stack's ORIGIN: slots are indices into it, so wherever a reallocation moves it, it is the same origin
        if f == 'stack' then return { k = 'org' } end
        return nil
    end
    if base.k == 'org' and op == '.' then return base end -- (an MRef's one member is the pointer)
    if (base.k == 'slot' and op == '->') or (base.k == 'slotv' and op == '.') then
        if layout.fields[f] then return { k = 'field', i = base.i, path = f } end
        for k in pairs(layout.fields) do if k:sub(1, #f + 1) == f .. '.' then return { k = 'field', i = base.i, path = f } end end
        return nil
    end
    if base.k == 'field' and op == '.' then return { k = 'field', i = base.i, path = base.path .. '.' .. f } end
    if base.k == 'sym' and base.tag and op == '->' then return read_field(base.tag, f) end
    return nil
end

--- the analyzer over a tree (see M.context)
function M.analyzer(ctx)
    local A = { memo = {}, active = {}, steps = 0, budget = ctx.budget or 400000,
    }
    local layout, reps = ctx.layout, ctx.reps
    local fbits = ffi.new('uint64_t[1]')
    local fdbl = ffi.cast('double *', fbits)
    local fcache = {}
    --- a slot's field at one tag, read from that tag's representative
    local function read_field(tag, path)
        if tag and tag:find('@', 1, true) then tag = elem(tag) end
        if not tag or tag == '?' or tag == 'ABSENT' then return nil end
        local ck = tag .. '\0' .. path
        local c = fcache[ck]
        if c ~= nil then return c or nil end
        local f, rep = layout.fields[path], reps.tag[tag]
        local r
        if f and rep then
            local u = U64(tonumber(rep.u64:sub(1, 8), 16)) * U64(2 ^ 32) + U64(tonumber(rep.u64:sub(9), 16))
            if f.cls == 'f64' then
                -- ★ a NaN comes back CANONICAL: a GC tag's word IS a payload NaN, and an ffi load does not canonicalize
                if bit.band(u, U64(0x7ff00000) * U64(2 ^ 32)) == U64(0x7ff00000) * U64(2 ^ 32) and bit.band(u, U64(0xfffff) * U64(2 ^ 32) + U64(0xffffffff)) ~= U64(0) then
                    r = { k = 'd', v = 0 / 0 }
                else fbits[0] = u; r = { k = 'd', v = fdbl[0] } end
            else
                local w = tonumber(f.cls:match('%d+'))
                r = int(I64(f.off == 0 and u or bit.rshift(u, f.off * 8)), w, f.cls:sub(1, 1) == 'u')
            end
        end
        fcache[ck] = r or false
        return r
    end
    --- a field REFERENCE made a value: the focus slot's per tag (unknown after a write to it), another slot's by its tag
    local function deref_field(v, st)
        if not (v and v.k == 'field') then return v end
        if v.i == st.fi then
            if st.fwrite then return nil end
            return vmap(st.fset, function (t) return read_field(t, v.path) end)
        end
        return read_field(st.slots[v.i], v.path)
    end
    local function rv(v, st)
        if v and v.k == 'vec' then
            -- (a vector of field refs: each read at its own tag)
            return vmap(st.fset, function (t) local x = at(v, t); if x and x.k == 'field' then return x.i == st.fi and not st.fwrite and read_field(t, x.path) or (x.i ~= st.fi and read_field(st.slots[x.i], x.path)) or nil end return x end)
        end
        return deref_field(v, st)
    end
    local function lift2(op, a, b, st)
        if (a and a.k == 'vec') or (b and b.k == 'vec') then
            return vmap(st.fset, function (t) return binop(op, at(a, t), at(b, t)) end)
        end
        return binop(op, a, b)
    end
    local function lift1(fn, a, st)
        if a and a.k == 'vec' then return vmap(st.fset, function (t) return fn(at(a, t)) end) end
        return fn(a)
    end
    local eval, exec
    --- does d's call closure (the no-return raisers left out) ever read the stack — L->top / L->base, index2adr? derived
    --- from the text, memoized; a cycle is one closure
    local cq = vim.treesitter.query.parse('c', '(call_expression function: (identifier) @f)')
    local own, callees, sfcache = {}, {}, {}
    local function own_reads(d)
        local o = own[d.id]
        if o == nil then
            local text = tx(d.node, d.src)
            o = text:find('%->%s*top') ~= nil or text:find('%->%s*base') ~= nil
            own[d.id] = o
        end
        return o
    end
    local function callees_of(d)
        local l = callees[d.id]
        if l then return l end
        l = {}
        for _, cn in cq:iter_captures(d.node, d.src, 0, -1) do
            local nm = tx(cn, d.src)
            local cd = (ctx.unitdefs[d.unit] or {})[nm] or ctx.defs[nm]
            if cd and not ctx.noret[nm] then l[#l + 1] = cd end
        end
        callees[d.id] = l
        return l
    end
    function A.stackfree(d)
        local c = sfcache[d.id]
        if c ~= nil then return c end
        c = true
        local seen, todo = { [d.id] = true }, { d }
        while #todo > 0 and c do
            local x = table.remove(todo)
            if own_reads(x) then c = false end
            for _, cd in ipairs(callees_of(x)) do if not seen[cd.id] then seen[cd.id] = true; todo[#todo + 1] = cd end end
        end
        sfcache[d.id] = c
        return c
    end

    -- a CALL: a no-return raiser rejects every tag of the path; a builtin whose declared meaning is an argument
    -- returns it; a defined function is run with the path's tags (its summary: the tags it may return with, may
    -- reject with, its value per tag, the slots it leaves); anything else is unknown, and a slot it is handed is
    -- unknown after it
    local function call(name, args, st, cx)
        if ctx.noret[name] then for t in pairs(st.fset) do cx.rej[t] = true end; st.fset = {}; return nil end
        local d = (ctx.unitdefs[st.unit] or {})[name] or ctx.defs[name]
        local bi = ctx.builtins[name]
        if not d and bi then
            local k = ((type(bi) == 'table' and bi.js) or bi):match('^%$(%d)$')
            if k then return args[tonumber(k)] end
        end
        if not d then
            for i = 1, args.n do
                local a = args[i]
                if a and a.k == 'slot' then if a.i == st.fi then st.fwrite = true else st.slots[a.i] = '?' end end
            end
            return nil
        end
        -- a STACK-FREE callee (its closure never reads L->top / L->base) neither sees nor moves the stack: it is
        -- left out of the key, and the caller's stack passes through (summaries shared across argument counts)
        local sfree = A.stackfree(d)
        -- FOCUS-FREE: no argument differs per element, none is the analyzed slot, and no L goes to a callee that reads
        -- the stack — the stack and the focus slot are out of its reach (only an L handed to it reaches them), so it
        -- cannot tell the elements apart: it runs ONCE over one stand-in element '*' and the answer is broadcast
        local ffree = true
        for i = 1, args.n do
            local a = args[i]
            if a and (a.k == 'vec' or ((a.k == 'slot' or a.k == 'slotv') and a.i == st.fi) or (a.k == 'L' and not sfree)) then ffree = false; break end
        end
        local reach = not sfree and not ffree
        local fset = ffree and { ['*'] = true } or st.fset
        local ltop, lbase = st.env['\0top'], st.env['\0base']
        local parts = { d.id, skey(fset), tostring(st.fi), st.fwrite and 'w' or '', reach and key_of(ltop) or '', reach and key_of(lbase) or '' }
        for i = 1, args.n do parts[#parts + 1] = key_of(args[i]) end
        local sk = {}
        for i, t in pairs(st.slots) do sk[#sk + 1] = i .. '=' .. t end
        table.sort(sk)
        local key = table.concat(parts, ',') .. '|' .. table.concat(sk, ',')
        local sum = A.memo[key]
        if not sum then
            if A.active[key] then
                -- (recursion: OPTIMISTIC — every element returns, and leaves the stack where it found it)
                sum = { ret = setof(fset), rej = {}, vals = {}, slots = st.slots, top = {}, base = {} }
                for t in pairs(fset) do sum.top[t] = at(ltop, t) or false; sum.base[t] = at(lbase, t) or false end
            else
                A.active[key] = true
                -- (the stack handed on: false = out of reach, true = unknown)
                sum = A.run(d, args, st.slots, st.fi, fset, st.fwrite, reach and (ltop or true), reach and (lbase or true))
                A.active[key] = nil
                if not sum.over then A.memo[key] = sum end
            end
        end
        if ffree then
            -- (the stand-in's answer, for every element of the path)
            local one = { ret = {}, rej = {}, vals = {} }
            for t in pairs(st.fset) do
                if sum.ret['*'] then one.ret[t] = true end
                if sum.rej['*'] then one.rej[t] = true end
                one.vals[t] = sum.vals['*']
            end
            sum = setmetatable(one, { __index = sum })
        end
        for t in pairs(sum.rej) do cx.rej[t] = true end
        if sum.over then cx.over = true end
        local live = {}
        for t in pairs(st.fset) do if sum.ret[t] then live[t] = true end end
        st.fset = live
        if empty(live) then return nil end
        for i, t in pairs(sum.slots or {}) do st.slots[i] = t end
        if sum.fwrite then st.fwrite = true end
        if reach then
            st.env['\0top'] = vmap(live, function (t) return sum.top[t] or nil end)
            st.env['\0base'] = vmap(live, function (t) return sum.base[t] or nil end)
        end
        return vmap(live, function (t) return sum.vals[t] or nil end)
    end

    local function lvalue_slot(n, st, cx)
        local t = n:type()
        if t == 'field_expression' then
            local b = eval(n:field('argument')[1], st, cx)
            if b and (b.k == 'slot' or b.k == 'field' or b.k == 'slotv') then return b.i end
            return lvalue_slot(n:field('argument')[1], st, cx)
        elseif t == 'pointer_expression' or t == 'parenthesized_expression' then
            local b = eval(kids(n)[1], st, cx)
            if b and b.k == 'slot' then return b.i end
        elseif t == 'subscript_expression' then
            local b = eval(n:field('argument')[1], st, cx)
            local i = eval(n:field('index')[1], st, cx)
            if b and b.k == 'slot' and i and i.k == 'i' then return b.i + asnum(i) end
        end
        return nil
    end
    local function write_slot(i, st) if i == st.fi then st.fwrite = true elseif i then st.slots[i] = '?' end end

    --- an expression's value on the path st (st.fset narrows as calls reject; empty = dead)
    function eval(n, st, cx)
        A.steps = A.steps + 1
        if A.steps > A.budget then cx.over = true; st.fset = {}; return nil end
        if empty(st.fset) then return nil end
        local t = n:type()
        local src = st.src
        if t == 'number_literal' then return literal(tx(n, src))
        elseif t == 'char_literal' then local c = tx(n, src):match("^'(.)'$"); return c and int(c:byte()) or nil
        elseif t == 'string_literal' or t == 'concatenated_string' then return { k = 'str' }
        elseif t == 'true' then return int(1) elseif t == 'false' then return int(0)
        elseif t == 'null' then return { k = 'null' }
        elseif t == 'identifier' then
            local nm = tx(n, src)
            local v = st.env[nm]
            if v ~= nil then return v end
            if ctx.enums[nm] then return int(ctx.enums[nm]) end
            return nil
        elseif t == 'parenthesized_expression' then return eval(kids(n)[1], st, cx)
        elseif t == 'comma_expression' then
            eval(n:field('left')[1], st, cx)
            return eval(n:field('right')[1], st, cx)
        elseif t == 'binary_expression' then
            local op = tx(n:field('operator')[1], src)
            if op == '&&' or op == '||' then
                local a = rv(eval(n:field('left')[1], st, cx), st)
                if empty(st.fset) then return nil end
                local T, F, U = split(a, st.fset)
                -- the tags the left side DECIDES skip the right side; the others evaluate it on their own path
                local decided = op == '&&' and F or T
                local rest = union(op == '&&' and T or F, U)
                if empty(rest) then return int(op == '&&' and 0 or 1) end
                local st2 = narrow(st, rest)
                local b = rv(eval(n:field('right')[1], st2, cx), st2)
                local r = join(narrow(st, decided), not empty(st2.fset) and st2 or nil)
                if not r then st.fset = {}; return nil end
                st.env, st.slots, st.fset, st.fwrite = r.env, r.slots, r.fset, r.fwrite
                return vmap(st.fset, function (tg)
                    if decided[tg] then return int(op == '&&' and 0 or 1) end
                    local x, y = truth(at(a, tg)), truth(at(b, tg))
                    if op == '&&' then
                        if y == false then return int(0) end
                        if x == true and y == true then return int(1) end
                    else
                        if y == true then return int(1) end
                        if x == false and y == false then return int(0) end
                    end
                    return nil
                end)
            end
            local a = rv(eval(n:field('left')[1], st, cx), st)
            local b = rv(eval(n:field('right')[1], st, cx), st)
            return lift2(op, a, b, st)
        elseif t == 'unary_expression' then
            local op = tx(n:field('operator')[1], src)
            local a = rv(eval(n:field('argument')[1], st, cx), st)
            return lift1(function (x)
                if op == '!' then local b = truth(x); if b == nil then return nil end return int(b and 0 or 1) end
                if x == nil then return nil end
                if x.k == 'd' then if op == '-' then return { k = 'd', v = -x.v } end return x end
                if x.k ~= 'i' then return nil end
                local px = promote(x)
                if op == '-' then return int(-px.v, px.w, px.u) elseif op == '~' then return int(bit.bnot(px.v), px.w, px.u) elseif op == '+' then return px end
                return nil
            end, a, st)
        elseif t == 'cast_expression' then
            local ty = M.ctype(tx(n:field('type')[1], src), ctx.typedefs)
            local a = rv(eval(n:field('value')[1], st, cx), st)
            return lift1(function (x) return convert(ty, x) end, a, st)
        elseif t == 'conditional_expression' then
            local c = rv(eval(n:field('condition')[1], st, cx), st)
            if empty(st.fset) then return nil end
            local T, F, U = split(c, st.fset)
            local sa, sb = narrow(st, union(T, U)), narrow(st, union(F, U))
            local va = sa and eval(n:field('consequence')[1], sa, cx)
            local vb = sb and eval(n:field('alternative')[1], sb, cx)
            if sa and empty(sa.fset) then sa = nil end
            if sb and empty(sb.fset) then sb = nil end
            local r = join(sa, sb)
            if not r then st.fset = {}; return nil end
            st.env, st.slots, st.fset, st.fwrite = r.env, r.slots, r.fset, r.fwrite
            return vmap(st.fset, function (tg)
                local ina, inb = sa and sa.fset[tg], sb and sb.fset[tg]
                if ina and not inb then return at(va, tg) elseif inb and not ina then return at(vb, tg) end
                local x, y = at(va, tg), at(vb, tg)
                if veq(x, y) then return x end
                return nil
            end)
        elseif t == 'field_expression' then
            local base = eval(n:field('argument')[1], st, cx)
            local op = tx(n:field('operator')[1], src)
            local f = tx(n:field('field')[1], src)
            -- (a base that differs per element — L->top over the counts, index2adr's slot-or-sentinel — per element)
            -- L->top / L->base are VALUES of the path (they move: lua_settop's `L->top++`, a finalizer's restore)
            if base and base.k == 'L' and op == '->' and (f == 'top' or f == 'base') then return st.env[f == 'top' and '\0top' or '\0base'] end
            if (base and base.k == 'vec') then
                return vmap(st.fset, function (e) return M._field(at(base, e), op, f, st, layout, read_field, e) end)
            end
            return M._field(base, op, f, st, layout, read_field, nil)
        elseif t == 'pointer_expression' then
            local op = tx(n:field('operator')[1], src)
            local arg = n:field('argument')[1]
            if op == '&' then
                local v = eval(arg, st, cx)
                if v and v.k == 'slotv' then return { k = 'slot', i = v.i } end
                -- the ADDRESS of a field of VM state: a sentinel, compared by its text; its tag if its initializer says
                local text = tx(arg, src):gsub('%s', '')
                local tail = text:match('([%w_]+%.[%w_]+)$')
                return { k = 'sym', s = text, tag = tail and ctx.sentinels[tail] or nil }
            end
            local v = eval(arg, st, cx)
            return lift1(function (x) if x and x.k == 'slot' then return { k = 'slotv', i = x.i } end return nil end, v, st)
        elseif t == 'subscript_expression' then
            local b = eval(n:field('argument')[1], st, cx)
            local i = rv(eval(n:field('index')[1], st, cx), st)
            return lift2('@index', b, i, st)
        elseif t == 'call_expression' then
            local fnode = n:field('function')[1]
            -- (arguments by POSITION: an unknown one is a nil, and appending would shift the rest)
            local args = { n = 0 }
            for i, a in ipairs(kids(n:field('arguments')[1])) do
                args[i] = rv(eval(a, st, cx), st)
                args.n = i
                if empty(st.fset) then return nil end
            end
            if fnode:type() ~= 'identifier' then
                for i = 1, args.n do local a = args[i]; if a and a.k == 'slot' then write_slot(a.i, st) end end
                return nil
            end
            return call(tx(fnode, src), args, st, cx)
        elseif t == 'assignment_expression' then
            local l, r = n:field('left')[1], n:field('right')[1]
            local op = tx(n:field('operator')[1], src)
            local v = rv(eval(r, st, cx), st)
            if empty(st.fset) then return nil end
            if l:type() == 'identifier' then
                local nm = tx(l, src)
                if op ~= '=' then v = lift2(op:sub(1, -2), st.env[nm], v, st) end
                local ty = st.types[nm]
                if ty and ty.k == 'i' then v = lift1(function (x) return x and x.k == 'i' and int(x.v, ty.w, ty.u) or x end, v, st) end
                st.env[nm] = v
                return v
            end
            if l:type() == 'field_expression' then
                local lb = eval(l:field('argument')[1], st, cx)
                local lf = tx(l:field('field')[1], src)
                if lb and lb.k == 'L' and (lf == 'top' or lf == 'base') then
                    local key = lf == 'top' and '\0top' or '\0base'
                    if op ~= '=' then v = lift2(op:sub(1, -2), st.env[key], v, st) end
                    st.env[key] = v
                    return v
                end
                if lb and lb.k == 'org' then
                    -- (the stack IS where L->stack points: a local stored there — a reallocation's result — is the origin)
                    local x = r
                    while x and (x:type() == 'cast_expression' or x:type() == 'parenthesized_expression') do
                        x = x:type() == 'cast_expression' and x:field('value')[1] or kids(x)[1]
                    end
                    if x and x:type() == 'identifier' then st.env[tx(x, src)] = { k = 'org' } end
                    return v
                end
            end
            write_slot(lvalue_slot(l, st, cx), st) -- a WRITE to a slot: its tag is unknown after it
            return v
        elseif t == 'update_expression' then
            local a = n:field('argument')[1]
            if a:type() == 'field_expression' then
                local lb = eval(a:field('argument')[1], st, cx)
                local lf = tx(a:field('field')[1], src)
                if lb and lb.k == 'L' and (lf == 'top' or lf == 'base') then
                    local key = lf == 'top' and '\0top' or '\0base'
                    local old = st.env[key]
                    local whole = tx(n, src)
                    local new = lift2(whole:find('%+%+') and '+' or '-', old, int(1), st)
                    st.env[key] = new
                    return (whole:sub(1, 2) == '++' or whole:sub(1, 2) == '--') and new or old
                end
                return nil
            end
            if a:type() == 'identifier' then
                local nm = tx(a, src)
                local old = st.env[nm]
                local whole = tx(n, src)
                local new = lift2(whole:find('%+%+') and '+' or '-', old, int(1), st)
                st.env[nm] = new
                return (whole:sub(1, 2) == '++' or whole:sub(1, 2) == '--') and new or old
            end
            return nil
        end
        return nil
    end

    --- a SIMPLE statement (a declaration, an expression — a graph node's work) on the path st -> the state after it
    --- (nil: dead); rejections in cx. The CONTROL FLOW is cartograph.cfg.graph's edges, run by A.run below.
    function exec(n, st, cx)
        if not st or empty(st.fset) then return nil end
        A.steps = A.steps + 1
        if A.steps > A.budget then cx.over = true; return nil end
        local t = n:type()
        local src = st.src
        if t == 'declaration' then
            local ty = M.ctype(tx(n:field('type')[1], src), ctx.typedefs)
            for _, d in ipairs(n:field('declarator')) do
                local dd, val, isptr = d, nil, false
                if d:type() == 'init_declarator' then dd = d:field('declarator')[1]; val = d:field('value')[1] end
                while dd and dd:type() == 'pointer_declarator' do isptr = true; dd = dd:field('declarator')[1] end
                if dd and dd:type() == 'identifier' then
                    local name = tx(dd, src)
                    local vty = isptr and { k = 'p' } or ty
                    st.types[name] = vty
                    local v
                    if val and val:type() ~= 'initializer_list' then v = rv(eval(val, st, cx), st) end
                    if empty(st.fset) then return nil end
                    if vty and vty.k == 'i' then v = lift1(function (x) return x and x.k == 'i' and int(x.v, vty.w, vty.u) or x end, v, st) end
                    st.env[name] = v
                end
            end
            return st
        end
        local e = t == 'expression_statement' and kids(n)[1] or (t ~= 'expression_statement' and n or nil)
        if e then eval(e, st, cx) end
        if empty(st.fset) then return nil end
        return st
    end

    --- run a defined function on a path: its arguments, the slots, the argument count, the focus slot and its tags ->
    --- { ret = tags that may return, rej = tags that may reject, vals = { [tag] = return value }, slots, fwrite, over }
    function A.run(d, args, slots, fi, fset, fwrite, ltop, lbase)
        local st = { env = {}, slots = {}, types = {}, src = d.src, unit = d.unit, fname = d.name,
            fi = fi, fset = setof(fset), fwrite = fwrite }
        -- the STACK: L->top (per element: its argument count + 1, unless the caller moved it) and L->base (slot 1)
        -- (a caller hands false: out of reach; true: unknown; nothing: the driver's entry, derived from the counts)
        if ltop == false or ltop == true then -- (a stack-free function never reads them)
        elseif ltop ~= nil then st.env['\0top'] = ltop
        else st.env['\0top'] = vmap(st.fset, function (e) return M._field({ k = 'L' }, '->', 'top', st, layout, read_field, e) end) end
        if lbase == nil then st.env['\0base'] = { k = 'slot', i = 1 } elseif lbase ~= false and lbase ~= true then st.env['\0base'] = lbase end
        for k, v in pairs(slots) do st.slots[k] = v end
        for i, p in ipairs(d.params) do
            st.types[p.name] = p.type
            local v = args[i]
            if p.type and p.type.k == 'i' then v = lift1(function (x) return x and x.k == 'i' and int(x.v, p.type.w, p.type.u) or x end, v, st) end
            -- (a lua_State * is THE thread only when the caller handed THE thread: a finalizer runs on the main one)
            if p.isL and not (v and v.k == 'L') then v = v and v.k == 'sym' and v or nil end
            st.env[p.name] = v
        end
        d.graph = d.graph or require('cartograph.cfg').graph(d.node, d.src)
        local g = d.graph
        local cx = { returns = {}, rej = {} }
        -- THE FIXPOINT over the graph, in reverse postorder. A node JOINS what reaches it (exact per tag), except a
        -- LOOP HEAD, which keeps up to CAP distinct states (a loop over the arguments stays exact: one state per
        -- iteration value) and past that JOINS them into one widened state — values only go to unknown, tags only
        -- grow, so the fixpoint ends without unrolling anything
        local CAP = 8
        local S, dirty = {}, {}
        local function sig(x)
            local l = {}
            for k, v in pairs(x.env) do l[#l + 1] = k .. '=' .. key_of(v) end
            for k, v in pairs(x.slots) do l[#l + 1] = '#' .. k .. '=' .. v end
            table.sort(l)
            return table.concat(l, ';') .. (x.fwrite and '|w' or '')
        end
        local function enqueue(id) dirty[id] = true end
        local function grew(a, b) for t in pairs(b) do if not a[t] then return true end end return false end
        local function push(id, x)
            if not x or empty(x.fset) then return end
            if id == 'exit' then cx.returns[#cx.returns + 1] = { v = nil, fset = setof(x.fset), slots = x.slots, fwrite = x.fwrite, void = d.void, env = x.env }; return end
            local E = S[id]
            if not E then E = { list = {} }; S[id] = E end
            -- a non-head node joins what reaches it WITHIN A TOKEN (a loop head's distinct states keep theirs through
            -- the body, so an argument loop's iterations do not meet); past CAP tokens, everything joins
            if not g.heads[id] then
                if E.one then
                    local j = join(E.one, x)
                    j.tok = nil
                    if grew(E.one.fset, j.fset) or sig(j) ~= sig(E.one) then E.one = j; E.dirty = true; enqueue(id) end
                    return
                end
                local tk = x.tok or ''
                for _, it in ipairs(E.list) do
                    if it.sig == tk then
                        local j = join(it.st, x) -- (it keeps the entry's token: the same one)
                        if grew(it.st.fset, j.fset) or sig(j) ~= sig(it.st) then it.st = j; it.dirty = true; enqueue(id) end
                        return
                    end
                end
                E.list[#E.list + 1] = { sig = tk, st = copy(x), dirty = true }
                if #E.list > CAP then
                    local j
                    for _, it in ipairs(E.list) do j = join(j, it.st) end
                    j.tok = nil
                    E.one, E.list, E.dirty = j, {}, true
                end
                enqueue(id)
                return
            end
            if E.one then
                local j = join(E.one, x)
                if grew(E.one.fset, j.fset) or sig(j) ~= sig(E.one) then E.one = j; E.dirty = true; enqueue(id) end
                return
            end
            local k = sig(x)
            for _, it in ipairs(E.list) do
                if it.sig == k then
                    if grew(it.st.fset, x.fset) then it.st.fset = union(it.st.fset, x.fset); it.dirty = true; enqueue(id) end
                    return
                end
            end
            local nx = copy(x)
            nx.tok = (x.tok or '') .. '/' .. id .. '#' .. (#E.list + 1)
            E.list[#E.list + 1] = { sig = k, st = nx, dirty = true }
            if #E.list > CAP then
                -- WIDEN: the distinct states join into one
                local j
                for _, it in ipairs(E.list) do j = join(j, it.st) end
                E.one, E.list, E.dirty = j, {}, true
            end
            enqueue(id)
        end
        local function step(id, x)
            local node = g.nodes[id]
            local k = node.k
            x = copy(x)
            if k == 'nop' then for _, e in ipairs(node.succ) do push(e.to, x) end
            elseif k == 'stmt' then
                local after = exec(node.ast, x, cx)
                if after then for _, e in ipairs(node.succ) do push(e.to, after) end end
            elseif k == 'cond' then
                local v = rv(eval(node.ast, x, cx), x)
                if empty(x.fset) then return end
                local T, F, U = split(v, x.fset)
                for _, e in ipairs(node.succ) do
                    if e.on == 'T' then push(e.to, narrow(x, union(T, U))) elseif e.on == 'F' then push(e.to, narrow(x, union(F, U))) end
                end
            elseif k == 'switch' then
                local v = rv(eval(node.ast, x, cx), x)
                if empty(x.fset) then return end
                -- each element goes down every case its value MAY equal; default takes those no case SURELY equals
                local surely = {}
                for _, e in ipairs(node.succ) do
                    if e.on == 'case' then
                        local cv = rv(eval(e.val, copy(x), cx), x)
                        local set = {}
                        for el in pairs(x.fset) do
                            local r = binop('==', at(v, el), at(cv, el))
                            local b = truth(r)
                            if b ~= false then set[el] = true end
                            if b == true then surely[el] = true end
                        end
                        push(e.to, narrow(x, set))
                    end
                end
                for _, e in ipairs(node.succ) do
                    if e.on == 'default' then
                        local set = {}
                        for el in pairs(x.fset) do if not surely[el] then set[el] = true end end
                        push(e.to, narrow(x, set))
                    end
                end
            elseif k == 'ret' then
                local ex = kids(node.ast)[1]
                local v
                if ex then v = rv(eval(ex, x, cx), x) end
                if not empty(x.fset) then cx.returns[#cx.returns + 1] = { v = v, fset = setof(x.fset), slots = x.slots, fwrite = x.fwrite, env = x.env } end
            end
        end
        if g.entry == 'exit' then push('exit', st) else push(g.entry, st) end
        -- sweeps in reverse postorder until nothing is dirty
        local order = {}
        for id in pairs(g.rpo) do order[#order + 1] = id end
        table.sort(order, function (a, b) return g.rpo[a] < g.rpo[b] end)
        local more = true
        while more and not cx.over do
            more = false
            for _, id in ipairs(order) do
                if dirty[id] then
                    dirty[id] = nil
                    more = true
                    local E = S[id]
                    if E.one then
                        if E.dirty then E.dirty = false; step(id, E.one) end
                    else
                        for _, it in ipairs(E.list) do if it.dirty then it.dirty = false; step(id, it.st) end end
                    end
                    if A.steps > A.budget then cx.over = true; break end
                end
            end
        end
        local sum = { ret = {}, rej = cx.rej, vals = {}, over = cx.over, fwrite = false, top = {}, base = {} }
        local seen, sseen = {}, {}
        for _, r in ipairs(cx.returns) do
            for tg in pairs(r.fset) do
                -- (where this return leaves the stack, per element: the caller's L->top after the call)
                for _, key in ipairs { 'top', 'base' } do
                    local sv = r.env and at(r.env['\0' .. key], tg)
                    local sk = key .. tg
                    if sseen[sk] then if not veq(sum[key][tg] or nil, sv) then sum[key][tg] = false end
                    else sum[key][tg] = sv or false; sseen[sk] = true end
                end
                sum.ret[tg] = true
                local v = r.void and nil or at(r.v, tg)
                if seen[tg] then if not veq(sum.vals[tg] or nil, v) then sum.vals[tg] = false end
                else sum.vals[tg] = v or false; seen[tg] = true end
            end
            if r.fwrite then sum.fwrite = true end
            if sum.slots then
                for k2, v in pairs(r.slots) do if sum.slots[k2] ~= v then sum.slots[k2] = '?' end end
            else sum.slots = {}; for k2, v in pairs(r.slots) do sum.slots[k2] = v end end
        end
        sum.returns = cx.returns
        if cx.over then for tg in pairs(fset) do sum.ret[tg] = true; sum.rej[tg] = true end end
        return sum
    end
    return A
end

--- a function's ACCEPTANCE at one slot: every first-class tag (the number at several values) in ONE run per argument
--- count, ABSENT in one more -> { [tag] = 'always' | 'content' | 'never' }, over, the return values seen
function M.acceptance(A, ctx, d, args, pos, maxcount)
    local tags = {}
    for _, t in ipairs(ctx.reps.order) do
        if ctx.firstclass[t] then
            if t == ctx.numtag then for _, v in ipairs(ctx.numvars) do tags[v] = true end else tags[t] = true end
        end
    end
    -- ONE run: every (tag, count) with the slot present, and ABSENT at every count below it
    local set = {}
    for count = pos, maxcount do for t in pairs(tags) do set[t .. '@' .. count] = true end end
    for count = 0, pos - 1 do set['ABSENT@' .. count] = true end
    local slots = {}
    for i = 1, maxcount do if i ~= pos then slots[i] = '?' end end
    A.steps = 0 -- (the budget is PER RUN)
    local sum = A.run(d, args, slots, pos, set, false)
    local ret, rej, rets = {}, {}, {}
    for e in pairs(set) do
        local t = elem(e)
        if sum.ret[e] then ret[t] = true end
        if sum.rej[e] or not sum.ret[e] then rej[t] = true end
    end
    for _, r in ipairs(sum.returns or {}) do for e in pairs(r.fset) do rets[#rets + 1] = at(r.v, e) or false end end
    local over = sum.over
    -- (the number's VALUES join back into one tag: some accepted and some rejected is content-dependent)
    local out = {}
    for t in pairs(tags) do
        local base = ctx.numof[t] or t
        local r0 = out[base] or { ret = false, rej = false }
        r0.ret, r0.rej = r0.ret or (ret[t] or false), r0.rej or (rej[t] or false)
        out[base] = r0
    end
    out.ABSENT = { ret = ret.ABSENT or false, rej = rej.ABSENT or false }
    for t, b in pairs(out) do out[t] = b.ret and (b.rej and 'content' or 'always') or 'never' end
    return out, over, rets
end

--- THE CONTEXT, all from the tree: every function (per unit: each carries its own copies of the static inlines),
--- typedefs, enum constants, the no-return raisers, TValue's layout (the compiler's), the representatives, and the
--- SENTINELS — a VM field whose initializer in the tree is a set*V (`setnilV(&g->nilnode.val)`: niltv's cell is nil)
function M.context(src, cflags)
    local B, C = require 'cartograph.luajs.boundary', require 'cartograph.cjs'
    local sources = B.preprocess(src, cflags)
    local ctx = { defs = {}, unitdefs = {}, typedefs = {}, enums = {}, noret = B.noreturn(src) }
    local fq = vim.treesitter.query.parse('c', '(function_definition) @f')
    local tq = vim.treesitter.query.parse('c', '(type_definition type: (_) @t declarator: (_) @n)')
    local eq = vim.treesitter.query.parse('c', '(enumerator_list) @e')
    for _, s in ipairs(sources) do
        local root = vim.treesitter.get_string_parser(s.text, 'c'):parse()[1]:root()
        local ud = {}
        ctx.unitdefs[s.name] = ud
        local cur
        for id, node in tq:iter_captures(root, s.text, 0, -1) do
            if tq.captures[id] == 't' then cur = node
            else
                local ty = cur:type()
                if ty ~= 'struct_specifier' and ty ~= 'union_specifier' and ty ~= 'enum_specifier' then
                    local nm = tx(node, s.text):gsub('^%*+', '')
                    if node:type() == 'type_identifier' or node:type() == 'primitive_type' then ctx.typedefs[nm] = ctx.typedefs[nm] or tx(cur, s.text) end
                    if node:type() == 'pointer_declarator' then ctx.typedefs[(tx(node, s.text):gsub('^%*+%s*', ''))] = tx(cur, s.text) .. ' *' end
                end
            end
        end
        for _, node in eq:iter_captures(root, s.text, 0, -1) do
            local nextv = 0
            for _, en in ipairs(kids(node)) do
                if en:type() == 'enumerator' then
                    local nm = tx(en:field('name')[1], s.text)
                    local v = en:field('value')[1]
                    if v then local lv = literal(tx(v, s.text)); nextv = lv and lv.k == 'i' and asnum(lv) or nil end
                    if nextv and ctx.enums[nm] == nil then ctx.enums[nm] = nextv end
                    if nextv then nextv = nextv + 1 end
                end
            end
        end
        for _, f in fq:iter_captures(root, s.text, 0, -1) do
            local decl = f:field('declarator')[1]
            local ptrret = false
            while decl and decl:type() == 'pointer_declarator' do ptrret = true; decl = decl:field('declarator')[1] end
            if decl and decl:type() == 'function_declarator' then
                local nmnode = decl:field('declarator')[1]
                local name = nmnode and tx(nmnode, s.text)
                local params = {}
                for _, pd in ipairs(kids(decl:field('parameters')[1])) do
                    if pd:type() == 'parameter_declaration' then
                        local pty = tx(pd:field('type')[1], s.text)
                        local dn, isptr = pd:field('declarator')[1], false
                        while dn and (dn:type() == 'pointer_declarator' or dn:type() == 'abstract_pointer_declarator') do isptr = true; dn = dn:field('declarator')[1] end
                        local pname = dn and dn:type() == 'identifier' and tx(dn, s.text) or ('$' .. (#params + 1))
                        params[#params + 1] = { name = pname, type = isptr and { k = 'p' } or M.ctype(pty, ctx.typedefs), isL = isptr and pty:find('lua_State') ~= nil }
                    end
                end
                local rty = tx(f:field('type')[1], s.text)
                local d = { id = s.name .. ':' .. tostring(name), name = name, src = s.text, unit = s.name, node = f, params = params,
                    void = not ptrret and vim.trim(rty) == 'void' }
                if name then ud[name] = ud[name] or d; ctx.defs[name] = ctx.defs[name] or d end
            end
        end
    end
    -- TValue's layout and the representatives
    local unit
    for _, s in ipairs(sources) do if s.name == 'lj_obj.c' then unit = s end end
    ctx.layout = assert(C.compiler_layout({ src = unit.text, type = 'TValue', header = 'lj_obj.h', include = src, cflags = cflags }))
    ctx.reps = assert(M.reps(src, cflags))
    -- sentinels: `set<x>V(&<var>-><a>.<b>)` in the tree's own units, <x> a tag's name
    ctx.sentinels = {}
    for _, path in ipairs(vim.fn.globpath(src, '*.c', false, true)) do
        for setter, fp in (readfile(path) or ''):gmatch('(set%a+V)%(%s*&%s*[%w_]+%s*%->%s*([%w_]+%.[%w_]+)%s*%)') do
            local nm = setter:match('^set(%a+)V$'):upper()
            if ctx.reps.tag[nm] then ctx.sentinels[fp] = nm end
        end
    end
    ctx.builtins = C.BUILTINS
    ctx.sources = sources
    -- the NUMBER's representatives: several values (a check may accept 10 and refuse 1.5 — tonumber's base), each
    -- with the number tag's name, so they join back into one
    ctx.numtag, ctx.numvars, ctx.numof = nil, {}, {}
    for name, t in pairs(ctx.reps.tag) do if ctx.reps.matrix.tvisnumber and ctx.reps.matrix.tvisnumber[name] == 1 then ctx.numtag = name end end
    local fb = ffi.new('double[1]')
    local ub = ffi.cast('uint64_t *', fb)
    for i, v in ipairs({ 10, 1.5, 0, -1, 3 }) do
        fb[0] = v
        local u = ub[0]
        local hex = ('%08x%08x'):format(tonumber(bit.rshift(u, 32)), tonumber(bit.band(u, 0xffffffff)))
        local nm = ctx.numtag .. '#' .. i
        ctx.reps.tag[nm] = { value = ctx.reps.tag[ctx.numtag].value, u64 = hex }
        ctx.numvars[#ctx.numvars + 1] = nm
        ctx.numof[nm] = ctx.numtag
    end
    -- FIRST-CLASS tags: all but those the API itself conflates with nil (lua_type -> LUA_TNIL for a tag that is not
    -- nil: upvalues, traces — no Lua value holds one)
    ctx.firstclass = {}
    local A0 = M.analyzer(ctx)
    local lt = ctx.defs.lua_type
    local luanil
    for n in (readfile(src .. '/lua.h') or ''):gmatch('#define%s+LUA_TNIL%s+(%d+)') do luanil = tonumber(n) end
    for _, name in ipairs(ctx.reps.order) do
        local sum = lt and A0.run(lt, { { k = 'L' }, int(1), n = 2 }, {}, 1, { [name .. '@1'] = true }, false)
        local v = sum and sum.vals[name .. '@1'] or nil
        local code = v and v.k == 'i' and asnum(v) or nil
        ctx.firstclass[name] = not (code == luanil and ctx.reps.matrix.tvisnil[name] ~= 1)
    end
    return ctx
end

--- Lua's type() name of each tag (lj_obj_itypename, read from lj_obj.c by position: the tags' ~N order)
function M.typenames(src, reps)
    local names = {}
    local itn = (readfile(src .. '/lj_obj.c') or ''):match('lj_obj_itypename%[%]%s*=%s*{(.-)}')
    for s in (itn or ''):gmatch('"([^"]*)"') do names[#names + 1] = s end
    local out = { ABSENT = 'absent' }
    for name, t in pairs(reps.tag) do out[name] = names[bit.band(bit.bnot(t.value), 0xffffffff) + 1] end
    return out
end

-- ── THE MEASUREMENT ────────────────────────────────────────────────────────────────────────────────────────────────
--- a position's reading as type() names: accepted (always or content-dependent), always, the absent and nil status,
--- and whether it is TAG-INDEPENDENT (every first-class tag the same status: an unread or `any` position)
function M.reading(acc, tn)
    local a, al, statuses = {}, {}, {}
    for tag, st in pairs(acc) do
        if tag ~= 'ABSENT' then
            statuses[st] = true
            if st ~= 'never' then a[tn[tag]] = true end
            if st == 'always' then al[tn[tag]] = true end
        end
    end
    local function l(set) local x = vim.tbl_keys(set); table.sort(x); return x end
    return { accepted = l(a), always = l(al), absent = acc.ABSENT, nilst = acc.NIL, untyped = vim.tbl_count(statuses) == 1 }
end

--- the RESULT COUNT a C function's return value says: a lua_CFunction returns it; a fast function's C fallback
--- returns FFH_RES(n) (lj_lib.h's own `#define FFH_RES(n) ((n)+OFFSET)`), FFH_RETRY (its define) being no count
function M.result_rule(src)
    local h = readfile(src .. '/lj_lib.h') or ''
    local off = tonumber(h:match('#define%s+FFH_RES%(n%)%s*%(%(n%)%+(%d+)%)'))
    local retry = tonumber(h:match('#define%s+FFH_RETRY%s+(%d+)'))
    return { offset = off, retry = retry }
end

--- the COMPARISON of a path reading with a checker's (leaf 1's) at one position, both as type() names: nil acceptance
--- is optionality on both sides, a checker's `any` is every first-class type -> nil (the same) | a named difference
--- ('finer: also accepts …' — a coercion or a value the checker's name did not say; 'narrower: rejects …'; or both)
function M.compare(path_acc, path_opt, chk_acc, chk_opt, firstnames)
    local a, b = {}, {}
    for _, t in ipairs(path_acc) do a[t] = true end
    for _, t in ipairs(chk_acc) do
        if t == 'any' then for n in pairs(firstnames) do b[n] = true end else b[t] = true end
    end
    -- OPTIONAL means may be ABSENT on both sides (checkany takes nil as a value, and rejects absence); a checker that
    -- is optional also accepts nil
    if chk_opt then b['nil'] = true end
    local more, less = {}, {}
    for t in pairs(a) do if not b[t] then more[#more + 1] = t end end
    for t in pairs(b) do if not a[t] then less[#less + 1] = t end end
    table.sort(more); table.sort(less)
    local out = {}
    if #more > 0 then out[#out + 1] = 'finer: also accepts ' .. table.concat(more, '|') end
    if #less > 0 then out[#out + 1] = 'narrower: rejects ' .. table.concat(less, '|') end
    if (path_opt or false) ~= (chk_opt or false) then out[#out + 1] = ('optional: path %s / checker %s'):format(tostring(path_opt), tostring(chk_opt)) end
    if #out == 0 then return nil end
    return table.concat(out, '; ')
end

--- opts: { src, cflags, config, positions = K (default 4), witness = bool, leaf1 = csig's measure (for the JOIN) }
function M.measure(opts)
    local PM, OJ = require 'cartograph.luajs.packmap', require 'cartograph.oraclejoin'
    local src = opts.src
    local t0 = vim.uv.hrtime()
    local ctx = M.context(src, opts.cflags)
    local tn = M.typenames(src, ctx.reps)
    for name, n in pairs(ctx.numof) do tn[name] = tn[n] end
    local reg = PM.registrations(src, opts.config)
    local _, where = PM.oracle_library(reg)
    local rr = M.result_rule(src)
    local A = M.analyzer(ctx)
    local K = opts.positions or 4
    local rows, stats = {}, { functions = 0, positions = 0, typed = 0, untyped = 0, over = 0, raise_only = 0 }
    for _, f in ipairs(reg.funcs) do
        local rname = where[f.module]
        if not f.noreg and rname and f.cfn and ctx.defs[f.cfn] then
            local q = (rname == '_G' and '' or (rname .. '.')) .. f.name
            local d = ctx.defs[f.cfn]
            local row = { cfn = f.cfn, kind = f.kind, pos = {} }
            local results = {}
            local anyret = false
            for k = 1, K do
                local acc, over, rets = M.acceptance(A, ctx, d, { { k = 'L' }, n = 1 }, k, K + 1)
                for _, v in ipairs(rets) do results[#results + 1] = v end
                local r = M.reading(acc, tn)
                r.over = over
                row.pos[k] = r
                if #r.accepted > 0 or r.absent ~= 'never' then anyret = true end
                stats.positions = stats.positions + 1
                if r.untyped then stats.untyped = stats.untyped + 1 else stats.typed = stats.typed + 1 end
                if over then stats.over = stats.over + 1 end
            end
            -- a C body that NEVER returns (the VM's fast path handles success; the C only raises: assert)
            row.raise_only = not anyret
            if row.raise_only then stats.raise_only = stats.raise_only + 1 end
            -- RESULT COUNTS
            local counts, unknown = {}, false
            for _, v in ipairs(results) do
                if v and v.k == 'i' then
                    local n = asnum(v)
                    if f.kind == 'CF' then counts[n] = true
                    elseif rr.offset and n ~= rr.retry then counts[n - rr.offset] = true end
                else unknown = true end
            end
            local cl = vim.tbl_keys(counts); table.sort(cl)
            row.results = { counts = cl, unknown = unknown }
            rows[q] = row
            stats.functions = stats.functions + 1
        end
    end
    local out = { rows = rows, stats = stats, seconds = (vim.uv.hrtime() - t0) / 1e9,
        firstclass = ctx.firstclass, reps = ctx.reps }
    -- THE JOIN with leaf 1 (the checker reading), at the positions leaf 1 states and closes
    if opts.leaf1 then
        local L1 = opts.leaf1.ours
        local inputs = {}
        -- (a RAISE-ONLY C body — the VM's fast path does the work, the C only raises — states no contract to join)
        for q in pairs(rows) do if L1[q] and L1[q].sig and not rows[q].raise_only then inputs[#inputs + 1] = q end end
        table.sort(inputs)
        local function kvobj(map) local keys = vim.tbl_keys(map); table.sort(keys); return { keys = keys, o = map } end
        local positions = {}
        for _, q in ipairs(inputs) do
            local s1 = L1[q].sig
            local ps = {}
            for k, p in pairs(s1.params) do if not s1.open[k] and not p.dispatch and p.types[1] ~= '?' and rows[q].pos[k] then ps[#ps + 1] = k end end
            table.sort(ps)
            positions[q] = ps
        end
        local CS = require 'cartograph.luajs.csig'
        local firstnames = {}
        for t, yes in pairs(ctx.firstclass) do if yes then firstnames[tn[t]] = true end end
        local function diffs(a, b)
            for _, k in ipairs(a.keys) do
                local x, y = a.o[k].o, b.o[k] and b.o[k].o
                if y then
                    local d = M.compare(vim.split(x.t, '|', { trimempty = true }), x.opt, vim.split(y.t, '|', { trimempty = true }), y.opt, firstnames)
                    if d then return d end
                end
            end
            return nil
        end
        out.join = OJ.run({
            inputs = inputs,
            read = function (q)
                if #positions[q] == 0 then return nil, 'leaf 1 states no closed position here' end
                local v = {}
                for _, k in ipairs(positions[q]) do
                    local r = rows[q].pos[k]
                    v[tostring(k)] = kvobj({ t = table.concat(r.accepted, '|'), opt = r.absent ~= 'never' })
                end
                return kvobj(v)
            end,
            oracle = function (q)
                local v = {}
                for _, k in ipairs(positions[q]) do
                    local p = L1[q].sig.params[k]
                    v[tostring(k)] = kvobj({ t = table.concat(CS.accepted(p), '|'), opt = p.opt })
                end
                return kvobj(v)
            end,
            eq = function (a, b) return diffs(a, b) == nil end,
            cause = function (_, _, a, b) return diffs(a, b) or 'other' end,
            examples = 6,
        })
        -- the positions ONLY the path reading types (leaf 1 refused the function, or left the position open)
        local only = {}
        for q, row in pairs(rows) do
            local s1 = L1[q] and L1[q].sig
            for k, r in pairs(row.pos) do
                local stated = s1 and s1.params[k] and not s1.open[k]
                if not r.untyped and not stated and #r.accepted > 0 then only[#only + 1] = { q = q, k = k } end
            end
        end
        table.sort(only, function (a, b) if a.q ~= b.q then return a.q < b.q end return a.k < b.k end)
        out.only = only
    end
    -- THE WITNESS on the positions only this reading types (csig's: a child LuaJIT, LuaJIT's own error wording)
    if opts.witness ~= false and out.only then
        local CS = require 'cartograph.luajs.csig'
        local jobs, byq = {}, {}
        for _, o in ipairs(out.only) do byq[o.q] = byq[o.q] or {}; table.insert(byq[o.q], o.k) end
        for q, ks in pairs(byq) do
            local P, pre = {}, {}
            for k, r in pairs(rows[q].pos) do pre[k] = { types = r.always[1] and r.always or r.accepted } end
            for _, k in ipairs(ks) do
                local r = rows[q].pos[k]
                P[k] = { types = r.always[1] and r.always or r.accepted, all = r.accepted, opt = r.absent ~= 'never' }
            end
            jobs[#jobs + 1] = { q = q, params = P, prefix = pre }
        end
        table.sort(jobs, function (a, b) return a.q < b.q end)
        local W = CS.witness(jobs, PM.vocabulary(src))
        local tally, notes = { confirmed = 0, contradicted = 0, named = 0, other = 0, lost = 0 }, {}
        local firstnames2 = {}
        for t, yes in pairs(ctx.firstclass) do if yes then firstnames2[tn[t]] = true end end
        for _, j in ipairs(jobs) do
            local w = W[j.q]
            if w.lost then tally.lost = tally.lost + 1 end
            for _, pr in ipairs(w.probes) do
                local r = rows[j.q].pos[pr.k]
                if pr.ok then
                    -- a probe the path reading REJECTS was accepted by LuaJIT: a contradiction of this reading
                    tally.contradicted = tally.contradicted + 1
                    notes[#notes + 1] = ('%s #%d: LuaJIT ACCEPTED a value the path reading rejects'):format(j.q, pr.k)
                elseif pr.at == pr.k and pr.expected then
                    local exp = pr.expected:gsub(' expected$', '')
                    local ok = exp == 'value' and r.absent == 'never'
                    for _, t in ipairs(r.accepted) do if exp:find(t, 1, true) then ok = true end end
                    -- a message naming a type OUTSIDE type()'s names ("coroutine", "C type"): the library's own word
                    local named = not ok and not firstnames2[exp] and not exp:find(' or ', 1, true)
                    if named then tally.named = (tally.named or 0) + 1; notes[#notes + 1] = ('%s #%d: LuaJIT names the type "%s" (path reading %s)'):format(j.q, pr.k, exp, table.concat(r.accepted, '|'))
                    elseif ok then tally.confirmed = tally.confirmed + 1
                    else tally.contradicted = tally.contradicted + 1; notes[#notes + 1] = ('%s #%d: path reading %s, LuaJIT says "%s"'):format(j.q, pr.k, table.concat(r.accepted, '|'), pr.expected) end
                else
                    tally.other = tally.other + 1
                    notes[#notes + 1] = ('%s #%d: %s'):format(j.q, pr.k, pr.at and ('raised at #' .. pr.at .. ': ' .. tostring(pr.expected)) or tostring(pr.other))
                end
            end
        end
        out.witness = { functions = #jobs, tally = tally, notes = notes }
    end
    return out
end

return M
