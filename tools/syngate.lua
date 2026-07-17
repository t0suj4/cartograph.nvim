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
local narrowenv, hoist, reuse, redun, ncomp, rung0, localized = {}, {}, {}, {}, {}, {}, {}
local paramnil = {} -- KR(file, fn, param) -> {verdict, conflict}
local prehoist = {} -- K(file, fn) -> true if a PRE hoist exists
local devirt = {}   -- K(file, line) -> status ('certified'|'candidate') of a dispatch site
local registry = {} -- K(file, line) -> the NAME of the node a LibStub retrieve resolved to
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
        local okz, zr = pcall(optimize.localize, store, n.id)
        if okz and zr then for _, lp in ipairs(zr.loops) do
            for _, cd in ipairs(lp.cands) do localized[KR(f, n.name or '?', cd.full)] = true end
        end end
        local okp, pr = pcall(narrow.param_nilability, store, n.id)
        if okp and pr and pr.params then for _, p in ipairs(pr.params) do
            paramnil[KR(f, n.name or '?', p.name)] = { verdict = p.verdict, conflict = p.conflict or false }
        end end
        local okc, cr = pcall(optimize.cse, store, n.id)
        if okc then for _, p in ipairs(cr.redundant) do
            reuse[K(f, cr.rows[p.second].l)] = cr.rows[p.first].l
        end end
        local okpre, prr = pcall(optimize.pre, store, n.id)
        if okpre and prr and #prr.hoists > 0 then prehoist[K(f, n.name or '?')] = true end
        local okd, dr = pcall(narrow.devirt, store, n.id)
        if okd and dr and dr.sites then for _, d in ipairs(dr.sites) do devirt[K(f, d.line)] = d.status end end
    end
end

-- registry: resolve_registry ran at extract → LibStub retrieves carry c.registry
-- (the resolved node id); record the resolved node's NAME per (file, line).
for _, c in ipairs(store.data.calls or {}) do
    if c.registry and c.callee == 'LibStub' and not c.method then
        local nd = store.node and store.node(c.registry)
        registry[K(c.file, (c.line or 0) + 1)] = nd and nd.name or true -- c.line is 0-based; key is 1-based
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
    elseif e.lens == 'localize' then
        local got = localized[KR(e.file, e.fn, e.full)] or false
        if e.present then
            if got then c.pass = c.pass + 1
            else c.fn[#c.fn + 1] = ('%s:%s expected localize `%s`, not suggested'):format(e.file, e.fn, e.full) end
        else
            if got then c.fp[#c.fp + 1] = ('%s:%s FALSE-POSITIVE localize `%s` (must not suggest)'):format(e.file, e.fn, e.full)
            else c.pass = c.pass + 1 end
        end
    elseif e.lens == 'pre' then
        local got = prehoist[K(e.file, e.fn)] or false
        if e.want then
            if got then c.pass = c.pass + 1
            else c.fn[#c.fn + 1] = ('%s:%s expected a PRE hoist, none'):format(e.file, e.fn) end
        else
            if got then c.fp[#c.fp + 1] = ('%s:%s FALSE-POSITIVE PRE hoist (must not)'):format(e.file, e.fn)
            else c.pass = c.pass + 1 end
        end
    elseif e.lens == 'paramnil' then
        local got = paramnil[KR(e.file, e.fn, e.param)]
        if not got then c.fn[#c.fn + 1] = ('%s:%s(%s) not analyzed'):format(e.file, e.fn, e.param)
        elseif got.verdict ~= e.verdict then
            c.fn[#c.fn + 1] = ('%s:%s(%s) expected %s, got %s'):format(e.file, e.fn, e.param, e.verdict, got.verdict)
        elseif got.conflict ~= e.conflict then
            -- a spurious conflict is the dangerous FP (the oracle must be trustworthy)
            local m = ('%s:%s(%s) conflict expected %s, got %s'):format(e.file, e.fn, e.param, tostring(e.conflict), tostring(got.conflict))
            if got.conflict then c.fp[#c.fp + 1] = m else c.fn[#c.fn + 1] = m end
        else c.pass = c.pass + 1 end
    elseif e.lens == 'registry' then
        -- want = <resolved var name> | false (must NOT resolve — unregistered key)
        local got = registry[K(e.file, e.line)]
        if e.want == false then
            if got then c.fp[#c.fp + 1] = ('%s:%d resolved to %s (unregistered — must not)'):format(e.file, e.line, tostring(got))
            else c.pass = c.pass + 1 end
        elseif got == e.want then c.pass = c.pass + 1
        else c.fn[#c.fn + 1] = ('%s:%d expected registry→%s, got %s'):format(e.file, e.line, e.want, tostring(got)) end
    elseif e.lens == 'devirt' then
        -- want = 'certified' | 'candidate' | false (must NOT be a devirt site)
        local got = devirt[K(e.file, e.line)]
        if e.want == false then
            if got then c.fp[#c.fp + 1] = ('%s:%d FALSE devirt site (%s; must be none)'):format(e.file, e.line, got)
            else c.pass = c.pass + 1 end
        elseif got == e.want then c.pass = c.pass + 1
        else c.fn[#c.fn + 1] = ('%s:%d expected %s dispatch, got %s'):format(e.file, e.line, e.want, tostring(got)) end
    end
end

local failed = false
-- the expr SELF-GATE: reads ≡ use∪rmw over every syn fn (an independent derivation;
-- a disagreement is a real bug on one side — the oracle discipline in the substrate)
print(('syngate %-7s %d disagreement(s)'):format('exprgate:', #gatebad))
for _, m in ipairs(gatebad) do print('  GATE ' .. m); failed = true end
for _, lens in ipairs({ 'narrow', 'redundant', 'licm', 'cse', 'untangle', 'rung0', 'localize', 'paramnil', 'pre', 'devirt', 'registry' }) do
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
