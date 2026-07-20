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
function Band:n_callees(id)     return #self:callees(id) end
function Band:n_registrants(id) return #self:registrants(id) end

-- CERTAINTY: the honesty tier of a ref edge (from→to), the thing that must
-- survive the representation swap — 'confident' | 'inferred' (~) | nil.
-- (Backends implement _tier; the sugar keeps the ref-graph default.)
function Band:tier(from, to) return self:_tier(from, to) end

-- ACCESS MODE of a use edge (the write axis): 'read' | 'write' | 'both' |
-- nil (no edge, or the language shipped no classifier — mode unknown)
function Band:rw(from, to) return self:_rw(from, to) end

-- GUARD CHAIN of a use edge's writes: 1 some-unguarded / 2 all-guarded /
-- 3 all-set-once / nil; PARAM PREDICATE (±index); PER-FIELD facts
-- ({field -> packed rw+gw*4}) — the analysis ladder, both backends
function Band:gw(from, to) return self:_gw(from, to) end
function Band:gp(from, to) return self:_gp(from, to) end
function Band:flds(from, to) return self:_flds(from, to) end

-- ── IDENTITY + DETAIL axes: name / file / call-site ──────────────────────
-- These slice NODE IDENTITY (named/nodes_of) and CALL OUTCOMES (sites),
-- which are representation-STABLE — the same regardless of whether topology
-- is wide-store or folded — so both backends answer them off the same
-- `_idx()` handle (the wide index the fold does not fold). This is where the
-- LSP name→node index and the refresh/documentSymbol file unit live — one
-- home on the seam, not a P1 special ([[cartograph-slice-api]] coverage). A
-- backend with no identity handle (a bare fold, no store) returns empty.

--- NAME axis: node ids whose bare name == `name` (a list — overloads and
--- same-named locals across files collide). The LSP workspaceSymbol index.
function Band:named(name)
    local idx = self:_idx()
    return (idx and idx.by_name[name]) or {}
end

--- FILE axis: the non-module node ids defined in `file` (the module node's
--- id IS the file key). The refresh / documentSymbol unit.
function Band:nodes_of(file)
    local idx = self:_idx()
    if not idx then return {} end
    local out = {}
    for _, n in ipairs(idx.by_file[file] or {}) do out[#out + 1] = n.id end
    return out
end

--- CALL-SITE axis: the call rows made FROM function `id`, as outcomes
--- (each row carries its resolution: c.to / c.refused / c.ext disposition).
--- Tier-1 slice; the argv/witness detail is Tier-2 reconstruct off the row.
function Band:sites(id)
    local idx = self:_idx()
    return (idx and idx.calls_by_fn[id]) or {}
end

-- USE / REG record slices (Tier-2 reconstruct): the FULL edge records, not
-- the bare id lists callees/var_uses/registrants return. A use record is
-- { to|from, at, rw, gw, gp, flds }; a reg record { from, at }. The `at`
-- occurrence spans the fold DROPS live only here, so — like sites/named —
-- these are representation-stable, served off the wide `_idx()` handle
-- (identical on both backends), and are the home for every reader that
-- needs an edge's write-axis / guard / field facts / call-site ranges
-- rather than just its endpoint ([[cartograph-slice-api]] Tier-2).

--- Forward use records: the var reads/writes MADE BY `id` ({to, at, rw, …}).
function Band:var_uses_detail(id)
    local idx = self:_idx()
    return (idx and idx.var_uses[id]) or {}
end

--- Backward use records: the readers/writers OF var `id` ({from, at, rw, …}).
function Band:var_used_by_detail(id)
    local idx = self:_idx()
    return (idx and idx.var_usedby[id]) or {}
end

--- Reg records: the registrations that keep `id` alive ({from, at}) — who
--- registers it, with the site spans (the alibi with its evidence).
function Band:registrants_detail(id)
    local idx = self:_idx()
    return (idx and idx.reg_by[id]) or {}
end

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
function StoreBand:_idx() return self.store end
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
local RW_NAME = { 'read', 'write', 'both' }
local function vurec(store, from, to)
    local vu = store.var_uses and store.var_uses[from]
    if not vu then return nil end
    for i = 1, #vu do
        if vu[i].to == to then return vu[i] end
    end
end
function StoreBand:_rw(from, to)
    local u = vurec(self.store, from, to)
    return u and RW_NAME[u.rw] or nil
end
function StoreBand:_gw(from, to)
    local u = vurec(self.store, from, to)
    return u and u.gw or nil
end
function StoreBand:_gp(from, to)
    local u = vurec(self.store, from, to)
    return u and u.gp or nil
end
function StoreBand:_flds(from, to)
    local u = vurec(self.store, from, to)
    return u and u.flds or nil
end

function M.from_store(store)
    return setmetatable({ store = store }, StoreBand)
end

-- ── fold backend: the folded triple table's slices ───────────────────────
local FoldBand = setmetatable({}, { __index = Band })
FoldBand.__index = FoldBand

-- the fold folds TOPOLOGY only; identity/detail (name/file/site) come from
-- the wide index handle store.topo() passes alongside it (representation-
-- stable — the fold never folded these). nil for a bare parity-test fold.
function FoldBand:_idx() return self.idx end

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
function FoldBand:_rw(from, to)
    local f = self.fold
    local s, o = f.it.get(from), f.it.get(to)
    if not s or not o then return nil end
    return f:rw(s, o)
end
function FoldBand:_gw(from, to)
    local f = self.fold
    local s, o = f.it.get(from), f.it.get(to)
    if not s or not o then return nil end
    return f:gw(s, o)
end
function FoldBand:_gp(from, to)
    local f = self.fold
    local s, o = f.it.get(from), f.it.get(to)
    if not s or not o then return nil end
    return f:gp(s, o)
end
function FoldBand:_flds(from, to)
    local f = self.fold
    local s, o = f.it.get(from), f.it.get(to)
    if not s or not o then return nil end
    return f:flds(s, o)
end

--- `idx` (optional) = the wide identity/detail handle (the store) the
--- resident topology view carries for the name/file/site axes; omit for a
--- pure-topology fold Band (the parity tests).
function M.from_fold(fold, idx)
    fold_mod = fold_mod or require 'cartograph.fold'
    return setmetatable({ fold = fold, idx = idx }, FoldBand)
end

return M
