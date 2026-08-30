-- :Cartograph command group — the transaction verbs (|cartograph-cmd-txn|)
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


    cmd('CartographDiff', function ()
        local st = live() if not st then return end
        if not st.txn then
            return vim.notify('cartograph: nothing staged', vim.log.levels.WARN)
        end
        local before, after, why = require(txn_module()).preview(st, st.txn)
        if not before then
            return vim.notify('cartograph: ' .. tostring(why), vim.log.levels.WARN)
        end
        scratch(require('cartograph.txn')
            .difftext(before, after, st.txn.touched), 'diff')
    end, { desc = 'cartograph: the exact diff the staged transaction would write' })

    cmd('CartographApply', function ()
        local st = live() if not st then return end
        if not st.txn then
            return vim.notify('cartograph: nothing staged', vim.log.levels.WARN)
        end
        local entry, why = require(txn_module()).apply(st, st.txn)
        if not entry then
            return vim.notify('cartograph: apply REFUSED — ' .. tostring(why),
                vim.log.levels.WARN)
        end
        vim.notify(('cartograph: applied %s (journal %s) —'
            .. ' :CartographUndo restores'):format(entry.verb, entry.id),
            vim.log.levels.INFO)
    end, { desc = 'cartograph: apply the staged transaction' })

    cmd('CartographTxnClear', function ()
        require('cartograph.store').set_txn(nil)
        vim.notify('cartograph: transaction cleared (nothing was written)',
            vim.log.levels.INFO)
    end, { desc = 'cartograph: abandon the staged transaction' })

    cmd('CartographUndo', function ()
        local st = live() if not st then return end
        local entry, why = require('cartograph.journal').rollback(st.data.root)
        if not entry then
            return vim.notify('cartograph: undo — ' .. tostring(why),
                vim.log.levels.WARN)
        end
        local touched = {}
        for rel in pairs(entry.files) do touched[#touched + 1] = rel end
        table.sort(touched)
        require('cartograph.refresh').files(touched)
        vim.cmd('silent! checktime')
        vim.notify(('cartograph: rolled back %s (%s) — files restored'
            .. ' byte-exact'):format(entry.verb, entry.id), vim.log.levels.INFO)
    end, { desc = 'cartograph: roll back the last applied transaction' })

    cmd('CartographRedo', function ()
        local st = live() if not st then return end
        local entry, why = require('cartograph.journal').redo(st.data.root)
        if not entry then
            return vim.notify('cartograph: redo — ' .. tostring(why),
                vim.log.levels.WARN)
        end
        local touched = {}
        for rel in pairs(entry.files) do touched[#touched + 1] = rel end
        require('cartograph.refresh').files(touched)
        vim.cmd('silent! checktime')
        vim.notify(('cartograph: redid %s (%s) — :CartographUndo reverses'
            .. ' again'):format(entry.verb, entry.id), vim.log.levels.INFO)
    end, { desc = 'cartograph: re-apply the most recently undone transaction' })

    -- ⚠ DRY BY DEFAULT, `!` TO APPLY (CART-0644). This deletes a USER RECORD, and
    -- the whole reason the journal lives in the state dir rather than a cache is that
    -- it is not ours to clear on a whim. So the bare verb REPORTS and the bang acts —
    -- the same shape the write verbs use, for the same reason.
    cmd('CartographJournalPrune', function (o)
        local j = require 'cartograph.journal'
        local st = j.prune({ apply = o.bang })
        local lines = {
            ('journal retention — %d directory(ies) under the state dir'):format(#st.rows),
            '',
            ('  UNREACHABLE: %d directory(ies), %d entry(ies)'):format(
                st.removed, st.entries_removed),
            '    a journal whose ROOT NO LONGER EXISTS cannot be rolled back —',
            '    `rollback` verifies current content against after_hash and there is',
            '    no current content. Removing it destroys nothing still reachable.',
            ('  KEPT: %d — the root still exists'):format(st.kept),
        }
        for _, r in ipairs(st.rows) do
            if r.keep then
                lines[#lines + 1] = ('    %-4d entries  %s'):format(r.entries,
                    tostring(r.root))
            end
        end
        lines[#lines + 1] = ''
        lines[#lines + 1] = st.applied
            and '  APPLIED — the directories above are gone.'
            or '  DRY RUN — nothing was touched. :CartographJournalPrune! to apply.'
        scratch(lines)
    end, { bang = true,
        desc = 'cartograph: report (or with ! remove) journals whose root is gone' })

    cmd('CartographJournal', function ()
        local st = live() if not st then return end
        local entries = require('cartograph.journal').list(st.data.root)
        local lines, at = {}, {}
        for _, e in ipairs(entries) do
            local files = {}
            for rel in pairs(e.files) do files[#files + 1] = rel end
            table.sort(files)
            lines[#lines + 1] = ('%s  %-11s %-14s %s'):format(
                os.date('%Y-%m-%d %H:%M', e.ts or 0), e.status, e.verb,
                table.concat(files, ', '))
            at[#lines] = e
        end
        if #lines == 0 then lines[1] = 'journal: empty' end
        lines[#lines + 1] = ''
        lines[#lines + 1] = '<CR> = the entry\'s diff'
            .. '  ·  :CartographUndo / :CartographRedo walk the stack'
        local buf = scratch(lines)
        vim.keymap.set('n', '<CR>', function ()
            local e = at[vim.api.nvim_win_get_cursor(0)[1]]
            if not e then return end
            local before, after, order = {}, {}, {}
            for rel, f in pairs(e.files) do
                if not f.after then
                    return vim.notify('cartograph: ' .. e.id
                        .. ' predates diff records', vim.log.levels.WARN)
                end
                order[#order + 1] = rel
                before[rel] = f.absent and false or f.before
                after[rel] = f.after
            end
            table.sort(order)
            scratch(require('cartograph.txn').difftext(before, after, order),
                'diff')
        end, { buffer = buf })
    end, { desc = 'cartograph: browse the transaction journal' })
end

return M
