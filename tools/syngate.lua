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

local SEED, NFILES = 1, 12
local a = gen.analysis('lua', NFILES, SEED)
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, 'p')
for name, src in pairs(a.files) do
    vim.fn.writefile(vim.split(src, '\n', { plain = true }), dir .. '/' .. name)
end
store.ingest(ts.extract(dir))

-- collect each lens's per-(file,line) facts in one pass (a line belongs to one fn)
local narrowenv, hoist, reuse, redun = {}, {}, {}, {}
local function K(f, l) return (f or '') .. '\31' .. l end
for _, n in ipairs(store.data.nodes) do
    if n.kind == 'function' then
        local f = n.file or ''
        local okn, nr = pcall(narrow.narrow, store, n.id)
        if okn then for _, p in ipairs(nr.points) do narrowenv[K(f, p.line)] = p.env end end
        local okr, rr = pcall(narrow.redundant, store, n.id)
        if okr then for _, c in ipairs(rr.checks) do redun[K(f, c.line)] = c.always end end
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
    end
end

local failed = false
for _, lens in ipairs({ 'narrow', 'redundant', 'licm', 'cse' }) do
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
