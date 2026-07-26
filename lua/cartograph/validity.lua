-- WHEN MAY A DERIVED VALUE BE REUSED. One place for a discipline this codebase
-- was writing by hand nine times, with five of those instances simply wrong.
--
-- THE SHAPE, everywhere it occurs: (derived value, inputs, validity key) -> reuse
-- or recompute. Found in the wild before this existed:
--
--   KEYED BY A CONTENT STAMP, correct
--     store.content            lines        <- file stamp
--     store.frontier_text      text+hash    <- file stamp
--     transport zip            central dir  <- archive stamp
--     cache.lua                whole graph  <- file stamps + VERSION + artifacts
--   KEYED BY THE GRAPH GENERATION, correct
--     store._topo_gen, store._post_gen, effects._fxgen
--   KEYED BY NOTHING — stale forever within a session
--     spec/profile   load cache       (ignored the stamp it PUBLISHES to others)
--     spec/ecosystem load cache       (same code, same bug)
--     spec/lua       FMODS / TOC_DIR / NLROOT   (per-root, never invalidated)
--
-- The last group is why this module exists rather than a style note. Two measured
-- consequences: editing a profile artifact mid-session returned the OLD table
-- while cache.lua recorded the NEW stamp in its manifest — so a warm graph claimed
-- a profile that extraction never used; and adding a package to a mods dir left
-- the identity map stale for the rest of the session.
--
-- TWO KEY SOURCES, because derivations genuinely differ:
--
--   STAMP  the value comes from ONE identifiable input whose validity key is
--          cheap (a file). Recompute when the stamp moves. Use this whenever a
--          stamp is available: it is precise, and it survives across epochs.
--   EPOCH  a named counter, bumped by whoever knows the inputs changed. For a
--          derivation whose inputs are a whole TREE, where a key would cost as
--          much as recomputing (FMODS must stat every candidate manifest to know
--          if it is stale — which is what computing it does).
--
-- Deliberately NOT a dependency graph. Inputs are not tracked transitively and
-- nothing is recomputed automatically; this decides reuse at a call site and
-- nothing more. The moment it wants to schedule work it has become a build
-- system, and that is a different design with a different justification.
--
-- Requires nothing from cartograph, so it can be used from any layer.

local M = {}

-- ── epochs ───────────────────────────────────────────────────────────────────
-- Named so unrelated lifetimes stay unrelated: 'extract' turns over per
-- extraction run, and a future 'session' or 'band' need not disturb it. An
-- unknown name reads as 0, so a memo declared before its first bump is valid.

local epochs = {}

--- The current value of a named epoch.
function M.epoch(name) return epochs[name] or 0 end

--- Advance a named epoch: every memo keyed on it recomputes on next use. Cheap —
--- it invalidates lazily rather than clearing tables, so bumping costs nothing
--- when nobody asks afterwards.
function M.bump(name)
    epochs[name] = (epochs[name] or 0) + 1
    return epochs[name]
end

-- ── memos ────────────────────────────────────────────────────────────────────

--- Build a memo. `opts`:
---   name     for diagnostics only
---   epoch    a name — key on that epoch's current value
---   stamp    function(key, ...) -> string|nil — key on the input's own stamp
---   compute  function(key, ...) -> value
--- Exactly one of `epoch` / `stamp` is required: a memo with neither is the bug
--- this module exists to remove, so it is refused rather than allowed to default.
---
--- The returned function is `f(key, ...)`. `key` selects the cache slot (a root, a
--- runtime name, a path); extra arguments pass through to stamp/compute and take
--- no part in the key — a caller that varies them per call is asking two
--- questions and wants two memos.
---
--- A nil STAMP means "cannot determine validity", and is deliberately NOT cached:
--- caching under an unknown key is how a stale value outlives its input.
function M.memo(opts)
    assert(type(opts) == 'table' and opts.compute, 'validity.memo: needs compute')
    assert((opts.epoch ~= nil) ~= (opts.stamp ~= nil),
        'validity.memo: exactly one of epoch / stamp (' .. tostring(opts.name) .. ')')
    local slots = {}
    local function f(key, ...)
        local k = key == nil and '\0nil' or key
        local ver
        if opts.epoch then
            ver = M.epoch(opts.epoch)
        else
            ver = opts.stamp(key, ...)
            if ver == nil then return opts.compute(key, ...) end
        end
        local s = slots[k]
        if s ~= nil and s.ver == ver then return s.v end
        local v = opts.compute(key, ...)
        slots[k] = { ver = ver, v = v }
        return v
    end
    return f
end

-- ── artifact contributors: what a cached GRAPH's validity must include ───────
-- The recurrence guard. A cached graph is only valid while every DECLARATIVE
-- ARTIFACT its resolution consulted is unchanged — profiles, package-ecosystem
-- specs, and whatever comes next. Composing that by hand in cache.lua is how one
-- input got missed: the ecosystem spec began shaping resolution while validity
-- still summed file stamps, VERSION and the profile, so editing a layout rule
-- left every warm cache confidently stale.
--
-- Now a contributor REGISTERS itself and cache.lua folds whatever is registered,
-- so a new artifact kind enters the key with no edit there. Contributors are
-- declared at load time by the module that owns the artifact — the same
-- in-file-declaration rule as transport.kinds and source.lua's providers.

local contributors = {}

--- Register a validity contributor. `fn()` returns a string (or nil to
--- contribute nothing — an absent artifact kind is not a mismatch).
function M.contribute(name, fn)
    assert(type(name) == 'string' and type(fn) == 'function',
        'validity.contribute: needs (name, fn)')
    contributors[name] = fn
end

--- The composed artifact key, or nil when nothing contributes. Sorted by name so
--- the string is stable across load orders — an unstable key would invalidate
--- every cache on every start, which is indistinguishable from having no cache.
function M.artifact_key()
    local names = {}
    for n in pairs(contributors) do names[#names + 1] = n end
    table.sort(names)
    local parts = {}
    for _, n in ipairs(names) do
        local ok, v = pcall(contributors[n])
        if ok and v ~= nil and v ~= '' then parts[#parts + 1] = n .. '=' .. tostring(v) end
    end
    return #parts > 0 and table.concat(parts, ';') or nil
end

--- The registered contributor names, for reporting and for a test that asserts
--- an artifact kind did not silently stop contributing.
function M.contributors()
    local names = {}
    for n in pairs(contributors) do names[#names + 1] = n end
    table.sort(names)
    return names
end

return M
