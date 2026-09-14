-- A PART OF `cartograph.algebra.core`, which requires this file at its end and
-- passes its own module table in. ⚠ IT DOES NOT `require` CORE BACK: that is a
-- load cycle — Lua says "loop or previous error loading module".
-- ★ 1 shared file-local(s), each (a) a core module-level local, (b) used
-- here and (c) not defined here — the three conditions, not a guess.
return function (M, SHARED)
-- ⚠ ONLY `hash` WAS DISCLOSED; the other three were found by hand (CART-0926).
-- The reads that matter here live inside `local function reader(V)` -> `return
-- function (spec)` — a closure nested TWO deep — and MEASURED, the analysis does
-- not reach it: a depth-1 nested local function is its own node and IS read, but
-- an anonymous closure RETURNED from one is not minted as a node at all, so
-- nothing reads its body. Every capture rung is blind below that line.
local at, hash, is_hole, key, subst =
    SHARED.at, SHARED.hash, SHARED.is_hole, SHARED.key, SHARED.subst

-- ── demand over a family: an analyzer reads members THROUGH the template ────────────────
--- A read of a fixed site is keyed by the template's fixed subterm at that path (its
--- content, not its position), a read of a hole by the member's value for it. So a value
--- edit invalidates only readers of that hole, a rewrite only readers whose fixed subterm
--- changed, and the edit-log stamp (TENSIONS.md) is the coarse key this refines. The
--- analyzer receives `read(spec)` with spec = { path = {..} } or { hole = 'h' }.
--- Constructive traces, several per analyzer: a member whose demanded reads verify against
--- a recorded trace gets that result without a run. Members with equal demanded
--- projections therefore share one run: the store law priced a second time.
function M.family_analyze(T, Vs, analyzer, cache, env)
    cache = cache or { traces = {} }
    local results, runs, reused = {}, {}, {}
    local function reader(V)
        return function(spec)
            if spec.hole then
                local v = V[spec.hole]
                if v == nil then error('no value for hole ' .. spec.hole) end
                return v, 'hole:' .. spec.hole
            end
            local sub = at(T.body, spec.path)
            if sub == nil then error('no subterm at ' .. key(spec.path)) end
            if is_hole(sub) then return V[sub.h], 'hole:' .. sub.h end
            -- a fixed subterm may still contain holes below: render it for this member
            local unfilled = {}
            local rendered = subst(sub, V, unfilled)
            return rendered, 'fixed:' .. key(spec.path)
        end
    end
    for i, V in ipairs(Vs) do
        local read = reader(V)
        local hit
        for _, t in ipairs(cache.traces) do
            local ok = true
            for _, d in ipairs(t.deps) do
                local v = read(d.spec)
                if hash(v) ~= d.hash then ok = false; break end
            end
            if ok then hit = t; break end
        end
        if hit then
            results[i] = hit.result; reused[#reused + 1] = i
        else
            local deps = {}
            local r = analyzer(function(spec)
                local v, k = read(spec)
                deps[#deps + 1] = { spec = spec, k = k, hash = hash(v) }
                return v
            end)
            cache.traces[#cache.traces + 1] = { deps = deps, result = r }
            results[i] = r; runs[#runs + 1] = i
        end
    end
    return { results = results, runs = runs, reused = reused, cache = cache }
end
end
