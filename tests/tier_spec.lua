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

-- ── THE TWO ABSENCE AXES (CART-0831) ───────────────────────────────────────
-- runtime-topology/05-build-order.md's Phase 0: "settle the absence warrant,
-- with no collector at all ... the only phase whose cost rises the longer it
-- waits, because every later consumer would otherwise be written against a bare
-- negative." Three consumers already had been.

test('tier: the ladder is untouched and still exactly seven rungs', function ()
    -- ★ THE TABLE IS FULL. fold.lua packs M.RANK into a 3-BIT field (1..7, 0
    -- meaning "no rank recorded"), so an eighth rung would pack as 8 and decode
    -- as 8 % 8 == 0 — read back as no tier at all. The absence axes are
    -- deliberately NOT rungs, and this spec is what stops a later hand adding
    -- one there by reflex.
    eq(7, #tier.LADDER)
    eq('confirmed', tier.LADDER[1].name)
    eq('matched', tier.LADDER[#tier.LADDER].name)
    eq(nil, tier.LADDER[#tier.LADDER].flag, 'the tail rung is the FLAGLESS one')
end)

test('tier: the READING axis is a table, not a sentence in a comment', function ()
    for _, name in ipairs({ 'absent', 'refused', 'frontier', 'unavailable' }) do
        ok(tier.is_absence(name), name .. ' must be a declared reading kind')
    end
    ok(not tier.is_absence('banana'))
    ok(not tier.is_absence('unprobed'), 'an observation warrant is NOT a reading kind')
    -- ★ ONLY ONE OF THE FOUR LICENSES ACTING, and it is the whole point of the
    -- split: on this repo's own fold the 266 dead-code findings are 7 absent /
    -- 229 refused / 12 frontier / 18 unavailable, and only the 7 permit a
    -- deletion.
    eq('act', tier.licenses('absent'))
    for _, name in ipairs({ 'refused', 'frontier', 'unavailable' }) do
        eq('nothing', tier.licenses(name))
    end
end)

test('tier: the OBSERVATION axis is a second question, not a fifth kind', function ()
    for _, name in ipairs({ 'proven-forbidden', 'absent-in-window', 'unsampled',
        'unprobed', 'dark' }) do
        ok(tier.is_warrant(name), name .. ' must be a declared warrant')
        ok(not tier.is_absence(name), name .. ' must not leak into the reading axis')
    end
    eq('unprobed', tier.WARRANT_DEFAULT)
    -- ★★ THE STRONGEST NEGATIVE IS NOT MADE BY WATCHING. A declaration the
    -- substrate ENFORCES outranks any amount of observation — the design's
    -- measured case is a principal with no Read grant anywhere, which no
    -- watching could establish.
    eq('act', tier.licenses('proven-forbidden'))
    eq('flag', tier.licenses('absent-in-window'))
    for _, name in ipairs({ 'unsampled', 'unprobed', 'dark' }) do
        eq('nothing', tier.licenses(name))
    end
    -- and the two axes never share a rank space with the presence ladder
    eq(nil, tier.rank('unprobed'))
    eq(nil, tier.rank('absent'))
end)

test('tier: a license is an UPPER BOUND a consumer may only weaken', function ()
    -- ⚠ `absent` licenses acting only where the world is CLOSED. The k8s design
    -- tiers a Service whose selector matches no Pods as `~` — "flag, surface,
    -- never auto-delete" — because an overlay or an operator may still supply
    -- it, while runtime-topology's thesis says why source differs: "over parsed
    -- source, absence is near-complete". Same warrant, different claim scope.
    -- The rule lives in the table's header; this asserts the shape it needs —
    -- a single declared maximum, never a per-consumer floor.
    eq('act', tier.licenses('absent'))
    eq(nil, tier.licenses('absent-in-variant'), 'no per-domain warrant is minted')
end)
