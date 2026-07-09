-- The corpus registry: every named corpus the benchmarks and gates run
-- against, with its expected baseline where the corpus is STABLE (read-only
-- dogfood targets). Baselines are data here — not numbers re-typed into
-- drivers and memos. Living corpora (self, bnw) get no `expected`; their
-- truth is a saved snapshot (tools/snapshot.lua), not a constant.
--
-- expected.refs / expected.nodes are EXACT counts from a calibrated run of
-- the current extractor (see the `calibrated` rev). If a gate fails against
-- them, either the change broke parity or it deliberately moved the baseline
-- — recalibrate with `nvim -l tools/gate.lua <name> --save` + edit here.

local HOME = vim.env.HOME or os.getenv('HOME')

return {
    server = {
        root = HOME .. '/git/elasticsearch/server/src/main/java',
        lang = 'java',
        expected = { refs = 66847, nodes = 87241 }, -- calibrated @ 98a02a1
        notes = 'THE parity gate corpus (5x scale, 4843 files, ~55s extract)',
    },
    libs = {
        root = HOME .. '/git/elasticsearch/libs',
        lang = 'java',
        expected = { refs = 9290, nodes = 13855 }, -- calibrated @ 98a02a1
        notes = 'the small/fast java corpus (943 files, ~10s) — quick iteration',
    },
    self = {
        root = HOME .. '/git/cartograph.nvim',
        lang = 'lua',
        notes = 'cartograph on cartograph — LIVING corpus, snapshot-only baseline',
    },
    bnw = {
        root = HOME .. '/git/bravest-new-world',
        lang = 'lua',
        notes = 'READ-ONLY dogfood target (never modify); dynamic-lua gate for'
            .. ' scope-model step 3 (id_pass precision)',
    },
    wow = {
        root = HOME .. '/work/wow_addons',
        lang = 'lua',
        notes = '353 addons / 2.27M lines — SCALE corpus; .toc load-order'
            .. ' adapter banked, whole-tree extract is a stress test not a gate',
    },
    desynced = {
        root = HOME .. '/work/desynced',
        lang = 'lua',
        notes = 'game-script corpus; adapter gap banked',
    },
}
