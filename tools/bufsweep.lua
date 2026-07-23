-- bufsweep — the BUFFERING sweep ([[cartograph-thin-index]]). The peak/IPC matrix showed the
-- parallel parent peak is RESIDENT-record-bound, not fold-transient-bound. Buffering is the
-- lever the fold strategies can't touch: how much un-merged work is resident MID-merge —
-- (a) worker CONCURRENCY (in-flight chunks) and (b) chunk BYTE-BUDGET (per-chunk transient).
-- Fewer workers / smaller chunks → lower transient (maybe lower peak) at a WALL cost. This
-- runs ONE config and reports peak + wall + IPC so a shell grid can sweep it in separate
-- processes (clean VmHWM per run).
--
--   nvim --headless -u NONE -l tools/bufsweep.lua <corpus> [workers] [maxKB] [minKB]
--     workers : cap on concurrent workers (0/omitted = default_workers())
--     maxKB   : M.MAX_BYTES override in KB (omitted = default 256)
--     minKB   : M.MIN_BYTES override in KB (omitted = default 8; set == maxKB for FIXED chunks)

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
pcall(vim.treesitter.language.add, 'lua')
package.path = repo .. '/tools/?.lua;' .. repo .. '/lua/?.lua;' .. repo .. '/lua/?/init.lua;' .. package.path
local bench = require 'bench'
local par = require 'cartograph.parallel'

local name = arg[1]
if not name then print('usage: bufsweep <corpus> [workers] [maxKB] [minKB]'); os.exit(2) end
local workers = tonumber(arg[2]) or 0
local maxkb = tonumber(arg[3])
local minkb = tonumber(arg[4])
if maxkb then par.MAX_BYTES = maxkb * 1024 end
if minkb then par.MIN_BYTES = minkb * 1024 end

local data, stats = bench.extract_parallel(name, { workers = workers > 0 and workers or nil })
local ipc = data._ipc_bytes and (data._ipc_bytes / 1e6) or nil

print(('bufsweep %s | workers=%-7s maxKB=%-4d minKB=%-4d | peak %6.2f GB  wall %6.1fs  IPC %s  nodes %d')
    :format(name,
        (workers > 0 and tostring(workers) or 'default'),
        (maxkb or 256), (minkb or 8),
        stats.peak / 1e9, stats.wall,
        ipc and ('%.0f MB'):format(ipc) or 'n/a',
        #(data.nodes or {})))
vim.cmd('qall!')
