-- LuaJIT's trace budgets for a BATCH process of ours (the extraction worker, toolbelt, the test runner). The defaults
-- (maxtrace=1000, maxmcode=512K) are too small for cartograph: the trace cache fills, flushes, and every hot loop
-- recompiles. NOT for an editor session: jit.opt is process-wide, and nvim is the user's process.
--   worker (parallel extraction): profiled at 15-17% of wall in the JIT; raising them measured -14% on server, -19% on
--     libs (J: 16.5% -> 2.2%).
--   one in-process extract + flowtype + lint of the 428-file corpus (2026-10-12): 247 flushes and ~295 K traces at
--     the defaults, 8 flushes and ~43 K traces here; 80.4-82.6 s -> 74.4-75.5 s, RSS +0-0.2 GB. maxmcode=16384: the
--     same flushes and time, more RSS. (cinterp.batch_tune goes further — 20000 traces, 256 MB, GC pause 400 — for the
--     interpreter gates; on this workload it bought ~5% more for +1.1-1.8 GB.)
-- CARTOGRAPH_JITTUNE=0 leaves LuaJIT's defaults: the A/B.
local M = {}

function M.batch()
    if vim.env.CARTOGRAPH_JITTUNE == '0' then return false end
    return (pcall(function () require('jit.opt').start('maxtrace=4000', 'maxmcode=8192') end))
end

return M
