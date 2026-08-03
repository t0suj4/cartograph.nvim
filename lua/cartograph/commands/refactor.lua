-- :Cartograph command group — the staging verbs (|cartograph-cmd-refactor|)
--
-- Registered by cartograph.commands, which owns the shared helpers and passes
-- them in: this module rebinds them as locals under the SAME names, so every
-- callback body reads exactly as it did when they all lived in one function.

local M = {}

function M.register(H)
    local cmd, live, whole_graph, mat_df, scratch, txn_module, reveal_at =
        H.cmd, H.live, H.whole_graph, H.mat_df, H.scratch, H.txn_module,
        H.reveal_at
    -- not every group uses every helper; keep the binding uniform
    local _ = cmd and live and whole_graph and mat_df and scratch


    -- ── transactions ────────────────────────────────────────────────
    cmd('CartographMerge', function ()
        local st = live() if not st then return end
        if st.txn then
            return vim.notify('cartograph: a transaction is already staged'
                .. ' — :CartographApply or :CartographTxnClear first',
                vim.log.levels.WARN)
        end
        local txn, why = require('cartograph.clonemerge').plan(st, st.focused)
        if not txn then
            return vim.notify('cartograph: ' .. tostring(why), vim.log.levels.WARN)
        end
        st.set_txn(txn)
        vim.notify(('cartograph: merge staged — %d clone(s) into %s,'
            .. ' %d rewrite(s), %d hazard(s). Review the plan bar, then'
            .. ' :CartographApply'):format(#txn.removed, txn.survivor.name,
            #txn.rewrites, #txn.hazards), vim.log.levels.INFO)
    end, { desc = 'cartograph: merge the focused function\'s clones into it' })

    cmd('CartographMove', function ()
        local st = live() if not st then return end
        if st.txn then
            return vim.notify('cartograph: a transaction is already staged'
                .. ' — :CartographApply or :CartographTxnClear first',
                vim.log.levels.WARN)
        end
        local txn, why = require('cartograph.moveapply').plan(st)
        if not txn then
            return vim.notify('cartograph: ' .. tostring(why), vim.log.levels.WARN)
        end
        st.set_txn(txn)
        vim.notify(('cartograph: move staged — %d symbol(s) → %s,'
            .. ' %d hazard(s). Review the plan bar, then :CartographApply')
            :format(#txn.moves, txn.dest, #txn.hazards), vim.log.levels.INFO)
    end, { desc = 'cartograph: turn the staged move-set into a transaction' })

    cmd('CartographExtractModule', function (o)
        local st = live() if not st then return end
        if st.txn then
            return vim.notify('cartograph: a transaction is already staged'
                .. ' — :CartographApply or :CartographTxnClear first',
                vim.log.levels.WARN)
        end
        local txn, why = require('cartograph.moveapply').plan_extract(st, o.args)
        if not txn then
            return vim.notify('cartograph: ' .. tostring(why), vim.log.levels.WARN)
        end
        st.set_txn(txn)
        vim.notify(('cartograph: extract staged — %d symbol(s) → NEW %s,'
            .. ' %d hazard(s). Review the plan bar, then :CartographApply')
            :format(#txn.moves, txn.dest, #txn.hazards), vim.log.levels.INFO)
    end, { nargs = 1, complete = 'file',
        desc = 'cartograph: extract the staged move-set into a new file' })

    -- ── THE REPORT→STAGE LAST MILE (CART-0125) ────────────────────────
    -- Three report surfaces computed an extraction and dry-ran it; none could
    -- stage one, so the write half was reachable only by hand-building the
    -- move-set. One verb per listing, each turning the plan its report already
    -- printed into a reviewable transaction.

    -- untangle-MODULE's "extract-as-module candidates" → a staged move-set
    cmd('CartographExtractCluster', function (o)
        local st = live() if not st then return end
        st = whole_graph(st) if not st then return end
        if st.txn then
            return vim.notify('cartograph: a transaction is already staged'
                .. ' — :CartographApply or :CartographTxnClear first', vim.log.levels.WARN)
        end
        local un = require 'cartograph.untangle'
        local ea = require 'cartograph.extractapply'
        local which, dest = o.fargs[1], o.fargs[2]
        local c = which and ea.comp_of(which)
        if not (c and dest) then
            return vim.notify('cartograph: :CartographExtractCluster <letter> <dest.lua>'
                .. ' (the cluster letter :CartographUntangleModule lists)', vim.log.levels.WARN)
        end
        -- the SAME scope the report clustered: a directory arg, else the focused
        -- node's file. Re-derived rather than remembered, so a stale report
        -- cannot silently address the wrong cluster.
        local scope, label
        if o.fargs[3] then
            scope, label = un.files_under(st, o.fargs[3]), o.fargs[3]
            if #scope == 0 then
                return vim.notify('cartograph: no files under ' .. o.fargs[3], vim.log.levels.WARN)
            end
        else
            local n = st.focused and st.node(st.focused)
            if not (n and n.file) then
                return vim.notify('cartograph: focus a node in the file first'
                    .. ' (or pass the same dir you gave :CartographUntangleModule)',
                    vim.log.levels.WARN)
            end
            scope, label = { n.file }, n.file
        end
        local res = un.analyze_scope(st, scope)
        if c >= res.ncomp then
            return vim.notify(('cartograph: %s has %d cluster(s) — no %s')
                :format(label, res.ncomp, ea.letter(c)), vim.log.levels.WARN)
        end
        local plan, why = un.extract_module(st, res, c, dest)
        if not plan then
            return vim.notify('cartograph: cannot extract cluster '
                .. ea.letter(c) .. ' — ' .. tostring(why), vim.log.levels.WARN)
        end
        -- the cluster's SAFETY verdict is a separate question from the move
        -- mechanics moveapply just checked; an uncertified scope rides as a
        -- hazard rather than blocking, because the mechanics are still sound
        if not un.module_safe(res, c) then
            table.insert(plan.hazards, 1, ('cluster %s is ~ NOT certified — an unmodeled'
                .. ' coupling could connect it to another cluster'
                .. ' (:CartographUntangleModule names the blocking statements)')
                :format(ea.letter(c)))
        end
        st.set_txn(plan)
        vim.notify(('cartograph: extract-cluster %s staged — %d symbol(s) → NEW %s,'
            .. ' %d hazard(s). Review with :CartographDiff, then :CartographApply')
            :format(ea.letter(c), #plan.moves, plan.dest, #plan.hazards),
            vim.log.levels.INFO)
    end, { nargs = '*', complete = 'file',
        desc = 'cartograph: stage one CLUSTER of :CartographUntangleModule as its own new module — <letter> <dest.lua> [<dir>], the letter being the cluster the report lists (pass the same dir arg for a god-PACKAGE scope; omit it for the focused file). The god-object split, end to end: untangle picks the cluster, moveapply independently checks the move mechanics and reports load-order/cycle hazards. An uncertified cluster stages with the coupling disclosed, never silently. Review :CartographDiff, commit :CartographApply' })

    -- untangle's per-concern "extract candidates" → a staged helper extraction
    cmd('CartographExtractConcern', function (o)
        local store = live() if not store then return end
        store = whole_graph(store) if not store then return end
        if store.txn then
            return vim.notify('cartograph: a transaction is already staged'
                .. ' — :CartographApply or :CartographTxnClear first', vim.log.levels.WARN)
        end
        local id = store.focused
        local n = id and store.node(id)
        if not n or (n.kind ~= 'function' and n.kind ~= 'method') then
            return vim.notify('cartograph: focus a function first', vim.log.levels.WARN)
        end
        -- NO mat_df here, deliberately: plan_concern goes through
        -- untangle.effect_edges, which needs the whole-graph call fixpoint. On an
        -- index-only graph the effect edges would come back EMPTY and the concern
        -- count would read higher than the truth — an unsound "independent"
        -- claim. whole_graph above refuses that case outright, which is why this
        -- verb is guarded like :CartographUntangle and not like the df-local
        -- verbs ([[cartograph-thin-index]]).
        local ea = require 'cartograph.extractapply'
        if o.fargs[1] == nil then
            return vim.notify('cartograph: :CartographExtractConcern <letter> [<name>]'
                .. ' (the concern letter :CartographUntangle lists)', vim.log.levels.WARN)
        end
        local plan, why = ea.plan_concern(store, id, o.fargs[1], o.fargs[2])
        if not plan then
            return vim.notify('cartograph: cannot extract concern '
                .. tostring(o.fargs[1]) .. ' — ' .. tostring(why), vim.log.levels.WARN)
        end
        store.set_txn(plan)
        vim.notify(('cartograph: extract-concern staged — %s(%d param%s) out of %s,'
            .. ' %d hazard(s). Review with :CartographDiff, then :CartographApply')
            :format(plan.name, #plan.params, #plan.params == 1 and '' or 's',
            plan.fn, #plan.hazards), vim.log.levels.INFO)
    end, { nargs = '*',
        desc = 'cartograph: stage one CONCERN of :CartographUntangle as a new local helper — <letter> [<name>], the letter being the concern the report lists. untangle picks the boundary; extract.plan independently validates the mechanics (params from live-in, returns from live-out, scope-correct reaching), so an independent-but-unextractable concern is refused with the reason. A scattered concern refuses — reorder gathers it first. Review :CartographDiff, commit :CartographApply' })

    -- the SELECTION path, headless: the source pane's :CartographExtract without
    -- the cockpit (so the verb is agent-drivable, [[cartograph-apply-for-agent]])
    cmd('CartographExtractFn', function (o)
        local store = live() if not store then return end
        if store.txn then
            return vim.notify('cartograph: a transaction is already staged'
                .. ' — :CartographApply or :CartographTxnClear first', vim.log.levels.WARN)
        end
        local id = store.focused
        local n = id and store.node(id)
        if not n or (n.kind ~= 'function' and n.kind ~= 'method') then
            return vim.notify('cartograph: focus a function first', vim.log.levels.WARN)
        end
        mat_df(store, n.file)
        local first, last, name = tonumber(o.fargs[1]), tonumber(o.fargs[2]), o.fargs[3]
        if not (first and last and name) then
            return vim.notify('cartograph: :CartographExtractFn <first> <last> <name>'
                .. ' (FILE line numbers, whole top-level statements)', vim.log.levels.WARN)
        end
        local plan, why = require('cartograph.extractapply')
            .plan(store, id, { first = first, last = last }, name)
        if not plan then
            return vim.notify('cartograph: cannot extract — ' .. tostring(why),
                vim.log.levels.WARN)
        end
        store.set_txn(plan)
        vim.notify(('cartograph: extract staged — L%d-%d → %s(%d param%s) in %s.'
            .. ' Review with :CartographDiff, then :CartographApply'):format(
            first, last, name, #plan.params, #plan.params == 1 and '' or 's',
            plan.fn), vim.log.levels.INFO)
    end, { nargs = '*',
        desc = 'cartograph: stage extracting FILE lines <first>..<last> of the focused function into a new local <name> — the headless face of the source pane\'s :CartographExtract. Whole top-level statements only; refuses a selection that cuts a control-structure body, contains return/break/goto, or would split a shadowed variable (scope-correct CFG reaching decides, never a name match). Review :CartographDiff, commit :CartographApply' })

    -- ── reorder APPLY: move a statement, verified against the commute verdict ──
    cmd('CartographReorderApply', function (o)
        local store = live() if not store then return end
        if store.txn then
            return vim.notify('cartograph: a transaction is already staged'
                .. ' — :CartographApply or :CartographTxnClear first', vim.log.levels.WARN)
        end
        local id = store.focused
        local n = id and store.node(id)
        if not n or (n.kind ~= 'function' and n.kind ~= 'method') then
            return vim.notify('cartograph: focus a function first', vim.log.levels.WARN)
        end
        -- <from> <to>  (single statement)  |  <from> <through> <to>  (block)
        local n1 = o.fargs[1] and tonumber(o.fargs[1])
        local n2 = o.fargs[2] and tonumber(o.fargs[2])
        local n3 = o.fargs[3] and tonumber(o.fargs[3])
        local from, through, to
        if n3 then from, through, to = n1, n2, n3
        elseif n2 then from, to = n1, n2 end
        if not (from and to) then
            return vim.notify('cartograph: :CartographReorderApply <from> [<through>] <to>'
                .. ' (move the statement/block at <from>[..<through>] to before <to>)', vim.log.levels.WARN)
        end
        local plan, why = require('cartograph.reorder').plan_move(store, id, from, to, through)
        if not plan then
            return vim.notify('cartograph: cannot reorder — ' .. tostring(why), vim.log.levels.WARN)
        end
        store.set_txn(plan)
        vim.notify(('cartograph: reorder staged — move %d statement(s) (L%d%s) before L%d in %s.'
            .. ' Review with :CartographDiff, then :CartographApply'):format(
            plan.nstmts, from, through and ('..L' .. through) or '', to, plan.fn), vim.log.levels.INFO)
    end, { nargs = '*', desc = 'cartograph: stage a VERIFIED statement reorder in the focused fn — move the statement at <from> (or the block <from>..<through>) to before <to>. Certified behavior-preserving by the commute verdict (refuses if it crosses a dataflow dep, a state/world conflict, or an opaque statement). Review :CartographDiff, commit :CartographApply' })

    -- ── hoist-closure: lift the focused nested closure to module scope ──
    cmd('CartographHoistClosure', function ()
        local store = live() if not store then return end
        if store.txn then
            return vim.notify('cartograph: a transaction is already staged'
                .. ' — :CartographApply or :CartographTxnClear first', vim.log.levels.WARN)
        end
        local id = store.focused
        local n = id and store.node(id)
        if not n or (n.kind ~= 'function' and n.kind ~= 'method') then
            return vim.notify('cartograph: focus a nested function first', vim.log.levels.WARN)
        end
        local plan, why = require('cartograph.hoistclosure').plan(store, id)
        if not plan then
            return vim.notify('cartograph: cannot hoist — ' .. tostring(why), vim.log.levels.WARN)
        end
        store.set_txn(plan)
        vim.notify(('cartograph: hoist staged — lift `%s` out of %s to module scope.'
            .. ' Review with :CartographDiff, then :CartographApply'):format(
            plan.name, plan.anchor), vim.log.levels.INFO)
    end, { desc = 'cartograph: stage lifting the focused NESTED closure to module scope — sound only when it captures nothing from its enclosing function(s) (every free read is module-level or global). Refuses a capture with the variable named (parameterize it via :CartographExtractHelperApply first). Review :CartographDiff, commit :CartographApply' })

    -- ── optimize-apply: dry-run the CSE-reuse rewrite of the focused fn ───
    cmd('CartographOptimizeApply', function ()
        local store = live() if not store then return end
        local id = store.focused
        local n = id and store.node(id)
        if not n or (n.kind ~= 'function' and n.kind ~= 'method') then
            return vim.notify('cartograph: focus a function first',
                vim.log.levels.WARN)
        end
        mat_df(store, n.file)
        scratch(require('cartograph.optapply').report(store, id))
    end, { desc = 'cartograph: DRY-RUN the CSE-reuse rewrite of the focused fn (optapply) — the diff an apply would write, txn-journaled + CAS/span/parse-verified; the headless apply verb is optapply.run/apply' })

    -- ── extract-helper proposal: the focused fn's best near-clone → a helper ──
    cmd('CartographExtractHelper', function ()
        local store = live() if not store then return end
        local id = store.focused
        local n = id and store.node(id)
        if not n or (n.kind ~= 'function' and n.kind ~= 'method') then
            return vim.notify('cartograph: focus a function first', vim.log.levels.WARN)
        end
        local clones = require 'cartograph.clones'
        -- the focused fn's best near-clone partner (most shared statements). near_of
        -- enumerates only the focus's candidate partners (not all pairs), over a
        -- generation-cached index — the interactive-scoped query.
        local best = clones.near_of(store, id, { max_dist = 2 })[1]
        if not best then
            return vim.notify(('cartograph: %s has no near-clone within edit distance 2')
                :format(n.name), vim.log.levels.INFO)
        end
        scratch(clones.extract_proposal(best, store))
    end, { desc = 'cartograph: propose the parameterized helper the focused function and its nearest near-clone could factor into — the anti-unified template with the differing leaves as parameters, plus a body-safety verdict (is the whole body cleanly liftable?). A reviewable scaffold (the write is not auto-applied). Companion to :CartographMerge for the near-clone case' })

    -- ── extract-helper APPLY: stage the transaction (verified auto-write) ──
    cmd('CartographExtractHelperApply', function (o)
        local store = live() if not store then return end
        if store.txn then
            return vim.notify('cartograph: a transaction is already staged'
                .. ' — :CartographApply or :CartographTxnClear first', vim.log.levels.WARN)
        end
        local id = store.focused
        local n = id and store.node(id)
        if not n or (n.kind ~= 'function' and n.kind ~= 'method') then
            return vim.notify('cartograph: focus a function first', vim.log.levels.WARN)
        end
        local best = require('cartograph.clones').near_of(store, id, { max_dist = 2 })[1]
        if not best then
            return vim.notify(('cartograph: %s has no near-clone within edit distance 2')
                :format(n.name), vim.log.levels.INFO)
        end
        -- an arg is the destination module for a CROSS-FILE pair (a new .lua)
        local dest = o.args ~= '' and o.args or nil
        local plan, why = require('cartograph.cloneextract').plan(store, best, { dest = dest })
        if not plan then
            return vim.notify('cartograph: cannot extract — ' .. tostring(why)
                .. ' (see :CartographExtractHelper for the scaffold)', vim.log.levels.WARN)
        end
        store.set_txn(plan)
        vim.notify(('cartograph: extract-helper staged — %s / %s → %s(%d param%s)%s.'
            .. ' Review with :CartographDiff, then :CartographApply'):format(
            plan.a.name, plan.b.name, plan.helper, plan.nparams,
            plan.nparams == 1 and '' or 's',
            plan.xfile and (' in NEW ' .. plan.create.file) or ''), vim.log.levels.INFO)
    end, { nargs = '?', complete = 'file', desc = 'cartograph: stage the VERIFIED extract-helper transaction for the focused function and its nearest near-clone — synthesizes the shared parameterized helper and rewrites both bodies to tail-call it. Same-file needs no arg; a CROSS-FILE pair takes a destination module path (a new .lua) for the shared helper + require wiring. Constrained to the sound subset (value-parameterizable, body-safe, globals-only for cross-file; Lua or JavaScript, same-file for JS); refuses otherwise. Review :CartographDiff, commit :CartographApply' })

    -- ── refactor-neutrality: certify a move/extract changed no behavior ──
    cmd('CartographNeutralitySnapshot', function ()
        local store = live() if not store then return end
        local n = require('cartograph.neutrality').snapshot(store)
        vim.notify(('cartograph: neutrality baseline captured — %d function witness(es).'
            .. ' Do the refactor, then :CartographNeutralityCheck'):format(n),
            vim.log.levels.INFO)
    end, { desc = 'cartograph: capture the current per-function behavior witnesses (df shape + params + callees) as a baseline, to later certify a move/extract refactor changed no behavior' })

    cmd('CartographNeutralityCheck', function ()
        local store = live() if not store then return end
        local cmp, why = require('cartograph.neutrality').check(store)
        if not cmp then return vim.notify('cartograph: ' .. why, vim.log.levels.WARN) end
        scratch(require('cartograph.neutrality').report(cmp))
        if #cmp.drifted > 0 then
            vim.notify(('cartograph: %d function(s) DRIFTED (body changed) since the baseline')
                :format(#cmp.drifted), vim.log.levels.WARN)
        end
    end, { desc = 'cartograph: diff the current per-function behavior witnesses against the baseline snapshot — neutral = a pure move (witness unchanged), DRIFTED = the body changed (a rewrite). Certifies a relocation was behavior-neutral; honestly flags a rewrite. Companion to :CartographMove / :CartographExtractModule' })
end

return M
