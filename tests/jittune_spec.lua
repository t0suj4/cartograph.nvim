-- jittune: LuaJIT's trace budgets for our batch processes, and the switch that leaves the defaults (the A/B)
local jittune = require 'cartograph.jittune'

test('jittune: a batch process gets the trace budgets; CARTOGRAPH_JITTUNE=0 leaves the defaults', function ()
    local saved = vim.env.CARTOGRAPH_JITTUNE
    vim.env.CARTOGRAPH_JITTUNE = '0'
    local off = jittune.batch()
    vim.env.CARTOGRAPH_JITTUNE = saved
    eq(false, off, 'the switch: nothing tuned')
    -- (the suite's own process is tuned by tests/run.lua already: tuning it again changes nothing)
    eq(true, jittune.batch(), 'tuned')
end)
