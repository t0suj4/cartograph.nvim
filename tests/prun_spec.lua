-- THE PARALLEL RUNNER (tests/prun.lua) over a FIXTURE suite: its own tests/run.lua (the real one, copied) and specs
-- written here. The oracle is the serial runner's contract: one summary line, the sums of the workers' counts; a
-- worker that prints no summary (a load error) FAILS the run by name, never reads as a pass.
local REPO = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')

local function fixture(specs)
    local root = vim.fn.tempname()
    vim.fn.mkdir(root .. '/tests', 'p')
    vim.fn.writefile(vim.fn.readfile(REPO .. '/tests/run.lua'), root .. '/tests/run.lua')
    for name, body in pairs(specs) do
        local fd = assert(io.open(root .. '/tests/' .. name .. '.lua', 'w')); fd:write(body); fd:close()
    end
    return root
end
local function prun(root, jobs)
    local r = vim.system({ 'nvim', '--headless', '-u', 'NONE', '--noplugin', '-l', REPO .. '/tests/prun.lua' },
        { cwd = root, text = true, env = { JOBS = tostring(jobs), SPEC = '', TEST_TIMES_CACHE = root .. '/times-cache.tsv' } }):wait(120000)
    return r.code, (r.stdout or ''), (r.stderr or '')
end

test('prun: the workers\' counts SUM into ONE summary line, on stderr like the serial runner, and the next run is balanced by measured time', function ()
    local root = fixture {
        a_spec = "test('a1', function () end)\ntest('a2', function () end)\n",
        b_spec = "test('b1', function () end)\ntest('b2', function () skip 'not here' end)\n",
        c_spec = "test('c1', function () end)\n",
    }
    local code, out, err = prun(root, 2)
    eq(0, code, err)
    eq('', out, 'nothing on stdout: the serial runner writes to stderr, and so does this')
    local sums = {}
    for line in err:gmatch('[^\n]+') do if line:match('^%d+ passed, %d+ failed, %d+ skipped') then sums[#sums + 1] = line end end
    eq({ '4 passed, 0 failed, 1 skipped' }, sums, 'one summary line — the workers\' own are not re-emitted')
    ok(err:find('parallel: 2 worker(s)', 1, true), err)
    local cache = table.concat(vim.fn.readfile(root .. '/times-cache.tsv'), '\n')
    ok(cache:find('a_spec\t', 1, true) and cache:find('c_spec\t', 1, true), 'the measured cost is kept for the next balance: ' .. cache)
end)

test('prun: a worker that prints NO summary (a load error) fails the run BY NAME — and a failing test fails it too', function ()
    local root = fixture {
        a_spec = "test('a1', function () end)\n",
        b_spec = "error('boom at load')\n",
    }
    local code, _, err = prun(root, 2)
    eq(1, code, err)
    ok(err:find('LOAD ERROR', 1, true) and err:find('BROKEN WORKER', 1, true) and err:find('b_spec', 1, true), err)
    local root2 = fixture { a_spec = "test('a1', function () end)\n", b_spec = "test('b1', function () error('no') end)\n" }
    local code2, _, err2 = prun(root2, 2)
    eq(1, code2); ok(err2:find('1 passed, 1 failed, 0 skipped', 1, true), err2)
end)
