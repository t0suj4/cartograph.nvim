-- :Cartograph command group — analysing the focused function (|cartograph-cmd-analysis|)
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

    -- the reorder lens adds the ordering-constraint note on top of a reveal
    local function reorder_reveal(store, m, spec)
        if not (spec and spec.l0 and m and m.node) then return end
        reveal_at(store, m.node.file, spec.l0)
        if spec.peer then
            vim.notify(('cartograph: #%d — ordering constraint with #%d')
                :format(spec.i, spec.peer), vim.log.levels.INFO)
        end
    end

    cmd('CartographReorder', function ()
        local store = live() if not store then return end
        store = whole_graph(store) if not store then return end
        local id = store.focused
        local n = id and store.node(id)
        if not n or (n.kind ~= 'function' and n.kind ~= 'method') then
            return vim.notify('cartograph: focus a function first',
                vim.log.levels.WARN)
        end
        local lines, at, m = require('cartograph.reorder').lens(store, id)
        local buf = scratch(lines)
        if m then
            vim.keymap.set('n', '<CR>', function ()
                reorder_reveal(store, m, at[vim.api.nvim_win_get_cursor(0)[1]])
            end, { buffer = buf, desc = 'cartograph: reveal this statement in the source pane' })
        end
    end, { desc = 'cartograph: statement commutativity of the focused fn — deps, conflicts, freely-movable (the cockpit reorder view; <CR> reveals a statement in the source)' })

    -- ── untangle: the focused fn's independent CONCERNS over the full PDG ─
    cmd('CartographUntangle', function ()
        local store = live() if not store then return end
        store = whole_graph(store) if not store then return end
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
        mat_df(store, n.file)
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
        mat_df(store, n.file)
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

    -- ── narrow: branch-sensitive nil/type narrowing of the focused fn ─────
    cmd('CartographNarrow', function ()
        local store = live() if not store then return end
        local id = store.focused
        local n = id and store.node(id)
        if not n or (n.kind ~= 'function' and n.kind ~= 'method') then
            return vim.notify('cartograph: focus a function first',
                vim.log.levels.WARN)
        end
        mat_df(store, n.file)
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
        mat_df(store, n.file)
        scratch(require('cartograph.narrow').param_report(store, id))
    end, { desc = 'cartograph: inferred parameter-nilability of the focused fn (required / optional / unknown) vs its ---@param annotations — an unguarded deref of a param annotated nilable `?` is a real defect (the lua-ls disagreement oracle)' })

    -- ── trace: where does a parameter's values come from? ─────────────────
    -- A jumpable lens over trace.lua's incremental API: one row per resolved
    -- call site, descend to take the next hop. Needs the whole graph — the
    -- rows ARE call sites, so on the thin index an empty answer would read as
    -- an honest "nothing passes here" when the calls were simply never built.
    cmd('CartographTrace', function (o)
        local store = live() if not store then return end
        store = whole_graph(store) if not store then return end
        local id = store.focused
        local n = id and store.node(id)
        if not n or (n.kind ~= 'function' and n.kind ~= 'method') then
            return vim.notify('cartograph: focus a function first',
                vim.log.levels.WARN)
        end
        local i = tonumber(o.fargs[1] or '1')
        local params = n.params or {}
        if not i or i < 1 then
            return vim.notify('cartograph: :CartographTrace [n] — the parameter'
                .. ' position to trace (default 1)', vim.log.levels.WARN)
        end
        if #params > 0 and i > #params then
            return vim.notify(('cartograph: %s takes %d parameter(s) (%s)')
                :format(n.name or id, #params, table.concat(params, ', ')),
                vim.log.levels.WARN)
        end
        local trace = require 'cartograph.trace'
        mat_df(store, n.file)
        local lines, at = trace.lens(store, id, i)
        local buf = scratch(lines)
        local keys = require('cartograph.config').keys
        if keys.pivot then
            vim.keymap.set('n', keys.pivot, function ()
                local e = at[vim.api.nvim_win_get_cursor(0)[1]]
                local s = e and e.origin.site
                if s then reveal_at(store, s.file, s.line or 0) end
            end, { buffer = buf,
                desc = 'cartograph: reveal where this value flows from' })
        end
        -- descend = take the next hop, spliced in under the row. A frontier
        -- says WHY it stops rather than silently doing nothing.
        if keys.descend then
            vim.keymap.set('n', keys.descend, function ()
                local row = vim.api.nvim_win_get_cursor(0)[1]
                local e = at[row]
                if not e then return end
                if e.done then
                    return vim.notify('cartograph: already expanded',
                        vim.log.levels.INFO)
                end
                if e.origin.site then mat_df(store, e.origin.site.file) end
                local kids, why = trace.expand(store, e.origin)
                if not kids or #kids == 0 then
                    e.done = true
                    return vim.notify('cartograph: frontier — '
                        .. tostring(why or 'nothing further'), vim.log.levels.INFO)
                end
                e.done = true
                local new = {}
                for _, k in ipairs(kids) do
                    new[#new + 1] = (trace.row(store, k, e.depth + 1))
                end
                vim.bo[buf].modifiable = true
                vim.api.nvim_buf_set_lines(buf, row, row, false, new)
                vim.bo[buf].modifiable = false
                -- shift the map past the insertion, then register the new rows
                local moved = {}
                for r, v in pairs(at) do
                    moved[r > row and r + #new or r] = v
                end
                for j, k in ipairs(kids) do
                    moved[row + j] = { origin = k, depth = e.depth + 1 }
                end
                at = moved
                pcall(vim.api.nvim_win_set_height, 0,
                    math.min(vim.api.nvim_buf_line_count(buf) + 1, 20))
            end, { buffer = buf,
                desc = 'cartograph: expand this origin one hop' })
        end
    end, { nargs = '?', desc = 'cartograph: trace where parameter [n] of the focused fn gets its values — one row per resolved call site, descend to take the next hop; a frontier (field/global aliasing, dynamic call, vararg) says why it stops' })

    -- ── devirt: dispatch sites the narrowing facts can turn static ────────
    cmd('CartographDevirt', function ()
        local store = live() if not store then return end
        local id = store.focused
        local n = id and store.node(id)
        if not n or (n.kind ~= 'function' and n.kind ~= 'method') then
            return vim.notify('cartograph: focus a function first',
                vim.log.levels.WARN)
        end
        mat_df(store, n.file)
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

    -- ── untangle MODULE: independent function clusters in a file (or a dir) ─
    cmd('CartographUntangleModule', function (o)
        local store = live() if not store then return end
        store = whole_graph(store) if not store then return end
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
        mat_df(store, n.file)
        scratch(require('cartograph.lens').report(store, id))
    end, { desc = 'cartograph: values LIVE through each CFG branch of the focused fn (~=hedged reaching) — the branch-value lens' })
end

return M
