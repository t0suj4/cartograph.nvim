-- CHARACTERIZE: one function → a RUNNABLE SPEC WITH HOLES (CART-0262, step 1 of the
-- CART-0260 arc). cartograph never executes user code, so it cannot know an expected
-- value — and rather than guess one, the expected value is a HOLE. That is the
-- never-draw invariant applied to a new medium: the blocker becomes structural.
--
-- TWO STANDING GATES, both more important than any feature here:
--  1. AN UNFILLED HOLE MUST FAIL. Every hole emits `HOLE(...)`, which errors. Never a
--     commented-out assert, never assert(true). A suite that goes green because its
--     assertions are missing is absence-rendered-as-silence at its most dangerous: it
--     LOOKS like coverage.
--  2. GENERATED SPECS STAY OUT OF THE PUSH FENCE. The suite globs `tests/*_spec.lua`;
--     these land under `characterized/` with a `_char.lua` suffix and are refused if
--     aimed at the fence (see M.plan). A characterization test is SUPPOSED to fail when
--     behaviour changes, so wiring it into pre-commit would block every legitimate
--     refactor. A tool you invoke, not a ratchet.
--
-- WHAT THE ENVIRONMENT ALREADY SUPPLIES IS NOT A HOLE, and getting this wrong would
-- have emitted thousands of spurious ones. The spec runs IN a Lua runtime, so a
-- dependency hole for `table.concat` is satisfied by the runtime itself; and it
-- `dofile`s the subject module, so a `derived` fixture hole (a same-file definition) is
-- satisfied by that load. Both are recorded as SATISFIED with the mechanism named —
-- disclosed, not silently dropped, because "no hole" and "a hole the environment fills"
-- are different claims.
--
-- A STUB IS A SUPPLIED PREMISE ([[cartograph-hedge-resolution-writes]]). The test is
-- HEDGED on its environment; a stub DISCHARGES the hedge; so the header carries every
-- premise it assumed, with the TIER of each. Without that we have fabricated an
-- environment and labelled the result a test — and it would look exactly like a real one.
--
-- AGENT-DRIVABLE IS A REQUIREMENT, NOT A LATER SURFACE (user, 2026-08-04). Use headless
-- ([[cartograph-apply-for-agent]]):
--   local ch = require 'cartograph.characterize'
--   local plan, why = ch.plan(store, ch.at(store, 'lua/foo.lua', 42))
--   if not plan then return why end               -- the refusal, verbatim
--   print(table.concat(ch.emit(plan), '\n'))      -- the spec, holes and all
--   ch.fill(plan, { ['input:a'] = { value = '7', basis = 'the caller passes 7',
--                                   by = 'agent' } })
--   local entry, err = ch.apply(store, plan)      -- journalled; parse-verified
-- Every row is DATA (plan.holes), never prose to parse.

local M = {}
local at = require 'cartograph.at'
local txn = require 'cartograph.txn'
local holes = require 'cartograph.holes'

-- Where generated specs land, and the fence they must never cross. The suite globs
-- `tests/*_spec.lua`; nothing here may match that.
M.DIR = 'characterized'
M.SUFFIX = '_char.lua'

--- The innermost function enclosing `line` — the TARGETED entry point every apply verb
--- in this codebase shares (optapply.at's shape, deliberately identical).
function M.at(store, file, line)
    if not (store.data and store.data.nodes and file and line) then return nil end
    local best, bestspan
    for _, n in ipairs(store.data.nodes) do
        if (n.kind == 'function' or n.kind == 'method') and n.range and n.file
            and (n.file == file or n.file:sub(-(#file + 1)) == '/' .. file) then
            local sl, el = at.sl(n.range) + 1, at.el(n.range) + 1
            if sl <= line and line <= el then
                local span = el - sl
                if not bestspan or span < bestspan then best, bestspan = n.id, span end
            end
        end
    end
    return best
end

--- HOW THE SPEC REACHES THE SUBJECT, which is a hole of its own when it cannot.
--- A `function M.add()` is reachable as a member of whatever the module returns; a
--- `local function helper()` is not reachable from outside the file AT ALL, and saying
--- so is the honest answer — a test that cannot call its subject is not a test.
---
--- THE MODULE-TABLE ASSUMPTION IS CHECKED, not assumed: the file must actually
--- `return <root>` at module level, where <root> is the name the definition hangs off.
--- Guessing here would emit a spec that dies with "attempt to index nil", which reads
--- as a broken tool rather than as the missing premise it is.
local function reach_of(node, lines)
    local root, member = (node.name or ''):match('^([%w_]+)%.([%w_]+)$')
    if not root then
        return { kind = 'file-local', name = node.name,
            why = ('`%s` is file-local: nothing outside %s can call it, so a spec'
                .. ' cannot reach it without an export'):format(
                tostring(node.name), node.file) }
    end
    for i = #lines, 1, -1 do
        local l = lines[i]
        if l and l:match('%S') then
            if l:match('^%s*return%s+' .. root .. '%s*$') then
                return { kind = 'member', module = root, member = member,
                    expr = 'SUBJECT.' .. member }
            end
            break
        end
    end
    return { kind = 'unreturned', module = root, member = member,
        why = ('%s does not end in `return %s`, so what dofile hands back may not'
            .. ' hold `%s` — the reach is unverified'):format(node.file, root,
            tostring(node.name)) }
end

--- CAN THE SPEC LOAD THE SUBJECT MODULE AT ALL? Returns (package_path_lines, nil) or
--- (nil, why). Found by DRIVING the verb on a real module rather than a fixture: the
--- fixture required nothing, so `dofile` worked; every real module opens with
--- `require 'cartograph.annot'`, and a bare dofile dies with "module 'x' not found".
---
--- THAT CRASH IS THE FAILURE MODE TO KILL. A spec that dies inside its own preamble
--- reads as a broken TOOL, while the truth is a missing PREMISE — the module needs a
--- package path we have not supplied. So the load is a premise like any other: derived
--- when we can align it, a HOLE when we cannot, never a crash.
---
--- THE ALIGNMENT IS THE DERIVATION: a `require 'a.b.c'` resolves to `a/b/c.lua`, so if
--- the graph holds a file whose path ends that way, the package root is the prefix that
--- remains. Nothing is guessed — a modname we cannot align is named in the refusal.
local function load_premise(store, node, lines)
    local mods, order = {}, {}
    for _, l in ipairs(lines) do
        -- module level only: an indented require runs when its function is CALLED, and
        -- the spec's own call is what would trigger it
        if l:match('^%s*local%s') or l:match('^%s*require') or l:match('^[%w_]') then
            for m in l:gmatch("require%s*%(?%s*['\"]([%w%._%-/]+)['\"]") do
                if not mods[m] then mods[m] = true; order[#order + 1] = m end
            end
        end
    end
    if #order == 0 then return {}, nil end          -- requires nothing: dofile is enough
    local root = store.data.root
    local roots, missing = {}, {}
    for _, m in ipairs(order) do
        local want = m:gsub('%.', '/')
        local hit
        for rel in pairs(store.by_file or {}) do
            if type(rel) == 'string' then
                local pre = rel:match('^(.*)' .. want:gsub('%-', '%%-') .. '%.lua$')
                    or rel:match('^(.*)' .. want:gsub('%-', '%%-') .. '/init%.lua$')
                if pre then hit = pre; break end
            end
        end
        if hit then roots[hit] = true else missing[#missing + 1] = m end
    end
    if #missing > 0 then
        return nil, ('%s requires %s, which this graph cannot align to a file — a spec'
            .. ' that dofiles it would die inside its own preamble with "module not'
            .. ' found", so the LOAD is the hole'):format(node.file,
            table.concat(missing, ', ', 1, math.min(3, #missing))
                .. (#missing > 3 and (' (+' .. (#missing - 3) .. ')') or ''))
    end
    local out, seen = {}, {}
    for pre in pairs(roots) do
        local abs = root and (root .. '/' .. pre) or pre
        abs = abs:gsub('/+$', '')
        if not seen[abs] then
            seen[abs] = true
            out[#out + 1] = ('package.path = %q .. package.path')
                :format(abs .. '/?.lua;' .. abs .. '/?/init.lua;')
        end
    end
    table.sort(out)
    return out, nil
end

--- Is this hole already answered by the spec's own environment? Returns the MECHANISM
--- or nil. Two cases, both measured rather than assumed:
---  · a stdlib dependency (rule='stdlib') — the spec runs in a Lua runtime that HAS
---    `table.concat`; nothing needs injecting.
---  · a `derived` fixture (a same-file definition) — the spec dofiles the module, so
---    the definition is in the function's own closure by the time it is called.
--- A HEDGED stdlib signature is deliberately NOT satisfied here: `s:match` was signed
--- by the only stdlib owner of the name with the receiver unverified (CART-0266), so
--- the RUNTIME may hold something else entirely under that name.
local function satisfied_by(h)
    if h.kind == 'dependency' and h.rule == 'stdlib' then
        -- A HEDGED signature is satisfied TOO, and this changed after driving it: a
        -- receiver-unverified match like `("x"):rep(n)` → string#rep was BLOCKING the run
        -- of any function using the idiom, even though the interpreter plainly holds
        -- string.rep. Over-strict, and in the one direction that costs coverage for
        -- nothing: if the receiver is NOT what we guessed, the subject fails when it runs
        -- and the probe reports that failure verbatim — the hedge cannot hide a wrong
        -- answer here, it can only be wrong about who supplies the name. So it is
        -- satisfied WITH THE HEDGE NAMED, which is what a premise line is for.
        return h.hedged
            and 'the runtime, HEDGED: the only stdlib owner of this member name, receiver'
                .. ' unverified — if the receiver is something else, the run will say so'
            or 'the runtime: a Lua interpreter holds this'
    end
    if h.kind == 'dependency' and h.owners then
        -- AN AMBIGUOUS STDLIB NAME IS STILL SUPPLIED BY THE RUNTIME. The SET is about
        -- which OWNER declares the member (`write` is file's and io's), not about whether
        -- the name exists — the interpreter holds every candidate. Blocking here stopped
        -- any subject using `f:write(...)` from running at all, for a question that does
        -- not affect availability. Disclosed with the set named, per usual.
        return ('the runtime, which holds every candidate owner (%s) — the SET is about'
            .. ' which one declares it, not about whether it exists'):format(
            table.concat(h.owners, ', '))
    end
    if h.kind == 'fixture' and h.tier == 'derived' then
        return 'loading the module: a same-file definition carries this name'
    end
    return nil
end


-- ── THE SANDBOX (CART-0277, user steer: "can't we just inject our own functions?") ──
-- An `io` subject was REFUSED outright, which is the safe answer and a poor one: the
-- population it excludes is exactly the population a refactor most needs a witness for.
-- So instead of refusing, INJECT — the CART-0261 injection frame turned on the DANGEROUS
-- case instead of the ABSENT one. A fake `io.open` records the call and touches nothing.
--
-- AND THE REAL PRIZE IS NOT RUNNING io FUNCTIONS. It is functions that return NOTHING,
-- whose behaviour IS their effects: this used to emit "no oracle … which this spec does
-- not observe", i.e. silence where a hole belongs. With a sandbox the CALL LOG is the
-- oracle, and a population that was 100% uncharacterizable becomes characterizable.
--
-- A FAKE IS A SUPPLIED PREMISE, NOT THE TRUTH, and that governs everything here. With a
-- fake that fails, `io.open(p) ~= nil` records false; with one that succeeds, true. BOTH
-- are facts about OUR STUB. So every injected name is disclosed as a premise, the basis
-- says the value was measured UNDER this environment, and THE SPEC INSTALLS THE SAME
-- SANDBOX — a spec that ran against a different world could not reproduce the value it
-- was handed, and the mismatch would read as a behaviour change in the subject.
--
-- The formatter is deliberately small: a call LOG needs argument text, not a faithful
-- round-trippable value (that is runoracle.serialize's job for the RETURN). Both the
-- probe and the spec emit this same block, from here, for the usual reason.
local SANDBOX_SRC = {
    'local __log, __restore = {}, {}',
    'local function __fmt(v)',
    '    local t = type(v)',
    '    if t == "string" then return string.format("%q", v) end',
    '    if t == "number" or t == "boolean" or v == nil then return tostring(v) end',
    '    if t == "table" then return "{table}" end',
    '    return "<" .. t .. ">"',
    'end',
    -- WHATEVER WE REPLACE, WE PUT BACK. Found by driving it: a spec loaded IN-PROCESS
    -- (which the test suite does, and which lets several specs share one process) left the
    -- fake `print` installed, so the HOST's output went silent after the first spec ran.
    -- Restoring is not politeness — a sandbox that outlives its subject has escaped.
    -- A PATH, not a root-and-member pair. `vim.fn.tempname` is THREE segments, and a
    -- two-segment matcher silently fell through to patching a GLOBAL literally named
    -- "vim.fn.tempname" — accepted, installed nowhere, and the run then went through the
    -- real call while reporting success. A name shape assumption that fails OPEN is the
    -- worst kind: everything looks wired.
    'local function __patch(path, fake)',
    '    local t = _G',
    '    for i = 1, #path - 1 do',
    '        t = t and t[path[i]]',
    '        if type(t) ~= "table" then return false end',
    '    end',
    '    local key = path[#path]',
    '    local old = t[key]',
    '    __restore[#__restore + 1] = function () t[key] = old end',
    '    t[key] = fake',
    '    return true',
    'end',
    'local function __unsandbox()',
    '    for i = #__restore, 1, -1 do __restore[i]() end',
    '    __restore = {}',
    'end',
    'local function __rec(name, fake)',
    '    return function (...)',
    '        local n, a = select("#", ...), {}',
    '        for i = 1, n do a[i] = __fmt((select(i, ...))) end',
    '        __log[#__log + 1] = name .. "(" .. table.concat(a, ", ") .. ")"',
    '        if fake then return fake(...) end',
    '    end',
    'end',
}

--- THE TIER OF AN INJECTED FAKE. `claim`, uniformly and deliberately: a fake is something we
--- DECLARED, exactly like an annotation, and CART-0240 established that a declaration is the
--- weakest evidence there is. A future fill could be stronger — a value RECORDED from a real
--- unsandboxed run would be `measured`, and a profile-supplied one is still a `claim` — which
--- is the whole point of treating the environment as a hole: the fill has a tier, and better
--- sources can replace ours without any of this machinery changing.
M.SANDBOX_TIER = 'claim'

--- The injectable roster: name → the FAKE's return, as Lua source. Every entry is a
--- DECLARED answer rather than a plausible one, and each is chosen to be the least
--- surprising failure: an unopened file is `nil, reason`, which is what real `io.open`
--- returns when it cannot open — so a subject that checks for nil takes its own error
--- path instead of dying inside our stub.
---
--- `os.exit` IS THE ONE THAT MUST BE HERE. A subject calling it would kill the probe
--- before it could report, and the run would surface as "produced no value" — a tool
--- failure where the truth is "the subject exited". Faked into an error, it is a finding.
M.SANDBOX = {
    ['io.open'] = 'function () return nil, "sandboxed: no file was opened" end',
    ['io.lines'] = 'function () return function () return nil end end',
    ['io.read'] = 'function () return nil end',
    ['io.write'] = 'function () return nil end',
    ['io.popen'] = 'function () return nil, "sandboxed: no process was started" end',
    ['os.execute'] = 'function () return nil, "sandboxed: nothing was executed" end',
    ['os.remove'] = 'function () return nil, "sandboxed: nothing was removed" end',
    ['os.rename'] = 'function () return nil, "sandboxed: nothing was renamed" end',
    ['os.getenv'] = 'function () return nil end',
    ['os.tmpname'] = 'function () return "/sandboxed/tmpname" end',
    ['os.time'] = 'function () return 0 end',
    ['os.clock'] = 'function () return 0 end',
    ['os.date'] = 'function () return "sandboxed" end',
    ['os.exit'] = 'function (c) error("sandboxed: the subject called os.exit("'
        .. ' .. tostring(c) .. ")", 0) end',
    print = 'function () return nil end',
    collectgarbage = 'function () return 0 end',
}

--- WHICH ENV FILLS ARE INSTALLED — a VIEW over the holes, never stored state. This was a
--- `plan.sandbox` field computed once at plan time, and it made a filled hole a lie: an agent
--- filling `env:vim.fn.tempname` AFTER planning was accepted, never installed, and the run
--- then went through the REAL nondeterministic call while the oracle was tiered `measured`.
--- Two things wrong at once, both from a cached copy of state that had moved.
--- ONE SOURCE OF TRUTH, and the holes are it.
function M.sandbox_of(plan)
    local out, any = {}, false
    for _, h in ipairs(plan.holes or {}) do
        if h.kind == 'env' and h.value then out[h.name] = h.value; any = true end
    end
    return any and out or nil
end

--- The WEAKEST tier among the installed env fills, or nil when nothing is installed. A run
--- through an agent-invented stub is `agent-supplied` evidence, not `claim` and certainly not
--- `measured`: the environment's tier travels into everything observed through it.
function M.env_tier(plan)
    local t
    for _, h in ipairs(plan.holes or {}) do
        if h.kind == 'env' and h.value then t = M.weakest(t or h.filled_tier, h.filled_tier) end
    end
    return t
end

--- The sandbox as spec lines: the recorder, then one patch per injected name.
local function sandbox_lines(names)
    local L = {}
    for _, l in ipairs(SANDBOX_SRC) do L[#L + 1] = l end
    local sorted = {}
    for n in pairs(names or {}) do sorted[#sorted + 1] = n end
    table.sort(sorted)          -- deterministic: the spec must not churn between runs
    for _, n in ipairs(sorted) do
        local fake = names[n]
        if fake then
            local segs = {}
            for seg in n:gmatch('[%w_]+') do segs[#segs + 1] = ('%q'):format(seg) end
            -- AND IT MUST NOT FAIL SILENTLY: a path we cannot walk (the host is absent in
            -- this interpreter) is an ERROR, because a spec that ran unsandboxed while
            -- believing itself contained is the failure mode this whole layer exists to
            -- prevent.
            L[#L + 1] = ('if not __patch({ %s }, __rec("%s", %s)) then'):format(
                table.concat(segs, ', '), n, fake)
            L[#L + 1] = ('    error("sandbox: cannot install %s — the path does not exist'
                .. ' in this interpreter, so this spec would run UNSANDBOXED", 0)'):format(n)
            L[#L + 1] = 'end'
        end
    end
    return L
end
M.sandbox_lines = sandbox_lines

--- WHAT THIS FUNCTION NEEDS FROM ITS ENVIRONMENT, as HOLE ROWS (CART-0279, user: "why not
--- treat the environment as a hole to fill?"). Derived from the effect vocabulary, per callee.
---
--- THIS RETIRED THREE MECHANISMS THAT WERE ONE QUESTION. A hand-maintained sandbox roster, a
--- categorical io REFUSAL, and (a layer up) the VM's host problem were all enumerating the
--- same names for different reasons — and all three ask "what does this code need from its
--- environment, and who supplies it?", which is a HOLE. The hole machinery already had
--- everything: an id, an owning rule, a tier, a mandatory basis, prediction refused, a premise
--- line in the header, and an unfilled hole that ERRORS instead of passing.
---
--- WHEN THREE MECHANISMS KEEP NEEDING THE SAME LIST, THE LIST IS A FIRST-CLASS THING YOU HAVE
--- NOT NAMED YET.
---
--- SO THE REFUSAL IS GONE. A channel we have no fake for is no longer a reason to refuse the
--- whole subject — it is one more named, addressable hole, and the run's existing precondition
--- ("every hole but the oracle must be filled") blocks it for free. Strictly more coverage at
--- identical honesty: before this, ONE unmodelled call made a function uncharacterizable.
---
--- NONDET COUNTS, NOT JUST IO. Measured while building the sandbox: the vocabulary calls
--- `os.getenv` pure-but-NONDETERMINISTIC, so an io-only filter passed it through and a run
--- recorded this machine's real $HOME — a value that fails on anyone else's machine, and one
--- the purity LABEL cannot see either.
local function env_holes(store, node)
    local effects = require 'cartograph.effects'
    local callrec = require 'cartograph.callrec'
    local pm = require 'cartograph.spec.profile'
    local stdprof = pm.load(pm.base_for('lua'))
    local sites = (store.topo and store.topo().sites) and store.topo():sites(node.id) or {}
    local rows, seen = {}, {}
    for _, c in ipairs(sites) do
        for _, nm in ipairs({ callrec.full(c) or callrec.callee(c), callrec.callee(c) }) do
            if nm and not seen[nm] then
                seen[nm] = true
                local sig = effects.sig_of and effects.sig_of('lua', nm, false)
                if sig and (sig.io or sig.nondet) then
                    local fake = M.SANDBOX[nm]
                    -- A PROFILE SIGNATURE IS EVIDENCE, NOT A FILL. It gives the RETURN TYPE,
                    -- and a type is not a value — the same reason an `@param` annotation does
                    -- not fill an input hole. So it rides as an EDGE to what would fill this
                    -- ([[cartograph-explaining-a-finding]]), never as an invented value.
                    local declared = pm.member_sig and select(1, pm.member_sig(stdprof, nm:match('([%w_]+)$'), nm))
                    rows[#rows + 1] = {
                        kind = 'env', name = nm, rule = 'profile',
                        -- OUR DEFAULT FILL, at the tier a DECLARATION deserves. It is data,
                        -- replaceable by a better source, which is the whole argument for the
                        -- reframe: the same hole can be filled better later and nothing here
                        -- changes.
                        value = fake or nil,
                        by = fake and 'sandbox' or nil,
                        filled_tier = fake and M.SANDBOX_TIER or nil,
                        basis = fake and ("cartograph's own declared fake — the call is"
                            .. ' RECORDED and the world is untouched') or nil,
                        declared = declared and declared.sig or nil,
                        why = fake and 'injected: the call is recorded, not performed'
                            or ((declared and ('the environment supplies this and we have no'
                                .. ' fake for it. The profile declares %s, so a stub of that'
                                .. ' shape would fill it'):format(declared.sig)
                            or 'the environment supplies this and we have no fake for it —'
                                .. ' nothing we hold can say what it returns')),
                    }
                end
            end
        end
    end
    table.sort(rows, function (a, b) return a.name < b.name end)
    return rows
end
M.env_holes = env_holes

local function hole_id(h) return ('%s:%s'):format(h.kind, h.name or '?') end

--- One COMMENT line's worth of text. A control character here is not cosmetic: Lua treats
--- CR as a line terminator, so a value carrying one would end the comment early and the
--- remainder of the provenance line would parse as code. Belt to runoracle's braces —
--- the value's own CONTENT must not be able to break the file that quotes it.
local function oneline(s)
    return (tostring(s or ''):gsub('[\r\n\t]', ' '):gsub('%s+', ' '))
end

--- Stage a characterization plan for ONE function. Returns (plan, nil) or (nil, why).
--- `opts.path` overrides the output file; `opts.dir` overrides the directory.
function M.plan(store, fn_id, opts)
    opts = opts or {}
    local node = fn_id and store.node(fn_id)
    if not node then return nil, 'no such function' end
    if node.kind ~= 'function' and node.kind ~= 'method' then
        return nil, ('%s is a %s, not a function'):format(tostring(node.name),
            tostring(node.kind))
    end
    local lines = store.content(node)
    if not lines then return nil, 'no source for ' .. tostring(node.file) end
    local ts = require 'cartograph.providers.treesitter'
    local ctx = holes.ctx_for(store, node, lines,
        ts.annot_tag and ts.annot_tag(node.file),
        ts.attach_pats and ts.attach_pats(node.file))
    local H, why = holes.of(store, node, ctx)
    if not H then return nil, why or 'no holes computed' end

    -- REACH IS A HOLE ROW LIKE ANY OTHER, and it must be, because it is the one hole
    -- that makes every other one moot: a spec that cannot call its subject is not a
    -- spec. Keeping it only in `plan.subject` let the header report "2 unfilled" for a
    -- file-local function whose real answer is "3, and one of them is fatal".
    -- THE ENVIRONMENT AS HOLES (CART-0279), and the EFFECTS hole that exists because we can
    -- inject at all (CART-0277). `sandbox` is now DERIVED from the env holes that carry a
    -- fill, so the emitter installs exactly what is filled and nothing else.
    local envrows = env_holes(store, node)
    local inject, unfilled_env = {}, {}
    -- AN ENV HOLE SUBSUMES THE DEPENDENCY HOLE FOR THE SAME CALL. `vim.fn.tempname` arrived
    -- twice — once as `dependency:tempname` (an unresolved callee) and once as
    -- `env:vim.fn.tempname` (a channel the vocabulary names) — which is one NEED counted
    -- TWICE, inflating `unfilled` and giving a filler two ids for one thing. Exactly the
    -- duplication this reframe exists to remove, so the env row owns it: it carries the full
    -- path, the profile evidence and the fill mechanism, while the dependency row carries a
    -- bare segment and no way to answer. Matching on the last segment is sound HERE because
    -- both rows were derived from the same function's call sites.
    local covered = {}
    for _, e in ipairs(envrows) do
        H[#H + 1] = e
        covered[e.name:match('([%w_]+)$') or e.name] = e.name
        if e.value then inject[e.name] = true else unfilled_env[#unfilled_env + 1] = e.name end
    end
    if next(covered) then
        local kept = {}
        for _, h in ipairs(H) do
            local sub = h.kind == 'dependency' and covered[h.name or '']
            if sub then
                -- recorded on the surviving row, never dropped in silence
                for _, e in ipairs(envrows) do
                    if e.name == sub then
                        e.subsumes = (e.subsumes or '') .. 'dependency:' .. h.name
                    end
                end
            else
                kept[#kept + 1] = h
            end
        end
        H = kept
    end
    local sandboxed = next(inject) ~= nil
    -- AN EFFECT-ONLY FUNCTION HAS A HOLE, not a shrug. This used to emit "no oracle …
    -- which this spec does not observe": true, and silence where a hole belongs. With a
    -- sandbox its behaviour IS the recorded call log, so the log is the thing to observe.
    local has_oracle = false
    for _, h in ipairs(H) do if h.kind == 'oracle' then has_oracle = true end end
    if sandboxed then
        H[#H + 1] = { kind = 'effects', name = '<calls>', rule = 'execution',
            why = ('what this function DOES: the sandboxed call log (%s). One RUN fills'
                .. ' it; no static tier can'):format(
                table.concat((function ()
                    local t = {}
                    for n in pairs(inject) do t[#t + 1] = n end
                    table.sort(t); return t
                end)(), ' ')) }
    end

    local reach = reach_of(node, lines)
    -- THE LOAD IS A PREMISE TOO, and when it cannot be derived it is a HOLE rather
    -- than a crash inside the spec's own preamble (see load_premise).
    local pathlines, loadwhy = load_premise(store, node, lines)
    if loadwhy then
        H[#H + 1] = { kind = 'load', name = node.file, rule = 'linker', why = loadwhy }
    end
    if reach.kind ~= 'member' then
        H[#H + 1] = { kind = 'reach', name = node.name or '?', rule = 'linker',
            why = reach.why }
    end

    local rows, unfilled, premises = {}, 0, {}
    for _, h in ipairs(H) do
        local sat = satisfied_by(h)
        local row = { id = hole_id(h), kind = h.kind, name = h.name, tier = h.tier,
            rule = h.rule, why = h.why, hard = h.hard, hedged = h.hedged,
            stub = h.stub, satisfied_by = sat, owners = h.owners,
            blocking = holes.blocking(h) or nil,
            -- A ROW MAY ARRIVE ALREADY FILLED, which env holes do (CART-0279 ships a
            -- default fake for the channels it knows). This loop used to copy a FIXED
            -- field list, so a pre-supplied fill was silently dropped and every env hole
            -- read as unfilled — a whitelist copy is how a new field gets lost.
            value = h.value, by = h.by, filled_tier = h.filled_tier, basis = h.basis,
            declared = h.declared }
        -- a MEASURED input is already an answer: the code itself demonstrates it
        if h.kind == 'input' and h.tier == 'measured' then
            local lit = h.why:match('passes the string (.*)$')
            local sca = h.why:match('passes the scalar (.*)$')
            if lit then row.value, row.filled_tier, row.by = ('%q'):format(lit),
                'measured', 'observed'
            elseif sca then row.value, row.filled_tier, row.by = sca, 'measured',
                'observed' end
        end
        if sat then
            premises[#premises + 1] = ('%s %s — satisfied by %s'):format(h.kind,
                tostring(h.name), sat)
        elseif not row.value then
            unfilled = unfilled + 1
        end
        rows[#rows + 1] = row
    end

    local root = store.data.root
    local base = (node.name or 'fn'):gsub('[^%w_]', '_')
    local dir = opts.dir or M.DIR
    local path = opts.path or (dir .. '/' .. base .. M.SUFFIX)
    -- GATE 2, enforced rather than documented: the suite globs tests/*_spec.lua, and a
    -- characterization spec is SUPPOSED to fail when behaviour changes. Landing one in
    -- the fence would block every legitimate refactor, so the path is refused here —
    -- the one place every entry point passes through.
    if path:match('^tests/') or path:match('_spec%.lua$') then
        return nil, ('%s is inside the push fence (tests/*_spec.lua) — a'
            .. ' characterization spec must not gate a commit; it is a tool you invoke')
            :format(path)
    end
    return {
        verb = 'characterize', generation = store.generation,
        file = node.file, fn = node.name or '?', fn_id = node.id,
        ref = store.ref_of(node.id),
        subject = reach,
        package_path = pathlines or {},
        sandbox = sandboxed and inject or nil,
        -- kept as a LIST for the report and the refusal text; the authority is the hole rows
        unfilled_env = (#unfilled_env > 0) and unfilled_env or nil,
        has_oracle = has_oracle,
        abspath = root and (root .. '/' .. node.file) or node.file,
        params = node.params or {},
        holes = rows, premises = premises, unfilled = unfilled,
        path = path,
        touched = { path },
        -- A CREATE, declared as one (txn.creates) — the same contract the extract-module
        -- verb uses for its new destination module. Without it txn refuses with "cannot
        -- read", which is correct behaviour for an EDIT and the wrong question here.
        -- Re-characterizing overwrites our own previous output, so the stamp still CASes
        -- when the file already exists: a spec someone has since hand-edited must not be
        -- silently clobbered.
        creates = { [path] = true },
        stamps = { [path] = root and txn.disk_stamp(root, path) or nil },
    }
end

--- SUPPLY A PREMISE for one or more holes — the agent-facing half, and the same
--- protocol as the decline ledger's `assume = {[line] = id}`: filling a hole is
--- DISCHARGING A HEDGE, so it needs a BASIS and the tier records WHO supplied it.
---
--- fills = { ['<hole id>'] = { value = <lua source>, basis = <why>, by = <channel> } }
--- Returns (n_filled, nil) or (nil, why) — and it refuses rather than warns:
---  · NO BASIS IS A REFUSAL. A value with no stated basis is a guess wearing an
---    answer's clothes, and once written into a spec it is indistinguishable from an
---    observed literal.
---  · THE ORACLE IS NEVER FILLABLE BY PREDICTION. `by` must be 'run' (a recorded
---    behaviour — CART-0263) or 'spec' (a declared contract). A predicted expected
---    value produces a test that passes because the prediction matched the prediction,
---    and it looks exactly like a real characterization test. Worse than no test.
---  · a MEASURED hole is not overwritten: the code already demonstrates that input.
M.BY_TIER = { run = 'measured', spec = 'claim', observed = 'measured',
    agent = 'agent-supplied' }
M.ORACLE_CHANNELS = { run = true, spec = true }

--- THE LADDER, so a tier can be COMPARED rather than only printed. Strongest first.
M.TIER_RANK = { measured = 1, derived = 2, claim = 3, ['agent-supplied'] = 4 }

--- THE WEAKEST LINK (user, 2026-08-04: "why not treat the environment as a hole to fill?").
--- An observation made THROUGH a supplied premise is only as strong as that premise: a value
--- observed by running the subject against our DECLARED fake `os.getenv` is not `measured`
--- evidence about anything, it is a `claim` — and it shipped as `measured` with the sandbox
--- mentioned only in prose, which is the tier field saying one thing and the sentence beside
--- it saying another. THE CHANNEL RECORDS HOW, THE TIER RECORDS HOW STRONG, and they are
--- separate fields for exactly this reason: `by` stays 'run' because it WAS a run.
function M.weakest(...)
    local worst, rank = nil, 0
    for i = 1, select('#', ...) do
        local t = (select(i, ...))
        local r = t and M.TIER_RANK[t]
        if r and r > rank then worst, rank = t, r end
    end
    return worst
end

function M.fill(plan, fills)
    if not (plan and type(fills) == 'table') then return nil, 'no fills' end
    local byid = {}
    for _, h in ipairs(plan.holes or {}) do byid[h.id] = h end
    local n = 0
    for id, f in pairs(fills) do
        local h = byid[id]
        if not h then
            return nil, ('no hole %q in this plan (ids are <kind>:<name>)'):format(id)
        end
        if type(f) ~= 'table' or f.value == nil then
            return nil, ('fill for %s carries no value'):format(id)
        end
        if type(f.basis) ~= 'string' or f.basis == '' then
            return nil, ('fill for %s carries no BASIS — a value with no stated basis'
                .. ' is a guess wearing an answer\'s clothes, and a spec cannot tell'
                .. ' the two apart afterwards'):format(id)
        end
        local by = f.by or 'agent'
        if not M.BY_TIER[by] then
            return nil, ('fill for %s names an unknown channel %q (run|spec|agent)')
                :format(id, tostring(by))
        end
        -- THE EFFECTS HOLE IS AN OBSERVATION TOO, and takes the same channel rule as the
        -- oracle: a PREDICTED call log makes a spec that passes because the prediction
        -- matched the prediction, which is the same fabrication one field over.
        if (h.kind == 'oracle' or h.kind == 'effects') and not M.ORACLE_CHANNELS[by] then
            return nil, ('the ORACLE hole %s may be filled by RUNNING (by=\'run\') or'
                .. ' by a SPEC (by=\'spec\'), never by prediction: a predicted expected'
                .. ' value makes a test that passes because the prediction matched the'
                .. ' prediction'):format(id)
        end
        if h.filled_tier == 'measured' and h.by == 'observed' then
            return nil, ('%s is already MEASURED (the code demonstrates this input) —'
                .. ' refusing to overwrite evidence with a supplied value'):format(id)
        end
        h.basis, h.by = f.basis, by
        -- an explicit tier WEAKENS (never strengthens): a caller may say "this run went
        -- through a claim-tier stub", and may not promote a claim to a measurement
        h.filled_tier = M.weakest(M.BY_TIER[by], f.tier)
        if h.kind == 'oracle' then
            -- THE ORACLE IS A TUPLE, always, because a function returning `nil, err` is
            -- characterized on half its behaviour otherwise. `n` is the arity and it is
            -- SEPARATE from the list: select('#') keeps a trailing nil that `#t` cannot
            -- see, and `return nil` vs `return` are different behaviours.
            h.n = f.n or 1
            h.raw_value = tostring(f.value)
            h.value = ('%d, { %s }'):format(h.n, h.raw_value)
        else
            h.value = tostring(f.value)
        end
        n = n + 1
    end
    local left = 0
    for _, h in ipairs(plan.holes or {}) do
        if not (h.value or h.satisfied_by) then left = left + 1 end
    end
    plan.unfilled = left
    return n
end

-- ── THE SPEC TEXT ───────────────────────────────────────────────────────────
-- Self-contained by design: no test framework, no rtp, no harness. It runs with
-- `nvim --headless -l <spec>` or any Lua, because the point is that the SUBJECT's
-- behaviour is characterized, not that our suite can host it.

local function hole_call(h)
    return ('HOLE(%q, %q)'):format(h.id, (h.why or 'no evidence'):gsub('"', "'"))
end

--- The plan as spec lines. PURE — no disk, so the dry-run diff, the applied bytes and
--- the tests all read the same function.
--- The spec's PREAMBLE — everything up to and including the call — shared verbatim with
--- the RUN probe (cartograph.oracle). One builder, two consumers, for the reason
--- portflow.lua exists: a probe that set the subject up DIFFERENTLY from the spec would
--- record a value the spec then fails to reproduce, and the disagreement would look like
--- a behaviour change.
function M.preamble(plan)
    local L = {}
    local function add(s) L[#L + 1] = s end
    -- OUR OWN OUTPUT CHANNEL, CAPTURED BEFORE ANYTHING CAN BE INJECTED. Found by driving
    -- it: `print` is in the effect vocabulary as io, so the sandbox faked it — and the
    -- PROBE reports through print, so it silenced itself and the run failed with "produced
    -- no value". A tool that injects into a shared namespace has to hold its own handles
    -- first; whatever we replace, we may be a user of too.
    add 'local __out = print'
    add(('-- CHARACTERIZATION SPEC for `%s` (%s)'):format(plan.fn, plan.file))
    add '-- Generated by cartograph. NOT a hand-written test, and NOT in the push fence:'
    add '-- a characterization spec is SUPPOSED to fail when behaviour changes.'
    -- NOTHING SESSION-SPECIFIC IN THE HEADER. This carried the graph GENERATION until a
    -- test caught it: applying bumps the generation, so a re-characterization of an
    -- unchanged function emitted different bytes and the idempotent write was not
    -- idempotent. A generated file that changes when nothing it describes has changed
    -- shows up as a diff in every review and trains its reader to stop reading it. The
    -- provenance that matters — the premises and their tiers — is below, and it is a fact
    -- about the SUBJECT rather than about our session.
    add ''
    if #(plan.premises or {}) > 0 then
        add '-- PREMISES THIS SPEC ASSUMES (a stub is a supplied premise, not a fact):'
        for _, p in ipairs(plan.premises) do add('--   · ' .. oneline(p)) end
        add ''
    end
    local supplied = {}
    for _, h in ipairs(plan.holes) do
        if h.basis then
            supplied[#supplied + 1] = oneline(('%s = %s  [%s, by %s] %s'):format(h.id,
                h.raw_value or h.value, h.filled_tier or '?', h.by or '?', h.basis))
        end
    end
    if #supplied > 0 then
        add '-- SUPPLIED PREMISES — who answered, on what basis, and at which tier:'
        for _, s in ipairs(supplied) do add('--   · ' .. s) end
        add ''
    end
    add(('-- %d hole(s) UNFILLED. This spec MUST fail until they are filled: a hole'):format(
        plan.unfilled or 0))
    add '-- errors, it never silently passes.'
    add ''
    add 'local function HOLE(id, why)'
    add "    error(('HOLE: %s — %s'):format(id, why), 2)"
    add 'end'
    add ''
    -- THE SANDBOX GOES IN BEFORE THE SUBJECT IS LOADED, because a module can call io at
    -- LOAD time and an injection that arrives after the dofile would have missed it.
    local sandbox = M.sandbox_of(plan)
    if sandbox then
        add '-- SANDBOX: our own functions, injected. Every call is RECORDED and the world'
        add '-- is untouched. A fake is a SUPPLIED PREMISE, not the truth — the values below'
        add '-- are what this subject does UNDER THIS ENVIRONMENT, which is a real fact and'
        add '-- a different one from what it does against the real io.'
        for _, l in ipairs(M.sandbox_lines(sandbox)) do add(l) end
        add ''
    end
    for _, l in ipairs(plan.package_path or {}) do
        add('-- DERIVED premise: the module requires siblings, so the spec supplies the')
        add('-- package path the graph aligned them to (a require it could NOT align is')
        add('-- a hole, never a silent "module not found").')
        add(l)
    end
    -- a LOAD hole fires BEFORE the dofile, so the reader sees the premise that is
    -- missing instead of Lua's own message about a module it never heard of
    for _, h in ipairs(plan.holes) do
        if h.kind == 'load' and not h.value then
            add(('HOLE(%q, %q)'):format(h.id, (h.why or ''):gsub('"', "'")))
        end
    end
    if plan.subject.kind ~= 'member' then
        add(('-- REACH: %s'):format(plan.subject.why or 'the subject is not reachable'))
        add(('local SUBJECT = HOLE(%q, %q)'):format('reach:' .. plan.fn,
            (plan.subject.why or 'unreachable'):gsub('"', "'")))
    else
        add(('local SUBJECT = dofile(%q)'):format(plan.abspath))
    end
    add ''
    -- INPUTS, in parameter order, so the call reads like the signature
    local byname = {}
    for _, h in ipairs(plan.holes) do
        if h.kind == 'input' then byname[h.name] = h end
    end
    local args = {}
    for _, p in ipairs(plan.params) do
        local h = byname[p]
        args[#args + 1] = p
        if h and h.value then
            add(('local %s = %s  -- %s: %s'):format(p, h.value,
                h.filled_tier or 'filled', h.basis or h.why or ''))
        elseif h then
            add(('local %s = %s'):format(p, hole_call(h)))
        else
            add(('local %s = HOLE(%q, %q)'):format(p, 'input:' .. p,
                'no hole row for this parameter'))
        end
    end
    add ''
    -- DEPENDENCY stubs that the environment does NOT supply
    for _, h in ipairs(plan.holes) do
        if h.kind == 'dependency' and not h.satisfied_by then
            if h.value then
                add(('-- stub %s — %s'):format(h.name, h.basis or ''))
                add(('_G[%q] = %s'):format(h.name, h.value))
            else
                add(('-- an absent dependency this spec cannot inject%s'):format(
                    h.stub and (' (declared ' .. h.stub .. ')') or ''))
                add(('HOLE(%q, %q)'):format(h.id, (h.why or ''):gsub('"', "'")))
            end
        end
    end
    -- FIXTURE holes the module load does not answer
    for _, h in ipairs(plan.holes) do
        if h.kind == 'fixture' and not h.satisfied_by then
            if h.value then
                add(('_G[%q] = %s  -- fixture: %s'):format(h.name, h.value,
                    h.basis or ''))
            else
                add(('HOLE(%q, %q)'):format(h.id, (h.why or ''):gsub('"', "'")))
            end
        end
    end
    add ''
    -- EVERY RETURN VALUE, and this matters: `local got = f(x)` keeps the FIRST and
    -- silently drops the rest, so a function returning `nil, err` was characterized on
    -- half its behaviour while the spec read as complete. select('#') also keeps a
    -- trailing nil, which `#t` cannot see — `return nil` and `return` are different
    -- behaviours and a characterization spec has to be able to tell them apart.
    add 'local function CAPTURE(...) return select("#", ...), { ... } end'
    add(('local gotn, got = CAPTURE(%s(%s))'):format(plan.subject.expr or 'SUBJECT',
        table.concat(args, ', ')))
    if sandbox then
        add 'local gotcalls = table.concat(__log, " | ")'
        -- RESTORED BEFORE THE ASSERTIONS, so a FAILING spec still leaves the process clean
        add '__unsandbox()'
    end
    return L, args
end

--- Deep VALUE equality, emitted into the spec because `got ~= want` on tables compares
--- IDENTITY: a subject returning a fresh table would report CHANGED on every run, which
--- is a false alarm indistinguishable from a real one.
local SAME = {
    'local function SAME(a, b)',
    '    if a == b then return true end',
    '    if type(a) ~= "table" or type(b) ~= "table" then return false end',
    '    for k, v in pairs(a) do if not SAME(v, b[k]) then return false end end',
    '    for k in pairs(b) do if a[k] == nil then return false end end',
    '    return true',
    'end',
    'local function SHOW(n, t)',
    '    local p = {}',
    '    for i = 1, n do p[i] = type(t[i]) == "table" and "{table}" or tostring(t[i]) end',
    '    return "(" .. table.concat(p, ", ") .. ")"',
    'end',
}

--- The plan as spec lines. PURE — no disk, so the dry-run diff, the applied bytes and
--- the tests all read the same function.
function M.emit(plan)
    local L = M.preamble(plan)
    local function add(s) L[#L + 1] = s end
    for _, l in ipairs(SAME) do add(l) end
    local oracle
    for _, h in ipairs(plan.holes) do
        if h.kind == 'oracle' then oracle = h end
    end
    if oracle then
        if oracle.value then
            add(oneline(('-- %s, by %s: %s'):format(oracle.filled_tier or '?',
                oracle.by or '?', oracle.basis or '')))
            add(('local wantn, want = %s'):format(oracle.value))
        else
            add(('local wantn, want = %s'):format(hole_call(oracle)))
        end
        add 'if gotn ~= wantn or not SAME(got, want) then'
        add ("    error(('CHANGED: %s returned %s, characterized as %s'):format("
            .. ('%q, SHOW(gotn, got), SHOW(wantn, want)))'):format(plan.fn))
        add 'end'
    else
        add '-- no oracle: this function returns nothing, so behaviour is its EFFECTS,'
        add '-- which this spec does not observe. Nothing is asserted about the result.'
    end
    -- THE EFFECT LOG, asserted separately from the return tuple because they are separate
    -- claims: a function can keep its return value and change what it DOES, and a spec
    -- that folded them would report one as the other.
    local eff
    for _, h in ipairs(plan.holes) do
        if h.kind == 'effects' then eff = h end
    end
    if eff and M.sandbox_of(plan) then
        if eff.value then
            add(oneline(('-- %s, by %s: %s'):format(eff.filled_tier or '?',
                eff.by or '?', eff.basis or '')))
            add(('local wantcalls = %s'):format(eff.value))
        else
            add(('local wantcalls = %s'):format(hole_call(eff)))
        end
        add 'if gotcalls ~= wantcalls then'
        add(('    error(("CHANGED (effects): %s did [%%s], characterized as [%%s]")'
            .. ':format(gotcalls, wantcalls))'):format(plan.fn))
        add 'end'
    end
    add(('__out(%q)'):format('ok  ' .. plan.fn .. ' characterized'))
    return L
end

--- The txn edit set: one whole-file write (a create, or a replace of our own output).
function M.edits_for(plan)
    return function (file)
        if file ~= plan.path then return nil end
        return table.concat(M.emit(plan), '\n') .. '\n'
    end
end

--- Dry run: (before, after) keyed by file, exactly as every other verb previews.
function M.preview(store, plan)
    return txn.dryrun(store, plan, M.edits_for(plan))
end

--- Write it, verified. The spec must LOAD (a syntax gate on our own output — an
--- emitter that writes a file Lua cannot parse has failed at its one job) and the
--- subject function must be unchanged since the plan was staged.
function M.apply(store, plan)
    local bad = txn.verify(store, plan,
        { { id = plan.fn_id, name = plan.fn, ref = plan.ref, what = 'function' } })
    if bad then return nil, bad end
    local text = table.concat(M.emit(plan), '\n') .. '\n'
    local chunk, lerr = loadstring(text, plan.path)
    if not chunk then
        return nil, ('the emitted spec does not parse — refusing: ' .. tostring(lerr))
    end
    -- IDEMPOTENCE (CART-0263). The spec is a pure function of the subject and the filled
    -- holes, so re-characterizing writes identical bytes — and a journal entry per
    -- no-op run would fill :CartographUndo with steps that undo nothing, which is how an
    -- undo stack stops being trustworthy. A CHANGED file still writes, because that is a
    -- real difference; only byte-identity short-circuits.
    local disk = store.data.root and txn.read_file(store.data.root, plan.path)
    if disk == text then
        return { unchanged = true, path = plan.path,
            desc = { name = plan.path, from = plan.fn } }
    end
    return txn.execute(store, plan,
        { name = plan.path, from = plan.fn }, M.edits_for(plan))
end

--- Every function a STAGED plan touches, characterized — the arc's first customer.
--- neutrality.lua certifies a refactor changed nothing by hashing the df shape, a
--- PROXY; running these before and after is the same check with real assertions.
--- Returns (plans, refusals) — both, because a refusal per symbol is the honest
--- answer for a move-set where only some members are reachable.
function M.plan_for_txn(store, staged, opts)
    local plans, refused = {}, {}
    local ids = {}
    if staged then
        if staged.fn_id then ids[#ids + 1] = staged.fn_id end
        for _, m in ipairs(staged.moves or {}) do
            if m.id then ids[#ids + 1] = m.id end
        end
    end
    for _, id in ipairs(ids) do
        local p, why = M.plan(store, id, opts)
        if p then plans[#plans + 1] = p
        else refused[#refused + 1] = { id = id, why = why } end
    end
    return plans, refused
end

--- The plan as report ROWS — (lines, at) so a pane can wire <CR> to the site, and so
--- an agent reads structure rather than parsing prose. plan.holes IS the data; this is
--- only its display.
function M.report(plan)
    local L, A = {}, {}
    local function add(s, a) L[#L + 1] = s; A[#A + 1] = a end
    add(('characterize %s (%s) — %d hole(s), %d unfilled'):format(plan.fn, plan.file,
        #plan.holes, plan.unfilled or 0), { file = plan.file, id = plan.fn_id })
    add(('  subject: %s%s'):format(plan.subject.kind,
        plan.subject.expr and (' via ' .. plan.subject.expr) or ''), nil)
    add(('  writes:  %s'):format(plan.path), nil)
    add('', nil)
    for _, h in ipairs(plan.holes) do
        local mark = h.value and '+' or (h.satisfied_by and '=' or '?')
        -- THE EFFECTIVE TIER, not the static one. This printed the STATIC tier, so a
        -- hole the run had just answered read `FRONTIER` on the same line as a basis
        -- saying it was observed — a row contradicting itself teaches a reader to trust
        -- neither half. `filled_tier` is what the evidence actually is now.
        -- A SATISFIED ROW IS NOT FRONTIER. The tier column answers "what evidence could
        -- FILL this", and a hole the environment already answers is not waiting for
        -- evidence at all — printing FRONTIER beside a `=` mark was the same
        -- self-contradiction the filled rows had.
        add(('  %s %-22s %-9s %s'):format(mark, h.id,
            h.satisfied_by and 'env' or h.filled_tier or h.tier or 'FRONTIER',
            h.satisfied_by or h.basis or h.why or ''), nil)
    end
    add('', nil)
    add('  + supplied or measured · = satisfied by the environment · ? a HOLE that'
        .. ' will error', nil)
    return L, A
end

return M
