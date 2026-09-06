-- THE UNIQUE-OWNER RUNG (CART-0806): a member name that belongs to exactly ONE
-- callable type in the distilled surface, and that the project never names, types
-- its own receiver. The rung is tested through the PROFILE's half — the engine's
-- half needs a corpus index, and the two gates are pinned separately below.

local prof = require 'cartograph.spec.profile'

local function node_profile()
    local ok, p = pcall(function ()
        return dofile(vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2),
            ':p:h:h') .. '/lua/cartograph/spec/profile/node.lua')
    end)
    return ok and p or nil
end

test('uniq: a name with ONE callable owner types its receiver', function ()
    local p = node_profile()
    if not p or not p.uniq_member then skip 'no node profile installed' end
    eq('Element', p.uniq_member('getAttribute'))
    eq('Element', p.uniq_member('setAttribute'))
    eq('Node', p.uniq_member('appendChild'))
    eq('ParentNode', p.uniq_member('querySelectorAll'))
    eq('String', p.uniq_member('toLowerCase'))
    eq('Array', p.uniq_member('splice'))
end)

test('uniq: THE KEY REFUSES the names a project is most likely to use', function ()
    local p = node_profile()
    if not p or not p.uniq_member then skip 'no node profile installed' end
    -- ★ this is what makes the rung sound rather than merely plausible: the
    -- generic names are exactly the ambiguous ones, and they decline themselves.
    -- get 14 callable owners, delete 13, has 11, add 10, set 9,
    -- addEventListener 230.
    for _, n in ipairs({ 'get', 'set', 'add', 'has', 'delete',
        'addEventListener', 'removeEventListener', 'forEach' }) do
        eq(nil, p.uniq_member(n))
    end
end)

test('uniq: a NON-CALLABLE member is never an owner', function ()
    local p = node_profile()
    if not p or not p.uniq_member then skip 'no node profile installed' end
    -- ⚠ THE BUG THIS PINS: `AddEventListenerOptions.once` is a BOOLEAN property of
    -- an options dictionary and was the unique owner of the name `once`, so an
    -- event emitter's `.once(...)` would have been typed as an options bag — 68
    -- sites on converse.js. A call resolves only to something declared callable.
    eq(nil, p.uniq_member('once'))
    eq(nil, p.uniq_member('passive'))
    eq(nil, p.uniq_member('capture'))
end)

test('uniq: the rung mints only through the INFERRED disposition', function ()
    local p = node_profile()
    if not p or not p.mint_path then skip 'no node profile installed' end
    -- a plain stdlib disposition must NOT take the unique-owner branch: without
    -- the engine's corpus check the project-names-it gate has not been applied,
    -- and that gate is the whole soundness argument
    eq(nil, p.mint_path('getAttribute', 'elem.getAttribute', 'stdlib'))
    eq('Element.getAttribute',
        p.mint_path('getAttribute', 'elem.getAttribute', 'stdlib', { inferred = true }))
    -- and a name the surface does not uniquely own stays refused either way
    eq(nil, p.mint_path('get', 'thing.get', 'stdlib', { inferred = true }))
end)
