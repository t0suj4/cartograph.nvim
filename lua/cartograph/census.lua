-- The honesty census: the graph's epistemic state as one report — edges by
-- trust tier, call resolution with refusals grouped by rule, frontiers. This
-- is the work-list query behind the deferred-analyzer economics ("write the
-- analyzer with 400 hits, not the one with 3") and the before/after number
-- for every oracle pass. take() is the programmatic face (the calibration
-- flywheel reads counts, not prose); report() renders it.

local M = {}

local SAMPLES = 3 -- example sites kept per refusal rule

--- Structured counts over a neutral-schema data table.
function M.take(data)
    local c = {
        nodes = { total = 0, by_kind = {}, unparsed = 0 },
        edges = { total = 0, by_kind = {},
            ref = { proven = 0, xlang = 0, inferred = 0, matched = 0 } },
        calls = { total = 0, resolved = 0, refused = 0, unresolved = 0,
            hedged = 0, rules = {} },
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
            local tier = e.proven and 'proven' or e.xlang and 'xlang'
                or e.inferred and 'inferred' or 'matched'
            c.edges.ref[tier] = c.edges.ref[tier] + 1
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
            -- (stdlib/vendor) — outside the graph, not a broken promise
            c.calls.unresolved = c.calls.unresolved + 1
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
    local reftotal = ref.proven + ref.xlang + ref.inferred + ref.matched
    local lines = {
        ('cartograph census — %s'):format(data.root or '?'),
        '',
        ('nodes %d: %s'):format(c.nodes.total, kind_line(c.nodes.by_kind)),
        ('edges %d: %s'):format(c.edges.total, kind_line(c.edges.by_kind)),
        ('ref trust: proven %d (%s) · xlang %d · ~inferred %d (%s) · name-matched %d (%s)')
            :format(ref.proven, pct(ref.proven, reftotal), ref.xlang,
                ref.inferred, pct(ref.inferred, reftotal),
                ref.matched, pct(ref.matched, reftotal)),
        ('calls %d: resolved %d (%s) · refused %d (%s) · outside the corpus %d%s')
            :format(c.calls.total, c.calls.resolved,
                pct(c.calls.resolved, c.calls.total), c.calls.refused,
                pct(c.calls.refused, c.calls.total), c.calls.unresolved,
                c.calls.hedged > 0
                    and (' · hedged %d'):format(c.calls.hedged) or ''),
    }
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
