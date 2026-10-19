-- DUMPCHECK (CART-1710): is a flowtype dump CLOSED? A transcription of the flowpath Lean checker's constraints —
-- ~/work/flowpath/lean/Flowpath/Core/Andersen.lean `Constraint` and Core/Errors.lean `EConstraint` (per-function error
-- ports), at the Lua instance (Lua/Instance.lean: chains and handlers are the field paths [META, ev]; a chain continues
-- only into a site that is not a closure). It predicts what FLOW C.2 will say, and it is the dump's acceptance test:
-- a failure is an instruction whose constraint the solution does not satisfy, named — excused when its destination is
-- tainted (the solve said that answer is partial), classified by the instruction's tag (a known contract edge or
-- divergence) otherwise.
--   require('cartograph.flowcheck').check(D[, maxshow]) -> { failed, excused, counts, fails, unwritten, ninst };
--   tools/experiments/flowtype_oracle/dumpcheck.lua <dump.json> [max shown] prints it.
-- Also a COMPLETENESS proxy: a variable that holds something but no instruction, parameter or self writes it is a
-- route the IR left out (closedness alone cannot see a missing instruction).
local M = {}

function M.check(D, maxshow)
maxshow = maxshow or 20
local NULL = vim.NIL

local META, IDX, NIDX, CALLK, GCK = 100, 101, 102, 103, 105
local evLoad, evStore, evStoreLook = 101, 102, 104
local function luaKey(ev) return ev == evStoreLook and NIDX or ev end

-- the solution
local S = D.solution
local V, TOP, TAINT = {}, {}, {}
for _, e in ipairs(S.v) do local t = {}; for _, s in ipairs(e[2]) do t[s] = true end; V[e[1]] = t end
for _, x in ipairs(S.top) do TOP[x] = true end
for _, x in ipairs(S.taint.ports) do TAINT[x] = true end
local H, HDYN, HTOP, HTAINT = {}, {}, {}, {}
for _, e in ipairs(S.h) do
    local m = H[e[1]]; if not m then m = {}; H[e[1]] = m end
    local t = {}; for _, s in ipairs(e[3]) do t[s] = true end; m[e[2]] = t
end
for _, e in ipairs(S.hdyn) do local t = {}; for _, s in ipairs(e[2]) do t[s] = true end; HDYN[e[1]] = t end
-- (the KEY SET a table holds: what pairs / next yield — read by `keys`, written by a storeDyn's key, CART-1739)
local HKEYS = {}
for _, e in ipairs(S.hkeys or {}) do local t = HKEYS[e[1]] or {}; for _, s in ipairs(e[2]) do t[s] = true end; HKEYS[e[1]] = t end
local HKEYSTOP = {}
for _, o in ipairs(S.hkeystop or {}) do HKEYSTOP[o] = true end -- (a saturated key set: it holds any key)
local DYNKEYS = D.contracts and D.contracts.dyn_keys == true -- (loadDyn x y k, storeDyn x k y; else storeDyn x y)
for _, e in ipairs(S.htop) do HTOP[e[1] .. ':' .. e[2]] = true end
for _, e in ipairs(S.htaint or {}) do HTAINT[e[1] .. ':' .. (e[2] == NULL and '*' or e[2])] = true end
-- (the store rule's reach: every cell (escaped site, hit field) is tainted, ported or not — CART-1744)
local ESC, FHIT = {}, {}
for _, o in ipairs(S.taint.escaped or {}) do ESC[o] = true end
for _, f in ipairs(S.taint.fields_hit or {}) do FHIT[f == NULL and '*' or f] = true end
local PORT, PTOP, PTAINT = {}, {}, {}
for _, e in ipairs(S.err.fn) do local t = {}; for _, s in ipairs(e[2]) do t[s] = true end; PORT[e[1]] = t end
for _, g in ipairs(S.err.top or {}) do PTOP[g] = true end
for _, g in ipairs(S.err.taint or {}) do PTAINT[g] = true end
local CERR, RIN, ROUT = {}, {}, {}
for _, s in ipairs(S.err.cerr) do CERR[s] = true end
for _, s in ipairs(S.rin) do RIN[s] = true end
for _, s in ipairs(S.rout) do ROUT[s] = true end
local FNOF, HOST, GLOBALS = {}, {}, nil
local STRLIB = D.contracts and D.contracts.strlib_site ~= NULL and D.contracts.strlib_site or nil
local STRSITE, EXTSITE
local EXTCH = D.contracts and D.contracts.ext_channel ~= NULL and D.contracts.ext_channel or nil
for _, st in ipairs(D.sites) do
    if st.kind == 'ext' then EXTSITE = st.id end
    if st.label == 'type:string' then STRSITE = st.id end
    if st.fn ~= NULL then FNOF[st.id] = st.fn end
    if st.kind == 'globals' then GLOBALS = st.id end
    if st.kind == 'type' or st.kind == 'ext' then HOST[st.id] = true end -- (contract:host: no fields)
end
local CODE = {}
for _, f in ipairs(D.functions) do CODE[f.id] = f end
local fname = function (g) return D.names.functions[g + 1] end
local fieldname = function (f) return D.names.fields[f + 1] end

local EMPTY = {}
local function v(x) return V[x] or EMPTY end
local function h(c, f) local m = H[c]; return m and m[f] or EMPTY end
local function hasv(x, s) return TOP[x] or (V[x] and V[x][s]) end
local function hash(c, f, s) return HTOP[c .. ':' .. f] or (H[c] and H[c][f] and H[c][f][s]) or (HDYN[c] and HDYN[c][s]) end

-- AChain ev a: a, then every site t with h(c, META, m), h(m, luaKey ev, t), t not a closure
local function chain(ev, a)
    local out, q, seen = {}, { a }, { [a] = true }
    local i = 1
    while i <= #q do
        local c = q[i]; i = i + 1
        out[#out + 1] = c
        for m in pairs(h(c, META)) do
            for t in pairs(h(m, luaKey(ev))) do if not FNOF[t] and not seen[t] then seen[t] = true; q[#q + 1] = t end end
        end
    end
    return out
end
-- AHandler ev c: the closures at [META, ev] from c
local function handlers(ev, c)
    local out = {}
    for m in pairs(h(c, META)) do for t in pairs(h(m, ev)) do if FNOF[t] then out[#out + 1] = t end end end
    return out
end

-- failures
local fails, nfail, excused, counts = {}, 0, 0, {}
local cur -- { g, i, ins, tag }
local function fail(part, dest, msg)
    if dest and (TAINT[dest] or TOP[dest]) then excused = excused + 1; return end
    local key = (cur.tag or 'untagged') .. ' ' .. cur.ins[1] .. ':' .. part
    counts[key] = (counts[key] or 0) + 1
    nfail = nfail + 1
    if #fails < maxshow then fails[#fails + 1] = ('%s  [%s] %s#%d %s — %s'):format(key, fname(cur.g), cur.ins[1], cur.i, vim.inspect(cur.ins, { newline = '' }):sub(1, 120), msg) end
end
local function failh(part, c, f, msg)
    if HTAINT[c .. ':' .. f] or HTAINT[c .. ':*'] or (ESC[c] and (FHIT[f] or FHIT['*'])) then excused = excused + 1; return end
    fail(part, nil, msg)
end
local function sub(srcset, x, part) -- v(x) ⊇ srcset
    if TOP[x] then return end
    for s in pairs(srcset) do if not hasv(x, s) then fail(part, x, ('site %d not in v(%d)'):format(s, x)); return end end
end
local function subport(srcset, g, part)
    if PTOP[g] then return end
    if PTAINT[g] then if next(srcset) then excused = excused + 1 end; return end
    local p = PORT[g] or EMPTY
    for s in pairs(srcset) do if not p[s] then fail(part, nil, ('site %d not in port(%s)'):format(s, fname(g))); return end end
end
-- EEntry g0 g' t srcs dst prot
local function entry(g0, g2, t, srcs, dst, prot)
    local F = CODE[g2]
    if not F then fail('entry', nil, 'no code for ' .. tostring(g2)); return end
    for i, src in ipairs(srcs) do local p = F.params[i]; if p then sub(src, p, 'arg') end end
    if not hasv(F.self, t) then fail('self', F.self, 'self lacks ' .. t) end
    for _, ins in ipairs(F.body) do
        if ins[1] == 'ret' then
            local d = prot and { unpack(dst, 2) } or dst
            for i, y in ipairs(ins[2]) do if d[i] then sub(v(y), d[i], 'ret') end end
        end
    end
    if PTOP[g2] then
        if prot and dst[2] and not TOP[dst[2]] then fail('errflows-top', dst[2], 'port(' .. fname(g2) .. ') is top') end
        if not prot and not PTOP[g0] and not PTAINT[g0] then fail('port-top', nil, 'port(' .. fname(g2) .. ') is top') end
    else
        if prot and dst[2] then sub(PORT[g2] or EMPTY, dst[2], 'errflows') end
        if not prot then subport(PORT[g2] or EMPTY, g0, 'port') end
    end
end

local ninst = 0
for _, F in ipairs(D.functions) do
    local tagat = {}
    for _, t in ipairs(F.tags) do tagat[t[1]] = t[2] end
    for i0, ins in ipairs(F.body) do
        ninst = ninst + 1
        cur = { g = F.id, i = i0 - 1, ins = ins, tag = tagat[i0 - 1] }
        local op = ins[1]
        if op == 'new' then
            if not hasv(ins[2], ins[3]) then fail('new', ins[2], 'v lacks its site') end
        elseif op == 'copy' then sub(v(ins[3]), ins[2], 'copy')
        elseif op == 'load' or op == 'loadDyn' then
            local x, y, f = ins[2], ins[3], ins[4]
            for a0 in pairs(v(y)) do
                -- (a string indexes through the string library: the Lean model's ABase / aprim, P.strLib)
                local a = (a0 == STRSITE and STRLIB) or a0
                if not HOST[a] then for _, c in ipairs(chain(evLoad, a)) do
                    if op == 'load' then
                        sub(h(c, f), x, 'field'); sub(HDYN[c] or EMPTY, x, 'field[]')
                        if HTOP[c .. ':' .. f] and not TOP[x] then fail('field-top', x, ('h(%d,%s) is top'):format(c, tostring(fieldname(f)))) end
                    else
                        for f2, t in pairs(H[c] or EMPTY) do
                            sub(t, x, f2 == META and 'field*META(model)' or (c == GLOBALS and 'field*contract:computed-global' or 'field*'))
                        end
                        sub(HDYN[c] or EMPTY, x, 'field[]')
                    end
                    for _, t in ipairs(handlers(IDX, c)) do entry(F.id, FNOF[t], t, { { [c] = true } }, { x }, false) end
                end end
            end
        elseif op == 'loadRaw' then
            -- (`loadRaw x y k`, FLOW-0090: any field of the object ITSELF — no __index, no prototype: pairs' value, rawget)
            local x, y = ins[2], ins[3]
            for a in pairs(v(y)) do
                if not HOST[a] then
                    for f2, t in pairs(H[a] or EMPTY) do
                        if f2 ~= META then sub(t, x, a == GLOBALS and 'raw*contract:computed-global' or 'raw*') end
                    end
                    sub(HDYN[a] or EMPTY, x, 'raw[]')
                end
            end
        elseif op == 'storeRawDyn' then
            -- (`storeRawDyn x k y`, CART-1771: storeDyn at the object ITSELF — every dynamic field of each object x may
            -- hold gets y, its key set gets k; no chain, no __newindex handler)
            local x, k, y = ins[2], ins[3] ~= NULL and ins[3] or nil, ins[4]
            for a in pairs(v(x)) do
                if not HOST[a] then
                    if k and not HKEYSTOP[a] then for b in pairs(v(k)) do if not (HKEYS[a] and HKEYS[a][b]) then failh('hkeys', a, '*', ('hkeys(%d) lacks %d'):format(a, b)); break end end end
                    for b in pairs(v(y)) do if not (HDYN[a] and HDYN[a][b]) then failh('hdyn', a, '*', ('hdyn(%d) lacks %d'):format(a, b)); break end end
                end
            end
        elseif op == 'storeRaw' then
            -- (`storeRaw x f y`, FLOW-0090: x.f = y on the object itself — no __newindex: a constructor's named field)
            local x, f, y = ins[2], ins[3], ins[4]
            for a in pairs(v(x)) do
                if not HOST[a] then for b in pairs(v(y)) do
                    if not hash(a, f, b) then failh('h', a, f, ('h(%d,%s) lacks %d'):format(a, tostring(fieldname(f)), b)); break end
                end end
            end
        elseif op == 'keys' then
            -- (`keys x y`: x holds every key of every table y may hold)
            local x, y = ins[2], ins[3]
            for a in pairs(v(y)) do
                if not HOST[a] then for _, c in ipairs(chain(evLoad, a)) do
                    sub(HKEYS[c] or EMPTY, x, 'keys')
                    if HKEYSTOP[c] and not TOP[x] then fail('keys-top', x, ('the key set of %d is top'):format(c)) end
                end end
            end
        elseif op == 'store' or op == 'storeDyn' then
            local x, f, y = ins[2], op == 'store' and ins[3] or nil, op == 'store' and ins[4] or (DYNKEYS and ins[4] or ins[3])
            local k = op == 'storeDyn' and DYNKEYS and ins[3] ~= NULL and ins[3] or nil
            for a in pairs(v(x)) do
                if not HOST[a] then for _, c in ipairs(chain(evStore, a)) do
                    -- (a dynamic store's key joins the target's key set)
                    if k and not HKEYSTOP[c] then for b in pairs(v(k)) do if not (HKEYS[c] and HKEYS[c][b]) then failh('hkeys', c, '*', ('hkeys(%d) lacks %d'):format(c, b)); break end end end
                    for b in pairs(v(y)) do
                        if f and not hash(c, f, b) then failh('h', c, f, ('h(%d,%s) lacks %d'):format(c, tostring(fieldname(f)), b)); break end
                        if not f and not (HDYN[c] and HDYN[c][b]) then failh('hdyn', c, '*', ('hdyn(%d) lacks %d'):format(c, b)); break end
                    end
                end end
                for _, c in ipairs(chain(evStoreLook, a)) do
                    for _, t in ipairs(handlers(NIDX, c)) do entry(F.id, FNOF[t], t, { { [c] = true }, EMPTY, v(y) }, {}, false) end
                end
            end
        elseif op == 'call' or op == 'pcall' then
            local xs, fv, args = ins[2], ins[3], ins[4]
            local srcs = {}
            for i, a in ipairs(args) do srcs[i] = v(a) end
            for a in pairs(v(fv)) do
                if FNOF[a] then entry(F.id, FNOF[a], a, srcs, xs, op == 'pcall') end
                -- (contract unknown-code: calling an ext site hands the arguments to the unknown-code channel)
                if a == EXTSITE and EXTCH then for _, s2 in ipairs(srcs) do sub(s2, EXTCH, 'unknown-code') end end
                for _, t in ipairs(handlers(CALLK, a)) do
                    local s2 = { { [a] = true } }
                    for _, s in ipairs(srcs) do s2[#s2 + 1] = s end
                    entry(F.id, FNOF[t], t, s2, xs, op == 'pcall')
                end
            end
        elseif op == 'error' then subport(v(ins[2]), F.id, 'error')
        elseif op == 'op' then
            local x, ys, k = ins[2], ins[3], ins[4]
            local srcs = {}
            for i, y in ipairs(ys) do srcs[i] = v(y) end
            for _, y in ipairs(ys) do
                for a in pairs(v(y)) do for _, t in ipairs(handlers(k, a)) do entry(F.id, FNOF[t], t, srcs, { x }, false) end end
            end
        elseif op == 'setmeta' then
            for a in pairs(v(ins[2])) do if not HOST[a] then for b in pairs(v(ins[3])) do
                if not hash(a, META, b) then
                    failh(FNOF[a] and 'meta-on-function(model)' or 'meta', a, META, ('h(%d,META) lacks %d'):format(a, b)); break
                end
            end end end
        elseif op == 'cocreate' then
            local x, a, fv = ins[2], ins[3], ins[4]
            if not hasv(x, a) then fail('cocreate', x, 'v lacks the thread') end
            for b in pairs(v(fv)) do
                local g2 = FNOF[b]
                if g2 and CODE[g2] then
                    for _, p in ipairs(CODE[g2].params) do sub(RIN, p, 'rin') end
                    if not hasv(CODE[g2].self, b) then fail('self', CODE[g2].self, 'self') end
                    for _, i2 in ipairs(CODE[g2].body) do if i2[1] == 'ret' then for _, y in ipairs(i2[2]) do
                        for c in pairs(v(y)) do if not ROUT[c] then fail('baserets', nil, 'rout lacks ' .. c); break end end
                    end end end
                    for s in pairs(PORT[g2] or EMPTY) do if not CERR[s] then fail('cerr', nil, 'cerr lacks ' .. s); break end end
                end
            end
        elseif op == 'resume' then
            local xs, args = ins[2], ins[4]
            for _, y in ipairs(args) do for c in pairs(v(y)) do if not RIN[c] then fail('rin', nil, 'rin lacks ' .. c); break end end end
            for i = 2, #xs do sub(ROUT, xs[i], 'rout') end
            if xs[2] then sub(CERR, xs[2], 'cerr') end
        elseif op == 'yield' then
            local xs, ys = ins[2], ins[3]
            for _, y in ipairs(ys) do for c in pairs(v(y)) do if not ROUT[c] then fail('rout', nil, 'rout lacks ' .. c); break end end end
            for _, x in ipairs(xs) do sub(RIN, x, 'rin') end
        end
    end
end
-- GcOK: every finalizer runs with its object
cur = { g = -1, i = -1, ins = { 'gc' } }
for _, st in ipairs(D.sites) do
    for _, t in ipairs(handlers(GCK, st.id)) do
        local F = CODE[FNOF[t]]
        if F and F.params[1] and not hasv(F.params[1], st.id) then fail('gc', F.params[1], 'finalizer param lacks ' .. st.id) end
    end
end

-- completeness proxy: written variables
local written = {}
local function w(x) written[x] = true end
for _, F in ipairs(D.functions) do
    for _, p in ipairs(F.params) do w(p) end
    w(F.self)
    for _, ins in ipairs(F.body) do
        local op = ins[1]
        if op == 'new' or op == 'copy' or op == 'load' or op == 'loadDyn' or op == 'loadRaw' or op == 'op' or op == 'cocreate' or op == 'keys' then w(ins[2])
        elseif op == 'call' or op == 'pcall' or op == 'resume' or op == 'yield' then for _, x in ipairs(ins[2]) do w(x) end end
    end
end
for _, g in ipairs(D.gaps) do for _, x in ipairs(g.vars) do w(x) end end -- (a gap names what the IR could not write)
if EXTCH then w(EXTCH) end -- (the unknown-code channel: written by the contract, not an instruction)
local unwritten = 0
local uex = {}
for x, t in pairs(V) do if next(t) and not written[x] then unwritten = unwritten + 1; if #uex < 5 then uex[#uex + 1] = x end end end

return { ninst = ninst, functions = #D.functions, sites = #D.sites, failed = nfail, excused = excused, counts = counts,
    fails = fails, unwritten = unwritten, unwritten_ex = uex }
end

return M
