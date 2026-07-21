local callrec = require 'cartograph.callrec'
-- The CONFIRMED tier: runtime-observed ground truth. If cartograph can
-- RUN the code it analyzes (self://loaded, factorio MCP, a live server),
-- observed dispatch is the SOUND reference static resolution only
-- approximates — the honesty ladder's top rung, above even a static
-- oracle: name-matched(~) < type-inferred < proven(static) < CONFIRMED
-- (the full ladder + its precedence live in [[cartograph.tier]]; this module
-- PRODUCES the `conf` top rung, it doesn't re-derive the order).
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

-- DISAGREEMENT AS PRODUCT: static resolution vs observed dispatch. Where
-- they agree = confirmed; where the runtime resolved what static REFUSED =
-- recovered (a win); where static resolved (fn,callee)->B but the runtime
-- only ever dispatched it to C (never B) = a CONFLICT — the memo's "VM
-- error OR real finding: dead branch / unexpected dispatch / config drift".
--
-- `dispatch` = { [fn_id\31callee] = { [target_id] = true, ... } } — the
-- targets a call point routed to at runtime (a set: >1 = genuinely
-- polymorphic). SOUNDNESS: a conflict is only sound when the observed set
-- is a SINGLE target (monomorphic site) — then runtime->C refutes static->B.
-- If the site dispatched to several, static->B may just be an unobserved
-- arm, so it's reported as 'polymorphic' context, not a conflict. Absence
-- of any observation for a call = never touched (not-yet-run, not a finding).
function M.diff(data, dispatch)
    local function keys(set)
        local k = {}; for id in pairs(set) do k[#k + 1] = id end
        table.sort(k); return k
    end
    local confirmed, recovered, findings = 0, 0, {}
    for _, c in ipairs(data.calls or {}) do
        local obs = c.fn and dispatch[c.fn .. '\31' .. (c.full or c.callee or '')]
        if obs then
            local rt = keys(obs)
            local mono = #rt == 1
            if c.to then
                if obs[c.to] then
                    c.conf = true; confirmed = confirmed + 1
                elseif mono then
                    -- static picked B, runtime only ever went to C — sound
                    findings[#findings + 1] = { kind = 'conflict',
                        fn = c.fn, callee = c.callee, file = callrec.file(c),
                        line = c.line, static = c.to, runtime = rt }
                else
                    findings[#findings + 1] = { kind = 'polymorphic',
                        fn = c.fn, callee = c.callee, file = callrec.file(c),
                        line = c.line, static = c.to, runtime = rt }
                end
            else
                -- static refused/frontier; runtime resolved it
                if mono then c.to, c.conf = rt[1], true end
                findings[#findings + 1] = { kind = 'recovered',
                    fn = c.fn, callee = c.callee, file = callrec.file(c),
                    line = c.line, static = nil, runtime = rt }
                recovered = recovered + 1
            end
        end
    end
    return { confirmed = confirmed, recovered = recovered, findings = findings }
end

-- Render a diff report as sorted finding lines (the honest product): each
-- disagreement is a place to look, tagged by kind.
function M.report(diff, node_name)
    local nm = node_name or function (id) return id end
    local lines = { ('runtime diff: %d confirmed · %d recovered · %d disagreements')
        :format(diff.confirmed, diff.recovered, #diff.findings) }
    local order = {}
    for _, f in ipairs(diff.findings) do order[#order + 1] = f end
    table.sort(order, function (a, b)
        if a.file ~= b.file then return (a.file or '') < (b.file or '') end
        return (a.line or 0) < (b.line or 0)
    end)
    for _, f in ipairs(order) do
        local rt = {}
        for _, id in ipairs(f.runtime) do rt[#rt + 1] = nm(id) end
        if f.kind == 'recovered' then
            lines[#lines + 1] = ('  %s:%d  %s → %s (RECOVERED: static refused)')
                :format(f.file or '?', (f.line or 0) + 1, f.callee,
                    table.concat(rt, ', '))
        elseif f.kind == 'conflict' then
            lines[#lines + 1] = ('  %s:%d  %s → static %s, runtime %s (CONFLICT)')
                :format(f.file or '?', (f.line or 0) + 1, f.callee,
                    nm(f.static), table.concat(rt, ', '))
        else
            lines[#lines + 1] = ('  %s:%d  %s → static %s, runtime {%s} (polymorphic)')
                :format(f.file or '?', (f.line or 0) + 1, f.callee,
                    nm(f.static), table.concat(rt, ', '))
        end
    end
    return lines
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
