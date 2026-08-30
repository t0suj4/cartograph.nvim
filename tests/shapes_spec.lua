-- Project-shape detection: markers preset inert hints, user config
-- wins, one root's presets never leak into the next root's open.

local shapes = require 'cartograph.shapes'
local cfg = require 'cartograph.config'

local function mkroot(files)
    local root = vim.fn.tempname()
    for rel, text in pairs(files) do
        local dir = (root .. '/' .. rel):match('^(.*)/[^/]*$')
        vim.fn.mkdir(dir, 'p')
        local fd = assert(io.open(root .. '/' .. rel, 'w'))
        fd:write(text)
        fd:close()
    end
    return root
end

local function names(applied)
    local t = {}
    for _, s in ipairs(applied) do t[#t + 1] = s.name end
    table.sort(t)
    return t
end

test('shapes: factorio markers preset the lifecycle', function ()
    local root = mkroot({ ['info.json'] = '{}', ['control.lua'] = '',
        ['data.lua'] = '' })
    local applied = shapes.apply(root)
    eq({ 'factorio-mod' }, names(applied))
    ok(vim.tbl_contains(cfg.entrypoints, 'control%.lua$'), 'lifecycle added')
    ok(vim.tbl_contains(cfg.entrypoints, 'main%.[%w]+$'), 'generic default kept')
    vim.fn.delete(root, 'rf')
end)

test('shapes: the node manifest NAMES its entry points', function ()
    local root = mkroot({ ['package.json'] =
        '{"main": "./lib/index.js", "bin": {"tool": "cli.js"}}' })
    shapes.apply(root)
    ok(vim.tbl_contains(cfg.entrypoints, '^lib/index%.js$'), 'main read')
    ok(vim.tbl_contains(cfg.entrypoints, '^cli%.js$'), 'bin read')
    vim.fn.delete(root, 'rf')
end)

test('shapes: one root never leaks into the next', function ()
    local fac = mkroot({ ['info.json'] = '{}', ['control.lua'] = '',
        ['data.lua'] = '' })
    local dj = mkroot({ ['manage.py'] = '' })
    shapes.apply(fac)
    ok(vim.tbl_contains(cfg.entrypoints, 'control%.lua$'))
    shapes.apply(dj)
    ok(not vim.tbl_contains(cfg.entrypoints, 'control%.lua$'),
        'factorio preset stripped')
    ok(vim.tbl_contains(cfg.entrypoints, 'manage%.py$'), 'django preset on')
    shapes.apply(vim.fn.tempname()) -- a root with no markers: all stripped
    ok(not vim.tbl_contains(cfg.entrypoints, 'manage%.py$'))
    vim.fn.delete(fac, 'rf')
    vim.fn.delete(dj, 'rf')
end)

test('shapes: explicit setup{} wins over detection', function ()
    local root = mkroot({ ['manage.py'] = '' })
    local saved_eps, saved_user = cfg.entrypoints, cfg.user_set
    cfg.entrypoints = { 'mine%.py$' }
    cfg.user_set = { entrypoints = true }
    local applied = shapes.apply(root)
    eq({ 'django' }, names(applied)) -- detected, reported…
    eq({ 'mine%.py$' }, cfg.entrypoints) -- …but the user's list untouched
    cfg.entrypoints, cfg.user_set = saved_eps, saved_user
    vim.fn.delete(root, 'rf')
end)

test('shapes: ansible collection, python package, haskell', function ()
    -- an Ansible COLLECTION (galaxy.yml + plugins/) — distinct from a role
    local coll = mkroot({ ['galaxy.yml'] = 'namespace: x',
        ['plugins/modules/foo.py'] = '' })
    eq({ 'ansible-collection' }, names(shapes.apply(coll)))
    ok(vim.tbl_contains(cfg.entrypoints, '^plugins/modules/.*%.py$'),
        'plugin modules are entry points')
    vim.fn.delete(coll, 'rf')

    -- a Python package excludes the NON-dotted venv/__pycache__ (.venv is
    -- already skipped by the dotfile rule)
    local py = mkroot({ ['pyproject.toml'] = '', ['setup.py'] = '' })
    shapes.apply(py)
    ok(vim.tbl_contains(cfg.exclude or {}, 'venv'), 'venv excluded')
    ok(vim.tbl_contains(cfg.exclude or {}, '__pycache__'), '__pycache__ excluded')
    ok(vim.tbl_contains(cfg.entrypoints, '^setup%.py$'), 'setup.py entry')
    vim.fn.delete(py, 'rf')

    -- Haskell via a <pkg>.cabal marker; dist-newstyle excluded
    local hs = mkroot({ ['acme.cabal'] = '', ['app/Main.hs'] = '' })
    eq({ 'haskell' }, names(shapes.apply(hs)))
    ok(vim.tbl_contains(cfg.exclude or {}, 'dist-newstyle'), 'dist-newstyle excluded')
    ok(vim.tbl_contains(cfg.entrypoints, 'Main%.hs$'), 'Main.hs entry')
    vim.fn.delete(hs, 'rf')

    -- GHC's hadrian layout (no root .cabal) also reads as haskell
    local ghc = mkroot({ ['hadrian/Build.hs'] = '', ['ghc/Main.hs'] = '' })
    eq({ 'haskell' }, names(shapes.apply(ghc)))
    vim.fn.delete(ghc, 'rf')

    shapes.apply(vim.fn.tempname()) -- a markerless root: strip all presets
end)

test('shapes: rust, go, jvm build dirs and entry points', function ()
    -- Rust excludes target/ (huge build dir, not globally excluded); crate
    -- roots match unanchored (ripgrep's crates/core/main.rs isn't under src/)
    local rs = mkroot({ ['Cargo.toml'] = '', ['crates/core/main.rs'] = '' })
    eq({ 'rust' }, names(shapes.apply(rs)))
    ok(vim.tbl_contains(cfg.exclude or {}, 'target'), 'rust target excluded')
    ok(vim.tbl_contains(cfg.entrypoints, 'main%.rs$'), 'crate main entry')
    vim.fn.delete(rs, 'rf')

    -- Go: package-main files are entry points (vendor already excluded)
    local go = mkroot({ ['go.mod'] = 'module x', ['main.go'] = '' })
    eq({ 'go' }, names(shapes.apply(go)))
    ok(vim.tbl_contains(cfg.entrypoints, 'main%.go$'), 'go main entry')
    vim.fn.delete(go, 'rf')

    -- Maven excludes target/; Gradle also detects (build/ already global)
    local mvn = mkroot({ ['pom.xml'] = '' })
    eq({ 'jvm' }, names(shapes.apply(mvn)))
    ok(vim.tbl_contains(cfg.exclude or {}, 'target'), 'maven target excluded')
    ok(vim.tbl_contains(cfg.entrypoints, 'Application%.java$'), 'spring entry')
    vim.fn.delete(mvn, 'rf')
    local gr = mkroot({ ['build.gradle'] = '' })
    eq({ 'jvm' }, names(shapes.apply(gr)))
    vim.fn.delete(gr, 'rf')

    shapes.apply(vim.fn.tempname()) -- strip presets
end)

-- UP-direction ([[cartograph-repo-shapes]]): a sub-root inside a shaped repo
-- inherits its L2 profile — the marker can be levels above the extraction root.
test('shapes.profile_for: a sub-root inherits the ancestor shape profile', function ()
    -- a Rails app: config/application.rb at the top, .git marking the repo root,
    -- and an app/models sub-dir we extract from (the discourse/app/models shape)
    local root = mkroot({ ['config/application.rb'] = 'module A; end',
        ['.git/HEAD'] = 'ref: x', ['app/models/post.rb'] = 'class Post; end' })
    local at_sub = shapes.profile_for(root .. '/app/models')
    ok(at_sub and at_sub.profile == 'ruby-rails', 'sub-root sees the ancestor rails profile')
    ok(at_sub and at_sub.inherited, 'flagged inherited (marker is up the tree)')
    ok(at_sub and at_sub.dir == root, 'attributed to the repo root dir')
    local at_root = shapes.profile_for(root)
    ok(at_root and at_root.profile == 'ruby-rails' and not at_root.inherited,
        'at the root itself it is a direct (non-inherited) match')
    vim.fn.delete(root, 'rf')
end)

test('shapes.profile_for: the .git boundary stops the walk (no cross-repo leak)', function ()
    -- an OUTER dir carrying the rails marker, an INNER repo (its own .git) with
    -- NO marker, and a sub-dir inside inner. Walking up from inner/app must STOP
    -- at inner's .git and never reach outer's config/application.rb.
    local outer = mkroot({ ['config/application.rb'] = 'module A; end',
        ['inner/.git/HEAD'] = 'ref: x', ['inner/app/x.rb'] = 'class X; end' })
    local pf = shapes.profile_for(outer .. '/inner/app')
    ok(pf == nil, 'the framework-source / cross-repo boundary is respected (nil)')
    vim.fn.delete(outer, 'rf')
end)

test('shapes.profile_for: a markerless tree yields no profile', function ()
    local root = mkroot({ ['app/models/x.rb'] = 'class X; end' })
    ok(shapes.profile_for(root .. '/app/models') == nil, 'no marker anywhere → nil')
    vim.fn.delete(root, 'rf')
end)

-- S2 ([[cartograph-repo-shapes]]): shape-activated PACKS, same UP-walk as profiles.
test('shapes.packs_for: a Rails sub-root inherits the pack from the ancestor shape', function ()
    local root = mkroot({ ['config/application.rb'] = 'module A; end',
        ['.git/HEAD'] = 'ref: x', ['app/models/post.rb'] = 'class Post; end' })
    eq({ 'rails' }, shapes.packs_for(root .. '/app/models'))
    eq({ 'rails' }, shapes.packs_for(root)) -- and at the root itself
    vim.fn.delete(root, 'rf')
end)

test('shapes.packs_for: the .git boundary fences a framework-source parent', function ()
    -- outer carries the app marker; inner is its own repo (.git) with none — a
    -- framework-source layout. Walking up from inner must NOT reach outer's marker.
    local outer = mkroot({ ['config/application.rb'] = 'module A; end',
        ['inner/.git/HEAD'] = 'ref: x', ['inner/lib/x.rb'] = 'class X; end' })
    eq({}, shapes.packs_for(outer .. '/inner/lib'))
    vim.fn.delete(outer, 'rf')
end)

test('shapes.packs_for: a markerless tree activates no pack', function ()
    local root = mkroot({ ['lib/x.rb'] = 'class X; end' })
    eq({}, shapes.packs_for(root .. '/lib'))
    vim.fn.delete(root, 'rf')
end)

-- CART-0218: profile_for and packs_for are ONE walk with three DECLARED differences.
-- What needs pinning is that the two COMBINING RULES stay distinct (they were only
-- implicit before) and that both carry their inverse.
test('shapes.select_env: the two combining rules are declared, and both invert',
    function ()
    local root = mkroot({ ['config/application.rb'] = 'module A; end',
        ['.git/HEAD'] = 'ref: x', ['app/models/post.rb'] = 'class Post; end' })
    local sub = root .. '/app/models'

    -- NEAREST: one answer, and it names the directory + evidence that produced it
    local prof = shapes.select_env(sub, 'profile')
    ok(prof, 'a rails app selects a profile')
    eq('ruby-rails', prof.value)
    eq(root, prof.dir, 'the ANCESTOR that matched, not the queried root')
    ok(prof.inherited, 'and it says the answer was inherited')
    ok(prof.evidence and #prof.evidence > 0, 'with the evidence, not just a verdict')

    -- UNION: a set, plus the inverse packs_for could not answer before
    local packs = shapes.select_env(sub, 'packs')
    eq({ 'rails' }, packs.values)
    ok(packs.by['rails'], 'THE INVERSE: which shape activated this pack')
    eq(root, packs.by['rails'].dir)
    eq('rails', packs.by['rails'].name)

    -- and packs_for still hands back a BARE list: it is serialized into worker opts,
    -- so a stowaway field would ride over the wire
    local plain = shapes.packs_for(sub)
    eq({ 'rails' }, plain)
    eq(nil, plain.by, 'no inverse smuggled into the serialized list')

    -- an unknown axis is a programming error, not a silent empty answer
    ok(not pcall(shapes.select_env, sub, 'nope'), 'an unknown axis refuses loudly')
    vim.fn.delete(root, 'rf')
end)

test('shapes.select_env: an unshaped root answers per its combining rule', function ()
    local root = mkroot({ ['lib/x.rb'] = 'class X; end' })
    eq(nil, shapes.select_env(root .. '/lib', 'profile'), 'NEAREST with no match = nil')
    local packs = shapes.select_env(root .. '/lib', 'packs')
    eq({}, packs.values, 'UNION with no match = the empty set, never nil')
    eq({}, packs.by, 'and the inverse is empty rather than absent')
    -- a non-string root is the same story, per rule
    eq(nil, shapes.select_env(nil, 'profile'))
    eq({}, shapes.select_env(nil, 'packs').values)
    vim.fn.delete(root, 'rf')
end)

test('shapes: the explainer shows hits, misses and overrides', function ()
    local root = mkroot({ ['manage.py'] = '' })
    local blob = table.concat(shapes.explain(root), '\n')
    ok(blob:match('✓ django'), blob)
    ok(blob:match('· factorio%-mod'), 'misses shown')
    ok(blob:match('inert hints'), 'doctrine stated')
    vim.fn.delete(root, 'rf')
end)

test('shapes: the explainer names an UP-inherited profile (and survives a scalar config)', function ()
    -- a factorio root DIRECTLY carries config.profile (scalar) — the explainer
    -- must print it, not crash on table.concat of a string
    local fac = mkroot({ ['info.json'] = '{}', ['control.lua'] = '',
        ['data.lua'] = '' })
    local facblob = table.concat(shapes.explain(fac), '\n')
    ok(facblob:match('profile: lua%-factorio'), 'scalar profile config shown')
    vim.fn.delete(fac, 'rf')
    -- a sub-root inheriting a rails profile from an ancestor
    local root = mkroot({ ['config/application.rb'] = 'module A; end',
        ['.git/HEAD'] = 'ref: x', ['app/models/post.rb'] = 'class Post; end' })
    local blob = table.concat(shapes.explain(root .. '/app/models'), '\n')
    ok(blob:match('↑ profile ruby%-rails inherited'), 'UP-inherited profile explained')
    vim.fn.delete(root, 'rf')
end)

-- ── THE PROFILE OVERRIDE (CART-0217) ────────────────────────────────────────
-- The packs axis has always had a DISPOSE doctrine (explicit opts.packs wins, and
-- `{}` means none); the profile axis never did. These pin the doctrine, the fence
-- on an unusable name, and — most importantly — that an override cannot poison the
-- root's cache, which is the part that would rot silently.

local pm = require 'cartograph.spec.profile'

test('profile.env_usable: an INGREDIENT or a typo is refused, with the reason',
    function ()
    local prof, err = pm.env_usable('lua-factorio')
    ok(prof, 'a real environment profile is usable: ' .. tostring(err))
    eq('lua', prof.lang)

    -- a distilled runtime-api / prototype-api artifact is an INPUT to a hand
    -- profile, not an environment. Naming one by string is exactly how an
    -- ingredient became a portability target and reported "0 LOST" (CART-0209).
    -- THE MARKER ALONE IS NOT ENOUGH, and this loop is what proved it: the proto
    -- artifacts declare `ingredient`, but the three OLDER runtime-api artifacts
    -- predate the marker and carry 3 free functions each — enough to pass any
    -- "claims some names" test. The positive namespace/type requirement is what
    -- catches those.
    for _, ing in ipairs({ 'lua-factorio-api', 'lua-factorio-api-11',
        'lua-factorio-api-20', 'lua-factorio-proto-11', 'lua-factorio-proto-20' }) do
        if pm.load(ing) then
            local p2, e2 = pm.env_usable(ing)
            eq(nil, p2 and true or nil, ing .. ' must be refused as an environment')
            ok(e2 and (e2:find('INGREDIENT') or e2:find('no namespace or type surface')),
                'and say why: ' .. tostring(e2))
        end
    end
    -- ruby-core is refused too, and that is CORRECT: it is the RBS signature-keyed
    -- artifact, documented as not name-queryable, and as an extraction environment it
    -- would disposition nothing. Pinned so nobody "fixes" it into one.
    if pm.load('ruby-core') then
        eq(nil, (pm.env_usable('ruby-core')) and true or nil,
            'a signature-keyed artifact is not an environment')
    end
    -- while every real environment profile passes
    for _, envn in ipairs({ 'luajit', 'ruby-rails', 'zig-std', 'cruby',
        'lua-factorio-11' }) do
        if pm.load(envn) then
            local p4, e4 = pm.env_usable(envn)
            ok(p4, envn .. ' is a usable environment: ' .. tostring(e4))
        end
    end
    local p3, e3 = pm.env_usable('no-such-profile-at-all')
    eq(nil, p3, 'a typo is refused')
    ok(e3 and e3:find('no profile named'), 'named, so it is actionable')
    eq(nil, pm.env_usable(nil), 'and a non-name is not a profile')
end)

test('profile override: a name DISPOSES of the shape, and false means NONE',
    function ()
    local ts = require 'cartograph.providers.treesitter'
    if not pcall(vim.treesitter.language.add, 'lua') then skip 'no lua parser' end
    -- an UNSHAPED root: the shape activates nothing, so any profile here is the
    -- override's doing
    local plain = mkroot({ ['m.lua'] = 'local function f() end\nreturn f\n' })
    eq(nil, shapes.profile_for(plain), 'no shape, so no profile is detected')
    local d0 = ts.extract(plain)
    eq(nil, d0.profile, 'and the graph records none')
    local d1 = ts.extract(plain, { profile = 'lua-factorio' })
    eq('lua-factorio', d1.profile, 'the override activates it anyway')

    -- a SHAPED root: factorio-mod detects lua-factorio, and `false` disposes of it
    local fac = mkroot({ ['info.json'] = '{}', ['control.lua'] = 'game.print("x")',
        ['data.lua'] = 'data.extend{{}}' })
    local det = ts.extract(fac)
    eq('lua-factorio', det.profile, 'the shape activates it')
    local none = ts.extract(fac, { profile = false })
    eq(nil, none.profile,
        '`false` is the {} of this axis: explicit NONE, not "detect"')

    -- and an unusable name ERRORS rather than quietly falling back to detection —
    -- a silent fallback means a typo changes how a graph resolves while reporting
    -- success
    local okc, e = pcall(ts.extract, fac, { profile = 'no-such-profile' })
    eq(false, okc, 'refused')
    ok(tostring(e):find('profile override'), 'and says it was the override: ' .. tostring(e))
    vim.fn.delete(plain, 'rf'); vim.fn.delete(fac, 'rf')
end)

test('profile override: an overridden graph does NOT populate the root cache',
    function ()
    local ts = require 'cartograph.providers.treesitter'
    local cachem = require 'cartograph.cache'
    if not pcall(vim.treesitter.language.add, 'lua') then skip 'no lua parser' end
    if cfg.cache == false then skip 'cache disabled' end
    -- THE POISONING THIS PREVENTS: the read gate compares a manifest's profile with
    -- the SHAPE-derived one, so an overridden graph can never be served warm — but
    -- without this guard it would still be WRITTEN, clobbering the shape-derived
    -- cache so the next ordinary open re-extracts cold.
    local fac = mkroot({ ['info.json'] = '{}', ['control.lua'] = 'game.print("x")',
        ['data.lua'] = 'data.extend{{}}' })
    local dir = cachem.path(fac)

    local over = ts.extract(fac, { profile = false }) -- disagrees with the shape
    cachem.save(over)
    eq(0, vim.fn.filereadable(dir .. '/manifest.bin'),
        'nothing was written for a graph whose profile is not the shape\'s')

    local det = ts.extract(fac) -- agrees with the shape
    cachem.save(det)
    eq(1, vim.fn.filereadable(dir .. '/manifest.bin'),
        'while the ordinary graph persists exactly as before')
    vim.fn.delete(dir, 'rf'); vim.fn.delete(fac, 'rf')
end)

-- ── THE ENTRY-POINT PAIR (CART-0635) ────────────────────────────────────────

test('factorio shape: every engine entry point detects, not just control/data',
    function ()
    local sh = require 'cartograph.shapes'
    local entry
    for _, e in ipairs(sh.registry) do if e.name == 'factorio-mod' then entry = e end end
    ok(entry ~= nil, 'the shape is registered')
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local function w(rel)
        local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write('-- x\n'); fd:close()
    end
    w('info.json')
    eq(nil, entry.detect(root), 'info.json alone is an asset pack, not a code mod')
    -- ⚠ THE REGRESSION THIS EXISTS FOR: `Squeak Through` ships data-updates.lua and
    -- NO data.lua, and its entire job is rewriting collision boxes. The old detector
    -- asked for `control.lua or data.lua`, so the shape never matched, the profile
    -- never activated, and a pure data-stage mod reported "no data stage here".
    w('data-updates.lua')
    local ev = entry.detect(root)
    ok(ev ~= nil, 'data-updates.lua alone is a factorio mod')
    ok(ev:find('data-updates.lua', 1, true) ~= nil,
        'and the evidence NAMES the file that matched: ' .. tostring(ev))
    vim.fn.delete(root, 'rf')
    -- settings-only is a DELIBERATE yes: mod-setting prototypes are prototypes
    local r2 = vim.fn.tempname(); vim.fn.mkdir(r2, 'p')
    local fd = assert(io.open(r2 .. '/info.json', 'w')); fd:write('{}'); fd:close()
    fd = assert(io.open(r2 .. '/settings.lua', 'w')); fd:write('-- x'); fd:close()
    ok(entry.detect(r2) ~= nil, 'a settings-only mod is a factorio mod')
    vim.fn.delete(r2, 'rf')
end)

test('factorio shape: the entry list agrees with the PROFILE stage table',
    function ()
    -- ★★ THE FENCE FOR THE ACTUAL BUG. This fact lived in three places — the
    -- detector, the shape's entrypoints, and the profile's STAGES — and only the
    -- short copy was load-bearing. The first two now derive from one list; this
    -- checks the third against it, so the remaining pair cannot drift silently.
    -- WHEN AN ECOSYSTEM FACT IS WRITTEN TWICE, FIXING ONE COPY LEAVES A BUG THAT
    -- LOOKS LIKE THE ORIGINAL WAS NEVER FIXED.
    local sh = require 'cartograph.shapes'
    local ok_p, prof = pcall(require, 'cartograph.spec.profile.lua-factorio')
    if not ok_p or not prof._stagedefs then skip 'no lua-factorio stage defs' end
    local from_shape = {}
    for _, f in ipairs(sh.FACTORIO_ENTRY) do from_shape[f] = true end
    local missing = {}
    for _, st in ipairs(prof._stagedefs) do
        for _, pat in ipairs(st.entry or {}) do
            -- the ROOT-ANCHORED forms name a file the engine loads by name; the
            -- `/`-prefixed twins are the same file one directory down (a multi-mod
            -- root) and carry no new name
            local f = pat:match('^%^(.+)%$$')
            if f then
                f = f:gsub('%%', '')
                -- migration scripts are an entry point but not a ROOT marker: the
                -- engine loads migrations/<x>.lua by directory, so a mod can carry
                -- them with no root file, and requiring one would shape nothing new
                if not f:find('/') and not from_shape[f] then
                    missing[#missing + 1] = f
                end
            end
        end
    end
    eq({}, missing,
        'the profile declares a root stage entry the shape detector does not know: '
        .. table.concat(missing, ', '))
end)
