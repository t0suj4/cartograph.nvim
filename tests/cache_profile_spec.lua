-- Cache × PROFILE IDENTITY ([[cartograph-repo-shapes]] stamping gap): the manifest
-- now persists the active L2 profile (name + artifact stamp) and packs, and a warm
-- load INVALIDATES when the root's current profile no longer matches (a shape/
-- registry change activates a different profile, or the artifact was edited). It
-- also RESTORES packs+profile so a refresh on a warm graph relinks with the same
-- context. Profileless roots (the common case) round-trip unchanged.

local cache = require 'cartograph.cache'
local config = require 'cartograph.config'

local R = { start = { line = 1, char = 0 }, ['end'] = { line = 1, char = 3 } }

local function graph(root, extra)
    local g = {
        schema = 1, root = root, provider = 'test',
        stamps = { ['a.rb'] = 'sA' },
        nodes = {
            { id = 'a.rb', name = 'a.rb', kind = 'module', file = 'a.rb', order = -1, range = R },
            { id = 'a.rb::f@1', name = 'f', kind = 'function', file = 'a.rb', order = 1, range = R },
        },
        edges = {}, calls = {}, names = {},
    }
    for k, v in pairs(extra or {}) do g[k] = v end
    return g
end

local function mark_rails(root)
    vim.fn.mkdir(root .. '/config', 'p')
    local fd = assert(io.open(root .. '/config/application.rb', 'w'))
    fd:write('module A; end'); fd:close()
end

test('cache profile: a profileless graph round-trips (the common case)', function ()
    if config.cache == false then skip 'cache disabled' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    cache.save(graph(root), nil)
    local loaded = cache.load(root)
    ok(loaded ~= nil, 'no profile → loads (nil == nil identity)')
    ok(loaded and loaded.profile == nil, 'no profile carried')
    vim.fn.delete(root, 'rf')
end)

test('cache profile: profile + packs are persisted and restored', function ()
    if config.cache == false then skip 'cache disabled' end
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    mark_rails(root) -- the root ACTIVATES ruby-rails (marker present)
    cache.save(graph(root, { profile = 'ruby-rails', packs = { 'rails' } }), nil)
    local loaded = cache.load(root)
    ok(loaded ~= nil, 'identity matches (root still activates ruby-rails) → loads')
    eq('ruby-rails', loaded and loaded.profile)
    eq({ 'rails' }, loaded and loaded.packs)
    vim.fn.delete(root, 'rf')
end)

test('cache profile: a graph claiming a profile the root no longer activates is INVALID', function ()
    if config.cache == false then skip 'cache disabled' end
    -- a MARKERLESS root: shapes.profile_for → nil, but the saved manifest claims
    -- ruby-rails → identity mismatch → cache miss (would cold re-extract)
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    cache.save(graph(root, { profile = 'ruby-rails', packs = { 'rails' } }), nil)
    ok(cache.load(root) == nil,
        'profile mismatch (manifest ruby-rails vs current none) invalidates the cache')
    vim.fn.delete(root, 'rf')
end)

test('cache profile: activation appearing under a cache also invalidates it', function ()
    if config.cache == false then skip 'cache disabled' end
    -- inverse direction: cache built WITHOUT a profile, then the root gains the
    -- marker (a config/application.rb added) → now activates ruby-rails → the
    -- profileless cache is stale (its calls were never minted) → miss
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    cache.save(graph(root), nil) -- profileless
    ok(cache.load(root) ~= nil, 'loads while still profileless')
    mark_rails(root) -- the shape now activates
    ok(cache.load(root) == nil, 'newly-activated profile invalidates the profileless cache')
    vim.fn.delete(root, 'rf')
end)
