-- SPEC-FAILS (discovery): does the named spec FAIL in a given tree? The oracle a mutation check stands on
-- (CART-1174): run `SPEC=<spec> bash tests/run.sh` in `root` and read the SUMMARY LINE ("N passed, M failed,
-- K skipped") — never a marker grep (a lost newline glues FAIL onto the line before it: harness #11).
-- CLAIM: at least one test failed. ⚠ A run that RAN NOTHING is not a pass and not a failure: the filter named no spec
-- (harness #18 — a positional argument is silently ignored, so the filter is the SPEC variable, and it must name a
-- spec file such as `tactic_spec`); the measure says so and the claim refuses.
local function repo_of_toolbelt()
    -- ABSOLUTE: a module loaded through a relative runtimepath entry ('.') reports a relative source path
    local here = vim.fn.fnamemodify((debug.getinfo(1, 'S').source:gsub('^@', '')), ':p')
    return (here:gsub('/lua/cartograph/tactics/[^/]*$', ''))
end

local M = {}

--- run the spec in `root` -> { passed, failed, skipped, ran, summary, code } | nil, why
--- env: extra environment variables for the runner { NAME = value } (CART-1368: DERIVE=<op> for the verb audit) —
--- merged over the inherited environment, never replacing SPEC
function M.run(root, spec, timeout, env)
    -- the runner in its OWN process group (setsid): a spec that HANGS (a mutation that makes a loop infinite) is
    -- killed WITH its children on the timeout — killing only bash left each hung `node` spinning at 100% CPU
    -- (measured: three orphans, 20-60 min each, one per re-run of one mutation)
    -- ⚠ NOT proc:wait(timeout): on its timeout nvim's wait SIGKILLs the LEADER only (`setsid bash`) and then waits a
    -- second full timeout for the result — which needs the output pipes closed, and the hung grandchild (a busy headless
    -- nvim, deaf to SIGTERM: harness #26) holds them open. MEASURED (CART-1333): a hung mutant ran 2 x 600 s, an outer
    -- `timeout` killed the tool first, no verdict, and the spec process ran on as an orphan for 20+ min. So the wait is
    -- ours: on the timeout the whole GROUP is SIGKILLed first, then the pipes close and the result arrives
    local proc, result
    local ok, err = pcall(function ()
        local e = {}
        for k, v in pairs(env or {}) do e[k] = v end
        e.SPEC, e.CARTOGRAPH_NVIM = spec, vim.v.progpath
        proc = vim.system({ 'setsid', 'bash', 'tests/run.sh' }, { cwd = root, text = true, env = e }, function (o) result = o end)
    end)
    if not ok then return nil, 'the runner did not start: ' .. tostring(err) end
    local finished = vim.wait(timeout or 600000, function () return result ~= nil end, 50)
    local obj = result
    if not finished or (obj and (obj.signal == 15 or obj.signal == 9)) then
        -- TIMED OUT: a hang is a spec that did NOT pass — a failure, named
        local pgid = proc.pid
        vim.system({ 'kill', '-9', '--', '-' .. pgid }):wait()
        vim.wait(10000, function () return result ~= nil end, 50)
        local gone = vim.system({ 'kill', '-0', '--', '-' .. pgid }):wait().code ~= 0
        local secs = (timeout or 600000) / 1000
        return { passed = 0, failed = 1, skipped = 0, ran = 1, code = 124, timed_out = true, pgid = pgid, group_gone = gone,
            summary = ('TIMED OUT after %g s (a hang: the spec did not pass; its process group killed)'):format(secs) }
    end
    local out = (obj.stdout or '') .. '\n' .. (obj.stderr or '')
    local p, f, s
    for a, b, c in out:gmatch('(%d+) passed, (%d+) failed, (%d+) skipped') do p, f, s = tonumber(a), tonumber(b), tonumber(c) end
    if not p then return nil, ('no summary line from %s/tests/run.sh (exit %s)'):format(root, tostring(obj.code)) end
    -- the NAMES of the failed tests (the harness's `  FAIL  <name>` lines) — WHICH tests a mutation broke is what a
    -- perturbation experiment reads (CART-1398: swap a semantics, see who depends on it). The SUMMARY still decides the
    -- counts: a lost newline can glue a FAIL onto the line before it (harness #11), so the names are read anywhere in a
    -- line and never counted.
    local failures = {}
    for name in out:gmatch('  FAIL  ([^\n]+)') do failures[#failures + 1] = vim.trim(name) end
    return { passed = p, failed = f, skipped = s, ran = p + f, code = obj.code, failures = failures,
        summary = ('%d passed, %d failed, %d skipped'):format(p, f, s) }
end

--- `NAME=value` items (a list, or `A=1,B=2`) -> { NAME = value } | nil; an item without `=` is ignored by name
function M.env_of(items)
    if not items then return nil end
    local e = {}
    for _, it in ipairs(items) do
        local k, v = tostring(it):match('^([%w_]+)=(.*)$')
        if k then e[k] = v end
    end
    return e
end

M.entry = {
    name = 'spec-fails',
    kind = 'discovery',
    summary = 'does SPEC fail in a tree? runs `SPEC=<spec> bash tests/run.sh` in root (default: the cartograph repo) and reads the summary line; a run that ran nothing refuses; timeout = seconds (default 600) — a hang is a failure, its process group killed',
    params = { spec = 'string', root = 'string?', timeout = 'string?', env = 'list?' },
    measure = function (_, p)
        local t0 = vim.uv.hrtime()
        local v, why = M.run(p.root or repo_of_toolbelt(), p.spec, p.timeout and tonumber(p.timeout) * 1000 or nil, M.env_of(p.env))
        v = v or { error = why }
        v.secs = (vim.uv.hrtime() - t0) / 1e9
        return v
    end,
    claim = function (v)
        if v.error then return false, v.error end
        if v.ran == 0 then return false, ('the spec RAN NOTHING (%s) — SPEC must name a spec file, e.g. tactic_spec'):format(v.summary) end
        return v.failed > 0, v.summary
    end,
}

-- the fixture both this entry's and mutation-check's examples use: a tiny repo with its OWN runner (the example must
-- not run cartograph's whole harness inside cartograph's suite)
M.FIXTURE = {
    ['lib/guard.lua'] = 'local M = {}\nfunction M.positive(x)\n  if x > 0 then return true end\n  return false\nend\nfunction M.nonempty(t) return #t > 0 end\nreturn M\n',
    ['tests/run.sh'] = '#!/usr/bin/env bash\ncd "$(dirname "$0")/.."\nexec "${CARTOGRAPH_NVIM:-nvim}" --headless -u NONE -l tests/mini.lua\n',
    ['tests/mini.lua'] = table.concat({
        "local spec = os.getenv('SPEC') or ''",
        "local pass, fail = 0, 0",
        "package.path = 'lib/?.lua;' .. package.path",
        "local f = loadfile('tests/' .. spec .. '.lua')",
        "if f then local ok = pcall(f, function (c) if c then pass = pass + 1 else fail = fail + 1; io.write(('  FAIL  check %d\\n'):format(pass + fail)) end end); if not ok then fail = fail + 1 end end",
        "io.write(('%d passed, %d failed, %d skipped\\n'):format(pass, fail, 0))",
    }, '\n') .. '\n',
    ['tests/guard_spec.lua'] = "local check = ...\nlocal g = require('guard')\ncheck(g.positive(1) == true)\ncheck(g.positive(-1) == false)\ncheck(g.positive(0) == false)\ncheck(g.nonempty({}) == false)\n",
    ['tests/weak_spec.lua'] = "local check = ...\nlocal g = require('guard')\ncheck(g.positive(1) == true)\n",
    ['tests/broken_spec.lua'] = "local check = ...\ncheck(1 == 2)\n",
    -- (a spec that fails only under an environment variable: the `env` param's example, and derive-check's)
    ['tests/env_spec.lua'] = "local check = ...\ncheck(os.getenv('DERIVE') ~= 'bad')\n",
    -- (a spec that HANGS busy: a headless nvim in a loop ignores SIGTERM — the case a timeout must kill by group)
    ['tests/hang_spec.lua'] = "local check = ...\nlocal n = 0\nfor _ = 1, math.huge do n = n + 1 end\ncheck(n > 0)\n",
}

M.entry.examples = {
    {
        name = 'a spec with a failing check: the claim holds, and the failed test is NAMED',
        files = M.FIXTURE,
        params = function (store) return { spec = 'broken_spec', root = store.data.root } end,
        expect = { holds = true, check = function (v) return vim.deep_equal(v.failures, { 'check 1' }), vim.inspect(v.failures) end },
    },
    {
        name = 'a green spec: the claim fails, and says what ran',
        files = M.FIXTURE,
        params = function (store) return { spec = 'guard_spec', root = store.data.root } end,
        expect = { holds = false, check = function (v) return v.passed == 4 and v.failed == 0, 'guard_spec: ' .. tostring(v.summary) end },
    },
    {
        -- CART-1333: the wait used to SIGKILL only the group leader and then wait a second timeout on the pipes the
        -- hung grandchild held — 2 x the timeout, and an orphan if anything outside gave up first
        name = 'a spec that HANGS is a failure at the timeout — not twice it — and its whole process group is gone',
        files = M.FIXTURE,
        params = function (store) return { spec = 'hang_spec', root = store.data.root, timeout = '2' } end,
        expect = { holds = true, check = function (v)
            return v.timed_out and v.group_gone and v.secs < 4, ('timed_out %s group_gone %s after %.1f s'):format(tostring(v.timed_out), tostring(v.group_gone), v.secs or -1)
        end },
    },
    {
        name = 'an ENVIRONMENT for the runner (env = NAME=value): the spec fails under it',
        files = M.FIXTURE,
        params = function (store) return { spec = 'env_spec', root = store.data.root, env = { 'DERIVE=bad' } } end,
        expect = { holds = true, check = function (v) return v.failed == 1, tostring(v.summary) end },
    },
    {
        name = '…and the same spec WITHOUT it is green: the variable reached the runner, nothing else changed',
        files = M.FIXTURE,
        params = function (store) return { spec = 'env_spec', root = store.data.root } end,
        expect = { holds = false, check = function (v) return v.passed == 1 and v.failed == 0, tostring(v.summary) end },
    },
    {
        name = 'a SPEC naming no spec runs nothing: refused, never read as green',
        files = M.FIXTURE,
        params = function (store) return { spec = 'guard', root = store.data.root } end,
        expect = { holds = false, check = function (v) return v.ran == 0, 'ran ' .. tostring(v.ran) end },
    },
}

return setmetatable(M.entry, { __index = M })
