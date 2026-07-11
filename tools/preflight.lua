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
