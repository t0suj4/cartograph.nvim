-- MUTATION-CHECK (discovery, CART-1174): does SPEC CATCH this mutation? The mutation is an EXAMPLE (before -> after
-- text inside FILE), applied by rewrite-by-example into a SCRATCH COPY of the repo — never the working tree — and the
-- spec runs there, before and after.
--
-- It replaces a hand loop run ~50 times in one session (sed the guard, cmp against a pristine copy, run the spec,
-- restore, cmp again), and each of its steps is now a refusal BY NAME where the loop had a silent pass:
--   harness #22  a mutation that did not APPLY passes     -> rewrite-by-example's `empty` stop: refused, not a pass
--   harness #25  a RED baseline catches everything        -> the unmutated spec runs first, in the scratch copy; red refuses
--   harness #32  a backup that never restores             -> nothing to restore: the scratch copy is thrown away
--   harness #11/#18  a marker grep / an ignored filter    -> the summary line is read (spec-fails), and a run that ran
--                                                            nothing refuses
-- The rewrite is STAGED (txn.stage: containment, the parse guard, the no-change refusal) and written into the scratch
-- copy directly: journaling a throwaway world would leave a journal for a root that stops existing (the 27798 stray
-- journal directories tests/run.sh was written to stop).
-- CLAIM: the mutated spec FAILS (the mutation is caught). A SURVIVOR is the claim failing, with both summaries.
local SF = require 'cartograph.tactics.spec-fails'

local function repo_of_toolbelt()
    -- ABSOLUTE: a module loaded through a relative runtimepath entry ('.') reports a relative source path
    local here = vim.fn.fnamemodify((debug.getinfo(1, 'S').source:gsub('^@', '')), ':p')
    return (here:gsub('/lua/cartograph/tactics/[^/]*$', ''))
end

--- copy `repo` (everything but .git) into a fresh scratch root -> root | nil, why
local function scratch_copy(repo)
    local root = vim.fn.tempname() .. '-mutation'
    vim.fn.mkdir(root, 'p')
    local obj = vim.system({ 'bash', '-c', 'tar --exclude=.git -C "$1" -cf - . | tar -C "$2" -xf -', 'copy', repo, root },
        { text = true }):wait(120000)
    if obj.code ~= 0 then return nil, ('copying %s failed: %s'):format(repo, tostring(obj.stderr)), 'environment' end
    return root
end

local function measure(_, p)
    local repo = p.repo or repo_of_toolbelt()
    local v = { file = p.file, spec = p.spec, repo = repo }
    local root, why = scratch_copy(repo)
    if not root then v.error = why; return v end
    v.scratch = root
    local function done() if not p.keep then vim.fn.delete(root, 'rf'); v.scratch = nil end return v end
    -- 1. the BASELINE, in the copy: it must be green, or every mutation is "caught"
    local limit = p.timeout and tonumber(p.timeout) * 1000 or nil
    local base, bwhy = SF.run(root, p.spec, limit)
    if not base then v.error = 'baseline: ' .. tostring(bwhy); return done() end
    v.baseline = base
    if base.ran == 0 then v.error = ('the spec RAN NOTHING (%s) — SPEC must name a spec file'):format(base.summary); return done() end
    if base.failed > 0 then v.error = ('the BASELINE is red (%s): a red baseline catches every mutation'):format(base.summary); return done() end
    -- 2. the MUTATION, by example, staged in the copy (a minimal graph: the rewrite needs a root and a file, no index).
    -- ★ A MUTATION IS USUALLY AN EXPRESSION (`#hits == 1` -> `#hits >= 1`), and an expression is not a chunk. When
    -- BOTH sides read as `return <expr>` they ARE expressions, and that reading wins — ⚠ even when the chunk reading
    -- also "succeeds": MEASURED, `#hits == 1` read as a chunk is a lone SHEBANG line (`#` at the start of a chunk), the
    -- rule learned from it was a shebang rule, and the mutation "matched nothing" in a file that holds it. A statement
    -- (`if … end`, `x = 1`) does not read after `return`, so it keeps the chunk reading.
    local R = require 'cartograph.algebraread'
    local before, after = p.before, p.after
    if R.read('return ' .. before, 'lua') and R.read('return ' .. after, 'lua') then
        before, after = 'return ' .. before, 'return ' .. after
    end
    local store = require 'cartograph.store'
    -- ★ GROUND mode (ground = 1): the mutation is EXACTLY the text given, applied once at its one site by the edit
    -- verb's classification — no rule is learned. MEASURED why it is needed: an edit inside an `or` chain was learned
    -- as FOUR independent rules applied at 10 sites (a multi-region diff does not compose to the intended mutant), so
    -- "SURVIVED" described a different mutant than the one written.
    if p.ground == '1' or p.ground == true then
        local E = require 'cartograph.edit'
        local path = root .. '/' .. p.file
        local fd = io.open(path, 'rb'); local text = fd and fd:read('a'); if fd then fd:close() end
        local state, why = E.classify(text, p.before, p.after)
        if state ~= 'pending' then v.error = 'the mutation did not APPLY: ' .. tostring(why or state); return done() end
        local new = E.apply_to(text, p.before, p.after)
        local parses = require('cartograph.planguards').GUARDS.parses(nil, nil, { [p.file] = text }, { [p.file] = new })
        for _, row in ipairs(parses or {}) do
            if row.verdict == require('cartograph.planguards').FAIL then v.error = 'the mutated file breaks a guard: ' .. tostring(row.why); return done() end
        end
        local wf = assert(io.open(path, 'wb')); wf:write(new); wf:close()
        v.sites, v.rules = 1, { ('`%s` -> `%s` (ground)'):format(p.before, p.after) }
        local mut, mwhy = SF.run(root, p.spec, limit)
        if not mut then v.error = 'mutated run: ' .. tostring(mwhy); return done() end
        v.mutated, v.caught = mut, mut.failed > 0
        return done()
    end
    local txn = require 'cartograph.txn'
    local ok, applied, awhy = pcall(store.scoped, { root = root, nodes = {}, edges = {}, calls = {} }, function ()
        local plan, pwhy, pclass = require('cartograph.byexample').plan(store, { before = before, after = after, scope = p.file })
        if not plan then return nil, ('%s (%s)'):format(tostring(pwhy), tostring(pclass)), pclass or 'ill-posed' end
        local staged, swhy, sclass = txn.stage(store, plan)
        if not staged then return nil, tostring(swhy), sclass or 'unbuilt' end
        if staged.failed then return nil, 'the mutated file breaks a guard: ' .. require('cartograph.planguards').refusal(staged.failed), 'ill-posed' end
        for rel, text in pairs(staged.after) do
            local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(text); fd:close()
        end
        return { sites = plan.sites, rules = plan.rules }
    end)
    if not ok then v.error = 'the rewrite raised: ' .. tostring(applied); return done() end
    if not applied then v.error = 'the mutation did not APPLY: ' .. tostring(awhy); return done() end
    v.sites, v.rules = applied.sites, applied.rules
    -- 3. the MUTATED run
    local mut, mwhy = SF.run(root, p.spec, limit)
    if not mut then v.error = 'mutated run: ' .. tostring(mwhy); return done() end
    v.mutated = mut
    v.caught = mut.failed > 0
    return done()
end

local E = {
    name = 'mutation-check',
    kind = 'discovery',
    measures = 'CART-1174',
    summary = 'does SPEC catch a mutation? file = the file to mutate, before/after = the mutation as an example (a chunk or an EXPRESSION), spec = the spec file name (e.g. tactic_spec); runs in a scratch COPY of repo (default: this cartograph), baseline first; keep = 1 keeps the copy; timeout = seconds per run (default 600): a mutant that HANGS is CAUGHT (timed out), its process group killed',
    params = { file = 'string', before = 'string', after = 'string', spec = 'string', repo = 'string?', keep = 'string?', ground = 'string?', timeout = 'string?' },
    measure = measure,
    claim = function (v)
        if v.error then return false, v.error end
        local rules = table.concat(v.rules or {}, ', ')
        if v.caught then
            return true, ('CAUGHT: %s at %d site(s) in %s — %s: baseline %s, mutated %s'):format(rules, v.sites or 0, v.file, v.spec,
                v.baseline.summary, v.mutated.summary)
        end
        -- ⚠ a survivor is a TEST GAP or an EQUIVALENT mutant (one that changes no behaviour) — the check cannot tell
        -- which; MEASURED on its first real run: `#e.point > #best` -> `>=` in namespace.lua survives, and equal-length
        -- containing points are the same point, so that one is equivalent. Say both, never "nothing pins this".
        return false, ('SURVIVED: %s at %d site(s) in %s — %s stays green (%s): a test gap, or an EQUIVALENT mutant (read the sites)')
            :format(rules, v.sites or 0, v.file, v.spec, v.mutated.summary)
    end,
}

local FX = SF.FIXTURE
local function params(spec, before, after)
    return function (store)
        return { file = 'lib/guard.lua', before = before or 'if x > 0 then return true end', after = after or 'if x >= 0 then return true end',
            spec = spec, repo = store.data.root }
    end
end
E.examples = {
    {
        name = 'a spec that pins the boundary CATCHES `>` -> `>=`',
        files = FX, params = params('guard_spec'),
        expect = { holds = true, check = function (v) return v.baseline.failed == 0 and v.mutated.failed > 0 and v.scratch == nil,
            'baseline ' .. tostring(v.baseline and v.baseline.summary) .. ' / mutated ' .. tostring(v.mutated and v.mutated.summary) end },
    },
    {
        -- ⚠ the rule is `?1 > 0 -> ?1 >= 0`: the CARRIED operand (`#t`) becomes a hole, so `x > 0` is mutated too — two
        -- sites. That is rewrite-by-example's generalization, reported in the claim (`at N site(s)`), not hidden
        name = 'an EXPRESSION mutation starting with `#` is read as an expression, not a shebang line — and is CAUGHT',
        files = FX, params = params('guard_spec', '#t > 0', '#t >= 0'),
        expect = { holds = true, check = function (v) return (v.sites or 0) >= 1, 'sites ' .. tostring(v.sites) .. ' ' .. tostring(v.error) end },
    },
    {
        name = 'a spec that never tests zero lets it SURVIVE — the finding this entry exists for',
        files = FX, params = params('weak_spec'),
        expect = { holds = false, check = function (v) return v.mutated and v.mutated.failed == 0 and v.error == nil, tostring(v.error) end },
    },
    {
        name = 'a mutation that matches NOTHING is refused by name — never read as caught or survived',
        files = FX, params = params('guard_spec', 'if x > 99 then return true end', 'if x >= 99 then return true end'),
        expect = { holds = false, check = function (v) return v.error and v.error:find('did not APPLY', 1, true) ~= nil, tostring(v.error) end },
    },
    {
        -- the SAME text as the `#` example, GROUND: exactly the written mutant at its one site (`x > 0` untouched) — the
        -- learned rule's two sites vs this one is the difference the mode exists for
        name = 'GROUND mode applies exactly the written text at its one site — no rule is learned, and it is CAUGHT',
        files = FX, params = function (store)
            local p = params('guard_spec', '#t > 0', '#t >= 0')(store); p.ground = '1'; return p
        end,
        expect = { holds = true, check = function (v) return v.sites == 1 and (v.rules[1] or ''):find('(ground)', 1, true) ~= nil,
            'sites ' .. tostring(v.sites) .. ' ' .. tostring(v.error) end },
    },
    {
        name = 'a GROUND mutation whose result already occurs elsewhere is refused (drifted) — never applied at a guess',
        files = FX, params = function (store)
            -- `x > 0` -> `#t > 0`: the result already occurs (M.nonempty), and neither text contains the other
            local p = params('guard_spec', 'x > 0', '#t > 0')(store); p.ground = '1'; return p
        end,
        expect = { holds = false, check = function (v) return v.error and v.error:find('did not APPLY', 1, true) ~= nil, tostring(v.error) end },
    },
    {
        -- CART-1333: a mutant that makes the spec HANG is CAUGHT at the timeout (once, not twice it), its process group
        -- killed — it used to give no verdict and leave the spec running as an orphan
        name = 'a mutant that HANGS the spec is CAUGHT at the timeout, named TIMED OUT, and leaves no process behind',
        files = FX, params = function (store)
            local p = params('guard_spec', 'if x > 0 then return true end', 'for _ = 1, math.huge do end if x > 0 then return true end')(store)
            p.ground, p.timeout = '1', '2'
            return p
        end,
        expect = { holds = true, check = function (v)
            local m = v.mutated or {}
            return m.timed_out and m.group_gone and v.baseline.failed == 0, tostring(m.summary) .. ' ' .. tostring(v.error)
        end },
    },
    {
        name = 'a RED baseline refuses: it would catch every mutation',
        files = FX, params = params('broken_spec'),
        expect = { holds = false, check = function (v) return v.error and v.error:find('BASELINE is red', 1, true) ~= nil, tostring(v.error) end },
    },
}

return E
