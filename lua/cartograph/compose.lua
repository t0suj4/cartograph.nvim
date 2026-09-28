-- cartograph.compose — RUN A LADDER OF VERB INVOCATIONS, PREVIEWING AS IT GOES.
--
-- USER (CART-0920): "this looks like this needs an interactive composition of
-- tool invocations, with a preview that might not entirely reflect a file state
-- but an intermediary effect".
--
-- ★★★ A RECIPE HOLDS INVOCATIONS, NOT PLANS, AND THAT IS THE WHOLE DESIGN.
-- Applying a plan BUMPS THE GRAPH GENERATION; every id in a plan held across that
-- apply may then name a different symbol, and measured on a two-step fixture the
-- held plan's node stopped resolving altogether. `moveapply.arm` refuses such a
-- plan by generation, which is the right answer and also the end of the idea that
-- a composition could be a list of plans. AN INVOCATION SURVIVES A GENERATION
-- BUMP; A PLAN DOES NOT.
--
-- ★★★ SO A STEP ADDRESSES SYMBOLS BY DURABLE REF, NEVER BY NODE ID, and passing
-- an id is REFUSED BY NAME rather than accepted and broken one step later. Ids
-- are session handles that die at the next edit; `refs` exists precisely because
-- a durable identity was needed for things that outlive a splice.
--
-- ⚠⚠ AND THE DRY RUN CAN ONLY SEE AS FAR AS IT CAN DERIVE. Step k+1 is planned
-- against the tree step k produced. The next step needs NODES (ranges, names,
-- call edges), not only text, so this used to stop at step 1 and report the rest
-- as `underivable`. ★ Now step k's staged texts become an OVERLAY WORLD
-- (world.edit, CART-1160 step 3) — a graph derived from them, never written — and
-- step k+1 plans in it. Only a JOURNALED step chains (tactic.next_world); after
-- any other, the rest is still `underivable`, naming the step it waits on and why.
-- Reporting them as "no change" would be an absence rendered as a plausible positive.

local M = {}

--- the verbs a recipe may name. ⚠ A TABLE, so adding one is an entry rather than
--- a branch -- and an unknown verb is a refusal, never a skipped step.
M.VERBS = {
    moveset = {
        --- @return table|nil plan, string|nil why
        plan = function (store, args)
            -- ★ THE GOAL CHECK (CART-1152): every seed already living at `dest` — the same name, the same body witness,
            -- resolving there WITHOUT a caveat — is the move DONE, so a re-run is `empty`, not a refusal. MEASURED:
            -- re-running a move refused as stale (its seed ref now pointed at a caveated neighbour).
            local seeds, home = args.seed_refs or {}, 0
            for _, ref in ipairs(seeds) do
                local id, note = store.resolve_ref({ file = args.dest, name = ref.name, kind = ref.kind, witness = ref.witness })
                if id and not note then home = home + 1 end
            end
            if #seeds > 0 and home == #seeds then
                return nil, ('all %d seed(s) already live in %s'):format(#seeds, tostring(args.dest)), 'empty'
            end
            local ids = {}
            for i, ref in ipairs(seeds) do
                local id, why = store.resolve_ref(ref)
                if not id then
                    return nil, ('seed_refs[%d] (%s in %s) does not resolve: %s')
                        :format(i, tostring(ref.name), tostring(ref.file), tostring(why)), 'stale'
                end
                -- ⚠ A CAVEAT REFUSES ON THE WRITE SIDE (the agent's resolve_write_ref rule). MEASURED: after a move, the
                -- SAME ref to M.dbl resolved to M.keep ("renamed? now 'M.keep'"), and a replayed recipe MOVED M.keep —
                -- txn.verify cannot catch it, the plan is M.keep's own
                if why then
                    return nil, ('seed_refs[%d] (%s in %s) resolved only WITH A CAVEAT — %s — and a write is not planned on a merely probable handle')
                        :format(i, tostring(ref.name), tostring(ref.file), tostring(why)), 'stale'
                end
                ids[#ids + 1] = id
            end
            if #ids == 0 then return nil, 'no seed_refs resolved', 'ill-posed' end
            return require('cartograph.moveapply').plan_moveset(store, ids, args.dest,
                { arm = false, reexport = args.reexport })
        end,
        arm = function (store, plan) return require('cartograph.moveapply').arm(store, plan) end,
        -- ★ THE GENERIC DRIVER (CART-0982). `plan` and `arm` stay per-verb — planning
        -- IS the verb, and `arm` runs at plan time — but APPLY is no longer something
        -- a recipe step has to know how to do. A verb added here declares no apply.
        apply = function (store, plan, o) return require('cartograph.txn').apply(store, plan, o) end,
        -- ★ WHAT A TACTIC MAY ASSUME (tactic.lua): the write is journaled (undoable), and re-running the SAME
        -- invocation after it applied is `empty` (the goal check above) — measured by tactic_spec's idempotence fence
        effect = 'journaled', rerun = 'empty',
        -- the arguments a did-you-mean may correct, and their kind (cartograph.correct)
        correct = { seed_refs = 'refs' },
        -- ★ PROVENANCE: what this invocation, once it has applied (or its goal check found it done), makes TRUE: each
        -- seed now lives at `dest` under its own name. The tactic runner records it, and a later step's stale ref to a
        -- seed's OLD address is corrected by it with CERTAINTY, not by inference (CART-1152).
        provides = function (args)
            local out = {}
            for _, ref in ipairs(args.seed_refs or {}) do
                if type(ref) == 'table' and ref.file and ref.name and args.dest then
                    out[#out + 1] = { from = { file = ref.file, name = ref.name }, to = { file = args.dest, name = ref.name } }
                end
            end
            return out
        end,
    },
}

--- a step's `ref` (durable) -> a node id, or nil, why, class
local function one_ref(store, args)
    if args.seed ~= nil or args.node ~= nil then
        return nil, 'a step addresses its symbol by `ref` (durable), never by a session id: an id dies at the first apply', 'ill-posed'
    end
    if type(args.ref) ~= 'table' then return nil, 'the step names no `ref`', 'ill-posed' end
    local id, why = store.resolve_ref(args.ref)
    if not id then
        return nil, ('ref %s in %s does not resolve: %s'):format(tostring(args.ref.name), tostring(args.ref.file),
            tostring(why)), 'stale'
    end
    -- ⚠ and a caveat refuses (the moveset adapter's note above; the agent's resolve_write_ref rule)
    if why then
        return nil, ('ref %s in %s resolved only WITH A CAVEAT — %s — and a write is not planned on a merely probable handle')
            :format(tostring(args.ref.name), tostring(args.ref.file), tostring(why)), 'stale'
    end
    return id
end

-- the single-subject verbs, addressed by ONE durable `ref` (tactics compose these; a recipe may too)
M.VERBS.replace = {
    plan = function (store, args)
        local id, why, class = one_ref(store, args)
        if not id then return nil, why, class or 'ill-posed' end
        return require('cartograph.replace').plan(store, { node = id, text = args.text })
    end,
    apply = function (store, plan, o) return require('cartograph.txn').apply(store, plan, o) end,
    effect = 'journaled', rerun = 'empty',
    correct = { ref = 'ref' },
}
M.VERBS.annotate = {
    plan = function (store, args)
        local id, why, class = one_ref(store, args)
        if not id then return nil, why, class or 'ill-posed' end
        return require('cartograph.annotate').plan(store, { node = id, text = args.text })
    end,
    apply = function (store, plan, o) return require('cartograph.txn').apply(store, plan, o) end,
    effect = 'journaled', rerun = 'empty',
    correct = { ref = 'ref' },
}
M.VERBS.clonemerge = {
    plan = function (store, args)
        local id, why, class = one_ref(store, args)
        if not id then return nil, why, class or 'ill-posed' end
        return require('cartograph.clonemerge').plan(store, id)
    end,
    apply = function (store, plan, o) return require('cartograph.txn').apply(store, plan, o) end,
    effect = 'journaled', rerun = 'empty',
    correct = { ref = 'ref' },
}

-- an edit on ONE clone carried to its family (cartograph.propagate). ★ RE-RUN IS EMPTY: once the origin holds the
-- edit it classifies as `none` — which is also why the SCOPE must be decided before the first write
M.VERBS.propagate = {
    plan = function (store, args)
        local id, why, class = one_ref(store, args)
        if not id then return nil, why, class or 'ill-posed' end
        return require('cartograph.propagate').plan(store, { node = id, text = args.text, scope = args.scope })
    end,
    apply = function (store, plan, o) return require('cartograph.txn').apply(store, plan, o) end,
    effect = 'journaled', rerun = 'empty',
    correct = { ref = 'ref' },
}

-- a rewrite rule LEARNED from one example (cartograph.byexample), applied wherever it matches. ★ RE-RUN IS EMPTY: a
-- learned rule never matches its own output (learn refuses one that does), so once applied nothing matches
M.VERBS['rewrite-by-example'] = {
    plan = function (store, args) return require('cartograph.byexample').plan(store, args) end,
    apply = function (store, plan, o) return require('cartograph.txn').apply(store, plan, o) end,
    effect = 'journaled', rerun = 'empty',
}

-- the toolbelt's own growth, as verbs: LEARN a tactic into the project (a journaled create, planned only once the
-- rendered entry passes its own examples) and PROMOTE one into the built-in toolbelt (always a `promote` decision).
-- ★ RE-RUN IS EMPTY for both: an identical file is the goal met.
-- ★ THE GROUND EDIT (CART-1182): supplied text at one site, exact-once anchored, idempotent by classifying the
-- current state against both images (cartograph.edit). The floor every other write rests on.
M.VERBS.edit = {
    plan = function (store, args) return require('cartograph.edit').plan(store, args) end,
    apply = function (store, plan, o) return require('cartograph.txn').apply(store, plan, o) end,
    effect = 'journaled', rerun = 'empty',
}
-- ★ RENAME A RECORD FIELD (CART-1175): reads by the base's spelling, keys in the define files, an occupied target a
-- DECISION (the occupant goes to a placeholder), text mentions a counted frontier (cartograph.renamefield)
M.VERBS['rename-field'] = {
    plan = function (store, args) return require('cartograph.renamefield').plan(store, args) end,
    apply = function (store, plan, o) return require('cartograph.txn').apply(store, plan, o) end,
    effect = 'journaled', rerun = 'empty',
}
M.VERBS['learn-tactic'] = {
    plan = function (store, args) return require('cartograph.toolbelt').plan_learn(store, args) end,
    apply = function (store, plan, o) return require('cartograph.txn').apply(store, plan, o) end,
    effect = 'journaled', rerun = 'empty',
}
M.VERBS['promote-tactic'] = {
    plan = function (store, args) return require('cartograph.toolbelt').plan_promote(store, args) end,
    apply = function (store, plan, o) return require('cartograph.txn').apply(store, plan, o) end,
    effect = 'journaled', rerun = 'empty',
}

local function step_error(i, verb, why)
    return { i = i, verb = verb, ok = false, why = why }
end

--- Run a recipe. Writes only when `opts.apply` is true.
---
--- @param store table
--- @param recipe table { version, steps = { { verb, args } } } or a bare step list
--- @param opts table|nil { apply = false, rollback = true }
--- @return table|nil rows, string|nil why
local run_recipe

function M.run(store, recipe, opts)
    opts = opts or {}
    if opts.apply then return run_recipe(store, recipe, opts) end
    -- a dry run may stack overlay worlds: the caller's graph comes back afterwards, raise or not
    local rec = store.capture()
    local res = { pcall(run_recipe, store, recipe, opts) }
    store.restore(rec)
    if not res[1] then error(res[2], 0) end
    return unpack(res, 2, table.maxn(res))
end

function run_recipe(store, recipe, opts)
    local schema = require 'cartograph.schema'
    local hz = require 'cartograph.hazard'

    local steps = recipe
    if type(recipe) == 'table' and recipe.steps ~= nil then
        local okv, vwhy, vwhy_class = schema.replayable('recipe', recipe.version)
        if not okv then return nil, vwhy, vwhy_class or 'stale' end
        steps = recipe.steps
    end
    if type(steps) ~= 'table' or #steps == 0 then return nil, 'an empty recipe', 'ill-posed' end

    local rows, applied, derailed = {}, {}, false
    for i, st in ipairs(steps) do
        local verb = type(st) == 'table' and st.verb or nil
        local spec = verb and M.VERBS[verb]
        if derailed then
            -- ★ EVERY REMAINING STEP IS REPORTED, NOT DROPPED. A recipe that stops
            -- at step 2 and returns two rows reads as a two-step recipe.
            rows[#rows + 1] = { i = i, verb = verb, ok = false, skipped = true,
                why = 'an earlier step did not complete' }
        elseif not spec then
            rows[#rows + 1] = step_error(i, verb,
                ('no such verb `%s` — the recipe names one this cartograph does'
                .. ' not run'):format(tostring(verb)))
            derailed = true
        elseif (st.args or {}).seed ~= nil then
            -- ⚠ THE ID REFUSAL, BY NAME. An id would work for step 1 and name a
            -- different symbol by step 2, which is the failure this design exists
            -- to prevent -- so it is refused at the door rather than at the edit.
            rows[#rows + 1] = step_error(i, verb,
                'a recipe step addresses symbols by `seed_refs` (durable), never'
                .. ' by `seed` (session ids): an id dies at the first apply')
            derailed = true
        else
            -- ★ ONE STEP EXECUTOR (tactic.step): plan -> stage -> arm -> apply, shared with the tactic runner so the two
            -- cannot drift. A recipe keeps its own reading: an EMPTY step derails it, as a refusal always did.
            local r = require('cartograph.tactic').step(store, st, { verbs = M.VERBS, apply = opts.apply })
            local plan, staged = r.plan, r.staged
            -- an arm or apply failure keeps the full row (plan, before/after): the preview was taken, the write refused
            if not r.ok and r.phase ~= 'apply' and r.phase ~= 'arm' or r.empty then
                local why = r.why
                if r.phase == 'stage' then why = ('the plan could not be previewed: %s'):format(tostring(why)) end
                local row = step_error(i, verb, why)
                row.class = r.class
                rows[#rows + 1] = row
                derailed = true
            else
                local before, after = staged.before, staged.after
                do
                    -- ★ THE RECEIPT RIDES WITH EVERY STEP, INCLUDING THE SMOOTH
                    -- ONES (CART-0912). A step with no hazards used to report
                    -- nothing at all, which is the same rendering as a step
                    -- nobody could analyse. `unwarranted` is the review question
                    -- in one field: a clean step is not "no rows", it is every
                    -- row `did` or `none`.
                    local rcm = require 'cartograph.receipt'
                    local row = { i = i, verb = verb, ok = true, plan = plan,
                        before = before, after = after,
                        hazards = plan.hazards, fixes = hz.fixes(plan),
                        receipt = plan.receipt,
                        unwarranted = plan.receipt and rcm.unwarranted(plan.receipt) or nil }
                    if opts.apply then
                        local entry = r.entry
                        if not entry then
                            row.ok, row.why, row.class = false, tostring(r.why), r.class
                            derailed = true
                        else
                            row.applied, row.journal = true, entry.id or entry
                            applied[#applied + 1] = entry
                            -- ★★★ AND NOTHING RE-INGESTS HERE, WHICH I GOT WRONG
                            -- FIRST. I built a `reingest` hook and wrote that the
                            -- next step's refs would otherwise resolve against a
                            -- tree that no longer exists. MEASURED: `apply`
                            -- SPLICES ITS RESULT INTO THE GRAPH — generation 1→2,
                            -- `by_file['sub/f.lua']` appears, and a ref to the
                            -- symbol's NEW HOME resolves immediately. The hook was
                            -- dead weight with a false justification, and dropping
                            -- it changed no test.
                            -- ⇒ THIS IS WHY A RECIPE OF INVOCATIONS WORKS AT ALL:
                            --   the write path keeps the graph current, so step
                            --   k+1 re-derives against what step k actually did.
                        end
                    else
                        -- ★ not applying: the next step plans against the OVERLAY world this one would produce
                        -- (CART-1160 step 3; tactic.next_world, the runner's own rule). M.run brings the caller's
                        -- graph back afterwards.
                        local over, wwhy = require('cartograph.tactic').next_world(store, spec.effect, r)
                        if over then
                            store.ingest(over)
                            row.world = i
                        else
                            -- no world: everything after this is underivable, and saying which step it waits on
                            -- is the useful half
                            for j = i + 1, #steps do
                                rows[#rows + 1] = { i = j, verb = steps[j].verb,
                                    ok = false, underivable = true,
                                    why = ('cannot be derived until step %d is applied'
                                        .. ' — its inputs do not exist yet (%s)'):format(i, tostring(wwhy)) }
                            end
                            rows[#rows + 1] = row
                            table.sort(rows, function (a, b) return a.i < b.i end)
                            return rows
                        end
                    end
                    rows[#rows + 1] = row
                end
            end
        end
    end

    -- ★ ROLLBACK IS ALL-OR-NOTHING AND NEWEST-FIRST. A composition that half-lands
    -- is worse than one that refuses: the tree is then in a state no step
    -- described. `rollback` restores BYTES from the journal, which is why it works
    -- across a generation bump when nothing else does.
    -- (tactic.rollback: identity-checked per entry, and the graph is RE-READ after each undo — this loop used to
    -- restore bytes and leave the graph describing the undone tree)
    if derailed and #applied > 0 and opts.rollback ~= false then
        local undone, failed = require('cartograph.tactic').rollback(store, applied)
        rows.rolled_back = undone
        rows.rollback_failed = failed
    end
    return rows
end

--- stamp a step list as a RECIPE, the serializable form `run` accepts back
--- @return table recipe { version, steps }
function M.recipe(steps)
    return require('cartograph.schema').stamp('recipe', { steps = steps })
end

return M
