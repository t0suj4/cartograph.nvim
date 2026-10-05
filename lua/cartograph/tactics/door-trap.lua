-- DOOR-TRAP (discovery, CART-1444): does a workload open any DOOR — a write, a delete, a process — in one run? Every
-- door of the host is wrapped while `workload` (Lua returning `function (store)`; `@file`) runs: io.open for writing,
-- os.remove / rename / execute, io.popen, vim.fn.system / systemlist / jobstart / writefile / delete / mkdir,
-- vim.uv.spawn / fs_unlink / fs_rename / fs_mkdir / fs_open for writing. Each opening is recorded with what it opened
-- and its CALLER (file:line). The user's rule for measuring: a measurement must not be destructive — this is its gate
-- (memo/trap.lua found 0 doors in the clone workload). ⚠ A door opened by a child process, or through FFI, is not seen.
-- CLAIM: the workload is CLOSED — it opened no door.
local W = require 'cartograph.workload'

local function writes_mode(m) return type(m) == 'string' and m:find('[wa+]') ~= nil end
local function writes_flags(f)
    if type(f) == 'string' then return f:find('[wa+]') ~= nil end
    if type(f) == 'number' then return f % 4 ~= 0 end -- (O_WRONLY / O_RDWR)
    return false
end

local function measure(store, p)
    local work, why = W.load(p.workload)
    if not work then return { error = why } end
    local doors = {}
    local function record(kind, what)
        local info = debug.getinfo(3, 'Sl')
        doors[#doors + 1] = { kind = kind, what = tostring(what):sub(1, 160), at = (info and info.short_src or '?') .. ':' .. tostring(info and info.currentline or '?') }
    end
    local wrapped = {
        { io, 'open', function (real) return function (path, mode, ...) if writes_mode(mode) then record('write', path) end return real(path, mode, ...) end end },
        { io, 'popen', function (real) return function (cmd, ...) record('process', cmd); return real(cmd, ...) end end },
        { os, 'remove', function (real) return function (path, ...) record('delete', path); return real(path, ...) end end },
        { os, 'rename', function (real) return function (a, b, ...) record('rename', tostring(a) .. ' -> ' .. tostring(b)); return real(a, b, ...) end end },
        { os, 'execute', function (real) return function (cmd, ...) record('process', cmd); return real(cmd, ...) end end },
        { vim.uv, 'spawn', function (real) return function (cmd, ...) record('process', cmd); return real(cmd, ...) end end },
        { vim.uv, 'fs_unlink', function (real) return function (path, ...) record('delete', path); return real(path, ...) end end },
        { vim.uv, 'fs_rename', function (real) return function (a, b, ...) record('rename', tostring(a) .. ' -> ' .. tostring(b)); return real(a, b, ...) end end },
        { vim.uv, 'fs_mkdir', function (real) return function (path, ...) record('mkdir', path); return real(path, ...) end end },
        { vim.uv, 'fs_open', function (real) return function (path, flags, ...) if writes_flags(flags) then record('write', path) end return real(path, flags, ...) end end },
    }
    for _, fname in ipairs({ 'system', 'systemlist', 'jobstart', 'writefile', 'delete', 'mkdir' }) do
        local kind = ({ system = 'process', systemlist = 'process', jobstart = 'process', writefile = 'write', delete = 'delete', mkdir = 'mkdir' })[fname]
        wrapped[#wrapped + 1] = { vim.fn, fname, function (real) return function (a, ...) record(kind, type(a) == 'table' and table.concat(vim.tbl_map(tostring, a), ' ') or a); return real(a, ...) end end, raw = true }
    end
    local saved = {}
    for i, w in ipairs(wrapped) do
        local t, k = w[1], w[2]
        saved[i] = w.raw and rawget(t, k) or t[k]
        local real = t[k]
        if type(real) == 'function' then rawset(t, k, w[3](real)) end
    end
    local okr, rerr = pcall(work, store)
    for i, w in ipairs(wrapped) do rawset(w[1], w[2], saved[i]) end -- (vim.fn's: the raw field removed, its __index serves again)
    if not okr then return { error = 'the workload raised: ' .. tostring(rerr), doors = doors } end
    return { doors = doors }
end

local E = {
    name = 'door-trap',
    kind = 'discovery',
    tags = { 'gate', 'code', 'optimize' },
    measures = 'CART-1444',
    summary = 'does a workload open any DOOR (a write, a delete, a process) in one run: the host\'s doors wrapped while `workload` (Lua returning function (store); @file) runs — each opening with what it opened and its caller. The gate for "a measurement must not be destructive"',
    params = { workload = 'string' },
    measure = measure,
    claim = function (v)
        if v.error then return false, v.error end
        if #v.doors == 0 then return true, 'CLOSED: the workload opened no door' end
        local d = v.doors[1]
        return false, ('%d door(s) opened; the first a %s of %s at %s'):format(#v.doors, d.kind, d.what, d.at)
    end,
}

E.examples = {
    {
        name = 'a pure computation is CLOSED',
        files = { ['a.lua'] = 'return 1\n' }, params = function () return { workload = 'return function () local s = 0 for i = 1, 10 do s = s + i end; local f = io.open(vim.fn.tempname(), "r") end' } end,
        expect = { holds = true, check = function (v) return #v.doors == 0, vim.inspect(v.doors) end },
    },
    {
        name = 'a write, a delete and a process are each caught with their caller — and vim.fn serves again after',
        files = { ['a.lua'] = 'return 1\n' }, params = function () return { workload = table.concat({
            'return function ()',
            '  local p = vim.fn.tempname()',
            '  local f = io.open(p, "w"); f:write("x"); f:close()',
            '  os.remove(p)',
            '  vim.fn.system({ "true" })',
            'end' }, '\n') } end,
        expect = { holds = false, check = function (v)
            local kinds = {}
            for _, d in ipairs(v.doors or {}) do kinds[#kinds + 1] = d.kind end
            -- (vim.fn caches a function as a raw field on first use: restored means it is no longer the TRAP's wrapper)
            local src = debug.getinfo(vim.fn.system, 'S').short_src
            return table.concat(kinds, ',') == 'write,delete,process' and not src:find('door%-trap'), vim.inspect(v.doors) .. ' ' .. src
        end },
    },
}

return E