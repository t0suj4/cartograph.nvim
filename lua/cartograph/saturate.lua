-- saturate — RULES over FACT TERMS to a fixpoint (CART-1525): the STRATEGY half of a rule engine whose kernel is the
-- algebra. A rule is { stratum = n, head = term, body = { term, .. }, absent = { term, .. } }, each term a node of
-- literals and holes; a fact is a ground term. The ALGEBRA does every premise (match — a hole shared by two premises IS
-- the join's equality), every head and negated atom (instantiate), each fact's key (show), the fact set and every join
-- index (a keyed node: a join is a KEY STEP, O(1) since CART-1528). This file is the strategy: premise order (as
-- written, the delta premise first), one index per kind and bound positions, semi-naive rounds per stratum.
--
-- ★ WHY NOT ONE TEMPLATE PER BODY: matching `db(…, P1, …, P2, …)` against an ordered fact sequence enumerates position
-- tuples blindly and checks the shared holes after — a cross product, O(n^k), and the answer then depends on fact
-- ORDER whenever a budget cuts it (measured: 50 min uncapped for what this does in seconds; CART-1525, CART-1527).
-- ⚠ Negation is STRATIFIED and SAFE, both refused by name in compile: a negated atom's relation is complete in an
-- earlier stratum, and every hole of it (and of the head) is bound by the body.
-- ⚠ A stratum that does not converge within opts.rounds RAISES — a cap is never a silent answer (CART-1527).
local M = {}
local unpack = table.unpack or unpack

local function holes_of(t, out)
    out = out or {}
    if type(t) ~= 'table' then return out end
    if t.k == 'hole' then out[t.h] = true end
    for _, c in ipairs(t.kids or {}) do holes_of(c, out) end
    return out
end
local function sorted_keys(s) local r = {}; for k in pairs(s) do r[#r + 1] = k end; table.sort(r); return r end

--- rules -> the compiled rule set, or raises naming the unsafe / unstratified rule
function M.compile(A, rules)
    local heads = {} -- kind -> { stratum, .. } of the rules defining it
    for _, r in ipairs(rules) do heads[r.head.k] = heads[r.head.k] or {}; table.insert(heads[r.head.k], r.stratum) end
    local C = { A = A, strata = {}, rules = {} }
    for ri, r in ipairs(rules) do
        local bound = {}
        for _, atom in ipairs(r.body) do holes_of(atom, bound) end
        local function safe(t, what)
            for h in pairs(holes_of(t)) do
                if not bound[h] then error(('saturate: rule %d (%s): the %s hole `%s` is not bound by the body'):format(ri, r.head.k, what, h), 0) end
            end
        end
        safe(r.head, 'head')
        for _, n in ipairs(r.absent or {}) do
            safe(n, 'negated')
            for _, s in ipairs(heads[n.k] or {}) do
                if s >= r.stratum then
                    error(('saturate: rule %d (%s): negates `%s`, which stratum %d defines — not earlier than %d'):format(ri, r.head.k, n.k, s, r.stratum), 0)
                end
            end
        end
        for _, atom in ipairs(r.body) do
            for _, s in ipairs(heads[atom.k] or {}) do
                if s > r.stratum then
                    error(('saturate: rule %d (%s): reads `%s`, which a LATER stratum %d defines'):format(ri, r.head.k, atom.k, s), 0)
                end
            end
        end
        local cr = { src = r, stratum = r.stratum, head_t = A.template(r.head), tpl = {}, neg_t = {} }
        cr.head_h = sorted_keys(holes_of(r.head))
        -- a FLAT premise (every kid a plain hole or a literal) needs no search: the index lookup on its literal and
        -- bound positions, an arity check and values_at ARE its match — anything else goes through A.match
        cr.flat, cr.H, cr.lits = {}, {}, {}
        for i, atom in ipairs(r.body) do
            cr.tpl[i] = A.template(atom)
            local flat, lits = true, {}
            for p, arg in ipairs(atom.kids or {}) do
                if arg.k == 'lit' then lits[#lits + 1] = { p = p, s = A.show(arg) }
                elseif arg.k ~= 'hole' or arg.rep or arg.ctx then flat = false end
            end
            cr.flat[i], cr.lits[i], cr.H[i] = flat, lits, A.sites(cr.tpl[i])
        end
        for i, n in ipairs(r.absent or {}) do cr.neg_t[i] = { t = A.template(n), h = sorted_keys(holes_of(n)) } end
        C.rules[#C.rules + 1] = cr
        if not C.strata[r.stratum] then C.strata[r.stratum] = {} end
        table.insert(C.strata[r.stratum], cr)
    end
    C.order = sorted_keys(C.strata)
    return C
end

local SEP = '\31'

--- the compiled rules over `facts` (ground terms) to a fixpoint -> { facts = list in canonical (key) order,
--- by = { kind -> list }, has = function (term) -> bool, stats = { rounds, matches, lookups } }.
--- opts.rounds: the per-stratum cap (default 10000), a RAISE when reached.
function M.run(C, facts, opts)
    local A = C.A
    local cap = opts and opts.rounds or 10000
    local key, pairof = {}, {} -- fact -> its key (show, once) and its pair in the fact set
    local all, by = {}, {}
    local stats = { rounds = 0, matches = 0, lookups = 0 }
    local function add(f, k)
        key[f] = k; pairof[f] = A.node('pair', A.lit(k), f)
        all[#all + 1] = f
        local l = by[f.k]; if not l then l = {}; by[f.k] = l end
        l[#l + 1] = f
    end
    do
        local seen, init = {}, {}
        for _, f in ipairs(facts) do local k = A.show(f); if not seen[k] then seen[k] = true; init[#init + 1] = { k, f } end end
        table.sort(init, function (a, b) return a[1] < b[1] end)
        for _, kf in ipairs(init) do add(kf[2], kf[1]) end
    end
    local db, idxc
    local function rebuild()
        local kids = {}
        for i, f in ipairs(all) do kids[i] = pairof[f] end
        db = A.keyed('facts', kids)
        idxc = {}
    end
    local argkey = setmetatable({}, { __mode = 'k' })
    local function show_arg(t) local s = argkey[t]; if not s then s = A.show(t); argkey[t] = s end; return s end
    local function index(kind, pos)
        local sig = kind .. ':' .. table.concat(pos, ',')
        local ix = idxc[sig]
        if ix then return ix end
        local groups, order = {}, {}
        for _, f in ipairs(by[kind] or {}) do
            local parts = {}
            for j, p in ipairs(pos) do parts[j] = show_arg(f.kids[p]) end
            local k = table.concat(parts, SEP)
            local g = groups[k]
            if not g then g = {}; groups[k] = g; order[#order + 1] = k end
            g[#g + 1] = f
        end
        local kids = {}
        for i, k in ipairs(order) do kids[i] = A.node('pair', A.lit(k), A.node('group', unpack(groups[k]))) end
        ix = A.keyed('index', kids)
        idxc[sig] = ix
        return ix
    end
    local function has(t) stats.lookups = stats.lookups + 1; return A.kid_by_key(db, A.show(t)) ~= nil end
    local function pick(V, hs) local o = {}; for _, h in ipairs(hs) do o[h] = V[h] end; return o end
    -- one rule, premise j over `src` (kind -> list), the rest through the indexes; `emit` gets each binding
    local function eval(cr, j, src, emit)
        local body = cr.src.body
        local ord = { j }
        for i = 1, #body do if i ~= j then ord[#ord + 1] = i end end
        local function step(n, b)
            if n > #ord then return emit(b) end
            local i = ord[n]
            local atom = body[i]
            local cands
            if n == 1 then cands = src[atom.k] or {}
            else
                local pos, parts = {}, {}
                for p, arg in ipairs(atom.kids or {}) do
                    if arg.k ~= 'hole' then pos[#pos + 1] = p; parts[#parts + 1] = show_arg(arg)
                    elseif b[arg.h] ~= nil then pos[#pos + 1] = p; parts[#parts + 1] = show_arg(b[arg.h]) end
                end
                stats.lookups = stats.lookups + 1
                local g = A.kid_by_key(index(atom.k, pos), table.concat(parts, SEP))
                cands = g and g.kids[2].kids or {}
            end
            local flat, arity, lits = cr.flat[i], #(atom.kids or {}), cr.lits[i]
            for _, f in ipairs(cands) do
                stats.matches = stats.matches + 1
                local V
                if flat then
                    -- (the index guaranteed the literal and bound positions past the first premise; the first one
                    -- is a scan of its kind, so its literals are checked here)
                    local fits = #(f.kids or {}) == arity
                    if fits and n == 1 then
                        for _, l in ipairs(lits) do if show_arg(f.kids[l.p]) ~= l.s then fits = false; break end end
                    end
                    if fits then
                        local conflicts
                        V, conflicts = A.values_at(f, cr.H[i])
                        if #conflicts > 0 then V = nil end
                    end
                else
                    local m = A.match(cr.tpl[i], f)
                    V = m.ok and m.values or nil
                end
                if V then
                    local nb, agree = {}, true
                    for k, v in pairs(b) do nb[k] = v end
                    for h, v in pairs(V) do
                        if nb[h] == nil then nb[h] = v elseif show_arg(nb[h]) ~= show_arg(v) then agree = false; break end
                    end
                    if agree then step(n + 1, nb) end
                end
            end
        end
        step(1, {})
    end
    for _, s in ipairs(C.order) do
        local rules, idb = C.strata[s], {}
        for _, cr in ipairs(rules) do idb[cr.src.head.k] = true end
        local delta
        local converged = false
        for round = 1, cap do
            stats.rounds = stats.rounds + 1
            rebuild()
            local pending, fresh = {}, {}
            for _, cr in ipairs(rules) do
                local function out(b)
                    -- (apply: compile proved every hole of a head and a negated atom bound, so substitution IS
                    -- instantiation here — ground, with no domain to check)
                    for _, n in ipairs(cr.neg_t) do
                        if has(A.apply(n.t, pick(b, n.h)).body) then return end
                    end
                    local h = { term = A.apply(cr.head_t, pick(b, cr.head_h)).body }
                    local k = A.show(h.term)
                    stats.lookups = stats.lookups + 1
                    if not pending[k] and not A.kid_by_key(db, k) then pending[k] = true; fresh[#fresh + 1] = { k, h.term } end
                end
                if round == 1 then eval(cr, 1, by, out)
                else
                    for j, atom in ipairs(cr.src.body) do
                        if idb[atom.k] and delta[atom.k] then eval(cr, j, delta, out) end
                    end
                end
            end
            if #fresh == 0 then converged = true; break end
            table.sort(fresh, function (a, b) return a[1] < b[1] end)
            delta = {}
            for _, kf in ipairs(fresh) do
                add(kf[2], kf[1])
                local l = delta[kf[2].k]; if not l then l = {}; delta[kf[2].k] = l end
                l[#l + 1] = kf[2]
            end
        end
        if not converged then error(('saturate: stratum %s did not converge in %d rounds'):format(tostring(s), cap), 0) end
    end
    rebuild()
    local sorted = {}
    for i, f in ipairs(all) do sorted[i] = f end
    table.sort(sorted, function (a, b) return key[a] < key[b] end)
    return { facts = sorted, by = by, has = has, stats = stats }
end

return M
