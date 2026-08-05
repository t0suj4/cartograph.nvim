-- A RAISE IS A BEHAVIOUR (CART-0295).
--
-- Measured before building: 366 of 399 subjects that "produced no value" were RAISING on the
-- input we chose, and a function whose behaviour on that input is TO FAIL got no spec at all.
-- What is tested here is not that a message is recorded — it is that the recording is
-- REPRODUCIBLE (the `file:line` prefix stripped, a premise failure refused rather than
-- characterized) and that it asserts in BOTH directions, since a subject that STOPS raising
-- has changed as much as one that starts.

local ch = require 'cartograph.characterize'
local ro = require 'cartograph.runoracle'
local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'

local SRC = table.concat({
    'local M = {}',
    'function M.boom(p)',
    '    return p.a.b',
    'end',
    'function M.fine(n)',
    '    return n + 1',
    'end',
    'return M',
}, '\n') .. '\n'

local root
local function proj(src)
    root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/m.lua', 'w')); fd:write(src or SRC); fd:close()
    local data = ts.extract(root)
    data.root = data.root or root
    store.ingest(data)
    return root
end
local function cleanup() if root then vim.fn.delete(root, 'rf'); root = nil end end
local function id_of(name)
    for _, n in ipairs(store.data.nodes) do
        if n.name == name and (n.kind == 'function' or n.kind == 'method') then return n.id end
    end
end
local function ready()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    return pcall(vim.treesitter.language.add, 'lua')
end
local function oracle_of(plan)
    for _, h in ipairs(plan.holes) do if h.kind == 'oracle' then return h end end
end
local function raising_plan()
    local plan = assert(ch.plan(store, id_of('M.boom')))
    ch.fill(plan, { ['input:p'] = { value = '{ }', basis = 'an empty table', by = 'agent' } })
    return plan
end

test('raise: the subject RAISED, so the raise is what gets characterized', function ()
    if not ready() then skip('no lua parser') end
    proj()
    local plan = raising_plan()
    local n, why = ro.fill_oracle(store, plan)
    ok(n, 'the run reports a raise instead of refusing: ' .. tostring(why))
    local o = assert(oracle_of(plan))
    eq(true, o.raises, 'the row is FLAGGED — a raise and a returned string are not the same')
    ok(o.value:find('attempt to index', 1, true), 'the message is the value: ' .. o.value)
    -- NOT wrapped as a tuple: `n, { … }` would make it indistinguishable from a function
    -- that RETURNED that string.
    eq(0, o.n)
    cleanup()
end)

test('raise: the `file:line` prefix is STRIPPED, and the basis says so', function ()
    if not ready() then skip('no lua parser') end
    proj()
    local plan = raising_plan()
    assert(ro.fill_oracle(store, plan))
    local o = assert(oracle_of(plan))
    -- comparing the raw message would fail on any edit ABOVE the raising line — a false
    -- CHANGED, which teaches its reader to ignore failures
    ok(not o.value:find('m%.lua:%d'), 'no path:line in the expectation: ' .. o.value)
    ok(o.basis:find('STRIPPED', 1, true), 'and the strip is disclosed: ' .. o.basis)
    cleanup()
end)

test('GATE: the spec PASSES while the subject still raises', function ()
    if not ready() then skip('no lua parser') end
    proj()
    local plan = raising_plan()
    assert(ro.fill_oracle(store, plan))
    local ran, err = pcall(assert(load(table.concat(ch.emit(plan), '\n'), 'r')))
    ok(ran, 'the emitted spec passes: ' .. tostring(err))
    cleanup()
end)

test('raise: a subject that STOPS raising reports CHANGED', function ()
    if not ready() then skip('no lua parser') end
    local dir = proj()
    local plan = raising_plan()
    assert(ro.fill_oracle(store, plan))
    local src = table.concat(ch.emit(plan), '\n')

    -- THE OTHER DIRECTION, and it is the one a naive implementation misses: a spec that only
    -- checked the message would pass silently the day the function starts returning.
    local path = dir .. '/m.lua'
    local fd = assert(io.open(path, 'r')); local text = fd:read('*a'); fd:close()
    text = text:gsub('return p%.a%.b', 'return 7')
    fd = assert(io.open(path, 'w')); fd:write(text); fd:close()

    local okrun, err = pcall(assert(load(src, 'r2')))
    eq(false, okrun, 'the spec FAILS')
    ok(tostring(err):find('no longer raises', 1, true),
        'and says the subject stopped raising: ' .. tostring(err))
    cleanup()
end)

test('raise: a subject that STARTS raising also reports CHANGED', function ()
    if not ready() then skip('no lua parser') end
    local dir = proj()
    -- characterize the VALUE first
    local plan = assert(ch.plan(store, id_of('M.fine')))
    ch.fill(plan, { ['input:n'] = { value = '1', basis = 'one', by = 'agent' } })
    assert(ro.fill_oracle(store, plan))
    local src = table.concat(ch.emit(plan), '\n')
    ok(pcall(assert(load(src, 'v'))), 'passes while it returns')

    local path = dir .. '/m.lua'
    local fd = assert(io.open(path, 'r')); local text = fd:read('*a'); fd:close()
    text = text:gsub('return n %+ 1', 'return n.x.y')
    fd = assert(io.open(path, 'w')); fd:write(text); fd:close()

    -- BEFORE THIS, the subject's own error escaped the spec and read as a broken SPEC rather
    -- than as the behaviour change it is.
    local okrun, err = pcall(assert(load(src, 'v2')))
    eq(false, okrun)
    ok(tostring(err):find('RAISED', 1, true) and tostring(err):find('CHANGED', 1, true),
        'it fails AS a behaviour change: ' .. tostring(err))
    cleanup()
end)

test('raise: an unresolvable require is refused BEFORE running, by name', function ()
    if not ready() then skip('no lua parser') end
    -- A `module '…' not found` raise is a PREMISE failure — a re-emitted declaration or the
    -- aligned package path failing in a fresh process — and characterizing it would freeze OUR
    -- incomplete premise into a test. Its message is not even stable: Lua appends the searched
    -- paths, which differ per process, which is exactly how it surfaced (the probe's text and
    -- the spec's text disagreed, so the spec reported a false CHANGED on 2 corpus functions).
    --
    -- WHAT THIS PINS is the LAYERING: a fixture cannot even reach that guard, because the
    -- earlier layers refuse first and name the missing thing. The runtime guard in
    -- `runoracle.run` is defence in depth for what slips past them — reached in practice, not
    -- reachable from a fixture, and that ordering is the property worth holding.
    proj(table.concat({
        'local M = {}',
        'function M.needs(p) local u = require "no.such.module.here" return u ~= nil end',
        'return M',
    }, '\n') .. '\n')
    local plan = ch.plan(store, id_of('M.needs'))
    if plan then
        ch.fill(plan, { ['input:p'] = { value = '1', basis = 'one', by = 'agent' } })
        local n, why = ro.fill_oracle(store, plan)
        eq(nil, n, 'refused rather than characterized')
        ok(tostring(why):find('require', 1, true) or tostring(why):find('not found', 1, true),
            'and the refusal names what is missing rather than shrugging: ' .. tostring(why))
    end
    cleanup()
end)
