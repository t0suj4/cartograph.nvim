-- THE DONOR'S OWN 372 TESTS, RUN AGAINST OUR VENDORED COPY (CART-0912).
-- (243 at the 2026-09-13 cut; 372 since the 2026-09-19 re-vendor.)
--
-- ★★★ THIS IS WHAT MAKES THE PROOF OURS RATHER THAN BORROWED. The code has been
-- ours since the vendoring, and we have since SPLIT IT 23 WAYS — a capability
-- whose evidence lives in someone else's repository is one we cannot re-check
-- after we change it. The donor's tests know nothing about parts, so they pass
-- only if the adaptation preserved behaviour exactly. ⇒ THEY ARE THE ACCEPTANCE
-- ORACLE FOR THE SPLIT, not a nicety.
--
-- ★★ THE THREE BANDS, EXACTLY AS THE USER DESCRIBED THEM:
--      VERBATIM  tests/vendor/algebra_spec.lua — 8270 lines, byte-identical,
--                stamped in `cartograph.algebra.origin` and watched by
--                `tools/vendordrift.lua` as its SECOND unit
--      ADAPT     this file: a harness shim, ~60 lines
--      NEW       nothing
--    The whole adaptation is the harness, which is the smallest possible cut.
--
-- ⚠ THE RE-VENDOR ADDED A THIRD ABSENCE KIND TO THE SHIM, NOT A FOURTH BAND.
-- 43 of the 372 pend on the donor's `experiments/` fixtures, which are its
-- measurement corpus and did not come with the code. The donor declares that
-- contract itself beside its first use — "a re-vendored spec without
-- experiments/ pends by name" — so `pending` is mapped onto `skip` and the two
-- tests that `dofile` a fixture UNGUARDED are classified the same way, by a
-- pattern that must name a missing file under `experiments/`. ⇒ WE HOLD THE
-- CODE BUT NOT ALL OF ITS EVIDENCE: the lossless lua reader, the scope-graph
-- census and the keyed oracle cannot be re-checked here.
--
-- ⚠ THE SHIM IS LOADED INTO A PRIVATE ENVIRONMENT, NOT INSTALLED GLOBALLY.
-- `assert` is a Lua builtin every other spec uses; overriding `_G.assert` to
-- mean busted's would be a global change to satisfy one file. `setfenv` gives
-- the donor chunk its own `_G`, and the `it` closures capture it, so the
-- assertions still resolve when the runner calls them later.

local schema_ok = true

--- ★★★ FAITHFUL, NOT CONVENIENT. busted's `assert.equals` is `==`; `assert.same`
--- is DEEP. Our `eq` is `vim.deep_equal`, so mapping `equals` onto it would make
--- the donor's oracle WEAKER — tests that busted fails would pass here, which is
--- the flattering direction and the one nobody questions. `equals` is strict.
--- ⚠ Likewise `is_true` is `== true`, not truthiness: busted distinguishes them
--- and so do 447 of these assertions.
local function mkassert(fail)
    local A = setmetatable({}, { __call = function (_, v, msg)
        if not v then fail(msg or 'assertion failed') end
        return v
    end })
    local function strict_eq(a, b, msg)
        if a ~= b then
            fail(('%s\n       expected: %s\n       got:      %s')
                :format(msg or 'assert.equals', vim.inspect(a), vim.inspect(b)))
        end
    end
    local function deep_eq(a, b, msg)
        if not vim.deep_equal(a, b) then
            fail(('%s\n       expected: %s\n       got:      %s')
                :format(msg or 'assert.same', vim.inspect(a), vim.inspect(b)))
        end
    end
    A.equals, A.equal = strict_eq, strict_eq
    A.same = deep_eq
    A.are = { same = deep_eq, equal = strict_eq, equals = strict_eq }
    A.is_true = function (v, m) if v ~= true then fail(m or ('expected true, got ' .. vim.inspect(v))) end end
    A.is_false = function (v, m) if v ~= false then fail(m or ('expected false, got ' .. vim.inspect(v))) end end
    A.is_nil = function (v, m) if v ~= nil then fail(m or ('expected nil, got ' .. vim.inspect(v))) end end
    A.truthy = function (v, m) if not v then fail(m or 'expected truthy') end end
    A.is_truthy = A.truthy
    A.falsy = function (v, m) if v then fail(m or 'expected falsy') end end
    A.is_falsy = A.falsy
    A.matches = function (pat, s, m)
        if type(s) ~= 'string' or not s:match(pat) then
            fail(m or ('%q does not match %q'):format(tostring(s), tostring(pat)))
        end
    end
    -- ★ THE FOUR THE TOTALITY FENCE FOUND, and it found them before I read a
    -- single failing test: `assert.are_not.equal`, `assert.is_not.equals`,
    -- `assert.is_not_nil`, `assert.has_error`. Three of the thirteen failures
    -- were this, and one of them ("attempt to index field 'are_not'") was the
    -- only one that named itself.
    local function ne(a, b, m)
        if a == b then fail(m or ('expected NOT ' .. vim.inspect(a))) end
    end
    A.are_not = { same = function (a, b, m)
        if vim.deep_equal(a, b) then fail(m or 'expected NOT the same') end
    end, equal = ne, equals = ne }
    A.is_not = { equals = ne, equal = ne, same = A.are_not.same }
    A.is_not_nil = function (v, m) if v == nil then fail(m or 'expected non-nil') end end
    --- ⚠ `has_error` TAKES A FUNCTION AND EXPECTS IT TO RAISE. Mapping it to
    --- anything weaker would turn a test that demands a refusal into one that
    --- accepts silence, which is the exact defect class this algebra is about.
    A.has_error = function (fn, expected, m)
        local okc, err = pcall(fn)
        if okc then fail(m or 'expected an error, none raised') end
        if expected ~= nil and not vim.deep_equal(expected, err)
            and not (type(err) == 'string' and type(expected) == 'string'
                     and err:find(expected, 1, true)) then
            fail(m or ('the error did not match: %s vs %s')
                :format(vim.inspect(expected), vim.inspect(err)))
        end
    end
    return A
end

--- the surface the shim SUPPLIES — read by the totality fence below, so the
--- list cannot drift from the implementation
local SUPPLIES = { 'describe', 'it', 'assert', 'assert.equals', 'assert.equal',
    'assert.same', 'assert.are.same', 'assert.are.equal', 'assert.is_true',
    'assert.is_false', 'assert.is_nil', 'assert.truthy', 'assert.is_truthy',
    'assert.falsy', 'assert.is_falsy', 'assert.matches',
    'assert.are_not.same', 'assert.are_not.equal', 'assert.are_not.equals',
    'assert.is_not.equals', 'assert.is_not.equal', 'assert.is_not.same',
    'assert.is_not_nil', 'assert.has_error', 'pending' }

local function load_donor()
    local path = vim.fn.getcwd() .. '/tests/vendor/algebra_spec.lua'
    local chunk, lerr = loadfile(path)
    if not chunk then return nil, lerr end

    local stack, registered = {}, 0
    local env = setmetatable({}, { __index = _G })
    env.assert = mkassert(function (m) error(m, 3) end)
    env.describe = function (name, fn)
        stack[#stack + 1] = name
        fn()
        stack[#stack] = nil
    end
    -- ★★ A DECLARED-UNPORTED DEPENDENCY IS A SKIP, NAMED — NOT A FAILURE AND NOT
    -- SILENCE. `cartograph.algebra.origin.unported` records that `derive` (the
    -- env-gated re-derivation affordance) did not come with the vendoring, and
    -- two donor tests require it directly. Reporting those as FAILURES would
    -- blame us for a dependency we deliberately left behind; deleting them would
    -- hide that the donor proves something we cannot.
    -- ⚠ THE SET IS CLOSED AND SMALL ON PURPOSE: only a module named here turns an
    -- error into a skip, so a genuine "module not found" still fails loudly.
    local UNPORTED = {
        derive = 'a prototype-development affordance, deliberately not vendored'
            .. ' — see cartograph.algebra.origin.unported',
    }
    --- ★★★ `pending` IS THE DONOR'S OWN WORD FOR "NOT ANSWERABLE HERE", AND THE
    --- DONOR WROTE IT FOR US. Its spec says so in as many words beside the first
    --- use: "the reader module lives beside the prototype; a re-vendored spec
    --- without experiments/ pends by name". busted has `pending`; this harness
    --- has `skip`; without the mapping all 40 of those became FAILURES, which is
    --- the flattering direction's opposite — it blames the copy for a fixture
    --- the donor deliberately kept.
    env.pending = function (why) skip('donor pending: ' .. tostring(why)) end
    env.it = function (name, fn)
        local full = table.concat(stack, ' / ') .. ' / ' .. name
        registered = registered + 1
        local inner = fn
        fn = function ()
            local okr, err = pcall(inner)
            if okr then return end
            local mod = type(err) == 'string' and err:match("module '([%w_.]+)' not found")
            if mod and UNPORTED[mod] then
                skip(('requires `%s`: %s'):format(mod, UNPORTED[mod]))
            end
            -- ⚠ THE SAME DOCTRINE, ONE DEPENDENCY KIND OVER: the donor's
            -- `experiments/` fixtures are its measurement material, not the
            -- algebra, and they did not come with the vendoring. Most donor
            -- tests guard them with `pending`; TWO `dofile` them unguarded, and
            -- the intent is plainly the same. The pattern is deliberately
            -- narrow — it must name a missing file under `experiments/`, so a
            -- genuine error from inside a fixture that IS present still fails.
            local fx = type(err) == 'string'
                and err:match("cannot open (experiments/[%w_%-%.]+)")
            if fx then
                skip(('requires `%s`: a donor fixture, not vendored'):format(fx))
            end
            error(err, 0)
        end
        -- ⚠ REGISTERED THROUGH OUR OWN `test`, so a donor test is a first-class
        -- row in this suite: it fails where every other test fails, and its name
        -- says which describe block it came from.
        _G.test('algebra(donor): ' .. full, fn)
    end
    -- the donor requires `algebra` by bare name; ours is the vendored module,
    -- ★ ASSEMBLED FROM ITS PARTS — so these tests exercise the SPLIT
    package.preload['algebra'] = function () return require 'cartograph.algebra.core' end
    setfenv(chunk, env)
    local ok, err = pcall(chunk)
    package.preload['algebra'] = nil
    if not ok then return nil, err end
    return registered
end

local n, why = load_donor()
if not n then
    schema_ok = false
    test('algebra(donor): the vendored spec loads', function ()
        ok(false, 'the donor spec did not load: ' .. tostring(why))
    end)
end

--- ★★★ CAN THE TOOL CREATE THE SHIM? IT CAN DERIVE THE OBLIGATION AND FENCE THE
--- TOTALITY; IT CANNOT INVENT THE SEMANTICS. That `assert.equals` is `==` while
--- `assert.same` is deep is a fact about busted, not about the text. What IS
--- derivable is WHICH NAMES the donor reaches for that nothing here defines —
--- and that is the same check as the PARTS fence (`reads ⊆ supplied`), one
--- interface over. This is that check.
test('algebra(donor): the shim is TOTAL over the surface the donor uses', function ()
    if not schema_ok then skip('the donor spec did not load') end
    local src = table.concat(vim.fn.readfile(vim.fn.getcwd()
        .. '/tests/vendor/algebra_spec.lua'), '\n')
    -- ★ THROUGH `tools/surface.lua`, which is this check promoted out of the two
    -- places I hand-rolled it. It carries the floor itself: a scan that matches
    -- nothing reports zero missing, which is the same answer as a complete shim.
    local surface = dofile(vim.fn.getcwd() .. '/tools/surface.lua')
    local used = surface.uses(src, { receivers = { 'assert' }, bares = { 'describe', 'it' } })
    local missing, why = surface.gap(used, SUPPLIES)
    ok(missing, tostring(why))
    eq(0, #missing, surface.report(missing, 'the donor\'s harness surface'))

    local nused = 0; for _ in pairs(used) do nused = nused + 1 end
    ok(nused >= 8, 'the scan found the donor\'s surface: ' .. nused)
    ok(n >= 200, 'and the donor registered its tests: ' .. tostring(n))
end)
