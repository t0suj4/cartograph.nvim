-- Sharding resolved extract output into per-module CSR shards + sparse cross
-- table + directory. Pins the partition, per-shard topology, conservation, and
-- cross-shard locate.

local shards = require 'cartograph.shards'

-- module_of = containing directory (the default). Two modules: a/, b/.
local data = {
    nodes = {
        { id = 'a/x', file = 'a/x.lua' },
        { id = 'a/y', file = 'a/y.lua' },
        { id = 'b/z', file = 'b/z.lua' },
    },
    edges = {
        { kind = 'ref', from = 'a/x', to = 'a/y' }, -- intra a
        { kind = 'ref', from = 'a/x', to = 'b/z' }, -- cross a -> b
        { kind = 'import', from = 'a/x', to = 'b/z' }, -- non-ref: ignored
    },
}

test('shards: partition into per-module CSR + cross + dir', function ()
    local s = shards.from_extract(data)
    -- two modules
    ok(s.shards['a'], 'module a shard')
    ok(s.shards['b'], 'module b shard')
    eq(2, s.shards['a'].n) -- a/x, a/y
    eq(1, s.shards['b'].n) -- b/z
    -- one intra edge in a, none in b
    eq(1, s.shards['a'].csr.m)
    eq(0, s.shards['b'].csr.m)
    -- one cross edge (the ref; the import is not counted)
    eq(1, #s.cross)
    eq('a/x', s.cross[1].from)
    eq('b/z', s.cross[1].to)
    -- directory
    eq('a', s.dir['a/x'])
    eq('b', s.dir['b/z'])
end)

test('shards: intra-shard topology is queryable', function ()
    local s = shards.from_extract(data)
    local sa = s.shards['a']
    local xi = sa.it.get('a/x')
    local yi = sa.it.get('a/y')
    eq(1, sa.csr:degree(xi)) -- a/x -> a/y
    eq(yi, sa.csr:neighbors(xi)[1])
    eq(0, sa.csr:degree(yi))
end)

test('shards: locate resolves a node to (module, local id)', function ()
    local s = shards.from_extract(data)
    local mod, lid = shards.locate(s, 'b/z')
    eq('b', mod)
    eq(lid, s.shards['b'].it.get('b/z'))
    eq(nil, (shards.locate(s, 'nope'))) -- unknown key
end)

test('shards: conservation — intra + cross = total ref edges', function ()
    local s = shards.from_extract(data)
    eq(2, shards.edge_count(s)) -- 1 intra + 1 cross (import excluded)
end)

test('shards: every node is homed; dropped edges are counted', function ()
    local d2 = {
        nodes = {
            { id = 'a/x', file = 'a/x.lua' },
            { id = 'a/iso', file = 'a/iso.lua' }, -- no edges at all
        },
        edges = {
            { kind = 'ref', from = 'a/x', to = 'ghost' }, -- endpoint not a node
        },
    }
    local s = shards.from_extract(d2)
    local mod, lid = shards.locate(s, 'a/iso')
    eq('a', mod)
    ok(lid ~= nil, 'isolated node has a local id')
    eq(1, s.dropped)             -- the ghost edge, counted not silent
    eq(0, shards.edge_count(s))  -- conservation covers what was kept
end)

test('shards: custom module_of (first path segment)', function ()
    local s = shards.from_extract(data, function (f) return (f:match('^([^/]+)')) end)
    ok(s.shards['a'] and s.shards['b'], 'segment modules')
    eq(1, #s.cross)
end)
