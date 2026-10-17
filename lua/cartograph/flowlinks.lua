-- FLOW LINKS (CART-1715 step 1): a Lua call that no BINDING links takes its link from FLOW, not from the name join.
--
-- The name join links a call to a definition whose name matches (`site.where()` -> mix.lua's cx.where); flowtype knows
-- which functions can reach the callee (byexample's own `where`). Measured on lua/cartograph: of 7,095 name-matched
-- calls flow pins the same single target for 4,280 (1,667 whole), a set holding it for 1,363, ANOTHER target for 138
-- (the name join's mistakes), and nothing for 1,314; of 46,600 binding-made links it agrees with every one it answers.
--
-- Only calls the name join made (c.inferred) or left refused are touched; a binding's link stays. Per call, by flow:
--   one function, whole                 -> c.to = it, confirmed                       (prov 'flow')
--   one function, partial / +non-fn     -> c.to = it, inferred (~)                    (prov 'flow')
--   several functions                   -> refused { rule = 'flow-set', cands = them }
--   nothing (no callee port, saturated)  -> refused { rule = 'name-only', cands = the name join's pick } where the join
--                                          had linked it; a call already refused stays as it was
-- The ref edges follow: the call's position leaves the old edge (gone once it holds none) and joins the new one.
-- Closed world, one solve, no context instances. Behind config.flow_links (env CARTOGRAPH_FLOW_LINKS=1) while measured.
local M = {}

local callrec = require 'cartograph.callrec'
local atr = require 'cartograph.at'

local function same_at(x, a)
    return rawequal(x, a) or (atr.sl(x) == atr.sl(a) and atr.sc(x) == atr.sc(a) and atr.el(x) == atr.el(a) and atr.ec(x) == atr.ec(a))
end

--- rewrite store.data's Lua calls and ref edges from flow, then re-ingest -> stats
function M.apply(store, opts)
    opts = opts or {}
    local data = store.data
    local R = require('cartograph.flowtype').solve(store, { open = false, ctx = false, allcallees = true })
    if not R.callee_of then return { skipped = 'no Lua walk' } end
    local edges = {}
    for i, e in ipairs(data.edges or {}) do if e.kind == 'ref' then edges[e.from .. '\31' .. e.to] = i end end
    local drop = {}
    -- (a call's position on its edge: the callee token's range, or the call's — the resolvers record either; the exact
    -- range first, else the first one on the call's line)
    local function unlink(from, to, a, line)
        local i = from and to and edges[from .. '\31' .. to]
        local e = i and data.edges[i]
        if not e then return end
        local hit
        for j, x in ipairs(e.at or {}) do if a and same_at(x, a) then hit = j; break end end
        if not hit then for j, x in ipairs(e.at or {}) do if atr.sl(x) == line then hit = j; break end end end
        local keep = {}
        for j, x in ipairs(e.at or {}) do if j ~= hit then keep[#keep + 1] = x end end
        e.at = keep
        if #keep == 0 then drop[i] = true end
    end
    local function link(from, to, a, inferred)
        if not (from and to and a) then return end
        local k = from .. '\31' .. to
        local i = edges[k]
        local e = i and data.edges[i]
        if e and drop[i] then drop[i] = nil end
        if not e then
            e = { from = from, to = to, kind = 'ref', at = {}, self = (from == to) or nil, inferred = inferred or nil }
            data.edges[#data.edges + 1] = e
            edges[k] = #data.edges
        elseif not inferred then e.inferred = nil end
        e.at[#e.at + 1] = a
    end
    -- (a call outside every function is its file's top-level REGION's, as the resolvers attribute it)
    local regions = {}
    for _, n in ipairs(data.nodes or {}) do
        if n.kind == 'region' and n.file and n.range then
            local l = regions[n.file]
            if not l then l = {}; regions[n.file] = l end
            l[#l + 1] = n
        end
    end
    local function owner(c)
        local fn = callrec.fn(c)
        if fn then return fn end
        local line = callrec.line(c)
        for _, n in ipairs(regions[callrec.file(c)] or {}) do
            if line and atr.sl(n.range) <= line and line <= atr.el(n.range) then return n.id end
        end
    end
    local st = { confirmed = 0, inferred = 0, set = 0, name_only = 0, unchanged = 0, moved = 0 }
    for _, c in ipairs(data.calls or {}) do
        local file = callrec.file(c)
        local to = callrec.to(c)
        if file and file:match('%.lua$') and ((to and c.inferred) or (not to and c.refused)) then
            local fns, how = R.callee_of(c)
            -- (only GRAPH NODES are link targets: a function literal flow names itself, `ts:<file>:<row>:<col>`, is not
            -- one — it stays out of the set and makes the answer partial, as a non-function would)
            if fns then
                local real = {}
                for _, id in ipairs(fns) do
                    if store.node(id) then real[#real + 1] = id elseif not how:find('+nonfn', 1, true) then how = how .. '+nonfn' end
                end
                fns = real
            end
            local fn, a = owner(c), c.at
            if fns and #fns == 1 then
                local whole = how == 'whole'
                if fns[1] ~= to then st.moved = st.moved + 1 end
                unlink(fn, to, a, callrec.line(c))
                c.to, c.inferred, c.refused, c.prov = fns[1], (not whole) or nil, nil, 'flow'
                link(fn, fns[1], a, not whole)
                if whole then st.confirmed = st.confirmed + 1 else st.inferred = st.inferred + 1 end
            elseif fns and #fns > 1 then
                unlink(fn, to, a, callrec.line(c))
                c.to, c.inferred, c.prov = nil, nil, nil
                c.refused = { rule = 'flow-set', cands = fns }
                st.set = st.set + 1
            elseif to and not (fns and #fns == 0 and how:find('+nonfn', 1, true)) then
                unlink(fn, to, a, callrec.line(c))
                c.to, c.inferred, c.prov = nil, nil, nil
                c.refused = { rule = 'name-only', cands = { to } }
                st.name_only = st.name_only + 1
            else
                st.unchanged = st.unchanged + 1
            end
        end
    end
    if next(drop) then
        local kept = {}
        for i, e in ipairs(data.edges) do if not drop[i] then kept[#kept + 1] = e end end
        data.edges = kept
    end
    if opts.ingest ~= false then store.ingest(data) end
    return st
end

--- the switch: apply when config.flow_links is on (the load paths call this after ingest)
function M.maybe(store)
    if not require('cartograph.config').flow_links then return nil end
    if not (store.data and store.data.calls) then return nil end
    return M.apply(store)
end

return M
