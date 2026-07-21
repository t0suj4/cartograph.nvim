-- The central name registry (registry.lua): structured node-id identity
-- (split/join + intern/reconstruct, EXACT round-trip = the correctness gate)
-- and the frequency-ordered varint cold form. Pure — no parser, always runs.

local reg = require 'cartograph.registry'

-- every node-id shape the minters produce (treesitter uid + the DSL/minted/
-- sentinel ids). Reconstruction must be byte-identical for ALL of them.
local IDS = {
    'src/foo.zig::bar@10',              -- function
    'm.lua::var:count@3',               -- var: discriminator rides in mid
    'a/b/c.ts::type:Widget@42',         -- type: discriminator
    'x.lua::region@0',                  -- region, line 0
    'deep/a::b::c.rb::meth@7',          -- a file path that itself splits oddly
    'plain.lua',                        -- module id: bare file, no :: no @
    'route::/users/:id',                -- DSL id, no @line
    'zig-std::std.mem.eql',             -- minted external, no @line
    'sql::table:users',                 -- another no-line shape
    '\0frontier',                       -- the fold sentinel
}

test('registry: split/join round-trips the matched grammar exactly', function ()
    local f, mid, line = reg.split('src/foo.zig::bar@10')
    eq('src/foo.zig', f); eq('bar', mid); eq(10, line)
    eq('src/foo.zig::bar@10', reg.join(f, mid, line))
    -- FIRST '::' and LAST '@digits': a file path containing '::' still splits
    -- so that join is exact
    local f2, m2, l2 = reg.split('deep/a::b::c.rb::meth@7')
    eq('deep/a', f2); eq('b::c.rb::meth', m2); eq(7, l2)
    eq('deep/a::b::c.rb::meth@7', reg.join(f2, m2, l2))
    -- var:/type:/region discriminators survive inside mid
    eq('var:count', (select(2, reg.split('m.lua::var:count@3'))))
    -- unmatched shapes return nil (→ stored whole)
    eq(nil, reg.split('plain.lua'))
    eq(nil, reg.split('zig-std::std.mem.eql')) -- no @line
    eq(nil, reg.split('\0frontier'))
end)

test('registry: add/reconstruct is exact for every id shape', function ()
    local r = reg.new()
    for _, id in ipairs(IDS) do
        eq(id, r:reconstruct(r:add(id)), 'round-trip: ' .. vim.inspect(id))
    end
end)

test('registry: the file prefix is stored ONCE across many nodes', function ()
    local r = reg.new()
    -- 4 nodes in one file + 1 in another → 2 file strings, 5 names
    r:add('src/foo.zig::a@1'); r:add('src/foo.zig::b@2')
    r:add('src/foo.zig::c@3'); r:add('src/foo.zig::d@4')
    r:add('src/bar.zig::e@5')
    local nf, nn = r:counts()
    eq(2, nf, 'two distinct files, prefix not repeated')
    eq(5, nn, 'five distinct names')
    -- a repeated (file,name,line) interns to the SAME ids (idempotent)
    local a = r:add('src/foo.zig::a@1')
    eq(0, a.f); eq(0, a.n) -- first-interned file/name (csr ids are 0-based)
end)

test('registry: uvarint round-trips across byte boundaries', function ()
    for _, x in ipairs({ 0, 1, 127, 128, 129, 16383, 16384, 1000000, 2 ^ 31 }) do
        local v, pos = reg.read_uvarint(reg.uvarint(x), 1)
        eq(x, v, 'value ' .. x)
        eq(#reg.uvarint(x) + 1, pos, 'consumed exactly one varint for ' .. x)
    end
    -- rank 1..127 is one byte; 128 crosses to two (the Zipfian win)
    eq(1, #reg.uvarint(127))
    eq(2, #reg.uvarint(128))
end)

test('registry: pack/unpack a sequence of varints', function ()
    local seq = { 0, 5, 200, 1, 40000, 3 }
    eq(seq, reg.unpack_varints(reg.pack_varints(seq), #seq))
end)

test('registry: freq_order ranks by descending frequency, stable ties', function ()
    -- 7 appears 3×, 4 twice, 9/2 once each → ranks: 7=1, 4=2, then 2<9 by id
    local rank, inv = reg.freq_order({ 7, 4, 7, 9, 4, 2, 7 })
    eq(1, rank[7]); eq(2, rank[4])
    eq(3, rank[2]); eq(4, rank[9]) -- equal freq → smaller id first (deterministic)
    eq(7, inv[1]); eq(4, inv[2]); eq(2, inv[3]); eq(9, inv[4])
    -- encoding the sequence via ranks costs 1 byte/slot here (all ranks < 128)
    local ranked = {}
    for i, id in ipairs({ 7, 4, 7, 9, 4, 2, 7 }) do ranked[i] = rank[id] end
    eq(7, #reg.pack_varints(ranked))
end)
