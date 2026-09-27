-- erldispatch — WHAT A DYNAMIC `Mod:f(...)` CAN RUN: the implementers of the behaviour that obliges `f` (CART-1130,
-- step 2). erlang.
-- @langs erlang
--
-- ★★ THE QUESTION A DYNAMIC CALL ASKS, AND WHERE THE TREE ANSWERS IT. `lists:foreach(fun(M) -> M:start(Host) end,
-- Modules)` in ejabberd_auth names no module, and since CART-1129 it is marked dynamic instead of being name-matched to
-- a wrong function. But the tree states the answer: ejabberd_auth declares `-callback start(binary()) -> …`, and seven
-- modules declare `-behaviour(ejabberd_auth)`. A call to a behaviour's own callback, made by the behaviour module, can
-- only reach its implementers — that is what a behaviour IS. Measured on ejabberd: 431 of the 519 variable-module calls
-- call a function some tree behaviour declares as a -callback.
--
-- THE POPULATION, per dynamic call `Mod:f/n` in module C:
--   own       C itself declares `-callback f/n`: Mod ranges over C's implementers (ejabberd_auth -> its 7 backends).
--             The behaviour module dispatching to its own obligation is the idiom; this is the precise case.
--   single    otherwise, exactly one tree behaviour declares f/n: its implementers.
--   several   more than one does: the UNION, every edge marked `pop_ambiguous` — the house answer to not knowing
--             which one is to represent the SET, never to choose.
--   none      no tree behaviour declares f/n: the call stays a frontier (apply/3, a fun value, an OTP behaviour).
-- An implementer that does not define f/n (an -optional_callbacks entry it skipped) gets no edge.
--
-- WHAT IT WRITES: one `ref` edge per (caller function, implementer function), site = the call, `inferred` (~, a
-- population is not a proof of which member runs), `dyn = true`, and `pop = { rule, behaviour(s) }` — the -callback it
-- came from. The CALL stays dynamic: its disposition is unchanged, the edges are a relation over it. ⚠ SESSION-LIVE, a
-- post-pass like erlreg (cartograph.postpass): the gate, which reads extraction, does not see these edges.
local M = {}

local B = require 'cartograph.erlbehaviour'

local function read(p)
    local fd = io.open(p, 'rb'); if not fd then return nil end
    local s = fd:read('a'); fd:close(); return s
end

function M.attach(data)
    local stats = { sites = 0, own = 0, single = 0, several = 0, none = 0, edges = 0, rows = {} }
    local root = data and data.root
    if not root or root:match('^%w+://') then return stats end
    -- every erlang module's behaviour facts, by module name (the file's basename)
    local facts, implementers, declarers = {}, {}, {}
    for _, n in ipairs(data.nodes or {}) do
        if n.kind == 'module' and n.file and n.file:match('%.erl$') then
            local mod = n.file:match('([^/]+)%.erl$')
            local src = read(root .. '/' .. n.file)
            if src then
                local f = B.parse_source(src)
                facts[mod] = f
                for _, b in ipairs(f.behaviours or {}) do
                    if b.name then implementers[b.name] = implementers[b.name] or {}; table.insert(implementers[b.name], mod) end
                end
                for key in pairs(f.by or {}) do declarers[key] = declarers[key] or {}; table.insert(declarers[key], mod) end
            end
        end
    end
    -- the functions each module defines, by name/arity
    local defs = {}
    for _, n in ipairs(data.nodes or {}) do
        if n.kind == 'function' and n.file and n.file:match('%.erl$') then
            local mod = n.file:match('([^/]+)%.erl$')
            local a = B.arity_of(n)
            if a then defs[mod] = defs[mod] or {}; defs[mod][n.name .. '/' .. a] = n.id end
        end
    end
    local seen = {}
    for _, c in ipairs(data.calls or {}) do
        if c.dynamic and c.file and c.file:match('%.erl$') and c.fn and c.callee then
            stats.sites = stats.sites + 1
            local key = c.callee .. '/' .. #(c.argv or c.args or {})
            local caller = c.file:match('([^/]+)%.erl$')
            local behs, rule
            if facts[caller] and facts[caller].by and facts[caller].by[key] then
                behs, rule = { caller }, 'own'
            elseif declarers[key] and #declarers[key] == 1 then
                behs, rule = declarers[key], 'single'
            elseif declarers[key] then
                behs, rule = declarers[key], 'several'
            else
                rule = 'none'
            end
            stats[rule] = stats[rule] + 1
            local n_edges = 0
            for _, b in ipairs(behs or {}) do
                for _, impl in ipairs(implementers[b] or {}) do
                    local to = defs[impl] and defs[impl][key]
                    if to and to ~= c.fn then
                        local k = c.fn .. '\31' .. to
                        local e = seen[k]
                        if not e then
                            e = { from = c.fn, to = to, kind = 'ref', at = {}, inferred = true, dyn = true,
                                pop = { rule = rule, behaviours = behs }, pop_ambiguous = rule == 'several' or nil }
                            seen[k] = e
                            data.edges[#data.edges + 1] = e
                            stats.edges = stats.edges + 1
                        end
                        if c.at then e.at[#e.at + 1] = c.at end
                        n_edges = n_edges + 1
                    end
                end
            end
            stats.rows[#stats.rows + 1] = { file = c.file, line = c.line, call = key, rule = rule, behaviours = behs,
                targets = n_edges }
        end
    end
    data.erldispatch = stats
    return stats
end

--- one line for the open path's notification
function M.summary(s)
    if not s or s.sites == 0 then return nil end
    return ('erldispatch: %d dynamic call(s) — %d to the caller\'s own behaviour, %d to one behaviour, %d to several, '
        .. '%d with no tree behaviour; %d implementer edge(s)'):format(s.sites, s.own, s.single, s.several, s.none, s.edges)
end

return M
