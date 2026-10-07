-- saturate — RULES over FACT TERMS to a fixpoint (CART-1525): the STRATEGY half of a rule engine whose kernel is the
-- algebra. A rule is { stratum = n, head = term, body = { term, .. }, absent = { term, .. } }, each term a node of
-- literals and holes; a fact is a ground term. The ALGEBRA does every nested premise (match — a hole shared by two
-- premises IS the join's equality), every key (show), the terms (node; apply for a nested head). This file is the
-- STRATEGY: the join order (compile's, most-bound premise next), the fact set and one index per kind and bound
-- positions (maps grown as facts arrive — CART-1528's keyed nodes are the same lookups as terms), a flat premise read
-- by position, semi-naive rounds per stratum.
--
-- ★ WHY NOT ONE TEMPLATE PER BODY: matching `db(…, P1, …, P2, …)` against an ordered fact sequence enumerates position
-- tuples blindly and checks the shared holes after — a cross product, O(n^k), and the answer then depends on fact
-- ORDER whenever a budget cuts it (measured: 50 min uncapped for what this does in seconds; CART-1525, CART-1527).
-- ⚠ Negation is STRATIFIED and SAFE, both refused by name in compile: a negated atom's relation is complete in an
-- earlier stratum, and every hole of it (and of the head) is bound by the body.
-- ⚠ A stratum that does not converge within opts.rounds RAISES — a cap is never a silent answer (CART-1527).
local M = {}
-- (no `unpack` alias and no metatable in the engine: mix specializes it to a rule set — CART-1535 — and knows the
-- global `unpack`, not a file-local value)

local function holes_of(t, out)
    out = out or {}
    if type(t) ~= 'table' then return out end
    if t.k == 'hole' then out[t.h] = true end
    for _, c in ipairs(t.kids or {}) do holes_of(c, out) end
    return out
end
local function sorted_keys(s) local r = {}; for k in pairs(s) do r[#r + 1] = k end; table.sort(r); return r end
-- a FLAT atom: every kid a literal or a plain hole — its ground instance is the term former over the bound values
local function flat_atom(atom)
    for _, arg in ipairs(atom.kids or {}) do if arg.k ~= 'lit' and (arg.k ~= 'hole' or arg.rep or arg.ctx) then return false end end
    return true
end

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
        -- bound positions, an arity check and its holes read by position ARE its match — anything else is A.match
        cr.flat, cr.slots, cr.lits = {}, {}, {}
        for i, atom in ipairs(r.body) do
            cr.tpl[i] = A.template(atom)
            local flat, lits = true, {}
            for p, arg in ipairs(atom.kids or {}) do
                if arg.k == 'lit' then lits[#lits + 1] = { p = p, s = A.show(arg) }
                elseif arg.k ~= 'hole' or arg.rep or arg.ctx then flat = false end
            end
            local slots = {}
            for p, arg in ipairs(atom.kids or {}) do if arg.k == 'hole' then slots[#slots + 1] = { h = arg.h, p = p } end end
            cr.flat[i], cr.lits[i], cr.slots[i] = flat, lits, slots
        end
        -- the JOIN ORDER from each starting premise, fixed here: next the premise with the most literal or already-bound
        -- positions (ties: as written) — a premise nothing binds yet would be a scan of its whole kind per binding
        cr.ord = {}
        for j = 1, #r.body do
            local ord, bound, used = { j }, holes_of(r.body[j]), { [j] = true }
            for _ = 2, #r.body do
                local best, score = nil, -1
                for i, atom in ipairs(r.body) do
                    if not used[i] then
                        local s = 0
                        for _, arg in ipairs(atom.kids or {}) do
                            if arg.k ~= 'hole' or bound[arg.h] then s = s + 1 end
                        end
                        if s > score then best, score = i, s end
                    end
                end
                ord[#ord + 1] = best; used[best] = true
                holes_of(r.body[best], bound)
            end
            cr.ord[j] = ord
        end
        -- each later step's LOOKUP PLAN under that order, fixed here too: which positions key the index (a literal, or
        -- a hole an earlier premise bound), the literal's key part, the index signature, and a key buffer to reuse
        cr.plan = {}
        for j = 1, #r.body do
            local bound, plans = holes_of(r.body[j]), {}
            for n = 2, #cr.ord[j] do
                local atom = r.body[cr.ord[j][n]]
                local pos, src = {}, {}
                for p, arg in ipairs(atom.kids or {}) do
                    if arg.k ~= 'hole' then pos[#pos + 1] = p; src[#src + 1] = { s = A.show(arg) }
                    elseif bound[arg.h] then pos[#pos + 1] = p; src[#src + 1] = { h = arg.h } end
                end
                plans[n] = { pos = pos, src = src, sig = atom.k .. ':' .. table.concat(pos, ','), buf = {} }
                holes_of(atom, bound)
            end
            cr.plan[j] = plans
        end
        for i, n in ipairs(r.absent or {}) do cr.neg_t[i] = { t = A.template(n), h = sorted_keys(holes_of(n)), atom = n, flat = flat_atom(n) } end
        cr.head_flat = flat_atom(r.head)
        C.rules[#C.rules + 1] = cr
        if not C.strata[r.stratum] then C.strata[r.stratum] = {} end
        table.insert(C.strata[r.stratum], cr)
    end
    C.order = sorted_keys(C.strata)
    return C
end

local SEP, EMPTY = '\31', {}

--- the compiled rules over `facts` (ground terms) to a fixpoint -> { facts = list in canonical (key) order,
--- by = { kind -> list }, has = function (term) -> bool, stats = { rounds, matches, lookups } }.
--- opts.rounds: the per-stratum cap (default 10000), a RAISE when reached; opts.list = false: no `facts` list (a
--- caller reading `by` and `has` skips its sort — the derived SET does not depend on order either way).
--- ★ The fact set and the join indexes are THIS STRATEGY's maps (key -> fact, key -> group), grown as facts arrive —
--- a key is the algebra's `show`. Expressed as keyed nodes and key steps they are the same lookups (measured in the
--- CART-1525 throwaway, 960/0/0); as the engine's own maps they are built once, not once a round.
function M.run(C, facts, opts)
    local A = C.A
    local cap = opts and opts.rounds or 10000
    local key, have = {}, {} -- fact -> its key (show, once); key -> the fact
    local all, by = {}, {}
    local idx = {} -- sig (kind:positions) -> { pos, kind, groups = { key -> list } }, kept current by add
    local idx_of = {} -- kind -> { idx entries over it }
    local stats = { rounds = 0, matches = 0, lookups = 0 }
    local argkey = {} -- (one run's: freed with it)
    local function show_arg(t) local s = argkey[t]; if not s then s = A.show(t); argkey[t] = s end; return s end
    local function group_key(f, pos)
        local parts = {}
        for j, p in ipairs(pos) do parts[j] = show_arg(f.kids[p]) end
        return table.concat(parts, SEP)
    end
    local function add(f, k)
        key[f] = k; have[k] = f
        all[#all + 1] = f
        local l = by[f.k]; if not l then l = {}; by[f.k] = l end
        l[#l + 1] = f
        for _, ix in ipairs(idx_of[f.k] or {}) do
            local gk = group_key(f, ix.pos)
            local g = ix.groups[gk]; if not g then g = {}; ix.groups[gk] = g end
            g[#g + 1] = f
        end
    end
    do
        local init = {}
        for _, f in ipairs(facts) do local k = A.show(f); if not have[k] then have[k] = f; init[#init + 1] = { k, f } end end
        table.sort(init, function (a, b) return a[1] < b[1] end) -- (the canonical order every index and round reads)
        have = {}
        for _, kf in ipairs(init) do add(kf[2], kf[1]) end
    end
    local function index(kind, pos, sig)
        local ix = idx[sig]
        if ix then return ix end
        ix = { pos = pos, groups = {} }
        for _, f in ipairs(by[kind] or {}) do
            local gk = group_key(f, pos)
            local g = ix.groups[gk]; if not g then g = {}; ix.groups[gk] = g end
            g[#g + 1] = f
        end
        idx[sig] = ix
        idx_of[kind] = idx_of[kind] or {}
        table.insert(idx_of[kind], ix)
        return ix
    end
    local function has(t) stats.lookups = stats.lookups + 1; return have[A.show(t)] ~= nil end
    local function pick(V, hs) local o = {}; for _, h in ipairs(hs) do o[h] = V[h] end; return o end
    -- the ground instance of a head or negated atom under b: a FLAT atom is its kind over the bound values (the term
    -- former itself); anything else is apply's substitution (compile proved every hole bound — no domain to check)
    local function ground(atom, t, hs, b, flat)
        if not flat then return A.apply(t, pick(b, hs)).body end
        local kids = {}
        for i, arg in ipairs(atom.kids or {}) do kids[i] = arg.k == 'hole' and b[arg.h] or arg end
        return A.node(atom.k, unpack(kids))
    end
    -- one rule, premise j over `src` (kind -> list), the rest through the indexes in compile's join order
    local function eval(cr, j, src, emit)
        local body = cr.src.body
        local ord = cr.ord[j]
        local function step(n, b)
            if n > #ord then return emit(b) end
            local i = ord[n]
            local atom = body[i]
            local cands
            if n == 1 then cands = src[atom.k] or {}
            else
                local pl = cr.plan[j][n]
                local buf = pl.buf
                for q, s in ipairs(pl.src) do buf[q] = s.s or show_arg(b[s.h]) end
                stats.lookups = stats.lookups + 1
                cands = index(atom.k, pl.pos, pl.sig).groups[table.concat(buf, SEP, 1, #pl.src)] or EMPTY
            end
            local flat, arity, lits, slots = cr.flat[i], #(atom.kids or {}), cr.lits[i], cr.slots[i]
            for _, f in ipairs(cands) do
                stats.matches = stats.matches + 1
                local V
                if flat then
                    -- (the index guaranteed the literal and bound positions past the first premise; the first one is a
                    -- scan of its kind, so its literals are checked here. A hole's value is the kid at its position —
                    -- the position lens's one step; a hole that occurs twice must read one value)
                    local fits = #(f.kids or {}) == arity
                    if fits and n == 1 then
                        for _, l in ipairs(lits) do if show_arg(f.kids[l.p]) ~= l.s then fits = false; break end end
                    end
                    if fits then
                        V = {}
                        for _, s in ipairs(slots) do
                            local v = f.kids[s.p]
                            if V[s.h] == nil then V[s.h] = v elseif show_arg(V[s.h]) ~= show_arg(v) then V = nil; break end
                        end
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
            local pending, fresh = {}, {}
            for _, cr in ipairs(rules) do
                local function out(b)
                    for _, n in ipairs(cr.neg_t) do
                        if has(ground(n.atom, n.t, n.h, b, n.flat)) then return end
                    end
                    local term = ground(cr.src.head, cr.head_t, cr.head_h, b, cr.head_flat)
                    local k = A.show(term)
                    stats.lookups = stats.lookups + 1
                    if not pending[k] and not have[k] then pending[k] = true; fresh[#fresh + 1] = { k, term } end
                end
                if round == 1 then eval(cr, 1, by, out)
                else
                    for j, atom in ipairs(cr.src.body) do
                        if idb[atom.k] and delta[atom.k] then eval(cr, j, delta, out) end
                    end
                end
            end
            if #fresh == 0 then converged = true; break end
            -- (a round's new facts join the set at its END: every premise of the round read one state)
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
    local sorted
    if not (opts and opts.list == false) then
        sorted = {}
        for i, f in ipairs(all) do sorted[i] = f end
        table.sort(sorted, function (a, b) return key[a] < key[b] end)
    end
    return { facts = sorted, by = by, has = has, stats = stats }
end

return M
