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
