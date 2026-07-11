-- The Band: a read-only TOPOLOGY view — the one query seam every graph
-- consumer reads through, so the representation behind it can change in one
-- place. A Band answers directional slices over the typed edges
-- (ref/use/reg/import) as node-id lists; domain sugar (callers/callees/
-- registrants/…) names the predicate+direction points.
--
-- TWO interchangeable backends, ONE interface:
--   * from_store — reads the wide store's forward/backward index tables
--     (today's representation)
--   * from_fold  — reads the folded triple table's out/incoming slices
--     (the resident representation, [[cartograph-fold]])
-- They return IDENTICAL results (parity-tested), which is the whole point:
-- migrate a consumer onto the Band, prove the fold backend matches, THEN
-- swap the representation with the suite still green (API-first, per the
-- scaling memo's DOGFOODING section).
--
-- Self-loops: the ref graph VIEW excludes recursion (matching the wide
-- store's uses/usedby), so callers/callees never include the node itself.

local M = {}

local Band = {}
Band.__index = Band

-- ── domain sugar: the named predicate×direction points ───────────────────
function Band:callees(id)      return self:_fwd(id, 'ref') end   -- fns this calls
function Band:callers(id)      return self:_bwd(id, 'ref') end   -- fns calling this
function Band:var_uses(id)     return self:_fwd(id, 'use') end   -- vars this reads
function Band:var_used_by(id)  return self:_bwd(id, 'use') end   -- readers of this var
function Band:registered(id)   return self:_fwd(id, 'reg') end   -- what this registers
function Band:registrants(id)  return self:_bwd(id, 'reg') end   -- who registers this
function Band:imports_out(id)  return self:_fwd(id, 'import') end
function Band:imports_in(id)   return self:_bwd(id, 'import') end

-- counts (the cheap degree query — dead-code's actual need)
function Band:n_callers(id)     return #self:callers(id) end
function Band:n_registrants(id) return #self:registrants(id) end

-- CERTAINTY: the honesty tier of a ref edge (from→to), the thing that must
-- survive the representation swap — 'confident' | 'inferred' (~) | nil.
-- (Backends implement _tier; the sugar keeps the ref-graph default.)
function Band:tier(from, to) return self:_tier(from, to) end

-- ── store backend: the wide forward/backward index tables ────────────────
local StoreBand = setmetatable({}, { __index = Band })
StoreBand.__index = StoreBand

-- store shapes vary by kind: ref forward/backward store plain ids; use/reg/
-- import store {from=|to=} records — normalize to id lists here
local S_FWD = {
    ref = { t = 'uses' }, use = { t = 'var_uses', k = 'to' },
    reg = { t = 'registers' }, import = { t = 'imports_out' },
}
local S_BWD = {
    ref = { t = 'usedby' }, use = { t = 'var_usedby', k = 'from' },
    reg = { t = 'reg_by', k = 'from' }, import = { t = 'imports_in', k = 'from' },
}
local function store_slice(store, spec, id)
    local raw = store[spec.t] and store[spec.t][id]
    if not raw then return {} end
    if not spec.k then return raw end -- already an id list
    local out = {}
    for i = 1, #raw do out[i] = raw[i][spec.k] end
    return out
end
function StoreBand:_fwd(id, kind) return store_slice(self.store, S_FWD[kind], id) end
function StoreBand:_bwd(id, kind) return store_slice(self.store, S_BWD[kind], id) end
function StoreBand:_tier(from, to)
    local u = self.store.uses[from]
    if not u then return nil end
    local found = false
    for i = 1, #u do if u[i] == to then found = true; break end end
    if not found then return nil end
    local k = from .. '\31' .. to
    if self.store.edge_tinf and self.store.edge_tinf[k] then return 'type-inferred' end
    return self.store.edge_inferred[k] and 'inferred' or 'confident'
end

function M.from_store(store)
    return setmetatable({ store = store }, StoreBand)
end

-- ── fold backend: the folded triple table's slices ───────────────────────
local FoldBand = setmetatable({}, { __index = Band })
FoldBand.__index = FoldBand

local fold_mod -- lazy: PRED table
local function names_of(f, ints)
    local out = {}
    for i = 1, #ints do out[i] = f.names[ints[i] + 1] end
    return out
end
function FoldBand:_fwd(id, kind)
    local f = self.fold
    local sid = f.it.get(id)
    if not sid then return {} end
    return names_of(f, f:out(sid, fold_mod.PRED[kind], kind == 'ref'))
end
function FoldBand:_bwd(id, kind)
    local f = self.fold
    local oid = f.it.get(id)
    if not oid then return {} end
    return names_of(f, f:incoming(oid, fold_mod.PRED[kind], kind == 'ref'))
end
function FoldBand:_tier(from, to)
    local f = self.fold
    local s, o = f.it.get(from), f.it.get(to)
    if not s or not o then return nil end
    return f:tier(s, o, fold_mod.PRED.ref)
end

function M.from_fold(fold)
    fold_mod = fold_mod or require 'cartograph.fold'
    return setmetatable({ fold = fold }, FoldBand)
end

return M
