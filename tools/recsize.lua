-- recsize — total resident size of RAW RECORDS (node/edge/call tables) vs the CSR fold
-- ([[cartograph-thin-index]] / [[cartograph-fold-core]]). Parallel extract (server-safe) →
-- ingest → topo (build CSR). Reports: the CSR fold bytes (exact, from csr:bytes), the record
-- arrays broken node/edge/call (deep byte estimate), and the true store heap (GC count).
--
--   nvim --headless -u NONE -l tools/recsize.lua [corpus]   (default: libs)

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
pcall(vim.treesitter.language.add, 'lua')
package.path = repo .. '/tools/?.lua;' .. repo .. '/lua/?.lua;' .. repo .. '/lua/?/init.lua;' .. package.path
local bench = require 'bench'
local store = require 'cartograph.store'

local name = arg[1] or 'libs'

-- deep byte estimate of a value: strings by length, numbers 8B, tables = fields
-- + ~40B/table overhead (LuaJIT GCtab). Approximate but consistent across arrays.
local seen
local function bytes(v)
    local t = type(v)
    if t == 'string' then return #v + 17
    elseif t == 'number' then return 8
    elseif t == 'boolean' then return 0
    elseif t == 'table' then
        if seen[v] then return 0 end -- shared refs (folded stores) counted once
        seen[v] = true
        local s = 40
        for k, x in pairs(v) do
            s = s + (type(k) == 'string' and #k + 17 or 8) + bytes(x)
        end
        return s
    end
    return 8
end
local function arr_bytes(list)
    seen = {}
    local s = 0
    for _, v in ipairs(list or {}) do s = s + bytes(v) end
    return s
end

local data = bench.extract_parallel(name)
store.ingest(data)
local fold = store.topo() and store._fold

collectgarbage(); collectgarbage()
local heap = collectgarbage('count') * 1024

local nb = arr_bytes(store.data.nodes)
local eb = arr_bytes(store.data.edges)
local cb = arr_bytes(store.data.calls)
local csr = fold and (fold:bytes() + fold:string_bytes()) or 0

local function mb(x) return x / 1048576 end
print(('recsize %s — %d nodes / %d edges / %d calls'):format(name,
    #(store.data.nodes or {}), #(store.data.edges or {}), #(store.data.calls or {})))
print('  ── RAW RECORDS (deep estimate) ──')
print(('    node records:  %8.1f MB'):format(mb(nb)))
print(('    edge records:  %8.1f MB'):format(mb(eb)))
print(('    call records:  %8.1f MB'):format(mb(cb)))
print(('    records TOTAL: %8.1f MB'):format(mb(nb + eb + cb)))
print('  ── CSR FOLD (exact) ──')
print(('    topology CSR:  %8.1f MB'):format(mb(csr)))
print(('  ── store heap (GC, all-in incl. indexes + folded riders) ──'))
print(('    total heap:    %8.1f MB'):format(mb(heap)))
print(('  CSR is %.1f%% of the records it indexes; records are %.0fx the CSR')
    :format(csr > 0 and 100 * csr / (nb + eb + cb) or 0, csr > 0 and (nb + eb + cb) / csr or 0))
vim.cmd('qall!')
