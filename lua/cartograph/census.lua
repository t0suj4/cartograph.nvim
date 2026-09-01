-- The honesty census: the graph's epistemic state as one report — edges by
-- trust tier, call resolution with refusals grouped by rule, frontiers. This
-- is the work-list query behind the deferred-analyzer economics ("write the
-- analyzer with 400 hits, not the one with 3") and the before/after number
-- for every oracle pass. take() is the programmatic face (the calibration
-- flywheel reads counts, not prose); report() renders it.

local tier = require 'cartograph.tier'
local callrec = require 'cartograph.callrec'
local callcols = require 'cartograph.callcols'
local tsutil = require 'cartograph.spec.tsutil'

local M = {}

local SAMPLES = 3 -- example sites kept per refusal rule

--- The TOTAL disposition of a call — exactly one of resolved / refused /
--- dynamic / external / noise ([[cartograph-graph-improvements]] #1). Returns
--- (disp, why): refused → why is the refusal rule; external / noise → why is
--- the gate that placed it outside (vocab / prefix / exact-key / no-def /
--- short); 'unknown' = a silent path not yet tagged (indirect / traced). This
--- is the one reading the D-census + specaudit gap detection query against.
-- the value-core: disposition from already-read field VALUES (so the record
-- path and the index-form path in take() share ONE definition — no divergence).
function M.disp_of(to, refused, dynamic, ext)
    if to then return 'resolved' end
    if refused then return 'refused', refused.rule end
    if dynamic then return 'dynamic' end
    if ext then return ext.disp, ext.why end
    return 'external', 'unknown'
end

function M.disp(call)
    return M.disp_of(callrec.to(call), call.refused, call.dynamic, call.ext)
end

--- Structured counts over a neutral-schema data table.
function M.take(data)
    local c = {
        nodes = { total = 0, by_kind = {}, unparsed = 0 },
        edges = { total = 0, by_kind = {},
            -- one counter per ladder rung (derived, so a new tier — stdlib —
            -- is covered without editing this init)
            ref = (function ()
                local r = {}
                for _, rung in ipairs(tier.LADDER) do r[rung.name] = 0 end
                return r
            end)() },
        calls = { total = 0, resolved = 0, refused = 0, unresolved = 0,
            hedged = 0, rules = {},
            -- THE INSTRUMENT REPORTING ON ITSELF (CART-0682). A refusal keeps a
            -- CAPPED sample of the candidates it declined between and records the
            -- true count as `n`; this counts the refusals where those differ. It
            -- belongs here rather than in a tool for the same reason `unparsed`
            -- and the `outside` buckets do — it is a fact about what the graph
            -- SAW versus what it KEPT, not about the code being read. A consumer
            -- that reads `cands` without `n` is silently wrong on every one of
            -- them, which is how a name with 9+ definitions got a false deletion
            -- licence for as long as this number was unreachable from any verb.
            refusals_truncated = 0,
            -- PROV axis rollup: resolved calls by the stage that landed them
            -- ('base' / <pass> / 'stdlib') — the calibration flywheel's
            -- pass-value accounting ([[cartograph-provenance-surfacing]])
            by_prov = {},
            -- the "outside the corpus" bucket, no longer a silent lump:
            -- by disposition (external/noise/dynamic) and by the gate (why)
            outside = { by_disp = {}, by_why = {} } },
    }
    for _, n in ipairs(data.nodes or {}) do
        c.nodes.total = c.nodes.total + 1
        c.nodes.by_kind[n.kind] = (c.nodes.by_kind[n.kind] or 0) + 1
        if n.unparsed then c.nodes.unparsed = c.nodes.unparsed + 1 end
    end
    for _, e in ipairs(data.edges or {}) do
        c.edges.total = c.edges.total + 1
        c.edges.by_kind[e.kind] = (c.edges.by_kind[e.kind] or 0) + 1
        if e.kind == 'ref' then
            local t = tier.of(e)
            c.edges.ref[t] = c.edges.ref[t] + 1
        end
    end
    -- Hot loop, INDEX FORM (record-fold arc, brick 3 step c): when the columnar
    -- store is live, read the fields DIRECTLY off the columns (callcols.get) +
    -- residual, bypassing the per-field proxy __index dispatch — the matrix's
    -- ~3x read win. A mode-branched READ PROLOGUE feeds ONE shared tally body, so
    -- there is no duplicated accounting logic (only the read differs).
    local view = data._callcols
    local cc, resid = view and view.cc, view and view.residual
    local calls = data.calls or {}
    local ncalls = cc and cc.n or #calls
    for i = 1, ncalls do
        local to, prov, hedge, refused, dynamic, ext
        if cc then
            to = callcols.get(cc, 'to', i); prov = callcols.get(cc, 'prov', i)
            dynamic = callcols.get(cc, 'dynamic', i)
            local r = resid[i]
            if r then hedge, refused, ext = r.hedge, r.refused, r.ext end
        else
            local call = calls[i]
            to, prov, hedge = callrec.to(call), callrec.prov(call), call.hedge
            refused, dynamic, ext = call.refused, call.dynamic, call.ext
        end
        c.calls.total = c.calls.total + 1
        if hedge then c.calls.hedged = c.calls.hedged + 1 end
        if to then
            c.calls.resolved = c.calls.resolved + 1
            local p = prov or 'unknown'
            c.calls.by_prov[p] = (c.calls.by_prov[p] or 0) + 1
        elseif refused then
            c.calls.refused = c.calls.refused + 1
            local rule = refused.rule or '?'
            local r = c.calls.rules[rule]
            if not r then r = { n = 0, truncated = 0, sites = {} }; c.calls.rules[rule] = r end
            r.n = r.n + 1
            if tsutil.truncated(refused) then
                r.truncated = r.truncated + 1
                c.calls.refusals_truncated = c.calls.refusals_truncated + 1
            end
            if #r.sites < SAMPLES then
                local file, line, callee, full
                if cc then
                    file, line = callcols.get(cc, 'file', i), callcols.get(cc, 'line', i)
                    callee, full = callcols.get(cc, 'callee', i), callcols.get(cc, 'full', i)
                else
                    local call = calls[i]
                    file, line = callrec.file(call), callrec.line(call)
                    callee, full = callrec.callee(call), callrec.full(call)
                end
                r.sites[#r.sites + 1] = ('%s:%d %s'):format(file or '?',
                    (line or 0) + 1, callee or full or '?')
            end
        else
            -- no target, no refusal: a name the corpus simply doesn't define
            -- (stdlib/vendor) — outside the graph, not a broken promise. The
            -- resolver's disposition says WHICH gate placed it there.
            c.calls.unresolved = c.calls.unresolved + 1
            local disp, why = M.disp_of(to, refused, dynamic, ext)
            local o = c.calls.outside
            o.by_disp[disp] = (o.by_disp[disp] or 0) + 1
            if why then o.by_why[why] = (o.by_why[why] or 0) + 1 end
        end
    end
    return c
end

local function pct(part, whole)
    if whole == 0 then return '0%' end
    return ('%.1f%%'):format(part * 100 / whole)
end

local function kind_line(by_kind)
    local ks = {}
    for k in pairs(by_kind) do ks[#ks + 1] = k end
    table.sort(ks, function (a, b) return by_kind[a] > by_kind[b] end)
    local parts = {}
    for _, k in ipairs(ks) do parts[#parts + 1] = ('%s %d'):format(k, by_kind[k]) end
    return table.concat(parts, ' · ')
end

--- The census as report lines (for the scratch buffer / a file).
function M.report(data)
    local c = M.take(data)
    local ref = c.edges.ref
    local reftotal = 0
    for _, v in pairs(ref) do reftotal = reftotal + v end
    local lines = {
        ('cartograph census — %s'):format(data.root or '?'),
        '',
        ('nodes %d: %s'):format(c.nodes.total, kind_line(c.nodes.by_kind)),
        ('edges %d: %s'):format(c.edges.total, kind_line(c.edges.by_kind)),
        ('ref trust: confirmed %d (%s) · proven %d (%s) · xlang %d · typed %d (%s) · stdlib %d (%s) · ~inferred %d (%s) · name-matched %d (%s)')
            :format(ref.confirmed, pct(ref.confirmed, reftotal),
                ref.proven, pct(ref.proven, reftotal), ref.xlang,
                ref.typed, pct(ref.typed, reftotal),
                ref.stdlib, pct(ref.stdlib, reftotal),
                ref.inferred, pct(ref.inferred, reftotal),
                ref.matched, pct(ref.matched, reftotal)),
        ('calls %d: resolved %d (%s) · refused %d (%s) · outside the corpus %d%s')
            :format(c.calls.total, c.calls.resolved,
                pct(c.calls.resolved, c.calls.total), c.calls.refused,
                pct(c.calls.refused, c.calls.total), c.calls.unresolved,
                c.calls.hedged > 0
                    and (' · hedged %d'):format(c.calls.hedged) or ''),
    }
    -- resolved-by-stage (the calibration flywheel): base vs each pass/pack,
    -- so "which convention earns its keep" is a census read, not an ablation.
    if next(c.calls.by_prov) then
        local provs = {}
        for p in pairs(c.calls.by_prov) do provs[#provs + 1] = p end
        table.sort(provs, function (a, b)
            return c.calls.by_prov[a] > c.calls.by_prov[b]
        end)
        local parts = {}
        for _, p in ipairs(provs) do
            parts[#parts + 1] = ('%s %d'):format(p, c.calls.by_prov[p])
        end
        lines[#lines + 1] = ('  resolved by stage: %s'):format(table.concat(parts, ' · '))
    end
    if c.calls.unresolved > 0 then
        -- the silent-gate hole, opened: which gate placed each call outside.
        -- 'unknown' = the resolver didn't tag it (indirect/traced dispatch)
        local order = { 'vocab', 'prefix', 'exact-key', 'no-def', 'short',
            'unknown' }
        local parts = {}
        for _, w in ipairs(order) do
            local n = c.calls.outside.by_why[w]
            if n then parts[#parts + 1] = ('%s %d'):format(w, n) end
        end
        local dyn = c.calls.outside.by_disp.dynamic
        if dyn then parts[#parts + 1] = ('dynamic %d'):format(dyn) end
        if #parts > 0 then
            lines[#lines + 1] = ('  outside by gate: %s')
                :format(table.concat(parts, ' · '))
        end
    end
    if c.nodes.unparsed > 0 then
        lines[#lines + 1] = ('frontier: %d unparsed landing node(s)')
            :format(c.nodes.unparsed)
    end
    local rules = {}
    for rule in pairs(c.calls.rules) do rules[#rules + 1] = rule end
    if #rules > 0 then
        table.sort(rules, function (a, b)
            return c.calls.rules[a].n > c.calls.rules[b].n
        end)
        lines[#lines + 1] = ''
        lines[#lines + 1] = 'refusals by rule (the analyzer work-list):'
        for _, rule in ipairs(rules) do
            local r = c.calls.rules[rule]
            lines[#lines + 1] = ('  %-24s %5d%s   e.g. %s')
                :format(rule, r.n,
                    (r.truncated or 0) > 0 and (' (%d truncated)'):format(r.truncated) or '',
                    table.concat(r.sites, ' · '))
        end
        -- SAY IT AS A SHARE, because the number that matters is not how many
        -- lists were capped but how much of the refusal evidence is incomplete.
        if c.calls.refusals_truncated > 0 then
            lines[#lines + 1] = ('  %-24s %5d   %s')
                :format('⚠ TRUNCATED', c.calls.refusals_truncated,
                    ('%s of ALL refusals kept fewer candidates than they saw — a consumer reading the list without the count is wrong on these')
                        :format(pct(c.calls.refusals_truncated, c.calls.refused)))
        end
    end
    return lines
end

return M
