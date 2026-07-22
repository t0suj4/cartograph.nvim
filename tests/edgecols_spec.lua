-- edgecols: the resident columnar EDGE store (the edge twin of callcols/nodecols).
-- Scalar fields (from/to/kind/bind + inferred/self/tinf flags) ride immutable
-- columns; the detail (at range-LIST, flds, sparse gw/rw) rides the residual.
-- Gate: a row is a faithful drop-in for a raw edge record; record() round-trips.

local edgecols = require 'cartograph.edgecols'

local A = { { start = { line = 1, char = 0 }, ['end'] = { line = 1, char = 4 } } }
local function edges()
    return {
        { from = 'a.lua::g@1', to = 'a.lua::f@9', kind = 'ref', inferred = true,
            at = A, rw = 2 }, -- at is a LIST of ranges; rw sparse
        { from = 'a.lua::g@1', to = 'a.lua::h@3', kind = 'ref', self = true,
            at = A, flds = { x = 'r' } },
        { from = 'b.lua', to = 'a.lua::f@9', kind = 'reg' }, -- from-pooled, sparse
    }
end

test('edgecols: proxy reads scalar columns and residual detail', function ()
    local v = edgecols.view(edges())
    local e = v.rows[1]
    eq('a.lua::g@1', e.from); eq('a.lua::f@9', e.to); eq('ref', e.kind)
    eq(true, e.inferred); eq(nil, e.self)             -- absent flag → nil
    eq(A, e.at)                                        -- range-list via residual
    eq(2, e.rw)                                        -- sparse int via residual
    eq(nil, e.bind)                                    -- absent str → nil
    eq(true, v.rows[2].self); eq({ x = 'r' }, v.rows[2].flds)
    eq('reg', v.rows[3].kind); eq('b.lua', v.rows[3].from)
end)

test('edgecols: residual detail is the SAME reference (not a copy)', function ()
    local es = edges()
    local v = edgecols.view(es)
    eq(true, v.rows[1].at == es[1].at)                 -- reference-faithful
end)

test('edgecols: record() materializes columns + residual', function ()
    local v = edgecols.view(edges())
    eq({ from = 'a.lua::g@1', to = 'a.lua::f@9', kind = 'ref', inferred = true,
        at = A, rw = 2 }, edgecols.record(v, 1))
    eq({ from = 'b.lua', to = 'a.lua::f@9', kind = 'reg' }, edgecols.record(v, 3))
end)
