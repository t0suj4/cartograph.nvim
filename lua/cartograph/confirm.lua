-- The CONFIRMED tier: runtime-observed ground truth. If cartograph can
-- RUN the code it analyzes (self://loaded, factorio MCP, a live server),
-- observed dispatch is the SOUND reference static resolution only
-- approximates — the honesty ladder's top rung, above even a static
-- oracle: name-matched(~) < type-inferred < proven(static) < CONFIRMED.
--
-- Two escalating uses ([[graph-vm-type-resolution]]):
--   * CONFIRM — an edge the graph already has, observed live → upgrade its
--     tier to runtime-confirmed (`e.conf`);
--   * RECOVER — an edge observed live that static resolution MISSED
--     (refused/blind) → add it, conf-tiered (the "resolve one dynamic
--     dispatch name-matching refuses" proof).
--
-- SOUNDNESS TRAP (the memo): observed ⊆ static — a run exercises SOME
-- paths, not all. So observation CONFIRMS and RECOVERS; ABSENCE never
-- refutes (a static edge not seen live is not dead — just not-yet-run).
-- Runtime facts are SAMPLES ([[cartograph-vision]] persistence rule):
-- this is a session-live OVERLAY on the edges, never folded or cached.

local M = {}

-- Apply a runtime-observation set to the graph. `observed` = a set of
-- "from\31to" edge keys seen live. Mutates data (marks e.conf / adds
-- recovered edges + c.conf on calls); returns { confirmed, recovered }.
function M.apply(data, observed)
    local have = {}
    for _, e in ipairs(data.edges) do
        if e.kind == 'ref' or e.kind == 'import' then
            have[e.from .. '\31' .. e.to] = e
        end
    end
    local confirmed, recovered = 0, 0
    for key in pairs(observed) do
        local e = have[key]
        if e then
            if not e.conf then e.conf = true; confirmed = confirmed + 1 end
        else
            local from, to = key:match('^(.-)\31(.*)$')
            if from and to and from ~= to then
                data.edges[#data.edges + 1] = { from = from, to = to,
                    kind = 'ref', conf = true } -- runtime RECOVERED
                have[key] = data.edges[#data.edges]
                recovered = recovered + 1
            end
        end
    end
    -- carry the tier onto the calls (the ladder/census read c.conf); a
    -- resolved call whose (fn->to) was observed is confirmed
    for _, c in ipairs(data.calls or {}) do
        if c.to and c.fn and observed[c.fn .. '\31' .. c.to] then
            c.conf = true
        end
    end
    return { confirmed = confirmed, recovered = recovered }
end

-- Observe cartograph's OWN running state (self://loaded): the module
-- import graph, confirmed against package.loaded — a require edge whose
-- target module is actually LIVE is runtime-confirmed. The bounded first
-- source (dispatch-table observation is the richer follow-on). Returns an
-- observed edge-key set for M.apply.
function M.observe_self(data)
    local so = require 'cartograph.self_oracle'
    local mod2key = {}
    for abs, modname in pairs(so.loaded_index(data)) do
        local key = so.key_for_abs(abs, data)
        if key then mod2key[modname] = key end
    end
    local observed = {}
    for _, e in ipairs(data.edges) do
        if e.kind == 'import' then
            -- the target file backs a live-loaded module → the import fired
            for _, k in pairs(mod2key) do
                if k == e.to then observed[e.from .. '\31' .. e.to] = true end
            end
        end
    end
    return observed
end

return M
