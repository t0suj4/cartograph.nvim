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
