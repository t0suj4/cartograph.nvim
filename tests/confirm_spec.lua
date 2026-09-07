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

-- ── THE TIER MUST NOT OUTLIVE THE SESSION (CART-0832) ──────────────────────
-- This module's own header states the contract: "Runtime facts are SAMPLES ...
-- this is a session-live OVERLAY on the edges, NEVER FOLDED OR CACHED." It was
-- not enforced. `conf` is a flag on an ORDINARY edge between two real source
-- nodes, so the cache's synthetic-node test — the only thing that dropped
-- session state — never looked at it, and an observed edge came back
-- `confirmed` in the next session with nothing having observed anything.
-- ★ AND `confirmed` IS THE TOP OF THE LADDER, above `proven`: a stale flag does
-- not degrade an answer, it PROMOTES one.

test('confirm: the runtime tier is stripped at the persistence gate', function ()
    local cache = require 'cartograph.cache'
    local tier = require 'cartograph.tier'
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/m.lua', 'w'))
    fd:write('local function g() end\nlocal function f() g() end\nreturn f\n')
    fd:close()
    local ts = require 'cartograph.providers.treesitter'
    local data = ts.extract(root)
    data.root = root
    local edge
    for _, e in ipairs(data.edges) do if e.kind == 'ref' then edge = e end end
    ok(edge, 'the fixture produced a ref edge to observe')
    eq('matched', tier.of(edge))

    confirm.apply(data, { [edge.from .. '\31' .. edge.to] = true })
    eq('confirmed', tier.of(edge))

    local prev = vim.env.XDG_CACHE_HOME
    vim.env.XDG_CACHE_HOME = vim.fn.tempname()
    local ok_save = pcall(cache.save, data)
    ok(ok_save, 'the graph saves')

    -- ★★ THE LIVE OVERLAY SURVIVES THE SAVE. The shard builder stores the LIVE
    -- edge table by reference, so a fix that cleared the field in place would
    -- destroy the graph the user is looking at. Copy-on-write, and this is the
    -- assertion that keeps it that way.
    eq(true, edge.conf)
    eq('confirmed', tier.of(edge))

    local back = pcall(cache.load, root) and cache.load(root)
    vim.env.XDG_CACHE_HOME = prev
    if back then
        local reloaded
        for _, e in ipairs(back.edges or {}) do
            if e.from == edge.from and e.to == edge.to and e.kind == 'ref' then
                reloaded = e
            end
        end
        ok(reloaded, 'the edge itself is still persisted — only the FLAG is not')
        eq(nil, reloaded.conf)
        -- and it falls back to the tier it earned statically, not to nothing
        eq('matched', tier.of(reloaded))
    end
end)

test('confirm: every session-live node family is named at the gate, not saved by luck', function ()
    -- ⚠ kb `synthetic-var-node-families`: the never-persist list named FOUR of
    -- the seven adapter families, and `sf` / `an` / `k8` survived only because
    -- yaml, twig and .proto files carry no STAMP so their shard is nil. That
    -- accident holds only while those extensions stay unclaimed by a spec.
    local src = assert(io.open('lua/cartograph/cache.lua')):read('a')
    local gate = src:match("if n%.id:sub%(1, 5%) == 'sql::'.-then")
    ok(gate, 'the synthetic-node gate is still recognisable')
    for _, marker in ipairs({ 'db', 'dj', 'sf', 'an', 'pb', 'k8' }) do
        ok(gate:find('n%.' .. marker .. '%f[^%w]'),
            ('the %q family is not named at the persistence gate'):format(marker))
    end
end)
