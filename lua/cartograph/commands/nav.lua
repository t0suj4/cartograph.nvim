-- :Cartograph command group — navigation overlays and the working set (|cartograph-cmd-nav|)
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
    -- `!` marks EVERY symbol row in the view, which is how a set gets filled from
    -- an axis: stand on `callees` or `reaches` and take the whole thing at once
    cmd('CartographMark', function (o)
        local store = live() if not store then return end
        local sym = require 'cartograph.panes.symbols'
        if o.bang then sym.ws_toggle_view() else sym.ws_toggle_cursor() end
    end, { bang = true,
        desc = 'cartograph: toggle the cursor row in the working set; ! toggles every symbol row in the view' })

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
end

return M
