-- `ts.flow_stop` — WHERE THE FLOW WALK STOPS, AND WHO IS ALLOWED TO CHANGE IT.
--
-- ★★★ THE ACCESSOR HAD NO TEST AT ALL until CART-0929, which is how the defect
-- below survived: `flow_stop` computed `LEGACY u (fn_types \ fn_unminted)`, so the
-- seven LEGACY names were immune to the very mechanism built to withdraw them.
-- Nothing was red, because no shipped spec had yet asked. An override nobody has
-- exercised is indistinguishable from one that does not work.
--
-- ⚠ BOTH DIRECTIONS ARE PINNED, per [[test-the-premise-not-the-consequence]]. A
-- suite that only checks "a withdrawn type is gone" passes for a flow_stop that
-- returns the empty set; one that only checks "LEGACY is present" passes for the
-- broken version this replaces. Each test below states which half it holds.

local ts = require 'cartograph.providers.treesitter'

--- The seven LEGACY names, RESTATED here because the table is a module local.
--- ⚠ A RESTATEMENT IS A SECOND LIST, the exact thing CART-0928/0929 are about — so
--- it is not trusted: `legacy_of()` below reads the set back OUT of the
--- implementation, and the first test asserts the two agree. If someone adds an
--- eighth name and not the line here, that test fails rather than silently
--- narrowing every assertion underneath it.
local LEGACY_RESTATED = { 'function_definition', 'function_declaration',
    'method_declaration', 'anonymous_function', 'arrow_function',
    'lambda_expression', 'constructor_declaration' }

--- flow_stop for a synthetic language, so no shipped spec is mutated.
--- `fn_types = {}` is a declared REFUSAL (treesitter.lua:1002), so a spec carrying
--- it contributes NOTHING to the union and whatever comes back IS legacy.
local function stop_for(fn_types, fn_unminted)
    local lang = '__flowstop_probe__'
    ts.spec[lang] = { fn_types = fn_types, fn_unminted = fn_unminted }
    -- ⚠ CLEARED EVEN IF flow_stop THROWS. `ts.spec` is process-wide, and a probe
    -- left behind carries `fn_unminted` naming a LEGACY type — which is exactly what
    -- the tripwire at the bottom scans for, so the leak would report a PHANTOM
    -- offender and send the reader to the wrong test while the real one is already
    -- broken. A second, lying failure is worse than none.
    local okc, out = pcall(ts.flow_stop, lang)
    ts.spec[lang] = nil
    if not okc then error(out, 0) end
    return out
end

local function legacy_of() return stop_for({}, nil) end

local function sorted_keys(t)
    local ks = {}
    for k in pairs(t) do ks[#ks + 1] = k end
    table.sort(ks)
    return ks
end

--- ★ THE ANCHOR. Ties the restatement above to the implementation, and doubles as
--- the "LEGACY is still the DEFAULT" half: a spec that withdraws nothing keeps all
--- seven. A fix that made the subtraction too eager fails here.
test('flow_stop: a spec that withdraws nothing gets exactly the seven LEGACY stops',
    function ()
        local want = {}
        for _, k in ipairs(LEGACY_RESTATED) do want[#want + 1] = k end
        table.sort(want)
        -- SET EQUALITY, not containment: containment alone would pass for a LEGACY
        -- that had quietly grown an eighth name.
        eq(want, sorted_keys(legacy_of()),
            'the restated LEGACY list and the implementation agree, exactly')
    end)

--- ★★★ THE MUTATION-CATCHER, and the whole reason CART-0929 exists. Revert
--- flow_stop to `LEGACY u (fn_types \ fn_unminted)` and this is the test that goes
--- red — under the old code `function_definition` came back from the LEGACY arm no
--- matter what the spec said.
test('flow_stop: a LEGACY name CAN be withdrawn by fn_unminted', function ()
    local got = stop_for({}, { function_definition = true })
    ok(not got.function_definition,
        'function_definition is in LEGACY and was declared unminted, so it is NOT a stop')
    ok(got.function_declaration,
        'and the withdrawal is SURGICAL — its six siblings are untouched')
    eq(#LEGACY_RESTATED - 1, #sorted_keys(got), 'exactly one name left the set')
end)

--- ★ THE PRE-EXISTING HALF, which the fix must not have broken: withdrawing a type
--- the language DECLARED (not a LEGACY name) worked before and still does. This is
--- the path ruby/python/rust/go/js actually use today.
test('flow_stop: a declared fn_types name is still withdrawable, and still unions in',
    function ()
        local kept = stop_for({ func_literal = true }, nil)
        ok(kept.func_literal, 'a declared scope type is a stop')
        ok(kept.function_definition, 'and LEGACY is still unioned in beside it')
        local gone = stop_for({ func_literal = true }, { func_literal = true })
        ok(not gone.func_literal, 'declaring it unminted withdraws it, as it always did')
        ok(gone.function_definition, 'without disturbing LEGACY')
    end)

--- ★ A WITHDRAWAL NAMING SOMETHING NOBODY DECLARED IS INERT, not an error. The
--- specs are hand-written and a grammar can rename a node out from under one
--- (php's `anonymous_function_creation_expression`, CART-0306), so a stale entry
--- must not take the set with it.
test('flow_stop: withdrawing a name that is in neither set changes nothing', function ()
    local got = stop_for({ func_literal = true }, { no_such_node_type = true })
    eq(#LEGACY_RESTATED + 1, #sorted_keys(got), 'the set is untouched')
end)

--- ★★★ THE TRIPWIRE ON THE CLAIM, not on the code. CART-0929 landed asserting it
--- was ZERO-DELTA, and the proof was a set intersection: no shipped spec withdraws
--- a LEGACY name, so re-parenthesising the subtraction moved nothing. That claim is
--- only true until someone declares one — at which point the change stops being
--- inert and the corpus pins (dfgate, exprcensus, dfparity) must be re-measured.
--- ⚠ THIS TEST GOING RED IS NOT A BUG. It means a spec became the first real user
--- of the mechanism. Re-run the gates, repin, and update the count here.
test('flow_stop: no shipped spec yet withdraws a LEGACY name (zero-delta tripwire)',
    function ()
        local legacy, n_langs, offenders = legacy_of(), 0, {}
        for lang, s in pairs(ts.spec) do
            if type(s) == 'table' then
                n_langs = n_langs + 1
                for t in pairs(s.fn_unminted or {}) do
                    if legacy[t] then
                        offenders[#offenders + 1] = lang .. '.' .. t
                    end
                end
            end
        end
        -- ⚠ THE GUARD THAT KEEPS THIS FROM BEING VACUOUS. If `ts.spec` were lazy or
        -- empty the loop above would pass by finding nothing, which is the failure
        -- mode this whole file is about.
        ok(n_langs >= 10, 'the sweep actually saw the specs: ' .. n_langs .. ' languages')
        -- ⚠ WHEN THIS FIRES, THE FIX IS NOT TO DELETE THE TEST. Replace `{}` with the
        -- offenders now expected — e.g. { 'lua.function_definition' } — AFTER re-running
        -- dfgate / exprcensus / dfparity and repinning, because at that point the
        -- re-parenthesisation has stopped being inert and is moving real rows.
        eq({}, offenders,
            'a spec now withdraws a LEGACY name — re-measure the corpus pins, see the header')
    end)
