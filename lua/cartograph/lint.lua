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

M.rules = {
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
