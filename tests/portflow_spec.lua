-- PORTFLOW — anonymous-type compatibility classes from OBSERVED flow. The measurement
-- harness (tools/portgraph.lua) reads this same module, so what these tests pin is the
-- contract both the probe and the :CartographPortClasses lens depend on.
--
-- The properties that matter are the two SIDES of the acceptance metric (CART-0269): the
-- rules must break a spurious fusion AND leave a real class standing. A test that only
-- checked the first would pass for a rule that deletes everything.

local pf = require 'cartograph.portflow'
local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'

local SRC = table.concat({
    'local M = {}',
    '',
    -- a real family: one producer, three consumers, via all three flow shapes
    'local function chain(k)',
    '    local h = Engine.FindComponent(k)',
    '    Engine.RemoveFromParent(h)',
    '    h:Destroy()',
    'end',
    '',
    'local function nested(k)',
    '    Engine.Attach(Engine.FindComponent(k))',
    'end',
    '',
    -- a SECOND family that must not join the first
    'local function other(k)',
    '    local s = Engine.OpenSocket(k)',
    '    Engine.CloseSocket(s)',
    'end',
    '',
    -- the blob maker: three families iterate through ipairs#a1, a universal sink
    'local function iterall(k)',
    '    local h = Engine.FindComponent(k)',
    '    local s = Engine.OpenSocket(k)',
    '    local q = Engine.OpenQueue(k)',
    '    for _, x in ipairs(h) do Engine.Touch(x) end',
    '    for _, y in ipairs(s) do Engine.Touch(y) end',
    '    for _, z in ipairs(q) do Engine.Touch(z) end',
    'end',
    '',
    'M.chain, M.nested, M.other, M.iterall = chain, nested, other, iterall',
    'return M',
}, '\n') .. '\n'

local root
local function proj(src)
    root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/m.lua', 'w')); fd:write(src or SRC); fd:close()
    store.ingest(ts.extract(root))
end
local function cleanup() if root then vim.fn.delete(root, 'rf'); root = nil end end

local FC = pf.port('Engine.FindComponent', 'ret')
local SOCK = pf.port('Engine.OpenSocket', 'ret')
local IP = pf.port('ipairs', 'a1')

test('portflow: the three observed flow shapes each make an edge', function ()
    proj()
    local col = pf.collect(store)
    local part = pf.partition(col, {})
    local function same(a, b)
        return part.uf.p[a] and part.uf.p[b] and part.uf:find(a) == part.uf:find(b)
    end
    ok(same(FC, pf.port('Engine.RemoveFromParent', 'a1')), 'local-mediated: local h = A(); B(h)')
    ok(same(FC, pf.port('Engine.Attach', 'a1')), 'direct nesting: B(A())')
    ok(same(FC, pf.port('Destroy', 'self')), 'method receiver: h:Destroy()')
    ok(col.is_ext(FC), 'a callee absent from the corpus is EXTERNAL')
    cleanup()
end)

test('portflow: a method port keys on the METHOD, not on the receiver variable', function ()
    proj()
    local col = pf.collect(store)
    -- `h:Destroy()` must not produce `h.Destroy#self`: the receiver VARIABLE's name is not
    -- part of the callee's identity, and not knowing the receiver's type is the point.
    ok(col.pcount[pf.port('Destroy', 'self')], 'Destroy#self exists')
    eq(nil, col.pcount[pf.port('h.Destroy', 'self')])
    cleanup()
end)

test('portflow: EVIDENCE is kept per edge, separately from degree', function ()
    proj()
    local col = pf.collect(store)
    eq(1, col.w[FC .. '\1' .. pf.port('Destroy', 'self')], 'a once-seen pair has weight 1')
    ok((col.pcount[FC] or 0) >= 3, 'degree counts DISTINCT partners, not observations')
    local nb = col.nbr[FC]
    ok(nb and #nb >= 3, 'the neighbour query lists partners')
    ok(nb and type(nb[1][2]) == 'number', 'each partner carries its observation count')
    cleanup()
end)

test('portflow: the rules break a spurious fusion AND keep the real classes', function ()
    proj()
    local col = pf.collect(store)
    local base = pf.partition(col, {})
    local ruled = pf.partition(col, { bare = true })
    -- SIDE ONE of the metric: the baseline must actually be degenerate here, or every
    -- assertion below would pass vacuously.
    ok(pf.together(base, { FC, SOCK }), 'baseline FUSES the families through ipairs#a1')
    ok(ruled.sinks[IP], 'ipairs#a1 is a universal SINK')
    -- SIDE TWO: separated, without either family being destroyed.
    ok(not pf.together(ruled, { FC, SOCK }), 'the rules SEPARATE the two families')
    ok(pf.together(ruled, { FC, pf.port('Engine.RemoveFromParent', 'a1'),
        pf.port('Engine.Attach', 'a1') }), 'the component family SURVIVES')
    ok(pf.together(ruled, { SOCK, pf.port('Engine.CloseSocket', 'a1') }),
        'the socket family SURVIVES')
    cleanup()
end)

test('portflow: the bare rule is DEGREE-GATED, so a single-receiver method survives', function ()
    proj()
    local col = pf.collect(store)
    local ruled = pf.partition(col, { bare = true })
    -- Destroy#self has ONE receiver: a categorical "unqualified callee is a sink" would
    -- condemn it, which is why the rule needs MDEG (CART-0269).
    eq(nil, ruled.sinks[pf.port('Destroy', 'self')])
    ok(pf.together(ruled, { FC, pf.port('Destroy', 'self') }), 'and it stays linked')
    cleanup()
end)

test('portflow: analyze counts the UNLINKED ports rather than omitting them', function ()
    proj()
    local a = pf.analyze(store, { bare = true })
    ok(a.stats.ports > 0, 'ports were found')
    eq(a.stats.ports, a.stats.linked + a.stats.unlinked,
        'every port is either in a class or counted as frontier — none vanish')
    ok(a.stats.classes >= 2, 'at least the two families are classes')
    cleanup()
end)

test('portflow: a class is reported as evidence, never as a type', function ()
    proj()
    local L = pf.roster(store)
    local blob = table.concat(L, '\n')
    ok(blob:find('observed interchangeable', 1, true), 'the roster says what a class IS')
    ok(blob:find('UNLINKED', 1, true), 'and shows the frontier')
    -- and a port report names a sink as a sink instead of hiding it
    local P = pf.port_report(store, IP)
    ok(table.concat(P, '\n'):find('SINK', 1, true), 'a universal sink says so')
    cleanup()
end)
