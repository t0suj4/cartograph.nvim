-- The ZIP transport (step B): an archive as a substrate, composing over whatever
-- serves the archive itself.
--
-- Fixtures are built with the `zip` CLI so the archives are REAL — a hand-rolled
-- stored-only zip would exercise none of what actually breaks. What actually
-- breaks, measured on 195 local Factorio archives: 67% of entries set the
-- DATA-DESCRIPTOR flag, which zeroes crc/sizes in the local header, so sizes must
-- come from the central directory. `zip -X` produces that shape.

local transport = require 'cartograph.transport'
local zipmod = require 'cartograph.zip'

local function have_zip() return vim.fn.executable('zip') == 1 end

--- Build a real archive with a nested layout, returning (archive_path, tmpdir).
local function fixture(opts)
    local d = vim.fn.tempname()
    vim.fn.mkdir(d .. '/Pkg_1.2.3/lib', 'p')
    local function w(rel, text)
        local fd = assert(io.open(d .. '/' .. rel, 'w')); fd:write(text); fd:close()
    end
    -- the manifest name deliberately DIFFERS from the directory name: measured, 112
    -- of 195 real archives disagree, so identity must never come from a path
    w('Pkg_1.2.3/info.json', '{"name":"Pkg","version":"1.2.3","factorio_version":"2.0"}')
    w('Pkg_1.2.3/control.lua', 'local function boot() return 1 end\nreturn { boot = boot }\n')
    w('Pkg_1.2.3/lib/util.lua', 'local function helper(x) return x * 2 end\n'
        .. 'return { helper = helper }\n')
    -- something big enough that DEFLATE is chosen over STORE
    w('Pkg_1.2.3/big.lua', ('-- padding padding padding\n'):rep(400))
    local archive = d .. '/Pkg_' .. (opts and opts.tag or '1.2.3') .. '.zip'
    -- -X drops extra fields; the archive is built from inside `d` so entry names
    -- are `Pkg_1.2.3/...` rather than absolute
    vim.fn.system({ 'sh', '-c', ('cd %q && zip -q -r -X %q Pkg_1.2.3')
        :format(d, archive) })
    return archive, d
end

test('zip: available() reports whether CONTENT can be read', function ()
    -- enumerating/stamping need no zlib; only inflate does. Either answer is
    -- valid — what must not happen is a hard error either way.
    eq('boolean', type(zipmod.available()))
end)

test('zip: the kind is skipped, not fatal, when zlib is missing', function ()
    -- build() drops a kind whose constructor returns nil; with zlib present the
    -- kind exists. Both branches leave a WORKING stack, which is the property.
    local stack = transport.build { { kind = 'zip' }, { kind = 'disk' } }
    local p = vim.fn.tempname()
    local fd = assert(io.open(p, 'w')); fd:write('plain\n'); fd:close()
    eq('plain\n', stack.read(p)) -- disk still answers ordinary paths
    vim.fn.delete(p)
end)

test('zip: reads an entry out of a real archive, CRC-verified', function ()
    if not have_zip() then skip 'no zip CLI to build a fixture' end
    if not zipmod.available() then skip 'no zlib' end
    local archive, d = fixture()
    local stack = transport.build { { kind = 'zip' }, { kind = 'disk' } }
    local txt = stack.read(archive .. '::Pkg_1.2.3/info.json')
    ok(txt ~= nil, 'manifest read')
    eq('Pkg', vim.json.decode(txt).name)
    -- a DEFLATEd entry too, not just a small stored one
    local big = stack.read(archive .. '::Pkg_1.2.3/big.lua')
    ok(big ~= nil and #big > 1000, 'deflated entry inflates: ' .. tostring(big and #big))
    vim.fn.delete(d, 'rf')
end)

-- the identity lesson from the real corpus, pinned: the archive's internal
-- directory is NOT the package name, so nothing may infer identity from a path
test('zip: the internal directory name is not the package name', function ()
    if not have_zip() then skip 'no zip CLI' end
    if not zipmod.available() then skip 'no zlib' end
    local archive, d = fixture()
    local stack = transport.build { { kind = 'zip' }, { kind = 'disk' } }
    local top
    for name, ty in stack.dir(archive .. '::') do
        if ty == 'directory' then top = name end
    end
    eq('Pkg_1.2.3', top)
    local manifest = vim.json.decode(stack.read(archive .. '::' .. top .. '/info.json'))
    eq('Pkg', manifest.name)      -- the manifest is authoritative
    ok(top ~= manifest.name, 'and it differs from the directory')
    vim.fn.delete(d, 'rf')
end)

test('zip: dir enumerates one level, typing nested paths as directories',
    function ()
    if not have_zip() then skip 'no zip CLI' end
    local archive, d = fixture()
    local stack = transport.build { { kind = 'zip' }, { kind = 'disk' } }
    local seen = {}
    for name, ty in stack.dir(archive .. '::Pkg_1.2.3') do seen[name] = ty end
    eq('file', seen['info.json'])
    eq('file', seen['control.lua'])
    eq('directory', seen['lib'])       -- reported once, from a nested entry
    eq(nil, seen['lib/util.lua'])      -- ... and not as a flat name
    local sub = {}
    for name, ty in stack.dir(archive .. '::Pkg_1.2.3/lib') do sub[name] = ty end
    eq('file', sub['util.lua'])
    vim.fn.delete(d, 'rf')
end)

-- ABSENCE vs INDETERMINACY across a container boundary, which is what lets a
-- caller mint a negative fact safely (see transport.ABSENT)
test('zip: a missing ENTRY and a missing ARCHIVE are both ABSENT', function ()
    if not have_zip() then skip 'no zip CLI' end
    local archive, d = fixture()
    local stack = transport.build { { kind = 'zip' }, { kind = 'disk' } }
    local _, e1 = stack.read(archive .. '::Pkg_1.2.3/nope.lua')
    eq(transport.ABSENT, e1)
    local _, e2 = stack.read(d .. '/not-there.zip::Pkg/x.lua')
    eq(transport.ABSENT, e2)
    vim.fn.delete(d, 'rf')
end)

test('zip: a NON-archive claimed key is UNAVAILABLE, never absent', function ()
    if not have_zip() then skip 'no zip CLI' end
    local d = vim.fn.tempname(); vim.fn.mkdir(d, 'p')
    local bogus = d .. '/notreally.zip'
    local fd = assert(io.open(bogus, 'w')); fd:write('this is not a zip at all\n'); fd:close()
    local stack = transport.build { { kind = 'zip' }, { kind = 'disk' } }
    local got, err = stack.read(bogus .. '::a/b.lua')
    eq(nil, got)
    -- the archive EXISTS but cannot be parsed: indeterminate, so no caller may
    -- conclude the entry is absent and mint a boundary fact from it
    eq(transport.UNAVAILABLE, err)
    vim.fn.delete(d, 'rf')
end)

-- the stamp is the ARCHIVE's: the container is the unit of change, so one stat
-- covers a whole package and any edit invalidates every entry at once
test('zip: an entry stamp derives from the archive and changes with it', function ()
    if not have_zip() then skip 'no zip CLI' end
    local archive, d = fixture()
    local stack = transport.build { { kind = 'zip' }, { kind = 'disk' } }
    local key = archive .. '::Pkg_1.2.3/info.json'
    local s1 = stack.stamp(key)
    ok(s1 ~= nil and s1:match('|Pkg_1%.2%.3/info%.json$') ~= nil,
        'stamp carries the entry: ' .. tostring(s1))
    -- two entries in ONE archive share the archive's half
    local s2 = stack.stamp(archive .. '::Pkg_1.2.3/control.lua')
    eq(s1:match('^(.-)|'), s2:match('^(.-)|'))
    vim.fn.delete(d, 'rf')
end)

-- COMPOSITION: the zip reads its archive through the stack, so it never opens a
-- file itself. Proven by making the BACKING transport the only thing that can
-- serve the archive and checking the zip still works through it.
test('zip: reads its archive through the BACKING transport, not io.open',
    function ()
    if not have_zip() then skip 'no zip CLI' end
    if not zipmod.available() then skip 'no zlib' end
    local archive, d = fixture()
    local bytes = assert(io.open(archive, 'rb')):read('a')
    local served = 0
    transport.kinds.memtest = function ()
        return {
            name = 'mem',
            claims = function (p) return p:match('%.memzip$') ~= nil end,
            size = function () return #bytes end,
            stamp = function () return 'memstamp' end,
            read_range = function (_, off, len)
                served = served + 1
                local start = (off and off < 0) and math.max(0, #bytes + off) or (off or 0)
                return bytes:sub(start + 1, len and (start + len) or nil)
            end,
        }
    end
    -- the archive lives ONLY in the mem transport; disk has no such path
    local stack = transport.build { { kind = 'zip', ext = '.memzip' },
        { kind = 'memtest' }, { kind = 'disk' } }
    local txt = stack.read('/nowhere/a.memzip::Pkg_1.2.3/info.json')
    eq('Pkg', txt and vim.json.decode(txt).name)
    ok(served > 0, 'the backing transport served the container bytes')
    transport.kinds.memtest = nil
    vim.fn.delete(d, 'rf')
end)

-- the read-once / ranged POLICY. Measured on a real 202 MB archive: default
-- threshold 26.7 ms, threshold raised so it reads whole 2481 ms — 93x. Here the
-- fixture is tiny, so the test asserts the DECISION, not the timing: a raised
-- threshold pulls the whole container in ONE range, a lowered one does not.
test('zip: whole_max decides read-once vs per-entry ranges', function ()
    if not have_zip() then skip 'no zip CLI' end
    if not zipmod.available() then skip 'no zlib' end
    local archive, d = fixture()
    local bytes = assert(io.open(archive, 'rb')):read('a')
    local function counting_stack(whole_max)
        local reads = {}
        transport.kinds.counttest = function ()
            return {
                name = 'count',
                claims = function (p) return p:match('%.czip$') ~= nil end,
                size = function () return #bytes end,
                stamp = function () return 'st' end,
                read_range = function (_, off, len)
                    reads[#reads + 1] = { off = off, len = len }
                    local start = (off and off < 0) and math.max(0, #bytes + off)
                        or (off or 0)
                    return bytes:sub(start + 1, len and (start + len) or nil)
                end,
            }
        end
        local s = transport.build { { kind = 'zip', ext = '.czip', whole_max = whole_max },
            { kind = 'counttest' } }
        return s, reads
    end
    -- threshold ABOVE the archive size: one full-container range, then no more I/O
    local s1, r1 = counting_stack(10 * 1024 * 1024)
    ok(s1.read('/x.czip::Pkg_1.2.3/info.json') ~= nil, 'read-once path works')
    eq(1, #r1)                       -- exactly one backing read
    eq(0, r1[1].off); eq(nil, r1[1].len) -- ... and it was the whole thing
    -- threshold BELOW it: the trailer is fetched as a SUFFIX range instead
    local s2, r2 = counting_stack(16)
    ok(s2.read('/x.czip::Pkg_1.2.3/info.json') ~= nil, 'ranged path works')
    ok(#r2 > 1, 'several ranged reads, not one slurp: ' .. #r2)
    ok(r2[1].off < 0, 'the first read is a suffix range for the trailer')
    transport.kinds.counttest = nil
    vim.fn.delete(d, 'rf')
end)

-- the central directory is parsed ONCE per archive version: cached on the
-- archive's own stamp, so a stable archive is not re-parsed per entry
test('zip: the central directory is parsed once per archive stamp', function ()
    if not have_zip() then skip 'no zip CLI' end
    if not zipmod.available() then skip 'no zlib' end
    local archive, d = fixture()
    local bytes = assert(io.open(archive, 'rb')):read('a')
    local opens = 0
    transport.kinds.opentest = function ()
        return {
            name = 'open', claims = function (p) return p:match('%.ozip$') ~= nil end,
            size = function () return #bytes end,
            stamp = function () return 'fixed' end,
            read_range = function (_, off, len)
                opens = opens + 1
                local start = (off and off < 0) and math.max(0, #bytes + off) or (off or 0)
                return bytes:sub(start + 1, len and (start + len) or nil)
            end,
        }
    end
    local s = transport.build { { kind = 'zip', ext = '.ozip', whole_max = 16 },
        { kind = 'opentest' } }
    s.read('/y.ozip::Pkg_1.2.3/info.json')
    local after_first = opens
    s.read('/y.ozip::Pkg_1.2.3/control.lua')
    s.read('/y.ozip::Pkg_1.2.3/lib/util.lua')
    -- two more entries cost only their own data reads, not another trailer+CD parse
    ok(opens - after_first < after_first * 2,
        ('%d reads for the first entry, %d for two more'):format(after_first,
            opens - after_first))
    transport.kinds.opentest = nil
    vim.fn.delete(d, 'rf')
end)
