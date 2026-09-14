-- The VENDORING of the algebra (CART-0912). The code is cartograph's own now;
-- these guard the three claims that ownership makes and that nothing else checks:
--
--   1. the seam loads the IN-TREE module and no longer reads the donor at all
--   2. the drift fence classifies all FOUR outcomes, not just the happy one
--   3. the ledger still excludes the algebra from its own consumer count
--
-- (3) is the one that would rot quietly: `core.lua` is skipped today partly
-- because it does not contain the string the consumer scan greps for, so an
-- exclusion that looks deliberate could in fact be an accident of the guard.

local alg = require 'cartograph.algebra'
local drift = dofile(vim.fn.getcwd() .. '/tools/vendordrift.lua')
local led = dofile(vim.fn.getcwd() .. '/tools/algebraledger.lua')

--- ★★★ THE SWITCH, PROVEN BY ITS ABSENCE OF AN EFFECT. Pointing the DONOR path
--- at nothing used to make the seam unavailable; after the vendoring it must
--- change nothing at all. Asserting `load() ~= nil` alone would pass on the old
--- code too, because the default path exists on this machine.
test('algebra vendoring: the seam loads the in-tree module, not the donor', function ()
    local core = require 'cartograph.algebra.core'
    eq(core, alg.load())

    local saved = os.getenv('CARTOGRAPH_ALGEBRA')
    vim.fn.setenv('CARTOGRAPH_ALGEBRA', '/nonexistent/algebra.lua')
    package.loaded['cartograph.algebra'] = nil
    local fresh = require 'cartograph.algebra'
    local okf, whyf = fresh.available()
    vim.fn.setenv('CARTOGRAPH_ALGEBRA', saved)
    package.loaded['cartograph.algebra'] = nil
    require 'cartograph.algebra'

    ok(okf, 'an unreadable DONOR path no longer makes the algebra unavailable: '
        .. tostring(whyf))
    ok(tostring(whyf):find('from '), 'and it still says where it came from')
    ok(tostring(whyf):find('vendored'), 'naming the vendoring: ' .. tostring(whyf))
end)

--- the stamp is not decoration: `vendordrift` compares BOTH sides to it, so a
--- stamp that does not describe the file it sits beside makes every state wrong.
--- ⚠ BUT IT IS A RECORD OF THE PAST, NOT A CLAIM ABOUT THE PRESENT (CART-0916).
--- The first cut asserted `o.lines` against the CURRENT file and so became a
--- freeze on ever editing the copy — which contradicts the design it guards,
--- where DIVERGED is the plan. The line count is checked only while the fence
--- itself says nothing has moved.
test('algebra vendoring: the origin stamp describes the file beside it', function ()
    local o = require 'cartograph.algebra.origin'
    eq(64, #o.sha256)
    eq(40, #o.donor_rev)
    ok(o.vendored_at:match('^%d%d%d%d%-%d%d%-%d%d$'), 'a dated stamp: ' .. tostring(o.vendored_at))

    local state = drift.check(drift.units[1]).state
    if state ~= 'IDENTICAL' then
        -- an adapted copy is the goal, not a failure; `vendordrift` owns the
        -- comparison and reports it as DIVERGED
        return
    end
    local n = 0
    for _ in io.lines(vim.fn.getcwd() .. '/lua/cartograph/algebra/core.lua') do n = n + 1 end
    eq(o.lines, n)
end)

--- ★★★ ALL FOUR STATES, against synthetic files. Only IDENTICAL is reachable
--- from the real pair on a clean tree, and a fence exercised in one state is a
--- fence whose other branches are prose.
test('algebra vendoring: the drift fence separates WE moved from THEY moved', function ()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    local function put(name, body)
        local p = dir .. '/' .. name
        local fd = assert(io.open(p, 'wb')); fd:write(body); fd:close()
        return p
    end
    local same_a, same_b = put('a.lua', 'return 1\n'), put('b.lua', 'return 1\n')
    local other = put('c.lua', 'return 2\n')

    -- the stamp records the sha of `return 1`
    local sha = drift.check {
        name = 'probe', copy = same_a, stamp = { sha256 = '' },
        donor = function () return same_b end,
    }
    local real = sha.copy_sha
    ok(#real == 64, 'a sha was computed')

    local function state(copy, donor)
        return drift.check {
            name = 'probe', copy = copy, stamp = { sha256 = real },
            donor = function () return donor end,
        }.state
    end

    eq('IDENTICAL', state(same_a, same_b))
    eq('DIVERGED', state(other, same_b))
    eq('ORIGIN MOVED', state(same_a, other))
    eq('BOTH MOVED', state(other, put('d.lua', 'return 3\n')))
    -- ⚠ an unreadable donor is UNAVAILABLE, never IDENTICAL: reporting a match
    -- for "could not look" is the absence-as-plausible-positive shape
    eq('UNAVAILABLE', state(same_a, dir .. '/missing.lua'))
    vim.fn.delete(dir, 'rf')
end)

--- ★★★ THE EXCLUSION MUST BE DELIBERATE. The algebra's own 6001 lines call its
--- own arrows constantly; counting them would report every export as shipped.
--- This drives `M.uses` over a fixture whose ONLY file is under the vendored
--- directory AND binds the algebra in a recognised shape — the exact case the
--- accidental exclusion would miss.
test('algebra vendoring: the ledger does not count the algebra as its own consumer', function ()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root .. '/lua/cartograph/algebra', 'p')
    vim.fn.mkdir(root .. '/tools', 'p')
    vim.fn.mkdir(root .. '/tests', 'p')
    local body = [[
local alg = require 'cartograph.algebra'
local A = alg.load()
local x = A.generalize(1, 2)
]]
    local fd = assert(io.open(root .. '/lua/cartograph/algebra/core.lua', 'wb'))
    fd:write(body); fd:close()

    local tiers = led.uses(root, { generalize = true })
    eq(nil, tiers.lua.generalize)

    -- and the same file ANYWHERE ELSE in lua/ is counted, so the test is not
    -- passing because `uses` stopped working
    local fd2 = assert(io.open(root .. '/lua/cartograph/elsewhere.lua', 'wb'))
    fd2:write(body); fd2:close()
    local t2 = led.uses(root, { generalize = true })
    ok((t2.lua.generalize or 0) > 0, 'a consumer outside the algebra IS counted')
    vim.fn.delete(root, 'rf')
end)

--- ★★★ THE PARTS PROTOCOL IS A HAND-WRITTEN DEPENDENCY, AND THIS IS WHAT MAKES IT
--- VISIBLE (CART-0912). `core.lua` ends with
---     local PARTS = { vsym = vsym, slice = slice, … }
---     require('cartograph.algebra.hopau')(M, PARTS)
--- and each part opens `return function (M, SHARED)` and binds what it needs.
--- ⚠ THE PARAMETER IS CALLED `SHARED` BECAUSE THIS FENCE READS IT BY NAME. It
--- was `S` first, and `termgraph` has its own `local S` — the term-graph store —
--- so the fence reported `termgraph reads S.eqs` twice. A text predicate over a
--- one-letter name is the same mistake this session filed three times in the
--- tool; here the collision was mine, and the fix is a name nothing else uses.
--- NO ANALYSIS KNOWS THAT SHAPE: the linker sees a call, not a protocol, so a
--- local leaving `core` takes the other parts down with it and nothing says so
--- until something runs. Both halves have already bitten —
---   `key` read by a part and NOT in PARTS  -> "attempt to call global 'key'"
---   a local that travels out of core        -> PARTS hands round a nil
--- so the fence checks the THREE sets against each other.
---
--- ⚠ IT IS A TEXT CHECK ON PURPOSE, and says so: the shape is four lines of Lua
--- in one file, and a parser for it would be a second authority on a convention
--- this spec IS the authority for. What it must not do is pass by finding
--- nothing — hence the floor assertions on each set.
test('algebra parts: what a part reads, core supplies, and core still defines', function ()
    local dir = vim.fn.getcwd() .. '/lua/cartograph/algebra'
    local core = table.concat(vim.fn.readfile(dir .. '/core.lua'), '\n')

    -- the PARTS table: `name = local_name`, from `local PARTS = {` to its `}`
    local decl = core:match('\nlocal PARTS = (%b{})')
    ok(decl, 'core declares a PARTS table')
    local supplied = {}
    for k, v in decl:gmatch('([%w_]+)%s*=%s*([%w_]+)') do supplied[k] = v end
    local nsup = 0; for _ in pairs(supplied) do nsup = nsup + 1 end
    ok(nsup >= 8, 'and it supplies a plausible number of locals: ' .. nsup)

    -- core's own module-level locals
    -- ⚠ FOUR DECLARATION FORMS, AND MISSING ONE IS A FALSE ALARM. The first cut
    -- read `local function X` and `local X =` only, and reported that PARTS hands
    -- round `subst`, which core no longer defines — core declares it at :397 as a
    -- bare FORWARD DECLARATION, `local subst`, assigned further down. A fence that
    -- over-reports on a declaration form it does not know teaches its reader to
    -- ignore it, which is the same cost as one that never fires.
    local defined = {}
    for n in core:gmatch('\nlocal function ([%w_]+)') do defined[n] = true end
    for names in core:gmatch('\nlocal ([%w_,%s]+)=') do          -- incl. `local a, b =`
        for n in names:gmatch('[%w_]+') do defined[n] = true end
    end
    for names in core:gmatch('\nlocal ([%w_,%s]+)\n') do        -- forward declarations
        for n in names:gmatch('[%w_]+') do defined[n] = true end
    end

    --- ★★★ AND EACH MUST BE DEFINED EXACTLY ONCE (CART-0924). `local PARTS = {…}`
    --- is built at the BOTTOM of core, so a name declared TWICE resolves there to
    --- the LAST definition — and a section from higher up in the file was written
    --- against the earlier one. MEASURED: `cat`@1448 and `is_prefix`@1438 with
    --- `M.classify` at 1450, and second definitions at 4609/4614 inside the
    --- VERTICAL DIFFERENCES section. Splitting `classify` silently turned a
    --- `value` edit into a `straddle`, and 17 donor tests caught it.
    --- ⇒ LUA SCOPING IS POSITIONAL AND THIS TABLE IS NOT. The fix is unique names;
    ---   this is the fence that keeps them unique.
    local counts = {}
    for n in core:gmatch('\nlocal function ([%w_]+)') do counts[n] = (counts[n] or 0) + 1 end
    local ambiguous = {}
    for k, v in pairs(supplied) do
        if (counts[v] or 0) > 1 then
            ambiguous[#ambiguous + 1] = ('%s = %s (%d definitions)'):format(k, v, counts[v])
        end
    end
    table.sort(ambiguous)
    eq(0, #ambiguous, 'PARTS hands round a name core defines MORE THAN ONCE, so'
        .. ' every part gets whichever one is in scope at the BOTTOM of the file: '
        .. table.concat(ambiguous, ', '))

    -- ★ EVERY VALUE PARTS HANDS ROUND MUST STILL EXIST IN CORE. This is the half
    -- that catches a local LEAVING with a section.
    local dead = {}
    for k, v in pairs(supplied) do
        if not defined[v] then dead[#dead + 1] = ('%s = %s'):format(k, v) end
    end
    table.sort(dead)
    eq(0, #dead, 'PARTS hands round a local core no longer defines: ' ..
        table.concat(dead, ', '))

    -- ★ AND EVERY `S.<name>` A PART READS MUST BE SUPPLIED. This is the half that
    -- catches the `key` bug — a part reading something nobody passes it.
    local parts, missing, total = 0, {}, 0
    for _, path in ipairs(vim.fn.glob(dir .. '/*.lua', false, true)) do
        local name = path:match('([^/]+)%.lua$')
        if name ~= 'core' and name ~= 'origin' then
            local src = table.concat(vim.fn.readfile(path), '\n')
            ok(src:find('return function (M, SHARED)', 1, true),
                name .. ' opens with the part signature')
            parts = parts + 1
            -- ★ THE SAME TOOL THE HARNESS-SHIM FENCE USES (`tools/surface.lua`):
            -- `reads ⊆ supplied`, one interface apart. Its receiver FRONTIER is
            -- what stopped this reporting `termgraph reads S.eqs` — that part's
            -- own term-graph store — back when the parameter was called `S`.
            local surface = dofile(vim.fn.getcwd() .. '/tools/surface.lua')
            for full in pairs(surface.uses(src, { receivers = { 'SHARED' } })) do
                total = total + 1
                local n = full:sub(#'SHARED.' + 1)
                if not supplied[n] then
                    missing[#missing + 1] = ('%s reads SHARED.%s'):format(name, n)
                end
            end
        end
    end
    ok(parts >= 4, 'the fence actually looked at parts: ' .. parts)
    ok(total >= 8, 'and at a plausible number of reads: ' .. total)
    table.sort(missing)
    eq(0, #missing, 'a part reads something PARTS does not supply: ' ..
        table.concat(missing, ', '))
end)

--- ⚠ AND THE STRUCTURAL CHECK IS NOT ENOUGH ON ITS OWN: it proves the wiring is
--- consistent, not that the code behind it works. One arrow per part, RUN.
test('algebra parts: one arrow from each part actually runs', function ()
    local alg = require 'cartograph.algebra'
    local A = alg.load()
    if not A then skip('algebra unavailable') end
    local t1 = A.node('f', A.name('x'), A.lit('number:1'))
    local t2 = A.node('f', A.name('y'), A.lit('number:1'))
    local cases = {
        { 'hopau',       function () return A.lam('x', A.name('x')) end },
        { 'termgraph',   function () return A.tg_of_term(t1) end },
        { 'eau',         function () return A.flatten(t1, { f = 'A' }) end },
        { 'materialize', function () return A.is_absence('absent') end },
        { 'tai',         function () return A.jwz(t1, t2) end },
        { 'vertical',    function () return A.vertical(t1, t2) end },
        -- ⚠ `generalize(instances, opts)` takes a LIST. Calling it with two terms
        -- raised "attempt to index a nil value", which is this test being
        -- wrong rather than the part being broken — exactly what a smoke
        -- test must not confuse.
        { 'core',        function () return A.generalize({ t1, t2 }) end },
    }
    for _, c in ipairs(cases) do
        local okc, r = pcall(c[2])
        ok(okc and r ~= nil, ('%s: %s'):format(c[1],
            okc and 'ran' or tostring(r):gsub('.*:%d+: ', '')))
    end
end)
