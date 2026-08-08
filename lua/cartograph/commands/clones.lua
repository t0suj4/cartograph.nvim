-- :Cartograph command group — clone detection and its in-buffer signs (|cartograph-cmd-clones|)
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


    -- ── exact-structural clones: duplication the extract/merge can remove ──
    cmd('CartographClones', function (o)
        local store = live() if not store then return end
        local nfns = 0
        for _, n in ipairs(store.data.nodes) do
            if n.kind == 'function' or n.kind == 'method' then nfns = nfns + 1 end
        end
        vim.notify(('cartograph: scanning %d functions for exact-structural clones…')
            :format(nfns), vim.log.levels.INFO)
        local groups = require('cartograph.clones').exact(store,
            { min_rows = o.count ~= -1 and o.count or 3 })
        scratch(require('cartograph.clones').report(groups))
    end, { count = -1, desc = 'cartograph: exact-structural clone groups (alpha-invariant on locals; expr-IR keyed). Focus a group member + :CartographMerge to remove it. [count] = min statements (default 3)' })

    -- ── block clones: contiguous statement runs shared across/within functions ──
    cmd('CartographBlockClones', function (o)
        local store = live() if not store then return end
        vim.notify('cartograph: scanning for block-structural clones…', vim.log.levels.INFO)
        local cl = require 'cartograph.clones'
        local groups = cl.blocks(store, { min_len = o.count ~= -1 and o.count or 6 })
        -- classify before reporting: extractability is the tier, length is a detail
        scratch(cl.blocks_report(cl.classify_blocks(store, groups)))
    end, { count = -1, desc = 'cartograph: block-structural clone groups — contiguous statement runs duplicated across/within functions (a clone INSIDE a function, which :CartographClones\' whole-function tier is blind to). Ranked by whether the block can be EXTRACTED and how narrow the resulting helper signature would be; length is a detail, not the tier. [count] = min statements (default 6)' })

    -- ── near-clones: functions differing by a few edits (anti-unification) ──
    cmd('CartographNearClones', function (o)
        local store = live() if not store then return end
        vim.notify('cartograph: scanning for near-clones (anti-unification)…', vim.log.levels.INFO)
        local pairs_ = require('cartograph.clones').near(store,
            { max_dist = o.count ~= -1 and o.count or 2 })
        scratch(require('cartograph.clones').near_report(pairs_, store))
    end, { count = -1, desc = 'cartograph: near-clone pairs — functions whose statement sequences differ by only a few edits. The matched rows are the shared template, the differing rows are the holes (parameters of the helper the copies could factor into). [count] = max edit distance (default 2)' })

    -- ── clone findings as in-buffer signs (the interactive surface) ──
    cmd('CartographClonesSigns', function ()
        local store = live() if not store then return end
        vim.notify('cartograph: scanning for clones (exact + near)…', vim.log.levels.INFO)
        local pub = {}
        for _, f in ipairs(require('cartograph.clones').findings(store)) do
            local file = f.file
            if file and file:sub(1, 1) ~= '/' then file = store.abs(file) end
            pub[#pub + 1] = { file = file, line = f.line, col = f.col,
                severity = f.severity, message = ('[clone] %s'):format(f.message) }
        end
        local n = require('cartograph.diag').publish(pub, 'clones')
        vim.notify(('cartograph: %d clone finding(s) on in-buffer signs — ]d / :CartographClonesSignsClear')
            :format(n), vim.log.levels.INFO)
    end, { desc = 'cartograph: publish clone findings as in-buffer signs — exact clones (:CartographMerge) + near-clone functions and their value holes, the hole signs sitting at the exact substitution column so ]d jumps to it. The interactive companion to the clone reports' })

    cmd('CartographClonesSignsClear', function ()
        require('cartograph.diag').clear('clones')
        vim.notify('cartograph: cleared in-buffer clone signs', vim.log.levels.INFO)
    end, { desc = 'cartograph: clear the in-buffer clone signs' })
end

return M
