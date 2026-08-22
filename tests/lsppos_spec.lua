-- lsppos: the LSP WIRE range, and the fact that it is NOT an `at` range.
-- The module exists because the two are shape-identical and the seam guard is a
-- line-pattern scan, so `loc.range.start.line` and `node.range.start.line` are
-- indistinguishable to it (CART-0502). These tests pin the distinction the guard
-- cannot see -- if the two representations ever converge, the module is pointless
-- and this file says so out loud.

local lsppos = require 'cartograph.lsppos'
local at = require 'cartograph.at'

local function wire(sl, sc, el, ec)
    return { start = { line = sl, character = sc },
        ['end'] = { line = el, character = ec } }
end

test('lsppos: the four wire coordinates', function ()
    local r = wire(3, 7, 4, 11)
    eq(3, lsppos.sl(r))
    eq(7, lsppos.sc(r))
    eq(4, lsppos.el(r))
    eq(11, lsppos.ec(r))
end)

test('lsppos: THE DISTINCTION — same shape, different char field', function ()
    local w = wire(3, 7, 4, 11)
    -- the coordinate the two representations SHARE is the only one a pattern
    -- guard can match, which is exactly why it cannot fence them apart
    eq(lsppos.sl(w), at.sl(w))
    eq(lsppos.el(w), at.el(w))
    -- and the ones they do not share: an `at` reader on a wire range gets nil,
    -- silently, which is the latent break this module names
    eq(nil, at.sc(w))
    eq(nil, at.ec(w))
    -- the mirror: a wire reader on an `at` range is just as blind
    local ours = { start = { line = 3, char = 7 }, ['end'] = { line = 4, char = 11 } }
    eq(7, at.sc(ours))
    eq(nil, lsppos.sc(ours))
end)

test('lsppos: a location yields its range, LocationLink first', function ()
    -- LocationLink: the SELECTION range (the identifier) beats the target range
    -- (the whole definition) -- the preference fieldharvest open-coded
    eq(9, lsppos.line({ targetSelectionRange = wire(9, 0, 9, 4),
        targetRange = wire(7, 0, 12, 1), uri = 'file:///x' }))
    eq(7, lsppos.line({ targetRange = wire(7, 0, 12, 1), uri = 'file:///x' }))
    eq(2, lsppos.line({ range = wire(2, 0, 2, 5), uri = 'file:///x' })) -- Location
    eq(nil, lsppos.range({ uri = 'file:///x' }))
    eq(nil, lsppos.line({ uri = 'file:///x' }))
    eq(nil, lsppos.range(nil))
end)
