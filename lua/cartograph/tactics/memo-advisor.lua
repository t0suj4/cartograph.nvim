-- MEMO-ADVISOR (discovery, CART-1441 / CART-1444): REPEATED WORK ON A REPEATING ARGUMENT, measured in ONE run. Each
-- target function (`targets` = 'module.fn,…') is wrapped for the run of `workload` (Lua source returning
-- `function (store)`; `@file` reads one): calls, DISTINCT argument keys (a table, a function, userdata by IDENTITY; a
-- scalar by value), inclusive time, and what a memo would SAVE — time × (1 − distinct / calls) — and PRICE: the bytes
-- of the distinct results, and whether a result holds userdata (a TSNode pins its tree) or a function.
-- WHY DYNAMIC: CART-1440's case (relink decoded one function's df once per CALL inside it, half of relink) gave the
-- static loopcost no finding — the cost was not loop depth but repetition on a smaller domain than the loop. Purity is
-- the caller's to establish (effects.lua): the advisor says what a memo WOULD save, not that it is sound.
-- ⚠ A wrapper on a module FIELD sees only calls made through the field: a caller that bound `local f = M.f` at load
-- is invisible (harness #47) — zero calls REFUSES by name instead of reading as "no repetition".
-- CLAIM: some target repeats (distinct < calls) and a memo would save time.
local W = require 'cartograph.workload'

local function measure(store, p)
    local targets = W.list(p.targets)
    if #targets == 0 then return { error = 'targets = module.fn[,module.fn…] names nothing' } end
    local work, why = W.load(p.workload)
    if not work then return { error = why } end
    local rows = {}
    local idkey = setmetatable({}, { __mode = 'k' })
    local nid = 0
    local function key_of(v)
        local ty = type(v)
        if ty == 'table' or ty == 'function' or ty == 'userdata' or ty == 'thread' then
            local k = idkey[v]
            if not k then nid = nid + 1; k = '#' .. nid; idkey[v] = k end
            return k
        end
        return ty:sub(1, 1) .. tostring(v)
    end
    local function size(v, seen, row)
        local ty = type(v)
        if ty == 'userdata' then row.userdata = true; return 16 end
        if ty == 'function' then row.functions = true; return 16 end
        if ty == 'string' then return 24 + #v end
        if ty ~= 'table' then return 16 end
        if seen[v] then return 0 end
        seen[v] = true
        local s = 56
        for k, x in pairs(v) do s = s + 16 + size(k, seen, row) + size(x, seen, row) end
        return s
    end
    local t0 = vim.uv.hrtime()
    local ok, okr, rerr = W.run_wrapped(store, work, targets, function (real, t)
        local row = { name = t, calls = 0, distinct = 0, ns = 0, bytes = 0, keys = {} }
        rows[#rows + 1] = row
        return function (...)
            local n = select('#', ...)
            local parts = {}
            for i = 1, n do parts[i] = key_of((select(i, ...))) end
            local k = table.concat(parts, '\31')
            local fresh = not row.keys[k]
            if fresh then row.keys[k] = true; row.distinct = row.distinct + 1 end
            row.calls = row.calls + 1
            local s = vim.uv.hrtime()
            local r = { real(...) }
            row.ns = row.ns + (vim.uv.hrtime() - s)
            if fresh then row.bytes = row.bytes + size(r, {}, row) end
            return unpack(r)
        end
    end)
    local total = (vim.uv.hrtime() - t0) / 1e9
    if not ok then return { error = okr } end
    if not okr then return { error = 'the workload raised: ' .. tostring(rerr) } end
    local out = {}
    for _, r in ipairs(rows) do
        local secs = r.ns / 1e9
        out[#out + 1] = { name = r.name, calls = r.calls, distinct = r.distinct, repeat_ratio = r.calls / math.max(r.distinct, 1),
            seconds = secs, saved = secs * (1 - r.distinct / math.max(r.calls, 1)), result_kb = r.bytes / 1e3,
            userdata = r.userdata or false, functions = r.functions or false }
    end
    table.sort(out, function (a, b) if a.saved ~= b.saved then return a.saved > b.saved end return a.name < b.name end)
    return { rows = out, workload_seconds = total }
end

local E = {
    name = 'memo-advisor',
    kind = 'discovery',
    tags = { 'find', 'code', 'optimize' },
    measures = 'CART-1441',
    summary = 'repeated work on a repeating argument, in ONE run: targets = module.fn[,…] wrapped while `workload` (Lua returning function (store); @file) runs — per target calls, distinct argument keys (tables by identity), time, what a memo would SAVE and its PRICE (bytes; userdata / functions in results). Purity is yours to establish (effects.lua)',
    params = { targets = 'string', workload = 'string' },
    measure = measure,
    claim = function (v)
        if v.error then return false, v.error end
        local best = v.rows[1]
        for _, r in ipairs(v.rows) do
            if r.calls == 0 then return false, ('%s was never called through its module field — a caller holds a local reference (wrap where it is bound)'):format(r.name) end
        end
        if not best or best.saved <= 0 then return false, 'no target repeats an argument' end
        return true, ('%s: %d calls on %d distinct arguments (%.1fx), a memo saves %.3f s of %.3f s (result %.1f KB%s)'):format(
            best.name, best.calls, best.distinct, best.repeat_ratio, best.saved, v.workload_seconds, best.result_kb,
            best.userdata and ', holds userdata' or '')
    end,
}

local FILES = {
    ['madv.lua'] = table.concat({
        'local M = {}',
        'function M.slow(t) local s = 0 for i = 1, 20000 do s = s + #t end return s end',
        'function M.fresh(i) return i * 2 end',
        'function M.work(items) local s = 0 for i, it in ipairs(items) do s = s + M.slow(it.f) + M.fresh(i) end return s end',
        'return M',
    }, '\n') .. '\n',
}
local WORK = 'return function (store) package.path = store.data.root .. "/?.lua;" .. package.path; local m = require "madv"; '
    .. 'local f = { 1, 2, 3 }; local items = {}; for i = 1, 200 do items[i] = { f = f } end; m.work(items) end'

E.examples = {
    {
        name = 'a function called 200 times on ONE table is a memo candidate; one called on 200 distinct values is not',
        files = FILES, params = function () return { targets = 'madv.slow,madv.fresh', workload = WORK } end,
        expect = { holds = true, check = function (v)
            local by = {}
            for _, r in ipairs(v.rows or {}) do by[r.name] = r end
            return by['madv.slow'] and by['madv.slow'].calls == 200 and by['madv.slow'].distinct == 1 and by['madv.slow'].saved > 0
                and by['madv.fresh'] and by['madv.fresh'].distinct == 200 and by['madv.fresh'].saved == 0, vim.inspect(by)
        end },
    },
    {
        name = 'a target never reached through its module field REFUSES by name — never "no repetition"',
        files = FILES, params = function () return { targets = 'madv.fresh', workload = 'return function (store) end' } end,
        expect = { holds = false, check = function (v) return v.rows and v.rows[1] and v.rows[1].calls == 0, vim.inspect(v) end },
    },
}

return E