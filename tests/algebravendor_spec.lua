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
