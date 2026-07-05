-- The epistemic ladder, as a readable distribution. Every call sits on
-- a rung by HOW its target is known, and the ladder answers "how much
-- of this can I trust" — for one function's outgoing calls, or the
-- whole graph. Pure: counts over store data, no UI.
--
-- Rungs, most-known first:
--   proven   an oracle (clangd/luals) or a cross-language key resolved it
--   linked   a same-file / same-scope name match, no ~ (plain resolution)
--   inferred a cross-file unique-name guess (the ~ vocabulary)
--   dynamic  a call the graph knows it cannot see ($fn(), variable method)
--   refused  ambiguity or scope/vocab declined to pick (a navigable fork)
--   frontier a callee neither resolved nor refused (unparsed / stdlib)

local M = {}

local RUNGS = { 'proven', 'linked', 'inferred', 'dynamic', 'refused', 'frontier' }
M.RUNGS = RUNGS

-- which rung a single call sits on. `edge_proven` = a set of
-- "from\31to" the oracle/xlang marked proven (from store).
local function rung_of(c, proven)
    if c.to then
        if proven and c.fn and proven[c.fn .. '\31' .. c.to] then return 'proven' end
        return c.inferred and 'inferred' or 'linked'
    end
    if c.dynamic then return 'dynamic' end
    if c.refused and c.refused.cands and #c.refused.cands > 0 then return 'refused' end
    return 'frontier'
end
M.rung_of = rung_of

-- proven set: xlang edges and oracle-resolved edges carry a marker on
-- the ref edge (xlang=true) or the graph capability says an oracle ran
local function proven_set(store)
    local set = {}
    for _, e in ipairs(store.data.edges or {}) do
        if e.kind == 'ref' and (e.xlang or e.proven) then
            set[e.from .. '\31' .. e.to] = true
        end
    end
    return set
end

--- Distribution over one function's outgoing calls (by id) or, with
--- no id, the whole graph. Returns { rung -> count, total = n }.
function M.tally(store, id)
    local proven = proven_set(store)
    local out = { total = 0 }
    for _, r in ipairs(RUNGS) do out[r] = 0 end
    local calls = id and (store.calls_by_fn[id] or {}) or (store.data.calls or {})
    for _, c in ipairs(calls) do
        local r = rung_of(c, proven)
        out[r] = out[r] + 1
        out.total = out.total + 1
    end
    return out
end

--- A one-line summary (the fn-view header, the ladder report top).
function M.summary(t)
    local parts = {}
    local glyph = { proven = '✓', linked = '→', inferred = '~',
        dynamic = '$', refused = '?', frontier = '·' }
    for _, r in ipairs(RUNGS) do
        if t[r] > 0 then parts[#parts + 1] = ('%s%d'):format(glyph[r], t[r]) end
    end
    return #parts > 0 and table.concat(parts, ' ') or '(no calls)'
end

--- The graph report: the distribution, then the heaviest refusal sites
--- (the forks worth resolving), each as { file, line, callee, n }.
function M.report(store)
    local t = M.tally(store)
    local lines = { ('epistemic ladder — %d calls'):format(t.total) }
    local label = { proven = 'proven (oracle / cross-language)',
        linked = 'linked (same scope, plain)',
        inferred = 'inferred (~ unique name)',
        dynamic = 'dynamic (unseeable frontier)',
        refused = 'refused (ambiguous fork)',
        frontier = 'frontier (stdlib / unparsed)' }
    for _, r in ipairs(RUNGS) do
        if t[r] > 0 then
            lines[#lines + 1] = ('  %5d  %s'):format(t[r], label[r])
        end
    end
    -- the heaviest refusals: where resolving one fork buys the most
    local refs = {}
    for _, c in ipairs(store.data.calls or {}) do
        if not c.to and not c.dynamic and c.refused
            and c.refused.cands and #c.refused.cands > 0 then
            refs[#refs + 1] = c
        end
    end
    table.sort(refs, function (a, b)
        return (a.refused.n or 0) > (b.refused.n or 0)
    end)
    if #refs > 0 then
        lines[#lines + 1] = ''
        lines[#lines + 1] = 'heaviest refusals (descend a `?callee` in its fn to resolve):'
        for i = 1, math.min(12, #refs) do
            local c = refs[i]
            lines[#lines + 1] = ('  %s:%d  %s  (%d candidates)')
                :format(c.file, c.line + 1, c.callee, c.refused.n or 0)
        end
    end
    return lines
end

return M
