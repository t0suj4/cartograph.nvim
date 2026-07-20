-- resident — the true post-ingest STORE resident, per index table (record-fold
-- arc step 1's measurement half, [[cartograph-record-fold-arc]]: "FINALLY
-- measure — no session measure included the indexes"). For each wide index the
-- store builds at ingest, the marginal retained cost via a GC delta (nil it,
-- full GC, measure, restore). Answers WHICH table is worth retiring first
-- (deriving from the fold CSR instead) — the measure-first input to the retire
-- decision, like ablate/levers for resolution.
--
--   nvim --headless -u NONE -l tools/resident.lua [<corpus-name>|<dir>]

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
pcall(vim.treesitter.language.add, 'lua')
package.path = repo .. '/lua/?.lua;' .. repo .. '/lua/?/init.lua;' .. package.path

local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'

local arg1 = arg[1]
local root = repo .. '/lua'
if arg1 then
    local ok, corpora = pcall(dofile, repo .. '/tools/corpora.lua')
    if ok and corpora[arg1] and corpora[arg1].root then root = corpora[arg1].root else root = arg1 end
end

local data = ts.extract(root)
data.root = data.root or root
store.ingest(data)
store.topo() -- build the fold (part of the resident picture)

-- clear JIT-trace-pinned extraction garbage FIRST (fold-core Stage-0: traces
-- compiled during a big extract pin extraction-era objects as GC constants;
-- ingest only auto-flushes >20000 nodes, so smaller corpora keep the garbage
-- resident and confound the measure). Flush → the TRUE resident.
if rawget(_G, 'jit') and jit.flush then jit.flush() end
collectgarbage(); collectgarbage()

-- the wide index tables the store builds at ingest (idx_node/idx_call/idx_edge)
local TABLES = {
    'by_id', 'by_file', 'by_name',
    'calls_to', 'calls_by_fn', 'calls_by_file', 'calls_by_prov',
    'uses', 'usedby', 'occ', 'edge_inferred', 'edge_tinf', 'edge_tier',
    'var_uses', 'var_usedby', 'imports_in', 'imports_out', 'reg_by', 'registers',
}

local function kb()
    collectgarbage(); collectgarbage()
    return collectgarbage('count')
end

-- marginal cost of one field: drop the store's reference, GC, measure the fall
-- (shared payloads referenced elsewhere — occ's at-lists live on data.edges —
-- stay, so this is the INDEX overhead, which is what retiring frees). Restore.
local function cost(field)
    local base = kb()
    local saved = store[field]
    store[field] = nil
    local delta = base - kb()
    store[field] = saved
    return delta
end

-- index-table overhead Σ (the step-1 retirement target)
local idx_total = 0
for _, f in ipairs(TABLES) do idx_total = idx_total + cost(f) end

-- the fold's EXACT serialized size (not a GC estimate) — the resident topology
-- representation the index tables would be derived from
local fold = store._fold
local fold_mb = fold and (fold:bytes() + fold:string_bytes()) / 1048576 or 0

local heap = kb() / 1024
local ncalls = #(data.calls or {})
local function mb(x) return ('%8.2f MB'):format(x) end
print(('resident %s — %d nodes / %d edges / %d calls'):format(
    root:gsub('.*/', ''), #(data.nodes or {}), #(data.edges or {}), ncalls))
print('  full store heap (trace-flushed): ' .. mb(heap))
print('  ── the record-fold TARGETS (measured) ──')
print('  index tables Σ (step-1 retire)   ' .. mb(idx_total / 1024)
    .. '   ← NEGLIGIBLE: reference-indexes pin, they don\'t own')
print('  _fold CSR (exact serialized)     ' .. mb(fold_mb)
    .. '   ← topology, already 32× folded')
print(('  RECORDS = heap − fold − indexes ≈ %.1f MB   ← THE WEIGHT: %d calls'):format(
    heap - fold_mb - idx_total / 1024, ncalls)
    .. ' + argv/at/df riders (steps 3-4)')
print('  → step 1 (index→Band) frees ~' .. ('%.2f'):format(idx_total / 1024)
    .. ' MB; the ROI is folding the RECORDS.')
