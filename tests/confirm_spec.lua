-- The confirmed tier: runtime observation upgrades/recovers edges. The pass
-- is pure over (data, observed), so it tests without a live session; the
-- self:// observation source is the production wiring.

local confirm = require 'cartograph.confirm'
local ladder = require 'cartograph.ladder'

local function mkdata()
    return {
        edges = {
            { from = 'a', to = 'b', kind = 'ref' },              -- static, will confirm
            { from = 'a', to = 'c', kind = 'ref', inferred = true }, -- static ~, not observed
        },
        calls = {
            { callee = 'b', fn = 'a', to = 'b', file = 'm', line = 1 },
            { callee = 'x', fn = 'a', file = 'm', line = 2,
                refused = { rule = 'ambiguous' } }, -- static refused
        },
    }
end

test('confirm: observed edges upgrade to the confirmed tier', function ()
    local data = mkdata()
    local r = confirm.apply(data, { ['a\31b'] = true })
    eq(1, r.confirmed)
    eq(0, r.recovered)
    local ab
    for _, e in ipairs(data.edges) do if e.to == 'b' then ab = e end end
    ok(ab.conf, 'the observed edge is runtime-confirmed')
    -- the matching call carries the tier for the ladder
    ok(data.calls[1].conf, 'resolved call a->b confirmed')
    eq('confirmed', ladder.rung_of(data.calls[1]), 'top rung')
end)

test('confirm: runtime RECOVERS what static refused/missed', function ()
    local data = mkdata()
    -- runtime observed a dispatch a->d that static never resolved
    local r = confirm.apply(data, { ['a\31d'] = true })
    eq(1, r.recovered)
    local ad
    for _, e in ipairs(data.edges) do if e.to == 'd' then ad = e end end
    ok(ad and ad.conf, 'a recovered runtime edge, conf-tiered')
    eq('ref', ad.kind)
end)

test('confirm: absence never refutes (partial-observation soundness)', function ()
    local data = mkdata()
    -- observe only a->b; a->c (static ~) is NOT observed
    confirm.apply(data, { ['a\31b'] = true })
    local ac
    for _, e in ipairs(data.edges) do if e.to == 'c' then ac = e end end
    ok(ac and not ac.conf and ac.inferred,
        'the unobserved static edge is untouched — not demoted, not dropped')
end)

test('confirm: a self-loop is never recovered as an edge', function ()
    local data = { edges = {}, calls = {} }
    local r = confirm.apply(data, { ['a\31a'] = true })
    eq(0, r.recovered)
    eq(0, #data.edges)
end)
