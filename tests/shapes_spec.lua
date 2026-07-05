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

test('shapes: the explainer shows hits, misses and overrides', function ()
    local root = mkroot({ ['manage.py'] = '' })
    local blob = table.concat(shapes.explain(root), '\n')
    ok(blob:match('✓ django'), blob)
    ok(blob:match('· factorio%-mod'), 'misses shown')
    ok(blob:match('inert hints'), 'doctrine stated')
    vim.fn.delete(root, 'rf')
end)
