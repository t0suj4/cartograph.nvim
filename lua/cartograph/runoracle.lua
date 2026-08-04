-- FILL THE ORACLE HOLE BY RUNNING (CART-0263, step 2 of the CART-0260 arc).
-- (Named for the job, not the concept: `oracle.lua` is the LSP-oracle substrate.)
--
-- THIS IS THE ONE PLACE CARTOGRAPH EXECUTES USER CODE, and the exception is the point
-- rather than a crack in the rule. Every analysis refuses to run anything, which is
-- exactly why the expected value is a HOLE and never a guess. But a hole is not a wall:
-- the value EXISTS, one run away, and a recorded run is `measured` evidence — the
-- strongest tier there is and the only one that can ever answer this question. The
-- never-draw invariant is intact: we still never INVENT the value. We observe it, label
-- it observed, and record what we ran to get it.
--
-- FOUR THINGS MAKE THAT SAFE ENOUGH TO SHIP, and none is optional:
--  1. THE EFFECT ANALYSIS DECIDES. effects.purity already labels every function
--     pure / io / writes (with `~` when it is unsure), so "is running this safe" has an
--     answer we COMPUTED rather than assumed. Only `pure` runs by default: `io` would
--     touch the world, `writes` would mutate module state, and a hedged `pure~` means
--     our own analysis is not certain — all refusals, overridable only EXPLICITLY. An
--     analysis gating an execution is the loop closing on itself.
--  2. A SEPARATE PROCESS, always. An infinite loop, an os.exit, a stack overflow or a
--     segfault in the subject must not take the editor with it.
--  3. SERIALIZATION IS A REFUSAL SURFACE. A value we cannot write back as Lua source
--     cannot be characterized, so the oracle STAYS A HOLE with the reason. A function, a
--     userdata, a coroutine, a cyclic table, NaN: all honest frontiers, none fabricated.
--  4. DETERMINISM IS CHECKABLE (M.determinism). A characterization spec for a
--     nondeterministic subject fails at random and teaches its reader to ignore
--     failures, which is worse than having no spec.
--
-- IDEMPOTENT BY CONSTRUCTION: the recorded value is a function of the subject and the
-- filled inputs, so a second run writes identical bytes and the txn is a no-op. A
-- DIFFERENT value on the second run is not a flaw here — it is the subject being
-- nondeterministic, and it is reported as that.
--
-- Use headless ([[cartograph-apply-for-agent]]):
--   local ro = require 'cartograph.runoracle'
--   local n, why = ro.fill_oracle(store, plan)   -- runs; fills at tier=measured
--   if not n then return why end                 -- the refusal, verbatim

local M = {}
local ch = require 'cartograph.characterize'

-- ── THE EXECUTION BUDGET, ENFORCED FROM BOTH SIDES ──────────────────────────
-- A budget is not optional once you are running someone else's code: without one, a
-- subject that loops forever hangs the run, and `vim.fn.system` gave us no timeout at
-- all. But ONE budget is not enough, because the two mechanisms are blind to different
-- things and each catches what the other cannot:
--
--  · INSTRUCTIONS (inside, a debug count hook) bound Lua-level nontermination
--    DETERMINISTICALLY: the same subject exhausts the same budget at the same point on
--    every machine. That matters more here than anywhere else — this tool exists to
--    record REPRODUCIBLE values, and a limit whose outcome depends on machine load would
--    make the recording itself flaky.
--  · WALL CLOCK (outside, kill the process) bounds everything the hook cannot see. The
--    count hook only ticks on Lua VM instructions, so a blocking read, a sleep, a C-level
--    infinite loop or a gigantic parse are all invisible to it. MEASURED: a real
--    load-plus-call of a nine-require module costs 6000 instructions and ~15 ms — nearly
--    all of that TIME is C (file IO and the parser) and produces almost no ticks. So the
--    wall clock is not a redundant second fence; it is the only fence on most of the cost.
--    (And the instruction budget only works with the JIT off — see the probe prologue.)
--  · OUTPUT bounds a subject that prints without stopping, which would otherwise be
--    captured into memory until something else broke.
--
-- The defaults are headroom over that measurement (~1600x the instructions, ~300x the
-- time), not guesses; every one is reported when it fires, and the COST OF A SUCCESSFUL
-- RUN rides in the recorded basis, so a budget can be raised from evidence rather than
-- from superstition. A default nobody can see the cost against is a superstition.
M.BUDGET = { instructions = 10000000, ms = 5000, output_kb = 512 }
M.TICK = 1000       -- hook granularity; the counter advances in these steps

-- ── SERIALIZATION: a value we cannot write back is not characterizable ───────

--- A Lua VALUE as Lua SOURCE. Returns (source, nil) or (nil, why). Refusal-first: this
--- is the gate that stops an uncharacterizable value from being written as one.
--- NaN and the infinities are refused because no literal reproduces them, so the spec
--- would compare against a value it cannot reconstruct.
function M.serialize(v, seen, depth)
    seen, depth = seen or {}, depth or 0
    local t = type(v)
    if v == nil then return 'nil' end
    if t == 'boolean' then return tostring(v) end
    if t == 'string' then return ('%q'):format(v) end
    if t == 'number' then
        if v ~= v then return nil, 'the value is NaN, which no literal reproduces' end
        if v == math.huge or v == -math.huge then
            return nil, 'the value is infinite, which no literal reproduces'
        end
        -- %.17g round-trips a double exactly where tostring() truncates
        if v == math.floor(v) and math.abs(v) < 2 ^ 53 then return ('%d'):format(v) end
        return ('%.17g'):format(v)
    end
    if t ~= 'table' then
        return nil, ('the value is a %s — a characterization spec compares by VALUE, and'
            .. ' a %s has no value form'):format(t, t)
    end
    if seen[v] then return nil, 'the value is a CYCLIC table; no literal reproduces it' end
    if depth > 6 then
        return nil, 'the value nests deeper than 6 tables — refusing rather than'
            .. ' truncating, because a truncated fixture is a WRONG fixture'
    end
    seen[v] = true
    -- DETERMINISTIC KEY ORDER, or one value serializes two ways and a re-run reads as a
    -- behaviour change: pairs() order is undefined between processes.
    local keys = {}
    for k in pairs(v) do
        local kt = type(k)
        if kt ~= 'string' and kt ~= 'number' then
            seen[v] = nil
            return nil, ('the table has a %s KEY, which no literal reproduces'):format(kt)
        end
        keys[#keys + 1] = k
    end
    table.sort(keys, function (a, b)
        if type(a) == type(b) then return tostring(a) < tostring(b) end
        return type(a) == 'number'
    end)
    local parts = {}
    for _, k in ipairs(keys) do
        local vs, why = M.serialize(v[k], seen, depth + 1)
        if not vs then seen[v] = nil; return nil, why end
        if type(k) == 'number' then
            parts[#parts + 1] = ('[%d] = %s'):format(k, vs)
        elseif k:match('^[%a_][%w_]*$') then
            parts[#parts + 1] = ('%s = %s'):format(k, vs)
        else
            parts[#parts + 1] = ('[%q] = %s'):format(k, vs)
        end
    end
    seen[v] = nil
    return '{ ' .. table.concat(parts, ', ') .. ' }'
end

-- ── MAY WE RUN IT? Our own effect analysis answers ──────────────────────────

--- Returns (true, label) or (nil, why). `opts.force` overrides EXPLICITLY, and the
--- override rides into the basis, so a spec built on it discloses that we ran something
--- our own analysis had flagged.
M.SAFE = { pure = true }
function M.runnable(store, plan, opts)
    local effects = require 'cartograph.effects'
    local label = effects.purity and effects.purity(store, plan.fn_id) or nil
    if not label then
        if opts and opts.force then return true, 'unknown (FORCED)' end
        return nil, ('the effect analysis has no summary for %s, so we cannot say what'
            .. ' running it would do — refusing (force overrides)'):format(plan.fn)
    end
    if M.SAFE[label] then return true, label end
    if opts and opts.force then return true, label .. ' (FORCED)' end
    local what = ({
        ['pure~'] = 'our own effect analysis is HEDGED about it — not certain it is pure',
        io = 'it touches the world (io / os / the editor), so running it would DO that',
        ['io~'] = 'it may touch the world, and the analysis is not certain',
        writes = 'it writes module state, so running it would mutate the process',
        ['writes~'] = 'it may write module state, and the analysis is not certain',
    })[label] or ('its purity label is ' .. label)
    return nil, ('%s is `%s`: %s. Refusing to run it — filling an oracle must not have'
        .. ' side effects (force overrides, and the spec then discloses it)')
        :format(plan.fn, label, what)
end

-- ── THE PROBE: the spec's own preamble, assertion replaced by a report ───────

-- The payload crosses the process boundary between MARKERS, because a subject that
-- prints — or whose module prints while loading — would otherwise corrupt the answer.
-- Everything outside them is noise and is discarded.
M.MARK_A, M.MARK_B = '--<CARTOGRAPH-ORACLE>', '--</CARTOGRAPH-ORACLE>'

-- The probe's own serializer, as SOURCE. It must live inside the probe (a separate
-- process cannot call ours) and it mirrors M.serialize rule for rule; the round-trip
-- test pins that they agree, because two serializers that drift would record a value the
-- spec cannot reproduce.
local PROBE_SER = [[
local function ser(v, seen, depth)
    seen, depth = seen or {}, depth or 0
    local t = type(v)
    if v == nil then return "nil" end
    if t == "boolean" then return tostring(v) end
    if t == "string" then return string.format("%q", v) end
    if t == "number" then
        if v ~= v or v == math.huge or v == -math.huge then return nil end
        if v == math.floor(v) and math.abs(v) < 2^53 then return string.format("%d", v) end
        return string.format("%.17g", v)
    end
    if t ~= "table" or seen[v] or depth > 6 then return nil end
    seen[v] = true
    local keys = {}
    for k in pairs(v) do
        if type(k) ~= "string" and type(k) ~= "number" then seen[v] = nil; return nil end
        keys[#keys + 1] = k
    end
    table.sort(keys, function (a, b)
        if type(a) == type(b) then return tostring(a) < tostring(b) end
        return type(a) == "number"
    end)
    local parts = {}
    for _, k in ipairs(keys) do
        local vs = ser(v[k], seen, depth + 1)
        if not vs then seen[v] = nil; return nil end
        if type(k) == "number" then
            parts[#parts + 1] = "[" .. k .. "] = " .. vs
        elseif string.match(k, "^[%a_][%w_]*$") then
            parts[#parts + 1] = k .. " = " .. vs
        else
            parts[#parts + 1] = "[" .. string.format("%q", k) .. "] = " .. vs
        end
    end
    seen[v] = nil
    return "{ " .. table.concat(parts, ", ") .. " }"
end
]]

--- The probe program. Shares characterize.preamble VERBATIM, so the subject is set up
--- exactly the way the spec will set it up: a probe that loaded it differently would
--- record a value the spec then fails to reproduce, and that disagreement would read as
--- a behaviour change in the subject rather than as a bug in us.
function M.probe_text(plan, budget)
    budget = budget or M.BUDGET
    local pre = {
        '-- EXECUTION BUDGET (CART-0263). Installed BEFORE the subject is even loaded, so a',
        '-- module that loops while LOADING is bounded too. os.exit rather than error(),',
        '-- because a subject full of pcall would swallow an error and keep going.',
        '--',
        '-- THE JIT IS TURNED OFF, and the budget does not work without it. MEASURED: with',
        '-- the JIT on, a 100-million-iteration loop finished having produced ZERO ticks,',
        '-- because LuaJIT count hooks fire only in the INTERPRETER and a hot loop is',
        '-- compiled to a trace. With jit.off() the same loop ticked in proportion to the work. So the',
        '-- probe runs interpreted: slower, and the only way the deterministic half of the',
        '-- budget is real rather than decorative. A fence that silently never fires is',
        '-- worse than no fence, because it reads as protection.',
        'if jit and jit.off then jit.off() end',
        ('local __budget = %d'):format(budget.instructions or M.BUDGET.instructions),
        'local __ticks = 0',
        'debug.sethook(function ()',
        ('    __ticks = __ticks + %d'):format(M.TICK),
        '    if __ticks > __budget then',
        '        debug.sethook()',
        ('        print(%q)'):format(M.MARK_A),
        '        print("BUDGET instructions " .. __ticks)',
        ('        print(%q)'):format(M.MARK_B),
        '        os.exit(0)',
        '    end',
        ('end, "", %d)'):format(M.TICK),
        '',
    }
    local L = ch.preamble(plan)
    for i = #pre, 1, -1 do table.insert(L, 1, pre[i]) end
    local function add(s) L[#L + 1] = s end
    add ''
    add 'debug.sethook()      -- the subject has returned; stop counting'
    add '-- THE PROBE: report the tuple, assert nothing.'
    for _, l in ipairs(vim.split(PROBE_SER, '\n')) do add(l) end
    add 'local out = {}'
    add 'for i = 1, gotn do'
    add '    local s = ser(got[i])'
    add '    if not s then'
    add(('        print(%q)'):format(M.MARK_A))
    add '        print("REFUSED " .. i .. " " .. type(got[i]))'
    add(('        print(%q)'):format(M.MARK_B))
    add '        os.exit(0)'
    add '    end'
    add '    out[i] = s'
    add 'end'
    add(('print(%q)'):format(M.MARK_A))
    add 'print("COST " .. __ticks)'
    add 'print("VALUES " .. gotn .. " " .. table.concat(out, ", "))'
    add(('print(%q)'):format(M.MARK_B))
    return L
end

-- ── THE RUN ─────────────────────────────────────────────────────────────────

--- Run the probe in a SEPARATE PROCESS. Returns (result, nil) or (nil, why), where
--- result = { n = <arity>, source = <lua source of the values, comma-separated> }.
--- Every non-oracle hole must be filled first: a probe cannot run on a hole, and asking
--- it to would surface the spec's own HOLE error as though the subject had failed.
function M.run(store, plan, opts)
    opts = opts or {}
    for _, h in ipairs(plan.holes or {}) do
        if h.kind ~= 'oracle' and not (h.value or h.satisfied_by) then
            return nil, ('%s is still a hole — fill every input before running, because a'
                .. ' probe cannot run on a hole'):format(h.id)
        end
    end
    local okrun, label = M.runnable(store, plan, opts)
    if not okrun then return nil, label end

    local budget = {
        instructions = (opts.budget and opts.budget.instructions)
            or M.BUDGET.instructions,
        ms = (opts.budget and opts.budget.ms) or M.BUDGET.ms,
        output_kb = (opts.budget and opts.budget.output_kb) or M.BUDGET.output_kb,
    }
    local text = table.concat(M.probe_text(plan, budget), '\n') .. '\n'
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    local file = dir .. '/probe.lua'
    vim.fn.writefile(vim.split(text, '\n'), file)
    -- THE SAME INTERPRETER the spec will run under, so the recorded value and the
    -- comparison that checks it happen in one Lua. vim.system (not vim.fn.system)
    -- because only the former can be given a DEADLINE — the old call had none at all,
    -- so a subject that looped forever hung the run with no way out.
    local proc = vim.system({ vim.v.progpath, '--headless', '-u', 'NONE', '-l', file },
        { text = true })
    local done = proc:wait(budget.ms)
    -- BOTH STREAMS, and this is not belt-and-braces: measured, `print` under
    -- `nvim --headless -l` writes to STDERR. vim.fn.system merged the two, so switching
    -- to vim.system (the only one that can carry a deadline) silently emptied the answer
    -- until this was found. A runner change can move which stream carries the payload.
    local out = (done.stdout or '') .. (done.stderr or '')
    local code = done.code or 0
    -- A TIMEOUT KILL IS code=124 signal=9 (measured, not assumed — vim.system's wait
    -- reports exactly that on expiry). Distinguished from any other nonzero exit because
    -- "it did not finish in time" and "it failed" are different answers.
    local killed = (code == 124 and done.signal == 9)
    -- OUTPUT CAP: a subject that prints without stopping would otherwise be captured
    -- into memory until something else broke. Truncating is safe here because the
    -- payload sits between markers near the END, and an overrun is REPORTED either way.
    local cap = budget.output_kb * 1024
    local truncated = #out > cap
    if truncated then out = out:sub(1, cap) end
    vim.fn.delete(dir, 'rf')
    if killed then
        return nil, ('the subject did not finish within %d ms and was KILLED. This is'
            .. ' the WALL-CLOCK budget, which is load-dependent by nature, so a slow'
            .. ' machine can trip it where a fast one would not — raise it with'
            .. ' opts.budget.ms if the subject is legitimately slow'):format(budget.ms)
    end

    -- STRIP CR, and this is not defensive dressing — it was a real bug caught the first
    -- time a TABLE was recorded. nvim's headless `print` emits CRLF, so the payload
    -- carried a trailing \r into the value source; Lua treats \r as a LINE TERMINATOR,
    -- so the spec's own provenance comment ended early and the rest of the line parsed as
    -- code ("unexpected symbol near '['"). A value that crosses a process boundary is
    -- bytes, not text, until something normalizes it.
    local lines, inside = {}, false
    for _, raw in ipairs(vim.split(out or '', '\n')) do
        local l = raw:gsub('[\r]', '')
        if l:find(M.MARK_B, 1, true) then inside = false end
        if inside and l:match('%S') then lines[#lines + 1] = l end
        if l:find(M.MARK_A, 1, true) then inside = true end
    end
    local payload, cost
    for _, l in ipairs(lines) do
        local c = l:match('^COST (%d+)$')
        if c then cost = tonumber(c) else payload = (payload or '') .. l end
    end
    if payload and payload:match('^BUDGET instructions (%d+)') then
        local burned = payload:match('^BUDGET instructions (%d+)')
        return nil, ('the subject burned the INSTRUCTION budget (%s of %d Lua VM'
            .. ' instructions) — it is looping, or it is genuinely that expensive. This'
            .. ' limit is DETERMINISTIC (the same subject trips it at the same point on'
            .. ' every machine); raise it with opts.budget.instructions'):format(
            burned, budget.instructions)
    end
    if truncated and not payload then
        return nil, ('the subject printed more than %d KB without reaching the report —'
            .. ' the OUTPUT budget stopped CAPTURING it (memory is what this bounds; the'
            .. ' wall clock is what bounds its time)'):format(budget.output_kb)
    end
    if not payload then
        -- NO MARKERS = the subject never reached the report. Its own error IS the answer
        -- and it is quoted verbatim: "the run failed" with no reason would be exactly the
        -- silence this codebase treats as the recurring defect.
        local tail = (out or ''):gsub('%s+$', '')
        return nil, ('the probe produced no value (exit %d). The subject, or loading it,'
            .. ' failed:\n%s'):format(code, tail:sub(math.max(1, #tail - 400)))
    end
    local ri, rt = payload:match('^REFUSED (%d+) (%S+)')
    if ri then
        return nil, ('return value %s is a %s — a characterization spec compares by'
            .. ' VALUE and a %s has no value form, so the oracle stays a HOLE')
            :format(ri, rt, rt)
    end
    local n, src = payload:match('^VALUES (%d+) ?(.*)$')
    if not n then return nil, 'the probe emitted an unreadable payload: ' .. payload end
    return { n = tonumber(n), source = src, purity = label, cost = cost }
end

--- Run, then FILL the oracle at tier `measured`. Returns (n_filled, nil) or (nil, why).
--- The basis records HOW the value was obtained, including a forced purity override:
--- a value observed from a function our analysis flagged is still evidence, but evidence
--- whose provenance the spec has to carry.
function M.fill_oracle(store, plan, opts)
    local oracle
    for _, h in ipairs(plan.holes or {}) do
        if h.kind == 'oracle' then oracle = h end
    end
    if not oracle then
        return nil, ('%s has no oracle hole — it returns nothing, so its behaviour is its'
            .. ' EFFECTS and a run cannot characterize it'):format(plan.fn)
    end
    if oracle.by == 'run' and oracle.value then
        return 0        -- already observed; re-running would only replace it with itself
    end
    local res, why = M.run(store, plan, opts)
    if not res then return nil, why end
    return ch.fill(plan, { [oracle.id] = {
        value = res.source, n = res.n, by = 'run',
        -- THE COST RIDES IN THE BASIS. It is provenance (what it took to observe this)
        -- and it is also the only evidence anyone has for choosing a budget: a default
        -- nobody can see the cost against is a superstition.
        -- "0 instructions" would read as free; it means BELOW THE HOOK GRANULARITY, which
        -- is a different claim and the honest one to print.
        basis = ('observed by running the subject in a separate process (purity %s, %s)')
            :format(res.purity or '?',
                res.cost == nil and 'instruction count unavailable'
                or res.cost == 0 and ('fewer than %d Lua VM instructions'):format(M.TICK)
                or ('%d Lua VM instructions'):format(res.cost)),
    } })
end

--- Run TWICE and say whether the subject is deterministic. Returns (true, note) or
--- (false, note) or (nil, why). Not the default — it doubles the cost — but the honest
--- check before trusting a recorded oracle.
function M.determinism(store, plan, opts)
    local a, whya = M.run(store, plan, opts)
    if not a then return nil, whya end
    local b, whyb = M.run(store, plan, opts)
    if not b then return nil, whyb end
    if a.n == b.n and a.source == b.source then
        return true, ('stable across two runs: %d value(s)'):format(a.n)
    end
    return false, ('NONDETERMINISTIC — two runs disagreed:\n  %d: %s\n  %d: %s')
        :format(a.n, a.source, b.n, b.source)
end

return M
