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
    'function M.editor() return vim.fn.tempname() end',         -- 11
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

    -- THE LINE IS CONTAINMENT, NOT PURITY (CART-0277). A separate process contains
    -- anything process-LOCAL, so a module-state write is safe AND reproducible in it —
    -- measured, `M.bump` returns 1 on three separate runs because each is a FIRST call.
    -- So it is allowed, and the recorded basis carries that premise: allowing a label
    -- without emitting its premise would be a promise made and broken in one breath.
    local okw, labelw = ro.runnable(store, planned('M.bump'))
    eq(true, okw, 'a module-state writer is runnable in a fresh process (' ..
        tostring(labelw) .. ')')
    local wplan = planned('M.bump')
    assert(ro.fill_oracle(store, wplan))
    local worac
    for _, h in ipairs(wplan.holes) do if h.kind == 'oracle' then worac = h end end
    eq('1', worac.raw_value, 'and the value is the FIRST call: ' .. tostring(worac.raw_value))
    ok(worac.basis:find('FIRST call', 1, true),
        'with the premise disclosed: ' .. tostring(worac.basis))

    -- touches the world with a channel we CANNOT fake: still refused, because running it
    -- would actually do the io. `M.opens` calls io.open, which IS injectable — so what is
    -- pinned here is that the label alone no longer decides; the CHANNELS do.
    local oplan = planned('M.opens')
    ok(oplan.sandbox and oplan.sandbox['io.open'],
        'io.open is derived as an injectable channel')

    -- AN io CHANNEL WE CANNOT FAKE IS STILL REFUSED, which is the honest narrowing:
    -- "refuse io" became "refuse UNKNOWN io". `vim.fn.*` is world in the effect vocabulary
    -- and is not in the injectable roster, so the sandbox would have a hole in it — and a
    -- sandbox with a hole LOOKS contained and is not.
    local eplan = planned('M.editor')
    local oke, whye = ro.runnable(store, eplan)
    eq(nil, oke, 'an un-injectable channel is refused')
    ok(whye:find('cannot inject', 1, true) or whye:find('io', 1, true),
        'and names it: ' .. tostring(whye))

    -- and the override is EXPLICIT, never a fallback, and LABELLED so a spec built on it
    -- discloses that we ran something our own analysis had flagged
    local okf, flabel = ro.runnable(store, planned('M.editor'), { force = true })
    eq(true, okf)
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
    -- M.void returns nothing AND touches no channel we can inject, so there is genuinely
    -- nothing to observe — and the reason says WHICH of the two is missing rather than
    -- shrugging at the whole question.
    local plan = planned('M.void')
    local n, why = ro.fill_oracle(store, plan)
    eq(nil, n, 'there is nothing to observe')
    ok(why:find('touches no channel we can inject', 1, true),
        'and the reason names what is missing: ' .. tostring(why))
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

-- ── THE SANDBOX (CART-0277, user: "can't we just inject our own functions?") ──
-- The io refusal was safe and poor: it excluded exactly the population a refactor most
-- needs a witness for. So inject instead — and the containment claims are proved by
-- CHECKING THE WORLD, not by reading the roster.

local SSRC = table.concat({
    'local M = {}',
    'function M.save(p, s) local f = io.open(p, "w") if f then f:write(s) f:close() end return p end',
    'function M.log(msg) print("[log] " .. msg) end',
    'function M.shell(c) return os.execute(c) end',
    'function M.env(k) return os.getenv(k) or "unset" end',
    'return M',
}, '\n') .. '\n'

local function sproj()
    root = vim.fn.tempname(); vim.fn.mkdir(root, 'p')
    local fd = assert(io.open(root .. '/m.lua', 'w')); fd:write(SSRC); fd:close()
    local data = ts.extract(root); data.root = data.root or root
    store.ingest(data)
end
local function hole(plan, kind)
    for _, h in ipairs(plan.holes) do if h.kind == kind then return h end end
end

test('sandbox: the effect is RECORDED and the world is not touched', function ()
    if not ready() then skip('no lua parser') end
    sproj()
    local victim = '/tmp/cartograph-sandbox-must-not-exist'
    vim.fn.delete(victim)
    local plan = planned('M.save', {
        ['input:p'] = { value = ('%q'):format(victim), basis = 'a path', by = 'agent' },
        ['input:s'] = { value = '"hi"', basis = 'content', by = 'agent' } })
    ok(plan.sandbox and plan.sandbox['io.open'],
        'io.open is derived from the effect vocabulary as an injectable channel')
    assert(ro.fill_oracle(store, plan))
    -- THE CONTAINMENT PROOF is the filesystem, not the roster
    eq(0, vim.fn.filereadable(victim), 'the file was NOT created')
    local eff = hole(plan, 'effects')
    ok(eff and eff.value:find('io.open', 1, true),
        'and the call is RECORDED: ' .. tostring(eff and eff.value))
    ok(eff.value:find(victim, 1, true), 'with its arguments')
    -- A FAKE IS A SUPPLIED PREMISE: the basis has to say the value came from our stubs,
    -- or an observation of a fabricated world reads as an observation of the real one.
    ok(eff.basis:find('SANDBOX', 1, true), 'disclosed: ' .. tostring(eff.basis))
    cleanup()
end)

test('sandbox: a function returning NOTHING is characterized by its CALL LOG', function ()
    if not ready() then skip('no lua parser') end
    sproj()
    -- THE REAL PRIZE. This population used to emit "no oracle … which this spec does not
    -- observe" — true, and silence where a hole belongs.
    local plan = planned('M.log',
        { ['input:msg'] = { value = '"hello"', basis = 'any string', by = 'agent' } })
    eq(nil, hole(plan, 'oracle'), 'it returns nothing, so there is no oracle hole')
    local eff = hole(plan, 'effects')
    ok(eff, 'but there IS an effects hole — its behaviour is what it DOES')
    assert(ro.fill_oracle(store, plan))
    eq('run', eff.by)
    -- CLAIM, not measured: the log was observed THROUGH our declared fake `print`, so it is
    -- only as strong as that fake (see the weakest-link test below). The channel still says
    -- `run`, because it was one.
    eq('claim', eff.filled_tier)
    ok(eff.value:find('%[log%] hello'), 'the log carries the call: ' .. tostring(eff.value))
    eq(0, plan.unfilled, 'and nothing is left open')
    -- and the spec REPRODUCES it, which is the only real check: the spec must install the
    -- SAME sandbox or it cannot see the same log
    local okrun, err = pcall(assert(loadstring(table.concat(ch.emit(plan), '\n'), 's')))
    ok(okrun, 'the spec reproduces the recorded log: ' .. tostring(err))
    cleanup()
end)

test('sandbox: a NONDETERMINISTIC channel is injected too', function ()
    if not ready() then skip('no lua parser') end
    sproj()
    -- FOUND BY DRIVING IT: the effect vocabulary calls os.getenv pure-but-NONDET, so an
    -- io-only filter passed it through and the run recorded this machine's real $HOME — a
    -- value that fails on anyone else's machine. Nondeterminism is as fatal to a recorded
    -- value as a side effect is to the world, and the purity LABEL cannot see it either.
    local plan = planned('M.env',
        { ['input:k'] = { value = '"HOME"', basis = 'a real variable', by = 'agent' } })
    ok(plan.sandbox and plan.sandbox['os.getenv'], 'os.getenv is injected')
    assert(ro.fill_oracle(store, plan))
    local o = hole(plan, 'oracle')
    eq('"unset"', o.raw_value,
        'the recorded value is the DECLARED fake, not this machine: ' .. tostring(o.raw_value))
    cleanup()
end)

test('sandbox: os.execute is recorded, never performed', function ()
    if not ready() then skip('no lua parser') end
    sproj()
    local plan = planned('M.shell',
        { ['input:c'] = { value = '"rm -rf /nope"', basis = 'a destructive command',
            by = 'agent' } })
    assert(ro.fill_oracle(store, plan))
    local eff = hole(plan, 'effects')
    ok(eff.value:find('rm %-rf /nope'), 'the command is RECORDED: ' .. tostring(eff.value))
    local o = hole(plan, 'oracle')
    ok(o.raw_value:find('sandboxed', 1, true),
        'and the return is the declared fake: ' .. tostring(o.raw_value))
    cleanup()
end)

test('sandbox: it RESTORES what it replaced, so it cannot outlive its subject', function ()
    if not ready() then skip('no lua parser') end
    sproj()
    -- FOUND BY DRIVING IT: `print` is io in the vocabulary, so the sandbox faked it — and
    -- the PROBE reports through print, so it silenced itself ("produced no value"). Two
    -- consequences, both fixed: our own output handle is captured BEFORE any injection,
    -- and the spec puts every global back. A sandbox that outlives its subject has escaped.
    local plan = planned('M.log',
        { ['input:msg'] = { value = '"x"', basis = 'any', by = 'agent' } })
    assert(ro.fill_oracle(store, plan))
    local before = print
    assert(loadstring(table.concat(ch.emit(plan), '\n'), 's'))()
    eq(before, print, 'the host process keeps its own print after the spec has run')
    eq(before, _G.print, 'and the global is the same one')
    cleanup()
end)

test('the tier is the WEAKEST LINK: a sandboxed run is a claim, not a measurement',
    function ()
    if not ready() then skip('no lua parser') end
    sproj()
    -- USER, 2026-08-04: "why not treat the environment as a hole to fill?" — and the first
    -- thing that reframe exposed was a shipped defect. A value observed by running the
    -- subject against our DECLARED fake `os.getenv` was tiered `measured`, the STRONGEST
    -- tier, with the sandbox mentioned only in prose. Nothing about the world was measured:
    -- "unset" is entirely a product of our own stub. An observation made THROUGH a supplied
    -- premise is only as strong as that premise.
    local plan = planned('M.env',
        { ['input:k'] = { value = '"HOME"', basis = 'a real variable', by = 'agent' } })
    assert(ro.fill_oracle(store, plan))
    local o = hole(plan, 'oracle')
    eq('claim', o.filled_tier, 'a sandboxed value is a CLAIM')
    eq('run', o.by, 'while the CHANNEL still records that it WAS a run — how and how-strong'
        .. ' are separate fields, which is why this was expressible at all')
    ok(o.basis:find('only as strong as that premise', 1, true), tostring(o.basis))
    cleanup()

    -- and an UNSANDBOXED run is unaffected: nothing was supplied, so nothing weakens it
    proj()
    local p2 = planned('M.add', { ['input:a'] = num(3), ['input:b'] = num(4) })
    assert(ro.fill_oracle(store, p2))
    eq('measured', hole(p2, 'oracle').filled_tier, 'a real run stays measured')
    cleanup()
end)

test('characterize.weakest: the ladder compares, and a fill can only WEAKEN', function ()
    eq('claim', ch.weakest('measured', 'claim'))
    eq('agent-supplied', ch.weakest('claim', 'agent-supplied'))
    eq('measured', ch.weakest('measured', nil), 'nil supplies no constraint')
    eq('measured', ch.weakest('measured'))
    -- A FILL CANNOT PROMOTE ITSELF. Allowing an explicit tier to strengthen would let a
    -- caller launder a claim into a measurement, which is the fabrication one field over.
    local p = { holes = { { id = 'input:x', kind = 'input' } } }
    assert(ch.fill(p, { ['input:x'] = { value = '1', basis = 'b', by = 'agent',
        tier = 'measured' } }))
    eq('agent-supplied', p.holes[1].filled_tier,
        'an agent-supplied value cannot claim to be measured')
end)
