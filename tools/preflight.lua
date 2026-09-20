-- PREFLIGHT: the dev loop as one command.
--   nvim --headless -u NONE -l tools/preflight.lua [--fast]
-- 1. IMPACT — parse `git diff HEAD -U0`, map changed lines to functions,
--    reverse call cone, and the specs whose require-cones reach any
--    touched file (lua/cartograph/preflight.lua, the pure core).
-- 2. GUARDS — the development lints on this repo (tools/guards.lua).
-- 3. SUITE — the full spec run, or with --fast only the affected specs
--    (SPEC= selection; import-cone based, so the FULL suite still guards
--    the actual push).
-- Exit 1 if anything fails.
--
-- ⚠ THIS IS STEPS 1-3 OF [[cartograph-refactor-playbook]], NOT ALL FIVE, and the
-- two that are missing are missing ON PURPOSE:
--   4. GATE THE CORPORA THAT EXERCISE THE CHANGE — the playbook picks the corpus
--      from what the change TOUCHES (guards→lua+php, taint→grocy,
--      receiver-typing→java, ecosystem→factorio/se). That choice is judgement,
--      and a runner that guessed it would gate the wrong tree and report OK.
--      Run `tools/gate.lua <corpus>` yourself.
--   5. PROVE NEUTRALITY against a stale baseline — the playbook's method is to
--      capture the gate diff WITH and WITHOUT the change, which means `git stash`
--      around a long gate run. That is a known way to lose work and it is not
--      something a tool should do unasked. Reported, never performed.

local here = debug.getinfo(1, 'S').source:sub(2)
local repo = vim.fn.fnamemodify(here, ':p:h:h')
vim.opt.rtp:prepend(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter'))
package.path = repo .. '/lua/?.lua;' .. repo .. '/lua/?/init.lua;' .. package.path

local fast = false
for _, a in ipairs(arg or {}) do
    if a == '--fast' then fast = true end
end

-- ── impact ────────────────────────────────────────────────────────────
local changed, nlines, nonlua = {}, 0, nil
do
    -- UNTRACKED lua files are invisible to `git diff HEAD` — count every
    -- line of a new file as changed (preflight's own first run missed
    -- its own three new files)
    local untracked = vim.fn.system(('git -C %s ls-files --others --exclude-standard')
        :format(vim.fn.shellescape(repo)))
    for f in untracked:gmatch('[^\n]+') do
        if f:match('%.lua$') then
            local fd = io.open(repo .. '/' .. f, 'r')
            if fd then
                local lines, l = {}, 0
                for _ in fd:lines() do
                    l = l + 1
                    lines[l] = l
                end
                fd:close()
                changed[f] = lines
                nlines = nlines + l
            end
        end
    end
    local diff = vim.fn.system(('git -C %s diff HEAD -U0 --no-color')
        :format(vim.fn.shellescape(repo)))
    local file
    for line in diff:gmatch('[^\n]+') do
        local nf = line:match('^%+%+%+ b/(.+)$')
        if nf then
            file = nf ~= '/dev/null' and nf or nil
        else
            local start, count = line:match('^@@ %-[%d,]+ %+(%d+),?(%d*) @@')
            if start and file and not file:match('%.lua$') then
                nonlua = (nonlua or 0) + 1
                file = nil -- count once, then stop attributing its hunks
            end
            if start and file and file:match('%.lua$') then
                local s, c = tonumber(start), tonumber(count) or 1
                if c > 0 then
                    changed[file] = changed[file] or {}
                    for l = s, s + c - 1 do
                        table.insert(changed[file], l)
                        nlines = nlines + 1
                    end
                end
            end
        end
    end
end

local failures = 0
if not next(changed) then
    -- say what we MEAN: non-lua changes are invisible to impact by design
    print(nonlua
        and ('impact: no lua changes (%d non-lua file(s) changed — outside impact scope)')
            :format(nonlua)
        or 'impact: working tree clean vs HEAD — nothing to select')
else
    local ts = require 'cartograph.providers.treesitter'
    local store = require 'cartograph.store'
    store.ingest(ts.extract(repo))
    local a = require('cartograph.preflight').affected(store, changed)
    local nf = 0
    for _ in pairs(changed) do nf = nf + 1 end
    print(('impact: %d changed lines in %d files → %d functions, +%d in the reverse cone')
        :format(nlines, nf, #a.fns, #a.cone))
    -- module-level changes (outside any fn) still select specs via the
    -- files set, but say so — file-wide impact is not zero impact
    do
        local unattr = 0
        for file, lines in pairs(changed) do
            local hit = {}
            for _, id in ipairs(a.fns) do
                local n = store.node(id)
                if n and n.file == file then hit[#hit + 1] = n end
            end
            for _, l in ipairs(lines) do
                local inside = false
                for _, n in ipairs(hit) do
                    local atr = require 'cartograph.at'
                    if l >= atr.sl(n.range) + 1 and l <= atr.el(n.range) + 1 then
                        inside = true break
                    end
                end
                if not inside then unattr = unattr + 1 end
            end
        end
        if unattr > 0 then
            print(('  (%d lines at module level — file-wide impact, spec selection covers the files)')
                :format(unattr))
        end
    end
    for _, id in ipairs(a.fns) do print('  changed  ' .. id) end
    for i = 1, math.min(#a.cone, 12) do print('  affected ' .. a.cone[i]) end
    if #a.cone > 12 then print(('  … %d more in the cone'):format(#a.cone - 12)) end
    if #a.specs > 0 then
        local names = {}
        for _, sp in ipairs(a.specs) do
            names[#names + 1] = sp:match('([^/]+)%.lua$')
        end
        print(('specs reached (%d): %s'):format(#a.specs, table.concat(names, ',')))
        if fast then vim.env.SPEC = table.concat(names, ',') end
    elseif fast then
        print('specs reached: none via require-cones — running the full suite')
    end
end

-- ── load ──────────────────────────────────────────────────────────────
-- THE PLAYBOOK'S STEP 1, WIRED (C3). [[cartograph-refactor-playbook]] opens with
-- "`require` both modules headless → load check (LOADED OK)", and
-- [[cartograph-acceleration-map]] records that STEP 1 ALONE WOULD HAVE CAUGHT C1
-- AUTOMATICALLY — CART-0542, an applied extract that wrote a file with no
-- `local M = {}` and no `return M`. That was found by hand and fixed by hand,
-- and until now nothing would have caught the next one.
--
-- ⚠⚠ A MODULE IS REQUIRED; A SCRIPT IS ONLY COMPILED. `tools/*.lua` and
-- `tests/*.lua` are SCRIPTS: requiring one RUNS it, so a changed `tools/gate.lua`
-- would launch a gate from inside preflight. They are loadfile'd instead —
-- which catches syntax and nothing else, and the difference is stated rather
-- than silently applied to everything.
--
-- ⚠ NEVER `luac -p`. The playbook's own gotcha: it cannot parse goto/labels that
-- nvim's Lua accepts, so a check built on it FAILS A FILE THAT IS FINE. This runs
-- inside nvim for exactly that reason.
local loadfails = 0
do
    -- ⚠ LIVING UNDER lua/ DOES NOT MAKE IT A MODULE, and the file says so itself:
    -- worker.lua opens "NOT a module: run as nvim ... -l worker.lua <job.json>"
    -- and requiring it errors "worker: no job file". Declared here rather than
    -- sniffed out of the header, because a prose matcher over comments is a guess
    -- and a named list of one with its reason is a fact. Swept the tree to find
    -- it: 233 modules, 209 tables, 23 functions, 1 of these.
    local NOT_A_MODULE = {
        ['cartograph.worker'] = 'declares "NOT a module" in its first line — it needs a job file',
    }
    local mods, scripts = {}, {}
    for f in pairs(changed) do
        local mod = f:match('^lua/(cartograph.*)%.lua$')
        mod = mod and mod:gsub('/', '.'):gsub('%.init$', '')
        if mod and not NOT_A_MODULE[mod] then mods[#mods + 1] = mod
        elseif f:match('%.lua$') then scripts[#scripts + 1] = f end
    end
    table.sort(mods); table.sort(scripts)
    for _, m in ipairs(mods) do
        package.loaded[m] = nil
        local ok, val = pcall(require, m)
        if not ok then
            print(('  LOAD FAILED  %s — %s'):format(m, tostring(val):gsub('\n.*', '')))
            loadfails = loadfails + 1
        elseif type(val) == 'boolean' then
            -- ⚠⚠ THE C1 SHAPE, AND `require` ALONE DOES NOT CATCH IT. A file with
            -- no `return M` REQUIRES CLEANLY and hands back `true` — measured:
            -- the module that CART-0542 wrote would have passed a plain load
            -- check, which is the check the playbook prescribes and the
            -- acceleration map credits with catching it. It would not have.
            -- What separates a module from a fragment is that it RETURNED
            -- SOMETHING; `true` means the chunk fell off its end.
            -- ⚠ NOT "must return a table": algebra parts return a FUNCTION
            -- (`return function (M, SHARED)`), and a rule written against the
            -- common case would fail 24 correct files.
            print(('  RETURNS NOTHING  %s — it loads, but the chunk returns no value,'
                .. ' so every `require` of it yields `true` (the CART-0542 shape)'):format(m))
            loadfails = loadfails + 1
        end
    end
    for _, f in ipairs(scripts) do
        local fn, err = loadfile(repo .. '/' .. f)
        if not fn then
            print(('  PARSE FAILED %s — %s'):format(f, tostring(err):gsub('\n.*', '')))
            loadfails = loadfails + 1
        end
    end
    print(('load: %d module(s) required, %d script(s) parsed%s')
        :format(#mods, #scripts, loadfails > 0 and (' — ' .. loadfails .. ' FAILED') or ' — OK'))
    if loadfails > 0 then failures = failures + 1 end
end

-- ── guards ────────────────────────────────────────────────────────────
local g = vim.fn.system(('nvim --headless -u NONE -l %s/tools/guards.lua 2>&1')
    :format(vim.fn.shellescape(repo)))
print((g:gsub('%s+$', ''))) -- parens: gsub's count must not leak into print
if vim.v.shell_error ~= 0 then failures = failures + 1 end

-- ── suite ─────────────────────────────────────────────────────────────
local env = (fast and vim.env.SPEC) and ('SPEC=' .. vim.env.SPEC .. ' ') or ''
local out = vim.fn.system(('cd %s && %s./tests/run.sh 2>&1')
    :format(vim.fn.shellescape(repo), env))
print(((out:match('(%d+ passed[^\n]*)') or out):gsub('%s+$', '')))
if vim.v.shell_error ~= 0 then failures = failures + 1 end

print(failures == 0 and 'preflight: OK' or 'preflight: FAILED')
if failures > 0 then os.exit(1) end
