-- f2graphdet — GRAPH-level cache determinism ([[cartograph-thin-index]], F2 step 3).
-- f2determ showed the cache BYTES vary run to run (same length, different order). But
-- M.load concatenates shards in SORTED file order, so byte-order noise inside a shard may
-- be cosmetic — what matters for correctness is whether the RECONSTRUCTED GRAPH is stable.
-- This extracts the corpus in parallel TWICE, saves + M.loads each cache back, and
-- graphdiffs the two loaded graphs (nodes by id, edges as (from,to,kind) multisets, calls
-- by site+outcome) — plus a df/flow FOLD spot-check (per-node stmt counts + row counts).
-- Graph-identical => byte non-determinism is cosmetic and step 3 was never truly blocked;
-- only the bloat remains. A graph DIFF => real non-determinism to fix before any wiring.
--
--   nvim --headless -u NONE -l tools/f2graphdet.lua [corpus]   (default: jquery)

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
pcall(vim.treesitter.language.add, 'lua')
package.path = repo .. '/tools/?.lua;' .. repo .. '/lua/?.lua;' .. repo .. '/lua/?/init.lua;' .. package.path
local bench = require 'bench'
local cache = require 'cartograph.cache'
local graphdiff = require 'cartograph.graphdiff'
local df = require 'cartograph.df'
local flow = require 'cartograph.flow'

local name = arg[1] or 'jquery'

-- extract in parallel, wipe+save the cache, load it back. Returns the LOADED graph
-- (independent of the extract acc, which is freed) so run B's save can't perturb it.
local function extract_save_load()
    local data = bench.extract_parallel(name)
    local root = data.root
    cache.wipe(root)
    cache.save(data)
    data = nil                       -- drop the extract graph; the cache is the source now
    collectgarbage(); collectgarbage()
    return (cache.load(root))
end

-- a stable per-df/flow fold fingerprint of the loaded graph: for each node id, its df
-- statement count and flow row count, summed and per-node hashed (order-independent).
local function fold_fingerprint(g)
    local sum_df, sum_fl, nodes = 0, 0, 0
    local pernode = {} -- id -> "dfN:flM"
    for _, n in ipairs(g.nodes or {}) do
        local dc = df.count(n)
        local fc = flow.present and (flow.count and flow.count(n) or 0) or 0
        if dc > 0 or fc > 0 then
            pernode[n.id] = dc .. ':' .. fc
            sum_df = sum_df + dc; sum_fl = sum_fl + fc; nodes = nodes + 1
        end
    end
    return { pernode = pernode, sum_df = sum_df, sum_fl = sum_fl, nodes = nodes }
end

print(('f2graphdet %s — two parallel extracts, save+load each, graphdiff the loaded graphs'):format(name))
local gA = extract_save_load()
local fpA = fold_fingerprint(gA)
-- keep only what the diff needs from A; drop nothing yet (diff needs full A)
local gB = extract_save_load()
local fpB = fold_fingerprint(gB)

print(('  loaded A: %d nodes, %d edges, %d calls'):format(#(gA.nodes or {}), #(gA.edges or {}), #(gA.calls or {})))
print(('  loaded B: %d nodes, %d edges, %d calls'):format(#(gB.nodes or {}), #(gB.edges or {}), #(gB.calls or {})))

-- ── structural graphdiff ─────────────────────────────────────────────
local d = graphdiff.diff(gA, gB)
local ok = graphdiff.empty(d)
print('  --- structural graphdiff (A vs B) ---')
for _, ln in ipairs(graphdiff.report(d, { limit = 12 })) do print('    ' .. ln) end

-- ── df/flow fold fingerprint diff ────────────────────────────────────
local fold_mismatch, checked = 0, 0
local first = {}
local seen = {}
for id, v in pairs(fpA.pernode) do
    seen[id] = true; checked = checked + 1
    if fpB.pernode[id] ~= v then
        fold_mismatch = fold_mismatch + 1
        if #first < 6 then first[#first + 1] = ('%s: A=%s B=%s'):format(id, v, tostring(fpB.pernode[id])) end
    end
end
for id in pairs(fpB.pernode) do if not seen[id] then fold_mismatch = fold_mismatch + 1 end end
print('  --- df/flow FOLD fingerprint (per-node stmt/row counts) ---')
print(('    A: %d df-carrying nodes, %d df stmts, %d flow rows')
    :format(fpA.nodes, fpA.sum_df, fpA.sum_fl))
print(('    B: %d df-carrying nodes, %d df stmts, %d flow rows')
    :format(fpB.nodes, fpB.sum_df, fpB.sum_fl))
print(('    per-node fold mismatches: %d (of %d checked)'):format(fold_mismatch, checked))
for _, s in ipairs(first) do print('      mismatch: ' .. s) end

-- ── verdict ──────────────────────────────────────────────────────────
if ok and fold_mismatch == 0 then
    print('VERDICT: GRAPH-DETERMINISTIC — loaded graphs are per-item identical (structure + fold).')
    print('         The byte non-determinism f2determ saw is COSMETIC (shard-internal key order);')
    print('         load reassembles in sorted file order. Step 3 was NOT truly blocked — only the')
    print('         P3 cache BLOAT (shared store duplicated per node) remains to fix.')
else
    print('VERDICT: GRAPH NON-DETERMINISTIC — the reconstructed graph itself varies run to run.')
    print('         Real correctness hole: must be fixed before per-chunk fold or any cache wiring.')
end
vim.cmd('qall!')
