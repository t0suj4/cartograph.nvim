-- callcolsdecide — the callcols-DEFAULT-ON decision matrix ([[cartograph-thin-index]]).
-- callcols swaps the resident call RECORDS for columns + lightweight proxy ROWS (consumers
-- keep working via proxy __index — no migration needed). The decision: is the resident win
-- worth the proxy-dispatch cost at query time, and is the ingest cost acceptable? Measures,
-- for one corpus, callcols OFF vs ON: ingest wall, resident heap, and a CALL-FIELD-HEAVY
-- query wall (ladder.report — reads to/dynamic/refused/callee/file/line per call = the proxy
-- hot path). Correctness is gated separately (suite + gate --parallel with CARTOGRAPH_CALLCOLS=1).
--
--   nvim --headless -u NONE -l tools/callcolsdecide.lua [corpus]   (default: libs)

local repo = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.rtp:prepend(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
pcall(vim.treesitter.language.add, 'lua')
package.path = repo .. '/tools/?.lua;' .. repo .. '/lua/?.lua;' .. repo .. '/lua/?/init.lua;' .. package.path
local bench = require 'bench'
local store = require 'cartograph.store'
local config = require 'cartograph.config'
local ladder = require 'cartograph.ladder'

local name = arg[1] or 'libs'

local function run(callcols)
    local data = bench.extract(name) -- inline (ingest folds/consumes it)
    config.callcols_store = callcols
    collectgarbage(); collectgarbage()
    local t0 = vim.uv.hrtime()
    store.ingest(data)
    local ingest_ms = (vim.uv.hrtime() - t0) / 1e6
    if rawget(_G, 'jit') and jit.flush then jit.flush() end
    collectgarbage(); collectgarbage()
    local heap_mb = collectgarbage('count') / 1024
    -- query cost: ladder.report is call-field-heavy → exercises proxy dispatch. Median of 5.
    local walls = {}
    for k = 1, 5 do
        local q0 = vim.uv.hrtime()
        ladder.report(store)
        walls[k] = (vim.uv.hrtime() - q0) / 1e6
    end
    table.sort(walls)
    config.callcols_store = false
    return { ingest_ms = ingest_ms, heap_mb = heap_mb, query_ms = walls[3],
        ncalls = #(store.data.calls or {}) }
end

local off = run(false)
collectgarbage(); collectgarbage()
local on = run(true)

print(('callcolsdecide %s — %d calls'):format(name, off.ncalls))
print(('  %-4s  ingest %7.1f ms   resident %7.1f MB   query(ladder.report) %6.2f ms'):format('OFF', off.ingest_ms, off.heap_mb, off.query_ms))
print(('  %-4s  ingest %7.1f ms   resident %7.1f MB   query(ladder.report) %6.2f ms'):format('ON', on.ingest_ms, on.heap_mb, on.query_ms))
print(('  Δ     ingest %+6.1f%%          resident %+6.1f%%          query %+6.1f%%'):format(
    100 * (on.ingest_ms - off.ingest_ms) / off.ingest_ms,
    100 * (on.heap_mb - off.heap_mb) / off.heap_mb,
    100 * (on.query_ms - off.query_ms) / off.query_ms))
vim.cmd('qall!')
