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
-- against the tree step k produced, and until step k is APPLIED that tree does
-- not exist -- `apply` is what splices it into the graph. `txn.dryrun`'s
-- `opts.before` makes a step's TEXT effect previewable against supplied content,
-- but the next step needs NODES: ranges, names, call edges. So a dry run previews
-- what it can derive and reports the rest as `underivable`, naming the step it
-- waits on. Reporting them as "no change" would be an absence rendered as a
-- plausible positive.

local M = {}

--- the verbs a recipe may name. ⚠ A TABLE, so adding one is an entry rather than
--- a branch -- and an unknown verb is a refusal, never a skipped step.
M.VERBS = {
    moveset = {
        --- @return table|nil plan, string|nil why
        plan = function (store, args)
            local ids = {}
            for i, ref in ipairs(args.seed_refs or {}) do
                local id, why = store.resolve_ref(ref)
                if not id then
                    return nil, ('seed_refs[%d] (%s in %s) does not resolve: %s')
                        :format(i, tostring(ref.name), tostring(ref.file), tostring(why))
                end
                ids[#ids + 1] = id
            end
            if #ids == 0 then return nil, 'no seed_refs resolved' end
            return require('cartograph.moveapply').plan_moveset(store, ids, args.dest,
                { arm = false, reexport = args.reexport })
        end,
        arm = function (store, plan) return require('cartograph.moveapply').arm(store, plan) end,
        -- ★ THE GENERIC DRIVER (CART-0982). `plan` and `arm` stay per-verb — planning
        -- IS the verb, and `arm` runs at plan time — but APPLY is no longer something
        -- a recipe step has to know how to do. A verb added here declares no apply.
        apply = function (store, plan) return require('cartograph.txn').apply(store, plan) end,
    },
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
function M.run(store, recipe, opts)
    opts = opts or {}
    local schema = require 'cartograph.schema'
    local hz = require 'cartograph.hazard'
    local txn = require 'cartograph.txn'

    local steps = recipe
    if type(recipe) == 'table' and recipe.steps ~= nil then
        local okv, vwhy = schema.replayable('recipe', recipe.version)
        if not okv then return nil, vwhy end
        steps = recipe.steps
    end
    if type(steps) ~= 'table' or #steps == 0 then return nil, 'an empty recipe' end

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
            local plan, why = spec.plan(store, st.args or {})
            if not plan then
                rows[#rows + 1] = step_error(i, verb, why)
                derailed = true
            else
                local before, after, dwhy = txn.dryrun(store, plan)
                if not before then
                    rows[#rows + 1] = step_error(i, verb,
                        ('the plan could not be previewed: %s'):format(tostring(dwhy)))
                    derailed = true
                else
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
                        local aok, awhy = spec.arm(store, plan)
                        local entry
                        if aok then entry, awhy = spec.apply(store, plan) end
                        if not entry then
                            row.ok, row.why = false, tostring(awhy)
                            derailed = true
                        else
                            row.applied, row.journal = true, entry.id or entry
                            applied[#applied + 1] = row.journal
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
                        -- not applying: everything after this is underivable,
                        -- and saying which step it waits on is the useful half
                        for j = i + 1, #steps do
                            rows[#rows + 1] = { i = j, verb = steps[j].verb,
                                ok = false, underivable = true,
                                why = ('cannot be derived until step %d is applied'
                                    .. ' — its inputs do not exist yet'):format(i) }
                        end
                        rows[#rows + 1] = row
                        table.sort(rows, function (a, b) return a.i < b.i end)
                        return rows
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
    if derailed and #applied > 0 and opts.rollback ~= false then
        local journal = require 'cartograph.journal'
        local root = store.data.root
        local undone, failed = 0, nil
        for _ = 1, #applied do
            local ok, why = journal.rollback(root)
            if ok then undone = undone + 1 else failed = why; break end
        end
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
