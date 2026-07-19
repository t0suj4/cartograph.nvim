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
        budget_mb = 3000, -- ~2x fresh-process inline peak @ new clock
        repo = 'https://github.com/elastic/elasticsearch',
        rev = '4743238408a4',
        lang = 'java',
        expected = { refs = 77127, nodes = 87241 }, -- +18 @ honesty pass v46 (stale baseline caught up on prior Java refused→resolved)
        notes = 'THE parity gate corpus (5x scale, 4843 files, ~55s extract)',
    },
    libs = {
        root = HOME .. '/git/elasticsearch/libs',
        repo = 'https://github.com/elastic/elasticsearch',
        rev = '4743238408a4',
        lang = 'java',
        expected = { refs = 10822, nodes = 13888 }, -- +1 @ generic Class<T> return (getLibrary(VectorLibrary.class))
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
        budget_mb = 1400, -- ~2x fresh-process inline peak @ new clock
        repo = 'https://github.com/sylius/sylius',
        rev = '9b6799e2b884',
        expected = { refs = 5595, nodes = 32160 }, -- calibrated @ 098c537
        lang = 'php',
        notes = 'php SCALE tier (4636 files) — symfony adapter territory',
    },
    grocy = {
        root = HOME .. '/git/grocy',
        repo = 'https://github.com/grocy/grocy',
        rev = '297cc5724441', -- PRE-FIX of #2259 (c415e2f) — the taint keystone
        expected = { refs = 1088, nodes = 1317 }, -- calibrated @ taint rung 2
        lang = 'php',
        notes = 'the TAINT keystone (Slim/PSR-7 + LessQL): both poles ground-'
            .. 'truth-validated — rung-2 fires on GetProductStockLocations (the '
            .. 'real SQLi), silent on the int-typed sibling; [[cartograph-taint-analysis]]',
    },
    cpp = {
        root = HOME .. '/git/7kaa',
        repo = 'https://git.code.sf.net/p/skfans/7kaa',
        rev = '9e5cde1bc1d7',
        expected = { refs = 8017, nodes = 12144 }, -- +1 @ v48 short-name honesty (same-file sq)
        lang = 'cpp',
        notes = 'cpp quick tier (~325 cpp + 189 h); openmw is DIRTY — never pin it',
    },
    ghost = {
        root = HOME .. '/git/ghost/ghost/core',
        budget_mb = 1600, -- ~2x fresh-process inline peak @ new clock
        repo = 'https://github.com/TryGhost/Ghost',
        rev = 'f7d7df8f9816',
        expected = { refs = 21048, nodes = 39867 }, -- +anon callback fns @ v51 (df-strangler B; ~18.7k #cb nodes)
        lang = 'javascript',
        notes = 'js SCALE tier (2134 files) — a real node webapp: express'
            .. ' routes + handlebars themes (parametric-files territory)',
    },
    v8 = {
        root = HOME .. '/git/v8/src',
        budget_mb = 7500, -- ~2x fresh-process inline peak @ new clock
        repo = 'https://chromium.googlesource.com/v8/v8',
        rev = '0646faaada71',
        expected = { refs = 74420, nodes = 165859 }, -- +7 @ v48 short-name honesty (V/I/T/F macro helpers)
        lang = 'cpp',
        notes = 'cpp SCALE tier (1267 cc + 1813 h) — preprocessor-heavy,'
            .. ' the TU-walk torture target; .tq (torque) not spec\'d',
    },
    scheme = {
        root = HOME .. '/git/guile/module',
        repo = 'https://github.com/cky/guile',
        rev = '89ce9fb31b00',
        expected = { refs = 3601, nodes = 3288 }, -- +5 @ v48 short-name honesty (scheme's ??/>>/vv culture)
        lang = 'scheme',
        notes = 'scheme quick tier (280 files)',
    },
    ruby = {
        root = HOME .. '/git/rails/activesupport/lib',
        repo = 'https://github.com/rails/rails',
        rev = 'ed0f92c5e779',
        expected = { refs = 1590, nodes = 2791 }, -- recalibrated @ R5b-ivar (v78)
        lang = 'ruby',
        notes = 'ruby quick tier (305 files) — BASE ruby, no framework pack',
    },
    rails = {
        root = HOME .. '/git/discourse/app/models',
        repo = 'https://github.com/discourse/discourse',
        rev = '28b003a38d82',
        expected = { refs = 2615, nodes = 4916 }, -- recalibrated @ R5b-ivar (v78)
        lang = 'ruby',
        packs = { 'rails' }, -- the rails overlay pack (assoc/delegate emitters
                             -- + ActiveRecord vocab) composed onto base ruby
        notes = 'rails overlay pack (discourse app/models, 369 files)',
    },
    rspec = {
        root = HOME .. '/git/discourse/spec/models',
        repo = 'https://github.com/discourse/discourse',
        rev = '28b003a38d82',
        expected = { refs = 13, nodes = 515 },
        lang = 'ruby',
        packs = { 'rails', 'rspec' }, -- MULTI-PACK composition (the de-risker):
                                      -- rails + the rspec/factory_bot test-DSL
        notes = 'rspec test-DSL pack + multi-pack composition (discourse '
            .. 'spec/models, 196 files) — DSL is framework-refused; low '
            .. 'resolution is honest (specs are framework-dominated)',
    },
    go = {
        root = HOME .. '/git/hugo',
        repo = 'https://github.com/gohugoio/hugo',
        rev = '5a5f4a549522',
        expected = { refs = 9575, nodes = 11709 }, -- +7/+2 @ v63 B4 prototype methods (embedded HugoReload.prototype.reload); +1 @ v59 class-keying (LRUCache.put)
        lang = 'go',
        notes = 'go quick tier (901 files)',
    },
    rust = {
        root = HOME .. '/git/ripgrep',
        repo = 'https://github.com/burntsushi/ripgrep',
        rev = '48b0c795f4fe',
        expected = { refs = 2593, nodes = 3360 }, -- +125 catch-up @ v59 re-gate: PRE-EXISTING v55 module-alias drift (NOT js class-keying — rust has no JS; baseline was last pinned @ v48, v55 never re-gated here)
        lang = 'rust',
        notes = 'rust quick tier (100 files)',
    },
    zig = {
        root = HOME .. '/git/zig/src',
        budget_mb = 3800, -- ~2x inline peak: the compiler files are enormous
        repo = 'https://github.com/ziglang/zig',
        rev = 'd5181a9c9bac',
        expected = { refs = 20242, nodes = 9408 }, -- recalibrated @ zig local field-access typing (v86)
        lang = 'zig',
        notes = 'zig + R5 receiver typing + @import module binding + value-recv '
            .. 'dual-key + multi-level chain type + instance-chain field typing '
            .. '(the self-hosted compiler, 171 files) — procedural+struct+method '
            .. 'family; `recv.method()` keyed Type.method from the pointer '
            .. 'receiver\'s type, `const Foo=@import("f.zig")` binds Foo.member() '
            .. 'to f.zig, a value-receiver method gains a Foo.m dual key, a chain '
            .. '`root.Type.method()` resolves via its PascalCase penultimate type, '
            .. 'and an instance chain `root.field.method()` resolves via struct '
            .. 'field types (file-bound), and a local `const x=param.field; '
            .. 'x.method()` resolves via one hop of local type inference (41.8% '
            .. 'resolved). Remaining: deeper local typing (call-return chains) + '
            .. 'generic field types',
    },
    odin = {
        root = HOME .. '/git/odin/core',
        budget_mb = 2000, -- ~2x inline peak
        repo = 'https://github.com/odin-lang/Odin',
        rev = '967c6046a624',
        expected = { refs = 17182, nodes = 37121 }, -- calibrated @ odin v1 (v80)
        lang = 'odin',
        notes = 'odin v1 (the core stdlib, 1279 files) — C/procedural family, '
            .. 'no methods; 15.7% (package-heavy — the package-qualified '
            .. 'resolution arc, Odin-R1, is where it climbs; banked, not built)',
    },
    python = {
        root = HOME .. '/git/django-oscar/src',
        repo = 'https://github.com/django-oscar/django-oscar',
        rev = 'c0608e0d167e',
        expected = { refs = 1571, nodes = 3872 }, -- +enclosing-chain captured-callable wins @ v51
        lang = 'python',
        notes = 'python quick tier (483 files) — the django adapter\'s home turf',
    },
    haskell = {
        root = HOME .. '/git/ghc/libraries/base',
        repo = 'https://github.com/ghc/ghc',
        rev = '8585f8cb561e',
        expected = { refs = 1571, nodes = 2805 }, -- +11 @ v48 short-name honesty (ghc test snippets' 1-char fns)
        lang = 'haskell',
        notes = 'haskell quick tier (515 files); ghc = the Track B reference repo',
    },
    jquery = {
        root = HOME .. '/git/jquery/src',
        repo = 'https://github.com/jquery/jquery',
        rev = 'b043db95042b',
        expected = { refs = 1029, nodes = 811 }, -- +anon callback fns @ v51 (df-strangler B; +257 #cb nodes)
        lang = 'javascript',
        notes = 'js quick tier (115 ESM files); selector/event-name strings'
            .. ' = typed-string territory',
    },
    mootools = {
        root = HOME .. '/git/mootools-core/Source',
        repo = 'https://github.com/mootools/mootools-core',
        rev = '187a16bae2d7',
        expected = { refs = 399, nodes = 545 }, -- +9/+3 @ v63 B4 prototype methods (Function.prototype.overloadSetter/String.prototype.contains)
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
        expected = { refs = 5260, nodes = 5078 }, -- +28 @ v48 short-name honesty (memo f1..fA chains)
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
        budget_mb = 1200, -- ~2x fresh-process inline peak @ new clock
        repo = 'https://github.com/openbios/openfirmware',
        rev = 'd1681c6293f6',
        expected = { refs = 67997, nodes = 48349 }, -- recalibrated @ dup-id fix; walk +52 only (fload paths ${BP}-templated, banked)
        provider = 'tokens',
        lang = 'forth',
        notes = 'forth SCALE tier (1804 .fth, 1.77M tokens) — the volume'
            .. ' discipline proof; inline only',
    },

    -- ── SYNTHETIC corpora (tools/gen.lua) ───────────────────────────────
    -- Identity = (GEN_VERSION, lang, seed, files) — deterministic, byte-
    -- reproducible, no checkout to pin. The root path EMBEDS g<genversion>-
    -- s<seed>: a generator change bumps GEN_VERSION → new paths here + a
    -- recalibration, the same discipline as expected counts. bench.corpus
    -- MATERIALIZES a missing root by running the generator — so these
    -- gates run on any machine, no ~/git checkouts required.
    synlua = {
        root = HOME .. '/.cache/cartograph-tools/syn/lua-g5-s1',
        synthetic = { lang = 'lua', seed = 1, files = 8 },
        lang = 'lua',
        expected = { refs = 102, nodes = 203 }, -- recalibrated @ gen v5 (+registry idiom + RNG shift)
        notes = 'synthetic lua (gen.lua g2 seed 1): the resolution-ladder'
            .. ' bestiary — fwd-decls, fn-values, higher-order, shadows,'
            .. ' smt classes, requires, goto',
    },
    synjava = {
        root = HOME .. '/.cache/cartograph-tools/syn/java-g5-s1',
        synthetic = { lang = 'java', seed = 1, files = 8 },
        lang = 'java',
        expected = { refs = 47, nodes = 87 }, -- calibrated @ gen v3, byte-identical @ v4
        notes = 'synthetic java (gen.lua g2 seed 1): @Service impls = the'
            .. ' ONLY locally-testable F1 bean redirects; unique Builder<k>'
            .. ' chains = the positive rt-rounds path; enums, overloads,'
            .. ' method refs, cross-file',
    },

    synjs = {
        root = HOME .. '/.cache/cartograph-tools/syn/js-g5-s1',
        synthetic = { lang = 'js', seed = 1, files = 8 },
        lang = 'javascript',
        expected = { refs = 154, nodes = 283 }, -- +6 @ v64 V2 ctor-typing (obj=new C → obj.calc→C.calc); +6 @ v62 B3 this.getv
        notes = 'synthetic js (gen.lua g4 seed 1): hoisted fwd calls,'
            .. ' fn-value consts, let/var regimes, arrows, classes, ESM +'
            .. ' one CommonJS module, and min.js — a one-line minified'
            .. ' module (the (l,c) column-spill exercise)',
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
    factorio = {
        root = HOME .. '/work/factorio-mods',
        lang = 'lua', -- symlink-assembled multi-mod root (SE + postprocess
        -- + scripts + bravest-new-world) — the CROSS-PROJECT corpus:
        -- __modname__ requires resolve by info.json identity across mods
        notes = 'factorio multi-mod: cross-mod imports (scripts->SE x9),'
            .. ' mod dirs = scope boundaries, per-phase entry cones',
    },
    se = {
        root = HOME .. '/work/space-exploration_0.7.57',
        lang = 'lua', -- version-pinned mod dir, not a git repo
        notes = 'Space Exploration 0.7.57 — the FACTORIO reference corpus:'
            .. ' 5 phase entries (control/data/updates/final-fixes/settings),'
            .. ' phase cones separate via imports (2 shared files), unreached'
            .. ' = conditional compat requires + menu-simulations engine'
            .. ' entries; the factorio sharing-model cut lands here',
    },
}
