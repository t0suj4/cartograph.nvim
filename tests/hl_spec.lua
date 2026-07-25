-- hl.blend: the pure colour-blend math shared by the concern tints (hl.setup)
-- and the relationship tints (symbols.hl_setup). Extracted from two byte-identical
-- local closures; this pins the arithmetic so the shared helper can't drift.

local hl = require 'cartograph.hl'

test('hl.blend: alpha endpoints return bg and hue verbatim', function ()
    eq('#123456', hl.blend(0xabcdef, 0x123456, 0), 'alpha 0 is the background')
    eq('#abcdef', hl.blend(0xabcdef, 0x123456, 1), 'alpha 1 is the hue')
end)

test('hl.blend: a half blend is the per-channel midpoint', function ()
    eq('#808080', hl.blend(0xffffff, 0x000000, 0.5), 'white over black at 0.5')
    eq('#808080', hl.blend(0x000000, 0xffffff, 0.5), 'symmetric the other way')
end)

test('hl.blend: channels blend independently', function ()
    -- hue r=0x40 g=0x80 b=0xc0 over black at 0.5 → halved each
    eq('#204060', hl.blend(0x4080c0, 0x000000, 0.5), 'per-channel, no bleed')
end)
