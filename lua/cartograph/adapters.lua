-- cartograph.adapters — A SKELETON GRAPH WITH GENERATED ADAPTERS (CART-1160 step 8). USER (2026-09-28): "graph in
-- RAM is fine, but what if it can't or doesn't need to fit? I think we can calculate only a skeleton and generate
-- adapters that fetch the data as needed" · "The generated adapters could be optimized for the task".
--
-- THE SKELETON is the thin index (treesitter.index_only): every file's defs, cheap to build — MEASURED 7-11x faster and
-- 62-106x lighter than a full extract, and the consumer roster (CART-1160 step 8 notes) derives the same field set as
-- the most-read one. THE DETAIL is everything a per-file PRODUCER adds on demand (store.materialize_file_dataflow).
--
-- ★ THE ADAPTERS ARE DERIVED, NOT WRITTEN: `derive()` builds a skeleton of a probe tree, runs each producer on it, and
-- records which node fields the producer WROTE (ask the producer) and whether it touched anything outside that file's
-- node records (graph-level tables, the generation). Those fields become the adapter's TRIGGERS; a LOCAL producer is
-- installed as an access-triggered adapter, a non-local one is never run from a field read (a relink mutating
-- data.calls under a consumer's loop) — it stays a PREFETCH a task asks for.
-- ★ ACCESS-TRIGGERED: on a skeleton graph each node carries a metatable whose __index fills the node's file when a
-- trigger field is read. Before this, `df.stmts(n)` on an unmaterialized node returned {} — a uniform empty that reads
-- as "no statements", the silent absence the thin index was always one forgotten materialize call away from.
-- ★ IT NEED NOT FIT: `budget` bounds how many files' detail are resident; filling past it EVICTS the least recently
-- filled file's detail (the fields go, the node stays), and the next read fills it again. Resident = skeleton + budget.
-- ★ OPTIMIZED FOR THE TASK: `prefetch(files, fields)` fills exactly the producers those fields need, once per file —
-- a task that declares what it reads pays for that and nothing else.
local M = { budget = nil, stats = { fills = 0, evictions = 0, prefetched = 0 } }

--- the producers an adapter may use: name -> fill(store, rel). Each is PROBED before it is trusted as an adapter.
local PRODUCERS = {
    dataflow = function (store, rel) return store.materialize_file_dataflow(rel) end,
    calls = function (store, rel) return store.materialize_file_calls(rel) end,
}

local derived, deriving
--- probe each producer on a tiny skeleton -> { [name] = { fields = { f = true }, is_local = bool } } | nil, why
function M.derive()
    if derived then return derived end
    if deriving then return nil, 'deriving' end -- the probe's own skeleton is ingested: no adapters on it
    local store = require 'cartograph.store'
    local ts = require 'cartograph.providers.treesitter'
    if not pcall(vim.treesitter.get_string_parser, '', 'lua') then return nil, 'no lua parser to probe the producers with' end
    deriving = true
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/probe.lua', 'w'))
    fd:write('local M = {}\nfunction M.f(t)\n  local n = 0\n  for i = 1, #t do n = n + t[i] end\n  return M.g(n)\nend\n'
        .. 'function M.g(x) return x * 2 end\nreturn M\n')
    fd:close()
    local out = {}
    for name, fill in pairs(PRODUCERS) do
        local ok, res = pcall(store.scoped, ts.index_only(root), function ()
            local before = {}
            for _, n in ipairs(store.data.nodes) do local s = {}; for k in pairs(n) do s[k] = true end; before[n.id] = s end
            local shape = { calls = #(store.data.calls or {}), edges = #(store.data.edges or {}), gen = store.generation }
            fill(store, 'probe.lua')
            local fields = {}
            for _, n in ipairs(store.data.nodes) do
                for k in pairs(n) do if not (before[n.id] or {})[k] then fields[k] = true end end
            end
            local is_local = #(store.data.calls or {}) == shape.calls and #(store.data.edges or {}) == shape.edges
                and store.generation == shape.gen
            return { fields = fields, is_local = is_local }
        end)
        if ok and res and next(res.fields) then out[name] = res end
    end
    vim.fn.delete(root, 'rf')
    derived, deriving = out, false
    return out
end

--- the LOCAL producers' trigger fields: { field -> producer name }
local function triggers()
    local T = {}
    for name, a in pairs(M.derive() or {}) do
        if a.is_local then for f in pairs(a.fields) do T[f] = name end end
    end
    return T
end

-- ── the resident working set (the budget) ────────────────────────────────────────────────────────────────────────
-- ★ PER GRAPH, IN THE GRAPH (CART-1160 step 1's rule): `data._adapters = { order, resident, filling }` — a lens switch
-- (store.scoped, a band switch) must not make one graph's working set answer for another's.
local function ws(store)
    local d = store.data
    d._adapters = d._adapters or { order = {}, resident = {}, filling = {} }
    return d._adapters
end

local function evict(store, rel, fields)
    for _, n in ipairs(store.by_file[rel] or {}) do
        for f in pairs(fields) do rawset(n, f, nil) end
    end
    if store._df_materialized then store._df_materialized[rel] = nil end
    ws(store).resident[rel] = nil
    M.stats.evictions = M.stats.evictions + 1
end

local function fill(store, rel, producer, T)
    local w = ws(store)
    if w.resident[rel] or w.filling[rel] then return end
    w.filling[rel] = true
    local ok, err = pcall(PRODUCERS[producer], store, rel)
    w.filling[rel] = nil
    if not ok then error(err, 0) end
    w.resident[rel] = true
    w.order[#w.order + 1] = rel
    M.stats.fills = M.stats.fills + 1
    if M.budget then
        local fields = {}
        for f, p in pairs(T) do if p == producer then fields[f] = true end end
        local live = 0
        for _, r in ipairs(w.order) do if w.resident[r] then live = live + 1 end end
        while live > M.budget and #w.order > 0 do
            local old = table.remove(w.order, 1)
            if w.resident[old] and old ~= rel then evict(store, old, fields); live = live - 1 end
        end
    end
end

--- install the adapters on the ACTIVE graph when it is a skeleton (index_only). -> number of nodes adapted
function M.install(store)
    local data = store.data
    if not (data and data.index_only) then return 0 end
    if deriving then return 0 end
    local T = triggers()
    if not next(T) then return 0 end
    data._adapters = { order = {}, resident = {}, filling = {} }
    local mt = { __index = function (n, k)
        local producer = T[k]
        if not producer then return nil end
        local rel = rawget(n, 'file')
        -- the node's OWN graph must be the lens: a node read after its graph left the lens is not filled from another
        if rel and store.data == data then
            local w = ws(store)
            if not w.resident[rel] and not w.filling[rel] then fill(store, rel, producer, T) end
        end
        return rawget(n, k)
    end }
    local count = 0
    for _, n in ipairs(data.nodes or {}) do
        if getmetatable(n) == nil then setmetatable(n, mt); count = count + 1 end
    end
    return count
end

--- fill exactly what `fields` needs for `files`, once each: the adapter optimized for a task that declares its reads.
--- A non-local producer runs here and only here. -> number of (file, producer) fills
function M.prefetch(store, files, fields)
    local all = M.derive() or {}
    -- per field, the CHEAPEST producer that provides it: a local one when any exists (a non-local producer also fills
    -- df/flow — it re-derives the file whole — and a task asking for df must not pay for a relink)
    local want = {}
    for _, f in ipairs(fields or {}) do
        local loc, nonloc = {}, {}
        for name, a in pairs(all) do
            if a.fields[f] then if a.is_local then loc[#loc + 1] = name else nonloc[#nonloc + 1] = name end end
        end
        for _, name in ipairs(#loc > 0 and loc or nonloc) do want[name] = true end
    end
    local T = triggers()
    local n = 0
    for name in pairs(want) do
        for _, rel in ipairs(files or {}) do
            if all[name].is_local then
                if not ws(store).resident[rel] then fill(store, rel, name, T); n = n + 1 end
            else
                PRODUCERS[name](store, rel); n = n + 1
            end
        end
    end
    M.stats.prefetched = M.stats.prefetched + n
    return n
end

--- the files whose detail is resident right now
function M.resident(store)
    local w = ws(store or require 'cartograph.store')
    local out, seen = {}, {}
    for _, rel in ipairs(w.order) do if w.resident[rel] and not seen[rel] then seen[rel] = true; out[#out + 1] = rel end end
    return out
end

return M
