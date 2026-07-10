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
        expected = { refs = 77109, nodes = 87241 }, -- calibrated @ step-4 return rounds
        notes = 'THE parity gate corpus (5x scale, 4843 files, ~55s extract)',
    },
    libs = {
        root = HOME .. '/git/elasticsearch/libs',
        repo = 'https://github.com/elastic/elasticsearch',
        rev = '4743238408a4',
        lang = 'java',
        expected = { refs = 10821, nodes = 13888 }, -- recalibrated @ bash-spec (.sh scripts join)
        notes = 'the small/fast java corpus (943 files, ~10s) — quick iteration',
    },
    -- ── per-language quick tier (libs-sized: seconds, calibrated, pinned) ──
    php = {
        root = HOME .. '/git/mantisbt/core',
        repo = 'https://github.com/mantisbt/mantisbt',
        rev = '821ce4ac9dab',
        expected = { refs = 6376, nodes = 2538 }, -- calibrated @ 098c537
        lang = 'php',
        notes = 'php quick tier (150 files); mantis events adapter banked',
    },
    sylius = {
        root = HOME .. '/git/sylius/src',
        repo = 'https://github.com/sylius/sylius',
        rev = '9b6799e2b884',
        expected = { refs = 5595, nodes = 32160 }, -- calibrated @ 098c537
        lang = 'php',
        notes = 'php SCALE tier (4636 files) — symfony adapter territory',
    },
    cpp = {
        root = HOME .. '/git/7kaa',
        repo = 'https://git.code.sf.net/p/skfans/7kaa',
        rev = '9e5cde1bc1d7',
        expected = { refs = 8016, nodes = 12144 }, -- recalibrated @ bash-spec (.sh scripts join)
        lang = 'cpp',
        notes = 'cpp quick tier (~325 cpp + 189 h); openmw is DIRTY — never pin it',
    },
    scheme = {
        root = HOME .. '/git/guile/module',
        repo = 'https://github.com/cky/guile',
        rev = '89ce9fb31b00',
        expected = { refs = 3596, nodes = 3288 }, -- calibrated @ 098c537
        lang = 'scheme',
        notes = 'scheme quick tier (280 files)',
    },
    ruby = {
        root = HOME .. '/git/rails/activesupport/lib',
        repo = 'https://github.com/rails/rails',
        rev = 'ed0f92c5e779',
        expected = { refs = 904, nodes = 2592 }, -- calibrated @ 098c537
        lang = 'ruby',
        notes = 'ruby quick tier (305 files)',
    },
    go = {
        root = HOME .. '/git/hugo',
        repo = 'https://github.com/gohugoio/hugo',
        rev = '5a5f4a549522',
        expected = { refs = 9526, nodes = 11624 }, -- recalibrated @ bash-spec (.sh scripts join)
        lang = 'go',
        notes = 'go quick tier (901 files)',
    },
    rust = {
        root = HOME .. '/git/ripgrep',
        repo = 'https://github.com/burntsushi/ripgrep',
        rev = '48b0c795f4fe',
        expected = { refs = 2455, nodes = 3360 }, -- recalibrated @ bash-spec (.sh scripts join)
        lang = 'rust',
        notes = 'rust quick tier (100 files)',
    },
    python = {
        root = HOME .. '/git/django-oscar/src',
        repo = 'https://github.com/django-oscar/django-oscar',
        rev = 'c0608e0d167e',
        expected = { refs = 1546, nodes = 3824 }, -- calibrated @ 098c537
        lang = 'python',
        notes = 'python quick tier (483 files) — the django adapter\'s home turf',
    },
    haskell = {
        root = HOME .. '/git/ghc/libraries/base',
        repo = 'https://github.com/ghc/ghc',
        rev = '8585f8cb561e',
        expected = { refs = 1560, nodes = 2805 }, -- calibrated @ 098c537
        lang = 'haskell',
        notes = 'haskell quick tier (515 files); ghc = the Track B reference repo',
    },
    bash = {
        root = HOME .. '/git/testssl.sh',
        repo = 'https://github.com/testssl/testssl.sh',
        rev = 'deda4c762768',
        expected = { refs = 822, nodes = 618 }, -- recalibrated @ torn-by-node + literal names
        lang = 'bash',
        notes = 'bash quick tier (~20 files, one giant sophisticated script)',
    },
    blesh = {
        root = HOME .. '/git/ble.sh',
        repo = 'https://github.com/akinomyoga/ble.sh.git',
        rev = '5d39ebe6db67',
        expected = { refs = 5231, nodes = 5078 }, -- recalibrated @ torn-by-node + literal names
        lang = 'bash',
        notes = 'bash SCALE tier (~420 files; a line editor written in bash —'
            .. ' eval-heavy, the aperture design\'s first real workout)',
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
