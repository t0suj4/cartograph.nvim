-- cartograph.cinterp.compile — THE CLOSURE COMPILER (CART-1317): each node of a function's tree compiled ONCE into a Lua
-- closure that does what cinterp's eval / exec do at that node, with everything the TREE decides read at compile time —
-- the node's type, its children, its operator and field text, a cast's C type, a literal's text, an identifier's name —
-- so a run touches no tree-sitter node at all. What a RUN decides (the path's env, types, tags, slots) stays in the
-- closures. It is a HAND BINDING-TIME ANALYSIS of eval: what is hoisted here is what mix must find static (CART-1278
-- S6), and this compiler is that projection's output oracle until the specializer replaces it.
-- ONE SEMANTICS, TWO EXECUTIONS: every arm below is eval's arm, line for line, its node reads moved up. The same
-- STEPS are counted (one per expression closure, one per statement — the budget and A.self see the same numbers), the
-- same allocations made where a value could be shared. A child is compiled LAZILY, the first time its parent reaches
-- it: a node's shape is read when eval would first read it, and code no run reaches is never compiled.
-- The DEFAULT ARM is eval's own default — an expression cinterp does not model is an UNKNOWN value — counted by type in
-- A.unmodeled, never a silent call back into eval. CARTOGRAPH_CINTERP=eval runs eval instead: the A/B.
return function (H)
    local A, ctx, M = H.A, H.ctx, H.M
    local tx, kids, literal, charlit, int, empty = H.tx, H.kids, H.literal, H.charlit, H.int, H.empty
    local split, union, narrow, join, vmap, truth, at = H.split, H.union, H.narrow, H.join, H.vmap, H.truth, H.at
    local rv, lift1, lift2, key_of, convert, veq = H.rv, H.lift1, H.lift2, H.key_of, H.convert, H.veq
    local icommon, ipromote, ityp = H.icommon, H.ipromote, H.ityp
    local readmem, read_field, call, write_slot = H.readmem, H.read_field, H.call, H.write_slot
    local layout, fr, binop, asnum, promote = H.layout, H.fr, H.binop, H.asnum, H.promote
    local bit = require 'bit'
    A.unmodeled = A.unmodeled or {}

    -- (eval's prologue: a step, the budget, a dead path)
    local function E(body)
        return function (st, cx)
            A.steps = A.steps + 1
            if A.steps > A.budget then cx.over = true; st.fset = {}; return nil end
            if next(st.fset) == nil then return nil end
            return body(st, cx)
        end
    end
    -- (a MISSING child — eval would index nil when it reaches it: the same failure, at the same moment)
    local NIL = E(function () error("cinterp: a node the tree does not have (eval: attempt to index local 'n' (a nil value))") end)

    local cexpr, cty, clv
    -- a child compiled the first time it runs: { closure } (the box's closure replaces itself)
    local function child(n, src)
        if n == nil then return { NIL } end
        local box = {}
        box[1] = function (st, cx) local f = cexpr(n, src); box[1] = f; n = nil; return f(st, cx) end
        return box
    end
    local function tychild(n, src)
        if n == nil then return { function () error('cinterp: stype of a node the tree does not have') end } end
        local box = {}
        box[1] = function (st) local f = cty(n, src); box[1] = f; n = nil; return f(st) end
        return box
    end
    local function lvchild(n, src)
        if n == nil then return { function () error('cinterp: lvalue_slot of a node the tree does not have') end } end
        local box = {}
        box[1] = function (st, cx) local f = clv(n, src); box[1] = f; n = nil; return f(st, cx) end
        return box
    end
    local function cleanobj(c, st)
        return vmap(st.fset, function (e) local x = at(c, e); if x and (x.k == 'unch' or x.k == 'unset' or x.k == 'any') then return nil end return x end)
    end
    local function narrowto(ty) return function (x) return x and x.k == 'i' and int(x.v, ty.w, ty.u) or x end end

    --- stype, compiled: an expression's STATIC integer type -> function (st) -> { w, u } | nil
    function cty(n, src)
        local t = n:type()
        if t == 'parenthesized_expression' then
            local c = kids(n)[1]
            if not c then return function () return nil end end
            local K = tychild(c, src)
            return function (st) return K[1](st) end
        elseif t == 'identifier' then
            local nm = tx(n, src)
            return function (st)
                if st.types[nm] then return ityp(st.types[nm]) end
                if ctx.enums[nm] then return { w = 32, u = false } end
                return nil
            end
        elseif t == 'number_literal' then
            local v = literal(tx(n, src))
            return function () return v and v.k == 'i' and { w = v.w, u = v.u } or nil end
        elseif t == 'char_literal' then return function () return { w = 32, u = false } end
        elseif t == 'cast_expression' then
            local ty = M.ctype(tx(n:field('type')[1], src), ctx.typedefs)
            return function () return ityp(ty) end
        elseif t == 'sizeof_expression' then return function () return { w = 64, u = true } end
        elseif t == 'unary_expression' then
            local op = tx(n:field('operator')[1], src)
            if op == '!' then return function () return { w = 32, u = false } end end
            local K = tychild(n:field('argument')[1], src)
            return function (st) local a = K[1](st); return a and ipromote(a) end
        elseif t == 'binary_expression' then
            local op = tx(n:field('operator')[1], src)
            if op == '&&' or op == '||' or op == '<' or op == '<=' or op == '>' or op == '>=' or op == '==' or op == '!=' then
                return function () return { w = 32, u = false } end
            end
            local L = tychild(n:field('left')[1], src)
            if op == '<<' or op == '>>' then return function (st) local a = L[1](st); return a and ipromote(a) end end
            local R = tychild(n:field('right')[1], src)
            return function (st) local a = L[1](st); local b = R[1](st); return a and b and icommon(a, b) or nil end
        elseif t == 'conditional_expression' then
            local Ka, Kb = tychild(n:field('consequence')[1], src), tychild(n:field('alternative')[1], src)
            return function (st) local a, b = Ka[1](st), Kb[1](st); return a and b and icommon(a, b) or nil end
        elseif t == 'assignment_expression' then
            local K = tychild(n:field('left')[1], src)
            return function (st) return K[1](st) end
        elseif t == 'call_expression' then
            local fnn = n:field('function')[1]
            local d = fnn and fnn:type() == 'identifier' and ctx.defs[tx(fnn, src)]
            return function () return d and ityp(d.rtype) or nil end
        end
        return function () return nil end
    end

    --- lvalue_slot, compiled: the slot an assignment target writes -> function (st, cx) -> slot index | nil
    function clv(n, src)
        local t = n:type()
        if t == 'field_expression' then
            local B, SUB = child(n:field('argument')[1], src), lvchild(n:field('argument')[1], src)
            return function (st, cx)
                local b = B[1](st, cx)
                if b and (b.k == 'slot' or b.k == 'field' or b.k == 'slotv') then return b.i end
                return SUB[1](st, cx)
            end
        elseif t == 'pointer_expression' or t == 'parenthesized_expression' then
            local K = child(kids(n)[1], src)
            return function (st, cx) local b = K[1](st, cx); if b and b.k == 'slot' then return b.i end return nil end
        elseif t == 'subscript_expression' then
            local B, I = child(n:field('argument')[1], src), child(n:field('index')[1], src)
            return function (st, cx)
                local b = B[1](st, cx)
                local i = I[1](st, cx)
                if b and b.k == 'slot' and i and i.k == 'i' then return b.i + asnum(i) end
                return nil
            end
        end
        return function () return nil end
    end

    local function unaryfn(op)
        return function (x)
            if op == '!' then local b = truth(x); if b == nil then return nil end return int(b and 0 or 1) end
            if x == nil then return nil end
            if x.k == 'd' then if op == '-' then return { k = 'd', v = -x.v } end return x end
            if x.k ~= 'i' then return nil end
            local px = promote(x)
            if op == '-' then return int(-px.v, px.w, px.u) elseif op == '~' then return int(bit.bnot(px.v), px.w, px.u) elseif op == '+' then return px end
            return nil
        end
    end
    local function derefn(x)
        if x and x.k == 'slot' then return { k = 'slotv', i = x.i } end
        if x and x.k == 'addr' then if x.to and x.to.k == 's' then return x end return readmem(x) end
        return nil
    end

    --- eval, compiled: an expression node -> function (st, cx) -> its value on the path (st.fset narrows; empty = dead)
    function cexpr(n, src)
        local t = n:type()
        if t == 'number_literal' then local text = tx(n, src); return E(function () return literal(text) end)
        elseif t == 'char_literal' then local text = tx(n, src); return E(function () return charlit(text) end)
        elseif t == 'string_literal' or t == 'concatenated_string' then return E(function () return { k = 'str' } end)
        elseif t == 'true' then return E(function () return int(1) end)
        elseif t == 'false' then return E(function () return int(0) end)
        elseif t == 'null' then return E(function () return { k = 'null' } end)
        elseif t == 'identifier' then
            local nm = tx(n, src)
            return E(function (st)
                local v = st.env[nm]
                if v ~= nil then return v end
                if ctx.enums[nm] then return int(ctx.enums[nm]) end
                return nil
            end)
        elseif t == 'parenthesized_expression' then
            local K = child(kids(n)[1], src)
            return E(function (st, cx) return K[1](st, cx) end)
        elseif t == 'comma_expression' then
            local L, R = child(n:field('left')[1], src), child(n:field('right')[1], src)
            return E(function (st, cx) L[1](st, cx); return R[1](st, cx) end)
        elseif t == 'binary_expression' then
            local op = tx(n:field('operator')[1], src)
            local L, R = child(n:field('left')[1], src), child(n:field('right')[1], src)
            if op == '&&' or op == '||' then
                local isand = op == '&&'
                return E(function (st, cx)
                    local a = rv(L[1](st, cx), st)
                    if empty(st.fset) then return nil end
                    local T, F, U = split(a, st.fset)
                    -- the tags the left side DECIDES skip the right side; the others evaluate it on their own path
                    local decided = isand and F or T
                    local rest = union(isand and T or F, U)
                    if empty(rest) then return int(isand and 0 or 1) end
                    local st2 = narrow(st, rest)
                    local b = rv(R[1](st2, cx), st2)
                    local r = join(narrow(st, decided), not empty(st2.fset) and st2 or nil)
                    if not r then st.fset = {}; return nil end
                    st.env, st.slots, st.fset, st.fwrite = r.env, r.slots, r.fset, r.fwrite
                    return vmap(st.fset, function (tg)
                        if decided[tg] then return int(isand and 0 or 1) end
                        local x, y = truth(at(a, tg)), truth(at(b, tg))
                        if isand then
                            if y == false then return int(0) end
                            if x == true and y == true then return int(1) end
                        else
                            if y == true then return int(1) end
                            if x == false and y == false then return int(0) end
                        end
                        return nil
                    end)
                end)
            end
            local eqop = op == '==' or op == '!='
            return E(function (st, cx)
                local a = rv(L[1](st, cx), st)
                local b = rv(R[1](st, cx), st)
                -- (the CONSTANTS an equality compares against — which words the code names: erts' atoms)
                if eqop then
                    for _, c in ipairs({ a, b }) do if c and c.k == 'i' then cx.compared[key_of(c)] = c end end
                end
                return lift2(op, a, b, st)
            end)
        elseif t == 'unary_expression' then
            local fn = unaryfn(tx(n:field('operator')[1], src))
            local K = child(n:field('argument')[1], src)
            return E(function (st, cx) local a = rv(K[1](st, cx), st); return lift1(fn, a, st) end)
        elseif t == 'sizeof_expression' then
            -- (a SIZE is the compiler's: the sizes fact holds every operand of the unit; a plain integer / pointer type
            -- is its own width)
            local c = n:field('type')[1] or n:field('value')[1]
            local o = c and vim.trim(tx(c, src):gsub('%s+', ' ')) or ''
            while o:match('^%b()$') do o = vim.trim(o:sub(2, -2)) end
            local ty = M.ctype(o, ctx.typedefs)
            return E(function (st)
                local s = ctx.sizes and (ctx.sizes[st.unit] or {})[o]
                if s then return int(s, 64, true) end
                if ty and ty.k == 'i' then return int(ty.w / 8, 64, true) end
                if ty and ty.k == 'p' then return int(8, 64, true) end
                return nil
            end)
        elseif t == 'compound_literal_expression' then
            -- (an AGGREGATE value `(T){ … }`: positional members in T's declaration order, `.f = v` by name, a nested
            -- literal flattened into paths)
            local T = vim.trim(tx(n:field('type')[1], src):gsub('%s+', ' '))
            local ag = ctx.aggregates and ctx.aggregates[T]
            if not ag then return E(function () return nil end) end
            local items, i = {}, 0
            for _, c in ipairs(kids(n:field('value')[1])) do
                local name, valnode
                if c:type() == 'initializer_pair' then
                    local d = c:field('designator')[1]
                    name = d and tx(d, src):match('^%.([%w_]+)$')
                    valnode = c:field('value')[1]
                else i = i + 1; name = ag.fields[i] and ag.fields[i].name; valnode = c end
                if name and valnode then items[#items + 1] = { name = name, K = child(valnode, src) } end
            end
            return E(function (st, cx)
                local f = {}
                for _, it in ipairs(items) do
                    local v = rv(it.K[1](st, cx), st)
                    if v and v.k == 'agg' then for p, x in pairs(v.f) do f[it.name .. '.' .. p] = x end
                    elseif v ~= nil then f[it.name] = v end
                end
                return { k = 'agg', T = T, f = f }
            end)
        elseif t == 'cast_expression' then
            local ty = M.ctype(tx(n:field('type')[1], src), ctx.typedefs)
            local fn = function (x) return convert(ty, x) end
            local K = child(n:field('value')[1], src)
            return E(function (st, cx) local a = rv(K[1](st, cx), st); return lift1(fn, a, st) end)
        elseif t == 'conditional_expression' then
            local Kc, Ka, Kb = child(n:field('condition')[1], src), child(n:field('consequence')[1], src), child(n:field('alternative')[1], src)
            local TA, TB = tychild(n:field('consequence')[1], src), tychild(n:field('alternative')[1], src)
            return E(function (st, cx)
                local c = rv(Kc[1](st, cx), st)
                if empty(st.fset) then return nil end
                local T, F, U = split(c, st.fset)
                local sa, sb = narrow(st, union(T, U)), narrow(st, union(F, U))
                local va = sa and Ka[1](sa, cx)
                local vb = sb and Kb[1](sb, cx)
                if sa and empty(sa.fset) then sa = nil end
                if sb and empty(sb.fset) then sb = nil end
                local r = join(sa, sb)
                if not r then st.fset = {}; return nil end
                st.env, st.slots, st.fset, st.fwrite = r.env, r.slots, r.fset, r.fwrite
                -- (C 6.5.15p5: both arms convert to their usual-arithmetic-conversion type, whichever one ran)
                local ta, tb = TA[1](st), TB[1](st)
                local C = ta and tb and icommon(ta, tb)
                local function cv(x) if C and x and x.k == 'i' then return int(x.v, C.w, C.u) end return x end
                return vmap(st.fset, function (tg)
                    local ina, inb = sa and sa.fset[tg], sb and sb.fset[tg]
                    if ina and not inb then return cv(at(va, tg)) elseif inb and not ina then return cv(at(vb, tg)) end
                    local x, y = cv(at(va, tg)), cv(at(vb, tg))
                    if veq(x, y) then return x end
                    return nil
                end)
            end)
        elseif t == 'field_expression' then
            local B = child(n:field('argument')[1], src)
            local op = tx(n:field('operator')[1], src)
            local f = tx(n:field('field')[1], src)
            -- (a field of an AGGREGATE VALUE: its path's value, or a view of the nested aggregate the path names)
            local function aggfield(b)
                local p = (b.prefix or '') .. f
                if b.f[p] ~= nil then return b.f[p] end
                for q in pairs(b.f) do if q:sub(1, #p + 1) == p .. '.' then return { k = 'agg', T = b.T, f = b.f, prefix = p .. '.' } end end
                return nil
            end
            return E(function (st, cx)
                local base = B[1](st, cx)
                -- (a field of an AGGREGATE behind an ADDRESS: where the compiler lays it)
                local anyaddr = base and base.k == 'addr'
                if base and base.k == 'vec' then for _, x in pairs(base.by) do if x and x.k == 'addr' then anyaddr = true end end end
                if ctx.layout_of and anyaddr then
                    return vmap(st.fset, function (tg)
                        local b = at(base, tg)
                        if not (b and b.k == 'addr') then return M._field(b, op, f, st, layout, read_field) end
                        if not (b.to and b.to.k == 's') then return nil end
                        local path = (b.to.prefix or '') .. f
                        local fl = ctx.layout_of(st.unit, b.to.text, path)
                        if not fl then return nil end
                        if fl.array then return { k = 'addr', v = b.v + fl.off, to = fl.elem } end
                        local p = { k = 'addr', v = b.v + fl.off, to = fl.to }
                        if fl.to and fl.to.k == 'p' and not fl.to.to then
                            local pto = M.field_pointee(ctx, b.to.text, path)
                            if pto then p.to = { k = 'p', to = pto } end
                        end
                        if fl.to and fl.to.k == 's' then p.to = { k = 's', text = b.to.text, prefix = path .. '.' }; return p end
                        return readmem(p)
                    end)
                end
                -- THE FRAME: its top / base are VALUES of the path; its ORIGIN is one value
                if base and base.k == 'thread' and op == '->' then
                    if f == fr.top then return st.env['\0top'] elseif f == fr.base then return st.env['\0base'] end
                    if f == fr.origin then return { k = 'org' } end
                    return nil
                end
                if base and base.k == 'agg' and op == '.' then return aggfield(base) end
                if base and base.k == 'vec' and op == '.' then
                    local anyagg = false
                    for _, x in pairs(base.by) do if x and x.k == 'agg' then anyagg = true end end
                    if anyagg then return vmap(st.fset, function (e) local b = at(base, e); if b and b.k == 'agg' then return aggfield(b) end return M._field(b, op, f, st, layout, read_field) end) end
                end
                if base and base.k == 'obj' then return cleanobj(st.env['\0obj:' .. base.id .. '.' .. f], st) end
                if base and base.k == 'vec' then
                    return vmap(st.fset, function (e) return M._field(at(base, e), op, f, st, layout, read_field) end)
                end
                return M._field(base, op, f, st, layout, read_field)
            end)
        elseif t == 'pointer_expression' then
            local op = tx(n:field('operator')[1], src)
            local arg = n:field('argument')[1]
            local K = child(arg, src)
            if op == '&' then
                local aid = arg:type() == 'identifier'
                local aname = aid and tx(arg, src) or nil
                local text = tx(arg, src):gsub('%s', '')
                local tail = text:match('([%w_]+%.[%w_]+)$')
                return E(function (st, cx)
                    -- (the ADDRESS of a global object the RUNNING runtime placed: ctx.symaddr, from a linked probe)
                    if ctx.symaddr and aid then
                        local s = ctx.symaddr[aname]
                        if s then return { k = 'addr', v = s.v, to = s.type and { k = 's', text = s.type } or nil } end
                    end
                    -- (the address of a LOCAL — an OUT-PARAMETER — is a CELL whose field `*` holds the local)
                    if aid and st.types[aname] ~= nil then
                        local cur = st.env[aname]
                        local cell = { k = 'obj', id = '&' .. aname .. '@' .. tostring(st.fname) .. '=' .. key_of(cur), cell = aname, init = cur ~= nil and { ['*'] = cur } or nil }
                        st.env['\0obj:' .. cell.id .. '.*'] = cur
                        return cell
                    end
                    local v = K[1](st, cx)
                    if v and v.k == 'slotv' then return { k = 'slot', i = v.i } end
                    -- the ADDRESS of a field of VM state: a sentinel, compared by its text
                    return { k = 'sym', s = text, tag = tail and ctx.sentinels[tail] or nil }
                end)
            end
            return E(function (st, cx)
                local v = K[1](st, cx)
                if v and v.k == 'obj' then return cleanobj(st.env['\0obj:' .. v.id .. '.*'], st) end
                return lift1(derefn, v, st)
            end)
        elseif t == 'subscript_expression' then
            local B, I = child(n:field('argument')[1], src), child(n:field('index')[1], src)
            return E(function (st, cx)
                local b = B[1](st, cx)
                local i = rv(I[1](st, cx), st)
                -- (a LOCAL ARRAY: its elements are values of the path, read by index)
                if b and b.k == 'arr' then return i and i.k == 'i' and b.vals[asnum(i) + 1] or nil end
                if (b and (b.k == 'addr' or b.k == 'vec')) then
                    return vmap(st.fset, function (tg)
                        local x, j = at(b, tg), at(i, tg)
                        if x and x.k == 'addr' and j and j.k == 'i' then return readmem(binop('+', x, j)) end
                        return binop('@index', x, j)
                    end)
                end
                return lift2('@index', b, i, st)
            end)
        elseif t == 'call_expression' then
            local fnode = n:field('function')[1]
            local argkids = kids(n:field('arguments')[1])
            -- (`(Eterm)(x)`: a cast to a TYPEDEF NAME the parser read as a call of a parenthesized identifier)
            local pn = fnode and fnode:type() == 'parenthesized_expression' and kids(fnode)[1]
            if pn and pn:type() == 'identifier' and ctx.typedefs[tx(pn, src)] and #argkids == 1 then
                local ty = M.ctype(tx(pn, src), ctx.typedefs)
                local fn = function (x) return convert(ty, x) end
                local K = child(argkids[1], src)
                return E(function (st, cx) local a = rv(K[1](st, cx), st); return lift1(fn, a, st) end)
            end
            local AK, spoilnames = {}, {}
            for i, a in ipairs(argkids) do
                AK[i] = child(a, src)
                if a:type() == 'identifier' then spoilnames[#spoilnames + 1] = tx(a, src) end
            end
            local isid = fnode:type() == 'identifier'
            local fname = isid and tx(fnode, src) or nil
            -- (a LOCAL ARRAY handed to a call is the callee's to write: the caller's elements are unknown after it)
            local function spoil(st)
                for _, nm in ipairs(spoilnames) do
                    local v = st.env[nm]
                    if v and v.k == 'arr' then st.env[nm] = { k = 'arr', id = v.id, n = v.n, vals = {} } end
                end
            end
            return E(function (st, cx)
                -- (arguments by POSITION: an unknown one is a nil, and appending would shift the rest)
                local args = { n = 0 }
                for i = 1, #AK do
                    args[i] = rv(AK[i][1](st, cx), st)
                    args.n = i
                    if empty(st.fset) then return nil end
                end
                if not isid then
                    for i = 1, args.n do local a = args[i]; if a and a.k == 'slot' then write_slot(a.i, st) end end
                    spoil(st)
                    return nil
                end
                local r = call(fname, args, st, cx)
                spoil(st)
                -- (an OUT-PARAMETER cell handed to the call: the caller's local is what the callee left in it)
                for i = 1, args.n do
                    local a = args[i]
                    if a and a.k == 'obj' and a.cell and st.types[a.cell] ~= nil then
                        st.env[a.cell] = cleanobj(st.env['\0obj:' .. a.id .. '.*'], st)
                    end
                end
                return r
            end)
        elseif t == 'assignment_expression' then
            local l, r = n:field('left')[1], n:field('right')[1]
            -- (a PARENTHESIZED target is its inside)
            while l and l:type() == 'parenthesized_expression' and kids(l)[1] do l = kids(l)[1] end
            local op = tx(n:field('operator')[1], src)
            local aop = op ~= '=' and op:sub(1, -2) or nil
            local R = child(r, src)
            local lt = l:type()
            local LV = lvchild(l, src)
            local function final(st, cx, v) write_slot(LV[1](st, cx), st); return v end -- (a WRITE to a slot: unknown after)
            if lt == 'identifier' then
                local nm = tx(l, src)
                return E(function (st, cx)
                    local v = rv(R[1](st, cx), st)
                    if empty(st.fset) then return nil end
                    if aop then v = lift2(aop, st.env[nm], v, st) end
                    local ty = st.types[nm]
                    if ty and ty.k == 'i' then v = lift1(narrowto(ty), v, st) end
                    st.env[nm] = v
                    return v
                end)
            end
            if lt == 'subscript_expression' and l:field('argument')[1]:type() == 'identifier' then
                local nm = tx(l:field('argument')[1], src)
                local I = child(l:field('index')[1], src)
                return E(function (st, cx)
                    local v = rv(R[1](st, cx), st)
                    if empty(st.fset) then return nil end
                    local a = st.env[nm]
                    if a and a.k == 'arr' then
                        local i = rv(I[1](st, cx), st)
                        local c = { k = 'arr', id = a.id, n = a.n, vals = {} }
                        for j = 1, a.n do c.vals[j] = a.vals[j] end
                        if i and i.k == 'i' and asnum(i) >= 0 then
                            local j = asnum(i) + 1
                            if aop then v = lift2(aop, a.vals[j], v, st) end
                            c.vals[j] = v
                            if j > c.n then c.n = j end
                        else c.vals, c.n = {}, a.n end -- (an unknown index: every element unknown after it)
                        st.env[nm] = c
                        return v
                    end
                    return final(st, cx, v)
                end)
            end
            if lt == 'field_expression' then
                local argn = l:field('argument')[1]
                local LB = child(argn, src)
                local lf = tx(l:field('field')[1], src)
                local argname = argn:type() == 'identifier' and tx(argn, src) or nil
                -- (the stack IS where L->stack points: a local stored there is the origin)
                local x = r
                while x and (x:type() == 'cast_expression' or x:type() == 'parenthesized_expression') do
                    x = x:type() == 'cast_expression' and x:field('value')[1] or kids(x)[1]
                end
                local orgname = x and x:type() == 'identifier' and tx(x, src) or nil
                return E(function (st, cx)
                    local v = rv(R[1](st, cx), st)
                    if empty(st.fset) then return nil end
                    local lb = LB[1](st, cx)
                    if lb and lb.k == 'thread' and (lf == fr.top or lf == fr.base) then
                        local key = lf == fr.top and '\0top' or '\0base'
                        if aop then v = lift2(aop, st.env[key], v, st) end
                        st.env[key] = v
                        return v
                    end
                    if lb and lb.k == 'agg' and argname and op == '=' then
                        local nf = {}
                        for p, y in pairs(lb.f) do nf[p] = y end
                        local p = (lb.prefix or '') .. lf
                        for q in pairs(nf) do if q == p or q:sub(1, #p + 1) == p .. '.' then nf[q] = nil end end
                        if v ~= nil then nf[p] = v end
                        st.env[argname] = { k = 'agg', T = lb.T, f = nf }
                        return v
                    end
                    if lb and lb.k == 'obj' then
                        local key = '\0obj:' .. lb.id .. '.' .. lf
                        if aop then v = lift2(aop, st.env[key], v, st) end
                        st.env[key] = v
                        return v
                    end
                    if lb and lb.k == 'org' then
                        if orgname then st.env[orgname] = { k = 'org' } end
                        return v
                    end
                    return final(st, cx, v)
                end)
            end
            if lt == 'pointer_expression' and tx(l:field('operator')[1], src) == '*' then
                local LB = child(l:field('argument')[1], src)
                return E(function (st, cx)
                    local v = rv(R[1](st, cx), st)
                    if empty(st.fset) then return nil end
                    local lb = LB[1](st, cx)
                    if lb and lb.k == 'obj' then
                        local key = '\0obj:' .. lb.id .. '.*'
                        if aop then v = lift2(aop, st.env[key], v, st) end
                        st.env[key] = v
                        if lb.cell and st.types[lb.cell] ~= nil then st.env[lb.cell] = v end
                        return v
                    end
                    return final(st, cx, v)
                end)
            end
            return E(function (st, cx)
                local v = rv(R[1](st, cx), st)
                if empty(st.fset) then return nil end
                return final(st, cx, v)
            end)
        elseif t == 'update_expression' then
            local a = n:field('argument')[1]
            while a and a:type() == 'parenthesized_expression' and kids(a)[1] do a = kids(a)[1] end
            local whole = tx(n, src)
            local uop = whole:find('%+%+') and '+' or '-'
            local pre = whole:sub(1, 2) == '++' or whole:sub(1, 2) == '--'
            if a:type() == 'field_expression' then
                local LB = child(a:field('argument')[1], src)
                local lf = tx(a:field('field')[1], src)
                return E(function (st, cx)
                    local lb = LB[1](st, cx)
                    if lb and lb.k == 'thread' and (lf == fr.top or lf == fr.base) then
                        local key = lf == fr.top and '\0top' or '\0base'
                        local old = st.env[key]
                        local new = lift2(uop, old, int(1), st)
                        st.env[key] = new
                        return pre and new or old
                    end
                    return nil
                end)
            end
            if a:type() == 'identifier' then
                local nm = tx(a, src)
                return E(function (st)
                    local old = st.env[nm]
                    local new = lift2(uop, old, int(1), st)
                    -- (C 6.5.2.4: the result is stored back in the operand's own type, as an assignment is — CART-1289)
                    local ty = st.types[nm]
                    if ty and ty.k == 'i' then new = lift1(narrowto(ty), new, st) end
                    st.env[nm] = new
                    return pre and new or old
                end)
            end
            return E(function () return nil end)
        end
        -- THE DEFAULT ARM — eval's own: an expression cinterp does not model is an UNKNOWN value; counted by type
        A.unmodeled[t] = (A.unmodeled[t] or 0) + 1
        return E(function () return nil end)
    end

    --- exec, compiled: a SIMPLE statement (a declaration, an expression — a graph node's work) -> function (st, cx) ->
    --- the state after it (nil: dead)
    local function cstmt(n, src)
        local t = n:type()
        if t == 'declaration' then
            local ty = M.ctype(tx(n:field('type')[1], src), ctx.typedefs)
            local decls = {}
            for _, d in ipairs(n:field('declarator')) do
                local dd, val, isptr = d, nil, false
                if d:type() == 'init_declarator' then dd = d:field('declarator')[1]; val = d:field('value')[1] end
                while dd and dd:type() == 'pointer_declarator' do isptr = true; dd = dd:field('declarator')[1] end
                if dd and dd:type() == 'array_declarator' and dd:field('declarator')[1] and dd:field('declarator')[1]:type() == 'identifier' then
                    -- (a LOCAL ARRAY, passed on BY VALUE)
                    local inits
                    if val and val:type() == 'initializer_list' then inits = {}; for j, e in ipairs(kids(val)) do inits[j] = child(e, src) end end
                    decls[#decls + 1] = { arr = true, name = tx(dd:field('declarator')[1], src), inits = inits }
                elseif dd and dd:type() == 'identifier' then
                    decls[#decls + 1] = { name = tx(dd, src), isptr = isptr, V = val and val:type() ~= 'initializer_list' and child(val, src) or nil }
                end
            end
            return function (st, cx)
                if not st or empty(st.fset) then return nil end
                A.steps = A.steps + 1
                if A.steps > A.budget then cx.over = true; return nil end
                for _, D in ipairs(decls) do
                    if D.arr then
                        local a = { k = 'arr', id = D.name, n = 0, vals = {} }
                        if D.inits then for j, I in ipairs(D.inits) do a.vals[j] = rv(I[1](st, cx), st); a.n = j end end
                        st.env[D.name] = a
                    else
                        local vty = D.isptr and { k = 'p' } or ty
                        st.types[D.name] = vty
                        local v
                        if D.V then v = rv(D.V[1](st, cx), st) end
                        if empty(st.fset) then return nil end
                        if vty and vty.k == 'i' then v = lift1(narrowto(vty), v, st) end
                        st.env[D.name] = v
                    end
                end
                return st
            end
        end
        local e = t == 'expression_statement' and kids(n)[1] or (t ~= 'expression_statement' and n or nil)
        local K = e and child(e, src)
        return function (st, cx)
            if not st or empty(st.fset) then return nil end
            A.steps = A.steps + 1
            if A.steps > A.budget then cx.over = true; return nil end
            if K then K[1](st, cx) end
            if empty(st.fset) then return nil end
            return st
        end
    end

    --- a graph node's compiled work, per ANALYZER (several analyzers — each its own ctx — share one definition's graph):
    --- code(g, id, d) -> { stmt | expr | ret = closure }, and an edge's case value: case(g, e, d)
    local per = setmetatable({}, { __mode = 'k' })
    local C = {}
    function C.node(g, id, d)
        local m = per[g]
        if not m then m = {}; per[g] = m end
        local c = m[id]
        if c then return c end
        local node = g.nodes[id]
        if node.k == 'stmt' then c = { stmt = cstmt(node.ast, d.src) }
        elseif node.k == 'cond' or node.k == 'switch' then c = { expr = child(node.ast, d.src) }
        elseif node.k == 'ret' then local ex = kids(node.ast)[1]; c = { ret = ex and child(ex, d.src) or false }
        else c = {} end
        m[id] = c
        return c
    end
    function C.case(g, e, d)
        local m = per[g]
        if not m then m = {}; per[g] = m end
        local c = m[e]
        if not c then c = child(e.val, d.src); m[e] = c end
        return c
    end
    return C
end
