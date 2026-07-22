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

-- resolve a cross-band reference `key` (a call's full/callee) to a def id, using ONLY
-- the const-selected target bands' indexes. `clang` = the ref's language (a name never
-- crosses languages). Returns (id, 'const') on a unique fit, else (nil, why):
-- 'no-const' (not constant-qualified — a bare/frontier ref), 'ambiguous' (>1 fit
-- across the linked bands), 'miss' (const known but no matching def there — the
-- ancestor case or a genuine frontier).
function M.resolve_ref(key, const_index, idx, clang, lang_of)
    local owner = ports.owner_of(key)
    local cand = owner and const_index[owner]
    if not cand then return nil, 'no-const' end
    -- EXACT owner-qualified match only. NO tail (bare-method) fallback: the linkage
    -- knows the owner constant, so `Owner#m` must match Owner's OWN `m`. A tail match
    -- would grab a same-band SIBLING class's m (the WRONG cases the gate caught:
    -- StaleRequestException::setShard → a sibling setShard). An exact miss = the
    -- method is INHERITED (defined on a parent) → MISS here, recovered by the
    -- ancestor hop (follow data.ruby_anc / extends to the parent's band), never guessed.
    local fit, dup = nil, false
    for b in pairs(cand) do
        local index = idx[b]
        for _, nd in ipairs(index and index.exact[key] or {}) do
            if (nd.kind == 'function' or nd.kind == 'method') and lang_of(nd.file) == clang then
                if fit and fit.id ~= nd.id then dup = true else fit = nd end
            end
        end
    end
    if dup then return nil, 'ambiguous' end
    if fit then return fit.id, 'const' end
    return nil, 'miss'
end

return M
