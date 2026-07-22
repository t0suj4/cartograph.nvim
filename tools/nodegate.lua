-- nodegate — the faithfulness gate for the resident columnar NODE store
-- (nodecols.lua, record-fold arc). Proves nodecols.view is a behaviour-faithful
-- drop-in for data.nodes: for every node, every field, a proxy read equals a
-- record read (covered field → column, else the residual; flags compared by
-- truthiness). Plus the honest residual coverage disclosure (which fields ride
-- columns vs the residual). The node analog of callgate/callparity — the gate
-- that must go green before any consumer migrates onto the columnar node store.
--
--   nvim --headless -u NONE -l tools/nodegate.lua <corpus>
-- Exit 1 on any mismatch, 2 if not applicable.

local here = debug.getinfo(1, 'S').source:sub(2):match('^(.*)/nodegate%.lua$')
local bench = dofile(here .. '/bench.lua')
bench.bootstrap()
local nodecols = require 'cartograph.nodecols'

local name = arg and arg[1]
if not name then print('usage: nodegate <corpus>'); os.exit(2) end
if not pcall(bench.corpus, name) then print('unknown corpus: ' .. name); os.exit(2) end

local FLAG = {}
for _, f in ipairs(nodecols.NODE_SYN.flags) do FLAG[f] = true end

-- range-shaped deep compare, else reference/scalar equality (a residual table is
-- the SAME ref the proxy returns, so == holds — matching a raw n.field read).
local function veq(a, b)
    if a == b then return true end
    if type(a) ~= 'table' or type(b) ~= 'table' then return false end
    local function pt(p, q)
        if p == q then return true end
        if type(p) ~= 'table' or type(q) ~= 'table' then return false end
        return p.line == q.line and p.char == q.char
    end
    if a.start or a['end'] or b.start or b['end'] then
        return pt(a.start, b.start) and pt(a['end'], b['end'])
    end
    return false
end
local function feq(field, a, b)
    if FLAG[field] then return (not not a) == (not not b) end
    return veq(a, b)
end

local data = bench.extract(name)
local nodes = data.nodes or {}
local view = nodecols.view(nodes)
local cov = view.covered

local mism, residual, columnar = {}, {}, {}
for i = 1, #nodes do
    local rec, proxy = nodes[i], view.rows[i]
    -- column readback == record over covered fields
    local rebuilt = nodecols.record(view, i)
    for f in pairs(cov) do
        if not feq(f, rebuilt[f], rec[f]) then mism[#mism + 1] = { i, f, 'column' } end
    end
    -- proxy round-trips EVERY record field
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

print(('nodegate %s — %d nodes · %d mismatch(es)'):format(name, #nodes, #mism))
block(columnar, '  columnar (fixed-width columns):')
block(residual, '  residual (detail tables — fold separately at ingest):')

if #mism > 0 then
    for j = 1, math.min(#mism, 20) do
        local m = mism[j]
        print(('  MISMATCH node #%d field %q (%s)'):format(m[1], m[2], m[3]))
    end
    vim.cmd('cquit 1')
else
    print('OK — nodecols.view is a faithful drop-in for data.nodes')
    vim.cmd('qall!')
end
