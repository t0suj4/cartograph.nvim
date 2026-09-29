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
function M.run(root, spec, timeout)
    -- the runner in its OWN process group (setsid): a spec that HANGS (a mutation that makes a loop infinite) is
    -- killed WITH its children on the timeout — killing only bash left each hung `node` spinning at 100% CPU
    -- (measured: three orphans, 20-60 min each, one per re-run of one mutation)
    local proc
    local ok, obj = pcall(function ()
        proc = vim.system({ 'setsid', 'bash', 'tests/run.sh' }, { cwd = root, text = true,
            env = { SPEC = spec, CARTOGRAPH_NVIM = vim.v.progpath } })
        return proc:wait(timeout or 600000)
    end)
    if not ok then return nil, 'the runner did not start: ' .. tostring(obj) end
    if not obj or obj.signal == 15 or obj.signal == 9 then
        -- TIMED OUT (wait returns no result, or the killed one): a hang is a spec that did NOT pass — a failure, named
        if proc and proc.pid then vim.system({ 'kill', '-9', '--', '-' .. proc.pid }):wait() end
        local secs = math.floor((timeout or 600000) / 1000)
        return { passed = 0, failed = 1, skipped = 0, ran = 1, code = 124, timed_out = true,
            summary = ('TIMED OUT after %d s (a hang: the spec did not pass; its process group killed)'):format(secs) }
    end
    local out = (obj.stdout or '') .. '\n' .. (obj.stderr or '')
    local p, f, s
    for a, b, c in out:gmatch('(%d+) passed, (%d+) failed, (%d+) skipped') do p, f, s = tonumber(a), tonumber(b), tonumber(c) end
    if not p then return nil, ('no summary line from %s/tests/run.sh (exit %s)'):format(root, tostring(obj.code)) end
    return { passed = p, failed = f, skipped = s, ran = p + f, code = obj.code,
        summary = ('%d passed, %d failed, %d skipped'):format(p, f, s) }
end

M.entry = {
    name = 'spec-fails',
    kind = 'discovery',
    summary = 'does SPEC fail in a tree? runs `SPEC=<spec> bash tests/run.sh` in root (default: the cartograph repo) and reads the summary line; a run that ran nothing refuses',
    params = { spec = 'string', root = 'string?' },
    measure = function (_, p)
        local v, why = M.run(p.root or repo_of_toolbelt(), p.spec)
        return v or { error = why }
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
        "if f then local ok = pcall(f, function (c) if c then pass = pass + 1 else fail = fail + 1 end end); if not ok then fail = fail + 1 end end",
        "io.write(('%d passed, %d failed, %d skipped\\n'):format(pass, fail, 0))",
    }, '\n') .. '\n',
    ['tests/guard_spec.lua'] = "local check = ...\nlocal g = require('guard')\ncheck(g.positive(1) == true)\ncheck(g.positive(-1) == false)\ncheck(g.positive(0) == false)\ncheck(g.nonempty({}) == false)\n",
    ['tests/weak_spec.lua'] = "local check = ...\nlocal g = require('guard')\ncheck(g.positive(1) == true)\n",
    ['tests/broken_spec.lua'] = "local check = ...\ncheck(1 == 2)\n",
}

M.entry.examples = {
    {
        name = 'a spec with a failing check: the claim holds',
        files = M.FIXTURE,
        params = function (store) return { spec = 'broken_spec', root = store.data.root } end,
        expect = { holds = true },
    },
    {
        name = 'a green spec: the claim fails, and says what ran',
        files = M.FIXTURE,
        params = function (store) return { spec = 'guard_spec', root = store.data.root } end,
        expect = { holds = false, check = function (v) return v.passed == 4 and v.failed == 0, 'guard_spec: ' .. tostring(v.summary) end },
    },
    {
        name = 'a SPEC naming no spec runs nothing: refused, never read as green',
        files = M.FIXTURE,
        params = function (store) return { spec = 'guard', root = store.data.root } end,
        expect = { holds = false, check = function (v) return v.ran == 0, 'ran ' .. tostring(v.ran) end },
    },
}

return setmetatable(M.entry, { __index = M })
