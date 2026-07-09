-- The corpus registry: every named corpus the benchmarks and gates run
-- against. A corpus's IDENTITY is its content — repo URL + commit — not the
-- local path (that's just where it happens to live). `expected` baselines are
-- only meaningful at the pinned `rev`: the gate refuses to apply them when
-- the checkout has moved (that would report corpus drift as extractor drift).
--
-- PINNED (repo + rev + expected): stable read-only dogfood targets. If the
-- checkout moves, either restore the rev or recalibrate (`gate <name> --save`
-- on the new rev + update rev/expected here).
-- UNPINNED (no rev): living corpora — their truth is a saved snapshot whose
-- meta records the corpus rev at save time; the gate surfaces rev drift as
-- context instead of failing.

local HOME = vim.env.HOME or os.getenv('HOME')

return {
    server = {
        root = HOME .. '/git/elasticsearch/server/src/main/java',
        repo = 'https://github.com/elastic/elasticsearch',
        rev = '4743238408a4',
        lang = 'java',
        expected = { refs = 66847, nodes = 87241 }, -- calibrated @ tool 98a02a1
        notes = 'THE parity gate corpus (5x scale, 4843 files, ~55s extract)',
    },
    libs = {
        root = HOME .. '/git/elasticsearch/libs',
        repo = 'https://github.com/elastic/elasticsearch',
        rev = '4743238408a4',
        lang = 'java',
        expected = { refs = 9290, nodes = 13855 }, -- calibrated @ tool 98a02a1
        notes = 'the small/fast java corpus (943 files, ~10s) — quick iteration',
    },
    self = {
        root = HOME .. '/git/cartograph.nvim',
        repo = 'git@github.com:t0suj4/cartograph.nvim.git',
        lang = 'lua',
        notes = 'cartograph on cartograph — LIVING corpus, snapshot-only baseline',
    },
    bnw = {
        root = HOME .. '/git/bravest-new-world',
        repo = 'https://github.com/t0suj4/bravest-new-world',
        lang = 'lua',
        notes = 'READ-ONLY dogfood target with UNCOMMITTED WIP (never checkout,'
            .. ' never pin); dynamic-lua gate for scope-model step 3',
    },
    wow = {
        root = HOME .. '/work/wow_addons',
        lang = 'lua', -- not a git repo: path-only identity, snapshot meta is the stamp
        notes = '353 addons / 2.27M lines — SCALE corpus; .toc load-order'
            .. ' adapter banked, whole-tree extract is a stress test not a gate',
    },
    desynced = {
        root = HOME .. '/work/desynced',
        lang = 'lua', -- not a git repo
        notes = 'game-script corpus; adapter gap banked',
    },
}
