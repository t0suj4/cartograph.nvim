-- Extract-function APPLY: the txn face of the pure extract engine. The engine
-- itself is pinned by extract_spec; what these tests pin is the LAST MILE that
-- was missing (CART-0125) — a computed extraction becomes a REVIEWABLE
-- transaction, and the write goes through txn.lua's ladder instead of straight
-- to disk. Two properties matter most and are asserted directly:
--   · the staged diff is the PURE engine's splice (one implementation, so the
--     dry-run and the applied bytes cannot diverge from extract_spec's answers)
--   · the plan REFUSES on the same grounds the engine does, and refuses again
--     at apply time when the file moved under it (the CAS the old path lacked)

local ea = require 'cartograph.extractapply'
local extract = require 'cartograph.extract'
local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'

-- f's body is a clean local chain; g holds a loop, so a selection cutting into
-- it must be refused; h has a shadowed name.
local SRC = table.concat({
    'local M = {}',                        -- 1
    '',                                    -- 2
    'local function f(a, b)',               -- 3
    '    local x = a + 1',                  -- 4
    '    local y = b + 2',                  -- 5
    '    local z = x + y',                  -- 6
    '    return z',                         -- 7
    'end',                                  -- 8
    '',                                     -- 9
    'local function g(n)',                  -- 10
    '    local t = 0',                      -- 11
    '    for i = 1, n do',                  -- 12
    '        t = t + i',                     -- 13
    '    end',                               -- 14
    '    return t',                          -- 15
    'end',                                   -- 16
    '',                                      -- 17
    'M.f, M.g = f, g',                        -- 18
    'return M',                               -- 19
}, '\n') .. '\n'

local root
local function proj(src)
    root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/m.lua', 'w')); fd:write(src or SRC); fd:close()
    store.ingest(ts.extract(root))
    return root
end
local function cleanup() if root then vim.fn.delete(root, 'rf'); root = nil end end
local function id_of(name)
    for _, n in ipairs(store.data.nodes) do
        if n.name == name and (n.kind == 'function' or n.kind == 'method') then return n.id end
    end
end

test('extractapply: a clean selection stages a transaction (nothing written yet)', function ()
    proj()
    -- line 6 is `local z = x + y`: x,y live in, z live out
    local plan, why = ea.plan(store, id_of('f'), { first = 6, last = 6 }, 'sum')
    ok(plan, 'a whole top-level statement is extractable: ' .. tostring(why))
    if plan then
        eq('extract-fn', plan.verb)
        eq({ 'x', 'y' }, plan.params)
        eq({ 'z' }, plan.returns)
        eq({ 'm.lua' }, plan.touched)
        ok(plan.stamps['m.lua'], 'the file stamp is captured for the apply-time CAS')
        ok(plan.ref, 'the fn ref is captured for the witness check')
        -- STAGED, not written: the file on disk is byte-identical
        local fd = assert(io.open(root .. '/m.lua')); local now = fd:read('a'); fd:close()
        eq(SRC, now)
        -- and the diff is exactly the pure engine's splice
        local _, after = ea.preview(store, plan)
        eq(table.concat(extract.apply(plan, vim.split(SRC, '\n', { plain = true })), '\n'),
            after['m.lua'])
        ok(after['m.lua']:find('local function sum(x, y)', 1, true), 'the helper is spliced in')
        ok(after['m.lua']:find('local z = sum(x, y)', 1, true), 'the call replaces the statement')
    end
    cleanup()
end)

test('extractapply: apply writes through the journal and the result parses', function ()
    proj()
    local plan = assert(ea.plan(store, id_of('f'), { first = 6, last = 6 }, 'sum'))
    local entry, err = ea.apply(store, plan)
    ok(entry, 'the apply succeeds: ' .. tostring(err))
    if entry then
        local fd = assert(io.open(root .. '/m.lua')); local now = fd:read('a'); fd:close()
        ok(now:find('local function sum(x, y)', 1, true), 'the helper landed on disk')
        local pr = vim.treesitter.get_string_parser(now, 'lua'):parse()[1]:root()
        ok(not pr:has_error(), 'the written file parses clean')
        -- journalled = undoable, which the old writefile path could never be
        local js = require('cartograph.journal').list(root)
        ok(#js > 0 and js[#js].files['m.lua'], 'the edit is in the journal')
    end
    cleanup()
end)

test('extractapply: a file changed since planning is REFUSED at apply (the CAS)', function ()
    proj()
    local plan = assert(ea.plan(store, id_of('f'), { first = 6, last = 6 }, 'sum'))
    -- somebody else edits the file after the plan was computed. The old
    -- vim.fn.writefile path clobbered this silently.
    local fd = assert(io.open(root .. '/m.lua', 'a')); fd:write('-- touched\n'); fd:close()
    local entry, why = ea.apply(store, plan)
    ok(not entry and tostring(why):find('changed on disk'),
        'the stale plan is refused, naming the reason: ' .. tostring(why))
    cleanup()
end)

test('extractapply: the engine\'s refusals pass through verbatim', function ()
    proj()
    -- inside g's loop body: not a top-level statement of g
    local p1, w1 = ea.plan(store, id_of('g'), { first = 13, last = 13 }, 'acc')
    ok(not p1 and w1:find('nested inside a loop or branch'),
        'a nested selection is refused: ' .. tostring(w1))
    -- a control escape
    local p2, w2 = ea.plan(store, id_of('g'), { first = 15, last = 15 }, 'ret')
    ok(not p2 and w2:find('return/break/goto'),
        'a control escape is refused: ' .. tostring(w2))
    -- a bad helper name never reaches the engine
    local p3, w3 = ea.plan(store, id_of('f'), { first = 6, last = 6 }, 'not an ident')
    ok(not p3 and w3:find('identifier'), 'a non-identifier name is refused')
    cleanup()
end)

-- ── the report handles: a letter IS the user's grip on a comp id ─────────────

test('extractapply: comp_of accepts the letter the report prints, or a number', function ()
    eq(0, ea.comp_of('A'))
    eq(1, ea.comp_of('b'))       -- the sub-group listing lowercases; accept both
    eq(3, ea.comp_of(3))
    eq(3, ea.comp_of('3'))
    eq(nil, ea.comp_of('AB'))
    eq(nil, ea.comp_of(''))
    eq(nil, ea.comp_of(nil))
    eq('A', ea.letter(0))
    eq('C', ea.letter(2))
end)

-- Two INDEPENDENT concerns in one body: the (a) chain and the (b) chain, each
-- ending in a write to a different module field. A shared `return a2, b2` would
-- couple them into one concern — the untangle analysis is right about that, so
-- the fixture avoids it deliberately.
local TWO = table.concat({
    'local M = {}',                      -- 1
    '',                                  -- 2
    'local function two(p, q)',           -- 3
    '    local a1 = p + 1',               -- 4
    '    local a2 = a1 * 2',              -- 5
    '    M.a = a2',                       -- 6
    '    local b1 = q + 1',               -- 7
    '    local b2 = b1 * 2',              -- 8
    '    M.b = b2',                       -- 9
    'end',                                -- 10
    '',                                   -- 11
    'M.two = two',                        -- 12
    'return M',                           -- 13
}, '\n') .. '\n'

test('extractapply: plan_concern stages the concern :CartographUntangle lists', function ()
    proj(TWO)
    local un = require 'cartograph.untangle'
    local id = id_of('two')
    -- the report is where the letter comes from, so assert it really lists two
    -- (a one-concern answer would silently turn this test into a no-op)
    ok((un.report(store, id)[1] or ''):find('2 concern'),
        'the fixture has two concerns: ' .. tostring(un.report(store, id)[1]))
    local plan, why = ea.plan_concern(store, id, 'A', 'part_a')
    ok(plan, 'concern A stages: ' .. tostring(why))
    if plan then
        eq('extract-fn', plan.verb)
        eq('part_a', plan.name)
        eq('concern A of two', plan.how)
        local _, after = ea.preview(store, plan)
        ok(after['m.lua']:find('local function part_a(p)', 1, true),
            'the concern became a helper taking the param it reads')
        ok(after['m.lua']:find('    part_a(p)', 1, true), 'and the call passes it')
        local pr = vim.treesitter.get_string_parser(after['m.lua'], 'lua'):parse()[1]:root()
        ok(not pr:has_error(), 'the staged result parses')
    end
    -- concern B is the other chain, and reads the OTHER param
    local pb = ea.plan_concern(store, id, 'B', 'part_b')
    ok(pb and pb.params[1] == 'q', 'concern B takes q')
    -- a letter past the end is named, not silently ignored
    local pz, wz = ea.plan_concern(store, id, 'Z', 'nope')
    ok(not pz and wz:find('concern'), 'an out-of-range letter is refused: ' .. tostring(wz))
    cleanup()
end)

-- ── the capture bug, end to end (CART-0125) ─────────────────────────────────
-- extract_spec pins this against a hand-built df; this pins it through the REAL
-- pipeline, because the fix depends on the store actually carrying the param
-- list to the engine (flow.record's `params`, node.params as the fallback).

test('extractapply: an enclosing param the selection reads is PASSED, not captured', function ()
    proj(TWO)
    local id = id_of('two')
    -- line 4 is `local a1 = p + 1` — `p` is two's parameter
    local plan, why = ea.plan(store, id, { first = 4, last = 4 }, 'bump')
    ok(plan, 'stages: ' .. tostring(why))
    if plan then
        eq({ 'p' }, plan.params)   -- was {} before the fix → `bump()` read a nil global
        local _, after = ea.preview(store, plan)
        ok(after['m.lua']:find('local function bump(p)', 1, true), 'the helper takes p')
        ok(after['m.lua']:find('    local a1 = bump(p)', 1, true), 'the call passes p')
        -- the real proof: the spliced module still RUNS and computes the same thing
        local fn = assert(loadstring or load)(after['m.lua'])
        local mod = fn()
        mod.two(1, 10)
        eq(4, mod.a)    -- (1+1)*2
        eq(22, mod.b)   -- (10+1)*2
    end
    cleanup()
end)

test('extractapply: a PARAMETERLESS enclosing fn still extracts (none ≠ unknown)', function ()
    -- the param list comes from flow (`{}` here), NOT node.params, which is nil
    -- for a parameterless function and so cannot tell "none" from "not recorded".
    -- Using it as a fallback would hand extract.plan a {} it never asked for.
    proj(table.concat({
        'local M = {}', '',
        'local function noargs()',
        '    local t = {}',
        '    local n = 0',
        '    M.t, M.n = t, n',
        'end', '',
        'M.noargs = noargs', 'return M',
    }, '\n') .. '\n')
    local id = id_of('noargs')
    ok(store.node(id).params == nil, 'the node records no param list at all')
    local plan, why = ea.plan(store, id, { first = 4, last = 4 }, 'mk')
    ok(plan, 'a parameterless enclosing fn is not mistaken for an unasked one: ' .. tostring(why))
    if plan then eq({}, plan.params) end
    cleanup()
end)

test('extractapply: a selection reading the enclosing vararg is refused', function ()
    proj(table.concat({
        'local M = {}', '',
        'local function va(fmt, ...)',
        '    local n = select("#", ...)',
        '    M.s = fmt .. tostring(n)',
        'end', '',
        'M.va = va', 'return M',
    }, '\n') .. '\n')
    local plan, why = ea.plan(store, id_of('va'), { first = 4, last = 4 }, 'count')
    ok(not plan and tostring(why):find('%.%.%.'),
        'the vararg read is refused: ' .. tostring(why))
    cleanup()
end)

test('extractapply: a non-function focus is refused before any analysis', function ()
    proj()
    local mid
    for _, n in ipairs(store.data.nodes) do if n.kind == 'module' then mid = n.id break end end
    local p1, w1 = ea.plan(store, mid, { first = 6, last = 6 }, 'sum')
    ok(not p1 and w1:find('not a function'), 'a module node is refused')
    local p2, w2 = ea.plan(store, 'nope-no-such-id', { first = 1, last = 1 }, 'sum')
    ok(not p2 and w2:find('no such node'), 'an unknown id is refused')
    cleanup()
end)
