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

-- ANCESTOR HOP (M.resolve over the const-path miss): an inherited/reopened method
-- lives on a PARENT in another band; chase data.ruby_anc to it. WRONG stays 0.
test('bandlink: ancestor hop resolves an INHERITED method to the parent\'s band', function ()
    local ci, idx = fixture()
    -- User#find is not on User (app) but on its parent ApplicationRecord (in lib)
    idx.lib.exact['ApplicationRecord#find'] = { { id = 'af', kind = 'method', file = 'lib/ar.rb' } }
    ci.ApplicationRecord = { lib = true }
    local anc = bandlink.ancestry({ { c = 'User', p = 'ApplicationRecord', mode = 'inst' } })
    -- const path alone misses; the hop recovers it
    eq(nil, (bandlink.resolve_ref('User#find', ci, idx, 'ruby', RUBY)))
    local id, why = bandlink.resolve('User#find', ci, idx, anc, 'ruby', RUBY)
    eq('af', id); eq('ancestor', why)
end)

test('bandlink: ancestor hop is nearest-first (own def wins, no hop needed)', function ()
    local ci, idx = fixture()
    idx.app.exact['User#save'] = { { id = 's1', kind = 'method', file = 'app/user.rb' } }
    idx.lib.exact['ApplicationRecord#save'] = { { id = 'as', kind = 'method', file = 'lib/ar.rb' } }
    ci.ApplicationRecord = { lib = true }
    local anc = bandlink.ancestry({ { c = 'User', p = 'ApplicationRecord', mode = 'inst' } })
    local id, why = bandlink.resolve('User#save', ci, idx, anc, 'ruby', RUBY)
    eq('s1', id); eq('const', why) -- User's OWN def, hop not taken
end)

test('bandlink: ancestor hop is honest — two distinct parents define it → no guess', function ()
    local ci, idx = fixture()
    idx.lib.exact['A#run'] = { { id = 'ra', kind = 'method', file = 'lib/a.rb' } }
    idx.lib.exact['B#run'] = { { id = 'rb', kind = 'method', file = 'lib/b.rb' } }
    ci.A = { lib = true }; ci.B = { lib = true }; ci.C = { app = true }
    -- C mixes in A and B (same frontier depth), both define run → ambiguous, MISS
    local anc = bandlink.ancestry({
        { c = 'C', p = 'A', mode = 'inst' }, { c = 'C', p = 'B', mode = 'inst' } })
    local id, why = bandlink.resolve('C#run', ci, idx, anc, 'ruby', RUBY)
    eq(nil, id); eq('miss', why)
end)

test('bandlink: singleton (.) hop chases superclass singletons then extend modules', function ()
    local ci, idx = fixture()
    idx.lib.exact['Base.build'] = { { id = 'bb', kind = 'method', file = 'lib/base.rb' } }
    ci.Base = { lib = true }; ci.Widget = { app = true }
    local anc = bandlink.ancestry({ { c = 'Widget', p = 'Base', mode = 'sings' } })
    local id, why = bandlink.resolve('Widget.build', ci, idx, anc, 'ruby', RUBY)
    eq('bb', id); eq('ancestor', why)
end)

-- EXTENDS HOP (java/php/js) — the single-parent superclass chain (data.extends), the
-- cross-band analog of resolve_super. Owner-key miss on `Class::m` → walk to the parent
-- that defines it, in another band, via the SAME const->band exact discipline.
local JAVA = function () return 'java' end
test('bandlink: extends hop resolves an inherited java method (::) to the superclass band', function ()
    local ci, idx = fixture()
    idx.lib.exact['Base::run'] = { { id = 'br', kind = 'method', file = 'lib/Base.java' } }
    ci.Base = { lib = true }; ci.Impl = { app = true }
    local ch = bandlink.chains({ extends = { { child = 'Impl', parent = 'Base', file = 'app/Impl.java' } } })
    eq(nil, (bandlink.resolve_ref('Impl::run', ci, idx, 'java', JAVA)))
    local id, why = bandlink.resolve('Impl::run', ci, idx, ch, 'java', JAVA)
    eq('br', id); eq('ancestor', why)
end)

test('bandlink: extends hop walks a TRANSITIVE chain to the nearest definer', function ()
    local ci, idx = fixture()
    idx.lib.exact['Grand::run'] = { { id = 'gr', kind = 'method', file = 'lib/Grand.java' } }
    ci.Grand = { lib = true }; ci.Mid = { lib = true }; ci.Leaf = { app = true }
    -- Leaf -> Mid -> Grand; only Grand defines run
    local ch = bandlink.chains({ extends = {
        { child = 'Leaf', parent = 'Mid', file = 'a' }, { child = 'Mid', parent = 'Grand', file = 'b' } } })
    local id, why = bandlink.resolve('Leaf::run', ci, idx, ch, 'java', JAVA)
    eq('gr', id); eq('ancestor', why)
end)

test('bandlink: extends collision (two distinct parents) stops the walk — no guess', function ()
    local ci, idx = fixture()
    idx.lib.exact['P1::run'] = { { id = 'p1', kind = 'method', file = 'lib/P1.java' } }
    ci.P1 = { lib = true }; ci.C = { app = true }
    -- C declared with two different parents across files → build_super sets false
    local ch = bandlink.chains({ extends = {
        { child = 'C', parent = 'P1', file = 'a' }, { child = 'C', parent = 'P2', file = 'b' } } })
    local id, why = bandlink.resolve('C::run', ci, idx, ch, 'java', JAVA)
    eq(nil, id); eq('miss', why)
end)
