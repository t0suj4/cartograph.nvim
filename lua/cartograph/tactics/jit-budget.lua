-- JIT-BUDGET (discovery, CART-1662): what LuaJIT's TRACE BUDGETS cost a workload — the one knob no code rewrite
-- reaches. The workload (Lua returning `function (store)`; `@file`) runs in a FRESH process per configuration (jit.opt is
-- process-wide): `default`, `tune` (maxtrace=4000 maxmcode=8192 — cartograph.jittune's), `big` (maxtrace=20000
-- maxmcode=262144 — cinterp.batch_tune's), `off` (jit.off()); each the best of `reps` runs after one warm run, with the
-- trace-cache FLUSHES counted (jit.attach) and the resident set at the end. The default cache flushing and recompiling
-- every hot loop is a cost no profile names: luacheck 1.2.0 under nvim's LuaJIT ran 4.88 s at 198 flushes and 1.48 s at
-- `big` (0 flushes) — faster than the PUC Lua 5.1 it is installed for (3.35 s); cartograph's own extract + flowtype +
-- lint flushed ~247 times per run before jittune.
-- `code = <dir>` (default: the graph's root): the measured tree's lua/ first on package.path, as hot-spots.
-- ⚠ The fastest configuration is a RECOMMENDATION for a batch process: jit.opt is process-wide, so an editor session or
-- a library must not set it — the caller that owns the process does.
-- CLAIM: every configuration ran, and one is the fastest.
local W = require 'cartograph.workload'

local CONFIGS = {
    { name = 'default' },
    { name = 'tune', opt = { 'maxtrace=4000', 'maxmcode=8192' } },
    { name = 'big', opt = { 'maxtrace=20000', 'maxmcode=262144' } },
    { name = 'off', off = true },
}

-- one configuration, IN THIS PROCESS (a fresh one: the top-level measure runs each through workload.elsewhere)
local function one(store, p)
    local cfg
    for _, c in ipairs(CONFIGS) do if c.name == p.config then cfg = c end end
    if not cfg then return { error = ('config = %s is none of default | tune | big | off'):format(tostring(p.config)) } end
    if cfg.off then jit.off() elseif cfg.opt then jit.opt.start(unpack(cfg.opt)) end
    local work, why = W.load(p.workload)
    if not work then return { error = why } end
    local flushes, traces = 0, 0
    jit.attach(function (what) if what == 'flush' then flushes = flushes + 1 elseif what == 'start' then traces = traces + 1 end end, 'trace')
    local okw, err = pcall(work, store) -- (the warm run: loads the modules, compiles the first traces)
    if not okw then jit.attach(function () end); return { error = 'the workload raised: ' .. tostring(err) } end
    local best = math.huge
    for _ = 1, tonumber(p.reps or 3) do
        collectgarbage()
        local t = vim.uv.hrtime()
        work(store)
        best = math.min(best, (vim.uv.hrtime() - t) / 1e9)
    end
    jit.attach(function () end)
    return { config = cfg.name, secs = best, flushes = flushes, traces = traces, rss_mb = vim.uv.resident_set_memory() / 1048576 }
end

local function measure(store, p)
    if p.config then return one(store, p) end
    local code = p.code or (store and store.data and store.data.root)
    if not code then return { error = 'no code = <dir> and no graph root to run the workload from' } end
    local rows = {}
    for _, c in ipairs(CONFIGS) do
        local q = vim.tbl_extend('force', p, { config = c.name })
        local r = W.elsewhere(code, 'jit-budget', q)
        if r.error then return { error = ('%s: %s'):format(c.name, r.error) } end
        rows[#rows + 1] = r
    end
    local best = rows[1]
    for _, r in ipairs(rows) do if r.secs < best.secs then best = r end end
    return { rows = rows, best = best.config, speedup = rows[1].secs / best.secs }
end

local E = {
    name = 'jit-budget',
    kind = 'discovery',
    tags = { 'code', 'optimize', 'performance' },
    measures = 'CART-1662',
    summary = 'what LuaJIT\'s trace budgets cost a workload: `workload` (Lua returning function (store); @file) in a fresh process per configuration — default | tune (4000 traces / 8 MB) | big (20000 / 256 MB) | off — best of `reps` after a warm run, trace-cache FLUSHES counted, RSS at the end; names the fastest (a batch process\'s choice: jit.opt is process-wide). code = <dir> runs that tree\'s modules',
    params = { workload = 'string', code = 'string?', reps = 'string?', config = 'string?', timeout = 'string?' },
    measure = measure,
    claim = function (v)
        if v.error then return false, v.error end
        local parts = {}
        for _, r in ipairs(v.rows) do parts[#parts + 1] = ('%s %.3f s (%d flushes, %.0f MB)'):format(r.config, r.secs, r.flushes, r.rss_mb) end
        return true, ('fastest: %s, x%.2f the default — %s'):format(v.best, v.speedup, table.concat(parts, '; '))
    end,
}

-- a module whose workload compiles MORE traces than the default cache holds (1000): 1500 distinct functions, each with
-- a hot loop of its own — the default flushes, `big` does not
local FILES = { ['lua/manytraces.lua'] = table.concat({
    'local M, fns = {}, {}',
    'for i = 1, 1500 do fns[i] = load("return function (n) local s = 0 for k = 1, n do s = s + (k * " .. i .. ") % 7 end return s end")() end',
    'function M.run() local s = 0 for _ = 1, 2 do for i = 1, #fns do s = s + fns[i](200) end end return s end',
    'return M', '' }, '\n') }
E.examples = {
    {
        name = 'more hot loops than the default trace cache holds: the default FLUSHES, the big budget does not, and every configuration is timed',
        files = FILES,
        params = function (store) return { workload = 'return function () require("manytraces").run() end', code = store.data.root, reps = '1' } end,
        expect = { status = 'done', check = function (v)
            local by = {}
            for _, r in ipairs(v.rows or {}) do by[r.config] = r end
            return by.default and by.big and by.off and by.tune and by.default.flushes > 0 and by.big.flushes == 0 and by.off.flushes == 0,
                vim.inspect(v.rows)
        end },
    },
}
return E
