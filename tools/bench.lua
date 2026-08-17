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
    -- the extractor's measured JIT budget (see worker.lua): default trace
    -- limits churn at 15-17% of wall; this is a bench process — tune freely
    pcall(function () require('jit.opt').start('maxtrace=4000', 'maxmcode=8192') end)
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
    -- a SYNTHETIC corpus materializes on demand: deterministic content from
    -- (GEN_VERSION, lang, seed, files) — the root path embeds the identity,
    -- so a stale dir from an older generator is simply never referenced
    if c.synthetic and vim.fn.isdirectory(c.root) ~= 1 then
        dofile(REPO .. '/tools/gen.lua').generate(
            c.synthetic.lang, c.root, c.synthetic.files, c.synthetic.seed)
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

--- Resident MB right now (VmRSS, not the high-water VmHWM) — for STAGED reporting inside
--- a long sweep, where the useful question is WHERE growth happens, not what the total was.
function M.rss_mb()
    local fd = io.open('/proc/self/status', 'r')
    if not fd then return nil end
    local txt = fd:read('a'); fd:close()
    local kb = txt:match('VmRSS:%s*(%d+)%s*kB')
    return kb and (tonumber(kb) / 1024) or nil
end

--- THE SWEEP GC STEP. Call once per item in a whole-corpus per-function walk:
---   for i, id in ipairs(fns) do … bench.sweep_gc(i) end
---
--- MEASURED (desynced, 3021 fns / 36459 rows, identical code three ways):
---   baseline (lua default pause 200%)     plateau 4556 MB   sweep 65.0s
---   collectgarbage('setpause', 110)       plateau 3084 MB   sweep 67.2s  (+3.4%)
---   collectgarbage() every 200 items      plateau 2767 MB   sweep 65.2s  (+0.3%)
--- -39% PEAK FOR +0.3% WALL in that isolated build-only loop. EXPECT LESS IN A REAL
--- TOOL: translit on the same corpus went 3110 -> 2555 MB, i.e. -18%, because its
--- emit+reparse work already provokes collections, so its baseline high-water was never
--- as high. Quote the -18% for a working sweep and the -39% only for a bare build loop.
--- It works because the plateau is GC HIGH-WATER FROM CHURN
--- and not live data: staged RSS climbs ~2.8 GB over the FIRST 500 functions and is then
--- FLAT to the end — the signature of an arena that grew once and is reused, not of
--- accumulation. (Which is also why "the sweep leaks" was the wrong diagnosis: nothing
--- grows after function 500.)
---
--- THE NUMBER THAT MOTIVATES IT: on that corpus the GRAPH costs 290 MB while SWEEPING it
--- costs 3-4.5 GB — an order of magnitude more than the thing being swept. The storage arc
--- ([[cartograph-fold-core]]: sharded CSR, 32.5x fold, extraction peak) all targets the
--- 290 MB; nothing targeted the 10x-larger TRANSIENT that every per-function analysis
--- pays. That transient is why a scale corpus can OOM while its extract fits easily —
--- wow extracts in 130s at 4.1 GB, then an unguarded sweep over it exhausted 11 GB.
function M.sweep_gc(i, every)
    if i % (every or 200) == 0 then collectgarbage() end
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

-- ── the WARM dev loop (CART-0429) ─────────────────────────────────────────────────────
--
-- ★ WHY THE DEFAULT IS COLD AND STAYS COLD. `M.extract` has always gone straight to the
-- provider, never to the cache, and that is CORRECT FOR A GATE: a cache can mask the very
-- bug being gated, and CART-0245 is the proof it has happened — a warm zig graph carried
-- 4122 edges into nodes that were never saved while the `valid` column stayed green,
-- because validate ran on the COLD graph and nothing ran it on the artifact the cache
-- produced. So warm is OPT-IN, gates opt OUT explicitly, and what warm serves is VALIDATED
-- before it is handed back.
--
-- ★ WHAT IT BUYS: measured, a repeat extract of an UNCHANGED corpus costs the same as the
-- first (12.30s -> 11.48s on go — no reuse at all), and zig is 106.8s on EVERY invocation.
-- A dev iterating on an analyzer re-pays that every run.
--
-- TWO WAYS IN, and `cold` beats both: `opts.warm`, else $CARTOGRAPH_BENCH_WARM=1 for a whole
-- shell session. ★ THE ENV VAR IS EXACTLY WHY `opts.cold` EXISTS — a dev who exports it and
-- then runs the matrix must not silently gate on a cached artifact, so THE GATE TOOLS SAY
-- COLD rather than trusting the environment not to say warm. An opt-out that depends on
-- nobody having opted in is not an opt-out.
local WARM_REFUSING = { 'files', 'defs_only', 'dataflow_only', 'index_only', 'subdirs',
    'legacy_df' }

--- May this extract be served from / written to the corpus cache?
--- Returns (true) or (false, reason). The reason is PRINTED, never swallowed: a run that
--- asked for warm and silently went cold is indistinguishable from one where warm did not
--- help, and that is the class of silence this repo keeps paying for.
local function warm_ok(opts)
    local asked
    if opts and opts.warm ~= nil then asked = opts.warm
    else asked = vim.env.CARTOGRAPH_BENCH_WARM == '1' end
    -- ★ SILENT UNLESS A REQUEST WAS DENIED. The matrix passes `cold` on all 31 rows, so
    -- announcing every one would bury the case that matters — a dev who exported the env
    -- var and needs to know THIS run ignored it. Say nothing when nobody asked.
    if opts and opts.cold then
        return false, asked and 'the caller asked for a COLD extract (overriding warm)' or nil
    end
    if not asked then return false end
    -- ★ A NON-CANONICAL EXTRACT MUST NOT TOUCH THE CORPUS CACHE, IN EITHER DIRECTION.
    -- `--file` is the sharp case this ships beside: a scoped extract holds a SUBSET of the
    -- corpus, so WRITING it would poison the cache for every later reader, and READING the
    -- full cache would silently undo the scoping the caller just asked for. Same for the
    -- defs_only / dataflow_only / index_only shapes — a different graph under one key.
    for _, k in ipairs(WARM_REFUSING) do
        if opts and opts[k] ~= nil then
            return false, ('opts.%s makes this a NON-CANONICAL extract'):format(k)
        end
    end
    return true
end

--- The common case: bootstrapped, measured extract of a corpus.
--- `opts.warm` (or $CARTOGRAPH_BENCH_WARM=1) serves an incremental warm open when one is
--- available; `opts.cold` refuses warm outright and wins over both. `stats.warm` records
--- which path ran, so a caller that reports timings can say WHICH NUMBER IT MEASURED.
function M.extract(name_or_root, opts)
    M.bootstrap()
    local c = M.corpus(name_or_root)
    -- provider dispatch: a corpus names its GraphProvider (default
    -- treesitter); any module producing the neutral schema slots in
    local prov = require('cartograph.providers.' .. (c.provider or 'treesitter'))
    -- overlay packs (rails): a corpus declares its framework packs; thread them
    -- into extraction opts so the composed spec is used
    if c.packs then opts = vim.tbl_extend('keep', { packs = c.packs }, opts or {}) end

    local want, why = warm_ok(opts)
    if why then print('bench: COLD — ' .. why) end
    if want then
        local cache = require 'cartograph.cache'
        -- cache.open is the INCREMENTAL open: it validates stamps, re-extracts the files
        -- that changed, drops deleted ones, and returns nil when there is nothing usable.
        -- It also refuses a VERSION mismatch and a profile-overridden graph, so an
        -- extraction-behaviour change invalidates this path for free.
        -- the note comes out through an upvalue, NOT a second return: M.measure returns
        -- (result, stats, all), so `local d, note = M.measure(...)` silently binds `note`
        -- to the STATS table — which is how the first cut printed "WARM — table: 0x…".
        local note
        local data, stats = M.measure(function ()
            local d, n = cache.open(c.root)
            note = n
            return d
        end)
        if data then
            -- ★★ VALIDATE WHAT WARM SERVES (CART-0245). The `valid` column checks the COLD
            -- graph; a warm graph that never meets validate is exactly how 4122 dangling
            -- edges shipped green. Measured cost 0–205 ms (v8 worst, against a 178s
            -- extract), so this is affordable on the path whose whole point is speed.
            local vr = require('cartograph.validate').check(data)
            if vr.ok then
                -- ★ REPORT THE WARM OPEN'S REAL COST, not a fabricated zero. The first cut
                -- measured an empty closure to manufacture a stats table, which would have
                -- had every warm run claim ~0s for work that genuinely reads and decodes
                -- every shard. A timing this path prints must be a timing of this path.
                stats.corpus, stats.warm = c, true
                print(('bench: WARM — %s'):format(note or 'cache open'))
                return data, stats
            end
            -- a bad warm graph is a CACHE bug, not a reason to fail the caller: say so
            -- loudly and fall through to the cold path, which is always correct
            print('bench: WARM GRAPH INVALID, falling back to COLD — '
                .. require('cartograph.validate').report(vr))
        end
    end

    local data, stats = M.measure(function () return prov.extract(c.root, opts) end)
    stats.corpus, stats.warm = c, false
    -- write the cache only for a CANONICAL extract that asked for warm, so the next
    -- iteration is the fast one. A gate never reaches here (it never asked).
    if want then pcall(function () require('cartograph.cache').save(data) end) end
    return data, stats
end

--- The parallel pipeline, measured end to end (workers -> merge -> audit ->
--- relink -> phase-2 id pass). Wall includes worker spawns; peak is the
--- PARENT process only (workers peak in their own processes — that IS the
--- streaming pipeline's point).
function M.extract_parallel(name_or_root, opts)
    M.bootstrap()
    local c = M.corpus(name_or_root)
    -- the worker pipeline is treesitter-only; refuse loudly, not wrongly
    assert(not c.provider or c.provider == 'treesitter',
        ('corpus %s uses provider %q — no parallel pipeline for it')
            :format(c.root, c.provider))
    local par = require 'cartograph.parallel'
    local data, stats = M.measure(function ()
        local done
        par.extract(c.root, {
            workers = opts and opts.workers,
            packs = c.packs, -- overlay packs (rails) — workers apply them too
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
