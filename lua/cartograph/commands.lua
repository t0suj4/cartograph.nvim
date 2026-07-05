-- User commands, registered at STARTUP from plugin/cartograph.lua so
-- invocation is painless: every :Cartograph* command exists (and
-- tab-completes) before any graph is open, answers with a pointer
-- instead of E492, and requires nothing heavy until it actually runs.
-- init.open() re-registers idempotently (the pcall-del pattern).
--
-- This module's top level must stay LEAN — it loads during startup.
-- All requires live inside callbacks.

local M = {}

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

    -- ── which project shape was detected, and what it changed ──────
    cmd('CartographShapes', function ()
        local st = require 'cartograph.store'
        local root = (st.data and st.data.root) or vim.fn.getcwd()
        scratch(require('cartograph.shapes').explain(root))
    end, { desc = 'cartograph: explain project-shape detection for this root' })

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
end

return M
