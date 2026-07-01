-- Unit tests for the untangle lens: partitioning statements into independent
-- concerns and measuring interleaving. Pure; operates on a `df`-shaped table.

local untangle = require 'cartograph.untangle'

-- build a df from a list of {dep = {fromIdx, ...}} (only deps matter to analyze)
local function df(deplists)
    local stmts = {}
    for _, deps in ipairs(deplists) do
        local dep = {}
        for _, from in ipairs(deps) do dep[#dep + 1] = { from = from, var = 'x' } end
        stmts[#stmts + 1] = { l = #stmts + 1, def = {}, use = {}, dep = dep }
    end
    return { inputs = {}, stmts = stmts }
end

test('untangle: two interleaved chains -> 2 concerns, positive tangle', function ()
    -- #1 a, #2 x, #3 b<-a, #4 y<-x   => comps [A,B,A,B]
    local a = untangle.analyze(df { {}, {}, { 1 }, { 2 } })
    eq(2, a.ncomp)
    eq(3, a.switches)       -- A B A B  -> 3 switches
    eq(2, a.tangle)         -- excess over the minimal (ncomp-1 = 1)
    eq({ 0, 1, 0, 1 }, a.comp)
end)

test('untangle: the same two chains, grouped -> tangle 0', function ()
    -- #1 a, #2 b<-a, #3 x, #4 y<-x   => comps [A,A,B,B]
    local a = untangle.analyze(df { {}, { 1 }, {}, { 3 } })
    eq(2, a.ncomp)
    eq(1, a.switches)
    eq(0, a.tangle)         -- perfectly grouped
    eq({ 0, 0, 1, 1 }, a.comp)
end)

test('untangle: one linear chain -> single concern, no tangle', function ()
    local a = untangle.analyze(df { {}, { 1 }, { 2 }, { 3 } })
    eq(1, a.ncomp)
    eq(0, a.tangle)
    eq(1, a.maxspan)        -- each dep is one step back
end)

test('untangle: maxspan is the largest def->use statement distance', function ()
    -- #4 depends on #1  => span 3
    local a = untangle.analyze(df { {}, {}, {}, { 1 } })
    eq(3, a.maxspan)
end)

test('untangle: empty body is inert', function ()
    local a = untangle.analyze(nil)
    eq(0, a.ncomp)
    eq(0, a.tangle)
end)
