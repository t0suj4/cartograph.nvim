-- Call-record accessors (callrec.lua): the read seam over data.calls records
-- (record-fold arc step 2). Today identity passthroughs; the spec pins the
-- contract (and the FIELD SET) so a step-3 dual-mode swap must keep it.

local cr = require 'cartograph.callrec'

test('callrec: accessors return the syntactic-immutable call fields', function ()
    local c = { fn = 'm.lua::f@1', callee = 'g', full = 'M.g', method = 'g',
        file = 'm.lua', line = 12, to = 'm.lua::g@3', refused = { rule = 'x' } }
    eq('m.lua::f@1', cr.fn(c))
    eq('g', cr.callee(c))
    eq('M.g', cr.full(c))
    eq('g', cr.method(c))
    eq('m.lua', cr.file(c))
    eq(12, cr.line(c))
end)

test('callrec: only the fold-candidate fields have accessors', function ()
    -- the resolution-era MUTABLE fields (to/refused/conf/inferred) are
    -- deliberately absent — they cannot fold into an immutable column
    eq('function', type(cr.file))
    eq(nil, cr.to, 'c.to is mutated post-ingest → not seamed')
    eq(nil, cr.refused, 'c.refused is mutated post-ingest → not seamed')
    eq(nil, cr.conf)
    eq(nil, cr.inferred)
end)

test('callrec: nil fields pass through as nil', function ()
    local c = { file = 'm.lua' }
    eq(nil, cr.fn(c))
    eq(nil, cr.callee(c))
    eq(nil, cr.line(c))
end)
