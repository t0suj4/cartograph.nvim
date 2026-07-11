-- The live oracle: the running system is the top rung of the epistemics
-- ladder. Through an MCP server it answers what IS — which listeners are
-- actually subscribed, which FSM state each force actually occupies — and
-- the diff against the static model turns hypotheses into verdicts:
-- a listener the current states demand but the game lacks is a missing
-- subscription; one the game holds but no occupied state explains is a
-- leak from an earlier state — the exact bug class wiretap's ordering
-- discipline exists to prevent.
--
-- Queries are ENTIRELY project config (setup{ live = { server, tool,
-- snapshot } }): what to ask a running system and how to read the
-- answer is that system's shape. examples/factorio.lua shows a full
-- wiring. One design rule the snapshot must honor: ONE query, ONE
-- moment — reading subscriptions and states separately can tear (a
-- transition in the gap fabricates leaks); return everything from a
-- single atomic call, stamped with when it was true.

local M = {}
local argv = require 'cartograph.argv'

--- Pure: diff the live picture against the static model.
--- live = { subscriptions = {name...}, states = {force -> state} }
--- Returns findings + the expected set for display.
function M.diff(store, model, live)
    local fsm = require 'cartograph.fsm'
    local out = { missing = {}, extra = {}, unknown = {} }
    -- expected listeners = PERMANENT subscriptions (subscribe called at
    -- load time, outside the state machinery) + the union over the states
    -- forces actually occupy
    local expected = {}
    local lc = require('cartograph.lint').listener_config
    for _, c in ipairs(store.data.calls or {}) do
        if c.top and c.callee == lc.subscribe.verb then
            local n = argv.str(c, lc.subscribe.at + (c.method and 1 or 0))
            if n and n ~= '' then expected[n] = true end
        end
    end
    for _, st in pairs(live.states or {}) do
        for _, sub in ipairs(model and model.subs and model.subs[st] or {}) do
            if sub.listener then expected[sub.listener] = true end
        end
    end
    local live_set = {}
    for _, n in ipairs(live.subscriptions or {}) do live_set[n] = true end
    for n in pairs(expected) do
        if not live_set[n] then out.missing[#out.missing + 1] = n end
    end
    -- registered names (the static registry) tell leak from unknown
    local registered = {}
    if model and model.bindings then
        for n in pairs(model.bindings) do registered[n] = true end
    end
    for n in pairs(live_set) do
        if not expected[n] then
            if registered[n] then
                out.extra[#out.extra + 1] = n -- known listener, wrong state: leak
            else
                out.unknown[#out.unknown + 1] = n -- graph blind spot
            end
        end
    end
    table.sort(out.missing)
    table.sort(out.extra)
    table.sort(out.unknown)
    out.expected = expected
    return out
end

--- Fetch the live picture over MCP — one atomic snapshot query.
--- Returns { tick?, subscriptions, states } or nil, why.
function M.fetch(cfg)
    local servers = require('cartograph.config').mcp or {}
    local scfg = servers[cfg.server]
    if not scfg then
        return nil, ("no MCP server %q configured"):format(cfg.server)
    end
    local client, err = require('cartograph.mcp').connect(scfg)
    if not client then return nil, err end
    local snap, why = client:call(cfg.tool, { code = cfg.snapshot }, 20000)
    client:close()
    if type(snap) ~= 'table' then
        return nil, 'snapshot query failed: ' .. tostring(why)
    end
    -- empty JSON arrays/objects both decode to {}; normalize
    return {
        tick = tonumber(snap.tick),
        subscriptions = type(snap.subscriptions) == 'table'
            and snap.subscriptions or {},
        states = type(snap.states) == 'table' and snap.states or {},
    }
end

--- The check: fetch, diff, publish (store.live drives the states-view
--- markers), and return report lines.
function M.check(store)
    local cfg = require('cartograph.config').live
    if not (cfg and cfg.server and cfg.snapshot) then
        return nil, 'no live oracle configured — setup{ live = { server,'
            .. ' tool, snapshot } }; see examples/factorio.lua'
    end
    cfg = vim.tbl_deep_extend('force', { tool = 'run_lua' }, cfg)
    local live, why = M.fetch(cfg)
    if not live then return nil, why end
    local fsm = require 'cartograph.fsm'
    local model = fsm.load(store) or (fsm.detect(store)
        and fsm.load(store, fsm.detect(store)))
    local d = M.diff(store, model, live)
    -- publish for the browser: states occupied right now
    local occupied = {}
    for force, st in pairs(live.states) do
        occupied[st] = (occupied[st] or 0) + 1
    end
    store.live = { states = occupied, subscriptions = live.subscriptions,
        tick = live.tick }

    local lines = { ('live check%s — %d subscription(s), %d force(s)')
        :format(live.tick and (' @ tick ' .. live.tick) or '',
            #live.subscriptions, vim.tbl_count(live.states)) }
    for force, st in pairs(live.states) do
        lines[#lines + 1] = ('  force %s ⇒ %s'):format(force, st)
    end
    local function section(title, list, mark)
        if #list > 0 then
            lines[#lines + 1] = title
            for _, n in ipairs(list) do
                lines[#lines + 1] = '  ' .. mark .. ' ' .. n
            end
        end
    end
    section('MISSING (state demands, game lacks):', d.missing, '✗')
    section('LEAKED (live, but no occupied state explains it):', d.extra, '⚠')
    section('UNKNOWN (live, absent from the graph):', d.unknown, '?')
    if #d.missing + #d.extra + #d.unknown == 0 then
        -- a sample proves the moment, not the invariant
        lines[#lines + 1] = 'runtime agrees with the model ✓ (at this tick)'
    end
    return lines, nil, d
end

return M
