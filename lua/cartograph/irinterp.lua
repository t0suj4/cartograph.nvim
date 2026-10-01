-- cartograph.irinterp — an ABSTRACT INTERPRETER over LLVM IR (CART-1259): cinterp's reading — which elements of a
-- finite set (a slot's value x the frame's count) reach a return, with which value, and which a no-return call —
-- over the IR a compiler lowered a unit to (cartograph.ir), so the language's semantics are the compiler's: C++'s
-- templates, overloads, references and `this` arrive resolved, every access a typed load / store at an offset.
--   VALUES, three-valued: { k = 'i', v = uint64 bits, w } · { k = 'f', v } · { k = 'p', r = region, o = offset |
--   false (unknown) } — a region: an alloca of a frame, a global '@g', 'null', 'abs' (an absolute address of a
--   probe's memory: ctx.memory), or one the driver names ('vp') — · { k = 'agg', f = { … } } · nil = unknown; a value
--   that differs per element is { k = 'vec', by = { [element] = value } }. A condition over a vector PARTITIONS the
--   element set and each part goes its own way.
--   MEMORY per path: regions of cells { [offset] = { n = bytes, v } }, zero ranges (memset 0), a region HAVOC'd by an
--   unknown call (all unknown); a global's constant initializer and the probe's words lie beneath.
--   CALLS: a function defined in the program is run INLINE on the caller's memory, its return states joined (exactly
--   where their element sets are disjoint); a noreturn one ends the path (an abort); anything else returns unknown
--   and havocs what its pointer arguments reach. A recursion, a depth past ctx.max_depth (48): an unknown call.
--   LOOPS: blocks in reverse postorder; a loop head keeps up to CAP (8) distinct states, then widens by joining.
-- The engine names no language and no runtime.
local ffi, bit = require 'ffi', require 'bit'
local IR = require 'cartograph.ir'
local M = {}

local U64, I64 = ffi.typeof('uint64_t'), ffi.typeof('int64_t')
local BINOPS = { add = true, sub = true, mul = true, udiv = true, sdiv = true, urem = true, srem = true, shl = true,
    lshr = true, ashr = true, ['and'] = true, ['or'] = true, xor = true, fadd = true, fsub = true, fmul = true,
    fdiv = true, frem = true }
local CASTS = { trunc = true, zext = true, sext = true, fptrunc = true, fpext = true, fptoui = true, fptosi = true,
    uitofp = true, sitofp = true, ptrtoint = true, inttoptr = true, bitcast = true, addrspacecast = true }
local ONES = U64(0xFFFFFFFFFFFFFFFFULL)
local function mask(w) if w >= 64 then return ONES end return bit.lshift(U64(1), w) - 1 end
local function int(v, w) return { k = 'i', v = bit.band(U64(v), mask(w)), w = w } end
M.int = int
local function signed(x)
    if x.w >= 64 then return ffi.cast('int64_t', x.v) end
    local top = bit.band(bit.rshift(x.v, x.w - 1), 1)
    if top == U64(1) then return ffi.cast('int64_t', x.v) - ffi.cast('int64_t', bit.lshift(U64(1), x.w)) end
    return ffi.cast('int64_t', x.v)
end
local dbits = ffi.new('uint64_t[1]')
local ddbl = ffi.cast('double *', dbits)
local fbits = ffi.new('uint32_t[1]')
local fflt = ffi.cast('float *', fbits)

-- ── per-element vectors ────────────────────────────────────────────────────────────────────────────────────────
local function at(v, e) if v and v.k == 'vec' then return v.by[e] end return v end
M.at = at
local function key_of(v)
    if v == nil then return '?' end
    local k = v.k
    if k == 'i' then return 'i' .. tostring(v.v):gsub('ULL$', '') .. ':' .. v.w end
    if k == 'f' then return 'f' .. tostring(v.v) end
    if k == 'p' then return 'p' .. v.r .. '+' .. tostring(v.o) end
    if k == 'agg' then
        local l = {}
        for i = 1, v.n or #v.f do l[i] = key_of(v.f[i]) end
        return '{' .. table.concat(l, ',') .. '}'
    end
    if k == 'vec' then
        local l = {}
        for e, x in pairs(v.by) do l[#l + 1] = e .. '=' .. key_of(x) end
        table.sort(l)
        return '[' .. table.concat(l, ';') .. ']'
    end
    return k
end
M.key_of = key_of
local function veq(a, b)
    if a == b then return true end
    if a == nil or b == nil then return false end
    if a.k ~= b.k then return false end
    if a.k == 'i' then return a.v == b.v and a.w == b.w end
    if a.k == 'f' then return a.v == b.v end
    if a.k == 'p' then return a.r == b.r and a.o == b.o end
    return key_of(a) == key_of(b)
end
--- a per-element function over a set, collapsed when every element agrees
local function vmap(set, fn)
    local by, first, uniform, any = {}, nil, true, false
    for e in pairs(set) do
        local r = fn(e)
        by[e] = r
        if not any then first = r; any = true elseif uniform and not veq(first, r) then uniform = false end
    end
    if not any then return nil end
    if uniform then return first end
    return { k = 'vec', by = by }
end
local function isvec(v) return v ~= nil and v.k == 'vec' end
local function lift1(fn, a, set) if isvec(a) then return vmap(set, function (e) return fn(at(a, e)) end) end return fn(a) end
local function lift2(fn, a, b, set)
    if isvec(a) or isvec(b) then return vmap(set, function (e) return fn(at(a, e), at(b, e)) end) end
    return fn(a, b)
end
local function setof(t) local s = {} for k in pairs(t) do s[k] = true end return s end
local function empty(s) return next(s) == nil end
--- an element's tag and count (`OBJECT@2`)
local ecache = {}
local function elem(e)
    local c = ecache[e]
    if not c then local t, n = e:match('^(.-)@(%d+)$'); c = { t or e, tonumber(n) or 0 }; ecache[e] = c end
    return c[1], c[2]
end
M.elem = elem

-- ── scalar operations ──────────────────────────────────────────────────────────────────────────────────────────
local function binop(op, a, b, w)
    if not (a and b) then
        -- (an absorbing operand decides alone: x & 0, x | ones, x * 0)
        local k = a or b
        if k and k.k == 'i' then
            if (op == 'and' or op == 'mul') and k.v == U64(0) then return int(0, w) end
            if op == 'or' and k.v == mask(w) then return int(mask(w), w) end
        end
        return nil
    end
    if a.k == 'f' or b.k == 'f' then
        if a.k ~= 'f' or b.k ~= 'f' then return nil end
        local x, y = a.v, b.v
        if op == 'fadd' then return { k = 'f', v = x + y } elseif op == 'fsub' then return { k = 'f', v = x - y }
        elseif op == 'fmul' then return { k = 'f', v = x * y } elseif op == 'fdiv' then return { k = 'f', v = x / y }
        elseif op == 'frem' then return { k = 'f', v = math.fmod(x, y) } end
        return nil
    end
    -- (pointer arithmetic on integers: ptrtoint'd addresses, an offset into the same region)
    if a.k == 'p' or b.k == 'p' then
        if op == 'add' and a.k == 'p' and b.k == 'i' and a.o then return { k = 'p', r = a.r, o = a.o + tonumber(signed(b)) } end
        if op == 'sub' and a.k == 'p' and b.k == 'p' and a.r == b.r and a.o and b.o then return int(I64(a.o - b.o), w) end
        return nil
    end
    if a.k ~= 'i' or b.k ~= 'i' then return nil end
    local x, y = a.v, b.v
    if op == 'add' then return int(x + y, w) elseif op == 'sub' then return int(x - y, w)
    elseif op == 'mul' then return int(x * y, w)
    elseif op == 'and' then return int(bit.band(x, y), w) elseif op == 'or' then return int(bit.bor(x, y), w)
    elseif op == 'xor' then return int(bit.bxor(x, y), w)
    elseif op == 'shl' then local s = tonumber(y); if s >= w then return nil end return int(bit.lshift(x, s), w)
    elseif op == 'lshr' then local s = tonumber(y); if s >= w then return nil end return int(bit.rshift(x, s), w)
    elseif op == 'ashr' then local s = tonumber(y); if s >= w then return nil end return int(bit.arshift(signed(a), s), w)
    elseif op == 'udiv' then if y == U64(0) then return nil end return int(x / y, w)
    elseif op == 'urem' then if y == U64(0) then return nil end return int(x % y, w)
    elseif op == 'sdiv' or op == 'srem' then
        local sx, sy = signed(a), signed(b)
        if sy == 0 then return nil end
        local q = sx / sy
        if op == 'sdiv' then return int(q, w) end
        return int(sx - q * sy, w)
    end
    return nil
end
M._binop = binop

local function truth(v)
    if v == nil then return nil end
    if v.k == 'i' then return v.v ~= U64(0) end
    if v.k == 'p' then if v.r == 'null' then return false end if v.r == 'abs' then return v.o ~= 0 end return true end
    return nil
end

local function icmp(pred, a, b, w)
    if not (a and b) then return nil end
    local function res(t) return int(t and 1 or 0, 1) end
    if a.k == 'p' or b.k == 'p' then
        -- (a pointer vs integer 0 / null; two pointers: one region compares offsets; a null vs a real object differs)
        local function isnull(p) return (p.k == 'p' and (p.r == 'null' or (p.r == 'abs' and p.o == 0))) or (p.k == 'i' and p.v == U64(0)) end
        if pred ~= 'eq' and pred ~= 'ne' then
            if a.k == 'p' and b.k == 'p' and a.r == b.r and a.o and b.o then
                local x, y = a.o, b.o
                local t = ({ ult = x < y, ule = x <= y, ugt = x > y, uge = x >= y, slt = x < y, sle = x <= y, sgt = x > y, sge = x >= y })[pred]
                if t ~= nil then return res(t) end
            end
            return nil
        end
        local same
        if isnull(a) and isnull(b) then same = true
        elseif isnull(a) or isnull(b) then
            local o = isnull(a) and b or a
            if o.k == 'p' and o.r ~= 'abs' then same = false elseif o.k == 'p' and o.r == 'abs' then same = o.o == 0 else return nil end
        elseif a.k == 'p' and b.k == 'p' then
            if a.r == b.r then if a.o and b.o then same = a.o == b.o else return nil end
            elseif a.r == 'abs' or b.r == 'abs' then return nil
            else same = false end
        else return nil end
        if pred == 'eq' then return res(same) else return res(not same) end
    end
    if a.k ~= 'i' or b.k ~= 'i' then return nil end
    local x, y = a.v, b.v
    if pred == 'eq' then return res(x == y) elseif pred == 'ne' then return res(x ~= y)
    elseif pred == 'ugt' then return res(x > y) elseif pred == 'uge' then return res(x >= y)
    elseif pred == 'ult' then return res(x < y) elseif pred == 'ule' then return res(x <= y) end
    local sx, sy = signed(a), signed(b)
    if pred == 'sgt' then return res(sx > sy) elseif pred == 'sge' then return res(sx >= sy)
    elseif pred == 'slt' then return res(sx < sy) elseif pred == 'sle' then return res(sx <= sy) end
    return nil
end

local function fcmp(pred, a, b)
    if not (a and b and a.k == 'f' and b.k == 'f') then return nil end
    local x, y = a.v, b.v
    local uno = x ~= x or y ~= y
    local function res(t) return int(t and 1 or 0, 1) end
    local base = pred:sub(2)
    local t
    if base == 'eq' then t = x == y elseif base == 'ne' then t = x ~= y elseif base == 'gt' then t = x > y
    elseif base == 'ge' then t = x >= y elseif base == 'lt' then t = x < y elseif base == 'le' then t = x <= y end
    if pred == 'true' then return res(true) elseif pred == 'false' then return res(false)
    elseif pred == 'ord' then return res(not uno) elseif pred == 'uno' then return res(uno) end
    if t == nil then return nil end
    if pred:sub(1, 1) == 'o' then return res(t and not uno) end
    return res(t or uno)
end

local function cast(op, v, from, to)
    if v == nil then return nil end
    if op == 'bitcast' or op == 'addrspacecast' then
        if v.k == 'i' and to.k == 'f' and to.w == 64 then dbits[0] = v.v; return { k = 'f', v = ddbl[0] } end
        if v.k == 'f' and to.k == 'i' and to.w == 64 then ddbl[0] = v.v; return int(dbits[0], 64) end
        if v.k == 'i' and to.k == 'f' and to.w == 32 then fbits[0] = tonumber(v.v); return { k = 'f', v = fflt[0] } end
        if v.k == 'f' and to.k == 'i' and to.w == 32 then fflt[0] = v.v; return int(fbits[0], 32) end
        return v
    end
    if op == 'trunc' then if v.k ~= 'i' then return nil end return int(v.v, to.w) end
    if op == 'zext' then if v.k ~= 'i' then return nil end return int(v.v, to.w) end
    if op == 'sext' then if v.k ~= 'i' then return nil end return int(ffi.cast('uint64_t', signed(v)), to.w) end
    if op == 'ptrtoint' then
        if v.k ~= 'p' then return nil end
        if v.r == 'null' then return int(0, to.w) end
        if v.r == 'abs' and v.o then return int(U64(v.o), to.w) end
        -- (another region's address is no number we know; kept a pointer so arithmetic and a cast back stay exact)
        return { k = 'p', r = v.r, o = v.o, asint = to.w }
    end
    if op == 'inttoptr' then
        if v.k == 'p' then return { k = 'p', r = v.r, o = v.o } end
        if v.k ~= 'i' then return nil end
        if v.v == U64(0) then return { k = 'p', r = 'null', o = 0 } end
        return { k = 'p', r = 'abs', o = tonumber(v.v) }
    end
    if op == 'sitofp' then if v.k ~= 'i' then return nil end return { k = 'f', v = tonumber(signed(v)) } end
    if op == 'uitofp' then if v.k ~= 'i' then return nil end return { k = 'f', v = tonumber(v.v) } end
    if op == 'fptosi' or op == 'fptoui' then
        if v.k ~= 'f' or v.v ~= v.v or v.v == math.huge or v.v == -math.huge then return nil end
        local t = v.v >= 0 and math.floor(v.v) or -math.floor(-v.v)
        return int(ffi.cast('uint64_t', I64(t)), to.w)
    end
    if op == 'fpext' or op == 'fptrunc' then if v.k ~= 'f' then return nil end return v end
    return nil
end

-- ── memory ─────────────────────────────────────────────────────────────────────────────────────────────────────
-- a region: { cells = { [off] = { n, v } }, zero = { { lo, hi } … }, havoc = bool }; regions are copied on write
local function region_copy(r)
    local c = { cells = {}, zero = r.zero, havoc = r.havoc }
    for o, cell in pairs(r.cells) do c.cells[o] = cell end
    return c
end

--- the analyzer over a PROGRAM: prog.fn(name) -> parsed function, its module | nil; prog.mod (layout); ctx = {
--- memory = { [tostring(int64 addr)] = hex word }, symaddr = { ['@name'] = number }, budget, max_depth, cap }
function M.analyzer(prog, ctx)
    ctx = ctx or {}
    local A = { steps = 0, budget = ctx.budget or 400000, frames = 0 }
    local CAP = ctx.cap or 8
    local MAXD = ctx.max_depth or 48
    local memory = ctx.memory or {}
    local mod0 = prog.mod

    local function size(ty, mod) return IR.size(mod or mod0, ty) end

    -- (a state: fset, env (SSA), mem (regions, copy on write), own (regions this state may write in place))
    local function copy(st, fset)
        local c = { fset = fset or setof(st.fset), env = {}, mem = {}, own = {}, frame = st.frame }
        for k, v in pairs(st.env) do c.env[k] = v end
        for k, v in pairs(st.mem) do c.mem[k] = v end
        return c
    end
    local function wregion(st, r)
        local reg = st.mem[r]
        if not reg then reg = { cells = {} } st.mem[r] = reg; st.own[r] = true; return reg end
        if not st.own[r] then reg = region_copy(reg); st.mem[r] = reg; st.own[r] = true end
        return reg
    end

    local const -- (forward: a constant operand -> value)
    -- the value of a GLOBAL's constant initializer at an offset (a table of cells, built once per global)
    local gcells = {}
    local function gfill(g, mod)
        local c = gcells[g.name]
        if c then return c end
        c = { cells = {}, zero = {} }
        gcells[g.name] = c
        local function put(ty, v, off)
            if not v then return end
            local rty = IR.resolve(mod, ty)
            if not rty then return end
            if v.k == 'c' and v.zero then c.zero[#c.zero + 1] = { off, off + size(rty, mod) }; return end
            if v.k == 'c' and v.undef then return end
            if v.k == 'c' and v.str then
                -- (c"…": bytes, \XX escapes)
                local s = v.str:gsub('\\(%x%x)', function (h) return string.char(tonumber(h, 16)) end)
                for i = 1, #s do c.cells[off + i - 1] = { n = 1, v = int(s:byte(i), 8) } end
                return
            end
            if v.k == 'c' and v.agg then
                for i, el in ipairs(v.agg) do
                    local fo
                    if rty.k == 's' then fo = IR.field_offset(mod, rty, i) else fo = (i - 1) * size(rty.e, mod) end
                    if fo then put(el.ty, el.v, off + fo) end
                end
                return
            end
            local x = const(v, ty, mod)
            if x then c.cells[off] = { n = size(rty, mod), v = x } end
        end
        if g.init then put(g.ty, g.init, 0) end
        return c
    end

    -- a constant operand -> value
    function const(v, ty, mod)
        if v.k == 'c' then
            if v.i then return int(v.i, (ty and ty.k == 'i') and ty.w or 64) end
            if v.f then return { k = 'f', v = v.f } end
            if v.null then return { k = 'p', r = 'null', o = 0 } end
            if v.zero then
                local t = IR.resolve(mod, ty)
                if t and t.k == 'i' then return int(0, t.w) end
                if t and t.k == 'p' then return { k = 'p', r = 'null', o = 0 } end
                if t and t.k == 'f' then return { k = 'f', v = 0 } end
                return nil
            end
            return nil
        end
        if v.k == 'g' then
            local a = ctx.symaddr and ctx.symaddr[v.n]
            if a then return { k = 'p', r = 'abs', o = a } end
            return { k = 'p', r = v.n, o = 0 }
        end
        if v.k == 'cgep' then
            local base = const(v.base, { k = 'p' }, mod)
            if not (base and base.k == 'p' and base.o) then return nil end
            local off = base.o
            local cur = v.T
            for i, ix in ipairs(v.idx) do
                local n = ix.v.k == 'c' and ix.v.i and tonumber(signed(int(ix.v.i, ix.ty.w or 64)))
                if not n then return nil end
                if i == 1 then off = off + n * size(cur, mod)
                else
                    local r = IR.resolve(mod, cur)
                    if r and r.k == 's' then local fo, ft = IR.field_offset(mod, r, n + 1); if not fo then return nil end off = off + fo; cur = ft
                    elseif r and (r.k == 'a' or r.k == 'x') then cur = r.e; off = off + n * size(cur, mod)
                    else return nil end
                end
            end
            return { k = 'p', r = base.r, o = off }
        end
        if v.k == 'ccast' then return cast(v.op, const(v.v, v.from, mod), v.from, v.to) end
        return nil
    end

    -- a word of the probe's memory
    local function memword(addr)
        local h = memory[tostring(I64(addr))]
        if not h then return nil end
        return U64(tonumber(h:sub(1, 8), 16)) * U64(2 ^ 32) + U64(tonumber(h:sub(9), 16))
    end

    -- LOAD ty at one pointer (one element's)
    local function load1(st, ty, p, mod)
        if not (p and p.k == 'p' and p.o) then return nil end
        local rty = IR.resolve(mod, ty)
        if not rty then return nil end
        local n = size(rty, mod)
        if rty.k == 's' or rty.k == 'a' then
            local f, cnt = {}, rty.k == 's' and #rty.f or rty.n
            if cnt > 64 then return nil end
            for i = 1, cnt do
                local fo, ft
                if rty.k == 's' then fo, ft = IR.field_offset(mod, rty, i) else ft = rty.e; fo = (i - 1) * size(ft, mod) end
                f[i] = load1(st, ft, { k = 'p', r = p.r, o = p.o + fo }, mod)
            end
            return { k = 'agg', f = f, n = cnt }
        end
        local reg = st.mem[p.r]
        if reg then
            local c = reg.cells[p.o]
            if c and c.n == n then
                local v = c.v
                -- (an integer read as a pointer, and back: the bits are the address)
                if rty.k == 'p' and v and v.k == 'i' then return cast('inttoptr', v, nil, rty) end
                if rty.k == 'i' and v and v.k == 'p' then return cast('ptrtoint', v, nil, rty) end
                if rty.k == 'i' and v and v.k == 'i' and v.w ~= rty.w then return int(v.v, rty.w) end
                return v
            end
            if c then return nil end
            for o, cell in pairs(reg.cells) do if o < p.o + n and o + cell.n > p.o then return nil end end
            for _, z in ipairs(reg.zero or {}) do
                if p.o >= z[1] and p.o + n <= z[2] then
                    if rty.k == 'i' then return int(0, rty.w) elseif rty.k == 'p' then return { k = 'p', r = 'null', o = 0 } elseif rty.k == 'f' then return { k = 'f', v = 0 } end
                end
            end
            if reg.havoc then return nil end
        end
        -- (beneath: a global's initializer, the probe's memory)
        if p.r:sub(1, 1) == '@' then
            local g = mod:global(p.r) or (prog.global and prog.global(p.r))
            if not g or not g.constant then
                -- (a mutable global: its initial value only while nothing may have written it — not assumed)
                if not (g and ctx.globals_initial) then return nil end
            end
            local gc = gfill(g, mod)
            local c = gc.cells[p.o]
            if c and c.n == n then
                local v = c.v
                if rty.k == 'i' and v.k == 'i' and v.w ~= rty.w then return int(v.v, rty.w) end
                return v
            end
            for _, z in ipairs(gc.zero) do
                if p.o >= z[1] and p.o + n <= z[2] then
                    if rty.k == 'i' then return int(0, rty.w) elseif rty.k == 'p' then return { k = 'p', r = 'null', o = 0 } end
                end
            end
            return nil
        end
        if p.r == 'abs' then
            local base = p.o - p.o % 8
            local wd = memword(base)
            if not wd then return nil end
            local off = p.o - base
            if off + n > 8 then return nil end
            if rty.k == 'p' then if off ~= 0 then return nil end if wd == U64(0) then return { k = 'p', r = 'null', o = 0 } end return { k = 'p', r = 'abs', o = tonumber(wd) } end
            if rty.k == 'f' and rty.w == 64 and off == 0 then dbits[0] = wd; return { k = 'f', v = ddbl[0] } end
            if rty.k == 'i' then return int(off == 0 and wd or bit.rshift(wd, off * 8), rty.w) end
            return nil
        end
        return nil
    end

    -- STORE v (ty) at one pointer: overlapping cells go; an aggregate is stored by its fields
    local function store1(st, ty, v, p, mod)
        if not (p and p.k == 'p') then return false end
        if p.r == 'null' then return true end
        local reg = wregion(st, p.r)
        if not p.o then reg.cells = {}; reg.zero = nil; reg.havoc = true; return true end
        local rty = IR.resolve(mod, ty)
        if not rty then return true end
        local n = size(rty, mod)
        for o, cell in pairs(reg.cells) do if o < p.o + n and o + cell.n > p.o then reg.cells[o] = nil end end
        if reg.zero then
            -- (a store inside a zero range splits it)
            local z2 = {}
            for _, z in ipairs(reg.zero) do
                if z[2] <= p.o or z[1] >= p.o + n then z2[#z2 + 1] = z
                else
                    if z[1] < p.o then z2[#z2 + 1] = { z[1], p.o } end
                    if z[2] > p.o + n then z2[#z2 + 1] = { p.o + n, z[2] } end
                end
            end
            reg.zero = z2
        end
        if (rty.k == 's' or rty.k == 'a') then
            if v and v.k == 'agg' then
                local cnt = rty.k == 's' and #rty.f or rty.n
                for i = 1, cnt do
                    local fo, ft
                    if rty.k == 's' then fo, ft = IR.field_offset(mod, rty, i) else ft = rty.e; fo = (i - 1) * size(ft, mod) end
                    store1(st, ft, v.f[i], { k = 'p', r = p.r, o = p.o + fo }, mod)
                end
            end
            return true
        end
        reg.cells[p.o] = { n = n, v = v }
        return true
    end

    -- a load / store through a pointer that may differ per element
    local function load(st, ty, p, mod)
        if isvec(p) then return vmap(st.fset, function (e) return at(load1(st, ty, at(p, e), mod), e) end) end
        local v = load1(st, ty, p, mod)
        return v
    end
    local function store(st, ty, v, p, mod)
        if not isvec(p) then
            if p == nil then return end -- (an unknown pointer: the write is lost — unsound only for the region it hit)
            -- (a per-element VALUE at one place: stored as the vector itself)
            if isvec(v) and IR.resolve(mod, ty) and (IR.resolve(mod, ty).k == 's' or IR.resolve(mod, ty).k == 'a') then
                -- (an aggregate that differs per element: field by field)
                local rty = IR.resolve(mod, ty)
                local cnt = rty.k == 's' and #rty.f or rty.n
                local f = {}
                for i = 1, cnt do f[i] = vmap(st.fset, function (e) local x = at(v, e); return x and x.k == 'agg' and x.f[i] or nil end) end
                v = { k = 'agg', f = f, n = cnt }
            end
            store1(st, ty, v, p, mod)
            return
        end
        -- (the target differs per element: each target gets the stored value for its elements, its old value for the
        -- rest)
        local groups = {}
        for e in pairs(st.fset) do
            local pe = at(p, e)
            local gk = pe and pe.k == 'p' and (pe.r .. '+' .. tostring(pe.o)) or '?'
            groups[gk] = groups[gk] or { p = pe, els = {} }
            groups[gk].els[e] = true
        end
        for _, g in pairs(groups) do
            if g.p and g.p.k == 'p' then
                local old = load1(st, ty, g.p, mod)
                local nv = vmap(st.fset, function (e) if g.els[e] then return at(v, e) end return at(old, e) end)
                store1(st, ty, nv, g.p, mod)
            end
        end
    end

    -- HAVOC what an unknown callee may write: each pointer argument's region and the regions its cells point to
    local function havoc(st, args)
        local seen = {}
        local function hit(p, depth)
            if not (p and p.k == 'p') or p.r == 'null' or p.r == 'abs' or p.r:sub(1, 1) == '@' then return end
            if seen[p.r] then return end
            seen[p.r] = true
            local reg = st.mem[p.r]
            if depth < 2 and reg then for _, c in pairs(reg.cells) do local x = c.v; if isvec(x) then for _, y in pairs(x.by) do hit(y, depth + 1) end else hit(x, depth + 1) end end end
            local w = wregion(st, p.r)
            w.cells = {}
            w.zero = nil
            w.havoc = true
        end
        for _, a in ipairs(args) do
            if isvec(a) then for _, x in pairs(a.by) do hit(x, 0) end else hit(a, 0) end
        end
    end

    -- JOIN two states (exact for the elements only one of them carries)
    local function joinv(x, y, sa, sb, set)
        if veq(x, y) then return x end
        return vmap(set, function (e)
            local ia, ib = sa[e], sb[e]
            if ia and not ib then return at(x, e) end
            if ib and not ia then return at(y, e) end
            local p, q = at(x, e), at(y, e)
            if veq(p, q) then return p end
            return nil
        end)
    end
    local function join(a, b, mod)
        local set = setof(a.fset)
        for e in pairs(b.fset) do set[e] = true end
        local s = { fset = set, env = {}, mem = {}, own = {}, frame = a.frame }
        local names = {}
        for k in pairs(a.env) do names[k] = true end
        for k in pairs(b.env) do names[k] = true end
        for k in pairs(names) do s.env[k] = joinv(a.env[k], b.env[k], a.fset, b.fset, set) end
        local regs = {}
        for r in pairs(a.mem) do regs[r] = true end
        for r in pairs(b.mem) do regs[r] = true end
        for r in pairs(regs) do
            local ra, rb = a.mem[r], b.mem[r]
            if ra == rb then s.mem[r] = ra
            else
                local out = { cells = {}, havoc = (ra and ra.havoc) or (rb and rb.havoc) }
                if ra and rb and ra.zero == rb.zero then out.zero = ra.zero end
                local offs = {}
                for o, c in pairs(ra and ra.cells or {}) do offs[o] = c.n end
                for o, c in pairs(rb and rb.cells or {}) do offs[o] = offs[o] or c.n end
                for o, n in pairs(offs) do
                    local ca, cb = ra and ra.cells[o], rb and rb.cells[o]
                    local va, vb
                    if ca and ca.n == n then va = ca.v elseif not ca then va = load1(a, { k = 'i', w = n * 8 }, { k = 'p', r = r, o = o }, mod) end
                    if cb and cb.n == n then vb = cb.v elseif not cb then vb = load1(b, { k = 'i', w = n * 8 }, { k = 'p', r = r, o = o }, mod) end
                    -- (a pointer cell read back as an integer above: keep the cell's own kind)
                    if ca and not cb and vb and vb.k == 'i' and va and va.k == 'p' then vb = cast('inttoptr', vb, nil, { k = 'p' }) end
                    if cb and not ca and va and va.k == 'i' and vb and vb.k == 'p' then va = cast('inttoptr', va, nil, { k = 'p' }) end
                    local v = joinv(va, vb, a.fset, b.fset, set)
                    out.cells[o] = { n = n, v = v }
                end
                s.mem[r] = out
            end
        end
        return s
    end
    local function state_key(st)
        local l = {}
        local el = vim.tbl_keys(st.fset); table.sort(el)
        l[1] = table.concat(el, ',')
        local names = vim.tbl_keys(st.env); table.sort(names)
        for _, k in ipairs(names) do l[#l + 1] = k .. '=' .. key_of(st.env[k]) end
        local regs = vim.tbl_keys(st.mem); table.sort(regs)
        for _, r in ipairs(regs) do
            local reg = st.mem[r]
            local offs = vim.tbl_keys(reg.cells); table.sort(offs)
            local c = {}
            for _, o in ipairs(offs) do c[#c + 1] = o .. ':' .. key_of(reg.cells[o].v) end
            l[#l + 1] = r .. (reg.havoc and '!' or '') .. '{' .. table.concat(c, ',') .. '}'
        end
        return table.concat(l, '|')
    end
    A.join, A.state_key = join, state_key

    -- the CFG of a function: successors, reverse postorder, loop heads (targets of a back edge)
    local function cfg(f)
        if f.cfg then return f.cfg end
        local succ = {}
        for _, lab in ipairs(f.order) do
            local insts = f.blocks[lab].insts
            local t = insts[#insts]
            local s = {}
            if t then
                if t.op == 'br' then for _, x in ipairs(t.to) do s[#s + 1] = x end
                elseif t.op == 'switch' then s[1] = t.default; for _, c in ipairs(t.cases) do s[#s + 1] = c.to end
                elseif t.op == 'call' and t.invoke then s[1] = t.normal end
            end
            succ[lab] = s
        end
        local rpo, state, heads, post = {}, {}, {}, {}
        local function dfs(b)
            state[b] = 1
            for _, x in ipairs(succ[b] or {}) do
                if state[x] == 1 then heads[x] = true elseif not state[x] and f.blocks[x] then dfs(x) end
            end
            state[b] = 2
            post[#post + 1] = b
        end
        dfs(f.entry)
        for i = #post, 1, -1 do rpo[#rpo + 1] = post[i] end
        local idx = {}
        for i, b in ipairs(rpo) do idx[b] = i end
        f.cfg = { succ = succ, rpo = rpo, idx = idx, heads = heads }
        return f.cfg
    end

    local run_fn -- (forward)

    -- an operand's value on a state
    local function opval(st, o, ty, mod)
        if o == nil then return nil end
        if o.k == 'l' then return st.env[o.n] end
        return const(o, ty, mod)
    end

    -- the INTRINSICS this engine knows (llvm.*): memcpy / memmove / memset, expect, min / max, the no-ops
    local function intrinsic(st, I, args, mod)
        local f = I.f
        if f:match('^@llvm%.lifetime') or f:match('^@llvm%.assume') or f:match('^@llvm%.experimental%.noalias')
            or f:match('^@llvm%.stack') or f:match('^@llvm%.va_') or f:match('^@llvm%.prefetch') then return true, nil end
        if f:match('^@llvm%.expect') then return true, args[1] end
        if f:match('^@llvm%.trap') or f:match('^@llvm%.debugtrap') or f:match('^@llvm%.ubsantrap') then return true, nil, 'noreturn' end
        if f:match('^@llvm%.memset') then
            local dst, val, len = args[1], args[2], args[3]
            if dst and not isvec(dst) and dst.k == 'p' and dst.o and len and not isvec(len) and len.k == 'i' and val and not isvec(val) and val.k == 'i' and val.v == U64(0) then
                local n = tonumber(len.v)
                local reg = wregion(st, dst.r)
                for o, cell in pairs(reg.cells) do if o < dst.o + n and o + cell.n > dst.o then reg.cells[o] = nil end end
                local z = {}
                for _, x in ipairs(reg.zero or {}) do z[#z + 1] = x end
                z[#z + 1] = { dst.o, dst.o + n }
                reg.zero = z
                reg.havoc = nil
            else havoc(st, { dst }) end
            return true, nil
        end
        if f:match('^@llvm%.memcpy') or f:match('^@llvm%.memmove') then
            local dst, src, len = args[1], args[2], args[3]
            if dst and src and not isvec(dst) and not isvec(src) and dst.k == 'p' and src.k == 'p' and dst.o and src.o and len and not isvec(len) and len.k == 'i' then
                local n = tonumber(len.v)
                -- (word by word where the source has words, byte cells otherwise; a hole copies as unknown)
                local cells = {}
                local sreg = st.mem[src.r]
                if sreg then for o, c in pairs(sreg.cells) do if o >= src.o and o + c.n <= src.o + n then cells[#cells + 1] = { o - src.o, c } end end end
                local reg = wregion(st, dst.r)
                for o, cell in pairs(reg.cells) do if o < dst.o + n and o + cell.n > dst.o then reg.cells[o] = nil end end
                local covered = {}
                for _, x in ipairs(cells) do reg.cells[dst.o + x[1]] = x[2]; for b = x[1], x[1] + x[2].n - 1 do covered[b] = true end end
                -- (the rest from beneath the source — a global's initializer, the probe's memory — 8 bytes at a time)
                local o = 0
                while o < n do
                    if not covered[o] then
                        local w = (n - o >= 8 and (src.o + o) % 8 == 0) and 8 or 1
                        local v = load1(st, { k = 'i', w = w * 8 }, { k = 'p', r = src.r, o = src.o + o }, mod)
                        if v then reg.cells[dst.o + o] = { n = w, v = v } end
                        o = o + w
                    else o = o + 1 end
                end
                if sreg and sreg.havoc then reg.havoc = true end
            else havoc(st, { dst }) end
            return true, nil
        end
        local w = I.T and I.T.w
        local function mm(fn) if w and args[1] and args[2] then return lift2(function (x, y) if not (x and y and x.k == 'i' and y.k == 'i') then return nil end return fn(x, y) end, args[1], args[2], st.fset) end return nil end
        if f:match('^@llvm%.umax') then return true, mm(function (x, y) return x.v >= y.v and x or y end) end
        if f:match('^@llvm%.umin') then return true, mm(function (x, y) return x.v <= y.v and x or y end) end
        if f:match('^@llvm%.smax') then return true, mm(function (x, y) return signed(x) >= signed(y) and x or y end) end
        if f:match('^@llvm%.smin') then return true, mm(function (x, y) return signed(x) <= signed(y) and x or y end) end
        if f:match('^@llvm%.') then return true, nil end -- (any other intrinsic: an unknown value, no memory effect)
        return false
    end

    -- ONE BLOCK on one state: -> list of { label, state } successors; returns / aborts recorded in cx
    local function exec_block(f, mod, lab, st, from, cx)
        local B = f.blocks[lab]
        local insts = B.insts
        -- (phis first, all read from the incoming edge)
        local phis = {}
        local i = 1
        while insts[i] and insts[i].op == 'phi' do
            local I = insts[i]
            local v
            for _, inc in ipairs(I.inc) do if inc.b == from then v = opval(st, inc.v, I.T, mod) end end
            phis[#phis + 1] = { I.dst, v }
            i = i + 1
        end
        for _, ph in ipairs(phis) do st.env[ph[1]] = ph[2] end
        while i <= #insts do
            local I = insts[i]
            A.steps = A.steps + 1
            if A.steps > A.budget then cx.over = true; return {} end
            local op = I.op
            if op == 'alloca' then
                st.env[I.dst] = { k = 'p', r = st.frame .. I.dst, o = 0 }
                local reg = { cells = {} }
                st.mem[st.frame .. I.dst] = reg
                st.own[st.frame .. I.dst] = true
            elseif op == 'load' then
                st.env[I.dst] = load(st, I.T, opval(st, I.p, nil, mod), mod)
            elseif op == 'store' then
                store(st, I.T, opval(st, I.v, I.T, mod), opval(st, I.p, nil, mod), mod)
            elseif op == 'gep' then
                local base = opval(st, I.p, nil, mod)
                local idx = {}
                for k, ix in ipairs(I.idx) do idx[k] = opval(st, ix.v, ix.ty, mod) end
                local function gep(b, ...)
                    if not (b and b.k == 'p') then return nil end
                    local iv = { ... }
                    local off = b.o
                    local cur = I.T
                    for k = 1, #I.idx do
                        local x = iv[k]
                        local n = x and x.k == 'i' and tonumber(signed(x)) or nil
                        if k == 1 then
                            if n == nil then off = false elseif off then off = off + n * size(cur, mod) end
                        else
                            local r = IR.resolve(mod, cur)
                            if r and r.k == 's' then
                                if n == nil then return { k = 'p', r = b.r, o = false } end
                                local fo, ft = IR.field_offset(mod, r, n + 1)
                                if not fo then return nil end
                                if off then off = off + fo end
                                cur = ft
                            elseif r and (r.k == 'a' or r.k == 'x') then
                                cur = r.e
                                if n == nil then off = false elseif off then off = off + n * size(cur, mod) end
                            else return nil end
                        end
                    end
                    return { k = 'p', r = b.r, o = off }
                end
                local anyvec = isvec(base)
                for k = 1, #idx do if isvec(idx[k]) then anyvec = true end end
                if anyvec then
                    st.env[I.dst] = vmap(st.fset, function (e)
                        local iv = {}
                        for k = 1, #idx do iv[k] = at(idx[k], e) end
                        return gep(at(base, e), unpack(iv, 1, #idx))
                    end)
                else st.env[I.dst] = gep(base, unpack(idx, 1, #idx)) end
            elseif op == 'icmp' then
                local w = I.T.w or 64
                st.env[I.dst] = lift2(function (a, b) return icmp(I.pred, a, b, w) end, opval(st, I.a, I.T, mod), opval(st, I.b, I.T, mod), st.fset)
            elseif op == 'fcmp' then
                st.env[I.dst] = lift2(function (a, b) return fcmp(I.pred, a, b) end, opval(st, I.a, I.T, mod), opval(st, I.b, I.T, mod), st.fset)
            elseif op == 'copy' then
                st.env[I.dst] = opval(st, I.v, I.T, mod)
            elseif op == 'select' then
                local c = opval(st, I.c, { k = 'i', w = 1 }, mod)
                local a, b = opval(st, I.a, I.T, mod), opval(st, I.b, I.T, mod)
                local function sel(cv, x, y)
                    local t = truth(cv)
                    if t == true then return x elseif t == false then return y end
                    if veq(x, y) then return x end
                    return nil
                end
                if isvec(c) or isvec(a) or isvec(b) then st.env[I.dst] = vmap(st.fset, function (e) return sel(at(c, e), at(a, e), at(b, e)) end)
                else st.env[I.dst] = sel(c, a, b) end
            elseif op == 'extractvalue' then
                local v = opval(st, I.v, I.T, mod)
                st.env[I.dst] = lift1(function (x)
                    for _, k in ipairs(I.path) do if not (x and x.k == 'agg') then return nil end x = x.f[k + 1] end
                    return x
                end, v, st.fset)
            elseif op == 'insertvalue' then
                local agg, v = opval(st, I.agg, I.T, mod), opval(st, I.v, nil, mod)
                local rty = IR.resolve(mod, I.T)
                local cnt = rty and (rty.k == 's' and #rty.f or rty.n) or 0
                local function ins(a, x)
                    local base = (a and a.k == 'agg') and a or { k = 'agg', f = {}, n = cnt }
                    local function put(node, path, k)
                        local c = { k = 'agg', f = {}, n = node.n }
                        for q = 1, (node.n or #node.f) do c.f[q] = node.f[q] end
                        local j = path[k] + 1
                        if k == #path then c.f[j] = x
                        else
                            local child = c.f[j]
                            if not (child and child.k == 'agg') then child = { k = 'agg', f = {}, n = 64 } end
                            c.f[j] = put(child, path, k + 1)
                        end
                        return c
                    end
                    return put(base, I.path, 1)
                end
                st.env[I.dst] = lift2(ins, agg, v, st.fset)
            elseif op == 'call' then
                local args = {}
                for k, a in ipairs(I.args) do args[k] = opval(st, a.v, a.ty, mod) end
                local fname = I.f
                -- (a call through a pointer that names a function)
                if fname and fname:sub(1, 1) == '%' then
                    local fp = st.env[fname]
                    fname = (fp and not isvec(fp) and fp.k == 'p' and fp.r:sub(1, 1) == '@' and fp.o == 0) and fp.r or nil
                end
                local handled, rv, kind = false, nil, nil
                if fname and fname:match('^@llvm%.') then handled, rv, kind = intrinsic(st, I, args, mod) end
                if kind == 'noreturn' or (fname and mod:noreturn(fname, I.attr)) then
                    for e in pairs(st.fset) do cx.rej[e] = true end
                    return {}
                end
                if not handled then
                    local cf, cmod
                    if fname then cf, cmod = prog.fn(fname) end
                    if cf and #cx.stack < MAXD and not cx.onstack[fname] then
                        local rets = run_fn(cf, cmod, args, st, cx)
                        if not rets then return {} end
                        st = rets.state
                        if I.dst then st.env[I.dst] = rets.v end
                        if empty(st.fset) then return {} end
                        if I.invoke then return { { I.normal, st } } end
                        goto next_inst
                    end
                    -- (an UNKNOWN callee: its result unknown, what its pointers reach havoc'd)
                    havoc(st, args)
                    if I.dst then st.env[I.dst] = nil end
                else
                    if I.dst then st.env[I.dst] = rv end
                end
                if I.invoke then return { { I.normal, st } } end
            elseif op == 'br' then
                if #I.to == 1 then return { { I.to[1], st } } end
                local c = opval(st, I.c, { k = 'i', w = 1 }, mod)
                local tset, fset = {}, {}
                for e in pairs(st.fset) do
                    local t = truth(at(c, e))
                    if t == true then tset[e] = true elseif t == false then fset[e] = true else tset[e] = true; fset[e] = true end
                end
                local out = {}
                if not empty(tset) then out[#out + 1] = { I.to[1], empty(fset) and st or copy(st, tset) } end
                if not empty(fset) then out[#out + 1] = { I.to[2], empty(tset) and st or copy(st, fset) } end
                return out
            elseif op == 'switch' then
                local v = opval(st, I.v, I.T, mod)
                local parts = {}
                local function add(lab2, e) parts[lab2] = parts[lab2] or {}; parts[lab2][e] = true end
                for e in pairs(st.fset) do
                    local x = at(v, e)
                    if x and x.k == 'i' then
                        local hit = false
                        for _, c in ipairs(I.cases) do
                            local cv = const(c.v, I.T, mod)
                            if cv and cv.v == x.v then add(c.to, e); hit = true; break end
                        end
                        if not hit then add(I.default, e) end
                    else
                        add(I.default, e)
                        for _, c in ipairs(I.cases) do add(c.to, e) end
                    end
                end
                local out = {}
                for lab2, set in pairs(parts) do out[#out + 1] = { lab2, copy(st, set) } end
                return out
            elseif op == 'ret' then
                local v = I.v and opval(st, I.v, I.T, mod) or nil
                cx.returns[#cx.returns + 1] = { state = st, v = v }
                return {}
            elseif op == 'unreachable' then
                for e in pairs(st.fset) do cx.rej[e] = true end
                return {}
            elseif BINOPS[op] then
                local w = I.T.w or 64
                st.env[I.dst] = lift2(function (a, b) return binop(op, a, b, w) end, opval(st, I.a, I.T, mod), opval(st, I.b, I.T, mod), st.fset)
            elseif CASTS[op] then
                st.env[I.dst] = lift1(function (x) return cast(op, x, I.from, I.T) end, opval(st, I.v, I.from, mod), st.fset)
            elseif I.unknown then
                if I.p then havoc(st, { opval(st, I.p, nil, mod) }) end
                if I.dst then st.env[I.dst] = nil end
            end
            ::next_inst::
            i = i + 1
        end
        return {}
    end

    --- RUN a function on a state (the caller's memory): its parameters bound to args, its blocks to a fixpoint ->
    --- { state = the joined return state (the caller's frame restored), v = the return value } | nil (no return)
    function run_fn(f, mod, args, cst, cx)
        local G = cfg(f)
        A.frames = A.frames + 1
        local frame = 'f' .. A.frames .. ':'
        local st = { fset = setof(cst.fset), env = {}, mem = {}, own = {}, frame = frame }
        for r, reg in pairs(cst.mem) do st.mem[r] = reg end
        for i, p in ipairs(f.params) do st.env[p.name] = args[i] end
        local sub = { returns = {}, rej = cx.rej, over = false, stack = cx.stack, onstack = cx.onstack }
        cx.stack[#cx.stack + 1] = f.name
        cx.onstack[f.name] = true
        -- the worklist over blocks in RPO: a loop head keeps CAP distinct states, then one widened state
        local pending = {}   -- [label] = { { state, from } … } (a non-head: joined into one on arrival)
        local count, widened, seenk = {}, {}, {}
        local function arrive(lab, s, from)
            if not f.blocks[lab] then return end
            if G.heads[lab] then
                count[lab] = (count[lab] or 0) + 1
                if count[lab] <= CAP and not widened[lab] then
                    local k = state_key(s) .. '<' .. tostring(from)
                    seenk[lab] = seenk[lab] or {}
                    if seenk[lab][k] then return end
                    seenk[lab][k] = true
                    pending[lab] = pending[lab] or {}
                    table.insert(pending[lab], { s, from })
                    return
                end
                -- (WIDEN: one state, joined with everything that arrives; processed again only when it changed)
                local w = widened[lab]
                local nw = w and join(w.state, s, mod) or s
                local nk = state_key(nw)
                if w and w.key == nk then return end
                widened[lab] = { state = nw, key = nk }
                pending[lab] = pending[lab] or {}
                table.insert(pending[lab], { nw, from, wide = true })
                return
            end
            local q = pending[lab]
            if q and q[1] then
                -- (one state per block, but the phi needs the edge: keep one per predecessor)
                for _, x in ipairs(q) do
                    if x[2] == from then x[1] = join(x[1], s, mod); return end
                end
                table.insert(q, { s, from })
            else pending[lab] = { { s, from } } end
        end
        arrive(f.entry, st, nil)
        while true do
            if cx.over or sub.over then break end
            local best, bi
            for lab, q in pairs(pending) do
                if q[1] and (not bi or G.idx[lab] < bi) then best, bi = lab, G.idx[lab] end
            end
            if not best then break end
            local item = table.remove(pending[best], 1)
            local outs = exec_block(f, mod, best, item[1], item[2], sub)
            if sub.over then cx.over = true; break end
            for _, o in ipairs(outs) do arrive(o[1], o[2], best) end
        end
        cx.stack[#cx.stack] = nil
        cx.onstack[f.name] = nil
        if sub.over then cx.over = true end
        if #sub.returns == 0 then return nil end
        -- the JOIN of the returns, and the return value per element
        local acc = sub.returns[1].state
        local rv = sub.returns[1].v
        local rset = setof(acc.fset)
        for k = 2, #sub.returns do
            local r = sub.returns[k]
            local nset = setof(rset)
            for e in pairs(r.state.fset) do nset[e] = true end
            rv = joinv(rv, r.v, rset, r.state.fset, nset)
            acc = join(acc, r.state, mod)
            rset = nset
        end
        -- (the caller's own SSA values and frame come back; the memory is the callee's result)
        local out = { fset = acc.fset, env = {}, mem = {}, own = {}, frame = cst.frame }
        -- (the callee's own stack is gone)
        for r, reg in pairs(acc.mem) do if r:sub(1, #frame) ~= frame then out.mem[r] = reg end end
        for k, v in pairs(cst.env) do out.env[k] = v end
        return { state = out, v = rv, returns = sub.returns }
    end

    --- the DRIVER's entry: run `name` on args and a fresh state over the element set (and initial memory regions) ->
    --- { returns = { { fset, v } }, rej = { [element] = true }, over, steps }
    function A.run(name, args, fset, mem)
        local f, fmod = prog.fn(name)
        if not f then return nil, 'no definition of ' .. name end
        local cst = { fset = setof(fset), env = {}, mem = mem or {}, own = {}, frame = 'top:' }
        local cx = { returns = {}, rej = {}, over = false, stack = {}, onstack = {} }
        A.steps = 0
        local r = run_fn(f, fmod, args, cst, cx)
        local out = { returns = {}, rej = cx.rej, over = cx.over, steps = A.steps }
        if r then for _, x in ipairs(r.returns) do out.returns[#out.returns + 1] = { fset = x.state.fset, v = x.v, state = x.state } end end
        return out
    end
    A.load = load
    return A
end

return M
