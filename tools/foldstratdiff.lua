-- foldstratdiff — CROSS-STRATEGY parity for the fold-emit knob ([[cartograph-thin-index]]).
-- The worker fold-emit path (config.merge_worker_fold: workers fold their chunk + ship the
-- store once, parent re-attaches + collects, multi-store) must produce a graph BYTE-for-
-- graph identical to the default parallel path (workers ship raw, parent folds whole-graph).
-- Extract the same corpus BOTH ways in one process (flip config between runs) and graphdiff
-- + compare the df/flow fold fingerprint. Any difference = the strategy changed the graph.
--
--   nvim --headless -u NONE -l tools/foldstratdiff.lua [corpus]   (default: jquery)

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
pcall(vim.treesitter.language.add, 'lua')
package.path = repo .. '/tools/?.lua;' .. repo .. '/lua/?.lua;' .. repo .. '/lua/?/init.lua;' .. package.path
local bench = require 'bench'
local config = require 'cartograph.config'
local graphdiff = require 'cartograph.graphdiff'
local df = require 'cartograph.df'
local flow = require 'cartograph.flow'

local name = arg[1] or 'jquery'

local function fold_fp(g)
    local sdf, sfl, n = 0, 0, 0
    local per = {}
    for _, node in ipairs(g.nodes or {}) do
        local dc, fc = df.count(node), (flow.count and flow.count(node) or 0)
        if dc > 0 or fc > 0 then per[node.id] = dc .. ':' .. fc; sdf = sdf + dc; sfl = sfl + fc; n = n + 1 end
    end
    return { per = per, sdf = sdf, sfl = sfl, n = n }
end

print(('foldstratdiff %s — default parallel vs worker-fold, graph must be identical'):format(name))

config.merge_worker_fold = false
local gD = bench.extract_parallel(name)
local fpD = fold_fp(gD)
print(('  DEFAULT (parent-fold): %d nodes, %d edges, %d calls; %d df-nodes, %d df stmts, %d flow rows')
    :format(#(gD.nodes or {}), #(gD.edges or {}), #(gD.calls or {}), fpD.n, fpD.sdf, fpD.sfl))

config.merge_worker_fold = true
local gW = bench.extract_parallel(name)
local fpW = fold_fp(gW)
print(('  WORKER-FOLD (collect):  %d nodes, %d edges, %d calls; %d df-nodes, %d df stmts, %d flow rows')
    :format(#(gW.nodes or {}), #(gW.edges or {}), #(gW.calls or {}), fpW.n, fpW.sdf, fpW.sfl))

-- how many distinct stores are the worker-fold nodes spread across (multi-store proof)?
local stores = {}
for _, node in ipairs(gW.nodes or {}) do if node._df then stores[node._df] = true end end
local nstores = 0; for _ in pairs(stores) do nstores = nstores + 1 end
print(('  worker-fold df is spread across %d distinct per-chunk store(s) (multi-store collect)'):format(nstores))

local d = graphdiff.diff(gD, gW)
print('  --- graphdiff (default vs worker-fold) ---')
for _, ln in ipairs(graphdiff.report(d, { limit = 12 })) do print('    ' .. ln) end

local fold_mm, checked = 0, 0
for id, v in pairs(fpD.per) do checked = checked + 1; if fpW.per[id] ~= v then fold_mm = fold_mm + 1 end end
for id in pairs(fpW.per) do if fpD.per[id] == nil then fold_mm = fold_mm + 1 end end
print(('  df/flow fold fingerprint mismatches: %d (of %d)'):format(fold_mm, checked))

if graphdiff.empty(d) and fold_mm == 0 then
    print('VERDICT: PARITY — worker-fold produces the identical graph (structure + fold). Multi-store collect is sound.')
    vim.cmd('qall!')
else
    print('FAIL: worker-fold diverges from the default parallel graph.')
    vim.cmd('cquit 1')
end
