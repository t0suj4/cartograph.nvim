-- The transport contract (transport.lua): WHERE bytes come from, separated from
-- what reads them. Step A wires ONE transport (disk) and moves the extractor's 6
-- io.open sites, its fs_scandir walk and its fs_stat stamp behind it, so the
-- refactor is provable rather than plausible — hence the fidelity tests here
-- pin the EDGE cases the old inline code had, not just the happy path.
--
-- The routing/partial-capability tests matter more than they look: they pin the
-- reason this is a three-op contract instead of one read(). A zip serves list
-- and stamp from its central directory (uncompressed) but needs inflate to
-- read, so "enumerable and stampable but not readable" is a real state, and it
-- must degrade like an unreadable path rather than erroring.

local transport = require 'cartograph.transport'

local function tmpfile(text)
    local p = vim.fn.tempname()
    local fd = assert(io.open(p, 'w')); fd:write(text); fd:close()
    return p
end

test('transport: disk read returns whole contents, nil when absent', function ()
    local p = tmpfile('alpha\nbeta\n')
    eq('alpha\nbeta\n', transport.read(p))
    vim.fn.delete(p)
    eq(nil, transport.read(p))
    eq(nil, transport.read(vim.fn.tempname() .. '/nope/nope.lua'))
end)

-- FIDELITY: the sites this replaced did `io.open(p,'r')` then `fd:read('a')`. A
-- DIRECTORY opens on Linux and reads nil, so the old code got src=nil with a
-- live handle. Callers branch on that nil; read() must reproduce it rather than
-- returning '' (which would parse as an empty file and mint a real module node).
test('transport: a directory reads nil, not empty string', function ()
    local d = vim.fn.tempname(); vim.fn.mkdir(d, 'p')
    eq(nil, transport.read(d))
    vim.fn.delete(d, 'rf')
end)

test('transport: lines splits contents; nil when unreadable', function ()
    local p = tmpfile('a\nb\nc')
    eq({ 'a', 'b', 'c' }, transport.lines(p))
    vim.fn.delete(p)
    eq(nil, transport.lines(p))
end)

-- the stamp FORMAT is load-bearing: data.stamps values are compared against
-- store.content's cache key and the cache's validity keys, so a change here
-- silently invalidates every warm open.
test('transport: stamp is mtime.sec:mtime.nsec:size, nil when absent', function ()
    local p = tmpfile('12345')
    local s = transport.stamp(p)
    local sec, nsec, size = tostring(s):match('^(%d+):(%d+):(%d+)$')
    ok(sec ~= nil, 'stamp matches sec:nsec:size — got ' .. tostring(s))
    eq(5, tonumber(size))
    local st = vim.uv.fs_stat(p)
    eq(st.mtime.sec, tonumber(sec)); eq(st.mtime.nsec, tonumber(nsec))
    vim.fn.delete(p)
    eq(nil, transport.stamp(p))
end)

test('transport: dir yields entries with types; yields NOTHING when unreadable',
    function ()
    local d = vim.fn.tempname(); vim.fn.mkdir(d .. '/sub', 'p')
    local fd = assert(io.open(d .. '/f.lua', 'w')); fd:write('x'); fd:close()
    local seen = {}
    for name, ty in transport.dir(d) do seen[name] = ty end
    eq('file', seen['f.lua'])
    eq('directory', seen['sub'])
    -- an unreadable container is the `while it do` guard the walk used to carry
    -- inline: the loop body simply never runs, no error
    local n = 0
    for _ in transport.dir(d .. '/absent') do n = n + 1 end
    eq(0, n)
    vim.fn.delete(d, 'rf')
end)

test('transport: for_path falls back to disk when nothing is registered', function ()
    eq('disk', transport.for_path('/any/path.lua').name)
end)

-- ROUTING: a registered transport shadows disk for the paths it claims, and only
-- those. This is the whole mechanism by which step B is an addition.
test('transport: a registered transport claims its own paths only', function ()
    local p = tmpfile('on disk\n')
    local fake = transport.register {
        name = 'fake',
        claims = function (path) return path:match('%.fake$') ~= nil end,
        read = function () return 'from fake' end,
        stamp = function () return 'fakestamp' end,
    }
    eq('fake', transport.for_path('/x/y.fake').name)
    eq('from fake', transport.read('/x/y.fake'))
    eq('fakestamp', transport.stamp('/x/y.fake'))
    -- ... and disk still answers everything it did before
    eq('disk', transport.for_path(p).name)
    eq('on disk\n', transport.read(p))
    transport.unregister(fake)
    eq('disk', transport.for_path('/x/y.fake').name)
    vim.fn.delete(p)
end)

-- PARTIAL CAPABILITY: the reason list/stamp/read are separate ops. A transport
-- that can enumerate and stamp but not read (a zip with no libz) must degrade to
-- the same nil an unreadable file gives, so no caller needs a new branch.
test('transport: a transport missing an op degrades to nil, never errors', function ()
    local partial = transport.register {
        name = 'partial',
        claims = function (path) return path:match('%.partial$') ~= nil end,
        stamp = function () return 'stamped' end,
        dir = function () return function () return nil end end,
        -- deliberately NO read
    }
    eq('stamped', transport.stamp('/a/b.partial'))
    eq(nil, transport.read('/a/b.partial'))   -- not an error
    eq(nil, transport.lines('/a/b.partial'))  -- derived from read, same nil
    eq(nil, transport.stat('/a/b.partial'))   -- no stat op either
    eq(nil, transport.realpath('/a/b.partial'))
    transport.unregister(partial)
end)
