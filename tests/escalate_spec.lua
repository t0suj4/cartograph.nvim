-- Escalation-on-hedge: the pure core (saturation detector + snapshot/diff
-- reconcile). The oracle run itself needs a live lua-ls, so here we SIMULATE
-- its in-place mutation and assert the diff surfaces the right findings —
-- especially the CONFLICT (the lua-ls-disagreement bug product).

local escalate = require 'cartograph.escalate'

test('escalate: hedge-saturated = zero proven, >=1 hedge', function ()
    local data = { calls = {
        -- fnA: a proven + a hedge → NOT saturated (has a proven edge)
        { fn = 'A', to = 'x', file = 'a.lua' },
        { fn = 'A', to = 'y', inferred = true, file = 'a.lua' },
        -- fnB: two hedges → saturated
        { fn = 'B', to = 'p', inferred = true, file = 'a.lua' },
        { fn = 'B', to = 'q', inferred = true, file = 'a.lua' },
        -- fnC: only refusals → NOT saturated (no hedge to escalate)
        { fn = 'C', file = 'a.lua' },
        -- fnD: a hedge + a refusal → saturated (proven==0, hedged>0)
        { fn = 'D', to = 'r', inferred = true, file = 'a.lua' },
        { fn = 'D', file = 'a.lua' },
    } }
    local sat = escalate.saturated(data)
    ok(sat.B, 'fnB (all-hedged) is saturated')
    ok(sat.D, 'fnD (hedge + refusal, no proven) is saturated')
    ok(not sat.A, 'fnA (has a proven edge) is NOT saturated')
    ok(not sat.C, 'fnC (all refused, no hedge) is NOT saturated')
end)

-- build the five reconcile cases, snapshot, simulate the oracle, diff
local function run_diff()
    local c_conf = { fn = 'B', callee = 'm1', to = 'X', inferred = true, file = 'a.lua', line = 0 }
    local c_confl = { fn = 'B', callee = 'm2', to = 'X', inferred = true, file = 'a.lua', line = 1 }
    local c_ref = { fn = 'B', callee = 'm3', to = 'X', inferred = true, file = 'a.lua', line = 2 }
    local c_rec = { fn = 'B', callee = 'm4', file = 'a.lua', line = 3 } -- refused (no to)
    local c_stale = { fn = 'B', callee = 'm5', to = 'X', inferred = true, file = 'a.lua', line = 4 }
    local data = { calls = { c_conf, c_confl, c_ref, c_rec, c_stale } }
    local snap = escalate.snapshot(data)
    -- simulate the lua-ls oracle mutating in place:
    c_conf.inferred = nil                     -- agreed on X → proven
    c_confl.to = 'Y'; c_confl.inferred = nil   -- said Y, not X → CONFLICT
    c_ref.to = nil; c_ref.inferred = nil       -- no such target → refuted
    c_rec.to = 'Z'                             -- resolved the refusal → recovered
    -- c_stale: untouched (oracle silent)
    local f = escalate.diff(snap, { B = { p = 0, h = 3 } })
    return f, { c_conf = c_conf, c_confl = c_confl, c_stale = c_stale }
end

test('escalate: diff surfaces confirmed / conflict / refuted / recovered / stale', function ()
    local f = run_diff()
    eq(1, #f.confirmed, 'one confirmed (oracle agreed on X)')
    eq(1, #f.conflict, 'one CONFLICT (static X vs lua-ls Y)')
    eq(1, #f.refuted, 'one refuted (no such target)')
    eq(1, #f.recovered, 'one recovered (refusal resolved)')
    eq(1, f.stale, 'one stale (oracle silent)')
end)

test('escalate: the conflict names both sides (the bug product)', function ()
    local f = run_diff()
    eq('X', f.conflict[1].was) -- what static resolved to
    eq('Y', f.conflict[1].now) -- what lua-ls resolved to
end)

test('escalate: priority (★) tags findings in hedge-saturated fns', function ()
    local f = run_diff() -- sat = {B=...}, all calls are in fn B
    ok(f.conflict[1].pri, 'conflict in a saturated fn is priority-flagged')
    ok(f.confirmed[1].pri, 'confirmed in a saturated fn is priority-flagged')
end)

test('escalate: anti-thrash — a stale hedge is marked and skipped next time', function ()
    local _, calls = run_diff()
    ok(calls.c_stale.escalated, 'the untouched hedge is marked escalated')
    -- a re-snapshot excludes it (never re-fires)
    local snap2 = escalate.snapshot({ calls = { calls.c_stale } })
    ok(next(snap2) == nil, 'an escalated call is not a candidate again')
    -- a confirmed (now-proven) call is also not a candidate
    local snap3 = escalate.snapshot({ calls = { calls.c_conf } })
    ok(next(snap3) == nil, 'a confirmed (proven) call is not a candidate again')
end)

test('escalate: report renders, conflicts headlined', function ()
    local f = run_diff()
    local lines = escalate.report(f, function (id) return 'N:' .. id end)
    ok(#lines > 0, 'report produced lines')
    local blob = table.concat(lines, '\n')
    ok(blob:find('CONFLICT'), 'the conflict section is present')
    ok(blob:find('N:X') and blob:find('N:Y'), 'both sides of the conflict named')
end)
