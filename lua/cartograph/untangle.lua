-- Untangle LENS (pure, read-only). Given a function's statement-level data-flow
-- (`df`), partition its statements into independent chains of computation
-- ("concerns") over the data-dependency edges, and measure how interleaved they
-- are in source order.
--
-- This REVEALS tangle; it does not fix it. Reordering code safely needs the full
-- PDG (control + anti/output deps + side-effect ordering) which `df` does not
-- carry — so `analyze(df)` is a comprehension/diagnostic lens over local data
-- flow, not a transformation and not a safety claim.
--
-- INC 1 of the PDG upgrade ([[cartograph-untangle-pdg]]): `analyze_flow(flow)` is
-- the FINE, data-precise sibling — same partition/metrics, but over flow's fine
-- rows (all nesting levels, so control bodies stop folding into one blob) with
-- data-dependency edges from `flow.reaching_cfg` (scope-aware, branch-join/loop
-- precise) instead of df's coarse first-def-wins `dep`. STILL data-deps only
-- (comprehension, not yet a safety claim — control + anti/output + side-effect
-- ordering are INC 2/3). It sits BESIDE analyze until the arc completes.
--
-- Use headless (analyze → safety check → extract plan; :CartographUntangle /
-- UntangleModule are the interactive face):
--   local un = require 'cartograph.untangle'
--   local res = un.analyze_flow(flow)          -- concerns + interleave metrics
--   if un.concern_safe(res, c) then            -- else un.why_unsafe(res)
--       local plan = un.extract_plan(store, fn_id, res, c, 'name')  -- an extract.plan
--   end                                        -- (plan.ok; feed to extract.apply)
--   -- module scope: un.analyze_module(store, file) → un.module_safe(res, c)
--   --               → un.extract_module(store, res, c, 'sub/dest.lua')

local flowmod = require 'cartograph.flow'
local callrec = require 'cartograph.callrec'

local M = {}

-- union-find over 1..n joined by the (a,b) edges `add_edges(union, span)` emits
-- (span reports each def→use distance for maxspan), then component labelling +
-- interleaving metrics. Shared by analyze/analyze_flow so the two dep sources
-- (df.dep vs reaching_cfg) differ ONLY in which edges they feed. Concerns are
-- labelled by first appearance in ROW order (0-based: A, B, C…); a perfectly
-- grouped function switches exactly ncomp-1 times, so tangle = the excess.
local function partition(n, add_edges)
    if n == 0 then return { n = 0, ncomp = 0, comp = {}, sizes = {}, switches = 0, tangle = 0, maxspan = 0 } end
    local parent = {}
    for i = 1, n do parent[i] = i end
    local function find(x)
        while parent[x] ~= x do parent[x] = parent[parent[x]]; x = parent[x] end
        return x
    end
    local function union(a, b)
        local ra, rb = find(a), find(b)
        if ra ~= rb then parent[ra] = rb end
    end
    local maxspan = 0
    local function span(d) if d > maxspan then maxspan = d end end
    add_edges(union, span)

    local root2comp, comp, next_id = {}, {}, 0
    for i = 1, n do
        local r = find(i)
        if root2comp[r] == nil then root2comp[r] = next_id; next_id = next_id + 1 end
        comp[i] = root2comp[r]
    end
    local ncomp = next_id
    local sizes = {}
    for i = 1, n do sizes[comp[i]] = (sizes[comp[i]] or 0) + 1 end
    local switches = 0
    for i = 1, n - 1 do if comp[i] ~= comp[i + 1] then switches = switches + 1 end end
    local tangle = math.max(0, switches - math.max(0, ncomp - 1))
    return { n = n, ncomp = ncomp, comp = comp, sizes = sizes,
             switches = switches, tangle = tangle, maxspan = maxspan }
end

-- Greedy agglomerative modularity (Clauset–Newman–Moore, deterministic). Where
-- `partition` answers "are a and b connected AT ALL" (ANY edge merges them — the
-- SOUND independence claim), this answers "do a and b sit in the same COHESIVE
-- cluster" — groups linked more densely inside than across the boundary. Because
-- merging two disconnected communities can only LOWER modularity, the result is a
-- strict refinement of the connected components: it never contradicts the safety
-- verdict, it just finds sub-structure INSIDE a connected blob that components are
-- blind to (the [[cartograph-untangle-pdg]] "cohesive blob" case — one concern,
-- but with natural seams). NOT a safety claim: communities DO share edges across
-- their boundary, so cutting them apart BREAKS real dependencies — the returned
-- `cut`/`crossing` is exactly that price. Edges are undirected; repeated (a,b)
-- pairs accumulate as weight = coupling strength.
--- @param n integer  node count (1..n)
--- @param edges { [1]:integer, [2]:integer, kind?:string, w?:number }[]
--- @return { comp:integer[], ncomp:integer, modularity:number, cut:number,
---           crossing: table[], sizes:table }
function M.communities(n, edges)
    if n == 0 then return { comp = {}, ncomp = 0, modularity = 0, cut = 0, crossing = {}, sizes = {} } end
    -- adjacency weights (symmetric, self-loops dropped) + degrees + total weight m
    local w, deg, m = {}, {}, 0
    for i = 1, n do w[i] = {}; deg[i] = 0 end
    for _, e in ipairs(edges or {}) do
        local a, b, ew = e[1], e[2], e.w or 1
        if a and b and a ~= b and a >= 1 and a <= n and b >= 1 and b <= n then
            w[a][b] = (w[a][b] or 0) + ew
            w[b][a] = (w[b][a] or 0) + ew
            deg[a] = deg[a] + ew; deg[b] = deg[b] + ew; m = m + ew
        end
    end
    local com = {}
    for i = 1, n do com[i] = i end
    if m > 0 then
        local two_m2 = 2 * m * m
        while true do
            -- Σtot per current community + edge weight E[c][d] (c<d) between them
            local sigma, E = {}, {}
            for i = 1, n do sigma[com[i]] = (sigma[com[i]] or 0) + deg[i] end
            for a = 1, n do
                for b, ew in pairs(w[a]) do
                    local ca, cb = com[a], com[b]
                    if a < b and ca ~= cb then
                        local lo, hi = ca, cb
                        if lo > hi then lo, hi = hi, lo end
                        E[lo] = E[lo] or {}
                        E[lo][hi] = (E[lo][hi] or 0) + ew
                    end
                end
            end
            -- pick the merge with the largest ΔQ (deterministic tie-break: lowest c,d)
            local best_dq, bc, bd = 0, nil, nil
            for c, row in pairs(E) do
                for d, ecd in pairs(row) do          -- c < d by construction
                    local dq = ecd / m - sigma[c] * sigma[d] / two_m2
                    if dq > 1e-12 and (not bc or dq > best_dq + 1e-12
                        or (dq >= best_dq - 1e-12 and (c < bc or (c == bc and d < bd)))) then
                        best_dq, bc, bd = dq, c, d
                    end
                end
            end
            if not bc then break end
            local keep, drop = math.min(bc, bd), math.max(bc, bd)
            for i = 1, n do if com[i] == drop then com[i] = keep end end
        end
    end
    -- relabel 0-based by first appearance in row order (matches `partition`)
    local root2comp, comp, next_id = {}, {}, 0
    for i = 1, n do
        local r = com[i]
        if root2comp[r] == nil then root2comp[r] = next_id; next_id = next_id + 1 end
        comp[i] = root2comp[r]
    end
    local ncomp, sizes = next_id, {}
    for i = 1, n do sizes[comp[i]] = (sizes[comp[i]] or 0) + 1 end
    -- the seam: inter-community edges (their kinds are the coupling a cut breaks)
    local cut, crossing = 0, {}
    for _, e in ipairs(edges or {}) do
        local a, b = e[1], e[2]
        if a and b and a ~= b and a >= 1 and a <= n and b >= 1 and b <= n
            and comp[a] ~= comp[b] then
            cut = cut + (e.w or 1)
            crossing[#crossing + 1] = { a = a, b = b, kind = e.kind, ca = comp[a], cb = comp[b] }
        end
    end
    -- final modularity Q = Σ_c [ Σin(c)/2m − (Σtot(c)/2m)² ]
    local q = 0
    if m > 0 then
        local sin, stot = {}, {}
        for c = 0, ncomp - 1 do sin[c] = 0; stot[c] = 0 end
        for i = 1, n do stot[comp[i]] = stot[comp[i]] + deg[i] end
        for a = 1, n do
            for b, ew in pairs(w[a]) do
                if comp[a] == comp[b] then sin[comp[a]] = sin[comp[a]] + ew end -- both dirs = Σin
            end
        end
        for c = 0, ncomp - 1 do q = q + sin[c] / (2 * m) - (stot[c] / (2 * m)) ^ 2 end
    end
    return { comp = comp, ncomp = ncomp, modularity = q, cut = cut, crossing = crossing, sizes = sizes }
end

-- the keys of a set as a sorted list (stable output for reports/tests)
local function sorted_keys(set)
    local out = {}
    for k in pairs(set) do out[#out + 1] = k end
    table.sort(out)
    return out
end

-- "3 data, 1 control" — tally a crossing-edge list by kind, for the seam report.
local function kinds_summary(crossing)
    local by = {}
    for _, x in ipairs(crossing) do by[x.kind or '?'] = (by[x.kind or '?'] or 0) + 1 end
    local parts = {}
    for k, v in pairs(by) do parts[#parts + 1] = ('%d %s'):format(v, k) end
    table.sort(parts)
    return #parts > 0 and table.concat(parts, ', ') or '(untyped)'
end

--- COARSE lens (the shipped comprehension view): union-find over df's data-dep
--- edges. Locals-only, top-level statements only, not a safety claim.
--- @param df { inputs:string[], stmts: table[] } | nil
--- @return { n:integer, ncomp:integer, comp:integer[], sizes:table, switches:integer, tangle:integer, maxspan:integer }
function M.analyze(df)
    local stmts = df and df.stmts or {}
    return partition(#stmts, function (union, span)
        for i, s in ipairs(stmts) do
            for _, d in ipairs(s.dep or {}) do
                if d.from >= 1 and d.from <= #stmts then
                    union(i, d.from); span(i - d.from)
                end
            end
        end
    end)
end

--- FINE lens over flow's PDG. Concerns = connected components under the program-
--- dependence edges, so statements in DIFFERENT concerns have NO dependency and
--- are independently reorderable/extractable (the safety verdict itself is INC 3).
--- Edge kinds (INC 1 + INC 2):
---   • DATA (RAW) — reaching_cfg def→use (scope-aware; `from` 0 = param, skipped).
---   • OUTPUT (WAW) — reaching_cfg's 2nd value: coupled defs of the same var.
---   • CONTROL — a row is control-dependent on its enclosing control head
---     (`parent`), so a branch/loop body joins its guard's concern even with no
---     data flow to the condition (fixes the "isolated body statement" mis-split).
---   • SIDE-EFFECT ordering (INC 2b) — passed in via `extra_edges` (store-dependent,
---     so it can't be derived from the flow record alone; the caller supplies it
---     from M.effect_edges). Non-commuting impure statements couple.
--- (WAR/anti falls out transitively via RAW+WAW.)
--- INC 3 honesty (the SAFETY verdict): two statements in different concerns are
--- provably independent ONLY if the PDG is complete. It isn't where a statement's
--- effects are UNRESOLVED (`opaque` — an unresolved call, aliasing, dynamic
--- dispatch): its hidden effect could couple it to any concern. So a concern
--- CONTAINING an opaque row is flagged `hedged`, and any opaque row at all sets
--- `certified=false` — the whole "safe to extract/reorder" claim drops to `~`
--- (sound-or-silent, honoring "a half-PDG is worse than none"). reaching-`hedged`
--- edges are conservative-INCLUSIVE (they only over-merge = safe to SEPARATE), so
--- they do NOT undermine the verdict. `certified=true` means: safe under the
--- MODELED effects (name-matched module state + resolved calls) — the residual `~`
--- is exactly the aliasing/unresolved-call gap that `opaque` captures.
--- @param flow { stmts: table[], params: string[] } | nil  (flow.record(n) shape)
--- @param extra_edges { [1]:integer, [2]:integer }[] | nil  effect-coupling row-pairs
--- @param opaque integer[] | nil  rows with unresolved effects (from effect_edges)
--- @return table  { n, ncomp, comp, sizes, switches, tangle, maxspan, hedged, certified }
function M.analyze_flow(flow, extra_edges, opaque)
    local stmts = flow and flow.stmts or {}
    local n = #stmts
    if n == 0 then
        return { n = 0, ncomp = 0, comp = {}, sizes = {}, switches = 0,
            tangle = 0, maxspan = 0, hedged = {}, certified = true }
    end
    local raw, waw = flowmod.reaching_cfg(flow)
    -- collect the PDG edges once (kind-tagged), then feed BOTH the sound union-find
    -- partition (connected components = the independence claim) AND community
    -- detection (cohesive sub-groups = the seam suggestion) from the same list.
    local edges = {}
    local function E(a, b, kind)
        if a and b and a >= 1 and a <= n and b >= 1 and b <= n and a ~= b then
            edges[#edges + 1] = { a, b, kind = kind }
        end
    end
    for _, e in ipairs(raw) do                  -- DATA (RAW)
        local at = e.at
        for _, from in ipairs(e.from) do
            if from ~= 0 then E(at, from, 'data') end
        end
    end
    for _, w in ipairs(waw) do E(w[1], w[2], 'output') end          -- OUTPUT (WAW)
    for i = 1, n do E(i, stmts[i].parent, 'control') end            -- CONTROL (parent, 0=skip)
    for _, e in ipairs(extra_edges or {}) do E(e[1], e[2], 'effect') end -- SIDE-EFFECT (INC 2b)
    local res = partition(n, function (union, span)
        for _, e in ipairs(edges) do
            union(e[1], e[2]); local s = e[1] - e[2]; if s < 0 then s = -s end; span(s)
        end
    end)
    res.communities = M.communities(n, edges)
    -- verdict: localize opacity to its concern(s); any opacity → uncertified.
    -- `why[c]` breaks down WHY concern c can't be certified — the blocking rows
    -- with their reason (from reorder's per-statement hedge). An `opaque` entry is
    -- either a bare row index (synthetic) or {row, line, reason}.
    local hedged, certified, why = {}, true, {}
    for _, o in ipairs(opaque or {}) do
        local r = type(o) == 'table' and o.row or o
        if r and r >= 1 and r <= n and res.comp[r] ~= nil then
            local c = res.comp[r]
            hedged[c] = true; certified = false
            if type(o) == 'table' and o.reason then
                why[c] = why[c] or {}
                why[c][#why[c] + 1] = { row = r, line = o.line, reason = o.reason }
            end
        end
    end
    res.hedged, res.certified, res.why = hedged, certified, why
    return res
end

--- is concern `c` (a comp id) safe to extract/reorder in isolation? Sound: only
--- when the whole function is certified (no opaque row anywhere could secretly
--- couple across a boundary) AND this concern isn't the one carrying the opacity.
function M.concern_safe(res, c)
    return res.certified and not res.hedged[c]
end

--- flat, human-readable breakdown of WHY the partition isn't certified safe —
--- one line per blocking (opaque) statement: "L<line>: <reason>". Empty when
--- certified. The actionable half of the honesty: resolve a blocker (annotate /
--- resolve the call via the oracle) → re-run → the concern can certify.
function M.why_unsafe(res)
    local out = {}
    for _, rows in pairs(res.why or {}) do
        for _, w in ipairs(rows) do
            out[#out + 1] = ('L%s: %s'):format(w.line or '?', w.reason or 'unresolved effects')
        end
    end
    table.sort(out)
    return out
end

-- ── INTER-FUNCTION untangle ([[cartograph-untangle-inter.md]]): the intra arc
-- one granularity up. Partition a SCOPE's functions into independent CLUSTERS
-- over the inter-procedural dependence graph — CALL edges (intra-scope
-- store.uses) + SHARED WRITTEN STATE (two fns that touch the same module var
-- that SOMEONE writes; read-only shared consts don't couple — they can be
-- imported freely). Reuses the same union-find `partition`, over functions
-- instead of statements. INC 1 = clustering (comprehension); verdict + extract
-- handoff are INC 2/3. Scoped to ONE file (MVP): "module state" = the file's
-- own vars, which sidesteps the shared-global blob (the sharing model, gated).

--- Cluster the functions across a SCOPE (a list of files) into independent
--- concerns. INC 4: cross-file — CALL edges (store.uses spans files once resolved)
--- + shared state span the whole scope, so a directory/package clusters as one.
--- The SHARING MODEL is the `opts.shared(var, written)` seam: whether a touched
--- module var actually couples. Default = written (mutable state couples;
--- read-only consts don't). Per-ecosystem refinements plug in here — e.g. a
--- factorio-runtime config would return false for cross-mod globals (sandboxed);
--- WoW returns true for shared globals. Only the default is built (the gate).
--- @return table { n, fns, comp, ncomp, sizes, switches, tangle, names,
---   calledges, stateedges, hedged, certified, why }
function M.analyze_scope(store, files, opts)
    opts = opts or {}
    local shared = opts.shared or function (_v, written) return written end
    local scope = {}
    for _, f in ipairs(files) do
        for _, node in ipairs((store.by_file and store.by_file[f]) or {}) do
            scope[#scope + 1] = node
        end
    end
    local fns, names = {}, {}
    for _, node in ipairs(scope) do
        if node.kind == 'function' or node.kind == 'method' then
            fns[#fns + 1] = node
        end
    end
    table.sort(fns, function (a, b) -- source order (stable, id tiebreak)
        local ao, bo = a.order or 0, b.order or 0
        if ao ~= bo then return ao < bo end
        return tostring(a.id) < tostring(b.id)
    end)
    local idx, idx_name = {}, {} -- id→index, in-scope fn NAME set (for the verdict)
    for k, node in ipairs(fns) do
        idx[node.id] = k; names[node.id] = node.name
        if node.name then idx_name[node.name] = true end
    end
    local n = #fns
    if n == 0 then
        return { n = 0, fns = {}, comp = {}, ncomp = 0, sizes = {}, switches = 0,
            tangle = 0, names = names, calledges = 0, stateedges = 0,
            hedged = {}, certified = true, why = {} }
    end
    local calls, states = 0, 0
    local edges = {}                                       -- kind-tagged, for communities
    local band = store.topo()
    for k, node in ipairs(fns) do                          -- CALL edges (intra-scope)
        for _, callee in ipairs(band:callees(node.id)) do
            if idx[callee] then edges[#edges + 1] = { k, idx[callee], kind = 'call' }; calls = calls + 1 end
        end
    end
    for _, v in ipairs(scope) do                           -- SHARED WRITTEN STATE
        if v.kind == 'var' then
            local written, touchers = false, {}
            for _, u in ipairs(band:var_used_by_detail(v.id)) do
                if u.rw and u.rw >= 2 then written = true end
                if idx[u.from] then touchers[idx[u.from]] = true end
            end
            if shared(v, written) then
                local first
                for k in pairs(touchers) do
                    if not first then first = k
                    else edges[#edges + 1] = { first, k, kind = 'state' }; states = states + 1 end
                end
            end
        end
    end
    local res = partition(n, function (union, span)
        for _, e in ipairs(edges) do union(e[1], e[2]); span(0) end
    end)
    res.communities = M.communities(n, edges)
    res.fns, res.names, res.calledges, res.stateedges = fns, names, calls, states
    -- INC 2 verdict: clusters are DISCONNECTED under the modeled edges by
    -- construction, so the only threat to "safe to extract as a module" is an
    -- UNMODELED edge that could secretly connect two clusters. Sound opacity
    -- sources: (a) a silently-unresolved call whose callee NAMES an in-scope fn
    -- (a missed intra-scope call edge would merge clusters) — name-matching keeps
    -- stdlib/external calls from over-hedging; (b) dynamic dispatch (could reach
    -- any fn); (c) unclassified module state (a hidden shared-state coupling). Any
    -- opacity → certified=false; the carrying cluster(s) hedged + why-breakdown.
    local hedged, why, certified = {}, {}, true
    local function flag(k, line, reason)
        local c = res.comp[k]
        hedged[c] = true; certified = false
        why[c] = why[c] or {}
        why[c][#why[c] + 1] = { fn = fns[k].name, line = line, reason = reason }
    end
    for k, node in ipairs(fns) do
        for _, c in ipairs(store.topo():sites(node.id)) do
            local line = (c.line or 0) + 1
            if c.dynamic then
                flag(k, line, 'dynamic dispatch (could reach any fn)')
            elseif not c.to and not c.refused and callrec.callee(c) then
                -- SILENT unresolved (the resolver made no determination): could hide
                -- an intra-scope edge. Name-matches an in-scope fn, OR a bracket-index
                -- callee `t[k]()` = table dispatch (could reach any in-scope fn value).
                -- `.`-qualified callees are left alone: those are stdlib/module calls
                -- (table.insert, string.format) that can't target an in-scope local fn.
                if idx_name[callrec.callee(c)] then
                    flag(k, line, ('unresolved call to in-scope `%s`'):format(callrec.callee(c)))
                elseif callrec.callee(c):find('%[') then
                    flag(k, line, ('dynamic dispatch `%s` (could reach any fn)'):format(callrec.callee(c)))
                end
            end
        end
    end
    for _, v in ipairs(scope) do
        if v.kind == 'var' then
            local unk, touchers = false, {}
            for _, u in ipairs(band:var_used_by_detail(v.id)) do
                if u.rw == nil then unk = true end
                if idx[u.from] then touchers[#touchers + 1] = idx[u.from] end
            end
            if unk then
                for _, k in ipairs(touchers) do
                    flag(k, (v.order or 0) + 1, ('unclassified state `%s`'):format(v.name or '?'))
                end
            end
        end
    end
    res.hedged, res.certified, res.why = hedged, certified, why
    res.files = files
    return res
end

--- Single-file scope (the god-FILE view) — the common case.
function M.analyze_module(store, file, opts)
    return M.analyze_scope(store, { file }, opts)
end

--- files under a directory prefix (relpaths), for a god-DIRECTORY/package scope.
function M.files_under(store, dir)
    dir = dir:gsub('/*$', '') .. '/'
    local out = {}
    for f in pairs(store.by_file or {}) do
        if f:sub(1, #dir) == dir then out[#out + 1] = f end
    end
    table.sort(out)
    return out
end

--- is cluster `c` safe to extract as its own module? Sound: only when the whole
--- file is certified (no unmodeled coupling could secretly connect clusters) AND
--- this cluster isn't the one carrying the opacity.
function M.module_safe(res, c)
    return res.certified and not res.hedged[c]
end

--- THE extract handoff (INC 3): plan cluster `c`'s functions into a new module
--- `relpath`. No contiguity gate — moveapply moves a scattered SYMBOL SET,
--- rewriting call sites + adding requires. plan_extract_ids independently computes
--- the moves + rewrites + LOAD-ORDER/cycle hazards (the disagreement oracle:
--- untangle picks the cluster, moveapply checks the move mechanics). Returns the
--- moveapply plan, or (nil, reason). ([[cartograph-untangle-inter]])
function M.extract_module(store, res, c, relpath)
    local ids = {}
    for k, node in ipairs(res.fns) do
        if res.comp[k] == c then ids[#ids + 1] = node.id end
    end
    if #ids == 0 then return nil, 'empty cluster' end
    return require('cartograph.moveapply').plan_extract_ids(store, ids, relpath)
end

--- Scope report (the inter-untangle surface): the function clusters across a
--- fileset — how many independent concerns are jammed into one file/directory
--- (the god-file / god-package signal). `label` names the scope + seeds the
--- synthesized extract destinations.
function M.report_scope(store, files, label)
    local res = M.analyze_scope(store, files)
    if res.n == 0 then return { ('untangle: %s — no functions'):format(label) } end
    local L = { ('untangle: %s — %d functions, %d independent cluster(s)')
        :format(label, res.n, res.ncomp) }
    L[#L + 1] = ('%d call edge(s), %d shared-written-state edge(s)')
        :format(res.calledges, res.stateedges)
    if res.ncomp > 1 then
        L[#L + 1] = ('this scope holds %d independent function groups — candidates to split apart')
            :format(res.ncomp)
    end
    L[#L + 1] = ''
    local members = {} -- comp id → {names}
    for k, node in ipairs(res.fns) do
        local c = res.comp[k]
        members[c] = members[c] or {}
        members[c][#members[c] + 1] = res.names[node.id] or ('#' .. tostring(node.id))
    end
    for c = 0, res.ncomp - 1 do
        local m = members[c] or {}
        L[#L + 1] = ('  %s%s (%d): %s'):format(string.char(65 + (c % 26)),
            res.hedged[c] and '~' or ' ', #m, table.concat(m, ', '))
    end
    -- cohesive sub-modules (community detection): when the functions form ONE
    -- connected cluster (they all call/share state — a god-file with no clean
    -- split), modularity still finds the denser sub-groups + the seam. SUGGESTION,
    -- not a safety claim: the crossing edges are real call/state coupling to break.
    local cm = res.communities
    if cm and cm.ncomp > res.ncomp then
        local sub = {} -- community id → {names}
        for k, node in ipairs(res.fns) do
            local g = cm.comp[k]
            sub[g] = sub[g] or {}
            sub[g][#sub[g] + 1] = res.names[node.id] or ('#' .. tostring(node.id))
        end
        L[#L + 1] = ''
        L[#L + 1] = ('cohesive sub-groups: %d inside the %d connected cluster(s) — '
            .. 'suggested split, breaks %d coupling edge(s) (%s):')
            :format(cm.ncomp, res.ncomp, #cm.crossing, kinds_summary(cm.crossing))
        for g = 0, cm.ncomp - 1 do
            L[#L + 1] = ('  %s: %s'):format(string.char(97 + (g % 26)),
                table.concat(sub[g] or {}, ', '))
        end
    end
    L[#L + 1] = ''
    if res.certified then
        L[#L + 1] = 'CERTIFIED: each cluster is safe to extract as its own module'
        L[#L + 1] = '(sound under the modeled call + shared-written-state edges)'
        -- INC 3 handoff: dry-run each cluster through moveapply.plan_extract_ids
        -- (a synthesized dest); show the move + hazard counts it would produce.
        if res.ncomp > 1 then
            local base = label:gsub('%.%w+$', ''):gsub('/+$', '') -- strip ext / trailing slash
            L[#L + 1] = 'extract-as-module candidates:'
            for c = 0, res.ncomp - 1 do
                local lt = string.char(65 + (c % 26))
                local rel = base .. '_' .. lt:lower() .. '.lua'
                local plan, err = M.extract_module(store, res, c, rel)
                if plan then
                    L[#L + 1] = ('  %s → %s: %d move(s), %d hazard(s)'):format(
                        lt, rel, #plan.moves, #plan.hazards)
                else
                    L[#L + 1] = ('  %s: %s'):format(lt, err)
                end
            end
        end
    else
        L[#L + 1] = 'NOT certified — an unmodeled coupling could connect clusters:'
        for c = 0, res.ncomp - 1 do
            for _, w in ipairs(res.why[c] or {}) do
                L[#L + 1] = ('  ~ %s L%s: %s'):format(w.fn or '?', w.line or '?', w.reason)
            end
        end
    end
    return L
end

--- Single-file report (the god-FILE view) — the common :CartographUntangleModule.
function M.report_module(store, file)
    return M.report_scope(store, { file }, file)
end

--- THE extract.plan HANDOFF: turn concern `c` (a comp id from a res) into an
--- extract.plan for the focused fn. A concern is directly extractable only when
--- its TOP-LEVEL statements (`parent==0` rows == df statements by parity) form a
--- CONTIGUOUS run — a scattered concern would need gathering/reorder first
--- (refused with `scattered=true`; the reorder verdict is what would license it).
--- Assembles the same opts the source-pane driver uses, then hands off to
--- extract.plan, whose reaching-based shadow-safety (live-in→params, live-out→
--- returns, ambiguous-return refusal) is an INDEPENDENT check of the boundary —
--- the disagreement oracle: untangle picks the boundary, extract.plan validates
--- the mechanics. Returns extract.plan's result (`{ok=false, reason}` or a plan).
--- ([[cartograph-untangle-pdg]])
function M.extract_plan(store, fn_id, res, c, name)
    local node = store.node and store.node(fn_id)
    if not node then return { ok = false, reason = 'no such node' } end
    local fl = flowmod.present(node) and flowmod.record(node)
    if not fl then return { ok = false, reason = 'no fine flow' } end
    local rows = fl.stmts
    local toplist = {} -- k-th top-level row (== df.stmts[k] by parity)
    for i, s in ipairs(rows) do if s.parent == 0 then toplist[#toplist + 1] = i end end
    local kmin, kmax
    for k, row in ipairs(toplist) do
        if res.comp[row] == c then kmin = kmin or k; kmax = k end
    end
    if not kmin then return { ok = false, reason = 'concern has no top-level statements' } end
    for k = kmin, kmax do -- contiguity: no other concern interleaved
        if res.comp[toplist[k]] ~= c then
            return { ok = false, scattered = true, reason =
                'concern is scattered (interleaved with other concerns) — gather/reorder first' }
        end
    end
    local at = require 'cartograph.at'
    local df = require('cartograph.df').get(node)
    if not (df and df.stmts and df.stmts[kmin]) then return { ok = false, reason = 'no df' } end
    local body_end = at.el(node.range)
    local sel = { first = df.stmts[kmin].l,
        last = (df.stmts[kmax + 1] and df.stmts[kmax + 1].l - 1) or body_end }
    return require('cartograph.extract').plan {
        df = df, sel = sel, fn_start = at.sl(node.range) + 1, body_end = body_end,
        file_lines = store.content(node), reaching = flowmod.reaching_cfg(fl),
        flow_rows = rows, name = name or ('extracted_' .. string.char(65 + (c % 26))) }
end

--- The lens surface (INC 4): render the focused fn's fine-PDG concerns + the
--- safety verdict as report lines (the scratch-buffer view, :CartographUntangle).
--- Each statement row is tagged with its concern letter (A/B/C…), indented by
--- nesting, and marked `~` when its concern can't be certified; the footer gives
--- the verdict and — when uncertified — WHY (the blocking statements). A CERTIFIED
--- concern is a ready-made extraction candidate for extract.plan (params=live-in,
--- returns=live-out from reaching/liveness). ([[cartograph-untangle-pdg]])
function M.report(store, fn_id)
    local node = store.node and store.node(fn_id)
    if not node then return { 'untangle: no such node' } end
    local flow = flowmod.record(node)
    if not flow or not flow.stmts or #flow.stmts == 0 then
        return { ('untangle: %s has no fine flow (not an imperative body?)')
            :format(node.name or fn_id) }
    end
    local edges, opaque = M.effect_edges(store, fn_id, flow)
    local res = M.analyze_flow(flow, edges, opaque)
    local function letter(c) return string.char(65 + (c % 26)) end
    local function depth(i)
        local d, p = 0, flow.stmts[i].parent
        while p and p ~= 0 do d = d + 1; p = flow.stmts[p].parent end
        return d
    end
    local L = {}
    L[#L + 1] = ('untangle: %s — %d statements, %d concern(s) — %s'):format(
        node.name or fn_id, res.n, res.ncomp,
        res.certified and 'CERTIFIED safe to split' or '~ NOT certified')
    L[#L + 1] = ('tangle %d (0 = already grouped in source), maxspan %d')
        :format(res.tangle, res.maxspan)
    -- community refinement: when modularity finds cohesive sub-groups INSIDE a
    -- connected concern, tag each row with a lowercase sub-group letter so the
    -- seam is visible in the listing. Only when it actually refines the components.
    local cm = res.communities
    local refine = cm and cm.ncomp > res.ncomp
    L[#L + 1] = ''
    for i, s in ipairs(flow.stmts) do
        local c = res.comp[i]
        local sub = refine and (' [%s]'):format(string.char(97 + (cm.comp[i] % 26))) or ''
        L[#L + 1] = ('  %s%s L%-5d %s%s%s'):format(letter(c),
            res.hedged[c] and '~' or ' ', s.l, ('  '):rep(depth(i)),
            s.kind or 'stmt', sub)
    end
    L[#L + 1] = ''
    if res.certified then
        L[#L + 1] = ('%d independent concern(s) — each safe to extract/reorder'):format(res.ncomp)
        L[#L + 1] = '(sound under the MODELED effects: name-matched module state +'
        L[#L + 1] = ' resolved calls; aliasing / unresolved calls would be flagged ~)'
    else
        L[#L + 1] = 'CANNOT guarantee safety — unresolved effects could couple'
        L[#L + 1] = 'concerns across a boundary. Blocking statements (resolve to certify):'
        for _, w in ipairs(M.why_unsafe(res)) do L[#L + 1] = '  ~ ' .. w end
    end
    -- COHESIVE SUB-GROUPS (community detection): where connected-components see one
    -- tangled blob, modularity finds the denser sub-clusters + the SEAM between
    -- them. This is a SUGGESTION, not a safety claim — the crossing edges are real
    -- dependencies a split would have to break (that's the price, spelled out).
    if refine then
        L[#L + 1] = ''
        L[#L + 1] = ('cohesive sub-groups: %d group(s) inside the %d concern(s) — '
            .. 'suggested seams, NOT free to split'):format(cm.ncomp, res.ncomp)
        L[#L + 1] = ('cutting them apart breaks %d dependency edge(s): %s')
            :format(#cm.crossing, kinds_summary(cm.crossing))
    end
    -- extract candidates (the extract.plan handoff): only meaningful when a fn
    -- has >1 concern (extracting one of several). extract.plan validates the
    -- mechanics independently of the concern analysis (the disagreement oracle).
    if res.ncomp > 1 then
        L[#L + 1] = ''
        L[#L + 1] = 'extract candidates (concern → extract.plan):'
        for cc = 0, res.ncomp - 1 do
            local lt = letter(cc)
            local plan = M.extract_plan(store, fn_id, res, cc)
            if plan.ok then
                local tag = res.hedged[cc]
                    and ' — mechanically clean, but ~ (unresolved effects, see above)' or ''
                L[#L + 1] = ('  %s: extractable — %d param(s), %d return(s)%s'):format(
                    lt, #plan.params, #plan.returns, tag)
            elseif M.concern_safe(res, cc) and not plan.scattered then
                -- untangle says independent, extract.plan refuses on mechanics:
                -- a genuine boundary disagreement worth surfacing
                L[#L + 1] = ('  %s: ⚠ independent but NOT mechanically extractable — %s')
                    :format(lt, plan.reason)
            else
                L[#L + 1] = ('  %s: %s'):format(lt, plan.reason)
            end
        end
    end
    return L
end

--- Compute the INC-2b SIDE-EFFECT ordering edges for `fn_id`'s flow, as row-pairs
--- consumable by analyze_flow's `extra_edges`. Reuses reorder.lua's state/world
--- conflict analysis (per-statement module-state writes/reads + discharged call
--- effects, set-once excused) — its conflicts are between COARSE (top-level) df
--- statements, and by df/flow parity coarse statement k == the k-th `parent==0`
--- flow row, so we map each conflict onto those rows (nested rows already ride
--- CONTROL edges up to their top-level ancestor). Store-dependent → separate from
--- the pure analyze_flow. Returns BOTH the effect-coupling edges AND the OPAQUE
--- rows (statements reorder couldn't resolve effects for) — analyze_flow's INC-3
--- honesty input — each mapped from reorder's coarse index onto its `parent==0` row.
--- @return { [1]:integer, [2]:integer }[] edges, integer[] opaque  (fine indices)
function M.effect_edges(store, fn_id, flow)
    local reorder = require 'cartograph.reorder'
    local ok, m = pcall(reorder.analyze, store, fn_id)
    if not ok or not m then return {}, {} end
    local stmts = flow and flow.stmts or {}
    local toprow, k = {}, 0 -- k-th top-level flow row (coarse statement k)
    for i, s in ipairs(stmts) do
        if s.parent == 0 then k = k + 1; toprow[k] = i end
    end
    local edges = {}
    for _, c in ipairs(m.conflicts or {}) do
        local a, b = toprow[c[1]], toprow[c[2]]
        if a and b then edges[#edges + 1] = { a, b } end
    end
    local opaque = {}
    for _, ci in ipairs(m.opaque or {}) do
        local row = toprow[ci]
        if row then
            local st = m.stmts[ci] -- carry the REASON (reorder's per-stmt hedge) so
            -- the verdict can break down WHY, not just flag ~ ([[cartograph-hedge-provenance]])
            opaque[#opaque + 1] = { row = row, line = st and st.l,
                reason = (st and st.hedges and st.hedges[1]) or 'unresolved effects' }
        end
    end
    return edges, opaque
end

-- ── NESTED-BLOCK EXTRACT-CANDIDATES ([[cartograph-untangle-pdg]]): the SECOND
-- kind of tangle — LINEAR-PIPELINE decomposition, not independent-slice. The
-- concern lens correctly calls a nested loop/branch body "one concern" (it is
-- control-dependent), so it can't suggest pulling that body into a helper. This
-- view does: it enumerates the fn's control sub-regions from the flow tree (every
-- loop/branch, at any depth) and, for each, computes the extraction interface
-- straight from reaching over the block's ROW-SET — params = locals used inside
-- whose reaching def is OUTSIDE (live-in), returns = locals defined inside and
-- read after (live-out) — plus a control-escape hazard check. Unlike extract.plan
-- (which handles whole TOP-LEVEL statements only, refusing anything nested), this
-- reads NESTED blocks too, because it works on reaching row-sets rather than
-- source-line selections. It SUGGESTS the blocks; extract.plan stays the
-- mechanical validator for the top-level ones (the disagreement oracle).
local LOOPISH = { for_statement = true, for_in_statement = true,
    while_statement = true, repeat_statement = true, loop_statement = true,
    loop_expression = true, switch_statement = true, switch_expression = true }
local RET = { return_statement = true, throw_statement = true, raise_statement = true }
local XFER = { break_statement = true, continue_statement = true, goto_statement = true }
-- sub-clauses of an enclosing construct — not standalone candidates (you extract
-- the whole if, incl. its elseifs, not a bare elseif)
local SUBCLAUSE = { elseif_statement = true, else_statement = true,
    else_if_clause = true, elif_clause = true, case = true, catch = true,
    cond = true, label = true, finally_clause = true, default_clause = true }
local FNDEF = { function_definition = true, function_declaration = true,
    arrow_function = true, method_definition = true, lambda = true }

--- Enumerate the focused fn's control sub-regions as extraction candidates. Each
--- candidate = the subtree rooted at a control head (the whole loop/branch), with
--- its live-in params, live-out returns, nesting depth, and a control-escape
--- verdict (a return/throw, or a break/continue/goto whose target is outside the
--- block, would change meaning if the block moved — so the block is not cleanly
--- extractable). Sound for LOCALS + control flow; non-local (table/global) state
--- is the residual gap, same as extract.plan.
--- Each candidate carries: head (row index), kind, line, endline, depth, nstmts,
--- params (string[] live-in), returns (string[] live-out), escape (reason|nil),
--- toplevel (bool).
--- @return table[]
function M.extract_candidates(store, fn_id)
    local node = store.node and store.node(fn_id)
    if not node then return {} end
    local fl = flowmod.present(node) and flowmod.record(node)
    if not fl or not fl.stmts or #fl.stmts == 0 then return {} end
    local rows = fl.stmts
    local n = #rows
    local kids = {}                              -- child rows, from parent pointers
    for i = 1, n do
        local p = rows[i].parent
        if p and p ~= 0 then kids[p] = kids[p] or {}; kids[p][#kids[p] + 1] = i end
    end
    local function depth(i)
        local d, p = 0, rows[i].parent
        while p and p ~= 0 do d = d + 1; p = rows[p].parent end
        return d
    end
    local gotomap = {}                           -- label defs, for goto targets
    for i = 1, n do
        local s = rows[i]
        if s.label and not XFER[s.t] then gotomap[s.label] = i end
    end
    local raw = flowmod.reaching_cfg(fl)         -- use row → def rows
    local out = {}
    for h = 1, n do
        -- classify by the RAW node type `t` (flow flattens most rows' `kind` to
        -- 'stmt'; only CTRL heads keep it — but `t` is always the real type)
        local kind = rows[h].t or rows[h].kind or ''
        if kids[h] and not SUBCLAUSE[kind] and not FNDEF[kind] then
            local B, stack, endline = { [h] = true }, { h }, rows[h].l or 0
            while #stack > 0 do                  -- subtree row-set B (h + descendants)
                local x = table.remove(stack)
                if (rows[x].l or 0) > endline then endline = rows[x].l end
                for _, c in ipairs(kids[x] or {}) do
                    if not B[c] then B[c] = true; stack[#stack + 1] = c end
                end
            end
            local nstmts = 0; for _ in pairs(B) do nstmts = nstmts + 1 end
            -- defs INSIDE the block (any), REASSIGNMENTS inside (non-declaration
            -- defs — an accumulator, not a fresh binding), and defs OUTSIDE that
            -- lexically precede the block.
            local hl = rows[h].l or 0
            local defsB, reassignB, defsBefore = {}, {}, {}
            for r in pairs(B) do
                local decl = (rows[r].t or ''):find('declaration') ~= nil
                for _, v in ipairs(rows[r].def or {}) do
                    defsB[v] = true
                    if not decl then reassignB[v] = true end
                end
            end
            for r = 1, n do
                if not B[r] and (rows[r].l or 0) < hl then
                    for _, v in ipairs(rows[r].def or {}) do defsBefore[v] = true end
                end
            end
            -- params (live-in): (a) a recorded use inside whose reaching def is
            -- outside (reaching-precise), PLUS (b) any var defined before the block
            -- AND REASSIGNED (not freshly re-declared) inside it. Clause (b) is the
            -- conservative catch for the accumulator `a = a + b`, whose RHS self-read
            -- flow's `du` DROPS (reaching alone would miss `a` as live-in — unsound);
            -- restricting to reassignments avoids a fresh `local a` shadow (a new
            -- binding, not a param) firing it falsely.
            local pset = {}
            for _, e in ipairs(raw) do
                if B[e.at] then
                    for _, from in ipairs(e.from) do
                        if from ~= 0 and not B[from] then pset[e.var] = true end
                    end
                end
            end
            for v in pairs(reassignB) do if defsBefore[v] then pset[v] = true end end
            -- returns (live-out): a local DEFINED in the block and used lexically
            -- after it. NOT reaching-based — reaching under-resolves a loop-carried
            -- def (a post-loop use can resolve to the pre-loop def), so a reaching
            -- live-out would MISS a var the block reassigns. This over-approximates
            -- (an extra return is harmless; a missed one is unsound) — the safe
            -- direction for an extraction interface.
            local rset = {}
            for r = 1, n do
                if not B[r] and (rows[r].l or 0) > hl then
                    for _, v in ipairs(rows[r].use or {}) do
                        if defsB[v] then rset[v] = true end
                    end
                end
            end
            local escape                          -- control-escape hazard (by raw type `t`)
            for r in pairs(B) do
                local rk = rows[r].t or ''
                if RET[rk] then
                    escape = escape or 'return/throw exits the function'
                elseif rk == 'goto_statement' then
                    local tgt = rows[r].label and gotomap[rows[r].label]
                    if not (tgt and B[tgt]) then escape = escape or 'goto leaves the block' end
                elseif XFER[rk] then              -- break/continue: its loop must be inside B
                    local p, ok = rows[r].parent, false
                    while p and p ~= 0 do
                        if LOOPISH[rows[p].t or ''] then ok = B[p] or false; break end
                        p = rows[p].parent
                    end
                    if not ok then escape = escape or (rk:gsub('_statement', '') .. ' leaves the block') end
                end
            end
            out[#out + 1] = {
                head = h, kind = kind, line = rows[h].l, endline = endline,
                depth = depth(h), nstmts = nstmts,
                params = sorted_keys(pset), returns = sorted_keys(rset),
                escape = escape, toplevel = (rows[h].parent == 0),
            }
        end
    end
    return out
end

--- The lens surface (:CartographExtractBlocks): the focused fn's control blocks as
--- extraction candidates, in source order, indented by nesting. Each line gives
--- the interface `(params) -> (returns)` and a verdict: `*` sweet spot (clean,
--- substantial, small interface), a space (clean but trivial/whole-fn), or `~`
--- with the control-escape reason. This is the tool for the LINEAR-PIPELINE
--- god-function the concern lens honestly reports as "one concern".
function M.report_blocks(store, fn_id)
    local node = store.node and store.node(fn_id)
    if not node then return { 'extract-blocks: no such node' } end
    local cands = M.extract_candidates(store, fn_id)
    if #cands == 0 then
        return { ('extract-blocks: %s has no control blocks to extract')
            :format(node.name or fn_id) }
    end
    table.sort(cands, function (a, b)
        if (a.line or 0) ~= (b.line or 0) then return (a.line or 0) < (b.line or 0) end
        return a.head < b.head
    end)
    -- "substantial" = more than a couple statements but not nearly the whole body
    local biggest = 0
    for _, c in ipairs(cands) do if c.nstmts > biggest then biggest = c.nstmts end end
    local function sweet(c)
        return not c.escape and c.nstmts >= 3 and c.nstmts < biggest and #c.params <= 4
    end
    local clean = 0
    for _, c in ipairs(cands) do if not c.escape then clean = clean + 1 end end
    local L = {}
    L[#L + 1] = ('extract-blocks: %s — %d control block(s), %d cleanly extractable')
        :format(node.name or fn_id, #cands, clean)
    L[#L + 1] = 'each = a whole loop/branch to pull into a helper; interface (params) -> (returns) from reaching'
    L[#L + 1] = '(* = sweet spot: clean, 3+ stmts, small interface; ~ = a control escape blocks it)'
    L[#L + 1] = ''
    for _, c in ipairs(cands) do
        local mark = c.escape and '~' or (sweet(c) and '*' or ' ')
        L[#L + 1] = ('%s %sL%-4d %-14s %2d stmt  (%s) -> (%s)'):format(
            mark, ('  '):rep(c.depth), c.line, (c.kind:gsub('_statement', '')),
            c.nstmts, table.concat(c.params, ', '), table.concat(c.returns, ', '))
        if c.escape then L[#L + 1] = ('  %s   ~ %s'):format(('  '):rep(c.depth), c.escape) end
    end
    return L
end

return M
