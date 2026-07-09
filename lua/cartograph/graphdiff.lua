-- Structural diff of two extracts (neutral-schema `data` tables). Count parity
-- ("66847 exact") is weaker than it looks — one spurious edge plus one missing
-- edge passes it. This compares per item: nodes by id, edges as multisets of
-- (from, to, kind) with their trust attributes, calls by site with their
-- resolution outcome — so a gate can assert "NOTHING moved" or "EXACTLY these
-- sites changed" instead of trusting a total. Pure data in, report out; the
-- verification half of extractor-change gates and refresh/splice testing.

local M = {}

-- trust signature of an edge: which honesty tier it sits on (order-stable)
local function esig(e)
    return (e.proven and 'proven' or e.xlang and 'xlang'
        or e.inferred and '~' or 'matched')
        .. (e.sideeffect and '!' or '')
end

-- edge identity = endpoints + kind; multiple call sites legitimately produce
-- the same pair, so identities are counted, not set-membered
local function ekey(e) return e.from .. ' -> ' .. e.to .. ' [' .. e.kind .. ']' end

-- call identity = site; outcome = where resolution landed
local function ckey(c)
    return (c.file or '?') .. ':' .. tostring((c.line or 0) + 1)
        .. ' ' .. (c.callee or c.full or '?')
end
local function coutcome(c)
    local hedge = c.hedge and (' hedged:' .. (c.hedge.rule or '?')) or ''
    if c.to then return 'to ' .. c.to .. hedge end
    if c.refused then return 'refused (' .. (c.refused.rule or '?') .. ')' .. hedge end
    return 'unresolved' .. hedge
end

-- key -> { outcome -> count } for one data table
local function edge_census(data)
    local t = {}
    for _, e in ipairs(data.edges or {}) do
        local k = ekey(e)
        t[k] = t[k] or {}
        t[k][esig(e)] = (t[k][esig(e)] or 0) + 1
    end
    return t
end
local function call_census(data)
    local t = {}
    for _, c in ipairs(data.calls or {}) do
        local k = ckey(c)
        t[k] = t[k] or {}
        t[k][coutcome(c)] = (t[k][coutcome(c)] or 0) + 1
    end
    return t
end

local function fmt_outcomes(o)
    local parts = {}
    for kk, n in pairs(o) do
        parts[#parts + 1] = (n > 1 and (n .. 'x ') or '') .. kk
    end
    table.sort(parts)
    return table.concat(parts, ' + ')
end

-- diff two censuses into added / removed / changed (same key, different
-- outcome distribution — an attr flip or resolution change, the gate's meat)
local function census_diff(a, b)
    local added, removed, changed = {}, {}, {}
    for k, ob in pairs(b) do
        local oa = a[k]
        if not oa then
            added[#added + 1] = k .. ' (' .. fmt_outcomes(ob) .. ')'
        else
            local same = true
            for kk, n in pairs(ob) do if oa[kk] ~= n then same = false break end end
            if same then
                for kk, n in pairs(oa) do if ob[kk] ~= n then same = false break end end
            end
            if not same then
                changed[#changed + 1] = k .. ': '
                    .. fmt_outcomes(oa) .. ' => ' .. fmt_outcomes(ob)
            end
        end
    end
    for k, oa in pairs(a) do
        if not b[k] then removed[#removed + 1] = k .. ' (' .. fmt_outcomes(oa) .. ')' end
    end
    table.sort(added); table.sort(removed); table.sort(changed)
    return { added = added, removed = removed, changed = changed }
end

--- Diff two extracts a -> b. Returns { nodes = {added, removed}, edges =
--- {added, removed, changed}, calls = {added, removed, changed} }, every entry
--- a human-readable line (stable-sorted, so diffs of diffs work too).
function M.diff(a, b)
    local na, nb = {}, {}
    for _, n in ipairs(a.nodes or {}) do na[n.id] = true end
    for _, n in ipairs(b.nodes or {}) do nb[n.id] = true end
    local nadded, nremoved = {}, {}
    for id in pairs(nb) do if not na[id] then nadded[#nadded + 1] = id end end
    for id in pairs(na) do if not nb[id] then nremoved[#nremoved + 1] = id end end
    table.sort(nadded); table.sort(nremoved)
    return {
        nodes = { added = nadded, removed = nremoved },
        edges = census_diff(edge_census(a), edge_census(b)),
        calls = census_diff(call_census(a), call_census(b)),
    }
end

--- No differences at all?
function M.empty(d)
    return #d.nodes.added == 0 and #d.nodes.removed == 0
        and #d.edges.added == 0 and #d.edges.removed == 0 and #d.edges.changed == 0
        and #d.calls.added == 0 and #d.calls.removed == 0 and #d.calls.changed == 0
end

--- Render a diff as report lines. opts.limit caps each section (default 20);
--- what got cut is COUNTED, never silently dropped.
function M.report(d, opts)
    local limit = (opts and opts.limit) or 20
    local lines = {}
    if M.empty(d) then return { 'graphs are identical (per-item)' } end
    local function section(title, list)
        if #list == 0 then return end
        lines[#lines + 1] = ('%s (%d)'):format(title, #list)
        for i = 1, math.min(#list, limit) do lines[#lines + 1] = '  ' .. list[i] end
        if #list > limit then
            lines[#lines + 1] = ('  … %d more'):format(#list - limit)
        end
    end
    section('nodes added', d.nodes.added)
    section('nodes removed', d.nodes.removed)
    section('edges added', d.edges.added)
    section('edges removed', d.edges.removed)
    section('edges changed', d.edges.changed)
    section('calls added', d.calls.added)
    section('calls removed', d.calls.removed)
    section('calls changed', d.calls.changed)
    return lines
end

return M
