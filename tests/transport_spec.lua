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

test('transport: a bare stack falls back to disk', function ()
    eq('disk', transport.for_path('/any/path.lua').name)
    eq('disk', transport.build({ { kind = 'disk' } }).for_path('/x.lua').name)
end)

-- ROUTING is a property of a STACK VALUE, not of module state. That matters
-- beyond tidiness: extraction runs in SPAWNED processes (parallel.lua:149) that
-- receive their job as JSON, so a registry mutated in the parent could never
-- reach a worker — every claimed path would silently fall back to disk. A stack
-- is built from a declarative spec that a jobfile CAN carry.
test('transport: a built stack claims its own paths only', function ()
    local p = tmpfile('on disk\n')
    transport.kinds.faketest = function (cfg)
        return {
            name = 'fake',
            claims = function (path) return path:match('%.fake$') ~= nil end,
            read = function () return cfg.payload end,
            stamp = function () return 'fakestamp' end,
        }
    end
    local stack = transport.build { { kind = 'faketest', payload = 'from fake' },
        { kind = 'disk' } }
    eq('fake', stack.for_path('/x/y.fake').name)
    eq('from fake', stack.read('/x/y.fake'))
    eq('fakestamp', stack.stamp('/x/y.fake'))
    -- ... while disk still answers everything it did before
    eq('disk', stack.for_path(p).name)
    eq('on disk\n', stack.read(p))
    -- ... and the module-level default is UNTOUCHED: no global was mutated
    eq('disk', transport.for_path('/x/y.fake').name)
    transport.kinds.faketest = nil
    vim.fn.delete(p)
end)

-- the stack carries the DATA it was built from, which is the half that crosses a
-- process boundary. Without this a worker cannot rebuild the parent's stack.
test('transport: a stack keeps its declarative spec for the wire', function ()
    local spec = { { kind = 'disk' } }
    local stack = transport.build(spec)
    eq(spec, stack.spec)
    eq('table', type(vim.json.decode(vim.json.encode(stack.spec))))
end)

test('transport: an unknown kind is an ERROR, not a silent disk fallback', function ()
    local ok_, err = pcall(transport.build, { { kind = 'nosuchkind' } })
    eq(false, ok_)
    ok(tostring(err):match('unknown kind') ~= nil, 'says which: ' .. tostring(err))
end)

-- PARTIAL CAPABILITY: the reason list/stamp/read are separate ops. A transport
-- that can enumerate and stamp but not read (a zip with no libz) must degrade to
-- the same nil an unreadable file gives, so no caller needs a new branch.
test('transport: a stack entry missing an op degrades to nil, never errors', function ()
    transport.kinds.partialtest = function ()
        return {
            name = 'partial',
            claims = function (path) return path:match('%.partial$') ~= nil end,
            stamp = function () return 'stamped' end,
            dir = function () return function () return nil end end,
            -- deliberately NO read
        }
    end
    local stack = transport.build { { kind = 'partialtest' } }
    eq('stamped', stack.stamp('/a/b.partial'))
    eq(nil, stack.read('/a/b.partial'))   -- not an error
    eq(nil, stack.lines('/a/b.partial'))  -- derived from read, same nil
    eq(nil, stack.stat('/a/b.partial'))   -- no stat op either
    eq(nil, stack.realpath('/a/b.partial'))
    transport.kinds.partialtest = nil
end)

-- a kind whose substrate is genuinely absent (no libz) returns nil and is
-- SKIPPED, leaving the rest of the stack working rather than failing the build
test('transport: a kind returning nil is skipped, not fatal', function ()
    transport.kinds.absenttest = function () return nil end
    local stack = transport.build { { kind = 'absenttest' }, { kind = 'disk' } }
    local p = tmpfile('still works\n')
    eq('still works\n', stack.read(p))
    transport.kinds.absenttest = nil
    vim.fn.delete(p)
end)

-- ── failure has two kinds ────────────────────────────────────────────────────
-- The soundness half. The extractor turns "no content" into a CONFIDENT NEGATIVE
-- FACT (a call into a file it cannot read is classified `external` = "project
-- boundary"), so absence and indeterminacy must not arrive as the same nil.

local function unreadable(text)
    local d = vim.fn.tempname(); vim.fn.mkdir(d, 'p')
    local p = d .. '/locked.lua'
    local fd = assert(io.open(p, 'w')); fd:write(text or 'x'); fd:close()
    vim.fn.system({ 'chmod', '000', p })
    -- running as root defeats chmod; the caller skips rather than asserting a
    -- property the environment cannot exhibit
    local still = io.open(p, 'r')
    if still then still:close(); vim.fn.delete(d, 'rf'); return nil end
    return p, d
end

test('transport: ENOENT is ABSENT, an unreadable file is UNAVAILABLE', function ()
    local missing = vim.fn.tempname() .. '/gone.lua'
    local src, err = transport.read(missing)
    eq(nil, src); eq(transport.ABSENT, err)
    local p, d = unreadable()
    if not p then skip 'running as root — chmod 000 is still readable' end
    local src2, err2 = transport.read(p)
    eq(nil, src2); eq(transport.UNAVAILABLE, err2)
    vim.fn.system({ 'chmod', '644', p }); vim.fn.delete(d, 'rf')
end)

-- what keeps an unavailable file cache-honest: stat succeeds where open fails, so
-- the frontier node still gets a validity key and a later refresh notices when
-- the file becomes readable.
test('transport: an UNREADABLE file can still be STAMPED', function ()
    local p, d = unreadable('12345')
    if not p then skip 'running as root — chmod 000 is still readable' end
    local s, err = transport.stamp(p)
    eq(nil, err)
    ok(s ~= nil and s:match('^%d+:%d+:5$') ~= nil, 'stamped despite unreadable: ' .. tostring(s))
    vim.fn.system({ 'chmod', '644', p }); vim.fn.delete(d, 'rf')
end)

test('transport: a missing op is UNAVAILABLE, never ABSENT', function ()
    transport.kinds.noreadtest = function ()
        return {
            name = 'noread',
            claims = function (path) return path:match('%.noread$') ~= nil end,
            stamp = function () return 'k' end,
        }
    end
    local stack = transport.build { { kind = 'noreadtest' } }
    local _, err = stack.read('/x.noread')
    eq(transport.UNAVAILABLE, err) -- "I cannot answer" is not "it is not there"
    transport.kinds.noreadtest = nil
end)

-- ── the extractor's reaction: a frontier, not a deletion ─────────────────────
-- Measured before the fix: making the callee's file unreadable dropped its module
-- node entirely (modules 2 -> 1) and the call to it became `external`.
local function fixture()
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local function w(rel, s)
        local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(s); fd:close()
    end
    w('lib.lua', 'local function helper(x) return x + 1 end\nreturn { helper = helper }\n')
    w('main.lua', "local lib = require 'lib'\n"
        .. 'local function run() return lib.helper(1) end\nreturn { run = run }\n')
    return root
end

test('transport: an UNAVAILABLE file stays a stamped unparsed frontier', function ()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not pcall(vim.treesitter.language.add, 'lua') then skip 'no lua parser' end
    local ts = require 'cartograph.providers.treesitter'
    local root = fixture()
    vim.fn.system({ 'chmod', '000', root .. '/lib.lua' })
    local probe = io.open(root .. '/lib.lua', 'r')
    if probe then probe:close(); vim.fn.delete(root, 'rf'); skip 'running as root' end
    local d = ts.extract(root)
    local mods, unp = 0, 0
    for _, n in ipairs(d.nodes or {}) do
        if n.kind == 'module' then
            mods = mods + 1
            if n.unparsed and n.file == 'lib.lua' then unp = unp + 1 end
        end
    end
    eq(2, mods)                       -- the file did NOT vanish
    eq(1, unp)                        -- ... it became an opaque frontier
    eq(true, (d.stamps or {})['lib.lua'] ~= nil) -- ... and it is stamped
    local roster = {}
    for _, f in ipairs(d.unparsed or {}) do roster[f] = true end
    eq(true, roster['lib.lua'] == true)          -- ... and on the roster
    vim.fn.system({ 'chmod', '644', root .. '/lib.lua' }); vim.fn.delete(root, 'rf')
end)

-- THE THREADING, end to end. A worker receives its transport as a JSON spec, so
-- extract must accept the DECLARATIVE form and not just a live stack — this is
-- the path parallel.lua ships through a jobfile.
test('transport: extract accepts a declarative spec, same graph as the default',
    function ()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not pcall(vim.treesitter.language.add, 'lua') then skip 'no lua parser' end
    local ts = require 'cartograph.providers.treesitter'
    local root = fixture()
    local plain = ts.extract(root)
    local spec = ts.extract(root, { transport = { { kind = 'disk' } } })
    local live = ts.extract(root, { transport = transport.build { { kind = 'disk' } } })
    eq(#(plain.nodes or {}), #(spec.nodes or {}))
    eq(#(plain.calls or {}), #(spec.calls or {}))
    eq(#(plain.nodes or {}), #(live.nodes or {}))
    eq(plain.stamps['lib.lua'], spec.stamps['lib.lua'])
    vim.fn.delete(root, 'rf')
end)

-- WAS RED. The frontier node surviving is not enough: the CALL into it was still
-- disposed `external` — "this is the project boundary" — a confident claim built
-- on a failed read, feeding :CartographExternals and the portability report.
-- Fixed in the SHARED resolution pass (resolve_module_alias), not at the 4
-- mirrored EXT.nodef sites: the evidence is an explicit import BINDING to a file
-- whose module node is unparsed, which is narrow enough to be sound and lives in
-- one place, so extract and relink cannot drift.
test('transport: a call into an UNAVAILABLE file is NOT disposed external', function ()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not pcall(vim.treesitter.language.add, 'lua') then skip 'no lua parser' end
    local ts = require 'cartograph.providers.treesitter'
    local root = fixture()
    vim.fn.system({ 'chmod', '000', root .. '/lib.lua' })
    local probe = io.open(root .. '/lib.lua', 'r')
    if probe then probe:close(); vim.fn.delete(root, 'rf'); skip 'running as root' end
    local d = ts.extract(root)
    local call
    for _, c in ipairs(d.calls or {}) do if c.callee == 'helper' then call = c end end
    ok(call ~= nil, 'the call site is still recorded')
    eq(nil, call.to)                          -- unresolved: we could not read it
    eq('frontier', call.ext and call.ext.disp) -- ... but NOT the boundary
    eq('unread-file', call.ext and call.ext.why)

    -- and the user-visible surfaces agree: it leaves the external boundary and
    -- the portability requirement set, rather than posing as a dependency
    local store = require 'cartograph.store'
    store.ingest(d)
    local surface = require('cartograph.externals').surface(store)
    eq(1, surface.unread)
    local req = require('cartograph.portability').requires(store)
    eq(nil, req.names['lib.helper'])
    vim.fn.system({ 'chmod', '644', root .. '/lib.lua' }); vim.fn.delete(root, 'rf')
end)
