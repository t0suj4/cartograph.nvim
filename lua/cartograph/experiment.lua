-- experiment — a DECLARED EXPERIMENT: a variant, a baseline, instruments, a decision (CART-1537, the wind tunnel's first
-- piece). Every mix / saturate commit of 2026-10-07 was gated BY HAND with the same battery — specs, derive-accept plain /
-- through / fuzz, the compiled-matcher regression, a row join of mix's sets against a baseline worktree, a fair A/B —
-- and each re-composition by hand was a chance to mis-run one (a cd that bound to the first job only, a harness edited
-- mid-loop, a ±12-line window). This module runs such a battery from DATA.
--
-- THE DECLARATION
--   decl = { name, baseline = '<git ref>' (a scratch worktree; nil: no baseline — tactic / specs instruments only),
--            variant = '<git ref>' (nil: the working tree), instruments = { inst… } }
--   inst = { name, kind, … }:
--     tactic : tactic = '<toolbelt entry>', params = { k = v }, expect = 'holds' | 'fails'   (in the variant), or
--              compare = '<Lua pattern>' — run in both trees, pass when the claim line's capture is the same (no regression),
--              or with better = { 'up' | 'down'… } when each captured number moved only its way
--     specs  : specs = { '<spec basename>'… }                                              (in the variant)
--     check  : file = '<throwaway>' | tactic = '<entry>', params, pattern = '<Lua pattern>' — passes when the output has it
--     join   : file = '<throwaway>', params — run in BOTH trees; its `ROW\t<key>\t<value>` lines are joined by key, and
--              pass = no joined key's value differs (keys on one side only are counted, not judged)
--     ab     : file = '<throwaway>' | tactic = '<entry>', params, extract = '<Lua pattern capturing a number>', runs = 5,
--              bound = 1.10 — FRESH PROCESS per run, baseline and variant INTERLEAVED, MEDIAN per side; pass = variant
--              median <= baseline median x bound (higher_is_better = true flips it)
--   CONDITIONS (decl.conditions = { { name, nvim = { argv… }, vars = { NAME = value } }… }, CART-1537): the same
--     instrument under several conditions of the run — `nvim` arguments go right after `nvim` (e.g. { '--cmd',
--     'lua jit.off()' }: the JIT off before the script loads), `vars` into the environment. An instrument runs under
--     `conditions = { names… } | 'all'`, by default the FIRST condition only; one row per instrument and condition, and an
--     A/B compares baseline and variant under the SAME condition (cost is the target's: the ranking may differ). A specs
--     instrument runs tests/run.sh, which starts nvim itself: a condition's `nvim` arguments do not reach it (refused
--     by name), its `vars` do.
--   the DECISION: accept when every instrument passes.
-- THE ENVIRONMENT (injected, so the logic is testable without processes)
--   env = { root = '<repo>', exec = function (dir, argv, vars) -> output, code,
--           worktree = function (ref) -> dir, drop = function (dir) }
local M = {}

local function median(xs)
    local s = {}
    for i, x in ipairs(xs) do s[i] = x end
    table.sort(s)
    local n = #s
    if n == 0 then return nil end
    if n % 2 == 1 then return s[(n + 1) / 2] end
    return (s[n / 2] + s[n / 2 + 1]) / 2
end
M.median = median

local function kv_args(params)
    local ks, out = {}, {}
    for k in pairs(params or {}) do ks[#ks + 1] = k end
    table.sort(ks)
    for _, k in ipairs(ks) do out[#out + 1] = k .. '=' .. tostring(params[k]) end
    return out
end
-- the toolbelt invocation of an entry or a throwaway file, in a tree (its OWN toolbelt: the tree's code is what runs),
-- under a condition (its nvim arguments right after `nvim`)
local function toolbelt(inst, cond)
    local argv = { 'nvim' }
    for _, a in ipairs(cond and cond.nvim or {}) do argv[#argv + 1] = a end
    for _, a in ipairs({ '--headless', '-u', 'NONE', '-l', 'tools/toolbelt.lua', 'run', inst.file and ('@' .. inst.file) or inst.tactic, '-' }) do argv[#argv + 1] = a end
    for _, a in ipairs(kv_args(inst.params)) do argv[#argv + 1] = a end
    return argv
end
M.toolbelt_argv = toolbelt

--- the toolbelt's verdict off its output: holds (true / false / nil when unreadable) and why
function M.verdict(out)
    local holds = out:match('\n%s*holds = (%a+),') or out:match('^{%s*holds = (%a+),')
    local why = out:match('\n%s*why = ("[^\n]*"),?\n') or out:match("\n%s*why = ('[^\n]*'),?\n")
    if why then local ok, w = pcall(load('return ' .. why)); why = ok and w or why end
    local refused = out:match('refused: ([^\n]*)')
    -- (explicit branches: `h == 'false' and false or nil` is nil — the and/or trap with false)
    local h
    if holds == 'true' then h = true elseif holds == 'false' then h = false elseif refused then h = false end -- (a refused run fails)
    return h, why or refused
end

local function rows_of(out)
    local rows, n = {}, 0
    for k, v in out:gmatch('\nROW\t([^\t\n]*)\t([^\n]*)') do rows[k] = v; n = n + 1 end
    return rows, n
end

local RUN = {}
function RUN.tactic(inst, trees, env, cond)
    local out = env.exec(trees.variant, toolbelt(inst, cond), cond and cond.vars)
    local holds, why = M.verdict('\n' .. out)
    -- compare = '<pattern>': NO REGRESSION instead of a verdict — the tactic runs in the baseline too, and the variant
    -- passes when the pattern's capture is the SAME on both sides (a claim the baseline already fails, e.g. a known
    -- refusal, is no reason to reject a change that leaves it as it was)
    if inst.compare then
        if not trees.baseline then return { pass = false, detail = 'compare needs a baseline' } end
        local _, bwhy = M.verdict('\n' .. env.exec(trees.baseline, toolbelt(inst, cond), cond and cond.vars))
        local cb, cv = tostring(bwhy or ''):match(inst.compare), tostring(why or ''):match(inst.compare)
        if not cb or not cv then return { pass = false, detail = ('the compare pattern matched baseline %s / variant %s'):format(tostring(cb), tostring(cv)) } end
        if cb == cv then return { pass = true, baseline = cb, variant = cv, detail = 'as the baseline: ' .. cv } end
        -- better = { 'up' | 'down'… }: the capture's NUMBERS, in order, may each move only that way (an improvement passes)
        local pass = false
        if inst.better then
            local nb, nv = {}, {}
            for x in cb:gmatch('%-?[%d.]+') do nb[#nb + 1] = tonumber(x) end
            for x in cv:gmatch('%-?[%d.]+') do nv[#nv + 1] = tonumber(x) end
            pass = #nb == #inst.better and #nv == #nb
            for i, dir in ipairs(inst.better) do
                if pass and ((dir == 'up' and nv[i] < nb[i]) or (dir == 'down' and nv[i] > nb[i])) then pass = false end
            end
        end
        return { pass = pass, baseline = cb, variant = cv, detail = ('baseline %s -> variant %s%s'):format(cb, cv, pass and ' (no worse)' or '') }
    end
    local want = (inst.expect or 'holds') == 'holds'
    return { pass = holds ~= nil and holds == want, detail = (holds == nil and 'no verdict: ' or '') .. tostring(why) }
end
function RUN.specs(inst, trees, env, cond)
    if cond and cond.nvim and #cond.nvim > 0 then return { pass = false, detail = 'condition ' .. tostring(cond.name) .. ': its nvim arguments cannot reach tests/run.sh' } end
    local vars = { SPEC = table.concat(inst.specs, ',') }
    for k, v in pairs(cond and cond.vars or {}) do vars[k] = v end
    local out = env.exec(trees.variant, { 'bash', 'tests/run.sh' }, vars)
    local p, f, s = out:match('(%d+) passed, (%d+) failed, (%d+) skipped')
    p, f = tonumber(p), tonumber(f)
    return { pass = p ~= nil and f == 0 and p > 0, detail = p and ('%d passed, %d failed, %s skipped'):format(p, f, s) or 'no summary line' }
end
function RUN.check(inst, trees, env, cond)
    local out = env.exec(trees.variant, toolbelt(inst, cond), cond and cond.vars)
    local hit = out:match(inst.pattern)
    return { pass = hit ~= nil, detail = hit and ('matched ' .. inst.pattern) or ('no match for ' .. inst.pattern .. ': ' .. (out:match('[^\n]*\n?$') or ''):sub(1, 160)) }
end
function RUN.join(inst, trees, env, cond)
    if not trees.baseline then return { pass = false, detail = 'a join needs a baseline' } end
    local a, na = rows_of('\n' .. env.exec(trees.baseline, toolbelt(inst, cond), cond and cond.vars))
    local b, nb = rows_of('\n' .. env.exec(trees.variant, toolbelt(inst, cond), cond and cond.vars))
    local joined, differ, only_a, only_b, first = 0, 0, 0, 0, nil
    local ks = {}
    for k in pairs(a) do ks[#ks + 1] = k end
    table.sort(ks)
    for _, k in ipairs(ks) do
        if b[k] == nil then only_a = only_a + 1
        else
            joined = joined + 1
            if a[k] ~= b[k] then differ = differ + 1; first = first or k end
        end
    end
    for k in pairs(b) do if a[k] == nil then only_b = only_b + 1 end end
    return { pass = joined > 0 and differ == 0, joined = joined, differ = differ, only_baseline = only_a, only_variant = only_b,
        detail = ('%d rows joined, %d differ, %d / %d on one side only%s'):format(joined, differ, only_a, only_b,
            joined == 0 and (' — NOTHING JOINED (%d / %d rows)'):format(na, nb) or (first and (', first ' .. first) or '')) }
end
function RUN.ab(inst, trees, env, cond)
    if not trees.baseline then return { pass = false, detail = 'an A/B needs a baseline' } end
    local runs, base, var = inst.runs or 5, {}, {}
    for _ = 1, runs do
        for _, side in ipairs({ 'baseline', 'variant' }) do -- (INTERLEAVED: a drift of the machine hits both sides)
            local out = env.exec(trees[side], toolbelt(inst, cond), cond and cond.vars)
            local x = tonumber(out:match(inst.extract))
            if x then table.insert(side == 'baseline' and base or var, x) end
        end
    end
    local mb, mv = median(base), median(var)
    if not mb or not mv then return { pass = false, detail = ('the pattern matched %d / %d runs'):format(#base, #var) } end
    local bound = inst.bound or 1.10
    local pass
    if inst.higher_is_better then pass = mv >= mb / bound else pass = mv <= mb * bound end
    return { pass = pass, baseline = mb, variant = mv, ratio = mv / mb,
        detail = ('median %.4g -> %.4g (x%.3f, bound x%.2f, %d runs each)'):format(mb, mv, mv / mb, bound, runs) }
end
M.RUN = RUN

--- run a declaration -> { name, accept, rows = { { name, kind, pass, detail, … } } }. The worktrees are made first and
--- dropped last, whatever an instrument did
function M.run(decl, env)
    local trees, made = {}, {}
    local function tree(ref) if ref == nil then return env.root end local d = env.worktree(ref); made[#made + 1] = d; return d end
    local ok, res = pcall(function ()
        trees.variant = tree(decl.variant)
        if decl.baseline then trees.baseline = tree(decl.baseline) end
        local rows = {}
        for _, inst in ipairs(decl.instruments or {}) do
            -- (a RELATIVE instrument file is the VARIANT checkout's: both sides run the same instrument, even when the
            -- baseline predates it — the instrument measures each tree's code, it is not that code)
            if inst.file and inst.file:sub(1, 1) ~= '/' then inst = vim.deepcopy(inst); inst.file = env.root .. '/' .. inst.file end
            local run = RUN[inst.kind]
            local conds, all = {}, decl.conditions or { { name = 'default' } }
            if inst.conditions == 'all' then conds = all
            elseif type(inst.conditions) == 'table' then
                for _, nm in ipairs(inst.conditions) do
                    local c
                    for _, x in ipairs(all) do if x.name == nm then c = x end end
                    conds[#conds + 1] = c or { name = nm, missing = true }
                end
            else conds = { all[1] } end
            for _, cond in ipairs(conds) do
                local r
                if not run then r = { pass = false, detail = 'no instrument kind ' .. tostring(inst.kind) }
                elseif cond.missing then r = { pass = false, detail = 'no condition ' .. tostring(cond.name) .. ' declared' }
                else
                    local okr, rr = pcall(run, inst, trees, env, cond)
                    r = okr and rr or { pass = false, detail = 'the instrument raised: ' .. tostring(rr) }
                end
                r.name, r.kind, r.condition = (inst.name or inst.kind) .. (#all > 1 and (' [' .. tostring(cond.name) .. ']') or ''), inst.kind, cond.name
                rows[#rows + 1] = r
            end
        end
        local accept = #rows > 0
        for _, r in ipairs(rows) do if not r.pass then accept = false end end
        return { name = decl.name, accept = accept, rows = rows }
    end)
    for _, d in ipairs(made) do pcall(env.drop, d) end
    if not ok then error(res, 0) end
    return res
end

return M
