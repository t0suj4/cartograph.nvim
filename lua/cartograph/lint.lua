-- Graph-aware linter (pure). Whole-program checks luacheck can't make because it
-- doesn't have the cross-file symbol graph: dead functions (no caller anywhere),
-- redundant requires (a pure module required only for effect), and call cycles
-- (mutual recursion / load-order risk). Each rule is pure over the store and
-- emits findings; the driver turns them into a quickfix list.
--
-- Honest scoping mirrors the rest of the tool: a no-caller function is only
-- flagged when it's a LOCAL (an exported one is public surface, not dead), and
-- the checks are structural — they surface smells, they don't prove bugs.

local M = {}

local function exported(n)
    return n.kind == 'method' or (n.name and n.name:find('%.') ~= nil)
end

-- metamethods (__index, __call, __newindex, …) are invoked via the metatable,
-- never called by name, so "no caller" says nothing about them.
local function metamethod(n) return n.name and n.name:find('__') ~= nil end

-- Tarjan SCC over an adjacency map (id -> {neighbour ids}).
local function sccs(ids, adj)
    local index, low, onstack, stack, counter, comps = {}, {}, {}, {}, 0, {}
    local function strongconnect(v)
        index[v], low[v] = counter, counter
        counter = counter + 1
        stack[#stack + 1] = v; onstack[v] = true
        for _, w in ipairs(adj[v] or {}) do
            if index[w] == nil then
                strongconnect(w); low[v] = math.min(low[v], low[w])
            elseif onstack[w] then
                low[v] = math.min(low[v], index[w])
            end
        end
        if low[v] == index[v] then
            local comp = {}
            repeat
                local w = stack[#stack]; stack[#stack] = nil; onstack[w] = false
                comp[#comp + 1] = w
            until w == v
            comps[#comps + 1] = comp
        end
    end
    for _, v in ipairs(ids) do if index[v] == nil then strongconnect(v) end end
    return comps
end

-- Paired-key listener audit (wiretap-style register/subscribe/unsubscribe). The
-- listener NAME is a call argument; `at` is its logical index (self is skipped
-- automatically for method calls via the call's `method` flag). Generalises to
-- any register/acquire/release keyed by an argument.
M.listener_config = {
    register    = { verb = 'register_listener', at = 1 },
    subscribe   = { verb = 'subscribe',   at = 2 },
    unsubscribe = { verb = 'unsubscribe', at = 2 },
}

local function listener_findings(store)
    local cfg, calls = M.listener_config, store.data.calls
    if not calls or #calls == 0 then return {} end
    local function abs(c) return store.data.root .. '/' .. c.file end
    local function keyname(c, spec)
        local a = c.args[spec.at + (c.method and 1 or 0)]
        return (a and a ~= '') and a or nil
    end

    local reg, reg_site, subL, sub_site, subDyn, unsubL, unsubDyn = {}, {}, {}, {}, false, {}, false
    local out = {}
    for _, c in ipairs(calls) do
        if c.callee == cfg.register.verb then
            local n = keyname(c, cfg.register)
            if n then reg[n] = true; reg_site[n] = reg_site[n] or c end
            if not c.top then
                out[#out + 1] = { file = abs(c), line = c.line + 1,
                    message = ("listener '%s' is registered inside a function, not at load — may register after init"):format(n or '?') }
            end
        elseif c.callee == cfg.subscribe.verb then
            local n = keyname(c, cfg.subscribe)
            if n then subL[n] = true; sub_site[n] = sub_site[n] or c else subDyn = true end
        elseif c.callee == cfg.unsubscribe.verb then
            local n = keyname(c, cfg.unsubscribe)
            if n then unsubL[n] = true else unsubDyn = true end
        end
    end
    if not next(reg) then return out end -- no register_listener anywhere: not a listener project

    -- subscribe/unsubscribe to a name that's never registered -> runtime error
    for _, c in ipairs(calls) do
        local spec = (c.callee == cfg.subscribe.verb and cfg.subscribe)
            or (c.callee == cfg.unsubscribe.verb and cfg.unsubscribe) or nil
        local n = spec and keyname(c, spec)
        if n and not reg[n] then
            out[#out + 1] = { file = abs(c), line = c.line + 1,
                message = ("%s to '%s', which is never registered (would error: 'Could not find listener')"):format(c.callee, n) }
        end
    end
    -- registered but never subscribed — suppressed if any dynamic subscribe could cover it
    if not subDyn then
        local names = {}; for n in pairs(reg) do names[#names + 1] = n end; table.sort(names)
        for _, n in ipairs(names) do
            if not subL[n] then
                out[#out + 1] = { file = abs(reg_site[n]), line = reg_site[n].line + 1,
                    message = ("listener '%s' is registered but never subscribed"):format(n) }
            end
        end
    end
    -- subscribed but never unsubscribed — suppressed if any dynamic unsubscribe could cover it
    if not unsubDyn then
        local names = {}; for n in pairs(subL) do names[#names + 1] = n end; table.sort(names)
        for _, n in ipairs(names) do
            if not unsubL[n] then
                out[#out + 1] = { file = abs(sub_site[n]), line = sub_site[n].line + 1,
                    message = ("'%s' is subscribed but never unsubscribed (leak-prone)"):format(n) }
            end
        end
    end
    return out
end

M.rules = {
    { name = 'listener-audit', severity = 'warn', run = listener_findings },
    {
        name = 'dead-function', severity = 'warn',
        run = function (store)
            local out = {}
            for _, n in ipairs(store.data.nodes) do
                if n.kind ~= 'module' and not exported(n) and not metamethod(n)
                    and #(store.usedby[n.id] or {}) == 0 then
                    out[#out + 1] = { file = store.abspath(n), line = n.range.start.line + 1,
                        message = ("local function '%s' has no callers (possibly dead)"):format(n.name) }
                end
            end
            return out
        end,
    },
    {
        name = 'redundant-require', severity = 'warn',
        run = function (store)
            local out = {}
            for _, file in ipairs(store.files) do
                if store.classify(file) == 'deadimport' then
                    out[#out + 1] = { file = store.data.root .. '/' .. file, line = 1,
                        message = ("'%s' is required only for effect, but has none — the require is redundant"):format(file) }
                end
            end
            return out
        end,
    },
    {
        name = 'call-cycle', severity = 'warn',
        run = function (store)
            local ids, adj = {}, {}
            for _, n in ipairs(store.data.nodes) do
                if n.kind ~= 'module' then ids[#ids + 1] = n.id; adj[n.id] = store.uses[n.id] end
            end
            local out = {}
            for _, comp in ipairs(sccs(ids, adj)) do
                if #comp > 1 then -- size-1 (plain recursion) is not a smell
                    local names = {}
                    for _, id in ipairs(comp) do names[#names + 1] = store.node(id).name end
                    table.sort(names)
                    local n0 = store.node(comp[1])
                    out[#out + 1] = { file = store.abspath(n0), line = n0.range.start.line + 1,
                        message = 'call cycle: ' .. table.concat(names, ' <-> ') }
                end
            end
            return out
        end,
    },
}

--- Run all (enabled) rules over the store. Returns a flat findings list.
---@param store table
---@param opts { only:table? }?  optional set of rule names to include
---@return table[]  { {rule, severity, file, line, message}, ... }
function M.run(store, opts)
    local only = opts and opts.only
    local findings = {}
    for _, rule in ipairs(M.rules) do
        if not only or only[rule.name] then
            for _, f in ipairs(rule.run(store)) do
                f.rule, f.severity = rule.name, rule.severity
                findings[#findings + 1] = f
            end
        end
    end
    table.sort(findings, function (a, b)
        if a.file ~= b.file then return a.file < b.file end
        return a.line < b.line
    end)
    return findings
end

return M
