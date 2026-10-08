-- an INTERROGATOR of compiled code (CART-1554): what reducible work do mix's compiled matchers still carry? Every
-- luajs rule template compiled (compile_match with ASSUME, as cmreg), the residuals loaded as a graph beside a CONTROL
-- file holding one hoistable, one redundant and one re-tested computation, and the shipped optimizers run over every
-- function: optimize.licm / cse and narrow.redundant. A control that is not detected makes the run DEAD, never 0.
-- Then a census of the residual text: field reads, how many repeat an identical `x["k"]` within one function (the
-- candidates an alias-aware certifier could remove, CART-1564), boxed-cell traffic, constructors.
--   nvim --headless -u NONE -l tools/toolbelt.lua run @tools/experiments/instruments/residops.lua -
-- -> `RO optimizers: <licm> hoistable, <cse> redundant, <checks> redundant checks over <fns> functions` and
-- `RO text: …`. FIRST RUN (2026-10-08): 0 / 0 / 0 over 888 functions (control detected); 3298 field reads, 1392 of them
-- repeating an identical chain in their function, 205 field writes, 978 boxed-cell accesses, 1229 constructors.
-- (one statement per LINE: the analyses read flow rows, which are lines)
local CONTROL = table.concat({
    'local function ctl_licm(t, n, a, b)', '    for i = 1, n do', '        local k = a * b', '        t[i] = k + i', '    end',
    '    return t', 'end',
    'local function ctl_cse(a, b)', '    local x = a + b', '    local y = a + b', '    return x * y', 'end',
    'local function ctl_red(x)', '    if x ~= nil then', '        if x ~= nil then return 1 end', '    end', '    return 0', 'end',
    'return { ctl_licm, ctl_cse, ctl_red }' }, '\n')
return { measure = function ()
    local MA = require 'cartograph.mixalg'
    local rules = require 'cartograph.luajs.rules'
    local ASSUME = require('cartograph.compiledverb').ASSUME
    local O, N = require 'cartograph.optimize', require 'cartograph.narrow'
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    local texts = {}
    for i, r in ipairs(rules.all()) do
        local ok, _, text = pcall(MA.compile_match, r.lhs, { assume = ASSUME })
        if ok and text then
            texts[#texts + 1] = text
            local f = assert(io.open(('%s/m%02d.lua'):format(dir, i), 'w')); f:write(text); f:close()
        end
    end
    local f = assert(io.open(dir .. '/zz_control.lua', 'w')); f:write(CONTROL); f:close()
    local store = require 'cartograph.store'
    store.ingest(require('cartograph.providers.treesitter').extract(dir))
    local t = { fns = 0, licm = 0, cse = 0, checks = 0 }
    local ctl = { licm = false, cse = false, checks = false }
    for _, n in ipairs(store.data.nodes) do
        if n.kind == 'function' then
            local is_ctl = n.file == 'zz_control.lua'
            if not is_ctl then t.fns = t.fns + 1 end
            local function add(k, m) if is_ctl then ctl[k] = ctl[k] or m > 0 else t[k] = t[k] + m end end
            local okl, l = pcall(O.licm, store, n.id)
            if okl then
                local m = 0
                for _, h in ipairs(l.heads) do for _ in pairs(l.loops[h].hoistable) do m = m + 1 end end
                add('licm', m)
            end
            local okc, c = pcall(O.cse, store, n.id)
            if okc then add('cse', #(c.redundant or {})) end
            local okr, r = pcall(N.redundant, store, n.id)
            if okr then add('checks', #(r.checks or {})) end
        end
    end
    vim.fn.delete(dir, 'rf') -- (only now: optimize and expr RE-READ the files — deleted earlier, every count was 0)
    if not (ctl.licm and ctl.cse and ctl.checks) then
        io.write('RO DEAD: the control was not detected ', vim.inspect(ctl):gsub('%s+', ' '), '\n')
        return {}
    end
    io.write(('RO optimizers: %d hoistable, %d redundant, %d redundant checks over %d functions (control detected)\n')
        :format(t.licm, t.cse, t.checks, t.fns))
    local reads, writes, repeated, cells, ctors = 0, 0, 0, 0, 0
    for _, text in ipairs(texts) do
        for body in ('\n' .. text):gmatch('\nfunction [^\n]*\n(.-)\nend') do
            local seen = {}
            for chain, rest in body:gmatch('([%w_]+%["[%w_]+"%])(%s*=?=?)') do
                if rest:match('^%s*=$') then writes = writes + 1
                else
                    reads = reads + 1
                    if seen[chain] then repeated = repeated + 1 end
                    seen[chain] = true
                end
            end
            for _ in body:gmatch('[%w_]+%[1%]') do cells = cells + 1 end
            for _ in body:gmatch('{ ') do ctors = ctors + 1 end
        end
    end
    io.write(('RO text: %d field reads (%d repeat an identical chain in their function), %d field writes, %d boxed-cell accesses, %d constructors\n')
        :format(reads, repeated, writes, cells, ctors))
    return {}
end }