-- cartograph.flowtype — WHAT VALUE REACHES A RECEIVER, BY FLOW (CART-1621: local type inference → record shapes).
--
-- An inclusion-based (Andersen) points-to analysis over a Lua tree: every value position is a PORT; objects — the
-- table constructors, the functions, and TYPE objects (`string`, a profile's `file` / `TSNode` …) — flow along
-- assignments, arguments to the parameters of the resolved callee (or, on the fly, of every function the callee
-- port holds), returns, `require` (the module's returned value), a `setmetatable(t, mt)` __index link (t's objects
-- read mt.__index's fields), `pcall` / `xpcall`, `for … in pairs / ipairs` (values: the `[]` field; keys: `{k}`).
-- Fields are per OBJECT; a dynamic-key load reads every field, and a function a dynamic-key store wrote may be any
-- member (CART-1726) — but `T[k] = S[k]` is a KEYED COPY, field to field. A profile's declared return types an external call's
-- result (tostring -> string, io.open -> file) and a method on a typed object (s:sub -> string, n:parent -> TSNode).
--
-- ★ WHY INCLUSION AND NOT UNIFICATION. Measured on lua/cartograph (the prototype): unification (Steensgaard) merged
-- every string with hazard.lua's string-API objects — 1572 wrong exact answers to 91 right; inclusion: 214 exact,
-- every one checked right (41 of them a function the name join never listed: at.lua's `C.sl` IS bytecol's returned
-- reader closure), 772 calls whose receiver is only ever a string.
--
-- ★ AN ANSWER IS A CLAIM ONLY WHEN NOTHING UNKNOWN REACHES THE RECEIVER. A port past CAP objects is `top` and that
-- spreads to whatever it flows into; code outside the tree — what load / loadstring / dofile and a require the tree
-- cannot map return — is EXT, and calling it returns EXT and hands it the arguments (CART-1707); with `open` (default),
-- a function a module exports takes EXT at its parameters (its callers are not all in the tree). A receiver holding
-- EXT or top gets no verdict. What the tree does not hold is a frontier, never a guess.
--
-- ★ THE CONTRACT — what a whole answer assumes of the code it cannot see (each clause pinned by a spec):
--   - a function outside the tree raises strings (pcall's second value, CART-1705);
--   - a profile-typed function (vim.*, string.*) writes nothing it is handed, and calls a function it is handed only
--     where a route models it (table.sort's comparator, __tostring; any such call's ERRORS reach the caller, CART-1708)
--     — `vim.tbl_map(f, t)` handing t's elements to f is not followed; UNKNOWN code (EXT) may write any field of what
--     it is handed and calls the functions among it with EXT — but not the globals table, which every code reaches;
--   - globals are named: a global read — an identifier, or a NAMED load off the globals table, `local G = _G; G.q`
--     (CART-1715) — sees `_G.q = v`, never a dynamic-key `_G[k] = v`, and a read by computed
--     name `_G[k]` sees dynamic-key writes and EXT, never the named globals (CART-1707: either widening made every
--     global read on the repo partial, or WoW w2's solve 15x slower); and _G never ESCAPES — a write through a value
--     the cap cut that may be _G is not followed (WoW passes _G as an argument: w3, 308 whole answers partial);
--   - a call on a MEMBER of unknown code's value (a receiver load / an unmappable module returned) runs no tree code
--     and hands its arguments nowhere — a member of EXT is not EXT (CART-1715: 427 typed / string answers went
--     unknown when it was); a call the flow cannot resolve runs nothing (the name join is no input, CART-1689).
--
--   M.of(store, opts) -> R, cached per graph generation; R.verdict(c) -> nil | { kind = 'exact' | 'narrowed' |
--     'string' | 'typed', targets = { fn id … } (exact / narrowed), type = 'string' | <profile type> }
--   for a REFUSED-ambiguous call `x.m()` / `x:m()` (the calls the name join could not decide). R.stats: the counts.
local callrec = require 'cartograph.callrec'
local atr = require 'cartograph.at'
local tsutil = require 'cartograph.spec.tsutil'
local EMPTY_NODE = { child = function () return nil end, named_child = function () return nil end } -- (an absent child list: tsutil.inext over nothing)

local M = {}
M.CAP = 64
-- (a binary operator's metamethod — run with both operands when either carries it, CART-1702; `a > b` is `b < a`)
local METAOP = { ['+'] = '__add', ['-'] = '__sub', ['*'] = '__mul', ['/'] = '__div', ['%'] = '__mod', ['^'] = '__pow',
    ['..'] = '__concat', ['//'] = '__idiv', ['&'] = '__band', ['|'] = '__bor', ['~'] = '__bxor', ['<<'] = '__shl',
    ['>>'] = '__shr', ['=='] = '__eq', ['~='] = '__eq', ['<'] = '__lt', ['<='] = '__le', ['>'] = '__lt', ['>='] = '__le' }
local CMPOP = { ['=='] = true, ['~='] = true, ['<'] = true, ['<='] = true, ['>'] = true, ['>='] = true }
-- ★ A SCALAR HAS NO FIELD TO WRITE: `s.body = f` on a string, number or boolean raises, so a program that gets past
-- the store did not hold one there (CART-1643's reading, for stores). The shared `type:string` object had collected
-- derive.lua's functions as `.body` that way, a call `t.body(…)` on a list walker reached them, and their returns
-- snowballed the walker's parameter past CAP — the store module escaped through it and every `store.node` answer
-- read partial (CART-1683)
local SCALAR = { string = true, number = true, integer = true, boolean = true, ['nil'] = true }
-- ★ ONE EMPTY TABLE FOR EVERY ABSENT LIST (CART-1656's allocation census): `ipairs(loads[p] or {})` in the solve loop
-- built a fresh empty table per port per visit — 16 M of the 27 M tables one solve of lua/cartograph allocated were
-- such fallbacks. Iterated only: NEVER written
local NOTHING = setmetatable({}, { __newindex = function () error('flowtype: NOTHING is read-only') end })
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
    -- ★ LUA'S HIDDEN VALUE ROUTES (CART-1699): a function reached as a Lua `__index` (LUAIDX: an index port a lua
    -- setmetatable made — JS prototypes are never called) is CALLED by a load that falls through to it (IDXFN: table ->
    -- its __index functions); OBJPORT / KEYPORT hold the (table, key) arguments it is called with. idxcall is set below
    local LUAIDX, IDXFN, OBJPORT, KEYPORT = {}, {}, {}, {}
    -- (METAH: a handler port -> its metamethod name; MTSTORES: every setmetatable's { target, metatable } ports — what
    -- decides whether a tainted handler port can be missing anything, see the taint loop)
    local METAH, MTSTORES = {}, {}
    -- (CART-1708: where an error raised by tree code that a LOAD runs — an __index function — goes: the load site's
    -- function's error port, LOADERR[load result]; WALKERR is the walker's current one. ARGERR: a call's argument
    -- port -> the error ports a function value arriving there carries into — a builtin may call it)
    local LOADERR, ARGERR, WALKERR = {}, {}, nil
    -- (CART-1707: EXTCALL — what UNKNOWN code (a call of EXT: load / loadstring / dofile, a module outside the tree)
    -- is handed; it may call every function arriving there with unknown arguments, and write or re-metatable every
    -- object. GOBJ / GPORT — the globals table, whose fields the globals are. Set below, with port)
    local G7 = {} -- (EXTCALL, GOBJ, GPORT, gport, gread: one local — the builder is at Lua's 200-local limit)
    -- (opts.dump: the program in the core IR, with this solve's solution — flowdump.lua, CART-1710. G7.mu runs a builtin
    -- translated by hand with its inner primitives MUTED; G7.ins / G7.gap record into the current function)
    if opts.dump then G7.REC = require('cartograph.flowdump').recorder(); G7.M = 0; G7.INSAT = {} end
    function G7.mu(f)
        if not G7.REC then return f() end
        G7.M = G7.M + 1
        local r = f()
        G7.M = G7.M - 1
        return r
    end
    function G7.cur() local st = G7.FNS; local fp = st and st[#st]; return fp and fp.id or G7.CK end
    function G7.ins(ins, tag) if G7.REC and G7.W then G7.REC.ins(G7.cur(), ins, tag) end end
    function G7.gap(kind, vars) if G7.REC and G7.W then G7.REC.gap(G7.cur(), kind, vars, G7.CK) end end
    local idxcall
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
        for f in pairs(ofield[o] or NOTHING) do l[#l + 1] = f end
        table.sort(l)
        okeys_cache[o] = l
        return l
    end
    local NS = '\0ns'
    local wl, inwl, head, tail = {}, {}, 1, 0
    -- ★ A FUEL BUDGET (CART-1706): termination BY CONSTRUCTION — after `fuel` worklist steps (opts.fuel, or
    -- CARTOGRAPH_FLOWTYPE_FUEL; per pass) the solve stops and every port still queued is UNFINISHED: its pending
    -- objects escape and it seeds the taint, as a saturated port does, so a whole answer read through none of them is
    -- unaffected by the work left (the flowpath Lean plan's 9.1). stats.fuel_cut counts them
    local FUEL = tonumber(opts.fuel or os.getenv('CARTOGRAPH_FLOWTYPE_FUEL') or '')
    local OUT = false
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
    -- (opts.explain: the saturated port each object ESCAPED through first, or { carrier object } for a field or
    -- prototype that escaped with it: R.escape_of)
    local ESCAT = opts.explain and {} or nil
    local SATSNAP = {}
    local function settop(p)
        if top[p] then return end
        local s = pts[p]
        if ESCAT then
            if type(s) == 'number' then ESCAT[s] = ESCAT[s] or p
            elseif s and s.bs then for o in bs_iter(s) do ESCAT[o] = ESCAT[o] or p end
            elseif s then for o in pairs(s) do ESCAT[o] = ESCAT[o] or p end end
        end
        if type(s) == 'number' then escaped[s] = true
        elseif s and s.bs then for o in bs_iter(s) do escaped[o] = true end
        elseif s then for o in pairs(s) do escaped[o] = true end end
        if opts.keepsat then
            local snap = {}
            if type(s) == 'number' then snap[1] = s elseif s and s.bs then for o in bs_iter(s) do snap[#snap + 1] = o end elseif s then for o in pairs(s) do snap[#snap + 1] = o end end
            SATSNAP[p] = snap
        end
        top[p] = true; pts[p] = nil; delta[p] = nil
        if spread then push(p) end
    end
    -- (a port's objects: ONE object is the number itself, more a set — most ports hold one, and a table per port was
    -- the memory: 1.3 GB on lua/cartograph)
    local EMPTY = {}
    local function one(st, ctl) if ctl == nil then return st end end
    -- (a delta's objects, a number or a list, without a table for the one-object case)
    local function one_i(n, i) if i == 0 then return 1, n end end
    local function dit(d) if type(d) == 'number' then return one_i, d, 0 end return ipairs(d) end
    -- (a port's successors, a number or a set, as pairs would give them)
    local function one_k(n, k) if k == nil then return n end end
    local function sit(s) if type(s) == 'number' then return one_k, s, nil end return next, s or NOTHING, nil end
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
        if type(d) == 'number' then bs_set(b, d) elseif d then for _, o in ipairs(d) do bs_set(b, o) end end
        delta[p] = b
        return b
    end
    local function addobj(p, o)
        if top[p] then escaped[o] = true; if ESCAT then ESCAT[o] = ESCAT[o] or p end; return end
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
        -- (a port's pending delta as its objects are: ONE object is the number itself, more a list, many a bitset — most
        -- deltas hold one object, and a list per port per round was the allocation census's top site, 1.3 M per run)
        local d = delta[p]
        if d == nil then delta[p] = o
        elseif type(d) == 'number' then delta[p] = { d, o }
        elseif d.bs then bs_set(d, o)
        else
            d[#d + 1] = o
            if #d > BIG then dbits(p) end
        end
        push(p)
    end
    -- the bitset d into q: word by word, what was new becomes q's delta
    local function addbits(q, d)
        if top[q] then for o in bs_iter(d) do escaped[o] = true; if ESCAT then ESCAT[o] = ESCAT[o] or q end end return end
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
    -- CART-1742: ALL SATURATED PORTS ARE ONE ⊤ NODE. A saturated destination only marks what reaches it escaped,
    -- so a source feeding any number of them feeds the canonical ⊤ port once (G7.TOPL; G7.TOPS for a strict reader)
    -- (CART-1742, measured in flowpath probes/solver: 92-99.5% of deliveries hand a port an object it already holds, most
    -- into SATURATED ports where a delivery only marks escaped; the dump is byte-identical with it. opts.top1 = false /
    -- env CARTOGRAPH_TOP1=0: one top port per saturated port, as before; off under opts.explain, which names each)
    if opts.top1 ~= false and os.getenv('CARTOGRAPH_TOP1') ~= '0' and not ESCAT then
        G7.TOPL, G7.TOPS = -1, -2; top[-1] = true; top[-2] = true -- (no port number: the walk's numbering is unchanged)
    end
    function G7.resucc(p) -- p's saturated successors replaced by ⊤
        local s, T = succ[p], G7.TOPL
        if type(s) == 'number' then if top[s] and s ~= T then succ[p] = T end; return end
        if s == nil then return end
        local dead
        for q in pairs(s) do if top[q] and q ~= T then dead = dead or {}; dead[#dead + 1] = q end end
        if dead then for i = 1, #dead do s[dead[i]] = nil end; s[T] = true end
    end
    -- a reader list's saturated readers are PARKED (G7.PARK[l]: a load's result port carries its own metadata — the
    -- error port an __index function's raise reaches, LOADERR — so prototype replays and __index calls still see them)
    -- and the list feeds ⊤ once instead (the strict ⊤ for a strict reader)
    G7.PARK, G7.FEDTOP = {}, {}
    function G7.rereaders(l)
        local dead
        for dst, v in pairs(l) do if top[dst] and dst ~= G7.TOPL and dst ~= G7.TOPS then dead = dead or {}; dead[#dead + 1] = dst end end
        if dead then
            local pk = G7.PARK[l]
            if not pk then pk = {}; G7.PARK[l] = pk end
            for i = 1, #dead do
                local v = l[dead[i]]; l[dead[i]] = nil; pk[dead[i]] = v
                if v == true then l[G7.TOPS] = true else l[G7.TOPL] = v end
            end
        end
    end
    -- every reader of a list, live and parked, without the ⊤ markers: for registrations that need the readers themselves
    function G7.allreaders(l, fn)
        local T, S = G7.TOPL, G7.TOPS
        for dst, v in pairs(l) do if dst ~= T and dst ~= S then fn(dst, v) end end
        local pk = G7.PARK[l]
        if pk then for dst, v in pairs(pk) do fn(dst, v) end end
    end
    local function edge(a, b) -- pts(b) ⊇ pts(a)
        if a == b then return end
        if G7.TOPL and top[b] then b = G7.TOPL; if a == b then return end end -- CART-1742
        -- (a port's successors as its objects are: ONE is the port number itself, more a set — a set per source port was
        -- the census's second site, 0.64 M per run. The set is grown key by key, as before: its pairs ORDER is the
        -- propagation order, and a constructor would lay the hash out differently)
        local s = succ[a]
        if s == nil then succ[a] = b
        elseif type(s) == 'number' then
            if s == b then return end
            local t = {}; t[s] = true; t[b] = true; succ[a] = t
        else
            if s[b] then return end
            s[b] = true
        end
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
            local cp = G7.CPAIR and G7.CPAIR[o] -- (a KEYED COPY's source gained a field: its targets gain it too)
            if cp and f:byte(1) ~= 1 then for t in pairs(cp) do G7.edge(p, ofp(t, f)) end end
        end
        return p
    end
    -- every load reading field g of o: the loads of g; a non-strict `[]` load reads every field but `{k}` and the
    -- HIDDEN ones (`\1mt`, `\1co`: no `t[k]` returns them — a `[]` load registered before setmetatable's store got
    -- the metatable, one registered after did not, CART-1707); `[]` is read by every non-strict named load as well (a
    -- Lua `t[k] = v` may write any name)
    local function readers(o, g, fn)
        local r = rd[o]
        if not r then return end
        local l = r[g]
        -- (CART-1742, CART-1742: a saturated reader seen here is PARKED and its list feeds the one ⊤ port instead)
        local T, dl, dd, dn = G7.TOPL, nil, nil, nil
        if l then for dst in pairs(l) do fn(dst); if T and top[dst] and dst ~= T and dst ~= G7.TOPS then dl = true end end end
        if g ~= '{k}' and g ~= '[]' and g:byte(1) ~= 1 and not G7.ISG[o] then
            local dyn = r['[]']
            if dyn then for dst, strict in pairs(dyn) do if not strict then fn(dst); if T and top[dst] and dst ~= T then dd = dyn end end end end
        end
        if g == '[]' then local ns = r[NS]; if ns then for dst in pairs(ns) do fn(dst); if T and top[dst] and dst ~= T and dst ~= G7.TOPS then dn = ns end end end end
        if dl then G7.rereaders(l) end
        if dd then G7.rereaders(dd) end
        if dn then G7.rereaders(dn) end
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
    local LOADV = 0 -- (load_obj calls: stats.loadvisits, the complexity a spec pins — CART-1686)
    local function load_obj(o, f, dst, seen, strict)
        LOADV = LOADV + 1
        -- (the cycle guard only matters along PROTOTYPES: allocated at the first one — 2.2 M sets per solve were built
        -- for loads that never followed a prototype, the allocation census's top site)
        if seen then
            if seen[o] then return end
            seen[o] = true
        end
        local tn = TNAME[o]
        if tn then
            -- (a string's metatable __index is the string library: `s.f` and `s[k]` — a computed key too — read its fields,
            -- `string.pick = …` among them; `s[k]` had read nothing, an unexplained loadDyn in the dump, CART-1730)
            local sl = G7.MULTI and G7.LENV[dst] and G7.LENV[dst].STRLIB or G7.STRLIB
            if tn == 'string' and sl and f ~= '#' then load_obj(sl, f, dst, seen, strict) end
            local e = (f == '#' or f == '[]' or not strict) and elemtype(tn)
            if e and e ~= '' then addobj(dst, typeobj((e:gsub('%?$', '')))) end
            return
        end
        -- (a NAMED load off a globals table is a global read, whatever expression reached the table — `_G.q`, `local G
        -- = _G; G.q`: strict, as the identifier read is (the contract). Non-strict, it read every dynamic-key write —
        -- AceHook's `_G[method] = uid`: with LibStub's `_G[LIBSTUB_MAJOR]` read by name (a constant key, CART-1729's
        -- patch) the global LibStub held every value in the program)
        if not strict and f ~= '[]' and G7.ISG[o] and f:byte(1) ~= 1 then strict = true end
        local r = rd[o]
        if not r then r = {}; rd[o] = r end
        local l = r[f]
        if not l then l = {}; r[f] = l end
        -- ★ A REGISTERED LOAD RETURNS AT ONCE (CART-1686): registering (o, f, dst) walked every prototype o had then (in
        -- the same call, below), and a prototype o gains LATER receives o's recorded loads through replay_loads — so a
        -- repeat could only re-walk the prototype DAG under a fresh `seen`. On WoW's mixin-dense trees that re-walk was
        -- 91% of the solve (w2, 607k lines: 184.7 s -> 15.6 s, every verdict row identical)
        if l[dst] ~= nil then return end
        do local pk = G7.PARK and G7.PARK[l]; if pk and pk[dst] ~= nil then return end end -- CART-1742 (parked: registered)
        do
            l[dst] = strict and true or false
            if not strict and f ~= '[]' then local ns = r[NS]; if not ns then ns = {}; r[NS] = ns end; ns[dst] = true end
            -- (what the fields hold already; what they gain later reaches dst as their readers)
            local function pull(q)
                if top[q] then if spread then settop(dst) end return end
                -- CART-1742: into ⊤, a field's objects are marked escaped ONCE: the first saturated reader stays
                -- registered on it (parked) and the list's ⊤ marker takes what it gains later
                if G7.TOPL and top[dst] then if G7.FEDTOP[q] then return end; G7.FEDTOP[q] = true end
                local sq = pts[q]
                if type(sq) == 'table' and sq.bs then addbits(dst, sq) else for x in each(q) do addobj(dst, x) end end
            end
            if strict then pull(ofp(o, f))
            elseif f == '[]' and G7.ISG[o] then
                -- (`_G[k]`, k unknown: what a dynamic-key write stored, and a global the HOST defines — EXT. Not every
                -- named global: on WoW `_G["Frame" .. i]` pulled every global's value set into each such read, and
                -- the solve went 41 -> 632 s. The mirror of a STRICT global read, CART-1707)
                pull(ofp(o, '[]')); if G7.EXT then addobj(dst, G7.EXT) end
            elseif f == '[]' then local m = ofield[o]; for _, fk in ipairs(okeys(o)) do if fk ~= '{k}' and fk:byte(1) ~= 1 then pull(m[fk]) end end
            else pull(ofp(o, f)); pull(ofp(o, '[]')) end
            -- (a load falling through to an __index FUNCTION calls it with (o, key): its result is the load's value)
            local fm = IDXFN[o]
            if fm then for g in pairs(fm) do idxcall(g, o, f, dst) end end
        end
        local pr = protos[o]
        -- (a HIDDEN field — the metatable `\1mt`, a thread's `\1co` — is the object's own: no __index chain reaches it)
        if pr and f:byte(1) ~= 1 then
            seen = seen or { [o] = true }
            for c in pairs(pr) do load_obj(c, f, dst, seen, strict) end
        end
    end
    -- the loads recorded on o, replayed on c (a prototype o gained) — field names in ONE order
    local function replay_loads(o, c)
        local r = rd[o]
        if not r then return end
        for f, l in sorted(r) do
            if f ~= NS and f:byte(1) ~= 1 then G7.allreaders(l, function (dst, strict) load_obj(c, f, dst, nil, strict) end) end -- CART-1742
        end
    end
    -- (PARAMETER PATHS, opts.pathsum — CART-1673: a parameter's port is tagged { fn, j, path = '' }, a load through a
    -- tagged port tags its result with the extended path (depth <= 3), and a tagged port's USES are noted — a method
    -- receiver, a call argument, a called value, a return. R.param_paths() -> uses, tags. Declared HERE: field() reads
    -- PTAG, and a later local would leave it a global inside field)
    local PTAG = opts.pathsum and {} or nil
    local PUSES = PTAG and {} or nil
    local function puse(p, kind, extra)
        local tg = PTAG and PTAG[p]
        if tg then PUSES[#PUSES + 1] = { fn = tg.fn, j = tg.j, path = tg.path, kind = kind, extra = extra } end
    end
    local function field(x, f, strict) -- a LOAD x.f -> its result port
        local dst = new()
        if G7.MULTI then G7.LENV[dst] = G7.ENV end
        if WALKERR then LOADERR[dst] = WALKERR() end
        if PTAG then
            local tg = PTAG[x]
            if tg and tg.d < 3 then PTAG[dst] = { fn = tg.fn, j = tg.j, path = tg.path .. '.' .. tostring(f), d = tg.d + 1 } end
        end
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
        -- (a FUNCTION has no metatable of its own — setmetatable raises on one — so `\1mt` never lands on it: a generic
        -- setmetatable(x, mt) whose x also held functions made a call of them run mt's __call, CART-1710)
        for o in each(x) do if not (fnports[o] and f == '\1mt') then edge(v, ofp(o, f)) end end
    end
    -- (`setmetatable(t, { __index = idx })`: every object at t has every object at idx as a prototype — linked when
    -- EITHER side gains one; linking only on t's arrivals lost an idx object that came later, an ORDER-dependent miss)
    local protos_rev = {}
    local function protolink(o, c, lua)
        if lua and fnports[c] then -- (a lua __index FUNCTION: each load on o calls it, CART-1703 — and it stays a prototype:
            -- the field rosters see a function there and refuse, rename-field / reshape)
            local m = IDXFN[o]
            if not m then m = {}; IDXFN[o] = m end
            if not m[c] then
                m[c] = true
                local r = rd[o]
                if r then
                    for f, l in sorted(r) do if f ~= NS then G7.allreaders(l, function (dst) idxcall(c, o, f, dst) end) end end -- CART-1742
                end
            end
        end
        local pr = protos[o]
        if not pr then pr = {}; protos[o] = pr end
        if pr[c] then return end
        pr[c] = true
        replay_loads(o, c)
    end
    local function proto(t, idx, lua)
        if lua then LUAIDX[idx] = true end
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
    local clone_at -- (set below, with the walker: a per-site instance of a small closed function)
    local function bindcall(o, args, res, site, cerr)
        if site and clone_at then
            local inst = clone_at(site, o)
            if inst then o = inst end
        end
        if args.fenv then
            -- (setfenv's function: its reads see the environment; unknown code is handed it)
            if o == G7.EXT then edge(args.fenv, G7.EXTCALL)
            elseif fnports[o] then G7.fenv(fnports[o].id, args.fenv) end
            return
        end
        if args.hook then
            -- (a HOOKED function — hooksecurefunc's: each function stored under the name also runs the hook with its
            -- arguments, CART-1707. A resolved call reaches the original straight, so its PARAMETERS are the hook's
            -- arguments)
            local fpp = fnports[o]
            if fpp then
                local ha = {}
                for i, pp in ipairs(fpp.params) do ha[i] = pp end
                if fpp.vararg then ha[#ha + 1] = fpp.vararg; ha.spread = #ha end
                G7.callc(args.hook, ha, new())
            end
            return
        end
        if o == G7.EXT and G7.EXTCALL then
            -- (calling UNKNOWN code: its results are unknown, what it is handed it may call or write — CART-1707)
            if type(res) == 'table' then for _, r in ipairs(res) do addobj(r, G7.EXT) end elseif res then addobj(res, G7.EXT) end
            for _, a in ipairs(args) do edge(a, G7.EXTCALL) end
            return
        end
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
        if cerr and fp.err then edge(fp.err, cerr) end -- (what the callee raises, the caller raises: CART-1705)
        -- (arguments past the named parameters reach the vararg; a spread last argument every parameter from its
        -- position, CART-1707)
        if fp.vararg then for i = #fp.params + 1, #args do edge(args[i], fp.vararg) end end
        local sp = args.spread
        if sp then
            for i = sp + 1, #fp.params do edge(args[sp], fp.params[i]) end
            if fp.vararg then edge(args[sp], fp.vararg) end
        end
        -- (a MULTI-value result — Go's `v, err := f()` — is a list of ports: the i-th return to the i-th)
        if type(res) == 'table' then
            for i, r in ipairs(res) do local fr = fp.rets and fp.rets[i] or (i == 1 and fp.ret); if fr then edge(fr, r) end end
        else edge(fp.ret, res) end
    end
    -- (one yield set and one resume-argument set for the whole program, CART-1700: any yield's values reach any resume,
    -- any resume's arguments any yield. GERR: what MODULE-LEVEL code raises — a function's own errors go to its port
    -- `e:<id>`, up the call graph to the pcall that protects it, CART-1705; one global set saturated on the repo and
    -- turned every pcall's second value into ⊤)
    local GERR, GYIELD, GRESARG
    local function gerr()
        if not GERR then GERR = new(); if G7.REC then G7.REC.errp[GERR] = true end; addobj(GERR, typeobj('string')) end
        return GERR
    end
    local function gyield() if not GYIELD then GYIELD = new() end return GYIELD end
    local function gresarg() if not GRESARG then GRESARG = new() end return GRESARG end
    idxcall = function (g, o, f, dst)
        local op = OBJPORT[o]
        if not op then op = new(); OBJPORT[o] = op; addobj(op, o) end
        local kp = KEYPORT[f]
        if not kp then
            kp = new(); KEYPORT[f] = kp
            if f ~= '[]' then addobj(kp, typeobj(f == '#' and 'number' or 'string')) end
        end
        bindcall(g, { op, kp }, dst, nil, LOADERR[dst])
    end
    local function callc(callee, args, res, site, cerr)
        local l = calls[callee]
        if not l then l = {}; calls[callee] = l end
        l[#l + 1] = { args, res, site, cerr }
        if top[callee] and spread and type(res) ~= 'table' then settop(res) end
        for o in each(callee) do bindcall(o, args, res, site, cerr) end
    end
    G7.callc = callc
    -- ★ A KEYED COPY (CART-1726): `M[op] = D[op]` — the same key on both sides, read in one statement — copies D's field
    -- k into M's field k, for whichever k: FIELD-WISE, not "any of D's values under any key". As a dynamic-key store it
    -- made every function of D a candidate for every member of M (algebra/core.lua's M, 394 answers); as a copy,
    -- M.generalize may be D.generalize and nothing else of D. G7.COPY: port -> its copy records; G7.CPAIR: source
    -- object -> its target objects
    -- object -> { [target object] = the copy's value port, what `S[k]` read }. A source the walk cannot copy field by
    -- field — unknown code's value, a typed one, one with a METATABLE (its __index answers keys it lacks) — is copied
    -- as the plain dynamic-key store of that value
    G7.edge, G7.COPY, G7.CPAIR = edge, {}, {}
    -- (a metatable is an object in the hidden field `\1mt` — the PORT alone is no evidence: a store creates it to look
    -- for __newindex. G7.mtcopy: a copy source's metatable port gained an object, or saturated)
    function G7.uncopyable(s0)
        local mp = ofield[s0] and ofield[s0]['\1mt']
        return s0 == G7.EXT or TNAME[s0] or (mp and (pts[mp] ~= nil or top[mp]))
    end
    function G7.mtcopy(p)
        local cp = fname[p] == '\1mt' and G7.CPAIR[fowner[p]]
        if cp then for t, v in pairs(cp) do edge(v, ofp(t, '[]')) end end
    end
    -- (the fields a copy from s0 may write: its own, and any key where it is uncopyable)
    function G7.copykeys(s0)
        local fs = ofield[s0] or NOTHING
        if not G7.uncopyable(s0) then return fs end
        local t = { ['[]'] = true }
        for f in pairs(fs) do t[f] = true end
        return t
    end
    function G7.copypair(s0, o, v)
        if s0 == o or TNAME[o] or o == G7.EXT then return end
        local m = G7.CPAIR[s0]
        if not m then m = {}; G7.CPAIR[s0] = m end
        if m[o] then return end
        m[o] = v
        if G7.uncopyable(s0) then edge(v, ofp(o, '[]')) end
        if s0 == G7.EXT or TNAME[s0] then return end
        for f, fp in pairs(ofield[s0] or NOTHING) do if f:byte(1) ~= 1 then edge(fp, ofp(o, f)) end end
    end
    function G7.copyf(dst, src, v)
        local r = { dst, src, v }
        for _, q in ipairs { dst, src } do local l = G7.COPY[q]; if not l then l = {}; G7.COPY[q] = l end; l[#l + 1] = r end
        -- (muted: the core IR has no field-wise copy — the dump names it as the gap `keyed-copy`)
        G7.mu(function () for s0 in each(src) do for o in each(dst) do G7.copypair(s0, o, v) end end end)
    end
    -- (a handler in x's metatable — `__call`, `__add`, `__newindex`… — called with args, its results into res: the
    -- metatable rides on the object as the hidden field `\1mt`, which `setmetatable` writes)
    local function metacall(x, mm, args, res, cerr, site)
        local h = field(field(x, '\1mt', true), mm) -- (non-strict: a handler written `mt[k] = f` counts)
        METAH[h] = mm
        callc(h, args, res, site, cerr)
    end
    -- (a store `x.f = v` / `x[k] = v` also reaches x's `__newindex`: a FUNCTION is called with (x, key, v), a TABLE
    -- receives the store — CART-1704)
    local function metastore(base, f, kp, v, cerr)
        local nh = field(field(base, '\1mt', true), '__newindex')
        METAH[nh] = '__newindex'
        callc(nh, { base, kp, v }, new(), nil, cerr)
        storec(nh, f, v)
    end
    -- type objects and the profiles' declared returns
    typeobj = function (t)
        local o = TYPEOBJ[t]
        if not o then o = newobj('type:' .. t); TYPEOBJ[t] = o; TNAME[o] = t end
        return o
    end
    local STR = typeobj('string')
    local EXT = newobj('external')
    G7.EXT = EXT
    local PSIGS = {}
    do
        local P = require 'cartograph.spec.profile'
        for _, nm in ipairs { P.base_for('lua'), store.data.profile } do
            local pr = nm and P.load(nm)
            for k, v in pairs(pr and pr.sigs or NOTHING) do if PSIGS[k] == nil then PSIGS[k] = v end end
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
    -- ★ A GENERIC RETURN IS ITS ARGUMENT (CART-1653): `assert(v: T, …): T` returns v — not an object of a type named
    -- `T`. 48 of lua/cartograph's empty receivers were `A().node(…)` with A = `assert(require(…).load())`: the algebra
    -- table never arrived, a bare `T` did. A return whose type is a generic-shaped name (T, K, V, T1) that also types a
    -- parameter takes that parameter's argument -> its index, or nil
    local GEN = {}
    local function genarg(key, k)
        local ck = key .. '\0' .. k
        local g = GEN[ck]
        if g ~= nil then return g or nil end
        g = false
        local sg = PSIGS[key]
        local rk = type(sg) == 'table' and sg.returns and sg.returns[k]
        local rt = rk and type(rk.type) == 'string' and rk.type:gsub('%?$', '')
        if rt and rt:match('^[A-Z]%d?$') then
            for i, pm in ipairs(sg.params or NOTHING) do
                if pm.name ~= '...' and type(pm.type) == 'string' and pm.type:gsub('%?$', '') == rt then g = i; break end
            end
        end
        GEN[ck] = g
        return g or nil
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
        if OUT then return end
        while head <= tail do
            if FUEL then
                if FUEL <= 0 then OUT = true; break end
                FUEL = FUEL - 1
            end
            local p = pop()
            if order == 'fifo' and head > tail then head, tail = 1, 0 end
            inwl[p] = nil
            if top[p] then
                G7.mtcopy(p)
                -- (SPREAD only: without it a saturated port DROPS OUT — the taint phase covers what it lost. A port queued
                -- before it saturated reached this branch by SCHEDULE and saturated its successors, load and call results:
                -- saturation counts went non-monotone in CAP — 15,358 / 13,246 / 20,955 at CAP 16 / 32 / 64, CART-1741)
                if spread then
                    for q in sit(succ[p]) do settop(q) end
                    if fowner[p] then readers(fowner[p], fname[p], settop) end
                    for _, ld in ipairs(loads[p] or NOTHING) do settop(ld[2]) end
                    for _, cl in ipairs(calls[p] or NOTHING) do if type(cl[2]) ~= 'table' then settop(cl[2]) end end
                end
            else
                local d = delta[p]
                delta[p] = nil
                if type(d) == 'table' and d.bs then
                    -- (a DENSE delta: the copy edges and the field's readers in bulk; the rest per object)
                    local db = d
                    local anytop = false
                    for q in sit(succ[p]) do addbits(q, db); if top[q] then anytop = true end end
                    if anytop and G7.TOPL then G7.resucc(p) end -- CART-1742
                    if fowner[p] then readers(fowner[p], fname[p], function (q) addbits(q, db) end) end
                    d = {}
                    for o in bs_iter(db) do d[#d + 1] = o end
                elseif d then
                    local anytop = false
                    for q in sit(succ[p]) do for _, o in dit(d) do addobj(q, o) end; if top[q] then anytop = true end end
                    if anytop and G7.TOPL then G7.resucc(p) end -- CART-1742
                    if fowner[p] then readers(fowner[p], fname[p], function (q) for _, o in dit(d) do addobj(q, o) end end) end
                end
                if d then
                    for _, ld in ipairs(loads[p] or NOTHING) do for _, o in dit(d) do load_obj(o, ld[1], ld[2], nil, ld[3]) end end
                    for _, st in ipairs(stores[p] or NOTHING) do
                        for _, o in dit(d) do
                            if not SCALAR[TNAME[o]] and not (fnports[o] and st[1] == '\1mt') then edge(st[2], ofp(o, st[1])) end
                        end
                    end
                    G7.mtcopy(p)
                    for _, r in ipairs(G7.COPY[p] or NOTHING) do
                        for _, x in dit(d) do
                            if p == r[1] then for s0 in each(r[2]) do G7.copypair(s0, x, r[3]) end end
                            if p == r[2] then for o in each(r[1]) do G7.copypair(x, o, r[3]) end end
                        end
                    end
                    for _, cl in ipairs(calls[p] or NOTHING) do for _, o in dit(d) do bindcall(o, cl[1], cl[2], cl[3], cl[4]) end end
                    for _, ce in ipairs(ARGERR[p] or NOTHING) do
                        for _, o in dit(d) do local fpp = fnports[o]; if fpp and fpp.err then edge(fpp.err, ce) end end
                    end
                    for _, fl in ipairs(filters[p] or NOTHING) do
                        for _, o in dit(d) do if fl[2](o) then addobj(fl[1], o) end end
                    end
                    for _, mf in ipairs(mflows[p] or NOTHING) do
                        for _, o in dit(d) do
                            local tn = TNAME[o]
                            local rt = tn and retk(tn .. '#' .. mf[1], mf[3] or 1)
                            if rt then addobj(mf[2], typeobj(rt)) end
                        end
                    end
                    for _, idx in ipairs(protos_at[p] or NOTHING) do
                        local lua = LUAIDX[idx]
                        for _, o in dit(d) do for c in each(idx) do protolink(o, c, lua) end end
                    end
                    local plua = LUAIDX[p]
                    for _, t in ipairs(protos_rev[p] or NOTHING) do
                        for o in each(t) do for _, c in dit(d) do protolink(o, c, plua) end end
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
    -- ★ THE GLOBALS ARE THE FIELDS OF ONE TABLE, _G (CART-1707): a global's port IS field `name` of GOBJ, so `_G.q = b`,
    -- `_G[k] = v` and `rawset(_G, …)` write it; a global READ is a load through GPORT, copied into a port of the
    -- reading FUNCTION (G7.GR: function id -> name -> port), so `setfenv(f, env)` adds env's field to f's reads — and
    -- to the functions nested in f, which inherit its environment — and nowhere else. getfenv returns G7.FENVP: _G and
    -- every environment setfenv set
    -- ★ ONE ENVIRONMENT PER PROGRAM (CART-1737, cartograph.programs): the globals table and the string library are a
    -- PROGRAM's — the files that run in one process. One environment unless config or derived evidence splits them;
    -- G7.ENV is the walked file's, G7.ISG / G7.ISGP every environment's _G object / port
    G7.ENVS, G7.ENVL, G7.ISG, G7.ISGP, G7.LENV = {}, {}, {}, {}, {}
    function G7.useenv(e)
        G7.ENV = e
        G7.GOBJ, G7.GPORT, G7.GREAD, G7.FENVP, G7.STRLIB = e.GOBJ, e.GPORT, e.GREAD, e.FENVP, e.STRLIB
    end
    function G7.gport(name)
        local key = G7.ENV.name == 'default' and ('g:' .. name) or ('g:' .. G7.ENV.name .. ':' .. name)
        local p = named[key]
        if not p then p = ofp(G7.GOBJ, name); named[key] = p end
        return p
    end
    function G7.mkenv(name)
        local e = G7.ENVS[name]
        if e then return e end
        e = { name = name, GOBJ = newobj(name == 'default' and '_G' or ('_G@' .. name)), GPORT = new(), GREAD = {} }
        addobj(e.GPORT, e.GOBJ)
        G7.ISG[e.GOBJ], G7.ISGP[e.GPORT] = true, true
        G7.ENVS[name] = e
        G7.ENVL[#G7.ENVL + 1] = e
        if name ~= 'default' then e.FENVP = new(); addobj(e.FENVP, e.GOBJ); G7.MULTI = true end
        local saved = G7.ENV
        G7.useenv(e)
        addobj(G7.gport('_G'), e.GOBJ)
        if saved then G7.useenv(saved) end
        return e
    end
    G7.useenv(G7.mkenv('default'))
    G7.GR, G7.KIDS, G7.FENV, G7.GCPEND = {}, {}, {}, {}
    G7.SSTAT = nil
    -- (opts.litkeys, CART-1729: a constant local's port -> its string, a key through it is that name; the names each
    -- file assigns; value-keyed instances)
    G7.LITKEYS, G7.CONSTK, G7.REASGF, G7.VINST, G7.VINSTN = opts.litkeys or nil, {}, {}, {}, 0
    G7.MSELF = opts.selfseed and {} or nil -- (each `function T:m`'s self port and T's port: the self seed, CART-1715)
    -- (the modules the environment profile declares: every dotted prefix of a signature's path)
    function G7.profmod(name)
        if not G7.PMODS then
            G7.PMODS = {}
            for k in pairs(PSIGS) do
                local path = k:match('^(.-)#') or k:match('^(.*)%.[^.]*$') or k
                local acc
                for part in path:gmatch('[^.]+') do acc = acc and (acc .. '.' .. part) or part; G7.PMODS[acc] = true end
            end
        end
        return G7.PMODS[name]
    end
    -- ★ THE STRING LIBRARY IS A TABLE (CART-1715; the Lean model's P.strLib): the global `string` holds it, a store
    -- `string.pick = f` lands on it, and a string value's member is read from it too — `("x"):pick()` calls f. The name
    -- join had resolved such a call by spelling; without it the library's own fields are the evidence. Made by the LUA
    -- walk, on its first file: an object minted for every solve renumbers a TypeScript tree's objects, and its schedule
    G7.FENVP = new()
    addobj(G7.FENVP, G7.GOBJ)
    G7.ENV.FENVP = G7.FENVP
    function G7.fenv(id, env, seen)
        seen = seen or {}
        if seen[id] then return end
        seen[id] = true
        for name, dst in pairs(G7.GR[id] or NOTHING) do edge(field(env, name), dst) end
        for _, k in ipairs(G7.KIDS[id] or NOTHING) do G7.fenv(k, env, seen) end
    end
    function G7.gread(name)
        local p = G7.GREAD[name]
        if not p then p = field(G7.GPORT, name, true); G7.GREAD[name] = p end
        return p
    end
    G7.EXTCALL = new()
    do
        local xa = new()
        G7.XA = xa
        addobj(xa, EXT)
        G7.XRES = new()
        callc(G7.EXTCALL, { xa, xa, xa, xa, spread = 4 }, G7.XRES)
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
    for _, c in ipairs(store.data.calls or NOTHING) do
        local at = c.at
        if at then
            local k = callrec.file(c) .. ':' .. atr.sl(at) .. ':' .. atr.sc(at)
            call_at[k .. '#' .. tostring(callrec.callee(c))] = c
            -- (by position alone only where ONE call starts there)
            if call_at[k] == nil then call_at[k] = c elseif call_at[k] ~= c then call_at[k] = false end
        end
    end
    local req_at = {}
    for _, e in ipairs(store.data.edges or NOTHING) do
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
    -- ★ PER-SITE INSTANCES (CART-1643): a small CLOSED function — every name it reads its own or a global, no function
    -- inside it — is instantiable: walked again from its own text with ports of its own. A generic for binds its
    -- iterator to an instance per loop, so one loop's values no longer pour into every other's: tsutil.inext's node
    -- parameter took a node from every loop in the tree and saturated, and every inext loop variable was partial
    local CLONE, CLONE_MAX = {}, 600 -- fn object -> { file, id, src, l, c }: the function's own position
    -- (CART-1687: a loop site minted INSIDE an instance walk takes no instance of its own — the shared function answers
    -- there, which instances only refine. Postal's IterateModules loop instantiated itself 230k times on WoW w3)
    local NOCLONE, INST, INSTN = {}, 0, 0 -- (INSTN: instances walked — stats.instances)
    -- ★ SELECTIVE CONTEXT SENSITIVITY (CART-1653; client-driven refinement, Guyer & Lin SAS'03, Zipper OOPSLA'18): the
    -- functions a first solve found with a SATURATED parameter upstream of an unknown answer (opts.ctxfns) get an
    -- instance per resolved call site — re-walked from their own node inside a snapshot of the scopes they were defined
    -- in (so a closure keeps its upvalues), keyed to the file's real positions so each instance probes the calls in it.
    -- A call's answer is then the union over its instances: each instance's receiver stays under the cap where the
    -- merged one did not
    local mcalls = {} -- every `x:m(…)` the Lua walker saw: { receiver port, method, result ports }
    -- ★ THE ACCESS ROSTER (opts.accesses, CART-1175): every field access the Lua walker sees — a read, a write, a method
    -- call, a constructor key, a computed key — with its source range and its base port, resolved after the solve to
    -- the ALLOCATION SITES that reach it. A representation change (renamefield's family mode) rewrites exactly the
    -- accesses one family of tables reaches
    local ACC = opts.accesses and {} or nil
    local ARRAYFN = { ['table.concat'] = true, ['table.sort'] = true, ['table.remove'] = true, ['table.unpack'] = true,
        unpack = true, ['vim.list_extend'] = true, ['vim.tbl_islist'] = true, ['vim.islist'] = true }
    local CTXFNS = opts.ctxfns
    -- (ARGUMENT PROBES, opts.argprobes — CART-1670: the ports of every resolved-or-not call's arguments, by call record
    -- (a method's receiver is position 1, as in argv); R.arg_objs(c, i) answers which allocation sites reach one. The
    -- writers census asks it: an opaque local handed to a param-mutating callee may hold a module table)
    local ARGP = opts.argprobes and {} or nil
    local ROOTS = ARGP and {} or nil -- (each walked file's TOP scope: name -> port, filled as the walk declares)
    -- (parameter paths: PTAG / PUSES / puse, declared before field() — opts.pathsum, CART-1673)
    local CTX, ctx_direct = {}, {}
    -- (CART-1715: the selecting solve records each call's CALLEE PORT — G7.CALLP — and exports the calls whose callee
    -- was ONE function, untainted: R.ctxcallee, call record -> fn id. The second solve instances by that map, never by
    -- the name join's c.to: a wrong claim bound the wrong function and skipped the callee's flow)
    G7.CALLP = (opts.ctxsel or opts.allcallees) and {} or nil
    G7.CTXC = opts.ctxcallee
    local function walk_file(file, src, clone)
        local isctx = clone and clone.ctx
        -- (one parse per text per process, shared with the extractor and the lint rules — a snippet instance's text is
        -- its own entry. Keyed by the PARSE VIEW, as every parse site is: the raw text of a file that mentions `global`
        -- is a different key, so it missed the extractor's tree, parsed again, and the grammar misread that copy.)
        local tree = require('cartograph.parsecache').root(require('cartograph.parseview').view(src, 'lua'), 'lua')
        if not tree then return end
        -- (the names this file ASSIGNS anywhere, `k = …` outside a declaration: a local of that name may change, so it
        -- is no constant key below. By name over the whole file — any binding — which only refuses more. Once per file:
        -- an instance walks its file again)
        if G7.LITKEYS and not G7.REASGF[file] then
            local ra = {}
            G7.REASGF[file] = ra
            local function scan(n)
                for _, x in tsutil.inamed, n, -1 do
                    if x:type() == 'assignment_statement' and n:type() ~= 'variable_declaration' then
                        for _, v in tsutil.inamed, x:named_child(0), -1 do
                            if v:type() == 'identifier' then local _, _, b, _, _, e = v:range(true); ra[src:sub(b + 1, e)] = true end
                        end
                    end
                    if x:named_child_count() > 0 then scan(x) end
                end
            end
            scan(tree)
        end
        G7.REASG = G7.REASGF[file] or NOTHING
        if G7.PROG == nil then G7.PROG = require('cartograph.programs').of(store) or false end
        if G7.PROG then G7.useenv(G7.mkenv(G7.PROG.env[file] or 'default')) end
        if not G7.STRLIB then G7.STRLIB = newobj('stringlib'); G7.ENV.STRLIB = G7.STRLIB; addobj(G7.gport('string'), G7.STRLIB) end
        local fnmap = fn_at[file] or {}
        local function txt(n) local _, _, s, _, _, e = n:range(true); return src:sub(s + 1, e) end
        -- (an instance's positions are the SNIPPET's: keyed under a file of its own, they match no call record — a
        -- CONTEXT instance walks the original node, at the file's own positions)
        local kfile = (clone and not isctx) and ('clone:' .. file) or file
        local function key_of(n) local l, c = n:start(); return kfile .. ':' .. l .. ':' .. c end
        -- (an access, at the FILE's positions: a snippet instance's positions are its own, so it records none)
        local function acc(kind, node, f, base, obj, range, key)
            if not ACC or (clone and (not isctx or clone.noacc)) or not node then return end
            local sr, sc, er, ec = node:range()
            if range then sr, sc, er, ec = range[1], range[2], range[3], range[4] end
            ACC[#ACC + 1] = { file = file, sr = sr, sc = sc, er = er, ec = ec, f = f, kind = kind, base = base, obj = obj, key = key }
        end
        local scopes = { {} }
        if ROOTS and not clone then ROOTS[#ROOTS + 1] = { file = file, scope = scopes[1] } end
        -- (a function is CLOSED when every name it reads is its own or a global: fnbase holds each open function's
        -- first scope, fnmeta whether it read past it or holds a function of its own)
        local fnbase, fnmeta = {}, {}
        local function lookup(name)
            for i = #scopes, 1, -1 do
                local p = scopes[i][name]
                if p then
                    for k = #fnbase, 1, -1 do if i < fnbase[k] then fnmeta[k].upv = true else break end end
                    return p
                end
            end
            return G7.gport(name), true
        end
        local function declare(name, p) local q = p or new(); scopes[#scopes][name] = q; return q end
        local fnstack = {}
        -- (where an error raised HERE goes: the enclosing function's error port; module-level code's, the chunk set)
        local function curerr() local f = fnstack[#fnstack]; return f and f.err or gerr() end
        WALKERR = curerr -- (a load this walk makes knows where the errors of an __index function it runs go)
        local MULTI = 4 -- (the values a `return f()` forwards)
        local function funtype(path, n)
            local owner, mm = path:match('^([%a_][%w_%.]*)%.([%a_][%w_]*)$')
            if not owner then return nil end
            local key = owner .. '#' .. mm
            local sg = PSIGS[key]
            if type(sg) ~= 'table' or not sg.returns or #sg.returns == 0 then return nil end
            local root = owner:match('^[%a_][%w_]*')
            for i = #scopes, 1, -1 do if scopes[i][root] then return nil end end -- (a local of that name: not the profile's)
            local tys = {}
            for k, r in ipairs(sg.returns) do tys[k] = (type(r.type) == 'string' and r.type ~= '') and r.type or 'any' end
            return typeobj('fun(): ' .. table.concat(tys, ', '))
        end
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
            -- (a CONSTANT — a local declared from a string literal and never assigned in its file, or a key parameter of
            -- a value-keyed instance — is that string: `_G[LIBSTUB_MAJOR]` is the global LibStub, CART-1729)
            if G7.LITKEYS and k:type() == 'identifier' then local p = lookup(txt(k)); local c = p and G7.CONSTK[p]; if c then return c end end
            if isnum(k) then return '#' end
            return '[]'
        end
        -- (a bracket key's access: a string literal names its field — the range is its content — a computed key may
        -- name any field: a `dynamic` access)
        -- (a NUMBER literal key is a position: `t[2]` — an `index` access whose range runs from the end of the table
        -- expression to the closing bracket, the text a positional -> named reshape replaces with `.name`; another
        -- numeric key is the array as a whole)
        local function acc_key(kind, kn, base, whole)
            if not ACC or not kn then return end
            if kn:type() == 'string' then local c = kn:field('content')[1]; if c then acc(kind, c, txt(c), base) end
            elseif kn:type() == 'number' and whole and tonumber(txt(kn)) then
                local tb = whole:field('table')[1]
                local _, _, er, ec = whole:range()
                local tr, tc = tb:end_()
                acc('index', kn, tostring(tonumber(txt(kn))), base, nil, { tr, tc, er, ec })
            elseif keyname(kn) == '#' then acc('array', kn, nil, base)
            elseif keyname(kn) == '[]' or kn:type() == 'identifier' then -- (a constant key is still a NAME in the text)
                -- (and what the key holds — read only where reading it adds nothing to the solve: a name, or a dotted read
                -- off one; any other key, a call among them, is taken as possibly a string)
                local kt, ok = kn:type(), false
                local x = kn
                while x and x:type() == 'dot_index_expression' do x = x:field('table')[1] end
                ok = x and x:type() == 'identifier'
                acc('dynamic', kn, nil, base, nil, nil, ok and expr(kn) or false)
            end
        end
        local function assign(target, v, rhs)
            local t = target:type()
            if t == 'identifier' then edge(v, lookup(txt(target)))
            elseif t == 'dot_index_expression' then
                local base = expr(target:field('table')[1])
                acc('write', target:field('field')[1], txt(target:field('field')[1]), base)
                storec(base, txt(target:field('field')[1]), v)
                local kp = new(); addobj(kp, STR)
                metastore(base, txt(target:field('field')[1]), kp, v, curerr())
            elseif t == 'bracket_index_expression' then
                local base, kn = expr(target:field('table')[1]), target:field('field')[1]
                acc_key('write', kn, base, target)
                -- (`T[k] = S[k]` — one local k read twice in one statement: a KEYED COPY, field k to field k, CART-1726)
                local rk = rhs and rhs:type() == 'bracket_index_expression' and rhs:field('field')[1]
                if kn and rk and kn:type() == 'identifier' and rk:type() == 'identifier' and txt(kn) == txt(rk)
                    and not select(2, lookup(txt(kn))) and G7.KBASE and G7.KBASE[rhs:id()] then
                    G7.copyf(base, G7.KBASE[rhs:id()], v)
                    G7.gap('keyed-copy', { base })
                else
                    -- (the key's port is walked FIRST: the dump's storeDyn carries it, CART-1739)
                    local kp0 = kn and keyname(kn) == '[]' and expr(kn) or nil
                    G7.KP0 = kp0
                    G7.NEXTK = kp0
                    storec(base, keyname(kn), v)
                end
                local kp = G7.KP0 or (kn and expr(kn)) or new()
                G7.KP0 = nil
                if kn then storec(base, '{k}', kp) end
                metastore(base, keyname(kn), kp, v, curerr())
            end
        end
        local function func(n)
            local l, c = n:start()
            -- (an INSTANCE keeps the original's id — it is that function — and gets ports of its own)
            local inst = clone and #fnstack == 0
            -- (a function INSIDE an instance is at the snippet's position, which the file's map does not describe)
            local id = inst and clone.id or ((not clone or isctx) and fnmap[l .. ':' .. c]) or ('ts:' .. kfile .. ':' .. l .. ':' .. c)
            local p = new()
            local o = newobj(id)
            addobj(p, o)
            local fp = { params = {}, ret = inst and new() or port('r:' .. id), id = id, inst = inst or nil }
            fp.rets = { fp.ret }
            fp.err = inst and new() or port('e:' .. id) -- (what it raises, CART-1705)
            if G7.REC then G7.REC.errp[fp.err] = true end
            fnports[o] = fp
            -- (a nested function inherits its parent's environment — a top-level one its file CHUNK's: G7.fenv)
            local pid = fnstack[#fnstack] and fnstack[#fnstack].id or G7.CHUNK
            if pid and not inst and not clone then local kl = G7.KIDS[pid]; if not kl then kl = {}; G7.KIDS[pid] = kl end; kl[#kl + 1] = id end
            if CTXFNS and not clone and CTXFNS[id] then
                -- (the scopes it sees: each copied, so a local declared after it is not visible to its instances)
                local snap = {}
                for i = 1, #scopes do local t = {}; for k, v in pairs(scopes[i]) do t[k] = v end; snap[i] = t end
                CTX[o] = { ctx = true, id = id, file = file, src = src, l = l, c = c, scopes = snap }
            end
            for k = 1, #fnmeta do fnmeta[k].nested = true end
            scopes[#scopes + 1] = {}
            fnbase[#fnbase + 1] = #scopes
            local meta = {}
            fnmeta[#fnmeta + 1] = meta
            local i = 0
            local nm = n:field('name')[1]
            local method = nm and txt(nm):find(':', 1, true)
            if method then i = 1; fp.params[1] = declare('self', inst and new() or port('a:' .. id .. ':1')) end
            if PTAG and method and not inst then PTAG[fp.params[1]] = { fn = id, j = 1, path = '', d = 0 } end
            local ps = n:field('parameters')[1]
            for _, x in tsutil.inext, ps or EMPTY_NODE, -1 do
                if x:named() and x:type() == 'vararg_expression' then
                    -- (`...`: every argument past the named ones, CART-1707)
                    fp.vararg = inst and new() or port('v:' .. id)
                end
                if x:named() and x:type() == 'identifier' then
                    i = i + 1
                    fp.params[i] = declare(txt(x), inst and new() or port('a:' .. id .. ':' .. i))
                    if PTAG and not inst then PTAG[fp.params[i]] = { fn = id, j = i, path = '', d = 0 } end
                end
            end
            -- (a VALUE-KEYED instance: its key parameters are the call's literals, constants inside it, CART-1729)
            if inst and clone.consts then for j, sv in pairs(clone.consts) do if fp.params[j] then G7.CONSTK[fp.params[j]] = sv end end end
            fnstack[#fnstack + 1] = fp
            local body = n:field('body')[1]
            if body then for _, s in tsutil.inamed, body, -1 do stmt(s) end end
            fnstack[#fnstack] = nil
            fnbase[#fnbase] = nil
            fnmeta[#fnmeta] = nil
            scopes[#scopes] = nil
            if not clone and not meta.upv and not meta.nested and body and #txt(n) <= CLONE_MAX then
                CLONE[o] = { file = file, id = id, src = src, l = l, c = c }
                -- (its KEY PARAMETERS — `t[p]` in its body, p never assigned in the file: a call passing a literal there
                -- binds to the instance for that value, opts.litkeys, CART-1729)
                if G7.LITKEYS then
                    local pos = {}
                    if method then pos.self = 1 end
                    local j = method and 1 or 0
                    for _, x in tsutil.inext, ps or EMPTY_NODE, -1 do
                        if x:named() and x:type() == 'identifier' then j = j + 1; pos[txt(x)] = j end
                    end
                    local kp
                    local function scan(x)
                        for _, y in tsutil.inamed, x, -1 do
                            if y:type() == 'bracket_index_expression' then
                                local k = y:field('field')[1]
                                local nm = k and k:type() == 'identifier' and txt(k)
                                if nm and pos[nm] and not G7.REASG[nm] then kp = kp or {}; kp[pos[nm]] = true end
                            end
                            if y:named_child_count() > 0 then scan(y) end
                        end
                    end
                    scan(body)
                    CLONE[o].kp = kp
                end
            end
            G7.LASTFP = fp
            return p
        end
        local function callv(n, want)
            if want and want < 2 then want = nil end
            local f = n:field('name')[1]
            local args = n:field('arguments')[1]
            local argn = {}
            for _, a in tsutil.inamed, args or EMPTY_NODE, -1 do argn[#argn + 1] = a end
            local cname = f and ((f:type() == 'method_index_expression' and f:field('method')[1])
                or (f:type() == 'dot_index_expression' and f:field('field')[1]) or (f:type() == 'identifier' and f))
            local c = f and (call_at[key_of(f) .. '#' .. (cname and txt(cname) or '')] or call_at[key_of(f)] or nil)
            local fname = f and txt(f) or ''
            -- (a CART-1707 builtin is the GLOBAL of that name: `local function load()` is the tree's own function)
            local function gbl()
                if not f or f:type() ~= 'identifier' then return false end
                local _, g = lookup(fname)
                return g
            end
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
                -- (a module the tree does not hold: what it returns is unknown, CART-1707 — unless the environment PROFILE
                -- declares it (a signature under its path: vim.treesitter, lpeg): a HOST module, whose members are what
                -- the profile says; unknown code there wiped every declared type behind it, CART-1715)
                for _, a in ipairs(argn) do expr(a) end
                local s0 = argn[1] and argn[1]:type() == 'string' and argn[1]:field('content')[1]
                local xp = new()
                if not (s0 and G7.profmod(txt(s0))) then addobj(xp, EXT) end
                return xp
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
            if fname == 'setmetatable' and argn[1] then return G7.mu(function ()
                local tp = expr(argn[1])
                if argn[2] then
                    local mtp = expr(argn[2])
                    G7.ins({ 'setmeta', tp, mtp })
                    proto(tp, field(mtp, '__index'), true)
                    storec(tp, '\1mt', mtp) -- (its handlers: __call, operators, __newindex — CART-1699)
                    MTSTORES[#MTSTORES + 1] = { tp, mtp } -- (it was never filled: a parked handler port was never released)
                    G7.GCPEND[#G7.GCPEND + 1] = { tp, gerr() } -- (a finalizer runs with the object, CART-1707: deferred)
                end
                return tp
            end) end
            -- (UNKNOWN CODE, CART-1707: what load / loadstring / loadfile / dofile return is code the tree does not hold
            -- — EXT, and calling EXT returns EXT and hands its arguments to unknown code. A require the tree cannot map
            -- falls through to the general call, whose callee is EXT below)
            if (fname == 'load' or fname == 'loadstring' or fname == 'loadfile' or fname == 'dofile') and gbl() then
                G7.gap('unknown-code', {})
                for _, a in ipairs(argn) do edge(expr(a), G7.EXTCALL) end
                local out = {}
                for k = 1, want or 1 do out[k] = new(); addobj(out[k], EXT) end
                if want then return out end
                return out[1]
            end
            -- (ENVIRONMENTS: setfenv(f, env) — f's global reads, and its nested functions', also read env: applied
            -- after the walk, when every function's reads are known (G7.FENV). setfenv(1, env) is the calling
            -- function (at the top level, the file's chunk); a deeper level is any function: env becomes a prototype of
            -- _G. getfenv returns _G and every environment set. rawget / rawset are a load and a store)
            if fname == 'getfenv' and gbl() then for _, a in ipairs(argn) do expr(a) end; G7.gap('getfenv', {}); return G7.FENVP end
            if fname == 'setfenv' and argn[2] and gbl() then
                G7.gap('setfenv', {})
                local fa, env = argn[1], expr(argn[2])
                edge(env, G7.FENVP)
                local pf = fnstack[#fnstack]
                if fa:type() ~= 'number' then
                    local fp = expr(fa)
                    G7.FENV[#G7.FENV + 1] = { port = fp, env = env }
                    return fp
                elseif txt(fa) == '1' and (pf or G7.CHUNK) then G7.FENV[#G7.FENV + 1] = { id = pf and pf.id or G7.CHUNK, env = env }
                else proto(G7.GPORT, env) end
                return new()
            end
            local function strkey(a)
                local s = a and a:type() == 'string' and a:field('content')[1]
                return s and txt(s) or '[]'
            end
            if fname == 'rawget' and argn[1] and gbl() then
                local tp = expr(argn[1]); if argn[2] then expr(argn[2]) end
                return field(tp, strkey(argn[2]), true)
            end
            if fname == 'rawset' and argn[3] and gbl() then
                local tp = expr(argn[1]); expr(argn[2])
                storec(tp, strkey(argn[2]), expr(argn[3]))
                return tp
            end
            -- (hooksecurefunc([t,] "name", hook): a call of the hooked function also runs the hook with its arguments)
            if fname == 'hooksecurefunc' and argn[2] and gbl() then
                local tp = argn[3] and expr(argn[1]) or G7.GPORT
                local kn = argn[3] and argn[2] or argn[1]
                local h = expr(argn[3] or argn[2])
                callc(field(tp, strkey(kn)), { hook = h }, new())
                return new()
            end
            -- (getmetatable(x) is the metatable setmetatable stored; newproxy(true) a userdata with a fresh one)
            if fname == 'getmetatable' and argn[1] and gbl() then return field(expr(argn[1]), '\1mt', true) end
            if fname == 'newproxy' and gbl() then
                local up = new()
                local u = newobj('proxy:' .. key_of(n))
                addobj(up, u)
                if argn[1] and txt(argn[1]) == 'true' then
                    local mp = new()
                    addobj(mp, newobj('proxymt:' .. key_of(n)))
                    storec(up, '\1mt', mp)
                    MTSTORES[#MTSTORES + 1] = { up, mp }
                    proto(up, field(mp, '__index'), true)
                    G7.GCPEND[#G7.GCPEND + 1] = { up, gerr() }
                end
                return up
            end
            -- (COROUTINES, CART-1700: create(f) is a thread holding f; resume(co, …) calls f with its arguments — and
            -- every yield returns them —, its results after the status are f's returns and every yield's values.
            -- wrap(f) is a FUNCTION of its own: a call forwards its arguments to f — the first call's are f's, every
            -- later one's every yield's results — and returns f's returns and every yield's values, CART-1707)
            if fname == 'coroutine.wrap' then return G7.mu(function ()
                local fp = argn[1] and expr(argn[1]) or new()
                G7.gap('coroutine.wrap', { fp })
                local id = 'ts:wrap:' .. key_of(n) -- (no graph node: a verdict naming it is no claim)
                local w = newobj(id)
                local wp = new()
                G7.ins({ 'new', wp, w })
                addobj(wp, w)
                local ps, rs = {}, {}
                for k = 1, MULTI do ps[k] = new(); edge(ps[k], gresarg()); rs[k] = new(); edge(gyield(), rs[k]) end
                local wfp = { params = ps, ret = rs[1], rets = rs, id = id, err = new(), vararg = new() }
                fnports[w] = wfp
                G7.gap('coroutine.wrap', rs) -- (its function's results: every yield's values, the solver's)
                callc(fp, ps, rs, nil, wfp.err)
                return wp
            end) end
            if fname == 'coroutine.create' then return G7.mu(function ()
                local fp = argn[1] and expr(argn[1]) or new()
                local tp = new()
                local th = newobj('thread:' .. key_of(n))
                G7.ins({ 'cocreate', tp, th, fp }, 'divergence:coroutine')
                addobj(tp, th)
                storec(tp, '\1co', fp)
                return tp
            end) end
            if fname == 'coroutine.resume' and argn[1] then return G7.mu(function ()
                local cp = expr(argn[1])
                local aps = {}
                for j = 2, #argn do aps[#aps + 1] = expr(argn[j]); edge(aps[#aps], gresarg()) end
                local fl, out = {}, { new() }
                for k = 1, math.max((want or 1) - 1, 1) do fl[k] = new(); out[k + 1] = fl[k]; edge(gyield(), fl[k]) end
                -- (resume CATCHES what the coroutine raises: `false, err`)
                local rerr = new()
                if G7.REC then G7.REC.rerr[#G7.REC.rerr + 1] = rerr end
                G7.ins({ 'resume', out, cp, aps }, 'divergence:coroutine')
                addobj(rerr, STR)
                edge(rerr, fl[1])
                callc(field(cp, '\1co', true), aps, fl, nil, rerr)
                if want then return out end
                return out[1]
            end) end
            if fname == 'coroutine.yield' then return G7.mu(function ()
                local ys = {}
                for j = 1, #argn do ys[j] = expr(argn[j]); edge(ys[j], gyield()) end
                local out = {}
                for k = 1, want or 1 do out[k] = new(); edge(gresarg(), out[k]) end
                G7.ins({ 'yield', out, ys })
                if want then return out end
                return out[1]
            end) end
            if (fname == 'pcall' or fname == 'xpcall') and argn[1] then return G7.mu(function ()
                local aps = {}
                for j = (fname == 'xpcall' and 3 or 2), #argn do
                    aps[#aps + 1] = expr(argn[j])
                    if j == #argn and argn[j]:type() == 'vararg_expression' then aps.spread = #aps end
                end
                -- (`local ok, v = pcall(f, …)`: v is f's FIRST value — the status comes before them)
                -- (a CAUGHT error, CART-1705: what the protected function — and everything it calls — raises, and a
                -- runtime error's message: a string. A function OUTSIDE the tree is taken to raise strings, the contract
                -- clause this rests on. xpcall hands it to its handler, whose result is the second value)
                local perr = new()
                addobj(perr, STR)
                if fname == 'xpcall' then G7.gap('xpcall-handler', {}) end
                if want then
                    local fl, out = {}, { new() }
                    for k = 1, want - 1 do fl[k] = new(); out[k + 1] = fl[k] end
                    local fv = expr(argn[1])
                    G7.ins({ 'pcall', out, fv, aps }, fname == 'xpcall' and 'divergence:xpcall' or nil)
                    callc(fv, aps, fl, nil, perr)
                    if out[2] then
                        if fname == 'xpcall' and argn[2] then
                            local hr = new()
                            callc(expr(argn[2]), { perr }, hr, nil, curerr())
                            edge(hr, out[2])
                        else edge(perr, out[2]) end
                    end
                    return out
                end
                local res = new()
                local fv = expr(argn[1])
                G7.ins({ 'pcall', { res }, fv, aps }, fname == 'xpcall' and 'divergence:xpcall' or nil)
                callc(fv, aps, res, nil, perr)
                return res
            end) end
            if fname == 'table.insert' and argn[1] then
                local tp = expr(argn[1])
                acc('array', argn[1], nil, tp)
                for j = 2, #argn do local v = expr(argn[j]); if j == #argn then storec(tp, '#', v) end end
                return new()
            end
            local recvp, callee
            -- (the roster: a dotted callee `M.show(a)` READS the field show — a resolved call never evaluates it)
            if ACC and f and f:type() == 'dot_index_expression' then acc('read', f:field('field')[1], txt(f:field('field')[1]), expr(f:field('table')[1])) end
            if f and f:type() == 'method_index_expression' then
                recvp = expr(f:field('table')[1])
                callee = field(recvp, txt(f:field('method')[1]))
                acc('method', f:field('method')[1], txt(f:field('method')[1]), recvp)
            end
            local aps = {}
            if recvp then aps[1] = recvp end
            -- (a LAST argument that is `...` SPREADS into every parameter from there and the callee's vararg; a last
            -- call passes its first MULTI values positionally, CART-1707)
            for j, a in ipairs(argn) do
                if j == #argn and a:type() == 'vararg_expression' then aps[#aps + 1] = expr(a); aps.spread = #aps
                elseif j == #argn and a:type() == 'function_call' then
                    local l = callv(a, MULTI)
                    if type(l) == 'table' then for _, r in ipairs(l) do aps[#aps + 1] = r end else aps[#aps + 1] = l end
                else aps[#aps + 1] = expr(a) end
            end
            -- (what error() / assert's message raises reaches every pcall's second result, CART-1705)
            if fname == 'error' and aps[1] then edge(aps[1], curerr()) end
            if fname == 'assert' and aps[2] then edge(aps[2], curerr()) end
            if ARGP and c and not clone then ARGP[c] = aps end
            if PTAG and not clone then
                if recvp then puse(recvp, 'recv', txt(f:field('method')[1])) end
                local to0 = c and callrec.to(c)
                for j = recvp and 2 or 1, #aps do puse(aps[j], 'arg', { to = to0, j = j }) end
            end
            -- (the array as a whole: a library function that reads or writes every position)
            if ACC and ARRAYFN[fname] and argn[1] then acc('array', argn[1], nil, aps[recvp and 2 or 1]) end
            local r = c and c.refused
            if type(r) == 'table' and r.rule == 'ambiguous' and r.cands then
                local member = f:type() == 'method_index_expression' and f:field('method')[1] or f:field('field')[1]
                local base = recvp or (f:type() == 'dot_index_expression' and expr(f:field('table')[1]))
                if base and member then probes[#probes + 1] = { c = c, recv = base, member = txt(member) } end
            end
            local to = c and G7.CTXC and G7.CTXC[c]
            -- (MULTIPLE VALUES: `want` > 1 asks for that many results — `local a, b = f()`, `return f()`, a generic
            -- for's iterator triple — the k-th result port gets the callee's k-th return)
            local res = new()
            local resl = { res }
            for k = 2, want or 1 do resl[k] = new() end
            if recvp then
                for k, r in ipairs(resl) do mflow(recvp, txt(f:field('method')[1]), r, k) end
                mcalls[#mcalls + 1] = { recvp, txt(f:field('method')[1]), resl }
            end
            if to and CTXFNS and CTXFNS[to] and not clone then
                if not callee and f then expr(f) end -- (the callee expression is still walked: a call inside it)
                ctx_direct[#ctx_direct + 1] = { to, aps, resl }
                return want and resl or res
            end
            -- ★ THE NAME JOIN IS NOT AN INPUT (CART-1689 / 1691 / 1692, the user's direction CART-1714 / 1715): a call the
            -- join resolved (c.to) took its callee from the join and skipped the callee expression's flow — an inferred
            -- unique-name edge was wrong in 218 of 2,553 observed pairs, a local defined in both branches of an if and
            -- a module field another module reassigns reached functions the claim did not name. The callee is the
            -- expression's flow, as for any call. (Not even as a HEDGE: where the flow reaches nothing, the join's pick
            -- was mostly spelling — `c:named()` on a tree-sitter node "resolved" to Band:named — and tainting what such
            -- calls are handed cost 55 of 83 whole RIGHT answers on the runtime oracle. Nor does a member of EXT become
            -- EXT — semantically right, but EXT reaches every function handed to unknown code, and through its members
            -- 427 typed / string answers went unknown: a call on unknown code's value runs nothing, THE CONTRACT)
            if f and f:type() ~= 'method_index_expression' then
                local owner, mm = fname:match('^(.+)%.([%w_]+)$')
                for k, r in ipairs(resl) do
                    local key = owner and (owner .. '#' .. mm) or fname
                    local gi = genarg(key, k)
                    if gi then if aps[gi] then edge(aps[gi], r) end
                    else
                        local rt = retk(key, k)
                        if rt then addobj(r, typeobj(rt)) end
                    end
                end
            end
            -- (CART-1708: tree code a BUILTIN runs. A function value handed to a call that is no resolved tree function
            -- may be called by it — its errors pass through to this caller. tostring runs __tostring and returns its
            -- result (5.1: any value); print and string.format run it on their arguments; table.sort compares the
            -- elements — its comparator or their __lt. (string.gsub's replacement function needs no route: its
            -- errors are the rule above, and it is handed only strings)
            for _, ap in ipairs(aps) do
                local l = ARGERR[ap]
                if not l then l = {}; ARGERR[ap] = l end
                local ce = curerr()
                l[#l + 1] = ce
                for o in each(ap) do local fpp = fnports[o]; if fpp and fpp.err then edge(fpp.err, ce) end end
            end
            if fname == 'tostring' and aps[1] then metacall(aps[1], '__tostring', { aps[1] }, res, curerr()) end
            -- (select(n, …) returns arguments past the first; unpack(t) a table's elements, CART-1707)
            if fname == 'select' and #aps >= 2 then for _, r in ipairs(resl) do for j = 2, #aps do edge(aps[j], r) end end end
            if (fname == 'unpack' or fname == 'table.unpack') and aps[1] then
                local el = field(aps[1], '[]')
                for _, r in ipairs(resl) do edge(el, r) end
            end
            if fname == 'print' or fname == 'string.format' then
                for _, ap in ipairs(aps) do metacall(ap, '__tostring', { ap }, new(), curerr()) end
            end
            if fname == 'table.sort' and aps[1] then
                local el = field(aps[1], '[]')
                if aps[2] then callc(aps[2], { el, el }, new(), nil, curerr())
                else metacall(el, '__lt', { el, el }, new(), curerr()) end
            end
            if not callee and f then callee = expr(f) end
            if G7.CALLP and c and not clone and callee then G7.CALLP[c] = callee end
            if PTAG and not clone and callee and not recvp then puse(callee, 'call') end
            if callee then
                -- (opts.dump: the call instruction this call record's ANSWER is about, CART-1725 — stamped by the recording callc)
                if G7.REC and c and not clone then G7.NEXTC = c end
                -- (the literal arguments, by position: a value-keyed instance's key, opts.litkeys)
                local vl
                if G7.LITKEYS then
                    local off = recvp and 1 or 0
                    for j, a in ipairs(argn) do
                        local sv
                        if a:type() == 'string' then local cc = a:field('content')[1]; sv = cc and txt(cc) or ''
                        elseif a:type() == 'identifier' then local p = lookup(txt(a)); sv = p and G7.CONSTK[p] end
                        if sv then vl = vl or {}; vl[j + off] = sv end
                    end
                end
                callc(callee, aps, want and resl or res, vl and { vlits = vl } or nil, curerr())
                G7.NEXTC = nil
                -- (calling a TABLE runs its metatable's __call with the table first, CART-1701)
                local ma = { callee }
                for _, ap in ipairs(aps) do ma[#ma + 1] = ap end
                local vm
                if vl then vm = {}; for j, sv in pairs(vl) do vm[j + 1] = sv end end
                metacall(callee, '__call', ma, want and resl or res, curerr(), vm and { vlits = vm } or nil)
            end
            return want and resl or res
        end
        -- an expression LIST's values: a call LAST in it supplies all the values still wanted (Lua truncates a call
        -- anywhere else to one)
        local function exprs(el, want)
            local xs = {}
            for _, x in tsutil.inamed, el or EMPTY_NODE, -1 do xs[#xs + 1] = x end
            local vals = {}
            for i, x in ipairs(xs) do
                if i == #xs and want > #xs and x:type() == 'function_call' then
                    local l = callv(x, want - #xs + 1)
                    if type(l) == 'table' then for _, r in ipairs(l) do vals[#vals + 1] = r end else vals[#vals + 1] = l end
                elseif i == #xs and want > #xs and x:type() == 'vararg_expression' then
                    local v = expr(x) -- (`local a, b = ...`: every value still wanted is a vararg)
                    for _ = i, want do vals[#vals + 1] = v end
                else vals[#vals + 1] = expr(x) end
            end
            return vals
        end
        expr = function (n)
            local t = n:type()
            if t == 'identifier' then
                local nm = txt(n)
                local p, glob = lookup(nm)
                if glob then -- (a global READ loads through _G, into the reading function's own port)
                    local gid = fnstack[#fnstack] and fnstack[#fnstack].id or G7.CHUNK
                    if not gid then return G7.gread(nm) end
                    local m = G7.GR[gid]
                    if not m then m = {}; G7.GR[gid] = m end
                    local q = m[nm]
                    if not q then q = new(); edge(G7.gread(nm), q); m[nm] = q end
                    return q
                end
                return p
            end
            if t == 'vararg_expression' then local f = fnstack[#fnstack]; return f and f.vararg or new() end
            if t == 'dot_index_expression' then
                local base = expr(n:field('table')[1])
                local fnode = n:field('field')[1] -- (each n:field() call allocates a table and a node: asked once)
                local fname_ = txt(fnode)
                local p = field(base, fname_)
                acc('read', fnode, fname_, base)
                -- ★ A PROFILE FUNCTION AS A VALUE (CART-1643): `pcall(vim.treesitter.get_string_parser, src, lang)` —
                -- 65 of lua/cartograph's tree-sitter entry points — passes the function, and a load off the global
                -- `vim` holds nothing: no parser, no tree, no node anywhere downstream. A dotted reference rooted at a
                -- GLOBAL that names a profile signature holds its function TYPE, `fun(): R1, R2`
                local ft = funtype(txt(n), n)
                if ft then addobj(p, ft) end
                return p
            end
            if t == 'bracket_index_expression' then
                local base = expr(n:field('table')[1])
                local knode = n:field('field')[1]
                if G7.KBASE then G7.KBASE[n:id()] = base end -- (a keyed copy's source, read again by assign: not walked twice)
                acc_key('read', knode, base, n)
                -- (a COMPUTED key is walked — a call in it, `t[make_key(x)]`, had gone unanalysed — and its port goes to the
                -- dump's loadDyn, CART-1739)
                local kname = keyname(knode)
                if kname == '[]' and knode then G7.NEXTK = expr(knode) end
                return field(base, kname)
            end
            if t == 'parenthesized_expression' then return expr(n:named_child(0)) end
            if t == 'string' then local p = new(); addobj(p, STR); return p end
            if t == 'function_call' then return callv(n) end
            if t == 'function_definition' then return func(n) end
            if t == 'table_constructor' then
                local p = new()
                local o = newobj('tbl:' .. key_of(n))
                addobj(p, o)
                local npos = 0
                for _, fl in tsutil.inext, n, -1 do
                    if fl:type() == 'field' then
                        local k, v = fl:field('name')[1], fl:field('value')[1]
                        if v and not k then npos = npos + 1; acc('pos', v, tostring(npos), nil, o) end
                        if v then
                            local key = (k and k:type() == 'identifier') and txt(k) or keyname(k)
                            if k and k:type() == 'identifier' then acc('key', k, key, nil, o) elseif k then acc_key('key', k, nil); if ACC and ACC[#ACC] and ACC[#ACC].sr == select(1, k:range()) then ACC[#ACC].obj = o end end
                            edge(expr(v), ofp(o, key))
                            if k then local sp = new(); addobj(sp, STR); edge(sp, ofp(o, '{k}')) end
                        end
                    end
                end
                return p
            end
            if t == 'unary_expression' then
                local op = txt(n):match('^%s*([#%-]?)')
                local x = n:named_child(0)
                local xp = x and expr(x)
                if ACC and op == '#' and x then acc('array', x, nil, xp) end
                local res = new()
                -- (`#x` runs __len, `-x` __unm, with the operand twice — CART-1702)
                if xp and (op == '#' or op == '-') then metacall(xp, op == '#' and '__len' or '__unm', { xp, xp }, res, curerr()) end
                return res
            end
            if t == 'binary_expression' then
                local op, l, r -- (one pass over the children: the operator token and both operands)
                for _, x in tsutil.inext, n, -1 do
                    if not x:named() then op = txt(x) elseif not l then l = x elseif not r then r = x end
                end
                local a, b = expr(l), expr(r)
                if op == 'or' or op == 'and' then local r = new(); edge(a, r); edge(b, r); return r end
                local res = new()
                local mm = METAOP[op]
                if mm then
                    local args = (op == '>' or op == '>=') and { b, a } or { a, b }
                    local hr = new()
                    metacall(a, mm, args, hr, curerr())
                    metacall(b, mm, args, hr, curerr())
                    if not CMPOP[op] then edge(hr, res) end -- (a comparison is a boolean whatever the handler returns)
                end
                if op == '..' then addobj(res, STR) end
                return res
            end
            for _, x in tsutil.inamed, n, -1 do expr(x) end
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
                    for _, v in tsutil.inamed, vl, -1 do
                        i = i + 1; local p = declare(txt(v)); if vals[i] then edge(vals[i], p) end
                        local ev = G7.LITKEYS and el and el:named_child(i - 1)
                        if ev and ev:type() == 'string' and v:type() == 'identifier' and not G7.REASG[txt(v)] then
                            local c = ev:field('content')[1]
                            G7.CONSTK[p] = c and txt(c) or ''
                        end
                        -- (a local DECLARED from a parameter path is that path — an upper bound: a later assignment
                        -- to it is not checked here, the census marks it)
                        if PTAG and vals[i] and PTAG[vals[i]] then local tg = PTAG[vals[i]]; PTAG[p] = { fn = tg.fn, j = tg.j, path = tg.path, d = tg.d, via = 'local' } end
                    end
                elseif a then
                    if a:type() == 'identifier' then declare(txt(a)) end
                    for _, v in tsutil.inext, a, -1 do if v:type() == 'identifier' then declare(txt(v)) end end
                end
            elseif t == 'assignment_statement' then
                local vl, el = n:named_child(0), n:named_child(1)
                G7.KBASE = {}
                local vals = exprs(el, vl:named_child_count())
                local i = 0
                for _, v in tsutil.inamed, vl, -1 do i = i + 1; if vals[i] then assign(v, vals[i], el and el:named_child(i - 1)) end end
                G7.KBASE = nil
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
                            if o and last then
                                local base = expr(o)
                                acc('write', last, txt(last), base)
                                storec(base, txt(last), fp)
                                if G7.MSELF and not clone and nm:type() == 'method_index_expression' then
                                    G7.MSELF[#G7.MSELF + 1] = { G7.LASTFP.params[1], base, G7.LASTFP.id }
                                end
                            end
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
                    if fp and PTAG and not fp.inst then puse(v, 'ret', i) end
                    if fp then
                        local r = fp.rets[i]
                        if not r then r = fp.inst and new() or port('r:' .. fp.id .. ':' .. i); fp.rets[i] = r end
                        edge(v, r)
                    elseif i == 1 and not clone then
                        edge(v, port('mod:' .. file)); modports[#modports + 1] = v
                    elseif i == 1 then clone.port = v
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
                        acc(fname == 'ipairs' and 'array' or 'iterate', a1, nil, tp)
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
                    for _, v in tsutil.inamed, vl, -1 do
                        i = i + 1
                        local p = declare(txt(v))
                        V[i] = p
                        if i == 1 and fname_ipairs then numeric[p] = true end
                        if i == 2 and vp then edge(vp, p) end
                        if i == 1 and kp then edge(kp, p) end
                    end
                    if trip and trip[1] then
                        local ctl = new()
                        if INST > 0 then NOCLONE[ctl] = true end
                        if trip[3] then edge(trip[3], ctl) end
                        if V[1] then edge(V[1], ctl) end
                        -- (the site: each loop binds a small closed iterator to an instance of its own — CLONE)
                        callc(trip[1], { trip[2] or new(), ctl }, V, ctl, curerr())
                    end
                elseif cl then
                    for _, x in tsutil.inamed, cl, -1 do
                        if x:type() == 'identifier' then
                            local p = declare(txt(x))
                            if cl:type() == 'for_numeric_clause' then numeric[p] = true end
                        else expr(x) end
                    end
                end
                for _, x in tsutil.inext, n, -1 do if x:named() and x ~= cl then stmt(x) end end
                scopes[#scopes] = nil
            elseif t == 'block' or t == 'do_statement' then
                scopes[#scopes + 1] = {}
                for _, x in tsutil.inamed, n, -1 do stmt(x) end
                scopes[#scopes] = nil
            elseif t == 'function_call' then callv(n)
            else
                for _, x in tsutil.inamed, n, -1 do
                    local xt = x:type()
                    if xt == 'block' or xt:find('statement', 1, true) then stmt(x) else expr(x) end
                end
            end
        end
        if isctx then
            -- (the instance: the function node at its own position, walked inside its definition's scopes)
            local nd = tree:named_descendant_for_range(clone.l, clone.c, clone.l, clone.c)
            while nd and not ((nd:type() == 'function_declaration' or nd:type() == 'function_definition') and select(1, nd:start()) == clone.l and select(2, nd:start()) == clone.c) do nd = nd:parent() end
            if not nd then return end
            scopes = {}
            for i, t in ipairs(clone.scopes) do scopes[i] = t end
            local p = func(nd)
            for y in each(p) do clone.obj = y end
            return
        end
        -- (the file's CHUNK is a function of its own: `setfenv(1, env)` at the top level is its environment — WoW's
        -- `setfenv(1, Prat)` had made Prat a prototype of _G for every global read in the corpus, CART-1707. Only in
        -- a file that names setfenv: a port per top-level global read cost w2 4x the load visits, 33 -> 55 s)
        local saved = G7.CHUNK
        G7.CHUNK = src:find('setfenv', 1, true) and ('chunk:' .. file) or nil
        if G7.REC then
            G7.W, G7.FNS, G7.CK = true, fnstack, 'chunk:' .. file
            local e0, c0 = expr, callv -- (an argument evaluated inside a hand-translated builtin is the program's)
            expr = function (x) local m = G7.M; G7.M = 0; local a, b = e0(x); G7.M = m; return a, b end
            callv = function (x, w) local m = G7.M; G7.M = 0; local a, b = c0(x, w); G7.M = m; return a, b end
        end
        for _, s in tsutil.inamed, tree, -1 do stmt(s) end
        G7.W = false
        G7.CHUNK = saved
    end
    local instances = {}
    clone_at = function (site, o)
        if G7.REC then return nil end -- (a dump is of the instance-free solve: an instance's ports are in no body)
        -- ★ VALUE-KEYED INSTANCES (CART-1729, opts.litkeys; flowpath FLOW-01's proposal): a call passing LITERALS at a
        -- small closed function's key parameters binds to ONE instance per distinct value, not per site — WoW w2's
        -- 1,047 `LibStub("…")` sites name 46 libraries. Inside it those parameters are constants, so `self.libs[major]`
        -- is a named access and `self.libs[major] = {}` allocates per library. A call with any key parameter not
        -- literal binds to the original, as before
        if type(site) == 'table' then
            local cl = CLONE[o]
            local kp = cl and cl.kp
            if not kp then return nil end
            local parts, consts = {}, {}
            for j in pairs(kp) do
                local sv = site.vlits[j]
                if not sv then return nil end
                consts[j] = sv
                parts[#parts + 1] = j .. '=' .. sv
            end
            table.sort(parts)
            local key = table.concat(parts, '\0')
            local per = G7.VINST[o]
            if not per then per = {}; G7.VINST[o] = per end
            local x = per[key]
            if x == nil then
                per[key] = false -- (being walked: a recursive call binds the original)
                local info = { ctx = true, id = cl.id, l = cl.l, c = cl.c, scopes = { {} }, noacc = true, consts = consts }
                INST, INSTN = INST + 1, INSTN + 1
                G7.VINSTN = G7.VINSTN + 1
                walk_file(cl.file, cl.src, info)
                INST = INST - 1
                x = info.obj or false
                per[key] = x
            end
            return x or nil
        end
        local cl = CLONE[o]
        if not cl or NOCLONE[site] then return nil end
        local per = instances[site]
        if not per then per = {}; instances[site] = per end
        local x = per[o]
        if x == nil then
            -- ★ AT THE FUNCTION'S OWN POSITIONS (CART-1688), as a context instance: its calls are the original call
            -- records, so a call's answer is the union over the original and every instance. A snippet walked under
            -- `clone:<file>` matched no record — the original's verdict read only the original's ports and answered an
            -- unsound exact (a loop's state reached only the instance). The function is CLOSED: no scope but its own
            local info = { ctx = true, id = cl.id, l = cl.l, c = cl.c, scopes = { {} }, noacc = true }
            INST, INSTN = INST + 1, INSTN + 1
            walk_file(cl.file, cl.src, info)
            INST = INST - 1
            x = info.obj or false
            per[o] = x
        end
        return x or nil
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
    -- (opts.dump: the walker's primitives RECORD — a primitive the walker calls is an instruction, what it does inside,
    -- and all the solver derives, is not: G7.M counts the depth. Installed in a function of its own: the builder is at
    -- the local limit)
    if G7.REC then (function ()
        local REC, E = G7.REC, G7.REC.errp
        for _, e in ipairs(G7.ENVL) do REC.objvar[e.GOBJ] = e.GPORT end
        local r_addobj, r_edge, r_field, r_storec, r_callc, r_metacall, r_metastore, r_proto =
            addobj, edge, field, storec, callc, metacall, metastore, proto
        local function on() return G7.W and G7.M == 0 end
        local function enter() G7.M = G7.M + 1 end
        local function leave() G7.M = G7.M - 1 end
        local function list(t) local l = {}; for i, x in ipairs(t) do l[i] = x end; return l end
        addobj = function (p, o)
            if on() and not E[p] then
                G7.ins({ 'new', p, o })
                if not REC.objvar[o] then REC.objvar[o] = p end
            end
            enter(); r_addobj(p, o); leave()
        end
        edge = function (a, b)
            if on() then
                if E[b] then if not E[a] then G7.ins({ 'error', a }) end -- (a call's port-to-port flow is its own)
                elseif E[a] then G7.gap('error-value', { a, b })
                elseif fowner[b] and fname[b] == '{k}' then -- (a key into the key set: no core field)
                elseif fowner[a] and fname[a] == '{k}' then G7.gap('table-keys', { b, a })
                elseif fowner[b] then
                    local hv = REC.objvar[fowner[b]]
                    if hv then G7.ins({ 'store', hv, fname[b], a }) else G7.gap('store-field-port', { a, b }) end
                elseif fowner[a] then
                    local hv = REC.objvar[fowner[a]]
                    if hv then G7.ins({ 'load', b, hv, fname[a] }) else G7.gap('load-field-port', { a, b }) end
                else G7.ins({ 'copy', b, a }) end
            end
            enter(); r_edge(a, b); leave()
        end
        field = function (x, f, strict)
            enter(); local dst = r_field(x, f, strict); leave()
            if on() then
                if f:byte(1) == 1 then G7.gap('hidden-load', { dst, x })
                elseif f == '{k}' then G7.ins({ 'keys', dst, x }) -- (the key set `pairs` / next yield, CART-1739)
                else
                    G7.ins({ 'load', dst, x, f, f == '[]' and G7.NEXTK or nil }, strict and f ~= '[]'
                        and (G7.ISGP[x] and 'contract:strict-global' or 'contract:strict') or nil)
                end
            end
            G7.NEXTK = nil
            return dst
        end
        storec = function (x, f, v)
            if on() and f ~= '{k}' then if f:byte(1) == 1 then G7.gap('hidden-store', { x, v }) else G7.ins({ 'store', x, f, v, f == '[]' and G7.NEXTK or nil }) end end
            G7.NEXTK = nil
            enter(); r_storec(x, f, v); leave()
        end
        callc = function (callee, args, res, site, cerr)
            if on() then
                if args.hook or args.fenv then G7.gap(args.hook and 'hooksecurefunc' or 'setfenv', { callee })
                else
                    G7.ins({ 'call', type(res) == 'table' and list(res) or { res }, callee, list(args) })
                    local k = G7.NEXTC and G7.W and G7.cur()
                    local l = k and G7.REC.fns[k]
                    if l then G7.INSAT[G7.NEXTC] = { k, #l - 1 } end
                end
            end
            enter(); r_callc(callee, args, res, site, cerr); leave()
        end
        G7.callc = callc
        -- (an operator's handler is the core's `op`; `__call`, `__index`, `__newindex` and `__gc` handlers are what a
        -- call, a load, a store and the collector already run in the core — no instruction of their own)
        local IMPLIED = { __call = true, __index = true, __newindex = true, __gc = true }
        metacall = function (x, mm, args, res, cerr)
            if on() and not IMPLIED[mm] then G7.ins({ 'op', res, list(args), mm }) end
            enter(); r_metacall(x, mm, args, res, cerr); leave()
        end
        metastore = function (base, f, kp, v, cerr) enter(); r_metastore(base, f, kp, v, cerr); leave() end
        proto = function (t, idx, lua)
            if on() then G7.gap('proto', { t, idx }) end
            enter(); r_proto(t, idx, lua); leave()
        end
    end)() end
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
    for _, fe in ipairs(G7.FENV) do
        if fe.id then G7.fenv(fe.id, fe.env) else callc(fe.port, { fenv = fe.env }, new()) end
    end
    -- (the context instances: one per resolved call site of a selected function; a site it cannot instance — the
    -- function was never walked — binds the shared ports as before)
    if CTXFNS then
        local byid = {}
        for o, fp in pairs(fnports) do if not fp.inst and fp.id and CTX[o] then byid[fp.id] = o end end
        for _, d in ipairs(ctx_direct) do
            local to, aps, resl = d[1], d[2], d[3]
            local o = byid[to]
            local info = o and setmetatable({ obj = false }, { __index = CTX[o] })
            if info then walk_file(info.file, info.src, info) end
            if info and info.obj then bindcall(info.obj, aps, #resl > 1 and resl or resl[1])
            else
                for j, ap in ipairs(aps) do edge(ap, port('a:' .. to .. ':' .. j)) end
                for k, r in ipairs(resl) do edge(port('r:' .. to .. (k > 1 and (':' .. k) or '')), r) end
            end
        end
    end
    -- (the walks are done: the solve's own reads of the current environment — a string's library for a load recorded
    -- before a second program existed — are the DEFAULT program's, never the last walked file's, CART-1737)
    if G7.ENVL[1] then G7.useenv(G7.ENVL[1]) end
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
                    for c in pairs(protos[o] or NOTHING) do if chain(c, seen) then return true end end
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
    -- ★ FINALIZERS, DEFERRED (CART-1707): each setmetatable's `\1mt.__gc` load was 29 M of w2's 39 M load visits
    -- (solve 41 -> 76 s) for a handler no WoW addon defines. A finalizer exists only where a metatable — read after the
    -- solve, when every write has landed — holds `__gc` or a field a dynamic key wrote, or its port saturated; otherwise
    -- the route stays unbuilt
    do
        local function possible()
            for _, ms in ipairs(MTSTORES) do
                local vp = ms[2]
                if top[vp] then return true end
                for x in each(vp) do
                    local m = ofield[x]
                    local d = m and m['[]']
                    if m and (m.__gc or (d and (top[d] or pts[d] ~= nil))) then return true end
                end
            end
            return false
        end
        if #G7.GCPEND > 0 and possible() then
            for _, g in ipairs(G7.GCPEND) do metacall(g[1], '__gc', { g[1] }, new(), g[2]) end
            G7.GCPEND = {}
            solve()
        end
    end
    -- ★ SELF OF A METHOD NO CALLER IN THE TREE REACHES (CART-1715, opts.selfseed — flowlinks): `function T:m` DECLARES
    -- its first parameter, and the host that calls it (an event, a lifecycle, a UI callback) hands it T or an object
    -- whose prototype chain reaches T — a WoW addon's methods take the addon object itself. Where self ended EMPTY,
    -- it holds every object prototyped by one of T's (a subclass, an instance a constructor made — with the fields it
    -- wrote) and ONE ABSTRACT INSTANCE per T object: a table whose prototype is T, standing for T itself or any object
    -- the host hands in. Never T's own object: a write through self (`target[name] = fn`, CallbackHandler embedding
    -- itself into an AceDB db whose methods were COPIED from DBObjectLib, not inherited) landed on T and made T's
    -- whole method calls sets (WoW w2: 37 confirmed links became sets, 291 calls saturated out of their set); on the
    -- instance it stays the instance's, and T's methods are read through the prototype. All of T's methods share
    -- the instance: `self.db =` in one is read in the next. HEDGED (tainted below): it is the declaration's
    -- evidence, not a flow. And where T's port ended EMPTY too — T came from a call the
    -- solve does not follow: a library factory (`LibStub:NewLibrary`, `addon:NewModule`), a host API (`CreateFrame`) —
    -- the declaration is still evidence: storing `m` into T succeeded, so a program that got past it had a TABLE there.
    -- T's port gets ONE stand-in table (every `function T:x` on that port shares it: the stores land on it, self holds
    -- it), tainted like self (WoW w2: 2,111 of 3,610 empty selfs had an empty T). One batch, decided on the solved
    -- state, then one solve: a method whose self the seed reaches through `self:n()` is not seeded again
    G7.SSEED = {} -- (G7: the builder's 200-local limit)
    if G7.MSELF then
        local SS = { methods = #G7.MSELF, empty = 0, seeded = 0, nobase = 0, standin = 0 }
        local STAND, AI, AIP = {}, {}, {}
        G7.SSTAT = SS
        local heirs
        local function heirsof(c)
            if not heirs then
                heirs = {}
                for o, pr in pairs(protos) do for x in pairs(pr) do local l = heirs[x]; if not l then l = {}; heirs[x] = l end; l[#l + 1] = o end end
            end
            local ai = AI[c]
            if not ai then ai = newobj('self<' .. tostring(okey(c)) .. '>'); AI[c] = ai; AIP[#AIP + 1] = { ai, c } end
            local out, seen, q = { ai }, { [c] = true }, { c }
            local i = 1
            while i <= #q do
                local x = q[i]; i = i + 1
                if x ~= c then out[#out + 1] = x end
                for _, o in ipairs(heirs[x] or NOTHING) do if not seen[o] then seen[o] = true; q[#q + 1] = o end end
            end
            return out
        end
        local plan = {}
        for _, ms in ipairs(G7.MSELF) do
            local sp, bp = ms[1], ms[2]
            if sp and pts[sp] == nil and not top[sp] then
                SS.empty = SS.empty + 1
                local objs = {}
                if not top[bp] then for c in each(bp) do if not fnports[c] and c ~= EXT then for _, x in ipairs(heirsof(c)) do objs[#objs + 1] = x end end end end
                if #objs == 0 and not top[bp] and pts[bp] == nil then
                    local so = STAND[bp]
                    if not so then
                        so = newobj('decl<' .. tostring(ms[3]) .. '>')
                        STAND[bp] = so
                        SS.standin = SS.standin + 1
                        plan[#plan + 1] = { bp, { so } }
                    end
                    for _, x in ipairs(heirsof(so)) do objs[#objs + 1] = x end
                end
                if #objs == 0 then SS.nobase = SS.nobase + 1 else plan[#plan + 1] = { sp, objs } end
            end
        end
        for _, x in ipairs(AIP) do objproto(x[1], x[2]) end
        for _, pl in ipairs(plan) do
            G7.SSEED[pl[1]] = true
            SS.seeded = SS.seeded + 1
            for _, o in ipairs(pl[2]) do addobj(pl[1], o) end
        end
        if #plan > 0 then solve() end
    end
    -- ★ A STRING METHOD ON AN EMPTY RECEIVER (CART-1643): `name:lower()`, `raw:sub(i)` — the receiver reached no value
    -- the solve holds, but a program that got past the call had a string there (a table would need the member; none
    -- arrived), so the result is what the string library returns. Only where the receiver ended EMPTY — a user table
    -- with its own `find` keeps its own answer — and HEDGED (tainted below): it is the call's evidence, not a flow.
    -- Rounds, because a typed result can feed the next call's receiver
    local sinf = {}
    for _ = 1, 4 do
        local grew = false
        for _, mc in ipairs(mcalls) do
            local recvp, m, resl = mc[1], mc[2], mc[3]
            if pts[recvp] == nil and not top[recvp] and PSIGS['string#' .. m] then
                for k, r in ipairs(resl) do
                    local rt = retk('string#' .. m, k)
                    if rt and not sinf[r] then sinf[r] = true; addobj(r, typeobj(rt)); grew = true end
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
        -- ★ O2 / C1 (CART-1685, the user's decision 2026-10-15): outside code may WRITE THE DATA FIELDS of what it can
        -- reach from the exports — a config, a cache, a registry, an object stored on the module — so what is read
        -- through one is PARTIAL (seeded in the taint phase, propagated through loads like any taint: `M.config.item:m()`
        -- is exact~); it does NOT replace FUNCTION members (C1, a contract, default on): a field holding a function, or a
        -- name the prototype chain supplies a method for. Answers read through a reachable receiver carry C1 (the
        -- verdicts). A metatable's fields are not data (C3). The strict reading — every reachable member writable —
        -- left 179 of 3,182 whole open answers
        G7.REACH = {}
        do
            local q, R = {}, G7.REACH
            local function reach(o) if not R[o] and o ~= EXT and not G7.ISG[o] and not TNAME[o] then R[o] = true; q[#q + 1] = o end end
            for _, mp in ipairs(modports) do for o in each(mp) do reach(o) end end
            local i = 1
            while i <= #q do
                local o = q[i]; i = i + 1
                for _, fp in pairs(ofield[o] or NOTHING) do for x in each(fp) do reach(x) end end
                for c in pairs(protos[o] or NOTHING) do reach(c) end
                local fpp = fnports[o]
                if fpp then for _, r in pairs(fpp.rets or { fpp.ret }) do for x in each(r) do reach(x) end end end
            end
        end
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
    -- (out of fuel: the queued ports' pending objects ESCAPE — the solve no longer follows them — before the escape
    -- closure below; the ports seed the taint with the saturated ones)
    local UNFIN = {}
    if OUT then
        for p in pairs(inwl) do
            UNFIN[#UNFIN + 1] = p
            local d = delta[p]
            local function esc1(o) if not escaped[o] then escaped[o] = true; if ESCAT then ESCAT[o] = ESCAT[o] or p end end end
            if type(d) == 'number' then esc1(d) elseif d and d.bs then for o in bs_iter(d) do esc1(o) end
            elseif d then for _, o in ipairs(d) do esc1(o) end end
        end
        table.sort(UNFIN)
    end
    -- ★ WHAT UNKNOWN CODE IS HANDED ESCAPES (CART-1707): load's chunk, a module outside the tree may write any field of
    -- it, set its metatable, keep it — closed over its fields and prototypes. Its field reads are tainted below, and
    -- it is prototype-incomplete; a function among them is called with EXT (G7.EXTCALL's call)
    local XESC = {}
    do
        local q = {}
        local function skip(x) return x == EXT or G7.ISG[x] end -- (_G: every code reaches it, the contract)
        for o in each(G7.EXTCALL) do if not skip(o) and not XESC[o] then XESC[o] = true; q[#q + 1] = o end end
        local i = 1
        while i <= #q do
            local o = q[i]; i = i + 1
            if not escaped[o] then escaped[o] = true; if ESCAT then ESCAT[o] = ESCAT[o] or G7.EXTCALL end end
            for _, fp in pairs(ofield[o] or NOTHING) do for x in each(fp) do if not skip(x) and not XESC[x] then XESC[x] = true; q[#q + 1] = x end end end
            for c in pairs(protos[o] or NOTHING) do if not skip(c) and not XESC[c] then XESC[c] = true; q[#q + 1] = c end end
        end
    end
    local tainted, twork = {}, {}
    local PINC = {} -- (object -> the tainted __index source port that leaves its prototypes incomplete, CART-1709)
    -- (opts.explain: what tainted each port — the port it flowed from, `{ port, why }` for a rule that jumps, or a
    -- seed's reason — so a partial answer can be walked back to its seed: R.taint_path)
    local TFROM = (opts.explain or opts.dump) and {} or nil
    local TCUR
    local function taint(p)
        if p and not tainted[p] then tainted[p] = true; twork[#twork + 1] = p; if TFROM then TFROM[p] = TCUR end end
    end
    local gf_of = {}
    for _, gf in ipairs(gfilters) do local l = gf_of[gf[1]] or {}; gf_of[gf[1]] = l; l[#l + 1] = gf[2] end
    -- (an escaped object's fields and prototypes escaped WITH it: the solve no longer follows it, so a load through a
    -- tainted base misses what its fields hold — a method of its metatable — and a call through that load binds none of
    -- them. Closed transitively)
    local esc = {}
    -- (the GLOBALS TABLE never escapes — the contract: a global is written by name, and every code reaches _G anyway.
    -- WoW passes _G as a value: one saturated parameter made every addon's namespace, its fields, escape, and each
    -- store of `.f` anywhere tainted every namespace's f — w3: 317 whole exact answers partial, CART-1707)
    for o in pairs(G7.ISG) do escaped[o] = nil end
    for o in pairs(escaped) do esc[#esc + 1] = o end
    do
        local i = 1
        while i <= #esc do
            local o = esc[i]; i = i + 1
            for _, fp in pairs(ofield[o] or NOTHING) do
                for x in each(fp) do if not escaped[x] and not G7.ISG[x] then escaped[x] = true; esc[#esc + 1] = x; if ESCAT then ESCAT[x] = { o } end end end
            end
            for c in pairs(protos[o] or NOTHING) do if not escaped[c] and not G7.ISG[c] then escaped[c] = true; esc[#esc + 1] = c; if ESCAT then ESCAT[c] = { o } end end end
        end
    end
    local field_hit, params_hit = {}, false
    local loadf, fhit = nil, {} -- (a load's result port -> its field name; the field names whose functions are tainted)
    -- (field name -> the ports of that field over every escaped object, built on the first store that needs it: each
    -- new field had scanned the whole escaped list — fields x escaped objects, half of build1)
    local escf
    -- ★ A FIELD THE SOLVE MAY HAVE WRITTEN UNSEEN ON EVERY ESCAPED OBJECT (a store of .f through a tainted base, a keyed
    -- copy into a lost target): its PORTS there — a named load made its port when it registered, and a tainted port
    -- taints its readers — and, once any field is hit, every DYNAMIC load of an escaped object: one WITHOUT the field
    -- had no port to taint, so `pairs(H)` over it read nothing, whole (CART-1732). G7.escreaders: o's dynamic loads,
    -- for an object escaping after that
    function G7.escreaders(o)
        if not G7.DYNHIT then return end
        local l = rd[o] and rd[o]['[]']
        if l then for dst in pairs(l) do taint(dst) end end
    end
    -- (a function's parameters AND its vararg port: a lost call's arguments past the named parameters land in `...`,
    -- CART-1738 — 35 of vimruntime's 2,152 escaped functions kept `...` whole)
    function G7.tparams(fpp)
        for _, pp in ipairs(fpp.params) do taint(pp) end
        if fpp.vararg then taint(fpp.vararg) end
    end
    function G7.fieldhit(f)
        if field_hit[f] then return end
        field_hit[f] = true
        if not escf then
            escf = {}
            for _, o in ipairs(esc) do
                for fk, fp in pairs(ofield[o] or NOTHING) do
                    local l = escf[fk]
                    if not l then l = {}; escf[fk] = l end
                    l[#l + 1] = fp
                end
            end
        end
        for _, fp in ipairs(escf[f] or NOTHING) do taint(fp) end
        if f:byte(1) ~= 1 and not G7.DYNHIT then G7.DYNHIT = true; for _, o in ipairs(esc) do G7.escreaders(o) end end
    end
    -- (an object that escapes DURING the taint — a lost call's argument — with its fields and prototypes, the rules
    -- that already fired applied to it: a store of .f through a tainted base, a call reaching any escaped function)
    function G7.escmore(o0)
        if escaped[o0] or o0 == EXT or G7.ISG[o0] then return end
        local q, i = { o0 }, 1
        escaped[o0] = true
        while i <= #q do
            local o = q[i]; i = i + 1
            esc[#esc + 1] = o
            G7.escreaders(o)
            for fk, fp in pairs(ofield[o] or NOTHING) do
                if escf then local l = escf[fk]; if not l then l = {}; escf[fk] = l end; l[#l + 1] = fp end
                if field_hit[fk] then taint(fp) end
                for x in each(fp) do if not escaped[x] and x ~= EXT and not G7.ISG[x] then escaped[x] = true; q[#q + 1] = x end end
            end
            for c in pairs(protos[o] or NOTHING) do if not escaped[c] and not G7.ISG[c] then escaped[c] = true; q[#q + 1] = c end end
            local fpp = fnports[o]
            if fpp and params_hit then G7.tparams(fpp) end
        end
    end
    TCUR = 'fuel: the solve stopped with this port unfinished'
    for _, p in ipairs(UNFIN) do taint(p) end
    -- (a guarded flow's chain test ran over prototypes the cut may have left incomplete)
    if OUT then for _, gf in ipairs(gfilters) do taint(gf[2]) end end
    TCUR = 'saturated (past CAP)'
    for p in pairs(top) do taint(p) end
    TCUR = 'sinf'
    for r in pairs(sinf) do taint(r) end
    TCUR = 'self seeded from its method declaration: the host may call it with another object'
    for r in pairs(G7.SSEED) do taint(r) end
    TCUR = 'handed to unknown code (load, a module outside the tree): it may write any field'
    for o in pairs(XESC) do
        PINC[o] = PINC[o] or G7.EXTCALL
        for _, fp in pairs(ofield[o] or NOTHING) do taint(fp) end
        for f, l in pairs(rd[o] or NOTHING) do if f ~= NS then for dst in pairs(l) do taint(dst) end end end
    end
    TCUR = 'O2: a data field of what outside code reaches from the exports — it may write it (open mode, CART-1685)'
    if open and G7.REACH then
        local function protofn(o, f, seen)
            for c in pairs(protos[o] or NOTHING) do
                if not seen[c] then
                    seen[c] = true
                    local fp = ofield[c] and ofield[c][f]
                    if fp then for y in each(fp) do if fnports[y] then return true end end end
                    if protofn(c, f, seen) then return true end
                end
            end
            return false
        end
        -- (a METATABLE's fields are structure, not data: outside code does not set metatables or their handlers — C3,
        -- default on, RESEARCH.md §17.2)
        local MT = {}
        for o in pairs(G7.REACH) do
            local mp = ofield[o] and ofield[o]['\1mt']
            if mp then for x in each(mp) do MT[x] = true end end
        end
        for o in pairs(G7.REACH) do
            if not fnports[o] and not MT[o] then
                -- (every name read from it has a field port — a load made it — so a key the tree never wrote is covered too)
                for f, fp in pairs(ofield[o] or NOTHING) do
                    if f:byte(1) ~= 1 and f ~= '{k}' and f ~= '[]' then
                        local fn = false
                        for x in each(fp) do if fnports[x] then fn = true; break end end
                        if not (fn or protofn(o, f, {})) then taint(fp) end
                    end
                end
            end
        end
    end
    TCUR = 'open: reachable from an export, an outside caller may fill it'
    -- ★ OPEN REACHES PAST THE EXPORTS (CART-1652): a caller outside the tree gets more than the module's functions —
    -- what they RETURN, and those objects' fields and methods — and calls those methods with objects it got the same
    -- way: `M.b():go()` runs A:go with a B instance the tree never builds, where the tree only calls `M.a():go()`.
    -- Every function reachable from the exports that way has parameters an outside caller may fill: tainted
    if open then
        local seen, q = {}, {}
        local function reach(o) if not seen[o] then seen[o] = true; q[#q + 1] = o end end
        for _, mp in ipairs(modports) do for o in each(mp) do reach(o) end end
        local i = 1
        while i <= #q do
            local o = q[i]; i = i + 1
            for _, fp in pairs(ofield[o] or NOTHING) do for x in each(fp) do reach(x) end end
            for c in pairs(protos[o] or NOTHING) do reach(c) end
            local fpp = fnports[o]
            if fpp then
                G7.tparams(fpp)
                for _, r in pairs(fpp.rets or { fpp.ret }) do for x in each(r) do reach(x) end end
            end
        end
    end
    -- ★ A HANDLER PORT IS MISSING NOTHING WHERE NO METATABLE CAN HOLD THE HANDLER (CART-1699): the metamethod routes
    -- load `x.\1mt.__add` off every operand — a tainted operand taints the load, and the call through it would taint
    -- its results: every `a .. b` on a hedged string went partial (typed RIGHT 122 -> 16 on the runtime oracle). A
    -- handler can only sit in a METATABLE (an object setmetatable stored); while no metatable's field under that name
    -- or a dynamic key holds anything, and no metatable port or field is saturated or tainted, the handler port cannot
    -- have lost a function: its calls and stores are PARKED. After the loop drains, a name that became possible
    -- releases its ports and the loop runs again — possibility only grows. (The metatables were never RECORDED until
    -- CART-1707: no name was ever possible, no parked port was released — a cap-cut metatable answered a whole exact.
    -- Recording them: 72 whole exact answers partial on the runtime-oracle tree, 0 wrong either way)
    local ALLOW, METAPEND = {}, {}
    local function meta_possible(mm)
        for _, ms in ipairs(MTSTORES) do
            local vp = ms[2]
            if top[vp] or tainted[vp] then return true end
            for x in each(vp) do
                local m = ofield[x]
                for _, k in ipairs({ mm, '[]' }) do
                    local fp = m and m[k]
                    if fp and (top[fp] or tainted[fp] or pts[fp] ~= nil) then return true end
                end
            end
        end
        return false
    end
    ::drain::
    while #twork > 0 do
        local p = twork[#twork]; twork[#twork] = nil
        TCUR = p
        for q in sit(succ[p]) do taint(q) end
        if fowner[p] then readers(fowner[p], fname[p], taint) end
        for _, ld in ipairs(loads[p] or NOTHING) do taint(ld[2]) end
        local mm = METAH[p]
        if mm and not ALLOW[mm] then
            local l = METAPEND[mm]
            if not l then l = {}; METAPEND[mm] = l end
            l[#l + 1] = p
            goto parked
        end
        for _, st in ipairs(stores[p] or NOTHING) do
            local f = st[1]
            if not field_hit[f] then
                if TFROM then TCUR = { p, 'a store of .' .. tostring(f) .. ' through it reaches that field of EVERY escaped object' } end
                G7.fieldhit(f)
                TCUR = p
            end
            -- (and what it stores ESCAPES: written into an object the solve no longer follows, it may be read — and a
            -- function called — wherever that object goes. `t.f = g` through a saturated t left g's parameters whole, and a
            -- call through a tainted H.f that ran g answered a whole exact, CART-1732)
            for o in each(st[2]) do G7.escmore(o) end
        end
        -- (a KEYED COPY through a port the solve lost objects of: a lost TARGET may have received every field the source
        -- holds — the store rule, per field; a lost SOURCE may have held anything under any key, CART-1726)
        for _, r in ipairs(G7.COPY[p] or NOTHING) do
            if p == r[1] then
                for s0 in each(r[2]) do
                    -- (what the copy writes escapes with its target, as a store's value does — CART-1732)
                    for f, fp in pairs(ofield[s0] or NOTHING) do if f:byte(1) ~= 1 then for o in each(fp) do G7.escmore(o) end end end
                    for f in pairs(G7.copykeys(s0)) do
                        if f:byte(1) ~= 1 and not field_hit[f] then
                            if TFROM then TCUR = { p, 'a keyed copy of .' .. tostring(f) .. ' into it reaches that field of EVERY escaped object' } end
                            G7.fieldhit(f)
                            TCUR = p
                        end
                    end
                end
            end
            if p == r[2] then for o in each(r[1]) do taint(ofp(o, '[]')) end end
        end
        -- ★ A CALL THROUGH A TAINTED LOAD OF `.f` MAY REACH ANY FUNCTION STORED AS `.f` (CART-1696): the load's base was
        -- cut short, so the method it would have read need not be ESCAPED — a class method sitting in its prototype's
        -- field never reaches a saturated port when the instances that would read it were dropped upstream. arktype:
        -- CompiledFunction.return's `this` held 3 objects untainted at CAP 64, the answer through it a WHOLE exact that
        -- CAP 256 widened to a set. Every function held under that field name, anywhere, has its parameters tainted
        if calls[p] then
            if not loadf then
                loadf = {}
                for _, l in pairs(loads) do for _, ld in ipairs(l) do loadf[ld[2]] = ld[1] end end
            end
            local f = loadf[p]
            if f and not fhit[f] then
                fhit[f] = true
                if TFROM then TCUR = { p, 'a call through it may reach any function stored as .' .. tostring(f) .. ': their parameters' } end
                -- (field name -> the functions held under it, built once: the solve is done, the sets are final. The
                -- scan of every object's fields per name hit was the taint phase's top line, ~19 s on WoW w2)
                if not G7.FNF then
                    G7.FNF = {}
                    for _, m in pairs(ofield) do
                        for fk, fp in pairs(m) do
                            if not top[fp] then
                                for x in each(fp) do
                                    if fnports[x] then local l = G7.FNF[fk]; if not l then l = {}; G7.FNF[fk] = l end; l[#l + 1] = x end
                                end
                            end
                        end
                    end
                end
                local function hit(l) for _, x in ipairs(l) do G7.tparams(fnports[x]) end end
                if f == '[]' then for _, l in pairs(G7.FNF) do hit(l) end
                elseif G7.FNF[f] then hit(G7.FNF[f]) end
                TCUR = p
            end
        end
        if calls[p] and not params_hit then
            params_hit = true
            if TFROM then TCUR = { p, 'a call through it may reach ANY escaped function: their parameters' } end
            for _, o in ipairs(esc) do local fpp = fnports[o]; if fpp then G7.tparams(fpp) end end
            TCUR = p
        end
        for _, cl in ipairs(calls[p] or NOTHING) do
            -- (a call the solve lost HANDS ITS ARGUMENTS to whatever it may reach — any escaped function, whose stores
            -- reach escaped objects: the arguments escape too. A call bound during the solve, not at the walk, is cut
            -- before it binds: `put(y)` through a callee port left queued never wrote y's table, CART-1706 / 1715)
            if TFROM then TCUR = { p, 'a call through it hands its arguments to whatever it may reach: they escape' } end
            for _, ap in ipairs(cl[1]) do for o in each(ap) do G7.escmore(o) end end
            TCUR = p
            -- (a hooked name the solve lost: the hook misses those functions' arguments)
            if cl[1].hook then for o in each(cl[1].hook) do local fpp = fnports[o]; if fpp then G7.tparams(fpp) end end end
            if type(cl[2]) == 'table' then for _, r in ipairs(cl[2]) do taint(r) end else taint(cl[2]) end
            if cl[4] then taint(cl[4]) end -- (a callee the solve lost may raise anything)
        end
        for _, ce in ipairs(ARGERR[p] or NOTHING) do taint(ce) end -- (a callback the solve lost may raise anything)
        for _, fl in ipairs(filters[p] or NOTHING) do taint(fl[1]) end
        for _, d in ipairs(gf_of[p] or NOTHING) do taint(d) end
        for _, mf in ipairs(mflows[p] or NOTHING) do taint(mf[2]) end
        for _, t in ipairs(protos_rev[p] or NOTHING) do
            -- (its __index SOURCE is incomplete, so o's prototype chain may be: o is PROTOTYPE-INCOMPLETE — the
            -- verdict walks protos[o] directly, CART-1709)
            for o in each(t) do
                PINC[o] = PINC[o] or p
                for f, l in pairs(rd[o] or NOTHING) do if f ~= NS then for dst in pairs(l) do taint(dst) end end end
            end
        end
        ::parked::
    end
    do -- (release the handler names that became possible, and drain again)
        local released = false
        for nm, ports in pairs(METAPEND) do
            if not ALLOW[nm] and meta_possible(nm) then
                ALLOW[nm] = true; released = true
                for _, q in ipairs(ports) do twork[#twork + 1] = q end
            end
        end
        if released then goto drain end
    end
    local partial_hit -- (set by targets: a field port it read was tainted)
    -- ── the verdicts ────────────────────────────────────────────────────────────────────────────────
    local verdicts = {}
    local stats = { probes = #probes, exact = 0, narrowed = 0, string = 0, typed = 0, unknown = 0, none = 0, same = 0, loadvisits = LOADV, instances = INSTN, fuel_cut = OUT and #UNFIN or nil,
        files = #files, ports = N, objects = NO }
    stats.vinstances = G7.VINSTN
    local function targets(o, m, out, seen)
        if seen[o] then return false end
        seen[o] = true
        local p = ofield[o] and ofield[o][m]
        if p and tainted[p] then partial_hit = partial_hit or p end
        if PINC[o] then partial_hit = partial_hit or PINC[o] end -- (a prototype it may lack holds m too)
        if p and top[p] then return true end
        if p then for x in each(p) do out[x] = true end end
        local t = false
        for c in pairs(protos[o] or NOTHING) do t = targets(c, m, out, seen) or t end
        return t
    end
    -- (does o — or its prototype chain — hold functions under a key the walk could not name, `t[k] = f`? A computed-key
    -- port the solve lost values of may hold one too: the answer is partial)
    local function dynfn(o, seen)
        if seen[o] then return false end
        seen[o] = true
        local p = ofield[o] and ofield[o]['[]']
        if p and tainted[p] then partial_hit = partial_hit or p end
        if p then for x in each(p) do if fnports[x] or x == EXT then return true end end end
        for c in pairs(protos[o] or NOTHING) do if dynfn(c, seen) then return true end end
        return false
    end
    stats.partial = 0
    -- (one answer per CALL: a call walked in several context instances has a receiver in each — its answer is over all)
    local groups, gorder = {}, {}
    for _, pr in ipairs(probes) do
        local g = groups[pr.c]
        if not g then g = { pr = pr, recvs = {} }; groups[pr.c] = g; gorder[#gorder + 1] = g end
        g.recvs[#g.recvs + 1] = pr.recv
    end
    stats.probes = #gorder
    for _, g in ipairs(gorder) do
        local pr = g.pr
        local kind, v
        partial_hit = false
        local anyunk, anyobj = false, false
        for _, r in ipairs(g.recvs) do
            if tainted[r] then partial_hit = partial_hit or r end
            if top[r] or has(r, EXT) then anyunk = true end
            if pts[r] ~= nil then anyobj = true end
        end
        if anyunk then kind = 'unknown'
        elseif not anyobj then kind = 'none'
        else
            local out, sat, tyname, other = {}, false, nil, false
            local recvobjs = {}
            for _, r in ipairs(g.recvs) do for o in each(r) do recvobjs[#recvobjs + 1] = o end end
            for _, o in ipairs(recvobjs) do
                local tn = TNAME[o]
                if tn then
                    -- (a STRING is the receiver only for a string-library member: `("x"):finish()` indexes nil and raises — the
                    -- program that got past the call did not hold a string there, CART-1690. pcall's error values,
                    -- strings and error tables, reach every `local ok, v = pcall(…)`'s v: this keeps them off v:parse())
                    if PSIGS[tn .. '#' .. pr.member] then tyname = tn end
                else
                    local mine = {}
                    if targets(o, pr.member, mine, {}) then sat = true end
                    -- (it may hold the member under a key the walk could not name — a function stored by a COMPUTED key, on it
                    -- or a prototype: no claim. Also where it has the member BY NAME: `M[op] = D[op]` overrides M.generalize
                    -- when op is 'generalize', and a named load reads those stores too — 394 exact answers on the repo read
                    -- only the named field, 101 wrong at runtime, CART-1726)
                    if dynfn(o, {}) then sat = true
                    elseif not next(mine) and escaped[o] then
                        -- (it may have gained the member where the solve no longer follows it)
                        partial_hit = true
                    end
                    if next(mine) then
                        other = true
                        for x in pairs(mine) do out[x] = true end
                    end
                    -- ★ AN OBJECT WITHOUT THE MEMBER IS NOT THIS CALL'S RECEIVER (CART-1643): `x:find()` on it would
                    -- raise, so a program that gets past the call did not hold it there. The exact answer always
                    -- read the call that way (only the objects that HAVE the member give targets); a string beside
                    -- such tables read `none`, and 275 of lua/cartograph's 566 non-empty `none` receivers were that
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
                -- (the answer is the FLOW's set, whatever the name join listed — a function the join never listed is still
                -- an answer, at.lua's C.sl. The set's kind was decided against the join's candidates: `narrowed` only
                -- inside them, else `same`, no answer — so {core M.lit, derive-accept's A[op]} said nothing, CART-1734)
                kind = #fns == 1 and 'exact' or 'narrowed'
                v = { kind = kind, targets = fns }
            end
        end
        stats[kind] = (stats[kind] or 0) + 1
        -- (the contracts an open answer rests on, CART-1685: C1 — read through a receiver outside code can reach, whose
        -- function members it does not replace; C2 — the string library and the host's methods are not patched)
        if v and open and G7.REACH then
            local cs = {}
            if v.kind == 'string' or v.kind == 'typed' then cs[#cs + 1] = 'C2' end
            for _, r in ipairs(g.recvs) do
                local hit = false
                for o in each(r) do if G7.REACH[o] then hit = true; break end end
                if hit then cs[#cs + 1] = 'C1'; break end
            end
            if #cs > 0 then v.contracts = cs end
        end
        if v and partial_hit then
            v.partial = true; stats.partial = stats.partial + 1
            if TFROM and type(partial_hit) == 'number' then v.ptport = partial_hit end -- (the tainted port it read)
        end
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
                    for c in pairs(protos[o] or NOTHING) do if chain(c, seen) then return true end end
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
        -- (how many objects the receiver held: a `none` over an EMPTY receiver and one over objects without the member
        -- are different gaps — CART-1678)
        local nobj = 0
        if not top[pr.recv] then for _ in each(pr.recv) do nobj = nobj + 1 end end
        probe_out[#probe_out + 1] = { file = pr.file, line = pr.line, col = pr.col, member = pr.member, kind = kind, targets = fns,
            guarded = pr.guard ~= nil, partial = partial_hit and true or nil, nobj = nobj, c = pr.c }
    end
    stats.ms = (vim.uv.hrtime() - t0) / 1e6
    local R = { verdict = function (c) return verdicts[c] end, stats = stats, probes = probe_out, selfseed = G7.SSTAT }
    if TFROM then
        -- (a partial verdict's v.ptport walked back to its SEED: { label… }, the last a reason)
        local named_of = {}
        for k, q in pairs(named) do named_of[q] = k end
        local function label(q)
            if named_of[q] then return tostring(named_of[q]) end
            if fowner[q] then return 'field ' .. tostring(obinfo[fowner[q]] or fowner[q]) .. '.' .. tostring(fname[q]) end
            local fp = nil
            for o, f in pairs(fnports) do
                for i, pp in ipairs(f.params or NOTHING) do if pp == q then fp = 'param ' .. i .. ' of ' .. tostring(obinfo[o] or o) end end
                if fp then break end
            end
            return fp or ('port ' .. tostring(q))
        end
        -- (how an object escaped: { object label, …, the saturated port's label }, following carriers)
        R.escape_of = function (o)
            local out, seen = {}, {}
            while o and not seen[o] do
                seen[o] = true
                out[#out + 1] = tostring(obinfo[o] or o)
                local w = ESCAT and ESCAT[o]
                if type(w) == 'table' then out[#out + 1] = '<- a field / prototype of'; o = w[1]
                else out[#out + 1] = '<- reached ' .. (w and label(w) or '?') .. (w and top[w] and ' [saturated]' or ''); R._escport = w; break end
            end
            return out
        end
        -- (what a saturated port held when it saturated — with opts.keepsat — by object label)
        R.sat_objs = function (p)
            local out = {}
            for _, o in ipairs(SATSNAP[p] or NOTHING) do out[#out + 1] = tostring(obinfo[o] or o) end
            table.sort(out)
            return out
        end
        R.label = label
        R.port = function (key) return named[key] end
        -- (the field port `f` of the object labelled `key`)
        R.field_port = function (o, f) return ofield[o] and ofield[o][f] end
        R.is_top = function (p) return top[p] == true end
        R.objs_of = function (p)
            local out = {}
            if top[p] then for _, o in ipairs(SATSNAP[p] or NOTHING) do out[#out + 1] = tostring(obinfo[o] or o) end
            else for o in each(p) do out[#out + 1] = tostring(obinfo[o] or o) end end
            return out
        end
        -- (the object whose obinfo key is `key`)
        R.object = function (key) for o, k in pairs(obinfo) do if k == key then return o end end end
        R.taint_path = function (p)
            local out, seen = {}, {}
            while p and not seen[p] do
                seen[p] = true
                out[#out + 1] = label(p) .. (top[p] and ' [saturated]' or '')
                local w = TFROM[p]
                if type(w) == 'string' then out[#out + 1] = '<- ' .. w; break
                elseif type(w) == 'table' then out[#out + 1] = '<- ' .. w[2]; p = w[1]
                else p = w end
            end
            return out
        end
    end
    -- (the allocation sites reaching argument i of call c -> { obinfo key… } | nil, why: a saturated or partial port,
    -- an external value, no port — never a short list read as the whole)
    if ARGP then
        R.arg_objs = function (c, i)
            local ap = ARGP[c] and ARGP[c][i]
            if not ap then return nil, 'no port' end
            if top[ap] then return nil, 'saturated' end
            if tainted[ap] then return nil, 'partial' end
            local out, ids = {}, {}
            for o in each(ap) do
                if o == EXT then return nil, 'external' end
                out[#out + 1] = tostring(obinfo[o] or o); ids[#ids + 1] = o
            end
            return out, ids
        end
        -- (MODULE STATE: every object reachable through fields from a module ROOT — a file's top-scope locals, a
        -- global, a module's returned value. An object it reaches outlives the call that made it: a write into it is
        -- a write of state. -> { [object] = true }, computed once)
        -- (WHERE SATURATION LIVES: every saturated port by its role — a function's parameter (`a:`) or return (`r:`)
        -- port, the call boundary a per-call summary would not merge; a global / module port; a FIELD of an object in
        -- module state or of one outside it; any other (a local, a temporary). -> { [role] = count }, total)
        R.param_paths = function () return PUSES or {}, PTAG or {} end
        R.top_census = function (only) -- (only: a set of ports — R.top_origins — instead of every saturated one)
            local role, n = {}, 0
            local fieldof = {}
            for o, m in pairs(ofield) do for _, fp in pairs(m) do fieldof[fp] = o end end
            local named_of = {}
            for key, p in pairs(named) do named_of[p] = key end
            local st = R.state_objs()
            for p in pairs(only or top) do
                n = n + 1
                local key, o = named_of[p], fieldof[p]
                local r = key and (key:match('^a:') and 'param' or key:match('^r:') and 'return' or (key:match('^g:') or key:match('^mod:')) and 'global / module' or 'named other')
                    or (o and (st[o] and 'field of module state' or 'field of a non-state object')) or 'local / temporary'
                role[r] = (role[r] or 0) + 1
            end
            return role, n
        end
        local state
        R.state_objs = function ()
            if state then return state end
            state = {}
            local q = {}
            -- (state[o] = the ROOT that reaches it first, breadth-first: 'var:<file>:<name>' for a file's top-scope
            -- local — the var a write into o writes —, or the global / module port key; a field path is not kept)
            local level = {}
            R.state_level = level -- (0: the root's OWN object; deeper: reached through fields — the root is then only the first found)
            -- (a TYPE object — every string is one `type:string` — and a function are no mutable tables: never state)
            local function add_port(p, root, lv) for o in each(p) do if o ~= EXT and not TNAME[o] and not fnports[o] and not state[o] then state[o] = root; level[o] = lv or 0; q[#q + 1] = o end end end
            for _, r in ipairs(ROOTS) do for name, p in pairs(r.scope) do add_port(p, 'var:' .. r.file .. ':' .. name) end end
            for key, p in pairs(named) do if key:match('^g:') or key:match('^mod:') then add_port(p, key) end end
            local h = 1
            while h <= #q do
                local o = q[h]; h = h + 1
                for _, fp in pairs(ofield[o] or NOTHING) do add_port(fp, state[o], level[o] + 1) end
            end
            return state
        end
    end
    if ACC then
        -- (one row per source range and kind: the shared walk and each context instance unioned)
        local rows, idx = {}, {}
        for _, a in ipairs(ACC) do
            local k = a.file .. ':' .. a.sr .. ':' .. a.sc .. ':' .. a.kind
            local r = idx[k]
            if not r then
                r = { file = a.file, range = { a.sr, a.sc, a.er, a.ec }, field = a.f, kind = a.kind, sites = {}, types = {}, top = false, partial = false }
                idx[k] = r; rows[#rows + 1] = r
            end
            local function add(o)
                if TNAME[o] then r.types[TNAME[o]] = true
                elseif obinfo[o] == 'external' then r.partial = true
                else r.sites[tostring(obinfo[o])] = true end
                if escaped[o] then r.partial = true end
            end
            -- (a computed key: may it be a STRING — a field name? `seen[node]` keyed by tables or functions never is)
            if a.key == false then r.keystr = true
            elseif a.key then
                if top[a.key] or tainted[a.key] or pts[a.key] == nil then r.keystr = true end
                for o in each(a.key) do
                    local tn = TNAME[o]
                    if obinfo[o] == 'external' or (tn and tn ~= 'integer' and tn ~= 'number' and tn ~= 'boolean') then r.keystr = true end
                end
            end
            if a.obj then r.sites[tostring(obinfo[a.obj])] = true -- (a constructor's own key: definitional, never partial)
            else
                if top[a.base] then r.top = true end
                if tainted[a.base] then r.partial = true end
                for o in each(a.base) do add(o) end
            end
        end
        R.accesses = rows
        -- (what a family's PROTOTYPES hold: proto_fields(site, f) -> { proto sites holding f }, computed — a prototype
        -- that is a function (an `__index` function computes fields). Every object of the site, instances included)
        local of_site = {}
        for o, info in pairs(obinfo) do
            if not TNAME[o] then local k = tostring(info); local l = of_site[k]; if not l then l = {}; of_site[k] = l end; l[#l + 1] = o end
        end
        R.proto_fields = function (site, f)
            local out, computed, seen = {}, false, {}
            local function go(o, depth)
                for c in pairs(protos[o] or NOTHING) do
                    if not seen[c] and depth < 8 then
                        seen[c] = true
                        if fnports[c] then computed = true
                        else
                            local m = ofield[c]
                            if m and m[f] then out[tostring(obinfo[c])] = true end
                            go(c, depth + 1)
                        end
                    end
                end
            end
            for _, o in ipairs(of_site[site] or NOTHING) do go(o, 0) end
            local l = {} for k in pairs(out) do l[#l + 1] = k end; table.sort(l)
            return l, computed
        end
        -- (the allocation sites whose tables ESCAPED — reached a saturated port, where the solve no longer follows them)
        R.escaped_sites = {}
        for o in pairs(escaped) do if not TNAME[o] and obinfo[o] ~= 'external' then R.escaped_sites[tostring(obinfo[o])] = true end end
    end
    if opts.keepsat then
        -- (the SELECTION: saturated ports upstream of an unknown answer — copies, field -> load, through prototypes —
        -- and the functions whose PARAMETERS are among them)
        local function objs(p) if top[p] then return SATSNAP[p] or {} end local t = {}; for o in each(p) do t[#t + 1] = o end; return t end
        -- (predecessors are only ever READ for a saturated port — the search below seeds and expands top ports alone — so
        -- only a top target's are built: the whole map, every load's fields through its objects' prototypes, was a third
        -- of build1)
        local pred = {}
        local function addp(q, p) local l = pred[q]; if not l then l = {}; pred[q] = l end; l[#l + 1] = p end
        for p, sq in pairs(succ) do for q in sit(sq) do if top[q] then addp(q, p) end end end
        if TFROM then R.sat_preds = function (p) return pred[p] or {} end end -- (explain: a saturated port's predecessors)
        for x, l in pairs(loads) do
            local os
            for _, ld in ipairs(l) do
                local f, dst, strict = ld[1], ld[2], ld[3]
                if not top[dst] then goto next_load end
                os = os or objs(x)
                local seen = {}
                local function via(o, depth)
                    if seen[o] or depth > 4 or TNAME[o] then return end
                    seen[o] = true
                    local m = ofield[o]
                    if m then
                        if strict then if m[f] then addp(dst, m[f]) end
                        elseif f == '[]' then for fk, fp in pairs(m) do if fk ~= '{k}' then addp(dst, fp) end end
                        else if m[f] then addp(dst, m[f]) end; if m['[]'] then addp(dst, m['[]']) end end
                    end
                    for c in pairs(protos[o] or NOTHING) do via(c, depth + 1) end
                end
                for _, o in ipairs(os) do via(o, 0) end
                ::next_load::
            end
        end
        -- (ORIGINS, with argument probes on: a saturated port none of whose predecessors is saturated — the union
        -- overflowed HERE, everything downstream only inherited it)
        if ARGP then
            local origin = {}
            for p in pairs(top) do
                local inherited = false
                for _, r in ipairs(pred[p] or NOTHING) do if top[r] then inherited = true; break end end
                if not inherited then origin[p] = true end
            end
            R.top_origins = origin
            -- (an origin that is a temporary, classified by what MERGED into it: fields (a load through a base of many
            -- objects — a heap merge), return ports (a call whose callee value holds several functions — a call-boundary
            -- merge), parameter ports, or plain copies (locals assigned from several places))
            -- (the LOAD an origin came from: { base port, field, the base's object count, the objects' keys (first 8) },
            -- and how many saturated ports it feeds downstream)
            R.origin_load = function (p)
                if not R._loadof then
                    R._loadof = {}
                    for x, l in pairs(loads) do for _, ld in ipairs(l) do R._loadof[ld[2]] = R._loadof[ld[2]] or { x, ld[1] } end end
                end
                local e = R._loadof[p]
                if not e then return nil end
                local os = objs(e[1])
                local keys = {}
                for i = 1, math.min(8, #os) do keys[i] = tostring(obinfo[os[i]] or os[i]) end
                local seen, q, n = { [p] = true }, { p }, 0
                local h = 1
                while h <= #q do
                    local x = q[h]; h = h + 1
                    for y in sit(succ[x]) do if top[y] and not seen[y] then seen[y] = true; n = n + 1; q[#q + 1] = y end end
                end
                return { base = e[1], field = e[2], nbase = #os, base_top = top[e[1]] or false, keys = keys, feeds = n }
            end
            R.origin_preds = function (p)
                local k = { field = 0, ret = 0, param = 0, copy = 0 }
                local fieldof = R._fieldof or {}
                if not R._fieldof then
                    for o, m in pairs(ofield) do for _, fp in pairs(m) do fieldof[fp] = o end end
                    R._fieldof = fieldof
                    R._named_of = {}
                    for key, q in pairs(named) do R._named_of[q] = key end
                end
                for _, r in ipairs(pred[p] or NOTHING) do
                    local key = R._named_of[r]
                    if fieldof[r] then k.field = k.field + 1
                    elseif key and key:match('^r:') then k.ret = k.ret + 1
                    elseif key and key:match('^a:') then k.param = k.param + 1
                    else k.copy = k.copy + 1 end
                end
                return k
            end
        end
        local S, q = {}, {}
        local function seed(p) if top[p] and not S[p] then S[p] = true; q[#q + 1] = p end end
        for _, pr in ipairs(probes) do
            local v = verdicts[pr.c]
            if not v then
                seed(pr.recv)
                local function mem(o, seen)
                    if seen[o] or TNAME[o] then return end
                    seen[o] = true
                    local m = ofield[o]
                    if m and m[pr.member] then seed(m[pr.member]) end
                    for c in pairs(protos[o] or NOTHING) do mem(c, seen) end
                end
                for _, o in ipairs(objs(pr.recv)) do mem(o, {}) end
            end
        end
        local h = 1
        while h <= #q do local p = q[h]; h = h + 1; for _, r in ipairs(pred[p] or NOTHING) do seed(r) end end
        if ARGP then R.unknown_ancestors = S end -- (the saturated ports upstream of an unknown answer: the ones that COST)
        local sel, n = {}, 0
        for o, fp in pairs(fnports) do
            if not fp.inst and fp.id and tostring(fp.id):find('%.lua::') then -- (instances are the Lua walker's)
                for _, pp in ipairs(fp.params) do if S[pp] and not sel[fp.id] then sel[fp.id] = true; n = n + 1 end end
            end
        end
        R.ctxfns, R.nctx = sel, n
        if G7.CALLP then
            local cc = {}
            for c, p in pairs(G7.CALLP) do
                if not top[p] and not tainted[p] then
                    local one, k = nil, 0
                    for o in each(p) do one = o; k = k + 1; if k > 1 then break end end
                    local fp = k == 1 and fnports[one]
                    if fp and not fp.inst and fp.id and sel[fp.id] then cc[c] = fp.id end
                end
            end
            R.ctxcallee = cc
        end
    end
    -- (opts.allcallees: every call's CALLEE SET by flow — cartograph.flowlinks takes links from it, CART-1715. A set of
    -- fn ids and how sure: 'whole' / 'partial' (the port was tainted), '+nonfn' when it also held a non-function — a
    -- table with __call, a type — whose handler is no fn id here)
    if opts.allcallees and G7.CALLP then
        R.callee_of = function (c)
            local p = G7.CALLP[c]
            if not p then return nil, 'no port' end
            if top[p] then return nil, 'top' end
            local fns, other = {}, false
            for o in each(p) do local fp = fnports[o]; if fp and fp.id and not fp.inst then fns[#fns + 1] = fp.id else other = true end end
            table.sort(fns)
            return fns, (tainted[p] and 'partial' or 'whole') .. (other and '+nonfn' or '')
        end
    end
    if G7.REC then -- (opts.dump: the program in the core IR and this solution, CART-1710)
        local FD = require 'cartograph.flowdump'
        local here = debug.getinfo(1, 'S').source:match('^@(.*)/[^/]*$')
        R.dump = FD.build(G7.REC, {
            N = N, NO = NO, each = each, top = top, tainted = tainted, tfrom = TFROM, obinfo = obinfo, fnports = fnports,
            ofield = ofield, okeys = okeys, TNAME = TNAME, GOBJ = G7.ENVL[1].GOBJ, GPORT = G7.ENVL[1].GPORT, ENVL = G7.ENVL, EXT = EXT, GERR = GERR,
            GYIELD = GYIELD, GRESARG = GRESARG, FENVP = G7.ENVL[1].FENVP, EXTCALL = G7.EXTCALL, XA = G7.XA, XRES = G7.XRES, STRLIB = G7.ENVL[1].STRLIB, verdicts = verdicts,
            calls = store.data.calls or {}, callrec = callrec, at = require 'cartograph.at', insat = G7.INSAT,
            -- (the producer: cartograph's OWN commit — its root must be a repository's top level, or none: a snapshot
            -- without .git inside another repository reported THAT repository's HEAD, CART-1724)
            sha = here and FD.head((here:gsub('/lua/cartograph$', '')), true), corpus = store.data.root, corpus_sha = FD.head(store.data.root, true) })
        if type(opts.dump) == 'string' then
            local fd = assert(io.open(opts.dump, 'w')); fd:write(R.dump); fd:close()
        end
    end
    return R
end
-- (TWO SOLVES, the selective context sensitivity: the first picks the functions, the second gives them instances.
-- `opts.ctx = false`: one solve. Measured on lua/cartograph: 92 functions; runtime oracle RIGHT open 556 -> 566, closed
-- 691 -> 762, unknown 693 -> 638; the schedule moves 204/174/171 -> 112/200/140; 2.3x the time. A second round of
-- selection (103 functions) answered no more: unknown 645)
local build1 = build
build = function (store, opts)
    opts = opts or {}
    if opts.ctx == false or opts.ctxfns or opts.dump then return build1(store, opts) end
    local R1 = build1(store, setmetatable({ keepsat = true, ctxsel = true }, { __index = opts }))
    if (R1.nctx or 0) == 0 then return R1 end
    local R = build1(store, setmetatable({ ctxfns = R1.ctxfns, ctxcallee = R1.ctxcallee }, { __index = opts }))
    R.stats.ms, R.stats.ctxfns = R.stats.ms + R1.stats.ms, R1.nctx
    return R
end

--- the analysis over `store`'s graph, cached per graph generation (and per `open`)
function M.of(store, opts)
    local key = ((opts and opts.open == false) and 'closed' or 'open') .. ((opts and opts.spread) and '+spread' or '')
        .. ((opts and opts.exclude) and ('-' .. opts.exclude) or '') .. ((opts and opts.ctx == false) and '-noctx' or '')
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
