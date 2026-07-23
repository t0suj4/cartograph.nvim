-- BANDLINK — the cross-band LINKAGE resolver (federation F1, [[cartograph-band-
-- federation]] / [[cartograph-merging-strategies]]). Resolves a band's free
-- references (the "needs" the port surface collects) against OTHER bands, WITHOUT a
-- whole-graph index: the constant->band map (ports.const_index) selects the target
-- band(s), and the def is found in THOSE bands' per-band indexes (build_index scoped
-- to a band). This is resolve_module_alias generalized — keyed on the qualifying
-- CONSTANT instead of an import alias — and the piece a per-band (F2) resolver calls
-- for the ~10-40% of references that leave a band.
--
-- FIRST CUT = the CONSTANT path (base-prov refs: Foo.m / Foo#m / Class::m). The
-- ANCESTOR path (ruby_ancestors: ref owner != def owner, chase data.ruby_anc to a
-- parent's band) is a declared follow-on — const-only MATCH ≈ the const-linkage
-- coverage (portgate), MISS = the ancestor+bare residual, WRONG must be ~0 (the
-- soundness invariant: linkage never picks a DIFFERENT target than whole-graph).

local ports = require 'cartograph.ports'

local M = {}

-- per-band resolution index: build_index (treesitter) scoped to each band's nodes.
-- band -> { exact, tail, ... }. No whole-graph index is ever built.
function M.indexes(data, band_of)
    local ts = require 'cartograph.providers.treesitter'
    local by = {}
    for _, n in ipairs(data.nodes or {}) do
        if n.file then
            local b = band_of(n.file)
            by[b] = by[b] or {}
            by[b][#by[b] + 1] = n
        end
    end
    local idx = {}
    for b, nodes in pairs(by) do idx[b] = ts.build_index(nodes) end
    return idx
end

-- the EXACT owner-qualified match against the const-selected bands — the shared core
-- of resolve_ref (const path) AND the ancestor chase (each parent hop). Returns
-- (nd, dup, has_const): nd = the unique fit node (nil if none), dup = >1 distinct fits
-- (ambiguous), has_const = the key was owner-qualified & the owner is a known constant.
-- NO tail (bare-method) fallback: the linkage knows the owner constant, so `Owner#m`
-- must match Owner's OWN `m`. A tail match would grab a same-band SIBLING class's m (the
-- WRONG cases the gate caught: StaleRequestException::setShard → a sibling setShard).
local function find_exact(key, const_index, idx, clang, lang_of)
    local owner = ports.owner_of(key)
    local cand = owner and const_index[owner]
    if not cand then return nil, false, false end
    local fit, dup = nil, false
    for b in pairs(cand) do
        local index = idx[b]
        for _, nd in ipairs(index and index.exact[key] or {}) do
            if (nd.kind == 'function' or nd.kind == 'method') and lang_of(nd.file) == clang then
                if fit and fit.id ~= nd.id then dup = true else fit = nd end
            end
        end
    end
    return fit, dup, true
end

-- resolve a cross-band reference `key` (a call's full/callee) to a def id, using ONLY
-- the const-selected target bands' indexes. `clang` = the ref's language (a name never
-- crosses languages). Returns (id, 'const') on a unique fit, else (nil, why):
-- 'no-const' (not constant-qualified — a bare/frontier ref), 'ambiguous' (>1 fit
-- across the linked bands), 'miss' (const known but no matching def there — the
-- INHERITED case or a genuine frontier). BEHAVIOR-FROZEN (bandlinkgate WRONG=0): the
-- const path never guesses. The ancestor hop is a SEPARATE, additive recovery over the
-- residual miss — see M.ancestry / M.resolve.
function M.resolve_ref(key, const_index, idx, clang, lang_of)
    local fit, dup, has = find_exact(key, const_index, idx, clang, lang_of)
    if not has then return nil, 'no-const' end
    if dup then return nil, 'ambiguous' end
    if fit then return fit.id, 'const' end
    return nil, 'miss'
end

-- build ANCESTOR adjacency (child const -> {parent consts}) by mode, from data.ruby_anc
-- (the {c, p, mode} edge list ruby_ancestors collects, file-deduped in the parallel
-- merge). Mirrors resolve_ruby_ancestors' adjacency EXACTLY so the cross-band hop and
-- the in-graph resolver agree on the chain: inst (instance chain — superclass +
-- include/prepend), sings (singleton via superclass, p.m), singe (extend module, p#m).
function M.ancestry(anc)
    local inst, sings, singe = {}, {}, {}
    local function add(map, k, v) map[k] = map[k] or {}; map[k][#map[k] + 1] = v end
    for _, e in ipairs(anc or {}) do
        if e.mode == 'inst' then add(inst, e.c, e.p)
        elseif e.mode == 'sings' then add(sings, e.c, e.p)
        elseif e.mode == 'singe' then add(singe, e.c, e.p) end
    end
    return { inst = inst, sings = sings, singe = singe }
end

local STEP_LIMIT = 32 -- mirrors treesitter's SUPER_STEP_LIMIT (chain depth guard)

-- nearest UNIQUE def of `member` up an adjacency chain from `start`, resolving each
-- parent's `parent .. sep .. member` through find_exact (const->band EXACT match — the
-- SAME soundness discipline as the const path). BFS (nearest ancestor first); >1
-- distinct fit at a frontier depth OR a within-band ambiguity → give up (honest, never
-- guess) — this is what keeps the hop WRONG=0. Returns the fit node or nil.
local function chase(start, member, adj, sep, const_index, idx, clang, lang_of)
    local seen, frontier = { [start] = true }, { start }
    for _ = 1, STEP_LIMIT do
        local nextf, hit = {}, nil
        for _, cur in ipairs(frontier) do
            for _, p in ipairs(adj[cur] or {}) do
                if not seen[p] then
                    seen[p] = true
                    nextf[#nextf + 1] = p
                    local nd, dup = find_exact(p .. sep .. member, const_index, idx, clang, lang_of)
                    if dup then return nil end
                    if nd then
                        if hit and hit.id ~= nd.id then return nil end
                        hit = nd
                    end
                end
            end
        end
        if hit then return hit end
        if #nextf == 0 then break end
        frontier = nextf
    end
    return nil
end

-- resolve a cross-band ref, const path FIRST then the ANCESTOR hop over the residual
-- miss. `ancestry` = M.ancestry(data.ruby_anc); pass nil to get pure const behavior.
-- Turns MISS (inherited/reopened: the method lives on a parent in ANOTHER band) into a
-- MATCH by chasing the owner's ancestors — instance calls up the inst chain (`#`),
-- singleton calls up the superclass singletons (`.`) then extend modules (`#`), exactly
-- as resolve_ruby_ancestors does in-graph. Returns (id, 'const'|'ancestor') or
-- (nil, why). Ruby-shaped owners only (single-segment capitalized const, `#`/`.` sep) —
-- the shape ruby_anc carries; anything else falls through to the const-path result.
function M.resolve(key, const_index, idx, ancestry, clang, lang_of)
    local id, why = M.resolve_ref(key, const_index, idx, clang, lang_of)
    if id or why ~= 'miss' or not ancestry then return id, why end
    local cls, csep, member = key:match('^(%u[%w_]*)([#.])([%w_?!=]+)$')
    if not cls then return id, why end
    local fit
    if csep == '#' then
        fit = chase(cls, member, ancestry.inst, '#', const_index, idx, clang, lang_of)
    else -- '.' : superclass singletons (p.m) then extend-modules (p#m)
        fit = chase(cls, member, ancestry.sings, '.', const_index, idx, clang, lang_of)
            or chase(cls, member, ancestry.singe, '#', const_index, idx, clang, lang_of)
    end
    if fit then return fit.id, 'ancestor' end
    return id, why
end

return M
