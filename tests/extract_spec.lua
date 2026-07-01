-- Unit tests for the extract-function engine: live-in -> params, live-out ->
-- returns, generated text, the safety guards, and applying the plan to lines.

local extract = require 'cartograph.extract'

-- a small file with a clean local chain:
--   1 local function f(a, b)
--   2     local x = a + 1
--   3     local y = b + 2
--   4     local z = x + y
--   5     return z
--   6 end
local F = {
    'local function f(a, b)',
    '    local x = a + 1',
    '    local y = b + 2',
    '    local z = x + y',
    '    return z',
    'end',
}
-- df for f's body (statements at lines 2..5)
local function dep(from, var) return { from = from, var = var } end
local F_DF = { inputs = { 'a', 'b' }, stmts = {
    { l = 2, def = { 'x' }, use = { 'a' }, dep = {} },
    { l = 3, def = { 'y' }, use = { 'b' }, dep = {} },
    { l = 4, def = { 'z' }, use = { 'x', 'y' }, dep = { dep(1, 'x'), dep(2, 'y') } },
    { l = 5, def = {}, use = { 'z' }, dep = { dep(3, 'z') } },
} }

test('extract: live-in becomes params, live-out becomes returns', function ()
    local p = extract.plan { df = F_DF, sel = { first = 4, last = 4 }, fn_start = 1, body_end = 5,
                             file_lines = F, name = 'sum' }
    ok(p.ok, p.reason)
    eq({ 'x', 'y' }, p.params)   -- x,y defined before the selection -> params
    eq({ 'z' }, p.returns)       -- z defined here, used after -> return
    eq('    local z = sum(x, y)', p.call[1])
    eq({ 'local function sum(x, y)', '    local z = x + y', '    return z', 'end' }, p.new_fn)
end)

test('extract: apply splices in the new function and the call', function ()
    local p = extract.plan { df = F_DF, sel = { first = 4, last = 4 }, fn_start = 1, body_end = 5,
                             file_lines = F, name = 'sum' }
    local out = extract.apply(p, F)
    eq('local function sum(x, y)', out[1])
    eq('end', out[4])
    eq('', out[5])                       -- blank between new fn and f
    eq('local function f(a, b)', out[6])
    eq('    local z = sum(x, y)', out[9]) -- the call replaced the original line
    eq('    return z', out[10])
end)

test('extract: refuses a selection containing a control escape', function ()
    local p = extract.plan { df = F_DF, sel = { first = 4, last = 5 }, fn_start = 1, body_end = 5,
                             file_lines = F, name = 'x' }
    ok(not p.ok)
    ok(p.reason:match('return/break/goto'), p.reason)
end)

test('extract: refuses a selection that cuts a loop body', function ()
    -- one statement (a loop) spans lines 3..6; selecting 4..5 hits no boundary
    local loopdf = { inputs = {}, stmts = {
        { l = 2, def = { 'acc' }, use = {}, dep = {} },
        { l = 3, def = {}, use = { 'acc' }, dep = { dep(1, 'acc') } }, -- the loop, spans 3..6
        { l = 7, def = {}, use = { 'acc' }, dep = { dep(1, 'acc') } },
    } }
    local lines = { 'local function g()', '    local acc = {}', '    for i = 1, 10 do',
                    '        acc[i] = i', '        print(i)', '    end', '    return acc', 'end' }
    -- selecting the loop's start line through the middle of its body (3..5)
    -- lands on the loop statement's boundary but ends mid-body -> misaligned
    local p = extract.plan { df = loopdf, sel = { first = 3, last = 5 }, fn_start = 1, body_end = 7,
                             file_lines = lines, name = 'x' }
    ok(not p.ok)
    ok(p.reason:match('whole statements'), p.reason)
end)

test('extract: a side-effecting statement extracts with params and no returns', function ()
    local lines = { 'local function g()', '    local n = compute()', '    record(n)', 'end' }
    local df = { inputs = {}, stmts = {
        { l = 2, def = { 'n' }, use = {}, dep = {} },
        { l = 3, def = {}, use = { 'n' }, dep = { dep(1, 'n') } },
    } }
    local p = extract.plan { df = df, sel = { first = 3, last = 3 }, fn_start = 1, body_end = 3,
                             file_lines = lines, name = 'do_record' }
    ok(p.ok, p.reason)
    eq({ 'n' }, p.params)
    eq({}, p.returns)
    eq('    do_record(n)', p.call[1])
    ok(#p.hazards >= 1, 'non-local-state hazard disclosed')
end)
