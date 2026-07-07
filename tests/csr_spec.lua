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

test('csr: each is complete and allocation-free', function ()
    local g = sample()
    local sum, count = 0, 0
    g:each(0, function (v) sum = sum + v; count = count + 1 end)
    eq(2, count)
    eq(3, sum) -- 1 + 2
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
