-- The measurement bench: the bootstrap + timing/memory discipline every
-- scratchpad driver used to re-derive by hand (rtp/package.path setup, hrtime
-- deltas, gc pairs, peak-RSS via /proc). Dev tooling — lives OUTSIDE the
-- plugin runtime, never required from lua/cartograph/.
--
-- Use from a headless driver:
--   local bench = dofile('tools/bench.lua')
--   bench.bootstrap()
--   local data, stats = bench.extract('server')
--   print(bench.fmt(stats))

local M = {}

local REPO = (function ()
    -- resolve the repo root from this file's own path, so drivers work from
    -- any cwd
    local src = debug.getinfo(1, 'S').source:sub(2)
    return src:match('^(.*)/tools/bench%.lua$') or vim.fn.getcwd()
end)()

--- Make the extractor requirable: nvim-treesitter parsers on the rtp + the
--- plugin's lua/ on package.path. Idempotent.
function M.bootstrap()
    if M._booted then return end
    M._booted = true
    vim.opt.runtimepath:prepend(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
    package.path = REPO .. '/lua/?.lua;' .. REPO .. '/lua/?/init.lua;' .. package.path
end

--- Resolve a corpus by name (tools/corpora.lua) or accept a literal root.
--- Errors loudly on an unknown name or a missing directory — the "~/work vs
--- ~/git" class of mistake dies here, not 55s into an extract of nothing.
function M.corpus(name_or_root)
    local reg = dofile(REPO .. '/tools/corpora.lua')
    local c = reg[name_or_root]
        or (vim.fn.isdirectory(name_or_root) == 1 and { root = name_or_root, notes = 'ad-hoc root' })
    if not c then
        local names = {}
        for k in pairs(reg) do names[#names + 1] = k end
        table.sort(names)
        error(('bench: unknown corpus %q (have: %s; or pass a directory)')
            :format(name_or_root, table.concat(names, ', ')))
    end
    if vim.fn.isdirectory(c.root) ~= 1 then
        error(('bench: corpus root missing: %s'):format(c.root))
    end
    c.name = reg[name_or_root] and name_or_root or c.root
    -- the corpus's ACTUAL identity right now (git works from a subdir root,
    -- e.g. server/src/main/java inside the elasticsearch repo); nil = not git
    local rev = vim.fn.systemlist({ 'git', '-C', c.root, 'rev-parse', '--short=12', 'HEAD' })
    if vim.v.shell_error == 0 and rev[1] then
        c.git = {
            rev = rev[1],
            url = vim.fn.systemlist({ 'git', '-C', c.root, 'remote', 'get-url', 'origin' })[1],
            dirty = #vim.fn.systemlist({ 'git', '-C', c.root, 'status', '--porcelain' }) > 0,
        }
    end
    return c
end

-- do two revs name the same commit (either may be a short form)?
function M.same_rev(a, b)
    if not a or not b then return false end
    return a:sub(1, #b) == b or b:sub(1, #a) == a
end

-- peak RSS (VmHWM) from /proc; reset via clear_refs("5") so a measurement
-- window sees ITS peak, not the process's lifetime high-water mark
local function vmhwm()
    local fd = io.open('/proc/self/status', 'r')
    if not fd then return nil end
    local txt = fd:read('a'); fd:close()
    local kb = txt:match('VmHWM:%s*(%d+)%s*kB')
    return kb and tonumber(kb) * 1024 or nil
end
function M.peak_reset()
    local fd = io.open('/proc/self/clear_refs', 'w')
    if not fd then return false end
    local ok = fd:write('5') ~= nil
    fd:close()
    return ok
end

--- Run f once inside a measurement window: full gc before, timed, peak RSS
--- over the window (when /proc allows the reset), lua-heap delta.
function M.measure(f, ...)
    collectgarbage(); collectgarbage()
    local heap0 = collectgarbage('count') * 1024
    local resettable = M.peak_reset()
    local t0 = vim.uv.hrtime()
    local res = { f(...) }
    local wall = (vim.uv.hrtime() - t0) / 1e9
    local stats = {
        wall = wall,
        peak = vmhwm(),
        peak_is_window = resettable, -- else: process-lifetime HWM, take as bound
        heap_delta = collectgarbage('count') * 1024 - heap0,
    }
    return res[1], stats, res
end

--- Timing discipline for perf configs: run f n times (default 3), report the
--- MEDIAN wall (plus min/max spread) — one number, reproducible, no cherry-pick.
function M.median(f, n, ...)
    n = n or 3
    local walls, last = {}, nil
    for _ = 1, n do
        local res, s = M.measure(f, ...)
        walls[#walls + 1] = s.wall
        last = res
    end
    table.sort(walls)
    return last, { median = walls[math.ceil(#walls / 2)],
        min = walls[1], max = walls[#walls], runs = n }
end

--- The common case: bootstrapped, measured extract of a corpus.
function M.extract(name_or_root, opts)
    M.bootstrap()
    local c = M.corpus(name_or_root)
    local ts = require 'cartograph.providers.treesitter'
    local data, stats = M.measure(function () return ts.extract(c.root, opts) end)
    stats.corpus = c
    return data, stats
end

--- The parallel pipeline, measured end to end (workers -> merge -> audit ->
--- relink -> phase-2 id pass). Wall includes worker spawns; peak is the
--- PARENT process only (workers peak in their own processes — that IS the
--- streaming pipeline's point).
function M.extract_parallel(name_or_root, opts)
    M.bootstrap()
    local c = M.corpus(name_or_root)
    local par = require 'cartograph.parallel'
    local data, stats = M.measure(function ()
        local done
        par.extract(c.root, {
            workers = opts and opts.workers,
            on_done = function (d) done = d end,
        })
        vim.wait(1800000, function () return done ~= nil end, 50)
        return assert(done, 'parallel extract timed out')
    end)
    stats.corpus = c
    stats.parallel = true
    return data, stats
end

function M.fmt(stats)
    local peak = stats.peak
        and ((' peak %.2f GB%s'):format(stats.peak / 1e9,
            stats.peak_is_window and '' or ' (lifetime bound)'))
        or ''
    return ('%s: %.1fs%s heap +%.0f MB'):format(
        stats.corpus and stats.corpus.name or 'run',
        stats.wall, peak, stats.heap_delta / 1e6)
end

return M
