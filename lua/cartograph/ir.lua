-- cartograph.ir — LLVM IR TEXT, read (CART-1259): the module a compiler lowered a unit to (`clang -S -emit-llvm -O0`),
-- the language's semantics already resolved — C++ templates instantiated, overloads and conversion operators chosen,
-- every load and store typed at an explicit offset. Indexed whole (named types, globals, declarations and their
-- attributes: noreturn), each FUNCTION parsed ON DEMAND: a unified SpiderMonkey unit is ~350k lines, a native's call
-- closure ~70 functions. Layout from the IR's own types (x86-64 data layout: natural alignment, a packed struct none).
--   M.read(path | { text = … }) -> module; mod:fn(name) -> { name, ret, params = { { ty, name } }, blocks = { [label] =
--   { insts, label } }, order = { label … }, entry } | nil; mod:global(name) -> { ty, init, constant } | nil;
--   M.size(mod, ty), M.align(mod, ty), M.field_offset(mod, ty, i).
-- A type: { k = 'i', w } | { k = 'f', w } | { k = 'p' } | { k = 'v' } (void) | { k = 'a', n, e } (array) |
-- { k = 's', f = { … }, packed } (struct) | { k = 'n', name } (named) | { k = 'x', n, e } (vector) | { k = 'other', t }.
-- An operand: { k = 'l', n = '%x' } (a local) | { k = 'g', n = '@x' } | { k = 'c', i | f | null | undef | zero | agg |
-- str } | { k = 'cgep', T, base, idx } | { k = 'ccast', op, v, to }.
local ffi = require 'ffi'
local M = {}

-- ── tokens ─────────────────────────────────────────────────────────────────────────────────────────────────────
local function tokens(s)
    local t, i, n = {}, 1, #s
    while i <= n do
        local c = s:sub(i, i)
        if c == ' ' or c == '\t' or c == '\r' then i = i + 1
        elseif c == ';' then break
        elseif (c == '%' or c == '@' or c == '!') and s:sub(i + 1, i + 1) == '"' then
            local j = s:find('"', i + 2, true) or n + 1
            t[#t + 1] = c .. s:sub(i + 2, j - 1)
            i = j + 1
        elseif c == '%' or c == '@' or c == '!' or c == '#' then
            local j = s:find('[^%w%-%$%._]', i + 1) or n + 1
            t[#t + 1] = s:sub(i, j - 1)
            i = j
        elseif c == 'c' and s:sub(i + 1, i + 1) == '"' then
            local j = s:find('"', i + 2, true) or n + 1
            t[#t + 1] = { str = s:sub(i + 2, j - 1) }
            i = j + 1
        elseif c:match('%d') or (c == '-' and s:sub(i + 1, i + 1):match('%d')) then
            local j = s:find('[^%w%.%+%-]', i + 1) or n + 1
            t[#t + 1] = s:sub(i, j - 1)
            i = j
        elseif c:match('[%a_]') then
            local j = s:find('[^%w_%.]', i + 1) or n + 1
            t[#t + 1] = s:sub(i, j - 1)
            i = j
        else
            t[#t + 1] = c
            i = i + 1
        end
    end
    return t
end
M._tokens = tokens

-- ── integers: decimal / hex text -> uint64 bits ───────────────────────────────────────────────────────────────
local U64 = ffi.typeof('uint64_t')
function M.int64(text)
    local neg = text:sub(1, 1) == '-'
    local s = neg and text:sub(2) or text
    local v = U64(0)
    if s:sub(1, 2) == '0x' or s:sub(1, 2) == '0X' then
        for ch in s:sub(3):gmatch('.') do v = v * 16 + tonumber(ch, 16) end
    else
        for ch in s:gmatch('%d') do v = v * 10 + tonumber(ch) end
    end
    if neg then v = U64(0) - v end
    return v
end
local dbits = ffi.new('uint64_t[1]')
local ddbl = ffi.cast('double *', dbits)

-- ── the parser over one line's tokens ──────────────────────────────────────────────────────────────────────────
local P = {}
P.__index = P
local function parser(toks) return setmetatable({ t = toks, i = 1 }, P) end
function P:peek(k) return self.t[self.i + (k or 0)] end
function P:next() local x = self.t[self.i]; self.i = self.i + 1; return x end
function P:accept(x) if self.t[self.i] == x then self.i = self.i + 1; return true end return false end
function P:skip_to(x) while self.t[self.i] ~= nil and self.t[self.i] ~= x do self.i = self.i + 1 end end
-- (a balanced group: from an opening bracket to its close)
function P:skip_group()
    local open = self:next()
    local close = ({ ['('] = ')', ['['] = ']', ['{'] = '}', ['<'] = '>' })[open]
    local depth = 1
    while depth > 0 and self.t[self.i] ~= nil do
        local x = self:next()
        if x == open then depth = depth + 1 elseif x == close then depth = depth - 1 end
    end
end

local ITYPE = {}
local PTR, VOID = { k = 'p' }, { k = 'v' }
function P:type()
    local x = self:next()
    local ty
    if x == 'ptr' then
        ty = PTR
        if self:peek() == 'addrspace' then self:next(); self:skip_group() end
    elseif x == 'void' then ty = VOID
    elseif type(x) == 'string' and x:match('^i%d+$') then
        local w = tonumber(x:sub(2))
        ty = ITYPE[w] or { k = 'i', w = w }
        ITYPE[w] = ty
    elseif x == 'float' then ty = { k = 'f', w = 32 }
    elseif x == 'double' then ty = { k = 'f', w = 64 }
    elseif x == 'half' or x == 'bfloat' then ty = { k = 'f', w = 16 }
    elseif x == 'x86_fp80' then ty = { k = 'f', w = 80 }
    elseif x == 'fp128' or x == 'ppc_fp128' then ty = { k = 'f', w = 128 }
    elseif x == '[' then
        local n = tonumber(self:next())
        self:accept('x')
        local e = self:type()
        self:accept(']')
        ty = { k = 'a', n = n, e = e }
    elseif x == '<' then
        if self:peek() == '{' then
            self:next()
            local f = {}
            while self:peek() ~= '}' and self:peek() ~= nil do f[#f + 1] = self:type(); self:accept(',') end
            self:accept('}')
            self:accept('>')
            ty = { k = 's', f = f, packed = true }
        else
            local n = tonumber(self:next())
            self:accept('x')
            local e = self:type()
            self:accept('>')
            ty = { k = 'x', n = n, e = e }
        end
    elseif x == '{' then
        local f = {}
        while self:peek() ~= '}' and self:peek() ~= nil do f[#f + 1] = self:type(); self:accept(',') end
        self:accept('}')
        ty = { k = 's', f = f }
    elseif type(x) == 'string' and x:sub(1, 1) == '%' then ty = { k = 'n', name = x }
    else ty = { k = 'other', t = x } end
    return ty
end

-- (the words a parameter or call may carry before its value)
local ATTR_WITH_ARG = { align = true, dereferenceable = true, dereferenceable_or_null = true, byval = true, sret = true,
    elementtype = true, inalloca = true, preallocated = true, alignstack = true, nofpclass = true, range = true,
    captures = true, memory = true, allocsize = true, initializes = true, byref = true }
local VALUE_WORD = { ['true'] = true, ['false'] = true, null = true, undef = true, poison = true, zeroinitializer = true,
    getelementptr = true, ptrtoint = true, inttoptr = true, bitcast = true, addrspacecast = true, trunc = true,
    zext = true, sext = true, none = true, blockaddress = true, dso_local_equivalent = true, no_cfi = true, asm = true }
function P:skip_attrs()
    while true do
        local x = self:peek()
        if type(x) ~= 'string' then return end
        local c = x:sub(1, 1)
        if c == '%' or c == '@' or c == '-' or c:match('%d') or VALUE_WORD[x] or c == '{' or c == '[' or c == '<' or c == ',' or c == ')' then return end
        self:next()
        if ATTR_WITH_ARG[x] then
            if self:peek() == '(' then self:skip_group() elseif x == 'align' then self:next() end
        elseif self:peek() == '(' then self:skip_group() end
    end
end

function P:value(ty)
    local x = self:next()
    if type(x) == 'table' then return { k = 'c', str = x.str } end
    if x == nil then return { k = 'c', undef = true } end
    local c = x:sub(1, 1)
    if c == '%' then return { k = 'l', n = x } end
    if c == '@' then return { k = 'g', n = x } end
    if x == 'true' then return { k = 'c', i = U64(1) } end
    if x == 'false' then return { k = 'c', i = U64(0) } end
    if x == 'null' or x == 'none' then return { k = 'c', null = true } end
    if x == 'undef' or x == 'poison' then return { k = 'c', undef = true } end
    if x == 'zeroinitializer' then return { k = 'c', zero = true } end
    if c == '-' or c:match('%d') then
        if ty and ty.k == 'f' then
            if x:sub(1, 2) == '0x' and ty.w == 64 then dbits[0] = M.int64(x); return { k = 'c', f = ddbl[0] } end
            if x:sub(1, 2) == '0x' then return { k = 'c', undef = true } end
            return { k = 'c', f = tonumber(x) }
        end
        return { k = 'c', i = M.int64(x) }
    end
    if x == '{' or x == '[' or (x == '<' and self:peek() == '{') then
        if x == '<' then self:next() end
        local close = x == '[' and ']' or '}'
        local agg = {}
        while self:peek() ~= close and self:peek() ~= nil do
            local et = self:type()
            agg[#agg + 1] = { ty = et, v = self:value(et) }
            self:accept(',')
        end
        self:accept(close)
        if x == '<' then self:accept('>') end
        return { k = 'c', agg = agg }
    end
    if x == 'getelementptr' then
        while self:peek() == 'inbounds' or self:peek() == 'nuw' or self:peek() == 'nusw' or self:peek() == 'inrange' do
            self:next()
            if self:peek() == '(' then self:skip_group() end
        end
        self:accept('(')
        local T = self:type()
        self:accept(',')
        local bt = self:type()
        local base = self:value(bt)
        local idx = {}
        while self:accept(',') do
            local it = self:type()
            idx[#idx + 1] = { ty = it, v = self:value(it) }
        end
        self:accept(')')
        return { k = 'cgep', T = T, base = base, idx = idx }
    end
    if x == 'ptrtoint' or x == 'inttoptr' or x == 'bitcast' or x == 'addrspacecast' or x == 'trunc' or x == 'zext' or x == 'sext' then
        self:accept('(')
        local ft = self:type()
        local v = self:value(ft)
        self:accept('to')
        local to = self:type()
        self:accept(')')
        return { k = 'ccast', op = x, v = v, from = ft, to = to }
    end
    if self:peek() == '(' then self:skip_group() end
    return { k = 'c', undef = true }
end

-- ── one instruction ────────────────────────────────────────────────────────────────────────────────────────────
local BIN = { add = true, sub = true, mul = true, udiv = true, sdiv = true, urem = true, srem = true, shl = true,
    lshr = true, ashr = true, ['and'] = true, ['or'] = true, xor = true, fadd = true, fsub = true, fmul = true,
    fdiv = true, frem = true }
local CAST = { trunc = true, zext = true, sext = true, fptrunc = true, fpext = true, fptoui = true, fptosi = true,
    uitofp = true, sitofp = true, ptrtoint = true, inttoptr = true, bitcast = true, addrspacecast = true }
local FLAG = { nuw = true, nsw = true, exact = true, disjoint = true, nneg = true, fast = true, nnan = true, ninf = true,
    nsz = true, arcp = true, contract = true, afn = true, reassoc = true, inbounds = true, samesign = true, volatile = true }

local function inst(line)
    local toks = tokens(line)
    if #toks == 0 then return nil end
    local p = parser(toks)
    local dst
    if type(toks[1]) == 'string' and toks[1]:sub(1, 1) == '%' and toks[2] == '=' then dst = p:next(); p:next() end
    local op = p:next()
    while op == 'tail' or op == 'musttail' or op == 'notail' do op = p:next() end
    local I = { op = op, dst = dst }
    if op == 'alloca' then
        p:accept('inalloca')
        I.T = p:type()
        if p:accept(',') and type(p:peek()) == 'string' and p:peek():match('^i%d+$') then local ct = p:type(); I.count = p:value(ct) end
    elseif op == 'load' then
        while FLAG[p:peek()] or p:peek() == 'atomic' do p:next() end
        I.T = p:type()
        p:accept(',')
        p:type()
        I.p = p:value()
    elseif op == 'store' then
        while FLAG[p:peek()] or p:peek() == 'atomic' do p:next() end
        I.T = p:type()
        I.v = p:value(I.T)
        p:accept(',')
        p:type()
        I.p = p:value()
    elseif op == 'getelementptr' then
        while FLAG[p:peek()] or p:peek() == 'inrange' do p:next(); if p:peek() == '(' then p:skip_group() end end
        I.op = 'gep'
        I.T = p:type()
        p:accept(',')
        p:type()
        I.p = p:value()
        I.idx = {}
        while p:accept(',') do
            local x = p:peek()
            if type(x) == 'string' and x:sub(1, 1) == '!' then break end
            if x == 'inrange' then p:next(); p:skip_group() end
            local it = p:type()
            I.idx[#I.idx + 1] = { ty = it, v = p:value(it) }
        end
    elseif BIN[op] then
        while FLAG[p:peek()] do p:next() end
        I.T = p:type()
        I.a = p:value(I.T)
        p:accept(',')
        I.b = p:value(I.T)
    elseif op == 'icmp' or op == 'fcmp' then
        while FLAG[p:peek()] do p:next() end
        I.pred = p:next()
        I.T = p:type()
        I.a = p:value(I.T)
        p:accept(',')
        I.b = p:value(I.T)
    elseif CAST[op] then
        while FLAG[p:peek()] do p:next() end
        I.from = p:type()
        I.v = p:value(I.from)
        p:accept('to')
        I.T = p:type()
    elseif op == 'select' then
        while FLAG[p:peek()] do p:next() end
        local ct = p:type()
        I.c = p:value(ct)
        p:accept(',')
        I.T = p:type()
        I.a = p:value(I.T)
        p:accept(',')
        p:type()
        I.b = p:value(I.T)
    elseif op == 'freeze' then
        I.op = 'copy'
        I.T = p:type()
        I.v = p:value(I.T)
    elseif op == 'phi' then
        while FLAG[p:peek()] do p:next() end
        I.T = p:type()
        I.inc = {}
        while p:accept('[') do
            local v = p:value(I.T)
            p:accept(',')
            local b = p:next()
            p:accept(']')
            I.inc[#I.inc + 1] = { v = v, b = b }
            if not p:accept(',') then break end
        end
    elseif op == 'call' or op == 'invoke' then
        while FLAG[p:peek()] do p:next() end
        -- (calling convention, return attributes)
        while type(p:peek()) == 'string' and (p:peek():match('cc$') or p:peek():match('^cc%d') or p:peek() == 'noundef'
            or p:peek() == 'zeroext' or p:peek() == 'signext' or p:peek() == 'nonnull' or p:peek() == 'noalias' or p:peek() == 'inreg'
            or ATTR_WITH_ARG[p:peek()] or p:peek() == 'dso_local' or p:peek() == 'dereferenceable') do
            local w = p:next()
            if ATTR_WITH_ARG[w] then if p:peek() == '(' then p:skip_group() elseif w == 'align' then p:next() end end
        end
        I.T = p:type()
        if p:peek() == '(' then p:skip_group() end -- (an explicit function type: a variadic callee)
        local f = p:next()
        if f == 'asm' then I.asm = true; p:skip_to('(') else I.f = f end
        I.args = {}
        if p:accept('(') then
            while p:peek() ~= ')' and p:peek() ~= nil do
                local at = p:type()
                p:skip_attrs()
                I.args[#I.args + 1] = { ty = at, v = p:value(at) }
                if not p:accept(',') then break end
            end
            p:accept(')')
        end
        while type(p:peek()) == 'string' and p:peek():sub(1, 1) == '#' do I.attr = p:next() end
        if op == 'invoke' then
            p:skip_to('to')
            p:next()
            p:next()
            I.normal = p:next()
            p:skip_to('unwind')
            p:next()
            p:next()
            I.unwind = p:next()
            I.op = 'call'
            I.invoke = true
        end
    elseif op == 'extractvalue' then
        I.T = p:type()
        I.v = p:value(I.T)
        I.path = {}
        while p:accept(',') do local x = p:next(); if type(x) ~= 'string' or not x:match('^%d') then break end I.path[#I.path + 1] = tonumber(x) end
    elseif op == 'insertvalue' then
        I.T = p:type()
        I.agg = p:value(I.T)
        p:accept(',')
        local vt = p:type()
        I.v = p:value(vt)
        I.path = {}
        while p:accept(',') do local x = p:next(); if type(x) ~= 'string' or not x:match('^%d') then break end I.path[#I.path + 1] = tonumber(x) end
    elseif op == 'br' then
        if p:peek() == 'label' then p:next(); I.to = { p:next() }
        else
            p:type()
            I.c = p:value()
            p:accept(',')
            p:accept('label')
            local a = p:next()
            p:accept(',')
            p:accept('label')
            I.to = { a, p:next() }
        end
    elseif op == 'switch' then
        I.T = p:type()
        I.v = p:value(I.T)
        p:accept(',')
        p:accept('label')
        I.default = p:next()
        I.cases = {}
        if p:accept('[') then
            while p:peek() ~= ']' and p:peek() ~= nil do
                local ct = p:type()
                local cv = p:value(ct)
                p:accept(',')
                p:accept('label')
                I.cases[#I.cases + 1] = { v = cv, to = p:next() }
            end
        end
    elseif op == 'ret' then
        if p:peek() == 'void' then p:next() else I.T = p:type(); I.v = p:value(I.T) end
    elseif op == 'unreachable' then
    else
        I.unknown = true -- (atomicrmw, cmpxchg, va_arg, landingpad, vector ops …: the result unknown)
        if op == 'atomicrmw' or op == 'cmpxchg' then
            while FLAG[p:peek()] do p:next() end
            if op == 'atomicrmw' then p:next() end
            p:type()
            I.p = p:value()
        end
    end
    return I
end
M._inst = inst

-- ── the module ─────────────────────────────────────────────────────────────────────────────────────────────────
local Mod = {}
Mod.__index = Mod

function M.read(src)
    local text = type(src) == 'table' and src.text or assert(io.open(src, 'rb')):read('a')
    local lines = {}
    for l in (text .. '\n'):gmatch('([^\n]*)\n') do lines[#lines + 1] = l end
    local mod = setmetatable({ lines = lines, types = {}, typeline = {}, globals = {}, fns = {}, decls = {}, attrs = {}, cache = {}, gcache = {} }, Mod)
    local i, n = 1, #lines
    while i <= n do
        local l = lines[i]
        local c = l:sub(1, 1)
        if c == '%' then
            local name = tokens(l:match('^(%S+)') or '')[1] or (l:match('^(%%"[^"]+")'))
            if name then mod.typeline[name] = i end
        elseif c == '@' then
            local t = tokens(l:match('^(@"[^"]*"%s*=)') or l:match('^(%S+)') or '')
            if t[1] then mod.globals[t[1]] = { line = i } end
        elseif l:sub(1, 7) == 'define ' then
            local nm = tokens(l:match('(@"[^"]+")%(') or l:match('(@[%w%-%$%._]+)%(') or '')[1]
            local j = i
            while j <= n and lines[j] ~= '}' do j = j + 1 end
            local attr = l:match('%)[^{]-(#%d+)')
            if nm then mod.fns[nm] = { first = i, last = j, attr = attr } end
            i = j
        elseif l:sub(1, 8) == 'declare ' then
            local nm = tokens(l:match('(@"[^"]+")%(') or l:match('(@[%w%-%$%._]+)%(') or '')[1]
            if nm then mod.decls[nm] = { attr = l:match('%)[^%)]-(#%d+)%s*$') } end
        elseif l:sub(1, 11) == 'attributes ' then
            local g, body = l:match('^attributes (#%d+) = (%b{})')
            if g then mod.attrs[g] = body end
        elseif l:sub(1, 18) == 'target datalayout ' then mod.datalayout = l:match('"(.-)"')
        end
        i = i + 1
    end
    return mod
end

--- a named type's definition, parsed once
function Mod:type(name)
    local t = self.types[name]
    if t ~= nil then return t or nil end
    local i = self.typeline[name]
    if not i then self.types[name] = false; return nil end
    local l = self.lines[i]
    local rhs = l:match('=%s*type%s+(.*)$') or ''
    if rhs:match('^opaque') then self.types[name] = false; return nil end
    t = parser(tokens(rhs)):type()
    self.types[name] = t
    return t
end

--- does a function / a call's attribute group say NORETURN?
function Mod:noreturn(name, callattr)
    local function has(g) return g and self.attrs[g] and self.attrs[g]:find('%f[%w]noreturn%f[^%w]') ~= nil end
    if has(callattr) then return true end
    local d = self.decls[name] or self.fns[name]
    return d ~= nil and has(d.attr)
end

--- a global: its type and initializer (an operand), constant or not
function Mod:global(name)
    local g = self.gcache[name]
    if g ~= nil then return g or nil end
    local e = self.globals[name]
    if not e then self.gcache[name] = false; return nil end
    local l = self.lines[e.line]
    local rhs = l:match('^@"[^"]*"%s*=%s*(.*)$') or l:match('^%S+%s*=%s*(.*)$') or ''
    local p = parser(tokens(rhs))
    local constant, ext = false, false
    while p:peek() ~= nil and p:peek() ~= 'global' and p:peek() ~= 'constant' do
        local x = p:next()
        if x == 'external' or x == 'extern_weak' then ext = true end
        if p:peek() == '(' then p:skip_group() end
    end
    constant = p:next() == 'constant'
    local ty = p:type()
    local init = not ext and p:peek() ~= ',' and p:peek() ~= nil and p:value(ty) or nil
    g = { name = name, ty = ty, init = init, constant = constant, external = ext }
    self.gcache[name] = g
    return g
end

--- a function, parsed: its parameters and blocks (the ENTRY block's implicit label is the next unnamed number)
function Mod:fn(name)
    local f = self.cache[name]
    if f ~= nil then return f or nil end
    local e = self.fns[name]
    if not e then self.cache[name] = false; return nil end
    local head = self.lines[e.first]
    local p = parser(tokens(head))
    p:next() -- define
    -- (linkage, visibility, cc, return attributes … up to the return type before @name)
    local ret
    local toks = p.t
    local at
    for k = 2, #toks do if toks[k] == name and toks[k + 1] == '(' then at = k; break end end
    if not at then self.cache[name] = false; return nil end
    -- (the return type: parse from each candidate start until one ends right before the name)
    for s = 2, at - 1 do
        local q = parser(toks)
        q.i = s
        local ok, ty = pcall(q.type, q)
        if ok and q.i == at and ty.k ~= 'other' then ret = ty; break end
    end
    p.i = at + 2
    local params, unnamed = {}, 0
    while p:peek() ~= ')' and p:peek() ~= nil do
        if p:peek() == '...' or p:peek() == '.' then while p:peek() == '.' do p:next() end break end
        local ty = p:type()
        p:skip_attrs()
        local pn
        if type(p:peek()) == 'string' and p:peek():sub(1, 1) == '%' then pn = p:next() end
        if not pn or pn:match('^%%%d+$') then pn = pn or ('%' .. unnamed); unnamed = unnamed + 1 end
        params[#params + 1] = { ty = ty, name = pn }
        if not p:accept(',') then break end
    end
    f = { name = name, ret = ret or VOID, params = params, blocks = {}, order = {} }
    local cur = { label = '%' .. unnamed, insts = {} }
    f.entry = cur.label
    f.blocks[cur.label] = cur
    f.order[1] = cur.label
    for i = e.first + 1, e.last - 1 do
        local l = self.lines[i]
        local lab = l:match('^([%w%-%$%._]+):') or l:match('^"([^"]+)":')
        if lab then
            cur = { label = '%' .. lab, insts = {} }
            -- (the entry's own label, when printed, replaces the implicit one)
            if #f.order == 1 and #f.blocks[f.order[1]].insts == 0 then f.blocks[f.order[1]] = nil; f.order[1] = cur.label; f.entry = cur.label
            else f.order[#f.order + 1] = cur.label end
            f.blocks[cur.label] = cur
        elseif l:match('^%s+[%%%a]') and not l:match('^%s+#dbg_') then
            local I = inst(l)
            if I and not (I.op == 'call' and I.f and I.f:match('^@llvm%.dbg%.')) then cur.insts[#cur.insts + 1] = I end
        end
    end
    self.cache[name] = f
    return f
end

-- ── layout (x86-64: natural alignment; a packed struct none) ───────────────────────────────────────────────────
local function resolve(mod, ty, depth)
    depth = depth or 0
    while ty and ty.k == 'n' and depth < 50 do ty = mod:type(ty.name); depth = depth + 1 end
    return ty
end
M.resolve = resolve
function M.align(mod, ty)
    ty = resolve(mod, ty)
    if not ty then return 1 end
    if ty.k == 'i' then local b = math.ceil(ty.w / 8); if b <= 1 then return 1 elseif b <= 2 then return 2 elseif b <= 4 then return 4 elseif b <= 8 then return 8 else return 16 end end
    if ty.k == 'p' then return 8 end
    if ty.k == 'f' then return ty.w == 32 and 4 or ty.w == 16 and 2 or ty.w == 64 and 8 or 16 end
    if ty.k == 'a' then return M.align(mod, ty.e) end
    if ty.k == 'x' then local s = M.size(mod, ty); local a = 1; while a < s and a < 16 do a = a * 2 end return a end
    if ty.k == 's' then
        if ty.packed then return 1 end
        local a = 1
        for _, f in ipairs(ty.f) do a = math.max(a, M.align(mod, f)) end
        return a
    end
    return 1
end
--- the ALLOC size in bytes (what a GEP strides by)
function M.size(mod, ty)
    ty = resolve(mod, ty)
    if not ty then return 0 end
    if ty.cached_size then return ty.cached_size end
    local s
    if ty.k == 'i' then s = M.align(mod, ty) * math.ceil(math.ceil(ty.w / 8) / M.align(mod, ty))
    elseif ty.k == 'p' then s = 8
    elseif ty.k == 'f' then s = ty.w == 80 and 16 or ty.w / 8
    elseif ty.k == 'a' then s = ty.n * M.size(mod, ty.e)
    elseif ty.k == 'x' then s = ty.n * M.size(mod, ty.e)
    elseif ty.k == 's' then
        local off = 0
        for _, f in ipairs(ty.f) do
            if not ty.packed then local a = M.align(mod, f); off = math.ceil(off / a) * a end
            off = off + M.size(mod, f)
        end
        local a = M.align(mod, ty)
        s = math.ceil(off / a) * a
    else s = 0 end
    ty.cached_size = s
    return s
end
--- the byte offset of struct field i (1-based)
function M.field_offset(mod, ty, i)
    ty = resolve(mod, ty)
    if not (ty and ty.k == 's') then return nil end
    local off = 0
    for k, f in ipairs(ty.f) do
        if not ty.packed then local a = M.align(mod, f); off = math.ceil(off / a) * a end
        if k == i then return off, f end
        off = off + M.size(mod, f)
    end
    return nil
end

return M
