-- cartograph.stampcache — a CONTENT-stamped store (CART-1303): keys hash the inputs' TEXT, never an mtime (CART-1301);
-- answers round-trip — `false` included — and a key holding a NUL (a layouts key is `T \0 path`) survives LuaJIT's
-- io.lines(), which mangles a raw NUL line and glues it onto the next.
local SC = require 'cartograph.stampcache'

test('stampcache: answers round-trip across logs — false is an answer, a miss is not; a NUL in a key does not corrupt its neighbour', function ()
    local scope = SC.key({ 'spec', tostring(vim.uv.hrtime()) })
    local L = SC.log('spec', scope)
    L.put('PyObject\0ob_type', { off = 8, to = { k = 'p' } })
    L.put('plain', false)
    L.put('next', { off = 1 })
    local R = SC.log('spec', scope)
    eq({ { off = 8, to = { k = 'p' } }, true }, { R.get('PyObject\0ob_type') })
    eq({ false, true }, { R.get('plain') }, 'a stored "none" is found')
    eq({ { off = 1 }, true }, { R.get('next') }, 'the line after a NUL key is intact')
    eq({ nil, false }, { R.get('absent') })
    vim.fn.delete(SC.root_dir() .. '/spec', 'rf')
end)

test('stampcache: keys hash CONTENT — length-prefixed parts, so concatenation cannot collide; file hashes by bytes', function ()
    ok(SC.key({ 'ab', 'c' }) ~= SC.key({ 'a', 'bc' }), 'parts are length-prefixed')
    eq(SC.key({ 'x' }), SC.key({ 'x' }))
    local p = vim.fn.tempname()
    local fd = io.open(p, 'w'); fd:write('one'); fd:close()
    local h1 = SC.file(p)
    SC._forget()
    fd = io.open(p, 'w'); fd:write('two'); fd:close()
    ok(SC.file(p) ~= h1, 'a changed file is a changed key, whatever its mtime')
end)

test('stampcache: CARTOGRAPH_STAMPCACHE=0 is a log that remembers nothing (the A/B that proves a cache changes no answer)', function ()
    local saved = vim.env.CARTOGRAPH_STAMPCACHE
    vim.env.CARTOGRAPH_STAMPCACHE = '0'
    local L = SC.log('spec', SC.key({ 'off' }))
    L.put('k', 1)
    eq({ nil, false }, { L.get('k') })
    vim.env.CARTOGRAPH_STAMPCACHE = saved
end)

test('stampcache.tree: a directory stamped by CONTENT — an edit, a new file, a symlink retarget change it; a rewrite of the same bytes does not', function ()
    local d = vim.fn.tempname()
    vim.fn.mkdir(d .. '/sub', 'p')
    local function put(rel, s) local fd = io.open(d .. '/' .. rel, 'wb'); fd:write(s); fd:close() end
    put('a.c', 'int a;\n'); put('sub/b.h', 'bin\0ary')
    vim.uv.fs_symlink('a.c', d .. '/l')
    local function stamp() SC._forget(); return (SC.tree(d)) end
    local h0 = stamp()
    eq(h0, stamp())
    put('a.c', 'int a;\n')
    eq(h0, stamp(), 'the same bytes rewritten (a new mtime) is the same stamp')
    put('sub/b.h', 'bin\0arY')
    local h1 = stamp()
    ok(h1 ~= h0, 'a byte after a NUL is content too')
    put('c.c', '')
    local h2 = stamp()
    ok(h2 ~= h1, 'a new empty file')
    os.remove(d .. '/l'); vim.uv.fs_symlink('sub/b.h', d .. '/l')
    ok(stamp() ~= h2, 'a symlink is its target')
end)

test('stampcache.value: a value hashed by its DATA — table order does not matter, key types do; more than data has no hash', function ()
    local ffi = require 'ffi'
    local a, b = {}, {}
    for i = 1, 50 do a['k' .. i] = i end
    for i = 50, 1, -1 do b['k' .. i] = i end
    eq(SC.value(a), SC.value(b), 'insertion order is not part of the value')
    ok(SC.value({ [1] = 'x' }) ~= SC.value({ ['1'] = 'x' }), 'a number key is not a string key')
    ok(SC.value({ 'ab', 'c' }) ~= SC.value({ 'a', 'bc' }), 'scalars are length-prefixed')
    ok(SC.value({ w = ffi.new('uint64_t', 1) }) ~= SC.value({ w = 1 }), 'a 64-bit word is not a number')
    eq(SC.value({ w = ffi.new('uint64_t', 7) }), SC.value({ w = ffi.new('uint64_t', 7) }))
    local cyc = {}; cyc.self = cyc
    eq({ nil, 'a function' }, { SC.value({ f = print }) })
    eq({ nil, 'a table with a metatable' }, { SC.value(setmetatable({}, {})) })
    eq({ nil, 'a cycle' }, { SC.value(cyc) })
    local shared = { 1 }
    ok(SC.value({ shared, shared }), 'a SHARED table is not a cycle')
end)

test('stampcache.blob: a whole value per key — 64-bit words and NUL bytes come back equal; a value string.buffer would change is refused; a torn blob is a miss', function ()
    local ffi = require 'ffi'
    local S = SC.blob('spec-blob')
    local key = SC.key({ 'blob', tostring(vim.uv.hrtime()) })
    local v = { w = ffi.new('uint64_t', 0xdeadbeef) * 2 ^ 20, s = 'x\0y', t = { 1, false, 'z' } }
    ok(S.put(key, v))
    local back, found = S.get(key)
    eq({ true, SC.value(v) }, { found, SC.value(back) })
    eq({ nil, 'a table with a metatable' }, { S.put(SC.key({ 'meta' }), { m = setmetatable({}, { __index = {} }) }) })
    local p = SC.root_dir() .. '/spec-blob/' .. key:sub(1, 2) .. '/' .. key
    local fd = io.open(p, 'wb'); fd:write('\1\2'); fd:close()
    eq({ nil, false }, { S.get(key) }, 'a blob that does not decode is a miss, not an error')
    vim.fn.delete(SC.root_dir() .. '/spec-blob', 'rf')
end)
