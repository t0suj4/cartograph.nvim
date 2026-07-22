-- rescols: the IN-RESOLUTION columnar call store. Unlike callcols (post-
-- resolution: `full` immutable), here `full` is a MUTABLE overlay field (resolve_
-- returns rewrites it), and argv survives as columns with a k/to/up overlay. The
-- gate is: a rescols row is a drop-in for a raw call record through the exact
-- mutations M.audit/M.relink perform, and materializes back identically.

local rescols = require 'cartograph.rescols'

local R = { start = { line = 5, char = 2 }, ['end'] = { line = 5, char = 9 } }
local function calls()
    return {
        { file = 'a.lua', callee = 'f', fn = 'a.lua::g@1', full = 'M.f', line = 10,
            method = true, at = R,
            argv = { { k = 'local', name = 'cb' }, { k = 'lit', v = 'x', kw = true } } },
        { file = 'a.lua', callee = 'h', fn = 'a.lua::g@1', line = 22,
            refused = { rule = 'nodef' } }, -- no argv; a residual refusal table
        { file = 'b.lua', callee = 'f', line = 0, argv = {} }, -- empty argv (present but 0)
    }
end

test('rescols: proxy reads scalar columns, residual, and columnar argv', function ()
    local v = rescols.view(calls())
    local c = v.rows[1]
    eq('a.lua', c.file); eq('f', c.callee); eq('a.lua::g@1', c.fn)
    eq('M.f', c.full); eq(10, c.line); eq(true, c.method)
    eq(5, c.at.start.line); eq(9, c.at['end'].char)
    eq(nil, c.to)                                  -- unresolved → nil
    eq('nodef', v.rows[2].refused.rule)            -- residual (non-scalar) field
    -- columnar argv: a stable element-handle array
    eq(2, #c.argv)
    eq('local', c.argv[1].k); eq('cb', c.argv[1].name)
    eq('lit', c.argv[2].k); eq('x', c.argv[2].v); eq(true, c.argv[2].kw) -- kw rides element residual
    eq(nil, v.rows[2].argv)                         -- no argv field → nil, like the record
    eq(0, #v.rows[3].argv)                          -- present-but-empty stays empty
end)

test('rescols: resolution writes go to the overlay/residual; argv upgrades persist', function ()
    local v = rescols.view(calls())
    local c = v.rows[1]
    -- the M.relink main-loop shape
    c.to = 'a.lua::f@9'; c.inferred = true
    eq('a.lua::f@9', c.to); eq(true, c.inferred)
    -- resolve_returns rewrites `full` — MUTABLE here (would assert on callcols)
    c.full = 'a.lua::M.f@1'
    eq('a.lua::M.f@1', c.full)
    -- a residual resolution field (refused table) clears
    v.rows[2].refused = nil
    eq(nil, v.rows[2].refused)
    -- the callback-mirror argv upgrade: a.k/a.to/a.up in place
    local a = c.argv[1]
    a.k = 'func'; a.to = 'a.lua::cb@3'; a.up = true
    eq('func', a.k); eq('a.lua::cb@3', a.to); eq(true, a.up)
    -- the SAME handle array is returned each read, so the mutation persisted
    eq('func', c.argv[1].k)
end)

test('rescols: immutable parse-fixed fields refuse writes (calls and argv)', function ()
    local v = rescols.view(calls())
    eq(false, pcall(function () v.rows[1].file = 'x.lua' end))
    eq(false, pcall(function () v.rows[1].callee = 'g' end))
    eq(false, pcall(function () v.rows[1].argv = {} end))        -- no wholesale argv replace
    eq(false, pcall(function () v.rows[1].argv[2].name = 'y' end)) -- argv name is immutable
    eq('a.lua', v.rows[1].file)                                   -- unchanged
end)

test('rescols: record() materializes columns + overlay + residual + argv', function ()
    local v = rescols.view(calls())
    -- untouched call round-trips exactly (note: no `to`, argv reconstructed)
    eq({ file = 'a.lua', callee = 'f', fn = 'a.lua::g@1', full = 'M.f', line = 10,
        method = true, at = R,
        argv = { { k = 'local', name = 'cb' }, { k = 'lit', v = 'x', kw = true } } },
        rescols.record(v, 1))
    -- residual-only call, no argv
    eq({ file = 'a.lua', callee = 'h', fn = 'a.lua::g@1', line = 22,
        refused = { rule = 'nodef' } }, rescols.record(v, 2))
    -- present-but-empty argv survives as {}
    eq({ file = 'b.lua', callee = 'f', line = 0, argv = {} }, rescols.record(v, 3))
end)

test('rescols: materialize reflects the resolution mutations', function ()
    local v = rescols.view(calls())
    v.rows[1].to = 'a.lua::f@9'; v.rows[1].inferred = true
    v.rows[1].full = 'a.lua::M.f@1'
    local a = v.rows[1].argv[1]; a.k = 'func'; a.to = 'a.lua::cb@3'; a.up = true
    eq({ file = 'a.lua', callee = 'f', fn = 'a.lua::g@1', full = 'a.lua::M.f@1',
        to = 'a.lua::f@9', inferred = true, line = 10, method = true, at = R,
        argv = { { k = 'func', name = 'cb', to = 'a.lua::cb@3', up = true },
            { k = 'lit', v = 'x', kw = true } } },
        rescols.record(v, 1))
end)

-- STEP 2 (the parent-merge peak lever): the streaming accumulator folds chunks
-- into columns and drops the records; finalize == build-from-whole (record-for-
-- record, argv included) even with out-of-order batches, canonical reorder, and
-- a demanded file's duplicate deduped away. tools/rescolacc.lua is the corpus gate.
test('rescols: accumulator (out-of-order batches + reorder + dedup) == view', function ()
    local cs = calls()
    local ref = rescols.view(cs) -- reference: canonical order a.lua,a.lua,b.lua
    -- file -> canonical rank (first appearance): a.lua=1, b.lua=2
    local fileorder = { ['a.lua'] = 1, ['b.lua'] = 2 }
    local acc = rescols.accumulator({ fileorder = fileorder })
    acc.add({ cs[3] })          -- b.lua first (arrival ≠ canonical)
    acc.add({ cs[1], cs[2] })   -- then a.lua's two calls
    acc.add({ cs[3] })          -- duplicate b.lua file → deduped away
    local store = acc.finalize()
    eq(3, store.cc.n)           -- dedup: 3 rows, not 4
    -- reorder put a.lua rows first, b.lua last — matching the view
    eq(rescols.record(ref, 1), rescols.record(store, 1))
    eq(rescols.record(ref, 2), rescols.record(store, 2))
    eq(rescols.record(ref, 3), rescols.record(store, 3))
end)

test('rescols: accumulator store drives resolution writes (index-form drop-in)', function ()
    local acc = rescols.accumulator()      -- no reorder (arrival == canonical)
    acc.add(calls())
    local store = acc.finalize()
    local cv = require('cartograph.callview').of({ _callstore = store })
    eq('f', cv.get(1, 'callee'))            -- immutable column read
    eq('local', cv.aget(1, 1, 'k'))         -- columnar argv read
    cv.set(1, 'to', 'a.lua::f@9')           -- overlay write
    cv.set(2, 'refused', nil)               -- residual write (clears the table)
    cv.aset(1, 1, 'k', 'func'); cv.aset(1, 1, 'up', true) -- argv upgrade in place
    eq('a.lua::f@9', cv.get(1, 'to'))
    eq(nil, cv.get(2, 'refused'))
    eq('func', cv.aget(1, 1, 'k')); eq(true, cv.aget(1, 1, 'up'))
end)
