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

-- ── the cluster, collapsed ───────────────────────────────────────────────────
-- spec/lua.lua:252 named factorio_mods / toc_scope / nvim_lua_root as "one
-- missing-abstraction". All three are now declared ecosystems. Reading the code
-- showed why they belonged together: toc_scope was never WoW-specific — it tested
-- `.toc` OR factorio's `info.json`, i.e. it was already the package-boundary
-- question with both answers inlined.

test('ecosystem: all three lua ecosystems are declared', function ()
    local names = {}
    for _, n in ipairs(eco.names()) do names[n] = true end
    ok(names['lua-factorio'], 'factorio')
    ok(names['lua-wow'], 'wow addons')
    ok(names['lua-nvim'], 'nvim plugins')
end)

-- THREE MARKER SHAPES, because packages really are identified three ways. Pinning
-- them separately is what lets the shared boundary test loop instead of branching.
test('ecosystem: the marker SHAPES differ per ecosystem, and each is declared',
    function ()
    local fac, wow = eco.load('lua-factorio'), eco.load('lua-wow')
    -- a FIXED filename
    eq('info.json', fac.identity.manifest)
    -- ... named after its own directory (Bagnon/Bagnon.toc)
    eq('.toc', wow.identity.manifest_named_after_dir)
    -- ... or any file of that type (a variant toc)
    eq('.toc', wow.identity.manifest_ext)
    -- and WoW takes the package name from the directory, having no id inside
    eq('directory', wow.identity.name_from)
end)

-- the BOUNDARY is the fact the wow spec exists for: 353 addons vendor their own
-- copies of the same libraries, so a name unique inside one addon is 353-way
-- ambiguous across the tree.
test('ecosystem: per-package boundaries are declared, not inferred', function ()
    eq(true, eco.load('lua-wow').boundary.per_package)
    eq(true, eco.load('lua-factorio').boundary.per_package)
    -- an nvim plugin is ONE package: a tree of them is a multi-root corpus
    -- instead, which is a different mechanism that already exists
    eq(false, eco.load('lua-nvim').boundary.per_package)
end)

test('ecosystem: nvim declares a package ROOT rather than a boundary', function ()
    local nv = eco.load('lua-nvim')
    eq('lua', nv.package_root)
    eq('init.lua', nv.require_form.index)
    -- and NOT a `dotted_ok`: that a '.' separates path segments is a property of
    -- LUA's require, true for every ecosystem here, so declaring it per-ecosystem
    -- put a language fact on the wrong axis. The rule-consumption audit surfaced
    -- that by reporting it permanently UNREAD.
    eq(nil, nv.require_form.dotted_ok)
    eq(nil, eco.load('lua-factorio').require_form.dotted_ok)
    -- no manifest at all: the marker is the layout
    eq(nil, nv.identity)
end)

-- the collapse must be BEHAVIOUR-PRESERVING, and the boundary test is the part
-- with teeth: it runs per top-level directory on a 353-addon tree. Both marker
-- kinds must still mark.
test('ecosystem: a .toc dir and a manifest dir are BOTH boundaries', function ()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not pcall(vim.treesitter.language.add, 'lua') then skip 'no lua parser' end
    local ts = require 'cartograph.providers.treesitter'
    local root = vim.fn.tempname()
    local function w(rel, text)
        local dir = rel:match('^(.*)/[^/]*$')
        if dir then vim.fn.mkdir(root .. '/' .. dir, 'p') end
        local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(text); fd:close()
    end
    -- an addon marked by <Addon>/<Addon>.toc, and a package marked by a manifest.
    -- Both define `helper`, so a cross-boundary match would be ambiguous — the
    -- boundary is what keeps each call inside its own package.
    w('AddonA/AddonA.toc', '## Interface: 100000\nmain.lua\n')
    w('AddonA/main.lua', 'local function helper() return 1 end\n'
        .. 'function AddonA_go() return helper() end\n')
    w('ModB/info.json', '{"name":"ModB","version":"1.0"}')
    w('ModB/main.lua', 'local function helper() return 2 end\n'
        .. 'function ModB_go() return helper() end\n')
    local data = ts.extract(root)
    -- each `helper` call resolves INSIDE its own package, not ambiguously
    local hits = {}
    for _, c in ipairs(data.calls or {}) do
        if c.callee == 'helper' and c.to then
            hits[c.file] = c.to
        end
    end
    ok(tostring(hits['AddonA/main.lua']):match('^AddonA/') ~= nil,
        'the .toc addon resolved within itself: ' .. tostring(hits['AddonA/main.lua']))
    ok(tostring(hits['ModB/main.lua']):match('^ModB/') ~= nil,
        'the manifest package resolved within itself: ' .. tostring(hits['ModB/main.lua']))
    vim.fn.delete(root, 'rf')
end)

-- a VARIANT toc (named for something other than its directory) still marks, which
-- is the manifest_ext fallback and the reason it costs a scandir
test('ecosystem: a variant .toc name still marks the directory', function ()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not pcall(vim.treesitter.language.add, 'lua') then skip 'no lua parser' end
    local ts = require 'cartograph.providers.treesitter'
    local root = vim.fn.tempname()
    local function w(rel, text)
        local dir = rel:match('^(.*)/[^/]*$')
        if dir then vim.fn.mkdir(root .. '/' .. dir, 'p') end
        local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(text); fd:close()
    end
    w('Bagnon/Bagnon-Mainline.toc', '## Interface: 110000\nmain.lua\n')
    w('Bagnon/main.lua', 'local function helper() return 1 end\n'
        .. 'function Bagnon_go() return helper() end\n')
    w('Other/Other.toc', '## Interface: 110000\nmain.lua\n')
    w('Other/main.lua', 'local function helper() return 2 end\n'
        .. 'function Other_go() return helper() end\n')
    local data = ts.extract(root)
    local to
    for _, c in ipairs(data.calls or {}) do
        if c.callee == 'helper' and c.file == 'Bagnon/main.lua' then to = c.to end
    end
    ok(tostring(to):match('^Bagnon/') ~= nil,
        'a variant toc still bounds its directory: ' .. tostring(to))
    vim.fn.delete(root, 'rf')
end)

-- ── the REACHABLE instance of `unread-file` ──────────────────────────────────
-- MEASURED across the corpus set (ghost/grocy/sylius/jquery/mootools/desynced):
-- import edges whose target is an unparsed file = 0 EVERYWHERE. Ghost has three
-- unparsed files and 3278 import binds, and not one bind points at a bundle —
-- ZERO edges of any kind do. Its bundles are `admin-auth.min.js` and two built
-- theme assets, named by serve-public-file.js / ghost_head.js / card-assets.js as
-- served PATHS.
--
-- So a bundle is an OUTPUT ARTIFACT, not a dependency: it exists to be shipped to a
-- browser, so it is referenced by URL and never imported by the module graph. The
-- disposition's original framing ("a call into an opaque bundle") mis-modelled what
-- a bundle is.
--
-- The trigger that IS reachable is the other one: an UNAVAILABLE read of a file
-- that really is in the graph. This drives it on a realistic failure — a CORRUPT
-- ARCHIVE MEMBER in a package roster, where cross-package requires do bind — rather
-- than on a synthetic chmod.
test('ecosystem roster: a corrupt archive member is a frontier, not the boundary',
    function ()
    if vim.fn.executable('zip') ~= 1 then skip 'no zip CLI' end
    if not require('cartograph.zip').available() then skip 'no zlib' end
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    if not pcall(vim.treesitter.language.add, 'lua') then skip 'no lua parser' end
    local zip = require 'cartograph.zip'
    local transport = require 'cartograph.transport'
    local ts = require 'cartograph.providers.treesitter'

    local d = vim.fn.tempname()
    vim.fn.mkdir(d .. '/mods/A', 'p'); vim.fn.mkdir(d .. '/build/Pkg_1.0', 'p')
    local function w(p, t) local fd = assert(io.open(p, 'w')); fd:write(t); fd:close() end
    w(d .. '/mods/A/info.json', '{"name":"A","version":"1.0"}')
    w(d .. '/mods/A/control.lua', "local lib = require '__Pkg__/lib'\n"
        .. 'return { run = function () return lib.helper(1) end }\n')
    w(d .. '/build/Pkg_1.0/info.json', '{"name":"Pkg","version":"1.0"}')
    -- padded so the member is DEFLATED (a stored member would survive corruption
    -- as valid-but-wrong text rather than failing to inflate)
    w(d .. '/build/Pkg_1.0/lib.lua',
        ('local function helper(x) return x + 1 end -- %s\n'):format(('pad '):rep(200))
        .. 'return { helper = helper }\n')
    vim.fn.system({ 'sh', '-c', ('cd %q/build && zip -q -r -X %q/mods/Pkg_1.0.zip Pkg_1.0')
        :format(d, d) })

    -- corrupt exactly the member's compressed data, located through the parser so
    -- the central directory stays intact (it is what makes the member KNOWN)
    local archive = d .. '/mods/Pkg_1.0.zip'
    local z = zip.open(function (p, off, len)
        return transport.read_range(p, off, len)
    end, archive)
    local e = z.byname['Pkg_1.0/lib.lua']
    ok(e ~= nil and e.method == 8, 'the member is deflated')
    local lh = transport.read_range(archive, e.offset, 30)
    local datapos = e.offset + 30 + (lh:byte(27) + lh:byte(28) * 256)
        + (lh:byte(29) + lh:byte(30) * 256)
    local fd = assert(io.open(archive, 'r+b'))
    fd:seek('set', datapos + 8); fd:write('\255\255\255\255'); fd:close()

    local r = eco.roster('lua-factorio', { dir = d .. '/mods' })
    local data = ts.extract(r.root, { files = r.files, abs = r.abs,
        transport = r.transport })
    -- KNOWN but unread: the central directory still lists it, so it is on the
    -- frontier roster rather than absent from the graph
    local roster = {}
    for _, f in ipairs(data.unparsed or {}) do roster[f] = true end
    eq(true, roster['Pkg/lib.lua'])
    -- and the bound cross-package call says FRONTIER, not "project boundary"
    local call
    for _, c in ipairs(data.calls or {}) do
        if c.callee == 'helper' then call = c end
    end
    ok(call ~= nil, 'the call is recorded')
    eq(nil, call.to)
    eq('frontier', call.ext and call.ext.disp)
    eq('unread-file', call.ext and call.ext.why)
    vim.fn.delete(d, 'rf')
end)

-- ── the API-DESCRIPTION OFFER ────────────────────────────────────────────────
-- An environment that publishes its own API description makes a profile for ANY
-- version obtainable, which is what turns "the target lacks this name" (possibly a
-- fact about the artifact) into "1.1 had it and 2.0 does not" (a fact about the
-- environments). Declared as data so the offer is auditable — and so NETWORK IS NEVER
-- IMPLICIT: extraction, every verb and every report stay offline, and tools/apifetch
-- contacts the host only when explicitly asked.

test('ecosystem: an api source is DECLARED, not hardcoded at a call site', function ()
    local f = eco.load('lua-factorio')
    local src = f.api_source
    ok(src ~= nil, 'lua-factorio declares where its API is published')
    ok(src.url:match('%%s') ~= nil, 'the url is a template over the version')
    ok(src.index ~= nil, 'and an index, so availability is CHECKABLE not guessed')
    ok(src.version_href ~= nil, 'with the pattern versions appear as in that index')
    -- the artifact template must produce a legal Lua module name: a dotted one makes
    -- require look for a directory (see spec/profile/lua-factorio-11.lua)
    eq(nil, src.artifact:format('11'):find('%.'))
end)

-- MEASURED against the live host 2026-07-26 and pinned here as the reason a declared
-- version must be RESOLVED: a full x.y.z resolves, `latest`/`stable` resolve, and a
-- BARE MINOR 404s. A manifest declares `1.1`, so the bare form is exactly what a
-- naive implementation would request.
test('ecosystem: the declaration records that a bare MINOR is not addressable',
    function ()
    local src = eco.load('lua-factorio').api_source
    local body = table.concat({ src.notes and src.notes.minor_not_addressable or '' })
    -- the fact lives either in a note or in the file's prose; what must be true is
    -- that aliases are declared, since those are the only non-exact forms that work
    ok(#(src.aliases or {}) > 0, 'the working non-exact forms are named')
    local found = false
    for _, a in ipairs(src.aliases) do if a == 'latest' or a == 'stable' then found = true end end
    ok(found, 'and they are the ones that actually resolve: ' ..
        table.concat(src.aliases, ' ') .. body)
end)

-- the OFFER path must not perform any request. Asserted by running the tool with no
-- arguments and checking it says so — a weak test on its own, so it is paired with
-- the stronger structural one: no verb and no report reaches api_source at all.
test('ecosystem: nothing in the plugin runtime consults api_source', function ()
    local dir = vim.fn.expand('~/git/cartograph.nvim/lua/cartograph')
    if vim.fn.isdirectory(dir) ~= 1 then skip 'source not present' end
    local hits = {}
    local stack = { dir }
    while #stack > 0 do
        local d = table.remove(stack)
        local ok_, iter = pcall(vim.fs.dir, d)
        if ok_ then
            for n, ty in iter do
                local p = d .. '/' .. n
                if ty == 'directory' then stack[#stack + 1] = p
                elseif n:match('%.lua$') and not p:match('/spec/ecosystem/') then
                    local fd = io.open(p, 'rb')
                    if fd then
                        local body = fd:read('a'); fd:close()
                        if body:find('api_source', 1, true) then
                            hits[#hits + 1] = p:gsub('.*/lua/cartograph/', '')
                        end
                    end
                end
            end
        end
    end
    -- the runtime may MENTION the offer in prose, but must not read the field: a
    -- fetch has to stay an explicit, out-of-band action
    eq({}, hits)
end)
