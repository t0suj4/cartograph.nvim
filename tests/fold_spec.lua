-- The fold: wide data -> one typed-edge triple table + by-subject/by-object
-- indexes. Pure over the neutral schema (no parser), so it always runs.
-- Parity is checked against the store's own forward/backward indexes on the
-- same data — the fold must be indistinguishable from the wide topology.

local fold = require 'cartograph.fold'
local store = require 'cartograph.store'

local R = { start = { line = 0, char = 0 }, ['end'] = { line = 0, char = 0 } }
local function node(id, kind)
    return { id = id, name = id, kind = kind or 'function',
        file = 'm.lua', range = R, order = 0 }
end

-- a graph exercising all four edge kinds + a refused frontier + a self-ref
local DATA = {
    nodes = {
        node('m.lua', 'module'), node('a'), node('b'), node('c'),
        node('v', 'var'), node('iso'),
    },
    edges = {
        { from = 'a', to = 'b', kind = 'ref', at = { R } },
        { from = 'a', to = 'c', kind = 'ref', at = { R } },
        { from = 'b', to = 'c', kind = 'ref', at = { R } },
        { from = 'c', to = 'c', kind = 'ref', at = { R } },   -- self (recursion)
        { from = 'a', to = 'v', kind = 'use', at = { R } },
        { from = 'm.lua', to = 'b', kind = 'reg', at = { R } },
        { from = 'm.lua', to = 'other.lua', kind = 'import' },
    },
    calls = {
        { callee = 'b', fn = 'a', to = 'b', file = 'm.lua', line = 1 },
        { callee = 'mystery', fn = 'a', file = 'm.lua', line = 2,
            refused = { rule = 'ambiguous' } },
        { callee = 'toplevel_mystery', file = 'm.lua', line = 3,
            refused = { rule = 'blocked' } }, -- no fn: counted, not folded
    },
}

test('fold: forward and backward parity with the store, all predicates', function ()
    store.ingest({ nodes = DATA.nodes, edges = DATA.edges, calls = DATA.calls,
        root = '/x' })
    local f = fold.build(DATA)
    local function names(ids)
        local t = {}
        for _, i in ipairs(ids) do t[#t + 1] = f.names[i + 1] end
        table.sort(t)
        return t
    end
    -- graph VIEW: no_self, matching the store's uses/usedby policy
    local function fwd(id, pred)
        return names(f:out(f.it.get(id), fold.PRED[pred], true))
    end
    local function bwd(id, pred)
        return names(f:incoming(f.it.get(id), fold.PRED[pred], true))
    end
    -- the self-loop IS a stored fact (raw slice keeps it)...
    eq({ 'a', 'b', 'c' }, names(f:incoming(f.it.get('c'), fold.PRED.ref)))
    -- ...but the graph view excludes it, as the store does
    eq({ 'b', 'c' }, fwd('a', 'ref'))
    eq({ 'a', 'b' }, bwd('c', 'ref'))         -- callers of c (self excluded)
    eq({ 'v' }, fwd('a', 'use'))
    eq({ 'a' }, bwd('v', 'use'))              -- used-by, free reverse
    eq({ 'b' }, fwd('m.lua', 'reg'))
    eq({ 'm.lua' }, bwd('b', 'reg'))
    eq({ 'other.lua' }, fwd('m.lua', 'import'))
    -- and it agrees with the store, computed independently
    local function storelist(t, key)
        local out = {}
        for _, x in ipairs(t or {}) do
            out[#out + 1] = type(x) == 'table' and (x.to or x.from) or x
        end
        table.sort(out)
        return out
    end
    eq(storelist(store.uses['a']), fwd('a', 'ref'))
    eq(storelist(store.usedby['c']), bwd('c', 'ref'))
    eq(storelist(store.var_usedby['v'], 'from'), bwd('v', 'use'))
    eq(storelist(store.registers['m.lua']), fwd('m.lua', 'reg'))
    eq(storelist(store.imports_out['m.lua']), fwd('m.lua', 'import'))
end)

test('fold: refused calls fold as frontier facts; top-level ones counted', function ()
    local f = fold.build(DATA)
    -- a's frontier: one refused call (mystery); points at the sentinel
    local fr = f:out(f.it.get('a'), fold.PRED.refused)
    eq(1, #fr)
    eq(f.sentinel, fr[1])
    eq(1, f.skipped_refused, 'the fn-less top-level refusal is counted, not folded')
    -- every fact is edges (7) + folded refused (1) = 8
    eq(8, f.m)
end)

test('fold: isolated nodes interned; size is columnar-small', function ()
    local f = fold.build(DATA)
    ok(f.it.get('iso'), 'isolated node exists in the id space')
    eq(0, #f:out(f.it.get('iso')), 'and has no facts')
    -- core = 3 u32 columns + u8 flags + 2 offset arrays + 1 permutation
    eq(f.m * 4 * 3 + f.m + (f.n + 1) * 4 * 2 + f.m * 4, f:bytes())
end)

test('fold: the flags column keeps tier and refusal rule', function ()
    local D = {
        root = '/x',
        nodes = { node('m.lua', 'module'), node('a'), node('b'), node('c') },
        edges = {
            { from = 'a', to = 'b', kind = 'ref', at = { R } },            -- confident
            { from = 'a', to = 'c', kind = 'ref', inferred = true, at = { R } }, -- ~
        },
        calls = {
            { callee = 'x', fn = 'a', file = 'm.lua', line = 1,
                refused = { rule = 'aperture' } },
            { callee = 'y', fn = 'b', file = 'm.lua', line = 2,
                refused = { rule = 'ambiguous' } },
        },
    }
    D.edges[#D.edges + 1] = { from = 'a', to = 'm.lua', kind = 'ref',
        inferred = true, tinf = true, at = { R } } -- graph-VM resolved
    local f = fold.build(D)
    local A, B, C = f.it.get('a'), f.it.get('b'), f.it.get('c')
    eq('matched', f:tier(A, B, fold.PRED.ref))
    eq('inferred', f:tier(A, C, fold.PRED.ref), 'the ~ tier survives the fold')
    eq('typed', f:tier(A, f.it.get('m.lua'), fold.PRED.ref),
        'the graph-VM tier is distinct from ~ (the full ladder, folded)')
    eq({ 'aperture' }, f:refusals(A), "a's frontier rule preserved")
    eq({ 'ambiguous' }, f:refusals(B))
end)

-- ── merge: the concat primitive (record-fold arc step 5) ─────────────────
-- Two chunks with OVERLAPPING-but-differently-ordered node sets (a,b in both;
-- c only in B; iso/v/m.lua only in A) so the merge exercises interner union +
-- id remap, not an identity map. The merged fold must be slice-parity with a
-- monolithic build over the concatenated wide data.
local CA = {
    nodes = { node('m.lua', 'module'), node('a'), node('b'),
        node('v', 'var'), node('iso') },
    edges = {
        { from = 'a', to = 'b', kind = 'ref', at = { R } },
        { from = 'a', to = 'v', kind = 'use', rw = 2, at = { R } }, -- write
        { from = 'm.lua', to = 'b', kind = 'reg', at = { R } },
        { from = 'm.lua', to = 'other.lua', kind = 'import' },
    },
    calls = {
        { callee = 'mystery', fn = 'a', file = 'm.lua', line = 2,
            refused = { rule = 'ambiguous' } },
    },
}
local CB = {
    nodes = { node('c'), node('a'), node('b') },
    edges = {
        { from = 'a', to = 'c', kind = 'ref', inferred = true, at = { R } }, -- ~
        { from = 'b', to = 'c', kind = 'ref', at = { R } },
        { from = 'c', to = 'c', kind = 'ref', at = { R } },   -- self (recursion)
    },
    calls = {
        { callee = 'y', fn = 'b', file = 'm.lua', line = 3,
            refused = { rule = 'blocked' } },
    },
}
local function concat(...)
    local out = {}
    for _, t in ipairs({ ... }) do
        for _, x in ipairs(t) do out[#out + 1] = x end
    end
    return out
end
local MONO = {
    nodes = concat(CA.nodes, CB.nodes),   -- a,b duplicated (interner dedups)
    edges = concat(CA.edges, CB.edges),
    calls = concat(CA.calls, CB.calls),
}

-- canonicalize a fold by NAME (id spaces differ across folds): every node's
-- forward/backward slices per predicate + ref tiers + refusals + rw.
local function canon(f)
    local out = {}
    for id0 = 0, f.n - 1 do
        local rec = { fwd = {}, bwd = {}, tier = {}, rw = {}, refusals = {} }
        for pname, p in pairs(fold.PRED) do
            local fwd = {}
            for _, o in ipairs(f:out(id0, p)) do fwd[#fwd + 1] = f.names[o + 1] end
            table.sort(fwd); rec.fwd[pname] = fwd
            local bwd = {}
            for _, s in ipairs(f:incoming(id0, p)) do bwd[#bwd + 1] = f.names[s + 1] end
            table.sort(bwd); rec.bwd[pname] = bwd
        end
        for _, o in ipairs(f:out(id0, fold.PRED.ref)) do
            rec.tier[f.names[o + 1]] = f:tier(id0, o, fold.PRED.ref)
        end
        for _, o in ipairs(f:out(id0, fold.PRED.use)) do
            rec.rw[f.names[o + 1]] = f:rw(id0, o)
        end
        rec.refusals = f:refusals(id0); table.sort(rec.refusals)
        out[f.names[id0 + 1]] = rec
    end
    return out
end

test('fold.merge: slice-parity with a monolithic build of the concat', function ()
    local merged = fold.merge({ fold.build(CA), fold.build(CB) })
    local mono = fold.build(MONO)
    eq(mono.n, merged.n, 'same node count (interner union)')
    eq(mono.m, merged.m, 'same fact count (column concat)')
    eq(canon(mono), canon(merged))
end)

test('fold.merge: order-independent and idempotent under a single chunk', function ()
    -- a single-fold merge equals the fold itself; swapping chunk order is parity
    local solo = fold.merge({ fold.build(CA) })
    eq(canon(fold.build(CA)), canon(solo))
    local ab = fold.merge({ fold.build(CA), fold.build(CB) })
    local ba = fold.merge({ fold.build(CB), fold.build(CA) })
    eq(canon(ab), canon(ba))
end)

test('fold.merge: ⊤ shared-interner path skips the remap, same result', function ()
    -- build both chunks against ONE shared interner → ids are already global,
    -- so merge auto-detects the ⊤ path (pure column concat, no remap).
    local shared = require('cartograph.csr').interner()
    local fa = fold.build(CA, shared)
    local fb = fold.build(CB, shared)
    ok(fa.it == fb.it, 'the folds share the interner object (⊤ precondition)')
    local top = fold.merge({ fa, fb })
    local mono = fold.build(MONO)
    eq(mono.n, top.n, 'same node count as the monolithic build')
    eq(mono.m, top.m, 'same fact count')
    eq(canon(mono), canon(top), '⊤ merge == monolithic build')
    -- and identical to the ⊥ path (independent interners, remap on merge)
    local bot = fold.merge({ fold.build(CA), fold.build(CB) })
    eq(canon(bot), canon(top), '⊤ == ⊥ (the rung is invisible to the result)')
end)

test('fold.merge: field-record ids remap into the merged fname space', function ()
    -- fldr carries packed field-name ids relative to EACH fold's fnames; the
    -- merge must re-intern them or flds() reads the wrong names post-union.
    local FA = {
        nodes = { node('a'), node('t', 'var') },
        edges = { { from = 'a', to = 't', kind = 'use',
            flds = { x = 1, y = 2 }, at = { R } } },
    }
    local FB = {
        nodes = { node('b'), node('u', 'var') },
        edges = { { from = 'b', to = 'u', kind = 'use',
            flds = { z = 3, x = 2 }, at = { R } } }, -- x shared name, diff mode
    }
    local merged = fold.merge({ fold.build(FA), fold.build(FB) })
    local mono = fold.build({
        nodes = concat(FA.nodes, FB.nodes),
        edges = concat(FA.edges, FB.edges),
    })
    eq(mono:flds(mono.it.get('a'), mono.it.get('t')),
        merged:flds(merged.it.get('a'), merged.it.get('t')))
    eq(mono:flds(mono.it.get('b'), mono.it.get('u')),
        merged:flds(merged.it.get('b'), merged.it.get('u')))
    eq({ x = 1, y = 2 }, merged:flds(merged.it.get('a'), merged.it.get('t')))
    eq({ z = 3, x = 2 }, merged:flds(merged.it.get('b'), merged.it.get('u')))
end)
