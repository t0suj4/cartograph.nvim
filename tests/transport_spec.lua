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
    -- and no resolve_entry: the type comes back exactly as given, so the walk
    -- carries no filesystem policy for a substrate that has none
    eq('file', stack.resolve_entry('/a', 'b.partial', 'file'))
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

-- ── ranged read ──────────────────────────────────────────────────────────────
-- The op that makes a container composable over another substrate instead of
-- special-cased inside it. Every case below was reached by probing Lua's seek/read
-- first, because they are all live: a short read at EOF, a nil read AT EOF, and a
-- suffix seek that ERRORS when it exceeds the file.

test('transport: read_range returns a byte range, 0-based', function ()
    local p = tmpfile('0123456789')
    eq('3456', transport.read_range(p, 3, 4))
    eq('0123456789', transport.read_range(p, 0, 99)) -- len past EOF: SHORT, not nil
    eq('89', transport.read_range(p, 8, 5))
    eq('0123456789', transport.read_range(p, 0))     -- no len = to the end
    vim.fn.delete(p)
end)

-- a SUFFIX range (HTTP `bytes=-N`) is the primitive a container needs to find its
-- trailer without pulling the whole file. seek('end', -n) errors when n exceeds
-- the file, so this must clamp rather than fail.
test('transport: a NEGATIVE offset is a suffix range, clamped', function ()
    local p = tmpfile('0123456789')
    eq('6789', transport.read_range(p, -4, 4))
    eq('0123456789', transport.read_range(p, -99, 20)) -- clamps to start
    vim.fn.delete(p)
end)

-- zero bytes available is NOT a failure: '' keeps the error channel meaning only
-- "could not determine", which is the whole point of the two failure kinds.
test('transport: at/past EOF and len<=0 are empty, not errors', function ()
    local p = tmpfile('0123456789')
    local at, err1 = transport.read_range(p, 10, 3)
    eq('', at); eq(nil, err1)
    local past, err2 = transport.read_range(p, 99, 3)
    eq('', past); eq(nil, err2)
    eq('', transport.read_range(p, 2, 0))
    eq('', transport.read_range(p, 2, -5))
    vim.fn.delete(p)
end)

test('transport: read_range reports ABSENT / UNAVAILABLE like read', function ()
    local _, err = transport.read_range(vim.fn.tempname() .. '/gone', 0, 4)
    eq(transport.ABSENT, err)
    local p, d = unreadable('0123456789')
    if not p then skip 'running as root — chmod 000 is still readable' end
    local _, err2 = transport.read_range(p, 0, 4)
    eq(transport.UNAVAILABLE, err2)
    vim.fn.system({ 'chmod', '644', p }); vim.fn.delete(d, 'rf')
end)

-- the FALLBACK must be indistinguishable from native ranging, or a substrate that
-- cannot seek would quietly answer differently from one that can
test('transport: the whole-read fallback matches native ranging exactly', function ()
    transport.kinds.noseek = function ()
        return {
            name = 'noseek',
            claims = function (path) return path:match('%.noseek$') ~= nil end,
            -- read only: no read_range, so the stack must slice for it
            read = function () return '0123456789' end,
        }
    end
    local stack = transport.build { { kind = 'noseek' }, { kind = 'disk' } }
    local p = tmpfile('0123456789')
    for _, case in ipairs { { 3, 4 }, { 8, 5 }, { 0, 99 }, { -4, 4 }, { -99, 20 },
        { 10, 3 }, { 99, 3 }, { 2, 0 } } do
        local off, len = case[1], case[2]
        eq(transport.read_range(p, off, len), stack.read_range('/x.noseek', off, len))
    end
    eq(transport.read_range(p, 0), stack.read_range('/x.noseek', 0))
    transport.kinds.noseek = nil
    vim.fn.delete(p)
end)

-- ── failure has two kinds ────────────────────────────────────────────────────
-- The soundness half. The extractor turns "no content" into a CONFIDENT NEGATIVE
-- FACT (a call into a file it cannot read is classified `external` = "project
-- boundary"), so absence and indeterminacy must not arrive as the same nil.

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


-- ── the filesystem is a SPECIAL CASE, not the shape ──────────────────────────
-- `stat` and `realpath` were briefly contract ops, which was a leak: only a
-- filesystem has symlinks, and their single caller was the extractor's walk. The
-- policy moved into the disk transport; the walk kept only the generic dedup.

test('transport: resolve_entry passes non-links straight through', function ()
    local d = vim.fn.tempname(); vim.fn.mkdir(d, 'p')
    eq('file', transport.resolve_entry(d, 'x.lua', 'file'))
    eq('directory', transport.resolve_entry(d, 'sub', 'directory'))
    vim.fn.delete(d, 'rf')
end)

-- a symlinked DIRECTORY pointing OUTSIDE the root is followed, and hands back a
-- canonical id so the caller can dedup two aliases to one real directory
test('transport: an OUTSIDE dir symlink resolves to directory + a canonical id',
    function ()
    local outside = vim.fn.tempname(); vim.fn.mkdir(outside .. '/pkg', 'p')
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    if vim.fn.executable('ln') ~= 1 then skip 'no ln' end
    vim.fn.system({ 'ln', '-s', outside .. '/pkg', root .. '/linked' })
    local ty, canon = transport.resolve_entry(root, 'linked', 'link')
    eq('directory', ty)
    ok(canon ~= nil and canon:match('pkg$') ~= nil, 'canonical: ' .. tostring(canon))
    vim.fn.delete(root, 'rf'); vim.fn.delete(outside, 'rf')
end)

-- an INTERNAL alias is left as-is (skipped downstream): the real path is walked
-- normally, and following both would key every file twice
test('transport: an INSIDE dir symlink is left unchanged, no canonical', function ()
    local root = vim.fn.tempname(); vim.fn.mkdir(root .. '/real', 'p')
    if vim.fn.executable('ln') ~= 1 then skip 'no ln' end
    vim.fn.system({ 'ln', '-s', root .. '/real', root .. '/alias' })
    local ty, canon = transport.resolve_entry(root, 'alias', 'link')
    eq('link', ty)   -- unchanged
    eq(nil, canon)   -- nothing to dedup
    vim.fn.delete(root, 'rf')
end)

-- FIDELITY: a dangling link keeps its type, because the inline walk left `link`
-- in place and let the language check decide. Returning nil would silently drop a
-- broken `foo.lua` symlink the old walk collected.
test('transport: a BROKEN link keeps its type unchanged', function ()
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    if vim.fn.executable('ln') ~= 1 then skip 'no ln' end
    vim.fn.system({ 'ln', '-s', root .. '/nothing-here', root .. '/foo.lua' })
    eq('link', transport.resolve_entry(root, 'foo.lua', 'link'))
    vim.fn.delete(root, 'rf')
end)

-- ── root values are transport KEYS, not paths ────────────────────────────────
-- The graph parses a file key's FIRST SEGMENT as a scope label in six places and
-- its extension as the language. So a packed package must be a LABEL whose root
-- value is a container — never a composite in n.file, which would collide with
-- that convention instead of extending it.

test('transport: join composes a directory root exactly as before', function ()
    eq('/base/rest.lua', transport.join('/base', 'rest.lua'))
    eq('/base/a/b.lua', transport.join('/base', 'a/b.lua'))
end)

test('transport: join composes a CONTAINER root, with and without a prefix',
    function ()
    eq('/m/Mod_1.0.zip::Mod/control.lua',
        transport.join({ container = '/m/Mod_1.0.zip', prefix = 'Mod' }, 'control.lua'))
    eq('/m/Mod_1.0.zip::control.lua',
        transport.join({ container = '/m/Mod_1.0.zip' }, 'control.lua'))
end)

-- the point of the whole exercise: the composite lives ONLY between abs() and a
-- transport. What the graph stores stays a conventional labelled path.
test('transport: a container root leaves n.file conventional', function ()
    local store = require 'cartograph.store'
    local data = { root = '/corpus', roots = {
        Unpacked = '/mods/Unpacked',
        Packed = { container = '/mods/Packed_1.0.zip', prefix = 'Packed' },
    } }
    -- the KEY the graph holds is the same shape for both forms
    eq('/mods/Unpacked/control.lua', store.abs_in(data, 'Unpacked/control.lua'))
    eq('/mods/Packed_1.0.zip::Packed/control.lua',
        store.abs_in(data, 'Packed/control.lua'))
    -- ... and the first segment still parses as a label, which is what the six
    -- segment-reading sites depend on
    eq('Packed', ('Packed/control.lua'):match('^([^/]+)/'))
    eq('lua', ('Packed/control.lua'):match('%.([%w]+)$'))
end)

-- ── the multi-root parallel path, which had NO coverage ──────────────────────
-- transport.join replaced the root-value concatenation in FOUR places. Two are
-- covered above (store.abs_in) and by self_spec; the other two — parallel.lua's
-- abs closure and worker.lua's reconstruction of it — are only reached by a
-- MULTI-ROOT parallel extract, which no gate performs (libs --parallel sets no
-- roots, and self_spec builds its own abs). So this drives one, with enough files
-- to force real worker SPAWNS: nw = min(default_workers, ceil(#files/BATCH)) needs
-- 49+ files to exceed 1, and a worker rebuilds `abs` from job.roots in a separate
-- process — the exact path a module-level anything could never reach.
test('transport: a MULTI-ROOT parallel extract resolves labels in workers',
    function ()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not pcall(vim.treesitter.language.add, 'lua') then skip 'no lua parser' end
    local par = require 'cartograph.parallel'
    local A, B = vim.fn.tempname(), vim.fn.tempname()
    vim.fn.mkdir(A, 'p'); vim.fn.mkdir(B, 'p')
    local files = {}
    for i = 1, 60 do
        local dir, label = (i % 2 == 0) and A or B, (i % 2 == 0) and 'plugA' or 'plugB'
        local rel = ('m%d.lua'):format(i)
        local fd = assert(io.open(dir .. '/' .. rel, 'w'))
        fd:write(('local function f%d(x) return x + %d end\nreturn { f%d = f%d }\n')
            :format(i, i, i, i))
        fd:close()
        files[#files + 1] = label .. '/' .. rel
    end
    local done, got = false, nil
    par.extract('self://loaded', {
        roots = { plugA = A, plugB = B },
        files = files,
        on_done = function (d) got = d; done = true end,
    })
    vim.wait(240000, function () return done end, 50)
    ok(got ~= nil, 'the parallel extract completed')
    -- every file was READ through a label-resolved key: 60 defs means the workers
    -- resolved `plugA/m2.lua` to a real directory in their own processes
    local defs = 0
    for _, n in ipairs(got.nodes or {}) do
        if n.kind == 'function' then defs = defs + 1 end
    end
    eq(60, defs)
    -- ... and nothing landed as an unreadable frontier
    eq(0, #(got.unparsed or {}))
    vim.fn.delete(A, 'rf'); vim.fn.delete(B, 'rf')
end)

-- ── the bound reader: repeated ranged reads of one path ──────────────────────
-- For a caller making SEVERAL ranged reads of one path (a container reading its
-- trailer, then its directory, then an entry) the cost is the REOPEN, not the
-- bytes — ~3.3 ms per open on a high-latency mount. Optional, like every op: a
-- substrate with no handle concept has none and callers must work without it.

test('transport: a reader answers ranges identically to the one-shot form',
    function ()
    local p = tmpfile('0123456789')
    local h = transport.reader(p)
    ok(h ~= nil, 'disk offers a reader')
    -- the SAME eight edge cases the one-shot form pins, so the two cannot drift
    for _, case in ipairs { { 3, 4 }, { 8, 5 }, { 0, 99 }, { -4, 4 }, { -99, 20 },
        { 10, 3 }, { 99, 3 }, { 2, 0 } } do
        eq(transport.read_range(p, case[1], case[2]), h.read_range(case[1], case[2]))
    end
    eq(transport.read_range(p, 0), h.read_range(0))
    h.close()
    vim.fn.delete(p)
end)

test('transport: a closed reader is UNAVAILABLE, not a crash', function ()
    local p = tmpfile('abc')
    local h = transport.reader(p)
    h.close()
    h.close() -- idempotent: a double close must not error
    local got, err = h.read_range(0, 3)
    eq(nil, got); eq(transport.UNAVAILABLE, err)
    vim.fn.delete(p)
end)

test('transport: a reader on a missing path reports ABSENT', function ()
    local h, err = transport.reader(vim.fn.tempname() .. '/gone')
    eq(nil, h); eq(transport.ABSENT, err)
end)

-- the op is OPTIONAL: a stack whose serving transport has no reader returns nil,
-- and every caller must already have a path that works without one
test('transport: a substrate with no handle concept simply has no reader', function ()
    transport.kinds.noreader = function ()
        return { name = 'noreader',
            claims = function (p) return p:match('%.nr$') ~= nil end,
            read_range = function () return 'x' end }
    end
    local stack = transport.build { { kind = 'noreader' }, { kind = 'disk' } }
    eq(nil, stack.reader('/a/b.nr'))
    eq('x', stack.read_range('/a/b.nr', 0, 1)) -- ... and ranges still work
    transport.kinds.noreader = nil
end)
