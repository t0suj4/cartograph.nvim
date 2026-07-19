-- The canonical tier ladder: one definition of resolved-edge trust precedence
-- (the sequencing-critical accessor the stdlib/convention tiers slot into).

local tier = require 'cartograph.tier'

test('tier: LADDER is highest-trust first, matched is the flagless tail', function ()
    local names = {}
    for _, r in ipairs(tier.LADDER) do names[#names + 1] = r.name end
    eq({ 'confirmed', 'proven', 'xlang', 'typed', 'stdlib', 'inferred', 'matched' }, names)
    eq(nil, tier.LADDER[#tier.LADDER].flag) -- the fallback rung has no flag
end)

test('tier: of() returns the HIGHEST set flag (precedence, not first-seen)', function ()
    eq('matched', tier.of({}))
    eq('inferred', tier.of({ inferred = true }))
    eq('typed', tier.of({ tinf = true }))
    eq('xlang', tier.of({ xlang = true }))
    eq('proven', tier.of({ proven = true }))
    eq('confirmed', tier.of({ conf = true }))
    -- an edge wearing several flags takes the most-trusted one
    eq('confirmed', tier.of({ conf = true, proven = true, inferred = true }))
    eq('proven', tier.of({ proven = true, tinf = true, inferred = true }))
    eq('typed', tier.of({ tinf = true, inferred = true }))
    eq('stdlib', tier.of({ stdlib = true }))
    eq('stdlib', tier.of({ stdlib = true, inferred = true })) -- stdlib > inferred
    eq('typed', tier.of({ tinf = true, stdlib = true }))      -- typed > stdlib
end)

test('tier: rank is monotonic and at_least reads it', function ()
    eq(1, tier.rank('confirmed'))
    eq(7, tier.rank('matched'))
    eq(nil, tier.rank('nonesuch'))
    ok(tier.rank('proven') < tier.rank('inferred'))
    ok(tier.at_least('proven', 'inferred'))       -- more trusted ≥ less
    ok(tier.at_least('proven', 'proven'))         -- reflexive
    ok(not tier.at_least('inferred', 'proven'))   -- not the other way
    ok(not tier.at_least('proven', 'nonesuch'))   -- unknown never satisfies
end)

test('tier: the ladder covers exactly the fields census/fold read', function ()
    -- flag field names are the resolved-edge trust flags the extractor sets;
    -- guard against a rung renaming a field out from under a producer.
    local flags = {}
    for _, r in ipairs(tier.LADDER) do if r.flag then flags[r.flag] = true end end
    eq({ conf = true, proven = true, xlang = true, tinf = true,
        stdlib = true, inferred = true }, flags)
end)

-- regression: census tier counting rides tier.of() now — prove it still bins
-- the same edges the same way (the near-free, output-identical contract).
test('tier: census bins ref edges by the ladder', function ()
    local census = require 'cartograph.census'
    local c = census.take({
        nodes = {}, calls = {},
        edges = {
            { kind = 'ref' },                        -- matched
            { kind = 'ref', inferred = true },       -- inferred
            { kind = 'ref', tinf = true },           -- typed
            { kind = 'ref', xlang = true },          -- xlang
            { kind = 'ref', proven = true },         -- proven
            { kind = 'ref', conf = true },           -- confirmed
            { kind = 'ref', conf = true, inferred = true }, -- confirmed wins
        },
    })
    eq(2, c.edges.ref.confirmed)
    eq(1, c.edges.ref.proven)
    eq(1, c.edges.ref.xlang)
    eq(1, c.edges.ref.typed)
    eq(1, c.edges.ref.inferred)
    eq(1, c.edges.ref.matched)
end)
