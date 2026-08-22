-- :Cartograph command group — the graph-aware lint (|cartograph-cmd-lint|)
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

    local SEV = { warn = 'W', info = 'I' }

    -- `!` SCOPES THE RUN TO WHERE YOU ARE STANDING (CART-0514). The browser's
    -- current frame already IS a node set -- the altitude stage of the
    -- concern pipeline emits one -- and this is the first consumer to receive it
    -- rather than render it. Rules that assert an ABSENCE are refused rather
    -- than clipped, and the refusal is reported, because a scope that silently
    -- dropped them would answer a question it cannot answer.
    cmd('CartographLint', function (o)
        local store = live() if not store then return end
        local scope, title
        if o.bang then
            local sym = require 'cartograph.panes.symbols'
            local alt = require 'cartograph.panes.altitudes'
            local lvl = sym.view and sym.view.level
            scope = require('cartograph.cut').of_frame(store, lvl,
                lvl and alt.key_of(lvl, sym.view))
            if not scope then
                return vim.notify(('cartograph: the %s altitude has no subject to'
                    .. ' scope to — run :CartographLint for the whole corpus')
                    :format(lvl or '?'), vim.log.levels.WARN)
            end
            title = 'cartograph lint — ' .. scope.label
        end
        local findings, refused =
            require('cartograph.lint').run(store, { scope = scope })
        -- the refusals are the design working, so they are SAID, not swallowed
        if scope and #refused > 0 then
            local names = {}
            for i = 1, math.min(#refused, 4) do names[#names + 1] = refused[i].rule end
            vim.notify(('cartograph: %d rule(s) refused for this scope — they assert'
                .. ' an absence, which a subset cannot support (%s%s)')
                :format(#refused, table.concat(names, ', '),
                    #refused > 4 and ', …' or ''), vim.log.levels.INFO)
        end
        if #findings == 0 then
            return vim.notify(('cartograph: no lint findings%s')
                :format(scope and (' in ' .. scope.label) or ''), vim.log.levels.INFO)
        end
        local qf = {}
        for _, f in ipairs(findings) do
            qf[#qf + 1] = { filename = f.file, lnum = f.line, col = 1,
                type = SEV[f.severity] or 'E',
                text = ('[%s] %s'):format(f.rule, f.message),
                user_data = f.fix }
        end
        vim.fn.setqflist({}, ' ', { title = title or 'cartograph lint', items = qf })
        vim.cmd('copen')
    end, { bang = true,
        desc = 'cartograph: graph-aware lint (dead code, redundant requires, call cycles) -> quickfix; ! scopes to the current frame' })

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
end

return M
