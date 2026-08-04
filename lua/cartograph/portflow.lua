-- PORTFLOW — anonymous-type COMPATIBILITY CLASSES from observed flow (CART-0267).
--
-- For a library function we cannot see, the types can never be NAMED. But if
-- `FindComponent`'s return flows into `RemoveFromParent`'s first argument, those two
-- anonymous PORTS are observably interchangeable — and sweeping the corpus for such flows
-- partitions opaque values into compatibility classes with no declarations anywhere. You
-- do not need the name, you need the partition ([[cartograph-anonymous-types]]).
--
-- A PORT is (callee, slot), slot ∈ { ret, self, aN }. An EDGE is one observed flow, so the
-- relation is EVIDENCE and never a declaration; each edge carries how many SITES observed
-- it. Union-find over the edges gives the classes — congruence closure, no solver.
--
-- THIS MODULE IS THE ONE IMPLEMENTATION. tools/portgraph.lua (the measurement harness)
-- reads it too, so the probe's numbers and the verb's display cannot diverge — the same
-- rule extractapply follows for its splice (CART-0125).
--
-- ── WHAT IT REFUSES TO CLAIM ────────────────────────────────────────────────
-- A class is NOT a type. It is "these ports were observed interchangeable", and the
-- surface says so: a class shows its evidence, a declared name appears only where a
-- declaration exists and is marked a CLAIM (docblocks lie — that is why
-- annotation-mismatch exists), two declarations inside one class are reported as a
-- CONFLICT and never resolved by majority, and the UNLINKED ports are counted out loud
-- rather than omitted — an absent relationship is the honest frontier, and rendering it
-- as silence is the recurring defect class ([[cartograph-concern-layering]]).
--
-- ── THE OPERATING POINT, AND WHY IT IS NOT A KNOB HERE ──────────────────────
-- `bare` (an unqualified, non-project callee whose degree clears MDEG) + degree>=12 was
-- chosen by measurement, not taste: it is the most aggressive setting at which every
-- hand-read real class survives on both calibration corpora (CART-0269). Weight
-- thresholding is deliberately NOT applied — measured, it improves the headline by
-- shattering the graph and destroys every real class (CART-0270). tools/portgraph.lua
-- prints both curves; this module ships the chosen point.
--
-- COST: builds from source via expr.of per function, so it is a whole-graph pass measured
-- in tens of seconds on a large corpus. The partition is inherently global — a class spans
-- files — so it CANNOT be scoped to one file. Cached by store.generation, the same
-- discipline as clones' fn index.

local M = {}
local expr = require 'cartograph.expr'
local annot = require 'cartograph.annot'
local txn = require 'cartograph.txn'
local at = require 'cartograph.at'

M.MDEG = 3        -- a bare name fuses receivers only once >=3 actually flow in
M.DEGREE = 12     -- the measured operating point (CART-0269)

-- ── union-find ──────────────────────────────────────────────────────────────
local UF = {}
UF.__index = UF
local function uf() return setmetatable({ p = {}, n = 0 }, UF) end
function UF:add(k)
    if self.p[k] == nil then self.p[k] = k; self.n = self.n + 1 end
    return k
end
function UF:find(k)
    local p = self.p
    while p[k] ~= k do p[k] = p[p[k]]; k = p[k] end
    return k
end
function UF:union(a, b)
    local ra, rb = self:find(self:add(a)), self:find(self:add(b))
    if ra ~= rb then self.p[ra] = rb end
end

function M.port(name, slot) return name .. '#' .. slot end
function M.callee_of(p) return (p:match('^(.*)#[^#]*$')) or p end
function M.slot_of(p) return p:match('#([^#]*)$') end

-- ── one function's observed flows ───────────────────────────────────────────
-- Off the expr IR: a call node is { k='call', f=<callee>, a={args}, method=bool }, and
-- expr.dotted turns a name/field chain into the qualified callee name (nil for a computed
-- callee, which is SKIPPED rather than guessed — the genuinely dynamic frontier).
local function flows_of(store, node, emit)
    local eo = expr.of(store, node.id)
    local fl = eo and eo.fl
    if not fl then return end
    local prod = {}
    for _, s in ipairs(fl.stmts or {}) do
        local first = s.expr and s.expr.rhs and s.expr.rhs[1]
        if first and first.k == 'call' and s.def then
            local cn = expr.dotted(first.f)
            if cn then for _, d in ipairs(s.def) do prod[d] = cn end end
        end
    end
    local function visit(e)
        if type(e) ~= 'table' then return end
        if e.k == 'call' then
            -- a METHOD call keys on the method SEGMENT: expr.dotted would return
            -- `h.Destroy`, folding the receiver VARIABLE into the callee's identity when
            -- not knowing the receiver's type is the entire point.
            local cname = e.method and e.f and e.f.n or expr.dotted(e.f)
            if cname then
                if e.method and e.f.b then
                    local rn = (e.f.b.k == 'name') and e.f.b.n or nil
                    if rn and prod[rn] then
                        emit(M.port(prod[rn], 'ret'), M.port(cname, 'self'))
                    elseif e.f.b.k == 'call' then
                        local inner = expr.dotted(e.f.b.f)
                        if inner then emit(M.port(inner, 'ret'), M.port(cname, 'self')) end
                    end
                end
                for i, a in ipairs(e.a or {}) do
                    if a.k == 'name' and prod[a.n] then
                        emit(M.port(prod[a.n], 'ret'), M.port(cname, 'a' .. i))
                    elseif a.k == 'call' then
                        local inner = expr.dotted(a.f)
                        if inner then emit(M.port(inner, 'ret'), M.port(cname, 'a' .. i)) end
                    end
                end
            end
        end
        for k, v in pairs(e) do
            if (k ~= 'f' or e.k ~= 'call') and type(v) == 'table' then visit(v) end
        end
        if e.k == 'call' and e.f then visit(e.f) end
    end
    for _, s in ipairs(fl.stmts or {}) do
        if s.expr then
            for _, x in ipairs(s.expr.rhs or {}) do visit(x) end
            for _, x in ipairs(s.expr.lhs or {}) do visit(x) end
            if s.expr.cond then visit(s.expr.cond) end
        end
    end
end

--- Collect the observed flows with NO unification: the rules need every port's DEGREE
--- before deciding which ports may unify. `w[pair]` = how many SITES observed that exact
--- pair; degree = DISTINCT partners. Two axes, deliberately not conflated.
function M.collect(store)
    local known = {}
    for _, n in ipairs(store.data.nodes or {}) do
        if n.name then
            known[n.name] = true
            local last = n.name:match('([%w_]+)$')
            if last then known[last] = true end
        end
    end
    local edges, seen, pcount, w = {}, {}, {}, {}
    local function emit(a, b)
        local k = a .. '\1' .. b
        if seen[k] then w[k] = w[k] + 1; return end
        seen[k] = true; w[k] = 1
        edges[#edges + 1] = { a, b }
        pcount[a] = (pcount[a] or 0) + 1
        pcount[b] = (pcount[b] or 0) + 1
    end
    local nfn = 0
    for _, n in ipairs(store.data.nodes or {}) do
        if (n.kind == 'function' or n.kind == 'method') and n.file
            and n.file:match('%.lua$') and n.range then
            nfn = nfn + 1
            pcall(flows_of, store, n, emit)
        end
    end
    local nbr = {}
    for _, e in ipairs(edges) do
        local n = w[e[1] .. '\1' .. e[2]]
        nbr[e[1]] = nbr[e[1]] or {}; table.insert(nbr[e[1]], { e[2], n })
        nbr[e[2]] = nbr[e[2]] or {}; table.insert(nbr[e[2]], { e[1], n })
    end
    for _, l in pairs(nbr) do
        table.sort(l, function (a, b)
            if a[2] ~= b[2] then return a[2] > b[2] end
            return a[1] < b[1]
        end)
    end
    local function is_ext(p)
        local name = M.callee_of(p)
        local last = name:match('([%w_]+)$')
        return not (known[name] or (last and known[last]))
    end
    return { edges = edges, pcount = pcount, w = w, nbr = nbr, nfn = nfn,
        known = known, is_ext = is_ext }
end

--- A UNIVERSAL SINK is a port that unifies values with nothing in common: `ipairs#a1`
--- accepts anything iterable, so every table flows into that ONE port. Its edges are kept
--- but do not TRANSIT, so it ends unified with nothing — the honest answer for a port with
--- no single type. `bare` is DEGREE-GATED because a categorical version condemned a
--- one-receiver engine method (CART-0269).
function M.sinks_of(col, opts)
    local s = {}
    local mdeg = (opts.bare == true) and M.MDEG or opts.bare
    for p in pairs(col.pcount) do
        local name = M.callee_of(p)
        local deg = col.pcount[p] or 0
        if mdeg and not name:find('.', 1, true) and not col.known[name] and deg >= mdeg then
            s[p] = 'bare'
        elseif opts.degree and deg >= opts.degree then s[p] = 'degree'
        end
    end
    return s
end

function M.partition(col, opts)
    local sinks = M.sinks_of(col, opts)
    local u = uf()
    local minw = opts.minw or 1
    for _, e in ipairs(col.edges) do
        if (col.w[e[1] .. '\1' .. e[2]] or 1) >= minw
            and not (sinks[e[1]] or sinks[e[2]]) then u:union(e[1], e[2]) end
    end
    local cls = {}
    for k in pairs(u.p) do
        local r = u:find(k)
        cls[r] = cls[r] or {}
        table.insert(cls[r], k)
    end
    local list = {}
    for _, members in pairs(cls) do
        if #members > 1 then list[#list + 1] = members end
    end
    table.sort(list, function (a, b)
        if #a ~= #b then return #a > #b end
        return a[1] < b[1]
    end)
    local nsink = 0
    for _ in pairs(sinks) do nsink = nsink + 1 end
    return { uf = u, classes = list, sinks = sinks, nsink = nsink, ports = u.n }
end

--- Are all of `group`'s ports in ONE class? The second side of the acceptance metric.
function M.together(part, group)
    local root
    for _, p in ipairs(group) do
        if not part.uf.p[p] then return false end
        local r = part.uf:find(p)
        if root and r ~= root then return false end
        root = r
    end
    return root ~= nil
end

-- ── declarations name a class (W4) ──────────────────────────────────────────
-- Give ONE member a declared type and the whole class acquires it. The source is
-- ANNOTATIONS, so a profile (CART-0266 / CART-0029) arrives later through the same door.
-- The port↔node link is FUZZY — a port key is the callee AS WRITTEN AT THE CALL SITE
-- (`optimize.cse`) while the node is `M.cse` in optimize.lua — so the index keys each node
-- three ways and callers report the match rate rather than implying completeness.
function M.declarations(store)
    local byname = {}
    local function put(k, v) if k and byname[k] == nil then byname[k] = v end end
    for _, n in ipairs(store.data.nodes or {}) do
        if (n.kind == 'function' or n.kind == 'method') and n.name and n.file then
            local last = n.name:match('([%w_]+)$')
            local base = n.file:match('([%w_]+)%.lua$')
            put(n.name, n); put(last, n)
            if base and last then put(base .. '.' .. last, n) end
        end
    end
    local ts = require 'cartograph.providers.treesitter'
    local flowmod = require 'cartograph.flow'
    local decl, srccache = {}, {}
    for _, n in ipairs(store.data.nodes or {}) do
        if (n.kind == 'function' or n.kind == 'method') and n.file
            and n.file:match('%.lua$') and n.range then
            local lines = srccache[n.file]
            if lines == nil then lines = store.content(n) or false; srccache[n.file] = lines end
            local pat = ts.annot_tag and ts.annot_tag(n.file)
            if lines and pat then
                local s0 = at.sl(n.range)
                local first = txn.attach_above(lines, s0, ts.attach_pats and ts.attach_pats(n.file))
                if first and first < s0 then
                    local tags = annot.read_block(lines, first, pat)
                    if tags and #tags > 0 then
                        -- param INDEX from flow when materialized, node.params otherwise:
                        -- only a NAMED param needs an index, so the fallback is adequate
                        -- and keeps this off the materialization path.
                        local rec = flowmod.present(n) and flowmod.record(n)
                        local plist = (rec and rec.params) or n.params or {}
                        local idx = {}
                        for i, pn in ipairs(plist) do idx[pn] = i end
                        local d = { params = {} }
                        for _, t in ipairs(tags) do
                            if t.kind == 'return' and t.type then d.ret = d.ret or t.type
                            elseif t.kind == 'param' and t.name and t.type and idx[t.name] then
                                d.params[idx[t.name]] = t.type
                            end
                        end
                        if d.ret or next(d.params) then decl[n] = d end
                    end
                end
            end
        end
    end
    return byname, decl
end

--- port → (declared type or nil, resolved-to-a-node bool). An unresolved port and a
--- resolved-but-undeclared one are DIFFERENT answers, so both are returned.
function M.decl_of(byname, decl, p)
    local name = M.callee_of(p)
    local node = byname[name]
    if not node then
        local last = name:match('([%w_]+)$')
        node = last and byname[last]
    end
    if not node then return nil, false end
    local d = decl[node]
    if not d then return nil, true end
    local slot = M.slot_of(p)
    if slot == 'ret' then return d.ret, true end
    local i = slot and slot:match('^a(%d+)$')
    if i then return d.params[tonumber(i)], true end
    return nil, true
end

-- ── the cached whole analysis ───────────────────────────────────────────────
local cache
function M.analyze(store, opts)
    opts = opts or { bare = true, degree = M.DEGREE }
    local key = ('%s|%s|%s'):format(tostring(opts.bare), tostring(opts.degree),
        tostring(opts.minw))
    if cache and cache.gen == store.generation and cache.key == key then return cache.a end
    local col = M.collect(store)
    local part = M.partition(col, opts)
    local byname, decl = M.declarations(store)
    local pdecl, resolved, declared = {}, 0, 0
    local total = 0
    for p in pairs(col.pcount) do
        total = total + 1
        local d, ok = M.decl_of(byname, decl, p)
        if ok then resolved = resolved + 1 end
        if d then declared = declared + 1; pdecl[p] = d end
    end
    -- per class: its declared names (a CLAIM), and whether they conflict
    local info = {}
    for i, m in ipairs(part.classes) do
        local kinds, n = {}, 0
        for _, p in ipairs(m) do
            local d = pdecl[p]
            if d then
                if kinds[d] == nil then kinds[d] = 0; n = n + 1 end
                kinds[d] = kinds[d] + 1
            end
        end
        info[i] = { kinds = kinds, ndistinct = n }
    end
    -- LINKED = in a class of >1. The rest are the honest frontier and are COUNTED, never
    -- omitted: an absent relationship rendered as silence is the recurring defect class.
    local linked = 0
    for _, m in ipairs(part.classes) do linked = linked + #m end
    local a = { col = col, part = part, pdecl = pdecl, info = info,
        stats = { ports = total, resolved = resolved, declared = declared,
            linked = linked, unlinked = total - linked, edges = #col.edges,
            nfn = col.nfn, nsink = part.nsink, classes = #part.classes },
        opts = opts }
    cache = { gen = store.generation, key = key, a = a }
    return a
end

-- ── REPORTS: rows carrying their SUBJECT, so <CR> can descend ───────────────
-- A report returns ROWS, not strings ([[cartograph-interactive-reports]]): `at[i]` is what
-- row i is ABOUT, which is what makes a class a navigable node rather than a dump. Two
-- altitudes and a DOOR between them — the roster lists classes, descending shows one
-- class's ports split by AXIS (producers `#ret` vs consumers `#aN`/`#self`), and descending
-- again shows a port's observed partners with their evidence.

local function decl_summary(inf)
    local ks = {}
    for k, c in pairs(inf.kinds) do ks[#ks + 1] = ('%s x%d'):format(k, c) end
    table.sort(ks)
    if inf.ndistinct == 0 then return nil end
    if inf.ndistinct == 1 then return '~' .. ks[1]:gsub(' x%d+$', '') end
    return 'CONFLICT ' .. table.concat(ks, ' | ')
end

--- The ROSTER: classes ranked, with the frontier counted out loud.
function M.roster(store)
    local a = M.analyze(store)
    local st = a.stats
    local L, at_ = {}, {}
    L[#L + 1] = ('port classes: %d class(es) over %d port(s) from %d observed flow(s)')
        :format(st.classes, st.ports, st.edges)
    L[#L + 1] = ('%d port(s) UNLINKED — no observed flow relates them to anything; that is'
        .. ' the frontier, not an empty answer'):format(st.unlinked)
    L[#L + 1] = ('%d port(s) are UNIVERSAL SINKS (no single type: they accept or produce'
        .. ' anything, so they unify nothing)'):format(st.nsink)
    L[#L + 1] = ('%d/%d port(s) resolve to a definition we can see; %d carry a declared type')
        :format(st.resolved, st.ports, st.declared)
    L[#L + 1] = 'a class is "these ports were observed interchangeable" — NOT a type.'
        .. ' ~name = a DECLARED name, which is a claim (docblocks lie)'
    L[#L + 1] = ''
    for i, m in ipairs(a.part.classes) do
        local d = decl_summary(a.info[i])
        -- NAME THE CLASS BY ITS MEMBERS. A row reading "3 ports" identifies nothing and
        -- the reader cannot tell one class from the next — found by driving the command,
        -- which no unit test would have caught. Highest-degree members first: they are the
        -- ones most likely to be recognizable.
        local mm = {}
        for _, pt in ipairs(m) do mm[#mm + 1] = pt end
        table.sort(mm, function (x, y)
            return (a.col.pcount[x] or 0) > (a.col.pcount[y] or 0)
        end)
        local shown = {}
        for j = 1, math.min(#mm, 3) do shown[#shown + 1] = mm[j] end
        L[#L + 1] = ('  %3d ports %s %s%s%s'):format(#m,
            a.col.is_ext(m[1]) and 'ext' or '   ', table.concat(shown, '  '),
            #mm > 3 and ('  …+' .. (#mm - 3)) or '', d and ('   ' .. d) or '')
        at_[#L] = { kind = 'class', idx = i }
    end
    if #a.part.classes == 0 then
        L[#L + 1] = '  (no class of more than one port — nothing was observed interchangeable)'
    end
    L[#L + 1] = ''
    L[#L + 1] = '<CR> = descend into a class'
    return L, at_
end

--- ONE class: its ports split by AXIS. Producers and consumers are the two directions the
--- design calls axes, and separating them is what makes the class answer "what produces
--- this?" and "what accepts this?" rather than one undifferentiated set.
function M.class_report(store, idx)
    local a = M.analyze(store)
    local m = a.part.classes[idx]
    local L, at_ = {}, {}
    if not m then return { 'port classes: no such class' }, {} end
    local d = decl_summary(a.info[idx])
    L[#L + 1] = ('class of %d port(s)%s'):format(#m, d and ('  —  ' .. d) or
        '  —  no declared name (nothing in this class carries one)')
    if a.info[idx].ndistinct > 1 then
        L[#L + 1] = 'CONFLICTING declarations: this class over-merged, OR the docblocks'
        L[#L + 1] = 'disagree. Not resolved by majority — which side is wrong is exactly'
        L[#L + 1] = 'what a declaration cannot settle.'
    end
    L[#L + 1] = ''
    local prod, cons = {}, {}
    for _, p in ipairs(m) do
        if M.slot_of(p) == 'ret' then prod[#prod + 1] = p else cons[#cons + 1] = p end
    end
    local function bydeg(x, y) return (a.col.pcount[x] or 0) > (a.col.pcount[y] or 0) end
    table.sort(prod, bydeg); table.sort(cons, bydeg)
    for _, group in ipairs({ { 'PRODUCED BY', prod }, { 'ACCEPTED BY', cons } }) do
        L[#L + 1] = ('%s (%d):'):format(group[1], #group[2])
        for _, p in ipairs(group[2]) do
            local dd = a.pdecl[p]
            L[#L + 1] = ('  %-46s %d partner(s)%s'):format(p, a.col.pcount[p] or 0,
                dd and ('  ~' .. dd) or '')
            at_[#L] = { kind = 'port', port = p }
        end
        if #group[2] == 0 then L[#L + 1] = '  (none)' end
    end
    L[#L + 1] = ''
    L[#L + 1] = '<CR> = a port\'s observed partners'
    return L, at_
end

--- ONE port: its partners, ranked by EVIDENCE. The honest form of "what accepts this?" —
--- a ranked list with counts, never a type name we do not have.
function M.port_report(store, p)
    local a = M.analyze(store)
    local L = {}
    local nb = a.col.nbr[p]
    L[#L + 1] = ('port %s'):format(p)
    if a.part.sinks[p] then
        L[#L + 1] = ('UNIVERSAL SINK (%s) — it accepts or produces anything, so it has no'
            .. ' single type and unifies nothing'):format(a.part.sinks[p])
    end
    local dd = a.pdecl[p]
    if dd then L[#L + 1] = ('declared ~%s (a CLAIM, not a fact)'):format(dd) end
    L[#L + 1] = ''
    if not nb then
        L[#L + 1] = 'no observed flows — unlinked. The frontier, not an empty answer.'
        return L, {}
    end
    L[#L + 1] = ('observed interchangeable with %d port(s):'):format(#nb)
    for _, e in ipairs(nb) do
        L[#L + 1] = ('  %-46s at %d site(s)'):format(e[1], e[2])
    end
    return L, {}
end

--- Every port belonging to one function, for the "what about THIS function" entry.
function M.ports_of(store, node)
    local a = M.analyze(store)
    local name = node.name or ''
    local last = name:match('([%w_]+)$') or name
    local base = node.file and node.file:match('([%w_]+)%.lua$')
    local want = { [name] = true, [last] = true }
    if base then want[base .. '.' .. last] = true end
    local out = {}
    for p in pairs(a.col.pcount) do
        if want[M.callee_of(p)] then out[#out + 1] = p end
    end
    table.sort(out)
    return out, a
end

return M
