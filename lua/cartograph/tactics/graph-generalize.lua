-- GRAPH-GENERALIZE (discovery, CART-1344): the least general generalization of two TERM GRAPHS, invariant under
-- bisimilarity of the inputs. A.tg_generalize follows the paper — its Merge pairs NODES by identity — so a free
-- variable written as two nodes generalizes apart from its one-node form (measured 2026-10-03: f(l1,l1,l2) vs
-- f(m1,m1,m2) gave f(z1,z2,z3) with l1 as two nodes, f(z1,z1,z2) with one: the aliasing lost; and an unshared
-- f(g(a), g(a)) against a shared f(g(b)) gave f(g(u1), g(u2))). The STEP collapses each input to its quotient by its own
-- maximal bisimulation first (A.tg_collapse — derived by partition refinement, not a primitive) and then generalizes;
-- the CLAIM is the algebra's own law, the ORACLE: each side's store instance rebuilds that input up to bisimilarity.
-- ⚠ The encoder's contract, not checked here: labels are global in a first-order graph, so scoped names (locations per
-- allocation, shadowed locals) must be renamed apart BEFORE they become labels.
local function A() return require('cartograph.algebra').load() end

local E = {
    name = 'graph-generalize',
    kind = 'discovery',
    tags = { 'find', 'algebra' },
    measures = 'CART-1344',
    summary = 'generalize two term graphs (g1, g2), each collapsed to its bisimulation quotient first, so bisimilar inputs give the same generalization; the claim is that the store rebuilds both inputs',
    params = { g1 = 'term', g2 = 'term' },
    measure = function (_, p)
        local a = A()
        local c1, c2 = a.tg_collapse(p.g1), a.tg_collapse(p.g2)
        local r = a.tg_generalize(c1, c2)
        local i1 = a.tg_instantiate(r.G, r.sigmaL, { c1 })
        local i2 = a.tg_instantiate(r.G, r.sigmaR, { c2 })
        return { G = r.G, show = a.tg_show(r.G), store = r.store,
            rebuilds = (a.tg_bisimilar(i1, p.g1)) and (a.tg_bisimilar(i2, p.g2)) and true or false }
    end,
    claim = function (v)
        if v.rebuilds then return true, v.show end
        return false, 'the store does not rebuild both inputs: ' .. v.show
    end,
}

local function tg(root, eqs) return function () return A().tg(root, eqs) end end
local function gen(a, b) return function () return { g1 = a(), g2 = b() } end end
local function shows(want) return function (v) return v.show == want, v.show end end

-- f(l1, l1, l2): the same location twice, written as ONE node and as TWO nodes carrying the label
local one = tg('x0', { x0 = { 'f', 'x1', 'x1', 'x2' }, x1 = { var = 'l1' }, x2 = { var = 'l2' } })
local two = tg('x0', { x0 = { 'f', 'x1', 'x1b', 'x2' }, x1 = { var = 'l1' }, x1b = { var = 'l1' }, x2 = { var = 'l2' } })
local other_two = tg('y0', { y0 = { 'f', 'y1', 'y1b', 'y2' }, y1 = { var = 'm1' }, y1b = { var = 'm1' }, y2 = { var = 'm2' } })
local other_one = tg('y0', { y0 = { 'f', 'y1', 'y1', 'y2' }, y1 = { var = 'm1' }, y2 = { var = 'm2' } })

E.examples = {
    {
        name = 'aliasing kept: a location written as ONE node pairs consistently',
        files = {}, params = gen(one, other_one),
        expect = { holds = true, check = shows('z0=f(z1,z1,z2) z1=u1 z2=u2') },
    },
    {
        name = 'aliasing kept when each location is written as TWO nodes — the raw tg_generalize gives f(z1,z2,z3) here',
        files = {}, params = gen(two, other_two),
        expect = { holds = true, check = function (v)
            local raw = A().tg_show(A().tg_generalize(two(), other_two()).G)
            return v.show == 'z0=f(z1,z1,z2) z1=u1 z2=u2' and raw == 'z0=f(z1,z2,z3) z1=u1 z2=u2 z3=u3', v.show .. ' / raw ' .. raw
        end },
    },
    {
        name = 'aliasing that DIFFERS is not invented: f(l1,l1) against f(m1,m2) keeps two variables',
        files = {}, params = gen(tg('x0', { x0 = { 'f', 'x1', 'x1' }, x1 = { var = 'l1' } }),
            tg('y0', { y0 = { 'f', 'y1', 'y2' }, y1 = { var = 'm1' }, y2 = { var = 'm2' } })),
        expect = { holds = true, check = shows('z0=f(z1,z2) z1=u1 z2=u2') },
    },
    {
        name = 'INTERNAL sharing counts too: an unshared f(g(a), g(a)) generalizes like the shared one — the vars-only collapse gave f(g(u1), g(u2))',
        files = {}, params = gen(tg('x0', { x0 = { 'f', 'x1', 'x3' }, x1 = { 'g', 'x2' }, x3 = { 'g', 'x4' }, x2 = { 'a' }, x4 = { 'a' } }),
            tg('y0', { y0 = { 'f', 'y1', 'y1' }, y1 = { 'g', 'y2' }, y2 = { 'b' } })),
        expect = { holds = true, check = shows('z0=f(z1,z1) z1=g(z2) z2=u1') },
    },
    {
        name = 'a reference and its store entry keep their tie, however the location is written',
        files = {}, params = gen(
            tg('x0', { x0 = { 'state', 'x1', 'x2' }, x1 = { 'ref', 'xl' }, x2 = { 'loc', 'xm', 'x3' }, xl = { var = 'l1' }, xm = { var = 'l1' }, x3 = { 'c1' } }),
            tg('y0', { y0 = { 'state', 'y1', 'y2' }, y1 = { 'ref', 'yl' }, y2 = { 'loc', 'yl', 'y3' }, yl = { var = 'm1' }, y3 = { 'c2' } })),
        expect = { holds = true, check = shows('z0=state(z1,z3) z1=ref(z2) z2=u1 z3=loc(z2,z4) z4=u2') },
    },
}

return E
