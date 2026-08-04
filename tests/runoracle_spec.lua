-- FILL THE ORACLE BY RUNNING (CART-0263). The one place cartograph executes user code,
-- so what these pin is mostly the REFUSALS: which values cannot be characterized, which
-- functions must not be run, and that a second run changes nothing.
--
-- The positive cases are end-to-end on purpose — record the value, emit the spec, RUN the
-- spec — because that is the only check that the recorded value ROUND-TRIPS. A serializer
-- tested against itself proves nothing; a value the spec cannot reproduce would report
-- CHANGED on a subject that never changed, and the false alarm is indistinguishable from
-- the real one.

local ro = require 'cartograph.runoracle'
local ch = require 'cartograph.characterize'
local ts = require 'cartograph.providers.treesitter'
local store = require 'cartograph.store'

local SRC = table.concat({
    'local M = {}',                                            -- 1
    'function M.add(a, b) return a + b end',                    -- 2
    'function M.pair(a) return a, a * 2 end',                   -- 3
    'function M.tbl(n) return { n = n, tag = "t", l = { 1 } } end', -- 4
    'function M.fn() return function () end end',               -- 5
    'function M.nada() return nil end',                         -- 6
    'function M.void() local x = 1 end',                        -- 7
    'local COUNT = 0',                                          -- 8
    'function M.bump() COUNT = COUNT + 1 return COUNT end',     -- 9
    'function M.opens(p) local f = io.open(p, "r") return f ~= nil end', -- 10
    'return M',                                                 -- 11
}, '\n') .. '\n'

local root
local function proj()
    root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/m.lua', 'w')); fd:write(SRC); fd:close()
    local data = ts.extract(root); data.root = data.root or root
    store.ingest(data)
    return root
end
local function cleanup() if root then vim.fn.delete(root, 'rf'); root = nil end end
local function id_of(name)
    for _, n in ipairs(store.data.nodes) do
        if n.name == name and (n.kind == 'function' or n.kind == 'method') then return n.id end
    end
end
local function planned(name, fills)
    local p = assert(ch.plan(store, id_of(name)))
    if fills then assert(ch.fill(p, fills)) end
    return p
end
local function ready()
    local tsdir = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter')
    if vim.fn.isdirectory(tsdir) == 1 then vim.opt.rtp:append(tsdir) end
    return pcall(vim.treesitter.language.add, 'lua')
end
local function num(v) return { value = tostring(v), basis = 'a number', by = 'agent' } end

test('runoracle.serialize: refuses every value with no literal form', function ()
    -- THIS IS THE GATE that keeps an uncharacterizable value from being written as one.
    eq('nil', ro.serialize(nil))
    eq('true', ro.serialize(true))
    eq('7', ro.serialize(7))
    -- %q escapes a newline as backslash-NEWLINE (valid Lua, spans two lines), so the
    -- round trip is what to assert rather than the exact spelling
    eq('a\nb', assert(loadstring('return ' .. ro.serialize('a\nb')))(),
        'a string round-trips through %q, newline and all')
    eq('{ [1] = 1, x = "y" }', ro.serialize({ 1, x = 'y' }))
    -- DETERMINISTIC KEY ORDER, or one value serializes two ways and a re-run reads as a
    -- behaviour change: pairs() order is undefined between processes.
    eq(ro.serialize({ b = 1, a = 2, c = 3 }), ro.serialize({ c = 3, a = 2, b = 1 }))

    local _, w1 = ro.serialize(function () end)
    ok(w1 and w1:find('no value form', 1, true), 'a function: ' .. tostring(w1))
    local _, w2 = ro.serialize(0 / 0)
    ok(w2 and w2:find('NaN', 1, true), 'NaN: ' .. tostring(w2))
    local _, w3 = ro.serialize(math.huge)
    ok(w3 and w3:find('infinite', 1, true), 'infinity: ' .. tostring(w3))
    local cyc = {}; cyc.me = cyc
    local _, w4 = ro.serialize(cyc)
    ok(w4 and w4:find('CYCLIC', 1, true), 'a cycle: ' .. tostring(w4))
    local badkey = { [{}] = 1 }
    local _, w5 = ro.serialize(badkey)
    ok(w5 and w5:find('KEY', 1, true), 'a table key: ' .. tostring(w5))
    -- a float keeps full precision: tostring() would truncate and the spec would compare
    -- against a number it cannot reconstruct
    eq(0.1 + 0.2, assert(loadstring('return ' .. ro.serialize(0.1 + 0.2)))())
end)

test('runoracle: OUR OWN EFFECT ANALYSIS decides whether we may run it', function ()
    if not ready() then skip('no lua parser') end
    proj()
    -- pure: allowed
    local okp, label = ro.runnable(store, planned('M.add'))
    eq(true, okp, 'a pure function is runnable (' .. tostring(label) .. ')')

    -- writes module state: REFUSED, because filling an oracle must not mutate anything
    local okw, whyw = ro.runnable(store, planned('M.bump'))
    eq(nil, okw, 'a module-state writer is refused')
    ok(whyw:find('writes', 1, true), 'and says which label: ' .. tostring(whyw))

    -- touches the world: REFUSED, because running it would actually DO the io
    local oki, whyi = ro.runnable(store, planned('M.opens'))
    eq(nil, oki, 'an io function is refused: ' .. tostring(whyi))

    -- and the override is EXPLICIT, never a fallback
    eq(true, (ro.runnable(store, planned('M.bump'), { force = true })))
    local _, flabel = ro.runnable(store, planned('M.bump'), { force = true })
    ok(flabel:find('FORCED', 1, true), 'a forced run is LABELLED: ' .. tostring(flabel))
    cleanup()
end)

test('runoracle: a run needs its INPUTS first — a probe cannot run on a hole', function ()
    if not ready() then skip('no lua parser') end
    proj()
    local plan = planned('M.add')          -- no fills
    local res, why = ro.run(store, plan)
    eq(nil, res, 'running with an unfilled input is refused')
    ok(why:find('still a hole', 1, true), tostring(why))
    -- otherwise the spec's own HOLE error would surface as though the SUBJECT had failed
    ok(why:find('input:', 1, true), 'and names which: ' .. tostring(why))
    cleanup()
end)

test('runoracle: the observed value ROUND-TRIPS — record, emit, run', function ()
    if not ready() then skip('no lua parser') end
    proj()
    -- a scalar, a TUPLE and a TABLE: the three shapes that broke in development
    for _, case in ipairs({
        { 'M.add', { ['input:a'] = num(3), ['input:b'] = num(4) }, 1 },
        { 'M.pair', { ['input:a'] = num(5) }, 2 },
        { 'M.tbl', { ['input:n'] = num(9) }, 1 },
        { 'M.nada', {}, 1 },   -- `return nil` is ONE value, and select('#') is why we know
    }) do
        local plan = planned(case[1], case[2])
        local n, why = ro.fill_oracle(store, plan)
        ok(n and n > 0, case[1] .. ': the oracle is filled by running: ' .. tostring(why))
        local oracle
        for _, h in ipairs(plan.holes) do if h.kind == 'oracle' then oracle = h end end
        eq('measured', oracle.filled_tier, 'a RUN is measured evidence')
        eq('run', oracle.by)
        ok(oracle.basis:find('separate process', 1, true),
            'and the basis says how: ' .. tostring(oracle.basis))
        eq(case[3], oracle.n, case[1] .. ': the ARITY is recorded, not just the value')
        eq(0, plan.unfilled, case[1] .. ': nothing is left open')
        -- THE ROUND TRIP: the emitted spec must PASS against the same subject
        local okrun, err = pcall(assert(loadstring(
            table.concat(ch.emit(plan), '\n'), 's')))
        ok(okrun, case[1] .. ': the spec reproduces the recorded value: ' .. tostring(err))
    end
    cleanup()
end)

test('runoracle: a value with no literal form leaves the oracle a HOLE', function ()
    if not ready() then skip('no lua parser') end
    proj()
    local plan = planned('M.fn')
    local n, why = ro.fill_oracle(store, plan)
    eq(nil, n, 'a returned function cannot be characterized')
    ok(why:find('no value form', 1, true), 'with the reason: ' .. tostring(why))
    -- AND THE HOLE SURVIVES: refusing to record is not the same as recording nothing,
    -- and the spec must still fail rather than pass vacuously
    ok(plan.unfilled > 0, 'the oracle is still open')
    local _, rerr = pcall(assert(loadstring(table.concat(ch.emit(plan), '\n'), 's')))
    ok(tostring(rerr):find('HOLE:', 1, true), 'and the spec still errors: ' .. tostring(rerr))
    cleanup()
end)

test('runoracle: a function returning NOTHING has no oracle to fill', function ()
    if not ready() then skip('no lua parser') end
    proj()
    local plan = planned('M.void')
    local n, why = ro.fill_oracle(store, plan)
    eq(nil, n, 'there is nothing to observe')
    ok(why:find('EFFECTS', 1, true),
        'and the reason names what its behaviour IS: ' .. tostring(why))
    cleanup()
end)

test('runoracle: filling twice is IDEMPOTENT, and so is the write', function ()
    if not ready() then skip('no lua parser') end
    proj()
    local plan = planned('M.add', { ['input:a'] = num(3), ['input:b'] = num(4) })
    ok(ro.fill_oracle(store, plan) > 0, 'the first run records')
    local before = table.concat(ch.emit(plan), '\n')
    eq(0, ro.fill_oracle(store, plan), 'the second run records NOTHING new')
    eq(before, table.concat(ch.emit(plan), '\n'), 'and the spec is byte-identical')

    -- the WRITE is idempotent too: a journal entry per no-op would fill the undo stack
    -- with steps that undo nothing, which is how an undo stack stops being trustworthy
    local e1 = assert(ch.apply(store, plan))
    eq(nil, e1.unchanged, 'the first apply writes')
    local plan2 = planned('M.add', { ['input:a'] = num(3), ['input:b'] = num(4) })
    assert(ro.fill_oracle(store, plan2))
    local e2 = assert(ch.apply(store, plan2))
    eq(true, e2.unchanged, 'the second apply is a NO-OP, nothing journalled')
    cleanup()
end)

test('runoracle.determinism: two runs, and a disagreement is the subject\'s', function ()
    if not ready() then skip('no lua parser') end
    proj()
    local plan = planned('M.add', { ['input:a'] = num(3), ['input:b'] = num(4) })
    local stable, note = ro.determinism(store, plan)
    eq(true, stable, 'a pure function is stable: ' .. tostring(note))
    ok(note:find('two runs', 1, true), tostring(note))
    -- A nondeterministic subject is NOT a failure of this tool: a characterization spec
    -- for one fails at random and teaches its reader to ignore failures, so the answer is
    -- false + the two values, and the driver refuses to record.
    cleanup()
end)

-- ── THE EXECUTION BUDGET (user steer, 2026-08-04) ───────────────────────────
-- Running someone else's code without a budget means a subject that loops forever hangs
-- the run, and the first cut had NO timeout at all. Two mechanisms, because each is blind
-- to what the other catches — and the instruction half needed a measurement to work at
-- all (see the probe prologue: LuaJIT count hooks do not fire inside a compiled trace).

local BSRC = table.concat({
    'local M = {}',
    'function M.busy(n) local t = 0 for i = 1, n do t = t + i end return t end',
    'function M.spin(n) local t = 0 while true do t = t + n end return t end',
    'function M.chatty(n) for i = 1, n do print("xxxxxxxxxxxxxxxxxxxxxxxx") end return n end',
    'return M',
}, '\n') .. '\n'

local function bproj()
    root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/m.lua', 'w')); fd:write(BSRC); fd:close()
    local data = ts.extract(root); data.root = data.root or root
    store.ingest(data)
end

test('budget: the INSTRUCTION limit is deterministic, and it reports the cost', function ()
    if not ready() then skip('no lua parser') end
    bproj()
    -- a cheap call succeeds AND reports what it cost, which is the only evidence anyone
    -- has for choosing a budget
    local cheap = planned('M.busy', { ['input:n'] = num(100) })
    local res = assert(ro.run(store, cheap))
    -- COUNTED, and 0 means "below the hook granularity" rather than "free" — the basis
    -- spells that out rather than printing a bare 0, which would read as no cost at all
    ok(res.cost ~= nil, 'a successful run reports its instruction count')
    local oracle
    assert(ro.fill_oracle(store, cheap))
    for _, h in ipairs(cheap.holes) do if h.kind == 'oracle' then oracle = h end end
    ok(oracle.basis:find('Lua VM instructions', 1, true),
        'and the COST rides in the recorded basis, which is the only evidence anyone has'
        .. ' for choosing a budget: ' .. tostring(oracle.basis))

    -- and an expensive one is STOPPED by the count, not by the clock: same subject, same
    -- point, every machine. That determinism is why this half exists at all — a
    -- load-dependent limit would make the RECORDING flaky, and recording reproducible
    -- values is the whole job.
    local heavy = planned('M.busy', { ['input:n'] = num(50000000) })
    local r2, why = ro.run(store, heavy, { budget = { instructions = 200000, ms = 30000 } })
    eq(nil, r2, 'the instruction budget stops it')
    ok(why:find('INSTRUCTION budget', 1, true), tostring(why))
    ok(why:find('DETERMINISTIC', 1, true), 'and says which kind of limit it is')
    cleanup()
end)

test('budget: the WALL CLOCK catches what the hook cannot see', function ()
    if not ready() then skip('no lua parser') end
    bproj()
    -- an infinite loop with a huge instruction budget: only the clock can end this, and
    -- before the budget existed at all this call hung forever (vim.fn.system has no
    -- deadline, which is why the runner is vim.system now).
    local plan = planned('M.spin', { ['input:n'] = num(1) })
    local res, why = ro.run(store, plan,
        { budget = { instructions = 1e12, ms = 700 } })
    eq(nil, res, 'the wall clock stops it')
    ok(why:find('was KILLED', 1, true), tostring(why))
    ok(why:find('load%-dependent'),
        'and DISCLOSES that this half is load-dependent, unlike the instruction count')
    cleanup()
end)

test('budget: a subject that floods output is bounded too', function ()
    if not ready() then skip('no lua parser') end
    bproj()
    local plan = planned('M.chatty', { ['input:n'] = num(4000) })
    -- FORCED, and the reason is a pleasing cross-check: a function that prints IS an `io`
    -- function, so the effect gate refuses it before the output budget can ever fire. The
    -- two fences are independent and the earlier one is the effect analysis.
    local res, why = ro.run(store, plan,
        { force = true, budget = { output_kb = 1, ms = 20000 } })
    eq(nil, res, 'the output cap stops the capture')
    ok(why:find('OUTPUT budget', 1, true), tostring(why))
    -- and it is honest about WHAT it bounds: memory, not time
    ok(why:find('memory is what this bounds', 1, true), tostring(why))
    cleanup()
end)
