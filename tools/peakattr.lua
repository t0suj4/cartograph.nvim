-- peakattr — decompose the parallel-merge RESIDENT graph by component, so a peak
-- lever targets the term that actually dominates (record-fold arc step 2b: is it
-- node scalars, node DETAIL tables, edges, or calls?). GC-delta attribution: free
-- one component, force a full collection, and the heap drop is its real byte cost.
-- Measured at on_done (the merged graph) — mentions/transient-chunk records are
-- transient spikes ON TOP of this, but this is the sustained bulk of the peak.
--
--   nvim --headless -u NONE -l tools/peakattr.lua <corpus>

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
pcall(vim.treesitter.language.add, 'lua')
package.path = repo .. '/tools/?.lua;' .. repo .. '/lua/?.lua;' .. repo .. '/lua/?/init.lua;' .. package.path
local bench = require 'bench'
bench.bootstrap()

local name = arg[1]
if not name then print('usage: peakattr <corpus>'); os.exit(2) end
local c = bench.corpus(name)
local par = require 'cartograph.parallel'

local acc
par.extract(c.root, { packs = c.packs, on_done = function (d) acc = d end })
vim.wait(1800000, function () return acc ~= nil end, 50)

local function heap()
    collectgarbage(); collectgarbage()
    return collectgarbage('count') / 1024 -- MB
end

local NODE_DETAIL = { 'df', '_flow', 'flow', 'params', 'data', 'pw', 'locals', 'synth' }

local nnodes = #(acc.nodes or {})
local nedges = #(acc.edges or {})
local ncalls = acc._callstore and acc._callstore.cc.n or #(acc.calls or {})
print(('peakattr %s — %d nodes · %d edges · %d calls'):format(name, nnodes, nedges, ncalls))

local base = heap()
local total = base
local function drop(label, fn)
    fn()
    local after = heap()
    print(('  %-22s %8.1f MB'):format(label, base - after))
    base = after
end

-- node DETAIL tables first (they hang off the node records; free them before the
-- nodes so the attribution is detail-vs-scalar)
drop('node detail (df/flow/…)', function ()
    for _, n in ipairs(acc.nodes or {}) do
        for _, f in ipairs(NODE_DETAIL) do n[f] = nil end
    end
end)
drop('edges (+ .at lists)', function () acc.edges = nil end)
drop('calls / callstore', function () acc.calls = nil; acc._callstore = nil end)
drop('nodes (scalars+range)', function () acc.nodes = nil end)
drop('everything else', function () acc = nil end)
print(('  %-22s %8.1f MB  (resident graph total)'):format('=', total - base))
vim.cmd('qall!')
