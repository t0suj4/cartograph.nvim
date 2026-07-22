-- bandlink: the cross-band LINKAGE resolver (federation F1). resolve_ref matches a
-- ref's OWNER-qualified key EXACTLY in the const-selected target band(s) — never a
-- bare-method (tail) fallback, which would grab a sibling class's method (the WRONG
-- cases the recall-diff gate caught). An owner-key miss = inherited/frontier = MISS,
-- recovered by the ancestor hop, never guessed.

local bandlink = require 'cartograph.bandlink'

local RUBY = function () return 'ruby' end
-- per-band exact indexes (build_index shape) + the const->band map
local function fixture()
    local idx = {
        lib = { exact = {
            ['Util.run'] = { { id = 'u1', kind = 'method', file = 'lib/util.rb' } },
            ['Other.run'] = { { id = 'o1', kind = 'method', file = 'lib/other.rb' } },
        } },
        app = { exact = {
            ['User#save'] = { { id = 's1', kind = 'method', file = 'app/user.rb' } },
        } },
    }
    local const_index = { Util = { lib = true }, Other = { lib = true }, User = { app = true } }
    return const_index, idx
end

test('bandlink: resolves an owner-qualified ref to the owner\'s method cross-band', function ()
    local ci, idx = fixture()
    local id, why = bandlink.resolve_ref('Util.run', ci, idx, 'ruby', RUBY)
    eq('u1', id); eq('const', why)
end)

test('bandlink: NO tail fallback — a sibling class\'s same-named method is NOT grabbed', function ()
    local ci, idx = fixture()
    -- Util's band (lib) defines Other.run but NOT Util.run → must MISS, not grab o1
    idx.lib.exact['Util.run'] = nil
    local id, why = bandlink.resolve_ref('Util.run', ci, idx, 'ruby', RUBY)
    eq(nil, id); eq('miss', why)
end)

test('bandlink: an inherited method (owner-key absent in owner band) MISSes', function ()
    local ci, idx = fixture()
    -- User#find is inherited (not defined on User in app) → miss (ancestor hop's job)
    local id, why = bandlink.resolve_ref('User#find', ci, idx, 'ruby', RUBY)
    eq(nil, id); eq('miss', why)
end)

test('bandlink: a non-constant (bare) ref is no-const, not attempted', function ()
    local ci, idx = fixture()
    local id, why = bandlink.resolve_ref('run', ci, idx, 'ruby', RUBY)
    eq(nil, id); eq('no-const', why)
end)

test('bandlink: >1 fit across the const\'s bands is ambiguous, never a guess', function ()
    local ci, idx = fixture()
    -- Util defined in TWO bands, both with Util.run → ambiguous
    ci.Util = { lib = true, app = true }
    idx.app.exact['Util.run'] = { { id = 'u2', kind = 'method', file = 'app/util.rb' } }
    local id, why = bandlink.resolve_ref('Util.run', ci, idx, 'ruby', RUBY)
    eq(nil, id); eq('ambiguous', why)
end)

test('bandlink: a name never crosses languages', function ()
    local ci, idx = fixture()
    local id = bandlink.resolve_ref('Util.run', ci, idx, 'python', RUBY) -- ref is python, def is ruby
    eq(nil, id)
end)
