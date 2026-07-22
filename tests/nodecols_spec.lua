-- nodecols: the resident columnar NODE store (the node twin of callcols).
-- Scalar fields (id/name/kind/file/order/flags/range) ride immutable width
-- columns; the detail TABLES (df/flow/params/…) ride the per-row residual. The
-- gate is: a nodecols row is a faithful drop-in for a raw node record, and
-- record() materializes back identically.

local nodecols = require 'cartograph.nodecols'

local R = { start = { line = 1, char = 0 }, ['end'] = { line = 3, char = 2 } }
local function nodes()
    local df = { { def = 'x' } }
    return {
        { id = 'a.lua::f@1', name = 'f', kind = 'function', file = 'a.lua', order = 1,
            range = R, top = true, exported = true, df = df, params = { 'p1' } },
        { id = 'a.lua', name = 'a.lua', kind = 'module', file = 'a.lua', order = -1,
            unparsed = true }, -- module, sparse (no range/df)
        { id = 'b.lua::f@9', name = 'f', kind = 'function', file = 'b.lua', order = 2,
            range = R }, -- shared name/file-pooled
    }
end

test('nodecols: proxy reads scalar columns and residual tables', function ()
    local v = nodecols.view(nodes())
    local n = v.rows[1]
    eq('a.lua::f@1', n.id); eq('f', n.name); eq('function', n.kind)
    eq('a.lua', n.file); eq(1, n.order)
    eq(1, n.range.start.line); eq(2, n.range['end'].char)
    eq(true, n.top); eq(true, n.exported)
    eq(nil, n.torn)                                  -- absent flag → nil
    eq({ { def = 'x' } }, n.df)                       -- detail table via residual
    eq({ 'p1' }, n.params)
    eq('module', v.rows[2].kind); eq(true, v.rows[2].unparsed)
    eq(nil, v.rows[2].range)                          -- absent range → nil
    eq('b.lua', v.rows[3].file)                       -- pooled independently
end)

test('nodecols: the residual table is the SAME reference (not a copy)', function ()
    local ns = nodes()
    local v = nodecols.view(ns)
    eq(true, v.rows[1].df == ns[1].df)                -- reference-faithful, like a raw read
end)

test('nodecols: record() materializes columns + residual', function ()
    local v = nodecols.view(nodes())
    eq({ id = 'a.lua::f@1', name = 'f', kind = 'function', file = 'a.lua', order = 1,
        range = R, top = true, exported = true, df = { { def = 'x' } }, params = { 'p1' } },
        nodecols.record(v, 1))
    eq({ id = 'a.lua', name = 'a.lua', kind = 'module', file = 'a.lua', order = -1,
        unparsed = true }, nodecols.record(v, 2))
end)
