-- The honesty census: the graph's epistemic state as one report — edges by
-- trust tier, call resolution with refusals grouped by rule, frontiers. This
-- is the work-list query behind the deferred-analyzer economics ("write the
-- analyzer with 400 hits, not the one with 3") and the before/after number
-- for every oracle pass. take() is the programmatic face (the calibration
-- flywheel reads counts, not prose); report() renders it.

local tier = require 'cartograph.tier'

local M = {}

local SAMPLES = 3 -- example sites kept per refusal rule

--- The TOTAL disposition of a call — exactly one of resolved / refused /
--- dynamic / external / noise ([[cartograph-graph-improvements]] #1). Returns
--- (disp, why): refused → why is the refusal rule; external / noise → why is
--- the gate that placed it outside (vocab / prefix / exact-key / no-def /
--- short); 'unknown' = a silent path not yet tagged (indirect / traced). This
--- is the one reading the D-census + specaudit gap detection query against.
function M.disp(call)
    if call.to then return 'resolved' end
    if call.refused then return 'refused', call.refused.rule end
    if call.dynamic then return 'dynamic' end
    if call.ext then return call.ext.disp, call.ext.why end
    return 'external', 'unknown'
end

--- Structured counts over a neutral-schema data table.
function M.take(data)
    local c = {
        nodes = { total = 0, by_kind = {}, unparsed = 0 },
        edges = { total = 0, by_kind = {},
            ref = { confirmed = 0, proven = 0, xlang = 0, typed = 0,
                inferred = 0, matched = 0 } },
        calls = { total = 0, resolved = 0, refused = 0, unresolved = 0,
            hedged = 0, rules = {},
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
    for _, call in ipairs(data.calls or {}) do
        c.calls.total = c.calls.total + 1
        if call.hedge then c.calls.hedged = c.calls.hedged + 1 end
        if call.to then
            c.calls.resolved = c.calls.resolved + 1
        elseif call.refused then
            c.calls.refused = c.calls.refused + 1
            local rule = call.refused.rule or '?'
            local r = c.calls.rules[rule]
            if not r then r = { n = 0, sites = {} }; c.calls.rules[rule] = r end
            r.n = r.n + 1
            if #r.sites < SAMPLES then
                r.sites[#r.sites + 1] = ('%s:%d %s'):format(call.file or '?',
                    (call.line or 0) + 1, call.callee or call.full or '?')
            end
        else
            -- no target, no refusal: a name the corpus simply doesn't define
            -- (stdlib/vendor) — outside the graph, not a broken promise. The
            -- resolver's disposition says WHICH gate placed it there.
            c.calls.unresolved = c.calls.unresolved + 1
            local disp, why = M.disp(call)
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
    local reftotal = ref.confirmed + ref.proven + ref.xlang + ref.typed
        + ref.inferred + ref.matched
    local lines = {
        ('cartograph census — %s'):format(data.root or '?'),
        '',
        ('nodes %d: %s'):format(c.nodes.total, kind_line(c.nodes.by_kind)),
        ('edges %d: %s'):format(c.edges.total, kind_line(c.edges.by_kind)),
        ('ref trust: confirmed %d (%s) · proven %d (%s) · xlang %d · typed %d (%s) · ~inferred %d (%s) · name-matched %d (%s)')
            :format(ref.confirmed, pct(ref.confirmed, reftotal),
                ref.proven, pct(ref.proven, reftotal), ref.xlang,
                ref.typed, pct(ref.typed, reftotal),
                ref.inferred, pct(ref.inferred, reftotal),
                ref.matched, pct(ref.matched, reftotal)),
        ('calls %d: resolved %d (%s) · refused %d (%s) · outside the corpus %d%s')
            :format(c.calls.total, c.calls.resolved,
                pct(c.calls.resolved, c.calls.total), c.calls.refused,
                pct(c.calls.refused, c.calls.total), c.calls.unresolved,
                c.calls.hedged > 0
                    and (' · hedged %d'):format(c.calls.hedged) or ''),
    }
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
            lines[#lines + 1] = ('  %-24s %5d   e.g. %s')
                :format(rule, r.n, table.concat(r.sites, ' · '))
        end
    end
    return lines
end

return M
