-- HOT-CALLERS (discovery, CART-1444): WHO calls a function during a workload — `target` = module.fn wrapped for one run of
-- `workload` (Lua returning `function (store)`; `@file`): per CALLER SITE (file:line, function name) the calls and
-- their inclusive seconds. The question that found CART-1440: 60,613 df.stmts calls, all from one closure (hasdf).
-- ⚠ only calls through the module field (cartograph.workload).
-- CLAIM: the target was called.
local W = require 'cartograph.workload'

local function measure(store, p)
    local work, why = W.load(p.workload)
    if not work then return { error = why } end
    local by, calls = {}, 0
    local ok, okr, rerr = W.run_wrapped(store, work, { p.target }, function (real)
        return function (...)
            calls = calls + 1
            local info = debug.getinfo(2, 'Sln')
            local k = (info and info.short_src or '?') .. ':' .. tostring(info and info.currentline or '?') .. ' ' .. tostring(info and info.name or '?')
            local row = by[k]
            if not row then row = { caller = k, calls = 0, ns = 0 }; by[k] = row end
            local s = vim.uv.hrtime()
            local r = { real(...) }
            row.calls, row.ns = row.calls + 1, row.ns + (vim.uv.hrtime() - s)
            return unpack(r)
        end
    end)
    if not ok then return { error = okr } end
    if not okr then return { error = 'the workload raised: ' .. tostring(rerr) } end
    local out = {}
    for _, r in pairs(by) do out[#out + 1] = { caller = r.caller, calls = r.calls, seconds = r.ns / 1e9 } end
    table.sort(out, function (a, b) if a.calls ~= b.calls then return a.calls > b.calls end return a.caller < b.caller end)
    return { callers = out, calls = calls, target = p.target }
end

local E = {
    name = 'hot-callers',
    kind = 'discovery',
    tags = { 'find', 'code', 'optimize' },
    measures = 'CART-1444',
    summary = 'who calls a function during a workload: target = module.fn wrapped for one run of `workload` (Lua returning function (store); @file) — per caller site (file:line, name) its calls and inclusive seconds',
    params = { target = 'string', workload = 'string' },
    measure = measure,
    claim = function (v)
        if v.error then return false, v.error end
        if v.calls == 0 then return false, v.target .. ' was never called through its module field' end
        local top = v.callers[1]
        return true, ('%s: %d calls from %d site(s); the top %s (%d calls, %.3f s)'):format(v.target, v.calls, #v.callers, top.caller, top.calls, top.seconds)
    end,
}

local FILES = { ['hcall.lua'] = 'local M = {}\nfunction M.leaf(x) return x end\nfunction M.a() for i = 1, 5 do M.leaf(i) end end\nfunction M.b() M.leaf(0) end\nreturn M\n' }
E.examples = {
    {
        name = 'the callers of a function, counted by site: the loop\'s site leads',
        files = FILES, params = function () return { target = 'hcall.leaf', workload = 'return function () local m = require("hcall"); m.a(); m.b() end' } end,
        expect = { holds = true, check = function (v)
            return v.calls == 6 and #v.callers == 2 and v.callers[1].calls == 5 and v.callers[1].caller:find('hcall.lua:3', 1, true) ~= nil, vim.inspect(v)
        end },
    },
}

return E