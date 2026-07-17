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

local flowmod = require 'cartograph.flow'

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
    local res = partition(n, function (union, span)
        local function couple(a, b) -- union + record the span (both directions)
            if a and b and a >= 1 and a <= n and b >= 1 and b <= n then
                union(a, b); local s = a - b; if s < 0 then s = -s end; span(s)
            end
        end
        for _, e in ipairs(raw) do              -- DATA (RAW)
            local at = e.at
            for _, from in ipairs(e.from) do
                if from ~= 0 then couple(at, from) end
            end
        end
        for _, w in ipairs(waw) do couple(w[1], w[2]) end       -- OUTPUT (WAW)
        for i = 1, n do couple(i, stmts[i].parent) end          -- CONTROL (parent, 0=skip)
        for _, e in ipairs(extra_edges or {}) do couple(e[1], e[2]) end -- SIDE-EFFECT (INC 2b)
    end)
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

--- Cluster the functions defined in `file` into independent concerns.
--- @return table { n, fns:integer[] (source-ordered ids), comp, ncomp, sizes,
---   switches, tangle, names:table<id,string>, calledges:int, stateedges:int }
function M.analyze_module(store, file)
    local scope = (store.by_file and store.by_file[file]) or {}
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
    local res = partition(n, function (union, span)
        for k, node in ipairs(fns) do                     -- CALL edges (intra-scope)
            for _, callee in ipairs(store.uses[node.id] or {}) do
                if idx[callee] then union(k, idx[callee]); span(0); calls = calls + 1 end
            end
        end
        for _, v in ipairs(scope) do                       -- SHARED WRITTEN STATE
            if v.kind == 'var' then
                local written, touchers = false, {}
                for _, u in ipairs(store.var_usedby[v.id] or {}) do
                    if u.rw and u.rw >= 2 then written = true end
                    if idx[u.from] then touchers[idx[u.from]] = true end
                end
                if written then
                    local first
                    for k in pairs(touchers) do
                        if not first then first = k
                        else union(first, k); span(0); states = states + 1 end
                    end
                end
            end
        end
    end)
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
        for _, c in ipairs(store.calls_by_fn[node.id] or {}) do
            local line = (c.line or 0) + 1
            if c.dynamic then
                flag(k, line, 'dynamic dispatch (could reach any fn)')
            elseif not c.to and not c.refused and c.callee then
                -- SILENT unresolved (the resolver made no determination): could hide
                -- an intra-scope edge. Name-matches an in-scope fn, OR a bracket-index
                -- callee `t[k]()` = table dispatch (could reach any in-scope fn value).
                -- `.`-qualified callees are left alone: those are stdlib/module calls
                -- (table.insert, string.format) that can't target an in-scope local fn.
                if idx_name[c.callee] then
                    flag(k, line, ('unresolved call to in-scope `%s`'):format(c.callee))
                elseif c.callee:find('%[') then
                    flag(k, line, ('dynamic dispatch `%s` (could reach any fn)'):format(c.callee))
                end
            end
        end
    end
    for _, v in ipairs(scope) do
        if v.kind == 'var' then
            local unk, touchers = false, {}
            for _, u in ipairs(store.var_usedby[v.id] or {}) do
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
    return res
end

--- is cluster `c` safe to extract as its own module? Sound: only when the whole
--- file is certified (no unmodeled coupling could secretly connect clusters) AND
--- this cluster isn't the one carrying the opacity.
function M.module_safe(res, c)
    return res.certified and not res.hedged[c]
end

--- Module report (the inter-untangle surface): the file's function clusters —
--- how many independent concerns are jammed into one file (the god-file signal).
function M.report_module(store, file)
    local res = M.analyze_module(store, file)
    if res.n == 0 then return { ('untangle module: %s — no functions'):format(file) } end
    local L = { ('untangle module: %s — %d functions, %d independent cluster(s)')
        :format(file, res.n, res.ncomp) }
    L[#L + 1] = ('%d intra-scope call edge(s), %d shared-written-state edge(s)')
        :format(res.calledges, res.stateedges)
    if res.ncomp > 1 then
        L[#L + 1] = ('this file holds %d independent function groups — candidates to split apart')
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
    L[#L + 1] = ''
    if res.certified then
        L[#L + 1] = 'CERTIFIED: each cluster is safe to extract as its own module'
        L[#L + 1] = '(sound under the modeled call + shared-written-state edges)'
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
    L[#L + 1] = ''
    for i, s in ipairs(flow.stmts) do
        local c = res.comp[i]
        L[#L + 1] = ('  %s%s L%-5d %s%s'):format(letter(c),
            res.hedged[c] and '~' or ' ', s.l, ('  '):rep(depth(i)),
            s.kind or 'stmt')
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

return M
