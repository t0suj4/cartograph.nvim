-- one FRESH-PROCESS timing: lower the M.match closure (compile_match's path) and the derivation programs
-- -> `TL match <ms> ms  derivations(<n>) <ms> ms` (an `ab` instrument of tools/experiments/mix-battery.lua).
-- rep=N (the WARM condition, CART-1541): the derivations are lowered N times in this one process, and
-- `warm <ms> ms` = the median of passes 2..N — the cost a long-running process pays once the JIT has its traces;
-- the first pass is the cold number above
return { measure = function (_, params)
    local MA, MX = require 'cartograph.mixalg', require 'cartograph.mix'
    local R = require 'cartograph.algebraread'
    local A = require('cartograph.algebra').load()
    local D = require 'cartograph.algebra.derive'
    D.apply_to(A, '')
    local progs = {}
    local text, _, lines = MA.program('M.match')
    progs[1] = { R.read(text, 'lua'), lines }
    for _, op in ipairs(D.OPERATORS) do
        local okp, t2, _, l2 = pcall(MA.program, 'derive.lua::D.' .. op, nil, { snapshot = true })
        if okp then progs[#progs + 1] = { R.read(t2, 'lua'), l2 } end
    end
    MX.lower(progs[1][1], { lines = progs[1][2] }) -- (warm: modules and the JIT)
    local t0 = vim.uv.hrtime()
    MX.lower(progs[1][1], { lines = progs[1][2] })
    local t1 = vim.uv.hrtime()
    for i = 2, #progs do pcall(MX.lower, progs[i][1], { lines = progs[i][2] }) end
    local t2 = vim.uv.hrtime()
    io.write(('TL match %.1f ms  derivations(%d) %.1f ms\n'):format((t1 - t0) / 1e6, #progs - 1, (t2 - t1) / 1e6))
    local rep = tonumber(params and params.rep) or 1
    if rep > 1 then
        local runs = {}
        for _ = 2, rep do
            local a = vim.uv.hrtime()
            for i = 2, #progs do pcall(MX.lower, progs[i][1], { lines = progs[i][2] }) end
            runs[#runs + 1] = (vim.uv.hrtime() - a) / 1e6
        end
        io.write(('TL warm %.1f ms (median of %d passes after the first)\n'):format(require('cartograph.experiment').median(runs), #runs))
    end
    return {}
end }
