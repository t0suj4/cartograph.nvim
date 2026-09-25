-- redundancy — redundant idempotent setup, and where one copy would do (cartograph.redundancy).
--
--   nvim --headless -u NONE -l tools/redundancy.lua <root> [--entry test] [--prelude <file>] [--show N]
--
-- The harness is derived: the PRELUDE defines the entry (`_G.test`), the UNITS call it. Prints the hoist
-- suggestions (with their premises), then the redundant steps by kind, then N samples of each.

local here = debug.getinfo(1, 'S').source:sub(2):match('^(.*)/[^/]*$')
package.path = './lua/?.lua;./lua/?/init.lua;' .. package.path
local bench = dofile(here .. '/bench.lua')
local store = require 'cartograph.store'
local redundancy = require 'cartograph.redundancy'

local root, opts, show = nil, {}, 8
local i = 1
while i <= #arg do
    if arg[i] == '--entry' then opts.entry = arg[i + 1]; i = i + 1
    elseif arg[i] == '--prelude' then opts.prelude = arg[i + 1]; i = i + 1
    elseif arg[i] == '--show' then show = tonumber(arg[i + 1]); i = i + 1
    else root = arg[i] end
    i = i + 1
end
assert(root, 'usage: redundancy.lua <root> [--entry test] [--prelude <file>] [--show N]')
local data = bench.extract((vim.fn.fnamemodify(root, ':p'):gsub('/$', '')))
store.ingest(data)
local t0 = vim.uv.hrtime()
local R = redundancy.analyze(store, data, opts)
local s = R.stats
print(('redundancy %s: %d harness(es); %d unit(s), %d test bod(ies), %d helper(s); %d fact(s), %d direct step(s)  [%.1fs]')
    :format(root, #(R.harnesses or {}), s.units, s.bodies, s.helpers, s.facts, s.steps, (vim.uv.hrtime() - t0) / 1e9))
for _, h in ipairs(R.harnesses or {}) do
    local n = 0
    for _ in pairs(h.units) do n = n + 1 end
    print(('  harness %s  glob %s  %d unit(s)'):format(h.prelude, tostring(h.glob), n))
end
if R.why then print('  refused: ' .. R.why) end
local by = {}
for _, f in ipairs(R.findings) do by[f.kind] = by[f.kind] or {}; table.insert(by[f.kind], f) end
for _, kind in ipairs({ 'missing', 'order-dependent', 'possible', 'hoist', 'redundant', 'redundant-via' }) do
    local l = by[kind] or {}
    print(('  %-14s %d'):format(kind, #l))
    for j = 1, math.min(kind == 'hoist' and #l or show, #l) do print('    ' .. redundancy.text(l[j])) end
    if kind == 'hoist' then
        for _, f in ipairs(l) do
            for _, a in ipairs(f.assumes or {}) do print(('      assumes %s [%s]: %s%s'):format(a.id, a.basis, a.says, a.src and ('  — ' .. a.src) or '')) end
        end
    end
end
