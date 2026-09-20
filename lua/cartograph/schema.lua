-- cartograph.schema — VERSIONS FOR ARTIFACTS THAT OUTLIVE THE PROCESS (CART-0922).
--
-- USER: "serialized plans need versioning."
--
-- ★★★ THE PROBLEM WAS NOT AN ABSENT VERSION, IT WAS A PRESENT ONE NOBODY READ.
-- `journal.begin` has written `version = 1` into every entry since it shipped and
-- nothing has ever consulted it — measured, zero readers. A field that LOOKS like
-- a guard and is never checked is the guarantee-outside-the-code shape in its
-- purest form: the next reader assumes entries are versioned BECAUSE THE FIELD IS
-- THERE. Meanwhile the real compatibility test in the tree is a presence probe --
-- `if not f.after then return nil, id .. ' predates redo support'` -- which works
-- for an ADDED field and cannot express a field whose MEANING changed, which is
-- the case a version number exists for.
--
-- ★★ ONE NUMBER PER ARTIFACT KIND, NOT ONE NUMBER. A shared counter bumps for
-- unrelated reasons and invalidates artifacts nothing changed for; that is the
-- argument against reusing `cache.VERSION` and it applies just as well between a
-- PLAN and a LADDER. Each kind carries its own reason log, on the cache's
-- convention: a number, and one line per bump saying what changed.
--
-- ⚠⚠ THE VERSION GATES EXECUTION, NEVER READING. Undo and redo restore BYTES --
-- `journal.redo` replays after-content, not a plan -- and they must keep working
-- for every entry ever written, including entries from before this file existed.
-- Refusing to READ an old entry would trade a real recovery path for a schema
-- opinion. What a version may refuse is REPLAY: executing a recorded artifact
-- under a meaning it was not recorded with.

local M = {}

--- THE PLAN: what a write verb hands to `apply`, and what the journal stores as
--- its description. Bumped when a field a replayer reads is ADDED, REMOVED, or
--- CHANGES MEANING.
M.PLAN = 3 -- v3: `plan.refspecs`, `plan.desc`, `plan.expect` and (where a verb is
           --     coupled to host state) `plan.precheck`/`plan.consume` — CART-0982.
           --     Together they are what `apply` used to do by hand, so that ONE
           --     driver runs any plan: `txn.apply`.
           --     `plan.refspecs` (CART-0982) — the resolutions a plan depends on,
           --     moved off each `apply` and onto the plan. IT GATES EXECUTION:
           --     `txn.verify` now REFUSES a plan that declares none, so a v2 plan
           --     does not merely verify less, it does not apply at all. That is the
           --     safe direction and exactly what a version is for — a recorded
           --     artifact must not execute under a meaning it was not recorded with.
           -- v2: `plan.reexports` (CART-0915) and `captures[].textual`
           --     (CART-0919), both added 2026-09-13 with no bump, because
           --     nothing could have checked one
           -- v1: moves/rewrites/imports_add/scaffold/hazards/stamps

--- THE LADDER: a list of RECORDED ALGEBRA OPS (`T.edits` entries), folded by
--- `clones.family_steps` through `A.replay_edit`. ★ THIS IS THE ONE THAT IS
--- EXECUTABLE: `replay_edit` dispatches on `op.op`, so a stale ladder does not
--- render oddly, it RUNS under a changed meaning. Versioned before the first one
--- is written rather than after.
M.LADDER = 1 -- v1: { version, ops = { {op='pin'|'open'|'dig'|'merge'|'split'|
           --     'rewrite'|'join', ...} } }, the vendored algebra's own log
           --     format at donor rev c07bdd40

--- THE RECIPE: a list of VERB INVOCATIONS a composition runs in order. ★ IT IS
--- NOT A LIST OF PLANS, and that distinction is the whole design: applying a plan
--- BUMPS THE GRAPH GENERATION, after which every id in a held plan may name a
--- different symbol — measured, the node stops resolving entirely. AN INVOCATION
--- SURVIVES A GENERATION BUMP; A PLAN DOES NOT. So a recipe records what to ask
--- for, and each step is re-derived against the graph as it then stands.
M.RECIPE = 1 -- v1: { version, steps = { { verb, args } } }, args addressing
           --     symbols by DURABLE REF and never by node id

local CURRENT = { plan = 'PLAN', ladder = 'LADDER', recipe = 'RECIPE' }

--- Is a recorded artifact safe to REPLAY here?
---
--- ⚠ THREE ANSWERS, AND THEY ARE NOT THE SAME REFUSAL. "No version" is an
--- artifact from before versioning and nothing can be inferred about it; "older"
--- means we would have to guess what it meant; "newer" means it was written by a
--- cartograph that knows something this one does not. Rendering them alike would
--- hide which of the three the operator can actually fix.
--- @param kind string 'plan' | 'ladder'
--- @param got number|nil the artifact's recorded version
--- @return boolean ok, string|nil why
function M.replayable(kind, got)
    local key = CURRENT[kind]
    if not key then return false, ('unknown artifact kind `%s`'):format(tostring(kind)) end
    local want = M[key]
    if got == nil then
        return false, ('this %s carries no schema version, so it predates'
            .. ' versioning and nothing can be inferred about its fields —'
            .. ' re-plan it against the current graph (current v%d)')
            :format(kind, want)
    end
    if type(got) ~= 'number' then
        return false, ('this %s\'s version is a %s, not a number')
            :format(kind, type(got))
    end
    if got > want then
        return false, ('this %s is v%d and this cartograph understands v%d —'
            .. ' it was written by a NEWER version; upgrade rather than replay')
            :format(kind, got, want)
    end
    if got < want then
        -- ★ NO SILENT MIGRATION. A migration that cannot be refused is a guess
        -- about what an old artifact meant, and the whole point of the version is
        -- that the guess is not available.
        return false, ('this %s is v%d and this cartograph writes v%d — no'
            .. ' migration exists, so replaying it would apply an old recording'
            .. ' under new meanings; re-plan it')
            :format(kind, got, want)
    end
    return true
end

--- stamp an artifact of `kind` — the one place a version is written, so a new
--- writer cannot forget the field
--- @return table artifact
function M.stamp(kind, t)
    local key = CURRENT[kind]
    if not key then error('unknown artifact kind ' .. tostring(kind), 2) end
    t = t or {}
    t.version = M[key]
    return t
end

return M
