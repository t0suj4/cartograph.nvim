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

test('shapes: the explainer shows hits, misses and overrides', function ()
    local root = mkroot({ ['manage.py'] = '' })
    local blob = table.concat(shapes.explain(root), '\n')
    ok(blob:match('✓ django'), blob)
    ok(blob:match('· factorio%-mod'), 'misses shown')
    ok(blob:match('inert hints'), 'doctrine stated')
    vim.fn.delete(root, 'rf')
end)
