-- fatguard — the FAT-RECORD migration meter (leaping the wall, [[cartograph-thin-index]]).
-- Goal: migrate the pipeline OFF fat df/flow records (n.df/n.flow record tables with raw
-- strings) onto the folded/columnar form. This tracks the surface:
--   PRE-INGEST fat = the record tables the extraction PRODUCES (the P3 target — fold at
--     production so these are never built).
--   POST-INGEST fat = MUST be 0 — df.fold/flow.fold collapse them to _df/_flow columns
--     (a folded node has n._df set and n.df == nil). A non-zero here = a fold seam leak.
-- As the migration lands (readers on dual-mode accessors → fold moved to production), the
-- PRE-INGEST count drops toward 0.
--
--   nvim --headless -u NONE -l tools/fatguard.lua <corpus>

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
pcall(vim.treesitter.language.add, 'lua')
package.path = repo .. '/tools/?.lua;' .. repo .. '/lua/?.lua;' .. repo .. '/lua/?/init.lua;' .. package.path
local bench = require 'bench'
local store = require 'cartograph.store'

local name = arg[1]
if not name then print('usage: fatguard <corpus>'); os.exit(2) end

local function count(data)
    local fat_df, fat_flow, folded_df, folded_flow = 0, 0, 0, 0
    for _, n in ipairs(data.nodes or {}) do
        if n.df then fat_df = fat_df + 1 end
        if n.flow then fat_flow = fat_flow + 1 end
        if n._df then folded_df = folded_df + 1 end
        if n._flow then folded_flow = folded_flow + 1 end
    end
    return fat_df, fat_flow, folded_df, folded_flow
end

local data = bench.extract(name)
if data._callstore then data.calls = require('cartograph.rescols').materialize(data._callstore) end
local pdf, pflow = count(data)
print(('fatguard %s — %d nodes'):format(name, #(data.nodes or {})))
print(('  PRE-INGEST fat records (the P3 target — extraction builds these): df %d · flow %d')
    :format(pdf, pflow))

store.ingest(data)
local qdf, qflow, foldf, folflow = count(store.data)
print(('  POST-INGEST: fat df %d · fat flow %d   folded _df %d · _flow %d  <- fat MUST be 0')
    :format(qdf, qflow, foldf, folflow))

if qdf > 0 or qflow > 0 then
    print('FAIL: fat records survive ingest — a fold seam leak')
    vim.cmd('cquit 1')
else
    print('OK — post-ingest is fully folded; PRE-INGEST fat is the remaining migration surface (P3: fold at production)')
    vim.cmd('qall!')
end
