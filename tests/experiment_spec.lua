-- experiment: a declared experiment (CART-1537) run against a FAKE environment — every instrument kind's reading of its
-- process output, the A/B's interleaving and medians, a join's verdict, worktrees dropped whatever happened, the decision

local X = require 'cartograph.experiment'

-- a fake environment: exec answers from `script(dir, argv, vars)`, and every call and worktree is recorded
local function fake(script)
    local env = { root = '/repo', calls = {}, made = {}, dropped = {} }
    env.exec = function (dir, argv, vars) env.calls[#env.calls + 1] = { dir = dir, argv = table.concat(argv, ' '), vars = vars }; return script(dir, argv, vars, #env.calls) end
    env.worktree = function (ref) local d = '/wt/' .. ref; env.made[#env.made + 1] = d; return d end
    env.drop = function (d) env.dropped[#env.dropped + 1] = d end
    return env
end

test('experiment: a tactic instrument reads the toolbelt verdict; expect = fails inverts it', function ()
    local env = fake(function () return '{\n  holds = false,\n  why = "1 differ — first: x",\n  value = {}\n}\n' end)
    local r = X.run({ name = 't', instruments = { { kind = 'tactic', tactic = 'derive-accept' }, { kind = 'tactic', tactic = 'derive-accept', expect = 'fails' } } }, env)
    eq(false, r.rows[1].pass); eq('1 differ — first: x', r.rows[1].detail)
    eq(true, r.rows[2].pass)
    eq(false, r.accept, 'one failing instrument rejects')
    eq('/repo', env.calls[1].dir, 'no baseline: the working tree')
    ok(env.calls[1].argv:find('tools/toolbelt.lua run derive-accept -', 1, true), env.calls[1].argv)
end)

test('experiment: a specs instrument runs tests/run.sh with SPEC and reads its summary line', function ()
    local env = fake(function (_, _, vars) return vars.SPEC == 'a_spec,b_spec' and 'x\n12 passed, 0 failed, 1 skipped\n' or '3 passed, 2 failed, 0 skipped\n' end)
    local r = X.run({ instruments = { { kind = 'specs', specs = { 'a_spec', 'b_spec' } }, { kind = 'specs', specs = { 'c_spec' } } } }, env)
    eq(true, r.rows[1].pass); eq('12 passed, 0 failed, 1 skipped', r.rows[1].detail)
    eq(false, r.rows[2].pass)
end)

test('experiment: a join compares ROW lines by key across the trees; a value that differs fails it, nothing joined fails it', function ()
    local env = fake(function (dir)
        if dir == '/wt/HEAD' then return 'ROW\tk1\ta\nROW\tk2\tb\nROW\tgone\tz\n' end
        return 'noise\nROW\tk1\ta\nROW\tk2\tB\nROW\tnew\ty\n'
    end)
    local r = X.run({ baseline = 'HEAD', instruments = { { kind = 'join', file = '/abs/rows.lua' } } }, env)
    local j = r.rows[1]
    eq({ false, 2, 1, 1, 1 }, { j.pass, j.joined, j.differ, j.only_baseline, j.only_variant })
    ok(j.detail:find('first k2', 1, true), j.detail)
    local none = X.run({ baseline = 'HEAD', instruments = { { kind = 'join', file = '/abs/rows.lua' } } }, fake(function () return 'no rows\n' end))
    eq(false, none.rows[1].pass, 'a join of nothing proves nothing')
end)

test('experiment: an A/B runs the sides INTERLEAVED, a fresh process each, and judges the MEDIANS against the bound', function ()
    local times = { ['/wt/HEAD'] = { 10, 11, 30, 10, 10 }, ['/repo'] = { 10.5, 10.8, 10.4, 11, 10.6 } }
    local i = { ['/wt/HEAD'] = 0, ['/repo'] = 0 }
    local env = fake(function (dir) i[dir] = i[dir] + 1; return ('x %s ms'):format(times[dir][i[dir]]) end)
    local r = X.run({ baseline = 'HEAD', instruments = { { kind = 'ab', file = '/abs/t.lua', extract = 'x ([%d.]+) ms', runs = 5, bound = 1.10 } } }, env)
    local seq = {}
    for _, c in ipairs(env.calls) do seq[#seq + 1] = c.dir == '/wt/HEAD' and 'B' or 'V' end
    eq('BVBVBVBVBV', table.concat(seq), 'interleaved')
    eq({ 10, 10.6 }, { r.rows[1].baseline, r.rows[1].variant }, 'the medians — the outlier 30 does not move them')
    eq(true, r.rows[1].pass, '10.6 <= 10 x 1.10')
    local slow = X.run({ baseline = 'HEAD', instruments = { { kind = 'ab', file = '/abs/t.lua', extract = 'x ([%d.]+) ms', runs = 1, bound = 1.01 } } },
        fake(function (dir) return dir == '/repo' and 'x 20 ms' or 'x 10 ms' end))
    eq(false, slow.rows[1].pass)
end)

test('experiment: a relative instrument file is the VARIANT checkout\'s, on both sides; worktrees are dropped even when an instrument raises', function ()
    local env = fake(function (dir, argv) error('boom in ' .. dir) end)
    local r = X.run({ baseline = 'HEAD', instruments = { { kind = 'join', file = 'tools/x.lua' } } }, env)
    eq(false, r.rows[1].pass); ok(tostring(r.rows[1].detail):find('raised', 1, true), r.rows[1].detail)
    eq({ '/wt/HEAD' }, env.dropped, 'the baseline worktree is removed')
    local env2 = fake(function () return 'ROW\tk\tv\n' end)
    X.run({ baseline = 'HEAD', instruments = { { kind = 'join', file = 'tools/x.lua' } } }, env2)
    for _, c in ipairs(env2.calls) do ok(c.argv:find('@/repo/tools/x.lua', 1, true), 'both sides run the variant\'s instrument: ' .. c.argv) end
end)

test('experiment: a check instrument passes on its pattern; an unknown kind is a failing row, not an accept', function ()
    local r = X.run({ instruments = { { kind = 'check', file = '/abs/c.lua', pattern = '0 refused;.*, 0 differ;' }, { kind = 'nope' } } },
        fake(function () return 'CMREG 33 compiled, 0 refused; compile 2.1 s; residual 411 KB; 7000 subjects, 0 differ; match\n' end))
    eq(true, r.rows[1].pass); eq(false, r.rows[2].pass); eq(false, r.accept)
end)

test('experiment: a tactic with compare = <pattern> is NO REGRESSION — the same capture as the baseline passes, whatever the claim', function ()
    local P = '(%d+ agree, %d+ differ, %d+ no sample, %d+ refused)'
    local function out(t) return '{\n  holds = false,\n  why = "' .. t .. ' (plain) — first: resolve refused",\n  value = {}\n}\n' end
    local same = X.run({ baseline = 'HEAD', instruments = { { kind = 'tactic', tactic = 'derive-accept', compare = P } } },
        fake(function () return out('27 agree, 0 differ, 6 no sample, 1 refused') end))
    eq(true, same.rows[1].pass, same.rows[1].detail)
    local worse = X.run({ baseline = 'HEAD', instruments = { { kind = 'tactic', tactic = 'derive-accept', compare = P } } },
        fake(function (dir) return out(dir == '/repo' and '26 agree, 1 differ, 6 no sample, 1 refused' or '27 agree, 0 differ, 6 no sample, 1 refused') end))
    eq(false, worse.rows[1].pass)
    eq('baseline 27 agree, 0 differ, 6 no sample, 1 refused -> variant 26 agree, 1 differ, 6 no sample, 1 refused', worse.rows[1].detail)
    local nobase = X.run({ instruments = { { kind = 'tactic', tactic = 'derive-accept', compare = P } } }, fake(function () return out('1 agree, 0 differ, 0 no sample, 0 refused') end))
    eq(false, nobase.rows[1].pass, 'compare needs a baseline')
end)
