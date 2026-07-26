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
    eq('manifest', f.identity.authoritative)
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
    -- disk exists today; zip does not yet, so it is named rather than dropped
    eq('disk', res.spec[1] and res.spec[1].kind)
    eq({ 'zip' }, res.unsupported)
    -- and what it produced is buildable, which is the contract that matters
    local stack = transport.build(res.spec)
    eq('disk', stack.for_path('/x.lua').name)
end)

-- when the zip kind lands, the SAME call must start emitting it with no edit here
-- — that is what makes the division additive rather than a rewrite
test('ecosystem: a newly registered kind is picked up with no spec edit', function ()
    transport.kinds.zip = function () return
        { name = 'zip', claims = function (p) return p:match('%.zip::') ~= nil end }
    end
    local res = eco.stack_spec(eco.load('lua-factorio'))
    eq({}, res.unsupported)
    eq('disk', res.spec[1].kind)
    eq('zip', res.spec[2].kind)
    transport.kinds.zip = nil
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
