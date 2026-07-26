-- The PACKAGE-ECOSYSTEM axis (spec/ecosystem/): where OTHER packages live, how
-- they are identified, which one wins. The third axis — language environment
-- (spec/profile/) and repo shape (shapes.lua) already had homes; this one did not,
-- which is why its facts were about to be scattered a fourth time by the zip
-- transport. spec/lua.lua:216 names the debt.
--
-- What these tests are really protecting is a DIVISION: precedence declared here
-- becomes transport stack ORDER, so the ecosystem knows Factorio and nothing
-- about bytes, and transport knows bytes and nothing about Factorio.

local eco = require 'cartograph.spec.ecosystem'
local transport = require 'cartograph.transport'

test('ecosystem: lua-factorio loads and is DATA (schema-marked, no behaviour)',
    function ()
    local f = eco.load('lua-factorio')
    ok(f ~= nil, 'lua-factorio loads')
    eq(1, f.schema)
    eq('lua', f.lang)
    -- data, not code: it must survive a JSON round trip, because extraction runs
    -- in spawned worker processes that receive their job as JSON. A layout rule
    -- expressed as a function could never reach one.
    local round = vim.json.decode(vim.json.encode(f))
    eq(f.identity.manifest, round.identity.manifest)
    eq(#f.forms, #round.forms)
end)

test('ecosystem: an unknown name is nil, never a partial spec', function ()
    eq(nil, eco.load('no-such-ecosystem'))
    eq(nil, eco.stamp_of('no-such-ecosystem'))
end)

test('ecosystem: names() derives from the directory', function ()
    local ns = eco.names()
    local found = false
    for _, n in ipairs(ns) do if n == 'lua-factorio' then found = true end end
    ok(found, 'lua-factorio listed among: ' .. table.concat(ns, ' '))
end)

-- the stamp exists so a cached graph whose resolution used the spec can be
-- invalidated when the spec is edited — same contract as profile.stamp_of
test('ecosystem: stamp_of changes when the artifact changes', function ()
    local s = eco.stamp_of('lua-factorio')
    ok(s ~= nil and s:match('^lua:%d+:%d+$') ~= nil, 'stamp shape: ' .. tostring(s))
end)

-- IDENTITY IS THE MANIFEST, NEVER THE FILENAME. Measured: 112 of 195 local
-- archives have an internal directory name that disagrees with their manifest
-- name, so a filename-derived identity is wrong for most of the corpus.
test('ecosystem: identity is manifest-authoritative, filename only a hint',
    function ()
    local f = eco.load('lua-factorio')
    eq('info.json', f.identity.manifest)
    -- the assertion ABOUT the rule lives under `notes` (prose the rule-consumption
    -- audit skips), so what is pinned here is that the rule itself is present and
    -- that the hint is only ever a hint
    ok(f.identity.notes.authoritative:match('manifest') ~= nil,
        'the manifest is authoritative: ' .. tostring(f.identity.notes.authoritative))
    -- the hint must be a HINT: it extracts a name to try, and the caller confirms
    eq('space-exploration', ('space-exploration_0.7.5.zip'):match(f.identity.filename_hint))
    eq('Explosive Excavation', ('Explosive Excavation_1.3.0.zip'):match(f.identity.filename_hint))
end)

test('ecosystem: the require form parses __mod__/path and __mod__.dotted',
    function ()
    local f = eco.load('lua-factorio')
    local pat = f.require_form.pattern
    local n1, p1 = ('__base__/scenarios/freeplay/silo-script'):match(pat)
    eq('base', n1); eq('scenarios/freeplay/silo-script', p1)
    local n2, p2 = ('__space-exploration__.data_util'):match(pat)
    eq('space-exploration', n2); eq('data_util', p2)
    -- a bare require is package-local and must NOT match
    eq(nil, ('lib.util'):match(pat))
end)

-- THE DIVISION: declared precedence becomes transport stack order. A form whose
-- transport kind does not exist yet is REPORTED, never handed to transport.build —
-- an unknown kind there is a hard error by design, and a spec must not be able to
-- turn that into a crash.
test('ecosystem: forms become a transport stack spec, unsupported ones reported',
    function ()
    local f = eco.load('lua-factorio')
    -- precedence: an unpacked directory shadows an archive of the same package
    eq('directory', f.forms[1].form)
    eq('archive', f.forms[2].form)
    local res = eco.stack_spec(f)
    -- both declared forms have kinds now; an UNKNOWN one would still be named
    -- rather than dropped, which is what the unsupported list is for
    eq('disk', res.spec[1] and res.spec[1].kind)
    eq({}, res.unsupported)
    -- and what it produced is buildable, which is the contract that matters
    local stack = transport.build(res.spec)
    eq('disk', stack.for_path('/x.lua').name)
end)

-- zip is now a REAL kind, so the declared archive form resolves. This is what
-- "additive" meant: the spec never changed, the kind arrived, and stack_spec
-- started emitting it. A kind is NEVER stubbed here — an earlier version of this
-- test assigned transport.kinds.zip and nil'd it in teardown, which silently
-- DELETED the real kind for every later test in the run.
test('ecosystem: the declared archive form resolves now that zip exists', function ()
    local res = eco.stack_spec(eco.load('lua-factorio'))
    eq({}, res.unsupported)
    eq('disk', res.spec[1].kind)
    eq('zip', res.spec[2].kind)
    local stack = transport.build(res.spec)
    eq('disk', stack.for_path('/x.lua').name)
    eq('zip', stack.for_path('/m/P_1.0.zip::P/control.lua').name)
end)

-- root resolution: an override always wins, because the INSTALL is not derivable
-- (measured: absent from every standard location on a machine that has the user
-- dir, and config.ini records only an unsubstituted token). Autodetection alone
-- would hand back a mods dir and silently no base data.
test('ecosystem: an override wins; a missing override says so', function ()
    local f = eco.load('lua-factorio')
    local d = vim.fn.tempname(); vim.fn.mkdir(d, 'p')
    local p, how = eco.root(f, 'install', d)
    eq(d, p); eq('override', how)
    local p2, how2 = eco.root(f, 'install', d .. '/nope')
    eq(nil, p2); eq('override-missing', how2) -- NOT silently falling back
    vim.fn.delete(d, 'rf')
end)

test('ecosystem: enablement is an HONESTY input, not a resolution one', function ()
    local f = eco.load('lua-factorio')
    -- a disabled package is still present and readable, so a require into it
    -- resolves; what changes is what we SAY about it
    eq('honesty', f.enablement.affects)
end)

-- the fragment this collapsed: spec/lua.lua no longer restates the manifest name
-- or the identity key. Two copies existed (factorio_mods and toc_scope's marker).
test('ecosystem: spec/lua.lua reads the identity rule rather than restating it',
    function ()
    local src = require('cartograph.transport').read(
        vim.fn.expand('~/git/cartograph.nvim/lua/cartograph/spec/lua.lua'))
    if not src then skip 'source not readable from here' end
    local _, n = src:gsub("'info%.json'", '')
    eq(0, n) -- zero literal copies of the manifest name remain
end)

-- REGRESSION for a live correctness hole: the ecosystem spec feeds resolution
-- (factorio_mods' identity rule, toc_scope's manifest marker) but cache validity
-- composed only file stamps, VERSION and the PROFILE stamp — so editing a layout
-- rule left every warm cache confidently stale. stamp_of existed and nothing
-- consumed it.
test('ecosystem: a spec edit INVALIDATES a warm graph cache', function ()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not pcall(vim.treesitter.language.add, 'lua') then skip 'no lua parser' end
    local cache = require 'cartograph.cache'
    local ts = require 'cartograph.providers.treesitter'
    local root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/m.lua', 'w'))
    fd:write('local function f(x) return x end\nreturn { f = f }\n'); fd:close()

    ok(cache._artifact_key() ~= nil, 'the surface is stampable')
    cache.wipe(root)
    cache.save(ts.extract(root))
    ok(cache.open(root) ~= nil, 'warm open works right after save')

    -- PERTURB the composition exactly as an edited spec would, without touching a
    -- checked-in file: swap in a stamp function that answers differently
    local real = cache._artifact_key
    cache._artifact_key = function () return (real() or '') .. ';edited' end
    eq(nil, cache.open(root)) -- the layout rules moved -> the cache is stale
    cache._artifact_key = real
    ok(cache.open(root) ~= nil, 'and valid again once restored')

    cache.wipe(root); vim.fn.delete(root, 'rf')
end)

-- and the composition covers EVERY declared spec, so one added later enters the
-- key with no edit to cache.lua — the structural fix, not just the instance
test('ecosystem: every declared spec is stampable', function ()
    local ns = eco.names()
    ok(#ns > 0, 'at least one ecosystem is declared')
    for _, n in ipairs(ns) do
        ok(eco.stamp_of(n) ~= nil, n .. ' is stampable')
        ok(eco.load(n) ~= nil, n .. ' loads')
    end
end)

-- ── the ROSTER: a package directory as a multi-root corpus ───────────────────
-- The acceptance test for the whole arc. A mods directory holds packages in two
-- FORMS at a declared precedence; this turns it into the `roots` label map
-- extraction already understands, with a label's base allowed to be a CONTAINER.
-- The payoff being proven: a cross-package require RESOLVING INTO A ZIP.

local function mods_fixture()
    local d = vim.fn.tempname()
    vim.fn.mkdir(d .. '/mods', 'p')
    local function w(rel, text)
        local dir = rel:match('^(.*)/[^/]*$')
        if dir then vim.fn.mkdir(d .. '/' .. dir, 'p') end
        local fd = assert(io.open(d .. '/' .. rel, 'w')); fd:write(text); fd:close()
    end
    -- an UNPACKED package that requires a PACKED one
    w('mods/Unpacked/info.json', '{"name":"Unpacked","version":"1.0","factorio_version":"2.0"}')
    w('mods/Unpacked/control.lua',
        "local lib = require '__Packed__/lib'\n"
        .. 'local function run() return lib.helper(1) end\nreturn { run = run }\n')
    -- the PACKED one, built for real: internal dir name deliberately unlike the
    -- package name, since 112 of 195 real archives disagree
    vim.fn.mkdir(d .. '/build/Packed_2.7.1', 'p')
    local function b(rel, text)
        local fd = assert(io.open(d .. '/build/' .. rel, 'w')); fd:write(text); fd:close()
    end
    b('Packed_2.7.1/info.json', '{"name":"Packed","version":"2.7.1","factorio_version":"2.0"}')
    b('Packed_2.7.1/lib.lua',
        'local function helper(x) return x + 1 end\nreturn { helper = helper }\n')
    vim.fn.system({ 'sh', '-c', ('cd %q/build && zip -q -r -X %q/mods/Packed_2.7.1.zip'
        .. ' Packed_2.7.1'):format(d, d) })
    -- mod-list.json: Packed enabled, a third name disabled
    w('mods/mod-list.json', '{"mods":[{"name":"Unpacked","enabled":true},'
        .. '{"name":"Packed","enabled":false}]}')
    return d
end

test('ecosystem roster: both package FORMS become labels with a base', function ()
    if vim.fn.executable('zip') ~= 1 then skip 'no zip CLI' end
    if not require('cartograph.zip').available() then skip 'no zlib' end
    local d = mods_fixture()
    local r, why = eco.roster('lua-factorio', { dir = d .. '/mods' })
    ok(r ~= nil, 'roster built: ' .. tostring(why))
    local by = {}
    for _, p in ipairs(r.packages) do by[p.name] = p end
    eq('directory', by.Unpacked and by.Unpacked.form)
    eq('archive', by.Packed and by.Packed.form)
    eq('2.7.1', by.Packed.version)
    -- identity came from the MANIFEST: the archive's internal dir is Packed_2.7.1
    eq('Packed_2.7.1', by.Packed.base.prefix)
    ok(by.Packed.base.container:match('%.zip$') ~= nil, 'base is a container')
    eq('string', type(by.Unpacked.base)) -- a directory base stays a plain path
    -- ENABLEMENT is carried, not acted on: a disabled package is still rostered
    eq(false, by.Packed.enabled)
    eq(true, by.Unpacked.enabled)
    vim.fn.delete(d, 'rf')
end)

test('ecosystem roster: file keys stay conventional labelled paths', function ()
    if vim.fn.executable('zip') ~= 1 then skip 'no zip CLI' end
    if not require('cartograph.zip').available() then skip 'no zlib' end
    local d = mods_fixture()
    local r = eco.roster('lua-factorio', { dir = d .. '/mods' })
    local set = {}
    for _, f in ipairs(r.files) do set[f] = true end
    -- no '::' anywhere in what the graph will hold, for EITHER form
    eq(true, set['Unpacked/control.lua'])
    eq(true, set['Packed/lib.lua'])
    for _, f in ipairs(r.files) do
        eq(nil, f:find('::', 1, true))
    end
    -- ... and abs() maps the packed label into the container
    ok(r.abs('Packed/lib.lua'):match('%.zip::Packed_2%.7%.1/lib%.lua$') ~= nil,
        'abs composes the container key: ' .. r.abs('Packed/lib.lua'))
    vim.fn.delete(d, 'rf')
end)

-- THE PAYOFF: a cross-package require resolving from an unpacked package INTO an
-- archive, with the graph holding only conventional paths.
test('ecosystem roster: a cross-package require resolves INTO a zip', function ()
    if vim.fn.executable('zip') ~= 1 then skip 'no zip CLI' end
    if not require('cartograph.zip').available() then skip 'no zlib' end
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not pcall(vim.treesitter.language.add, 'lua') then skip 'no lua parser' end
    local ts = require 'cartograph.providers.treesitter'
    local d = mods_fixture()
    local r = eco.roster('lua-factorio', { dir = d .. '/mods' })
    local data = ts.extract(r.root, { files = r.files, abs = r.abs,
        transport = r.transport })
    -- the archive's file was PARSED, not just listed
    local defs = {}
    for _, n in ipairs(data.nodes or {}) do
        if n.kind == 'function' then defs[n.file .. '::' .. n.name] = true end
    end
    ok(defs['Packed/lib.lua::helper'], 'the def inside the ZIP was extracted')
    -- and the cross-package import edge points at it
    local crossed = false
    for _, e in ipairs(data.edges or {}) do
        if e.kind == 'import' and e.from == 'Unpacked/control.lua'
            and e.to == 'Packed/lib.lua' then crossed = true end
    end
    ok(crossed, '__Packed__/lib resolved from an unpacked package into an archive')
    vim.fn.delete(d, 'rf')
end)

-- PRECEDENCE: an unpacked directory shadows an archive of the SAME package, which
-- is the normal state while editing one. Declared in the spec's `forms` order and
-- not exercised by any real local case (2 unpacked, 195 zipped, zero overlap).
test('ecosystem roster: an unpacked package SHADOWS an archive of the same name',
    function ()
    if vim.fn.executable('zip') ~= 1 then skip 'no zip CLI' end
    if not require('cartograph.zip').available() then skip 'no zlib' end
    local d = mods_fixture()
    -- add an unpacked copy of Packed, with a marker file the archive lacks
    vim.fn.mkdir(d .. '/mods/Packed_unpacked', 'p')
    local function w(rel, t)
        local fd = assert(io.open(d .. '/mods/' .. rel, 'w')); fd:write(t); fd:close()
    end
    w('Packed_unpacked/info.json', '{"name":"Packed","version":"9.9.9"}')
    w('Packed_unpacked/lib.lua', 'return { helper = function (x) return x end }\n')
    local r = eco.roster('lua-factorio', { dir = d .. '/mods' })
    local by = {}
    for _, p in ipairs(r.packages) do by[p.name] = p end
    eq('directory', by.Packed.form)  -- the directory form won
    eq('9.9.9', by.Packed.version)   -- ... and it is the unpacked manifest
    eq('string', type(by.Packed.base))
    -- exactly ONE package named Packed: the archive did not also claim it
    local n = 0
    for _, p in ipairs(r.packages) do if p.name == 'Packed' then n = n + 1 end end
    eq(1, n)
    vim.fn.delete(d, 'rf')
end)

test('ecosystem roster: enabled_only drops disabled packages from the corpus',
    function ()
    if vim.fn.executable('zip') ~= 1 then skip 'no zip CLI' end
    if not require('cartograph.zip').available() then skip 'no zlib' end
    local d = mods_fixture()
    local all = eco.roster('lua-factorio', { dir = d .. '/mods' })
    local few = eco.roster('lua-factorio', { dir = d .. '/mods', enabled_only = true })
    ok(all.roots.Packed ~= nil, 'present by default (enablement is honesty)')
    eq(nil, few.roots.Packed)           -- ... and droppable on request
    ok(few.roots.Unpacked ~= nil, 'the enabled one survives')
    -- the PACKAGE list still carries it either way: dropping it from the corpus is
    -- not the same as forgetting it exists
    local seen = false
    for _, p in ipairs(few.packages) do if p.name == 'Packed' then seen = true end end
    eq(true, seen)
    vim.fn.delete(d, 'rf')
end)

test('ecosystem roster: a missing directory is a clear refusal, not a crash',
    function ()
    local r, why = eco.roster('lua-factorio', { dir = vim.fn.tempname() .. '/nope' })
    eq(nil, r)
    ok(tostring(why):match('not a directory') ~= nil, 'says why: ' .. tostring(why))
end)
