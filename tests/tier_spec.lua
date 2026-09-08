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

-- ── THE FLOOR OVER A PATH (CART-0843) ──────────────────────────────────────
-- ★★★ THE LADDER WAS ALWAYS A MAX OVER MECHANISMS. `M.of` grades an edge by the
-- HIGHEST flag set on it — right for one edge resolved one way, and silently
-- FLATTERING for a path through several. Each hop of a composed relation is the
-- mechanism that would have set one of those flags, so the floor is the
-- composition-honest aggregation of the same vocabulary.

test('tier: floor takes the WEAKEST hop, never the strongest', function ()
    -- rank is the index: confirmed=1 … matched=7, so a HIGHER rank is weaker
    eq('stdlib', (tier.floor({ 'xlang', 'stdlib' })), 'stdlib(5) is weaker than xlang(3)')
    eq('stdlib', (tier.floor({ 'stdlib', 'xlang' })), 'and order does not matter')
    eq('matched', (tier.floor({ 'confirmed', 'proven', 'matched' })), 'the tail rung wins')
    eq('confirmed', (tier.floor({ 'confirmed' })), 'one hop is its own floor')
    -- ⚠ THE SHIPPED OVERCLAIM THIS EXISTS TO PREVENT: rootjoin asserted a flat
    -- `xlang` on rows whose key comes from a distilled PROFILE artifact, which
    -- the ladder itself grades `stdlib`. Two rungs of flattery, from stamping a
    -- constant where a computation belonged.
    ok(tier.RANK.stdlib > tier.RANK.xlang, 'and the direction is the ladder\'s own')
end)

test('tier: an UNGRADED hop is COUNTED, never approximated', function ()
    -- ⚠ THE VACUOUS CASES, BOTH DECIDED. An empty or wholly-ungraded list must
    -- return nil so a caller says UNGRADED — returning a rung, or silently "no
    -- downgrade", is the guard-that-reads-like-a-pass shape.
    local f0, u0 = tier.floor({})
    eq(nil, f0, 'no hops grades nothing')
    eq(0, u0)
    local f1, u1 = tier.floor({ 'banana' })
    eq(nil, f1, 'an undeclared rung is NOT approximated by a neighbour')
    eq(1, u1, 'it is counted so the caller must render it')
    -- ★ AND THE REAL INSTANCE: the tuple carrier's interpretation hop is
    -- `convention`, which tier.lua lists as a BANKED insertion point that does
    -- not exist — the ladder is full (7 rungs, fold packs 3 bits). So a real
    -- composed relation has an ungraded hop TODAY (CART-0848).
    local f2, u2 = tier.floor({ 'stdlib', 'xlang', 'convention' })
    eq('stdlib', f2, 'the declared hops still produce a floor')
    eq(1, u2, 'and the undeclared one is reported beside it')
    eq(nil, tier.RANK.convention, 'convention is banked, not declared')
end)

test('tier: floor is the ONE implementation — agent delegates to it', function ()
    -- "a probe and a verb that compute the same thing SEPARATELY will disagree,
    -- and the disagreement will be discovered by a reader who trusts the wrong
    -- one". agent.lua's floor_tier was a second copy of this arithmetic.
    local src = assert(io.open(vim.fn.getcwd() .. '/lua/cartograph/agent.lua')):read('a')
    local body = assert(src:match('local function floor_tier%(list%)(.-)\nend'),
        'could not find floor_tier — this test reads it, not a copy')
    ok(body:find('tiers%.floor'), 'floor_tier must delegate, not reimplement')
    ok(not body:find('for _, t in ipairs'), 'and the loop must be gone')
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
    for _, name in ipairs({ 'absent', 'refused', 'frontier', 'unavailable',
        'unbuilt' }) do
        ok(tier.is_absence(name), name .. ' must be a declared reading kind')
    end
    ok(not tier.is_absence('banana'))
    ok(not tier.is_absence('unprobed'), 'an observation warrant is NOT a reading kind')
    -- ★ ONLY ONE OF THEM LICENSES ACTING, and it is the whole point of the
    -- split: on this repo's own fold the 266 dead-code findings are 7 absent /
    -- 229 refused / 12 frontier / 18 unavailable, and only the 7 permit a
    -- deletion.
    eq('act', tier.licenses('absent'))
    for _, name in ipairs({ 'refused', 'frontier', 'unavailable', 'unbuilt' }) do
        eq('nothing', tier.licenses(name))
    end
end)

-- ── ★★★ `unbuilt` IS THE ONE KIND THE FALSIFIER PRODUCED, and this spec is the
-- reason it is not `absent`. CART-0831 declared its own falsifier — "if some
-- existing analysis cannot honestly say which absence warrant its negatives
-- carry, the taxonomy is wrong and should be fixed here, not papered over with
-- a default" — and grpcjoin's five hand-written warrants were run against the
-- four original kinds: four fitted, and the java one did not fit anything.
test('tier: unbuilt exists because a COMPLETE reading can still be incomplete', function ()
    -- THE MEASURED INSTANCE: microservices-demo declares gRPC rpcs, java is
    -- present, and no `*Grpc.java` exists in the tree because protoc runs at
    -- BUILD time. A reading complete over the artifacts read is NOT complete
    -- over the system when something outside them PRODUCES more.
    ok(tier.is_absence('unbuilt'))
    -- ⚠ THE LOAD-BEARING ASSERTION. Before this kind, that case classified as
    -- `absent` — which licenses ACTING, and acting on it is exactly wrong. If a
    -- later hand collapses the two, this fails.
    ok(tier.licenses('unbuilt') ~= tier.licenses('absent'),
        'unbuilt must never inherit the one license that permits acting')
    eq('nothing', tier.licenses('unbuilt'))
    -- and it is not `frontier` either: the region was never SKIPPED, it does
    -- not exist yet. Same license, different cause, so the distinction lives in
    -- the kind rather than in prose a reader has to find.
    ok(tier.is_absence('frontier'))
end)

test('tier: the OBSERVATION axis is a second question, never one more reading kind', function ()
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

-- ── ★★ THE MIGRATION IS THE OTHER HALF OF CART-0831, and a taxonomy nothing
-- consumes is not checked by anything. These two tools are WHY the tables
-- exist: each had written its own warrants as prose. So the fence reads their
-- SOURCE rather than a copy of it — a sixth reason added there with an
-- undeclared kind fails here, which is the shape a fence needs to have.
test('tier: grpcjoin names only DECLARED reading kinds', function ()
    local src = assert(io.open(vim.fn.getcwd() .. '/tools/grpcjoin.lua')):read('a')
    local body = assert(src:match('local WARRANTS = (.-)\n}\n'),
        'could not find the WARRANTS table — this test reads it, not a copy')
    local kinds = {}
    for k in body:gmatch("kind = '([%w%-]+)'") do kinds[#kinds + 1] = k end
    -- guard the scrape itself: a pattern that matches nothing would make every
    -- assertion below vacuously true, which is the fence-that-never-fires shape
    eq(5, #kinds, 'the five measured warrants, each carrying its kind')
    for _, k in ipairs(kinds) do
        ok(tier.is_absence(k), k .. ' is named by grpcjoin but not declared')
    end
    -- ⚠ AND THE WORD COLLISION IS GONE. This tool used to call an unreadable
    -- extension "dark", which on the OBSERVATION axis means a probe was
    -- attempted and REFUSED — one word, two axes, the `torn` failure the tier
    -- header warns about.
    ok(not body:find('dark'), 'a WARRANT word must not be reused for a reading')
end)

test('tier: otelobserve never mints the warrant that would RAISE its license', function ()
    local src = assert(io.open(vim.fn.getcwd() .. '/tools/otelobserve.lua')):read('a')
    local w = assert(src:match("local WARRANT = '([%w%-]+)'"),
        'could not find the declared WARRANT — this test reads it, not a copy')
    eq('unsampled', w)
    ok(tier.is_warrant(w))
    -- ★★★ THE POINT: a capture is not a window. `absent-in-window` licenses
    -- 'flag' and `unsampled` licenses nothing, so minting the former from a run
    -- RAISES a license the consumer may only weaken. Health/Check measured the
    -- sensitivity — unobserved on a 3-request compose workload, the most-called
    -- rpc in the system on kubernetes. Same graph, opposite emptiness.
    eq('nothing', tier.licenses(w))
    eq('flag', tier.licenses('absent-in-window'))
    ok(not src:find('absent%-in%-window\'', 1),
        'the stronger warrant must not be minted from a capture')
end)

-- ★★ THE AGENT-FACING SURFACE, which is the one that nearly went stale. The MCP
-- tool description tells every agent what an empty answer can say, and it had
-- the four kinds HARDCODED — so a fifth would have left the host denying a kind
-- it now emits. A DATA FIELD HAS ITS OWN SURFACES and nothing enumerates them.
test('tier: mcpserve DERIVES the absence enum instead of retyping it', function ()
    local src = assert(io.open(vim.fn.getcwd() .. '/tools/mcpserve.lua')):read('a')
    ok(src:find('kinds_of%(tiers%.ABSENCE%)'),
        'the tool description must read tier.ABSENCE, not a copy of its names')
    ok(src:find('kinds_of%(tiers%.WARRANT%)'), 'and the warrant axis too')
    -- the retyped list must be GONE, not merely joined by a new one
    ok(not src:find('absent|refused|frontier|unavailable'),
        'a hardcoded enum is what went stale; it must not survive')
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
