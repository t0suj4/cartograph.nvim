-- DOOR-TRAP (discovery, CART-1444): does a workload open any DOOR — a write, a delete, a process — in one run? Every
-- door of the host is wrapped while `workload` (Lua returning `function (store)`; `@file`) runs: io.open for writing,
-- os.remove / rename / execute, io.popen, vim.fn.system / systemlist / jobstart / writefile / delete / mkdir,
-- vim.uv.spawn / fs_unlink / fs_rename / fs_mkdir / fs_open for writing. Each opening is recorded with what it opened
-- and its CALLER (file:line). The user's rule for measuring: a measurement must not be destructive — this is its gate
-- (memo/trap.lua found 0 doors in the clone workload). ⚠ A door opened by a child process, or through FFI, is not seen.
-- The wrapper is cartograph.doors (CART-1915), shared with the read-only host's trap and the toolbelt's `executes` fence.
-- CLAIM: the workload is CLOSED — it opened no door.
local W = require 'cartograph.workload'
local doors = require 'cartograph.doors'

local KINDS = { write = true, delete = true, rename = true, mkdir = true, process = true }

local function measure(store, p)
    local work, why = W.load(p.workload)
    if not work then return { error = why } end
    local okr, opened, rerr = doors.watch(KINDS, 'record', work, store)
    if not okr then return { error = 'the workload raised: ' .. tostring(rerr), doors = opened } end
    return { doors = opened }
end

local E = {
    name = 'door-trap',
    kind = 'discovery',
    executes = { 'lua', 'process' }, -- CART-1915: pinned by the toolbelt fence
    tags = { 'gate', 'code', 'optimize' },
    measures = 'CART-1444',
    summary = 'does a workload open any DOOR (a write, a delete, a process) in one run: the host\'s doors wrapped while `workload` (Lua returning function (store); @file) runs — each opening with what it opened and its caller. The gate for "a measurement must not be destructive"',
    params = { workload = 'string', code = 'string?', timeout = 'string?' },
    measure = W.code_aware('door-trap', measure),
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
            -- (vim.fn caches a function as a raw field on first use: restored means no wrapper of a FINISHED watch is
            -- left in place — an enclosing watch's own wrapper, the toolbelt audit's, is still rightly there)
            local left = require('cartograph.doors').stale(rawget(vim.fn, 'system'))
            return table.concat(kinds, ',') == 'write,delete,process' and not left, vim.inspect(v.doors) .. (left and ' (a wrapper was left in vim.fn)' or '')
        end },
    },
}

return E