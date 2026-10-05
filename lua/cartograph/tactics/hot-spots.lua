-- HOT-SPOTS (discovery, CART-1444): where a workload's time goes, UNHINTED — LuaJIT's sampling profiler (jit.profile,
-- 1 ms) over one run of `workload` (Lua returning `function (store)`; `@file`), each sample's stack attributed to the
-- MODULE FIELD functions that hold its lines: SELF samples (the NEAREST field frame from the top: a local function
-- counts for the field running it) and INCLUSIVE ones (any frame, once per
-- sample). The rung before phase-profile / hot-callers / memo-advisor, which all take NAMED targets: this one names
-- them. A module field is what the other discoveries can wrap, so it is the unit; a line in no field (a local
-- function, a closure) still counts toward the fields above it on the stack, and the hottest such LINES are listed
-- raw (`lines`) — CART-1440's hot closure (hasdf) was a local, its callee (df.stmts) a field.
-- ⚠ SAMPLES, NOT CALLS: a function under 1 ms total may never be seen; JIT-compiled code is sampled as well.
-- ⚠ `code = <dir>` measures that tree's modules in a process of its own (cartograph.workload) — required to profile a
-- checkout of cartograph itself, whose modules are already loaded here.
-- CLAIM: the profiler took samples and some field holds them.
local W = require 'cartograph.workload'

-- every Lua function reachable as a FIELD of a loaded module -> by absolute file: { { name, first, last } }
local function fields()
    local by = {}
    local mods = vim.tbl_keys(package.loaded)
    table.sort(mods)
    local seen = {}
    for _, m in ipairs(mods) do
        local T = package.loaded[m]
        if type(T) == 'table' then
            local ks = {}
            for k, v in pairs(T) do if type(k) == 'string' and type(v) == 'function' then ks[#ks + 1] = k end end
            table.sort(ks)
            for _, k in ipairs(ks) do
                local f = T[k]
                local info = not seen[f] and debug.getinfo(f, 'S')
                seen[f] = true
                if info and info.what == 'Lua' and info.source:sub(1, 1) == '@' then
                    local file = vim.fn.fnamemodify(info.source:sub(2), ':p')
                    by[file] = by[file] or {}
                    table.insert(by[file], { name = m .. '.' .. k, first = info.linedefined, last = info.lastlinedefined, file = file })
                end
            end
        end
    end
    return by
end

-- the INNERMOST field holding file:line, or nil
local function holder(by, file, line)
    local best
    for _, f in ipairs(by[file] or {}) do
        if line >= f.first and line <= f.last and (not best or f.last - f.first < best.last - best.first) then best = f end
    end
    return best
end

local function measure(store, p)
    local work, why = W.load(p.workload)
    if not work then return { error = why } end
    local okp, prof = pcall(require, 'jit.profile')
    if not okp then return { error = 'no jit.profile in this Lua (LuaJIT only)' } end
    local stacks, total = {}, 0
    prof.start('li1', function (th, n)
        local s = prof.dumpstack(th, 'pl;', 64)
        stacks[s] = (stacks[s] or 0) + n
        total = total + n
    end)
    local okr, rerr = pcall(work, store)
    prof.stop()
    if not okr then return { error = 'the workload raised: ' .. tostring(rerr) } end
    local by = fields()
    local root = store and store.data and store.data.root
    local rootp = root and (vim.fn.fnamemodify(root, ':p'):gsub('/+$', '') .. '/')
    local function rel(file) return rootp and file:sub(1, #rootp) == rootp and file:sub(#rootp + 1) or file end
    local self, incl, lines, where = {}, {}, {}, {}
    for s, n in pairs(stacks) do
        local once, top, owned = {}, true, false
        for frame in s:gmatch('[^;]+') do
            local file, line = frame:match('^(.*):(%d+)$')
            if file then
                file = vim.fn.fnamemodify(file, ':p')
                local f = holder(by, file, tonumber(line))
                if top then
                    local k = rel(file) .. ':' .. line
                    lines[k] = { line = k, field = f and f.name or nil, self = ((lines[k] or {}).self or 0) + n }
                    top = false
                end
                -- SELF = the NEAREST field from the top: a local function's or closure's samples are its field's own
                -- time (a local is no wrap target; the field that runs it is), never lost
                if f and not owned then owned = true; self[f.name] = (self[f.name] or 0) + n end
                if f and not once[f.name] then once[f.name] = true; incl[f.name] = (incl[f.name] or 0) + n; where[f.name] = f end
            end
        end
    end
    local rows = {}
    -- (each row says WHERE the field is defined — file relative to the root when inside it, and its first line — so a
    -- write tactic can find the function to rewrite; an absolute file is code outside the world)
    for name, n in pairs(incl) do
        rows[#rows + 1] = { name = name, self = self[name] or 0, inclusive = n, file = rel(where[name].file), line = where[name].first }
    end
    -- ranked by SELF (where the work is done), or by INCLUSIVE (`by = inclusive`: what a memo of the field would save —
    -- a cheap wrapper over the expensive part, CART-1427's expr.of: self 25, inclusive 3,266 samples, the largest)
    local first, second = 'self', 'inclusive'
    if p.by == 'inclusive' then first, second = 'inclusive', 'self' end
    table.sort(rows, function (a, b)
        if a[first] ~= b[first] then return a[first] > b[first] end
        if a[second] ~= b[second] then return a[second] > b[second] end
        return a.name < b.name
    end)
    local top = tonumber(p.top or 25)
    local out = {}
    for i = 1, math.min(#rows, top) do out[i] = rows[i] end
    local ls = vim.tbl_values(lines)
    table.sort(ls, function (a, b) if a.self ~= b.self then return a.self > b.self end return a.line < b.line end)
    local lout = {}
    for i = 1, math.min(#ls, top) do lout[i] = ls[i] end
    return { rows = out, lines = lout, samples = total, by = p.by == 'inclusive' and 'inclusive' or 'self' }
end

local E = {
    name = 'hot-spots',
    kind = 'discovery',
    tags = { 'find', 'code', 'optimize' },
    measures = 'CART-1444',
    summary = 'where a workload\'s time goes, UNHINTED: LuaJIT\'s sampling profiler over one run of `workload` (Lua returning function (store); @file), samples attributed to the module FIELD functions holding them — self and inclusive — plus the hottest raw lines; the targets the named discoveries (phase-profile, hot-callers, memo-advisor) take. code = <dir> profiles that tree\'s modules',
    params = { workload = 'string', top = 'string?', by = 'string?', code = 'string?', timeout = 'string?' },
    measure = W.code_aware('hot-spots', measure),
    claim = function (v)
        if v.error then return false, v.error end
        if v.samples == 0 then return false, 'the profiler took no sample (a workload under 1 ms?)' end
        local r = v.rows[1]
        if not r then return false, ('%d samples, none in a module field'):format(v.samples) end
        if v.by == 'inclusive' then return true, ('%s: %d of %d samples inclusive, %d self'):format(r.name, r.inclusive, v.samples, r.self) end
        return true, ('%s: %d of %d samples self, %d inclusive'):format(r.name, r.self, v.samples, r.inclusive)
    end,
}

local FILES = { ['hspot.lua'] = table.concat({
    'local M = {}',
    'function M.slow(n) local s = 0 for i = 1, n do s = s + i % 7 end return s end',
    'function M.quick() return 1 end',
    'function M.run() local function via() return M.slow(4e7) end local x = via() + M.quick() for i = 1, 1e7 do x = x + i % 3 end return x end',
    'return M', '' }, '\n') }
E.examples = {
    {
        name = 'nothing named: the field holding the hot loop leads by SELF samples, and its caller (through a local closure) by INCLUSIVE ones',
        files = FILES,
        params = function () return { workload = 'return function (store) package.path = store.data.root .. "/?.lua;" .. package.path; require("hspot").run() end' } end,
        expect = { holds = true, check = function (v)
            local by = {}
            for _, r in ipairs(v.rows or {}) do by[r.name] = r end
            return v.rows[1].name == 'hspot.slow' and v.rows[1].file == 'hspot.lua' and v.rows[1].line == 2
                and by['hspot.run'] and by['hspot.run'].inclusive >= by['hspot.slow'].self
                and by['hspot.run'].self < by['hspot.slow'].self, vim.inspect(v.rows)
        end },
    },
    {
        name = 'by = inclusive: the CALLER that holds the hot loop below it leads — what a memo of it would save',
        files = FILES,
        params = function () return { by = 'inclusive', workload = 'return function (store) package.path = store.data.root .. "/?.lua;" .. package.path; require("hspot").run() end' } end,
        expect = { holds = true, check = function (v) return v.rows[1].name == 'hspot.run' and v.by == 'inclusive', vim.inspect(v.rows) end },
    },
}

return E
