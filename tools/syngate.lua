-- The SYNTHETIC ANALYSIS ground-truth gate ([[cartograph-synthetic-analysis-groundtruth]]).
--   nvim --headless -u NONE -l tools/syngate.lua
-- Generates planted analysis corpora with a KNOWN answer key (tools/gen.lua's
-- M.analysis), runs the analysis LENSES over them, and asserts findings == key —
-- the systematic version of dogfooding. The key's NEGATIVES (fact=false) are the
-- point: a lens that narrows where it must NOT is a false positive caught here,
-- not by eyeballing self. Exit 1 on any false positive OR false negative.
-- INC 1 = narrowing (narrow.lua). LICM/CSE/untangle keys follow in later INCs.

local here = debug.getinfo(1, 'S').source:sub(2)
local repo = vim.fn.fnamemodify(here, ':p:h:h')
vim.opt.rtp:prepend(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
package.path = repo .. '/lua/?.lua;' .. repo .. '/lua/?/init.lua;' .. package.path

local gen = dofile(repo .. '/tools/gen.lua')
local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local narrow = require 'cartograph.narrow'
local optimize = require 'cartograph.optimize'
local flow = require 'cartograph.flow'
local untangle = require 'cartograph.untangle'
local exprlint = require 'cartograph.exprlint'
local expr = require 'cartograph.expr'

local SEED, NFILES = 1, 12
local a = gen.analysis('lua', NFILES, SEED)
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, 'p')
for name, src in pairs(a.files) do
    vim.fn.writefile(vim.split(src, '\n', { plain = true }), dir .. '/' .. name)
end
store.ingest(ts.extract(dir))

-- collect each lens's per-(file,line) facts in one pass (a line belongs to one fn)
local narrowenv, hoist, reuse, redun, ncomp, rung0 = {}, {}, {}, {}, {}, {}
local gatebad = {} -- expr self-gate disagreements (reads ≠ use∪rmw) — must be empty
local function K(f, l) return (f or '') .. '\31' .. l end
local function KR(f, l, r) return (f or '') .. '\31' .. l .. '\31' .. r end
for _, n in ipairs(store.data.nodes) do
    if n.kind == 'function' then
        local f = n.file or ''
        local oke, got = pcall(expr.of, store, n.id)
        if oke and got then
            for _, d in ipairs(expr.gate(got.fl)) do
                gatebad[#gatebad + 1] = ('%s:%d reads≠use∪rmw missing=[%s] extra=[%s]')
                    :format(f, d.line, table.concat(d.missing, ','), table.concat(d.extra, ','))
            end
        end
        local okx, xr = pcall(exprlint.lint, store, n.id)
        if okx and xr and xr.findings then
            for _, fd in ipairs(xr.findings) do rung0[KR(f, fd.line, fd.rule)] = true end
        end
        local okn, nr = pcall(narrow.narrow, store, n.id)
        if okn then for _, p in ipairs(nr.points) do narrowenv[K(f, p.line)] = p.env end end
        local okr, rr = pcall(narrow.redundant, store, n.id)
        if okr then for _, c in ipairs(rr.checks) do redun[K(f, c.line)] = c.always end end
        local oku, fl = pcall(flow.record, n)
        if oku and fl then
            local oka, res = pcall(function ()
                local e, o = untangle.effect_edges(store, n.id, fl)
                return untangle.analyze_flow(fl, e, o)
            end)
            if oka and res then ncomp[K(f, n.name or '?')] = res.ncomp end
        end
        local okl, lr = pcall(optimize.licm, store, n.id)
        if okl then for _, h in ipairs(lr.heads) do
            for r in pairs(lr.loops[h].hoistable) do hoist[K(f, lr.rows[r].l)] = true end
        end end
        local okc, cr = pcall(optimize.cse, store, n.id)
        if okc then for _, p in ipairs(cr.redundant) do
            reuse[K(f, cr.rows[p.second].l)] = cr.rows[p.first].l
        end end
    end
end

-- diff per lens: `pass` counts, `fp`/`fn` collect (false-positive = the lens fired
-- where the negative key says it must NOT — the whole point of the negatives).
local census = {} -- lens -> {pass, fp={}, fn={}}
local function rec(lens) census[lens] = census[lens] or { pass = 0, fp = {}, fn = {} }; return census[lens] end
for _, e in ipairs(a.key) do
    local c = rec(e.lens)
    if e.lens == 'narrow' then
        local got = (narrowenv[K(e.file, e.line)] or {})[e.var]
        if e.fact == false then
            if got ~= nil then c.fp[#c.fp + 1] = ('%s:%d `%s` narrowed to %s (must stay unknown)'):format(e.file, e.line, e.var, got)
            else c.pass = c.pass + 1 end
        elseif got == e.fact then c.pass = c.pass + 1
        else c.fn[#c.fn + 1] = ('%s:%d `%s` expected %s, got %s'):format(e.file, e.line, e.var, e.fact, tostring(got)) end
    elseif e.lens == 'licm' then
        local got = hoist[K(e.file, e.line)] or false
        if e.hoistable then
            if got then c.pass = c.pass + 1
            else c.fn[#c.fn + 1] = ('%s:%d expected hoistable, was not'):format(e.file, e.line) end
        else
            if got then c.fp[#c.fp + 1] = ('%s:%d FALSE-POSITIVE hoistable (must not be)'):format(e.file, e.line)
            else c.pass = c.pass + 1 end
        end
    elseif e.lens == 'cse' then
        local got = reuse[K(e.file, e.line)]
        if e.reuses then
            if got == e.reuses then c.pass = c.pass + 1
            else c.fn[#c.fn + 1] = ('%s:%d expected reuse of L%s, got %s'):format(e.file, e.line, e.reuses, tostring(got)) end
        else
            if got then c.fp[#c.fp + 1] = ('%s:%d FALSE-POSITIVE redundant (must not be)'):format(e.file, e.line)
            else c.pass = c.pass + 1 end
        end
    elseif e.lens == 'redundant' then
        local got = redun[K(e.file, e.line)] -- true | false | nil
        if e.want == 'none' then
            if got ~= nil then c.fp[#c.fp + 1] = ('%s:%d FALSE-POSITIVE redundant-check (must not flag)'):format(e.file, e.line)
            else c.pass = c.pass + 1 end
        elseif got == e.want then c.pass = c.pass + 1
        else c.fn[#c.fn + 1] = ('%s:%d expected redundant always=%s, got %s'):format(e.file, e.line, tostring(e.want), tostring(got)) end
    elseif e.lens == 'untangle' then
        local got = ncomp[K(e.file, e.fn)]
        if got == e.ncomp then c.pass = c.pass + 1
        else c.fn[#c.fn + 1] = ('%s:%s expected ncomp=%d, got %s'):format(e.file, e.fn, e.ncomp, tostring(got)) end
    elseif e.lens == 'rung0' then
        local got = rung0[KR(e.file, e.line, e.rule)] or false
        if e.present then
            if got then c.pass = c.pass + 1
            else c.fn[#c.fn + 1] = ('%s:%d expected `%s`, not flagged'):format(e.file, e.line, e.rule) end
        else
            if got then c.fp[#c.fp + 1] = ('%s:%d FALSE-POSITIVE `%s` (must not flag)'):format(e.file, e.line, e.rule)
            else c.pass = c.pass + 1 end
        end
    end
end

local failed = false
-- the expr SELF-GATE: reads ≡ use∪rmw over every syn fn (an independent derivation;
-- a disagreement is a real bug on one side — the oracle discipline in the substrate)
print(('syngate %-7s %d disagreement(s)'):format('exprgate:', #gatebad))
for _, m in ipairs(gatebad) do print('  GATE ' .. m); failed = true end
for _, lens in ipairs({ 'narrow', 'redundant', 'licm', 'cse', 'untangle', 'rung0' }) do
    local c = census[lens]
    if c then
        print(('syngate %-7s %d ok, %d false-pos, %d false-neg')
            :format(lens .. ':', c.pass, #c.fp, #c.fn))
        for _, m in ipairs(c.fp) do print('  FP ' .. m); failed = true end
        for _, m in ipairs(c.fn) do print('  FN ' .. m); failed = true end
    end
end
if failed then print('SYNGATE: FAIL'); os.exit(1) end
print('SYNGATE: PASS')
