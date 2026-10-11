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
-- ★ DENSE SETS (CART-1643): a set past M.BIG objects becomes a BITSET (LuaJIT FFI uint32 words), and so does a delta,
-- so a big delta moves along an edge as a word loop (new = delta & ~target) instead of one hash probe per object —
-- the complete solve of arktype offered objects 14.7 BILLION times to add 52 M. M.BIG > M.CAP: under the default cap
-- no set ever becomes dense, and a solve that saturates nothing has one answer whatever its representation.
M.BIG = 128
local ffi = require 'ffi'
local bit = require 'bit'
local band, bor, bnot, lshift, rshift = bit.band, bit.bor, bit.bnot, bit.lshift, bit.rshift
local U32 = ffi.typeof('uint32_t[?]')
local POP8 = {}
for i = 0, 255 do local c, x = 0, i; while x > 0 do c = c + band(x, 1); x = rshift(x, 1) end; POP8[i] = c end
local function pop32(x)
    return POP8[band(x, 255)] + POP8[band(rshift(x, 8), 255)] + POP8[band(rshift(x, 16), 255)] + POP8[band(rshift(x, 24), 255)]
end
-- (lo / hi: the words that may be non-zero — a delta is usually a few words of a wide set)
local function bs_new(nw) return { bs = U32(nw), nw = nw, lo = nw, hi = -1 } end
local function bs_grow(b, need)
    if need <= b.nw then return end
    local nw = math.max(need, b.nw * 2)
    local nb = U32(nw)
    ffi.copy(nb, b.bs, b.nw * 4)
    b.bs, b.nw = nb, nw
end
local function bs_test(b, o)
    local w = rshift(o, 5)
    if w >= b.nw then return false end
    return band(b.bs[w], lshift(1, band(o, 31))) ~= 0
end
local function bs_set(b, o) -- -> true when o was not there
    local w = rshift(o, 5)
    if w >= b.nw then bs_grow(b, w + 1) end
    local m = lshift(1, band(o, 31))
    local v = b.bs[w]
    if band(v, m) ~= 0 then return false end
    b.bs[w] = bor(v, m)
    if w < b.lo then b.lo = w end
    if w > b.hi then b.hi = w end
    return true
end
local function bs_iter(b) -- the objects, ascending
    local w, word, base = b.lo - 1, 0, 0
    local hi = b.hi
    return function ()
        while word == 0 do
            w = w + 1
            if w > hi then return nil end
            word = b.bs[w]; base = w * 32
        end
        local low = band(word, -word)
        local i, t = 0, low
        while band(t, 1) == 0 do t = rshift(t, 1); i = i + 1 end
        word = band(word, bnot(low))
        return base + i
    end
end

-- (a STRING-keyed table walked in ONE order: LuaJIT seeds its string hash per process, so `pairs` over field names
-- walks differently in every run — and while a saturated port drops out, the walk order decides which objects reached
-- downstream before it saturated: arktype read 456 / 413 / 422 exact answers in three runs of one input)
local function sorted(t)
    local ks = {}
    for k in pairs(t) do ks[#ks + 1] = k end
    -- (string keys compare as themselves — the same order tostring gave, without a tostring per comparison: it was
    -- 9% of a near-complete solve)
    if #ks > 1 then
        table.sort(ks, function (a, b)
            if type(a) == 'string' and type(b) == 'string' then return a < b end
            return tostring(a) < tostring(b)
        end)
    end
    local i = 0
    return function ()
        i = i + 1
        local k = ks[i]
        if k ~= nil then return k, t[k] end
    end
end
M.sorted = sorted

local function build(store, opts)
    opts = opts or {}
    local open = opts.open ~= false
    local t0 = vim.uv.hrtime()
    -- ── the solver: ports are ints, objects are ints ────────────────────────────────────────────────
    local N, NO = 0, 0
    local pts, cnt, top, delta = {}, {}, {}, {}
    local succ, loads, stores, calls, mflows, protos_at = {}, {}, {}, {}, {}, {}
    local ofield, protos, fnports, obinfo = {}, {}, {}, {}
    local TYPEOBJ, TNAME = {}, {} -- (type objects: below, with typeobj)
    local typeobj
    -- ★ A FIELD'S READERS ARE IMPLICIT (CART-1643, to make the solver SMALLER): a load of x.f READS field f of every
    -- object at x, and materializing that as an edge per (object, load) was 96% of all edges — 10.96 M of 11.38 M on
    -- lua/cartograph, 339 MB. Instead each object keeps the loads that read it, rd[o] = { [f] = { [dst] = strict } }
    -- (a non-strict named load also under NS: it reads `[]` too), and a field port's new objects go to its readers.
    local rd, fowner, fname = {}, {}, {}
    -- (an object's field names in ONE order, cached until it gains a field: a dynamic load walks them per object)
    local okeys_cache = {}
    local function okeys(o)
        local l = okeys_cache[o]
        if l then return l end
        l = {}
        for f in pairs(ofield[o] or {}) do l[#l + 1] = f end
        table.sort(l)
        okeys_cache[o] = l
        return l
    end
    local NS = '\0ns'
    local wl, inwl, head, tail = {}, {}, 1, 0
    local walking, NW, NOW = true, 0, 0
    local function new() N = N + 1; return N end
    local function newobj(info) NO = NO + 1; obinfo[NO] = info; return NO end
    -- (an object named stably: one the walk made by its number, one the solve made — a type object — by its info)
    local function okey(o) return o <= NOW and o or tostring(obinfo[o]) end
    -- ★ THE SCHEDULE IS A STABLE ORDER, not a stack: a port saturating mid-solve has handed downstream whatever it
    -- held when it was processed, so the answer depends on the order ports are processed in. The worklist is a heap
    -- over an order an unrelated edit does not change: ports the walk made by number (files are walked sorted, so
    -- adding a file shifts numbers but keeps every other port's relative order), then the solve's field ports by their
    -- object (a walk object by number, a solve object by its info) and field name. Two ports no flow connects are
    -- processed in the same relative order whatever else the tree holds. (`opts.order` = 'asc' / 'lifo' / 'fifo':
    -- other orders, an INSTRUMENT — how much an answer depends on the schedule)
    local order = opts.order
    local pinfo = {}
    local LATE = { math.huge, '' } -- (a port made after the walk other than a field port: last, by number)
    local less
    less = function (a, b)
        local wa, wb = walking or a <= NW, walking or b <= NW
        if wa and wb then return a < b end
        if wa then return true end
        if wb then return false end
        local x, y = pinfo[a] or LATE, pinfo[b] or LATE
        if x[1] ~= y[1] then
            if type(x[1]) == type(y[1]) then return x[1] < y[1] end
            return type(x[1]) == 'number'
        end
        if x[2] ~= y[2] then return x[2] < y[2] end
        return a < b
    end
    -- (DESCENDING: the latest port first — what a stack did, depth-first, so a value travels before a helper fills;
    -- ascending saturated more receivers: lroot string verdicts 673 vs 567, arktype class exact-right 330 vs 326)
    if order ~= 'asc' then
        local asc = less
        less = function (a, b) return asc(b, a) end
    end
    if order == 'asc' or order == 'desc' then order = nil end
    local function push(p)
        if inwl[p] then return end
        inwl[p] = true
        tail = tail + 1; wl[tail] = p
        if order then return end
        local i = tail
        while i > 1 do
            local j = math.floor(i / 2)
            if not less(wl[i], wl[j]) then break end
            wl[i], wl[j] = wl[j], wl[i]; i = j
        end
    end
    local function pop()
        local p
        if order == 'fifo' then p = wl[head]; wl[head] = nil; head = head + 1; return p end
        if order == 'lifo' then p = wl[tail]; wl[tail] = nil; tail = tail - 1; return p end
        p = wl[1]
        wl[1] = wl[tail]; wl[tail] = nil; tail = tail - 1
        local i = 1
        while true do
            local l, r, m = 2 * i, 2 * i + 1, i
            if l <= tail and less(wl[l], wl[m]) then m = l end
            if r <= tail and less(wl[r], wl[m]) then m = r end
            if m == i then break end
            wl[i], wl[m] = wl[m], wl[i]; i = m
        end
        return p
    end
    -- (SPREAD: a saturated port makes everything it flows into unknown — sound, and measured to blank 1252 of 3674
    -- receivers on lua/cartograph: a registration helper `cmd(name, fn)` takes every handler at one parameter, and
    -- context-insensitive flow carries that set everywhere the helper's value goes. Off by default: a saturated port
    -- DROPS OUT — its objects are not propagated — and a verdict is a claim over the flows kept, which every sampled
    -- verdict held. Consumers hedge it (~). Context sensitivity for such helpers is the real fix.)
    local spread = opts.spread == true
    -- (ESCAPED: an object that reached a saturated port — from there it may go anywhere the solve no longer follows:
    -- written through, called through. See PARTIAL below)
    local escaped = {}
    local function settop(p)
        if top[p] then return end
        local s = pts[p]
        if type(s) == 'number' then escaped[s] = true
        elseif s and s.bs then for o in bs_iter(s) do escaped[o] = true end
        elseif s then for o in pairs(s) do escaped[o] = true end end
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
        if s.bs then return bs_iter(s) end
        return next, s, nil
    end
    local function has(p, o)
        local s = pts[p]
        if type(s) == 'number' then return s == o end
        if s and s.bs then return bs_test(s, o) end
        return s ~= nil and s[o] == true
    end
    local BIG = M.BIG
    local function tobits(p) -- p's set as a bitset
        local s = pts[p]
        if type(s) == 'table' and s.bs then return s end
        local b = bs_new(rshift(NO, 5) + 2)
        if type(s) == 'number' then bs_set(b, s) elseif s then for o in pairs(s) do bs_set(b, o) end end
        pts[p] = b
        return b
    end
    local function dbits(p) -- p's pending delta as a bitset
        local d = delta[p]
        if type(d) == 'table' and d.bs then return d end
        local b = bs_new(rshift(NO, 5) + 2)
        if d then for _, o in ipairs(d) do bs_set(b, o) end end
        delta[p] = b
        return b
    end
    local function addobj(p, o)
        if top[p] then escaped[o] = true; return end
        local s = pts[p]
        if s == nil then pts[p] = o; cnt[p] = 1
        elseif type(s) == 'number' then
            if s == o then return end
            pts[p] = { [s] = true, [o] = true }; cnt[p] = 2
        elseif s.bs then
            if not bs_set(s, o) then return end
            cnt[p] = cnt[p] + 1
        else
            if s[o] then return end
            s[o] = true
            cnt[p] = cnt[p] + 1
            if cnt[p] > BIG then tobits(p) end
        end
        if cnt[p] > M.CAP then return settop(p) end
        local d = delta[p]
        if type(d) == 'table' and d.bs then bs_set(d, o)
        else
            if not d then d = {}; delta[p] = d end
            d[#d + 1] = o
            if #d > BIG then dbits(p) end
        end
        push(p)
    end
    -- the bitset d into q: word by word, what was new becomes q's delta
    local function addbits(q, d)
        if top[q] then for o in bs_iter(d) do escaped[o] = true end return end
        local t = tobits(q)
        if t.nw < d.nw then bs_grow(t, d.nw) end
        local tb, db = t.bs, d.bs
        local dd, added = nil, 0
        for w = d.lo, d.hi do
            local x = db[w]
            if x ~= 0 then
                local tv = tb[w]
                local nw = band(x, bnot(tv))
                if nw ~= 0 then
                    tb[w] = bor(tv, nw)
                    if w < t.lo then t.lo = w end
                    if w > t.hi then t.hi = w end
                    if not dd then dd = dbits(q); if dd.nw < d.nw then bs_grow(dd, d.nw) end end
                    dd.bs[w] = bor(dd.bs[w], nw)
                    if w < dd.lo then dd.lo = w end
                    if w > dd.hi then dd.hi = w end
                    added = added + pop32(nw)
                end
            end
        end
        if added > 0 then
            cnt[q] = (cnt[q] or 0) + added
            if cnt[q] > M.CAP then return settop(q) end
            push(q)
        end
    end
    local function edge(a, b) -- pts(b) ⊇ pts(a)
        if a == b then return end
        local s = succ[a]
        if not s then s = {}; succ[a] = s end
        if s[b] then return end
        s[b] = true
        if top[a] then if spread then settop(b) end; return end
        local sa = pts[a]
        if type(sa) == 'table' and sa.bs then addbits(b, sa) else for o in each(a) do addobj(b, o) end end
    end
    local function ofp(o, f)
        local m = ofield[o]
        if not m then m = {}; ofield[o] = m end
        local p = m[f]
        if not p then
            p = new(); m[f] = p
            okeys_cache[o] = nil
            fowner[p], fname[p] = o, f
            if not walking then pinfo[p] = { okey(o), f } end
        end
        return p
    end
    -- every load reading field g of o: the loads of g; a non-strict `[]` load reads every field but `{k}`; `[]` is read
    -- by every non-strict named load as well (a Lua `t[k] = v` may write any name)
    local function readers(o, g, fn)
        local r = rd[o]
        if not r then return end
        local l = r[g]
        if l then for dst in pairs(l) do fn(dst) end end
        if g ~= '{k}' and g ~= '[]' then
            local dyn = r['[]']
            if dyn then for dst, strict in pairs(dyn) do if not strict then fn(dst) end end end
        end
        if g == '[]' then local ns = r[NS]; if ns then for dst in pairs(ns) do fn(dst) end end end
    end
    -- (STRICT: a language whose records have no dynamic keys — Go — reads exactly the field: a named load never reads
    -- `[]`, a `[]` load never reads every field. Lua's `t[k] = v` may write any field, so there both widen)
    -- ★ A CONTAINER TYPE'S ELEMENTS (CART-1643): the environment profile types what comes from OUTSIDE the tree —
    -- `vim.split` -> string[], `TSNode:field()` -> TSNode[], `LanguageTree:parse()` -> table<integer, TSTree> — and a
    -- value read out of one (`lines[i]`, `node:field('name')[1]`) is its element type. On lua/cartograph most
    -- ambiguous calls with nothing at the receiver held values from outside: tree-sitter nodes and strings.
    local function elemtype(tn)
        if tn:match('^%(?fun%(') then return nil end -- (`fun(): T[]` returns a list; it is none)
        local e = tn:match('^(.-)%[%]$')
        if e then return e end
        local v = tn:match('^table<[^,]+,%s*(.-)>$')
        return v
    end
    local function load_obj(o, f, dst, seen, strict)
        seen = seen or {}
        if seen[o] then return end
        seen[o] = true
        local tn = TNAME[o]
        if tn then
            local e = (f == '#' or f == '[]' or not strict) and elemtype(tn)
            if e and e ~= '' then addobj(dst, typeobj((e:gsub('%?$', '')))) end
            return
        end
        local r = rd[o]
        if not r then r = {}; rd[o] = r end
        local l = r[f]
        if not l then l = {}; r[f] = l end
        if l[dst] == nil then
            l[dst] = strict and true or false
            if not strict and f ~= '[]' then local ns = r[NS]; if not ns then ns = {}; r[NS] = ns end; ns[dst] = true end
            -- (what the fields hold already; what they gain later reaches dst as their readers)
            local function pull(q)
                if top[q] then if spread then settop(dst) end return end
                local sq = pts[q]
                if type(sq) == 'table' and sq.bs then addbits(dst, sq) else for x in each(q) do addobj(dst, x) end end
            end
            if strict then pull(ofp(o, f))
            elseif f == '[]' then local m = ofield[o]; for _, fk in ipairs(okeys(o)) do if fk ~= '{k}' then pull(m[fk]) end end
            else pull(ofp(o, f)); pull(ofp(o, '[]')) end
        end
        for c in pairs(protos[o] or {}) do load_obj(c, f, dst, seen, strict) end
    end
    -- the loads recorded on o, replayed on c (a prototype o gained) — field names in ONE order
    local function replay_loads(o, c)
        local r = rd[o]
        if not r then return end
        for f, l in sorted(r) do
            if f ~= NS then for dst, strict in pairs(l) do load_obj(c, f, dst, nil, strict) end end
        end
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
    -- (`setmetatable(t, { __index = idx })`: every object at t has every object at idx as a prototype — linked when
    -- EITHER side gains one; linking only on t's arrivals lost an idx object that came later, an ORDER-dependent miss)
    local protos_rev = {}
    local function protolink(o, c)
        local pr = protos[o]
        if not pr then pr = {}; protos[o] = pr end
        if pr[c] then return end
        pr[c] = true
        replay_loads(o, c)
    end
    local function proto(t, idx)
        local l = protos_at[t]
        if not l then l = {}; protos_at[t] = l end
        l[#l + 1] = idx
        local r = protos_rev[idx]
        if not r then r = {}; protos_rev[idx] = r end
        r[#r + 1] = t
    end
    local function objproto(o, c) -- o's loads also read c's fields (an EMBEDDED type's methods: Go promotion)
        local pr = protos[o]
        if not pr then pr = {}; protos[o] = pr end
        if pr[c] then return end
        pr[c] = true
        replay_loads(o, c)
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
    local funrets
    local function bindcall(o, args, res)
        local fp = fnports[o]
        if not fp then
            -- (a TYPED function — the profile's `fun(): TSNode, string`, what TSNode:iter_children returns — returns its
            -- declared types)
            local rl = TNAME[o] and funrets(TNAME[o])
            if rl then
                if type(res) == 'table' then
                    for i, r in ipairs(res) do if rl[i] then addobj(r, typeobj(rl[i])) end end
                elseif rl[1] then addobj(res, typeobj(rl[1])) end
            end
            return
        end
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
    typeobj = function (t)
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
    -- (a declared type that is ONE type: `X?` / `X|nil` is X, a real union is none)
    local function onetype(ty)
        if type(ty) ~= 'string' then return nil end
        if ty:match('^%(?fun%(') then return (ty:gsub('^%s+', ''):gsub('%s+$', '')) end
        local one
        for part in (ty:gsub('%s', '') .. '|'):gmatch('([^|]*)|') do
            part = part:gsub('%?$', ''):gsub('%*$', '')
            if part ~= '' and part ~= 'nil' then
                if one and one ~= part then return nil end
                one = part
            end
        end
        return one
    end
    local RET = {}
    local function retk(key, k) -- the k-th declared return of a profile signature
        local ck = k == 1 and key or (key .. '\0' .. k)
        local r = RET[ck]
        if r ~= nil then return r or nil end
        local sg = PSIGS[key]
        local rk = type(sg) == 'table' and sg.returns and sg.returns[k]
        local one = onetype(rk and rk.type)
        RET[ck] = one or false
        return one
    end
    -- (a function TYPE's returns: `fun(a: integer): TSNode, string` -> { 'TSNode', 'string' }; wrapped in parentheses
    -- too. Anything else is no function type: nil)
    local FUNRETS = {}
    funrets = function (tn)
        local r = FUNRETS[tn]
        if r ~= nil then return r or nil end
        local s = tn:match('^%((.*)%)$') or tn
        local params = s:match('^fun(%b())')
        if not params then FUNRETS[tn] = false; return nil end
        local list = s:sub(4 + #params):match('^%s*:%s*(.-)%s*$')
        r = {}
        if list and list ~= '' then
            local depth, from = 0, 1
            local function put(part) r[#r + 1] = onetype((part:gsub('^%s*[%a_][%w_]*%s*:%s+', ''))) or false end
            for i = 1, #list do
                local ch = list:sub(i, i)
                if ch:match('[%(<{%[]') then depth = depth + 1
                elseif ch:match('[%)>}%]]') then depth = depth - 1
                elseif ch == ',' and depth == 0 then put(list:sub(from, i - 1)); from = i + 1 end
            end
            put(list:sub(from))
        end
        FUNRETS[tn] = r
        return r
    end
    local function mflow(recv, m, res, k) -- a method on a TYPED object returns its signature's type (its k-th)
        k = k or 1
        local l = mflows[recv]
        if not l then l = {}; mflows[recv] = l end
        l[#l + 1] = { m, res, k }
        for o in each(recv) do
            local tn = TNAME[o]
            local rt = tn and retk(tn .. '#' .. m, k)
            if rt then addobj(res, typeobj(rt)) end
        end
    end
    local function solve()
        if walking then walking = false; NW, NOW = N, NO end
        while head <= tail do
            local p = pop()
            if order == 'fifo' and head > tail then head, tail = 1, 0 end
            inwl[p] = nil
            if top[p] then
                for q in pairs(succ[p] or {}) do settop(q) end
                if spread and fowner[p] then readers(fowner[p], fname[p], settop) end
                for _, ld in ipairs(loads[p] or {}) do settop(ld[2]) end
                for _, cl in ipairs(calls[p] or {}) do if type(cl[2]) ~= 'table' then settop(cl[2]) end end
            else
                local d = delta[p]
                delta[p] = nil
                if d and d.bs then
                    -- (a DENSE delta: the copy edges and the field's readers in bulk; the rest per object)
                    local db = d
                    for q in pairs(succ[p] or {}) do addbits(q, db) end
                    if fowner[p] then readers(fowner[p], fname[p], function (q) addbits(q, db) end) end
                    d = {}
                    for o in bs_iter(db) do d[#d + 1] = o end
                elseif d then
                    for q in pairs(succ[p] or {}) do for _, o in ipairs(d) do addobj(q, o) end end
                    if fowner[p] then readers(fowner[p], fname[p], function (q) for _, o in ipairs(d) do addobj(q, o) end end) end
                end
                if d then
                    for _, ld in ipairs(loads[p] or {}) do for _, o in ipairs(d) do load_obj(o, ld[1], ld[2], nil, ld[3]) end end
                    for _, st in ipairs(stores[p] or {}) do for _, o in ipairs(d) do edge(st[2], ofp(o, st[1])) end end
                    for _, cl in ipairs(calls[p] or {}) do for _, o in ipairs(d) do bindcall(o, cl[1], cl[2]) end end
                    for _, fl in ipairs(filters[p] or {}) do
                        for _, o in ipairs(d) do if fl[2](o) then addobj(fl[1], o) end end
                    end
                    for _, mf in ipairs(mflows[p] or {}) do
                        for _, o in ipairs(d) do
                            local tn = TNAME[o]
                            local rt = tn and retk(tn .. '#' .. mf[1], mf[3] or 1)
                            if rt then addobj(mf[2], typeobj(rt)) end
                        end
                    end
                    for _, idx in ipairs(protos_at[p] or {}) do
                        for _, o in ipairs(d) do for c in each(idx) do protolink(o, c) end end
                    end
                    for _, t in ipairs(protos_rev[p] or {}) do
                        for o in each(t) do for _, c in ipairs(d) do protolink(o, c) end end
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
    -- (keyed by position AND callee name: a chained call starts where its inner call does — `load().run()` and
    -- `load()`, `parser:parse()[1]:root()` and `parser:parse()` — and by position alone the inner record overwrote
    -- the outer, so the outer, ambiguous call was never probed)
    local call_at = {}
    for _, c in ipairs(store.data.calls or {}) do
        local at = c.at
        if at then
            local k = callrec.file(c) .. ':' .. atr.sl(at) .. ':' .. atr.sc(at)
            call_at[k .. '#' .. tostring(callrec.callee(c))] = c
            -- (by position alone only where ONE call starts there)
            if call_at[k] == nil then call_at[k] = c elseif call_at[k] ~= c then call_at[k] = false end
        end
    end
    local req_at = {}
    for _, e in ipairs(store.data.edges or {}) do
        if e.kind == 'import' and e.at then
            -- (a range is a table only until ingest FOLDS it into an index — after any ingest every one is a number:
            -- a table-only guard here left this map empty, and no `require` ever reached its module)
            local a = type(e.at) == 'table' and (e.at[1] or e.at) or e.at
            if type(a) == 'number' or (type(a) == 'table' and a.start) then
                req_at[e.from .. ':' .. atr.sl(a) .. ':' .. atr.sc(a)] = e.to
            end
        end
    end
    local probes = {}
    local modports = {}
    -- (a module NAME -> its file by Lua's path convention, lua/a/b.lua or lua/a/b/init.lua: the fallback for a require
    -- the graph has no import edge for — `pcall(require, 'cartograph.algebra.core')` passes require as a VALUE, and
    -- that one call is where cartograph.algebra's whole API comes from. Filled before the walk)
    local modfile = {}
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
        local MULTI = 4 -- (the values a `return f()` forwards)
        local expr, stmt
        -- ★ THE ARRAY PART `#` (CART-1643): a key that is a NUMBER — a literal, `-x` / `#x`, arithmetic, a numeric-for or
        -- ipairs index — is no field NAME, so what is stored there (a list built by `t[#t + 1] = x`, table.insert, a
        -- positional constructor field) goes to `#`, which a named load `t.name` does not read; `[]` keeps the keys
        -- we cannot type, which every load reads. On lua/cartograph `[]` was the commonest saturated hub (366): every
        -- list built into a table poured into every field read of it. (An arithmetic metamethod that returns a string
        -- would break the rule; none is assumed)
        local numeric = {} -- ports of the numeric-for / ipairs index variables
        local ARITH = { ['+'] = true, ['-'] = true, ['*'] = true, ['/'] = true, ['%'] = true, ['//'] = true, ['^'] = true }
        local function isnum(k)
            local kt = k:type()
            if kt == 'number' then return true end
            if kt == 'parenthesized_expression' then local x = k:named_child(0); return x ~= nil and isnum(x) end
            if kt == 'unary_expression' then local op = txt(k):match('^%s*([#%-])'); return op ~= nil end
            if kt == 'binary_expression' then
                for _, x in tsutil.inext, k, -1 do if not x:named() then return ARITH[txt(x)] == true end end
            end
            if kt == 'identifier' then
                for i = #scopes, 1, -1 do local p = scopes[i][txt(k)]; if p then return numeric[p] == true end end
            end
            return false
        end
        local function keyname(k)
            if not k then return '#' end -- (a positional constructor field)
            if k:type() == 'string' then local c = k:field('content')[1]; return c and txt(c) or '[]' end
            if isnum(k) then return '#' end
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
            local fp = { params = {}, ret = port('r:' .. id), id = id }
            fp.rets = { fp.ret }
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
            fnstack[#fnstack + 1] = fp
            local body = n:field('body')[1]
            if body then for _, s in tsutil.inext, body, -1 do if s:named() then stmt(s) end end end
            fnstack[#fnstack] = nil
            scopes[#scopes] = nil
            return p
        end
        local function callv(n, want)
            if want and want < 2 then want = nil end
            local f = n:field('name')[1]
            local args = n:field('arguments')[1]
            local argn = {}
            for _, a in tsutil.inext, args or EMPTY_NODE, -1 do if a:named() then argn[#argn + 1] = a end end
            local cname = f and ((f:type() == 'method_index_expression' and f:field('method')[1])
                or (f:type() == 'dot_index_expression' and f:field('field')[1]) or (f:type() == 'identifier' and f))
            local c = f and (call_at[key_of(f) .. '#' .. (cname and txt(cname) or '')] or call_at[key_of(f)] or nil)
            local fname = f and txt(f) or ''
            local function modport(a)
                local s = a and a:type() == 'string' and a:field('content')[1]
                local mf = s and modfile[txt(s)]
                return mf and port('mod:' .. mf)
            end
            if fname == 'require' and argn[1] then
                local l, cc = argn[1]:start()
                local m = req_at[file .. ':' .. l .. ':' .. cc]
                if m then return port('mod:' .. m) end
                local mp = modport(argn[1])
                if mp then return mp end
            end
            if fname == 'pcall' and argn[1] and argn[1]:type() == 'identifier' and txt(argn[1]) == 'require' then
                local mp = modport(argn[2])
                if mp then
                    if not want then return mp end
                    local out = { new(), mp }
                    for k = 3, want do out[k] = new() end
                    return out
                end
            end
            if fname == 'setmetatable' and argn[1] then
                local tp = expr(argn[1])
                if argn[2] then proto(tp, field(expr(argn[2]), '__index')) end
                return tp
            end
            if (fname == 'pcall' or fname == 'xpcall') and argn[1] then
                local aps = {}
                for j = (fname == 'xpcall' and 3 or 2), #argn do aps[#aps + 1] = expr(argn[j]) end
                -- (`local ok, v = pcall(f, …)`: v is f's FIRST value — the status comes before them)
                if want then
                    local fl, out = {}, { new() }
                    for k = 1, want - 1 do fl[k] = new(); out[k + 1] = fl[k] end
                    callc(expr(argn[1]), aps, fl)
                    return out
                end
                local res = new()
                callc(expr(argn[1]), aps, res)
                return res
            end
            if fname == 'table.insert' and argn[1] then
                local tp = expr(argn[1])
                for j = 2, #argn do local v = expr(argn[j]); if j == #argn then storec(tp, '#', v) end end
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
            -- (MULTIPLE VALUES: `want` > 1 asks for that many results — `local a, b = f()`, `return f()`, a generic
            -- for's iterator triple — the k-th result port gets the callee's k-th return)
            local res = new()
            local resl = { res }
            for k = 2, want or 1 do resl[k] = new() end
            if recvp then for k, r in ipairs(resl) do mflow(recvp, txt(f:field('method')[1]), r, k) end end
            if to then
                for j, ap in ipairs(aps) do edge(ap, port('a:' .. to .. ':' .. j)) end
                for k, r in ipairs(resl) do edge(port('r:' .. to .. (k > 1 and (':' .. k) or '')), r) end
                return want and resl or res
            end
            if f and f:type() ~= 'method_index_expression' then
                local owner, mm = fname:match('^(.+)%.([%w_]+)$')
                for k, r in ipairs(resl) do
                    local rt = retk(owner and (owner .. '#' .. mm) or fname, k)
                    if rt then addobj(r, typeobj(rt)) end
                end
            end
            if not callee and f then callee = expr(f) end
            if callee then callc(callee, aps, want and resl or res) end
            return want and resl or res
        end
        -- an expression LIST's values: a call LAST in it supplies all the values still wanted (Lua truncates a call
        -- anywhere else to one)
        local function exprs(el, want)
            local xs = {}
            for _, x in tsutil.inext, el or EMPTY_NODE, -1 do if x:named() then xs[#xs + 1] = x end end
            local vals = {}
            for i, x in ipairs(xs) do
                if i == #xs and want > #xs and x:type() == 'function_call' then
                    local l = callv(x, want - #xs + 1)
                    if type(l) == 'table' then for _, r in ipairs(l) do vals[#vals + 1] = r end else vals[#vals + 1] = l end
                else vals[#vals + 1] = expr(x) end
            end
            return vals
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
                    local vals = exprs(el, vl:named_child_count())
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
                local vals = exprs(el, vl:named_child_count())
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
                local fp = fnstack[#fnstack]
                -- (each value to its position: `return i, c` — tsutil.inext's — the second is the node. A call last
                -- forwards its values: up to MULTI of them)
                local vals = exprs(el, fp and MULTI or 1)
                for i, v in ipairs(vals) do
                    if fp then
                        local r = fp.rets[i]
                        if not r then r = port('r:' .. fp.id .. ':' .. i); fp.rets[i] = r end
                        edge(v, r)
                    elseif i == 1 then
                        edge(v, port('mod:' .. file)); modports[#modports + 1] = v
                    end
                end
            elseif t == 'for_statement' then
                scopes[#scopes + 1] = {}
                local cl = n:named_child(0)
                if cl and cl:type() == 'for_generic_clause' then
                    local vl, el = cl:named_child(0), cl:named_child(1)
                    local it = el and el:named_child_count() == 1 and el:named_child(0)
                    local vp, kp, trip
                    local fname_ipairs = false
                    local fname = it and it:type() == 'function_call' and it:field('name')[1] and txt(it:field('name')[1])
                    local a1 = fname and it:field('arguments')[1] and it:field('arguments')[1]:named_child(0)
                    if (fname == 'ipairs' or fname == 'pairs') and a1 then
                        fname_ipairs = fname == 'ipairs'
                        local tp = expr(a1)
                        -- (ipairs walks the array part: `#` — a load of it also reads `[]`, the untyped keys)
                        vp = field(tp, fname == 'ipairs' and '#' or '[]')
                        if fname == 'pairs' then kp = field(tp, '{k}') end
                    else
                        -- ★ ANY OTHER ITERATOR IS A CALL (CART-1643): `for a, b in f, s, c` calls f(s, c) — then f(s, a) —
                        -- and a, b are its values; `for x in n:iter_children()` / `s:gmatch(p)` first evaluate the
                        -- triple. tsutil.inext, a TSNode iterator, was 106 of lua/cartograph's empty receivers
                        trip = exprs(el, 3)
                    end
                    local i, V = 0, {}
                    for _, v in tsutil.inext, vl, -1 do
                        if v:named() then
                            i = i + 1
                            local p = declare(txt(v))
                            V[i] = p
                            if i == 1 and fname_ipairs then numeric[p] = true end
                            if i == 2 and vp then edge(vp, p) end
                            if i == 1 and kp then edge(kp, p) end
                        end
                    end
                    if trip and trip[1] then
                        local ctl = new()
                        if trip[3] then edge(trip[3], ctl) end
                        if V[1] then edge(V[1], ctl) end
                        callc(trip[1], { trip[2] or new(), ctl }, V)
                    end
                elseif cl then
                    for _, x in tsutil.inext, cl, -1 do
                        if x:named() then
                            if x:type() == 'identifier' then
                                local p = declare(txt(x))
                                if cl:type() == 'for_numeric_clause' then numeric[p] = true end
                            else expr(x) end
                        end
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
        local dup = {}
        for _, f in ipairs(files) do
            local rel = f:match('^lua/(.+)%.lua$') or f:match('/lua/(.+)%.lua$')
            if rel then
                local name = rel:gsub('/init$', ''):gsub('/', '.')
                if modfile[name] and modfile[name] ~= f then dup[name] = true end
                modfile[name] = f
            end
        end
        for name in pairs(dup) do modfile[name] = nil end
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
                for _, fp in sorted(ofield[o] or {}) do
                    for fo in each(fp) do
                        local fpp = fnports[fo]
                        if fpp then for _, pp in ipairs(fpp.params) do addobj(pp, EXT) end end
                    end
                end
            end
        end
        solve()
    end
    -- ★ PARTIAL: a set the cap made INCOMPLETE (CART-1643). A port past CAP drops out: what it held before has gone
    -- downstream (an order-chosen part), what came after is lost — and a call through it never binds the functions it
    -- did not hand on, so their parameters miss those arguments. Sorting the schedule made that part REPRODUCIBLE, not
    -- whole. So every port whose set may be missing something is TAINTED, and an answer read through one is `partial`:
    -- the saturated ports, and whatever a tainted port flows into — edges, a load's result (its base is incomplete), a
    -- call's result (its callee is), filters, typed method returns, the loads of an object whose prototype port is
    -- tainted. And what an ESCAPED object (one that reached a saturated port) may still receive where the solve no
    -- longer follows it: its field f once a store with a tainted base writes f (or `[]`, which a Lua load also
    -- reads), and — for a function — its parameters once a call's callee is tainted (which function it would reach is
    -- what was lost).
    local tainted, twork = {}, {}
    local function taint(p) if p and not tainted[p] then tainted[p] = true; twork[#twork + 1] = p end end
    local gf_of = {}
    for _, gf in ipairs(gfilters) do local l = gf_of[gf[1]] or {}; gf_of[gf[1]] = l; l[#l + 1] = gf[2] end
    -- (an escaped object's fields and prototypes escaped WITH it: the solve no longer follows it, so a load through a
    -- tainted base misses what its fields hold — a method of its metatable — and a call through that load binds none of
    -- them. Closed transitively)
    local esc = {}
    for o in pairs(escaped) do esc[#esc + 1] = o end
    do
        local i = 1
        while i <= #esc do
            local o = esc[i]; i = i + 1
            for _, fp in pairs(ofield[o] or {}) do
                for x in each(fp) do if not escaped[x] then escaped[x] = true; esc[#esc + 1] = x end end
            end
            for c in pairs(protos[o] or {}) do if not escaped[c] then escaped[c] = true; esc[#esc + 1] = c end end
        end
    end
    local field_hit, params_hit = {}, false
    for p in pairs(top) do taint(p) end
    while #twork > 0 do
        local p = twork[#twork]; twork[#twork] = nil
        for q in pairs(succ[p] or {}) do taint(q) end
        if fowner[p] then readers(fowner[p], fname[p], taint) end
        for _, ld in ipairs(loads[p] or {}) do taint(ld[2]) end
        for _, st in ipairs(stores[p] or {}) do
            local f = st[1]
            if not field_hit[f] then
                field_hit[f] = true
                for _, o in ipairs(esc) do local m = ofield[o]; if m and m[f] then taint(m[f]) end end
            end
        end
        if calls[p] and not params_hit then
            params_hit = true
            for _, o in ipairs(esc) do local fpp = fnports[o]; if fpp then for _, pp in ipairs(fpp.params) do taint(pp) end end end
        end
        for _, cl in ipairs(calls[p] or {}) do
            if type(cl[2]) == 'table' then for _, r in ipairs(cl[2]) do taint(r) end else taint(cl[2]) end
        end
        for _, fl in ipairs(filters[p] or {}) do taint(fl[1]) end
        for _, d in ipairs(gf_of[p] or {}) do taint(d) end
        for _, mf in ipairs(mflows[p] or {}) do taint(mf[2]) end
        for _, t in ipairs(protos_rev[p] or {}) do
            for o in each(t) do for f, l in pairs(rd[o] or {}) do if f ~= NS then for dst in pairs(l) do taint(dst) end end end end
        end
    end
    local partial_hit -- (set by targets: a field port it read was tainted)
    -- ── the verdicts ────────────────────────────────────────────────────────────────────────────────
    local verdicts = {}
    local stats = { probes = #probes, exact = 0, narrowed = 0, string = 0, typed = 0, unknown = 0, none = 0, same = 0,
        files = #files, ports = N, objects = NO }
    local function targets(o, m, out, seen)
        if seen[o] then return false end
        seen[o] = true
        local p = ofield[o] and ofield[o][m]
        if p and tainted[p] then partial_hit = true end
        if p and top[p] then return true end
        if p then for x in each(p) do out[x] = true end end
        local t = false
        for c in pairs(protos[o] or {}) do t = targets(c, m, out, seen) or t end
        return t
    end
    stats.partial = 0
    for _, pr in ipairs(probes) do
        local kind, v
        partial_hit = tainted[pr.recv] or false
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
        if v and partial_hit then v.partial = true; stats.partial = stats.partial + 1 end
        if v then verdicts[pr.c] = v end
    end
    -- (PROBES a language walker records itself — every Go method call: { file, line, col, member, recv } -> targets)
    local probe_out = {}
    for _, pr in ipairs(S.probes) do
        local kind, fns, unknown = nil, {}, top[pr.recv] or has(pr.recv, EXT)
        partial_hit = tainted[pr.recv] or false
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
            guarded = pr.guard ~= nil, partial = partial_hit or nil }
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

-- (one solve, uncached — for an instrument that varies opts.order)
function M.solve(store, opts) return build(store, opts) end

return M
