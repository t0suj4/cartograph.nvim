-- CSR topology backend: correctness + exact size + backend agreement +
-- serialize round-trip. Perf/size-vs-Lua-tables (the 5×/2×/32.5× wins) is a
-- benchmark, not a unit test — timing is flaky; here we pin correctness and the
-- exact byte formula, which are deterministic.

local csr = require 'cartograph.csr'

-- sample graph over n=4 nodes: 0→1, 0→2, 2→0, node 3 isolated
local function sample(backend)
    return csr.build({ 0, 0, 2 }, { 1, 2, 0 }, 4, { backend = backend })
end

test('csr: degree and neighbors', function ()
    local g = sample()
    eq(2, g:degree(0))
    eq(0, g:degree(1))
    eq(1, g:degree(2))
    eq(0, g:degree(3))
    local nb = g:neighbors(0)
    table.sort(nb)
    eq(1, nb[1]); eq(2, nb[2])
    eq(0, g:neighbors(2)[1])
    eq(0, #g:neighbors(3))
end)

test('csr: span + at is the fast neighbor path', function ()
    local g = sample()
    local lo, hi = g:span(0)
    eq(2, hi - lo)          -- degree of node 0
    eq(g:degree(0), hi - lo)
    local sum = 0
    for j = lo, hi - 1 do sum = sum + g.at(j) end
    eq(3, sum)              -- 1 + 2
    local a, b = g:span(3)  -- isolated node: empty span
    eq(a, b)
end)

test('csr: bytes = (n+1 + m) * 4', function ()
    eq((4 + 1) * 4 + 3 * 4, sample():bytes())
end)

test('csr: string and ffi backends agree', function ()
    if not csr.have_ffi then skip 'no ffi' end
    local gf, gs = sample('ffi'), sample('string')
    for node = 0, 3 do
        eq(gf:degree(node), gs:degree(node))
        local a, b = gf:neighbors(node), gs:neighbors(node)
        table.sort(a); table.sort(b)
        eq(#a, #b)
        for i = 1, #a do eq(a[i], b[i]) end
    end
end)

test('csr: from_edges interns and builds', function ()
    local g, it = csr.from_edges({
        { from = 'a', to = 'b' }, { from = 'a', to = 'c' }, { from = 'c', to = 'a' },
    })
    eq(3, it.count())
    eq(2, g:degree(it.id('a')))
    local names = {}
    for _, v in ipairs(g:neighbors(it.id('a'))) do names[it.name(v)] = true end
    ok(names.b and names.c, 'a -> b, c')
    eq(1, g:degree(it.id('c'))) -- c -> a
    eq(0, g:degree(it.id('b'))) -- b is a target only
end)

test('csr: pack / unpack round-trip preserves the graph', function ()
    local g = sample('string')
    local ob, nb = g:pack()
    local g2 = csr.unpack(ob, nb, g.n, g.m)
    eq(g:bytes(), g2:bytes())
    for node = 0, 3 do
        local a, b = g:neighbors(node), g2:neighbors(node)
        table.sort(a); table.sort(b)
        eq(#a, #b)
        for i = 1, #a do eq(a[i], b[i]) end
    end
end)

test('csr: empty graph is well-formed', function ()
    local g = csr.build({}, {}, 0)
    eq(0, g.m)
    eq(4, g:bytes()) -- off has n+1 = 1 entry
end)

test('csr: ffi pack() matches string pack byte-for-byte', function ()
    if not csr.have_ffi then skip 'no ffi' end
    local of, nf = sample('ffi'):pack()   -- the pack-out branch
    local os_, ns = sample('string'):pack() -- the no-copy branch
    eq(os_, of)
    eq(ns, nf)
end)

test('csr: span agrees across backends', function ()
    if not csr.have_ffi then skip 'no ffi' end
    local gf, gs = sample('ffi'), sample('string')
    for node = 0, 3 do
        local a1, b1 = gf:span(node)
        local a2, b2 = gs:span(node)
        eq(a1, a2); eq(b1, b2)
        for j = a1, b1 - 1 do eq(gf.at(j), gs.at(j)) end
    end
end)

test('csr: unpack rejects mis-sized bytes', function ()
    local g = sample('string')
    local ob, nb = g:pack()
    ok(not pcall(csr.unpack, ob:sub(1, #ob - 1), nb, g.n, g.m), 'short offsets')
    ok(not pcall(csr.unpack, ob, nb .. '\0', g.n, g.m), 'long neighbors')
end)

test('csr: build rejects an out-of-range edge target', function ()
    ok(not pcall(csr.build, { 0 }, { 4 }, 4), 'to >= n')
    ok(not pcall(csr.build, { 0 }, { -1 }, 4), 'negative to')
end)
