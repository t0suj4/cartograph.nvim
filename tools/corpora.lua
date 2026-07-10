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
    ghost = {
        root = HOME .. '/git/ghost/ghost/core',
        repo = 'https://github.com/TryGhost/Ghost',
        rev = 'f7d7df8f9816',
        expected = { refs = 5840, nodes = 21128 }, -- calibrated @ require-imports (v22)
        lang = 'javascript',
        notes = 'js SCALE tier (2134 files) — a real node webapp: express'
            .. ' routes + handlebars themes (parametric-files territory)',
    },
    v8 = {
        root = HOME .. '/git/v8/src',
        repo = 'https://chromium.googlesource.com/v8/v8',
        rev = '0646faaada71',
        expected = { refs = 74413, nodes = 165859 }, -- calibrated @ js-corpora join (v22)
        lang = 'cpp',
        notes = 'cpp SCALE tier (1267 cc + 1813 h) — preprocessor-heavy,'
            .. ' the TU-walk torture target; .tq (torque) not spec\'d',
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
    jquery = {
        root = HOME .. '/git/jquery/src',
        repo = 'https://github.com/jquery/jquery',
        rev = 'b043db95042b',
        expected = { refs = 672, nodes = 581 }, -- calibrated @ js-corpora join
        lang = 'javascript',
        notes = 'js quick tier (115 ESM files); selector/event-name strings'
            .. ' = typed-string territory',
    },
    mootools = {
        root = HOME .. '/git/mootools-core/Source',
        repo = 'https://github.com/mootools/mootools-core',
        rev = '187a16bae2d7',
        expected = { refs = 334, nodes = 443 }, -- calibrated @ js-corpora join
        lang = 'javascript',
        notes = 'js archaeology tier (29 files, frozen 2017) — prototype-'
            .. 'extension culture, string-keyed dispatch',
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
        expected = { refs = 5232, nodes = 5078 }, -- recalibrated @ typed-strings v1 (eval heads)
        lang = 'bash',
        notes = 'bash SCALE tier (~420 files; a line editor written in bash —'
            .. ' eval-heavy, the aperture design\'s first real workout)',
    },

    -- ── stack languages (token provider — no tree-sitter substrate) ──
    postscript = {
        root = HOME .. '/git/postscript-examples',
        repo = 'https://github.com/jwaite/postscript-examples',
        rev = 'b6c8be09c600',
        expected = { refs = 0, nodes = 159 }, -- recalibrated @ ps depth fix (348 counted proc-local false defs)
        provider = 'tokens',
        lang = 'postscript',
        notes = 'postscript quick tier (43 files); inline only (no parallel'
            .. ' pipeline for the token provider)',
    },
    bwipp = {
        root = HOME .. '/git/postscriptbarcode',
        repo = 'https://github.com/bwipp/postscriptbarcode',
        rev = 'b22ce8fe921d',
        provider = 'tokens',
        lang = 'postscript',
        expected = { refs = 11, nodes = 1234 }, -- calibrated @ token-provider v1
        notes = 'postscript REAL tier (130 .ps.src encoders + examples) —'
            .. ' declared --REQUIRES manifests = declared-vs-derived bait;'
            .. ' findresource dispatch; inline only',
    },
    gforth = {
        root = HOME .. '/git/gforth',
        repo = 'https://git.savannah.gnu.org/git/gforth.git',
        rev = '0235f65b468a',
        expected = { refs = 33195, nodes = 21165 }, -- recalibrated @ dup-id fix (aliased edges split honest)
        provider = 'tokens',
        lang = 'forth',
        notes = 'forth mid tier (555 files) — the language\'s own kernel;'
            .. ' [IF] dup defs = candidate sets; inline only',
    },
    openfirmware = {
        root = HOME .. '/git/openfirmware',
        repo = 'https://github.com/openbios/openfirmware',
        rev = 'd1681c6293f6',
        expected = { refs = 67997, nodes = 48349 }, -- recalibrated @ dup-id fix; walk +52 only (fload paths ${BP}-templated, banked)
        provider = 'tokens',
        lang = 'forth',
        notes = 'forth SCALE tier (1804 .fth, 1.77M tokens) — the volume'
            .. ' discipline proof; inline only',
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
