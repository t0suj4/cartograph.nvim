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

test('callrec: read accessors for scalar fields, incl. resolution-era', function ()
    -- syntactic (immutable columns in callcols) + resolution-era READ accessors
    -- (to/prov — read seam; they live in the callcols mutable overlay, writes
    -- stay direct until the write brick)
    eq('function', type(cr.file)); eq('function', type(cr.to)); eq('function', type(cr.prov))
    eq('a', cr.to({ to = 'a' })); eq('base', cr.prov({ prov = 'base' }))
    -- SUBTABLE / transient fields are NOT scalar read-accessors here (refused is
    -- a table via refused.lua; conf is a transient confirm mark)
    eq(nil, cr.refused)
    eq(nil, cr.conf)
end)

test('callrec: nil fields pass through as nil', function ()
    local c = { file = 'm.lua' }
    eq(nil, cr.fn(c))
    eq(nil, cr.callee(c))
    eq(nil, cr.line(c))
end)

test('callrec: record() materializes a detached editable copy (record branch)', function ()
    local c = { file = 'a.lua', callee = 'f', fn = 'a.lua::g@1', line = 10,
        to = 'a.lua::f@9', argv = { 1, 2 } }
    local rec = cr.record(c)
    eq(c.file, rec.file); eq(c.fn, rec.fn); eq(c.to, rec.to); eq(c.argv, rec.argv)
    rec.fn = 'x'                         -- editing the copy never touches the call
    eq('a.lua::g@1', c.fn)
    eq(true, rec ~= c)
end)

test('callrec: record() reconstructs a callcols proxy row (columns+overlay+residual)', function ()
    local callcols = require 'cartograph.callcols'
    local calls = { { file = 'a.lua', callee = 'f', fn = 'a.lua::g@1', line = 3,
        to = 'a.lua::f@9', inferred = true, argv = { 'x' } } }
    local v = callcols.view(calls)
    local rec = cr.record(v.rows[1])     -- a proxy row, not a plain record
    eq('a.lua', rec.file); eq('f', rec.callee); eq('a.lua::g@1', rec.fn)
    eq(3, rec.line); eq('a.lua::f@9', rec.to); eq(true, rec.inferred)
    eq(calls[1].argv, rec.argv)          -- residual field carried through
    rec.fn = 'edited'                    -- detached: the store is untouched
    eq('a.lua::g@1', callcols.get(v.cc, 'fn', 1))
end)
