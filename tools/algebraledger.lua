-- algebraledger — HOW MUCH OF THE PROTOTYPE IS ACTUALLY ABSORBED, derived.
--
-- ★★★ WHY A TOOL AND NOT A TABLE. The prototype carries its own mapping table
-- (ALGEBRA.md, "here | cartograph"), and by the time this was written one of its
-- rows was already wrong in our favour: `partition` still read "the near tier's
-- similarity threshold; no objective" after `clones.families` had been running
-- `A.partition` with MDL for a day. A hand-maintained ledger drifts in BOTH
-- directions, and the direction that flatters you is the one nobody checks.
-- Everything here is derived from the two trees on every run.
--
-- ★★ ABSORB MEANS GIVE IT A HOME, NOT MAKE A COPY (cartograph.algebra's header).
-- So "absorbed" is not "the code is present" — it is "a SHIPPED consumer calls
-- it". An arrow used only from `tools/` is a measurement, and one used only from
-- `tests/` is an assertion about the prototype, not a capability of cartograph.
-- The three tiers are reported separately for exactly that reason.
--
-- ⚠ IT READS THE PROTOTYPE AS TEXT, NEVER `dofile`s IT. The seam executes the
-- prototype deliberately and says so; a ledger has no reason to, and the path it
-- reads is the DECLARED one (`algebra.path()`), never a path from the analysed
-- tree — the same rule the seam states.
--
-- ★ THE GROUPING IS THE PROTOTYPE'S OWN. Sections come from its `-- ── title ──`
-- headers, so a flat "6 of 159" does not mislead: `terms` is plumbing and its
-- constructors are used everywhere, while `transplant` and `unification` are
-- capabilities and sit at zero. Attributing exports by hand would be a second
-- authority that drifts, which is the thing this file exists to avoid.

-- the same self-location every tool in here uses: resolve the repo from this
-- file's own path so the ledger runs from anywhere, including a pre-commit hook
local REPO = (debug.getinfo(1, 'S').source:match('@(.*)/tools/[^/]+$')) or '.'
package.path = REPO .. '/lua/?.lua;' .. REPO .. '/lua/?/init.lua;' .. package.path

local M = {}

local function read(path)
    local fd = io.open(path, 'r'); if not fd then return nil end
    local s = fd:read('*a'); fd:close(); return s
end

local function ls(dir, out)
    out = out or {}
    local p = io.popen(('find %q -name "*.lua" -type f 2>/dev/null'):format(dir))
    if not p then return out end
    for line in p:lines() do out[#out + 1] = line end
    p:close()
    return out
end

--- every `function M.x` in the prototype, attributed to its enclosing section
function M.exports(src)
    local sect, order, of = {}, {}, {}
    local cur = '(preamble)'
    sect[cur] = {}; order[#order + 1] = cur
    for line in src:gmatch('[^\n]*') do
        local title = line:match('^%-%- \226\148\128\226\148\128 (.-) [\226\148\128 ]*$')
            or line:match('^%-%- \226\148\128\226\148\128 (.+)$')
        if title then
            cur = title:gsub('[\226\148\128%s]+$', '')
            if not sect[cur] then sect[cur] = {}; order[#order + 1] = cur end
        else
            local fn = line:match('^function M%.([%w_]+)')
            if fn and not of[fn] then
                of[fn] = cur
                sect[cur][#sect[cur] + 1] = fn
            end
        end
    end
    return sect, order, of
end

--- the local each consumer binds the loaded algebra to — DERIVED, not assumed.
--- `clones.lua` writes `local A, why = alg.load()` and the seam writes
--- `local A = M.load()`; a tool that hardcoded `A` would silently miss any file
--- that picked another name, and report it as unabsorbed.
local function bindings(text)
    -- ⚠ LINE-ORIENTED AND WRAPPER-BLIND ON PURPOSE. Three shapes are in the
    -- tree already and a fourth will appear:
    --     local A       = alg.load()                     -- clones.lua
    --     local A, why  = alg.load()                     -- families
    --     local A       = assert(alg.load(), '...')      -- tools/familydiff.lua
    -- Matching the CALL rather than the expression around it covers all of them;
    -- the earlier `[%w_.]-load%(` form silently missed the assert-wrapped one.
    local names = {}
    for line in text:gmatch('[^\n]*') do
        local v = line:match('^%s*local%s+([%w_]+)%s*=.*load%s*%(')
            or line:match('^%s*local%s+([%w_]+)%s*,%s*[%w_]+%s*=.*load%s*%(')
        if v then names[v] = true end
    end

    -- ★ ONE LEVEL OF INDIRECTION, because the spec binds through a helper:
    --     local function need() ... return alg.load() end
    --     local A = need()
    -- The first cut matched only the direct form and reported 0 TEST-ONLY
    -- arrows while `join` and `unify` were sitting in `algebra_spec.lua`. An
    -- absorption ledger that UNDERCOUNTS reads as "less absorbed than we are",
    -- which is the flattering direction for a tool whose job is to find gaps —
    -- and therefore the one that would never have been questioned.
    local loaders, cur = {}, nil
    for line in text:gmatch('[^\n]*') do
        local fn = line:match('^%s*local function ([%w_]+)')
        if fn then cur = fn end
        if cur and line:match('return%s+[%w_]+%.load%s*%(') then loaders[cur] = true end
    end
    for v, f in text:gmatch('local%s+([%w_]+)%s*=%s*([%w_]+)%s*%(%s*%)') do
        if loaders[f] then names[v] = true end
    end
    return names
end

-- exposed for the spec: the binding shapes are where this tool's bugs live
M._bindings = bindings

--- count uses of each arrow, per tier
function M.uses(root, arrows)
    M.unbound = {}
    local tiers = { lua = {}, tools = {}, tests = {} }
    local _ = root
    for tier, dir in pairs { lua = root .. '/lua', tools = root .. '/tools', tests = root .. '/tests' } do
        for _, f in ipairs(ls(dir)) do
            local text = read(f)
            -- ⚠ NOT ITSELF. This file names the arrows in its own prose (`A.partition`
            -- in the header), so it looks like a consumer that binds nothing. A
            -- measurement that includes the measuring instrument reports the
            -- instrument.
            if f:find('algebraledger%.lua$') then text = nil end
            if text and text:find('cartograph.algebra', 1, true) then
                local vars = bindings(text)
                -- ⚠ ABSENCE RENDERED AS SILENCE IS THE FAILURE MODE HERE. A file
                -- that requires the algebra but binds it in a shape this does
                -- not recognise contributes ZERO, which is indistinguishable
                -- from "uses nothing". Say so instead.
                if not next(vars) then
                    -- ⚠ ONLY WARN IF THE FILE ACTUALLY REACHES FOR AN ARROW.
                    -- `health.lua` requires the algebra to ask `available()` and
                    -- touches no operator at all; flagging it would be a fence
                    -- that cries wolf, and a warning nobody believes is worse
                    -- than none.
                    local reaches = false
                    for a in pairs(arrows) do
                        if text:find('%.' .. a .. '%f[^%w_]') then reaches = true; break end
                    end
                    if reaches then
                        M.unbound[#M.unbound + 1] = f:gsub('^' .. (root or ''), '')
                    end
                end
                for v in pairs(vars) do
                    for a in pairs(arrows) do
                        local n = select(2, text:gsub(v .. '%.' .. a .. '%f[^%w_]', ''))
                        if n > 0 then tiers[tier][a] = (tiers[tier][a] or 0) + n end
                    end
                end
            end
        end
    end
    return tiers
end

function M.run(opts)
    opts = opts or {}
    local alg = require 'cartograph.algebra'
    local path, declared = alg.path()
    local src = path and read(path)
    if not src then
        print(('algebraledger: cannot read the prototype at %s (declared by %s)')
            :format(tostring(path), tostring(declared)))
        return 1
    end
    local root = opts.root or REPO
    local sect, order, of = M.exports(src)
    local arrows = {}
    for a in pairs(of) do arrows[a] = true end
    local nexp = 0; for _ in pairs(arrows) do nexp = nexp + 1 end
    local tiers = M.uses(root, arrows)

    local shipped, harness, testonly, absent = {}, {}, {}, {}
    for a in pairs(arrows) do
        if (tiers.lua[a] or 0) > 0 then shipped[a] = true
        elseif (tiers.tools[a] or 0) > 0 then harness[a] = true
        elseif (tiers.tests[a] or 0) > 0 then testonly[a] = true
        else absent[a] = true end
    end
    local function count(t) local n = 0; for _ in pairs(t) do n = n + 1 end; return n end

    print(('ALGEBRA ABSORPTION LEDGER'))
    print(('  prototype: %s  (declared by %s)'):format(path, declared))
    print(('  exports: %d'):format(nexp))
    print(('    SHIPPED  (a consumer in lua/):  %3d'):format(count(shipped)))
    print(('    HARNESS  (tools/ only):         %3d'):format(count(harness)))
    print(('    TEST     (tests/ only):         %3d'):format(count(testonly)))
    print(('    ABSENT   (no consumer at all):  %3d'):format(count(absent)))
    print('')
    print(('  %-58s %5s %5s %5s %5s'):format('section (the prototype\'s own)', 'exp', 'ship', 'harn', 'test'))
    for _, s in ipairs(order) do
        local list = sect[s]
        if #list > 0 then
            local e, sh, h, t = #list, 0, 0, 0
            for _, a in ipairs(list) do
                if shipped[a] then sh = sh + 1
                elseif harness[a] then h = h + 1
                elseif testonly[a] then t = t + 1 end
            end
            local mark = (sh == 0 and e > 0) and '  <- nothing shipped' or ''
            print(('  %-58s %5d %5d %5d %5d%s'):format(s:sub(1, 58), e, sh, h, t, mark))
        end
    end
    if opts.verbose then
        print('\n  SHIPPED arrows:')
        local names = {}; for a in pairs(shipped) do names[#names + 1] = a end
        table.sort(names)
        for _, a in ipairs(names) do
            print(('    %-20s lua %d  tools %d  tests %d'):format(a,
                tiers.lua[a] or 0, tiers.tools[a] or 0, tiers.tests[a] or 0))
        end
    end

    -- ★ THE RATCHET. A ledger nobody gates is a report, and a report that only
    -- goes up when someone looks is not a measurement. `--min N` fails when the
    -- shipped count DROPS, which is the regression worth catching: an arrow
    -- losing its last shipped consumer looks like a refactor, not a loss.
    if opts.min and count(shipped) < opts.min then
        print(('\nalgebraledger: FAIL — %d shipped arrows, floor is %d')
            :format(count(shipped), opts.min))
        return 1
    end
    if #(M.unbound or {}) > 0 then
        print('\n  \226\154\160 files that require the algebra but bind it in an unrecognised shape')
        print('    (their uses are NOT counted above — fix the binding detection, not the file):')
        for _, f in ipairs(M.unbound) do print('      ' .. f) end
    end
    print('\nalgebraledger: ok')
    return 0
end

if not pcall(debug.getlocal, 4, 1) then
    local opts = { verbose = false }
    for _, a in ipairs(vim.v.argv or {}) do
        if a == '--verbose' then opts.verbose = true end
        local m = a:match('^%-%-min=(%d+)$'); if m then opts.min = tonumber(m) end
    end
    os.exit(M.run(opts))
end
return M
