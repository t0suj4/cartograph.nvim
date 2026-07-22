-- edgegate — the faithfulness gate for the resident columnar EDGE store
-- (edgecols.lua, record-fold arc). Proves edgecols.view is a behaviour-faithful
-- drop-in for data.edges: for every edge, every field, a proxy read equals a
-- record read (covered field → column, else the residual; flags by truthiness) +
-- the honest residual coverage disclosure. The edge analog of callgate/nodegate.
--
--   nvim --headless -u NONE -l tools/edgegate.lua <corpus>
-- Exit 1 on any mismatch, 2 if not applicable.

local here = debug.getinfo(1, 'S').source:sub(2):match('^(.*)/edgegate%.lua$')
local bench = dofile(here .. '/bench.lua')
bench.bootstrap()
local edgecols = require 'cartograph.edgecols'
local colparity = require 'cartograph.colparity'

local name = arg and arg[1]
if not name then print('usage: edgegate <corpus>'); os.exit(2) end
if not pcall(bench.corpus, name) then print('unknown corpus: ' .. name); os.exit(2) end

-- flags compared by truthiness, scalars/ranges by value; the shared colparity core
local FLAG = {}
for _, f in ipairs(edgecols.EDGE_SYN.flags) do FLAG[f] = true end
for _, f in ipairs(edgecols.EDGE_RES.flags or {}) do FLAG[f] = true end
local feq = colparity.mkfeq(FLAG)

local data = bench.extract(name)
local edges = data.edges or {}
local view = edgecols.view(edges)
local cov = view.covered

local mism, residual, columnar = {}, {}, {}
for i = 1, #edges do
    local rec, proxy = edges[i], view.rows[i]
    local rebuilt = edgecols.record(view, i)
    for f in pairs(cov) do
        if not feq(f, rebuilt[f], rec[f]) then mism[#mism + 1] = { i, f, 'column' } end
    end
    for k, v in pairs(rec) do
        if not feq(k, proxy[k], v) then mism[#mism + 1] = { i, k, 'proxy' } end
        if cov[k] then columnar[k] = (columnar[k] or 0) + 1
        else residual[k] = (residual[k] or 0) + 1 end
    end
end

local function block(tbl, title)
    local keys = {}
    for k in pairs(tbl) do keys[#keys + 1] = k end
    if #keys == 0 then return end
    table.sort(keys, function (a, b) return tbl[a] > tbl[b] or (tbl[a] == tbl[b] and a < b) end)
    print(title)
    for _, k in ipairs(keys) do print(('    %-12s %d'):format(k, tbl[k])) end
end

print(('edgegate %s — %d edges · %d mismatch(es)'):format(name, #edges, #mism))
block(columnar, '  columnar (fixed-width columns):')
block(residual, '  residual (detail — at range-list / flds / sparse gw,rw):')

if #mism > 0 then
    for j = 1, math.min(#mism, 20) do
        local m = mism[j]
        print(('  MISMATCH edge #%d field %q (%s)'):format(m[1], m[2], m[3]))
    end
    vim.cmd('cquit 1')
else
    print('OK — edgecols.view is a faithful drop-in for data.edges')
    vim.cmd('qall!')
end
