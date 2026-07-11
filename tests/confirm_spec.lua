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

test('confirm.diff: agreement, recovery, conflict, and the mono caveat', function ()
    local confirm = require 'cartograph.confirm'
    local data = { edges = {}, calls = {
        -- static resolved to b, runtime confirms b: CONFIRMED
        { callee = 'f', fn = 'A', to = 'b', file = 'm', line = 1 },
        -- static refused, runtime dispatched to c: RECOVERED
        { callee = 'g', fn = 'A', file = 'm', line = 2,
            refused = { rule = 'ambiguous' } },
        -- static resolved to d, runtime ONLY ever went to e (mono): CONFLICT
        { callee = 'h', fn = 'B', to = 'd', file = 'm', line = 3 },
        -- static resolved to x (unobserved), runtime saw {p,q}: NOT a
        -- conflict — a multi-target site, x may be an unobserved arm
        { callee = 'k', fn = 'B', to = 'x', file = 'm', line = 4 },
        -- never observed: untouched (absence never refutes)
        { callee = 'z', fn = 'C', to = 'x', file = 'm', line = 5 },
    } }
    local d = confirm.diff(data, {
        ['A\31f'] = { b = true },
        ['A\31g'] = { c = true },
        ['B\31h'] = { e = true },
        ['B\31k'] = { p = true, q = true },
    })
    eq(1, d.confirmed)
    eq(1, d.recovered)
    local kinds = {}
    for _, f in ipairs(d.findings) do kinds[f.kind] = (kinds[f.kind] or 0) + 1 end
    eq(1, kinds.recovered)
    eq(1, kinds.conflict, 'mono static≠runtime is a sound conflict')
    eq(1, kinds.polymorphic, 'multi-target site is not a conflict (unobserved arm)')
    -- the confirmed + recovered calls carry the tier; the unobserved one does not
    ok(data.calls[1].conf, 'agreed call confirmed')
    ok(data.calls[2].conf and data.calls[2].to == 'c', 'recovered adopts runtime target')
    ok(not data.calls[5].conf and data.calls[5].to == 'x',
        'unobserved static call untouched')
end)
