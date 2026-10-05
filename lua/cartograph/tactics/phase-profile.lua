-- PHASE-PROFILE (discovery, CART-1444): where a workload's time goes, by NAMED function — each target (`module.fn,…`)
-- wrapped for one run of `workload` (Lua returning `function (store)`; `@file`): calls and INCLUSIVE seconds, and the
-- share of the run. The split that sized a save (refresh's 5.2 s: splice 2.0 / relink 1.45 / ingest 1.74, CART-1439)
-- as a tactic instead of a throwaway. ⚠ inclusive: a target that calls another counts it too; ⚠ only calls through the
-- module field (cartograph.workload).
-- CLAIM: every target was reached (a zero says the wrapper missed it, not that it is free).
local W = require 'cartograph.workload'

local function measure(store, p)
    local targets = W.list(p.targets)
    if #targets == 0 then return { error = 'targets = module.fn[,…] names nothing' } end
    local work, why = W.load(p.workload)
    if not work then return { error = why } end
    local rows = {}
    local t0 = vim.uv.hrtime()
    local ok, okr, rerr = W.run_wrapped(store, work, targets, function (real, t)
        local row = { name = t, calls = 0, ns = 0 }
        rows[#rows + 1] = row
        return function (...)
            row.calls = row.calls + 1
            local s = vim.uv.hrtime()
            local r = { real(...) }
            row.ns = row.ns + (vim.uv.hrtime() - s)
            return unpack(r)
        end
    end)
    local total = (vim.uv.hrtime() - t0) / 1e9
    if not ok then return { error = okr } end
    if not okr then return { error = 'the workload raised: ' .. tostring(rerr) } end
    local out = {}
    for _, r in ipairs(rows) do out[#out + 1] = { name = r.name, calls = r.calls, seconds = r.ns / 1e9, share = r.ns / 1e9 / math.max(total, 1e-9) } end
    table.sort(out, function (a, b) if a.seconds ~= b.seconds then return a.seconds > b.seconds end return a.name < b.name end)
    return { rows = out, total = total }
end

local E = {
    name = 'phase-profile',
    kind = 'discovery',
    tags = { 'find', 'code', 'optimize' },
    measures = 'CART-1444',
    summary = 'where a workload\'s time goes by named function: targets = module.fn[,…] wrapped for one run of `workload` (Lua returning function (store); @file) — calls, inclusive seconds, share of the run',
    params = { targets = 'string', workload = 'string' },
    measure = measure,
    claim = function (v)
        if v.error then return false, v.error end
        for _, r in ipairs(v.rows) do if r.calls == 0 then return false, r.name .. ' was never called through its module field' end end
        local top = v.rows[1]
        return true, ('%s: %.3f s of %.3f s (%.0f%%) over %d calls'):format(top.name, top.seconds, v.total, top.share * 100, top.calls)
    end,
}

local FILES = { ['pprof.lua'] = 'local M = {}\nfunction M.slow() local s = 0 for i = 1, 300000 do s = s + i end return s end\nfunction M.quick() return 1 end\nfunction M.run() for _ = 1, 3 do M.slow(); M.quick() end end\nreturn M\n' }
E.examples = {
    {
        name = 'two phases timed by name: the slow one leads, each with its calls',
        files = FILES, params = function () return { targets = 'pprof.slow,pprof.quick', workload = 'return function () require("pprof").run() end' } end,
        expect = { holds = true, check = function (v)
            -- (and RESTORED after the run: the module's functions are its own again — cartograph.workload's promise)
            local src = debug.getinfo(require('pprof').slow, 'S').short_src
            return v.rows and v.rows[1].name == 'pprof.slow' and v.rows[1].calls == 3 and v.rows[2].calls == 3 and src:find('pprof%.lua$') ~= nil,
                vim.inspect(v) .. ' ' .. src
        end },
    },
}

return E