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

test('cache minted externals: they survive the round-trip, and so do the edges into them',
    function ()
    if config.cache == false then skip 'cache disabled' end
    -- CART-0245. A stdlib symbol minted during resolution lives in a pseudo-file named for
    -- the profile (`zig-std`), which carries NO STAMP — so build_shards created no shard for
    -- it and dropped the node, while KEEPING the edge into it. MEASURED on zig: 360 nodes
    -- lost and 4122 DANGLING edge targets in the warm graph, and `valid` passed throughout
    -- because validate does not check referential integrity.
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    -- NO `profile` here: read_manifest invalidates a warm load when the root's current
    -- profile identity differs, and a temp root activates none — the first version of this
    -- test set profile='zig-std' and got nil back, which is that check working, not this
    -- bug. What causes the DROP is the missing STAMP, nothing about profiles.
    local g = graph(root, {
        nodes = {
            { id = 'a.rb', name = 'a.rb', kind = 'module', file = 'a.rb', order = -1, range = R },
            { id = 'a.rb::f@1', name = 'f', kind = 'function', file = 'a.rb', order = 1, range = R },
            -- the minted external: no stamp for its file, kind 'external'
            { id = 'zig-std::std.mem.eql', name = 'std.mem.eql', kind = 'external',
              file = 'zig-std', external = true, order = -1, range = R },
        },
        edges = {
            { kind = 'ref', from = 'a.rb::f@1', to = 'zig-std::std.mem.eql', stdlib = true },
        },
    })
    cache.save(g, nil)
    local warm = assert(cache.load(root), 'warm load')

    local ids, minted = {}, 0
    for _, n in ipairs(warm.nodes) do
        ids[n.id] = true
        if n.external then minted = minted + 1 end
    end
    eq(1, minted, 'the minted external came back')
    ok(ids['zig-std::std.mem.eql'], 'by its exact id, so the edge still lands')
    -- the invariant that was actually broken: no edge may point at a node that is gone
    local dangling = 0
    for _, e in ipairs(warm.edges) do
        if e.to and not ids[e.to] then dangling = dangling + 1 end
    end
    eq(0, dangling, 'no dangling edge targets in the warm graph')
    -- and it must NOT have become a stamped file: `stamps` is the set of real validity
    -- keys every consumer reads for staleness
    eq(nil, warm.stamps['zig-std'], 'the pseudo-file did not sneak into the stamp set')
    vim.fn.delete(root, 'rf')
end)
