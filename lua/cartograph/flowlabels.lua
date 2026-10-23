-- FLOWLABELS (CART-1801): which CONTRACT CLAUSES each value's derivation rests on, propagated over a flowdump's IR with
-- its solution — like taint — so each answer lists what it rests on. flowpath asked for it (FLOW-0057): its post-hoc
-- slice (probes/slice contracts_of) is precise for small derivations and says nothing at hubs.
--
-- It is that slice read FORWARDS: every backward step of slice_of (what can influence a variable's abstract value —
-- value sources, load / store bases, callee variables, handler operands, metatable cells) is an edge here, and labels
-- flow along the edges to a fixpoint. The SEEDS are contracts_of's table — an instruction whose acceptance uses a
-- clause labels what it writes:
--   loadDyn / loadRaw / keys on _G            computed-global
--   storeDyn / storeRawDyn / copyKeyed on _G  strict-global (the cells it writes)
--   a NAMED cell of _G, read or written       GN, and globals-never-escape (GE: no hidden write reaches it)
--   load / loadDyn / loadRaw on a fixed host site (type / ext, not open)   host
--   call / pcall whose callee holds ext       unknown-receiver, unknown-code
--   pcall whose callee is cut or escaped      outside-raises-strings
--   the ESCAPED region (a cut variable, a cell of an escaped site, a parameter of an escaped function)   C1, C3
-- and, past contracts_of: a load from a library site (libraries-never-escape), a call into a host model (host-model).
-- A dest's labels ⊇ its sources' ∪ its instruction's seeds: what flowpath checks like a certificate.
-- An op without a rule here is an ERROR, never silence: a missing label claims an answer rests on nothing.
local M = {}
local bit = require 'bit'
local bor, band = bit.bor, bit.band

M.CLAUSES = { 'GN', 'strict-global', 'computed-global', 'host', 'unknown-receiver', 'unknown-code',
    'outside-raises-strings', 'C1', 'C3', 'globals-never-escape', 'libraries-never-escape', 'host-model',
    'hidden-fields', 'function-no-metatable', 'loaded-code', 'fixed-env', 'reflection:package.loaded' }
local B = {}
for i, c in ipairs(M.CLAUSES) do B[c] = bit.lshift(1, i - 1) end
local ESC = bor(B.C1, B.C3)
local META, IDX, NIDX, CALL = 100, 101, 102, 103
local SYNTH = { ['#'] = true, ['[]'] = true, ['{k}'] = true }

local function num(x) return type(x) == 'number' end

--- labels of a decoded dump D -> L: { v = {var = mask}, h = {site = {field = mask}}, d, k, w = {site = mask}, err, chan,
--- ret }, plus L.answer(a) -> sorted clause names, L.names(mask)
function M.compute(D)
    local s = D.solution
    local fields = D.names.fields
    local V = {}
    for _, e in ipairs(s.v) do local t = {}; for _, a in ipairs(e[2]) do t[#t + 1] = a end; V[e[1]] = t end
    local tops = {}
    for _, x in ipairs(s.top or {}) do tops[x] = true end
    for _, x in ipairs(s.taint.ports or {}) do tops[x] = true end
    local esc = {}
    for _, a in ipairs(s.taint.escaped or {}) do esc[a] = true end
    local H = {} -- site -> field -> sites
    local fieldsof = {} -- site -> named fields (not META), for cells_of
    for _, e in ipairs(s.h) do
        local a, f = e[1], e[2]
        local r = H[a]; if not r then r = {}; H[a] = r end
        r[f] = e[3]
        if f ~= META then local l = fieldsof[a]; if not l then l = {}; fieldsof[a] = l end; l[#l + 1] = f end
    end
    for _, e in ipairs(s.htop or {}) do
        if type(e) == 'table' and e[2] ~= META then
            local l = fieldsof[e[1]]; if not l then l = {}; fieldsof[e[1]] = l end
            local has = false
            for _, f in ipairs(l) do if f == e[2] then has = true end end
            if not has then l[#l + 1] = e[2] end
        end
    end
    local closure, globals, fixed, ext, libs = {}, {}, {}, {}, {}
    for _, si in ipairs(D.sites) do
        if num(si.fn) then closure[si.id] = si.fn end
        if si.kind == 'globals' then globals[si.id] = true end
        if (si.kind == 'type' or si.kind == 'ext') and si.host ~= 'open' then fixed[si.id] = true end
        if si.label == 'external' then ext[si.id] = true end
    end
    for _, a in ipairs(D.contracts.library_sites or {}) do libs[a] = true end
    -- (REFLECTION, CART-1816: a computed-key, pairs or keys read whose base may hold package.loaded is a reflective read
    -- over the loaded modules — its result carries the label wherever it flows, a saturated port included)
    local pls = {}
    for _, a in ipairs(D.contracts.package_loaded_sites or {}) do pls[a] = true end
    local REFL = B['reflection:package.loaded']
    local CUR -- (the instruction being evaluated: { fn, index } — the first cause of a label on a variable)
    local first = {}
    local seeds = {}
    local hmodel = {}
    for _, e in ipairs(D.contracts.host_models or {}) do for _, g in ipairs(e[2] or {}) do hmodel[g] = true end end
    local F = {}
    for _, f in ipairs(D.functions) do F[f.id] = f end
    local escfn = {}
    for c, g in pairs(closure) do if esc[c] then escfn[g] = true end end
    local cofns = {}
    for _, f in ipairs(D.functions) do
        for _, ins in ipairs(f.body) do
            if ins[1] == 'cocreate' then for _, c in ipairs(V[ins[4]] or {}) do if closure[c] then cofns[closure[c]] = true end end end
        end
    end

    local Lv, Lh, Ld, Lk, Lw, Lerr, Lret = {}, {}, {}, {}, {}, {}, {}
    local Lall = {} -- (site -> the union of its named cells and its dynamic cell: a dynamic read's, kept as they grow)
    local Lchan = { rin = 0, rout = 0 }
    local changed
    local function lv(x)
        if not num(x) then return 0 end
        local m = Lv[x] or 0
        if tops[x] then m = bor(m, ESC) end
        return m
    end
    -- (REFLECTION rides on what a reflected object YIELDS — copies, cell values, arguments into parameters, returns into
    -- results, and what is read THROUGH it (its contents). A callee, a store's base, a key or an operand contributes the
    -- other clauses but not it: by dependence, reflective code calling and writing what it found reached 93,137 variables
    -- in 5,131 functions of cartograph's own tree, CART-1816)
    local NOREFL = bit.bnot(REFL)
    local function lvb(x) return band(lv(x), NOREFL) end
    -- (a read THROUGH a reflected base yields reflected content only where the base holds something beyond the globals
    -- table, the libraries and package.loaded — those are reachable by name, and reading through them is an ordinary
    -- global read: in the default reading a reflective read returns exactly them, and labelling their contents labelled
    -- every global, 37,312 variables)
    local bmemo = {}
    local function lvthru(y)
        if not num(y) then return 0 end
        local b = bmemo[y]
        if b == nil then
            b = false
            for _, a in ipairs(V[y] or {}) do if not (globals[a] or libs[a] or pls[a]) then b = true; break end end
            if tops[y] then b = true end
            bmemo[y] = b
        end
        return b and lv(y) or lvb(y)
    end
    local function setv(x, m)
        if not num(x) or m == 0 then return end
        local o = Lv[x] or 0
        local n = bor(o, m)
        if n ~= o then
            Lv[x] = n; changed = true
            if band(o, REFL) == 0 and band(n, REFL) ~= 0 and CUR and not first[x] then first[x] = CUR end
        end
    end
    local function orinto(t, k, m)
        if m == 0 then return end
        local o = t[k] or 0
        local n = bor(o, m)
        if n ~= o then t[k] = n; changed = true end
    end
    local function seth(a, f, m)
        if m == 0 then return end
        local r = Lh[a]; if not r then r = {}; Lh[a] = r end
        orinto(r, f, m)
        if f ~= META then orinto(Lall, a, m) end
    end
    local function setd(a, m) orinto(Ld, a, m); orinto(Lall, a, m) end
    -- (a cell read: its own labels and what every dynamic write to the site carried. A cell of an ESCAPED site is the
    -- escaped region: C1 / C3 only — not expanded, as the slice does not: the E-certificate covers it as a whole, and
    -- what it rests on is labels.region, once for every answer that reaches it)
    local function cell(a, f)
        if esc[a] then return ESC end
        local m = bor(Lh[a] and Lh[a][f] or 0, Lw[a] or 0)
        if globals[a] and f ~= META and not SYNTH[fields[f + 1] or ''] then m = bor(m, B.GN, B['globals-never-escape']) end
        return m
    end
    local function dcell(a) if esc[a] then return ESC end; return bor(Ld[a] or 0, Lw[a] or 0) end
    local function kcell(a) if esc[a] then return ESC end; return bor(Lk[a] or 0, Lw[a] or 0) end
    local gnall = {} -- (a globals site with a named cell: a dynamic read of it touches a named global)
    for a in pairs(globals) do
        for _, f in ipairs(fieldsof[a] or {}) do if not SYNTH[fields[f + 1] or ''] then gnall[a] = true; break end end
    end
    local function allcells(a)
        if esc[a] then return ESC end
        local m = bor(Lall[a] or 0, Lw[a] or 0)
        if gnall[a] then m = bor(m, B.GN, B['globals-never-escape']) end
        return m
    end
    local chains = {}
    local function chain(a, ev)
        local key = a * 1000 + ev
        local c = chains[key]
        if c then return c end
        local out, seen = {}, {}
        local function go(x)
            if seen[x] then return end
            seen[x] = true
            out[#out + 1] = x
            for _, m in ipairs(H[x] and H[x][META] or {}) do
                for _, t in ipairs(H[m] and H[m][ev] or {}) do if not closure[t] then go(t) end end
            end
        end
        go(a)
        chains[key] = out
        return out
    end
    local hmemo = {}
    local NONE = {}
    local function handlers(a, ev) -- (the handler functions an access through a's chain runs: static, memoized)
        local key = a * 1000 + ev
        local r = hmemo[key]
        if r then return r end
        local out = {}
        for _, c in ipairs((ev == IDX or ev == NIDX) and chain(a, ev) or { a }) do
            for _, m in ipairs(H[c] and H[c][META] or {}) do
                for _, t in ipairs(H[m] and H[m][ev] or {}) do if closure[t] then out[#out + 1] = closure[t] end end
            end
        end
        if #out == 0 then out = NONE end
        hmemo[key] = out
        return out
    end
    -- (per BASE VARIABLE, static: the distinct sites of its sites' __index chains, and the distinct handlers they run —
    -- a hub variable's 64 sites share their chains; per site, WoW's w1 entered each handler dozens of times per load)
    local vcmemo, vhmemo = {}, {}
    local function vchain(y)
        local r = vcmemo[y]
        if r then return r end
        local out, seen = {}, {}
        for _, a in ipairs(V[y] or {}) do for _, c in ipairs(chain(a, IDX)) do if not seen[c] then seen[c] = true; out[#out + 1] = c end end end
        vcmemo[y] = out
        return out
    end
    local function vhandlers(y, ev)
        local key = y * 1000 + ev
        local r = vhmemo[key]
        if r then return r end
        local out, seen = {}, {}
        for _, a in ipairs(V[y] or {}) do for _, g in ipairs(handlers(a, ev)) do if not seen[g] then seen[g] = true; out[#out + 1] = g end end end
        if #out == 0 then out = NONE end
        vhmemo[key] = out
        return out
    end
    local function ret(g) return Lret[g] or 0 end
    local function params_in(g, m, args) -- (a function entered: every parameter gets m; parameter i also args[i])
        local f = F[g]
        if not f then return end
        local ps = f.params
        for i, p in ipairs(ps) do
            local mi = m
            if args then
                local y = args[i]
                if y ~= nil then mi = bor(mi, lv(y)) end
                if i == #ps then for j = #ps + 1, #args do mi = bor(mi, lv(args[j])) end end -- (the vararg)
            end
            setv(p, mi)
        end
    end
    local smemo = {}
    local function seedload(y, m, dyn) -- (the load's own seeds: static per base variable)
        if not num(y) then return m end
        local key = dyn and -y - 1 or y
        local sd = smemo[key]
        if not sd then
            sd = 0
            for _, a in ipairs(V[y] or {}) do
                if fixed[a] then sd = bor(sd, B.host) end
                if libs[a] then sd = bor(sd, B['libraries-never-escape']) end
                if dyn and globals[a] then sd = bor(sd, B['computed-global']) end
            if dyn and pls[a] then sd = bor(sd, REFL) end
            end
            smemo[key] = sd
        end
        return bor(m, sd)
    end

    local RULE = {}
    RULE.new = function () end
    RULE.prim = RULE.new
    RULE.copy = function (_, ins) setv(ins[2], lv(ins[3])) end
    -- (an instruction's SEEDS go to everything it writes — a handler's parameters too: the slice applies the seeds of
    -- every instruction it reaches, a handler's entry among them)
    RULE.load = function (_, ins)
        local x, y, f = ins[2], ins[3], ins[4]
        local m = seedload(y, lvthru(y), false)
        local pin = bor(m, lv(y))
        for _, c in ipairs(vchain(y)) do m = bor(m, cell(c, META), cell(c, f), dcell(c)) end
        for _, g in ipairs(vhandlers(y, IDX)) do m = bor(m, ret(g)); params_in(g, pin) end
        setv(x, m)
    end
    RULE.loadDyn = function (_, ins)
        local x, y, k = ins[2], ins[3], ins[4]
        local m = seedload(y, bor(lvthru(y), lvb(k)), true)
        local pin = bor(m, lv(y), lv(k))
        for _, c in ipairs(vchain(y)) do m = bor(m, cell(c, META), allcells(c)) end
        for _, g in ipairs(vhandlers(y, IDX)) do m = bor(m, ret(g)); params_in(g, pin) end
        setv(x, m)
    end
    RULE.loadRaw = function (_, ins)
        local x, y, k = ins[2], ins[3], ins[4]
        local m = seedload(y, bor(lvthru(y), lvb(k)), true)
        for _, a in ipairs(V[y] or {}) do m = bor(m, cell(a, META), allcells(a)) end
        setv(x, m)
    end
    RULE.keys = function (_, ins)
        local x, y = ins[2], ins[3]
        local m = seedload(y, lvthru(y), true)
        for _, a in ipairs(V[y] or {}) do m = bor(m, cell(a, META), kcell(a)) end
        setv(x, m)
    end
    RULE.getmeta = function (_, ins)
        local x, y, f = ins[2], ins[3], ins[4]
        local m = lvb(y)
        for _, a in ipairs(V[y] or {}) do
            m = bor(m, cell(a, META))
            for _, mt in ipairs(H[a] and H[a][META] or {}) do m = bor(m, cell(mt, f)) end
        end
        setv(x, m)
    end
    RULE.op = function (_, ins)
        local x, ys, k = ins[2], ins[3], ins[4]
        local m = 0
        for _, y in ipairs(ys) do m = bor(m, lvb(y)) end
        local inm = 0
        for _, y in ipairs(ys) do inm = bor(inm, lv(y)) end
        for _, y in ipairs(ys) do
            for _, a in ipairs(V[y] or {}) do
                m = bor(m, cell(a, META))
                for _, mt in ipairs(H[a] and H[a][META] or {}) do
                    m = bor(m, cell(mt, k))
                    for _, t in ipairs(H[mt] and H[mt][k] or {}) do
                        local g = closure[t]
                        if g then m = bor(m, ret(g)); params_in(g, inm, ys) end
                    end
                end
            end
        end
        setv(x, m)
    end
    local function callrule(op, ins)
        local rets, fv, args = ins[2], ins[3], ins[4]
        local cs = V[fv] or {}
        local seed, anyesc = 0, tops[fv] or false
        for _, a in ipairs(cs) do
            if ext[a] then seed = bor(seed, B['unknown-receiver'], B['unknown-code']) end
            if esc[a] then anyesc = true end
            if closure[a] and hmodel[closure[a]] then seed = bor(seed, B['host-model']) end
        end
        if op == 'pcall' and anyesc then seed = bor(seed, B['outside-raises-strings']) end
        local pin = bor(lvb(fv), seed)
        local m = pin
        for _, a in ipairs(cs) do
            local g = closure[a]
            if g then
                m = bor(m, ret(g))
                if op == 'pcall' then m = bor(m, Lerr[g] or 0) end
                params_in(g, pin, args)
            else
                m = bor(m, cell(a, META))
            end
        end
        -- (a callable object: its __call handler runs with (object, args…) — the distinct handlers over the callee's
        -- sites, static per variable: per site, a hub callee rebuilt the argument list and re-entered one handler for
        -- each of its tables)
        local hs = vhandlers(fv, CALL)
        if #hs > 0 then
            local hargs = { fv }
            for _, y in ipairs(args) do hargs[#hargs + 1] = y end
            for _, g2 in ipairs(hs) do m = bor(m, ret(g2)); params_in(g2, pin, hargs) end
        end
        for _, r in ipairs(rets) do setv(r, m) end
    end
    RULE.call = function (_, ins) callrule('call', ins) end
    RULE.pcall = function (_, ins) callrule('pcall', ins) end
    local function storerule(x, f, vals, dyn)
        local m = lvb(x)
        for _, y in ipairs(vals) do m = bor(m, lv(y)) end
        for _, a in ipairs(V[x] or {}) do
            local ma = m
            if dyn and globals[a] then ma = bor(ma, B['strict-global']) end
            if dyn then orinto(Lw, a, ma)
            else seth(a, f, ma); setd(a, ma); orinto(Lk, a, ma) end
            -- (a store through a __newindex chain runs its handler with (object, key, value))
            for _, g in ipairs(handlers(a, NIDX)) do params_in(g, ma) end
        end
    end
    RULE.store = function (_, ins) storerule(ins[2], ins[3], { ins[4] }, false) end
    RULE.storeRaw = RULE.store
    RULE.storeDyn = function (_, ins) storerule(ins[2], nil, { ins[3], ins[4] }, true) end
    RULE.storeRawDyn = RULE.storeDyn
    RULE.copyKeyed = function (_, ins) storerule(ins[2], nil, { ins[3], ins[4], ins[5] }, true) end
    RULE.setmeta = function (_, ins)
        local x, y = ins[2], ins[3]
        local m = bor(lv(x), lv(y))
        for _, a in ipairs(V[x] or {}) do seth(a, META, m); setd(a, m); orinto(Lk, a, m) end
    end
    RULE.error = function (g, ins) orinto(Lerr, g, lv(ins[2])) end
    RULE.ret = function (g, ins)
        local m = 0
        for _, y in ipairs(ins[2]) do m = bor(m, lv(y)) end
        orinto(Lret, g, m)
        if cofns[g] then local o = Lchan.rout; Lchan.rout = bor(o, m); if Lchan.rout ~= o then changed = true end end
    end
    RULE.cocreate = function (_, ins) setv(ins[2], lv(ins[4])) end
    RULE.resume = function (_, ins)
        local m = 0
        for _, y in ipairs(ins[4]) do m = bor(m, lv(y)) end
        local o = Lchan.rin; Lchan.rin = bor(o, m); if Lchan.rin ~= o then changed = true end
        for _, r in ipairs(ins[2]) do setv(r, bor(Lchan.rout, lvb(ins[3]))) end
    end
    RULE.yield = function (_, ins)
        local m = 0
        for _, y in ipairs(ins[3]) do m = bor(m, lv(y)) end
        local o = Lchan.rout; Lchan.rout = bor(o, m); if Lchan.rout ~= o then changed = true end
        for _, r in ipairs(ins[2]) do setv(r, Lchan.rin) end
    end

    -- (callees per function, for the error channel: a call raises what its callee raises)
    local callees = {}
    for _, f in ipairs(D.functions) do
        local l = {}
        for _, ins in ipairs(f.body) do
            if ins[1] == 'call' or ins[1] == 'pcall' then
                for _, a in ipairs(V[ins[3]] or {}) do if closure[a] and ins[1] == 'call' then l[#l + 1] = closure[a] end end
            end
        end
        callees[f.id] = l
        local rule
        for _, ins in ipairs(f.body) do
            rule = RULE[ins[1]]
            if not rule then error('flowlabels: no rule for op ' .. tostring(ins[1]) .. ' — a missing label would claim nothing', 0) end
        end
    end
    -- ★ TARGETED WHOLE-PROGRAM SEEDS (CART-1807): a violation no instruction carries, seeded on what it can REACH rather
    -- than on every answer. Each is a REACH from what the violation is handed: every site reached through the heap may be
    -- written (every cell), every function reached called with anything (its parameters). GE's world side — outside
    -- code holding _G triggers its metamethods: it is handed the handlers of _G's metatable (an __index table it reads
    -- through and may write into, flowpath's h18; a __newindex table it stores into; a function it calls). An
    -- UNRESOLVED callee (its variable lists nothing) is handed its arguments, and its results are its own
    do
        local GE, UR = B['globals-never-escape'], B['unknown-receiver']
        local function seedparams(g, m) local f = F[g]; if f then for _, p in ipairs(f.params) do setv(p, m) end end end
        local hd = {}
        for _, e in ipairs(s.hdyn or {}) do hd[e[1]] = e[2] end
        local function closure_of(roots, m) -- (BFS over the heap from roots: every reached cell and function seeded m)
            local q, seen = {}, {}
            for _, a in ipairs(roots) do if not seen[a] then seen[a] = true; q[#q + 1] = a end end
            local i = 1
            while i <= #q do
                local a = q[i]; i = i + 1
                orinto(Lw, a, m)
                if closure[a] then seedparams(closure[a], m) end
                for _, bs in pairs(H[a] or {}) do for _, b in ipairs(bs) do if not seen[b] then seen[b] = true; q[#q + 1] = b end end end
                for _, b in ipairs(hd[a] or {}) do if not seen[b] then seen[b] = true; q[#q + 1] = b end end
            end
            return #q
        end
        local groots = {}
        for gs in pairs(globals) do
            for _, mt in ipairs(H[gs] and H[gs][META] or {}) do
                for ev, ts in pairs(H[mt] or {}) do if ev ~= META then for _, t in ipairs(ts) do groots[#groots + 1] = t end end end
            end
        end
        M.LAST_GE_REACH = closure_of(groots, GE)
        local uroots = {}
        for _, f in ipairs(D.functions) do
            for _, ins in ipairs(f.body) do
                if (ins[1] == 'call' or ins[1] == 'pcall') and num(ins[3]) and ins[3] ~= D.contracts.ext_channel
                    and not tops[ins[3]] and #(V[ins[3]] or {}) == 0 then
                    for _, r in ipairs(ins[2]) do setv(r, UR) end
                    for _, y in ipairs(ins[4]) do for _, a in ipairs(V[y] or {}) do uroots[#uroots + 1] = a end end
                end
            end
        end
        M.LAST_REACH = closure_of(uroots, UR)
    end
    local passes = 0
    repeat
        changed = false
        passes = passes + 1
        for _, f in ipairs(D.functions) do
            local g = f.id
            -- (escaped function: anything escaped reaches its parameters; a coroutine function's, what resume passes in)
            if escfn[g] then for _, p in ipairs(f.params) do setv(p, ESC) end end
            if cofns[g] then for _, p in ipairs(f.params) do setv(p, Lchan.rin) end end
            for k, ins in ipairs(f.body) do CUR = { g, k - 1 }; RULE[ins[1]](g, ins) end
            CUR = nil
            for _, c in ipairs(callees[g]) do orinto(Lerr, g, Lerr[c] or 0) end
        end
    until not changed

    -- (the ESCAPED REGION's own labels: what was written into an escaped site's cells)
    local region = 0
    for a in pairs(esc) do
        for _, m in pairs(Lh[a] or {}) do region = bor(region, m) end
        region = bor(region, Ld[a] or 0, Lk[a] or 0, Lw[a] or 0)
    end
    -- ★ WHOLE-PROGRAM CLAUSES (CART-1805, flowpath's run-time witnesses): a violation no tree instruction carries — outside
    -- code holding _G runs its __newindex into a tree table (GE's world side), an UNRESOLVED callee (one whose variable
    -- lists nothing) runs a handler, code loaded at run time, an environment set from outside, a dynamic key hitting
    -- the metatable slot, a metatable on a function — labels no instruction, so EVERY answer carries the stated ones
    local global = 0
    local stated = D.contracts.clauses or {}
    -- (globals-never-escape's world side and an unresolved callee's unknown-receiver are seeded where they reach, above;
    -- init's own call of the ext channel lists nothing by construction and is no unresolved call)
    for _, c in ipairs({ 'hidden-fields', 'function-no-metatable', 'loaded-code', 'fixed-env' }) do
        if stated[c] then global = bor(global, B[c]) end
    end
    -- (the reflective reads, the functions holding them, and the BOUNDARY: every labelled variable of another function,
    -- with the instruction that first carried the label into it — where reflection's results leave the reflecting code)
    local refl = { seeds = {}, functions = {}, boundary = {} }
    if next(pls) then
        local owner = {}
        for _, f in ipairs(D.functions) do
            for _, p in ipairs(f.params) do owner[p] = owner[p] or f.id end
            for k, ins in ipairs(f.body) do
                local op = ins[1]
                if num(ins[2]) then owner[ins[2]] = owner[ins[2]] or f.id end
                if (op == 'loadDyn' or op == 'loadRaw' or op == 'keys') then
                    for _, a in ipairs(V[ins[3]] or {}) do
                        if pls[a] then refl.seeds[#refl.seeds + 1] = { f.id, k - 1 }; refl.functions[f.id] = true; break end
                    end
                end
            end
        end
        for x, m in pairs(Lv) do
            local o = owner[x]
            if band(m, REFL) ~= 0 and o and not refl.functions[o] then
                local fc = first[x]
                refl.boundary[#refl.boundary + 1] = { x, o, fc and fc[1] or -1, fc and fc[2] or -1 }
            end
        end
        table.sort(refl.boundary, function (p, q) return p[1] < q[1] end)
    end
    local L = { v = Lv, h = Lh, d = Ld, k = Lk, w = Lw, err = Lerr, ret = Lret, chan = Lchan, passes = passes, region = region,
        global = global, reflection = refl }
    function L.names(m)
        local out = {}
        for i, c in ipairs(M.CLAUSES) do if band(m, bit.lshift(1, i - 1)) ~= 0 then out[#out + 1] = c end end
        return out
    end
    -- (an answer: its callee variable's labels and its call instruction's own seeds)
    function L.mask(fnid, k)
        local f = F[fnid]
        local ins = f and f.body[k + 1]
        if not ins or (ins[1] ~= 'call' and ins[1] ~= 'pcall') then return nil end
        local m = lv(ins[3])
        for _, a in ipairs(V[ins[3]] or {}) do
            if ext[a] then m = bor(m, B['unknown-receiver'], B['unknown-code']) end
            if ins[1] == 'pcall' and (esc[a] or tops[ins[3]]) then m = bor(m, B['outside-raises-strings']) end
        end
        -- (one that reaches the ESCAPED region rests on what the region rests on — a value a violation produced may be
        -- stored through a cut base into an escaped cell it reads, CART-1805; and every answer on the global clauses)
        if band(m, ESC) ~= 0 then m = bor(m, region) end
        return bor(m, global)
    end
    return L
end

return M
