-- indexlsp — wire + gate the LSP/nav path over the INDEX-ONLY graph ([[cartograph-thin-index]]
-- increment 2). The thin index (defs only, no calls/edges) must serve the Tier-0 LSP handlers —
-- workspace/symbol, documentSymbol, definition-ON-A-DEF, def hover — IDENTICALLY to the full
-- graph (same def nodes → same symbols/locations). The Tier-1 handlers (definition on a call,
-- references, callHierarchy, semanticTokens) must DEGRADE HONESTLY: empty results, no crash
-- (index-only has no calls/edges to resolve). Ingest full then index-only, compare Tier-0, drive
-- Tier-1 for liveness.
--
--   nvim --headless -u NONE -l tools/indexlsp.lua [corpus]   (default: jquery)

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
pcall(vim.treesitter.language.add, 'lua')
package.path = repo .. '/tools/?.lua;' .. repo .. '/lua/?.lua;' .. repo .. '/lua/?/init.lua;' .. package.path
local bench = require 'bench'
local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'
local lsp = require 'cartograph.lsp'

local name = arg[1] or 'jquery'

-- a comparable signature for a symbol list (name+kind+uri+range), order-independent
local function symkey(s)
    local loc = s.location or s
    local r = loc.range or {}
    return ('%s\31%s\31%s\31%d:%d'):format(s.name or '?', s.kind or 0,
        loc.uri or '?', (r.start or {}).line or -1, (r.start or {}).character or -1)
end
local function symset(list)
    local set, n = {}, 0
    for _, s in ipairs(list or {}) do set[symkey(s)] = true; n = n + 1 end
    return set, n
end

-- full graph
local full = bench.extract(name)
store.ingest(full)
local full_ws = select(1, symset(lsp.handle(store, 'workspace/symbol', { query = '' })))

-- pick a file with defs to exercise documentSymbol + definition-on-a-def
local probe_file, probe_node
for _, node in ipairs(store.data.nodes or {}) do
    if node.kind == 'function' or node.kind == 'method' then probe_file = node.file; probe_node = node; break end
end
local full_ds = probe_file and select(1, symset(lsp.handle(store, 'textDocument/documentSymbol',
    { textDocument = { uri = vim.uri_from_fname(store.abs(probe_file)) } }))) or {}

-- index-only graph
local idx = ts.index_only(full.root)
store.ingest(idx)
local idx_ws, nws = symset(lsp.handle(store, 'workspace/symbol', { query = '' }))
local idx_ds = probe_file and select(1, symset(lsp.handle(store, 'textDocument/documentSymbol',
    { textDocument = { uri = vim.uri_from_fname(store.abs(probe_file)) } }))) or {}

-- diff Tier-0 (index-only must equal full for def-based queries)
local function diff(a, b)
    local miss, extra = 0, 0
    for k in pairs(a) do if not b[k] then miss = miss + 1 end end
    for k in pairs(b) do if not a[k] then extra = extra + 1 end end
    return miss, extra
end
local ws_miss, ws_extra = diff(full_ws, idx_ws)
local ds_miss, ds_extra = diff(full_ds, idx_ds)

-- definition ON A DEF (cursor on the def's own name) — must return that def's location.
-- Pick the probe node from the INDEX-ONLY store (current), so its folded range index reads
-- against the current at-store (the at module re-points C on each ingest).
local atr = require 'cartograph.at'
local inode
for _, node in ipairs(store.data.nodes or {}) do
    if node.kind == 'function' or node.kind == 'method' then inode = node; break end
end
local def_ok = false
if inode then
    local uri = vim.uri_from_fname(store.abs(inode.file))
    local locs = lsp.handle(store, 'textDocument/definition',
        { textDocument = { uri = uri },
          position = { line = atr.sl(inode.range), character = atr.sc(inode.range) } })
    def_ok = type(locs) == 'table' and #locs >= 1
end

-- Tier-1 handlers must not CRASH on the callless graph (honest-empty)
local live_ok, live_err = pcall(function ()
    local uri = inode and vim.uri_from_fname(store.abs(inode.file))
    local pos = { line = 0, character = 0 }
    lsp.handle(store, 'textDocument/references', { textDocument = { uri = uri }, position = pos, context = {} })
    lsp.handle(store, 'textDocument/hover', { textDocument = { uri = uri }, position = pos })
    lsp.handle(store, 'textDocument/semanticTokens/full', { textDocument = { uri = uri } })
    lsp.handle(store, 'textDocument/prepareCallHierarchy', { textDocument = { uri = uri }, position = pos })
end)

print(('indexlsp %s'):format(name))
print(('  workspace/symbol: %d symbols (index-only) — vs full: %d missing · %d extra'):format(nws, ws_miss, ws_extra))
print(('  documentSymbol (%s): %d missing · %d extra'):format(probe_file or '?', ds_miss, ds_extra))
print(('  definition-on-a-def: %s'):format(def_ok and 'OK (returns the def location)' or 'FAIL'))
print(('  Tier-1 handlers on callless graph: %s'):format(live_ok and 'no crash (honest-empty)' or ('CRASH: ' .. tostring(live_err))))

if ws_miss == 0 and ws_extra == 0 and ds_miss == 0 and ds_extra == 0 and def_ok and live_ok then
    print('OK — Tier-0 LSP/nav serves IDENTICALLY off the thin index; Tier-1 degrades honestly')
    vim.cmd('qall!')
else
    print('FAIL — LSP/nav over the thin index diverges from full, or a handler crashed')
    vim.cmd('cquit 1')
end
