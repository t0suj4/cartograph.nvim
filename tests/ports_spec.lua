-- ports: the per-band PORT SURFACE (federation F1). A band PROVIDES the symbols it
-- defines (+ owner constants) and NEEDS the free refs to symbols it doesn't define
-- (cross-band resolved or frontier); const_index is the constant->band(s) linkage map.

local ports = require 'cartograph.ports'

test('ports: owner_of splits the last method separator, language-general', function ()
    eq('Foo', ports.owner_of('Foo#bar'))          -- ruby instance
    eq('Foo', ports.owner_of('Foo.bar'))          -- ruby singleton / js
    eq('pkg.Class', ports.owner_of('pkg.Class::m')) -- java (:: wins over the pkg dots)
    eq('A::B', ports.owner_of('A::B::c'))          -- nested constant
    eq(nil, ports.owner_of('bare'))                -- not method-qualified
end)

-- two bands: app/models (defines User#save, Base#find via a reopen) and lib/util.
-- band = directory depth 2 -> "app/models" and "lib".
local function graph()
    return {
        nodes = {
            { id = 'app/models/user.rb::User#save@1', name = 'User#save',
                kind = 'method', file = 'app/models/user.rb' },
            { id = 'app/models/base.rb::Base#find@1', name = 'Base#find',
                kind = 'method', file = 'app/models/base.rb' },
            { id = 'lib/util.rb::Util.run@1', name = 'Util.run',
                kind = 'method', file = 'lib/util.rb' },
            -- a torn def must NOT appear in provides
            { id = 'lib/util.rb::Util.torn@9', name = 'Util.torn',
                kind = 'method', file = 'lib/util.rb', torn = true },
        },
        calls = {
            -- same-band call (User -> Base, both app/models) : NOT a need
            { file = 'app/models/user.rb', full = 'Base#find', callee = 'find',
                to = 'app/models/base.rb::Base#find@1' },
            -- cross-band resolved (app/models -> lib) : a need, routed by const Util
            { file = 'app/models/user.rb', full = 'Util.run', callee = 'run',
                to = 'lib/util.rb::Util.run@1' },
            -- unresolved frontier : a need with no target band
            { file = 'lib/util.rb', full = 'Missing.gone', callee = 'gone' },
        },
    }
end

test('ports: provides excludes torn defs; consts index owners', function ()
    local s = ports.surface(graph(), ports.default_band_of(2))
    local am, lib = s.bands['app/models'], s.bands['lib']
    ok(am.provides['User#save'] and am.provides['Base#find'], 'app/models provides its methods')
    ok(lib.provides['Util.run'], 'lib provides Util.run')
    eq(nil, lib.provides['Util.torn'])            -- torn excluded (mirrors build_index)
    ok(am.consts['User'] and am.consts['Base'], 'owner constants indexed')
    ok(s.const_index['Util'] and s.const_index['Util']['lib'], 'const->band map routes Util to lib')
end)

test('ports: needs = cross-band + frontier, not same-band', function ()
    local s = ports.surface(graph(), ports.default_band_of(2))
    local am, lib = s.bands['app/models'], s.bands['lib']
    eq(nil, am.needs['Base#find'])                -- same-band → not a need
    eq('lib', am.needs['Util.run'].to)            -- cross-band → need, records target band
    ok(lib.needs['Missing.gone'] and lib.needs['Missing.gone'].to == nil, 'frontier need, no target band')
end)
