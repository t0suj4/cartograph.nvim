local atr = require 'cartograph.at'
-- Temporal (change) coupling — pure core. Two functions are coupled when they
-- tend to be edited in the same commits. This reveals coupling the static graph
-- CANNOT: shared assumptions, parallel data formats, copy-paste siblings — things
-- with no call edge between them but that must change in lockstep.
--
-- Attribution maps a commit's changed lines to the functions whose ranges (at
-- that commit) contain them; co-occurrence accumulates over commits. Identity is
-- (file, name, kind) — stable across the line churn of history.

local M = {}

function M.key(n) return n.file .. '::' .. n.name .. '/' .. n.kind end

--- Which function keys does a commit touch?
--- @param nodes table[]  the function nodes AT that commit (with ranges)
--- @param changed table  { [file] = { [lineNo]=true, ... } }  (1-based new-side lines)
--- @return table  set of keys
function M.attribute(nodes, changed)
    local touched = {}
    for _, n in ipairs(nodes) do
        if n.kind ~= 'module' then
            local lines = changed[n.file]
            if lines then
                local s, e = atr.sl(n.range) + 1, atr.el(n.range) + 1
                for ln in pairs(lines) do
                    if ln >= s and ln <= e then touched[M.key(n)] = true; break end
                end
            end
        end
    end
    return touched
end

--- Accumulate co-occurrence over a sequence of touched-sets.
--- @param sets table[]  list of key-sets (one per commit)
--- @return { solo:table, pair:table }  solo[k]=#commits touching k; pair["a\31b"]=#commits touching both
function M.accumulate(sets)
    local solo, pair = {}, {}
    for _, set in ipairs(sets) do
        local keys = {}
        for k in pairs(set) do keys[#keys + 1] = k end
        table.sort(keys)
        for i = 1, #keys do
            solo[keys[i]] = (solo[keys[i]] or 0) + 1
            for j = i + 1, #keys do
                local pk = keys[i] .. '\31' .. keys[j]
                pair[pk] = (pair[pk] or 0) + 1
            end
        end
    end
    return { solo = solo, pair = pair }
end

--- Ranked co-change partners of `key`.
--- @return table[]  { { key, count, confidence }, ... }  confidence = count / solo[key]
function M.partners(coupling, key)
    local support = coupling.solo[key] or 0
    local out = {}
    for pk, c in pairs(coupling.pair) do
        local a, b = pk:match('^(.-)\31(.+)$')
        local other = (a == key and b) or (b == key and a) or nil
        if other then
            out[#out + 1] = { key = other, count = c, confidence = support > 0 and (c / support) or 0 }
        end
    end
    table.sort(out, function (x, y)
        if x.count ~= y.count then return x.count > y.count end
        return x.key < y.key
    end)
    return out
end

return M
