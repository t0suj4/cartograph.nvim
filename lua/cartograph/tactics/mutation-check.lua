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
local function scratch_copy(repo, keep)
    -- (a KEPT copy outlives this process: nvim deletes its own tempdir — where tempname() points — at exit, so keep = 1
    -- under it kept nothing; measured 2026-10-03, the copy was gone when the command returned)
    local root = keep and (vim.fn.stdpath('cache') .. '/cartograph/mutation-kept/' .. os.date('%Y%m%dT%H%M%S') .. '-' .. vim.uv.hrtime() % 1e6)
        or (vim.fn.tempname() .. '-mutation')
    vim.fn.mkdir(root, 'p')
    local obj = vim.system({ 'bash', '-c', 'tar --exclude=.git -C "$1" -cf - . | tar -C "$2" -xf -', 'copy', repo, root },
        { text = true }):wait(120000)
    if obj.code ~= 0 then return nil, ('copying %s failed: %s'):format(repo, tostring(obj.stderr)), 'environment' end
    -- ★ THE COPY READS THE REPO'S HISTORY, AND CANNOT WRITE IT (CART-1444): a tactic whose examples read git (ab-equivalence
    -- unpacks `git archive HEAD`) ran in a copy with no .git and turned toolbelt_spec's baseline red — every mutation
    -- check against toolbelt_spec then refused. The copy gets a git repo of its OWN whose objects come from the original
    -- through `objects/info/alternates` (read-only) and whose HEAD is the original's commit; a write lands in the copy's
    -- .git, never in the original's (a `.git` file pointing at the original would have let a test commit into it)
    local head = vim.system({ 'git', '-C', repo, 'rev-parse', '--verify', 'HEAD' }, { text = true }):wait()
    if head.code == 0 then
        local objs = vim.system({ 'git', '-C', repo, 'rev-parse', '--path-format=absolute', '--git-path', 'objects' }, { text = true }):wait()
        local init = vim.system({ 'git', 'init', '-q', root }, { text = true }):wait()
        if init.code == 0 and objs.code == 0 then
            local fd = io.open(root .. '/.git/objects/info/alternates', 'w')
            if fd then fd:write(vim.trim(objs.stdout), '\n'); fd:close() end
            vim.system({ 'git', '-C', root, 'update-ref', 'HEAD', vim.trim(head.stdout) }, { text = true }):wait()
        end
    end
    return root
end

local function measure(_, p)
    local repo = p.repo or repo_of_toolbelt()
    local v = { file = p.file, spec = p.spec, repo = repo }
    local root, why = scratch_copy(repo, p.keep)
    if not root then v.error = why; return v end
    v.scratch = root
    local function done() if not p.keep then vim.fn.delete(root, 'rf'); v.scratch = nil end return v end
    -- 1. the BASELINE, in the copy: it must be green, or every mutation is "caught"
    local limit = p.timeout and tonumber(p.timeout) * 1000 or nil
    -- (env = NAME=value,… for both runs — DERIVE=<op> mutation-checks a DERIVATION, CART-1368)
    local env, ewhy = SF.env_of(p.env)
    if p.env and not env then v.error = ewhy; return done() end
    local base, bwhy = SF.run(root, p.spec, limit, env)
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
        -- ★ ONE COPY OF A DUPLICATED BLOCK (CART-1569): the resolver's link and relink copies are identical for 100+
        -- lines, so "add context so the site is unique" has no answer — `site = N` mutates the N-th occurrence of the
        -- text (left to right, non-overlapping), `site = all` every one; the result may occur elsewhere (the site is
        -- named, not guessed)
        local new, nsite = nil, p.site
        if nsite ~= nil and nsite ~= 'all' then
            nsite = tonumber(nsite)
            if not nsite then v.error = 'site must be a number or `all`'; return done() end
        end
        if nsite then
            local hits, at = {}, 1
            for _ = 1, 100000 do
                local s, e = text:find(p.before, at, true)
                if not s then break end
                hits[#hits + 1], at = s, e + 1
            end
            local pick = nsite == 'all' and hits or { hits[nsite] }
            if #hits == 0 or #pick == 0 then
                v.error = ('the mutation did not APPLY: site = %s, the text to edit occurs %d time(s)'):format(p.site, #hits)
                return done()
            end
            local out, i = {}, 1
            for _, s in ipairs(pick) do
                out[#out + 1] = text:sub(i, s - 1); out[#out + 1] = p.after; i = s + #p.before
            end
            out[#out + 1] = text:sub(i)
            new = table.concat(out)
            v.site_of, v.nsites = ('site %s of %d'):format(p.site, #hits), #pick
        else
            local state, why = E.classify(text, p.before, p.after)
            if state ~= 'pending' then v.error = 'the mutation did not APPLY: ' .. tostring(why or state); return done() end
            new = E.apply_to(text, p.before, p.after)
        end
        local parses = require('cartograph.planguards').GUARDS.parses(nil, nil, { [p.file] = text }, { [p.file] = new })
        for _, row in ipairs(parses or {}) do
            if row.verdict == require('cartograph.planguards').FAIL then v.error = 'the mutated file breaks a guard: ' .. tostring(row.why); return done() end
        end
        local wf = assert(io.open(path, 'wb')); wf:write(new); wf:close()
        v.sites = v.nsites or 1
        v.rules = { ('`%s` -> `%s` (ground%s)'):format(p.before, p.after, v.site_of and (', ' .. v.site_of) or '') }
        local mut, mwhy = SF.run(root, p.spec, limit, env)
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
    -- ★ A WIDENED MUTANT IS SAID (CART-1457): the learned rule generalizes, so it may change more than the text written —
    -- `okc` -> `true` became every `okc` of the file (it no longer parsed), `false -> 0` 30 sites. When it applied at more
    -- sites than the written text occurs, the verdict names it and the exact alternative, ground = 1
    do
        local fd0 = io.open(repo .. '/' .. p.file) -- (the ORIGINAL file: the copy is mutated by now)
        local src = fd0 and fd0:read('a') or ''
        if fd0 then fd0:close() end
        local n, at = 0, 1
        for _ = 1, 100000 do
            local i = src:find(p.before, at, true)
            if not i then break end
            n, at = n + 1, i + 1
        end
        if (v.sites or 0) > n then
            v.widened = ('the learned rule applied at %d site(s), the written text occurs at %d — ground=1 applies exactly it'):format(v.sites, n)
        end
    end
    -- 3. the MUTATED run
    local mut, mwhy = SF.run(root, p.spec, limit, env)
    if not mut then v.error = 'mutated run: ' .. tostring(mwhy); return done() end
    v.mutated = mut
    v.caught = mut.failed > 0
    return done()
end

local E = {
    name = 'mutation-check',
    kind = 'discovery',
    tags = { 'accept', 'repo' },
    measures = 'CART-1174',
    summary = 'does SPEC catch a mutation? file = the file to mutate, before/after = the mutation as an example (a chunk or an EXPRESSION), spec = the spec file name (e.g. tactic_spec); runs in a scratch COPY of repo (default: this cartograph), baseline first; keep = 1 keeps the copy; ground = 1 applies exactly the text written, at its one site — site = N its N-th occurrence, site = all every one (a duplicated block, CART-1569); timeout = seconds per run (default 600): a mutant that HANGS is CAUGHT (timed out), its process group killed',
    params = { file = 'string', before = 'string', after = 'string', spec = 'string', repo = 'string?', keep = 'string?', ground = 'string?', site = 'string?', timeout = 'string?', env = 'list?' },
    measure = measure,
    claim = function (v)
        if v.error then return false, v.error end
        local rules = table.concat(v.rules or {}, ', ')
        local widened = v.widened and (' ⚠ ' .. v.widened) or ''
        if v.caught then
            return true, ('CAUGHT: %s at %d site(s) in %s — %s: baseline %s, mutated %s%s'):format(rules, v.sites or 0, v.file, v.spec,
                v.baseline.summary, v.mutated.summary, widened)
        end
        -- ⚠ a survivor is a TEST GAP or an EQUIVALENT mutant (one that changes no behaviour) — the check cannot tell
        -- which; MEASURED on its first real run: `#e.point > #best` -> `>=` in namespace.lua survives, and equal-length
        -- containing points are the same point, so that one is equivalent. Say both, never "nothing pins this".
        return false, ('SURVIVED: %s at %d site(s) in %s — %s stays green (%s): a test gap, or an EQUIVALENT mutant (read the sites)%s')
            :format(rules, v.sites or 0, v.file, v.spec, v.mutated.summary, widened)
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
        -- (and the verdict SAYS the rule widened past the written text, naming ground=1 — CART-1457)
        expect = { holds = true, check = function (v)
            return (v.sites or 0) >= 2 and (v.widened or ''):find('ground=1', 1, true) ~= nil,
                'sites ' .. tostring(v.sites) .. ' widened ' .. tostring(v.widened) .. ' ' .. tostring(v.error)
        end },
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
        -- CART-1569: ` > 0` occurs twice (`x > 0`, `#t > 0`) — no context makes one copy of a duplicated block unique;
        -- `site = 2` mutates exactly the second, and only nonempty's check (the 4th) fails
        name = 'GROUND `site = N` mutates exactly the N-th occurrence of a text that occurs more than once',
        files = FX, params = function (store)
            local p = params('guard_spec', ' > 0', ' >= 0')(store); p.ground, p.site = '1', '2'; return p
        end,
        expect = { holds = true, check = function (v)
            local f = v.mutated and v.mutated.failures or {}
            return v.sites == 1 and #f == 1 and f[1] == 'check 4' and (v.rules[1] or ''):find('site 2 of 2', 1, true) ~= nil,
                'sites ' .. tostring(v.sites) .. ' failures ' .. vim.inspect(f) .. ' ' .. tostring(v.error)
        end },
    },
    {
        name = 'a GROUND `site` past the text\'s occurrences is refused by name',
        files = FX, params = function (store)
            local p = params('guard_spec', ' > 0', ' >= 0')(store); p.ground, p.site = '1', '3'; return p
        end,
        expect = { holds = false, check = function (v) return v.error and v.error:find('occurs 2 time', 1, true) ~= nil, tostring(v.error) end },
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
        -- (env reaches BOTH runs: under DERIVE=bad the fixture's env_spec is red at the baseline already — CART-1368's
        -- DERIVE=<op> mutation checks of a derivation ride this param)
        name = 'env = NAME=value reaches the runs: a spec red under that variable refuses at the baseline',
        files = FX, params = function (store)
            local p = params('env_spec', '#t > 0', '#t >= 0')(store); p.ground, p.env = '1', { 'DERIVE=bad' }; return p
        end,
        expect = { holds = false, check = function (v) return v.error and v.error:find('BASELINE is red', 1, true) ~= nil, tostring(v.error) end },
    },
    {
        name = 'a RED baseline refuses: it would catch every mutation',
        files = FX, params = params('broken_spec'),
        expect = { holds = false, check = function (v) return v.error and v.error:find('BASELINE is red', 1, true) ~= nil, tostring(v.error) end },
    },
}

-- (shared with mutation-campaign: the same scratch copy, git alternates included)
E.scratch_copy = scratch_copy
return E
