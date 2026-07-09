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
    ok(p.reason:match('starts or ends inside'), p.reason)
end)

test('extract: a selection nested inside a block explains the top-level limit', function ()
    -- lines 4..5 sit inside the loop body; no top-level statement starts there
    local loopdf = { inputs = {}, stmts = {
        { l = 2, def = { 'acc' }, use = {}, dep = {} },
        { l = 3, def = {}, use = { 'acc' }, dep = { dep(1, 'acc') } }, -- loop, spans 3..6
        { l = 7, def = {}, use = { 'acc' }, dep = { dep(1, 'acc') } },
    } }
    local lines = { 'local function g()', '    local acc = {}', '    for i = 1, 10 do',
                    '        acc[i] = i', '        munge(acc)', '    end', '    return acc', 'end' }
    local p = extract.plan { df = loopdf, sel = { first = 4, last = 5 }, fn_start = 1, body_end = 7,
                             file_lines = lines, name = 'x' }
    ok(not p.ok)
    ok(p.reason:match('nested inside'), p.reason)
    ok(p.reason:match('TOP.LEVEL'), p.reason)
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

-- SHADOW SAFETY (scope-model): `x` has two binders — an inner one whose
-- do-block is the selection (decl row 2, 0-based) and an outer one after
-- it (decl row 5). The name-keyed dep invents a return of x.
--   1 local function f(a)
--   2     do                  ← selection 2..5
--   3         local x = a * 2
--   4         g(x)
--   5     end
--   6     local x = a + 1
--   7     h(x)
--   8 end
local S = {
    'local function f(a)',
    '    do',
    '        local x = a * 2',
    '        g(x)',
    '    end',
    '    local x = a + 1',
    '    h(x)',
    'end',
}
local S_DF = { inputs = { 'a' }, stmts = {
    { l = 2, def = { 'x' }, use = { 'a' }, dep = {}, defr = { 2 } },
    { l = 6, def = { 'x' }, use = { 'a' }, dep = {}, defr = { 5 } },
    { l = 7, def = {}, use = { 'x' }, dep = { dep(1, 'x') } }, -- FALSE dep
} }

test('extract shadow: without a resolver, a shadowed return REFUSES', function ()
    local p = extract.plan { df = S_DF, sel = { first = 2, last = 5 },
        fn_start = 1, body_end = 7, file_lines = S, name = 'f2' }
    ok(not p.ok)
    ok(p.reason:match('shadowed'), p.reason)
end)

test('extract shadow: the resolver attributes the use and DROPS the false return', function ()
    local p = extract.plan { df = S_DF, sel = { first = 2, last = 5 },
        fn_start = 1, body_end = 7, file_lines = S, name = 'f2',
        resolve_binder = function (nm, row0)
            eq('x', nm)
            eq(6, row0)          -- the h(x) row, 0-based
            return { row = 5 }   -- the OUTER binder
        end }
    ok(p.ok, p.reason)
    eq({}, p.returns)            -- no junk `local x = f2(...)`
    eq('    f2()', p.call[1])
end)

test('extract shadow: a use matching an in-selection binder KEEPS the return', function ()
    -- select the OUTER decl (line 6); craft the dep to point at it
    local df2 = { inputs = { 'a' }, stmts = {
        { l = 2, def = { 'x' }, use = { 'a' }, dep = {}, defr = { 2 } },
        { l = 6, def = { 'x' }, use = { 'a' }, dep = {}, defr = { 5 } },
        { l = 7, def = {}, use = { 'x' }, dep = { dep(2, 'x') } },
    } }
    local p = extract.plan { df = df2, sel = { first = 6, last = 6 },
        fn_start = 1, body_end = 7, file_lines = S, name = 'f2',
        resolve_binder = function () return { row = 5 } end }
    ok(p.ok, p.reason)
    eq({ 'x' }, p.returns)
    eq('    local x = f2()', p.call[1])
end)

test('extract shadow: unattributable use refuses rather than guess', function ()
    local p = extract.plan { df = S_DF, sel = { first = 2, last = 5 },
        fn_start = 1, body_end = 7, file_lines = S, name = 'f2',
        resolve_binder = function () return nil end }
    ok(not p.ok)
    ok(p.reason:match('could not be attributed'), p.reason)
end)
