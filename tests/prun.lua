-- tests/prun.lua — THE SUITE, IN PARALLEL: the spec files split across N worker processes, each the ordinary serial
-- runner (tests/run.lua) over its share. Run by tests/run.sh BY DEFAULT:
--
--   bash tests/run.sh                 workers derived: min(cores, total / slowest spec)
--   JOBS=8 bash tests/run.sh          exactly 8 (SPEC=a_spec,b_spec narrows as always; JOBS=1 = the serial runner)
--
-- ★ THE UNIT IS A SPEC FILE, never a test: tests inside one spec share its fixtures and module state, so a spec runs
-- whole, in one process, in its own order — exactly as the serial runner runs it.
-- ★ EACH WORKER HAS ITS OWN STATE HOME (XDG_STATE_HOME), for the reason run.sh gives one to the whole suite: journals,
-- working sets and remembered decisions are per-root user records, and two workers must not share one.
-- ★ BALANCED BY MEASURED TIME, not a list: every parallel run records each test's time (TIMES) and keeps the per-spec
-- totals in the cache (stdpath('cache')/cartograph/test-times.tsv); the next run packs specs longest-first onto the
-- least-loaded worker (LPT). A spec with no recorded time is costed at the median.
-- ★ THE SUMMARY LINE IS THE SERIAL ONE (`N passed, N failed, N skipped`): the fences and the pre-commit hook read it.
-- A worker that does not print it (a crash, a load error, a hang past the timeout) FAILS the run by name — a silent
-- worker must never read as a pass.
local cwd = vim.fn.getcwd()
-- ★ EVERYTHING GOES TO STDERR, as the serial runner's output does (`print` under `-c luafile` writes there): a consumer
-- that captures one stream must read the same text either way (MEASURED: stdout here, stderr there, on the first run)
local function out(...) io.stderr:write(...) end
local timeout_ms = (tonumber(vim.env.JOB_TIMEOUT or '') or 900) * 1000
-- TEST_TIMES_CACHE: a test of this runner points it elsewhere (a fixture's spec names must not land in the real one)
local cache = (vim.env.TEST_TIMES_CACHE and vim.env.TEST_TIMES_CACHE ~= '') and vim.env.TEST_TIMES_CACHE
    or (vim.fn.stdpath('cache') .. '/cartograph/test-times.tsv')

-- the specs, narrowed by SPEC exactly as run.lua narrows them
local only
if vim.env.SPEC and vim.env.SPEC ~= '' then
    only = {}
    for s in vim.env.SPEC:gmatch('[^,%s]+') do only[s] = true end
end
local specs = {}
for _, f in ipairs(vim.fn.glob('tests/*_spec.lua', false, true)) do
    local name = f:match('([^/]+)%.lua$')
    if not only or only[name] then specs[#specs + 1] = name end
end

-- the measured cost per spec
local cost = {}
local fd = io.open(cache)
if fd then
    for line in fd:lines() do
        local s, ms = line:match('^([^\t]+)\t([%d.]+)$')
        if s then cost[s] = tonumber(ms) end
    end
    fd:close()
end
local known = {}
for _, s in ipairs(specs) do if cost[s] then known[#known + 1] = cost[s] end end
table.sort(known)
local median = known[math.max(1, math.floor(#known / 2))] or 100
table.sort(specs, function (a, b)
    local ca, cb = cost[a] or median, cost[b] or median
    if ca ~= cb then return ca > cb end
    return a < b
end)
-- ★ HOW MANY WORKERS, DERIVED (JOBS unset or `auto`): past total / slowest-spec, another worker cannot shorten the
-- run — the slowest spec is its floor (MEASURED 2026-09-29: 12.4 / 12.2 / 12.0 s at 8 / 12 / 16 workers, the slowest
-- spec 12 s) — and never more than the machine's cores
local total, slowest = 0, 0
for _, s in ipairs(specs) do local c = cost[s] or median; total = total + c; if c > slowest then slowest = c end end
local jobs = tonumber(vim.env.JOBS or '')
if not jobs then
    jobs = math.min(#(vim.uv.cpu_info() or {}) > 0 and #vim.uv.cpu_info() or 4, math.ceil(total / math.max(slowest, 1)))
end
jobs = math.max(1, math.min(jobs, #specs))
local bins = {}
for i = 1, jobs do bins[i] = { specs = {}, load = 0 } end
for _, s in ipairs(specs) do
    local best = bins[1]
    for i = 2, jobs do if bins[i].load < best.load then best = bins[i] end end
    best.specs[#best.specs + 1] = s
    best.load = best.load + (cost[s] or median)
end

-- run the workers
local t0 = vim.uv.hrtime()
local procs = {}
for i, b in ipairs(bins) do
    local state = vim.fn.tempname() .. '-state'
    vim.fn.mkdir(state, 'p')
    local times = vim.fn.tempname() .. '-times.tsv'
    b.state, b.times = state, times
    b.proc = vim.system({ 'nvim', '--headless', '-u', 'NONE', '--noplugin', '-c', 'set rtp+=' .. cwd, '-c', 'luafile tests/run.lua' },
        { cwd = cwd, text = true, env = { SPEC = table.concat(b.specs, ','), XDG_STATE_HOME = state, TIMES = times, TIMES_QUIET = '1' } })
    procs[i] = b
end
local pass, fail, skipped, pending, broken = 0, 0, 0, 0, {}
local rows = {}
for i, b in ipairs(procs) do
    local r = b.proc:wait(timeout_ms)
    local text = (r.stdout or '') .. (r.stderr or '')
    -- a worker's own summary line is NOT re-emitted: the run has one summary, the combined one (a reader taking the
    -- first match would read a share as the whole)
    out((text:gsub('\n%d+ passed, %d+ failed, %d+ skipped[^\n]*\n', '\n')))
    local p, f, s, rest = text:match('(%d+) passed, (%d+) failed, (%d+) skipped([^\n]*)\n%s*$')
    if not p then
        broken[#broken + 1] = ('worker %d (%s) printed no summary (exit %s%s)'):format(i, table.concat(b.specs, ','),
            tostring(r.code), r.signal and r.signal ~= 0 and (', signal ' .. r.signal) or '')
    else
        pass, fail, skipped = pass + tonumber(p), fail + tonumber(f), skipped + tonumber(s)
        pending = pending + (tonumber(rest:match('(%d+) PENDING') or '0') or 0)
        if r.code ~= 0 and tonumber(f) == 0 then broken[#broken + 1] = ('worker %d exited %s with 0 failures'):format(i, tostring(r.code)) end
    end
    local tf = io.open(b.times)
    if tf then for line in tf:lines() do rows[#rows + 1] = line end; tf:close() end
    vim.fn.delete(b.state, 'rf'); os.remove(b.times)
end

-- the measured cost, for the next run's balance (and TIMES, when asked)
local per = {}
for _, line in ipairs(rows) do
    local ms, s = line:match('^([%d.]+)\t([^\t]+)\t')
    if ms then per[s] = (per[s] or 0) + tonumber(ms) end
end
for s, ms in pairs(per) do cost[s] = ms end
vim.fn.mkdir(vim.fn.fnamemodify(cache, ':h'), 'p')
local names = {}
for s in pairs(cost) do names[#names + 1] = s end
table.sort(names)
local cf = io.open(cache, 'w')
if cf then for _, s in ipairs(names) do cf:write(('%s\t%.1f\n'):format(s, cost[s])) end; cf:close() end
if vim.env.TIMES and vim.env.TIMES ~= '' then
    local tf = io.open(vim.env.TIMES, 'w')
    if tf then tf:write(table.concat(rows, '\n'), '\n'); tf:close() end
end
local wall = (vim.uv.hrtime() - t0) / 1e9
local loads = {}
for i, b in ipairs(procs) do loads[i] = ('%.0f'):format(b.load / 1e3) end
out(('\nparallel: %d worker(s), %.0f s wall; planned load per worker (s): %s\n'):format(#procs, wall, table.concat(loads, ' ')))
for _, why in ipairs(broken) do out('BROKEN WORKER — ', why, '\n') end
out(('\n%d passed, %d failed, %d skipped%s\n'):format(pass, fail, skipped,
    pending > 0 and (', %d PENDING REVIEW'):format(pending) or ''))
if fail > 0 or #broken > 0 then vim.cmd('cquit 1') else vim.cmd('qall!') end
