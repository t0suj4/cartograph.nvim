-- cartograph.flowtype — WHAT VALUE REACHES A RECEIVER, BY FLOW (CART-1621: local type inference → record shapes).
--
-- An inclusion-based (Andersen) points-to analysis over a Lua tree: every value position is a PORT; objects — the
-- table constructors, the functions, and TYPE objects (`string`, a profile's `file` / `TSNode` …) — flow along
-- assignments, arguments to the parameters of the resolved callee (or, on the fly, of every function the callee
-- port holds), returns, `require` (the module's returned value), a `setmetatable(t, mt)` __index link (t's objects
-- read mt.__index's fields), `pcall` / `xpcall`, `for … in pairs / ipairs` (values: the `[]` field; keys: `{k}`).
-- Fields are per OBJECT; a dynamic-key load reads every field. A profile's declared return types an external call's
-- result (tostring -> string, io.open -> file) and a method on a typed object (s:sub -> string, n:parent -> TSNode).
--
-- ★ WHY INCLUSION AND NOT UNIFICATION. Measured on lua/cartograph (the prototype): unification (Steensgaard) merged
-- every string with hazard.lua's string-API objects — 1572 wrong exact answers to 91 right; inclusion: 214 exact,
-- every one checked right (41 of them a function the name join never listed: at.lua's `C.sl` IS bytecol's returned
-- reader closure), 772 calls whose receiver is only ever a string.
--
-- ★ AN ANSWER IS A CLAIM ONLY WHEN NOTHING UNKNOWN REACHES THE RECEIVER. A port past CAP objects is `top` and that
-- spreads to whatever it flows into; an external call with no declared return yields EXT; with `open` (default), a
-- function a module exports takes EXT at its parameters (its callers are not all in the tree). A receiver holding
-- EXT or top gets no verdict. What the tree does not hold is a frontier, never a guess.
--
--   M.of(store, opts) -> R, cached per graph generation; R.verdict(c) -> nil | { kind = 'exact' | 'narrowed' |
--     'string' | 'typed', targets = { fn id … } (exact / narrowed), type = 'string' | <profile type> }
--   for a REFUSED-ambiguous call `x.m()` / `x:m()` (the calls the name join could not decide). R.stats: the counts.
local callrec = require 'cartograph.callrec'
local atr = require 'cartograph.at'
local tsutil = require 'cartograph.spec.tsutil'
local EMPTY_NODE = { child = function () return nil end } -- (an absent child list: tsutil.inext over nothing)

local M = {}
M.CAP = 64

local function build(store, opts)
    opts = opts or {}
    local open = opts.open ~= false
    local t0 = vim.uv.hrtime()
    -- ── the solver: ports are ints, objects are ints ────────────────────────────────────────────────
    local N, NO = 0, 0
    local pts, cnt, top, delta = {}, {}, {}, {}
    local succ, loads, stores, calls, mflows, protos_at = {}, {}, {}, {}, {}, {}
    local ofield, olodes, anyload, protos, fnports, obinfo = {}, {}, {}, {}, {}, {}
    local wl, inwl = {}, {}
    local function new() N = N + 1; return N end
    local function newobj(info) NO = NO + 1; obinfo[NO] = info; return NO end
    local function push(p) if not inwl[p] then inwl[p] = true; wl[#wl + 1] = p end end
    -- (SPREAD: a saturated port makes everything it flows into unknown — sound, and measured to blank 1252 of 3674
    -- receivers on lua/cartograph: a registration helper `cmd(name, fn)` takes every handler at one parameter, and
    -- context-insensitive flow carries that set everywhere the helper's value goes. Off by default: a saturated port
    -- DROPS OUT — its objects are not propagated — and a verdict is a claim over the flows kept, which every sampled
    -- verdict held. Consumers hedge it (~). Context sensitivity for such helpers is the real fix.)
    local spread = opts.spread == true
    local function settop(p)
        if top[p] then return end
        top[p] = true; pts[p] = nil; delta[p] = nil
        if spread then push(p) end
    end
    -- (a port's objects: ONE object is the number itself, more a set — most ports hold one, and a table per port was
    -- the memory: 1.3 GB on lua/cartograph)
    local EMPTY = {}
    local function one(st, ctl) if ctl == nil then return st end end
    local function each(p)
        local s = pts[p]
        if s == nil then return next, EMPTY, nil end
        if type(s) == 'number' then return one, s, nil end
        return next, s, nil
    end
    local function has(p, o)
        local s = pts[p]
        if type(s) == 'number' then return s == o end
        return s ~= nil and s[o] == true
    end
    local function addobj(p, o)
        if top[p] then return end
        local s = pts[p]
        if s == nil then pts[p] = o; cnt[p] = 1
        elseif type(s) == 'number' then
            if s == o then return end
            pts[p] = { [s] = true, [o] = true }; cnt[p] = 2
        else
            if s[o] then return end
            s[o] = true
            cnt[p] = cnt[p] + 1
        end
        if cnt[p] > M.CAP then return settop(p) end
        local d = delta[p]
        if not d then d = {}; delta[p] = d end
        d[#d + 1] = o
        push(p)
    end
    local function edge(a, b) -- pts(b) ⊇ pts(a)
        if a == b then return end
        local s = succ[a]
        if not s then s = {}; succ[a] = s end
        if s[b] then return end
        s[b] = true
        if top[a] then if spread then settop(b) end; return end
        for o in each(a) do addobj(b, o) end
    end
    local function ofp(o, f)
        local m = ofield[o]
        if not m then m = {}; ofield[o] = m end
        local p = m[f]
        if not p then
            p = new(); m[f] = p
            if f ~= '{k}' then for _, dst in ipairs(anyload[o] or {}) do edge(p, dst) end end
        end
        return p
    end
    -- (STRICT: a language whose records have no dynamic keys — Go — reads exactly the field: a named load never reads
    -- `[]`, a `[]` load never reads every field. Lua's `t[k] = v` may write any field, so there both widen)
    local function load_obj(o, f, dst, seen, strict)
        seen = seen or {}
        if seen[o] then return end
        seen[o] = true
        if strict then
            edge(ofp(o, f), dst)
        elseif f == '[]' then
            local al = anyload[o]
            if not al then al = {}; anyload[o] = al end
            al[#al + 1] = dst
            for fk, fp in pairs(ofield[o] or {}) do if fk ~= '{k}' then edge(fp, dst) end end
        else
            edge(ofp(o, f), dst)
            edge(ofp(o, '[]'), dst)
        end
        local l = olodes[o]
        if not l then l = {}; olodes[o] = l end
        local key = f .. '\0' .. dst
        if not l[key] then l[key] = true; l[#l + 1] = { f, dst, strict } end
        for c in pairs(protos[o] or {}) do load_obj(c, f, dst, seen, strict) end
    end
    local function field(x, f, strict) -- a LOAD x.f -> its result port
        local dst = new()
        local l = loads[x]
        if not l then l = {}; loads[x] = l end
        l[#l + 1] = { f, dst, strict }
        if top[x] and spread then settop(dst) end
        for o in each(x) do load_obj(o, f, dst, nil, strict) end
        return dst
    end
    local function storec(x, f, v)
        local l = stores[x]
        if not l then l = {}; stores[x] = l end
        l[#l + 1] = { f, v }
        for o in each(x) do edge(v, ofp(o, f)) end
    end
    local function proto(t, idx)
        local l = protos_at[t]
        if not l then l = {}; protos_at[t] = l end
        l[#l + 1] = idx
    end
    local function objproto(o, c) -- o's loads also read c's fields (an EMBEDDED type's methods: Go promotion)
        local pr = protos[o]
        if not pr then pr = {}; protos[o] = pr end
        if pr[c] then return end
        pr[c] = true
        for _, ld in ipairs(olodes[o] or {}) do load_obj(c, ld[1], ld[2], nil, ld[3]) end
    end
    -- (a GUARDED flow: dst holds the objects of src whose prototype chain reaches an object of gp — `x instanceof
    -- C` narrows x to C's instances; prototypes are whole only after a solve, so it is re-run to a fixpoint below)
    local gfilters = {}
    local function gfilter(src, dst, gp) gfilters[#gfilters + 1] = { src, dst, gp, {} } end
    -- (a FILTERED flow: only the objects `pred` admits — a type assertion `x.(*T)` is a runtime type check)
    local filters = {}
    local function filter(a, b, pred)
        local l = filters[a]
        if not l then l = {}; filters[a] = l end
        l[#l + 1] = { b, pred }
        for o in each(a) do if pred(o) then addobj(b, o) end end
    end
    local function bindcall(o, args, res)
        local fp = fnports[o]
        if not fp then return end
        for i, a in ipairs(args) do if fp.params[i] then edge(a, fp.params[i]) end end
        -- (a MULTI-value result — Go's `v, err := f()` — is a list of ports: the i-th return to the i-th)
        if type(res) == 'table' then
            for i, r in ipairs(res) do local fr = fp.rets and fp.rets[i] or (i == 1 and fp.ret); if fr then edge(fr, r) end end
        else edge(fp.ret, res) end
    end
    local function callc(callee, args, res)
        local l = calls[callee]
        if not l then l = {}; calls[callee] = l end
        l[#l + 1] = { args, res }
        if top[callee] and spread and type(res) ~= 'table' then settop(res) end
        for o in each(callee) do bindcall(o, args, res) end
    end
    -- type objects and the profiles' declared returns
    local TYPEOBJ, TNAME = {}, {}
    local function typeobj(t)
        local o = TYPEOBJ[t]
        if not o then o = newobj('type:' .. t); TYPEOBJ[t] = o; TNAME[o] = t end
        return o
    end
    local STR = typeobj('string')
    local EXT = newobj('external')
    local PSIGS = {}
    do
        local P = require 'cartograph.spec.profile'
        for _, nm in ipairs { P.base_for('lua'), store.data.profile } do
            local pr = nm and P.load(nm)
            for k, v in pairs(pr and pr.sigs or {}) do if PSIGS[k] == nil then PSIGS[k] = v end end
        end
    end
    local RET = {}
    local function ret1(key)
        local r = RET[key]
        if r ~= nil then return r or nil end
        local sg = PSIGS[key]
        local r1 = type(sg) == 'table' and sg.returns and sg.returns[1]
        local ty = r1 and r1.type
        local one
        if type(ty) == 'string' then
            for part in (ty:gsub('%s', '') .. '|'):gmatch('([^|]*)|') do
                part = part:gsub('%?$', ''):gsub('%*$', '')
                if part ~= '' and part ~= 'nil' then
                    if one and one ~= part then one = nil; break end
                    one = part
                end
            end
        end
        RET[key] = one or false
        return one
    end
    local function mflow(recv, m, res) -- a method on a TYPED object returns its signature's type
        local l = mflows[recv]
        if not l then l = {}; mflows[recv] = l end
        l[#l + 1] = { m, res }
        for o in each(recv) do
            local tn = TNAME[o]
            local rt = tn and ret1(tn .. '#' .. m)
            if rt then addobj(res, typeobj(rt)) end
        end
    end
    local function solve()
        while #wl > 0 do
            local p = table.remove(wl)
            inwl[p] = nil
            if top[p] then
                for q in pairs(succ[p] or {}) do settop(q) end
                for _, ld in ipairs(loads[p] or {}) do settop(ld[2]) end
                for _, cl in ipairs(calls[p] or {}) do if type(cl[2]) ~= 'table' then settop(cl[2]) end end
            else
                local d = delta[p]
                delta[p] = nil
                if d then
                    for q in pairs(succ[p] or {}) do for _, o in ipairs(d) do addobj(q, o) end end
                    for _, ld in ipairs(loads[p] or {}) do for _, o in ipairs(d) do load_obj(o, ld[1], ld[2], nil, ld[3]) end end
                    for _, st in ipairs(stores[p] or {}) do for _, o in ipairs(d) do edge(st[2], ofp(o, st[1])) end end
                    for _, cl in ipairs(calls[p] or {}) do for _, o in ipairs(d) do bindcall(o, cl[1], cl[2]) end end
                    for _, fl in ipairs(filters[p] or {}) do
                        for _, o in ipairs(d) do if fl[2](o) then addobj(fl[1], o) end end
                    end
                    for _, mf in ipairs(mflows[p] or {}) do
                        for _, o in ipairs(d) do
                            local tn = TNAME[o]
                            local rt = tn and ret1(tn .. '#' .. mf[1])
                            if rt then addobj(mf[2], typeobj(rt)) end
                        end
                    end
                    for _, idx in ipairs(protos_at[p] or {}) do
                        for _, o in ipairs(d) do
                            for c in each(idx) do
                                local pr = protos[o]
                                if not pr then pr = {}; protos[o] = pr end
                                if not pr[c] then
                                    pr[c] = true
                                    for _, ld in ipairs(olodes[o] or {}) do load_obj(c, ld[1], ld[2], nil, ld[3]) end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    local named = {}
    local function port(key)
        local p = named[key]
        if not p then p = new(); named[key] = p end
        return p
    end
    -- ── the graph's facts ───────────────────────────────────────────────────────────────────────────
    local fn_at = {}
    for _, n in ipairs(store.data.nodes) do
        if (n.kind == 'function' or n.kind == 'method') and n.range then
            local m = fn_at[n.file]
            if not m then m = {}; fn_at[n.file] = m end
            m[atr.sl(n.range) .. ':' .. atr.sc(n.range)] = n.id
        end
    end
    local call_at = {}
    for _, c in ipairs(store.data.calls or {}) do
        local at = c.at
        if at then call_at[callrec.file(c) .. ':' .. atr.sl(at) .. ':' .. atr.sc(at)] = c end
    end
    local req_at = {}
    for _, e in ipairs(store.data.edges or {}) do
        if e.kind == 'import' and e.at then
            local a = e.at[1] or e.at
            if type(a) == 'table' and a.start then req_at[e.from .. ':' .. atr.sl(a) .. ':' .. atr.sc(a)] = e.to end
        end
    end
    local probes = {}
    local modports = {}
    -- ── one file: a scoped walk emitting the constraints ─────────────────────────────────────────────────
    local function walk_file(file, src)
        local okp, parser = pcall(vim.treesitter.get_string_parser, src, 'lua')
        if not okp then return end
        local tree = parser:parse()[1]:root()
        local fnmap = fn_at[file] or {}
        local function txt(n) local _, _, s, _, _, e = n:range(true); return src:sub(s + 1, e) end
        local function key_of(n) local l, c = n:start(); return file .. ':' .. l .. ':' .. c end
        local scopes = { {} }
        local function lookup(name)
            for i = #scopes, 1, -1 do local p = scopes[i][name]; if p then return p end end
            return port('g:' .. name)
        end
        local function declare(name, p) local q = p or new(); scopes[#scopes][name] = q; return q end
        local fnstack = {}
        local expr, stmt
        local function keyname(k)
            if k and k:type() == 'string' then local c = k:field('content')[1]; return c and txt(c) or '[]' end
            return '[]'
        end
        local function assign(target, v)
            local t = target:type()
            if t == 'identifier' then edge(v, lookup(txt(target)))
            elseif t == 'dot_index_expression' then storec(expr(target:field('table')[1]), txt(target:field('field')[1]), v)
            elseif t == 'bracket_index_expression' then
                local base, kn = expr(target:field('table')[1]), target:field('field')[1]
                storec(base, keyname(kn), v)
                if kn then storec(base, '{k}', expr(kn)) end
            end
        end
        local function func(n)
            local l, c = n:start()
            local id = fnmap[l .. ':' .. c] or ('ts:' .. file .. ':' .. l .. ':' .. c)
            local p = new()
            local o = newobj(id)
            addobj(p, o)
            local fp = { params = {}, ret = port('r:' .. id) }
            fnports[o] = fp
            scopes[#scopes + 1] = {}
            local i = 0
            local nm = n:field('name')[1]
            if nm and txt(nm):find(':', 1, true) then i = 1; fp.params[1] = declare('self', port('a:' .. id .. ':1')) end
            local ps = n:field('parameters')[1]
            for _, x in tsutil.inext, ps or EMPTY_NODE, -1 do
                if x:named() and x:type() == 'identifier' then
                    i = i + 1
                    fp.params[i] = declare(txt(x), port('a:' .. id .. ':' .. i))
                end
            end
            fnstack[#fnstack + 1] = fp.ret
            local body = n:field('body')[1]
            if body then for _, s in tsutil.inext, body, -1 do if s:named() then stmt(s) end end end
            fnstack[#fnstack] = nil
            scopes[#scopes] = nil
            return p
        end
        local function callv(n)
            local f = n:field('name')[1]
            local args = n:field('arguments')[1]
            local argn = {}
            for _, a in tsutil.inext, args or EMPTY_NODE, -1 do if a:named() then argn[#argn + 1] = a end end
            local c = f and call_at[key_of(f)]
            local fname = f and txt(f) or ''
            if fname == 'require' and argn[1] then
                local l, cc = argn[1]:start()
                local m = req_at[file .. ':' .. l .. ':' .. cc]
                if m then return port('mod:' .. m) end
            end
            if fname == 'setmetatable' and argn[1] then
                local tp = expr(argn[1])
                if argn[2] then proto(tp, field(expr(argn[2]), '__index')) end
                return tp
            end
            if (fname == 'pcall' or fname == 'xpcall') and argn[1] then
                local aps = {}
                for j = (fname == 'xpcall' and 3 or 2), #argn do aps[#aps + 1] = expr(argn[j]) end
                local res = new()
                callc(expr(argn[1]), aps, res)
                return res
            end
            if fname == 'table.insert' and argn[1] then
                local tp = expr(argn[1])
                for j = 2, #argn do local v = expr(argn[j]); if j == #argn then storec(tp, '[]', v) end end
                return new()
            end
            local recvp, callee
            if f and f:type() == 'method_index_expression' then
                recvp = expr(f:field('table')[1])
                callee = field(recvp, txt(f:field('method')[1]))
            end
            local aps = {}
            if recvp then aps[1] = recvp end
            for _, a in ipairs(argn) do aps[#aps + 1] = expr(a) end
            local r = c and c.refused
            if type(r) == 'table' and r.rule == 'ambiguous' and r.cands then
                local member = f:type() == 'method_index_expression' and f:field('method')[1] or f:field('field')[1]
                local base = recvp or (f:type() == 'dot_index_expression' and expr(f:field('table')[1]))
                if base and member then probes[#probes + 1] = { c = c, recv = base, member = txt(member) } end
            end
            local to = c and callrec.to(c)
            local res = new()
            if recvp then mflow(recvp, txt(f:field('method')[1]), res) end
            if to then
                for j, ap in ipairs(aps) do edge(ap, port('a:' .. to .. ':' .. j)) end
                edge(port('r:' .. to), res)
                return res
            end
            if f and f:type() ~= 'method_index_expression' then
                local owner, mm = fname:match('^(.+)%.([%w_]+)$')
                local rt = ret1(owner and (owner .. '#' .. mm) or fname)
                if rt then addobj(res, typeobj(rt)) end
            end
            if not callee and f then callee = expr(f) end
            if callee then callc(callee, aps, res) end
            return res
        end
        expr = function (n)
            local t = n:type()
            if t == 'identifier' then return lookup(txt(n)) end
            if t == 'dot_index_expression' then return field(expr(n:field('table')[1]), txt(n:field('field')[1])) end
            if t == 'bracket_index_expression' then return field(expr(n:field('table')[1]), keyname(n:field('field')[1])) end
            if t == 'parenthesized_expression' then return expr(n:named_child(0)) end
            if t == 'string' then local p = new(); addobj(p, STR); return p end
            if t == 'function_call' then return callv(n) end
            if t == 'function_definition' then return func(n) end
            if t == 'table_constructor' then
                local p = new()
                local o = newobj('tbl:' .. key_of(n))
                addobj(p, o)
                for _, fl in tsutil.inext, n, -1 do
                    if fl:type() == 'field' then
                        local k, v = fl:field('name')[1], fl:field('value')[1]
                        if v then
                            local key = (k and k:type() == 'identifier') and txt(k) or keyname(k)
                            edge(expr(v), ofp(o, key))
                            if k then local sp = new(); addobj(sp, STR); edge(sp, ofp(o, '{k}')) end
                        end
                    end
                end
                return p
            end
            if t == 'binary_expression' then
                local op
                for _, x in tsutil.inext, n, -1 do if not x:named() then op = txt(x) end end
                local a, b = expr(n:named_child(0)), expr(n:named_child(1))
                if op == 'or' or op == 'and' then local r = new(); edge(a, r); edge(b, r); return r end
                if op == '..' then local r = new(); addobj(r, STR); return r end
                return new()
            end
            for _, x in tsutil.inext, n, -1 do if x:named() then expr(x) end end
            return new()
        end
        stmt = function (n)
            local t = n:type()
            if t == 'variable_declaration' then
                local a = n:named_child(0)
                if a and a:type() == 'assignment_statement' then
                    local vl, el = a:named_child(0), a:named_child(1)
                    local vals = {}
                    for _, x in tsutil.inext, el, -1 do if x:named() then vals[#vals + 1] = expr(x) end end
                    local i = 0
                    for _, v in tsutil.inext, vl, -1 do
                        if v:named() then i = i + 1; local p = declare(txt(v)); if vals[i] then edge(vals[i], p) end end
                    end
                elseif a then
                    if a:type() == 'identifier' then declare(txt(a)) end
                    for _, v in tsutil.inext, a, -1 do if v:type() == 'identifier' then declare(txt(v)) end end
                end
            elseif t == 'assignment_statement' then
                local vl, el = n:named_child(0), n:named_child(1)
                local vals = {}
                for _, x in tsutil.inext, el, -1 do if x:named() then vals[#vals + 1] = expr(x) end end
                local i = 0
                for _, v in tsutil.inext, vl, -1 do if v:named() then i = i + 1; if vals[i] then assign(v, vals[i]) end end end
            elseif t == 'function_declaration' then
                local nm = n:field('name')[1]
                if nm and txt(n):match('^local%s') then
                    local target = declare(txt(nm))
                    edge(func(n), target)
                else
                    local fp = func(n)
                    if nm then
                        if nm:type() == 'identifier' then edge(fp, lookup(txt(nm)))
                        else
                            local o, last = nm:named_child(0), nm:named_child(nm:named_child_count() - 1)
                            if o and last then storec(expr(o), txt(last), fp) end
                        end
                    end
                end
            elseif t == 'return_statement' then
                local el = n:named_child(0)
                local first = true
                for _, x in tsutil.inext, el or EMPTY_NODE, -1 do
                    if x:named() then
                        local v = expr(x)
                        if first then
                            edge(v, fnstack[#fnstack] or port('mod:' .. file))
                            if not fnstack[#fnstack] then modports[#modports + 1] = v end
                            first = false
                        end
                    end
                end
            elseif t == 'for_statement' then
                scopes[#scopes + 1] = {}
                local cl = n:named_child(0)
                if cl and cl:type() == 'for_generic_clause' then
                    local vl, el = cl:named_child(0), cl:named_child(1)
                    local it = el and el:named_child(0)
                    local vp, kp
                    if it and it:type() == 'function_call' then
                        local fname = it:field('name')[1] and txt(it:field('name')[1])
                        local a1 = it:field('arguments')[1] and it:field('arguments')[1]:named_child(0)
                        if (fname == 'ipairs' or fname == 'pairs') and a1 then
                            local tp = expr(a1)
                            vp = field(tp, '[]')
                            if fname == 'pairs' then kp = field(tp, '{k}') end
                        else expr(it) end
                    end
                    local i = 0
                    for _, v in tsutil.inext, vl, -1 do
                        if v:named() then
                            i = i + 1
                            local p = declare(txt(v))
                            if i == 2 and vp then edge(vp, p) end
                            if i == 1 and kp then edge(kp, p) end
                        end
                    end
                elseif cl then
                    for _, x in tsutil.inext, cl, -1 do
                        if x:named() then if x:type() == 'identifier' then declare(txt(x)) else expr(x) end end
                    end
                end
                for _, x in tsutil.inext, n, -1 do if x:named() and x ~= cl then stmt(x) end end
                scopes[#scopes] = nil
            elseif t == 'block' or t == 'do_statement' then
                scopes[#scopes + 1] = {}
                for _, x in tsutil.inext, n, -1 do if x:named() then stmt(x) end end
                scopes[#scopes] = nil
            elseif t == 'function_call' then callv(n)
            else
                for _, x in tsutil.inext, n, -1 do
                    if x:named() then
                        local xt = x:type()
                        if xt == 'block' or xt:find('statement', 1, true) then stmt(x) else expr(x) end
                    end
                end
            end
        end
        for _, s in tsutil.inext, tree, -1 do if s:named() then stmt(s) end end
    end
    local files = {}
    do
        local seen = {}
        for _, n in ipairs(store.data.nodes) do
            local f = n.file
            if type(f) == 'string' and (f:match('%.lua$') or f:match('%.go$') or f:match('%.[jt]sx?$')) and not f:match('%.d%.ts$') and not seen[f]
                and not (opts.exclude and f:match(opts.exclude)) then seen[f] = true; files[#files + 1] = f end
        end
        table.sort(files)
    end
    local root = store.data.root
    -- (the solver's operations, for a language's own walker: flowtype_go)
    local S = { new = new, newobj = newobj, addobj = addobj, edge = edge, ofp = ofp, field = field, storec = storec,
        callc = callc, mflow = mflow, port = port, objproto = objproto, fnports = fnports, typeobj = typeobj, STR = STR,
        filter = filter, proto = proto, gfilter = gfilter, each = each, fields = function (o) return ofield[o] end,
        EXT = EXT, fn_at = fn_at, call_at = call_at, req_at = req_at, root = root, probes = {}, modports = modports,
        nodes = store.data.nodes }
    local gowalk, jswalk, jsfinish
    for _, f in ipairs(files) do
        local fd = type(root) == 'string' and io.open(root .. '/' .. f, 'rb')
        local src = fd and fd:read('a')
        if fd then fd:close() end
        if src then
            if f:match('%.go$') then
                gowalk = gowalk or require('cartograph.flowtype_go').walker(S, files)
                gowalk(f, src)
            elseif f:match('%.[jt]sx?$') then
                if not jswalk then jswalk, jsfinish = require('cartograph.flowtype_js').walker(S, files) end
                jswalk(f, src)
            else walk_file(f, src) end
        end
    end
    if jsfinish then jsfinish() end
    solve()
    -- (the instanceof GUARDS to a fixpoint: admit what the solved prototypes allow, solve again — sets only grow)
    for _ = 1, 20 do
        local grew = false
        for _, gf in ipairs(gfilters) do
            local gp = {}
            for g in each(gf[3]) do gp[g] = true end
            if next(gp) then
                local function chain(o, seen)
                    if gp[o] then return true end
                    if seen[o] then return false end
                    seen[o] = true
                    for c in pairs(protos[o] or {}) do if chain(c, seen) then return true end end
                    return false
                end
                for o in each(gf[1]) do
                    if not gf[4][o] and chain(o, {}) then gf[4][o] = true; addobj(gf[2], o); grew = true end
                end
            end
        end
        if not grew then break end
        solve()
    end
    -- (OPEN: an exported function's callers are not all in the tree — its parameters may hold anything)
    if open then
        for _, mp in ipairs(modports) do
            for o in each(mp) do
                for _, fp in pairs(ofield[o] or {}) do
                    for fo in each(fp) do
                        local fpp = fnports[fo]
                        if fpp then for _, pp in ipairs(fpp.params) do addobj(pp, EXT) end end
                    end
                end
            end
        end
        solve()
    end
    -- ── the verdicts ────────────────────────────────────────────────────────────────────────────────
    local verdicts = {}
    local stats = { probes = #probes, exact = 0, narrowed = 0, string = 0, typed = 0, unknown = 0, none = 0, same = 0,
        files = #files, ports = N, objects = NO }
    local function targets(o, m, out, seen)
        if seen[o] then return false end
        seen[o] = true
        local p = ofield[o] and ofield[o][m]
        if p and top[p] then return true end
        if p then for x in each(p) do out[x] = true end end
        local t = false
        for c in pairs(protos[o] or {}) do t = targets(c, m, out, seen) or t end
        return t
    end
    for _, pr in ipairs(probes) do
        local kind, v
        if top[pr.recv] or has(pr.recv, EXT) then kind = 'unknown'
        elseif pts[pr.recv] == nil then kind = 'none'
        else
            local out, sat, tyname, other = {}, false, nil, false
            for o in each(pr.recv) do
                local tn = TNAME[o]
                if tn then
                    if tn == 'string' or PSIGS[tn .. '#' .. pr.member] then tyname = tn end
                else
                    other = true
                    if targets(o, pr.member, out, {}) then sat = true end
                end
            end
            local fns, unknown = {}, sat
            for x in pairs(out) do
                if x == EXT then unknown = true
                elseif fnports[x] then
                    local id = obinfo[x]
                    if tostring(id):find('^ts:') then unknown = true else fns[#fns + 1] = id end
                end
            end
            table.sort(fns)
            if unknown then kind = 'unknown'
            elseif tyname and not other then kind = tyname == 'string' and 'string' or 'typed'; v = { kind = kind, type = tyname }
            elseif tyname or #fns == 0 then kind = 'none'
            else
                local cands = {}
                for _, id in ipairs(pr.c.refused.cands) do cands[id] = true end
                -- (a function the join never listed is still an answer: the join is a NAME guess — at.lua's C.sl)
                if #fns == 1 then kind = 'exact'
                else
                    local all = true
                    for _, id in ipairs(fns) do if not cands[id] then all = false end end
                    kind = (all and #fns < #pr.c.refused.cands) and 'narrowed' or 'same'
                end
                if kind ~= 'same' then v = { kind = kind, targets = fns } end
            end
        end
        stats[kind] = (stats[kind] or 0) + 1
        if v then verdicts[pr.c] = v end
    end
    -- (PROBES a language walker records itself — every Go method call: { file, line, col, member, recv } -> targets)
    local probe_out = {}
    for _, pr in ipairs(S.probes) do
        local kind, fns, unknown = nil, {}, top[pr.recv] or has(pr.recv, EXT)
        if not unknown then
            local out = {}
            -- (a GUARD — `x instanceof C` around the call — keeps only the objects whose prototype chain holds one of
            -- C's prototypes: a runtime type check, decided after the solve, when the sets are whole)
            local keep
            if pr.guard then
                keep = {}
                local gp = {}
                for g in each(pr.guard) do gp[g] = true end
                local function chain(o, seen)
                    if gp[o] then return true end
                    if seen[o] then return false end
                    seen[o] = true
                    for c in pairs(protos[o] or {}) do if chain(c, seen) then return true end end
                    return false
                end
                for o in each(pr.recv) do if chain(o, {}) then keep[o] = true end end
            end
            for o in each(pr.recv) do
                if not keep or keep[o] then if targets(o, pr.member, out, {}) then unknown = true end end
            end
            for x in pairs(out) do
                if x == EXT then unknown = true
                elseif fnports[x] then
                    -- (a function the graph has no node for is no answer it can give: unknown, as for Lua's verdicts)
                    if tostring(obinfo[x]):find('^ts:') then unknown = true else fns[#fns + 1] = obinfo[x] end
                end
            end
            table.sort(fns)
        end
        if unknown then kind = 'unknown' elseif #fns == 0 then kind = 'none' elseif #fns == 1 then kind = 'exact' else kind = 'set' end
        probe_out[#probe_out + 1] = { file = pr.file, line = pr.line, col = pr.col, member = pr.member, kind = kind, targets = fns,
            guarded = pr.guard ~= nil }
    end
    stats.ms = (vim.uv.hrtime() - t0) / 1e6
    return { verdict = function (c) return verdicts[c] end, stats = stats, probes = probe_out }
end

--- the analysis over `store`'s graph, cached per graph generation (and per `open`)
function M.of(store, opts)
    local key = ((opts and opts.open == false) and 'closed' or 'open') .. ((opts and opts.spread) and '+spread' or '')
        .. ((opts and opts.exclude) and ('-' .. opts.exclude) or '')
    local c = store._flowtype
    -- (the generation AND the graph itself: a fresh ingest may restart the generation count)
    if c and c.gen == store.generation and c.data == store.data and c[key] then return c[key] end
    if not c or c.gen ~= store.generation or c.data ~= store.data then
        c = { gen = store.generation, data = store.data }; store._flowtype = c
    end
    c[key] = build(store, opts)
    return c[key]
end

return M
