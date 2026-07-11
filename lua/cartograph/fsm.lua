-- State-machine reachability: which functions can run while the FSM is in a
-- given state? Pure logic over the store's extracted DATA tables (the FSM
-- spec, the per-state subscription map), the call inventory (listener
-- registrations) and the call graph (the reachability cone).
--
-- The domain semantics live in a small declarative adapter (config.fsm): which
-- var holds the transitions, which maps state -> subscriptions, which table
-- holds the callbacks, and the register verb. The engine is generic over that.
-- Callback naming follows the lua-state-machine conventions
-- (onbefore<event> / on<event> / onleave<state> / onenter<state> / onstatechange).

local M = {}
local argv = require 'cartograph.argv'

local function var_by_name(store, name, no_data)
    for _, n in pairs(store.by_id) do
        if n.kind == 'var' and n.name == name and (no_data or n.data) then return n end
    end
end

-- resolve one {ref='name'} indirection through another var's data
local function deref(store, v)
    if type(v) == 'table' and v.ref then
        local n = var_by_name(store, v.ref)
        if n and n.data then return n.data end
    end
    return v
end

--- Registered listener name -> { fn = handler node id (nil if unresolvable),
--- call = the registration call }. Handlers passed as named locals resolve;
--- inline functions are honest nils.
function M.bindings(store, cfg)
    local verb = (cfg or {}).register or 'register_listener'
    local out = {}
    for _, c in ipairs(store.data.calls or {}) do
        if c.callee == verb then
            local off = c.method and 1 or 0
            local name = argv.str(c, 1 + off)
            if name and name ~= '' then
                local hv = argv.at(c, 2 + off)
                local hid
                if hv and hv.k == 'func' and hv.to then
                    hid = store.node(hv.to) and hv.to -- inline fn, named by its key
                elseif hv and hv.k == 'local' and hv.name then
                    for _, n in ipairs(store.by_file[c.file] or {}) do
                        if n.kind == 'function' and n.name == hv.name then
                            hid = n.id
                            break
                        end
                    end
                elseif hv and hv.k == 'field' and hv.path then
                    for id, n in pairs(store.by_id) do
                        if (n.kind == 'function' or n.kind == 'method') and n.name == hv.path then
                            hid = id
                            break
                        end
                    end
                end
                out[name] = { fn = hid, call = c }
            end
        end
    end
    return out
end

--- Callback-table members: name -> fn node id (functions defined inside the
--- callbacks var's constructor span).
function M.callbacks(store, model)
    local out = {}
    local v = model.callbacks_var
    if not v then return out end
    local s, e = v.range.start.line, v.range['end'].line
    for _, n in ipairs(store.by_file[v.file] or {}) do
        if (n.kind == 'function' or n.kind == 'method')
            and n.range.start.line >= s and n.range['end'].line <= e then
            out[n.name] = n.id
        end
    end
    return out
end

--- Autodetect an FSM spec: a litdata var holding (at depth <= 2) a list
--- of >= 2 tables each shaped {name, from, to}. Returns a cfg for M.load,
--- or nil.
function M.detect(store)
    local function is_translist(t)
        if type(t) ~= 'table' or #t < 2 then return false end
        local hits = 0
        for _, e in ipairs(t) do
            if type(e) == 'table' and e.name and e.from and e.to then
                hits = hits + 1
            end
        end
        return hits >= 2 and hits >= #t * 0.6
    end
    local function scan(t, path, depth)
        if depth > 2 or type(t) ~= 'table' then return nil end
        if is_translist(t) then return path end
        for k, v in pairs(t) do
            if type(k) == 'string' and type(v) == 'table' then
                local sub = scan(v, vim.list_extend(vim.list_extend({}, path), { k }), depth + 1)
                if sub then return sub end
            end
        end
        return nil
    end
    for _, n in pairs(store.by_id) do
        if n.kind == 'var' and type(n.data) == 'table' then
            local path = scan(n.data, {}, 0)
            if path then
                return { events = { var = n.name, path = path }, detected = true }
            end
        end
    end
    return nil
end

--- Build the state model from the adapter config. Returns model or nil, reason.
function M.load(store, cfg)
    cfg = cfg or require('cartograph.config').fsm
    if not (cfg and cfg.events and cfg.events.var) then
        return nil, 'no fsm adapter configured (setup{ fsm = {...} })'
    end
    local ev = var_by_name(store, cfg.events.var)
    if not ev then return nil, ('no data table %q in the graph'):format(cfg.events.var) end
    local events, container = ev.data, ev.data
    for _, seg in ipairs(cfg.events.path or {}) do
        container = events
        events = type(events) == 'table' and events[seg] or nil
    end
    if type(events) ~= 'table' then return nil, 'transitions not found in the spec data' end

    local model = { transitions = {}, order = {}, subs = {}, cfg = cfg }
    local seen = {}
    local function addstate(s)
        if type(s) == 'string' and s ~= '*' and not seen[s] then
            seen[s] = true
            model.order[#model.order + 1] = s
        end
    end
    -- lua-state-machine names the starting state next to the events list; it
    -- may appear nowhere else as a `to`, so seed the order with it
    if type(container) == 'table' and type(container.initial) == 'string' then
        addstate(container.initial)
        model.initial = container.initial
    end
    for _, t in ipairs(events) do
        if type(t) == 'table' and t.name then
            -- `from` is a state name, an array of them, or '*'
            local from = type(t.from) == 'table' and t.from or { t.from }
            model.transitions[#model.transitions + 1] =
                { name = t.name, from = from, to = t.to }
            for _, f in ipairs(from) do addstate(f) end
            addstate(t.to)
        end
    end
    if #model.transitions == 0 then return nil, 'no transitions in the spec data' end

    local bindings = M.bindings(store, cfg)
    local sv = cfg.subs and var_by_name(store, cfg.subs.var)
    if sv and type(sv.data) == 'table' then
        for state, list in pairs(sv.data) do
            local out = {}
            for _, entry in ipairs(type(list) == 'table' and list or {}) do
                entry = deref(store, entry)
                if type(entry) == 'table' then
                    -- the listener is the string element that names a
                    -- registered listener (fallback: last string element)
                    local pick, laststr
                    for _, el in ipairs(entry) do
                        if type(el) == 'string' then
                            laststr = el
                            if bindings[el] then pick = el end
                        end
                    end
                    out[#out + 1] = { listener = pick or laststr }
                end
            end
            model.subs[state] = out
        end
    end
    model.callbacks_var = cfg.callbacks and var_by_name(store, cfg.callbacks.var, true)
    model.events_var = ev
    model.bindings = bindings
    return model
end

--- Transitions leaving `state` (including from='*' wildcards).
function M.transitions_from(model, state)
    local out = {}
    for _, t in ipairs(model.transitions) do
        for _, f in ipairs(t.from) do
            if f == state or f == '*' then out[#out + 1] = t; break end
        end
    end
    return out
end

--- Entry points active in `state`: subscribed listeners + the FSM callbacks
--- its outgoing transitions can fire. { {kind, label, fn?}, ... } (fn nil =
--- honest frontier: unresolvable handler).
function M.entrypoints(store, model, state)
    local cbs = M.callbacks(store, model)
    local eps, seen = {}, {}
    local function add(kind, label, fn)
        if label and not seen[label] then
            seen[label] = true
            eps[#eps + 1] = { kind = kind, label = label, fn = fn }
        end
    end
    for _, sub in ipairs(model.subs[state] or {}) do
        local b = sub.listener and model.bindings[sub.listener]
        add('listener', sub.listener or '?', b and b.fn)
    end
    local function cb(name)
        if cbs[name] then add('callback', name, cbs[name]) end
    end
    for _, t in ipairs(M.transitions_from(model, state)) do
        cb('onbefore' .. t.name)
        cb('on' .. t.name)
        cb('onafter' .. t.name)
        cb('onleave' .. state)
        cb('onenter' .. t.to)
        cb('on' .. t.to)
        cb('onstatechange')
    end
    return eps
end

--- Reachability cone from a set of node ids (BFS over the call graph).
--- Returns set, count.
function M.cone(store, ids)
    local seen, queue = {}, {}
    for _, id in ipairs(ids) do
        if id and not seen[id] then seen[id] = true; queue[#queue + 1] = id end
    end
    local i = 1
    while queue[i] do
        for _, to in ipairs(store.uses[queue[i]] or {}) do
            if not seen[to] then seen[to] = true; queue[#queue + 1] = to end
        end
        i = i + 1
    end
    return seen, #queue
end

--- Convenience: entry fn ids + cone count for a state.
function M.state_cone(store, model, state)
    local ids = {}
    for _, e in ipairs(M.entrypoints(store, model, state)) do
        if e.fn then ids[#ids + 1] = e.fn end
    end
    local set, n = M.cone(store, ids)
    return set, n
end

return M
