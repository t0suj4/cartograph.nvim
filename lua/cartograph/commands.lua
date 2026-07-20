-- User commands, registered at STARTUP from plugin/cartograph.lua so
-- invocation is painless: every :Cartograph* command exists (and
-- tab-completes) before any graph is open, answers with a pointer
-- instead of E492, and requires nothing heavy until it actually runs.
-- init.open() re-registers idempotently (the pcall-del pattern).
--
-- This module's top level must stay LEAN — it loads during startup.
-- All requires live inside callbacks.

local M = {}

-- the running dead-biter web canvas (server + live MCP client), if any
local canvas = nil

-- the graph-needing guard: a command that acts on the open cockpit
-- answers helpfully when there is none
local function live()
    local store = require 'cartograph.store'
    if not (store.data and store.data.root) then
        vim.notify('cartograph: no graph open — :Cartograph [dir] first',
            vim.log.levels.WARN)
        return nil
    end
    return store
end

local function scratch(lines, ft)
    vim.cmd('botright new')
    local buf = vim.api.nvim_get_current_buf()
    vim.bo[buf].buftype, vim.bo[buf].bufhidden, vim.bo[buf].swapfile
        = 'nofile', 'wipe', false
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    if ft then vim.bo[buf].filetype = ft end
    vim.api.nvim_win_set_height(0, math.min(#lines + 1, 20))
    vim.keymap.set('n', require('cartograph.config').keys.close,
        '<cmd>close<cr>', { buffer = buf })
    return buf
end

local function txn_module()
    local st = require 'cartograph.store'
    return (st.txn.verb == 'move' or st.txn.verb == 'extract-module')
        and 'cartograph.moveapply' or 'cartograph.clonemerge'
end

local function cmd(name, fn, opts)
    pcall(vim.api.nvim_del_user_command, name)
    vim.api.nvim_create_user_command(name, fn, opts)
end

function M.register()
    -- ── graph-aware lint → quickfix ─────────────────────────────────
    local SEV = { warn = 'W', info = 'I' }
    cmd('CartographLint', function ()
        local store = live() if not store then return end
        local findings = require('cartograph.lint').run(store)
        if #findings == 0 then
            return vim.notify('cartograph: no lint findings', vim.log.levels.INFO)
        end
        local qf = {}
        for _, f in ipairs(findings) do
            qf[#qf + 1] = { filename = f.file, lnum = f.line, col = 1,
                type = SEV[f.severity] or 'E',
                text = ('[%s] %s'):format(f.rule, f.message),
                user_data = f.fix }
        end
        vim.fn.setqflist({}, ' ', { title = 'cartograph lint', items = qf })
        vim.cmd('copen')
    end, { desc = 'cartograph: graph-aware lint (dead code, redundant requires, call cycles) -> quickfix' })

    -- apply the quick fix (an annotation line) of the CURRENT qf entry
    cmd('CartographLintFix', function ()
        local qf = vim.fn.getqflist({ idx = 0, items = 1 })
        local it = qf.items[qf.idx]
        local fix = it and it.user_data
        if type(fix) ~= 'table' or not fix.text then
            return vim.notify('cartograph: no quick fix on this finding', vim.log.levels.WARN)
        end
        local buf = vim.fn.bufadd(fix.file)
        vim.fn.bufload(buf)
        local target = vim.api.nvim_buf_get_lines(buf, fix.line, fix.line + 1, false)[1] or ''
        local indent = target:match('^%s*') or ''
        vim.api.nvim_buf_set_lines(buf, fix.line, fix.line, false, { indent .. fix.text })
        vim.api.nvim_buf_call(buf, function () vim.cmd('silent noautocmd write') end)
        vim.notify(('cartograph: inserted `%s` at %s:%d — regenerate the graph to re-check'):format(
            fix.text, vim.fn.fnamemodify(fix.file, ':t'), fix.line + 1), vim.log.levels.INFO)
    end, { desc = 'cartograph: apply the annotation quick fix of the current quickfix entry' })

    -- ── A1: lint findings as IN-BUFFER SIGNS (diag surface) ──────────
    -- the whole shipped lint suite (taint rungs, external-surface, redundant-
    -- require, seam-guard, …) lands where the code is, not only in quickfix.
    cmd('CartographLintSigns', function ()
        local store = live() if not store then return end
        local findings = require('cartograph.lint').run(store)
        local pub = {}
        for _, f in ipairs(findings) do
            local file = f.file
            if file and file:sub(1, 1) ~= '/' then file = store.abs(file) end
            pub[#pub + 1] = { file = file, line = f.line, col = f.col,
                severity = f.severity,                 -- the rule's curated tier
                message = ('[%s] %s'):format(f.rule, f.message) }
        end
        local n = require('cartograph.diag').publish(pub, 'lint')
        vim.notify(('cartograph: %d lint finding(s) on in-buffer signs'):format(n),
            vim.log.levels.INFO)
    end, { desc = 'cartograph: publish lint findings as in-buffer signs (A1)' })

    cmd('CartographLintClear', function ()
        require('cartograph.diag').clear('lint')
        vim.notify('cartograph: cleared in-buffer lint signs', vim.log.levels.INFO)
    end, { desc = 'cartograph: clear the in-buffer lint signs' })

    -- ── live refresh ────────────────────────────────────────────────
    cmd('CartographRefresh', function (o)
        local store = live() if not store then return end
        local r = require 'cartograph.refresh'
        local stats, why
        if o.bang then
            stats, why = r.all()
        else
            local abs = vim.api.nvim_buf_get_name(0)
            local root = store.data.root
            if abs:sub(1, #root + 1) == root .. '/' then
                stats, why = r.file(abs:sub(#root + 2))
            else
                stats, why = r.all()
            end
        end
        vim.notify(stats and ('cartograph: refreshed (' .. vim.inspect(stats):gsub('%s+', ' ') .. ')')
            or ('cartograph: ' .. tostring(why)),
            stats and vim.log.levels.INFO or vim.log.levels.WARN)
    end, { bang = true,
        desc = 'cartograph: refresh the graph (current file; ! = whole project)' })

    -- ── LSP read surface (T1 in-process) ────────────────────────────
    -- attach a REAL LSP client to the current buffer, served from the open
    -- graph — gd / gr / K / documentSymbol / workspaceSymbol answer from the
    -- common core (cross-language, honesty-on-hover). Read-only.
    cmd('CartographLspAttach', function ()
        local store = live() if not store then return end
        local id, why = require('cartograph.lsp').attach()
        vim.notify(id and 'cartograph: LSP attached (client ' .. id .. ')'
            or ('cartograph: LSP attach failed — ' .. tostring(why)),
            id and vim.log.levels.INFO or vim.log.levels.WARN)
    end, { desc = 'cartograph: attach the in-process LSP read surface to this buffer' })

    cmd('CartographLspDetach', function ()
        for _, c in ipairs(vim.lsp.get_clients({ name = 'cartograph' })) do
            vim.lsp.stop_client(c.id)
        end
        vim.notify('cartograph: LSP detached', vim.log.levels.INFO)
    end, { desc = 'cartograph: stop the in-process LSP read surface' })

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

    -- ── the running system vs the static model ──────────────────────
    cmd('CartographLive', function ()
        local store = live() if not store then return end
        local lines, why = require('cartograph.live').check(store)
        if not lines then
            return vim.notify('cartograph: live check failed — ' .. tostring(why),
                vim.log.levels.WARN)
        end
        require('cartograph.panes.symbols').render() -- states view gains ◉
        scratch(lines)
    end, { desc = 'cartograph: check the RUNNING system against the static model (MCP oracle)' })

    -- ── safe-reorder: which of the focused fn's statements commute ───
    cmd('CartographReorder', function ()
        local store = live() if not store then return end
        local id = store.focused
        local n = id and store.node(id)
        if not n or (n.kind ~= 'function' and n.kind ~= 'method') then
            return vim.notify('cartograph: focus a function first',
                vim.log.levels.WARN)
        end
        scratch(require('cartograph.reorder').report(store, id))
    end, { desc = 'cartograph: statement commutativity of the focused fn — deps, conflicts, freely-movable (the cockpit reorder view)' })

    -- ── untangle: the focused fn's independent CONCERNS over the full PDG ─
    cmd('CartographUntangle', function ()
        local store = live() if not store then return end
        local id = store.focused
        local n = id and store.node(id)
        if not n or (n.kind ~= 'function' and n.kind ~= 'method') then
            return vim.notify('cartograph: focus a function first',
                vim.log.levels.WARN)
        end
        scratch(require('cartograph.untangle').report(store, id))
    end, { desc = 'cartograph: independent concerns of the focused fn over the data+control+effect PDG, with the safe-to-split verdict and why-not breakdown (the untangle lens)' })

    -- ── extract-blocks: the focused fn's nested loops/branches as helper candidates
    cmd('CartographExtractBlocks', function ()
        local store = live() if not store then return end
        local id = store.focused
        local n = id and store.node(id)
        if not n or (n.kind ~= 'function' and n.kind ~= 'method') then
            return vim.notify('cartograph: focus a function first',
                vim.log.levels.WARN)
        end
        scratch(require('cartograph.untangle').report_blocks(store, id))
    end, { desc = 'cartograph: the focused fn\'s control sub-regions (loops/branches) as extract-into-helper candidates, with the (params)->(returns) interface and control-escape verdict — the linear-pipeline decomposition view' })

    -- ── optimize (LICM): loop-invariant computations of the focused fn ─────
    cmd('CartographOptimize', function ()
        local store = live() if not store then return end
        local id = store.focused
        local n = id and store.node(id)
        if not n or (n.kind ~= 'function' and n.kind ~= 'method') then
            return vim.notify('cartograph: focus a function first',
                vim.log.levels.WARN)
        end
        scratch(require('cartograph.optimize').report(store, id))
    end, { desc = 'cartograph: loop-invariant computations of the focused fn (LICM) — pure work whose inputs are all loop-invariant, hoistable above the loop; * = clean, ~ = aliasing/branch-hedged (the optimizing sibling of untangle)' })

    -- ── expr: Rung-0 lints over the expression IR of the focused fn ───────
    cmd('CartographExpr', function ()
        local store = live() if not store then return end
        local id = store.focused
        local n = id and store.node(id)
        if not n or (n.kind ~= 'function' and n.kind ~= 'method') then
            return vim.notify('cartograph: focus a function first',
                vim.log.levels.WARN)
        end
        scratch(require('cartograph.exprlint').report(store, id))
    end, { desc = 'cartograph: Rung-0 expression lints of the focused fn — self-compare / duplicated-operand / bool-comparison / self-assignment / pseudo-ternary / constant-condition / string-concat-in-loop / duplicated-condition, over the per-row expression IR (the expression layer)' })

    -- ── optimize-apply: dry-run the CSE-reuse rewrite of the focused fn ───
    cmd('CartographOptimizeApply', function ()
        local store = live() if not store then return end
        local id = store.focused
        local n = id and store.node(id)
        if not n or (n.kind ~= 'function' and n.kind ~= 'method') then
            return vim.notify('cartograph: focus a function first',
                vim.log.levels.WARN)
        end
        scratch(require('cartograph.optapply').report(store, id))
    end, { desc = 'cartograph: DRY-RUN the CSE-reuse rewrite of the focused fn (optapply) — the diff an apply would write, txn-journaled + CAS/span/parse-verified; the headless apply verb is optapply.run/apply' })

    -- ── narrow: branch-sensitive nil/type narrowing of the focused fn ─────
    cmd('CartographNarrow', function ()
        local store = live() if not store then return end
        local id = store.focused
        local n = id and store.node(id)
        if not n or (n.kind ~= 'function' and n.kind ~= 'method') then
            return vim.notify('cartograph: focus a function first',
                vim.log.levels.WARN)
        end
        scratch(require('cartograph.narrow').report(store, id))
    end, { desc = 'cartograph: branch-sensitive narrowing of the focused fn — where a guard (nil-check / truthiness) proves a variable non-nil in a region, over cfg.guards_over (the type sibling of const-fold)' })

    -- ── param-nil: inferred parameter nilability vs the @param annotations ─
    cmd('CartographParamNil', function ()
        local store = live() if not store then return end
        local id = store.focused
        local n = id and store.node(id)
        if not n or (n.kind ~= 'function' and n.kind ~= 'method') then
            return vim.notify('cartograph: focus a function first',
                vim.log.levels.WARN)
        end
        scratch(require('cartograph.narrow').param_report(store, id))
    end, { desc = 'cartograph: inferred parameter-nilability of the focused fn (required / optional / unknown) vs its ---@param annotations — an unguarded deref of a param annotated nilable `?` is a real defect (the lua-ls disagreement oracle)' })

    -- ── devirt: dispatch sites the narrowing facts can turn static ────────
    cmd('CartographDevirt', function ()
        local store = live() if not store then return end
        local id = store.focused
        local n = id and store.node(id)
        if not n or (n.kind ~= 'function' and n.kind ~= 'method') then
            return vim.notify('cartograph: focus a function first',
                vim.log.levels.WARN)
        end
        scratch(require('cartograph.narrow').devirt_report(store, id))
    end, { desc = 'cartograph: devirtualization of the focused fn — a method dispatch `recv:m()` whose receiver a guard narrows to a concrete type is a static-call candidate (string → stdlib target now, certified; other types → blocked on VM receiver typing). The devirt-gap consumer of the type/discriminant facts' })

    -- ── field-link: where the focused method's self.field reads are DEFINED ─
    cmd('CartographFields', function ()
        local store = live() if not store then return end
        local id = store.focused
        local n = id and store.node(id)
        if not n or (n.kind ~= 'function' and n.kind ~= 'method') then
            return vim.notify('cartograph: focus a method first',
                vim.log.levels.WARN)
        end
        scratch(require('cartograph.fieldlink').report(store, id))
    end, { desc = 'cartograph: field/member linker (Track 3) — resolves the focused method\'s self.field READS to the self.field = … WRITE(s) on its class (own methods + extends ancestors), receiver-typed. Go-to-definition for a data member; a writeless read is left unresolved (sound-first, not the dead undefined-member lint)' })

    -- ── field-harvest: the disagreement harvest — field resolutions vs lua-ls ─
    cmd('CartographFieldHarvest', function ()
        local store = live() if not store then return end
        vim.notify('cartograph: harvesting field resolutions vs lua-ls (async)…',
            vim.log.levels.INFO)
        require('cartograph.fieldharvest').harvest(store, {}, function (stats, why)
            scratch(require('cartograph.fieldharvest').report(stats, why))
        end)
    end, { desc = 'cartograph: DISAGREEMENT HARVEST — compares the field linker\'s self.field read→write resolutions to lua-ls go-to-definition over the loaded graph. Agree = confidence; a CONFLICT is a real bug on ONE side (the north-star success bar). Bounded-scope (lua-ls indexing) — best per-addon / per-file' })

    -- ── untangle MODULE: independent function clusters in a file (or a dir) ─
    cmd('CartographUntangleModule', function (o)
        local store = live() if not store then return end
        local u = require 'cartograph.untangle'
        local arg = o.args ~= '' and o.args or nil
        if arg then -- a directory scope (god-package): cluster across its files
            local files = u.files_under(store, arg)
            if #files == 0 then
                return vim.notify('cartograph: no files under ' .. arg, vim.log.levels.WARN)
            end
            return scratch(u.report_scope(store, files, arg))
        end
        local id = store.focused
        local n = id and store.node(id)
        if not n or not n.file then
            return vim.notify('cartograph: focus a node in the file first (or pass a dir)',
                vim.log.levels.WARN)
        end
        scratch(u.report_module(store, n.file))
    end, { nargs = '?', complete = 'dir',
        desc = 'cartograph: independent function clusters in the focused file (or a directory arg = god-package scope) over call + shared-written-state edges — inter-function untangle' })

    -- ── the branch-value lens: what flows through each CFG branch ────
    cmd('CartographBranchValues', function ()
        local store = live() if not store then return end
        local id = store.focused
        local n = id and store.node(id)
        if not n or (n.kind ~= 'function' and n.kind ~= 'method') then
            return vim.notify('cartograph: focus a function first',
                vim.log.levels.WARN)
        end
        scratch(require('cartograph.lens').report(store, id))
    end, { desc = 'cartograph: values LIVE through each CFG branch of the focused fn (~=hedged reaching) — the branch-value lens' })

    -- ── the honesty census: how well is this graph actually resolved ─
    cmd('CartographCensus', function ()
        local store = live() if not store then return end
        scratch(require('cartograph.census').report(store.data))
    end, { desc = 'cartograph: epistemic census — edge trust tiers + refusals by rule (the analyzer work-list)' })

    -- ── derived-index integrity: the Log/View rule, executable ───────
    cmd('CartographAudit', function ()
        local store = live() if not store then return end
        local out, why = store.audit()
        if not out then
            return vim.notify('cartograph: audit skipped — ' .. why,
                vim.log.levels.WARN)
        end
        if #out == 0 then
            return vim.notify('cartograph: indexes match a fresh derive (clean)',
                vim.log.levels.INFO)
        end
        table.insert(out, 1, ('index drift — %d divergence(s) vs a fresh derive:')
            :format(#out))
        scratch(out)
    end, { desc = 'cartograph: diff live indexes against a fresh derive (catches in-place writer drift)' })

    -- ── escalation-on-hedge: confirm the ~ hotspots vs lua-ls ────────
    cmd('CartographEscalate', function (o)
        local store = live() if not store then return end
        local esc = require 'cartograph.escalate'
        vim.notify('cartograph: escalating hedge-saturated fns to lua-ls…',
            vim.log.levels.INFO)
        -- ASYNC: lua-ls's workspace load no longer freezes the editor. The
        -- generation gates the anti-thrash cache; --all widens past the
        -- saturated work-list to the whole graph.
        esc.run_async(store.data, { generation = store.generation, all = o.bang },
            function (f, why)
                if not f then
                    return vim.notify('cartograph: escalate — ' .. tostring(why),
                        vim.log.levels.WARN)
                end
                local byid = {}
                for _, n in ipairs(store.data.nodes) do byid[n.id] = n end
                local function nameof(id) return byid[id] and byid[id].name or tostring(id) end
                require('cartograph.panes.symbols').render() -- upgraded ~→proven show
                -- in-buffer surface: conflicts (★ error) + refuted (warn) as signs
                local n = require('cartograph.diag').publish(
                    esc.diagnostics(f, store.abs, nameof), 'escalate')
                scratch(esc.report(f, nameof))
                if n > 0 then
                    vim.notify(('cartograph: %d conflict/refuted finding(s) on in-buffer signs')
                        :format(n), vim.log.levels.INFO)
                end
            end)
    end, { bang = true, desc = 'cartograph: escalate hedge-saturated fns to lua-ls (async) — confirmed/CONFLICT/refuted/recovered; ! = whole graph' })

    -- ── the self oracle: declared vs actually-registered ────────────
    cmd('CartographSelf', function ()
        local store = live() if not store then return end
        if store.data.provider ~= 'self' then
            return vim.notify('cartograph: :CartographSelf needs a self:// graph'
                .. ' — open :Cartograph self://loaded', vim.log.levels.WARN)
        end
        scratch(require('cartograph.self_oracle').registrations(store.data))
    end, { desc = 'cartograph: declared vs live registrations (self:// oracle)' })

    -- ── why did registry discovery (not) find a verb? ───────────────
    cmd('CartographDiscover', function (o)
        local store = live() if not store then return end
        local g = require 'cartograph.greenspun'
        local xl = require 'cartograph.xlang'
        local deep = o.bang and { deep = true } or nil
        local lines = g.explain(store.data, o.args ~= '' and o.args or nil, deep)
        -- the bang is the BUTTON: apply what deep discovery found beyond
        -- the bindings already in force, then restore the exact location
        if o.bang and o.args == '' then
            local have = {}
            for _, b in ipairs(xl.effective_bindings(store.data)) do
                for _, v in ipairs(type(b.export.verb) == 'table'
                    and b.export.verb or { b.export.verb }) do
                    have[v] = true
                end
            end
            local fresh = {}
            for _, b in ipairs(g.registries(store.data, { deep = true })) do
                if not have[b.export.verb] then fresh[#fresh + 1] = b end
            end
            if #fresh > 0 then
                local loc = store.loc_provider and store.loc_provider.get()
                local stats = xl.link(store.data, fresh)
                store.ingest(store.data)
                require('cartograph.toc').attach(store)
                if loc and store.loc_provider then store.loc_provider.set(loc) end
                local names = {}
                for _, b in ipairs(fresh) do names[#names + 1] = b.export.verb end
                lines[#lines + 1] = ''
                lines[#lines + 1] = ('APPLIED %d deep binding(s): %s — %d handler(s) resolved, %d site(s) linked')
                    :format(#fresh, table.concat(names, ', '), stats.exports, stats.links)
            else
                lines[#lines + 1] = ''
                lines[#lines + 1] = 'deep discovery found nothing beyond the bindings already in force'
            end
        end
        scratch(lines)
    end, { nargs = '?', bang = true,
        desc = 'cartograph: explain registry discovery; ! runs the deep tier and applies it' })

    -- ── the epistemic ladder: how much of the graph is trustworthy ──
    cmd('CartographLadder', function ()
        local store = live() if not store then return end
        scratch(require('cartograph.ladder').report(store))
    end, { desc = 'cartograph: the call graph\'s epistemic distribution + heaviest refusals' })

    -- ── the EXTERNAL SURFACE: names used but defined nowhere here, with the
    --    shape inferred backward from usage (the boundary map + write-side seed)
    cmd('CartographExternals', function ()
        local store = live() if not store then return end
        scratch(require('cartograph.externals').report(store))
    end, { desc = 'cartograph: the external boundary — unresolved names + their used-shape (~)' })

    -- ── which project shape was detected, and what it changed ──────
    cmd('CartographShapes', function ()
        local st = require 'cartograph.store'
        local root = (st.data and st.data.root) or vim.fn.getcwd()
        scratch(require('cartograph.shapes').explain(root))
    end, { desc = 'cartograph: explain project-shape detection for this root' })

    -- ── generate compile_commands.json for clangd ──────────────────
    cmd('CartographCompileCommands', function (o)
        local clangd = require 'cartograph.providers.clangd'
        local store = require 'cartograph.store'
        local root = (store.data and store.data.root) or vim.fn.getcwd()
        local plan = clangd.compile_plan(root, o.args ~= '' and o.args or nil)
        if not plan then
            return vim.notify('cartograph: no recognized build system at ' .. root
                .. ' — need CMakeLists.txt or meson.build (plain make: run `bear -- make` yourself)',
                vim.log.levels.WARN)
        end
        if vim.fn.executable(plan.need) ~= 1 then
            return vim.notify(('cartograph: %s not found — install it (e.g. pkgit -if %s), then retry')
                :format(plan.need, plan.need), vim.log.levels.WARN)
        end
        local shown = plan.cmdline or table.concat(plan.argv, ' ')
        if plan.builds and not o.bang then
            return vim.notify(('cartograph: this runs a FULL build via `%s` (slow, writes objects). '
                .. 'Re-run as :CartographCompileCommands! to proceed.'):format(shown),
                vim.log.levels.WARN)
        end
        vim.notify('cartograph: generating compile_commands.json — ' .. shown .. ' …',
            vim.log.levels.INFO)
        clangd.run_compile_plan(root, plan, function (okr, output)
            if not okr then
                scratch(vim.split('cartograph: compile_commands generation FAILED\n\n' .. output,
                    '\n', { plain = true }))
                return
            end
            vim.notify('cartograph: compile_commands.json ready at ' .. output
                .. '/ — clangd now has cross-file eyes', vim.log.levels.INFO)
            -- restart the demand session so the open C/C++ graph resolves against
            -- the new db, and re-resolve whatever is focused right now
            if store.data then
                local has_c = false
                for _, n in ipairs(store.data.nodes) do
                    if n.kind == 'module' and n.file:match('%.[ch]p?p?$') then has_c = true break end
                end
                if has_c then
                    clangd.start_session(store.data)
                    local n = store.focused and store.node(store.focused)
                    if n and (n.kind == 'function' or n.kind == 'method') and not n.decl then
                        local gen = store.generation -- see the on_focus hook: stale answers drop
                        clangd.resolve_focused(n, function (edges)
                            if store.generation ~= gen then return end
                            store.set_callers(n.id, edges) store.redraw()
                        end)
                    end
                    vim.notify('cartograph: clangd session restarted — focus a function to resolve it',
                        vim.log.levels.INFO)
                end
            end
        end)
    end, { nargs = '?', bang = true, complete = 'dir',
        desc = 'cartograph: generate compile_commands.json (cmake/meson configure; ! allows a full bear build)' })

    -- ── browse the state machine ────────────────────────────────────
    cmd('CartographStates', function ()
        local store = live() if not store then return end
        local symbols = require 'cartograph.panes.symbols'
        -- pivot to the spec var first: <C-o> returns here, and the
        -- source pane anchors on the spec while browsing states
        local v = symbols.fsm_anchor()
        if v then store.pivot(v.id) end
        symbols.show('states')
    end, { desc = 'cartograph: browse the state machine (states -> entry points -> code)' })

    -- ── project the browser view into a Factorio world ──────────────
    cmd('CartographProject', function (o)
        local store = live() if not store then return end
        local tp = require 'cartograph.textplates'
        if o.bang then -- live: reproject on every navigation until stopped
            local L, why = tp.attach()
            if not L then
                return vim.notify('cartograph: ' .. tostring(why), vim.log.levels.WARN)
            end
            return vim.notify('cartograph: live projection ON — the world tracks the view.'
                .. ' :CartographProjectStop to detach', vim.log.levels.INFO)
        end
        local client, io = tp.connect()
        if not client then
            return vim.notify('cartograph: ' .. tostring(io), vim.log.levels.WARN)
        end
        local cfg = require('cartograph.config').factorio or {}
        local view = require('cartograph.panes.symbols').projection(cfg.max_rows)
        local opts = vim.tbl_extend('force', cfg, { selected = view.selected })
        local ok, delta = pcall(tp.project, io, view.labels, opts)
        pcall(function () client:close() end)
        if not ok then
            return vim.notify('cartograph: projection failed — ' .. tostring(delta), vim.log.levels.WARN)
        end
        local msg = ('cartograph: projected %d row(s) — %d built, %d re-lettered, %d removed')
            :format(#view.labels, #delta.create, #delta.revary, #delta.destroy)
        local level = vim.log.levels.INFO
        if delta.verified == false then -- read-back caught writes that didn't land
            msg = msg .. (' — ⚠ %d cell(s) did not land'):format(tp.delta_count(delta.drift))
            level = vim.log.levels.WARN
        end
        vim.notify(msg, level)
    end, { bang = true,
        desc = 'cartograph: project the current view into Factorio (! = live, reproject on navigation)' })

    cmd('CartographProjectStop', function ()
        require('cartograph.textplates').detach()
        vim.notify('cartograph: live projection detached', vim.log.levels.INFO)
    end, { desc = 'cartograph: stop the live Factorio projection' })

    cmd('CartographProjectStatus', function ()
        local s = require('cartograph.textplates').status()
        if not s.live then
            return vim.notify('cartograph: no live projection (:CartographProject! starts one)',
                vim.log.levels.INFO)
        end
        local when = s.last_sync and os.date('%H:%M:%S', s.last_sync) or 'never'
        if not s.connected then
            return vim.notify('cartograph: projection STALE — wire lost; world frozen as of '
                .. when, vim.log.levels.WARN)
        end
        vim.notify(('cartograph: projection live — last synced %s%s'):format(when,
            (s.drift or 0) > 0 and (', ⚠ %d cell(s) adrift'):format(s.drift) or ', in sync'),
            (s.drift or 0) > 0 and vim.log.levels.WARN or vim.log.levels.INFO)
    end, { desc = 'cartograph: the live Factorio projection\'s honesty state (synced / stale / drift)' })

    -- ── the dead-biter brush: paint a raster into Factorio as corpses ───
    cmd('CartographBrush', function (o)
        local tp = require 'cartograph.textplates'
        local brush = require 'cartograph.brush'
        local client, io = tp.connect() -- reuse the factorio MCP transport
        if not client then
            return vim.notify('cartograph: ' .. tostring(io), vim.log.levels.WARN)
        end
        -- input: a file argument, else the current buffer's lines (draw in nvim)
        local lines
        if o.args ~= '' then
            local okr, r = pcall(vim.fn.readfile, vim.fn.expand(o.args))
            if not okr then
                pcall(function () client:close() end)
                return vim.notify('cartograph: cannot read ' .. o.args, vim.log.levels.WARN)
            end
            lines = r
        else
            lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
        end
        local cfg = require('cartograph.config').factorio or {}
        local opts = vim.tbl_extend('force', { surface = cfg.surface, anchor = cfg.anchor },
            cfg.brush or {})
        local ok, delta = pcall(brush.project, io, lines, opts)
        pcall(function () client:close() end)
        if not ok then
            return vim.notify('cartograph: brush failed — ' .. tostring(delta), vim.log.levels.WARN)
        end
        local msg = ('cartograph: brushed — %d corpse(s) placed, %d cleared')
            :format(#delta.create, #delta.destroy)
        local level = vim.log.levels.INFO
        if delta.verified == false then
            msg = msg .. (' — ⚠ %d cell(s) did not land'):format(brush.delta_count(delta.drift))
            level = vim.log.levels.WARN
        end
        vim.notify(msg .. ' (corpses decay — re-run to refresh)', level)
    end, { nargs = '?', complete = 'file',
        desc = 'cartograph: paint the current buffer (or a file) into Factorio as biter corpses' })

    -- ── territory overlay: partition the graph by which entries reach each node
    cmd('CartographTerritory', function ()
        local store = live() if not store then return end
        local on = require('cartograph.panes.symbols').toggle_territory()
        if not on then
            return vim.notify('cartograph: territory overlay off', vim.log.levels.INFO)
        end
        local t = store.territory()
        if not t then return vim.notify('cartograph: no graph', vim.log.levels.WARN) end
        local s = require('cartograph.territory').summary(t)
        local terr_n = 0; for _ in pairs(s.territories) do terr_n = terr_n + 1 end
        vim.notify(('cartograph: territory — %d root%s (%s) · %d territor%s · %d commons · %d core · %d border%s')
            :format(t.k, t.k == 1 and '' or 's', t.declared and 'declared' or 'apparent',
                terr_n, terr_n == 1 and 'y' or 'ies', s.commons, s.core,
                s.borders, s.borders == 1 and '' or 's'), vim.log.levels.INFO)
    end, { desc = 'cartograph: territory overlay — partition the graph by which entry points reach each node' })

    -- ── detect the tree structures (spines) hiding in the graph ─────
    cmd('CartographSpines', function ()
        local store = live() if not store then return end
        local t = store.territory()
        if not t then return vim.notify('cartograph: no graph', vim.log.levels.WARN) end
        local spines = require 'cartograph.spines'
        local doms = spines.dominator_analysis(t.entries, store.uses)
        -- distinct entry-set regions
        local seen, regions = {}, {}
        for _, info in pairs(t.node) do
            local ids = {}
            for e in pairs(info.entries) do ids[#ids + 1] = e end
            table.sort(ids)
            local key = table.concat(ids, '\31')
            if not seen[key] then
                seen[key] = true
                regions[#regions + 1] = { set = info.entries, n = info.n }
            end
        end
        local rf = spines.region_forest(regions)

        local lines = { 'cartograph: spines', '',
            ('CALL-DOMINATOR SPINES  (%d root%s, %s) — depth = longest must-pass chain')
            :format(t.k, t.k == 1 and '' or 's', t.declared and 'declared' or 'apparent'),
            ('  %-34s %5s %5s  %s'):format('root', 'nodes', 'depth', 'shape') }
        local tally = {}
        for i, d in ipairs(doms) do
            tally[d.shape] = (tally[d.shape] or 0) + 1
            if i <= 25 and d.size > 1 then
                local n = store.node(d.root)
                lines[#lines + 1] = ('  %-34s %5d %5d  %s'):format(
                    ((n and n.name) or d.root):sub(1, 34), d.size, d.depth, d.shape)
            end
        end
        lines[#lines + 1] = ('  — %d spine · %d bushy · %d shallow · %d trivial'):format(
            tally.spine or 0, tally.bushy or 0, tally.shallow or 0, tally.trivial or 0)
        lines[#lines + 1] = ''
        lines[#lines + 1] = 'REGION POSET  (subsystem nesting from entry-sets)'
        if rf.skipped then
            lines[#lines + 1] = ('  %d regions — too many to forest-test'):format(rf.regions)
        elseif rf.forest then
            lines[#lines + 1] = ('  %d regions · forest? YES — a clean subsystem tree'):format(rf.regions)
        else
            lines[#lines + 1] = ('  %d regions · forest? NO · %d multi-parent (layering seams)')
                :format(rf.regions, rf.multiparent)
        end
        scratch(lines)
    end, { desc = 'cartograph: detect the tree structures (call-dominator + subsystem) hiding in the graph' })

    -- ── graph-ops with no vim idiom: commands, bind your own leader keys
    cmd('CartographMark', function ()
        local store = live() if not store then return end
        require('cartograph.panes.symbols').ws_toggle_cursor()
    end, { desc = 'cartograph: toggle the cursor row in the working set' })

    cmd('CartographWorkingSet', function ()
        local store = live() if not store then return end
        require('cartograph.panes.symbols').show('ws')
    end, { desc = 'cartograph: open the working-set view' })

    cmd('CartographCone', function (o)
        local store = live() if not store then return end
        require('cartograph.panes.symbols').cone_cursor(o.args == 'out' and 'out' or 'in')
    end, { nargs = '?', complete = function () return { 'in', 'out' } end,
        desc = 'cartograph: reachability cone on the cursor node (in = ancestors, out = descendants)' })

    -- ── the workspace: ad-hoc Lua against the graph (Smalltalk doit) ─
    cmd('CartographEval', function (o)
        require('cartograph.workspace').run(o.args)
    end, { nargs = '+',
        desc = 'cartograph: evaluate Lua against the graph (store/spines/territory/… in scope)' })

    cmd('CartographWorkspace', function ()
        require('cartograph.workspace').open()
    end, { desc = 'cartograph: open the workspace — ad-hoc Lua against the loaded graph (a returned node list is browsable)' })

    -- ── the LIVE web canvas: draw in a browser, project as corpses ──────
    cmd('CartographCanvas', function ()
        if canvas then
            return vim.notify('cartograph: canvas already running at http://' .. canvas.url
                .. ' (:CartographCanvasStop to end)', vim.log.levels.INFO)
        end
        local tp = require 'cartograph.textplates'
        local brush = require 'cartograph.brush'
        local web = require 'cartograph.webserver'
        local client, io = tp.connect() -- one live MCP connection for the session
        if not client then
            return vim.notify('cartograph: ' .. tostring(io), vim.log.levels.WARN)
        end
        local cfg = require('cartograph.config').factorio or {}
        local bopts = vim.tbl_extend('force', { surface = cfg.surface, anchor = cfg.anchor },
            cfg.brush or {})
        -- debounce: a drag POSTs a burst; project only the latest grid
        local st = { grid = nil, gen = 0 }
        local function schedule()
            st.gen = st.gen + 1
            local mine = st.gen
            vim.defer_fn(function ()
                if not canvas or mine ~= st.gen or not client.alive or not st.grid then return end
                pcall(brush.project, io, st.grid, bopts)
            end, cfg.debounce or 200)
        end
        local srv, err = web.serve({ port = cfg.port or 8778, handler = function (req)
            if req.method == 'GET' and req.path == '/' then
                return 200, 'text/html', web.canvas_html()
            elseif req.method == 'POST' and req.path == '/paint' then
                st.grid = req.body; schedule()
                return 200, 'text/plain', 'ok'
            end
            return 404, 'text/plain', 'not found'
        end })
        if not srv then
            pcall(function () client:close() end)
            return vim.notify('cartograph: ' .. tostring(err), vim.log.levels.WARN)
        end
        canvas = { srv = srv, client = client, url = srv.host .. ':' .. srv.port }
        vim.notify('cartograph: dead-biter canvas live → open http://' .. canvas.url
            .. ' and draw. :CartographCanvasStop to end', vim.log.levels.INFO)
    end, { desc = 'cartograph: serve a browser canvas that paints into Factorio as biter corpses' })

    cmd('CartographCanvasStop', function ()
        if not canvas then
            return vim.notify('cartograph: no canvas running', vim.log.levels.INFO)
        end
        pcall(canvas.srv.close)
        pcall(function () canvas.client:close() end)
        canvas = nil
        vim.notify('cartograph: canvas stopped (the corpses stay — they decay on their own)',
            vim.log.levels.INFO)
    end, { desc = 'cartograph: stop the live web canvas' })
end

return M
